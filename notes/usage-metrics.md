# AI 使用效能与知识价值的量化统计：数据从哪来、怎么算、算了什么

> 面向小白。先给全景图，再沿着"采集 → 存储 → 重建 → 聚合 → 展示 → 团队汇总"逐层看代码；知识价值那条链路单独成章。
> 代码摘自本仓库 0.22.0 源码，标注 `文件:行号`，摘录时删减了部分注释，用 `// ...` 省略无关分支。
> 前置阅读（可选）：`notes/hook-dispatcher.md`。本文的数据**全部**由 hook 调度器里的 handler 顺手采集。

---

## 0. 一句话

teamai 不额外埋点，而是**复用每个 AI 工具的生命周期 hook**：会话开始、调用工具、提交 prompt、回复结束时，各追加一条事件到本机的 `events.jsonl`；回复结束（Stop）时再扫描一遍 AI 工具自己的 transcript 文件，拿到 token、费用、人工干预次数。看板通过**回放事件**（event sourcing）重建会话状态并计算指标；知识侧则用"召回计数 + 采纳计数"两个计数器，衡量每条团队知识到底有没有被用上。

---

## 1. 全景图：三条链路

```
                        AI 工具触发 hook（SessionStart / PostToolUse / UserPromptSubmit / Stop / SessionEnd）
                                                   │
                                     teamai hook-dispatch <event>
                     ┌─────────────────────────────┼──────────────────────────────┐
                     ▼                             ▼                              ▼
          dashboard-report handler        recall（AI 主动检索知识）          votes-sync handler（Stop）
                     │                             │                              │
          parseHookEvent()                 incrementRecalled()             creditAdoptedDocs()
          Stop 时扫描 transcript           recalled_count +1               "召回后 24h 内真的打开了"
                     │                             │                       → incrementUpvoted()
                     ▼                             └────────────┬─────────────────┘
       ~/.teamai/dashboard/events.jsonl                         ▼
                     │                           votes/<user>.yaml（本地 → 同步到团队仓库）
   ┌─────────────────┼──────────────────┐                       │
   ▼                 ▼                  ▼                       ▼
rebuildSessions  aggregateSession   aggregateDaily        buildVizData()
（会话状态）      Metrics（会话指标） Sessions（按天）      索引 × 全员投票
   │                 │                  │                       │
   └──── A. 本地实时看板 teamai dashboard（SSE）────┘          B. 知识库报告（SVG）
                                        │
                     team-push：增量写入 teamai-reports 分支 stats/<user>.yaml
                                        │
                              C. 团队汇总（digest / stats）
```

| 链路 | 回答的问题 | 核心文件 |
| --- | --- | --- |
| A. 会话效能 | 用 AI 写代码顺不顺？花了多少钱？ | `dashboard-collector.ts`、`session-trends.ts`、`model-pricing.ts`、`dashboard.ts` |
| B. 知识价值 | 团队沉淀的知识有没有被用上？ | `recall.ts`、`recall-adoption.ts`、`votes.ts`、`viz.ts`、`viz-render.ts` |
| C. 团队汇总 | 整个团队的趋势如何？ | `team-push.ts`、`digest.ts`、`stats.ts` |

---

## 2. 采集层：一次 hook 变成一条事件

### 2.1 入口 handler

`src/hook-handlers.ts:326`：

```ts
const dashboardReportHandler: HookHandler = {
  name: 'dashboard-report',
  async execute(stdin, tool, config) {
    if (!config) return null;      // 没装 teamai 的目录不记录（注册时还标了 requiresConfig）
    const { parseHookEvent, appendEvent, compactEvents, dataHomeKey, eventProjectAnchor, addGitStateAtStart } =
      await import('./dashboard-collector.js');
    const event = await parseHookEvent(JSON.stringify(stdin), tool, {
      correctionKeywords: await teamCorrectionKeywords(stdin, config), // 团队自定义的"纠正"关键词
      modelAliases: await userModelAliases(stdin),                     // 网关模型别名 → 真实模型名，用于计价
    });
    if (event) {
      event.dataHomeKey = await dataHomeKey(getDataHome(config));      // 归属到哪个 teamai 作用域
      const [projectAnchor] = await Promise.all([
        eventProjectAnchor(event.cwd, event.sessionId),                // 归属到哪个 git 仓库（worktree 共享）
        addGitStateAtStart(event),                                     // 仅 session_start：当时的 commit 和是否有改动
      ]);
      event.projectAnchor = projectAnchor;
      await appendEvent(event);
      compactEvents().catch(() => {});                                 // 顺手压缩，不阻塞
    }
    return null;                                                       // 纯副作用，不给宿主输出
  },
};
```

它在注册表里挂了 5 个事件：session-start、post-tool-use、prompt-submit（前台），stop、session-end（后台，因为 Stop 要扫描 transcript，可能比较慢）。

### 2.2 事件长什么样：`DashboardEvent`

`src/types.ts:1711` 起（只列关键字段）：

```ts
export type DashboardEventType =
  'session_start' | 'session_end' | 'tool_use' | 'prompt_submit' | 'stop' | 'process_exit';

export interface DashboardEvent {
  type: DashboardEventType;
  timestamp: string;            // ISO 时间
  sessionId: string;            // 优先用宿主给的 session_id，没有就用 PID+cwd 推导
  tool: string;                 // claude / cursor / codex ...
  cwd?: string;
  dataHomeKey?: string;         // 属于哪个 teamai 作用域（报表按它过滤）
  projectAnchor?: string;       // 属于哪个 git 仓库（worktree 删了也能归属）
  promptSummary?: string;       // 脱敏 + 截断到 200 字的 prompt
  correction?: boolean;         // 这条 prompt 是否是"纠正"
  toolName?: string;            // PostToolUse 的工具名（已归一化）
  monitorPid?: number;          // AI 工具主进程 PID（用来判断进程是否真的退出）
  gitAtStart?: HeadState;       // 会话开始时的 commit 和是否有改动
  stoppedOutput?: string;       // Stop 时 AI 的最后一段输出（截断）
  // —— 以下都只在 Stop（或 Copilot 的 SessionEnd）上出现，是对 transcript 的"全量快照" ——
  interventions?: { interrupt: number; toolReject: number; toolError?: number };
  tokens?: TokenUsage;          // input / output / cacheRead / cacheCreation
  tokenScope?: TokenSnapshotScope;
  prompts?: number;             // transcript 里真实的人类提问轮数
  requestMetrics?: RequestCostMetrics;
  requestDaily?: Record<string, RequestCostMetrics>;   // 按"每个请求自己的日期"分桶的费用
}
```

### 2.3 不同事件采集什么：`parseHookEvent`

`src/dashboard-collector.ts:1219`，按事件类型分支：

