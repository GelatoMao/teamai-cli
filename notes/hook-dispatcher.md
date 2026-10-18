# 统一的 Hook 调度器：一个入口，扇出所有团队能力

> 面向小白。先讲"为什么要有它"和"整体长什么样"，再沿着一次真实调用逐行看代码。
> 代码摘自本仓库 0.22.0 源码，标注 `文件:行号`；为便于阅读删减了部分注释，用 `// ...` 省略无关分支。
> 前置阅读（可选）：`notes/cross-tool-adapter-layer.md` 第 5.5 节（hook 怎么装进各工具）。本文讲的是**装进去之后，被触发时发生了什么**。

---

## 0. 一句话 + 一个类比

**一句话**：teamai 在每个 AI 工具里只注册"每个事件一条"hook 命令 `teamai hook-dispatch <event> --tool <tool>`。这条命令启动后**只读一次 STDIN**，按 `事件 + matcher` 找出所有该跑的处理器（handler），**并发执行、互相隔离、各自限时**，把多个输出**合并成一份**写回宿主；不需要返回结果的慢活儿，丢到一个**脱离宿主的后台进程**里去做。

**类比**：公司前台。

- 访客（AI 工具的事件）只找前台一个人，不用知道公司有几个部门
- 前台登记一次访客信息（读一次 STDIN），然后同时通知所有相关部门（并发 handler）
- 某个部门没人接（handler 崩溃/超时）不影响其他部门
- 需要当场答复的（前台 handler）等结果，汇总成一句话告诉访客；只需要事后处理的（后台 handler）交给后勤慢慢办，访客先走

---

## 1. 为什么需要调度器

### 1.1 旧方案：一个功能一条 hook

早期 teamai 往 settings.json 里给每个功能单独注册一条 hook。`src/hooks.ts:69` 还保留着那时的子命令清单（现在只用来做迁移清理）：

```ts
/** Legacy subcommands that are cleaned up during migration. */
export const TEAMAI_LEGACY_HOOK_SUBCOMMANDS = [
  'pull', 'update', 'track', 'track-slash', 'dashboard-report',
  'contribute-check', 'auto-recall', 'todowrite-hint', 'mr-hint',
] as const;
```

也就是说，一次 Stop 事件可能要启动好几个 `teamai xxx` 进程。问题很多：

| 问题 | 后果 |
| --- | --- |
| 每条 hook 都启动一个 Node 进程 | 启动开销 × N，会话启动、每次工具调用都变慢 |
| 每个进程各读一次 STDIN | 宿主要把同一份 payload 喂 N 次 |
| 多条 hook 各自往 stdout 写 | 宿主只认一份 JSON，提示互相覆盖或格式错乱 |
| 慢操作（git fetch、npm 查版本）阻塞宿主 | CodeBuddy 约 10 秒就强杀 hook，直接报错 |
| 每加一个功能都要改所有工具的 settings | 和"跨工具适配"的复杂度相乘 |

### 1.2 新方案：一个事件一条 hook

现在所有工具里，teamai 只装形如这样的命令（`src/builtin-hooks.ts:215` 生成）：

```bash
bash -lc "teamai hook-dispatch stop --tool claude 2>/dev/null" || true
```

`src/hooks.ts:66` 里 doctor 检查的子命令也只剩一个：

```ts
export const TEAMAI_HOOK_SUBCOMMANDS = ['hook-dispatch'] as const;
```

**加一个新功能 = 在 handler 注册表里加一行**，任何工具的配置文件都不用动。这是调度器最大的价值：把"工具适配"和"业务功能"两个维度彻底解耦。

`src/hook-dispatch.ts` 文件头的注释把设计目标写得很清楚：

```ts
/**
 * Instead of spawning N separate processes per event, Claude Code invokes
 * a single `teamai hook-dispatch <event> [--matcher <m>]` command.
 * The dispatcher reads STDIN once and fans out to all registered handlers.
 *
 * Design:
 *   - Handlers are pure functions: (stdin, tool, config) → output | null
 *   - Promise.allSettled ensures one handler crash doesn't take down others
 *   - Compatible structured outputs are merged so concurrent hints are preserved
 */
```

---

## 2. 整体架构

### 2.1 三个文件，三层职责

| 文件 | 行数 | 职责 | 类比 |
| --- | --- | --- | --- |
| `src/index.ts:1073` | — | Commander 注册隐藏命令 `hook-dispatch`，设置 7 秒硬退出保险 | 大门 |
| `src/hook-dispatch-cli.ts` | ~520 | **进程级编排**：读 STDIN、归一化、解析配置、宿主去重、前后台拆分、写 stdout | 前台 |
| `src/hook-dispatch.ts` | 238 | **纯调度内核**：路由、并发、超时、错误隔离、输出合并。不碰进程、不碰文件 | 调度规则 |
| `src/hook-handlers.ts` | ~1250 | **handler 实现 + 注册表**：哪个事件跑哪些 handler、超时多少、前台还是后台 | 各部门 |

分层的好处：`hook-dispatch.ts` 不依赖任何 IO，可以用纯单元测试覆盖（`src/__tests__/hook-dispatch.test.ts`）；进程相关的脏活全在 CLI 层。

### 2.2 一次调用的全景图

