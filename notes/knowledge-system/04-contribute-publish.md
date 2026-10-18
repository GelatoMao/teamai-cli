# 第 4 步：teamai contribute 背后发生了什么（入库与发布）

> 面向小白。先讲"为什么要这样设计"，再沿着一次真实的 `teamai contribute --file x.md` 调用逐函数看代码。
> 基于 `main@fe3b906` 源码（2026-10-17）整理，代码标注 `文件:行号`；行号会随代码变动，以函数名为准。为便于阅读删了部分注释，用 `// ...` 省略无关分支。
> 前置阅读：[03-share-skill.md](./03-share-skill.md)（agent 怎么写出这份 Markdown）。本文讲 Markdown 写好之后，它怎么进入团队知识库。

---

## 0. 一句话 + 一个类比

一句话：`teamai contribute` 先把文档写进本机一个 git 不会动到的持久队列（pending-learnings），马上重建本地检索索引，然后尝试把整个队列提交并推送到团队仓库的 `teamai-learnings` 孤儿分支。只有确认远端已经收到，才把对应条目从队列删掉；推不上去就留在队列里，等下一次 `teamai pull` 再推。

类比：快递驿站。

- 你把包裹交给驿站（写入队列），驿站当场登记（建索引），你自己马上就能查到这件包裹
- 快递员来了就装车发走（commit + push 到 `teamai-learnings`）
- 收到"已签收"回执（push 被远端接受）后，才把包裹从货架上撤下
- 快递员没来、路不通（离线、没权限、锁被占）时，包裹一直留在货架上，下一趟（下一次 `pull`）接着发

---

## 1. 为什么要这样设计

### 1.1 三个硬约束

| 约束 | 出处 | 带来的设计 |
| --- | --- | --- |
| 贡献不能依赖网络、推送权限，也不能依赖某次 git 操作当场成功 | `src/utils/pending-learnings.ts:12-15` 文件头注释 | 先写本地持久队列，再发布 |
| 成员可能没有 `main` 的写权限（受保护分支） | `src/utils/learnings-branch.ts:4-5`（#485） | learnings 不进默认分支，进独立的孤儿分支 `teamai-learnings` |
| 队列条目只能在确认到达 origin 之后删除 | `src/utils/learnings-publish.ts:6-7`、`pending-learnings.ts:262-265` | 发布结果用多状态的 `PublishResult` 表示，只有 `published` / `already-present` 才出队 |

`src/contribute.ts:138-146` 的注释把总原则写得很直白：

```ts
/**
 * The contribution is written to the durable queue first and published from
 * there. Nothing about it depends on the network, on push rights, or on a git
 * operation succeeding right now: what cannot be published stays queued and the
 * next `teamai pull` publishes it, once any checkout refusal that stopped it is
 * dealt with.
 */
```

### 1.2 设计取舍

| 选择 | 得到 | 付出 |
| --- | --- | --- |
| 队列放在 clone 之外 | clone 分叉时 `pullRepo` 执行的 `reset --hard` 碰不到它（`pending-learnings.ts:18-19`） | 多一个要管理的目录；切换安装时还得把旧队列挪开（`setAsideQueueOnModeSwitch`） |
| 孤儿分支 + worktree | 不碰默认分支，也不碰用户当前的工作区（`learnings-publish.ts:511-514`） | 要处理 worktree 的创建、损坏、"属于别的仓库的 checkout"等边界 |
| 不走 PR，直接 push | 没有审核延迟，知识马上共享 | 质量靠事后的投票和淘汰来治理（见第 7 篇） |
| 发布永不抛错 | 发布失败不会让 contribute 命令失败（`learnings-publish.ts:150-151`） | 用户只能从提示文案里得知"仅保存在本地" |
| 入队即算"已贡献" | 同一会话不会被反复提示，也不会产生重复副本 | 发布失败也已标记，仍在队列这件事只能靠 `pull`/`doctor` 告知（`contribute.ts:272-275`） |

---

## 2. 关键路径与存储位置

常量见 `src/types.ts:2746-2773`：

```ts
export const LEARNINGS_BRANCH = 'teamai-learnings';
export const LEARNINGS_WORKTREE_DIRNAME = 'learnings-wt';
// ...
export const LEARNINGS_LOCK_FILENAME = '.learnings-lock';
// ...
export const SYNC_LOCK_FILENAME = '.sync-lock';
```

worktree 放在哪由 `getWorktreeDir` 决定（`src/types.ts:2850-2858`）：

```ts
export function getWorktreeDir(localConfig: LocalConfig, dirname: string): string {
  if (!usesBranchWorktree(localConfig)) {
    return localConfig.repo.localPath;
  }
  if (isSelfMode(localConfig)) {
    return path.join(getDataHome(localConfig), dirname);
  }
  return path.join(path.dirname(localConfig.repo.localPath), dirname);
}
```

而 `usesBranchWorktree`（`src/types.ts:2737-2739`）只有一句 `return localConfig.repo.kind !== 'http';`。

汇总成表（以独立 clone `~/.teamai/team-repo` 为例）：

| 东西 | git 模式（独立 clone） | self 模式（单仓） | http 模式 | 代码 |
| --- | --- | --- | --- | --- |
| 持久队列 | `~/.teamai/pending-learnings/` | `<dataHome>/pending-learnings/` | contribute 走不到（见 3.2） | `pendingLearningsDir`，`pending-learnings.ts:26` |
| learnings worktree | `~/.teamai/learnings-wt/` | `<dataHome>/learnings-wt/` | 就是 `repo.localPath` | `getWorktreeDir`，`types.ts:2850` |
| 写根 | `<worktree>/learnings/` | 同左 | `<localPath>/learnings/` | `writeRoot`，`learnings-roots.ts:68` |
| 队列锁 | `~/.teamai/locks/queue-<sha256 前 16 位>.lock` | 同左 | — | `queueLockPath`，`pending-learnings.ts:42` |
| 分支锁 | worktree 同级目录下的 `.learnings-lock` | 同左 | — | `lockFilePath`，`branch-worktree.ts:103` |
| 同步锁 | `<dataHome>/.sync-lock` | 同左 | — | `syncLockPath`，`learnings-publish.ts:168` |
| 会话贡献状态 | `~/.teamai/sessions/<sessionId>.json` | 同左 | — | `contribute-check.ts:120` 注释 |

