# TeamAI CLI 知识沉淀机制

> 基于 `main@fe3b906` 源码整理（2026-10-17）。行号会随代码变动，以函数名/常量名为准。

## 总览

两条沉淀线，一个检索出口：

```text
会话 ──Stop hook──> contribute-check（摩擦打分）──提示──> share skill 写文档
                                                         │
                                         teamai contribute
                                                         ▼
                        pending 队列 ──publish──> teamai-learnings 分支 /learnings/
                                                         │
代码 / MR / iWiki ──teamai import──> teamwiki/ 图谱        │ teamai pull
                                   │                     ▼
                                   └────────> teamai recall（teamai-recall 子 agent）
                                                         │
                        votes ──> confidence ──> prune / promote（升级为 skills/rules/docs）
```

- learnings：从 AI 会话中提炼的经验，轻量、无 PR、靠投票自然淘汰或升级。
- teamwiki：从代码等来源抽取的结构化知识图谱，可走人工审核。
- 正式知识：skills / rules / docs，用 `teamai push` 管理，见 `docs/guide/zh-CN/sharing.md`。

## 1. 触发：摩擦检测（contribute-check）

入口：内置 `Stop` hook（`src/builtin-hooks.ts`），会话结束时执行 `teamai hook-dispatch stop`，进而调用 `src/contribute-check.ts`，输入是 STDIN JSON（sessionId、cwd、transcript_path）。

摩擦信号（优先实时扫描 transcript，失败时退回最近一次 Stop 事件的 `interventions` 快照）：

- `interrupt`：用户中途打断（ESC）
- `toolReject`：用户拒绝工具调用
- `correction`：打断后带纠正意图的再次提问（`stop→prompt_submit`）
- `toolError`：工具失败重试，按次数分档计分

打分（`computeSmartScore`），常量在 `src/types.ts` 约 2016–2064 行：

- interrupt / reject / correction 每次各计 20 分（`CONTRIBUTE_*_WEIGHT = 20`）
- toolError 分档计分（`CONTRIBUTE_TOOLERROR_TIERS`）：3 次以上 10 分，5 次以上 18 分，8 次以上 25 分
- 用到 skill 加 5 分；工具多样性最多加 5 分
- 门槛：`CONTRIBUTE_BASE_THRESHOLD = 15`，`CONTRIBUTE_SMART_THRESHOLD = 20`
- 结合 recall 命中情况做知识缺口判断（`src/recall-quality.ts`，缓存在 `~/.teamai/sessions/<id>-recall-cache.json`）

去重：会话状态存在 `~/.teamai/sessions/<sessionId>.json`，`hinted=true` 后同一会话不再提示；`contribute` 成功后用 `markContributed` 标记。

提示文案（英文，写到 STDOUT 注入给 agent）：

```text
[teamai] This session may contain a problem worth documenting: <reasons>.
Task: <first prompt>
Consider running `/teamai share what this session taught me` ...
```

存在知识缺口时会换成 "The current task is not covered by the team knowledge base ..."。

## 2. 写文档：share skill

agent 按 `skill-data/share/SKILL.md` 执行，要求用子 agent 跑，避免污染主会话；文档用简体中文写。

内容覆盖：问题背景、关键决策及原因、解决方案或绕过方法、好用的工具和 skill、踩过的坑。

模板见 `skill-data/share/references/doc-template.md`。frontmatter 必填，它是建索引的依据：

```markdown
---
title: "<60 字符内，点明核心问题>"
author: <username>
date: <YYYY-MM-DD>
tags: [tag1, tag2, tag3]   # 选 2-5 个
---
## Context / ## Solution / ## Lessons / ## Related Skills
```

标签分类：

- 技术栈：python, typescript, go, k8s, docker, sglang, cuda
- 问题类型：troubleshooting, performance, deployment, config, api
- 模式：workflow, pattern, tool-usage, best-practice
- 场景：debugging, testing, monitoring, security

## 3. 发布：teamai contribute

```bash
teamai contribute --file /tmp/x.md --title "<title>" [--namespace <ns>] [--scope user|workspace] [--session-id <id>]
```

流程（`src/contribute.ts`）：