```ts
const eventType = mapEventType(hookEventName);   // SessionStart → session_start ...
const event: DashboardEvent = { type: eventType, timestamp, sessionId, tool, cwd };

// PostToolUse：只记工具名，并归一化（CodeBuddy 的 execute_command → Bash）
if (eventType === 'tool_use' && typeof hookData.tool_name === 'string') {
  event.toolName = normalizeToolName(hookData.tool_name);
}

// SessionStart：记录 AI 工具主进程 PID，供看板做存活检测
if (eventType === 'session_start') {
  event.monitorPid = resolveMonitorPid(process.ppid ?? process.pid);
}

// UserPromptSubmit：先去掉系统注入内容，再判断是否是纠正，最后脱敏截断
if (eventType === 'prompt_submit' && typeof hookData.prompt === 'string') {
  const human = stripInjectedPrompt(hookData.prompt);
  if (!human) return null;                                 // 纯注入内容（如后台任务通知）不算一轮提问
  event.correction = isCorrectionPrompt(human, options?.correctionKeywords);
  if (!isCopilot) event.promptSummary = redactWithEnv(human).slice(0, 200);
}

// Stop：读 transcript，做全量扫描
if (eventType === 'stop' && !isCopilot && typeof hookData.transcript_path === 'string') {
  event.stoppedOutput = await readLastAssistantOutput(hookData.transcript_path);
  const scan = await scanTranscriptStop(hookData.transcript_path, { tool, modelAliases: options?.modelAliases });
  if (scan.interrupt > 0 || scan.toolReject > 0 || scan.toolError > 0) event.interventions = { /* ... */ };
  if (/* 有 token */) event.tokens = scan.tokens;
  if (scan.prompts > 0) event.prompts = scan.prompts;
  if (scan.requestMetrics) event.requestMetrics = scan.requestMetrics;
  const records = scan.requestRecords ?? [];
  if (records.length) event.requestDaily = aggregateRequestDaily(records);   // 按请求日期分桶
  await reconcileRequestLog(records);                                        // 同时记一份请求明细 requests.jsonl
}
```

三个细节：

1. **纠正判断放在采集时做**：只有 hook 知道这条 prompt 属于哪个团队，也就知道该用哪组团队关键词。而且判断用的是完整 prompt，存下来的只是 200 字摘要。
2. **先脱敏再截断**（代码注释原话）：*"Redact before truncating so a secret that crosses the 200-character boundary cannot be partially leaked."* 如果先截断，一个刚好跨在第 200 字边界上的密钥，前半截就漏不掉脱敏、被原样存下来。
3. **Copilot 特殊处理**：它的会话日志里有 prompt、工具参数、鉴权信息，所以完全不存 prompt 和路径，只在 SessionEnd 时从日志尾部读取最终的 token 计数。

### 2.4 Stop 时扫描 transcript：人工干预怎么数

`dashboard-collector.ts:173` 的注释定义了口径，`:388` 是实现：

```ts
// interrupt：用户消息以 "[Request interrupted by user" 开头 → 用户按了中断
if (item.text.startsWith(TRANSCRIPT_INTERRUPT_PREFIX)) interrupt++;

// tool_result 且 is_error=true：
else if (item?.type === 'tool_result' && item.is_error === true) {
  if (/* 内容是用户拒绝授权 */) toolReject++;   // 人拒绝了 AI 的工具调用
  else toolError++;                             // 工具真的执行失败（参数错、命令报错）
}
```

| 信号 | 含义 | 去向 |
| --- | --- | --- |
| `interrupt` | 用户中途打断 AI | 会话指标、"成功会话"判定、团队统计 |
| `toolReject` | 用户拒绝 AI 的工具调用 | 会话指标、团队统计 |
| `toolError` | 工具执行失败、AI 只能重试 | **只用于**判断"这次会话值不值得分享经验"，代码注释写明*不进* SessionMetrics 和团队统计 |
| `correction` | 用户回复了一句"不对，重来"之类 | **不从 transcript 来**，由事件序列推导（第 5 节） |

为什么用"全量快照"：每次 Stop 都从头扫描整个 transcript，得到截至当前的累计值。所以同一个会话 Stop 十次也不会重复累加，聚合时取最新一份就行。transcript 本身不会被压缩，所以即使对话被 compact 或者 resume，计数也不会丢。

### 2.5 费用估算：`model-pricing.ts`

扫描 transcript 时，每条 assistant 消息都带着模型名和 token 用量，交给 `estimateClaudeRequest`（`src/model-pricing.ts`）估算单次请求的费用：

```ts
export const PRICE_TABLE_VERSION = 'anthropic-2026-09-09';   // 价格表快照日期

// 正则匹配模型名 → 每百万 token 的美元单价
const RATES = [
  { match: /sonnet[-_ ]?4(?:[-_.]?(?:6|5))?/i, rates: { input: 3, output: 15, cacheRead: 0.3, cacheWrite: 3.75 } },
  { match: /haiku[-_ ]?4[-_.]?5/i,             rates: { input: 1, output: 5,  cacheRead: 0.1, cacheWrite: 1.25 } },
  // ... opus / 其他型号
];

export function estimateClaudeRequest(model, usage, aliases?): RequestCostMetrics | null {
  const resolved = aliases?.[model] ?? model;          // 公司网关的模型别名 → 真实模型名
  const entry = RATES.find(({ match }) => match.test(resolved));
  if (!entry) return null;                             // 认不出的模型：不计价，而不是当作免费
  const { rates } = entry;
  return {
    pricedRequests: 1,
    // 单价是"美元/百万 token"，token 数 × 单价 = 微美元（百万分之一美元）
    costMicros: Math.round(
      usage.input * rates.input + usage.output * rates.output
      + usage.cacheRead * rates.cacheRead + usage.cacheCreation * rates.cacheWrite,
    ),
    cacheReadTokens: usage.cacheRead,
    cacheEligibleInputTokens: usage.input + usage.cacheRead + usage.cacheCreation,
    priceVersion: PRICE_TABLE_VERSION,
  };
}
```

值得一提的设计：

- **整数微美元**：`costMicros` 是整数，避免浮点数累加的误差。
- **价格带版本号**：注释写明已经存下的每日费用**不会因为价格表更新而重算**，历史数据保持稳定，可以追溯。
- **缓存命中率不依赖计价**：`cacheReadTokens / cacheEligibleInputTokens` 直接来自 token 数。模型认不出、算不了钱，命中率照样能算（第 6 节还会提到）。
- **口径声明**：注释写着 *"Estimate standard first-party API token cost. Subscription and enterprise discounts are excluded."* 也就是说，这是按官方公开 API 标价的**估算**，不含订阅或企业折扣。

---

## 3. 存储层：一个追加写的 JSONL 文件

### 3.1 写入：加锁追加，抢不到锁就写旁路文件

`dashboard-collector.ts:1720`：

