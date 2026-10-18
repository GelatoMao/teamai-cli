# 第 7 步：知识的新陈代谢（反馈、置信度、淘汰、晋升）

> 面向小白。先讲"为什么要有它"和"整体长什么样"，再沿着一次真实的 upvote 逐函数看代码，最后用一个 learning 的一生演算置信度。
> 基于 main@fe3b906 源码（2026-10-17），标注 `文件:行号`；行号会随提交变化，以函数名为准。为便于阅读删减了部分注释，用 `// ...` 省略无关分支。
> 前置阅读：[06-recall-search.md](./06-recall-search.md)（recall 怎么召回文档并打印 `run=<uuid>`）。本文讲召回之后：团队怎么知道这条知识有没有用，没用或很有用时怎么处理。

---

## 0. 一句话 + 一个类比

**一句话**：AI 每召回（recall）一篇团队知识记一次 `recalled`；同一会话在 24 小时内真的**打开**了这篇文档，就记一次 `upvoted`（每会话每文档只记一次）；计数以增量（delta）推到团队仓库的 reports 分支；维护命令把全员的票汇总成 0~1 的**置信度**，据此给搜索降权（冷知识）、淘汰（prune / `_archive`），或由 AI 改写后晋升为正式的 skills / rules / docs（promote）。

**类比**：图书馆的借阅系统。

- 管理员推荐一本书 = recall（`recalled_count + 1`）
- 读者真的翻开了 = adoption（`upvoted_count + 1`）；同一读者同一次来馆翻十次也只算一次（ledger）
- 每个分馆先在本地小本子上记"今天新增几次"（deltas），之后汇总给总馆（推送 reports 分支）
- 总馆定期盘点：常被推荐却没人翻的书放角落（hotness 降权），长期无人问津的下架入库（`_archive`），好评多且多人借阅的收进"馆藏精选"（promote）

---

## 1. 为什么需要它

### 1.1 只沉淀不代谢会怎样

前几篇让团队不断产生 learnings 并分发到每台机器，06 让 AI 能检索它们。如果到此为止：

| 问题 | 后果 |
| --- | --- |
| learnings 只增不减 | 检索越来越吵，过时经验和新经验混在一起 |
| 不知道哪条真有用 | 偶发经验和反复验证过的经验排序一样 |
| 有价值的经验停留在"个人经验"形态 | 进不了 skills/rules 这种更正式的形态 |
| 正式文档常被召回却没人采纳 | 说明它"相关但不好用"，没人发现、没人改 |

### 1.2 设计取舍（都能在源码注释里找到依据）

| 取舍 | 选择 | 依据 |
| --- | --- | --- |
| "有用"怎么判定 | 默认看工具调用证据（会话打开了召回的文件），不让模型自我声明 | `hook-handlers.ts:653-655`："Deterministic: built from tool-use evidence, not from the model self-declaring anything"；`hook-handlers.ts:514-516` 写明 self-declaration 机制已移除 |
| 子代理只给摘要、没打开文件 | 可选后台 LLM 判官 `votes-judge`，默认关 | `hook-handlers.ts:681-701`：opt-in via `TEAMAI_UPVOTE_JUDGE=1`，由 reviewer 评估成本后再决定是否默认开启 |
| 防重复计数 | 账本写在 votes 文件**内部**，与计数同锁、一次写完 | `votes.ts:63-67`、`votes.ts:296-306` |
| 同步方式 | 只推增量，合并基于 origin 已确认的快照 | `hook-handlers.ts:600-603`（#1027，防重试时重复计数） |
| hook 侧预算 | PostToolUse 只追加日志行，不读日志、不读文件 | `hook-handlers.ts:384-390` |
| 维护结果怎么到队友手里 | 写进 learnings worktree，再由 `publishLearningsMaintenance` 推送 | `learnings-publish.ts:326-337` |
| 新文档保护 | 没有投票数据的文档不参与 prune；搜索 hotness 记中性 1.0 | `prune.ts:57-58`、`hot-cold.ts:19-21` |

---

## 2. 关键数据结构与存储位置

### 2.1 三类数据，三个地方

| 数据 | 位置 | 谁写 | 谁读 |
| --- | --- | --- | --- |
| recall log（`run` / `claim` / `evidence` / `link` / `consumed` 多种行） | 当前作用域的 data home（`recallLogPath`，见 06） | `teamai recall` 写 run；PostToolUse 的 `recall-attribution` 写 claim/evidence；reducer 写 consumed | `creditAdoptedDocs`（reducer） |
| 本机投票文件 `<votesDir>/<username>.yaml` | `getVotesDir(config)`：`<dataHome>/votes`，用户作用域则是 `getUserVotesDir()`（`types.ts:2228-2233`） | `incrementUpvoted`、`incrementRecalled`、`recall feedback` | votes-sync（看有没有 deltas 要推） |
| 团队投票目录 `votes/` | `path.join(getReportsDir(localConfig), 'votes')`（`maintenance/paths.ts:99`）；非 HTTP 团队在 `teamai-reports` 分支的 worktree 里（`paths.ts:65-75` 注释） | votes-sync 合并 deltas 后推送 | 所有 maintenance 计算 |

关键点：hook 写的是**本机**投票文件，maintenance 读的是**团队**投票目录（每个成员一个 `<username>.yaml`），两者之间靠 deltas 同步。

### 2.2 投票文件里的三块

从 `incrementUpvoted` 的写法能看清字段（`votes.ts:341-352`）：

```ts
for (const docId of toCredit) {
  if (!data.votes[docId]) {
    data.votes[docId] = { recalled_count: 0, upvoted_count: 0, last_recalled_at: '' };
  }
  data.votes[docId].upvoted_count++;
  data.votes[docId].last_upvoted_at = now;

  if (!data.deltas[docId]) {
    data.deltas[docId] = { recalled_delta: 0, upvoted_delta: 0 };
  }
  data.deltas[docId].upvoted_delta++;
}
```

