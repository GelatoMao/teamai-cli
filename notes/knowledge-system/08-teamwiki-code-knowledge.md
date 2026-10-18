# 第 8 步：另一条知识来源（teamwiki 代码知识图谱与 MR 提炼）

> 面向小白。先讲"为什么要有它"和"整体长什么样"，再沿着一次真实调用逐函数看代码。
> 代码摘自本仓库 main@fe3b906 源码（2026-10-17），标注 `文件:行号`；行号会随提交变化，以函数名为准。为便于阅读删减了部分注释，用 `// ...` 省略无关分支。
> 前 7 篇讲的都是 learning（会话里沉淀出来的"经验"）。本篇讲另一条完全不同的知识来源：从代码本身抽出来的"结构知识"，存在团队仓库的 `teamwiki/` 下。

---

## 0. 一句话 + 一个类比

一句话：`teamai import --dir / --from-repo / --from-repo-list / --from-org` 把一份代码 checkout 放到临时目录里抽取成"证据 + 图谱"，发布到团队仓库的 `teamwiki/evidence/code/<slug>/`，并在同一目录留一份 `source-manifest.json`（每个文件的 SHA256 基线）。之后 `--incremental` 只重抽有变化的部分；`--from-mr` 和 `teamai ci extract-mr` 让每次合入的 MR 同时产出一条 learning 和一次 teamwiki 增量更新；recall 命中 teamwiki 页面时，会用当前 checkout 的文件哈希和基线比对，告诉 AI 这条知识是 `current`、`stale`、`missing` 还是 `unknown`。

类比：城市的"地图"和"老司机笔记"。

- learning 是老司机笔记，比如"这个路口早高峰别左转"。来自经验，主观、零散，但很值钱
- teamwiki 是测绘院出的地图：每条路、每座桥在哪，都能追到实地坐标（代码行）
- `--incremental` 是"只重测修过路的街区"，`source-manifest.json` 是上次测绘时每个地块的指纹
- Source freshness 是地图角上的一行字："本页测绘于 X 日，与现场一致/已变更"

---

## 1. 为什么需要它

### 1.1 learning 解决不了"全局结构"问题

learning 是一条条 Markdown 经验，靠 BM25 召回（见 [06-recall-search.md](06-recall-search.md)）。它擅长记录"踩过的坑"，但回答不了"这个服务依赖哪些模块""改这个接口会影响谁"这类问题。`skill-data/wiki/SKILL.md:22` 把问题说得很直白：

```text
**The problem**: large projects (10+ repositories, dozens of microservices, years of iteration) defeat global understanding by AI. The context window cannot hold all the code, component relations are scattered everywhere, and business rules hide deep in call chains.
```

### 1.2 learning 与 teamwiki 的对比

| 维度 | learning（经验） | teamwiki（结构知识） |
| --- | --- | --- |
| 来源 | 会话、MR 讨论，AI 提炼后人工确认 | 代码 checkout，确定性抽取（AI 叙事可选） |
| 存放 | 团队仓库 `learnings/`（及项目命名空间） | 团队仓库 `teamwiki/evidence/code/<slug>/` |
| 粒度 | 一条一个文件 | 每个代码库一组页面，外加 `.indices/graph-index.json` |
| 新鲜度 | 靠投票、置信度、prune 治理（第 7 篇） | 靠 `source-manifest.json` 的文件哈希基线 |
| 更新触发 | contribute / share | import、`--incremental`、`--from-mr`、CI |
| 典型问题 | "为什么这么做""别这样做" | "在哪、谁调谁、改了影响谁" |

两者在两个地方交汇：

1. `teamai import --from-mr` 一次运行同时产出 learning 草稿和 teamwiki 增量更新（`src/import.ts:197` 的注释"提取 learning + 增量更新 teamwiki"）。
2. recall 把两类结果合并排序，codebase 结果额外带 `Sources:` 和 `Source freshness:` 两行（`src/recall.ts:254-262`）。

互补关系可以这样记：teamwiki 告诉 AI "代码现在长什么样"，learning 告诉 AI "人们为什么这样写、哪里容易错"。前者随时可以从代码重新生成，后者一旦没记下来就丢了。

### 1.3 设计取舍（从代码里读出来的）

| 取舍 | 代码体现 |
| --- | --- |
| 抽取在临时目录里做，绝不碰源码目录 | `importCodebase` 用 `fs.mkdtemp(... 'teamai-extract-')`（`src/import-codebase.ts:88`） |
| 结构抽取是确定性的，AI 只是锦上添花 | `--skip-enrich` 跳过 AI；AI 扫描失败只告警、不阻断（`src/import-repo.ts:372-380`） |
| 每个代码库自带基线，多个仓库共用一个 teamwiki | 缓存放在 `evidence/code/<slug>/.indices/`（`src/import-codebase.ts:118-123`） |
| 结构知识也走 MR 审核，不直接推送 | `publishTeamwikiViaMR` 调用 `autoPushViaMR`（`src/import-codebase.ts:183-195`） |
| 新鲜度检查只读且保守：证明不了就标 unknown | `src/codebase-freshness.ts:1-5` 文件头："The source manifest is treated as untrusted metadata" |
| 一个 MR 失败不拖垮整批 | 多 URL 时逐个 try/catch，最后 `process.exitCode = 1`（`src/import.ts:255-261, 378`） |

---

## 2. 关键路径与数据结构

### 2.1 slug 规则：`<provider>__<owner>__<repo>`

`src/utils/repo-cache.ts:40`：

```ts
export function getRepoSlug(provider: string, owner: string, repo: string): string {
    const safeOwner = owner.replace(/\//g, '-');
    return `${provider}__${safeOwner}__${repo}`;
}
```

