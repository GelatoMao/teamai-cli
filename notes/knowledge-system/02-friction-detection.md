# 第 2 步：怎么判断会话值得沉淀（摩擦检测）

> 面向小白。先讲"为什么要有它"和"整体长什么样"，再沿着一次真实的 Stop 调用逐函数看代码。
> 基于 `main@fe3b906` 源码（2026-10-17），代码片段标注 `文件:行号`；删减了部分注释，用 `// ...` 省略无关分支。行号会随代码变动，以函数名/常量名为准。
> 前置阅读：[01-hook-layer.md](./01-hook-layer.md)（hook 怎么被触发、调度器怎么把 Stop 事件分给各 handler）。本文只讲其中一个 handler `contribute-check`，以及它的搭档 `pending-hint`。

---

## 0. 一句话 + 一个类比

一句话：每次 AI 答完一轮（Stop 事件），teamai 给当前会话算一个"摩擦分"：用户打断过、拒绝过工具、AI 刚停下就被纠正、AI 反复撞上工具报错，都会加分；分数 >= 20 且会话至少有 15 次工具调用，就往对话里塞一段提示，建议运行 `/teamai share` 把这次的经验分享给团队。每个会话最多提示一次。

类比：健身房的教练。

- 教练不看你练了多久（工具调用多不代表有收获），只看你哪里卡住：动作被叫停（interrupt）、拒绝某个器械（toolReject）、刚做完就说"不对，重来"（correction）、同一个动作反复失败（toolError）
- 只来了两分钟的人，教练不会让你写训练心得（15 次工具调用硬门槛）
- 教练只提醒一次；你写过心得（contributed）之后就不再唠叨
- 有的场馆广播坏了（某些 AI 工具不处理 Stop hook 的输出），教练就把便条压在你下次进门一定会看到的地方（pending hint，在下一次 prompt-submit 时注入）

---

## 1. 为什么需要它

### 1.1 要解决的问题

团队知识库靠成员主动贡献，但人很少在会话结束时主动想起"这个坑值得记下来"。teamai 需要一个自动、低打扰的触发器：判断"这次会话大概率踩过坑"，然后轻推一下。

难点在于"值得沉淀"怎么量化。`computeSmartScore` 的注释写明了思路（`src/contribute-check.ts:224-241`）：

```ts
/**
 * Compute a session's FRICTION score — how much the user had to correct the AI
 * or the AI had to fight its tools. A session is worth documenting because it hit
 * a real snag, not because it ran a lot of tools.
 * ...
 * Scale is only a tiny nudge (diversity + skill use, max ~10) and can never
 * trigger a hint on its own — that is the whole point of the rewrite.
 */
```

衡量的是"摩擦"，不是"规模"。一个调用了 50 次工具但一路顺畅的会话不值得提示；用户被迫纠正 AI 的会话才值得。

### 1.2 设计取舍一览

| 取舍 | 选择 | 理由（来自源码注释） |
| --- | --- | --- |
| 打分依据 | 摩擦信号为主，规模只做微调 | 规模加分上限约 10，到不了阈值 20（`src/types.ts:2018-2026`） |
| 阈值高低 | 一个强信号（20 分）即达标 | "Calibrated so ONE clear primary friction signal ... crosses it"（`src/types.ts:2021`） |
| 防止小会话误报 | toolCount >= 15 硬门槛 | "a one-command session the user rejected is not knowledge-base material"（`src/types.ts:2014`） |
| 工具报错 | 分档计分，少于 3 次不计分 | "Distinct from a single fluke error — it takes a few to signal a real struggle"（`src/types.ts:2046`） |
| 打扰频率 | 每会话只提示一次（`hinted`） | 去重，避免每轮 Stop 都唠叨 |
| 性能 | 5 分钟去抖 + 状态缓存 | Stop 每轮都触发，不能每次都读全量 events.jsonl（`src/types.ts:2058-2064`） |
| 数据竞争 | 优先实时扫 transcript | Stop 事件由脱离的后台进程异步写入，检查时可能还没落盘（`src/contribute-check.ts:383-391`） |
| Stop 输出不可用的工具 | 暂存为 `pendingHint`，下一次 prompt-submit 注入 | 晚一轮送达好过直接丢失（`src/utils/tool-names.ts:57-66`） |
| 可关闭 | 环境变量 > 个人配置 > 团队配置 > 默认开 | 团队可能走自己的评审流程（`src/types.ts:124-131`） |

为什么"一个强信号就够"：interrupt / reject / correction 都是用户明确表达"AI 走错了"的动作，而且频率很低。阈值 20 恰好等于单个信号的权重，所以只要出现一次就达标；而规模类加分（skill 5 + 多样性最多 5）加起来只有 10，单靠"干得多"永远够不着。为了防止"一次拒绝就提示"在很短的会话里误报，再叠加 15 次工具调用的硬门槛：真正有内容可写的会话才会被提示。

---

## 2. 关键数据结构与存储位置

### 2.1 SessionFriction：四个摩擦计数

`src/types.ts:1966-1972`：

```ts
/** Friction signals that explain why a session qualified for contribution. */
export interface SessionFriction {
  interrupt: number;
  toolReject: number;
  correction: number;
  toolError: number;
}
```

| 字段 | 含义 | 数据来源 |
| --- | --- | --- |
| `interrupt` | 用户在 AI 输出中途打断（ESC） | 优先实时扫 transcript；否则取最新 Stop 事件的 `interventions` 快照 |
| `toolReject` | 用户拒绝了某次工具调用 | 同上 |
| `toolError` | 工具真实失败、AI 不得不重试 | 同上（旧事件没有该字段时按 0） |
| `correction` | Stop 后 60 秒内的下一条 prompt 被判为纠正 | 只能从 events 序列推导（`aggregateSessionMetrics`，见 3.4） |

