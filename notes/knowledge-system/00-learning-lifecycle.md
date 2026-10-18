# 第 0 篇：一条 learning 的一生（端到端追踪）

> 面向小白。01~08 按"零件"拆开讲；本文反过来，跟着**同一条** learning 从诞生走到晋升，每一步只回答四个问题：谁触发、调了什么、磁盘上多了/少了什么、靠什么交给下一步。
> 基于 `main@f58f315`（2026-10-18）。函数名和路径在源码里抽查过；行号会变，以函数名为准。细节请跳到每节末尾标注的分篇。

---

## 0. 主角与舞台

- 作者 Alice，队友 Bob，都用 user scope、git 后端、独立 clone 在 `~/.teamai/team-repo`（最常见的安装形态）。
- Alice 在会话里折腾了很久"K8s pod 启动超时"，最后用加大 `startupProbe.failureThreshold` 解决。
- 下文路径都按这个形态写；self 模式（单仓）把 `~/.teamai/` 换成 `<dataHome>/`，HTTP 后端没有分支，见 [04 §2](./04-contribute-publish.md)。

一句话时间线：

```text
T0 Alice 会话中      hook 默默记账（events.jsonl / transcript）
T1 Alice 一轮结束    Stop → contribute-check 打分 → 吐出提醒（或暂存 pendingHint）
T2 Alice 的 AI       teamai skill get share → 子 agent 写 /tmp/xxx.md
T3 teamai contribute 入队 pending → 建索引 → 推 teamai-learnings → 出队 → 再建索引 → 标记 contributed
T4 Bob 开会话        SessionStart 后台 pull → 刷新 worktree → 镜像 → 重建索引 → 部署 recall 规则/子 agent
T5 Bob 的 AI 开工前  teamai recall "k8s 启动超时 startup probe" → 命中 → recalled +1
T6 Bob 的 AI 打开它  PostToolUse 记 evidence → Stop 时 votes-sync 记 upvoted +1 → 推 teamai-reports
T7 任意成员维护      recall maintenance：汇总全员票 → 置信度 → 回写 / 淘汰
T8 够格了            recall promote → AI 改写进 skills|rules|docs，原 learning 加 promoted_to
```

---

## 1. 全景：learning 文件住过的地方

同一份内容会先后出现在这些位置（"→" 表示复制或移动）：

```text
/tmp/session-summary.md                          T2  子 agent 写的草稿（teamai 不管它的死活）
  → ~/.teamai/pending-learnings/<rel>            T3  持久队列，本机唯一可靠副本
  → ~/.teamai/learnings-wt/learnings/<rel>       T3  teamai-learnings 分支的 worktree（写根）
  → origin teamai-learnings:learnings/<rel>      T3  推送成功后，pending 那份才删
  → Bob: ~/.teamai/learnings-wt/learnings/<rel>  T4  Bob 的 worktree 刷新
  → Bob: ~/.teamai/learnings/<rel>               T4  user scope 的机器级镜像
  → <写根>/_archive/<文件名>                      T7  prune --archive（不加 --archive 就直接删）
  → ~/.teamai/team-repo/<category>/<文件名>       T8  promote 改写后的新文件（原 learning 保留）
```

其中 `<rel>` = `[<namespace>/]<slug>-<YYYY-MM-DD>-<6位随机>.md`，例如 `k8s-pod-2026-10-18-a1b2c3.md`。

围绕它的"账本"文件：

| 文件 | 记什么 | 写入时刻 |
| --- | --- | --- |
| `~/.teamai/dashboard/events.jsonl` | 本机所有会话的 tool_use / prompt_submit / stop 事件 | T0（dashboard-report handler） |
| `~/.teamai/sessions/<sid>.json` | 本会话的打分缓存、`hinted`、`contributed`、`pendingHint` | T1、T3 |
| `~/.teamai/sessions/<sid>-recall-cache.json` | 本会话 recall 命中/未命中次数 | 每次 recall |
| `~/.teamai/search-index.json` | 检索索引 | T3（两次）、T4 |
| `<dataHome>/dashboard/recall.jsonl` | recall log：run / claim / evidence / consumed | T5、T6 |
| `~/.teamai/user-votes/<user>.yaml` | 本机票数 + 未推送的 deltas + 会话去重账本 | T5、T6 |
| origin `teamai-reports:votes/<user>.yaml` | 团队票数，每人一个文件 | T6 |