owner 里的 `/`（比如多级 group）会被换成 `-`，保证 slug 是一个合法的目录名。远端 URL 统一用 `repoSlugForUrl` 求 slug（`src/import-repo.ts:211-223`），注释写明这是三条路径共用的命名：

```ts
/**
 * The evidence slug of a remote repo, `<provider>__<owner>__<repo>`: what
 * `--from-repo`, `--from-mr` and `teamai ci extract-mr` all name
 * `teamwiki/evidence/code/<slug>/`, so they update the same codebase.
 */
export function repoSlugForUrl(url: string): string {
    const providerName = detectProvider(url);
    if (!providerName) throw new Error(`Unsupported repo URL: ${url}`);
    const { owner, repo } = getProvider(providerName).parseRepoInput(url);
    return getRepoSlug(providerName, owner, repo);
}
```

`--dir` 用的是另一个函数 `defaultProjectSlug(dirPath)`（`src/import.ts:385-386`，定义在 `src/codebase-extract.ts`），它的具体规则见文末"未逐行核实"。

### 2.2 文件与目录一览

| 路径 | 内容 | 谁写 / 谁读 |
| --- | --- | --- |
| `~/.teamai/cache/repos/<provider>/<owner>/<repo>` | `--from-repo` 的浅克隆缓存，含 `LAST_SYNC` | `getRepoCacheDir`（`src/utils/repo-cache.ts:29`）、`importFromRepo` |
| `teamwiki/evidence/code/<slug>/` | 该代码库的证据页面、`overview.md`、`_manifest.json`、`_domains.json` | `importCodebase` 写；recall 读 |
| `teamwiki/evidence/code/<slug>/source-manifest.json` | 该代码库的基线：`headSha`、`repoUrl`、`lastScan`、`files[{relativePath, sha256}]`、`ingestedMrs` | 抽取时写；增量与 freshness 读 |
| `teamwiki/evidence/code/<slug>/.indices/` | `graph-index.json`、`facts-cache.json`、`interfaces-cache.json` | `importCodebase` 复制进来；`seedBaseline` 读 |
| `teamwiki/source-manifest.json` | 根 manifest，只保存"最近一次"抽取的基线 | `teamai codebase --status` 读 |
| `.teamai/pending-review.jsonl` | 等待人工审核的变更 | `src/review-store.ts` |
| `~/.teamai/sessions/mr-hint-<slug>.json` | mr-hint 已经提示过的 MR id | `src/mr-hint.ts:72` 的注释 |
| `<output_dir>/graph/G1..G9_*.md`、`_review/progress.json` | wiki skill 方法论产物（由 AI agent 按 skill 写，不是 CLI 写） | `skill-data/wiki/SKILL.md:232-268` |

`importCodebase` 的文件头注释（`src/import-codebase.ts:73-85`）说明了"每个代码库自己的 manifest"和"根 manifest"各管什么：

```ts
/**
 * Extract a source checkout into `<wikiRoot>/evidence/code/<slug>/`, the one
 * code path every import source shares (`--dir`, `--from-repo`, `ci extract-mr`).
 *
 * Extraction runs in a temporary directory, never in the source checkout, so a
 * teamwiki already there is left alone. The published evidence, the per-repo
 * graph, the incremental caches and source-manifest.json land in the
 * codebase's evidence directory; the root source-manifest.json keeps the most
 * recent baseline for `teamai codebase --status`.
 */
```

### 2.3 pending-review 条目结构

`src/review-store.ts:19-31`：

```ts
export interface PendingReviewItem {
    id: string;
    ts: string;
    kind: 'codebase-section' | 'domain-drift' | 'multi-source-conflict';
    target: { file: string; section?: string };
    payload: Record<string, unknown>;
    source: string;
    risk: Risk;
}

export const PENDING_REVIEW_PATH = '.teamai/pending-review.jsonl';
```

`id` 是 `sha1(file|section|ts)` 取前 12 位（`computeReviewId`，`src/review-store.ts:54-64`）。`risk` 缺省时由 `inferRisk` 推断：章节名属于"架构""模块依赖""external-knowledge"这类高风险集合，或文件路径含 `external-knowledge`，判为 `high`，其余为 `medium`（`src/review-store.ts:34-38, 71-75`）。注意代码里从不自动产出 `low`。

---

## 3. 沿着一次调用逐函数走读

以最常见的 `teamai import --from-repo <url> --incremental` 为主线，再看 `--dir`、`--from-mr`、CI、mr-hint 这几条支线如何汇入同一个函数 `importCodebase`。

### 3.1 `importCmd`：按来源分发

`src/import.ts:84` 的 `importCmd` 是一条 if/else 链，顺序决定优先级：`--from-org` > `--from-repo` > `--from-repo-list` > `--from-iwiki` > `--from-mr` > `--dir` > `--from-claude`，都没有就打印用法（`src/import.ts:439`）。`--from-repo` 分支只做参数转换后交给 `importFromRepo`（`src/import.ts:116-133`）：

```ts
} else if (opts.fromRepo) {
  const tasks = new Listr([
    {
      title: 'Import remote repository',
      task: async (ctx, task) => {
        task.output = `Repository: ${opts.fromRepo}`;
        await importFromRepo({
          url: opts.fromRepo!,
          depth: opts.depth ? parseInt(opts.depth, 10) : 1,
          forceSsh: opts.ssh ?? false,
          explicitDomain: opts.domain,
          dryRun: opts.dryRun,
          output: opts.output,
          incremental: opts.incremental ?? false,
          skipEnrich: opts.skipEnrich ?? false,
        });
      },
      // ...
```

几个默认值值得记住：`--depth` 默认 1（浅克隆）；`--from-repo-list` 并发默认 3（`src/import.ts:151`）；`--from-org` 默认最多 200 个仓库、默认排除归档仓库（`src/import.ts:97-98`）。`--incremental` 和 `--skip-enrich` 一路透传下去。

