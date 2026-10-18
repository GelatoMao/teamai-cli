# 第 6 步：AI 怎么用上知识（recall 检索）

> 面向小白。先讲"为什么要有它"和"整体长什么样"，再沿着一次真实的 `teamai recall "api timeout"` 调用逐函数看代码。
> 代码基于 main@fe3b906 源码（2026-10-17），标注 `文件:行号`；行号会随版本变化，以函数名为准。为便于阅读删减了部分注释，用 `// ...` 省略无关分支。
> 上一步（[05-pull-distribution.md](./05-pull-distribution.md)）讲了知识怎么被 pull 到本机并建好索引；本文讲 AI 在干活前怎么把这些知识查出来用上。

---

## 0. 一句话 + 一个类比

**一句话**：`teamai recall <关键词>` 在本机的 `search-index.json` 上做一次纯词法的 TF-IDF 式打分（标题 3 分、tag 2 分、正文 1 分，乘 IDF、除以查询长度的平方根、加投票分、乘领域和类型系数），同时去 `teamwiki/` 代码知识图谱查一次，把两路结果换算到同一把 0-10 的尺子上合并排序，取前 5 条用带分隔符的文本打印给 AI，并顺手记一次"被召回"。

**类比**：图书馆的检索台。

- 卡片目录（`search-index.json`）是 pull 时提前编好的，查询时不翻书，只翻卡片
- 书名命中比目录命中值钱，目录命中又比正文命中值钱（3/2/1）
- 越冷门的词越能说明问题（IDF）：每本书都有"问题"二字，命中它说明不了什么
- 馆里有两套目录：经验笔记（learnings/docs/rules/skills）和代码地图（teamwiki），评分口径不同，前台先换算成同一个"推荐指数"再一起排
- 前台只说"这几本可能有用，书号在这"，读不读、信不信由读者（AI）自己判断
- 每推荐一次就在登记簿上记一笔（`recalled_count`），后面的治理（第 7 篇）靠这些数据

---

## 1. 为什么需要它

### 1.1 知识沉淀下来，不被用上就等于没有

前几步把团队经验写成 learnings、发布、再 pull 到每个人本机。但 AI 不会自己去翻这些目录。recall 解决的是"在恰当时机，把少量最相关的条目递到 AI 眼前"。

### 1.2 谁来触发：规则，而不是 hook

`src/builtin-rules.ts:20-22` 的注释说明了历史：

```ts
//  teamai-recall.md instructs the AI to proactively search the team
//  knowledge base (via the `teamai-recall` subagent or `teamai recall`)
//  before starting a task — this replaced the old passive auto-recall
```

现在是 pull 时下发一条内置规则 `teamai-recall`（`BUILTIN_RULE_NAMES`，`src/builtin-rules.ts:29`），让 AI 自己决定什么时候调用。规则正文（`src/builtin-rules.ts:183-206`）要求：

- 涉及代码改动、调试、设计决策的任务开始前"SHOULD"检索
- 三个跳过条件：用户已给上下文、本地文件已有答案、简单局部改动
- 两种方式：调用 `teamai-recall` 子 agent（推荐），或直接 `teamai recall "<关键词1> <关键词2> ..."`，提取 3-6 个高信号关键词
- 输出里出现 `Nothing was searched:` 或 `Recall skips the older index` 时，要把原话转告用户，不能得出"团队没有相关知识"的结论（`src/builtin-rules.ts:208-212`）

### 1.3 为什么规则要求"中英双语关键词"

因为检索是纯词法匹配，没有向量/语义。规则原文（`src/builtin-rules.ts:214-219`）：

```text
**务必中英双语检索（跨语言召回）**：知识库中英文混杂，检索是纯词法匹配，
中文 query 无法命中纯英文文档，反之亦然。因此每个领域术语都应**同时给出中英两种写法**
一起检索，例如「重启推理集群」应扩展为 `重启 推理 集群 restart inference cluster`；
只翻译中英确实不同的术语；任何**语言无关的 token**（中英写法相同、或无实际译法者）一律保持原样，
例如专有名词、品牌与产品名、缩写、代码标识符与符号、错误码、版本号、文件路径、命令与 API 名
（`AppID`、`Kubernetes`、`GPU`、`RuntimeError`、`v2.1.3`、`oauth`）——翻译它们只会损害匹配。
```

设计取舍：不引入 embedding 模型（零依赖、离线、毫秒级、结果可解释），代价是跨语言召回要靠调用方自己扩展查询。把"翻译"交给本来就擅长它的 LLM，是划算的分工。为什么不能翻译 `AppID` 这类词，看 4.1 节的分词器就明白了：它们会被拆成 `appid`、`app`、`id` 精确匹配，翻译后反而一个都对不上。

`recallRuleContent(language)`（`src/builtin-rules.ts:259`）：团队 `language: en` 时下发纯英文版，否则下发中英双语的历史版本（#1014）。

### 1.4 为什么不用一个固定分数阈值

这是 recall.ts 里注释最长的部分（`src/recall.ts:27-61`）。核心矛盾：