### 2.2 ContributeState：每个会话一个状态文件

`src/types.ts:1974-2008`（节选，删去 JSDoc，行尾中文注释为本文所加）：

```ts
/** Per-session contribute state, persisted to ~/.teamai/sessions/{sessionId}.json */
export interface ContributeState {
  toolCount?: number;        // 上次评估时的 tool_use 次数（Layer 1 快速路径用）
  uniqueTools?: number;
  lastEvaluated?: number;    // 上次评估时间戳（ms）
  smartScore?: number;       // 上次算出的分数
  contributed: boolean;      // 用户已贡献（markContributed 设置）
  hinted?: boolean;          // 已提示过，去重
  sessionStartIso?: string;  // Phase 2：会话开始时间，用于检测 git commit
  hasGitCommit?: boolean;
  isKnowledgeGap?: boolean;
  friction?: SessionFriction;   // 缓存的摩擦明细，缓存命中时用来生成提示文案
  promptSummary?: string;       // 脱敏、压成单行的首条任务
  pendingHint?: string;         // 等待下一次 UserPromptSubmit 送达的提示
}
```

### 2.3 涉及的文件与路径

| 路径 | 内容 | 读写方 |
| --- | --- | --- |
| `~/.teamai/sessions/<sanitized-id>.json` | `ContributeState` | `getSessionPath`（`src/contribute-check.ts:120-128`） |
| `~/.teamai/sessions/<sanitized-id>-recall-cache.json` | 本会话 recall 命中统计 | `teamai recall` 写，`readRecallQuality` 读（`src/recall-quality.ts:38-46`） |
| `~/.teamai/dashboard/events.jsonl` | 本机所有会话的事件流（tool_use / prompt_submit / stop 等） | dashboard-collector 写，`readEvents()` 读（路径见 `contribute-check-e2e.test.ts:48` 等测试） |
| hook payload 里的 `transcript_path` | AI 工具自己的会话记录 | `scanTranscriptStop(..., { frictionOnly: true })` 只读扫描 |

`sanitizeSessionId` 把 `[a-zA-Z0-9._-]` 以外的字符全换成 `_`（`src/contribute-check.ts:78-80`）。注释给的原因：PID 兜底的 sessionId 形如 `pid-{pid}-{cwd}`，带 `/`，曾在 sessions 目录下建出嵌套子目录，而清理只扫顶层，永远回收不掉。

### 2.4 CONTRIBUTE_* 常量逐个解释

全部在 `src/types.ts:2010-2076`：

| 常量 | 值 | 作用 |
| --- | --- | --- |
| `CONTRIBUTE_BASE_THRESHOLD` | 15 | 双重身份：Layer 1 快速路径的"小会话"界线；以及提示的硬门槛，toolCount < 15 无论多少摩擦都不提示 |
| `CONTRIBUTE_SMART_THRESHOLD` | 20 | 摩擦分阈值，>= 20 才可能提示 |
| `CONTRIBUTE_INTERRUPT_WEIGHT` | 20 | 每次打断 +20 |
| `CONTRIBUTE_REJECT_WEIGHT` | 20 | 每次拒绝工具 +20 |
| `CONTRIBUTE_CORRECTION_WEIGHT` | 20 | 每次纠正 +20 |
| `CONTRIBUTE_TOOLERROR_TIERS` | `[{min:8,points:25},{min:5,points:18},{min:3,points:10}]` | 工具报错分档，取最高匹配档，不累加；< 3 次 0 分 |
| `CONTRIBUTE_SKILL_BONUS` | 5 | 本会话用过名为 `Skill` 的工具 +5 |
| `CONTRIBUTE_DIVERSITY_BONUS_MAX` | 5 | 工具多样性加分上限 |
| `CONTRIBUTE_FASTPATH_TTL_MS` | 5 分钟 | 去抖窗口：窗口内信任上次快照，超出必重读 events |
| `CONTRIBUTE_KNOWLEDGE_GAP_BONUS` | 20 | Phase 2：有 recall 但全部落空（hitCount=0）+20 |
| `CONTRIBUTE_LOW_QUALITY_BONUS` | 10 | Phase 2：有命中但最高分 < 5.0，+10 |
| `CONTRIBUTE_LOW_QUALITY_THRESHOLD` | 5.0 | "命中质量低"的分数线 |
| `CONTRIBUTE_GIT_COMMIT_DOWNWEIGHT` | 0 | Phase 2：会话内有 commit 且 recall 有命中时的扣分，当前为 0，即中性 |

`CONTRIBUTE_SESSIONS_DIR` 已删除（`src/types.ts:2078-2080` 注释，issue #374 P3），路径统一由 `getSessionPath()` 计算。

另外两个和 correction 相关的常量在 `src/types.ts:1902-1909`：`CORRECTION_WINDOW_MS = 60 * 1000`，以及内置纠正关键词表 `CORRECTION_KEYWORDS`（见 3.4）。

---

## 3. 沿着一次 Stop 调用逐函数走读

场景：你在 Claude Code 里让 AI 修一个 bug，AI 答完一轮，宿主触发 Stop hook，调度器（见第 1 篇）把事件分给注册表里的各个 handler。

### 3.1 注册：contribute-check 是前台 handler

`src/hook-handlers.ts:1170` 与 `:1196`：

```ts
{ event: 'stop', matcher: '*', handler: contributeCheckHandler, timeoutMs: FOREGROUND_HOOK_TIMEOUT_MS, gitOnly: true, requiresConfig: true },
// ...
{ event: 'prompt-submit', matcher: '*', handler: pendingHintHandler, timeoutMs: FOREGROUND_HOOK_TIMEOUT_MS, gitOnly: true, requiresConfig: true },
```

要点：