### 3.2 `importFromRepo`：克隆缓存、快路径、AI 叙事

`src/import-repo.ts:242`。第一段决定能不能走增量（`src/import-repo.ts:262-276`）：

```ts
const cacheDir = getRepoCacheDir(providerName, owner, repoName);
const slug = getRepoSlug(providerName, owner, repoName);

const lastSync = await readLastSync(cacheDir);
const cacheExists = await fs.pathExists(path.join(cacheDir, '.git'));
const useIncremental = incremental && cacheExists && lastSync !== null;

const target = await resolveTeamwiki({ output, dryRun }).catch((error: unknown) => {
    if (!dryRun) throw error;
    return undefined;
});
const evidenceDest = target ? path.join(target.wikiRoot, 'evidence', 'code', slug) : undefined;
```

- 只有"用户要增量 + 本地缓存是 git 仓库 + 有 `LAST_SYNC`"三者同时成立，才真正走增量 fetch；否则全量浅克隆。
- 写到哪：`--output <dir>` 时是 `<dir>/teamwiki`，否则是团队仓库的 `teamwiki/`。在克隆之前就解析，团队仓库缺失时可以尽早失败。

增量模式下 fetch 失败会自动退回全量克隆，并把 `oldSha` 置空（`src/import-repo.ts:325-336`，注释 "treat as full clone on fallback, skip drift detection"）。

快路径（`src/import-repo.ts:359-367`）：

```ts
if (useIncremental && oldSha && cloneSha === oldSha && (await publishedHead()) === cloneSha) {
    log.info(`[incremental] SHA unchanged (${cloneSha.slice(0, 8)}), skipping AI scan`);
    await writeLastSync(cacheDir, cloneSha);
    // ...
    return;
}
```

跳过的条件除了"缓存 SHA 没动"，还要求"目标 teamwiki 里这个代码库的 `source-manifest.json` 的 `headSha` 也等于它"（`publishedHead`，`src/import-repo.ts:280-282`）。原因写在注释里：`LAST_SYNC` 属于共享的克隆缓存，别的 `--output` 或别的团队仓库可能已经用同一份缓存导入过，不能据此判断"这个 teamwiki 已经是最新"。

AI 叙事是可选、非阻断的（`src/import-repo.ts:372-380`）：

```ts
if (skipEnrich) {
    log.debug('AI enrichment skipped (--skip-enrich)');
} else {
    try {
        codebaseMd = await generateCodebaseMd({ repoPath: cacheDir });
    } catch (err) {
        log.warn(`AI codebase scan failed (non-blocking): ${err instanceof Error ? err.message : String(err)}`);
    }
}
```

随后在 teamwiki 锁内（`lockTeamwiki`，`src/import-repo.ts:382`）调用 `importCodebase`。如果有 AI 叙事，就写到 `overview.md` 的 `## AI Architecture Narrative` 段落，已有该段（或旧的中文标题 `## AI 架构叙事`）则替换，保证幂等（`src/import-repo.ts:394-410`）。`--domain` 会覆盖 `_domains.json` 里 AI 推断的领域（`src/import-repo.ts:412-423`）。最后（`src/import-repo.ts:431-440`）：

```ts
if (updated) {
    await reconcileAndDeepEnrich({ slug, wikiRoot: teamwikiRoot, sourceDir: cacheDir, skipEnrich });
    if (!skipAutoPush) {
        await refreshTeamwikiIndexes(teamwikiRoot);
        if (team) await publishTeamwikiViaMR(team, `[teamai] Import codebase knowledge from ${owner}/${repoName}`);
    }
}
```

注释写明 reconcile 和 deep enrich "synchronous, before push — so all content goes into one MR"。`skipAutoPush` 是给批量模式和 `--from-mr` 用的：它们自己在最后统一刷新索引、统一开 MR。

### 3.3 `importCodebase` + `seedBaseline`：所有来源的共同出口

`src/import-codebase.ts:86`。不管是 `--dir`、`--from-repo` 还是 CI，最后都调它：

```ts
export async function importCodebase(opts: ImportCodebaseOptions): Promise<boolean> {
  const { sourceDir, slug, wikiRoot } = opts;
  const staging = await fs.mkdtemp(path.join(os.tmpdir(), 'teamai-extract-'));
  try {
    const stagingWiki = path.join(staging, 'teamwiki');
    const seeded = opts.incremental ? await seedBaseline(wikiRoot, stagingWiki, slug) : false;
    if (opts.incremental && !seeded) log.debug(`[import] ${slug}: no published baseline, running a full extraction`);
    const wrote = await extractCodebase({
      path: sourceDir,
      project: slug,
      outputRoot: staging,
      json: false,
      incremental: seeded,
      // ...
    });
    if (!wrote) return false;
    // ...
```

分三步理解：

1. 建一个临时 staging 目录。抽取器只往 staging 写，源码目录和已发布的 teamwiki 都不会被半成品污染。
2. 要增量时，先用 `seedBaseline` 把"上次发布的基线"复制进 staging；复制成功才真的以增量模式跑 `extractCodebase`（`incremental: seeded`），否则静默退回全量。
3. `extractCodebase` 返回 false（源码没变或为空）就直接返回，已发布的证据原样保留。

`seedBaseline` 找基线的顺序（`src/import-codebase.ts:37-71`）：

```ts
const sidecarJson = await readManifest(sidecar);
if (sidecarJson && await fs.pathExists(path.join(ownIndices, INCREMENTAL_CACHES[0]))) {
  manifest = sidecar;
  indices = ownIndices;
} else {
  const rootJson = await readManifest(rootManifest);
  if (rootJson?.project === slug && (!sidecarJson || sidecarJson.headSha === rootJson.headSha)) {
    manifest = rootManifest;
    indices = path.join(wikiRoot, '.indices');
  }
}
```

