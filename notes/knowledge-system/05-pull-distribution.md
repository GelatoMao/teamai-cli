# 第 5 步：队友怎么拿到（pull 与分发）

> 面向小白。基于 main@fe3b906 源码（2026-10-17），代码片段标注 `文件:行号`，行号会随版本变化，以函数名为准。
> 为便于阅读删减了部分注释，用 `// ...` 省略无关分支。
> 前置阅读：[04-contribute-publish.md](./04-contribute-publish.md)（learning 怎么写进队列、发布到 `teamai-learnings` 分支）。

---

## 0. 一句话 + 一个类比

**一句话**：队友每次开新会话，teamai 都会在后台跑一次 `pull`：先把本机还没发出去的 learning 重新发布，再刷新 `teamai-learnings` 知识分支，用 learning、docs、rules、skills 重建本地搜索索引，最后给每个 AI 工具部署一条"动手前先去搜"的 recall 规则和一个 `teamai-recall` 子 agent。**learning 的正文从不塞进 AI 的上下文**，AI 拿到的只是"去哪搜、怎么搜"的说明。

**类比**：图书馆。

- pull 是夜班管理员：把新到的书（队友的 learning）上架，更新目录卡片（搜索索引）
- recall 规则是贴在阅览室门口的告示："查资料前先去目录柜"
- `teamai-recall` 子 agent 是图书管理员：读者说出需求，他去翻目录，只把相关书目的摘要递回来
- 管理员不会把整个书库搬到读者桌上（不注入正文），读者桌面（上下文窗口）保持干净

---

## 1. 为什么需要它

### 1.1 知识分支和主分支各有各的历史

learning 不发布到团队仓库主分支，而是单独的知识分支（`src/types.ts:2746`）：

```ts
export const LEARNINGS_BRANCH = 'teamai-learnings';
```

问题随之而来：队友贡献 learning 只移动知识分支，主分支 revision 不变。pull 有个"主分支没变就跳过"的快速路径，如果只看主分支，就永远看不到队友的新 learning。`src/pull.ts:1694` 的注释记录了这个坑（#704）：

```ts
          // The knowledge branch has its own history: a teammate's contribution
          // moves teamai-learnings without touching main, so main's revision is
          // an unchanged "already synced" here. Refresh it and rebuild the index
          // on the fast path too, or an ordinary pull never surfaces a teammate's
          // learning until `pull --force` (#704).
          await syncLearningsAndRebuildIndex();
```

所以知识同步被抽成独立的 helper `syncLearningsAndRebuildIndex`，快速路径和完整同步都会调用。

### 1.2 为什么不把 learning 直接塞进上下文

`src/builtin-rules.ts:20` 的文件头注释说明了现方案替代了什么：

```ts
//  teamai-recall.md instructs the AI to proactively search the team
//  knowledge base (via the `teamai-recall` subagent or `teamai recall`)
//  before starting a task — this replaced the old passive auto-recall
//  PostToolUse hook, which fired implicitly on every Bash/Grep/WebSearch/
//  WebFetch call but added noise without the benefit of the subagent's
//  codebase-graph drill-down and compact structured output.
```

子 agent 定义（`agents/teamai-recall.md:9`）把动机写得更直白：

```text
You are a knowledge retrieval agent for the **teamai** ecosystem. Your sole
job is to search the local team knowledge base and return a **compact**
structured summary to the main conversation. The main conversation will
delegate tasks to you so its own context window is not polluted by raw
knowledge content.
```

设计取舍：

| 方案 | 优点 | 缺点 |
| --- | --- | --- |
| 把全部 learning 拼进 CLAUDE.md / SessionStart | AI 一定"看到" | 知识越多上下文越大，大部分与当前任务无关 |
| 旧的 PostToolUse 自动召回 hook | 不用 AI 主动 | 每次 Bash/Grep 都触发，噪音大 |
| 现在：规则 + 子 agent + 本地索引 | 上下文只多一段固定规则；按需检索；结果压缩 | 依赖 AI 遵守规则，有跳过条件，可能漏搜 |

### 1.3 为什么 pull 要在后台跑

pull 要 `git fetch`、更新子模块、对账资源，冷启动很慢。`src/hook-handlers.ts:90`：

```ts
/**
 * Budget for the detached session-start pull.
 *
 * A background handler's timeout is not advisory: the dispatch pass settles on
 * it and index.ts then `process.exit(0)`s, truncating whatever is still running
 * (git children orphaned, later sync stages never run). Cold pulls — fetch,
 * submodule update, resource reconcile — measured 10-25s, so the shared 15s
 * budget silently cut the pull short. ...
 */
export const PULL_TIMEOUT_MS = 120_000;
```

要点：

- 后台 handler 的超时是"硬"的：到点后进程直接 `process.exit(0)`，没跑完的同步阶段就丢了
- 实测冷启动 10-25 秒，原来共用的 15 秒预算会把 pull 悄悄截断，所以单独给 120 秒
- pull 不需要向宿主返回任何东西，放前台只会拖慢会话启动（调度器的前后台拆分见 [01-hook-layer.md](./01-hook-layer.md)）