- 它没有 `background: true`，是前台 handler：它的返回值要写回宿主 stdout，变成 AI 能看到的上下文
- `requiresConfig: true`：当前目录没有 teamai 配置就不跑
- `gitOnly: true`：HTTP 团队（只读源）不跑，因为没地方提交分享（测试 `hook-handlers.test.ts` 的 `marks contribute-check, mr-hint, and votes-sync as gitOnly`）

### 3.2 contributeCheckHandler：先问"能不能提示"，再算分

`src/hook-handlers.ts:464-493`（删了部分注释）：

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

逐段解释：

1. 闸门：`contributeHintAllowed` 判断"此处允许提示吗"。注意传的是 payload 里的 cwd 推导出的作用域目录，而不是进程当前目录（注释：chdir 可能失败，闸门不能读到启动器所在目录；测试 `contribute-check handler asks the gate about the payload cwd, not the directory the process is in`）。
2. sessionId：`deriveSessionId(stdin, { includeCwd: true })` 和 dashboard-collector 的推导方式一致，保证"事件流里的 sessionId"和"状态文件名"对得上（测试 `contribute-check handler derives session id even when stdin.session_id is missing`）。
3. `transcript_path` 原样转发，用于实时扫描摩擦（测试 `contribute-check handler forwards transcript_path so friction is read live`）。
4. `stash = stopStdoutUnsupported(tool)`：这个工具的 Stop hook 能不能接住输出？不能就走暂存，见 3.8。
5. 有提示时用 `formatStopHookOutput` 按工具格式包装；`relayWhenHidden` 只在宿主不会自己展示时才让模型转述（Claude Code 自己会打印，不能再让模型复述，#719）。

### 3.3 闸门：contributeHintAllowed 与 isContributeHintEnabled

`src/skill-content.ts:180-195`：

```ts
export async function contributeHintAllowed(cwd?: string): Promise<boolean> {
  const { isContributeHintEnabled } = await import('./types.js');
  let gate: ShareGate;
  try {
    gate = await shareGate(cwd);
  } catch (e) {
    log.debug(`share gate failed, reminder withheld: ${e instanceof Error ? e.message : String(e)}`);
    return false;
  }
  if (gate.block) return false;
  return gate.config
    ? isContributeHintEnabled(gate.config.localConfig, gate.config.teamConfig)
    : false;
}
```

逻辑：提示的目的地是 `share` skill，所以凡是 `shareGate` 会拒绝的地方（配置读不出、recall 关闭、只读 HTTP 源等）都不提示，否则就是"把人引到一个会说不的命令"。闸门自身异常也只是不提示，不让 Stop 失败。

开关优先级在 `src/types.ts:281-289`：

```ts
export function isContributeHintEnabled(
  localConfig: { contributeHintEnabled?: boolean },
  teamConfig: { sharing?: { contributeHint?: { enabled?: boolean } } },
  env: NodeJS.ProcessEnv = process.env,
): boolean {
  if (env.TEAMAI_CONTRIBUTE_HINT_DISABLED === '1') return false;
  if (localConfig.contributeHintEnabled !== undefined) return localConfig.contributeHintEnabled;
  return teamConfig.sharing?.contributeHint?.enabled ?? true;
}
```

| 优先级 | 来源 | 说明 |
| --- | --- | --- |
| 1 | 环境变量 `TEAMAI_CONTRIBUTE_HINT_DISABLED=1` | 一票否决 |
| 2 | 个人配置 `contributeHintEnabled`（`src/types.ts:831`） | 可以覆盖团队设置，包括在团队关掉时重新打开 |
| 3 | 团队配置 `sharing.contributeHint.enabled`（`src/types.ts:124-131`） | 关掉提示不影响 Stop 的其他功能 |
| 4 | 默认 | `true` |

对应测试：`contribute-check handler stays silent when the team turned the hint off`、`contribute-check handler honors a member override that re-enables the hint`、`contribute-check handler obeys TEAMAI_CONTRIBUTE_HINT_DISABLED=1`、`contribute-check handler stays silent while recall is off, since \`teamai skill get share\` would refuse`。

### 3.4 contributeCheckForSession 第一段：短路与两层缓存

`src/contribute-check.ts:509-540`：

```ts
export async function contributeCheckForSession(
  sessionId: string,
  cwd?: string,
  transcriptPath?: string,
  stashInsteadOfReturn = false,
): Promise<{ hint: string | null }> {
  const state = await readContributeState(sessionId);
  const now = Date.now();

  if (state.contributed) {
    return { hint: null };
  }
  if (state.hinted) {
    log.debug(`contribute-check: hint already emitted for ${sessionId.slice(0, 16)}, skipping`);
    return { hint: null };
  }

  const debounceFresh =
    state.lastEvaluated !== undefined && now - state.lastEvaluated < CONTRIBUTE_FASTPATH_TTL_MS;

  if (
    debounceFresh &&
    state.toolCount !== undefined &&
    state.toolCount < CONTRIBUTE_BASE_THRESHOLD
  ) {
    log.debug(`contribute-check: fast-path skip (toolCount ${state.toolCount} < ${CONTRIBUTE_BASE_THRESHOLD}, debounce fresh)`);
    return { hint: null };
  }
```

- 短路：已贡献或已提示过，直接返回，不读任何事件
- Layer 1 快速路径：上次评估距今不到 5 分钟、且当时 toolCount < 15，说明是个刚评估过的小会话，连 events.jsonl 都不读。注意它是"短去抖"而非长期压制：超过 5 分钟一定重新评估（测试 `fast-path debounce: low-toolCount snapshot older than 5min → re-evaluate (regression)`）

接着是 Layer 2（`src/contribute-check.ts:551-592`，节选）：