优先用代码库自己目录下的 `source-manifest.json` + `.indices/facts-cache.json`；只有旧版 teamwiki（缓存只放在共享的 `teamwiki/.indices/`）才回退到根 manifest，而且要求根 manifest 的 `project` 正好是这个 slug。注释说明了原因：共享缓存"describe whichever codebase was extracted last"，用错了会拿别的仓库当基线。另外 `dependency-paths.md` 故意不复制，因为它的调用链可能还引用已被删除的符号（`src/import-codebase.ts:68-69`）。

发布阶段（`src/import-codebase.ts:107-127`）：

```ts
if (await fs.pathExists(evidenceDest)) {
  for (const entry of await fs.readdir(evidenceDest)) {
    if (entry !== '.indices') await fs.remove(path.join(evidenceDest, entry));
  }
}
await fs.ensureDir(evidenceDest);
await fs.copy(stagingEvidence, evidenceDest, { overwrite: true });

const destIndices = path.join(evidenceDest, '.indices');
await fs.ensureDir(destIndices);
for (const file of ['graph-index.json', ...INCREMENTAL_CACHES]) {
  // ... copy from stagingWiki/.indices
}
// ... stagingManifest -> <wikiRoot>/source-manifest.json
```

先删旧页面（保留 `.indices`）再整体复制，这样被删掉的模块不会留下孤儿页面；再把单仓图谱和两份增量缓存放进 `.indices/`；最后用本次 manifest 覆盖根 manifest，供 `--status` 显示。

`importCodebase` 之后通常紧跟两个非阻断步骤：

- `reconcileAndDeepEnrich`（`src/import-codebase.ts:138-164`）：先 `reconcileKnowledge` 把 `teamwiki/product/` 的产品文档与代码知识对齐，再在存在 `_manifest.json` 且没 `--skip-enrich` 时跑 `deepEnrich`。两者失败都只记 debug 日志。
- `refreshTeamwikiIndexes`（`src/import-codebase.ts:167-180`）：`aggregateGlobalGraph` 聚合全局图谱，`rebuildWikiIndex` 重建 `router.md` / `index.md`。

### 3.4 `--dir`：跳过 clone 的同一条路

`src/import.ts:379-418`：

```ts
} else if (opts.dir) {
  const dirPath = path.resolve(opts.dir);
  // ... Directory not found
  const { defaultProjectSlug } = await import('./codebase-extract.js');
  const slug = await defaultProjectSlug(dirPath);
  // ... dry-run 直接返回，不做任何抽取
  const { lockTeamwiki, resolveTeamwiki } = await import('./utils/teamwiki-root.js');
  const target = await resolveTeamwiki({ output: opts.output });
  const { wikiRoot, team } = target;
  const releaseImportLock = await lockTeamwiki(target);
  try {
    const { importLocalCheckout } = await import('./import-codebase.js');
    const updated = await importLocalCheckout({
      sourceDir: dirPath, slug, wikiRoot,
      incremental: opts.incremental ?? false,
      skipEnrich: opts.skipEnrich ?? false,
    });
    if (!team) {
      log.info(`Output written: ${wikiRoot}`);
    } else if (updated) {
      await autoPushTeamRepo(team.localConfig.repo.localPath, `[teamai] Import from local dir: ${slug}`);
      // ...
```

`importLocalCheckout`（`src/import-codebase.ts:203-215`）= `importCodebase` + `reconcileAndDeepEnrich` + `refreshTeamwikiIndexes`。注意两个差异：`--dir` 的发布用 `autoPushTeamRepo`，而 `--from-repo` 用 `publishTeamwikiViaMR`（开 MR）；`--dir` 的 `--dry-run` 什么都不抽，`--from-repo` 的 dry-run 会用 `git ls-remote` 查远端 HEAD 并报告缓存是否最新（`src/import-repo.ts:286-306`）。wiki skill 的 Phase 0 正是用 `teamai import --dir <repo> --skip-enrich` 建结构基线（`skill-data/wiki/SKILL.md:306`）。

### 3.5 `--from-mr`：一个 MR，两种知识

`src/import.ts:196-378`。分两个阶段：

阶段一在 Listr 任务列表之外逐个 URL 调 `importFromMR`，这样交互式的 "Accept learning?" 提示能正常显示（注释 #823：在 listr2 里 stdout 会被扣住，看起来像卡死）。草稿写进贡献队列（`savePendingLearning`），多个 URL 时文件名为 `learning-<n>.md`，避免互相覆盖（`src/import.ts:245`）。

阶段二是三个任务：

1. Publish learning：一次 `publishQueuedLearnings` 排空队列，然后重建 recall 索引（发布流程见 [04-contribute-publish.md](04-contribute-publish.md)）。
2. Incremental teamwiki update：按仓库分组，每个仓库只更新一次（`src/import.ts:307-332`）：

```ts
for (const [repoUrl, sourceMrUrls] of mrUrlsByRepo) {
  try {
    const slug = repoSlugForUrl(repoUrl);
    const evidenceDir = path.join(teamwikiRoot, 'evidence', 'code', slug);
    if (!(await fs.pathExists(evidenceDir))) {
      skipped.push(`No existing evidence for ${slug}`);
      continue;
    }
    task.output = `Updating ${slug}...`;
    await importFromRepo({
      url: repoUrl,
      incremental: true,
      skipAutoPush: true,
      sourceMrUrl: sourceMrUrls,
    });
    ctx.didUpdate = true;
  } catch (e) {
    skipped.push(`Incremental update skipped: ${(e as Error).message}`);
  }
}
```

