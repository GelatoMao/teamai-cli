# 第 1 步：TeamAI 怎么挂进 AI 工具（hook 层）

> 面向小白。基于 `main@fe3b906` 源码（2026-10-17），代码片段标注 `文件:行号`；行号会随代码变动，以函数名/常量名为准。为便于阅读删减了部分注释，用 `// ...` 省略无关分支。
> 调度器内部机制（并发、错误隔离、输出合并、后台 detach）已在 [../hook-dispatcher.md](../hook-dispatcher.md) 详细讲过，本篇只简述。本篇从“知识沉淀”视角看：哪些 handler 挂在哪个事件上，为什么前台或后台。

导航：上一步 [README.md（索引）](./README.md) | 下一步 [02-friction-detection.md](./02-friction-detection.md)

---

## 0. 一句话 + 一个类比

一句话：teamai 在每个 AI 工具里为每个生命周期事件（SessionStart、Stop、PostToolUse、UserPromptSubmit，部分工具还有 SessionEnd / SubagentStop / SubagentStart）各注册一条 `teamai hook-dispatch <event> --tool <tool>` 命令；被触发后，调度器按注册表 `buildHandlerRegistry()` 找出该事件的 handler，其中一批负责知识沉淀：会话开始时拉取团队知识，过程中记下读了哪些知识，结束时检测摩擦、提示沉淀、给被采纳的知识投票。

类比：图书馆的门禁闸机。

- 闸机（hook 命令）装在每个入口（AI 工具），每个“动作”（进门、借书、出门）只有一个传感器
- 进门时（SessionStart）：后台补货员悄悄把新书上架（pull），前台递给你一张今日须知（team rules）
- 借书时（PostToolUse）：记一笔“这个人翻了哪本书”（recall-attribution）
- 出门时（Stop）：问一句“今天遇到难题了吗？要不要写个心得？”（contribute-check），并给你翻过且用上的书点个赞（votes-sync）

---

## 1. 为什么需要 hook 层

知识沉淀要回答三个问题：知识怎么到达 agent、agent 用了哪些知识、新知识从哪里产生。这三件事都发生在 AI 工具的会话里，而 teamai 是一个外部 CLI，看不到会话内部。唯一的切入点是 AI 工具对外暴露的 hook：特定事件发生时执行一条 shell 命令，把事件 payload 通过 STDIN 交给它，命令的 STDOUT 还能被注入回会话。

| 知识沉淀环节 | 需要的时机 | 挂载的事件 |
| --- | --- | --- |
| 把团队最新知识同步到本机 | 会话一开始 | SessionStart |
| 告诉 agent 团队规则 / 有新合入的 MR 可提炼 | 会话一开始，且要注入上下文 | SessionStart（Codex 子 agent 用 SubagentStart） |
| 记录 agent 读了哪些召回到的知识 | 每次工具调用之后 | PostToolUse |
| 判断这次会话值不值得沉淀 | 一轮对话结束 | Stop |
| 给被采纳的知识投赞成票 | 一轮结束 / 子 agent 结束 / 会话结束 | Stop、SubagentStop、SessionEnd |
| 补发 Stop 时发不出去的提示 | 用户下一次提问 | UserPromptSubmit |

设计取舍（后文逐条展开）：

- 每事件一条命令，而不是每功能一条：加功能只改注册表，不动各工具的配置文件。
- 前台 / 后台二分：需要把文字注入会话的 handler 必须前台等结果；纯副作用（拉取、上报、慢的 LLM 判断）放进脱离宿主的后台进程，避免宿主 hook 超时（代码注释写明 CodeBuddy 约 10 秒强杀 hook）。
- 两道配置闸门：没装 teamai 的目录不跑团队 handler（`requiresConfig`）；HTTP 只读源的团队不跑 git 专属功能（`gitOnly`）。

---

## 2. 第一层：装进工具的是什么命令

### 2.1 内置 hook 规格表 `BUILTIN_HOOK_SPECS`

`src/builtin-hooks.ts:303` 定义了每条规格的形状：

```ts
interface BuiltinHookSpec {
  /** description keyword (stable identity / HookDef.key). */
  key: string;
  /** Claude PascalCase event. */
  event: string;
  /** hook-dispatch sub-event passed to the command. */
  dispatchEvent: string;
  /** matcher ("*" = wildcard, no --matcher arg, omitted in Cursor output). */
  matcher: string;
  /** Per-hook timeout in seconds (rendered for Cursor and WorkBuddy). */
  timeoutSec: number;
}
```

`src/builtin-hooks.ts:316` 是所有工具共享的 6 条：

```ts
const BUILTIN_HOOK_SPECS: BuiltinHookSpec[] = [
  { key: 'Hook dispatch session-start', event: 'SessionStart', dispatchEvent: 'session-start', matcher: '*', timeoutSec: 15 },
  { key: 'Hook dispatch stop', event: 'Stop', dispatchEvent: 'stop', matcher: '*', timeoutSec: 15 },
  { key: 'Hook dispatch post-tool-use wildcard', event: 'PostToolUse', dispatchEvent: 'post-tool-use', matcher: '*', timeoutSec: 10 },
  { key: 'Hook dispatch post-tool-use Skill', event: 'PostToolUse', dispatchEvent: 'post-tool-use', matcher: 'Skill', timeoutSec: 10 },
  { key: 'Hook dispatch post-tool-use TodoWrite', event: 'PostToolUse', dispatchEvent: 'post-tool-use', matcher: 'TodoWrite', timeoutSec: 3 },
  { key: 'Hook dispatch prompt-submit', event: 'UserPromptSubmit', dispatchEvent: 'prompt-submit', matcher: '*', timeoutSec: 10 },
];
```

逐列解释：

- `event` 是宿主认识的 PascalCase 事件名；`dispatchEvent` 是传给 `hook-dispatch` 的 kebab-case 子事件名，第 3 节的注册表按它路由。
- `matcher` 为 `*` 时命令里不带 `--matcher`；`Skill` / `TodoWrite` 是只在特定工具调用后触发的专用条目。
- `timeoutSec` 是写进工具配置的宿主侧超时（秒），和 handler 自己的 `timeoutMs`（毫秒）是两回事，见 3.2。
- `key` 是这条 hook 的稳定身份，也会拼进 `description`。reconcile 靠它认出“这条是 teamai 装的”，更新/删除时不误伤用户自己写的 hook。

以 `Stop` 那一行为例，整行读作：在宿主的 `Stop` 事件（一轮结束）上注册 `teamai hook-dispatch stop --tool <tool>`，任何情况都触发，宿主最多等 15 秒。

易混点：

- `event` 不是跨工具的公认标准，而是 Claude Code 的命名（源码注释 `/** Claude PascalCase event. */`）。teamai 把它当内部统一写法，写配置时再翻译成各家原生名：

  | Claude（内部写法） | Cursor | OpenCode | Pi |
  | --- | --- | --- | --- |
  | SessionStart | sessionStart | session.created | session_start |
  | Stop | stop | session.idle | agent_settled |
  | PostToolUse | postToolUse | tool.execute.after | tool_execution_end |
  | UserPromptSubmit | beforeSubmitPrompt | chat.message | before_agent_start |

  映射表见 `CLAUDE_TO_CURSOR_EVENTS`（`src/hooks.ts:72`）、`CLAUDE_TO_OPENCODE_EVENTS`（`src/opencode-hooks.ts:462`）、`CLAUDE_TO_PI_EVENTS`（`src/pi-hooks.ts:37`）。Copilot / Codex / CodeBuddy / Qoder 沿用 Claude 兼容格式，所以名字一样；OpenClaw 只映射得上 SessionStart 和 UserPromptSubmit（`src/openclaw-hooks.ts:337`）。语义也只是“近似”，比如 Stop 在 OpenCode 是“会话空闲”。宿主没有对应事件的，就不装那条。