| 问题 | 原因 | 对策 |
| --- | --- | --- |
| 长查询天然高分 | 原始分是逐词累加 | `search` 里除以 `sqrt(查询 token 数)` |
| 语料越大分数越高 | IDF 里含条目总数 N，分数随 log(N) 漂移 | 阈值 = 单词命中基线 × 1.35 |
| 冷启动语料（1-5 条）相对阈值太松 | 基线很小，单个 tag 命中就过线 | 再加绝对地板 4.0，取 max |
| learnings 分数无上界、codebase 分数有界 | 两套打分算法不同 | 都映射到 0-10 再合并排序 |

---

## 2. 关键数据结构与存储位置

### 2.1 文件都在哪

| 东西 | 位置 | 来源 |
| --- | --- | --- |
| 用户级索引 | `~/.teamai/search-index.json` | `getUserSearchIndexPath()`，`src/types.ts:2209` |
| 项目级索引 | `<dataHome>/search-index.json`；self 模式按 checkout 分开：`<dataHome>/workspaces/<id>/search-index.json` | `getProjectSearchIndexPath()`，`src/types.ts:2817` |
| 索引 schema 版本 | `SEARCH_INDEX_VERSION = 7` | `src/types.ts:2152` |
| 代码知识图谱 | `<repo.localPath>/teamwiki/` | `src/recall.ts:673-675` |
| 本地投票文件 | `getVotesDir(config)/<username>.yaml` | `autoUpvote`，`src/recall.ts:308-309` |
| 召回质量缓存 | `~/.teamai/sessions/<sid>-recall-cache.json` | 数据流注释，`src/recall.ts:173-175` |
| 召回运行日志 | `<dataHome>/dashboard/recall.jsonl` | 数据流注释，`src/recall.ts:177-179` |

```ts
// src/types.ts:2817
export function getProjectSearchIndexPath(localConfig: LocalConfig): string {
  const dataHome = getDataHome(localConfig);
  if (isSelfMode(localConfig)) {
    return path.join(dataHome, 'workspaces', managedMcpWorkspaceId(getBusinessRoot(localConfig)), 'search-index.json');
  }
  return path.join(dataHome, 'search-index.json');
}
```

### 2.2 一条索引条目长什么样

每篇文档是一个 `SearchIndexEntry`。关键是 `tokens` 字段：建索引时把"位置信息"编码进了 token 名字里（`src/utils/search-index.ts:513-525`）：

```ts
  const titleTokens = tokenize(title);
  const tagTokens = tags.flatMap((tag) => tokenize(tag));
  const bodyTokens = tokenize(bodyExcerpt);

  const tokens = [
    ...titleTokens.map((t) => `title:${t}`),
    ...titleTokens,
    ...tagTokens.map((t) => `tag:${t}`),
    ...tagTokens,
    ...bodyTokens,
    `type:${type}`,
  ];
```

两点手算时会用到：

1. 标题词既以 `title:x` 存一次，又以裸的 `x` 存一次；tag 同理。所以一次标题命中实际拿到"标题分 + 正文分"
2. 返回时 `tokens: [...new Set(tokens)]` 去重（`src/utils/search-index.ts:535`），正文里一个词出现 10 次和 1 次一样。没有真正的词频，严格说是"二值 TF × IDF"

一个示意条目（为讲解手写，字段名来自 `src/utils/search-index.ts:529-539` 的返回对象）：

```json
{
  "filename": "api-timeout-retry.md",
  "title": "API timeout retry",
  "tags": ["api"],
  "tokens": ["title:api", "title:timeout", "title:retry", "api", "timeout", "retry", "tag:api", "type:learnings"],
  "votes": 2,
  "type": "learnings",
  "domain": "technical",
  "path": "/abs/path/api-timeout-retry.md"
}
```

索引顶层除了 `entries`，还有 `df`（全局文档频率）和 `dfByDomain`（按领域分开的文档频率），在 `indexInMemory` 最后统计（`src/utils/search-index.ts:952-961`）：

```ts
  const df: Record<string, number> = {};
  const dfByDomain: NonNullable<SearchIndex['dfByDomain']> = {};
  for (const entry of entries) {
    const domain = entry.domain ?? 'neutral';
    const domainDf = dfByDomain[domain] ??= {};
    for (const token of new Set(entry.tokens)) {
      df[token] = (df[token] ?? 0) + 1;
      domainDf[token] = (domainDf[token] ?? 0) + 1;
    }
  }
```

### 2.3 四种类型、四个领域

- 类型 `type`：`learnings / docs / rules / skills`，由不同 collector 收集（`src/utils/search-index.ts:912-935`）
- 领域 `domain`：`technical / ops / support / neutral`，由 `inferDomain` 按优先级推断（`src/utils/search-index.ts:236-285`）：frontmatter 显式 `domain:` > tag 词表（`TECHNICAL_TAGS` 等）> 路径模式（如 `docs/architecture/` 是 technical、`learnings/ops/` 是 ops）> 类型兜底（skills/rules 算 technical，其他 neutral）

---

## 3. 端到端流程图