```ts
export async function appendEvent(event: DashboardEvent): Promise<void> {
  try {
    const eventsPath = getEventsPath();                    // ~/.teamai/dashboard/events.jsonl
    const line = JSON.stringify(event) + '\n';
    if (await withEventsLock(eventsPath, EVENTS_APPEND_LOCK_WAIT,
        () => fs.promises.appendFile(eventsPath, line, 'utf-8'))) {
      return;                                              // 正常路径：拿到锁，追加一行
    }
    // 锁被占用（比如正在压缩）：写到一个独立的旁路文件，等下一个持锁者合并进来（#804）
    const pendingId = randomUUID();
    const pendingPath = path.join(path.dirname(eventsPath), `${eventsPendingPrefix(eventsPath)}${pendingId}.jsonl`);
    const mode = await fs.promises.stat(eventsPath).then((s) => s.mode & 0o777, () => 0o600);  // 权限不比主文件宽
    await fs.promises.writeFile(pendingPath, JSON.stringify({ ...event, pendingId }) + '\n',
      { encoding: 'utf-8', flag: 'wx', mode });
  } catch (e) {
    log.error(`dashboard: failed to write event: ${(e as Error).message}`);
  }
}
```

为什么需要锁：多个 AI 工具、多个会话的 hook 进程会同时写这个文件，压缩（`compactEvents`）时还要整体重写它。拿不到锁的时候**不等、不丢**，换个旁路文件先写下来，用 `pendingId` 保证合并时不会写重。

### 3.2 读取：跳过坏行 + 跨工具去重

```ts
async function readEventsRaw(filePath) {
  for (const line of content.split('\n')) {
    try {
      const parsed = JSON.parse(trimmed);
      if (parsed.type && parsed.sessionId && parsed.timestamp) events.push(parsed);
    } catch { /* 坏行跳过，不影响其他行 */ }
  }
}
export async function readEvents(eventsPath?) {
  return dedupeEvents(await readEventsRaw(filePath)) /* ... 去掉 pendingId */;
}
```

**跨工具去重**（`dashboard-collector.ts:1786`）解决的是一个真实问题：Cursor 会兼容加载 `~/.claude/settings.json`，于是同一个动作会同时触发 `--tool claude` 和 `--tool cursor` 两条 hook，在**同一个 sessionId** 下写入两条几乎一样的事件。实测两者时间差 7~172ms。

```ts
const CROSS_TOOL_DEDUP_WINDOW_MS = 2000;

export function dedupeEvents(events) {
  // 按时间排序，以 (sessionId + 事件签名) 为键
  // 两条事件只有同时满足以下条件才合并：同会话、同类型、同内容签名、工具不同、相差 2 秒内
  if (prev.tool !== e.tool && gap <= CROSS_TOOL_DEDUP_WINDOW_MS) {
    const carrier = eventPayloadScore(e) > eventPayloadScore(prev) ? e : prev;   // 保留信息更丰富的那条
    result[idx] = { ...carrier, tool: preferTool(prev.tool, e.tool) };          // 工具名取更具体的（cursor 优先于 claude）
  }
}
```

`eventPayloadScore` 给字段打分（带 tokens 记 8 分、带 AI 输出记 4 分……），保证合并后留下的是信息最全的那条。

### 3.3 压缩

`compactEvents`（`:2271`）只保留仍然活跃的会话的事件（没结束、30 分钟内有活动，或者工具进程还在），防止文件无限增长。每次 dashboard-report 之后都会触发一次，用 `.catch(() => {})` 包住，不阻塞 hook。

---

## 4. 会话重建：用事件回放推出"现在每个会话在干什么"

### 4.1 状态机

`rebuildSessions`（`dashboard-collector.ts:1886`）是典型的 **event sourcing**：没有存"当前状态"，每次都从事件序列重新算出来。

```ts
export function rebuildSessions(events: DashboardEvent[]): DashboardSession[] {
  const sessions = new Map<string, DashboardSession>();
  for (const event of events) {
    let session = sessions.get(event.sessionId) ?? /* 新建，status: 'running' */;
    session.lastActivity = event.timestamp;
    switch (event.type) {
      case 'session_start': session.status = 'running'; session.monitorPid = event.monitorPid; break;
      case 'tool_use':      session.status = 'running'; session.lastTool = event.toolName; break;
      case 'prompt_submit': session.status = 'running'; session.prompts.push(event.promptSummary); break;
      case 'stop':
        // Stop 只代表"AI 回复完了"，用户还在会话里 → 等待输入，而不是结束
        session.status = 'waiting_for_input';
        session.stoppedOutput = event.stoppedOutput;
        break;
      case 'session_end':
      case 'process_exit':  session.status = 'stopped'; session.stoppedAt = event.timestamp; break;
    }
  }
  // 填入指标：唯一来源是 aggregateSessionMetrics（第 5 节）
  // 超时规则：
  //   stopped        → 再展示 30 秒后移除   DASHBOARD_STOPPED_DISPLAY_MS = 30s
  //   30 分钟无活动  → 移除                 DASHBOARD_STALE_TIMEOUT_MS   = 30min
  //   5 分钟无活动   → idle                 DASHBOARD_IDLE_TIMEOUT_MS    = 5min
  // 排序：活跃在前、已结束在后；组内按运行时长降序（让卡片位置稳定）
}
```

```
session_start ─▶ running ◀──── tool_use / prompt_submit
                    │                    ▲
                  stop                   │
                    ▼                    │
            waiting_for_input ───────────┘
                    │  5 分钟无事件
                    ▼
                  idle ── 30 分钟 ──▶ 不再显示
   session_end / process_exit ──▶ stopped ── 30 秒 ──▶ 不再显示
```

### 4.2 为什么需要 PID 存活检测

很多工具关窗口时**不会触发 SessionEnd**，只靠 hook 永远等不到"结束"。看板服务（`dashboard.ts:132`）每隔一段时间检查每个未结束会话的 `monitorPid`：

```ts
const checkPids = async () => {
  const sessions = rebuildSessions(await readEvents(eventsPath));
  for (const session of sessions) {
    if (session.status === 'stopped' || !session.monitorPid) continue;
    if (!isProcessAlive(session.monitorPid)) {
      await appendEvent({
        type: 'process_exit',                     // 由看板"补写"一条结束事件
        timestamp: new Date().toISOString(),
        sessionId: session.sessionId,
        processExitAfter: session.lastActivity,   // 标明针对的是哪一轮运行
        // ... 带上 dataHomeKey / projectAnchor，保证归属正确
      });
    }
  }
};
```

注意：这个结束事件也是**写进事件流**，而不是直接改内存状态。所以"事件是唯一事实来源"这个原则没有被打破。

---

## 5. 会话指标：`aggregateSessionMetrics`

`dashboard-collector.ts:2058`。看板和团队统计**共用这一个函数**，注释写的是 *"single source of truth: aggregate fold"*。

### 5.1 输出