- `matcher` 里的 `Skill`、`TodoWrite` 是宿主自带的工具名（Claude Code 里加载 skill、维护待办的工具），不是 teamai 提供的。按工具名过滤由宿主完成，teamai 只填名字。
- 为什么 PostToolUse 要拆成三行：dispatcher 按 `event` + `matcher` 精确匹配 handler（见 3.1），三行各管各的 handler。调一次 Skill 工具，宿主会同时命中 `*` 和 `Skill` 两行，起两个 teamai 进程，各跑各的，不重复。
- `timeoutSec` 的源码注释写“rendered for Cursor and WorkBuddy”，已过时；实际写入超时的工具以 `builtinHookDefs` 的 `withTimeout` 为准（见 2.3）。

6 行各自触发哪些 handler（完整清单见 `buildHandlerRegistry()`，本篇第 4 节只挑沉淀相关的讲）：

- session-start：pull（后台）、team-rules、mr-hint、package-hint、team-env-hint、dashboard-report、local-agent，webhook（后台）。
- stop：votes-sync、contribute-check（前台，可能回写提示）；update、votes-judge、dashboard-report、local-agent、webhook（后台）。
- post-tool-use `*`：recall-attribution、dashboard-report，local-agent（后台）。
- post-tool-use `Skill`：track（统计 skill 使用），webhook（后台）。
- post-tool-use `TodoWrite`：todowrite-hint。宿主上限 3 秒，handler 预算压到 `TODOWRITE_HINT_TIMEOUT_MS = 2_500`。
- prompt-submit：pending-hint、package-pending-hint、track-slash（统计斜杠命令）、dashboard-report、local-agent。

### 2.2 按工具追加的事件：SessionEnd / SubagentStop / SubagentStart

三条额外规格只给特定工具（`src/builtin-hooks.ts:325`、`:333`、`:346`）：

```ts
const COPILOT_SESSION_END_SPEC: BuiltinHookSpec = {
  key: 'Hook dispatch session-end',
  event: 'SessionEnd',
  dispatchEvent: 'session-end',
  matcher: '*',
  timeoutSec: 15,
};

const SUBAGENT_STOP_SPEC: BuiltinHookSpec = {
  key: 'Hook dispatch subagent-stop',
  event: 'SubagentStop',
  dispatchEvent: 'subagent-stop',
  matcher: '*',
  timeoutSec: 15,
};
// SUBAGENT_START_SPEC 结构相同：event 'SubagentStart'，dispatchEvent 'subagent-start'
```

谁能拿到 SubagentStop，由 `src/builtin-hooks.ts:367` 的白名单决定：

```ts
const SUBAGENT_STOP_TOOLS = new Set([
  'claude', 'claude-internal', 'tclaude', ...CODEX_TOOL_IDS, 'codebuddy', 'qoder', 'qoder-cn',
]);
```

三者都和知识沉淀有关，理由都写在源码注释里：

- SessionEnd 只给 Copilot：Copilot 最后一轮可能只发 SessionEnd、不发 Stop，所以投票同步也挂在这里，否则最后一轮的采纳记录推不出去（`src/hook-handlers.ts:1153` 注释，#884）。
- SubagentStop 只给“子 agent 结束时带父会话 session id”的工具：子 agent 可能在父会话最后一次 Stop 之后才结束（后台 worker），它读过的知识要在这时记账（`src/builtin-hooks.ts:354` 注释）。Cursor / Copilot 的子 agent 跑在独立会话里，没有 hook 能关联到父会话；ZCode 没有这个事件，且遇到未知 key 会拒绝整个 hooks 块；WorkBuddy 的引擎版本未核实——所以都不加。
- SubagentStart 只给 Codex 家族：Codex 新开的子 agent 只触发 SubagentStart、不触发 SessionStart，团队规则只能从这里送进去（`src/builtin-hooks.ts:341` 注释，#938）。

### 2.3 `builtinHookDefs()`：把规格渲染成每个工具的 hook 定义

`src/builtin-hooks.ts:392`：

```ts
export function builtinHookDefs(tool: string): HookDef[] {
  const withTimeout = tool === 'cursor' || tool === 'copilot' || tool === 'workbuddy' || tool === 'codebuddy' || isCodexTool(tool);
  const buildCommand = tool === 'zcode'
    ? getRawDispatchCommand
    : toolUsesPwshShell(tool)
      ? getPwshDispatchCommand
      : WRAPPER_TOOLS.has(tool)
        ? getWrapperDispatchCommand
        : getDispatchCommand;
  const specs = [
    ...BUILTIN_HOOK_SPECS,
    ...(tool === 'copilot' ? [COPILOT_SESSION_END_SPEC] : []),
    ...(SUBAGENT_STOP_TOOLS.has(tool) ? [SUBAGENT_STOP_SPEC] : []),
    ...(isCodexTool(tool) ? [SUBAGENT_START_SPEC] : []),
  ];
  return specs.map((spec) => ({
    source: 'builtin' as const,
    key: spec.key,
    event: spec.event,
    matcher: spec.matcher === 'Skill' ? SKILL_TOOL_MATCHER[tool] ?? spec.matcher : spec.matcher,
    command: buildCommand(spec.dispatchEvent, tool, spec.matcher),
    timeout: withTimeout ? spec.timeoutSec : undefined,
    ...(isCodexTool(tool) && (spec.event === 'SessionStart' || spec.event === 'SubagentStart') ? { additionalContextLimit: 0 } : {}),
    description: `${TEAMAI_HOOK_DESCRIPTION_PREFIX} ${spec.key}`,
  }));
}
```

逐段看：

1. `withTimeout`：只有 Cursor、Copilot、WorkBuddy、CodeBuddy、Codex 家族把 `timeoutSec` 写进配置；Claude 不写（测试 `Claude defs carry no timeout; ...` 钉住了这一点）。
2. `buildCommand` 四选一：ZCode 用裸命令（它的 hook 是 argv 形式，由写入器自己包 `bash -lc`）；Windows 上的 DSH 用 PowerShell 语法；WorkBuddy / CodeBuddy 用带 `$HOME/.teamai/bin` PATH 的包装命令；其余用 `getDispatchCommand`。
3. `specs` 拼接：共享 6 条 + 按工具追加的 0~2 条。所以 Claude 是 6 + SubagentStop = 7 条，Copilot 是 6 + SessionEnd = 7 条。
4. `matcher`：Skill 专用条目在不同工具里名字不同，`SKILL_TOOL_MATCHER`（`src/builtin-hooks.ts:390`）把它映射成 Cursor 的 `Read`、Copilot 的 `skill`、Muse 的 `read_skill`（Cursor 没有独立 Skill 工具，是 Read 一下 `SKILL.md` 来加载 skill，#1156）；但命令里仍是 `--matcher Skill`，所以 handler 侧只认 `Skill` 一个名字。这张表本质是“各宿主里加载 skill 的那个工具叫什么”。
5. Codex 的 SessionStart / SubagentStart 带 `additionalContextLimit: 0`：注释说 Codex 默认只保留超长 additionalContext 的头尾，团队规则会被截断，0 表示关闭截断。