---
## 2. T0：会话进行中，hook 只记账不说话

触发：Alice 的 AI 每调一次工具、每提交一次 prompt、每停一次，宿主工具就跑一次 `teamai hook-dispatch <event> --tool <tool>`。

做了什么：

- `dashboardReportHandler` 把事件追加到 `~/.teamai/dashboard/events.jsonl`。Stop 事件上带一份累计的 `interventions` 快照（interrupt / toolReject / toolError 次数）。
- UserPromptSubmit 时顺带判断这条 prompt 是不是"纠正"（命中纠正关键词，团队可在 `sharing.intervention.correctionKeywords` 追加），结果作为布尔值记在事件里。
- 这一阶段**不产生任何 learning 相关文件**，只是给 T1 准备原料。

交给下一步：events.jsonl + 宿主自己的 transcript 文件。

> 细节：[01 §4.5](./01-hook-layer.md)、[02 §3](./02-friction-detection.md)。

---

## 3. T1：一轮结束，contribute-check 决定要不要提醒

触发：Stop 事件 → `contributeCheckHandler` → `contributeCheckForSession(sessionId, cwd, transcriptPath, stash)`（`src/contribute-check.ts`）。

判定顺序（任何一步"否"就静默返回）：

0. 门禁 `contributeHintAllowed()`：没有团队配置、配置读不了、HTTP 只读源、recall 未开启、团队关闭了提醒，都不提醒。它和 T2 的 `skill get share` 共用 `shareGate()`，所以不会出现"提醒你分享、命令却拒绝"。
1. 读 `~/.teamai/sessions/<sid>.json`。`contributed === true`（本会话已经分享过）或 `hinted === true`（已经提醒过）→ 不再提醒。
2. 去抖：5 分钟内评估过且当时工具调用 < 15 → 连 events.jsonl 都不读。
3. 算摩擦：优先实时扫 transcript（避开"Stop 事件还没被后台进程写进 events.jsonl"的竞争），失败退回最新一条 Stop 快照。
4. `computeSmartScore` 打分：interrupt / toolReject / correction 各 20 分，toolError 按 3/5/8 次分档 10/18/25 分，用到 skill +5，工具多样性最多 +5。
5. Phase 2 修正：读 recall-cache 判"知识缺口"（本会话 recall 全落空），看本会话有没有 git commit，再调分。
6. 硬门槛：`toolCount >= 15`（`CONTRIBUTE_BASE_THRESHOLD`）**且** `score >= 20`（`CONTRIBUTE_SMART_THRESHOLD`）。

过了门槛，生成提醒（`buildHint`，英文）：

```text
[teamai] This session may contain a problem worth documenting: <reasons>.

Task: <第一条 prompt 摘要>

Consider running `/teamai share what this session taught me` to summarize what you learned
and share it with your team (or run `teamai skill get share`).
```

知识缺口时标题换成 `The current task is not covered by the team knowledge base ...`，动作句多一句 "fill the knowledge gap"。

磁盘变化：`~/.teamai/sessions/<sid>.json` 一次原子写入，更新 `smartScore / toolCount / friction / promptSummary / lastEvaluated / isKnowledgeGap / hasGitCommit`，并置 `hinted = true`。写之前会重读一次，避免把并发写入的 `contributed` 冲掉。

两条投递路：

- 宿主会展示 Stop 输出：提醒直接写 STDOUT（`formatStopHookOutput`）。
- 宿主不展示（如 CodeBuddy）：提醒加上"请原样转告用户"前缀（`RELAY_TO_USER_PREFIX`）存进 `pendingHint`；下一次 UserPromptSubmit 时 `pendingHintHandler` 调 `takePendingHint()` 取出并清空，注入上下文。两条路互斥，同一提醒不会发两次。