关键点：只有已经 import 过（存在 `evidence/code/<slug>/`）的仓库才会被增量更新，`--from-mr` 不会替你做首次全量导入。`sourceMrUrl` 会作为来源记录到 `source-manifest.json` 的 `ingestedMrs`，`teamai codebase --status` 能看到。
3. Push changes via MR：只推 teamwiki 的改动（learning 已在第 1 步发布），`ctx.didUpdate` 为假时跳过。

`--dry-run` 和 `--output` 时 Publish 与 teamwiki 更新都跳过；只读（HTTP）团队源会被 `assertNotReadOnly` 拒绝（`src/import.ts:207`）。

### 3.6 `teamai ci extract-mr`：在 CI 里自动跑

`src/ci/extract-mr.ts:233` 的 `ciExtractMr`，`mode` 取 `comment | write | both`：

- 先调用 `importFromMR({ all: true, dryRun: true })` 只拿 learning 草稿，不让它自己写文件（`src/ci/extract-mr.ts:242-248`）。
- comment 模式：`postOrUpdateMrComment` 幂等地发布或更新一条 MR 评论（或 `--individual-comments` 逐条发）。
- 图谱预览：用 `git diff --name-only HEAD~1 HEAD` 等三种方式依次尝试拿变更文件（兼容 depth=1 的浅克隆），过滤出源码后缀，再 `collectCode → extractCodeFacts → buildCodeGraph`，把新增节点贴成一条图谱评论（`src/ci/extract-mr.ts:288-333`）。
- write 模式（必须 `--team-repo`，否则抛错 `write 模式需要 --team-repo 参数`）：learning 直接写进 `<team-repo>/learnings/<日期>-<标题>.md`；teamwiki 走 `importMergedCheckout`，即把当前工作目录当 `--dir . --incremental` 导入（`src/ci/extract-mr.ts:177-201`）：

```ts
const relative = path.relative(sourceDir, teamRepoDir);
if (!relative || (!relative.startsWith('..') && !path.isAbsolute(relative))) {
  log.warn(`Skipped the teamwiki update: the team repo (${teamRepoDir}) is inside the source checkout `
    + `(${sourceDir}), so its files would be extracted as source. Clone it outside the checkout (see examples/ci/).`);
  return false;
}
// ...
return await importLocalCheckout({
  sourceDir,
  slug: repoSlugForUrl(repoUrl),
  wikiRoot: path.join(teamRepoDir, 'teamwiki'),
  incremental: true,
  repoUrl,
  sourceMrUrl: mrUrl,
});
```

注意 CI 写入用的是 `pushRepoDirectly`（直推团队仓库，`src/ci/extract-mr.ts:156`），这和本地 `--from-mr` 开 MR 不同。写入 teamwiki 的条件是"有源码文件变更"，而不是"有新增图谱节点"，所以只删文件的 MR 也会把旧页面清掉（`src/ci/extract-mr.ts:357-361` 的注释）。

`writeKnowledgeToRepo` 里保留了 `pending-review` 写 `docs/codebase.md` 段落建议的分支，但 `ciExtractMr` 调它时 `suggestions` 恒传 `undefined`（`src/ci/extract-mr.ts:377-385`），文件头也注明 "applyCodebaseSuggestions removed"。也就是说，当前 CI 路径实际不再往 pending-review.jsonl 写东西。

### 3.7 mr-hint：在会话开始时提醒"有 MR 还没提炼"

注册在 `src/hook-handlers.ts:1139`：`session-start` 事件、前台、`gitOnly: true`、`requiresConfig: true`。handler 本体只是转调（`src/hook-handlers.ts:867-873`）：

```ts
const mrHintHandler: HookHandler = {
  name: 'mr-hint',
  async execute(_stdin, _tool, config) {
    const { computeMrHintOutput } = await import('./mr-hint.js');
    return computeMrHintOutput(await teamAgentLanguage(config), config);
  },
};
```

`computeMrHintOutput`（`src/mr-hint.ts:454-520`）：环境变量 `TEAMAI_MR_HINT_DISABLED=1` 或作用域配置关掉开关时返回 null；读 `origin` remote 解析出 tgit/github 仓库；查最近 7 天（`LOOKBACK_DAYS = 7`）合入的 MR；用 `~/.teamai/sessions/mr-hint-<slug>.json` 过滤已提示过的 id（缓存 TTL 30 天）；有新的就输出 `SessionStart` 的 `additionalContext`，里面是一条合并命令 `teamai import --from-mr <url1> <url2> ...`（`buildHintMessage`，`src/mr-hint.ts:369-410`）。所以 mr-hint 只是"提醒 AI 告诉用户"，本身不导入任何东西。hook 调度机制见 [01-hook-layer.md](01-hook-layer.md)。

### 3.8 `teamai codebase`：查看与加工已导入的 teamwiki

`src/codebase-cmd.ts:43` 的 `codebaseCmd` 按开关分发，不带开关时只打印用法。teamwiki 位置同样由 `resolveTeamwiki` 决定（`--output` 或团队仓库），只读操作带 `dryRun: true`，避免顺手写入配置迁移（注释 #893，`src/codebase-cmd.ts:30-38`）。

| 开关 | 做什么 | 退出码 |
| --- | --- | --- |
| `--status` | 读 `teamwiki/source-manifest.json`，打印 `headSha`、`repoUrl`、`branch`、`lastScan`、文件数、`ingestedMrs`（`printCodebaseStatus`，`src/codebase-cmd.ts:181-235`） | 没有 teamwiki 或 manifest 时为 1 |
| `--deep-enrich --project <slug>` | 校验 slug 不越出 `evidence/code/`（`assertWithinRoot`），要求 `_manifest.json` 里至少有一个 component，然后调 `deepEnrich` | 缺 `--project`、无证据、无组件、生成不完整时为 1 |
| `--reconcile` | `reconcileKnowledge({ wikiRoot, dryRun })`，打印 mappings / gaps / conflicts | 无 teamwiki 时为 1 |
| `--lint [--severity] [--json]` | `lintTeamwiki` 一致性检查；`--fix` 只提示"no autofix" | 有 high 级问题时为 1 |