会话账本（ledger）的形状和寿命（`votes.ts:68-78`）：

```ts
interface UpvoteLedger {
  // ...
  [sessionId: string]: { docIds: string[]; ts: string; firstTs: string };
}

const LEDGER_TTL_MS = 24 * 60 * 60 * 1000; // 1 day
```

账本存在文件的 `upvotedSessions` 字段里（`votes.ts:81`、`votes.ts:154`）。合起来大致长这样（字段名来自代码，值是示意）：

```yaml
version: 2
votes:
  learnings/redis-timeout: { recalled_count: 3, upvoted_count: 1, last_recalled_at: "...", last_upvoted_at: "..." }
deltas:
  learnings/redis-timeout: { recalled_delta: 1, upvoted_delta: 1 }
upvotedSessions:
  sess-abc: { docIds: [learnings/redis-timeout], ts: "...", firstTs: "..." }
```

| 字段 | 含义 |
| --- | --- |
| `votes` | 本机视角的累计值，计算置信度用的就是这几个字段 |
| `deltas` | 还没送到 origin 的增量；推送确认后才扣掉 |
| `upvotedSessions` | 每个会话已经 upvote 过哪些文档；`firstTs` 起算 24 小时后整条过期 |

为什么 TTL 从 `firstTs` 而不是 `ts` 起算？注释（`votes.ts:69-73`、`votes.ts:101-106`）：长会话每轮都会刷新 `ts`，若按 `ts` 算，去重窗口会一直往后滑；按"会话第一次出现"算，窗口固定。

---

## 3. 端到端流程图

```text
[AI 会话]
  | (1) Bash: teamai recall "redis 超时"
  |     recall 输出 "--- [teamai:recall:start] --- (2 results) run=<uuid>"，并往 recall log 写一行 run
  v
PostToolUse -> recall-attribution（前台）-> recordToolCall()
  |     正则从输出抓 run=<uuid> -> 追加 claim 行（direct = 命令本身是不是在跑 teamai recall）
  | (2) Read: /.../learnings/redis-timeout.md
  v
PostToolUse -> recall-attribution -> recordToolCall()
  |     .md 且在 knowledgeRoots 之下 -> 追加 evidence 行（path / status / simple）
  v
Stop / SubagentStop / SessionEnd -> votes-sync（前台）
  | (3) creditAdoptedDocs()：join run + claim + evidence
  |       run 归属 -> 24h 窗口 -> 路径匹配 -> eligible 过滤
  |       -> incrementUpvoted(votePath, keys, rootSession)   锁内：账本去重 + 计数 + delta
  |       -> 追加 consumed 行（这些 evidence 再也不计票）
  | (4) 非 SubagentStop：pruneUpvoteLedger()   清理超过 24h 的账本条目
  | (5) 非 SubagentStop 且有 deltas：
  |       updateReports(worktree) -> stageVotesMerge(以 origin 快照为基) -> push teamai-reports
  |       送达后 onDelivered -> confirmVotesSynced() 扣掉已送达的 deltas
  | (6) 仅 Stop、且工具会打印 Stop 输出：返回 "[teamai] Adopted team knowledge this session: ..."
  v
(可选) Stop -> votes-judge（后台，TEAMAI_UPVOTE_JUDGE=1）
  |     先跑一遍 creditAdoptedDocs；账本里已有的不判；LLM 判 -> incrementUpvoted(..., sessionId) -> 同样推送
  v
[团队仓库 teamai-reports 分支] votes/<username>.yaml（每人一个）
  v
teamai recall maintenance / promote（手动触发）
  |   computeAllConfidence(votesDir) 汇总全员 -> 每篇文档 0~1
  +-- --confidence-writeback -> 写回 learning frontmatter
  +-- --prune [--archive]    -> 删除或移到 _archive/
  +-- --update-quality       -> 找"常召回少采纳"的 docs/rules/skills，AI 写 .draft.md
  +-- promote                -> AI 改写进 skills/ rules/ docs/，原文加 promoted_to
  v
publishLearningsMaintenance()  把改动推到 learnings 分支（失败就记录，下次重试）

另：建搜索索引时 annotateHotness() 用同一份置信度给冷文档打分 x0.3
```

---

## 4. 逐函数走读：一次 upvote 的一生

### 4.1 PostToolUse：`recall-attribution` 只记账，不算账

注册：每次工具调用都触发（`hook-handlers.ts:1190`）：

```ts
{ event: 'post-tool-use', matcher: '*', handler: recallAttributionHandler, timeoutMs: FOREGROUND_HOOK_TIMEOUT_MS, requiresConfig: true },
```

handler 本身只有几行（`hook-handlers.ts:391-399`）：

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

真正干活的 `toolCallLines`（`recall-adoption.ts:132-161`）分两种情况：

```ts
const call = classifyToolCall(stdin, tool);

if (call.command !== undefined && call.output !== undefined) {
  const runs = [...new Set([...call.output.matchAll(RUN_ID_PATTERN)].map((m) => m[1]))];
  if (runs.length > 0) {
    const actor = actorOf(stdin, tool);
    const direct = invokesRecall(call.command);
    for (const run of runs) lines.push({ kind: 'claim', ts: new Date().toISOString(), run, ...actor, direct, agent: tool });
    return lines;
  }
}

if ((call.category !== 'read' && call.category !== 'search') || call.status === 'failure') return lines;
let roots: string[] | undefined;
for (const file of call.paths) {
  if (!/\.md$/i.test(file)) continue;
  if (isAbsolutePath(file)) {
    const { knowledgeRoots, isUnderRoots } = await import('./utils/learnings-roots.js');
    roots ??= await knowledgeRoots(config);
    if (!isUnderRoots(file, roots)) continue;
  }
  lines.push({
    kind: 'evidence', ts: new Date().toISOString(), id: randomUUID(),
    ...actorOf(stdin, tool), path: file, status: call.status, simple: call.simple,
  });
}
```

逐段解释：