交给下一步：一段注入到 AI 上下文里的文字。**之后能不能沉淀，完全取决于 AI（或用户）是否照做**，没有任何自动流程会替它写文档。

> 细节：[02](./02-friction-detection.md) 全篇。

---
## 4. T2：AI 按 share skill 把会话写成文档

触发：AI 看到提醒，执行 `/teamai share ...`；teamai 的发现入口 `skills/teamai/SKILL.md` 指向 `teamai skill get share`，CLI 打印 `skill-data/share/SKILL.md`（`{SKILL_DIR}` 替换成真实路径，`--full` 追加模板）。

AI 被要求做的事（`skill-data/share/SKILL.md`）：

1. 用**子 agent** 执行，避免把总结过程塞进主会话上下文。
2. 回顾本次会话：任务是什么、关键决策和原因、最终方案或绕过办法、好用的工具/skill、踩过的坑。
3. 用简体中文写 Markdown，frontmatter 照 `references/doc-template.md` 填：

   ```markdown
   ---
   title: "K8s pod 启动超时：startupProbe 阈值过小"
   author: alice
   date: 2026-10-18
   tags: [k8s, troubleshooting, deployment]
   ---
   ## Context
   ## Solution
   ## Lessons
   ## Related Skills
   ```

4. 写到临时文件，执行 `teamai contribute --file /tmp/session-summary.md --title "<title>"`。

磁盘变化：只有 `/tmp/...` 这份草稿，teamai 还没介入。

衔接要点：

- frontmatter 是**作者写、CLI 原样保存**的。`contribute` 读出 `--file` 的内容后原封不动入队，不补 author/date/tags，也不改正文。frontmatter 写得差，入库照样成功，但检索变差（索引的标题、标签都取自 frontmatter，见 [03 §5.3](./03-share-skill.md)）。
- `--title` 只用于生成文件名的 slug，不写进文档。

> 细节：[03](./03-share-skill.md)。

---

## 5. T3：`teamai contribute`，从草稿到团队分支

代码：`contribute()`（`src/contribute.ts`）。按执行顺序：

| # | 动作 | 函数 | 磁盘变化 |
| --- | --- | --- | --- |
| 1 | 读 `--file`，空文件直接拒绝；按 `--scope` 或当前目录选配置；HTTP 源拒绝 | `contribute` | 无 |
| 2 | 选 namespace：只有一个激活的就用它，否则写共享根；`--namespace` 覆盖时校验是否已分发 | `resolveActiveLearningsNamespaces` | 无 |
| 3 | 生成文件名 `<slug>-<date>-<6位随机>.md`（slug 小写、保留中文、截 50 字符） | `generateFilename` | 无（`--dry-run` 到此为止） |
| 4 | 入队（队列锁 `~/.teamai/locks/queue-<hash>.lock`，30×100ms） | `savePendingLearning` | **新增** `~/.teamai/pending-learnings/<rel>` |
| 5 | 第一次建索引，pending 目录排最前 | `rebuildIndexAfterContribute` | 改写 `~/.teamai/search-index.json` |
| 6 | 拿同步锁 `.sync-lock`，把队列里**所有**条目写进 worktree，一个 commit 推上去 | `publishQueuedLearnings` → `publishToLearningsBranch` → `learningsBranch.update` | **新增** `~/.teamai/learnings-wt/learnings/<rel>`；origin `teamai-learnings` 多一个 commit |
| 7 | 只对确认送达（`published` / `already-present`）的条目出队 | `dropPendingLearning` | **删除** `~/.teamai/pending-learnings/<rel>` |
| 8 | 有条目送达时第二次建索引，让条目改指向 worktree 副本（#705） | `rebuildIndexAfterContribute` | 改写索引 |
| 9 | 有 sessionId（参数或环境变量）就标记已分享 | `markContributed` | `~/.teamai/sessions/<sid>.json` 置 `contributed: true` |
| 10 | 打印结果 | — | 无 |

第 6 步的细节：