---

## 2. 端到端流程图

```text
队友打开 AI 工具，触发 SessionStart
  │  teamai hook-dispatch session-start --tool <tool>
  ▼
┌─ buildHandlerRegistry()  hook-handlers.ts:1130 ───────────────────────┐
│ 前台：teamRulesHandler 等（FOREGROUND_HOOK_TIMEOUT_MS）               │
│ 后台：pullHandler（PULL_TIMEOUT_MS = 120s, background: true）         │
└───────┬───────────────────────────────────────┬───────────────────────┘
        │ 前台（宿主等结果）                      │ 后台（脱离宿主的子进程）
        ▼                                       ▼
┌─ teamRulesHandler :940 ───────────┐   ┌─ pullHandler :113 ─────────────────────┐
│ 仅 project scope 且工具没有自己的 │   │ 配置不可读 / 工具被排除 → 直接返回      │
│ 规则格式（Codex 系列、ZCode 等）  │   │ seedProjectAgentRoot                   │
│ additionalContext =               │   │ pull({ silent: true })                 │
│   culture + claudemd + recall 块  │   └───────────┬────────────────────────────┘
│   + 团队 rules 文本               │               ▼
│ （不含 learning 正文）            │   ┌─ pull.ts（每个 scope 一遍）─────────────┐
└───────────────────────────────────┘   │ A. publishQueuedLearnings  :1301        │
                                        │    队列里没发出去的 learning 先重发      │
                                        │ B. 主分支 rev 没变且目标集合一致？       │
                                        │    ├ 是 → 快速路径 :1616                 │
                                        │    │   部署内置 agent / rule / 指令块    │
                                        │    │   syncLearningsAndRebuildIndex()    │
                                        │    └ 否 → 完整同步                       │
                                        │        Step 4.5 deployBuiltinRules :2139 │
                                        │        Step 4.6 deployBuiltinAgents:2152 │
                                        │        syncManagedInstructions、索引重建 │
                                        └───────────┬─────────────────────────────┘
                                                    ▼
                         ┌─ syncLearningsAndRebuildIndex :1394 ──────────────────┐
                         │ learningsBranch.refresh(pushIfCreated:false) 只读刷新 │
                         │ user scope：镜像到 ~/.teamai/learnings/               │
                         │ buildIndex({ learningsDirs:[pending, ..., published], │
                         │   docsDir, rulesDir, skills, votesDir, indexPath })   │
                         └───────────────────────────────────────────────────────┘
落盘结果：
  - 本地搜索索引（indexPath，供 teamai recall 读）
  - <工具 rules 目录>/teamai-recall.md|.mdc|...  （recall 开启时）
  - <工具 agents 目录>/teamai-recall.<ext>        （recall 开启时）
  - 指令文件里的 <!-- [teamai:recall-rules:start] --> ... <!-- [teamai:recall-rules:end] --> 块
```

---

## 3. 入口：pullHandler

### 3.1 注册：后台 + 独立超时

`src/hook-handlers.ts:1133`：

```ts
    // pull does not produce output the host needs; run detached so git fetch
    // on a slow network cannot delay session startup. Its own generous budget
    // (PULL_TIMEOUT_MS) — the shared 15s truncated the pull itself.
    { event: 'session-start', matcher: '*', handler: pullHandler, timeoutMs: PULL_TIMEOUT_MS, background: true },
    { event: 'session-start', matcher: '*', handler: dashboardReportHandler, timeoutMs: FOREGROUND_HOOK_TIMEOUT_MS, requiresConfig: true },
    { event: 'session-start', matcher: '*', handler: teamRulesHandler, timeoutMs: FOREGROUND_HOOK_TIMEOUT_MS, requiresConfig: true },
```

两点值得注意：

- pullHandler 没有 `requiresConfig: true`，没配置 teamai 的目录也会进来，由 handler 自己判断
- 它是 SessionStart 里唯一 `background: true` 的。后果是：本次会话启动时 AI 用到的规则和索引，是**上一次** pull 留下的；这次 pull 的成果要等它跑完才生效（下一次 `teamai recall` 读索引、或下一次会话读规则）