队列放在 clone 的"旁边"而不是里面，是故意的（`pending-learnings.ts:17-24`）：

```ts
 * It lives outside anything git rewrites:
 *  - git: beside the clone, where pullRepo's diverged `reset --hard` on the
 *    clone cannot reach it.
 *  - self: in the data home, outside the user's own product repo, where an
 *    untracked directory would show up in `git status` and be swept into a
 *    commit by `git add -A`. Not in the checkout's `.teamai/`: every checkout
 *    shares the queue, and a removed worktree takes its ignored files with it
 *    (#808).
```

一次贡献最终落在远端 `teamai-learnings` 分支的 `learnings/[<namespace>/]<slug>-<YYYY-MM-DD>-<6 位随机>.md`。

---

## 3. 沿着一次调用走读：`contribute()`

入口是 `src/contribute.ts:147` 的 `contribute(options)`。文件里自带一张数据流草图（`contribute.ts:90-103`）：

```ts
//  User/Agent runs: teamai contribute --file <path> [--title <title>]
//      │
//      ├─ requireInit() → localConfig + username
//      ├─ readFile(path) → validate non-empty
//      ├─ generateFilename(title) → <title-slug>-<date>-<random>.md
//      ├─ savePendingLearning() → the durable queue, outside anything git rewrites
//      ├─ rebuildIndexAfterContribute() → recallable now, online or not
//      ├─ publishQueuedLearnings() → the one place that knows the destination
//      │   ├── confirmed on origin → drop the queue entry, markContributed()
//      │   └── not confirmed → keep it queued, retried by the next pull
//      └─ done
```

注意：草图把 `markContributed()` 画在"确认到达 origin"分支下，但实际代码不管发布结果如何都会调用它（见 3.9）。以代码为准。

### 3.1 读文件、做最基本的校验

`src/contribute.ts:151-167`：

```ts
  if (!options.file) {
    log.error('Usage: teamai contribute --file <path> [--title <title>] [--namespace <ns>]');
    return;
  }

  let content: string;
  try {
    content = await fs.promises.readFile(options.file, 'utf-8');
  } catch (e) {
    log.error(`Cannot read file: ${options.file} — ${(e as Error).message}`);
    return;
  }

  if (!content.trim()) {
    log.error('Contribution file is empty — nothing to push.');
    return;
  }
```

三种失败都只是 `log.error` 后 `return`，不抛异常。此时还没加载任何配置，所以参数错了不会留下任何副作用。对应测试：`src/__tests__/contribute.test.ts` 的 `rejects empty file`、`rejects missing file`。

### 3.2 选配置（scope），拦住 HTTP 后端

`src/contribute.ts:172-196`：

```ts
  const loadOpts = { dryRun: options.dryRun };
  let scope: Scope | undefined;
  try {
    scope = options.scope === undefined ? undefined : parseInstallScope(options.scope);
  } catch (e) {
    log.error((e as Error).message);
    process.exitCode = 1;
    return;
  }
  let localConfig: LocalConfig;
  if (scope === 'project') {
    const cfg = await loadLocalConfigForScope('project', process.cwd(), loadOpts);
    if (!cfg) { log.error('No workspace teamai config in this directory'); return; }
    localConfig = cfg;
  } else if (scope === 'user') {
    const { localConfig: userCfg } = await requireInit(loadOpts);
    localConfig = userCfg;
  } else {
    const projectConfig = await detectProjectConfig(undefined, undefined, loadOpts);
    localConfig = projectConfig ?? (await requireInit(loadOpts)).localConfig;
  }
  assertNotReadOnly(localConfig, 'teamai contribute');
  const username = localConfig.username;
  localConfig = await readWorkspaceChildren(localConfig);
```

- `--scope workspace` 会被解析成内部的 `'project'`，加载当前目录的工作区配置；`--scope user` 走用户级配置；不传时先找项目配置，找不到再退回用户级。测试 `contribute-edge-modes.test.ts` 的 `reads --scope workspace as the workspace config of this directory` 断言调用了 `loadLocalConfigForScope('project', process.cwd(), ...)`；`refuses a scope it does not know instead of guessing one` 断言未知 scope 报 `Invalid scope "global". Use "workspace" or "user".`。
- `dryRun` 一路传进配置加载器。注释解释：直接加载会就地迁移旧的 role 配置，在 `--dry-run` 下这就成了一次写操作（#850）。
- `assertNotReadOnly` 是 HTTP 后端的闸门（`src/read-only.ts:10-16`）：

```ts
export function assertNotReadOnly(localConfig: LocalConfig, op: string): void {
  if (localConfig.repo.kind === 'http') {
    throw new Error(
      `This team uses a read-only HTTP source — \`${op}\` is not supported. ` +
        `Ask a team admin to update the team repo.`,
    );
  }
}
```

所以对 HTTP 团队，`contribute` 会在解析任何 learnings 路径、写队列之前直接抛错。测试 `contribute-edge-modes.test.ts` 的 `refuses on an HTTP backend, before any of this touches it` 断言抛出 `/read-only HTTP/`，而且队列为空。后文提到的 HTTP 分支（写根就是 knowledge 目录、维护提交不走分支）是给 recall、维护等其他调用方准备的，contribute 本身走不到那里。

### 3.3 决定落到哪个 namespace

namespace 就是 `learnings/` 下面的一级子目录，用来按项目隔离经验。`src/contribute.ts:198-218`：

```ts
  const filename = generateFilename(options.title);
  const ownNamespaces = await resolveActiveLearningsNamespaces(
    localConfig.repo.localPath,
    localConfig.projects ?? [],
  );
  const namespaces = await deliveredLearningsNamespaces(localConfig);
  // Validate before saving the queue, creating worktrees or rebuilding indexes.
  if (options.namespace !== undefined &&
      (!isSafeNamespaceSegment(options.namespace) || !namespaces.includes(options.namespace))) {
    log.error(`Cannot contribute to namespace "${options.namespace}". Allowed learnings namespaces: ${namespaces.join(', ') || '(none)'}.`);
    process.exitCode = 1;
    return;
  }
  const learningsSubdir = options.namespace ?? (ownNamespaces.length === 1 ? ownNamespaces[0] : '');
  if (options.namespace === undefined && !learningsSubdir && namespaces.length > 0) {
    log.info(`Contributing to learnings/ (shared root). To choose a namespace, pass --namespace <ns>: ${namespaces.join(', ')}.`);
  }
  const relPath = learningsSubdir ? path.posix.join(learningsSubdir, filename) : filename;