```ts
export interface SessionMetrics {
  interrupt: number;     // 被打断次数
  toolReject: number;    // 被拒绝的工具调用次数
  correction: number;    // 纠正次数
  prompts: number;       // 人类提问轮数
  tokens: TokenUsage;    // 累计 token
  segments?: /* Codex 每个 rollout 的分段明细 */;
}
```

### 5.2 各指标的计算规则

**interrupt / toolReject：取最新一次 Stop 的快照**

```ts
if (event.type === 'stop' && event.interventions) {
  m.interrupt = event.interventions.interrupt;      // 直接覆盖，不是累加
  m.toolReject = event.interventions.toolReject;
}
```

**correction：由事件序列推导**

```ts
const CORRECTION_WINDOW_MS = 60 * 1000;             // types.ts:1902

if (event.type === 'stop') {
  lastStopAt.set(event.sessionId, Date.parse(event.timestamp));
} else if (event.type === 'prompt_submit') {
  const stopAt = lastStopAt.get(event.sessionId);
  if (stopAt !== undefined) {
    const gap = Date.parse(event.timestamp) - stopAt;
    const isCorrection = event.correction ?? isCorrectionPrompt(event.promptSummary);  // 老事件退回内置词表
    if (gap >= 0 && gap <= CORRECTION_WINDOW_MS && isCorrection) m.correction++;
    lastStopAt.delete(event.sessionId);             // 每个 Stop 只能被"消费"一次
  }
}
```

翻译一下：**AI 回复完后 60 秒内，用户发来的下一条消息命中了纠正关键词**，才算一次纠正。条件很严格：

- 必须紧跟在 Stop 之后：过了很久才发的消息更可能是新任务。
- 每个 Stop 只算一次：连发两条"不对"也只算一次。

内置关键词表在 `types.ts:1904`，覆盖中、英、日三种语言：

```ts
export const CORRECTION_KEYWORDS = [
  '不对', '不是', '错了', '错误', '重来', '重新', '撤销', '回退', '别这样', '不要',
  'wrong', 'redo', 'undo', 'revert', 'mistake', 'instead', "don't", "that's not", 'not what',
  '違う', 'ちがう', /* ... */
];
```

团队还可以通过 `sharing.intervention.correctionKeywords` 追加自己的关键词。

**prompts：两个来源取最大值**

```ts
// submitCount：实时的 prompt_submit 事件计数（及时，但事件文件会被压缩）
// stopPrompts：最近一次 Stop 从 transcript 数出的轮数（不怕压缩和 resume）
m.prompts = Math.max(submitCount.get(sid) ?? 0, stopPrompts.get(sid) ?? 0, rolloutPrompts);
```

第一次 Stop 之前只有实时计数可用，之后 transcript 快照更可靠。取 `max` 保证这个数只增不减。

**tokens：按"快照的作用域"分别处理**

```ts
if (event.tokenScope === 'session') {
  setLatestTokenSnapshot(sessionTokens, sid, event);          // 新版 Codex：线程级计数，本身就覆盖整个会话
} else if (event.tokenScope === 'transcript' && event.transcriptPath) {
  setLatestTokenSnapshot(segments, event.transcriptPath, event); // 老版 Codex：每个 rollout 文件各自从 0 计数
} else {
  setLatestTokenSnapshot(unscopedTokens, sid, event);         // Claude、CodeBuddy 等：取最新一次 Stop
}
// 汇总时：session 级直接用；transcript 级把各 rollout 的最新值相加；其他取最新
```

`setLatestTokenSnapshot` 比较的是**事件时间戳**而不是写入顺序。因为 Stop handler 跑在后台，两次扫描可能晚开始的先写完，追加顺序和真实顺序不一定一致。

---

## 6. 按天汇总与周环比：`session-trends.ts`

### 6.1 每个会话压成一个"日快照"

`aggregateDailySessions`（`session-trends.ts:56`）：

```ts
export function aggregateDailySessions(events): Map<string, DailySessionSnapshot> {
  const metrics = aggregateSessionMetrics(events);            // 复用第 5 节
  for (const [sessionId, own] of grouped) {
    const firstStop = own.find((e) => e.type === 'stop');
    if (!firstStop) continue;                                 // 一次 Stop 都没有的会话不计入
    // 活跃时长：相邻事件间隔累加，超过 5 分钟的空档不算（人离开了）
    for (let i = 1; i < own.length; i++) {
      const gap = Date.parse(own[i].timestamp) - Date.parse(own[i - 1].timestamp);
      if (gap >= 0 && gap <= DASHBOARD_IDLE_TIMEOUT_MS) durationMs += gap;
    }
    const hasError = own.some((e) => e.status === 'error');
    const corrected = metric.correction > 0 ? 1 : 0;
    result.set(sessionId, {
      date: firstStop.timestamp.slice(0, 10),                 // 归到"第一次 Stop 的那天"
      prompts: metric.prompts,
      durationMs,
      succeeded: !hasError && metric.interrupt === 0 && corrected === 0 ? 1 : 0,
      corrected,
      requestDaily,                                           // 费用按请求自己的日期分桶
      sessionCacheReadTokens: metric.tokens.cacheRead,
      sessionCacheEligibleTokens: metric.tokens.input + metric.tokens.cacheRead + metric.tokens.cacheCreation,
    });
  }
}
```

两个关键口径：

- **成功会话 = 没出错 && 没被打断 && 没被纠正**。注意 `toolReject`（拒绝工具调用）**不影响**成功判定。
- **活跃时长不是墙上时间**：相邻事件间隔超过 5 分钟的部分不计入，排除"开着窗口去开会"的情况。

### 6.2 增量计算：重复上报不重复计数

`computeDailyStatsDelta`（`session-trends.ts:255`）比较"这次的快照"和"上次已上报的快照"，只输出差值：

```ts
export function computeDailyStatsDelta(current, reported) {
  for (const [sessionId, snapshot] of current) {
    const previous = reported[sessionId];
    const date = previous?.date ?? snapshot.date;      // resume 后继续的工作，仍算在第一次 Stop 那天
    const bucket = delta[date] ?? emptyDaily();
    if (!previous) bucket.sessionsEnded += 1;          // 新会话才 +1
    // 成功数用有符号差值：会话可能从"成功"变成"失败"（resume 后又被打断），要能扣回去（#473）
    bucket.sessionsSucceeded += snapshot.succeeded - (previous?.succeeded ?? 0);
    bucket.promptTurns       += positiveDelta(snapshot.prompts, previous?.prompts);
    bucket.durationMs        += positiveDelta(snapshot.durationMs, previous?.durationMs);
    bucket.sessionsCorrected += positiveDelta(snapshot.corrected, previous?.corrected);
    // 缓存 token 也归到第一次 Stop 那天（不依赖计价）
    bucket.cacheReadTokens          += positiveDelta(snapshot.sessionCacheReadTokens ?? 0, prevCache.read);
    bucket.cacheEligibleInputTokens += positiveDelta(snapshot.sessionCacheEligibleTokens ?? 0, prevCache.eligible);
    // 费用按每个请求自己的日期入账
    for (const [requestDate, request] of Object.entries(snapshot.requestDaily)) {
      requestBucket.costMicros += positiveDelta(request.costMicros, previousRequest?.costMicros);
      // ...
    }
    nextReported[sessionId] = { ...snapshot, date };   // 下一次的"已上报"基线
  }
  return { delta, nextReported };
}
```