- 分支是孤儿分支 `teamai-learnings`，和 `main` 没有共同历史；worktree 不存在时用 `git worktree add --orphan` 创建（老 git 有降级路径）。
- commit message 固定为 `[teamai] Contribute session knowledge from <username>`，只 add 本次的文件。
- push 被拒（non-fast-forward）就 fetch → rebase 到 `origin/teamai-learnings` → 再推，最多 5 次。文件名带随机后缀，真实冲突几乎不会发生。
- 不走 PR，所以没有 `main` 写权限的成员也能贡献（#485）。

三种结局：

```text
Contributed: learnings/<rel>                                  送达
Saved locally (<原因>). It stays recallable here and the next `teamai pull` publishes it.
Saved locally, not published: <原因>. ...                      安装已变（配置被 init 换了）
```

衔接要点：

- **入队即算分享**：第 9 步在发布结果出来之前就执行，推送失败也不会再被提醒（避免同一经验被写两份）。是否仍在排队，由 `pull` / `doctor` 告诉用户。
- **没推上去也能搜到**：第 5 步让 pending 里的条目进索引，Alice 自己的下一次 recall 就能命中。
- 推不上去的条目由 T4 的 `pull` 先重试。

> 细节：[04](./04-contribute-publish.md) 全篇。

---
## 6. T4：Bob 开会话，后台 pull 把它拉下来

触发：Bob 的 SessionStart → `hook-dispatch session-start` → `pullHandler`（后台、脱离宿主，超时 120s）→ `pull({ silent: true })`。前台同时跑 `teamRulesHandler` 注入团队规则和 recall 块，但**不注入任何 learning 正文**。

`pull.ts` 里和这条 learning 有关的四件事：

1. 先 `publishQueuedLearnings`：Bob 自己队列里没推出去的先推（Alice 若 T3 失败，就是在她自己下次 pull 的这一步补推）。
2. 主分支没变走快速路径，变了走完整同步；两条路最后都会刷新知识。
3. `syncLearningsAndRebuildIndex`：
   - `learningsBranch.refresh(pushIfCreated: false)`：只读地把 `~/.teamai/learnings-wt` 同步到 `origin/teamai-learnings`，Alice 的文件出现在 Bob 的 worktree 里。
   - user scope：镜像到 `~/.teamai/learnings/`（`mirrorLearnings`，按激活的 namespace 过滤，上游删除的也会删掉）。
   - `buildIndex({ learningsDirs: [pending, ..., published], docsDir, rulesDir, skills, votesDir, indexPath })`：重建 `~/.teamai/search-index.json`，同时读 votes 给条目标冷热。
4. 部署 recall 的"触发器"（recall 开启时）：内置规则 `teamai-recall.md|.mdc|...`、内置子 agent `teamai-recall.<ext>`、指令文件里的 `[teamai:recall-rules:start] ... end` 块。

读根优先级（`learningsRoots()`，同一相对路径以靠前者为准）：写根（worktree 下 `learnings/`）→ 机器级镜像（仅 user scope）→ 分区缓存 `<dataHome>/learnings` → 旧数据所在的 clone 内 `learnings/`（只读）。pending 队列不在 roots 里，但索引会单独把它排在最前。

衔接要点：pull 之后 learning 只是"躺在索引里"，Bob 的 AI 不会主动看到它。让它被用上的是第 4 件事部署的规则。

> 细节：[05](./05-pull-distribution.md)；读根见 [04 §4](./04-contribute-publish.md)。

---

## 7. T5：Bob 的 AI 开工前 recall，命中它

触发：内置规则要求 AI 在动手前调用子 agent `teamai-recall`，子 agent 执行 `teamai recall "<中英双语关键词>" --caller ...`（`--caller` 防止子 agent 递归调用自己）。用户也可以手动跑。

`src/recall.ts` 做的事：

1. 读 `~/.teamai/search-index.json`（缺失就现建）。
2. learnings 用 TF-IDF 打分并按查询长度归一化；阈值随语料自适应：`max(baseline × 1.35, 4.0)`（`LEARNINGS_RELEVANCE_RATIO`、`LEARNINGS_ABSOLUTE_FLOOR`）。冷知识（hotness 低）会被降权。teamwiki 结果走 BM25，另算阈值，两类合并排序。
3. 输出以 `--- [teamai:recall:start] --- (N results) run=<uuid>` 开头，每条带文件路径，AI 要读正文得自己去打开文件。