### 2.4 `getDispatchCommand()`：最常见的那条命令

`src/builtin-hooks.ts:215`：

```ts
export function getDispatchCommand(event: string, tool: string, matcher?: string, binPath?: string): string {
  const bin = binPath ?? 'teamai';
  const matcherArg = matcher && matcher !== '*' ? ` --matcher ${matcher}` : '';
  const shell = isCodexTool(tool) ? 'bash' : getHookShellCommand();
  return `${shell} -lc "${bin} hook-dispatch ${event} --tool ${tool}${matcherArg} 2>/dev/null" || true`;
}
```

以 Claude 的 Stop 为例，渲染结果是：

```bash
bash -lc "teamai hook-dispatch stop --tool claude 2>/dev/null" || true
```

三个细节：

- `bash -lc`：登录 shell，保证能读到用户 PATH 里的 `teamai`。Windows 上 `getHookShellCommand()` 换成 Git Bash 的绝对路径，避免落到 WSL 启动器（`src/builtin-hooks.ts:186` 注释）。
- `2>/dev/null`：stderr 丢弃，宿主看不到 teamai 的日志。
- `|| true`：fail-open。teamai 出任何错，宿主都看到退出码 0，不会因此阻塞会话。这一点对知识沉淀很重要：沉淀是锦上添花，绝不能让 agent 停摆。

---

## 3. 第二层：命令被触发后，谁决定跑哪些 handler

### 3.1 `HandlerRegistration`：注册表的一行长什么样

`src/hook-handlers.ts:26`：

```ts
export interface HandlerRegistration {
  event: string;
  matcher: string;
  handler: HookHandler;
  timeoutMs: number;
  /** Fire-and-forget: run detached so it can't delay host hook completion. */
  background?: boolean;
  /** Git-provider-only handler. ... (contribute / import-from-mr / votes push). */
  gitOnly?: boolean;
  /** Team handler: it only makes sense where teamai is set up. ... (#748). */
  requiresConfig?: boolean;
}
```

| 字段 | 含义 | 对知识沉淀的影响 |
| --- | --- | --- |
| `event` / `matcher` | 和命令里的 `dispatchEvent` / `--matcher` 对上才会跑 | 决定“在会话的哪个时刻”介入 |
| `timeoutMs` | handler 自己的预算（毫秒），超时即放弃 | 前台统一 4.5 秒；pull 120 秒；LLM 判票 45 秒 |
| `background` | 放进脱离宿主的子进程跑，输出不回给宿主 | 只能做副作用，不能往会话里塞提示 |
| `gitOnly` | 团队源是 HTTP 时整行去掉 | contribute / mr-hint / votes 都依赖 git 仓库写入 |
| `requiresConfig` | 当前目录解析不到 teamai 配置时整行去掉 | 没加入团队的项目不出现任何团队提示 |

路由规则：怎么知道一次 hook 跑了哪些 handler。dispatcher 只做精确匹配（`src/hook-dispatch.ts:160`）：

```ts
const matchedFor = (event: string, matcher: string) =>
  config.handlers.filter((reg) => reg.event === event && reg.matcher === matcher);
```

所以把两张表用 `dispatchEvent` + `matcher` 对起来即可：`BUILTIN_HOOK_SPECS` 的一行 → 渲染成 `hook-dispatch <dispatchEvent> [--matcher X]`（不带 `--matcher` 即 `*`）→ 注册表里 `event`、`matcher` 都相等的所有行。`*` 不是“匹配一切”，带 `--matcher Skill` 的派发不会跑 `*` 的行（注释：通配那条 hook 会单独派发一次）。匹配之后再按 3.3 的两道闸门和 3.4 的前/后台 mode 过滤。

### 3.2 两套超时常量

`src/hook-handlers.ts:68` 起，几个和沉淀相关的预算：

```ts
const FOREGROUND_HOOK_TIMEOUT_MS = 4_500;
const TODOWRITE_HINT_TIMEOUT_MS = 2_500;
const UPDATE_TIMEOUT_MS = 10_000;
const LOCAL_AGENT_TIMEOUT_MS = 15_000;
const VOTES_JUDGE_TIMEOUT_MS = 45_000;
export const PULL_TIMEOUT_MS = 120_000;
```

注释给出的理由（`src/hook-handlers.ts:51` 起）：

- 前台 4.5 秒：CodeBuddy 不管配置里声明多少秒，约 10 秒就杀 hook。同一事件的前台 handler 是并发跑的，整个前台阶段约等于“最长的那个 handler + Node 启动/退出”，统一压在 5 秒以内才有余量。前台里被截断的网络副作用（比如投票增量推送）由后续的后台阶段或下一次 Stop 补上。
- pull 120 秒：后台 handler 的超时“不是建议值”——派发结束后进程会 `process.exit(0)`，还在跑的 git 子进程会被腰斩。冷启动的 pull 实测 10~25 秒，原先共用的 15 秒会把 pull 悄悄截断（`src/hook-handlers.ts:91` 注释）。
- 判票 45 秒：LLM 判票调用本地 CLI 本身上限 30 秒，再留出解析、写票、同步的时间（`src/hook-handlers.ts:83` 注释）。

### 3.3 `filterHandlersForConfig()`：两道闸门

`src/hook-handlers.ts:1234`：

```ts
export function filterHandlersForConfig(
  registry: HandlerRegistration[],
  localConfig: LocalConfig | null,
): HandlerRegistration[] {
  if (!localConfig) {
    return registry.filter((reg) => reg.requiresConfig !== true);
  }
  if (localConfig.repo.kind === 'http') {
    return registry.filter((reg) => reg.gitOnly !== true);
  }
  return registry;
}
```

- 没配置 → 去掉所有 `requiresConfig`。注释解释：即使是项目级安装，hook 也写在 HOME 下，所以本机每个项目都会触发；没装 teamai 的目录必须看不到团队提示（#748）。配置文件解析失败也会读成 null，于是同样不提示，由 `teamai doctor` 报告。
- HTTP 源 → 去掉所有 `gitOnly`。注释特意强调：判断依据是 teamai 自己配置的源，而不是当前工作目录的 git remote；这也不是安全闸门，HTTP 下的写操作在执行时还会被 `assertNotReadOnly()` 拦住。
- git 源（`kind === 'git'` 或未填写，向后兼容）→ 全部保留。

### 3.4 `hookDispatchCli()`：进程级编排（简述）

完整走读见 [../hook-dispatcher.md](../hook-dispatcher.md)，这里只摘和本篇有关的几行（`src/hook-dispatch-cli.ts:416`）：