```

这里有两个集合，容易混：

| 变量 | 来源 | 用途 |
| --- | --- | --- |
| `ownNamespaces` | 本 scope 自己激活的项目 | 决定默认值：恰好一个就用它，否则落共享根 `''` |
| `namespaces` | `deliveredLearningsNamespaces`，还包括 workspace 子成员的（#913） | `--namespace` 的白名单 |

`deliveredLearningsNamespaces`（`src/workspace-children.ts:163-171`）对每个成员都调一次 `resolveActiveLearningsNamespaces` 再取并集。

核心映射在 `src/projects.ts:245-258`：

```ts
export async function resolveActiveLearningsNamespaces(
  repoPath: string,
  activeProjects: string[],
): Promise<string[]> {
  if (activeProjects.length === 0) return [];
  const manifest = await loadProjectsManifest(repoPath);
  if (!manifest) return [];
  try {
    return resolveProjectResourceNamespaces({ manifest, activeProjects }).learnings;
  } catch {
    // Unknown active project id, etc. — degrade to shared root rather than throw.
    return [];
  }
}
```

- manifest 文件是团队仓库里的 `manifest/projects.yaml`（`loadProjectsManifest`，`projects.ts:132-133`）。文件不存在时返回 null，等于"这个团队没有项目划分"。
- 项目的 learnings namespace 来自 `resources.learnings`，而且可以和项目 id 不同。注释举的例子是项目 `alpha` 对应 `learnings: [alpha-notes]`（`projects.ts:236-240`）。所以 contribute 必须走这个映射，不能直接用项目 id，否则落点会和 `pull` 建索引用的目录对不上。
- 未知项目 id 之类的错误一律降级为共享根，不抛错。
- namespace 会当路径的一部分用，所以还要过一遍 `isSafeNamespaceSegment`（`src/manifest-schema.ts:47-52`）：非空、不含不安全字符、末尾不能是点或空格、不能是 Windows 设备名。

同文件的 `resolveLearningsSubdir`（`contribute.ts:31-44`）用的是同一套规则（一个才用、零或多个落共享根，并做安全检查），但 `contribute()` 自己没调用它。它的调用方是 `learnings-publish.ts:250-251`，用于给老版本 `import --from-mr` 留下的文件重新入队。

namespace 一旦算好就写进 `relPath` 存进队列。注释说得明白："Keep the chosen path in the queue so retries publish to the same namespace."，所以重试时不会再重新判断一次。

### 3.4 生成文件名与 dry-run

`src/contribute.ts:126-136`：

```ts
export function generateFilename(title?: string): string {
  const slug = (title ?? 'session-notes')
    .toLowerCase()
    .replace(/[^a-z0-9\u4e00-\u9fff]+/g, '-') // Allow CJK characters
    .replace(/^-+|-+$/g, '') // Trim leading/trailing hyphens
    .slice(0, 50);

  const date = new Date().toISOString().slice(0, 10); // YYYY-MM-DD
  const random = Math.random().toString(36).slice(2, 8);
  return `${slug}-${date}-${random}.md`;
}
```

- 不传 `--title` 时 slug 是 `session-notes`
- 只保留小写字母、数字和中日韩统一汉字（`\u4e00-\u9fff`），其他连续字符都折叠成一个 `-`
- 日期取 `toISOString()`，也就是 UTC 日期，不是本地日期
- 6 位 base36 随机后缀用来防止重名

测试：`contribute.test.ts` 的 `generates valid filenames with title`、`generates valid filenames with Chinese title`。

dry-run 到这一步就结束了（`contribute.ts:220-223`），只打印 `[dry-run] Would push: learnings/<relPath> (<n> bytes)`，不写队列、不建 worktree。测试：`contribute.test.ts` 的 `handles dry-run mode`。

接着，self 模式（单仓）会先调用 `migrateSelfModeGitignore`（`contribute.ts:230-233`）。原因是发布要在 `.teamai/` 下建 worktree，如果用户仓库的 `.gitignore` 早于这个改动，worktree 就会出现在用户自己的 `git status` 里。

### 3.5 写进持久队列：`savePendingLearning`

`src/contribute.ts:235-246` 调用队列写入；没写成功就直接失败，后面不会继续：

```ts
  try {
    const queued = await savePendingLearning(localConfig, relPath, content);
    if (queued.status !== 'saved') {
      spin.fail(queueWriteRefusal(queued));
      process.exitCode = 1;
      return;
    }
  } catch (e) {
    spin.fail(`Contribution failed: ${(e as Error).message}`);
    log.info('You can retry with: teamai contribute --file <path>');
    return;
  }
```

写入本身在 `src/utils/pending-learnings.ts:162-178`：

```ts
export async function savePendingLearning(
  localConfig: LocalConfig,
  relPath: string,
  content: string,
): Promise<QueueWrite> {
  const locked = await withQueueLock(queueHome(localConfig), async (): Promise<QueueWrite> => {
    const changed = await installChanged(localConfig);
    if (changed) return { status: 'changed', ...changed };
    const dest = path.join(pendingLearningsDir(localConfig), relPath);
    await ensureDir(path.dirname(dest));
    await fs.promises.writeFile(dest, content, 'utf-8');
    return { status: 'saved', path: dest };
  });
  return locked.status === 'done' ? locked.value : locked;
}
```

返回值是一个三选一的联合类型（`pending-learnings.ts:132-135`）：

```ts
export type QueueWrite =
  | { status: 'saved'; path: string }
  | { status: 'busy'; lockPath: string }
  | { status: 'changed'; configPath: string; cause: string };