三个副作用（`--check` 只做相关性预检，不计票）：

| 副作用 | 函数 | 写到哪 |
| --- | --- | --- |
| 每条返回结果 `recalled_count +1`，并记一笔 `recalled_delta` | `autoUpvote` → `incrementRecalled` | `~/.teamai/user-votes/bob.yaml`（拿不到锁就跳过本次） |
| 本会话命中/落空计数 | `recordRecallQuality` | `~/.teamai/sessions/<sid>-recall-cache.json` |
| 记一行 run（run_id、结果、分数） | `recordRun` | `<dataHome>/dashboard/recall.jsonl` |

注意 `autoUpvote` 名字里有 upvote，实际只加 **recalled**，不加 upvoted。

衔接要点：

- run_id 被打印进输出，是 T6 判断"这次打开文件是不是因为这次 recall"的关联键。
- recall-cache 会反过来喂给 Bob 自己会话的 T1：如果 Bob 的 recall 全部落空、又折腾了很久，他会收到"知识缺口"版本的提醒，于是又一条新 learning 开始诞生。

> 细节：[06](./06-recall-search.md)。

---

## 8. T6：Bob 的 AI 真的打开了它，记一票 upvote

"被召回"不等于"有用"，所以 upvote 要求 AI **真的读了文件**。

```text
PostToolUse（Bash 跑 recall）  recall-attribution：从输出里抓 run=<uuid>，追加 claim 行
PostToolUse（Read 该 .md）     recall-attribution：路径在知识根下 → 追加 evidence 行
Stop / SubagentStop / SessionEnd → votes-sync：
   creditAdoptedDocs：把 run + claim + evidence 拼起来（同会话、24h 内、路径匹配）
   → incrementUpvoted(votePath, docIds, rootSession)
        锁内：查会话账本 upvotedSessions，同一会话同一文档只记一次
        upvoted_count +1，upvoted_delta +1
   → 追加 consumed 行（这些 evidence 以后不再计票）
   → 非 SubagentStop 且有 deltas：updateReports → 以 origin 快照为基合并 → push teamai-reports
        送达后 confirmVotesSynced 扣掉已送达的 deltas；失败则 deltas 留着下次再推
   → 仅 Stop 且宿主显示输出：打印 "[teamai] Adopted team knowledge this session: ..."
```

磁盘变化：`recall.jsonl` 追加 claim / evidence / consumed；`~/.teamai/user-votes/bob.yaml` 计数和账本变化；origin `teamai-reports:votes/bob.yaml` 更新。

其他投票入口：

- 手动：`teamai recall feedback --positive|--negative <docId>`。
- 可选的后台 LLM 判官 `votes-judge`（`TEAMAI_UPVOTE_JUDGE=1` 才开）：子 agent 只给了摘要、没打开文件时，由模型判断是否采纳。

衔接要点：hook 写的是**本机**票，T7 读的是 reports 分支上**全员**的票，中间只靠 deltas 增量同步（只推增量，所以重试不会重复计数，#1027）。

> 细节：[07 §2~§4](./07-feedback-governance.md)、[01 §4.6、§4.9](./01-hook-layer.md)。

---
## 9. T7：维护，把全员的票变成置信度

触发：**手动**。`teamai recall maintenance [--prune [--archive]] [--confidence-writeback] [--update-quality] [--dry-run]`，没有任何 hook 会自动跑它。

计算（`computeAllConfidence`，`src/maintenance/confidence.ts`）：把 reports 分支 `votes/` 下每个成员的 yaml 按 docId（文件名去掉 `.md`）累加，再代公式：

```text
base       = min(1, recalled×0.1 + upvoted×0.3)
recency    = max(0, 1 - 距最近一次召回天数/180)
ratio      = upvoted / max(1, recalled)
confidence = base×0.4 + recency×0.3 + ratio×0.3
```