```
AI 工具（如 Claude Code）触发 Stop 事件
  │  spawn: bash -lc "teamai hook-dispatch stop --tool claude ..."
  │  STDIN: {"session_id":"..","cwd":"/repo","transcript_path":"..",...}
  ▼
┌─ index.ts ──────────────────────────────────────────────────────────┐
│  设置 7s 硬退出定时器（宿主约 10s 杀进程，必须抢在前面）              │
└───────────────┬─────────────────────────────────────────────────────┘
                ▼
┌─ hookDispatchCli()  hook-dispatch-cli.ts:416 ───────────────────────┐
│ ① setStderrOnly(true)          stdout 只留给协议 JSON                │
│ ② 宿主去重                      Cursor/Copilot 里跑到了 Claude 的 hook？跳过 │
│ ③ readStdin() ≤1s → parseStdin  容错解析 + 补事件名 + 归一化 cwd     │
│ ④ chdir(cwd) → resolveHookConfig  决定"当前属于哪个 teamai 作用域"   │
│ ⑤ Copilot 专属去重（同一事件可能被全局和项目两份配置各触发一次）      │
│ ⑥ buildHandlerRegistry() → filterHandlersForConfig()                 │
│    没配置 → 去掉 requiresConfig；HTTP 团队 → 去掉 gitOnly             │
│ ⑦ createDispatcher({ handlers, localConfig })                        │
│ ⑧ 有后台 handler？→ spawnBackground(... --bg-only)  脱离宿主的子进程 │
│ ⑨ dispatch(mode='foreground') → 合并输出 → 写 stdout                 │
│ ⑩ 等后台子进程"启动完成"（不等它跑完）→ 退出                          │
└───────────────┬───────────────────────────────┬─────────────────────┘
                ▼                               ▼
┌─ createDispatcher()  hook-dispatch.ts:159 ─┐  ┌─ 后台子进程 ──────────────────┐
│ 过滤：event 相等 && matcher 相等 && 模式匹配│  │ teamai hook-dispatch stop      │
│ Promise.allSettled(                         │  │   --tool claude --bg-only      │
│   withTimeout(handler.execute(), timeoutMs) │  │ 重走 ③-⑦，只跑 background     │
│ )                                           │  │ handler：update / dashboard /  │
│ 收集 errors（只记日志）                     │  │ webhook / votes-judge ...      │
│ mergeHookOutputs(outputs) → 一份 JSON       │  │ 输出丢弃，宿主早已返回          │
└─────────────────────────────────────────────┘  └───────────────────────────────┘
                ▼
宿主读到 stdout：{"hookSpecificOutput":{"hookEventName":"Stop","additionalContext":"..."}}
```

下面按"入口 → CLI 编排 → 调度内核 → handler 注册表"的顺序逐层看代码。

---

## 3. 入口：隐藏命令 + 硬退出保险

`src/index.ts:1073`：

```ts
program
  .command('hook-dispatch <event> [hookArgs...]', { hidden: true })   // 隐藏：给机器用，不给人用
  .description('Unified hook dispatcher — handles all teamai hooks for a given event in one process')
  .option('--tool <name>', 'Tool identifier (e.g. codebuddy, workbuddy, claude)')
  .option('--matcher <matcher>', 'Hook matcher for PostToolUse (e.g. Skill, Bash)')
  .option('--bg-only', 'Internal: run only fire-and-forget background handlers (used by the detached child)')
  .option('--stdin-file <path>', 'Internal: read the hook payload from this file instead of STDIN')
  .option('--team-hooks', '...')       // 团队自定义 hook 走另一条路，保留退出码
  .action(async (event, hookArgs, cmdOpts) => {
    const bgOnly = cmdOpts.bgOnly ?? false;
    const tool = cmdOpts.tool ?? 'claude';
    // ... --team-hooks 分支 ...

    const HOOK_HARD_EXIT_MS = 7_000;
    let hardExit: NodeJS.Timeout | undefined;
    if (!bgOnly && tool !== 'git') {
      hardExit = setTimeout(() => process.exit(0), HOOK_HARD_EXIT_MS);
      hardExit.unref();                 // 不让这个定时器本身拖住进程
    }
    const { hookDispatchCli } = await import('./hook-dispatch-cli.js');   // 懒加载
    try {
      await hookDispatchCli(event, tool, cmdOpts.matcher ?? '*', { ...cmdOpts, hookArgs });
    } finally {
      // ...
    }
  });
```

**为什么是 7 秒**（`index.ts:1101` 注释）：宿主不管你声明多大的 timeout，大约 10 秒就会强杀 hook，并报 "Hook timed out after 10000ms"，IDE 直接出错。卡住的原因可能是 STDIN 一直不发 EOF、某个 handler 死锁、或者一个被中止的 fetch 留下 socket 让事件循环不退出。7 秒既低于 10 秒上限，又高于前台 handler 的 4.5 秒预算，所以**正常情况下永远不会触发，只兜最坏情况**。

两个例外：

- `--bg-only` 后台子进程：宿主不等它，不需要抢时间
- `--tool git`：git 没有 hook 超时，强杀反而会把正在写的文件写坏

---

## 4. CLI 编排层：`hookDispatchCli()` 逐步拆解

完整函数在 `src/hook-dispatch-cli.ts:416`，下面按执行顺序拆开讲。

### 4.1 第一件事：stdout 只留给协议

```ts
export async function hookDispatchCli(event, tool, matcher, options = {}) {
  const { bgOnly = false, stdinFile } = options;
  setStderrOnly(true);   // 所有日志改走 stderr
  // ...
}
```

小白要点：对宿主来说，hook 进程的 **stdout 就是返回值**，必须是一份合法 JSON（或者为空）。只要混进一行日志，宿主就解析失败。所以入口第一行就把 logger 切到 stderr。文件头注释也强调了这一点：*"STDOUT is reserved for the AI-tool hook JSON payload; all log lines go to STDERR"*。

### 4.2 宿主去重：别在错误的宿主里跑

```ts
if (claudeHookRunsInAnotherHost(tool, process.env, false)) {
  log.debug('hook-dispatch: skipping claude hooks because Cursor or Copilot CLI has its own teamai hooks');
  return;
}
```

为什么需要：Cursor 和 Copilot CLI 都能**兼容读取** Claude 的 `settings.json`。如果它们本身也装了 teamai 自己的 hook，那么同一个事件会被触发两次：一次 `--tool cursor`，一次 `--tool claude`。这里通过环境变量识别真实宿主，把多余的那次直接丢掉。

### 4.3 读 STDIN：最多等 1 秒

`hook-dispatch-cli.ts:56`：