```ts
export async function hookDispatchCli(
  event: string, tool: string, matcher: string,
  options: { bgOnly?: boolean; copilotGlobal?: string; stdinFile?: string; hookArgs?: string[] } = {},
): Promise<void> {
  const { bgOnly = false, stdinFile } = options;
  setStderrOnly(true);
  // ...
    const stdin = parseStdin(raw, event);
    // ...
    const localConfig = await resolveHookConfig(stdin, tool);
    // ... Copilot 去重
    const handlers = filterHandlersForConfig(buildHandlerRegistry(), localConfig);
    const dispatcher = createDispatcher({ handlers, localConfig });

    if (bgOnly) {
      await runDispatch(dispatcher, event, matcher, stdin, tool, 'background');
      return;
    }
    let settling: Promise<void> | undefined;
    if (dispatcher.hasBackground(event, matcher)) {
      if (typeof stdin.session_id !== 'string' || !stdin.session_id) {
        stdin.session_id = deriveDispatchSessionId(stdin, tool);
      }
      settling = spawnBackground(event, tool, matcher, JSON.stringify(stdin), cwd);
    }
    const output = await runDispatch(dispatcher, event, matcher, stdin, tool, 'foreground');
    if (output) {
      await new Promise<void>((resolve) => process.stdout.write(output, () => resolve()));
    }
    await settling;
  // ...
}
```

对知识沉淀来说要记住三点：

1. 配置按 hook payload 里的 `cwd` 解析（`resolveHookConfig`），不是按 teamai 进程启动时的目录——所以“这个项目属于哪个团队”由会话所在目录决定。
2. 后台子进程先启动、前台后跑；后台是同一个命令加 `--bg-only` 重新执行，只跑 `background: true` 的行。
3. 宿主没给 `session_id` 时，父进程先补一个再传给子进程，保证前后台两边算出同一个会话 id（注释：否则会按 PID 生成不同 id，同一条提示可能被领取两次）。会话 id 一致是后面“摩擦状态文件”“投票账本”能对上的前提。

前台和后台的区别，一句话：宿主等不等它。

```
宿主触发 Stop
  │
  ▼
teamai 父进程 ──────────────────────────────┐ 宿主在等这段
  ├─ spawn 子进程(--bg-only) ──▶ [脱离] update / dashboard / webhook ...（宿主不管）
  ├─ 跑前台：votes-sync、contribute-check   │
  └─ 写 STDOUT（"要不要沉淀心得？"）          │
  ▼                                          ┘
宿主拿到输出，注入会话，继续
```

| | 前台 | 后台 |
| --- | --- | --- |
| 跑在哪 | 宿主正在等的那个 teamai 进程 | 脱离宿主的子进程（同一命令加 `--bg-only`） |
| 宿主等不等 | 等，耗时计入宿主 hook 超时 | 不等 |
| 输出 | 合并后写 STDOUT，被宿主注入会话 | 没人接收，丢弃 |
| 超时 | 一般 4.5 秒 | 可以很长（pull 120 秒） |
| 适合 | 要对 agent“说话”的：注入规则、沉淀提示 | 纯副作用、可能很慢的：git 拉取、npm 检查、上报 |

- 分拣在 `createDispatcher().dispatch` 里按 mode 过滤：`foreground` 取 `background !== true` 的行，`background` 取 `background === true` 的行（`src/hook-dispatch.ts:172`）。
- `await settling` 只等子进程“启动完成”，不等它跑完。
- 拆成两类的两个理由（`src/hook-dispatch-cli.ts:7` 文件头注释）：一是慢网络不能拖住宿主（CodeBuddy 约 10 秒强杀）；二是主进程结束会 `process.exit(0)`，进程内未等待的异步任务会被杀，放进脱离的子进程才能跑完。
- 推论：后台 handler 没法对 agent 说话。要提示就得“后台暂存、前台补发”，pull 就是这么做的（见 4.2）。

---

## 4. 第三层：和知识沉淀相关的 9 个 handler

### 4.1 先看全局：它们挂在哪

从 `buildHandlerRegistry()`（`src/hook-handlers.ts:1130`）里挑出与沉淀相关的行（其余如 update、webhook、local-agent、package-hint 省略）：

```ts
// ─── SessionStart ─────────────────────────────────
{ event: 'session-start', matcher: '*', handler: pullHandler, timeoutMs: PULL_TIMEOUT_MS, background: true },
{ event: 'session-start', matcher: '*', handler: dashboardReportHandler, timeoutMs: FOREGROUND_HOOK_TIMEOUT_MS, requiresConfig: true },
{ event: 'session-start', matcher: '*', handler: teamRulesHandler, timeoutMs: FOREGROUND_HOOK_TIMEOUT_MS, requiresConfig: true },
{ event: 'session-start', matcher: '*', handler: mrHintHandler, timeoutMs: FOREGROUND_HOOK_TIMEOUT_MS, gitOnly: true, requiresConfig: true },
// ...
{ event: 'session-end', matcher: '*', handler: dashboardReportHandler, timeoutMs: FOREGROUND_HOOK_TIMEOUT_MS, background: true, requiresConfig: true },
{ event: 'session-end', matcher: '*', handler: votesSyncHandler, timeoutMs: FOREGROUND_HOOK_TIMEOUT_MS, gitOnly: true, requiresConfig: true },
// ─── Stop ─────────────────────────────────────────
{ event: 'stop', matcher: '*', handler: votesSyncHandler, timeoutMs: FOREGROUND_HOOK_TIMEOUT_MS, gitOnly: true, requiresConfig: true },
{ event: 'stop', matcher: '*', handler: votesJudgeHandler, timeoutMs: VOTES_JUDGE_TIMEOUT_MS, background: true, gitOnly: true, requiresConfig: true },
{ event: 'stop', matcher: '*', handler: contributeCheckHandler, timeoutMs: FOREGROUND_HOOK_TIMEOUT_MS, gitOnly: true, requiresConfig: true },
{ event: 'stop', matcher: '*', handler: dashboardReportHandler, timeoutMs: FOREGROUND_HOOK_TIMEOUT_MS, background: true, requiresConfig: true },
// ─── SubagentStart / SubagentStop ─────────────────
{ event: 'subagent-start', matcher: '*', handler: teamRulesHandler, timeoutMs: FOREGROUND_HOOK_TIMEOUT_MS, requiresConfig: true },
{ event: 'subagent-stop', matcher: '*', handler: votesSyncHandler, timeoutMs: FOREGROUND_HOOK_TIMEOUT_MS, gitOnly: true, requiresConfig: true },
// ─── PostToolUse ──────────────────────────────────
{ event: 'post-tool-use', matcher: '*', handler: dashboardReportHandler, timeoutMs: FOREGROUND_HOOK_TIMEOUT_MS, requiresConfig: true },
{ event: 'post-tool-use', matcher: '*', handler: recallAttributionHandler, timeoutMs: FOREGROUND_HOOK_TIMEOUT_MS, requiresConfig: true },
// ─── UserPromptSubmit ─────────────────────────────
{ event: 'prompt-submit', matcher: '*', handler: pendingHintHandler, timeoutMs: FOREGROUND_HOOK_TIMEOUT_MS, gitOnly: true, requiresConfig: true },
{ event: 'prompt-submit', matcher: '*', handler: dashboardReportHandler, timeoutMs: FOREGROUND_HOOK_TIMEOUT_MS, requiresConfig: true },
```

汇总成表（前台 = 结果会被合并写回宿主；后台 = `--bg-only` 子进程）：