1. 校验：`--file` 必填且内容非空；解析 scope。
2. 文件名：`generateFilename`（约 126 行）生成 `<slug>-<YYYY-MM-DD>-<6位随机>.md`。slug 转小写，非字母数字的字符替换为 `-`，保留中文，截断到 50 字符。
3. namespace：`resolveActiveLearningsNamespaces` 读取 manifest 的 `resources.learnings`。只有一个激活的 namespace 时自动选用；没有或有多个时写到共享根目录，可用 `--namespace` 覆盖。覆盖值会按已分发的 namespace 校验。
4. 入队：`savePendingLearning` 先把文档写进持久化队列（`src/utils/pending-learnings.ts`）：
   - git 模式：clone 目录同级的 `pending-learnings/`
   - self 模式：`<dataHome>/pending-learnings/`
5. 立即重建索引（`rebuildIndexAfterContribute`），发布前就能被 recall 检索到。
6. 发布：`publishQueuedLearnings`（`src/utils/learnings-publish.ts`）提交到 `teamai-learnings` 孤儿分支的 worktree 下 `learnings/[<ns>/]`，每次发布一个 commit，不走 PR。
7. 发布失败时文档留在队列，下次 `teamai pull` 会先重试发布。队列锁按安装实例区分，最多 30 次 × 100ms。

## 4. 存储与读取根（learnings-roots）

`src/utils/learnings-roots.ts` 的 `learningsRoots()` 是唯一的路径来源，返回 `{ write, read[] }`，`read[0] === write`，同一相对路径以靠前的根为准：

1. write 根：`teamai-learnings` 分支 worktree 下的 `learnings/`；HTTP 后端没有分支，直接用 knowledge 目录
2. 机器级镜像 `getUserLearningsDir()`，仅 `scope === 'user'` 时读取，防止串到其他项目
3. 当前 scope 的分区缓存 `<dataHome>/learnings`
4. 继承根：knowledge clone 里的 `learnings/`，即迁移到独立分支之前的历史数据，只读不写（#485）

pending 队列不在 roots 里：recall 和索引会读它，但 prune 和 promote 不会处理尚未发布的条目。

## 5. 检索：teamai recall

```bash
teamai recall "<query>" [--depth route|context|lookup] [--check]
```

- 索引：`search-index.json`。用户级在 `~/.teamai/`，项目级在 `<project>/.teamai/`，由 pull 和 contribute 重建。
- learnings 打分用 TF-IDF，并按查询长度归一化。阈值取 `max(baseline × 1.35, 4.0)`，常量为 `LEARNINGS_RELEVANCE_RATIO` 和 `LEARNINGS_ABSOLUTE_FLOOR`（`src/recall.ts:49,61`）。
- teamwiki 打分用 BM25 加图谱扩展，结果压缩到 0–10 区间，阈值 `CODEBASE_RELEVANCE_THRESHOLD = 4.0`（`src/recall.ts:25`）。命中结果附带 `sources` 和 `relatedFiles`。两类结果合并后统一排序。
- `--depth` 控制 teamwiki 图谱的遍历深度：route 只看入口，context（默认）到模块级，lookup 做全图遍历。
- `--check` 只做相关性预检，输出 `RELEVANT|NOT_RELEVANT score=… threshold=…`，不读文件也不计票。
- 自动召回：不靠 hook，而是由内置 rule（`src/builtin-rules.ts`）要求 agent 在合适时机调用内置子 agent `teamai-recall`（`src/builtin-agents.ts`）。子 agent 运行时带 `--caller` 标记，避免递归调用。`recall disable/enable/status` 用来开关这个功能。
## 6. 治理：投票、置信度、淘汰、升级

代码在 `src/maintenance/`。投票文件存放在 `<reportsDir>/votes`（`paths.ts`）。

反馈：`teamai recall feedback --positive|--negative <docId>`，被 recall 命中也会计入 recalled 次数。

置信度（`confidence.ts` 的 `computeConfidence`）：

```text
base     = min(1, recalled×0.1 + upvoted×0.3)
recency  = max(0, 1 - 距最近一次召回天数/180)
ratio    = upvoted / max(1, recalled)
confidence = base×0.4 + recency×0.3 + ratio×0.3
```

`teamai recall maintenance` 的选项：