`--status` 读的是根 manifest，所以多仓 teamwiki 里它只反映"最近一次导入的那个仓库"，这一点和 2.2 节的注释一致。`--deep-enrich` 的路径防护（`src/codebase-cmd.ts:89-98`）：

```ts
const { assertWithinRoot } = await import('./utils/path-safety.js');
const codeRoot = path.join(teamwikiDir, 'evidence', 'code');
const evidenceDir = path.join(codeRoot, project);
try {
    assertWithinRoot(codeRoot, evidenceDir);
} catch (e) {
    console.log((e as Error).message);
    process.exitCode = 1;
    return;
}
```

### 3.9 `teamai review`：pending-review 的人工闸门

存储层 `src/review-store.ts` 只有四个核心 API：`loadPendingReview`（读全量；文件不存在返回 `[]`；超过 10 MB 抛错；坏行跳过；旧格式 `type/file/section/content` 归一化为新 schema）、`savePendingReview`（先写 `.tmp` 再 `rename`，原子覆盖）、`appendPendingReview`（只追加一行，自动补 id/ts/risk）、`removePendingReview`（按 id 删）。

命令层 `src/review-cmd.ts:164` 的 `reviewCmd` 支持 list / show / `--apply` / `--reject` / `--all-apply`。真正落盘的 `applyOne`（`src/review-cmd.ts:123-158`）只接受 `codebase-section`：

```ts
if (item.kind !== 'codebase-section') {
    return { ok: false, reason: `kind ${item.kind} does not support auto-apply; please handle manually` };
}
// ... section 缺失、目标文件不存在、payload.content 为空都会拒绝
const newMd = patchManagedSection(oldMd, section, body, {
    source: item.source,
    syncedAt: new Date().toISOString(),
});
if (!dryRun) await fs.writeFile(filePath, newMd, 'utf8');
```

`--all-apply` 默认 `maxRisk = 'medium'`，只批量应用风险不高于 medium 的 `codebase-section`，high 风险和其他 kind 都被跳过，留给人逐条看（`src/review-cmd.ts:164-178`）。应用成功且非 dry-run 才从 jsonl 删除该条。

谁会往队列里写？当前读到的写入方是 `--from-iwiki --iwiki-dual --require-review`（`src/import.ts:180-187`，`requireReview` 传给 `importFromIWikiDual`）。CI 的那条路径见 3.6 节，实际已不写入。

### 3.10 recall 里的 Source freshness

recall 合并 learning 与 codebase 结果、取前 5 条之后，才对可见的 codebase 结果做哈希校验（`src/recall.ts:778-788`）：

```ts
const topResults = allResults.slice(0, 5);
// Hash only codebase sources that will be shown. This stays after the
// --check early return so the relevance precheck remains filesystem-cheap.
await annotateCodebaseSourceFreshness(topResults, wikiRoot).catch(() => {
  for (const result of topResults) {
    if (result.fromCodebase && result.sources) {
      result.sources = result.sources.map((source) => ({ ...source, freshness: 'unknown' }));
    }
  }
});
```

放在 `--check` 提前返回之后、并且只算前 5 条，是为了让"要不要召回"的预检保持便宜。输出时每条 codebase 结果多一行（`src/recall.ts:256-261`）：`Source freshness: src/foo.ts=current (last scan: ...)`。

`annotateCodebaseSourceFreshness`（`src/codebase-freshness.ts:293-330`）对每个来源锚点的判断过程：

1. 从页面路径 `evidence/code/<slug>/...` 取出 slug（`codebaseSlug`）。
2. `baselineForPage` 找基线：优先该代码库目录下的 `source-manifest.json`；它损坏或越界时直接放弃，不会被根 manifest 掩盖；只有它缺失、且 teamwiki 里恰好只有一个代码库时，才回退到根 manifest。
3. `currentCheckout` 读当前目录的 git 顶层与所有 remote。manifest 的 `repoIdentity`（或由 `repoUrl` 推出）必须出现在这些 remote 里，否则 `unknown`，防止拿别的仓库的基线比对。
4. `checkOneSource`：路径不能含 `..`、不能是绝对路径、不能被忽略、必须是代码文件；按 manifest 的 `sourceSubdir` 定位源码根；用 realpath 防止符号链接逃出仓库；最后按 UTF-8 解码内容求 SHA256，与基线比较。

结果四态（`src/codebase-freshness.ts:15`）：

| 值 | 含义 |
| --- | --- |
| `current` | 当前文件内容哈希等于扫描基线（与 HEAD 是否变化无关） |
| `stale` | 文件存在但内容变了，包括未提交的本地修改 |
| `missing` | 基线里有这个文件，当前仓库里"安全地确认"它不存在了 |
| `unknown` | 任何无法证明的情况：仓库不匹配、基线缺失、路径可疑、符号链接越界等 |

wiki skill 对此的使用约定（`skill-data/wiki/SKILL.md:26`）：`current` 只表示被引用的文件与扫描基线一致；标为 `stale`、`missing`、`unknown` 的结论，使用前要先看当前源码。

### 3.11 wiki skill：CLI 之上的"深度知识库"方法论

CLI 只负责确定性的结构基线；更深的架构文档由 AI agent 按 `skill-data/wiki/SKILL.md` 的流程写。阶段与人工确认点（`skill-data/wiki/SKILL.md:69-83, 197-208, 216-222`）：