- 第一段：shell 命令的输出里出现了 `run=<uuid>`，就记一条 **claim**——"这个 run 是我这个会话跑的"。`direct` 记录命令本身是否真的在调用 `teamai recall`（`invokesRecall`，`recall-adoption.ts:77-92`）；像 `codex exec "run teamai recall …"` 这种只在引号参数里出现的不算。
- 第二段：读文件或搜索命中的 `.md`，且绝对路径落在团队知识根目录下，就记一条 **evidence**，每条带 `randomUUID()` 作 id，之后用来标记"已消费"。
- 两种情况都**不读 recall log、不读文件内容**，一次调用一次追加写，所以能塞进前台 hook 的时间预算（`hook-handlers.ts:384-390` 注释）。命令文本本身也从不落盘（`recall-adoption.ts:115`）。

### 4.2 Stop：reducer `creditAdoptedDocs` 把日志 join 成票

文件头注释画了整体关系（`recall-adoption.ts:1-14`）：

```ts
 *   PostToolUse ── recordToolCall ──▶ claim / evidence ─┐
 *   teamai recall ────────────────▶ run ────────────────┼─▶ recall log
 *   Stop / SubagentStop ── creditAdoptedDocs ◀── join ──┤
 *   pull ── drainRecallLog: pending sessions, retention ┘
 *              └─▶ incrementUpvoted (per-session ledger) ─▶ consumed
```

reducer 的核心（`recall-adoption.ts:327-356`）：

```ts
async function creditRoot(config: LocalConfig, index: LogIndex, sessionId: string): Promise<AdoptionResult> {
  const target = index.rootOf(sessionId);
  const { runs, recalled, evidence, opened, creditOf, done } = viewRoot(index, target);
  if (runs.length === 0) return { credited: [], recalled };
  const { consumed } = index;

  const keys = new Set<string>();
  const crediting: string[] = [];
  for (const e of evidence) {
    if (consumed.has(e.id)) continue;
    const fresh = opened(e).filter((d) => !done.has(creditOf(d)));
    if (fresh.length === 0) continue;
    for (const d of fresh) keys.add(d.key);
    crediting.push(e.id);
  }
  if (keys.size === 0) return { credited: [], recalled };

  const { incrementUpvoted } = await import('./votes.js');
  const credited = await incrementUpvoted(path.join(getVotesDir(config), `${config.username}.yaml`), [...keys], target);
  if (credited === null) return { credited: null, recalled };
  for (const id of crediting) consumed.add(id);
  // ...
    await appendRecallLines(config, crediting.map((evidence) => ({ kind: 'consumed', ts, evidence })));
  // ...
  return { credited, recalled };
}
```

一篇文档要被算作"采纳"，要依次过这几关（来自 `viewRoot`，`recall-adoption.ts:289-325`，及 `indexLog`、`inWindow`）：

| 关卡 | 规则 | 代码 |
| --- | --- | --- |
| run 归属 | run 先按"第一条 direct 为 true 的 claim"定归属；没有 claim 时只有环境唯一指向一个会话（`unambiguous`）才算；否则这个 run 永不计票 | `recall-adoption.ts:205-231` |
| 子会话合并 | 有 `link` 行的子会话（OpenCode task、OMP）按链条归到根会话，账本也记在根会话名下 | `rootOf`，`recall-adoption.ts:221-229` |
| 24h 窗口 | 读取时间必须在 run 之后 0~24h 内 | `ADOPTION_WINDOW_MS`，`recall-adoption.ts:34`、`:235-238` |
| 不能自己读自己 | recall 子代理（`teamai-recall`）自己跑的 run，它自己再读那些文件不算，主代理或别的子代理读才算 | `recall-adoption.ts:296-315` |
| 读取状态 | `success` 才算；`unknown`（如 Codex 的 shell）只有是单条简单命令时才算 | `recall-adoption.ts:319-321` |
| 路径匹配 | 绝对路径必须与 run 打印的路径相同；相对路径按尾部至少两段匹配且只能唯一命中 | `docsOpened`，`recall-adoption.ts:181-190` |
| 作用域 | 项目作用域激活时，从继承的 user 作用域召回的文档只读、不计票（`d.eligible`） | `recall-adoption.ts:317`、`hook-handlers.ts:444-462` |
| 一次 run 一篇只记一次 | `creditOf = run + key`，已消费过的 credit 进 `done` | `recall-adoption.ts:306`、`:322-323` |

注意顺序：**先** `incrementUpvoted` 成功，**再**追加 `consumed`。锁拿不到返回 `null`，这时什么都不标记，下一次 Stop / SubagentStop / pull 会重试（`recall-adoption.ts:240-248` 注释）。

### 4.3 `incrementUpvoted`：账本如何保证"同一会话同一文档只计一次"

`votes.ts:311-368`，关键部分：

```ts
const { acquired, value } = await withVotesLock(votePath, async () => {
  const data = await loadUserVotes(votePath);
  // ...
  let toCredit = docIds;
  let ledger: UpvoteLedger | null = null;
  if (sessionId) {
    ledger = readLedger(data);
    const pruned = pruneLedger(ledger, nowMs);
    const seen = new Set(ledger[sessionId]?.docIds ?? []);
    toCredit = docIds.filter((id) => !seen.has(id));
    if (toCredit.length === 0) {
      if (pruned) { /* 仅当清理过才回写 */ }
      return [] as string[];
    }
  }

  for (const docId of toCredit) { /* votes.upvoted_count++ / deltas.upvoted_delta++ */ }

  if (sessionId && ledger) {
    const existing = ledger[sessionId];
    const prev = new Set(existing?.docIds ?? []);
    for (const id of toCredit) prev.add(id);
    ledger[sessionId] = { docIds: [...prev], ts: now, firstTs: existing?.firstTs ?? now };
    (data as unknown as { upvotedSessions: UpvoteLedger }).upvotedSessions = ledger;
  }

  await saveUserVotes(votePath, data);
  return toCredit;
});
if (!acquired) return null;
return value ?? [];
```