```ts
const STDIN_READ_TIMEOUT_MS = 1_000;

export async function readStdin(stream = process.stdin, timeoutMs = STDIN_READ_TIMEOUT_MS) {
  if (stream.isTTY) return '';                   // 手动在终端里跑，没有管道
  const chunks: Buffer[] = [];
  const readAll = (async () => {
    for await (const chunk of stream) chunks.push(chunk as Buffer);   // 读到 EOF 才结束
  })();
  void readAll.catch(() => {});                  // 防止超时后出现未处理的 rejection
  let timedOut = false;
  const deadline = new Promise<void>((resolve) => {
    const timer = setTimeout(() => { timedOut = true; resolve(); }, timeoutMs);
    timer.unref();
  });
  await Promise.race([readAll, deadline]);       // 谁先完成用谁
  if (timedOut && !stream.destroyed) stream.destroy();   // 释放管道句柄，否则进程退不出去
  return Buffer.concat(chunks).toString('utf-8');
}
```

为什么要超时：`for await (process.stdin)` 要等宿主**关闭管道（EOF）**才会结束。有些宿主（注释里点名 CodeBuddy）写完 payload 却不关管道，于是一直卡到被宿主杀掉，handler 一个都没跑。正常宿主几毫秒内就会发 EOF，所以 1 秒的截止时间只在出问题时起作用：**拿着已经收到的数据继续往下走**。

### 4.4 解析 STDIN：坏数据也要尽量用

`hook-dispatch-cli.ts:340`：

```ts
export function parseStdin(raw: string, event: string): Record<string, unknown> {
  let stdin: Record<string, unknown> = {};
  if (raw.trim()) {
    try {
      stdin = JSON.parse(raw);
    } catch {
      // 只记长度，不记内容：payload 里可能有 prompt、凭证、工具参数
      log.debug(`hook-dispatch: failed to parse STDIN JSON for event=${event} (len=${raw.length})`);
      stdin = salvageStdinFields(raw);           // 抢救关键字段
    }
  }
  // JSON.parse('null') / '123' / '[]' 也能成功，但它们不是合法 payload
  if (!stdin || typeof stdin !== 'object' || Array.isArray(stdin)) stdin = {};

  // WorkBuddy/CodeBuddy 可能传 hook_event_name: ""，用 CLI 参数补上
  if (!stdin.hook_event_name) {
    const EVENT_MAP: Record<string, string> = {
      'session-start': 'SessionStart', 'session-end': 'SessionEnd',
      'stop': 'Stop', 'subagent-stop': 'SubagentStop', 'subagent-start': 'SubagentStart',
      'post-tool-use': 'PostToolUse', 'prompt-submit': 'UserPromptSubmit',
    };
    stdin.hook_event_name = EVENT_MAP[event] ?? event;
  }
  const cwd = resolveHookCwd(stdin);             // Cursor 只给 workspace_roots，这里统一成 cwd
  if (cwd) stdin.cwd = cwd;
  return stdin;
}
```

"抢救"是什么（`hook-dispatch-cli.ts:152`）：Windows 上某些启动器会用 ANSI 代码页解码 UTF-8 payload，遇到中文就把 JSON 结构弄坏，但前面的 ASCII 部分通常是完好的。于是用正则把几个身份字段捞出来：

```ts
const SALVAGEABLE_STDIN_FIELDS = [
  'session_id', 'sessionId', 'transcript_path', 'transcriptPath',
  'tool_name', 'toolName', 'tool_use_id', 'toolUseId', 'cwd',
] as const;
// camelCase 的命中（ZCode 这么传）同时抄一份到 handler 读的 snake_case 名字上
const CANONICAL_FIELD_ALIASES = { sessionId: 'session_id', transcriptPath: 'transcript_path', /* ... */ };
```

这里体现的原则是**降级优于中断**：数据坏了，依赖 transcript 的 handler 会自己跳过，不读 stdin 的后台 handler（比如版本检查）照样能跑，dashboard 也还能把事件归到正确的会话上。注释里专门说明了：如果这里抛异常，外层 try/catch 会吞掉它，整次调度就短路了，而这正是要避免的。

### 4.5 解析作用域：这个 hook 属于哪个团队配置？

```ts
const { resolveHookConfig } = await import('./dashboard-collector.js');
const cwd = resolveHookCwd(stdin);
if (cwd) {
  try { process.chdir(cwd); }
  catch (e) { log.debug(`hook-dispatch: chdir to ${cwd} failed: ...`); }   // 失败也不中断
}
// ...
const localConfig = await resolveHookConfig(stdin, tool);
```

关键背景：**即使是项目级安装，hook 也装在 HOME 下**（比如 `~/.claude/settings.json`），所以它会在这台机器的**每一个项目**里触发。调度器必须根据 payload 的 `cwd` 判断：

- 这个目录有项目级 teamai 配置 → 用项目配置（#264）
- 没有 → 退回用户级配置
- 都没有 → `localConfig = null`（下一步会过滤掉所有团队相关 handler）
- cwd 已经不存在了（worktree 被删）→ 沿用这个会话之前记录的作用域（#810）

`HookHandler` 接口的注释（`hook-dispatch.ts:22`）特别强调：handler 必须从 `config` 参数读取作用域，**不能读 `process.cwd()`**，因为上面的 `chdir` 可能失败（#752）。这是一个很好的"显式依赖优于隐式全局状态"的例子。

### 4.6 构建并过滤 handler

```ts
const handlers = filterHandlersForConfig(buildHandlerRegistry(), localConfig);
const dispatcher = createDispatcher({ handlers, localConfig });
```

`filterHandlersForConfig`（`hook-handlers.ts:1234`）就两条规则：

```ts
export function filterHandlersForConfig(registry, localConfig) {
  if (!localConfig) {
    // 没有 teamai 的目录：不能出现任何团队提示（#748）
    return registry.filter((reg) => reg.requiresConfig !== true);
  }
  if (localConfig.repo.kind === 'http') {
    // HTTP 源的团队没有 git 工作流：不提示"去提 PR 分享经验"之类
    return registry.filter((reg) => reg.gitOnly !== true);
  }
  return registry;
}
```

注释还说明了两个细节：

- 配置文件损坏时 `loadLocalConfig` 也返回 null，所以损坏的配置同样不会弹团队提示，由 `teamai doctor` 去报告。
- 这**不是安全闸门**，只是体验过滤。HTTP 团队的写操作在执行时另有 `assertNotReadOnly()` 拦截。