这是整个统计里最值得讲的设计：**快照 + 差值**。每个会话每次都生成完整快照，和上次上报的快照相减，只把增量累加到总数里。效果是：

- 同一个会话无论上报多少次，总数都是对的（幂等）；
- 会话状态可以回退，比如成功变失败，总数也能修正；
- 本地 `nextReported` 就是断点，下次从这里继续。

本地看板调用时传入的 `reported` 是 `{}`（`dashboard.ts:279`），也就是把本机所有会话当作新会话全量计算；团队上报时才传入真实的已上报基线（第 8 节）。

### 6.3 周环比

`summarizeTrendWindow`（`:356`）把每日数据切成"最近 7 天"和"再往前 7 天"两个窗口，`summarizePeriod`（`:333`）对每个窗口计算：

| 指标 | 公式 |
| --- | --- |
| `sessionsEnded` | 会话数 |
| `successRate` | 成功会话 ÷ 会话数 |
| `avgPrompts` | 提问轮数 ÷ 会话数 |
| `avgDurationMs` | 活跃时长 ÷ 会话数 |
| `avgRequestCostMicros` | 费用 ÷ **已计价的请求数** |
| `cacheReadShare` | 缓存读取 token ÷ 可缓存的输入 token |
| `correctionRate` | 被纠正会话数 ÷ 会话数 |

分母为 0 时返回 `null` 而不是 0，前端据此显示"无数据"，避免误导。

`summarizeSessionCosts`（`:377`）另外计算**平均每个会话的费用**，注释特别说明：没有任何已计价请求的会话**直接排除**，而不是当成 0 元会话，否则平均值会被拉低。

---

## 7. 展示层：本地看板 `teamai dashboard`

### 7.1 架构

`dashboard.ts:20` 自带的架构图：

```
events.jsonl ──fs.watch, stat each second──▶ rebuildSessions()
                                  │
                                  ▼
                           DashboardSession[]
                                  │
                  ┌───────────────┼───────────────┐
                  ▼               ▼               ▼
             GET /          GET /api/sessions  GET /events
             (HTML)         (JSON)             (SSE stream)
```

### 7.2 实时推送：fs.watch + 每秒兜底轮询 + 防抖

`dashboard.ts:79` 起：

```ts
const eventsStamp = () =>
  fs.promises.stat(eventsPath).then((s) => `${s.ino}:${s.size}:${s.mtimeMs}`, () => '');   // 文件"指纹"

const pushSessions = async () => {
  pushedStamp = await eventsStamp();
  const events = await readEvents(eventsPath);
  for (const client of clients) {
    // 每个 SSE 客户端可能订阅了不同的 workspace，分别过滤后推送
    client.write(`data: ${JSON.stringify(rebuildSessions(/* 该客户端范围内的事件 */))}\n\n`);
  }
};

const schedulePush = () => {                       // 防抖 200ms：多个 hook 几乎同时写入时只推一次
  if (watchDebounce) clearTimeout(watchDebounce);
  watchDebounce = setTimeout(() => { watchDebounce = null; void pushSessions(); }, 200);
};

// 监听"目录"而不是文件：压缩会原子替换文件（换了 inode），监听文件本身会跟丢
const watcher = fs.watch(path.dirname(eventsPath), (_t, filename) => {
  if (filename && filename.toString() !== eventsFileName) return;
  schedulePush();
});

// macOS 的 FSEvents 在磁盘繁忙时会延迟，实测一次追加 20 多秒都没通知 → 每秒 stat 兜底
const eventsPoll = setInterval(() => {
  void eventsStamp().then((stamp) => { if (stamp !== pushedStamp && !watchDebounce) schedulePush(); });
}, 1000);
```

这一小段代码处理了三个真实问题：文件被原子替换、文件监听在某些平台上丢通知、多个事件同时写入。可以当作"可靠的文件变更推送"的教科书例子。

### 7.3 接口一览

| 路由 | 返回 | 数据来源 |
| --- | --- | --- |
| `/` | 看板 HTML | `getDashboardHtml` |
| `/events` | SSE 流，连上立即推一次全量 | `rebuildSessions` |
| `/api/sessions` | 当前会话列表 | `rebuildSessions` |
| `/api/trends` | 本周 / 上周对比 | `aggregateDailySessions` → `computeDailyStatsDelta` → `summarizeTrendWindow` + `summarizeSessionCosts` |
| `/api/workspaces` | 可切换的作用域 | `dashboardWorkspaces` |
| `/api/kb-summary`、`/api/context` | 知识库摘要（缓存 30 秒） | `viz.ts`（第 9 节） |
| `/kb-report` | 完整知识库报告 HTML | `generateReportHtml` |
| `/api/resources/rules`、`/api/distribution` | 规则清单、角色/项目分发配置 | 只返回名称和元数据，不返回规则正文 |

所有接口都支持 `?workspace=<id>` 参数，按作用域过滤事件。

### 7.4 安全

```ts
server.listen(serverPort, '127.0.0.1', ...);        // dashboard.ts:443，只监听本机，默认端口 3721

// dashboard.ts:230：CORS 是 *，任何网页都能"读"；所以除 GET/HEAD 外的请求一律视为写，必须来自本地页面
if (req.method !== 'GET' && req.method !== 'HEAD' && !isLocalWrite(req, serverPort)) {
  res.writeHead(403, /* ... */);
}
```

`isLocalWrite`（`dashboard/http.ts:23`）要求同时满足三条：

```ts
export function isLocalWrite(req, port) {
  const local = new Set([`localhost:${port}`, `127.0.0.1:${port}`]);
  if (!(req.headers['content-type'] ?? '').startsWith('application/json')) return false; // 1. 必须是 JSON
  if (!local.has(req.headers.host ?? '')) return false;                                    // 2. Host 必须是本机
  const origin = req.headers.origin;
  if (origin === undefined) return true;
  return new URL(origin).protocol === 'http:' && local.has(new URL(origin).host);          // 3. Origin 必须是本机
}
```

每条各防一类攻击：

1. **要求 `application/json`**：浏览器跨站发送 JSON 请求必须先发预检（OPTIONS），而预检在上面就被拒了。普通表单提交（简单请求）带不了这个 Content-Type。
2. **校验 Host**：防 DNS 重绑定。攻击者的域名即使解析到 127.0.0.1，Host 头仍然是攻击者的域名。
3. **校验 Origin**：防普通的跨站请求（CSRF）。

---

## 8. 团队汇总：本地增量 → reports 分支 → 全员合并