| handler（name） | 事件 | 前/后台 | gitOnly | requiresConfig | 超时 | 详见 |
| --- | --- | --- | --- | --- | --- | --- |
| pullHandler（pull） | session-start | 后台 | - | - | 120s | 第 5 篇 |
| teamRulesHandler（team-rules） | session-start、subagent-start | 前台 | - | 是 | 4.5s | 第 5 篇 |
| mrHintHandler（mr-hint） | session-start | 前台 | 是 | 是 | 4.5s | 第 8 篇 |
| dashboardReportHandler（dashboard-report） | session-start、post-tool-use、prompt-submit 前台；stop、session-end 后台 | 混合 | - | 是 | 4.5s | 第 2 篇 |
| recallAttributionHandler（recall-attribution） | post-tool-use | 前台 | - | 是 | 4.5s | 第 6、7 篇 |
| contributeCheckHandler（contribute-check） | stop | 前台 | 是 | 是 | 4.5s | 第 2 篇 |
| pendingHintHandler（pending-hint） | prompt-submit | 前台 | 是 | 是 | 4.5s | 第 2 篇 |
| votesSyncHandler（votes-sync） | stop、subagent-stop、session-end | 前台 | 是 | 是 | 4.5s | 第 7 篇 |
| votesJudgeHandler（votes-judge） | stop | 后台 | 是 | 是 | 45s | 第 7 篇 |

为什么这样分前后台，Stop 段的注释说得最直白（`src/hook-handlers.ts:1159`）：votes-sync 和 contribute-check 可能返回一条要注入回会话的提示，所以前台跑；其余是纯副作用，放后台，免得把 Stop hook 拖过宿主超时。

下面每个 handler 只讲“run 函数（`execute`）做了什么”，细节留给后续篇章。

### 4.2 pullHandler：会话开始，把团队知识拉到本机

`src/hook-handlers.ts:113`：

```ts
const pullHandler: HookHandler = {
  name: 'pull',
  async execute(stdin, tool, config) {
    const cwd = resolveHookCwd(stdin);
    if (!config && (cwd === undefined || await pathExists(cwd))) {
      const { findUnreadableProjectConfig } = await import('./config.js');
      if (await findUnreadableProjectConfig(cwd) !== null) return null;
    }
    if (config) {
      const { isAgentExcluded } = await import('./types.js');
      if (isAgentExcluded(config, tool)) return null;
    }
    // ... 记录 pull 前的包清单哈希
    try {
      const { seedProjectAgentRoot } = await import('./project-agent-root.js');
      await seedProjectAgentRoot(tool, cwd);
    } catch (e) { /* log.debug */ }
    const { pull } = await import('./pull.js');
    await pull({ silent: true });
    // ... stashPackageHintAfterPull(...)
    return null;
  },
};
```

- 做什么：静默执行一次 `teamai pull`，把团队的 skills / rules / docs / learnings 同步到本机，后续 recall 才查得到最新知识。
- 两个提前退出：项目配置存在但读不出来时不拉（注释：否则可能拉到别的团队的东西，#784）；该工具被 `uninstall --agent` 排除时不拉（否则会把卸掉的东西装回来，#993）。
- 为什么后台：它不返回任何要注入的内容（`return null`），而 git fetch 在慢网络下可能很久，不能拖住会话启动。
- 为什么没有 `requiresConfig`：注释说明“没解析到配置”有两种情况，只有“配置不可读”才该停；未配置时交给 `pull()` 自己处理。测试 `filterHandlersForConfig drops gitOnly handlers for http source` 也断言 HTTP 团队仍保留 `pull`。
- 完整步骤：① 两道安全检查 → ② 记下 pull 前 package 清单的哈希 → ③ `seedProjectAgentRoot` 确保项目里有该工具的目录（失败只打 debug 日志）→ ④ `pull({ silent: true })` → ⑤ `stashPackageHintAfterPull` 对比哈希，有变化就暂存一条提示。
- 后台暂存、前台补发：pull 在后台，输出没人接收，所以第 ⑤ 步只把提示存起来，等用户下一次提问时由 prompt-submit 上的 `packagePendingHintHandler`（前台）发出去。
- 超时 `PULL_TIMEOUT_MS = 120s`：到点进程即被结束，没跑完的同步阶段直接丢弃，所以必须给足。
- 详见第 5 篇 [05-pull-distribution.md](./05-pull-distribution.md)。

### 4.3 teamRulesHandler：把团队规则注入会话上下文

`src/hook-handlers.ts:940`：

```ts
const teamRulesHandler: HookHandler = {
  name: 'team-rules',
  async execute(stdin, tool, config) {
    if (!config || config.scope !== 'project' || stdin.source === 'resume') return null;
    const { getsRulesFromSessionHook } = await import('./resources/rule-format.js');
    const { isAgentExcluded } = await import('./types.js');
    if (!getsRulesFromSessionHook(tool) || isAgentExcluded(config, tool)) return null;
    // ... loadTeamConfig
    const text = deliversInstructionsByHook(tool, config.scope) ? await instructionHookTextFor(teamConfig, config, tool) : '';
    const parts = text ? [text] : [];
    const rules = await teamRulesContext(teamConfig, config);
    if (rules !== null) parts.push(rules);
    if (parts.length === 0) return null;
    const hookEventName = stdin.hook_event_name === 'SubagentStart' ? 'SubagentStart' : 'SessionStart';
    return JSON.stringify({ hookSpecificOutput: { hookEventName, additionalContext: parts.join('\n\n') } });
  },
};
```

- 做什么：对“没有自己的规则文件格式”的工具（注释列举 Codex 家族、ZCode、DeepSeek Harness），把项目规则和指令块（含 recall 指令）通过 `additionalContext` 塞进会话。这是“已沉淀的正式知识”到达 agent 的一条通道。
- 为什么前台：它的产出就是要注入会话的文字，必须等结果。
- 边界：只处理 `scope === 'project'`；会话是 `resume` 时跳过（历史里已经有了）；`hookEventName` 必须和实际事件一致，否则 Codex 拒收（注释）。
- 易错点：它不是给所有工具注入规则。白名单是 `getsRulesFromSessionHook`（`src/resources/rule-format.ts:201`，Codex 家族、ZCode、DeepSeek Harness、Muse Code），其余工具它直接 `return null`。团队规则有两条送达路径：
  - 有自己规则格式的工具（Claude、Cursor 等）：pull 时写成规则文件，工具自己读。
  - 没有规则格式的工具：pull 不写规则文件，只能靠这个 handler 在 SessionStart（Codex 子 agent 是 SubagentStart）用 `additionalContext` 注入。
- 其他细节：非项目 scope 跳过，因为用户级内容已在工具自己的 AGENTS.md 里；Codex 压缩上下文或 clear 后会重新触发 SessionStart，届时重新注入。
- 推论（未运行验证）：它和后台 pull 同时挂在 session-start，注入的是本机现有规则；pull 新拉到的规则要到下一次会话才生效。
- 详见第 5 篇。

### 4.4 mrHintHandler：提示“有新合入的 MR 可以提炼”

`src/hook-handlers.ts:867`：

```ts
const mrHintHandler: HookHandler = {
  name: 'mr-hint',
  async execute(_stdin, _tool, config) {
    const { computeMrHintOutput } = await import('./mr-hint.js');
    return computeMrHintOutput(await teamAgentLanguage(config), config);
  },
};
```