### 4.7 前后台拆分：慢活交给"脱离宿主"的子进程

```ts
// 子进程：只跑后台 handler，跑完就退，不回写任何东西
if (bgOnly) {
  await runDispatch(dispatcher, event, matcher, stdin, tool, 'background');
  return;
}

// 父进程：先把后台子进程拉起来，让它和前台并行工作
let settling: Promise<void> | undefined;
if (dispatcher.hasBackground(event, matcher)) {
  // 宿主没传 session_id 时，父子进程必须用同一个兜底 id，否则同一条提示会被领取两次
  if (typeof stdin.session_id !== 'string' || !stdin.session_id) {
    stdin.session_id = deriveDispatchSessionId(stdin, tool);
  }
  settling = spawnBackground(event, tool, matcher, JSON.stringify(stdin), cwd);
}

const output = await runDispatch(dispatcher, event, matcher, stdin, tool, 'foreground');
if (output) {
  await new Promise<void>((resolve) => process.stdout.write(output, () => resolve()));
}
await settling;   // 只等子进程"启动成功"，不等它跑完
```

`spawnBackground`（`hook-dispatch-cli.ts:97`）其实就是**用同样的参数再调一次自己**，加上 `--bg-only`：

```ts
async function spawnBackground(event, tool, matcher, raw, cwd?) {
  const args = [resolveCliEntry() ?? '', 'hook-dispatch', event, '--tool', tool, '--bg-only'];
  if (matcher && matcher !== '*') args.push('--matcher', matcher);
  if (await trySpawnDetachedViaWmi(process.execPath, args, { cwd, stdin: raw })) return;   // Windows
  await spawnPlainDetached(process.execPath, args, raw, cwd);                              // 其他平台
}

async function spawnPlainDetached(command, args, stdin, cwd?) {
  try {
    const child = spawn(command, args, {
      detached: true,                          // 独立进程组，父进程退出不影响它
      windowsHide: true,
      stdio: ['pipe', 'ignore', 'ignore'],     // 只给 stdin，输出全部丢弃
      ...(cwd ? { cwd: fs.existsSync(cwd) ? cwd : os.tmpdir() } : {}),  // 目录被删了就用临时目录
    });
    child.on('error', () => {});
    await new Promise<void>((resolve) => {
      if (!child.stdin) return resolve();
      child.stdin.on('error', () => resolve());
      child.stdin.end(stdin, () => resolve());  // 把已读过的 STDIN 原样转交给子进程
    });
    child.unref();                             // 父进程不再等它
  } catch {
    // 后台工作是尽力而为，启动失败也绝不能影响宿主
  }
}
```

几个值得注意的设计：

1. **复用而不是另写**：子进程走的是同一条代码路径，只是 `mode` 不同。前后台用的是同一份注册表，不会出现两套逻辑对不上的情况。
2. **STDIN 只读一次**：父进程已经读过了，通过管道（或 Windows 上的临时文件 `--stdin-file`）转交给子进程。
3. **先启动后台，再跑前台**：两者并行，总耗时更短。
4. **Windows 的 WMI 逃逸**（`trySpawnDetachedViaWmi`，`:220`）：WorkBuddy/CodeBuddy 在 Windows 上把 hook 放进一个 job object，hook 的直接子进程一退出就杀掉整个 job，`detached: true` 也躲不过。解决办法是通过 WMI 服务创建进程，这样新进程天生就不在这个 job 里。约 0.3 秒的开销和前台执行重叠，基本感觉不到。

### 4.8 兜底：任何意外都不能冒泡到宿主

```ts
  } catch (e) {
    log.warn(`hook-dispatch: unexpected error: ${e instanceof Error ? e.message : String(e)}`);
  }
}
```

再加上安装时的 `2>/dev/null || true`，teamai 出了任何问题，宿主看到的都只是"这个 hook 什么都没返回"。

> 4.5 和 4.6 之间还有一段 Copilot 专属逻辑（`hook-dispatch-cli.ts:476`）：Copilot 的同一个事件可能被全局配置和项目配置各触发一次，`claimCopilotHookEvent` 以事件 + payload 为键做"先到先得"，只让一次通过。这是宿主特性导致的去重，与调度内核无关。

---

## 5. 调度内核：`createDispatcher()`（238 行，全项目最值得精读的文件）

### 5.1 接口：handler 就是一个纯函数

`src/hook-dispatch.ts:20`：

```ts
export interface HookHandler {
  name: string;
  // 输入：解析好的 STDIN、工具 id、作用域配置
  // 输出：要写回宿主的字符串（JSON），或 null 表示"我没什么要说的"
  execute(stdin: Record<string, unknown>, tool: string, config: LocalConfig | null): Promise<string | null>;
}

export interface HandlerRegistration {
  event: string;          // 'stop' / 'session-start' / ...
  matcher: string;        // '*' 或具体工具名，如 'Skill'
  handler: HookHandler;
  timeoutMs?: number;     // 超时就算失败
  background?: boolean;   // 纯副作用，放到后台子进程跑
}

export type DispatchMode = 'all' | 'foreground' | 'background';

export interface DispatchResult {
  output: string | null;      // 合并后的输出
  errors: DispatchError[];    // 失败的 handler（非致命）
}
```

接口非常小：handler 不知道自己是前台还是后台，不知道有没有别的 handler，也不直接写 stdout。**它只负责"拿到输入，给出输出"**，编排全交给调度器。

### 5.2 路由：精确匹配

```ts
export function createDispatcher(config: DispatcherConfig): Dispatcher {
  const matchedFor = (event: string, matcher: string) =>
    config.handlers.filter((reg) => reg.event === event && reg.matcher === matcher);

  return {
    hasBackground(event, matcher) {
      return matchedFor(event, matcher).some((reg) => reg.background === true);
    },
    async dispatch(event, matcher, stdin, tool, mode = 'all') {
      const matched = matchedFor(event, matcher).filter((reg) => {
        if (mode === 'foreground') return reg.background !== true;
        if (mode === 'background') return reg.background === true;
        return true;
      });
      // ...
    },
  };
}
```

小白容易误解的一点：**matcher 是精确匹配，`'*'` 不是"匹配所有"**。看注释（`:154`）：