```ts
  const cachedContextAvailable =
    debounceFresh
    && state.smartScore !== undefined
    && state.toolCount !== undefined
    && state.friction !== undefined;

  if (cachedContextAvailable) {
    score = state.smartScore!;
    toolCount = state.toolCount!;
    friction = state.friction!;
    // ...
    needsPersist = false;
  } else {
    const allEvents = await readEvents();
    const sessionEvents = allEvents.filter((e) => e.sessionId === sessionId);
    if (transcriptPath) {
      const scan = await scanTranscriptStop(transcriptPath, { frictionOnly: true });
      friction = extractFriction(sessionEvents, sessionId, {
        interrupt: scan.interrupt,
        toolReject: scan.toolReject,
        toolError: scan.toolError,
      });
    } else {
      friction = extractFriction(sessionEvents, sessionId);
    }
    promptSummary = extractPromptSummary(sessionEvents);
    score = computeSmartScore(sessionEvents, friction);
    toolCount = countToolUseEvents(sessionEvents);
    uniqueTools = countUniqueTools(sessionEvents);
    needsPersist = true;
    if (sessionEvents.length > 0) {
      sessionStartIso = sessionEvents[0].timestamp;
    }
    // ...
  }
```

- 缓存命中要求 friction 也在：旧版状态文件没有 friction，会被当成未命中并迁移（测试 `M3: legacy cache missing friction → falls back to cache miss and migrates state`）；被篡改成非法值的 friction 也会被 `parseSessionFriction` 拒绝（`src/contribute-check.ts:89-102`）
- 未命中时：读 `~/.teamai/dashboard/events.jsonl` 全量，按 sessionId 过滤；有 transcript 就实时扫描
- `toolCount` 只数 `type === 'tool_use'` 的事件（`countToolUseEvents`，`src/contribute-check.ts:371-373`）
- 会话开始时间取本会话第一条事件的 timestamp，供 Phase 2 查 git commit

### 3.5 extractFriction：四个信号分别从哪来

`src/contribute-check.ts:395-417`：

```ts
function extractFriction(
  events: DashboardEvent[],
  sessionId: string,
  transcriptFriction?: { interrupt: number; toolReject: number; toolError: number },
): SessionFriction {
  let interrupt = 0;
  let toolReject = 0;
  let toolError = 0;
  if (transcriptFriction) {
    ({ interrupt, toolReject, toolError } = transcriptFriction);
  } else {
    for (const e of events) {
      if (e.type === 'stop' && e.interventions) {
        interrupt = e.interventions.interrupt;
        toolReject = e.interventions.toolReject;
        toolError = e.interventions.toolError ?? 0;
      }
    }
  }
  const correction = aggregateSessionMetrics(events).get(sessionId)?.correction ?? 0;
  return { interrupt, toolReject, correction, toolError };
}
```

为什么优先扫 transcript：注释（`:383-391`）说，interrupt / toolReject / toolError 本来记在最新 Stop 事件的 `interventions` 快照上，但那条 Stop 事件是由脱离宿主的后台进程异步追加的，contribute-check（前台）运行时它可能还没写进 events.jsonl。直接扫 transcript 消除了这个跨进程竞争。没有 transcript 时退回"最新一条 Stop 快照"（快照是累计值，取最后一条即可）。对应测试 `race fix: reads friction from transcript when Stop event interventions are absent` 与 `without transcriptPath, still falls back to events Stop interventions (backward compat)`。

correction 不在任何单条事件上，只能看事件序列，所以复用 `aggregateSessionMetrics`。

### 3.6 correction 到底怎么识别：关键词 + stop→prompt_submit 时间窗

答案是两者都要：时间上紧跟 Stop，内容上含纠正关键词。分两步完成。

第一步，在写入事件时打标。`src/dashboard-collector.ts:1287-1301`（节选）：

```ts
  if (eventType === 'prompt_submit' && typeof hookData.prompt === 'string') {
    const human = stripInjectedPrompt(hookData.prompt);
    if (!human) return null;
    event.correction = isCorrectionPrompt(human, options?.correctionKeywords);
    if (!isCopilot) event.promptSummary = redactWithEnv(human).slice(0, 200);
  }
```

注释解释为什么在这里判：只有 hook 知道这条 prompt 属于哪个团队（团队可以在 `sharing.intervention.correctionKeywords` 追加关键词），而 events.jsonl 是整台机器共用的；并且要在截断前对完整 prompt 判断。Copilot 不保存 prompt 摘要，但保留 correction 布尔值。

关键词表 `src/types.ts:1904-1909`：

```ts
export const CORRECTION_KEYWORDS = [
  '不对', '不是', '错了', '错误', '重来', '重新', '撤销', '回退', '别这样', '不要',
  'wrong', 'redo', 'undo', 'revert', 'mistake', 'instead', "don't", "that's not", 'not what',
  '違う', 'ちがう', 'そうじゃな', 'そうではな', 'やり直', 'やりなおし', '間違って', '間違え', '勝手に', '戻して',
];
```

匹配规则（`src/dashboard-collector.ts:1150-1178`）：中日韩文字做子串匹配；有空格分词的语言做整词匹配，所以 `undo` 不会命中 "segundo" 或 "test_undo"。

第二步，聚合时看时间窗。`src/dashboard-collector.ts:2140-2167`（节选）：

```ts
    if (event.type === 'stop') {
      // ...
      lastStopAt.set(event.sessionId, new Date(event.timestamp).getTime());
    } else if (event.type === 'prompt_submit') {
      // ...
      const stopAt = lastStopAt.get(event.sessionId);
      if (stopAt !== undefined) {
        const gap = new Date(event.timestamp).getTime() - stopAt;
        const isCorrection = event.correction ?? isCorrectionPrompt(event.promptSummary);
        if (gap >= 0 && gap <= CORRECTION_WINDOW_MS && isCorrection) {
          m.correction++;
          // ...
        }
        lastStopAt.delete(event.sessionId);
      }
    }
```