本地看板只能看到本机。团队层面的数据由 `reportUsageToTeam`（`src/team-push.ts:933`）在 **pull 期间**顺带上报：

```ts
export async function reportUsageToTeam(repoPath, username, options?) {
  // 非 HTTP 仓库：统计和投票属于"报表数据"，写到 teamai-reports 孤儿分支（独立 worktree），
  // 绝不污染默认分支
  const useReportsBranch = !!reportsConfig && usesBranchWorktree(reportsConfig);

  const events = reportsConfig ? await readUsageEvents(reportsConfig) : [];   // skill 使用记录
  const dashboardEvents = await filterEventsByScope(await readEvents(), reportsConfig); // 只取本作用域的事件
  const metrics = aggregateSessionMetrics(dashboardEvents);                    // 复用第 5 节
  const currentDaily = aggregateDailySessions(dashboardEvents);                // 复用第 6 节

  // 读取"上次已上报"的基线，计算三类增量
  const { interventions: reportedInterventions, promptTokens: reportedPromptTokens, daily: reportedDailySessions }
    = await reportedBaselines(dashboardEvents, metrics, currentDaily, reportsConfig, true);
  const { delta: interventionDelta } = computeInterventionDelta(/* ... */);
  const { delta: promptTokenDelta }  = computePromptTokenDelta(/* ... */);
  const { delta: dailyDelta }        = computeDailyStatsDelta(effective.daily, reportedDailySessions);

  // 写 stats/<username>.yaml：已有数据 + 增量
  const merged = mergeStatsWithinTeamSkills(existing, username, newStats, teamSkillNames);
  merged.daily = mergeDailyStats(existing?.daily, dailyDelta);
  // ... 同时把 votes 的本地增量同步上去（第 9 节）
}
```

几点说明：

1. **为什么要增量**：本地 `events.jsonl` 会被压缩（第 3.3 节），历史事件迟早会被删掉。所以不能每次都重算全量，只能"记住上次报到哪了，这次只报新增的部分"。这正是 6.2 节快照 + 差值设计的用武之地。
2. **为什么用孤儿分支**：每个成员每次 pull 都可能写统计，如果写在主分支上，会产生大量和业务无关的提交，还容易冲突。孤儿分支和主分支完全隔离。
3. **按作用域隔离**：`filterEventsByScope` 只上报属于这个团队配置的会话。一台机器可能同时加入多个团队，A 团队的数据不能报给 B 团队（#748、#785）。
4. **隐私过滤**：`mergeStatsWithinTeamSkills` 只上报团队共享过的 skill 名称和 CLI 内置 skill（#1055），成员私人 skill 的名字不会出现在团队统计里。
5. **失败可重试**：推送失败时 `restoreStats` 会把 reports worktree 里已经加过增量的文件恢复原状，避免重试时重复累加。

团队视图（`digest.ts:367`）把所有成员的 `daily` 合并后，复用同一个 `summarizeTrendWindow` 计算团队周环比：

```ts
export function summarizeTeamTrends(teamStats: UserStats[], now = new Date()) {
  let daily = {};
  for (const user of teamStats) daily = mergeDailyStats(daily, user.daily ?? {});
  return Object.keys(daily).length > 0 ? summarizeTrendWindow(daily, now) : null;
}
```

除此之外，`stats.ts` 的 `aggregateUsage` 按 skill 名统计调用次数和最近使用时间。这份数据来自 `post-tool-use / Skill` 上注册的 `trackHandler`，写在各作用域自己的 `usage.jsonl` 里。

> 说明：`team-push.ts` 有 1200 多行，`reportedBaselines`、`droppedRollouts` 等处理"Codex rollout 被压缩掉"之类边界情况的逻辑，我只看了调用关系，没有逐行读。

---

## 9. 知识价值链路：召回计数 × 采纳计数

### 9.1 两个计数器，两个时机

每个成员都有一个 `votes/<user>.yaml`，记录每条知识（docId）的两个计数：

| 计数 | 含义 | 什么时候 +1 | 代码 |
| --- | --- | --- | --- |
| `recalled_count` | 被检索**命中**的次数 | AI 执行 `teamai recall` 搜到这条知识时，立即 +1 | `recall.ts:300` `autoUpvote` → `votes.ts:271` `incrementRecalled` |
| `upvoted_count` | 被**采纳**的次数 | 召回之后 24 小时内，同一会话真的打开（读取）了这个文档 | `recall-adoption.ts` → `votes.ts:311` `incrementUpvoted` |

召回时（`recall.ts:300`）：

```ts
export async function autoUpvote(results: SearchResult[], config: LocalConfig) {
  if (results.length === 0) return;
  const localVotePath = path.join(getVotesDir(config), `${config.username}.yaml`);
  const docIds = results.map(voteKey);
  // 尽力而为：锁被占用时跳过这次计数，并如实记录日志（不再假装成功，#723）
  const applied = await incrementRecalled(localVotePath, docIds);
}
```

采纳判定（`recall-adoption.ts` 文件头）：

```
 * Adoption of recalled docs (#884): a doc counts as adopted when the session
 * that ran a recall opens it within 24 hours after the run.
 *
 *   PostToolUse ── recordToolCall ──▶ claim / evidence ─┐
 *   teamai recall ────────────────▶ run ────────────────┼─▶ recall log
 *   Stop / SubagentStop ── creditAdoptedDocs ◀── join ──┤
 *   pull ── drainRecallLog: pending sessions, retention ┘
 *              └─▶ incrementUpvoted (per-session ledger) ─▶ consumed
```

翻译一下：

1. `teamai recall` 每次运行都写一条 `run` 记录（带 run id 和命中的文档）。
2. `post-tool-use` 上的 `recall-attribution` handler 把每次工具调用分类（是不是读了某个文档），写成 `claim / evidence`。**它只追加、从不读日志**，保证 hook 足够快。
3. Stop 和 SubagentStop 时，`votes-sync` handler 把两类记录 join 起来：召回过、并且 24 小时内被读过的文档，记一次采纳。pull 时会再做一次补偿，并清理过期日志。
4. 另外两条采纳来源：可选的 LLM 评判（`votes-judge`，`TEAMAI_UPVOTE_JUDGE=1` 开启，`hook-handlers.ts:804`），以及用户手动反馈（`votes.ts:681`）。

**为什么分两个计数**：召回只说明"搜索结果里有它"，不说明有用。"被搜到之后真的被打开了"才是更强的价值信号。两者共同决定知识的置信度（`src/maintenance/confidence.ts:21`）：

```ts
// base    = min(1.0, recalled * 0.1 + upvoted * 0.3)   采纳的权重是召回的 3 倍
// recency = 按最近召回时间衰减
// ratio   = upvoted / max(1, recalled)                  采纳率
// confidence = base * 0.4 + recency * 0.3 + ratio * 0.3
```

