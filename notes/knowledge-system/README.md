# TeamAI 知识沉淀体系：8 步学习路线

> 面向小白。基于 `main@fe3b906` 源码（2026-10-17），行号会变，以函数名为准。
> 速查版总览见 [../knowledge-sedimentation.md](../knowledge-sedimentation.md)；hook 调度器内部机制见 [../hook-dispatcher.md](../hook-dispatcher.md)。

## 一句话

经验在会话里产生 → hook 检测"卡住过" → 提醒 AI 按 share skill 写成 learning → `teamai contribute` 推到团队仓库的 `teamai-learnings` 分支 → 队友 `pull` 拿到 → AI 开工前 `teamai recall` 检索 → 被用上就 upvote → 高分 learning 晋升为 skill/rule/doc。

四个零件：hook（耳朵和嘴）、skill/rule（说明书）、CLI（手）、git 仓库（仓库）。

## 全景图

```text
 你的 AI 会话
   │  PostToolUse hook 记录每次工具调用 / 打断 / 拒绝             ── 01
   ▼
 Stop hook → contribute-check 算摩擦分（≥15 次工具 且 ≥20 分）    ── 02
   │  输出提醒
   ▼
 AI 运行 `teamai skill get share` → 按说明书写 learning            ── 03
   ▼
 `teamai contribute` → 本地队列 → 重建索引 → push 到 teamai-learnings ── 04
   ▼
 队友 SessionStart → 后台 `teamai pull` → 重建索引 + 部署 recall 规则 ── 05
   ▼
 AI 开工前 `teamai recall "中英关键词"` → 加权关键词检索           ── 06
   ▼
 打开了某篇文档 → upvote → 置信度 → 淘汰 / 晋升                    ── 07

 另一条线：源码 / MR → `teamai import` → teamwiki/ 代码知识图谱 ──> recall ── 08
```

## 目录

0. [00-learning-lifecycle.md](00-learning-lifecycle.md)：一条 learning 的一生（端到端追踪，串起 01~07）
1. [01-hook-layer.md](01-hook-layer.md)：TeamAI 怎么挂进 AI 工具（hook 层）
2. [02-friction-detection.md](02-friction-detection.md)：怎么判断会话值得沉淀（摩擦检测）
3. [03-share-skill.md](03-share-skill.md)：AI 怎么把会话写成 learning（share skill）
4. [04-contribute-publish.md](04-contribute-publish.md)：`teamai contribute` 背后发生了什么（入库与发布）
5. [05-pull-distribution.md](05-pull-distribution.md)：队友怎么拿到（pull 与分发）
6. [06-recall-search.md](06-recall-search.md)：AI 怎么用上知识（recall 检索）
7. [07-feedback-governance.md](07-feedback-governance.md)：知识的新陈代谢（反馈、置信度、淘汰、晋升）
8. [08-teamwiki-code-knowledge.md](08-teamwiki-code-knowledge.md)：另一条知识来源（teamwiki 与 MR 提炼）

## 建议读法

- 第一遍：只读每篇的"0. 一句话 + 类比"和流程图，建立整体印象。
- 第二遍：按顺序读代码走读，边读边打开对应源码。
- 第三遍：做每篇末尾的"动手验证"和"自测问题"。

每篇末尾有"未逐行核实"小节，列出写作时没逐行读过的部分，读的时候以源码为准。