```text
AI（受 teamai-recall 规则驱动）
  │  teamai recall "api timeout"     或子 agent: teamai recall --caller teamai-recall ...
  ▼
index.ts:1180  Commander: recall [query...] --depth(默认 context) --check --caller(隐藏)
  ▼
recall()  recall.ts:537
  ├─ 空查询且非 --check → 打印用法，返回
  ├─ detectProjectConfig()  项目配置读不了 → "Nothing was searched: ..."，exitCode=1
  ├─ 空查询 + --check → NOT_RELEVANT score=0.0
  ├─ 校验 --depth ∈ {route, context, lookup}，否则回落 context
  │
  ├─ 选作用域
  │   有项目配置：project 索引；inheritUserScope=true 时再加 user
  │   无项目配置：只用 user 索引
  │   每个都走 loadOrBuildScopeIndex()：
  │     loadIndex → 缺失 / isLegacyIndex / children 指纹变了 → 重建
  │
  ├─ 路 A：learnings 路（learnings / docs / rules / skills）
  │   for 每个 scope 索引: search(query, index, 全部条目数)
  │     tokenize → 推断查询领域 → 逐条目 3/2/1 × IDF(按条目领域)
  │     → 无标题/tag 命中且非 docs 就丢 → ÷√len → +投票 → ×领域×类型
  │     → 排序 → 去重
  │   project 条目遮蔽同 type:filename 的 user 条目
  │   每条结果记下"自己领域"的 idfBaseline
  │
  ├─ 路 B：codebase 路（详见第 8 篇）
  │   queryCodeKnowledge(query, {wikiRoot, limit:3, depth})
  │   score = min(10, log2(bm25+1) × 2)，标记 fromCodebase
  │
  ├─ 合并排序：codebase 用原分；learnings 用 normalizeLearningsScoreForRanking
  │            同分按日期新的在前
  │
  ├─ --check？→ 只看 top1：isRelevantScore → "RELEVANT|NOT_RELEVANT score=.. threshold=.." → 返回
  │
  ├─ 取前 5 → annotateCodebaseSourceFreshness（只对要展示的 codebase 结果）
  ├─ 非 dry-run 且未设 TEAMAI_RECALL_DISABLED=1：recordRecallQuality + recordRun（得 run id）
  ├─ 0 条 → "No matching learnings found for ... run=<id>"
  ├─ formatResults → STDOUT（AI 读这里）
  └─ autoUpvote：只给"当前活跃作用域"的结果 recalled_count +1
```

---

## 4. 逐函数走读

### 4.1 tokenize：中英混合怎么切词

索引侧和查询侧用的是同一个分词器 `src/utils/tokenizer.ts`（文件头注释：确保 search-index 和 code-knowledge-recall 分词一致）。核心逻辑（`src/utils/tokenizer.ts:26-83`，删了部分注释）：

```ts
const sharedSegmenter = new Intl.Segmenter('zh-CN', { granularity: 'word' });

export function tokenize(text: string): string[] {
  if (!text) return [];
  const input = text.length > MAX_TOKENIZE_CHARS ? text.slice(0, MAX_TOKENIZE_CHARS) : text;
  // ...
  for (const seg of segmenter.segment(input)) {
    if (!seg.isWordLike) { flushCjkRun(); continue; }

    const word = seg.segment.toLowerCase();
    tokens.push(word);

    if (/[A-Z]/.test(seg.segment)) {
      const split = seg.segment
        .replace(/([a-z])([A-Z])/g, '$1 $2')
        .replace(/([A-Z]+)([A-Z][a-z])/g, '$1 $2')
        .toLowerCase()
        .split(/\s+/)
        .filter((t) => t.length >= 2);
      for (const t of split) {
        if (t !== word) tokens.push(t);
      }
    }

    if (word.length === 1 && /[一-鿿]/.test(word)) {
      cjkRun.push(word);
    } else {
      flushCjkRun();
    }
  }
  flushCjkRun();
  return [...new Set(tokens)];
}
```

逐段看：

- 用 Node 内置的 `Intl.Segmenter('zh-CN')` 做词边界切分，中英文都能切，零依赖
- 全部转小写；含大写字母的标识符额外拆 camelCase：`getUserById` 除了 `getuserbyid` 还会产出 `get / user / by / id`（`src/utils/tokenizer.ts:7`）。拆出的子词长度要 >= 2
- 中文的补救：Segmenter 有时把真词切成单字（"排查" 切成 "排" 和 "查"），所以连续的单字会两两拼成 bigram 补回来；遇到多字词就断开，避免 "推理"+"服务" 拼出无意义的 "理服"（`src/utils/tokenizer.ts:8-9, 35-37`）
- 最多处理 `MAX_TOKENIZE_CHARS = 50_000` 个字符；最后去重

文件头还有一条维护约定（`src/utils/tokenizer.ts:13-22`）：分词逻辑只减 token 是安全的；一旦开始产生新 token，旧索引里没有它，召回会静默失效，必须 bump `SEARCH_INDEX_VERSION` 触发全量重建。