| 阶段 | 做什么 | 人工确认 |
| --- | --- | --- |
| Phase 0 | `teamai import --dir <repo> --skip-enrich` 建结构基线、列仓库清单 | 无 |
| K1 | 架构逆向，产出 `_review/k1-architecture-map.md` | 确认点 ①（状态 `phasek1_waiting_confirm`） |
| K2 | 子 agent `kb-doc-generator` 分批并行生成组件文档，每批写 `progress.json` | 确认点 ②（`phasek2_waiting_confirm`） |
| K3 | 子 agent `graph-rag-agent` 生成 `graph/G1..G9`，并做跨文档一致性检查 | 无 |
| K4 | 跑 `scripts/validate_kb.py` 与 `teamai codebase --lint`，产出质量报告 | 无 |

G1-G9 九份图谱文档（`skill-data/wiki/SKILL.md:250-258`）：G1 组件依赖矩阵、G2 组件调用链总览、G3 数据流与存储依赖、G4 错误码组件映射、G5 跨组件交互场景、G6 知识图谱三元组、G7 架构风险与影响分析、G8 核心配置参数索引、G9 业务规则约束矩阵。

两条硬规则值得记住：每个结论都要引用 `文件:行号`，查不到就标 `[UNVERIFIED]`；每条关系必须标 `EXTRACTED(1.0)` / `INFERRED` / `AMBIGUOUS(0.1~0.3)`，禁止 0.5 这种默认值（`skill-data/wiki/SKILL.md:199-201, 294`）。`validate_kb.py` 文件头列出它检查的 5 项：死链、search-anchor 覆盖、AI Quick Reference 表覆盖、双向链接完整性、README 索引覆盖（`skill-data/wiki/scripts/validate_kb.py:5-10`）。

---

## 4. 端到端流程图

```text
         代码来源                                     触发方式
  本地目录 / 远端仓库 / 仓库清单 / 组织          人手动 | mr-hint 提醒 | CI
          │                                              │
          ▼                                              ▼
  importCmd (src/import.ts:84)  ── --from-mr ──> importFromMR ─> learning 草稿 ─> 贡献队列 ─> publish（第 4 篇）
    │ --dir               │ --from-repo / -list / -org         │
    │                     ▼                                    │ 仓库已有 evidence 才继续
    │        importFromRepo (src/import-repo.ts:242)  <────────┘ incremental + skipAutoPush
    │          ① ~/.teamai/cache/repos/... 浅克隆或 fetch
    │          ② SHA 未变且 teamwiki headSha 相同 → 直接返回
    │          ③ 可选 AI 叙事（--skip-enrich 跳过，失败不阻断）
    ▼                     ▼
  importCodebase (src/import-codebase.ts:86)      <── ciExtractMr write 模式（--dir . --incremental）
    ① mkdtemp staging   ② seedBaseline（--incremental）
    ③ extractCodebase   ④ 无变化 → return false
    ⑤ 替换 teamwiki/evidence/code/<slug>/ + .indices/ + 根 source-manifest.json
          │
          ▼
  reconcileAndDeepEnrich → refreshTeamwikiIndexes（全局图谱 + router/index）
          │
          ▼
  发布：--from-repo 开 MR | --dir autoPushTeamRepo | CI pushRepoDirectly
          │
          ▼  teamai pull 同步到每个成员（第 5 篇）
  teamai recall → 合并 learning 与 codebase 结果 → 取前 5
          │
          ▼
  annotateCodebaseSourceFreshness：manifest 基线 vs 当前 checkout 的 SHA256
          │
          ▼
  输出 Sources: ... / Source freshness: path=current|stale|missing|unknown
```

---

## 5. 常见坑与边界情况

| 现象 | 原因（代码 / 测试依据） |
| --- | --- |
| `--from-mr` 跑完 teamwiki 没变化 | 该仓库从没 import 过，`No existing evidence for <slug>` 被跳过（`src/import.ts:317-320`）；先跑一次 `--from-repo` |
| `--incremental` 还是全量 | 本地缓存不是 git 仓库、没有 `LAST_SYNC`，或 teamwiki 里找不到这个 slug 的基线（`src/import-repo.ts:267`，`src/import-codebase.ts:92`） |
| 增量跑完页面"消失" | 不会：无变化时 `importCodebase` 返回 false，不动已发布证据。测试 `import-codebase.test.ts` 的 "never drops published pages on an incremental run that changes no source file" |
| 多仓共用 teamwiki 时增量拿错基线 | 已修复：优先用代码库自己的 `.indices`。测试 "extracts incrementally from the codebase's own baseline after another repo was imported into the same teamwiki" |
| CI 里 teamwiki 没更新 | 团队仓库 clone 在业务仓库目录内部，被主动跳过（`src/ci/extract-mr.ts:180-185`）。测试 `ci-extract-mr.test.ts` 的 "skips the teamwiki update when the team repo is cloned inside the checkout" |
| 只删文件的 MR | 仍会更新 teamwiki，清掉旧页面。测试 "updates the teamwiki for a merge that only deletes a source file" |
| freshness 一直是 unknown | 当前目录不是同一仓库（remote 不匹配，含 host 和端口）、基线不可读或旧 manifest 缺少 `sourceSubdir`。见 `codebase-freshness.test.ts` 的 "returns unknown when the manifest belongs to another repository"、"requires the same host and port even when repository paths match"、"leaves legacy metadata without source-root provenance unknown" |
| 本地改了没提交，显示 stale | 比较的是文件内容不是 HEAD。测试 "marks uncommitted source edits stale by comparing file content, independent of HEAD" |
| `--status` 只显示一个仓库 | 读的是根 manifest，只记录最近一次导入（`src/import-codebase.ts:80-81` 注释） |
| `teamai review --all-apply` 有条目没应用 | 默认只到 medium；high 风险和非 `codebase-section` 被跳过（`src/review-cmd.ts:170-176`） |