置信度低于 0.15 的知识会成为归档候选；置信度高、采纳人数和存续天数都达标的会成为晋升候选。这些候选会直接显示在下面的报告里。

### 9.2 并发与一致性：votes 文件怎么保证不乱

votes 文件会被前台 Stop handler、后台 LLM 评判、recall、pull 同时写，代码里做了三层保护：

```ts
// 1. 所有写操作都在同一把文件锁里（withVotesLock）
export async function incrementRecalled(votePath, docIds): Promise<boolean> {
  const { acquired } = await withVotesLock(votePath, async () => {
    const data = await loadUserVotes(votePath);
    for (const docId of docIds) {
      data.votes[docId].recalled_count++;
      data.votes[docId].last_recalled_at = now;
      data.deltas[docId].recalled_delta++;       // 同时记一份"还没同步到团队的增量"
    }
    await saveUserVotes(votePath, data);
  });
  return acquired;                               // 拿不到锁就如实返回 false
}

// 2. 原子写入：临时文件 + rename（votes.ts:250 的注释）
//    后台进程可能在写到一半时被杀（关 IDE、电脑休眠）。如果直接覆盖写，会留下截断的 YAML，
//    而 loadUserVotes 解析失败时会退回空对象 → 所有计数、增量、采纳账本全部清零。
//    同一文件系统内 rename 是原子的，读者要么看到旧文件，要么看到新文件。
export async function saveUserVotes(votePath, votes) {
  await writeFileAtomic(votePath, YAML.stringify(votes));
}

// 3. 采纳的幂等账本（votes.ts:296 的注释）：
//    每个会话已经采纳过哪些文档，记在 votes 文件内部的 upvotedSessions 里，和计数在同一把锁下更新。
//    所以前台 handler 和后台评判不会重复计数；同一会话多次 Stop，同一文档最多采纳一次；
//    拿不到锁就什么都不记，下次 Stop 再干净地重试。
```

### 9.3 同步到团队：增量合并

本地只上报 `deltas`，团队仓库那份做增量合并（`votes.ts:380` `mergeDeltas`）：

```ts
export function mergeDeltas(local: UserVotesV2, remote: UserVotesV2): UserVotesV2 {
  const votes = { ...remote.votes };                          // 以远端为准
  for (const [docId, delta] of Object.entries(local.deltas)) {
    votes[docId].recalled_count = Math.max(0, votes[docId].recalled_count + delta.recalled_delta);
    votes[docId].upvoted_count  = Math.max(0, votes[docId].upvoted_count  + delta.upvoted_delta);
    // 时间戳取较新的一方
    // 一致性约束：计数归零时清掉对应的时间戳
  }
  return { version: 2, votes, deltas: {} };                   // 合并后增量清空
}
```

这和第 6 节的会话统计是同一个思路：**本地记增量，远端做累加**。即使多台机器同时上报，也不会互相覆盖。

### 9.4 知识库报告：`buildVizData`

`src/viz.ts:429`，把"有哪些知识"和"用得怎么样"按 docId 拼起来：

```ts
export async function buildVizData(paths: VizPaths): Promise<VizData> {
  const [entries, { byDoc: votesAgg, activeContributors }] = await Promise.all([
    loadEntries(paths),                  // 知识条目：搜索索引（learnings/docs/rules/skills），没有就临时建一份
    aggregateTeamVotes(paths.votesDir),  // 使用数据：votes/ 下所有成员的 yaml 相加
  ]);
  const metrics: EntryMetric[] = entries.map((entry) => {
    const docId = entry.filename.replace(/\.md$/i, '');
    const v = votesAgg[docId];
    return {
      docId, title: entry.title, type: entry.type, author: entry.author, date: entry.date, tags: entry.tags,
      recalledCount: v?.recalledCount ?? 0,
      upvotedCount: v?.upvotedCount ?? 0,
      lastRecalledAt: v?.lastRecalledAt ?? null,
    };
  });
  // ... 覆盖率 / 热门 / 沉默 / 趋势 / 作者 / 维护候选
}
```

`aggregateTeamVotes`（`viz.ts:270`）跨成员相加：

```ts
for (const file of files) {                              // votes/alice.yaml, votes/bob.yaml ...
  const userVotes = await readUserVotes(path.join(votesDir, file));
  let userHasRecall = false;
  for (const [docId, entry] of Object.entries(userVotes.votes)) {
    byDoc[docId].recalledCount += entry.recalled_count;
    byDoc[docId].upvotedCount  += entry.upvoted_count;
    if (entry.last_recalled_at > byDoc[docId].lastRecalledAt) byDoc[docId].lastRecalledAt = entry.last_recalled_at;
    if (entry.recalled_count > 0) userHasRecall = true;
  }
  if (userHasRecall) activeContributors++;               // 至少召回过一次知识的人数
}
```

报告中的各项指标：

```ts
// 覆盖率（viz.ts:371）：每种类型中，至少被召回过一次的条目占比
coveragePct = Math.round(covered / total * 100);   // covered = recalledCount > 0 的条目数

// 热门榜：recalledCount > 0，按召回次数降序取前 20
// 沉默条目：recalledCount === 0 的全部条目

// 趋势（viz.ts:394）：按"最近一次召回时间"的年月分桶
function buildTrend(metrics) {
  for (const m of metrics) {
    if (!m.lastRecalledAt) continue;
    const period = m.lastRecalledAt.substring(0, 7);   // '2026-10'
    buckets.set(period, (buckets.get(period) ?? 0) + 1);
  }
}

// 作者（viz.ts:407）：每位作者的条目数 + 被召回总次数，按召回降序取前 15

// 维护候选：findPromotionCandidates / findPruneCandidates / findStaleEntries（maintenance/）
```

**渲染**：`viz-render.ts` 是纯函数，没有 IO，也没有外部依赖。柱状图和趋势图直接拼 SVG 字符串，所有用户数据都先过 `escapeHtml` 再插入（知识标题、作者名都是用户写的，不转义就有 XSS 风险）。输出是一个独立的 HTML 文件，可以离线打开、直接转发。

入口：看板里的 `/kb-report`（完整报告）和 `/api/kb-summary`、`/api/context`（摘要卡片，缓存 30 秒）。我在 `src/` 里只找到 `dashboard.ts` 这一个调用 `generateReportHtml` 的地方，没有单独的 `viz` 命令。

---

## 10. 指标口径速查表

**会话效能（链路 A / C）**