另一个函数 `wordSegments`（`src/utils/tokenizer.ts:123`）不转小写、不拆 camelCase、不出 bigram，只用来把"命中了哪些词 / 漏了哪些词"按用户原样报告回去（比如报 `AppID` 而不是 `app`、`id`）。

### 4.2 loadOrBuildScopeIndex：索引不在或过时就当场重建

recall 不假设 pull 一定建好了索引。`loadOrBuildScopeIndex`（`src/recall.ts:385`）先定路径：

```ts
  const indexPath = localConfig.scope === 'project' && localConfig.projectRoot
    ? getProjectSearchIndexPath(localConfig)
    : getUserSearchIndexPath();
```

再判断要不要重建（`src/recall.ts:416-424`）：

```ts
  let index = await loadIndex(indexPath);
  const needsRebuild = !index || isLegacyIndex(index) || index.children !== localConfig.children?.fingerprint;
  if (needsRebuild && (index || effectiveLearningsDir || await pathExists(path.join(localConfig.repo.localPath, 'docs')) || /* rules、skills 同理 */)) {
    // ... 组装 BuildIndexOptions，调 buildIndex 或 dry-run 时的 indexInMemory
  }
```

三个触发条件：

- `loadIndex` 返回 null：文件不存在或 JSON 坏了（`src/utils/search-index.ts:991-997`，只要 `entries` 不是数组就当没有）
- `isLegacyIndex`：版本号小于 7，或有条目缺 `type`/`domain`，或缺 `df`/`dfByDomain`（`src/utils/search-index.ts:979-986`）
- workspace 子项目选择变了（`children` 指纹不同，#913）

```ts
// src/utils/search-index.ts:979
export function isLegacyIndex(index: SearchIndex | null): boolean {
  if (!index) return false;
  if (typeof index.version !== 'number' || index.version < SEARCH_INDEX_VERSION) return true;
  return index.entries.some((e) => !e.type || e.domain === undefined)
    || !index.df
    || !index.dfByDomain
    || index.entries.some((e) => index.dfByDomain?.[e.domain ?? 'neutral'] === undefined);
}
```

重建时 learnings 的来源是多根合并：`[pendingLearningsDir(localConfig), ...roots.read]`（`src/recall.ts:407`），即"排队未发布的 + learnings 分支 + 本机镜像 + 拆分前的历史目录"，注释说只挑一个根"会悄悄返回更少"（`src/recall.ts:400-403`）。所以刚 contribute、还没发布的条目也能被召回。

`buildIndex`（`src/utils/search-index.ts:833`）本身只是 `indexInMemory` + 原子写入 `writeJsonAtomic`。写失败时会把旧索引删掉并抛错，理由是旧索引会继续返回"成员已经不再接收"的内容（#1006，`src/utils/search-index.ts:855-863`）。recall 侧对应的处理是：构建失败返回 `'build-failed'`，绝不回退到磁盘上的旧索引（`src/recall.ts:508-520`）。

### 4.3 search：一条条目怎么得分（`src/utils/search-index.ts:1049-1203`）

第一步，分词 + 推断查询领域：

```ts
  const queryTokens = tokenize(query);
  if (queryTokens.length === 0) return [];
  const queryDomain = inferQueryDomain(queryTokens);
  const domainWeightRow = DOMAIN_WEIGHT[queryDomain];
```

`inferQueryDomain`（`src/utils/search-index.ts:186`）拿查询 token 去对 `TECHNICAL_TAGS / OPS_TAGS / SUPPORT_TAGS` 计数，最多者胜，平局 technical > ops > support，都没命中就是 neutral。

第二步，按条目自己的领域算 IDF（`src/utils/search-index.ts:1077-1087`）：

```ts
  const idf = (token: string, domain: KnowledgeDomain): number => {
    const domainDf = index.dfByDomain?.[domain];
    if (domainDf) {
      const n = domainSizes[domain] ?? 0;
      const docFreq = domainDf[token] ?? 0;
      return Math.log((n + 1) / (docFreq + 1)) + 1;
    }
    if (!index.df) return 1.0;
    const docFreq = df[token] ?? 0;
    return Math.log((index.entries.length + 1) / (docFreq + 1)) + 1;
  };
```

公式是平滑 IDF：`ln((N+1)/(df+1)) + 1`，其中 N 是**该领域**的条目数。为什么按领域分？注释（`src/utils/search-index.ts:1063-1065`）：这样往库里加一批无关领域的知识，不会改变已有条目的分数。

第三步，逐 token 累加，并做"标题/tag 门槛"（`src/utils/search-index.ts:1114-1146`）：