---

## 6. 动手验证

只读命令（在已 `teamai init` 的项目里执行）：

```bash
teamai codebase --status                 # 看 teamwiki 基线：headSha、lastScan、ingestedMrs
teamai codebase --status --json
teamai codebase --lint --severity high   # 只读一致性检查
teamai --dry-run import --from-repo <url> --incremental   # 只查远端 HEAD，报告缓存是否最新
teamai review                            # 列出 pending-review 条目（不加开关只读）
ls teamwiki/evidence/code/               # 每个目录名就是 <provider>__<owner>__<repo>
cat teamwiki/evidence/code/<slug>/source-manifest.json | head -40
```

相关测试（可 `npx vitest run <文件>` 运行）：

- `src/__tests__/import-codebase.test.ts`："writes nothing into the source checkout and leaves a teamwiki already there alone"
- `src/__tests__/import-repo-incremental.test.ts`："缓存不存在时走全量 clone，不调 shallowFetch"
- `src/__tests__/ci-extract-mr.test.ts`："imports the checkout incrementally under the slug import --from-repo uses, then pushes teamwiki/"、"write 模式需要 --team-repo 参数"
- `src/__tests__/codebase-freshness.test.ts`："marks a source missing only when the path is safely absent in the matching repository"、"returns unknown for source symlinks that escape the repository"
- `src/__tests__/review-store.test.ts`："旧 schema 条目（type/file/section/content）能被归一化"、"savePendingReview 原子性：rename 失败时不留 .tmp 残留"
- `src/__tests__/mr-hint.test.ts`、`src/__tests__/mr-hint-toggle.test.ts`（具体用例名未逐条核对）

---

## 7. 自测问题

<details>
<summary>1. learning 和 teamwiki 各自回答什么问题？为什么不能只要一个？</summary>

teamwiki 回答"代码现在长什么样、谁依赖谁"，可以从代码重新生成；learning 回答"为什么这样、哪里容易踩坑"，来自人的经验，代码里没有。两者在 recall 中合并排序。
</details>

<details>
<summary>2. `github.com/a/b/c` 这种多级 owner 的 slug 长什么样？</summary>

`getRepoSlug` 把 owner 中的 `/` 换成 `-`，得到 `<provider>__a-b__c`。
</details>

<details>
<summary>3. 增量快路径为什么要同时检查 LAST_SYNC 和 teamwiki 里的 headSha？</summary>

`LAST_SYNC` 属于共享克隆缓存，可能是别的 `--output` 或别的团队仓库导入时写的；只有目标 teamwiki 的 `source-manifest.json` 也记录了同一 commit，才能确定这个 teamwiki 已是最新。
</details>

<details>
<summary>4. recall 显示 `src/a.ts=stale`，AI 应该怎么做？</summary>

说明文件内容已与扫描基线不同（可能是未提交改动）。按 wiki skill 约定，依赖该结论前先读当前源码；要刷新知识库就跑 `teamai import --dir <repo> --incremental`。
</details>

<details>
<summary>5. mr-hint 会自动导入 MR 吗？</summary>

不会。它在 SessionStart 输出一段 `additionalContext`，让 AI 提醒用户运行 `teamai import --from-mr <url...>`，并把已提示的 MR id 缓存起来避免重复。
</details>

---

## 8. 导航

- 上一步：[07-feedback-governance.md](07-feedback-governance.md)（learning 的反馈与治理）
- 下一步：[README.md](README.md)（系列索引）

---

## 9. 未逐行核实

以下内容只读到入口、注释或文件名，未逐行确认，使用前请自行核对：

- `defaultProjectSlug`（`src/codebase-extract.ts`）的 `--dir` slug 计算规则，以及 `extractCodebase` 内部的抽取步骤、`_manifest.json` / `_domains.json` / `overview.md` 的具体字段。
- `src/wiki-engine/` 下 `code-collector`、`code-extractors`、`code-graph`、`code-incremental`、`ast/`、`interface-scanner`、`call-chain-tracer`、`knowledge-reconciler` 的具体算法；只确认了 `adapters/index.ts` 的导出列表与 `code-incremental.ts` 的导出函数名。
- `deepEnrich`（`src/deep-enrich.js`）、`aggregateGlobalGraph`、`rebuildWikiIndex`、`lintTeamwiki`（`src/codebase-wiki-lint.ts`）、`patchManagedSection` 的实现。
- `importFromMR`（`src/import-mr.ts`）如何从 MR 提炼 learning、如何解析出 `repoUrl`；`importFromRepoList`、`importFromOrg` 的批处理细节（并发、失败汇总、统一开 MR）。
- `resolveTeamwiki` / `lockTeamwiki`（`src/utils/teamwiki-root.ts`）的锁实现；`autoPushTeamRepo`、`autoPushViaMR`、`pushRepoDirectly` 的 git 细节。
- recall 中 codebase 结果的打分方式（BM25 + 图谱扩展、阈值 `CODEBASE_RELEVANCE_THRESHOLD`、`--depth`）只来自总览笔记，未在本篇核对，参见 [06-recall-search.md](06-recall-search.md)。
- `listTGitMergedMRs` / `listGitHubMergedMRs` 的 API 调用细节；`isMrHintEnabled` 的开关解析。
- `importFromIWikiDual` 写入 pending-review 的具体条目格式。
- `skill-data/wiki/references/` 下各 phase、methodology、agents 文件只看了目录名，K1-K4 的细节以 `SKILL.md` 为准；`validate_kb.py` 只读了文件头。