为什么这样就不会重复计数（函数注释 `votes.ts:296-310` 列了三条）：

1. **同锁同写**：读账本、过滤、加计数、更新账本、落盘，全在 `withVotesLock` 里一次完成。前台 votes-sync 和后台 votes-judge 谁先拿到锁谁记，另一个看到账本里已有就跳过。
2. **跨轮次去重**：Stop 每轮都触发，但同一 `sessionId` 的账本里已有这个 docId，`toCredit` 就是空的。
3. **失败不预占**：锁拿不到时直接返回 `null`，账本没写，计数也没加，下一次重试干净。

账本之外还有第二道保险：reducer 的 `consumed` 行让同一条 evidence 永不再用，且"一个 run 的一篇文档只 credit 一次，即使过了账本窗口"（`recall-adoption.ts:243-245`）。账本 24h 过期后，就要靠 consumed 防重；注释也承认 consumed 写失败时，过了账本窗口这条 evidence 可能再算一次（`recall-adoption.ts:352`）。

不传 `sessionId` 时（手动 `recall feedback --positive`）跳过账本，每次都加 1（`votes.ts:308-309`）。

### 4.4 `votes-sync`：从本机文件到团队仓库

注册在三个事件上（`hook-handlers.ts:1156`、`:1166`、`:1185`），都是前台、`gitOnly`、`requiresConfig`：

```ts
{ event: 'session-end', matcher: '*', handler: votesSyncHandler, timeoutMs: FOREGROUND_HOOK_TIMEOUT_MS, gitOnly: true, requiresConfig: true },
{ event: 'stop', matcher: '*', handler: votesSyncHandler, timeoutMs: FOREGROUND_HOOK_TIMEOUT_MS, gitOnly: true, requiresConfig: true },
{ event: 'subagent-stop', matcher: '*', handler: votesSyncHandler, timeoutMs: FOREGROUND_HOOK_TIMEOUT_MS, gitOnly: true, requiresConfig: true },
```

handler 主体（`hook-handlers.ts:571-631`，删了注释）：

```ts
const { credited, recalled } = await creditAdoptedDocs(localConfig, sessionId);
const adoptedDocIds = credited ?? [];
const hookEvent = typeof stdin.hook_event_name === 'string' ? stdin.hook_event_name.toLowerCase() : '';
const subagentStop = hookEvent === 'subagentstop';
const sessionEnd = hookEvent === 'sessionend';

if (!subagentStop) await pruneUpvoteLedger(votePath).catch(() => undefined);

const { usesBranchWorktree } = await import('./types.js');
if (subagentStop) {
  // Nothing to push now: see above.
} else if (usesBranchWorktree(localConfig)) {
  try {
    // ...
    if (await hasPendingVoteDeltas(votesDir, localConfig.username)) {
      // ...
      await updateReports(localConfig, async (wt, { onDelivered }) => {
        const origin = await readReportsOriginFile(wt, `votes/${localConfig.username}.yaml`);
        const staged = await stageVotesMerge(
          wt,
          localConfig.username,
          votesDir,
          origin === null ? null : readUserVotesFromContent(origin),
        );
        if (!staged) return null;
        onDelivered(() => confirmVotesSynced(votePath, staged.syncedDeltas));
        return {
          files: [`votes/${localConfig.username}.yaml`],
          message: `[teamai] Update votes for ${localConfig.username}`,
        };
      });
    }
  } catch {
    // Push failed — the deltas stay pending and retry next session
  }
} else {
  await syncVotesToTeam(localConfig.repo.localPath, localConfig.username, votesDir).catch(() => {});
}
```

分四步看：

1. **记票**：先跑 reducer（4.2），拿到这一轮新 credit 的文档。
2. **清账本**：`pruneUpvoteLedger` 每轮跑一次。为什么不等 `incrementUpvoted` 顺手清？默认配置下"召回了但从不采纳"的会话永远走不到 `incrementUpvoted`，账本就会无限长（`hook-handlers.ts:582-585`）。它只在真删掉条目时才写盘（`votes.ts:142-157`）。
3. **推送**：没有待推 deltas 就连 fetch 都省了（Stop 每轮都触发）。有的话，在 reports worktree 里以 **origin 上已确认的快照** 为基合并（不是 worktree 副本，因为副本里可能已有本机合并过但没推成功的 deltas，再合一次就双计，#1027）。合并靠 `mergeDeltas`：远端计数 + 本地 delta，且 `Math.max(0, …)` 防负（`votes.ts:380-418`）。
4. **送达后才扣 deltas**：`onDelivered(() => confirmVotesSynced(...))`。锁忙、推送失败、进程中途被杀，deltas 都原样保留，下一次 Stop 重推（`hook-handlers.ts:612-616`）。扣的方式是"当前 deltas 减去已送达那部分"，推送期间新增的 delta 不会被误删（`remainingDeltasAfter`，`votes.ts:431-445`）。

最后，仅当这一轮真的采纳了文档、事件是 Stop、且宿主会把 Stop 输出打印给用户时，才返回一行提示（`hook-handlers.ts:664-670`）：

```ts
if (adoptedDocIds.length > 0 && !subagentStop && !sessionEnd) {
  const { stopStdoutUnsupported } = await import('./utils/tool-names.js');
  if (!stopStdoutUnsupported(tool)) {
    const { formatStopHookOutput } = await import('./utils/hook-output.js');
    return formatStopHookOutput(buildAdoptedSummary(adoptedDocIds), tool ?? 'claude');
  }
}
```

输出形如 `[teamai] Adopted team knowledge this session: learnings/redis-timeout`（列出的是投票 key）（`buildAdoptedSummary`，`hook-handlers.ts:440-442`）。不打印 Stop 输出的工具会把内容转进模型上下文，注释说这会污染下一轮，所以干脆不发（`hook-handlers.ts:657-662`）。

### 4.5 为什么 SubagentStop 和 SessionEnd 也挂 votes-sync