- 条件：同会话、在某次 Stop 之后 0 到 60 秒内（`CORRECTION_WINDOW_MS`）、且被标为纠正
- 每个 Stop 只能被紧随的第一条 prompt "消费"一次：之后的 prompt 视为新任务
- 旧事件没有 `correction` 字段时，退回用内置关键词表判断 `promptSummary`

所以"AI 停下 30 秒后，用户输入'不对，应该改另一个文件'"会记 1 次 correction；同样的话在 Stop 后 5 分钟才说，不算。

### 3.7 computeSmartScore 与 toolErrorPoints：打分公式

`src/contribute-check.ts:216-222` 与 `:242-279`（节选）：

```ts
function toolErrorPoints(toolError: number): number {
  for (const tier of CONTRIBUTE_TOOLERROR_TIERS) {
    if (toolError >= tier.min) return tier.points;
  }
  return 0;
}

export function computeSmartScore(events: DashboardEvent[], friction?: SessionFriction): number {
  if (events.length === 0) return 0;
  // ... 统计 tool_use 事件：toolNames（去重）、totalToolCalls、hasSkills（toolName === 'Skill'）
  let score = 0;
  if (friction) {
    score += friction.interrupt * CONTRIBUTE_INTERRUPT_WEIGHT;
    score += friction.toolReject * CONTRIBUTE_REJECT_WEIGHT;
    score += friction.correction * CONTRIBUTE_CORRECTION_WEIGHT;
    score += toolErrorPoints(friction.toolError);
  }
  if (hasSkills) {
    score += CONTRIBUTE_SKILL_BONUS;
  }
  if (totalToolCalls > 0) {
    const diversity = toolNames.size / Math.min(totalToolCalls, 10);
    score += Math.min(Math.round(diversity * CONTRIBUTE_DIVERSITY_BONUS_MAX), CONTRIBUTE_DIVERSITY_BONUS_MAX);
  }
  return score;
}
```

写成公式：

```text
score = 20 x interrupt + 20 x toolReject + 20 x correction
      + tier(toolError)                      // >=8:25, >=5:18, >=3:10, 否则 0
      + (用过 Skill ? 5 : 0)
      + min(round(去重工具数 / min(工具调用数, 10) x 5), 5)
```

`CONTRIBUTE_TOOLERROR_TIERS` 按 min 从大到小排列，所以循环找到的第一个就是最高匹配档。

### 3.8 一个完整的数值演算

假设某会话的事件与扫描结果是：

| 输入 | 值 |
| --- | --- |
| tool_use 事件 | 20 次，工具名 Bash / Read / Edit / Grep（4 种），没用 Skill |
| transcript 扫描 | interrupt 0、toolReject 0、toolError 4 |
| 事件序列 | 某次 Stop 后 30 秒，用户输入"不对，应该改 config 文件" -> correction 1 |
| recall-cache | hitCount 0、missCount 2 |
| git | 会话期间无 commit |

第一阶段 `computeSmartScore`：

```text
correction   1 x 20                        = 20
toolError    4 次 -> 命中 min:3 档          = 10
Skill        未使用                         =  0
多样性       4 / min(20,10) = 0.4
             round(0.4 x 5) = 2, min(2,5)   =  2
-----------------------------------------------
小计                                         32
```

第二阶段 `applyPhase2Adjustments`（3.9）：recall 2 次全落空 -> +20，`isKnowledgeGap = true`，得 52。

判定：`52 >= 20` 且 `toolCount 20 >= 15` -> 提示，文案走"知识缺口"版本。

对比两种变体：

- 同样的摩擦，但会话只有 12 次工具调用：分数仍是 52，却被硬门槛拦下，不提示
- 50 次工具调用、5 种工具、用过 Skill、零摩擦：`5 + min(round(5/10 x 5), 5) = 5 + 3 = 8`，远低于 20（测试 `scores low for a large but frictionless session (scale never triggers alone)`）

### 3.9 applyPhase2Adjustments：知识缺口与 git commit

`src/contribute-check.ts:307-338`：

```ts
  const recallQuality = readRecallQuality(sessionId);

  if (recallQuality) {
    const totalRecalls = recallQuality.hitCount + recallQuality.missCount;
    if (totalRecalls > 0 && recallQuality.hitCount === 0) {
      score += CONTRIBUTE_KNOWLEDGE_GAP_BONUS;
      isKnowledgeGap = true;
    } else if (recallQuality.topScore < CONTRIBUTE_LOW_QUALITY_THRESHOLD && recallQuality.hitCount > 0) {
      score += CONTRIBUTE_LOW_QUALITY_BONUS;
      isKnowledgeGap = true;
    }
  }

  if (cwd && sessionStartIso) {
    gitCommitDetected = hasGitCommitInSession(cwd, sessionStartIso);
    if (gitCommitDetected && recallQuality && recallQuality.hitCount > 0) {
      score -= CONTRIBUTE_GIT_COMMIT_DOWNWEIGHT;
    }
  }

  return { score: Math.max(0, score), isKnowledgeGap, hasGitCommit: gitCommitDetected };
```

recall 质量数据来自 `src/recall-quality.ts`：每次 `teamai recall`（手动或 `teamai-recall` 子 agent）搜索后，`recordRecallQuality` 往 `~/.teamai/sessions/<id>-recall-cache.json` 累加 `hitCount`（有结果）/ `missCount`（零结果）/ `topScore`（历史最高分）。`readRecallQuality` 在缓存超过 24 小时或一次 recall 都没有时返回 null（`src/recall-quality.ts:56-57`、`:125`），此时不加分。

判定规则：

| 情况 | 加分 | isKnowledgeGap |
| --- | --- | --- |
| 本会话没 recall 过 | 0 | false |
| recall 过，全部零结果 | +20 | true |
| 有命中，但历史最高分 < 5.0 | +10 | true |
| 有命中且最高分 >= 5.0 | 0 | false |