三种处理，改动都写进 learnings worktree，再由 `publishLearningsMaintenance` 推到 `teamai-learnings`（先在 worktree 的 git 目录下记一条 `teamai-maintenance/` 记录，送达后才删，保证失败可重推）：

| 选项 | 条件 | 对这条 learning 做什么 |
| --- | --- | --- |
| `--confidence-writeback` | 算出了置信度的条目 | frontmatter 写入 `confidence`（下次建索引会读进条目） |
| `--prune` | 置信度 < 0.15，或创建满 180 天且 < 0.3 | 删除；加 `--archive` 改为移到 `<写根>/_archive/` |
| `--update-quality` | 针对 docs/rules/skills，不针对 learning | 生成 `.draft.md` 更新建议 |

保护新文档：**没有任何投票数据**的条目不参与 prune，搜索 hotness 记中性 1.0。所以刚发布的 learning 不会因为"还没人用"被删。

> 细节：[07 §5](./07-feedback-governance.md)。

---

## 10. T8：够格了，晋升为正式知识

触发：手动。`teamai recall promote` 列出候选；`teamai recall promote <learningId> [--category skills|rules|docs]` 执行。

候选门槛（`src/maintenance/promote.ts`）：`confidence >= 0.90`、全员 `upvoted >= 5`、有 upvote 的成员 >= 2、frontmatter `date` 距今 >= 14 天（没有 date 不查年龄）、还没有 `promoted_to`。

`executePromotion` 三步：

1. 选类别：本机 CLI 模型判断，失败按关键词计数。
2. 改写：skills 改成触发条件 + 步骤 + 常见坑；rules 改成一句 Always/Never + 理由 + 正反例；docs 改成背景 + 概念 + 决策；去掉日期、人名。模型失败就原样复制。写到**团队 clone 的工作区** `~/.teamai/team-repo/<category>/<文件名>`。
3. 标记：原 learning frontmatter 加 `promoted_to: <category>/<文件名>`（原文件不在写根时，标记写到写根），再以 `[teamai] Mark <docId> as promoted` 推到 `teamai-learnings`。

两个容易误会的点：

- 原 learning **不删除**，继续可被 recall；`promoted_to` 只是防止重复晋升。
- promote 只推送了"标记"。改写出的 `skills/ rules/ docs/` 文件落在团队 clone 的工作区里，promote 本身不提交也不推送；要让队友拿到，需要走正式知识的管理流程（`teamai push`，见 `docs/guide/zh-CN/sharing.md`）。这一点是读 `index.ts` 的 promote action 得出的，没有端到端跑过。

至此，一条从"Alice 被卡住"开始的经验，变成了全队 AI 每次都会加载的 skill / rule / doc。

> 细节：[07 §5.5~§6](./07-feedback-governance.md)。

---
## 11. 这条 learning 本身变了什么

| 时刻 | 内容变化 | 由谁写 |
| --- | --- | --- |
| T2 | 诞生：`title / author / date / tags` + 四段正文 | 子 agent |
| T3~T6 | **不变**。入队、发布、分发、召回、投票都不改文件内容，票数只记在 votes 文件里 | — |
| T7 | 可能多一个 `confidence`；可能被移到 `_archive/` 或删除 | maintenance |
| T8 | 多一个 `promoted_to`；另外生成一份改写后的新文件 | promote |

也就是说，"它有多有用"这件事在 T7 之前只存在于 votes 里，不在 learning 文件里。

---

## 12. 链条在哪里会断，断了怎么接上