| 事件 | 为什么要挂 | 行为差异 | 依据 |
| --- | --- | --- | --- |
| Stop | 主路径，每轮结束一次 | 记票 + 清账本 + 推送 + 可能打印摘要 | `hook-handlers.ts:1166` |
| SubagentStop | 子代理读完文件就结束了，在这一刻把它的读取记成票；只有 `SUBAGENT_STOP_TOOLS` 里的工具注册 | **只在本地记票**：不清账本、不推送（主代理在等这个 hook，git 往返太慢），等下一次 Stop 或 pull 推送 | `hook-handlers.ts:573-575`、`:1181-1185` |
| SessionEnd | Copilot 的最后一轮可能只有 SessionEnd 没有 Stop，不挂就丢最后一轮的票 | 像 Stop 一样推送，但不打印摘要（没人读它的回复） | `hook-handlers.ts:578-580`、`:1153-1156` |

三处都调 reducer 不会重复计数：前面的 Stop 已 credit 的读取，账本和 consumed 都会挡掉（`hook-handlers.ts:1154-1155` 注释）。

### 4.6 可选：后台判官 `votes-judge`

问题：推荐的 recall 路径让子代理把摘要以文本注入主会话，主代理常常**不打开文件**就用了这条知识，没有工具调用痕迹（`hook-handlers.ts:684-687`）。

```ts
{ event: 'stop', matcher: '*', handler: votesJudgeHandler, timeoutMs: VOTES_JUDGE_TIMEOUT_MS, background: true, gitOnly: true, requiresConfig: true },
```

流程（`hook-handlers.ts:704-831`）：

1. 没设 `TEAMAI_UPVOTE_JUDGE=1`、没有 `transcript_path` 直接返回。
2. 解析 transcript 拿到被召回的 docId；**一个都没有就不往下走**（早期轮次还没召回）。
3. 先跑一遍 `creditAdoptedDocs`：判官作为后台进程启动得比前台 votes-sync 早，先跑 reducer 能让"本轮打开过的文档"进账本，不必送去判（`hook-handlers.ts:730-733`）。
4. 读账本 `creditedDocIdsForSession`（只读、不加锁，读旧了最多多判一次，不会双计，`votes.ts:116-122`），过滤掉已记过的 + 作用域不允许的。
5. `judgeAdoption(...)` 让用户本机已登录的 CLI 判断最后一条回复是否实质用了每篇文档；只读可信知识根目录里的文件节选，防止伪造的 transcript 让它读任意本地文件（`hook-handlers.ts:783-789`）。
6. `incrementUpvoted(votePath, keys, sessionId)` —— **同一个账本**，因此判官和前台不会双计；然后同样推送。

被判"没采纳"的文档下一轮还会再判；没有"本会话已判过"的标记，所以进程被杀不会留下卡死状态（`hook-handlers.ts:771-777`）。

### 4.7 手动反馈：`teamai recall feedback`

入口 `index.ts:1373-1382`，实现 `recallFeedback`（`votes.ts:648-741`）：

```ts
if (opts.positive) {
  const credited = await incrementUpvoted(votePath, [opts.positive]);
  if (credited === null) {
    log.warn(`Could not record upvote for ${opts.positive}: votes file is busy, try again`);
  } else {
    log.success(`Upvoted: ${opts.positive}`);
  }
  return;
}
```

- `--positive`：不带 sessionId，跳过账本，每次都 +1。
- `--negative`：在同一把锁里把 `upvoted_count` 减 1、`upvoted_delta` 减 1，最低到 0；计算"当前值"时取本机值与"团队文件值 + 未推 delta"的较大者，因为升级后作用域自己的文件可能是空的（`votes.ts:698-712`）。从没见过这篇文档报 `missing`，已经是 0 报 `none`。它**只撤销 upvote，不影响 recalled**。
- 全局 `--dry-run` 只打印将要做什么（`votes.ts:670-674`）。

---

## 5. 治理侧：maintenance 怎么用这些票

这一侧**不是 hook 自动跑的**，要人手动执行 `teamai recall maintenance ...` 或 promote 命令。

### 5.1 先找对目录：`resolveMaintenancePaths`

`maintenance/paths.ts:76-103`。非 HTTP 团队会先刷新 reports worktree 和 learnings 分支，且 `pushIfCreated: false`——maintenance 只是读报表，不会顺手把一个不存在的分支推上去。锁被占时抛 `CheckoutLockedError`，checkout 建不起来抛 `CheckoutUnavailableError`，都是"什么都没改"（`paths.ts:21-47`）。`--dry-run` 时什么都不建、不刷新（`paths.ts:80-85`）。

```ts
return {
  repoPath,
  votesDir: path.join(getReportsDir(localConfig), 'votes'),
  learningsWriteDir: roots.write,
  learningsReadDirs: roots.read,
};
```

`learningsWriteDir` 是能被推送的那个根，`learningsReadDirs` 是所有要读的根（优先级从高到低）。区分两者是为了处理"继承来的 learning"（见 7 节）。

### 5.2 置信度公式：`computeConfidence`

`maintenance/confidence.ts:26-42`：

```ts
export function computeConfidence(factors: ConfidenceFactors): number {
  const { recalledCount, upvotedCount, lastRecalledAt } = factors;

  const base = Math.min(1.0, recalledCount * 0.1 + upvotedCount * 0.3);

  let daysSinceRecall = 180;
  if (lastRecalledAt) {
    const elapsed = Date.now() - new Date(lastRecalledAt).getTime();
    daysSinceRecall = Math.max(0, elapsed / (1000 * 60 * 60 * 24));
  }
  const recency = Math.max(0, 1.0 - daysSinceRecall / 180);

  const ratio = upvotedCount / Math.max(1, recalledCount);

  const score = base * 0.4 + recency * 0.3 + ratio * 0.3;
  return Math.round(score * 100) / 100;
}
```