- `--prune [--threshold n] [--archive]`（`prune.ts`）：置信度低于 0.15（`DEFAULT_THRESHOLD`）的条目，或超过 180 天（`STALE_DAYS`）且置信度低于 0.3 的条目，会被删除；加 `--archive` 时改为移到 write 根下的 `_archive/`。
- `--confidence-writeback`：把置信度写回 frontmatter（`writeBackConfidence`）。
- `--update-quality`：找出过时的 docs、rules、skills，并给出更新建议（`quality-update.ts`）。
- 所有选项都支持 `--dry-run`。

`teamai recall promote [learningId] [--category skills|rules|docs]`（`promote.ts`）：

- 门槛：confidence ≥ 0.90，upvoted ≥ 5，投票人数 ≥ 2，创建满 14 天。
- 由模型按目标类别改写：skills 改成 SOP，rules 改成约束加理由，docs 改成参考文档。改写结果写到团队仓库的 `<category>/<filename>`。
- 原 learning 的 frontmatter 加上 `promoted_to` 标记，写在 write 根，防止下次重复升级。

## 7. 代码知识：teamwiki

适用场景：多仓库、多微服务的大型项目。工作流在 `skill-data/wiki/SKILL.md`，产出文档用简体中文。

- 模式：默认（单会话核心路径）、`--deep`（完整 K1~K4 加 G1~G9 图谱文档）、`--update`（按文件 SHA256 增量更新）、`continue`（从 `_review/progress.json` 断点续跑）。
- 阶段：
  - Phase 0：用 `teamai import --dir` 建立结构基线
  - K1：架构逆向，产出 `k1-architecture-map.md`，需人工确认 ①
  - K2：分批生成组件文档（子 agent `kb-doc-generator`），需人工确认 ②
  - K3：Graph RAG（子 agent `graph-rag-agent`）
  - K4：质量校验（`scripts/validate_kb.py`）
- 子 agent prompt、方法论和模板在 `skill-data/wiki/references/` 下。

CLI 侧：

```bash
teamai import --dir <path> | --from-repo <url> | --from-repo-list <yaml> | --from-org <org>
teamai import --from-mr <url...>        # 从合入的 MR/PR 提炼 learning，并增量更新 teamwiki
teamai import --from-iwiki <space|url>  # 需要 TAI_PAT_TOKEN
teamai import ... --incremental | --skip-enrich
teamai codebase --deep-enrich --project <slug> | --lint | --reconcile | --status
teamai review [id] --apply | --reject | --all-apply   # 处理 .teamai/pending-review.jsonl
```

- 产物写在团队仓库的 `teamwiki/`，代码证据在 `teamwiki/evidence/code/<project>`。
- `--require-review` 会把 codebase 段落的写入先放进 `.teamai/pending-review.jsonl`，由 `teamai review` 人工审核后再应用（`src/review-store.ts`）。

## 8. 周边：会话与周报

- `teamai session save [--push]`：把脱敏后的会话摘要写进本地月度日志；加 `--push` 时同时推到团队仓库，作为 `teamai digest` 的数据源。
- `teamai digest`：生成团队周报（`src/digest.ts`）。
- `teamai session push/pull/list/search/resume`：整段会话的团队共享与跨平台迁移。

## 9. 源码索引

- 触发：`src/builtin-hooks.ts`、`src/contribute-check.ts`、`src/recall-quality.ts`、`src/types.ts`（`CONTRIBUTE_*`）
- 发布：`src/contribute.ts`、`src/utils/pending-learnings.ts`、`src/utils/learnings-publish.ts`、`src/utils/learnings-branch.ts`
- 存储：`src/utils/learnings-roots.ts`、`src/utils/search-index.ts`
- 检索：`src/recall.ts`、`src/builtin-rules.ts`、`src/builtin-agents.ts`
- 治理：`src/maintenance/{confidence,prune,promote,quality-update,hot-cold,paths}.ts`
- teamwiki：`src/wiki-engine/`、`src/review-store.ts`、`src/ci/extract-mr.ts`、`skill-data/wiki/`
- agent 读的工作流：`skill-data/share/`、`skill-data/wiki/`、`skill-data/core/references/commands.md`（自动生成）

## 未逐行核实

- `--depth` 三档在图谱遍历上的具体差异：以上描述来自 option help，没有读 `queryCodeKnowledge` 的实现。
- `hot-cold.ts` 的作用没有展开。
- `session save` 月度日志的确切路径，以及 `digest` 的统计口径，没有读源码。