```ts
    for (const qt of queryTokens) {
      const titleToken = `title:${qt}`;
      const tagToken = `tag:${qt}`;
      if (entryTokens.has(titleToken)) { score += 3 * idf(titleToken, entryDomain); hasTitleOrTagMatch = true; }
      if (entryTokens.has(tagToken))   { score += 2 * idf(tagToken, entryDomain);   hasTitleOrTagMatch = true; }
      if (entryTokens.has(qt))         { score += 1 * idf(qt, entryDomain); }
    }

    const isDocsEntry = entry.type === 'docs';
    if (score > 0 && (hasTitleOrTagMatch || isDocsEntry)) {
      score /= lengthNorm;
      score += Math.min(entry.votes * 0.5, 5);
      const domainMultiplier = domainWeightRow[entry.domain ?? 'neutral'];
      const typeMultiplier = TYPE_BONUS[entry.type];
      score *= domainMultiplier * typeMultiplier;
      // codebase-index.md ×1.5；hotness < 1 时 ×hotness
      // ...
    }
```

（为排版把 if 体压成了单行，逻辑与源码一致。）顺序很重要：

1. 只命中正文、没命中标题或 tag 的条目直接丢弃，除非它是 docs（docs 常没有 tag、标题又泛，`src/utils/search-index.ts:1131-1133`）
2. 先除以 `lengthNorm = sqrt(查询 token 数)`，再加投票分。投票分是绝对值：每票 0.5，封顶 5
3. 再乘领域系数和类型系数（skills/rules ×1.1，learnings/docs ×1.0，`src/utils/search-index.ts:204-209`）
4. 文件名是 `codebase-index.md` 的再 ×1.5；带 `hotness` 且小于 1 的冷条目按比例降权（hotness 由第 7 篇的治理逻辑写入）

领域系数表（行=查询领域，列=条目领域，`src/utils/search-index.ts:169-176`）：

| 查询 \ 条目 | technical | neutral | ops | support |
| --- | --- | --- | --- | --- |
| technical | 1.0 | 0.85 | 0.5 | 0.3 |
| ops | 0.7 | 0.85 | 1.0 | 0.3 |
| neutral | 1.0 | 0.85 | 0.75 | 0.3 |
| support | 0.8 | 0.85 | 0.5 | 1.0 |

第四步，排序（分数降序，同分日期新的在前）后按 `dedupKey` 去重再截断（`src/utils/search-index.ts:1179-1200`）。`dedupKey` 用 type、domain、title、date、author 和排序后的 tokens 判同：同一条经验被分享两次、只差文件名随机后缀时，只保留分高的那份，避免占掉两个名额。

另外，命中标题/tag 的结果还会带 `matchedTerms / missingTerms`：按 `wordSegments(query)` 的每个原词，看它的任一 token 是否命中 `title:` 或 `tag:`（`src/utils/search-index.ts:1167-1174`）。

### 4.4 手算一次：`teamai recall "api timeout"`

假设（为讲解虚构的数据）：technical 领域有 N=9 个条目；目标条目就是 2.2 节那条 `api-timeout-retry.md`（technical、learnings、2 票）；该领域文档频率为 `title:api`=2、`api`=4、`tag:api`=3、`title:timeout`=1、`timeout`=2。

1. 分词：`tokenize("api timeout")` = `["api", "timeout"]`，`lengthNorm = sqrt(2) ≈ 1.414`
2. 查询领域：`api` 和 `timeout` 都在 `TECHNICAL_TAGS`（`src/utils/search-index.ts:110,113`），所以是 technical，用 technical 那一行系数
3. 逐 token 打分，IDF = `ln((9+1)/(df+1)) + 1`：

| 命中的 token | 权重 | df | IDF | 得分 |
| --- | --- | --- | --- | --- |
| `title:api` | 3 | 2 | ln(10/3)+1 ≈ 2.204 | 6.612 |
| `tag:api` | 2 | 3 | ln(10/4)+1 ≈ 1.916 | 3.833 |
| `api` | 1 | 4 | ln(10/5)+1 ≈ 1.693 | 1.693 |
| `title:timeout` | 3 | 1 | ln(10/2)+1 ≈ 2.609 | 7.828 |
| `timeout` | 1 | 2 | ln(10/3)+1 ≈ 2.204 | 2.204 |
| 合计 | | | | 22.170 |

4. 除长度：22.170 / 1.414 ≈ 15.68
5. 加投票：+ min(2 × 0.5, 5) = +1，得 16.68
6. 乘系数：technical 查 technical = 1.0，learnings = 1.0，最终原始分 ≈ 16.7（输出里的 `Score: 16.7`）

7. 相关性阈值（4.5 节）：基线 = `ln((9+1)/2) + 1` ≈ 2.609；2.609 × 1.35 ≈ 3.52 < 4.0，所以阈值取地板 4.0。16.7 >= 4.0，RELEVANT
8. 排序用分（4.6 节）：`4 + 2 × log2(16.68 / 4.0)` ≈ 4 + 2 × 2.06 ≈ 8.12

对比：如果这条是 ops 领域，第 6 步要乘 0.5，原始分只剩约 8.3。这就是"技术问题优先给技术经验"的落地方式。另外注意 `timeout` 只在标题不在 tag，所以 `tag:timeout` 没分；而只在正文出现 `timeout` 的 learnings 条目，如果标题和 tag 都没命中，会被门槛直接丢掉。

### 4.5 isRelevantScore 和 computeIdfBaseline：阈值怎么定