| 分量 | 含义 | 权重 |
| --- | --- | --- |
| `base` | 热度：召回一次 0.1，采纳一次 0.3，封顶 1 | 0.4 |
| `recency` | 新鲜度：距最近一次**召回**多少天，180 天线性衰减到 0；从没召回过按 180 天算 | 0.3 |
| `ratio` | 采纳率：upvoted / recalled | 0.3 |

`lastUpvotedAt` 字段被收集了但公式没用（`confidence.ts:14`、`:27`）。

`computeAllConfidence`（`confidence.ts:47-86`）把 `votesDir` 下**每个成员**的 yaml 读出来，按 docId 把 recalled、upvoted 相加，`last_recalled_at` 取最新，再算分。读用的是 `readUserVotes`，遇到 v1 文件只在内存迁移、不回写（测试 `maintenance-votes-readonly.test.ts`）。

### 5.3 四个用途

| 用途 | 入口 | 规则 | 代码 |
| --- | --- | --- | --- |
| 搜索冷热 | 建索引时自动 | 无数据 = 1.0（中性）；`>= 0.5` = 1.0；否则 0.3；搜索打分时 `score *= hotness` | `hot-cold.ts:4-26`，`search-index.ts:944`、`:1154-1155` |
| 写回 frontmatter | `--confidence-writeback` | 与已有 `confidence` 差值 `> 0.05` 才写 | `confidence.ts:94-140` |
| 淘汰 | `--prune [--threshold n] [--archive]` | 见 5.4 | `prune.ts` |
| 质量改进 | `--update-quality` | docs/rules/skills 中 recalled `>= 5`、upvoted `<= 1`、召回过它的人 `>= 2`；AI 写 `<原路径>.draft.md` | `quality-update.ts:25-89`，`index.ts:1451-1471` |
| 晋升 | promote | 见 5.5 | `promote.ts` |

### 5.4 淘汰：`findPruneCandidates` + `executePrune`

```ts
const DEFAULT_THRESHOLD = 0.15;
const STALE_DAYS = 180;
// ...
    const confidence = confidenceMap.get(docId);
    if (confidence === undefined) continue;
    const daysSinceCreate = date ? (now - new Date(date).getTime()) / (1000 * 60 * 60 * 24) : Infinity;

    if (confidence < threshold) {
      // reason: `confidence 0.xx < 0.15`
    } else if (daysSinceCreate > STALE_DAYS && confidence < 0.3) {
      // reason: `inactive Nd, confidence 0.xx`
    }
```

（`prune.ts:25-26`、`:56-77`）两条规则：分数低于阈值；或者**创建**超过 180 天（看 frontmatter `date`，没有 date 当作无穷久）且分数低于 0.3。

执行时（`prune.ts:111-123`）：`--archive` 把文件复制到 `<learningsWriteDir>/_archive/<文件名>` 再删原件；不加就直接删。两种情况都把改动的路径收集到 `changed`，交给发布。

### 5.5 晋升：`findPromotionCandidates` + `executePromotion`

门槛（`promote.ts:26-29`）：

```ts
const MIN_CONFIDENCE = 0.90;
const MIN_UPVOTED = 5;
const MIN_USERS = 2;
const MIN_AGE_DAYS = 14;
```

"人数"指**有 upvote 的成员文件数**（`aggregatePerDocVotes`，`promote.ts:256-265`）；frontmatter 已有 `promoted_to` 的跳过；没有 `date` 的不检查年龄（`promote.ts:69-72`）。

执行三步（`promote.ts:155-195`）：

1. 分类：先让本机 CLI 模型在 skills/rules/docs 里选一个，失败退回关键词计数（`inferCategory`、`inferCategoryByKeywords`）。
2. 改写：按类别给不同模板（skills = 触发条件 + 步骤 + 预期结果 + 常见坑；rules = 一句话 Always/Never + 理由 + 正反例；docs = 背景 + 概念 + 决策），去掉日期、人名、一次性事件；模型失败就**原样复制**（`promote.ts:104-149`）。写到 `<repoPath>/<category>/<文件名>`。
3. 标记：原 learning 的 frontmatter 加 `promoted_to: <category>/<文件名>`。如果原文件在不能推送的根里，标记写到 write root，否则下次 realign 会丢掉标记、下次又晋升一次、又花一次模型调用（`promote.ts:179-182`）。

### 5.6 让队友看到：`publishLearningsMaintenance`

`index.ts:1563-1574` 的 `publishMaintenance` 包了一层，失败只警告不报错。核心（`learnings-publish.ts:338-365`）：

```ts
const checkout = learningsBranch.dir(localConfig);
const inCheckout = changed
  .map((file) => path.relative(checkout, file))
  .filter((rel) => rel !== '' && !rel.startsWith('..') && !path.isAbsolute(rel));
// ...
if (!learningsBranch.enabled(localConfig)) {
  return inCheckout.length === 0 ? { status: 'already-present' } : commitMaintenance(localConfig, message, inCheckout);
}
if (inCheckout.length > 0) {
  try {
    const contents: Record<string, string | null> = {};
    for (const rel of inCheckout) contents[rel] = await contentDigest(path.join(checkout, rel));
    await recordMaintenance(checkout, { message, files: inCheckout, contents });
  } catch (e) {
    // ...
    return commitMaintenance(localConfig, message, inCheckout);
  }
}
return publishRecordedMaintenance(localConfig);
```

- 只发布 learnings checkout **里面**的文件，外面的忽略。
- 先把"这次改了哪些文件、每个文件改成了什么样（sha256，删除记 null）"写一条记录，放在 checkout 的 git 目录 `teamai-maintenance/` 下（git 不会显示也不会提交，`learnings-publish.ts:389-397`），原子写入。
- 然后发布所有积压记录，origin 收到后才删记录。注释解释原因：文件在拿锁之前就已经改了，重跑时已经"没什么可改的"，如果不留记录，一次推送失败就永远推不上去了（`learnings-publish.ts:326-337`）。

---