注意：知识缺口加分只是"加分"，不绕过 15 次工具调用的硬门槛。

`hasGitCommitInSession`（`:287-301`）先用正则校验 ISO 时间格式（防止拼进命令行的参数被注入），再用 `execFileSync('git', ['log', '--oneline', '--after=...', '--format=%H', '-1'])` 查，3 秒超时，非 git 目录或出错一律返回 false。由于 `CONTRIBUTE_GIT_COMMIT_DOWNWEIGHT = 0`，它目前只影响状态里的 `hasGitCommit` 标记，不改分数。

### 3.10 判定、生成文案、唯一一次写盘

`src/contribute-check.ts:605-650`（节选）：

```ts
  const willHint = score >= CONTRIBUTE_SMART_THRESHOLD && toolCount >= CONTRIBUTE_BASE_THRESHOLD;
  const hintText = willHint ? buildHint({ friction, promptSummary, isKnowledgeGap }) : null;

  if (needsPersist || willHint) {
    const latest = await readContributeState(sessionId);
    const updated: ContributeState = {
      ...latest,
      smartScore: score,
      toolCount,
      // ...
      friction,
      promptSummary: promptSummary ?? latest.promptSummary,
    };
    if (latest.hinted || willHint) {
      updated.hinted = true;
    }
    if (willHint && stashInsteadOfReturn) {
      updated.pendingHint = hintText ? RELAY_TO_USER_PREFIX + hintText : undefined;
    }
    await writeContributeState(sessionId, updated);
  }

  if (!willHint) {
    return { hint: null };
  }
  return { hint: stashInsteadOfReturn ? null : hintText };
```

- 两个条件同时满足才提示：分数 >= 20，toolCount >= 15
- 写盘前重新读一次最新状态再合并（`...latest`）：评估期间用户可能刚跑完分享、`contributed` 被设为 true，直接覆盖会把它抹掉（测试 `M2: contributed=true set during evaluation is NOT clobbered by the score write`）
- 每次调用最多写一次（测试 `M1: cache miss + high score performs exactly ONE writeContributeState (not two)`）；缓存命中且分数低时一次都不写（`M1: cache hit + low score performs ZERO writes`）
- 暂存模式下，提示放进 `pendingHint` 并加上 `RELAY_TO_USER_PREFIX`（"把下面的话原样告诉用户……"，`src/utils/hook-output.ts:9-10`），因为 UserPromptSubmit 的上下文宿主不展示，只能请模型转述；同时返回 null，保证同一提示不会两条路都发

### 3.11 buildHint：分数怎么变成一句人话

`src/contribute-check.ts:461-478`（节选）：

```ts
function buildHint({ friction, promptSummary, isKnowledgeGap }: HintContext): string {
  const reasons = formatFrictionReasons(friction).join(', ');
  let headline: string;
  if (isKnowledgeGap) {
    headline = reasons
      ? `[teamai] The current task is not covered by the team knowledge base, and this session had signs of friction: ${reasons}.`
      : '[teamai] The current task is not covered by the team knowledge base.';
  } else {
    headline = reasons
      ? `[teamai] This session may contain a problem worth documenting: ${reasons}.`
      : '[teamai] This session may contain a problem worth documenting.';
  }
  const task = promptSummary ? `\n\nTask: ${promptSummary}` : '';
  // ... action：建议运行 `/teamai share what this session taught me`（或 `teamai skill get share`）
  return `${headline}${task}\n\n${action}`;
}
```

`formatFrictionReasons`（`:436-452`）只列非零信号，例如 "you corrected the AI once, the AI retried failing tools 4 times"。3.8 的例子生成的提示大致是：

```text
[teamai] The current task is not covered by the team knowledge base, and this session had signs of friction: you corrected the AI once, the AI retried failing tools 4 times.

Task: <首条 prompt 的脱敏摘要>

Consider running `/teamai share what this session taught me` to summarize what you learned, share it with your team, and fill the knowledge gap (or run `teamai skill get share`).
```

`Task:` 后面是首条带摘要的 prompt，经过 `normalizePromptSummary`（`:105-118`）：`redactWithEnv` 脱敏、去换行与控制字符、截到 160 字符并避免切断代理对。

### 3.12 pending hint：为什么有的工具要等下一轮

`src/utils/tool-names.ts:56-97` 维护白名单 `STOP_STDOUT_TOOLS`（claude、claude-internal、tclaude、cursor、copilot、qoder、qoder-cn、zcode、omp、pi、opencode、dsh）。注释说 CodeBuddy/WorkBuddy 忽略 Stop 的 stdout，Codex 和 Muse Code 会拒绝 Stop 的 additionalContext。设计是"白名单"而非"黑名单"：不在名单里的工具只是晚一轮收到提示，而误放进名单的工具会彻底丢提示（#719 里 Codex 就因此丢过两次），所以新工具默认走暂存。

下一次用户提交 prompt 时，`pendingHintHandler` 取出并注入（`src/hook-handlers.ts:496-529`，节选）：

```ts
const pendingHintHandler: HookHandler = {
  name: 'pending-hint',
  async execute(stdin, tool) {
    const { stopStdoutUnsupported } = await import('./utils/tool-names.js');
    if (!stopStdoutUnsupported(tool)) return null;
    const sessionId = deriveSessionId(stdin, { includeCwd: true });
    const pending = await import('./contribute-check.js');
    const stashed = await pending.takePendingHint(sessionId);
    // ...
    const hint = (await contributeHintAllowed(await hookScopeDir(stdin, tool))) ? stashed : null;
    if (!hint) return null;
    return JSON.stringify({
      hookSpecificOutput: { hookEventName: 'UserPromptSubmit', additionalContext: hint },
    });
  },
};
```