| 指标 | 来源 | 口径 |
| --- | --- | --- |
| 会话状态 | 事件回放 | running / waiting_for_input / idle（5 分钟）/ stopped；30 分钟无活动不再显示 |
| interrupt | Stop 扫描 transcript | 用户消息以 `[Request interrupted by user` 开头；取最新快照 |
| toolReject | Stop 扫描 transcript | `tool_result.is_error` 且是用户拒绝；取最新快照 |
| correction | 事件序列 | Stop 后 60 秒内的下一条 prompt 命中纠正关键词；每个 Stop 最多算一次 |
| prompts | 实时事件 + transcript | 两者取 max；剔除系统注入内容 |
| tokens | Stop 扫描 transcript | 按快照作用域取最新或分段求和 |
| 成功会话 | 日快照 | 无 error && interrupt = 0 && correction = 0 |
| 活跃时长 | 事件间隔 | 只累加 ≤ 5 分钟的间隔 |
| 费用 | 价格表估算 | 公开 API 标价，整数微美元，带价格版本，认不出的模型不计价 |
| 缓存命中率 | token 数 | cacheRead ÷ (input + cacheRead + cacheCreation)，不依赖计价 |
| 周环比 | 每日汇总 | 最近 7 天 vs 前 7 天；分母为 0 返回 null |

**知识价值（链路 B）**

| 指标 | 口径 |
| --- | --- |
| recalled_count | 被 `teamai recall` 搜到的次数 |
| upvoted_count | 召回后 24 小时内同一会话真的打开了（或经 LLM 评判、手动反馈）；每会话每文档最多 1 次 |
| 覆盖率 | 至少被召回 1 次的条目 ÷ 总条目 |
| 活跃用户 | 至少召回过 1 次知识的成员数 |
| 月度趋势 | 按每条知识**最近一次**召回的月份计数，表示"每月仍在被用的知识条数"，**不是**每月召回次数 |
| 置信度 | base×0.4 + recency×0.3 + 采纳率×0.3 |

---

## 11. 设计思想总结

| 思想 | 体现 |
| --- | --- |
| **无侵入采集** | 复用 hook 调度器，不改 AI 工具、不加 SDK；数据由 hook handler 顺手写出 |
| **Event Sourcing** | 只存事件，不存状态；会话状态、指标都由回放得到；连"进程退出"也是补写一条事件 |
| **快照 + 差值** | Stop 产出全量快照，聚合取最新；上报时与已上报基线相减，只累加增量 → 幂等、可回退、可断点续传 |
| **单一聚合函数** | `aggregateSessionMetrics` 同时服务本地看板和团队上报，口径不会分叉 |
| **并发安全** | 事件文件加锁 + 旁路文件；votes 文件加锁 + 原子写 + 会话账本 |
| **隐私优先** | 先脱敏再截断；Copilot 不存 prompt；团队统计只含共享 skill 名；规则接口不返回正文 |
| **诚实的数字** | 费用标"估算"并带版本；认不出的模型不计价、不算 0；分母为 0 返回 null |
| **数据隔离** | 按作用域（dataHomeKey）和仓库（projectAnchor）归属；报表数据写孤儿分支 |
| **可靠推送** | 监听目录 + 每秒 stat 兜底 + 200ms 防抖 |
| **本地服务安全** | 只监听 127.0.0.1；写请求校验 Content-Type、Host、Origin |

面试时的一段话版本：

> 统计完全复用 hook 事件流，不需要额外埋点。每个生命周期事件追加一条记录到本地 JSONL，Stop 时再扫描 AI 工具的 transcript，拿到 token、按模型估算的费用、缓存命中率，以及打断、拒绝授权这些人工干预信号；"纠正"则由"Stop 后 60 秒内的下一条 prompt 命中纠正词"这个事件模式推导。看板通过回放事件重建会话状态和指标，用文件监听加 SSE 实时推送。团队上报采用快照加差值：每个会话生成完整快照，和上次已上报的基线相减，只把增量写进 reports 孤儿分支，所以重复上报是幂等的，会话从成功变失败也能扣回来。知识侧用"召回"和"24 小时内真的打开"两个计数器区分"被搜到"和"被用上"，按成员增量合并，再算覆盖率、沉默条目和置信度，自动列出该晋升和该归档的知识。

（同前两份文档：没参与开发就说"项目的设计是……"。）

---

## 12. 动手实验

```bash
# 1. 看自己机器上已有的事件（如果用过 teamai）
tail -n 5 ~/.teamai/dashboard/events.jsonl | python3 -m json.tool --json-lines

# 2. 启动看板，浏览器打开 http://localhost:3721
teamai dashboard

# 3. 另开终端，直接请求接口
curl -s http://localhost:3721/api/sessions | python3 -m json.tool | head -40
curl -s http://localhost:3721/api/trends   | python3 -m json.tool
curl -N http://localhost:3721/events                              # SSE，保持连接，观察实时推送

# 4. 验证写接口的防护：没有本地 Origin 的 POST 会被拒（预期 403）
curl -s -X POST -H 'Content-Type: application/json' -H 'Origin: http://evil.example' \
  http://localhost:3721/api/distribution -d '{}' -o /dev/null -w '%{http_code}\n'

# 5. 跑相关单元测试（需先 npm install）
npx vitest run session-trends     # 快照 + 差值、成功变失败的回退
npx vitest run votes              # 计数器、锁、会话账本、mergeDeltas
npx vitest run dashboard-collector   # 采集、去重、会话重建
npx vitest run dashboard-http        # isLocalWrite 写接口防护
```

> `~/.teamai/dashboard/events.jsonl` 里有你的 prompt 摘要（已脱敏），分享截图前注意。第 4 条只是验证 403，不会写入任何数据。

推荐阅读顺序：

1. `src/types.ts:1682-1830`（数据结构）和 `:1876-1915`（阈值常量和关键词）
2. `src/dashboard-collector.ts:1219` `parseHookEvent`
3. `src/dashboard-collector.ts:1886` `rebuildSessions` 和 `:2058` `aggregateSessionMetrics`
4. `src/session-trends.ts` 全文（400 行），重点是 `computeDailyStatsDelta`
5. `src/model-pricing.ts`
6. `src/dashboard.ts:72-170`（推送和 PID 监控）、`:225-417`（路由）
7. `src/votes.ts:250-420`、`src/recall-adoption.ts` 文件头、`src/viz.ts:266-460`

---

## 13. 自测问题

1. `interrupt` 为什么取最新一次 Stop 的快照，而不是把每次 Stop 的值相加？
2. "纠正"为什么不从 transcript 里数，而要用"Stop 后 60 秒内的 prompt"来判断？
3. `computeDailyStatsDelta` 里，为什么 `sessionsSucceeded` 用有符号差值，其他字段用 `positiveDelta`？
4. 本地 `events.jsonl` 会被压缩，那团队的历史统计为什么不会丢？
5. 看板为什么监听目录而不是 `events.jsonl` 本身？为什么还要每秒 stat 一次？
6. `recalled_count` 和 `upvoted_count` 分别在什么时候 +1？只看召回次数有什么问题？
7. votes 文件为什么必须原子写？如果直接覆盖写，被中途杀掉会发生什么？
8. 报告里的"月度趋势"真正表示什么？为什么不能说成"每月召回次数"？
9. `isLocalWrite` 的三个条件分别防的是什么攻击？

（答案都在上文对应章节里。）