## 6. 一个 learning 的一生：手算置信度

主角：`learnings/redis-timeout.md`，frontmatter `date` = 第 0 天。以下数字代入 5.2 的公式；"天数"指距最近一次召回。

| 阶段 | 全员汇总 | base | recency | ratio | confidence | 后果 |
| --- | --- | --- | --- | --- | --- | --- |
| A. 刚发布，没人召回 | 无投票数据 | - | - | - | 无（Map 里没有） | hotness 1.0；prune、promote 都跳过 |
| B. 第 1 天 Alice 召回 1 次并打开 | r=1, u=1, 0 天 | min(1, 0.1+0.3)=0.4 | 1.0 | 1/1=1 | 0.16+0.30+0.30 = **0.76** | 热（>= 0.5） |
| C. 第 20 天，Alice、Bob 共召回 7 次、采纳 6 次 | r=7, u=6, 0 天, 2 人 | min(1, 0.7+1.8)=1 | 1.0 | 6/7=0.857 | 0.40+0.30+0.257 = **0.96** | 满足 >= 0.90、u >= 5、人 >= 2、满 14 天 → promote 候选 |
| D. 晋升后（frontmatter 有 `promoted_to`） | 同上 | | | | | 不再成为 promote 候选 |

对照组（同样的公式，换一篇文档）：

| 场景 | 汇总 | 计算 | confidence | 后果 |
| --- | --- | --- | --- | --- |
| 召回 1 次没人用，170 天前 | r=1, u=0 | 0.04 + 0.3×(1-170/180)=0.017 + 0 | **0.06** | < 0.15 → prune 候选；搜索 ×0.3 |
| 召回 2 次没人用，60 天前，创建已 200 天 | r=2, u=0 | 0.08 + 0.3×0.667=0.2 + 0 | **0.28** | 不低于 0.15，但创建 > 180 天且 < 0.3 → prune 候选（inactive） |
| 召回 10 次没人用，90 天前 | r=10, u=0 | 0.40 + 0.3×0.5=0.15 + 0 | **0.55** | 仍是"热"，不会被 prune |

最后一行值得注意：`base` 里召回次数也算热度，召回满 10 次 base 就封顶 1，所以"经常被召回、从没被采纳"的文档单靠召回就能拿 0.4 分，永远到不了 prune 的 0.3 线。这类文档要靠 `--update-quality`（recalled >= 5 且 upvoted <= 1）来发现——但它只扫 `docs/ rules/ skills/`，不扫 learnings（`index.ts:1455-1459`）。

---

## 7. 常见坑与边界情况

| 现象 | 原因 | 出处 |
| --- | --- | --- |
| 设置了 `TEAMAI_RECALL_DISABLED=1` 后什么都不记 | recall-attribution、votes-sync、votes-judge 开头都检查它 | `hook-handlers.ts:394`、`:552`、`:705`；测试 `recall-attribution.test.ts` "TEAMAI_RECALL_DISABLED=1 leaves nothing in the recall log, from recall or the hook" |
| HTTP 团队没有 upvote | votes-sync、votes-judge 是 `gitOnly`，HTTP 团队被调度器过滤掉 | `hook-handlers.ts:1166-1169`；`hook-handlers.test.ts:966-975` |
| 子代理读完文件，团队仓库里还没看到票 | SubagentStop 只本地记票，下一次 Stop 或 pull 才推 | `hook-handlers.ts:573-575` |
| 本轮没出现 "Adopted team knowledge" 提示 | 只在 Stop、本轮新 credit 了、且宿主打印 Stop 输出时才出现；SessionEnd 永不出现 | `hook-handlers.ts:664-670` |
| votes 文件锁忙，这轮没记上 | `incrementUpvoted` 返回 null，evidence 不标 consumed，下次重试 | `recall-adoption.ts:345-347`；测试 "11: votes lock contended at Stop → no vote now; the next trigger credits it once" |
| 推送失败票会不会丢 | 不会，deltas 只在 `onDelivered` 后才扣 | `hook-handlers.ts:612-617` |
| 项目作用域里召回的用户级文档不加票 | 继承的 user 作用域文档只读 | `eligibleUpvotes`，`hook-handlers.ts:444-462` |
| prune 说"cannot be pruned from here" | 文件在继承根（默认分支），从这里删了也推不出去，需要给团队仓库提 PR | `prune.ts:101-110`、`:128-133`；测试 `maintenance-two-roots.test.ts` "refuses to prune an inherited learning, and says what to do instead" |
| prune 的"180 天"看的不是最后活跃时间 | 看的是 frontmatter `date`（创建日期）；没有 date 视为无穷久 | `prune.ts:59` |
| writeback 后 frontmatter 没变 | 新旧差值 <= 0.05 不写 | `confidence.ts:115` |
| 继承的 learning 写回置信度/晋升标记后出现在 write root | 有意为之：写回原处会被下次 realign 冲掉 | `confidence.ts:119-125`、`promote.ts:179-189` |
| 晋升后的文件内容和原文一样 | 模型调用失败时回退为原文（含原 frontmatter） | `promote.ts:145-148` |
| `--update-quality` 只生成 `.draft.md` | 草稿需要人审，不会覆盖原文 | `index.ts:1467-1471` |

---

## 8. 动手验证

只读命令（在仓库根目录执行）：

```bash
# 公式与阈值
grep -n "0.1 + \|0.4 + \|/ 180" src/maintenance/confidence.ts
grep -n "THRESHOLD\|STALE_DAYS\|MIN_" src/maintenance/prune.ts src/maintenance/promote.ts src/maintenance/hot-cold.ts src/maintenance/quality-update.ts
# votes-sync 挂在哪些事件上
grep -n "votesSyncHandler\|votesJudgeHandler\|recallAttributionHandler" src/hook-handlers.ts
# 账本 TTL
grep -n "LEDGER_TTL_MS" src/votes.ts
# 在已配置 teamai 的项目里预演（不改任何东西）
teamai --dry-run recall maintenance --prune
teamai --dry-run recall feedback --positive some-doc-id
```