> The injected wildcard hook dispatches matcher='*' separately, so wildcard handlers must not also run during a specific matcher dispatch.

原因要回到安装侧：`BUILTIN_HOOK_SPECS` 给 PostToolUse 装了**三条** hook，分别是 `*`、`Skill`、`TodoWrite`。当 AI 调用 Skill 工具时，宿主会**同时**触发 `*` 那条和 `Skill` 那条，也就是两个进程：

```
--matcher 不传（即 *）  → 只跑 matcher='*' 的 handler（dashboard、recall 归因……）
--matcher Skill          → 只跑 matcher='Skill' 的 handler（track 使用统计、webhook）
```

如果 `'*'` 在调度器里也算"匹配所有"，`*` 类的 handler 就会在两个进程里各跑一次，统计翻倍。**宿主已经做过一次通配，调度器不能再做第二次。**

### 5.3 执行：并发 + 隔离 + 各自限时

```ts
const DEFAULT_TIMEOUT_MS = 60_000;   // 与 Claude Code 默认 hook 超时一致

const settled = await Promise.allSettled(
  matched.map((reg) => {
    const timeoutMs = reg.timeoutMs ?? DEFAULT_TIMEOUT_MS;
    const handlerStartedAt = Date.now();
    const record = (outcome: string) => {
      timings.push({ handler: reg.handler.name, ms: Date.now() - handlerStartedAt, outcome });
    };
    return withTimeout(reg.handler.execute(stdin, tool, config.localConfig), timeoutMs, reg.handler.name).then(
      (value) => { record('ok'); return value; },
      (err) => {
        record(err instanceof Error && /exceeded timeout/.test(err.message) ? 'timeout' : 'failed');
        throw err;
      },
    );
  }),
);
```

三个关键词：

- **并发**：`matched.map(...)` 一次性启动所有 handler，总耗时约等于最慢的那个，而不是全部相加。
- **隔离**：用 `Promise.allSettled` 而不是 `Promise.all`。`all` 只要有一个 reject 就整体失败，其他结果全部丢失；`allSettled` 会等所有 handler 结束，每个结果单独标记成功或失败。
- **限时**：`withTimeout`（`:139`）：

```ts
function withTimeout<T>(promise: Promise<T>, ms: number, handlerName: string): Promise<T> {
  return new Promise<T>((resolve, reject) => {
    const timer = setTimeout(() => {
      reject(new Error(`Handler "${handlerName}" exceeded timeout of ${ms}ms`));
    }, ms);
    promise.then(
      (val) => { clearTimeout(timer); resolve(val); },
      (err) => { clearTimeout(timer); reject(err); },
    );
  });
}
```

注意：超时只是**不再等**这个 handler，并不能真正中止它（JS 的 Promise 无法取消）。它还在后台继续跑，直到进程退出。这也是入口需要 7 秒硬退出的原因之一。

**可观测性**：每次调度都会打一行 debug 日志，按耗时从慢到快列出每个 handler 和它的结果（`:207`）：

```
# 示意（数字是编的，格式与代码一致）
[hook-dispatch] stop/claude foreground: 812ms total, 2 handlers, slowest votes-sync=790ms | votes-sync=790ms(ok) contribute-check=120ms(ok)
```

用 `teamai --verbose hook-dispatch ...` 就能看到，排查"为什么会话启动变慢"时非常有用。

### 5.4 收集结果：错误只记日志，输出交给合并

```ts
const outputs: string[] = [];
const errors: DispatchError[] = [];
for (let i = 0; i < settled.length; i++) {
  const result = settled[i];
  const handlerName = matched[i].handler.name;
  if (result.status === 'rejected') {
    errors.push({ handlerName, error: result.reason instanceof Error ? result.reason : new Error(String(result.reason)) });
  } else if (result.status === 'fulfilled' && result.value != null) {
    outputs.push(result.value);           // null 表示"没话说"，不参与合并
  }
}
return { output: mergeHookOutputs(outputs), errors };
```

CLI 层的 `runDispatch`（`hook-dispatch-cli.ts:391`）拿到 `errors` 后**只写 debug 日志**，绝不写 stdout：

```ts
for (const err of result.errors) {
  log.debug(`hook-dispatch: handler "${err.handlerName}" failed: ${err.error.message}`);
}
return result.output;
```

### 5.5 合并输出：多个提示合成一份 JSON

一次 Stop 可能有两个 handler 都想说话（比如一条知识采纳相关的提示，加一条"这次会话值得分享"）。宿主只读一份 stdout，所以要合并（`hook-dispatch.ts:94`）：

```ts
export function mergeHookOutputs(outputs: string[]): string | null {
  if (outputs.length === 0) return null;
  if (outputs.length === 1) return outputs[0];

  let parsed: JsonObject[];
  try {
    parsed = outputs.map((output) => {
      const value = asObject(JSON.parse(output));
      if (!value) throw new Error('Hook output is not an object');
      return value;
    });
  } catch {
    return outputs[0];                   // 看不懂的格式：保持老行为，只取第一个
  }

  // 情况 1：Cursor 协议，都是 followup_message → 用换行拼起来
  const followups = parsed.map((value) => value.followup_message);
  if (followups.every((v): v is string => typeof v === 'string')) {
    return JSON.stringify({ ...parsed[0], followup_message: followups.join('\n') });
  }

  // 情况 2：Claude 协议，都是 hookSpecificOutput.additionalContext，且事件名一致 → 拼接
  const specificOutputs = parsed.map((value) => asObject(value.hookSpecificOutput));
  if (specificOutputs.every((v): v is JsonObject => v !== null)) {
    const contexts = specificOutputs.map((v) => v.additionalContext);
    const eventNames = new Set(specificOutputs.map((v) => v.hookEventName).filter(Boolean));
    if (contexts.every((v): v is string => typeof v === 'string') && eventNames.size <= 1) {
      return JSON.stringify({
        ...parsed[0],
        hookSpecificOutput: { ...specificOutputs[0], additionalContext: contexts.join('\n') },
      });
    }
  }

  return outputs[0];                     // 混合格式：不冒险，取第一个
}
```