### 3.2 handler 本体

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
    // ... 记录 pull 前的 package manifest 哈希
    try {
      const { seedProjectAgentRoot } = await import('./project-agent-root.js');
      await seedProjectAgentRoot(tool, cwd);
    } catch (e) { /* ... log.debug */ }
    const { pull } = await import('./pull.js');
    await pull({ silent: true });
    // ... stashPackageHintAfterPull
    return null;
  },
};
```

逐段看：

1. **项目配置读不了就不拉**：没解析到 config 时，区分"这里根本没装 teamai"和"项目配置文件存在但读不了"。后者直接返回，注释（:117）给的理由是：读不了的时候，探测逻辑接下来加载的可能是另一个团队的配置（#784）
2. **被排除的工具不拉**：`uninstall --agent` 排除了某工具后，它的 hook 若还残留，pull 会把删掉的东西又装回去（#993）
3. **`pull({ silent: true })`**：真正干活的地方，静默模式，返回 `null`，宿主拿不到任何输出——这是后台 handler 的本分

---

## 4. pull.ts 里与知识有关的四件事

`pull()` 很长（3700+ 行的文件），下面只摘和知识分发有关的部分，按执行顺序排列。

### 4.1 先重发队列里的 learning

`src/pull.ts:1294`：

```ts
  // Publish what contribute queued. Here rather than inside the refresh, which
  // returns early for single-repo and HTTP: contribute tells the member the next
  // pull will retry, and that has to hold in every mode. ...
  if (!options.inline) try {
    const queue = await publishQueuedLearnings(localConfig, localConfig.username, { holdsSyncLock: true, dryRun: options.dryRun });
    // ... dry-run 提示 / 成功提示
    if (queue.remaining > 0 && !options.dryRun) {
      reported.add('pending-learnings');
      log.warn(
        `${queue.remaining} learning(s) are written locally but not published`
        + `${queue.lastError ? `: ${queue.lastError}` : ''}. `
        + 'They stay recallable here; run `teamai doctor` for what to check.',
      );
    }
  } catch (e) {
    log.debug(`publishing queued learnings skipped: ${(e as Error).message}`);
  }
```

这兑现了 [04 篇](./04-contribute-publish.md) 里 contribute 的承诺"下次 pull 会重试"：

- 放在这里而不是知识分支刷新函数里，是因为刷新函数对单仓库模式和 HTTP 模式会提前返回，而重试必须在所有模式下都成立
- `holdsSyncLock: true`：pull 已经持有分区同步锁，锁不可重入，发布时不能再去抢
- 发不出去也不阻塞 pull，只打一条 warn：这些 learning "在本机仍可被 recall 到"
- 位置在读 `teamai.yaml`（:1323）之前，所以就算团队配置缺失导致后面提前 return，重发也已经做过了

### 4.2 快速路径：主分支没动，但知识照样刷新

`src/pull.ts:1608` 起，主分支 rev 与上次一致、目标工具集合也一致时走快速路径：

```ts
        if (targetSetMatches) {
          log.success(`[${scopeLabel}] Already synced at ${currentRev}, skipping`);
          // 即使 repo 未变化，仍部署 CLI 内置资源（确保 CLI 升级后新版本 agent/rules 生效）
          const skipRecall = !isRecallEnabled(localConfig, freshConfig);
          const { recorder } = policy;
          try { const { deployBuiltinAgents } = await import('./builtin-agents.js'); await deployBuiltinAgents(freshConfig, localConfig, { skipRecall, recorder }); } catch {}
          try { const { deployBuiltinRules } = await import('./builtin-rules.js'); await deployBuiltinRules(freshConfig, localConfig, { skipRecall, recorder }); } catch {}
          // ... deployBuiltinSkills、reclaimReservedRuleCopies
          const delivery = await syncManagedInstructions(freshConfig, localConfig, roleContext, scopeLabel, false, recorder);
          // ... 清理墓碑资源、重渲染规则、agent 模型、env
          await syncLearningsAndRebuildIndex();
          await syncWorkflows(localConfig, !!options.dryRun, scopeLabel);
          return;
        }