对应测试用例（`npx vitest run <文件>` 运行；测试在临时目录里造数据）：

| 文件 | 用例 |
| --- | --- |
| `src/__tests__/votes-e2e.test.ts` | "full pipeline: recall → vote → sync → confidence → hotness → search ranking"；"prune skips docs with no vote data (new docs protected)" |
| `src/__tests__/recall-attribution.test.ts` | "11: SubagentStop credits a read locally and pushes nothing mid-turn; the next Stop pushes it"；"08: Copilot SessionEnd pushes the votes it credits and prints no adopted summary"；"12: judge on: a doc the hook path credited is not sent to the judge again" |
| `src/__tests__/hook-handlers.test.ts` | "votes-judge is a no-op unless TEAMAI_UPVOTE_JUDGE=1 (opt-in)"；"votes-judge SKIPS a doc already in the session upvote ledger (no CLI call, keeps cost bounded)" |
| `src/__tests__/maintenance-prune.test.ts` | "identifies low-confidence docs"；"archive mode moves files to _archive/" |
| `src/__tests__/maintenance-promote.test.ts` | "identifies high-confidence learnings from multiple users"；"skips learnings younger than 14 days"；"copies file and marks original with promoted_to" |
| `src/__tests__/maintenance-votes-readonly.test.ts` | "computeAllConfidence aggregates v1 votes and leaves them on disk" |
| `src/__tests__/maintenance-paths.test.ts` | "reads git-kind votes from the sibling reports worktree" |

---

## 9. 自测问题

<details>
<summary>1. AI 召回了一篇文档但从没打开它，默认配置下会加 upvote 吗？</summary>

不会。默认只认工具调用证据（evidence：会话 24h 内读了 run 打印的那个路径）。只有设置 `TEAMAI_UPVOTE_JUDGE=1` 后，后台 votes-judge 才会让 LLM 判断回复是否实质用了它。
</details>

<details>
<summary>2. 同一会话里 AI 连续三轮都打开同一篇文档，upvoted_count 加几次？为什么？</summary>

加 1 次。每轮 Stop 都会调 `incrementUpvoted(..., sessionId)`，它在同一把锁里读账本 `upvotedSessions[sessionId].docIds`，已存在的 docId 被过滤掉；另外 reducer 的 `creditOf = run + key` 和 consumed 行也挡掉同一 run 的重复 credit。
</details>

<details>
<summary>3. SubagentStop 为什么不推送？SessionEnd 为什么要挂？</summary>

SubagentStop 时主代理正在等这个 hook，git 往返太慢，所以只本地记票，下一次 Stop/pull 推。SessionEnd 是给 Copilot 的：它最后一轮可能只有 SessionEnd 没有 Stop，不挂就丢票；它会推送，但不打印摘要。
</details>

<details>
<summary>4. 推送到一半网络断了，下次会不会把同样的增量合并两次？</summary>

不会。deltas 只在 `onDelivered` 回调（origin 确认收到）后才扣；而合并基准是 origin 上已确认的快照而不是 worktree 副本，所以重推时不会把本机已合并但未推出的增量叠加两次（#1027）。
</details>

<details>
<summary>5. 一篇 learning recalled=4、upvoted=0、最近召回在 0 天前，置信度多少？会被 prune 吗？</summary>

base = 0.4，recency = 1，ratio = 0 → 0.16 + 0.30 + 0 = 0.46。不低于 0.15；若创建超过 180 天也不低于 0.3，所以不会被 prune。它比 0.5 低，搜索时会被乘 0.3 降权。
</details>

---

## 10. 导航

- 上一步：[06-recall-search.md](./06-recall-search.md)（召回与检索）
- 下一步：[08-teamwiki-code-knowledge.md](./08-teamwiki-code-knowledge.md)（代码知识库）
- 索引：[README.md](./README.md)

---

## 11. 未逐行核实

- `classifyToolCall`（`utils/tool-call.ts`）如何把各工具的读/搜索调用归类、如何产出 `paths`/`status`/`simple`：只读了调用处，没读实现。
- recall log 的文件路径（`recallLogPath`）与 `run` 行由 `teamai recall` 写入的细节、`drainRecallLog` 在 pull 时的保留/清理策略：只看到注释，未读 `recall-log.ts` 与 pull 侧代码。
- `stageVotesMerge`、`confirmVotesSynced`、`syncVotesToTeam` 的完整实现（`votes.ts:451-643`）：只读了签名、注释与 `mergeDeltas`/`remainingDeltasAfter`。
- `updateReports`、`readReportsOriginFile`、`refreshReportsWorktree`（`utils/reports-branch.ts`）的加锁与推送细节，以及 `getReportsDir` 在各团队类型下的具体路径。
- `judgeAdoption`（`votes-judge.ts`）的 prompt、调用的 CLI、`VOTES_JUDGE_TIMEOUT_MS` 的值；`parseTranscriptForVotes` 的解析规则。
- `publishRecordedMaintenance` / `commitMaintenance` 的提交与推送实现（只读到 `learnings-publish.ts:338-409`）。
- promote 对应的 CLI 子命令名称与参数：只读了 `maintenance/promote.ts`，未在 `index.ts` 中核对入口。
- 投票 key 的格式：注释称 run 记录的 key 形如 `learnings/setup`（`hook-handlers.ts:756-758`），而 `computeAllConfidence`/`findPruneCandidates`/`annotateHotness` 用文件名去掉 `.md` 作 docId 去查分数；两者在各种目录布局下如何对齐，未核实。本文示例中的 `learnings/redis-timeout` 仅为示意。
- `search-index.ts:944`、`:1154-1155` 附近 hotness 的完整打分流程（只看到 `annotateHotness` 调用和 `score *= entry.hotness`）。
- 第 8 节的 `teamai --dry-run recall maintenance --prune` 在未配置团队的目录下的具体输出未实际运行。