```ts
// src/recall.ts:81
export function isRelevantScore(score: number, isCodebaseHit: boolean, idfBaseline: number): boolean {
  if (isCodebaseHit) return score >= CODEBASE_RELEVANCE_THRESHOLD;
  const baseline = idfBaseline > 0 ? idfBaseline : 1;
  return score >= Math.max(baseline * LEARNINGS_RELEVANCE_RATIO, LEARNINGS_ABSOLUTE_FLOOR);
}
```

三个常量：`CODEBASE_RELEVANCE_THRESHOLD = 4.0`（`src/recall.ts:25`）、`LEARNINGS_RELEVANCE_RATIO = 1.35`（`:49`）、`LEARNINGS_ABSOLUTE_FLOOR = 4.0`（`:61`）。

基线就是"一个只在 1 个条目里出现的 token 的 IDF"，与 search 的公式保持一致（`src/recall.ts:109-130`，删了注释）：

```ts
export function computeIdfBaseline(indexes: SearchIndex[], domain?: KnowledgeDomain): number {
  let maxEntries = 0;
  for (const idx of indexes) {
    if (!idx.df) continue;
    if (idx.dfByDomain) {
      const domainSizes: Partial<Record<KnowledgeDomain, number>> = {};
      for (const entry of idx.entries) {
        const entryDomain = entry.domain ?? 'neutral';
        domainSizes[entryDomain] = (domainSizes[entryDomain] ?? 0) + 1;
      }
      const entryCount = domain
        ? domainSizes[domain] ?? 0
        : Math.max(0, ...Object.values(domainSizes));
      if (entryCount > maxEntries) maxEntries = entryCount;
    } else if (idx.entries.length > maxEntries) {
      maxEntries = idx.entries.length;
    }
  }
  if (maxEntries === 0) return 1;
  return Math.log((maxEntries + 1) / 2) + 1;
}
```

要点：

- 传了 `domain` 就只数该领域的条目数，所以每条结果的阈值只看自己领域的语料大小，无关领域长大不会抬高它的门槛（测试 `does not let unrelated domains raise a result baseline`）
- 没有 `df` 的旧索引直接跳过，不参与 N 的计算；全都没有时返回 1，相当于退回绝对阈值
- 交叉点：`ln((N+1)/2)+1` 要大于 `4.0/1.35 ≈ 2.96`，N 大约要到 20 以上，相对阈值才会超过地板，和源码注释说的"N ≳ 20"一致

### 4.6 两路合并：为什么 learnings 要换算一次

learnings 原始分没有上界，codebase 分被压到 0-10。直接比，语料一大 learnings 就永远压过代码知识。所以合并排序前给 learnings 做一次换算（`src/recall.ts:138-143`）：

```ts
export function normalizeLearningsScoreForRanking(score: number, idfBaseline: number): number {
  if (score <= 0) return 0;
  const baseline = idfBaseline > 0 ? idfBaseline : 1;
  const threshold = Math.max(baseline * LEARNINGS_RELEVANCE_RATIO, LEARNINGS_ABSOLUTE_FLOOR);
  return Math.min(10, Math.max(0, 4 + 2 * Math.log2(score / threshold)));
}
```

设计很巧：刚好等于阈值的 learnings 映射成 4，正好等于 codebase 的阈值 4.0；分数每翻一倍加 2，封顶 10。于是"刚过线"在两边是同一个意思。

codebase 一侧（`src/recall.ts:731-756`）：

```ts
    const codeResults = await queryCodeKnowledge(query, { wikiRoot, limit: 3, depth: options.depth, withheldCodebases });
    for (const cr of codeResults) {
      allResults.push({
        entry: { filename: cr.page, title: cr.title, /* ... */ type: 'docs' as const, domain: 'technical' as const, path: path.join(wikiRoot, cr.page), snippet: cr.snippet },
        score: Math.min(10, Math.log2(cr.score + 1) * 2),
        // ...
        sources: cr.sources,
        relatedFiles: cr.relatedFiles,
        fromCodebase: true,
      });
    }
```

（`entry` 字段为排版压成一行。）BM25 原始分用 `log2(x+1) × 2` 压缩（注释叫 "B11 fix: log-dampening instead of min-max normalization"），最多取 3 条。比如 BM25=20 时得 `log2(21)×2 ≈ 8.78`，会排在 4.4 节那条 8.12 的 learnings 前面。整个 codebase 查询包在 try 里，失败只打一条 warn（`src/recall.ts:757-759`），不影响 learnings 结果。`--depth` 只传给 `queryCodeKnowledge`，内部怎么遍历图谱见第 8 篇。

最终排序（`src/recall.ts:763-770`）：

```ts
  const rankingScore = (result: ScopedSearchResult): number => result.fromCodebase
    ? result.score
    : normalizeLearningsScoreForRanking(result.score, result.idfBaseline ?? idfBaseline);
  allResults.sort((a, b) => {
    const scoreDelta = rankingScore(b) - rankingScore(a);
    if (scoreDelta !== 0) return scoreDelta;
    return (b.entry.date || '').localeCompare(a.entry.date || '');
  });
```