```

"跳过"只跳过团队资源的重新对账。三类东西每次都做：

| 动作 | 为什么快速路径也要做 |
| --- | --- |
| 部署内置 agent / rule | 团队仓库没变，但 CLI 可能升级了，新版规则要生效（中文注释原话） |
| `syncManagedInstructions` | CLI 升级可能换了指令文件位置或 recall 块内容（:1630 注释） |
| `syncLearningsAndRebuildIndex` | 知识分支独立演进（#704，见 1.1） |

### 4.3 完整同步里的 Step 4.5 / 4.6

`src/pull.ts:2138`：

```ts
  // Step 4.5: Deploy CLI built-in rules
  try {
    const { deployBuiltinRules } = await import('./builtin-rules.js');
    const skipRecall = !isRecallEnabled(localConfig, freshConfig);
    const deployed = await deployBuiltinRules(freshConfig, localConfig, { skipRecall, recorder, dryRun });
    // ...
  } catch (e) {
    recorder?.failed('builtin');
    log.debug(`[${scopeLabel}] Built-in rules deployment skipped: ${(e as Error).message}`);
  }

  // Step 4.6: Deploy CLI built-in agents (e.g. teamai-recall subagent)
  try {
    const { deployBuiltinAgents } = await import('./builtin-agents.js');
    const skipRecall = !isRecallEnabled(localConfig, freshConfig);
    const deployed = await deployBuiltinAgents(freshConfig, localConfig, { skipRecall, recorder, dryRun });
    // ...
```

和快速路径一样，两处都用 `skipRecall = !isRecallEnabled(...)` 决定是否带上 recall 相关文件；失败只记 `recorder.failed('builtin')` 和 debug 日志，不中断 pull。

### 4.4 syncLearningsAndRebuildIndex：刷新知识分支 + 重建索引

`src/pull.ts:1394`，先看开头：

```ts
  const syncLearningsAndRebuildIndex = async (): Promise<void> => {
    // Inline (new-worktree hook): the detached pull after it does this.
    if (options.dryRun || options.inline) return;
    const reportsRootReady = resolveReportsReadRoot();
    try {
      try {
        const { learningsBranch } = await import('./utils/learnings-branch.js');
        const refreshed = await learningsBranch.refresh(localConfig, { pushIfCreated: false });
        // Busy or failed: index what is there.
        if (refreshed.status === 'failed') log.debug(`learnings worktree unavailable: ${refreshed.reason}`);
      } catch (e) {
        log.debug(`learnings worktree unavailable: ${(e as Error).message}`);
      }
      // ...
```

- `pushIfCreated: false`：只读刷新。上方注释（:1391）强调它"从不发布"，所以在快速路径里调用也不会在同步锁之外把队列 flush 出去
- 刷新失败不致命："Busy or failed: index what is there"——用本地已有的内容建索引

user scope 和 project scope 处理 learning 的位置不同（`:1427` 注释）：

```ts
      // user scope: sync learnings to ~/.teamai/learnings/ (legacy behavior)
      // project scope: use learnings directly from repo
```

user scope 下会调用 `mirrorLearnings(mirrorSources, getUserLearningsDir(), ...)` 把已发布根目录镜像到 `~/.teamai/learnings/`；而且只有在所有源都能读（`unresolved.length === 0`）时才镜像，因为镜像会删除"没有任何源拥有"的文件，源缺一个就可能误删（`:1467` 注释）。

最后是建索引（`src/pull.ts:1523`）：

```ts
        const elapsed = await buildIndex({
          // The queue comes first: a contribution that could not be published
          // yet stays recallable, and a queued edit wins over the published copy.
          learningsDirs: [
            pendingLearningsDir(localConfig),
            ...(localConfig.scope === 'user' ? [getUserLearningsDir()] : []),
            ...publishedRoots,
          ],
          learningsNamespaces: activeLearningsNamespaces,
          docsDir: docsRepoDir,
          docFiles,
          rulesDir: rulesRepoDir,
          ruleFiles,
          skills: await skillsToIndex(),
          unreadable: unresolved,
          children: localConfig.children?.fingerprint,
          codebaseDir: undefined, // codebase now served by teamwiki/ graph engine
          votesDir: votesExist ? votesDir : undefined,
          indexPath,
        });
```

这是本篇最关键的数据结构，逐项解释：

| 字段 | 来源 | 含义 |
| --- | --- | --- |
| `learningsDirs[0]` | `pendingLearningsDir(localConfig)` | 发布队列。排第一：没发出去的 learning 也能被搜到，队列里的编辑优先于已发布版本 |
| `learningsDirs` 中段 | `~/.teamai/learnings/`（仅 user scope） | 上一步的镜像 |
| `publishedRoots` | `indexableLearningsRoots(...)` | 知识分支检出后的各个已发布根目录 |
| `learningsNamespaces` | `roleContext?.activeNamespaces.learnings` | 只索引当前项目选中的子目录；根目录下的平铺 `.md` 永远共享 |
| `docsDir` / `rulesDir` | `<团队仓库>/docs`、`<团队仓库>/rules` | 只索引 pull 实际下发的那部分文件（#707） |
| `codebaseDir` | 固定 `undefined` | 代码知识已改由 teamwiki 图谱引擎提供（见 [08 篇](./08-teamwiki-code-knowledge.md)） |
| `votesDir` | reports 检出下的 `votes/` | 反馈投票（见 [07 篇](./07-feedback-governance.md)） |
| `indexPath` | `getProjectSearchIndexPath(localConfig)` | 索引文件落盘位置 |

触发条件（`:1503`）：任一类别有内容、或已有索引文件存在时才建。后者是 #1006 的修复——源全部消失后，旧索引不能继续返回已不再下发的内容。

**重点**：索引只是本地文件，`buildIndex` 不往任何 AI 工具的上下文里写东西。learning 正文要等 AI 主动 `teamai recall` 时才被读取（[06 篇](./06-recall-search.md)）。

---

## 5. 内置规则：builtin-rules.ts

### 5.1 名单与保留名

`src/builtin-rules.ts:28`：

```ts
export const BUILTIN_RULE_NAMES = new Set<string>(['teamai-recall']);
export const LEGACY_RULE_NAMES: string[] = [];
export const TEAMAI_CONTEXT_RULE_NAME = 'teamai-context';
export const EXCLUDED_RULE_NAMES = new Set<string>([
    ...BUILTIN_RULE_NAMES,
    ...LEGACY_RULE_NAMES,
    TEAMAI_CONTEXT_RULE_NAME,
]);
```

- `teamai-recall`：唯一的内置规则，由 CLI 维护，push 时排除，不进团队仓库
- `teamai-context`：对于"规则目录就是指令目标"的工具，pull 把 culture、claudemd、recall 三个块写进这个规则文件（:35 注释，#945）
- `EXCLUDED_RULE_NAMES`：push 扫描和陈旧清理都会跳过这几个名字，团队不能用它们命名自己的 rule

### 5.2 deployBuiltinRules

`src/builtin-rules.ts:57`（省略 dry-run 与 legacy 清理）：

```ts
export async function deployBuiltinRules(
    teamConfig: TeamaiConfig,
    localConfig?: LocalConfig,
    options?: { skipRecall?: boolean; recorder?: DeliveryRecorder; dryRun?: boolean },
): Promise<number> {
    // ...
    const builtinRules: Array<{ name: string; content: string }> = [
        { name: 'teamai-recall', content: recallRuleContent(teamConfig.language) },
    ].filter(r => !(options?.skipRecall && r.name === 'teamai-recall'));

    for (const [tool, toolPath] of Object.entries(scopedToolPaths(teamConfig, localConfig ?? {}))) {
        if (!toolPath.rules) continue;
        // ... 未安装 → 跳过；isAgentExcluded → 跳过；rulesDir 不存在 → 跳过
        try {
            await ensureDir(rulesDir);
            const ext = ruleFileExtensionForTool(tool);
            for (const rule of builtinRules) {
                const destFile = path.join(rulesDir, `${rule.name}${ext}`);
                const content = renderRuleForTool(tool, rule.content);
                await writeFile(destFile, content);
                // ...
                // Drop the `.md` copy an older layout left in an `.mdc` rules dir.
                if (ext !== '.md') {
                    try { await fs.unlink(path.join(rulesDir, `${rule.name}.md`)); } catch {}
                }
            }
            // ... 清理 LEGACY_RULE_NAMES
            deployed++;
        } catch (e) { /* recorder.failed + log.error */ }
    }
    return deployed;
}
```

逐段：

1. `skipRecall` 为真时，过滤掉唯一的规则，循环照跑但什么都不写
2. 只处理配置了 `rules` 路径、已安装、未被排除、且规则目录**已存在**的工具（`pathExists(rulesDir)` 为假就 `continue`，不会凭空创建）
3. 每个工具用自己的格式：`ruleFileExtensionForTool` 决定扩展名（例如 Cursor 是 `.mdc`），`renderRuleForTool` 补该工具要的 frontmatter
4. 扩展名不是 `.md` 时，顺手删掉旧版本遗留的 `.md` 副本，避免重复加载
5. 每次 pull 都**无条件覆盖**写入，所以 CLI 升级后规则内容自动更新

### 5.3 recallRuleContent：按团队语言选正文

`src/builtin-rules.ts:258`：

```ts
/** Recall rule body for `teamai.yaml` `language`. `en` is English only; anything else is the historical bilingual text (#1014). */
export function recallRuleContent(language?: 'en' | 'zh'): string {
    return language === 'en' ? TEAMAI_RECALL_RULE_CONTENT_EN : TEAMAI_RECALL_RULE_CONTENT;
}
```

`teamai.yaml` 里 `language: en` 才用纯英文版，不写或写 `zh` 都是历史上的中英混排版。两个版本内容结构一致（`:177`、`:222`）：

1. 自豁免：如果你自己就是 `teamai-recall` 子 agent，不要再调用 recall——防止 Cursor 这类会把 always-apply 规则漏进子 agent 会话的工具无限递归
2. 规则：涉及代码改动、调试、设计决策的任务开始前"SHOULD"检索
3. 三个跳过条件：用户已给上下文、本地文件已有答案、简单局部改动
4. 方式一：调 `teamai-recall` 子 agent；方式二：`teamai recall "<关键词>"`
5. 输出含 `Nothing was searched:` 或 `Recall skips the older index` 时要把原话转告用户，不能断言"团队没有相关知识"
6. 检索是纯词法匹配，领域术语要中英双写，专有名词、标识符、错误码保持原样

注意：整条规则里没有任何一条具体 learning，只有"去搜"的方法。

### 5.4 isDeployedRecallRule：用哈希认出"原封未动的旧版本"

`src/builtin-rules.ts:145`：

```ts
/**
 * SHA-256 of every `teamai-recall` rule body a teamai version deployed under
 * TEAMAI_RECALL_RULE_HEADING, newest first ... The built-ins are not in the delivery ledger, so
 * these hashes are what proves a copy in a Codex legacy rules dir unedited.
 * ...
 */
const DEPLOYED_RECALL_RULE_HASHES = new Set<string>([
    '37d1a34f733bfb15e291b08bd17951f2764b91047117d1b2c396e7d01c67c038',
    // ... 共 11 个
]);

export function isDeployedRecallRule(content: string): boolean {
    return DEPLOYED_RECALL_RULE_HASHES.has(crypto.createHash('sha256').update(content).digest('hex'));
}
```

为什么需要它：团队资源有"交付台账"记录 pull 写了什么，内置规则不在台账里。当某个旧位置（如 Codex 的旧 rules 目录）要清理时，teamai 必须区分"这是我当年写的原样副本，可以删"和"成员自己改过，必须保留"。办法是把历来发布过的每个版本正文的 SHA-256 列成白名单，内容哈希命中才算 teamai 所有。调用方在 `src/resources/rules.ts:1209`：

```ts
        if (recallContent !== null) (isDeployedRecallRule(recallContent) ? owned : edited).push(recall);
```

维护约定（注释原话的意思）：任一版本正文改动，都要把新哈希加进来。

---

## 6. 内置子 agent：builtin-agents.ts

源文件在 npm 包里的 `agents/teamai-recall.md`，pull 时按工具渲染后复制过去（`src/builtin-agents.ts:15` 的示意图）：

```ts
//  npm package
//    agents/teamai-recall.md
//      │
//      ▼  (teamai pull)
//    ~/.claude/agents/teamai-recall.md
//    ~/.claude-internal/agents/teamai-recall.md
//    ~/.codebuddy/agents/teamai-recall.md
```

`deployBuiltinAgents`（`:95`）的骨架：

```ts
  const builtinDir = getBuiltinAgentsDir();
  if (!await pathExists(builtinDir)) { /* ... */ return 0; }
  // ...
  const agentFiles = entries
    .filter((f) => f.endsWith('.md') && !f.startsWith('.'))
    .filter((f) => !(options?.skipRecall && f === 'teamai-recall.md'));
  // ...
  for (const [tool, toolPath] of Object.entries(scopedToolPaths(teamConfig, localConfig ?? {}))) {
    if (!toolPath.agents) { /* ... */ continue; }
    // ... 未安装、被排除 → 跳过
    if (!(ALL_SUPPORTED_TOOLS as string[]).includes(tool)) { log.warn(/* unsupported agent format */); continue; }
    // ...
    for (const file of agentFiles) {
        const parsed = source ? reverseFromClaude(src, source) : { ok: false as const, reason: 'cannot read source file' };
        // ...
        const rendered = renderForTool(parsed.spec, tool as ToolName);
        // ...
        await removeStaleAgentSiblings(targetAgentsDir, stem, rendered.ext);
        const dest = path.join(targetAgentsDir, `${stem}${rendered.ext}`);
        await writeFile(dest, rendered.content);
```

与 deployBuiltinRules 的区别：

| 点 | deployBuiltinRules | deployBuiltinAgents |
| --- | --- | --- |
| 路径字段 | `toolPath.rules` | `toolPath.agents` |
| 目录不存在 | 跳过 | `ensureDir` 创建 |
| 格式转换 | `renderRuleForTool` | 先 `reverseFromClaude` 解析 Claude 格式，再 `renderForTool`（例如 Codex `.toml`、Kiro `.json`，见 `:67` 注释） |
| 换扩展名 | 删同名 `.md` | `removeStaleAgentSiblings` 删同名不同扩展名的旧文件 |
| 不支持的工具 | 无此分支 | warn 并跳过 |

子 agent 自己运行 recall 时带 `--caller teamai-recall`（`agents/teamai-recall.md:28`）：

```bash
teamai recall --caller teamai-recall --check "<3-6 keywords from the task>"
```

它的 frontmatter 只给了 `tools: Bash, Read, Grep, Glob`，返回的是带 doc_id 的压缩摘要，正文留在子 agent 自己的上下文里。

---

## 7. 指令文件里的 recall 块

规则目录不是唯一的投放点。很多工具读的是一个"指令文件"（CLAUDE.md、AGENTS.md 一类），pull 会在里面维护一段带标记的块。标记定义在 `src/types.ts:1528`：

```ts
export const TEAMAI_RECALL_RULES_START = '<!-- [teamai:recall-rules:start] -->';
export const TEAMAI_RECALL_RULES_END = '<!-- [teamai:recall-rules:end] -->';
```

### 7.1 两种块，一套标记

`resolveInstructionBlocks`（`src/pull.ts:2417`）同时生成两种：

```ts
  const recallEnabled = isRecallEnabled(localConfig, config);
  const blocks: InstructionBlocks = {
    recall: recallEnabled ? compileRecallRulesBlock() : null,
    directRecall: recallEnabled ? compileDirectRecallRulesBlock() : null,
  };
```

| 块 | 函数 | 给谁 | 内容要点 |
| --- | --- | --- | --- |
| `recall` | `compileRecallRulesBlock`（`:2598`） | 有 `agents` 路径、装了子 agent 的工具 | 自豁免；先单独调 `teamai-recall` 子 agent，别和 Explore 并行；recall 管 `.teamai/`、`learnings/`、`docs/team-codebase/`，Explore 管源码和网页 |
| `directRecall` | `compileDirectRecallRulesBlock`（`:2552`） | 没有子 agent 的工具 | 直接跑 `teamai recall "<3-6 keywords>"`；多一条跳过条件，可用 `teamai recall --check` 预判 `RELEVANT` / `NOT_RELEVANT` |

两者用同一对标记（`:2548` 注释），读取和删除逻辑就不用区分。选哪个由 `src/instruction-targets.ts:926` 决定：

```ts
    const recall = target.recall ? blocks.recall : blocks.directRecall;
```

块的取值有三态：字符串（写入）、`null`（recall 关了，移除）、`undefined`（来源读不出，保留原样，见 `InstructionBlocks` 定义 `src/instruction-targets.ts:272` 及其上方注释）。

### 7.2 写到哪些文件

`syncManagedInstructions`（`src/pull.ts:2466`）调 `resolveInstructionTargets` 拿到每个工具的目标文件，再 `planInstructionFiles` / `applyInstructionPlan` 写入。具体每个工具对应哪个文件由 `instruction-targets.ts` 的表决定（`instructionTargetFile`，`:286`）；对于"规则目录就是指令目标"的工具，写进的是 `teamai-context` 规则文件（5.1）。还有一类工具不读文件，由 hook 注入——见下一节。

---

## 8. SessionStart 前台：teamRulesHandler 注入了什么

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

- 只服务一类工具：project scope 下"没有规则格式、也没有自己的项目文件"的工具（上方注释 `:930` 点名 Codex 系列、ZCode、DeepSeek Harness）。项目 `AGENTS.md` 归项目所有者，teamai 不往里写，所以改由 hook 注入
- `resume` 会话跳过：历史里已经有了
- 注入内容 = `instructionHookTextFor` 的文本（culture、claudemd、recall 三块，`src/instruction-targets.ts:318` 的 `instructionHookText` 拼接）+ 团队 rules 文本
- recall 块按工具有无 `agents` 路径选 `recall` 或 `directRecall`（`instruction-targets.ts:347`）；如果项目原生 `AGENTS.md` 里已有 recall 标记，就置 `null` 不重复注入（`:345`）

所以即便是走 hook 注入的路径，进入 `additionalContext` 的也只是"去搜"的指令，没有 learning 正文。

---

## 9. recall 开关如何影响分发

判定函数 `src/types.ts:268`：

```ts
/** Resolve whether recall is enabled: user override > team config > default (false). */
export function isRecallEnabled(
  localConfig: { recallEnabled?: boolean },
  teamConfig: { sharing?: { recall?: { enabled?: boolean } } },
): boolean {
  if (localConfig.recallEnabled !== undefined) return localConfig.recallEnabled;
  return getRecallSharing(teamConfig).enabled;
}
```

`getRecallSharing`（`:225`）的默认值是 `false`。优先级：本机 `recallEnabled` > 团队 `sharing.recall.enabled` > 关。

| 开关为假时 | 效果 |
| --- | --- |
| `deployBuiltinRules(..., { skipRecall: true })` | 不写 `teamai-recall` 规则 |
| `deployBuiltinAgents(..., { skipRecall: true })` | 不写 `teamai-recall` 子 agent |
| `resolveInstructionBlocks` | `recall` / `directRecall` 都是 `null`，指令文件里的标记块被移除 |
| 索引重建 | 不受影响，`syncLearningsAndRebuildIndex` 不看这个开关 |

用户手册 `docs/guide/zh-CN/knowledge.md:60` 的说明与代码一致："默认关"；团队在 `teamai.yaml` 写 `sharing.recall.enabled: true`；本机用 `teamai recall enable|disable|status`，覆盖值写在 `~/.teamai/config.yaml` 的 `recallEnabled`；"关掉之后 pull 不再安装 recall；直接运行 `teamai recall` 仍然可以搜"。手册还提到 `TEAMAI_RECALL_DISABLED=1` 强制关闭——在 `src/` 中它出现在 `recall.ts:796` 和几个 hook handler（如 `hook-handlers.ts:394`），**不在** `isRecallEnabled` 里，也就是说它不改变 pull 部署什么。

---

## 10. 常见坑与边界情况

| 现象 | 原因（代码/注释出处） |
| --- | --- |
| 队友刚发了 learning，我这边搜不到 | pull 在后台，本次会话用的是上次的索引；另外旧版本快速路径不刷新知识分支（#704，`pull.ts:1694`） |
| 开了 recall，但某工具没有 `teamai-recall` 规则文件 | 该工具 rules 目录不存在时 `deployBuiltinRules` 直接 `continue`，不创建目录（`builtin-rules.ts:84`） |
| 某工具没有子 agent | 没配 `agents` 路径或不在 `ALL_SUPPORTED_TOOLS`（后者会 warn）；这类工具拿到的是 `directRecall` 块 |
| 自己改过 `teamai-recall.md`，被覆盖了 | 正常规则目录每次 pull 无条件覆盖；只有 Codex 旧目录的清理会用哈希判断是否保留（`isDeployedRecallRule`） |
| pull 里看到 "learning(s) are written locally but not published" | 队列重发失败，learning 留在 `pendingLearningsDir`，索引里排第一所以本机仍能搜到（`pull.ts:1311`、`:1524`） |
| Cursor 里 recall 子 agent 无限递归 | 规则开头的"自豁免"段就是为此写的（`builtin-rules.ts:179`） |
| 源全部移除后 recall 还返回旧内容 | 已修：索引文件存在时也会重建（#1006，`pull.ts:1501`） |
| 想用 `teamai-context` 作为团队规则名 | 它在 `EXCLUDED_RULE_NAMES` 里，是保留名；旧版本留下的同名团队规则副本会被 `reclaimReservedRuleCopies` 收回（`pull.ts:1633`） |

---

## 11. 动手验证

只读命令（在自己的机器上执行）：

```bash
# 本机 recall 开关状态
teamai recall status
# 预演一次 pull，看内置规则/agent/指令块会落到哪里，不写任何文件
teamai pull --dry-run
# 看某个工具的内置规则和子 agent（以 Claude Code 为例）
ls ~/.claude/rules/ ~/.claude/agents/ 2>/dev/null | grep teamai
# 看指令文件里的 recall 块
grep -n "teamai:recall-rules" ~/.claude/CLAUDE.md
```

相关测试（`npx vitest run <文件>`）：

- `src/__tests__/builtin-rules.test.ts`
  - `should deploy teamai-recall.md rule to tool rules directory`
  - `deploys an English-only recall rule when language is en and treats that body as teamai-owned (#1014)`
  - `keeps the historical bilingual recall rule when language is omitted or zh (#1014)`
  - `should deploy the recall rule to cursor as .mdc, not an ignored .md`
  - `should skip tool directories that do not exist (tool not installed)`
- `src/__tests__/builtin-agents.test.ts`
  - `deploys built-in agent files to every installed tool with agents path`
  - `renders the recall agent in OpenCode native format`
  - `the deployed recall agent marks every recall it runs and asks for no referenced-doc-ids`
  - `removes a stale same-stem sibling when re-rendering to a different extension`
- `src/__tests__/codex-legacy-rules.test.ts`
  - `removes the built-in teamai-recall.md as teamai deployed it`
  - `keeps a teamai-recall.md the member edited after the last pull that wrote it`

---

## 12. 自测问题

<details>
<summary>1. 为什么 pullHandler 要单独用 120 秒超时，而不是共用 15 秒？</summary>

后台 handler 的超时到点后进程会 `process.exit(0)`，没跑完的阶段直接丢失；冷启动 pull 实测 10-25 秒，15 秒会悄悄截断（`hook-handlers.ts:90`）。
</details>

<details>
<summary>2. 主分支没有新提交时，pull 还会刷新队友的 learning 吗？</summary>

会。快速路径同样调用 `syncLearningsAndRebuildIndex()`，因为知识分支 `teamai-learnings` 有独立历史（#704）。
</details>

<details>
<summary>3. 关掉 recall 后，本地索引还会重建吗？`teamai recall` 还能用吗？</summary>

都会/能。开关只通过 `skipRecall` 和指令块 `null` 控制"部署给 AI 的规则和子 agent"，索引重建不看它。
</details>

<details>
<summary>4. 一个工具没有子 agent，它怎么知道要去搜？</summary>

它的指令文件（或 SessionStart 注入）拿到的是 `compileDirectRecallRulesBlock` 生成的块，让 AI 直接运行 `teamai recall "<keywords>"`。
</details>

<details>
<summary>5. learning 正文在哪一步进入 AI 上下文？</summary>

pull 阶段从不进入。只有 AI 主动运行 `teamai recall`（通常经由子 agent）时，才读取索引并返回压缩摘要，见下一篇。
</details>

---

上一步：[04-contribute-publish.md](./04-contribute-publish.md)　|　索引：[README.md](./README.md)　|　下一步：[06-recall-search.md](./06-recall-search.md)

---

## 未逐行核实

- `learningsBranch.refresh`（`src/utils/learnings-branch.js`）内部如何 fetch / 检出知识分支、worktree 放在哪里，本文未读其源码
- `publishQueuedLearnings` 的重试细节（锁、次数）未读实现，以 [04 篇](./04-contribute-publish.md) 为准
- `buildIndex` 的索引格式、`getProjectSearchIndexPath` 的具体路径，以及 `indexableLearningsRoots`、`mirrorLearnings` 的实现未读
- `resolveInstructionTargets` / `planInstructionFiles` / `applyInstructionPlan` 以及 `instruction-targets.ts` 中"工具 -> 指令文件"映射表未逐行读，所以本文没有列出每个工具的具体目标文件
- `renderRuleForTool`、`ruleFileExtensionForTool`、`renderForTool`、`reverseFromClaude` 的各工具格式细节未读
- `getsRulesFromSessionHook` 返回真的完整工具清单未核实，仅引用了 `teamRulesHandler` 上方注释
- "动手验证"中的 `~/.claude/rules/`、`~/.claude/CLAUDE.md` 路径是按常见 Claude Code 布局写的示例，未在 `toolPaths` 默认值中逐项核实；`teamai pull --dry-run` 的输出格式未实际运行
- `TEAMAI_RECALL_DISABLED` 只核实了它在 `src/` 中出现的位置，未读 `recall.ts:796` 处的完整语义