`computeMrHintOutput` 的注释（`src/mr-hint.ts:447`）：检测仓库、查询已合入 MR、更新缓存、生成 SessionStart 的 `hookSpecificOutput`；没有可提示的或开关关闭时返回 null；它不读 STDIN，所以能被调度器复用。它开头还会检查 `TEAMAI_MR_HINT_DISABLED=1` 和 `mrHintAllowed()`。

- 为什么前台：产出是注入会话的提示。
- 为什么 `gitOnly`：MR 提炼依赖 git 托管平台，HTTP 团队不该看到（测试 `marks contribute-check, mr-hint, and votes-sync as gitOnly`）。
- 详见第 8 篇 [08-teamwiki-code-knowledge.md](./08-teamwiki-code-knowledge.md)（`teamai import --from-mr`）。

### 4.5 dashboardReportHandler：记录会话事件（摩擦检测的原料）

`src/hook-handlers.ts:326`：

```ts
const dashboardReportHandler: HookHandler = {
  name: 'dashboard-report',
  async execute(stdin, tool, config) {
    if (!config) return null;
    const { parseHookEvent, appendEvent, compactEvents, dataHomeKey, eventProjectAnchor, addGitStateAtStart } = await import('./dashboard-collector.js');
    const { getDataHome } = await import('./types.js');
    const raw = JSON.stringify(stdin);
    const event = await parseHookEvent(raw, tool, {
      correctionKeywords: await teamCorrectionKeywords(stdin, config),
      modelAliases: await userModelAliases(stdin),
    });
    if (event) {
      event.dataHomeKey = await dataHomeKey(getDataHome(config));
      // ... projectAnchor / addGitStateAtStart
      await appendEvent(event);
      compactEvents().catch(() => {});
    }
    return null;
  },
};
```

- 做什么：把每个 hook 事件解析成一条会话事件追加到本地事件日志。解析时带上团队的“纠正关键词”（`teamCorrectionKeywords`），这正是第 2 篇摩擦检测里 `correction` 信号的来源之一；总览笔记提到的“Stop 事件的 interventions 快照”也出自这条链路（后者未在本篇逐行核实）。
- 前台还是后台：同一个 handler 注册了 5 次。session-start、post-tool-use、prompt-submit 上是前台（只是一次本地追加，很快）；stop、session-end 上是后台。它永远 `return null`，所以前台也不会往会话里写东西。
- 一个值得注意的顺序关系：Stop 上 dashboard-report 在后台跑，contribute-check 在前台跑，二者并不保证先后。这就是为什么 contribute-check 优先实时扫 transcript、扫不到再退回事件快照（见第 2 篇）。
- 详见第 2 篇 [02-friction-detection.md](./02-friction-detection.md)。

### 4.6 recallAttributionHandler：记下“agent 读了哪条知识”

`src/hook-handlers.ts:391`：

```ts
const recallAttributionHandler: HookHandler = {
  name: 'recall-attribution',
  async execute(stdin, tool, config) {
    if (process.env.TEAMAI_RECALL_DISABLED === '1' || !config) return null;
    const { recordToolCall } = await import('./recall-adoption.js');
    await recordToolCall(stdin, tool, config);
    return null;
  },
};
```

- 做什么：每次工具调用之后，把“一次 recall 的声明”或“读了一份团队知识文件”记进 recall 日志，供 Stop / SubagentStop / SessionEnd 上的 votes-sync 做归约（注释，#884）。
- 为什么前台却很快：注释强调每次调用只写一次、从不读日志或文件，所以能稳稳待在 4.5 秒预算里。
- 为什么没有 `gitOnly`：它只写本地日志，不推送；推送投票的 votes-sync 才是 `gitOnly`。
- 开关：`TEAMAI_RECALL_DISABLED=1` 时直接跳过。
- 详见第 6 篇 [06-recall-search.md](./06-recall-search.md) 和第 7 篇 [07-feedback-governance.md](./07-feedback-governance.md)。

### 4.7 contributeCheckHandler：一轮结束，判断要不要提示“沉淀一下”

`src/hook-handlers.ts:464`：

```ts
const contributeCheckHandler: HookHandler = {
  name: 'contribute-check',
  async execute(stdin, tool) {
    const { contributeHintAllowed } = await import('./skill-content.js');
    const { hookScopeDir } = await import('./dashboard-collector.js');
    if (!(await contributeHintAllowed(await hookScopeDir(stdin, tool)))) return null;

    const { contributeCheckForSession } = await import('./contribute-check.js');
    const { formatStopHookOutput, relayWhenHidden } = await import('./utils/hook-output.js');
    const { stopStdoutUnsupported } = await import('./utils/tool-names.js');

    const sessionId = deriveSessionId(stdin, { includeCwd: true });
    const cwd = resolveHookCwd(stdin);
    const transcriptPath = typeof stdin.transcript_path === 'string' ? stdin.transcript_path : undefined;
    const stash = stopStdoutUnsupported(tool);
    const { hint } = await contributeCheckForSession(sessionId, cwd, transcriptPath, stash);
    if (!hint) return null;
    return formatStopHookOutput(relayWhenHidden(hint, tool), tool);
  },
};
```

逐段看：

1. 闸门 `contributeHintAllowed(hookScopeDir(...))`：用 payload 的 cwd（而非进程目录）判断团队/成员是否允许这个提示。测试覆盖了多种静默情形：团队关掉提示、recall 关闭、HTTP 只读源、无配置、项目配置不可读、`TEAMAI_CONTRIBUTE_HINT_DISABLED=1`。
2. `sessionId` 用 `deriveSessionId(stdin, { includeCwd: true })`，注释说和 dashboard-collector 的推导方式一致，这样事件和沉淀状态共享同一个会话 id。
3. `transcript_path` 传下去，让摩擦检测能实时读会话记录（测试 `contribute-check handler forwards transcript_path so friction is read live`）。
4. `stash`：有些工具的 Stop hook 无法把内容送给模型。`stopStdoutUnsupported(tool)` 对不在 `STOP_STDOUT_TOOLS`（`src/utils/tool-names.ts:72`，含 claude、cursor、copilot、qoder、zcode、omp、pi、opencode、dsh 等）里的工具返回 true，此时提示被暂存，本次返回 null，下一次用户提问时由 pendingHintHandler 补发。
5. 有提示时用 `formatStopHookOutput` 包成宿主认识的格式；`relayWhenHidden` 处理“宿主不显示 payload，需要模型转述”的情况（注释：Claude Code 自己会打印，不要让它转述，#719）。

- 为什么前台：提示要回到会话里。
- 为什么 `gitOnly`：后续的 `teamai contribute` 要写入团队仓库的 learnings 分支。
- 详见第 2 篇（打分与阈值）、第 3 篇 [03-share-skill.md](./03-share-skill.md)（提示之后 agent 怎么写文档）。

### 4.8 pendingHintHandler：替 Stop 发不出去的工具补发提示

`src/hook-handlers.ts:496`：

```ts
const pendingHintHandler: HookHandler = {
  name: 'pending-hint',
  async execute(stdin, tool) {
    const { stopStdoutUnsupported } = await import('./utils/tool-names.js');
    if (!stopStdoutUnsupported(tool)) return null;
    const sessionId = deriveSessionId(stdin, { includeCwd: true });
    const pending = await import('./contribute-check.js');
    const stashed = await pending.takePendingHint(sessionId);
    const { contributeHintAllowed } = await import('./skill-content.js');
    const { hookScopeDir } = await import('./dashboard-collector.js');
    const hint = (await contributeHintAllowed(await hookScopeDir(stdin, tool))) ? stashed : null;
    if (!hint) return null;
    return JSON.stringify({
      hookSpecificOutput: { hookEventName: 'UserPromptSubmit', additionalContext: hint },
    });
  },
};
```