注意：只是排序用换算分，`result.score` 本身保持原值，所以输出里的 `Score:`、`--check` 判定、质量记录用的都是原始分（`src/recall.ts:761-762` 注释）。

### 4.7 recall 主流程的收尾：--check、输出、记账

`--check` 只看合并排序后的第 1 名（`src/recall.ts:772-776`），由 `emitCheckVerdict`（`src/recall.ts:546-571`）打印一行，例如：

```text
RELEVANT score=16.7 threshold=4.0 title="API timeout retry" matched=api,timeout missing=retry? ...
```

（示意。真实字段：`score`、`threshold` 必有；RELEVANT 时追加 `title`、`matched`、`missing`、`sources`。）它在 `annotateCodebaseSourceFreshness`、`recordRecallQuality`、`recordRun`、`autoUpvote` 之前就 return，所以预检不读源文件哈希、不计票、不记质量（注释 `src/recall.ts:780-781`）。子 agent 的工作流是先 `--check` 再决定要不要真查（`agents/teamai-recall.md:28`）。

正式输出 `formatResults`（`src/recall.ts:228-294`）：首行 `--- [teamai:recall:start] --- (N results) run=<id>`，每条有 `[i/N] [type] 标题 ★票数 [scope]`、Author/Date/Score、Tags、`Matched/Missing`（有缺词时才打）、`File:`、codebase 的 `Sources:` 和新鲜度、Snippet；最后汇总最多 10 个 `Candidate change files`，以 `--- [teamai:recall:end] ---` 和一句"仅供参考，用 Read 打开文件"结尾。用分隔符包起来，是为了让 AI 把内容当参考而不是指令（`src/recall.ts:189`）。`File:` 走 `resolveReadablePath`：索引里的绝对路径不存在了（比如 worktree 重建）就回退到当前 learnings 根下的同名文件（`src/recall.ts:202-212`）。

`autoUpvote`（`src/recall.ts:300-325`）给返回的每条结果在 `getVotesDir(config)/<username>.yaml` 里 `incrementRecalled`，键是索引 filename 去掉 `.md`。拿不到锁就跳过这次，只打 debug 日志（#723）。项目模式下只给 project 作用域的结果记票，继承来的 user 结果只读（`src/recall.ts:815-833`）。这些计数怎么变成置信度，见第 7 篇。

`--caller` 是隐藏参数（`src/index.ts:1184`："set by the teamai-recall subagent to mark its own runs"）。在 recall.ts 里它只被写进运行日志（`recordRun` 的 `caller` 字段，`src/recall.ts:354`）。真正防止"子 agent 又去调子 agent"无限递归的，是规则开头的自豁免段落（`src/builtin-rules.ts:179-181`）：Cursor 这类工具会把 always-apply 规则泄漏进子 agent 会话，所以规则自己声明"如果你就是 teamai-recall 子 agent，本规则不适用"。

---

## 5. 常见坑与边界情况

| 现象 | 原因 | 出处 |
| --- | --- | --- |
| 中文查询查不到英文经验 | 纯词法匹配，没有翻译 | 规则 `src/builtin-rules.ts:214`；所以要双语关键词 |
| 正文明明有这个词却没召回 | learnings/rules/skills 要求标题或 tag 至少命中一个；只有 docs 豁免 | `src/utils/search-index.ts:1131-1135` |
| 冷启动只有 3 条经验，单个 tag 命中也不算 RELEVANT | 绝对地板 4.0 | 测试 `cold-start (baseline=1): old passing score (1.35) now correctly fails` |
| 项目里改过的经验，用户级旧版还冒出来 | 不会：project 条目按 `type:filename` 遮蔽 user 条目，即使 project 版本没命中这次查询 | `src/recall.ts:703-707`；测试 `shadows a matching user entry even when the project replacement does not match` |
| 输出 `Nothing was searched:` | 项目配置读不了，宁可不查也不去查别的团队 | `src/recall.ts:598-608`（#784、#796） |
| 索引写失败后 recall 什么都查不到 | 故意删掉旧索引，不用过期数据，提示跑 `teamai pull` | `src/utils/search-index.ts:855-863` |
| 改了分词逻辑召回静默变差 | 新增 token 旧索引里没有，必须 bump `SEARCH_INDEX_VERSION` | `src/utils/tokenizer.ts:13-22` |
| `docs/team-codebase` 不再被索引 | 已迁移到 `teamwiki/` 图谱，只打一条 warn | `src/recall.ts:436-440` |
| `--depth abc` | warn 后回落到 `context` | `src/recall.ts:615-619` |
| `TEAMAI_RECALL_DISABLED=1` 或 `--dry-run` | 照常搜索输出，但不记质量、不记运行日志；dry-run 还不投票、索引只在内存重建 | `src/recall.ts:796, 819, 502-503` |

---

## 6. 动手验证

只读命令（在仓库根目录执行）：