`takePendingHint`（`src/contribute-check.ts:660-667`）：

```ts
export async function takePendingHint(sessionId: string): Promise<string | null> {
  const state = await readContributeState(sessionId);
  if (!state.pendingHint) return null;
  const hint = state.pendingHint;
  await writeContributeState(sessionId, { ...state, pendingHint: undefined });
  return state.contributed ? null : hint;
}
```

四个细节：

- 先消费、后判开关：注释说，这样团队关掉提示期间暂存的旧提示，不会在重新打开后冒出来（测试 `pending-hint handler drops (consumes but hides) a stashed hint when the team turned the hint off`）
- 清除 `pendingHint` 时保留 `hinted`，一会话一提示依然成立（测试 `takePendingHint clears pendingHint but preserves other state (e.g. hinted)`）
- 若用户在暂存后已经贡献，丢弃过期提示（测试 `takePendingHint drops the nudge (but still clears it) when already contributed`）
- 前提是 Stop 和下一次 UserPromptSubmit 带同一个 `session_id`；若工具不给 session_id，PID+cwd 兜底在两个 hook 进程间可能不同，暂存就会成为孤儿（`src/hook-handlers.ts:502-508` 注释，best-effort）

### 3.13 状态文件的读、写、清理与标记

- `readContributeState`（`:138-163`）：逐字段做类型校验，类型不对就当 undefined；文件不存在或 JSON 损坏返回 `{ contributed: false }`（测试 `returns defaults when session file contains corrupted JSON`）
- `writeContributeState`（`:166-181`）：写前再次净化 friction 与 promptSummary，写完顺手调用 `cleanupStaleSessions`；I/O 失败只记日志不抛错
- `cleanupStaleSessions`（`:194-214`）：删除 sessions 目录下 mtime 超过 24 小时的 `.json`，跳过当前会话（与 sanitize 后的文件名比较，测试 `cleanupStaleSessions skips the current session even when its filename was sanitized`）。注意它匹配所有 `.json`，所以超过 24 小时的 `-recall-cache.json` 也会被一并回收
- `markContributed`（`:725-729`）：读出状态、设 `contributed: true`、写回，保留 `hinted`（测试 `L4: markContributed preserves hinted flag`）。注释说它在分享推送成功后被调用

另有一个旧入口 `contributeCheck`（`:680-719`，即 `teamai contribute-check --stdin`）：老版本安装的 hook 仍会调用它，它自己读 STDIN、检查 teamai 是否在该目录配置（#748）、走同一个闸门，然后调用同一个 `contributeCheckForSession`。

---

## 4. 端到端流程图

```text
用户和 AI 对话中 ...
  PostToolUse / UserPromptSubmit / Stop 等事件
  └─> dashboard-collector 追加到 ~/.teamai/dashboard/events.jsonl
      （prompt_submit 写入时已用关键词打好 correction 标记）

AI 答完一轮 -> 宿主触发 Stop -> teamai hook-dispatch stop --tool <t>
  └─> contributeCheckHandler                         hook-handlers.ts:464
       ├─ contributeHintAllowed(scopeDir)?  否 ─────> null（不提示）
       │    env 开关 > 个人配置 > 团队配置 > 默认 true；shareGate 拒绝也不提示
       └─ contributeCheckForSession(id, cwd, transcript, stash)
            ├─ 读 ~/.teamai/sessions/<id>.json
            ├─ contributed 或 hinted？ ──────────────> null
            ├─ Layer 1：5 分钟内评估过且 toolCount<15 ─> null（不读事件）
            ├─ Layer 2：缓存完整且新鲜？
            │    是 -> 复用 smartScore / friction
            │    否 -> readEvents + 按 sessionId 过滤
            │          scanTranscriptStop -> interrupt / toolReject / toolError
            │          aggregateSessionMetrics -> correction（Stop 后 60s + 关键词）
            │          computeSmartScore -> 摩擦分 + 规模微调
            ├─ applyPhase2Adjustments：recall 全落空 +20 / 低质量 +10；git commit 记标记
            ├─ willHint = score>=20 && toolCount>=15
            ├─ 重读最新状态 -> 合并 -> 写一次（hinted=true；stash 时写 pendingHint）
            └─ 返回 hint / null
       ├─ Claude/Cursor 等（STOP_STDOUT_TOOLS）：hint -> formatStopHookOutput -> stdout
       └─ 其他工具：hint 已暂存，本轮返回 null

用户下一次提交 prompt -> hook-dispatch prompt-submit
  └─> pendingHintHandler（仅 stdout 不可用的工具）
       takePendingHint：取出并清空 pendingHint（contributed 则丢弃）
       闸门仍开 -> additionalContext 注入（带"原样转告用户"前缀）

用户运行 /teamai share ... 分享成功 -> markContributed -> contributed=true
```

---

## 5. 常见坑与边界情况

| 现象 | 原因 | 出处 |
| --- | --- | --- |
| 明明被纠正过却没提示 | 会话 tool_use 不足 15 次，硬门槛拦下 | `src/contribute-check.ts:607` |
| "不对"说晚了不算 correction | 必须在 Stop 后 60 秒内，且只算 Stop 后的第一条 prompt | `src/dashboard-collector.ts:2151-2166` |
| 英文 `undo` 没在 "test_undo" 中命中 | 有空格的语言按整词匹配 | `src/dashboard-collector.ts:1153-1168` |
| 提示只出现一次 | `hinted=true` 后永久去重，直到 24 小时后状态文件被清理 | `:521`、`:183` |
| 工具报错 2 次不加分 | 最低档 `min:3` | `src/types.ts:2048-2052` |
| interrupt 为 0 但实际按过 ESC | 没有 transcript 路径时退回 Stop 快照，而快照可能还没落盘 | `:383-391` |
| CodeBuddy 等工具提示晚一轮 | Stop stdout 不被处理，改为下一次 prompt-submit 注入 | `src/utils/tool-names.ts:56-72` |
| 暂存的提示丢了 | 工具不给 `session_id`，PID+cwd 兜底在两进程间不同 | `src/hook-handlers.ts:502-508` |
| 关掉提示后又打开，旧提示没出现 | pending-hint 总是先消费再判开关 | `src/hook-handlers.ts:511-519` |
| 没配 teamai 的目录不提示 | `requiresConfig`；旧入口也检查（#748） | `:691-699` |
| recall 缓存超过 24 小时 | `readRecallQuality` 视为无数据，不加知识缺口分 | `src/recall-quality.ts:56-57` |