- 做什么：只对 Stop 发不出内容的工具生效；取出（并消费）暂存的提示，以 `additionalContext` 注入到用户的下一轮提问里。
- 关键细节：先 `takePendingHint` 再判断开关——“总是消费”，避免团队关掉功能时暂存的提示，在重新打开后才冒出来（注释；测试 `pending-hint handler drops (consumes but hides) a stashed hint when the team turned the hint off`）。
- 坑：跨进程交接依赖宿主在 Stop 和下一次 UserPromptSubmit 里带同一个 `session_id`。注释说已用 codebuddy / workbuddy 真实数据验证过；若宿主不带，退回 pid+cwd，两次 hook 进程可能算出不同 id，暂存就成了孤儿（尽力而为）。
- 详见第 2 篇。

### 4.9 votesSyncHandler：给“读过且用上”的知识记赞成票并推送

`src/hook-handlers.ts:549`（节选）：

```ts
const votesSyncHandler: HookHandler = {
  name: 'votes-sync',
  async execute(stdin, tool, localConfig) {
    if (process.env.TEAMAI_RECALL_DISABLED === '1' || !localConfig) return null;
    try {
      // ...
      const votePath = path.join(votesDir, `${localConfig.username}.yaml`);
      const sessionId = deriveDispatchSessionId(stdin, tool);
      const { credited, recalled } = await creditAdoptedDocs(localConfig, sessionId);
      const adoptedDocIds = credited ?? [];
      const hookEvent = typeof stdin.hook_event_name === 'string' ? stdin.hook_event_name.toLowerCase() : '';
      const subagentStop = hookEvent === 'subagentstop';
      const sessionEnd = hookEvent === 'sessionend';
      if (!subagentStop) await pruneUpvoteLedger(votePath).catch(() => undefined);
      if (subagentStop) {
        // Nothing to push now
      } else if (usesBranchWorktree(localConfig)) {
        // ... hasPendingVoteDeltas → updateReports(...) 推到 teamai-reports 分支
      } else {
        await syncVotesToTeam(localConfig.repo.localPath, localConfig.username, votesDir).catch(() => {});
      }
      // ... TEAMAI_ADOPTION_EVAL_LOG 可选测量日志
      if (adoptedDocIds.length > 0 && !subagentStop && !sessionEnd) {
        // 仅对能显示 Stop payload 的工具输出 "[teamai] Adopted team knowledge this session: ..."
      }
    } catch (error) {
      log.debug(`votes-sync handler failed: ...`);
    }
    return null;
  },
};
```

- 做什么：用 4.6 记下的 recall 日志做归约——本会话打开了某次 recall 返回的文档、且在该次 recall 后 24 小时内，就算“采纳”，给它记一票（注释，#884）。投票文件是 `<votesDir>/<username>.yaml`。
- 三个事件三种行为：Stop 上记账 + 推送 + 可能输出“本轮采纳了哪些知识”；SubagentStop 上只在本地记账，不推送（主 agent 在等这个 hook，git 往返留给下一次 Stop 或 pull）；SessionEnd（Copilot）上推送但不输出摘要（没人看）。
- 去重：Stop 每轮都触发，`incrementUpvoted` 内的“每会话账本”保证一篇文档只记一次。
- 存储：用 branch worktree 的团队，投票作为报告数据推到 `teamai-reports` 孤儿分支（经隔离 worktree，不碰默认分支）；否则走 `syncVotesToTeam`。推送失败时增量保留，下次重试（#1027）。
- 为什么前台：它可能返回给用户看的“采纳摘要”。为了不超 4.5 秒，没有待推增量时连 fetch 都跳过。
- 详见第 7 篇。

### 4.10 votesJudgeHandler：可选的后台 LLM 判票

`src/hook-handlers.ts:702`（节选）：

```ts
const votesJudgeHandler: HookHandler = {
  name: 'votes-judge',
  async execute(stdin, _tool, localConfig) {
    if (process.env.TEAMAI_RECALL_DISABLED === '1' || !localConfig) return null;
    if (process.env.TEAMAI_UPVOTE_JUDGE !== '1') return null;
    const transcriptPath = typeof stdin.transcript_path === 'string' ? stdin.transcript_path : null;
    if (!transcriptPath) return null;
    // ...
    const voteData = await parseTranscriptForVotes(transcriptPath);
    if (voteData.recalledDocIds.length === 0) return null;
    // ... 先跑一遍 creditAdoptedDocs，再排除账本里已记票的文档
    const toJudge = voteData.recalledDocIds.filter(
      (id) => scopeEligible.has(id) && !ledgerCredited.has(keyOf(id)),
    );
    if (toJudge.length === 0) return null;
    // ... knowledgeRoots 限定可读的知识根
    const adopted = await judgeAdoption(voteData.finalAssistantText, toJudge, docPaths, roots);
    // ... incrementUpvoted(votePath, ..., sessionId) 后同步
  },
};
```

- 解决的问题（注释）：推荐的 recall 路径是子 agent 把摘要以文字注入主会话，主 agent 常常“用了却没打开文件”，4.9 的工具证据抓不到。判票器问本机已登录的 CLI：最新回复有没有实质使用某篇召回文档。
- 为什么后台：要调本地 LLM CLI（上限 30 秒），绝不能拖住 Stop；`VOTES_JUDGE_TIMEOUT_MS = 45_000`。
- 默认关闭：仅 `TEAMAI_UPVOTE_JUDGE=1` 时启用。
- 不重复计票：和前台共用同一个每会话账本；它甚至先跑一遍 `creditAdoptedDocs`，因为后台进程比前台的 votes-sync 先启动。
- 安全：读文档摘录时限定在可信知识根内，防止伪造的 transcript 让它读任意本地文件（#723 review）。
- 详见第 7 篇。

---

## 5. 端到端流程图：一次会话里 hook 层做了什么

```text
AI 工具会话（以 Claude Code 为例）
│
├─ SessionStart ─> bash -lc "teamai hook-dispatch session-start --tool claude ..." || true
│     hookDispatchCli: 读 STDIN → resolveHookConfig(cwd) → filterHandlersForConfig
│     ├─ [后台 --bg-only] pull ............ 同步 skills/rules/docs/learnings   (第 5 篇)
│     └─ [前台] dashboard-report ........ 追加会话事件                       (第 2 篇)
│              team-rules ............. 注入项目规则（Codex/ZCode 等）       (第 5 篇)
│              mr-hint (gitOnly) ...... 提示可提炼的已合入 MR                (第 8 篇)
│
├─ 每次工具调用后 PostToolUse
│     └─ [前台] dashboard-report / recall-attribution（写 recall 日志）     (第 6/7 篇)
│
├─ 子 agent 结束 SubagentStop（仅白名单工具）
│     └─ [前台] votes-sync：只在本地记账，不推送                           (第 7 篇)
│
├─ 一轮结束 Stop
│     ├─ [后台] votes-judge（TEAMAI_UPVOTE_JUDGE=1）、dashboard-report
│     └─ [前台] votes-sync ─> 记票 + 推送 + "Adopted team knowledge ..."
│              contribute-check ─> 摩擦打分 ─┬─ 能显示 Stop 输出：直接返回提示   (第 2 篇)
│                                            └─ 不能：暂存到会话状态
│                                                        │
├─ 下一次提问 UserPromptSubmit                           ▼
│     └─ [前台] pending-hint：取出暂存提示，作为 additionalContext 注入
│                    │
│                    ▼
│            agent 按 share skill 写文档 (第 3 篇) → teamai contribute (第 4 篇)
│
└─ SessionEnd（仅 Copilot）
      ├─ [前台] votes-sync：推送，不输出摘要
      └─ [后台] dashboard-report
```