```bash
# 看本机用户级索引的版本、条目数、各领域条目数
jq '{version, n: (.entries|length), domains: ([.entries[].domain] | group_by(.) | map({(.[0]): length}) | add)}' ~/.teamai/search-index.json

# 看某条目的 tokens，理解 title:/tag:/裸词三份存储
jq '.entries[0] | {title, tags, domain, type, votes, tokens}' ~/.teamai/search-index.json

# 只做相关性预检（不计票、不记质量）
teamai recall --check "api timeout"
```

相关单测（`npm test` 即 `vitest run`，可单跑一个文件：`npx vitest run src/__tests__/recall-relevance-threshold.test.ts`）：

- `src/__tests__/recall-relevance-threshold.test.ts`：`N=25: relative threshold governs — score just above baseline*1.35 passes`、`maps the corpus-aware learnings relevance threshold to the codebase threshold`、`does not let unrelated domains raise a result baseline`
- `src/__tests__/recall-check.test.ts`：`ranks graph hits against corpus-normalized learnings scores`、`check mode does not record recall quality (no side effects)`、`empty query + check emits NOT_RELEVANT score=0.0`
- `src/__tests__/search-domain-weighting.test.ts`：`technical entry outranks ops entry with the same raw title/tag score`、`skills type gets TYPE_BONUS (×1.1) over a same-domain learnings entry`
- `src/__tests__/search-idf-domain-isolation.test.ts`：`CJK query resolves to a real domain (0b)`
- `src/__tests__/recall-scope-isolation.test.ts`：`does not write inherited user votes through the active project channel`
- `src/__tests__/recall-format.test.ts`：`falls back to the learnings root when the indexed absolute path is gone`

---

## 7. 自测问题

<details>
<summary>1. 同一个词出现在标题里，一共能拿几份分？</summary>

两份：`title:x` 的 3×IDF，加上裸词 `x` 的 1×IDF，因为建索引时标题词两种形式都存了（`src/utils/search-index.ts:518-519`）。如果 tag 里也有，再加 2×IDF。
</details>

<details>
<summary>2. 为什么 learnings 阈值是 max(基线×1.35, 4.0)，而不是固定数？</summary>

IDF 随语料条目数 N 按 log 增长，固定阈值会随语料变大而漂移变松；只用相对阈值在 1-5 条的冷启动语料里又太松。取 max 让小语料沿用 4.0，大语料自动跟着基线走。
</details>

<details>
<summary>3. learnings 原始分 8.0、阈值 4.0，codebase BM25 分 15，谁排前面？</summary>

learnings 换算为 4 + 2×log2(8/4) = 6.0；codebase 为 min(10, log2(16)×2) = 8.0。codebase 在前。
</details>

<details>
<summary>4. `--check` 为什么能保证"便宜"？</summary>

它在合并排序后就 return，不做源文件新鲜度哈希、不写召回质量、不写运行日志、不 autoUpvote（`src/recall.ts:772-776, 780-781`）。
</details>

<details>
<summary>5. 子 agent 如何避免无限递归？</summary>

靠 `teamai-recall` 规则开头的自豁免段落告诉子 agent 本规则不适用于它；`--caller teamai-recall` 只是给这次运行打标记，写进 recall 运行日志。
</details>

---

## 8. 导航

- 上一步：[05-pull-distribution.md](./05-pull-distribution.md)（知识怎么 pull 到本机、索引怎么建）
- 下一步：[07-feedback-governance.md](./07-feedback-governance.md)（recalled/upvoted 怎么变成置信度、淘汰和升级）
- 代码知识图谱那一路（`queryCodeKnowledge`、`--depth`）：[08-teamwiki-code-knowledge.md](./08-teamwiki-code-knowledge.md)
- 系列索引：[README.md](./README.md)

---

## 9. 未逐行核实

- `queryCodeKnowledge`（`src/code-knowledge-recall.ts`）内部的 BM25、图谱扩展和 `--depth` 三档的具体遍历逻辑未读，本文只引用了 recall.ts 里对它的调用和分数压缩
- `annotateCodebaseSourceFreshness`、`recordRecallQuality`、`recordRun` 依赖的 `recall-log.ts`、`votes.js` 的 `incrementRecalled` 内部实现未读；召回质量缓存和 recall.jsonl 的路径取自 recall.ts 数据流注释，未在实现中核对
- `collectLearningsEntries` 等 collector 如何截取 `bodyExcerpt`（正文取多长）未读，只知道单文件超过 50KB 会截断（`MAX_DOC_BYTES`）
- `hotness` 的计算（`maintenance/hot-cold.js` 的 `annotateHotness`）未读
- `teamai recall` 在 CLI 层是否接受全局 `--dry-run`（`src/index.ts` 有 `dryRunRefusal` 守卫）未核实；recall.ts 内部确实处理 `options.dryRun`
- `teamai recall --check` 在索引缺失或过时时仍可能触发一次重建写盘（`loadOrBuildScopeIndex` 在 check 判断之前执行），所以"只读"只对已有新索引成立
- 4.4 节的语料数字与 4.7 节的 check 输出行是为讲解虚构的示意，不是实际运行结果
- `inferDomain` 的完整 tag 词表（`TECHNICAL_TAGS` 等）只看了前几项