---

## 6. 动手验证

只读命令（需要你本机实际用过 teamai；路径来自源码）：

```bash
# 看最近的会话状态文件（ContributeState）
ls -lt ~/.teamai/sessions/ | head
cat ~/.teamai/sessions/<某个会话>.json

# 看某会话的 recall 质量缓存
cat ~/.teamai/sessions/<某个会话>-recall-cache.json

# 看事件流里被打了 correction 标记的 prompt
grep '"correction":true' ~/.teamai/dashboard/events.jsonl | tail -3
```

在仓库里读测试用例（运行测试会创建临时文件，本笔记只建议阅读；若要运行可用 `npx vitest run src/__tests__/contribute-check.test.ts`）：

| 测试文件 | 推荐用例 |
| --- | --- |
| `src/__tests__/contribute-check.test.ts` | `a single correction lands at/above threshold`、`tool errors score on a gradient (more struggle → more points)`、`fast-path: low toolCount + fresh cache → no hint, no events read, state untouched`、`race fix: reads friction from transcript when Stop event interventions are absent`、`M2: contributed=true set during evaluation is NOT clobbered by the score write`、`takePendingHint returns a stashed hint then clears it` |
| `src/__tests__/contribute-check-phase2.test.ts` | `adds KNOWLEDGE_GAP_BONUS when all recalls missed`、`adds LOW_QUALITY_BONUS when top score below threshold`、`score cannot go below 0 after adjustments` |
| `src/__tests__/contribute-check-e2e.test.ts` | `outputs contextual, sanitized hint JSON for a rich session that exceeds threshold`、`standalone Codex Stop queues the hint without emitting incompatible JSON`、`stays silent where teamai is not set up (#748)` |
| `src/__tests__/hook-handlers.test.ts` | `contribute-check handler forwards transcript_path so friction is read live`、`contribute-check handler obeys TEAMAI_CONTRIBUTE_HINT_DISABLED=1`、`pending-hint handler drops (consumes but hides) a stashed hint when the team turned the hint off` |

---

## 7. 自测问题

<details>
<summary>1. 一个会话调用了 80 次工具、用了 Skill、零摩擦，会被提示吗？</summary>

不会。规模加分最多 5（Skill）+ 5（多样性）= 10，低于阈值 20。
</details>

<details>
<summary>2. correction 是靠关键词还是靠时间判断？</summary>

两者都要：prompt 写入事件时按关键词（内置表 + 团队 `correctionKeywords`）打 `correction` 标记；聚合时还要求它是某次 Stop 之后 60 秒内的第一条 prompt。
</details>

<details>
<summary>3. 只有 10 次工具调用、但用户拒绝了 2 次工具，分数 40，会提示吗？</summary>

不会。`willHint` 要求 `toolCount >= 15`，硬门槛独立于分数。
</details>

<details>
<summary>4. 为什么 interrupt 优先从 transcript 读，而不是 events.jsonl？</summary>

最新的 Stop 事件由后台进程异步写入，前台的 contribute-check 运行时可能还没写进去；直接扫 transcript 避免竞争。
</details>

<details>
<summary>5. CodeBuddy 用户什么时候看到提示？</summary>

Stop 时提示被写入状态文件的 `pendingHint`；用户下一次提交 prompt 时由 `pending-hint` handler 作为 additionalContext 注入，并请模型原样转告用户。
</details>

---

## 8. 导航

- 上一步：[01-hook-layer.md](./01-hook-layer.md)（hook 怎么进到 teamai）
- 下一步：[03-share-skill.md](./03-share-skill.md)（用户收到提示后，share skill 怎么写出一篇经验）
- 索引：[README.md](./README.md)

---

## 9. 未逐行核实

- `scanTranscriptStop`（`src/dashboard-collector.ts:192` 起）内部如何从各工具 transcript 中识别 interrupt / toolReject / toolError，本文只读了函数签名，没有逐行看
- `shareGate` 的具体拒绝条件（recall 关闭、HTTP 只读源、配置不可读等）是根据 `contributeHintAllowed` 注释和 `hook-handlers.test.ts` 用例名归纳的，未逐行读 `shareGate` 实现
- `formatStopHookOutput`、`relayWhenHidden` 对各工具的具体输出格式未逐行核实
- `deriveSessionId`、`resolveHookCwd`、`hookScopeDir`、`stripInjectedPrompt`、`redactWithEnv` 的实现未读
- `readEvents()` 默认读取 `~/.teamai/dashboard/events.jsonl` 这一点来自多处测试中的路径，未读该函数本体
- `markContributed` 的调用方（注释称在分享推送成功后调用）未追踪到具体位置，见第 4 篇
- 3.11 的提示文案示例是按 `buildHint` / `formatFrictionReasons` 拼接规则推演的，未实际运行
- 总览笔记 `notes/knowledge-sedimentation.md` 写 correction 是"打断后带纠正意图的再次提问"，源码实际是"任意 Stop 后 60 秒内的首条纠正 prompt"，不要求先有 interrupt