合并前后对比（文案是示意，结构与代码一致）：

```jsonc
// handler A 输出
{"hookSpecificOutput":{"hookEventName":"Stop","additionalContext":"你采纳了 3 条团队知识"}}
// handler B 输出
{"hookSpecificOutput":{"hookEventName":"Stop","additionalContext":"本次会话值得分享，运行 /share"}}
// 合并后写到 stdout
{"hookSpecificOutput":{"hookEventName":"Stop","additionalContext":"你采纳了 3 条团队知识\n本次会话值得分享，运行 /share"}}
```

设计思路：**只合并"确定能安全合并"的情况**（全部同一种协议、同一个事件），其他情况退回"取第一个"的老行为。宁可少传一条提示，也不生成一份宿主看不懂的 JSON。

注意合并只认两种协议形状，不关心是哪个工具。handler 自己按工具产出对应格式（比如用 `formatStopHookOutput(message, tool)`，见第 7 节），调度器只看形状。

---

## 6. Handler 注册表：一张表定义所有行为

### 6.1 注册项的元数据

`hook-handlers.ts:26` 在内核接口的基础上多了几个字段：

```ts
export interface HandlerRegistration {
  event: string;
  matcher: string;
  handler: HookHandler;
  timeoutMs: number;           // 这里是必填：每个 handler 必须明确自己的预算
  background?: boolean;        // 纯副作用 → 后台子进程
  gitOnly?: boolean;           // 只对 git 源团队有意义
  requiresConfig?: boolean;    // 只在配置了 teamai 的目录生效
}
```

**一个 handler 的全部"调度属性"都声明在注册表里**：什么时候跑、跑多久、前台还是后台、哪些团队能看到。handler 实现本身只管业务。

### 6.2 注册表全貌

`buildHandlerRegistry()`（`hook-handlers.ts:1130`）按事件整理如下。"前台"表示可能返回内容注入会话，"后台"表示纯副作用：

| 事件 | matcher | handler | 前/后台 | 作用 |
| --- | --- | --- | --- | --- |
| session-start | * | pull | 后台 | 拉取团队仓库并同步资源（120s 预算） |
| session-start | * | dashboard-report | 前台 | 上报会话事件 |
| session-start | * | team-rules | 前台 | 给 Codex 等没有规则目录的工具注入团队规则 |
| session-start | * | mr-hint | 前台 | 提示可导入的 MR 经验（gitOnly） |
| session-start | * | package-hint / team-env-hint | 前台 | 依赖变化、团队环境变量提示 |
| session-start | * | local-agent | 前台 | 本地 agent 联动 |
| session-start | * | webhook | 后台 | 通知外部系统 |
| stop | * | update | 后台 | 查 npm 新版本（10s） |
| stop | * | votes-sync | 前台 | 统计本次会话采纳了哪些团队知识（gitOnly） |
| stop | * | votes-judge | 后台 | 可选的 LLM 评判（45s，`TEAMAI_UPVOTE_JUDGE=1` 开启） |
| stop | * | contribute-check | 前台 | 判断是否值得分享经验（gitOnly） |
| stop | * | dashboard-report / local-agent / webhook | 后台 | 上报、通知 |
| session-end | * | dashboard / webhook / votes-sync | 混合 | Copilot 结束时发 SessionEnd 而不是 Stop（#702） |
| subagent-start | * | team-rules 等 | 前台 | Codex 子 agent 不触发 SessionStart（#938） |
| subagent-stop | * | votes-sync | 前台 | 子 agent 在最后一次 Stop 之后才结束（#884） |
| post-tool-use | * | dashboard-report / recall-attribution | 前台 | 记录工具调用、知识召回归因 |
| post-tool-use | Skill | track / webhook | 前台 / 后台 | skill 使用统计 |
| post-tool-use | TodoWrite | todowrite-hint | 前台 | 2.5s 预算（宿主上限只有 3s） |
| prompt-submit | * | pending-hint | 前台 | 补发 Stop 时发不出去的提示 |
| prompt-submit | * | track-slash / dashboard / local-agent | 前台 | 斜杠命令统计等 |
| instructions | * | instructions | 前台 | Pi / OMP / Hermes 扩展主动拉取指令块 |
| post-checkout / post-merge / post-rewrite | * | new-worktree / git-pull | 前台 | `--tool git`：git hook 也走同一个调度器 |

几个值得注意的点：

- **同一个 handler 可以注册到多个事件**：`dashboardReportHandler` 出现了 5 次，`votesSyncHandler` 出现在 stop、session-end、subagent-stop。handler 本身复用，差异由注册表表达。
- **宿主差异也在注册表里体现**：Copilot 没有 Stop 就补 session-end，Codex 子 agent 没有 SessionStart 就补 subagent-start。
- **调度器不只服务 AI 工具**：`--tool git` 让 git hook 也复用这套机制，`instructions` 事件给插件型工具按需拉取。**它是一个通用的"事件 → 处理器"总线**。

### 6.3 超时预算体系

`hook-handlers.ts:49` 起的常量是一套经过实测的预算：

```ts
const FOREGROUND_HOOK_TIMEOUT_MS = 4_500;   // 所有前台 handler 统一上限
const TODOWRITE_HINT_TIMEOUT_MS = 2_500;    // TodoWrite 的宿主上限只有 3s
const UPDATE_TIMEOUT_MS = 10_000;           // 后台：查 npm registry
const LOCAL_AGENT_TIMEOUT_MS = 15_000;      // 后台：本地 agent 同步
const VOTES_JUDGE_TIMEOUT_MS = 45_000;      // 后台：调用本地 CLI 做 LLM 评判（其内部 30s 上限）
export const PULL_TIMEOUT_MS = 120_000;     // 后台：冷启动 pull 实测 10~25s
```

为什么前台是 4.5 秒（注释的核心逻辑）：

1. CodeBuddy 约 10 秒强杀 hook，**不管声明的 timeout 是多少**
2. 前台 handler 是并发的，所以前台总耗时 ≈ 最大的单个 timeout + Node 启动/退出时间
3. 把每个前台 handler 都卡在 5 秒以内，总耗时就稳定在 10 秒以下，还有余量
4. 被截断的网络副作用（比如首次大量同步、投票增量推送）会由后台进程或下一次补完