```

有三层保护：

1. 队列锁。`withQueueLock`（`pending-learnings.ts:84-96`）用 `acquireQueueLock` 抢锁，最多重试 `QUEUE_LOCK_ATTEMPTS = 30` 次，每次间隔 `QUEUE_LOCK_RETRY_MS = 100` 毫秒，总共约 3 秒（`pending-learnings.ts:55-56`）。抢不到就返回 `busy`。锁文件在 `~/.teamai/locks/queue-<hash>.lock`，hash 是 `realpath(home)` 的 sha256 前 16 位（`queueLockPath`，`pending-learnings.ts:42-46`）。锁不放在 `home` 里面，因为迁移会把 checkout 的 `.teamai/` 整个改名挪走，锁要是在里面会被一起带走（`pending-learnings.ts:33-41` 注释）。
2. 安装是否变了。`installChanged`（`pending-learnings.ts:106-125`）在锁内重新读一遍 `config.yaml`，比较 kind 和 remote。原因是命令加载配置要早于写入，这期间 `init` 可能把项目切到了另一个团队仓库，再写就会把学习内容发到错误的仓库。远端比较用 `remotesMatch`，会忽略凭据、协议、`.git` 后缀和大小写（`sameQueueOwner`，`pending-learnings.ts:290-292`）。
3. 只锁这一次写入。注释（`pending-learnings.ts:167-168`）："Only the write is locked: the publish that follows takes the sync and learnings locks, and no queue lock is held while waiting for another." 这样做是为了避免持有一把锁的同时去等另一把锁，造成死锁。

`queueWriteRefusal`（`pending-learnings.ts:138-151`）把 `busy` / `changed` 翻译成给用户看的话，两种情况都以 "Nothing was saved." 结尾。

测试：`src/__tests__/pending-learnings.test.ts` 的 `writes content into the queue`、`preserves a namespace subdirectory in relPath (PR #426 P1 regression)`，以及 `pendingLearningsDir` 下的 `sits beside an independent clone, where a clone reset cannot reach it`（断言 `/home/user/.teamai/team-repo` 的队列在 `/home/user/.teamai/pending-learnings`）。

### 3.6 发布前先建索引：`rebuildIndexAfterContribute`

`src/contribute.ts:250-254`：

```ts
  try {
    await rebuildIndexAfterContribute(localConfig);
  } catch (e) {
    log.debug(`contribute: index rebuild skipped: ${(e as Error).message}`);
  }
```

索引失败只打 debug 日志，不影响后续步骤。函数本体在 `contribute.ts:55-88`，关键部分：

```ts
  await dropOtherCheckoutIndexes(localConfig);
  await buildIndex({
    learningsDirs: [
      pendingLearningsDir(localConfig),
      ...await indexableLearningsRoots(localConfig),
    ],
    learningsNamespaces: activeLearningsNamespaces,
    docsDir: (await pathExists(docsRepoDir)) ? docsRepoDir : undefined,
    rulesDir: (await pathExists(rulesRepoDir)) ? rulesRepoDir : undefined,
    ...await deliveredIndexSources(localConfig),
    votesDir: votesDir && (await pathExists(votesDir)) ? votesDir : undefined,
    indexPath,
    children: localConfig.children?.fingerprint,
  });
```

- 队列目录排在 `learningsDirs` 的第一位，而且同一相对路径以先出现的根为准（见 4.1）。所以如果队列里有一份对已发布 learning 的修改，recall 读到的是队列里这一份（`contribute.ts:51-53` 注释）。
- `learningsNamespaces` 用的是 `deliveredLearningsNamespaces`，必须和 `pull` 建索引用的一致。否则 contribute 这次重建会把项目里其他 learnings 从 recall 里丢掉（`contribute.ts:77-78` 注释）。
- `indexableLearningsRoots` 会排除"别的仓库的 learnings checkout"（见 4.2）。

为什么要在发布前建一次索引？测试 `src/__tests__/contribute-unpublishable.test.ts` 的 `keeps the note recallable on this machine` 给出了答案：learnings 分支根本写不进去的时候（`not-a-clone`），`~/.teamai/search-index.json` 里依然能找到 `unpublishable-` 开头的条目。

### 3.7 发布：`publishQueuedLearnings` 与 `publishUnderSyncLock`

`contribute.ts:256` 调用 `publishQueuedLearnings(localConfig, username)`。这个函数也会被 `pull` 调用（`src/pull.ts:1301`，传入 `holdsSyncLock: true`），所以离线时存下的贡献会在下次 pull 时补发。

先抢同步锁（`src/utils/learnings-publish.ts:64-84`）：

```ts
  const syncLock = options.holdsSyncLock ? null : syncLockPath(localConfig);
  const locked = syncLock === null || await acquireLock(syncLock, { dryRun: options.dryRun });
  try {
    return await publishUnderSyncLock(localConfig, username, locked, options.dryRun === true);
  } finally {
    if (syncLock && locked) await releaseLock(syncLock);
  }
```

同步锁是 pull/push 保护团队 clone 的那把锁。它不可重入，所以 pull 调用时要声明"我已经持有"，否则会自己等自己、死锁。如果没抢到，`locked` 为 false，但仍然进入 `publishUnderSyncLock`，由后者决定怎么处理。

`publishUnderSyncLock`（`learnings-publish.ts:86-160`）按以下顺序执行：

| 步骤 | 代码 | 说明 |
| --- | --- | --- |
| 1 | `queueImportRemnants`（仅 `locked && !dryRun`） | 把老版本 `import --from-mr` 遗留在 checkout 里、没提交的文件重新入队 |
| 2 | `listPendingForInstall` | 在队列锁内列出队列，并再次检查安装是否变了；`busy` 时返回 `lastError`，`changed` 时返回 `installChanged` |
| 3 | `publishRecordedMaintenance`（仅 `locked && !dryRun`） | 先补发之前维护操作没推上去的改动（见第 5 节） |
| 4 | 队列为空 → `{ published: [], remaining: 0 }`；dry-run → 只报数量 | |
| 5 | `!locked` → `lastError: 'another teamai pull or push is in progress'` | 不抢锁，把队列留给持锁的那次 pull/push 去发 |
| 6 | `publishToLearningsBranch` 后逐个 `dropPendingLearning` | 只删 `report.published` 中的条目 |

第 6 步，也就是"确认后才出队"（`learnings-publish.ts:142-159`）：

```ts
  try {
    const report = await publishToLearningsBranch(localConfig, username, queued);

    for (const relPath of report.published) {
      await dropPendingLearning(localConfig, relPath);
    }
    return { ...report, remaining: queued.length - report.published.length };
  } catch (e) {
    // Never throw: a contribution is already safe in the queue, and publishing
    // it is never the reason a command fails.
    log.debug(`[learnings] publishing failed (non-blocking): ${(e as Error).message}`);
    return {
      published: [],
      remaining: queued.length,
      lastError: failureReason(e),
      refused: e instanceof CheckoutRefusedError || undefined,
    };
  }
```

`dropPendingLearning`（`pending-learnings.ts:262-271`）的注释强调：只在内容确认到达 origin 后才调用，因为 worktree 被重置后，这份是唯一幸存的副本。

### 3.8 写进 worktree、commit、push

`publishToLearningsBranch`（`learnings-publish.ts:516-562`）通过 `learningsBranch.update()` 把队列逐个写进 worktree：

```ts
  const result = await learningsBranch.update(localConfig, async (worktree) => {
    const files: string[] = [];
    for (const relPath of queued) {
      const content = await readPendingLearning(localConfig, relPath);
      if (content === null) {
        unreadable.push(relPath);
        continue;
      }
      const destAbs = path.join(worktree, 'learnings', relPath);
      await ensureDir(path.dirname(destAbs));
      await fs.promises.writeFile(destAbs, content, 'utf-8');
      files.push(path.posix.join('learnings', relPath.split(path.sep).join('/')));
      published.push(relPath);
    }
    if (files.length === 0) return null;
    return { files, message: commitMessageFor(username) };
  });
```

所有队列条目合成一个 commit，提交信息是 `[teamai] Contribute session knowledge from <username>`（`learnings-publish.ts:55-57`）。随后按 `result.status` 分支：`published` / `already-present` 返回 `published` 列表（可以出队）；`busy` / `failed` 返回空列表（全部保留）。`already-present` 的注释说明：分支上已经有完全相同的内容，说明之前某次 push 成功了但没能确认，这时出队是安全的。

`learningsBranch` 本身只是一份配置（`src/utils/learnings-branch.ts:16-22`）：

```ts
export const learningsBranch = createBranchWorktree({
  branch: LEARNINGS_BRANCH,
  worktreeDirname: LEARNINGS_WORKTREE_DIRNAME,
  lockFilename: LEARNINGS_LOCK_FILENAME,
  logTag: 'learnings',
  initCommitMessage: '[teamai] Initialize learnings branch',
});
```

真正的逻辑在通用的 `src/utils/branch-worktree.ts`（reports 分支也用它）。`update` 对应 `updateImpl`（`branch-worktree.ts:736-786`），流程是：

1. `kind: 'http'` 直接抛错：`update() needs a branch-backed repo`（`branch-worktree.ts:742-744`）。
2. 抢分支锁 `.learnings-lock`，抢不到就返回 `{ status: 'busy' }`。
3. `openWorktree`：worktree 不存在时创建孤儿分支 worktree。独立 clone 模式下，如果 `repoRoot` 不是专用的团队 clone 根目录，会拒绝创建（`branch-worktree.ts:202-206`）。已有 checkout 时会检查它是否属于别的仓库（`refuseForeignCheckout`）。
4. 如果 checkout 不是最新的，先 `syncWorktree`；同步失败只记日志，"writing onto the local copy"。
5. 执行写入回调，然后 `commitAndPushAt`。

孤儿分支的创建在 `createOrphanWorktree`（`branch-worktree.ts:536-564`）：git 2.42 及以上用 `git worktree add --orphan -b teamai-learnings <wt>`，失败就退回老办法，先 `worktree add --detach` 再 `checkout --orphan`；两条路都会执行 `git rm -rf --cached .` 并清空文件，确保分支从空树开始。

`commitAndPushAt`（`branch-worktree.ts:606-674`）的要点：

```ts
  await git.raw(['--literal-pathspecs', 'add', '--', ...files]);
  // ...
  if (staged === 0 && !options.pushIfUnchanged && await nothingLeftToPush(git, spec)) {
    return { status: 'already-present' };
  }
  if (staged > 0) await commitSkippingHooks(git, message, files);

  const maxRetries = options.initPush ? INIT_PUSH_MAX_RETRIES : MAX_PUSH_RETRIES;
  for (let attempt = 1; attempt <= maxRetries; attempt++) {
    try {
      await git.push(['origin', spec.branch]);
      return { status: 'published' };
    } catch (pushErr) {
      if (attempt === maxRetries) {
        return { status: 'failed', reason: (pushErr as Error).message };
      }
      // ...
        await fetchTrackingRef(git, spec.branch);
        carried = await snapshotDirtyTree(spec, git);
        if (carried) await git.raw(['reset', '--hard', 'HEAD']);
        await git.rebase([`origin/${spec.branch}`]);
      // ...（rebase 失败则 rebase --abort）
      if (carried) await applyDirtySnapshot(spec, git, carried);
    }
  }
```

- `--literal-pathspecs`：防止文件名里的 `[`、`*` 被当成通配符。
- 只 add、只 commit 传入的 `files`，worktree 里别人暂存的东西不会被带进这次提交。
- 冲突处理靠 "push 失败 → fetch → rebase 到 `origin/teamai-learnings` → 再 push"，最多 `MAX_PUSH_RETRIES = 5` 次（`branch-worktree.ts:586`）。每个人写的文件名都带随机后缀，所以真实冲突基本不会出现，重试主要应对的是 non-fast-forward 的竞争。rebase 前会把工作区的脏改动做成快照，rebase 后再恢复。
- 判断成功的唯一依据是 `git push` 正常返回。注释特意说明不去重新检查远端跟踪引用：`--single-branch` clone 在 push 侧分支之后不会更新跟踪引用，如果检查它，每次成功的 push 都会被误判为失败（`branch-worktree.ts:642-645`）。
- `nothingLeftToPush` 只用来判断"什么都没暂存时，是否还欠 origin 一个 commit"，读不出来时一律当作"还要推"（`branch-worktree.ts:107-118`）。

`PublishResult` 有四种状态（`branch-worktree.ts:64-68`），只有 `published` 和 `already-present` 算送达（`isDelivered`，`branch-worktree.ts:81-83`）：

```ts
export type PublishResult =
  | { status: 'published' }
  | { status: 'already-present' }
  | { status: 'busy' }
  | { status: 'failed'; reason: string; refused?: true };
```

### 3.9 收尾：第二次建索引、markContributed、提示文案

`src/contribute.ts:264-294`：

```ts
  if (report.published.length > 0) {
    try {
      await rebuildIndexAfterContribute(localConfig);
    } catch (e) { /* debug */ }
  }

  const sessionId = options.sessionId || (await agentSessionIdFromEnv()) || '';
  if (sessionId) {
    await markContributed(sessionId);
  }

  if (report.published.includes(relPath)) {
    spin.succeed(`Contributed: learnings/${relPath}`);
    // ...
    return;
  }
  if (report.installChanged) {
    spin.warn(`Saved locally, not published: ${report.installChanged}. ${KEPT_FOR_ITS_INSTALL}`);
    return;
  }
  spin.warn(
    `Saved locally (${report.lastError ?? 'not published yet'}). `
    + (report.refused ? KEPT_UNTIL_CHECKOUT_SETTLED : 'It stays recallable here and the next `teamai pull` publishes it.'),
  );
```

- 第二次建索引：发布成功后队列文件已被删掉，第一次建的索引还指向这些已不存在的 pending 路径，agent 会拿到一个打不开的文件（#705）。所以要重建一次，让条目指向 worktree 里的持久副本。只有确实发布出去了才重建。
- `markContributed`（`src/contribute-check.ts:725-729`）把会话状态文件里的 `contributed` 置为 `true`，第 2 篇讲的摩擦检测靠这个标记不再重复提示。session id 优先取 `--session-id`，其次从环境变量推断（`agentSessionIdFromEnv`）。注意它在发布结果分支之前执行，只要入队成功就会标记，注释给了理由（`contribute.ts:272-275`）：队列总会重试，同一会话再贡献一次只会多出一份重复的知识。测试 `contribute-edge-modes.test.ts` 的 `marks the session named by the agent variable`（`CLAUDE_CODE_SESSION_ID`）和 `marks the Pi session, not the outer Claude Code session, from a Pi shell it started` 覆盖了这一逻辑。
- 三种结局对应三种文案：成功（`Contributed:`）、安装已变（`KEPT_FOR_ITS_INSTALL`）、暂存本地（若是 checkout 拒绝，提示用 `KEPT_UNTIL_CHECKOUT_SETTLED`，即每次 pull 都会遇到同样的拒绝，必须先处理）。

---

## 4. 写根与读根：`learnings-roots.ts`

发布写到哪里、recall 从哪里读，统一由 `src/utils/learnings-roots.ts` 一个文件决定。文件头注释（第 1-8 行）说明了原因：以前每个读取方各自拼路径，漏改一处不会报错，只会读到一个空目录，recall 结果悄悄变少（#485）。

### 4.1 `learningsRoots`：一个写根，多个读根

`learnings-roots.ts:77-100`：

```ts
export function learningsRoots(localConfig: LocalConfig): LearningsRoots {
  const write = writeRoot(localConfig);
  const read = [write];
  if (localConfig.scope === 'user') {
    read.push(getUserLearningsDir());
  }
  try {
    read.push(path.join(getDataHome(localConfig), 'learnings'));
  } catch {
    // no partition for this config
  }
  read.push(inheritedRoot(localConfig));
  return { write, read: dedupe(read) };
}
```

读根按优先级从高到低：

| 顺序 | 根 | 条件 |
| --- | --- | --- |
| 1 | 写根 `learningsBranch.dir()/learnings`（`writeRoot`，第 68-71 行） | 总是有，且 `read[0] === write` |
| 2 | 机器级镜像 `~/.teamai/learnings`（`getUserLearningsDir`，`types.ts:2205-2207`） | 只在 `scope === 'user'` 时加入，避免项目 scope 读到其他项目的经验 |
| 3 | 本 scope 的分区缓存 `<dataHome>/learnings` | `getDataHome` 抛错时（没有项目根的 project 配置）跳过 |
| 4 | 继承根 `<knowledge clone>/learnings`（`inheritedRoot`，第 58-61 行） | 总是有：learnings 迁到独立分支之前写下的内容，只读不写 |

- 这个函数是纯函数：不做 IO、不建 worktree、不联网（第 73-76 行注释）。
- `dedupe` 按 `path.resolve` 去重。HTTP 模式下 `getWorktreeDir` 返回的就是 `localPath`，所以写根和继承根是同一个目录，去重后只剩一个。测试 `learnings-roots.test.ts` 的 `writes into the knowledge dir for an HTTP backend, which has no branch` 断言 `roots.write` 等于 `~/.teamai/team-repo/learnings`。
- 队列目录故意不在读根里（第 45-48 行注释）：recall 和索引会读队列，但 prune、promote 不能动还没到达团队的条目，需要读队列的调用方自己把 `pendingLearningsDir` 加进去。

### 4.2 另外四个辅助函数

| 函数 | 位置 | 作用 |
| --- | --- | --- |
| `indexableLearningsRoots` | 第 113-128 行 | 调 `learningsBranch.checkOwner`。写根上的 checkout 属于别的仓库（`ForeignCheckoutError`，git/self 切换后会出现，#808）时把写根去掉；其他错误如果调用方传了 `unreadable` 就记一笔，否则抛出 |
| `knowledgeRoots` | 第 143-158 行 | recall 读取知识的全部目录：clone、用户镜像、读根、队列。用 `isForeignByFiles` 只看文件判断是否外来 checkout（hook 里不启动 git 进程）；出错时退回较小的集合，不抛错 |
| `listLearningFiles` | 第 186-206 行 | 按根的顺序列出 `.md`，用 `claimed` 集合保证同一相对路径只取第一个根里的那份；根不存在就跳过 |
| `isInWriteRoot` | 第 215-219 行 | 判断文件是否在写根下。维护类改动据此决定原地写还是写到写根，因为写根之外的文件没人会推送，改了别人也看不到 |

`listLearningFiles` 的先到先得规则在收集时就生效，不是事后再去重，因为相对路径同时也是计票用的 id（第 41-43 行注释）。测试：`learnings-roots.test.ts` 的 `keeps the first root when the same file is in two of them`、`ignores a root that does not exist`。

---

## 5. 维护改动的发布：`publishLearningsMaintenance`

prune、promote、置信度回写（第 7 篇）也会修改 learnings。以前它们改的是一个没人推送的 checkout，结果到不了任何队友，下次对齐时还可能被冲掉。现在它们直接写进 worktree，再由这个函数推出去（`learnings-publish.ts:326-337` 注释）。

`learnings-publish.ts:338-365` 的逻辑：

```ts
  const checkout = learningsBranch.dir(localConfig);
  const inCheckout = changed
    .map((file) => path.relative(checkout, file))
    .filter((rel) => rel !== '' && !rel.startsWith('..') && !path.isAbsolute(rel));
  // ...
  if (!learningsBranch.enabled(localConfig)) {
    // kind: 'http' has no branch to retry against.
    return inCheckout.length === 0 ? { status: 'already-present' } : commitMaintenance(localConfig, message, inCheckout);
  }
  if (inCheckout.length > 0) {
    try {
      const contents: Record<string, string | null> = {};
      for (const rel of inCheckout) contents[rel] = await contentDigest(path.join(checkout, rel));
      await recordMaintenance(checkout, { message, files: inCheckout, contents });
    } catch (e) {
      return commitMaintenance(localConfig, message, inCheckout);
    }
  }
  return publishRecordedMaintenance(localConfig);
```

- 和队列的思路一样：先把改动记下来，确认送达后再删记录。记录是一个 JSON（message、文件列表、每个文件的 sha256，删除用 null），放在 `git rev-parse --git-path teamai-maintenance` 指向的目录里（`maintenanceRecordsDir`，第 394-397 行），git 不会显示也不会提交它。写入是原子的，文件名以时间戳开头。
- `publishRecordedMaintenance`（第 407-474 行）按文件名排序合并所有记录。如果文件现在的哈希和记录里的不一致，而且还有未提交的改动，说明有人在维护之后又手动改过，这部分不发布，并打印警告。结果是 `published` 或 `already-present` 时才删记录。
- `commitMaintenance`（第 480-506 行）只提交维护涉及的那些文件，不会把整个 `learnings/` 带进去；最终调用的是 `learningsBranch.commitAndPush`，不是 `update`。注释解释：维护已经先写进了 worktree，而 `update` 会先和 origin 同步，可能把这些未提交的文件卷进 rebase。
- HTTP 分支：`enabled()` 为 false（即 `usesBranchWorktree`），不写记录，直接提交；没有文件时返回 `already-present`。如果目录不是 git 能识别的 checkout，返回 `failed`，不抛错（第 494-496 行）。
- 3.7 的第 3 步会在每次发布队列前调用一次 `publishRecordedMaintenance`，所以维护时没推上去的改动，会搭下一次 contribute 或 pull 的车发出去。

---

## 6. 端到端流程图

```text
teamai contribute --file x.md [--title T] [--namespace NS] [--scope S]
  │
  ├─ 读文件 / 非空校验 ──失败──> log.error, return（无副作用）
  ├─ 解析 scope → localConfig
  ├─ assertNotReadOnly ──kind=http──> throw "read-only HTTP"（不写队列）
  ├─ 算 namespace：--namespace（白名单校验）| 恰好 1 个 | 共享根 ''
  ├─ generateFilename → relPath = [ns/]slug-YYYY-MM-DD-xxxxxx.md
  ├─ --dry-run ──> 打印 "[dry-run] Would push"，return
  ├─ (self 模式) migrateSelfModeGitignore
  │
  ├─ savePendingLearning ── 队列锁(≤3s) + installChanged 检查
  │     ├─ busy / changed ──> spin.fail, exitCode=1, return
  │     └─ saved: <queue>/[ns/]file.md
  │
  ├─ rebuildIndexAfterContribute #1（队列优先）── 失败只记 debug
  │
  ├─ publishQueuedLearnings
  │     ├─ 抢同步锁 .sync-lock（pull 传 holdsSyncLock 跳过）
  │     └─ publishUnderSyncLock
  │          ├─ queueImportRemnants / listPendingForInstall / publishRecordedMaintenance
  │          ├─ 未持锁 ──> lastError，全部留在队列
  │          └─ publishToLearningsBranch → learningsBranch.update
  │               ├─ 分支锁 .learnings-lock ──busy──> 全部留在队列
  │               ├─ openWorktree（必要时建孤儿分支 worktree）+ syncWorktree
  │               ├─ 写 <wt>/learnings/[ns/]file.md
  │               └─ commitAndPushAt: add → commit → push
  │                    push 失败 → fetch + rebase → 重试（≤5 次）
  │          published/already-present ──> dropPendingLearning（出队）
  │          busy/failed ──> 留在队列，等下次 pull
  │
  ├─ 有发布成功的条目 ──> rebuildIndexAfterContribute #2（指向 worktree 副本）
  ├─ markContributed(sessionId)（只要入队成功就标记）
  └─ 提示：Contributed / Saved locally (原因) / 安装已变
```

---

## 7. 常见坑与边界情况

| 现象 | 原因（代码/注释） |
| --- | --- |
| HTTP 团队执行 contribute 直接报错 | `assertNotReadOnly` 在入队之前就抛错（`read-only.ts:10-16`）；HTTP 后端只能 pull |
| 显示"Saved locally"，但会话已不再被提示分享 | 入队即 `markContributed`，发布结果不影响（`contribute.ts:272-279`） |
| 一直发布不出去，提示要先处理 checkout | `refused`：worktree 位置上的 checkout 属于别的仓库或无法证明归属，每次 pull 都会遇到（`KEPT_UNTIL_CHECKOUT_SETTLED`） |
| 显示 "another teamai pull or push is in progress" | 没抢到同步锁，交给持锁的那个命令去发（`learnings-publish.ts:133-140`） |
| 多个项目激活时没进项目目录 | 归属不明确，落共享根，并打印可选的 `--namespace` 列表（`contribute.ts:213-216`） |
| `--namespace` 被拒绝 | 必须是安全的单段路径，且在 `deliveredLearningsNamespaces` 里（`contribute.ts:207-212`） |
| 文件名里的日期比本地日期早一天 | `toISOString()` 取的是 UTC 日期（`contribute.ts:133`） |
| 发布后 recall 给出的文件路径不存在 | 已由第二次建索引修复（#705，`contribute.ts:258-270`） |
| 换团队仓库或换模式后，队列被挪到 `pending-learnings.<kind>[-<repo>]` | `setAsideQueueOnModeSwitch` / `setAside`，不删除任何文件，并告知数量和位置（`pending-learnings.ts:299-378`） |
| 队列里的 `.swp`、隐藏文件没被发布 | 只取 `.md`，并跳过任何以 `.` 开头的路径段（`pending-learnings.ts:240-248`） |
| 推送成功却显示"失败"？ | 代码刻意不检查跟踪引用，避免 `--single-branch` clone 误判（`branch-worktree.ts:642-645`） |

---

## 8. 动手验证

只读命令（假设是 git 模式的独立 clone，在 `~/.teamai/team-repo`）：

```bash
# 队列里还有哪些没发布的
ls -R ~/.teamai/pending-learnings 2>/dev/null

# learnings worktree 及其分支
git -C ~/.teamai/learnings-wt branch --show-current
git -C ~/.teamai/learnings-wt log --oneline -5

# 远端分支上的 learnings 文件
git -C ~/.teamai/team-repo ls-tree -r --name-only origin/teamai-learnings -- learnings | head

# 只预览、不写入
teamai contribute --file /tmp/x.md --title "demo" --dry-run

# 某个会话是否已标记 contributed
cat ~/.teamai/sessions/<sessionId>.json
```

对应测试（在仓库根目录执行 `npx vitest run <文件>`，会创建临时目录）：

- `src/__tests__/contribute.test.ts`：`rejects empty file`、`generates valid filenames with Chinese title`、`handles dry-run mode`
- `src/__tests__/pending-learnings.test.ts`：`preserves a namespace subdirectory in relPath (PR #426 P1 regression)`、`leaves every entry queued when publishing fails`、`leaves the queue alone while a pull or push holds the sync lock`、`keeps the queued copy when the repository cannot be written`
- `src/__tests__/learnings-roots.test.ts`：`adds the machine-local cache as a read root in user scope`、`leaves the machine-local cache out in project scope, because it is shared by every project`、`writes into the knowledge dir for an HTTP backend, which has no branch`
- `src/__tests__/contribute-edge-modes.test.ts`：`refuses on an HTTP backend, before any of this touches it`、`marks the session named by the agent variable`
- `src/__tests__/contribute-unpublishable.test.ts`：`keeps the note recallable on this machine`

---

## 9. 自测问题

<details>
<summary>1. 断网时执行 contribute，这条经验会丢吗？队友什么时候能看到？</summary>

不会丢。它已经写进 `pending-learnings` 队列，并且建了本地索引，自己马上能 recall 到。发布失败时条目留在队列；下一次 `teamai pull` 会调用 `publishQueuedLearnings` 再推，推成功后队友才能看到。
</details>

<details>
<summary>2. 为什么 learnings 不直接提交到 main？</summary>

成员可能没有受保护 `main` 的写权限（#485）。写到独立的孤儿分支 `teamai-learnings` 的 worktree，既不碰默认分支，也不碰用户的工作区。
</details>

<details>
<summary>3. 队列条目什么时候才会被删除？</summary>

只有发布结果是 `published` 或 `already-present`（远端确实已有这份内容）时，才对 `report.published` 里的条目调用 `dropPendingLearning`。`busy` 和 `failed` 一律保留。
</details>

<details>
<summary>4. 项目 alpha 的 manifest 写着 `learnings: [alpha-notes]`，贡献会落在哪个目录？</summary>

`learnings/alpha-notes/`。namespace 来自 `manifest/projects.yaml` 里的 `resources.learnings`，不是项目 id（`resolveActiveLearningsNamespaces`）。前提是只有这一个激活的 namespace；有多个时，不传 `--namespace` 就落到共享根。
</details>

<details>
<summary>5. HTTP 后端和 git 后端，在这条链路上有哪些不同？</summary>

contribute 在 HTTP 下直接拒绝（`assertNotReadOnly`）。其他地方：`usesBranchWorktree` 为 false，所以 `getWorktreeDir` 返回 `localPath`，写根就是 knowledge 目录，和继承根合并为一个；`update()` 会抛错；维护改动走 `commitMaintenance`，不写重试记录。
</details>

---

## 10. 导航

- 上一步：[03-share-skill.md](./03-share-skill.md)：agent 怎么写出这份经验文档
- 下一步：[05-pull-distribution.md](./05-pull-distribution.md)：pull 如何补发队列、同步 learnings 给队友
- 索引：[README.md](./README.md)

---

## 未逐行核实

- `branch-worktree.ts` 只读了第 40-245 行和第 530-790 行：`syncWorktree`、`refuseForeignCheckout` / `refuseUnprovenCheckout` 的具体判断、`snapshotDirtyTree` / `applyDirtySnapshot` 的实现、`checkOwnerImpl` / `isForeignByFilesImpl` 都没逐行读，相关描述来自函数名和注释。
- `pending-learnings.test.ts` 有个用例名为 `stays inside .teamai in single-repo mode`，断言 self 模式的队列在 `/workspace/product/.teamai/pending-learnings`；而源码注释说 self 模式的队列在 data home、"Not in the checkout's `.teamai/`"。两者之间的关系（这个测试配置下 `getDataHome` 是否恰好解析到 `.teamai`）没有核实，所以本文表格只写了 `<dataHome>/pending-learnings/`。
- `getDataHome`、`getBusinessRoot`、`isDedicatedRepoRoot` 的具体实现没读，表格里 `<dataHome>` 的具体路径没有展开。
- `agentSessionIdFromEnv` 如何在多个环境变量（如 `CLAUDE_CODE_SESSION_ID`、`PI_SESSION_ID`）之间选择，只读了测试，没读实现。
- `readContributeState` / `writeContributeState` 的完整字段和文件格式没读；`~/.teamai/sessions/<id>.json` 的路径来自 `contribute-check.ts:120` 的注释。
- `buildIndex`、`dropOtherCheckoutIndexes`、`deliveredIndexSources`、`indexableVotesDir` 内部没读（属于第 6 篇的范围）。
- `pull.ts` 只确认了第 1301 行调用 `publishQueuedLearnings(..., { holdsSyncLock: true, ... })`，pull 的整体流程没读（见第 5 篇）。
- `migrateSelfModeGitignore`（`init.ts`）、`commitSkippingHooks`、`fetchTrackingRef` 的实现没读。
- 第 8 节的 shell 命令是按本文推导出的路径写的，没有在真实安装上执行过；`npx vitest` 是根据测试文件推断的运行方式，没有核对 package.json 里的 scripts。