---

## 6. 常见坑与边界情况

| 现象 | 原因（出处） |
| --- | --- |
| 在没加入团队的项目里看不到任何沉淀提示 | `requiresConfig` 闸门，hook 装在 HOME 下会在每个项目触发（#748，`filterHandlersForConfig` 注释） |
| 配置文件写坏了，提示全没了 | 解析失败读作 null，同样走无配置分支；用 `teamai doctor` 排查（同上注释） |
| HTTP 团队没有沉淀提示、不投票 | contribute-check / mr-hint / votes-sync / votes-judge / pending-hint 都是 `gitOnly`（测试 `filterHandlersForConfig drops gitOnly handlers for http source`） |
| CodeBuddy / WorkBuddy 的沉淀提示在下一轮才出现 | Stop 输出送不到模型，先暂存再由 pending-hint 补发（`stopStdoutUnsupported`） |
| 暂存提示丢失 | 宿主两次 hook 没带同一个 `session_id`，回退 pid+cwd 导致 id 不一致（`pendingHintHandler` 注释） |
| 冷启动 pull 只同步了一半 | 后台超时会被 `process.exit(0)` 腰斩，所以 pull 单独给 120 秒（`PULL_TIMEOUT_MS` 注释） |
| Cursor / Copilot 的子 agent 读的知识没被算票 | 它们的子 agent 跑在独立会话，没有 SubagentStop（测试 `adds SubagentStop only for the agents that fire it (#884)`） |
| 子 agent 看过的知识只在本地有票 | SubagentStop 只记账不推送，等下一次 Stop 或 pull（`votesSyncHandler` 注释） |
| teamai 报错但会话完全没受影响 | 命令尾部 `|| true` / `; exit 0` fail-open，stderr 也被丢弃 |

---

## 7. 动手验证

只读命令（在仓库根目录 `/Users/maolu/Documents/learn/teamai-cli` 下执行）：

```bash
# 看本机 Claude Code 装了哪些 teamai hook
grep -n "hook-dispatch" ~/.claude/settings.json

# 注册表里所有沉淀相关的行
grep -nE "pullHandler|teamRulesHandler|mrHintHandler|recallAttributionHandler|contributeCheckHandler|pendingHintHandler|votesSyncHandler|votesJudgeHandler" src/hook-handlers.ts

# 哪些工具 Stop 能直接显示输出
sed -n '72,97p' src/utils/tool-names.ts
```

相关测试用例（可用 `npx vitest run <文件>` 运行，会产生临时文件但不改源码）：

- `src/__tests__/builtin-hooks.test.ts`：`returns 7 built-in defs for Claude in canonical order, all tagged source=builtin`、`adds SubagentStop only for the agents that fire it (#884)`、`adds a lifecycle-complete SessionEnd hook only for Copilot`、`Claude defs carry no timeout; Cursor and the Codex family carry per-hook timeouts (#1070)`
- `src/__tests__/hook-handlers.test.ts`：`marks contribute-check, mr-hint, and votes-sync as gitOnly`、`filterHandlersForConfig drops gitOnly handlers for http source`、`votes-judge is registered as a detached background stop handler`、`session-end records the final dashboard snapshot and dispatches the webhook in the background, and syncs votes in the foreground`、`contribute-check handler forwards transcript_path so friction is read live`、`pending-hint handler drops (consumes but hides) a stashed hint when the team turned the hint off`
- `src/__tests__/hook-dispatch.test.ts`：`foreground mode runs only non-background handlers`

---

## 8. 自测问题

<details>
<summary>1. 为什么 pullHandler 放后台，而 contributeCheckHandler 放前台？</summary>

pull 返回 null、不需要注入会话，且 git fetch 可能很慢；contribute-check 的产出是要回到会话里的提示，必须前台等结果并合并写回 stdout。
</details>

<details>
<summary>2. 一个 HTTP 源团队的成员，Stop 时还会跑哪些和沉淀相关的 handler？</summary>

`gitOnly` 的 votes-sync、votes-judge、contribute-check 都被过滤掉，只剩后台的 dashboard-report（它只有 `requiresConfig`）。
</details>

<details>
<summary>3. 为什么 Copilot 需要 SessionEnd，而 Claude 不需要？</summary>

Copilot 最后一轮可能只发 SessionEnd 不发 Stop，votes-sync 必须在这里补推投票；Claude 的每轮都有 Stop。
</details>

<details>
<summary>4. CodeBuddy 上沉淀提示是怎么到达模型的？</summary>

CodeBuddy 不在 `STOP_STDOUT_TOOLS` 里，Stop 时 contribute-check 把提示暂存并返回 null；下一次 UserPromptSubmit，pending-hint 取出并以 `additionalContext` 注入。
</details>

<details>
<summary>5. votes-judge 和 votes-sync 会不会给同一篇文档记两票？</summary>

不会。两者写同一个每会话账本，judge 只判账本里还没有的文档，且在判之前先跑一次 `creditAdoptedDocs`。
</details>

---

## 9. 未逐行核实

- `createDispatcher` 的路由与前台输出合并细节（只引用了 `hook-dispatcher.md` 的结论，本篇没有重读 `src/hook-dispatch.ts`）。
- `resolveHookConfig`、`hookScopeDir`、`contributeHintAllowed`、`deriveSessionId` / `deriveDispatchSessionId` 的内部实现。
- `contributeCheckForSession`、`takePendingHint` 的暂存位置（总览笔记说是 `~/.teamai/sessions/<id>.json`，未核实）。
- `recordToolCall` / `creditAdoptedDocs` 的 recall 日志格式与存放路径；“24 小时窗口”仅来自注释。
- `getVotesDir`、`updateReports`、`syncVotesToTeam` 的具体路径与 git 操作。
- `pull()` 内部做了什么，以及 `teamRulesContext` / `instructionHookTextFor` 的内容。
- `mr-hint.ts` 中 `computeMrHintOutput` 第 466 行之后的查询与缓存逻辑。
- `dashboard-collector.ts` 的事件日志位置，以及 Stop 事件 `interventions` 快照的生成方式。
- WorkBuddy / CodeBuddy 包装命令、ZCode 与 PowerShell 渲染在磁盘上的最终形态（只读了生成函数，没看实际配置文件）。
- 第 7 节 `grep ~/.claude/settings.json` 命令假定 Claude 的用户级配置在该路径，未在本机验证。

---

导航：上一步 [README.md（索引）](./README.md) | 下一步 [02-friction-detection.md](./02-friction-detection.md)