为什么 pull 要 120 秒：后台 handler 的超时**不是建议值**。调度一结束，进程就会 `process.exit(0)`，还没跑完的工作会被截断（git 子进程变成孤儿、后续同步步骤不执行）。早先共用的 15 秒预算就曾把 pull 静默截断。

完整的时间线：

```
宿主强杀（~10s，CodeBuddy 实测）─────────────────────────────────────┐
入口硬退出（7s）HOOK_HARD_EXIT_MS ──────────────────────────┐          │
前台 handler 上限（4.5s）────────────────────┐               │          │
STDIN 读取上限（1s）────┐                     │               │          │
0s ─────────────────────┴─────────────────────┴───────────────┴──────────┴──>
后台子进程：不受以上限制，各自预算（10s / 15s / 45s / 120s）
```

一层套一层，**每一层都比外层留出余量**。

### 6.4 懒加载：只加载要跑的模块

`hook-handlers.ts:103` 的注释：

```ts
// Each handler is a thin adapter that:
//   1. Receives pre-parsed STDIN
//   2. Delegates to the actual subcommand logic
//   3. Returns output string or null
//
// IMPORTANT: These use dynamic imports to keep module loading lazy.
// The dispatcher only loads the modules that actually need to run.
```

所以每个 handler 内部都是 `await import('./xxx.js')`。hook 在每次工具调用时都会触发，启动速度非常关键：PostToolUse 的调度没必要加载 pull、git、yaml 这些重模块。`utils/tool-names.ts` 的注释里甚至专门说明 `CODEX_TOOL_IDS` 为什么放在这里而不是 `agent-format.ts`：后者会连带引入 yaml、gray-matter、smol-toml，而 `hook-handlers.ts` 每次调度都会静态 import 这个文件。

---

## 7. 两个 handler 实例

### 7.1 `pullHandler`：后台、带守卫的副作用

`hook-handlers.ts:113`：

```ts
const pullHandler: HookHandler = {
  name: 'pull',
  async execute(stdin, tool, config) {
    const cwd = resolveHookCwd(stdin);
    // 没解析到配置时，区分"这里没装 teamai"和"项目配置读不了"，后者不能乱拉（#784）
    if (!config && (cwd === undefined || await pathExists(cwd))) {
      const { findUnreadableProjectConfig } = await import('./config.js');
      if (await findUnreadableProjectConfig(cwd) !== null) return null;
    }
    // 用户对这个工具执行过 uninstall --agent：不能通过 hook 又把东西装回来（#993）
    if (config) {
      const { isAgentExcluded } = await import('./types.js');
      if (isAgentExcluded(config, tool)) return null;
    }
    // ...
    const { pull } = await import('./pull.js');      // 懒加载重模块
    await pull({ silent: true });                     // 复用 `teamai pull` 的同一套逻辑
    // ...
    return null;                                      // 后台 handler 永远不返回内容
  },
};
```

要点：handler 是**薄适配器**，真正的逻辑还是 `pull()`。命令行 `teamai pull` 和会话启动时的自动 pull 跑的是同一份代码。

### 7.2 `contributeCheck` + `pendingHint`：跨进程接力

问题：Stop 时想提示"这次会话值得分享"，但 CodeBuddy、WorkBuddy、Codex、Muse 的 Stop hook 没法把内容送达（见 `stopStdoutUnsupported`）。

解决：Stop 时**暂存**，下一次用户提交 prompt 时**补发**。两个 handler 分别注册在两个事件上，通过磁盘上的会话状态接力。

Stop 侧（`hook-handlers.ts:464`）：

```ts
const contributeCheckHandler: HookHandler = {
  name: 'contribute-check',
  async execute(stdin, tool) {
    // ...作用域判断...
    const sessionId = deriveSessionId(stdin, { includeCwd: true });
    const stash = stopStdoutUnsupported(tool);          // 这个工具 Stop 时发不出去？
    const { hint } = await contributeCheckForSession(sessionId, cwd, transcriptPath, stash);
    if (!hint) return null;                             // 暂存时这里拿到 null
    return formatStopHookOutput(relayWhenHidden(hint, tool), tool);   // 能发：按工具格式输出
  },
};
```

UserPromptSubmit 侧（`hook-handlers.ts:496`）：

```ts
const pendingHintHandler: HookHandler = {
  name: 'pending-hint',
  async execute(stdin, tool) {
    const { stopStdoutUnsupported } = await import('./utils/tool-names.js');
    if (!stopStdoutUnsupported(tool)) return null;     // Stop 能发的工具不需要补发
    // 必须和 contributeCheckHandler 用同样的方式推导 sessionId，才能找到同一个状态文件
    // ...读出暂存的提示，输出，并标记已发送...
  },
};
```

这个例子说明调度器的边界：**它只管单次调度内的扇出和合并**；跨事件的协作由 handler 通过共享状态（会话 id + 状态文件）自己完成。代码注释反复强调 sessionId 的推导方式必须一致，这也是 4.7 节里父子进程要共用同一个兜底 session_id 的原因。

---

## 8. 设计思想总结

| 思想 | 体现 |
| --- | --- |
| **单一入口 / 扇出（fan-out）** | 每个事件只有一条 hook 命令，内部扇出到 N 个 handler；新功能不需要改任何工具配置 |
| **注册表驱动** | event / matcher / timeout / background / gitOnly / requiresConfig 全部声明在一张表里 |
| **纯函数 handler** | `(stdin, tool, config) → string \| null`，不碰 stdout、不读 cwd，便于测试和复用 |
| **故障隔离** | `Promise.allSettled` + 每个 handler 独立超时；错误只记日志 |
| **快慢分离** | 需要回复的在前台，纯副作用放到 detached 子进程；子进程复用同一条代码路径 |
| **分层时间预算** | STDIN 1s < 前台 4.5s < 硬退出 7s < 宿主约 10s；后台按实测单独设预算 |
| **降级优于中断** | STDIN 坏了就抢救字段、cwd 没了就用临时目录、chdir 失败继续跑、spawn 失败静默 |
| **协议纯净** | stdout 只写一份合并后的协议 JSON，日志全走 stderr，命令尾部 `2>/dev/null \|\| true` |
| **保守合并** | 只合并确定兼容的输出形状，其他情况保持"取第一个"的老行为 |
| **按需加载** | handler 内部动态 import，高频事件不加载重模块 |
| **作用域显式传递** | `config` 作为参数传给 handler，而不是依赖进程全局状态 |