| 断点 | 现象 | 兜底 |
| --- | --- | --- |
| T1 分数不够 / 工具调用不到 15 次 | 没有提醒 | 用户随时可以手动 `/teamai share` |
| T1 宿主不展示 Stop 输出 | 看不到提醒 | `pendingHint` 在下一条 prompt 时补发 |
| T1 recall 未开启 / HTTP 源 | 不提醒，`skill get share` 也拒绝 | 门禁一致，`teamai recall enable` |
| T2 AI 没照做 | 什么也不发生 | 每会话只提醒一次，不会反复打扰 |
| T3 推送失败（离线、无权限） | `Saved locally (...)` | 留在 pending，下次 pull 第一步重推；期间本机 recall 照样能搜到 |
| T3 checkout 被拒（worktree 位置属于别的仓库） | `Saved locally` + 需要先处理 checkout | 每次 pull 都会遇到同样拒绝，必须人工处理 |
| T4 Bob 一直不开新会话 | 拿不到 | 手动 `teamai pull` |
| T5 关键词没对上 | recall 落空 | Bob 会话可能触发"知识缺口"提醒，产生新 learning |
| T6 子 agent 只给摘要没开文件 | 没有 upvote | 可选 `votes-judge`，或手动 `recall feedback` |
| T6 reports 推送失败 | 团队看不到这票 | deltas 留在本机，下次 Stop 再推 |
| T7/T8 没人跑维护 | 置信度不更新，不淘汰不晋升 | 只能手动（或团队自己接 CI） |

---

## 13. 动手追踪一条 learning

按 T3 → T6 的顺序观察（路径按本文的安装形态；先 `--dry-run` 看，不想真推就别去掉）：

```bash
# T3 前：预演文件名，不写任何东西
teamai contribute --file /tmp/session-summary.md --title "K8s pod 启动超时" --dry-run

# T3 后：队列应为空（已送达），worktree 里有文件，分支上有 commit
ls ~/.teamai/pending-learnings/
ls ~/.teamai/learnings-wt/learnings/
git -C ~/.teamai/learnings-wt log --oneline -3

# T3 后：会话已标记
cat ~/.teamai/sessions/<sid>.json        # 看 hinted / contributed

# T4（Bob 机器）：镜像和索引里有它
ls ~/.teamai/learnings/
grep -c 'k8s-pod' ~/.teamai/search-index.json

# T5：只看相关性，不计票
teamai recall "k8s pod 启动超时 startup probe" --check

# T6：本机票数与待推增量
cat ~/.teamai/user-votes/<username>.yaml

# T7 / T8：先预演
teamai recall maintenance --prune --dry-run
teamai recall promote
```

---

## 14. 自测问题

<details>
<summary>1. Alice 的 contribute 推送失败了，她会再收到分享提醒吗？她自己能 recall 到这条吗？</summary>

不会再收到提醒；能 recall 到。`markContributed` 在入队后就执行，不看推送结果；第一次建索引把 pending 目录排在最前，所以本机能搜到。

</details>

<details>
<summary>2. Bob 的 recall 命中了 5 次但从没打开过文件，这条 learning 的置信度会怎样？</summary>

recalled 增加、upvoted 为 0，`ratio` 趋近 0，`base` 只靠 recalled×0.1。长期看会变冷、降权，最终可能被 prune。

</details>

<details>
<summary>3. 为什么 contribute 发布后要再建一次索引？</summary>

第一次索引指向 pending 路径，发布成功后 pending 文件被删，不重建的话 AI 拿到的是打不开的路径（#705）。

</details>

<details>
<summary>4. promote 之后队友马上能用到新 skill 吗？</summary>

不一定。promote 只推送了 `promoted_to` 标记；改写出的 skill 文件在团队 clone 工作区里，需要走 `teamai push` 等正式流程。

</details>

---

## 未逐行核实

- promote 生成的 `skills/ rules/ docs/` 文件需要 `teamai push` 才能到队友手里：依据是 promote action 只对标记调用了 `publishMaintenance`，没有端到端验证。
- reports 分支 worktree 的具体目录名没有核对。
- `--check` 是否也跳过 `recordRecallQuality` / `recordRun`，没读实现，本文只确认它不计票。
- 投票 key（run 记录里形如 `learnings/<name>`）与维护侧用的 docId（文件名去 `.md`）在各种 namespace 布局下如何对齐，沿用 [07 未逐行核实](./07-feedback-governance.md) 的结论，未核实。
- 本文是对 01~07 的串联，具体数值和函数行为以这些分篇和源码为准；第 8 篇 teamwiki 那条知识线不在本文范围内。