面试时可以这样概括：

> 我们把每个 AI 工具的每个生命周期事件都收敛成一条 `teamai hook-dispatch <event> --tool <id>` 命令。调度器读一次 STDIN，做容错解析和归一化，根据 cwd 解析出团队作用域，再按注册表精确匹配 event 和 matcher 找出 handler，用 `Promise.allSettled` 加独立超时并发执行，最后把多个 handler 的输出按宿主协议合并成一份 JSON 写回 stdout。git fetch、npm 版本检查这类慢的副作用标记为 background，由一个复用同一套代码、用 `--bg-only` 启动的 detached 子进程执行（Windows 上通过 WMI 逃出宿主的 job object），宿主不需要等待。配合 STDIN 1 秒、前台 4.5 秒、硬退出 7 秒的分层超时，保证在 CodeBuddy 约 10 秒的强杀线之前一定返回。这样新增功能只是在注册表里加一行，和 30 多个工具的适配完全解耦。

（如果你没有参与过这部分开发，记得说成"这个项目的设计是……"或"我研读源码后梳理出……"。）

---

## 9. 如果要加一个新 handler

假设要在 Stop 时做一件新事情：

1. 在 `src/hook-handlers.ts` 写一个 `const xxxHandler: HookHandler = { name, async execute(stdin, tool, config) {...} }`
   - 内部用 `await import(...)` 加载依赖
   - 从 `config` 读作用域，不要读 `process.cwd()`
   - 需要给宿主输出就返回 JSON 字符串（Stop 用 `formatStopHookOutput`），否则返回 `null`
2. 在 `buildHandlerRegistry()` 加一行注册，明确四件事：
   - `timeoutMs`：前台用 `FOREGROUND_HOOK_TIMEOUT_MS`，后台按实测设置
   - `background`：不需要返回内容的一律设为 `true`
   - `requiresConfig`：团队相关功能设为 `true`
   - `gitOnly`：依赖 git 工作流（PR、投票推送）的设为 `true`
3. 输出在某些工具上发不出去？参考 7.2 节的暂存 + 补发模式
4. 在 `src/__tests__/hook-handlers.test.ts` 加测试

**不需要**改 `builtin-hooks.ts`、`hooks.ts` 或任何工具的配置格式，除非你要监听一个新的事件。

---

## 10. 动手实验

测试文件就是最好的"可运行文档"：

```bash
npx vitest run hook-dispatch        # 内核：路由、allSettled、超时、合并（hook-dispatch.test.ts）
npx vitest run hook-dispatch-cli    # CLI 层：readStdin 超时、parseStdin 容错、salvage
npx vitest run hook-dispatch-scope  # 作用域解析
npx vitest run hook-handlers        # 注册表与过滤规则
```

（需要先在仓库里 `npm install`。）

手动触发一次，观察日志里的耗时明细：

```bash
# 1. 在一个已 init 的测试项目里，模拟 Claude 的 PostToolUse（matcher=Skill）
echo '{"cwd":"'"$PWD"'","session_id":"test","tool_name":"Skill","tool_input":{"skill":"demo"}}' \
  | teamai --verbose hook-dispatch post-tool-use --tool claude --matcher Skill

# 2. 坏 JSON：观察"降级而不中断"
echo '{"session_id":"test", broken' | teamai --verbose hook-dispatch prompt-submit --tool claude

# 3. 不在任何 teamai 项目里（如 /tmp）：requiresConfig 的 handler 会被过滤掉
cd /tmp && echo '{"cwd":"/tmp"}' | teamai --verbose hook-dispatch prompt-submit --tool claude
```

> 注意：`session-start` 和 `stop` 会触发真实的后台 pull、版本检查、上报，最好在测试项目里试。全局安装的 teamai 是 0.27.0，源码是 0.22.0，日志格式和行为可能略有不同。

建议的阅读顺序：

1. `src/hook-dispatch.ts` 全文（238 行）：先吃透内核
2. `src/hook-handlers.ts:24-110`（接口和超时常量）和 `:1130-1245`（注册表和过滤）
3. `src/hook-dispatch-cli.ts:339-519`（`parseStdin` 和主流程），再回头看 `:38-140`（读 STDIN、启动后台进程）
4. `src/index.ts:1073-1125`（入口和硬退出）
5. 随便挑两个 handler 精读，推荐 `contributeCheckHandler` 和 `pendingHintHandler`

---

## 11. 自测问题

1. 为什么 `matchedFor` 对 `'*'` 做精确匹配而不是通配？如果改成通配，会出现什么 bug？
2. `Promise.all` 和 `Promise.allSettled` 在这里的差别是什么？
3. `withTimeout` 超时后，handler 真的停止了吗？这和入口的 7 秒硬退出有什么关系？
4. 为什么前台 handler 的统一预算是 4.5 秒，而 pull 是 120 秒？
5. 后台子进程是怎么拿到 STDIN 的？Windows 上为什么不能直接用 `detached: true`？
6. 宿主没传 `session_id` 时，父进程为什么要在启动后台子进程**之前**补上一个？
7. 两个 handler 输出的格式不一致（一个是 `followup_message`，一个是 `hookSpecificOutput`）时，`mergeHookOutputs` 会怎么处理？为什么这样设计？
8. 在一个没装 teamai 的项目里打开 Claude Code，会话启动时哪些 handler 还会跑？（提示：看哪些注册项没有 `requiresConfig`）

（答案都在上文对应章节里。第 8 题：session-start 上没有 `requiresConfig` 的只有 `pull`（后台）和 `local-agent`（前台）；`pull` 内部还会再判断要不要真的拉取。）

