# 第 3 步：AI 怎么把会话写成 learning（share skill）

> 面向小白。先讲"为什么要有它"和"整体长什么样"，再沿着一次真实调用逐函数看代码。
> 基于 `main@fe3b906` 源码（2026-10-17），标注 `文件:行号`；行号会随代码变动，以函数名/常量名为准。删减了部分注释，用 `// ...` 省略无关分支。
> 前置：[02-friction-detection.md](./02-friction-detection.md) 讲了 Stop hook 怎么判断"这次会话值得分享"并打出提醒。本文讲**提醒之后，AI 拿到什么指令、按什么格式写文档**。

---

## 0. 一句话 + 一个类比

**一句话**：AI 工具里只装了一个很薄的发现入口 `skills/teamai/SKILL.md`（stub），它不写具体做法，只告诉 AI "去运行 `teamai skill get share`"；CLI 从 npm 包里的 `skill-data/share/` 读出**与当前安装版本一致**的工作流，替换 `{SKILL_DIR}` 占位符后打到 stdout。AI 按其中的模板（`references/doc-template.md`）写一份带 YAML frontmatter 的中文 Markdown，再交给 `teamai contribute`。frontmatter 里的 `title / author / date / tags` 之后会被 `parseLearningDoc` 解析进搜索索引。

**类比**：餐厅的点菜牌和后厨菜谱。

- 桌上的点菜牌（stub）印好就不再换，只写"想吃 X 请问服务员"
- 服务员（`teamai skill get`）每次都去后厨拿**当天版本**的菜谱（`skill-data/`），菜谱更新了点菜牌也不用重印
- 菜谱规定了出菜的摆盘格式（frontmatter 模板）；格式统一，前台（搜索索引）才能按菜名、标签把菜找出来
- 今天这道菜没备料（recall 没开、只读源），服务员直接说"做不了，原因是……"，而不是让厨师做到一半才发现

---

## 1. 为什么需要它

### 1.1 问题：复制进 agent 目录的 skill 会过期

teamai 同时支持多种 AI 工具，每个工具有自己的 skills 目录。如果把完整 skill 复制进去，用户升级 CLI 后，已复制出去的文本不会跟着更新，AI 读到的指令就和实际 CLI 行为对不上。

`src/skill-content.ts:10` 的文件头注释写明了新方案：

```ts
// ─── CLI-served skill content ────────────────────────────
//
//  Built-in skill bodies ship inside the npm package and are
//  printed on demand instead of being copied into every agent
//  skills directory.  What the agent reads therefore always
//  matches the installed CLI version.
//
//  npm package
//    skills/<name>/SKILL.md       deployed to agents (discovery stub)
//    skill-data/<name>/SKILL.md   never deployed, printed by `teamai skill get`
```

也就是两层：

| 位置 | 是否部署到 agent 目录 | 内容 | 是否随版本变 |
| --- | --- | --- | --- |
| `skills/teamai/SKILL.md` | 是 | 发现入口 stub，只做路由 | 设计上不变 |
| `skill-data/<name>/SKILL.md` | 否 | 真正的工作流 | 每个版本都可能变 |
| `skill-data/<name>/references/*` | 否 | 模板、字段表等补充材料 | 同上 |

### 1.2 stub 写了什么

`skills/teamai/SKILL.md:25` 原文（节选）：

```markdown
This file is a discovery stub, not the usage guide. Load the workflow from the CLI before running anything, so the instructions match the installed version:
...
The CLI serves skill content that always matches the installed version, so instructions never go stale. The content in this stub cannot change between releases, which is why it just points at `skill get`.
```

和本文相关的两行（`skills/teamai/SKILL.md:39`、`:44`）：

```markdown
teamai skill get share            # turn what this session taught you into a team learning (needs recall on)
A friction reminder at the end of a turn means `teamai skill get share`.
```

frontmatter 第 14 行把 stub 预授权的工具限定为 `teamai skill` 子命令：

```yaml
allowed-tools: Bash(teamai skill:*), Bash(npx teamai-cli skill:*)
```

所以第 2 篇的摩擦提醒一出现，AI 读 stub，就会去跑 `teamai skill get share`。

---

## 2. 整体流程图

```text
 Stop hook 打出摩擦提醒（第 2 篇）
        │   "... run `teamai skill get share`"
        ▼
 AI 读 stub skills/teamai/SKILL.md ──> 执行 teamai skill get share
        │
        ▼
 src/index.ts:236  skill get [names...]  ──> skillGet()            skill-content.ts:440
        │
        ├─ packagedSkillRoots()   定位 npm 包内 skills/ 与 skill-data/   :227
        ├─ resolveServableSkill() 名字/别名解析 + 门禁（gate）           :309
        │     ├─ resolvePackagedSkill()  "learnings" → "share"         :270
        │     └─ blockReason() → shareGate() → gateFor()             :198/:145/:150
        │            ├─ 没有任何配置       → 放行（新装机器也能看文档）
        │            ├─ 配置读不了         → 拒绝 reason=config
        │            ├─ HTTP 只读源        → 拒绝 reason=read-only
        │            └─ recall 未开启      → 拒绝 reason=recall
        └─ renderSkill()  读 SKILL.md，替换 {SKILL_DIR}，--full 追加 references/   :385
        ▼
 stdout：share 工作流正文（诊断信息全走 stderr）
        ▼
 AI（建议在子 agent 中）总结会话 → 按 doc-template 写 Markdown → 存临时文件
        ▼
 teamai contribute --file <path> --title "<title>"（第 4 篇）
        ▼
 建索引时 parseLearningDoc() 解析 frontmatter        search-index.ts:294
```

---

## 3. 代码走读：`teamai skill get share` 做了什么

### 3.1 命令注册

`src/index.ts:234`：

```ts
skillCmd
  .command('get [names...]')
  .description('Print built-in skill content served by the installed CLI')
  .option('--full', 'Append the skill\'s references/ and templates/ files')
  .option('--all', 'Print every skill the CLI serves')
  .allowUnknownOption()
  .action(async (names: string[] | undefined, cmdOpts) => {
    const { skillGet } = await import('./skill-content.js');
    await skillGet(names ?? [], { full: cmdOpts.full, all: cmdOpts.all });
  });
```

有两点值得注意：

- `allowUnknownOption()`：AI 有时会编造参数（比如 `--verbose`）。这里只打一行警告，不让命令失败，免得 AI 白白多走一轮。
- 用 `await import(...)` 懒加载：只有执行到这个子命令时才加载对应模块，CLI 启动更快。

### 3.2 找到 npm 包里的两个根目录

`src/skill-content.ts:227`：

```ts
export function packagedSkillRoots(): PackagedSkillRoots {
  const modulePath = fileURLToPath(import.meta.url);
  let moduleDir: string;
  try {
    moduleDir = path.dirname(fs.realpathSync(modulePath));
  } catch {
    moduleDir = path.dirname(modulePath);
  }
  const packageRoot = path.join(moduleDir, '..');
  return {
    deployRoot: path.join(packageRoot, 'skills'),
    dataRoot: path.join(packageRoot, 'skill-data'),
  };
}
```

为什么先调 `realpathSync`？`npm i -g` 装出来的 `teamai` 命令是一个符号链接。不先解析成真实路径，`..` 可能指到包外面的目录。路径是根据当前运行模块的位置算出来的，所以 **AI 读到的内容一定和正在运行的 CLI 是同一个版本**，这就是"版本一致"的实现方式。

### 3.3 名字解析与别名

`src/skill-content.ts:43`：

```ts
const SKILL_ALIASES: Readonly<Record<string, string>> = {
  default: 'core',
  onboarding: 'setup',
  join: 'setup',
  codebase: 'wiki',
  'team-wiki-codebase': 'wiki',
  learning: 'share',
  learnings: 'share',
  'teamai-share-learnings': 'share',
};
```

`resolvePackagedSkill()`（`:270`）先按名字精确匹配，匹配不到再查别名表。`skill-data/` 下的内容优先于同名的已部署 stub。所以 `teamai skill get learnings` 和 `teamai skill get share` 拿到的是同一份内容。保留旧名字作为别名，是为了让老文档、老习惯继续能用。

### 3.4 门禁：什么时候拒绝提供 share

`share` 是唯一一个"需要 recall"的 skill（`:64`）：

```ts
const RECALL_DEPENDENT_SKILLS = new Set(['share']);
```

判断逻辑在 `gateFor()`（`:150`）：

```ts
async function gateFor(team: TeamDetection): Promise<ShareGate> {
  const { isRecallEnabled } = await import('./types.js');
  if (team.kind === 'none') return { block: null, config: null };
  if (team.kind === 'unusable') return { block: { reason: 'config', detail: team.detail }, config: null };
  const { localConfig, teamConfig } = team.init;
  if (localConfig.repo?.kind === 'http') return { block: { reason: 'read-only' }, config: null };
  if (!isRecallEnabled(localConfig, teamConfig)) return { block: { reason: 'recall' }, config: null };
  return { block: null, config: team.init };
}
```

逐行说明：

1. `none`：这台机器上根本没有 teamai 配置。此时放行，让刚安装、还在看文档的人能读到内容，而不是收到一个他没法处理的拒绝。
2. `unusable`：配置文件存在但读不了。这时无法知道 recall 是否开启、源是否可写，所以拒绝，并把失败原因带出去。
3. `http`：只读的 HTTP 源。`teamai contribute` 最后一步一定会失败，与其让 AI 写完文档才发现推不上去，不如一开始就拒绝。
4. recall 未开启：learning 推上去也搜不到，没有意义。

被拒绝时，`blockMessage()`（`:329`）往 stderr 输出两行英文说明，比如：

```text
✖ share needs recall, which is disabled for this team.
  Turn it on with `teamai recall enable`, or ask your team admin to enable sharing.
```

**同一个门禁也控制 Stop hook 的提醒。** `contributeHintAllowed()`（`:180`）内部调用的就是 `shareGate()`，在 `src/hook-handlers.ts:472` 和 `:519` 被使用：

```ts
export async function contributeHintAllowed(cwd?: string): Promise<boolean> {
  const { isContributeHintEnabled } = await import('./types.js');
  let gate: ShareGate;
  try {
    gate = await shareGate(cwd);
  } catch (e) {
    log.debug(`share gate failed, reminder withheld: ...`);
    return false;
  }
  if (gate.block) return false;
  return gate.config
    ? isContributeHintEnabled(gate.config.localConfig, gate.config.teamConfig)
    : false;
}
```

这样就保证"提醒"和"命令"不会互相矛盾：不会出现 hook 提醒你去分享，结果 `skill get share` 拒绝你的情况。注意它和 `gateFor` 有一处不同：**没有配置时不提醒**（返回 `false`），因为没有团队，也就没有可以分享的对象。

源码注释（`:418`）特意说明：门禁只是"路由辅助"，不是访问控制。文件本身就在 npm 包里，谁都能读到。

### 3.5 渲染：替换 `{SKILL_DIR}`，`--full` 追加附录

`src/skill-content.ts:385`：

```ts
export async function renderSkill(skill: PackagedSkill, options: { full?: boolean } = {}): Promise<string> {
  const resolve = (text: string): string => text.split(SKILL_DIR_PLACEHOLDER).join(skill.dir);

  let out = withTrailingNewline(resolve(await fs.promises.readFile(path.join(skill.dir, SKILL_MD), 'utf8')));

  if (options.full) {
    for (const file of await collectSupplementaryFiles(skill.dir)) {
      out += `\n--- ${file.relativePath} ---\n\n`;
      out += withTrailingNewline(resolve(file.content));
    }
  }
  return out;
}
```

- `{SKILL_DIR}` 会被替换成包内的绝对路径，例如 `.../node_modules/teamai-cli/skill-data/share`。AI 拿到后，可以直接 `Read {SKILL_DIR}/references/doc-template.md`。这里用 `split/join` 做全局替换，没有用正则，所以不用处理花括号转义。
- `--full` 会把 `references/` 和 `templates/`（`SUPPLEMENTARY_DIRS`，`:32`）下的所有文件按路径排序，用 `--- references/doc-template.md ---` 分隔后追加在正文后面。share skill 只有一个附录文件；wiki skill 的附录目录有多层嵌套，所以这里用 `listFilesRecursive` 递归收集（`:361`）。

**输出纪律**（`:21` 的文件头注释）：skill 正文原样写到 stdout，所有诊断信息用 `console.error` 写到 stderr。这样 `teamai skill get share > SKILL.md` 得到的文件和原文逐字节一致，AI 读 stdout 时也不会混进警告。

---

## 4. share 工作流本身（`skill-data/share/SKILL.md`）

这是 AI 实际读到的指令。核心是 4 步（`:25-33`）：

1. **Summarize**：回顾这次会话用了什么工具、解决了什么问题、发现了什么模式。
2. **Write the document**：写 Markdown，覆盖问题、关键决策及原因、解决办法或绕过方法、好用的工具和 skill、踩过的坑。
3. **Save it**：写到一个临时文件。
4. **Push it to the team**：执行 `teamai contribute --file <path> --title "<title>"`。

另外几条约束：

- **用简体中文写**（`:13`）。命令、参数、路径、代码标识符保持原样。这是为了兼容早期版本的行为。
- **用子 agent 执行**（`:50`）。总结整个会话会产生大量中间推理，放在子 agent 里做，主会话的上下文不会被污染。
- 推到 `teamai-learnings` 分支的 `learnings/` 目录，**不走 PR**（`:51`）。
- "这是知识库，不是日记"（`:53`）：要简洁、可操作。
- 想发布一个可复用的 **skill**（不是 learning），走的是另一个流程，在 `core` skill 的 `references/contribute-member.md` 里（`:55-60`）。

---

## 5. 文档模板与 frontmatter（`references/doc-template.md`）

### 5.1 模板

```markdown
---
title: "<short title naming the core problem or finding>"
author: <username>
date: <YYYY-MM-DD>
tags: [tag1, tag2, tag3]
---

## Context
## Solution
## Lessons
## Related Skills
```

### 5.2 字段

| 字段 | 必填 | 含义 | 在索引里的用途 |
| --- | --- | --- | --- |
| title | 是 | 60 字符以内，点明核心问题 | 标题 token 权重最高（第 6 篇：命中计 3 分） |
| author | 是 | 贡献者用户名 | 晋升时统计贡献者人数（第 7 篇） |
| date | 是 | YYYY-MM-DD | 展示，以及按时间排序 |
| tags | 是 | 2-5 个标签 | tag token 命中计 2 分，并用来推断领域（domain） |

标签从 4 类里选：技术栈（python、k8s…）、问题类型（troubleshooting、performance…）、模式（workflow、best-practice…）、场景（debugging、testing…）。

### 5.3 frontmatter 怎么进索引

`src/utils/search-index.ts:294`：

```ts
export function parseLearningDoc(content: string, filename: string) {
  if (!content.trim()) return null;
  let data: Record<string, unknown>;
  let body: string;
  try {
    ({ data, content: body } = matter(content));
  } catch {
    // 不是严格 YAML（如 rule 的 `paths: **/*.ts`）时宽松解析 (#946)
    data = teamRuleData(content);
    body = teamRuleBody(content);
  }
  const meta: LearningDocMeta = {
    title: typeof data.title === 'string' ? data.title : undefined,
    author: typeof data.author === 'string' ? data.author : undefined,
    date: typeof data.date === 'string'
      ? data.date
      : data.date instanceof Date ? data.date.toISOString().slice(0, 10) : undefined,
    tags: Array.isArray(data.tags)
      ? data.tags.filter((t: unknown) => typeof t === 'string')
      : typeof data.Tags === 'string'
        ? data.Tags.split(/[,，]\s*/).map((t: string) => t.trim()).filter(Boolean)
        : undefined,
  };
  return { meta, bodyExcerpt: body };
}
```

几处容错处理：

- `date: 2026-10-17` 不加引号时，YAML 会把它解析成 `Date` 对象。代码会把它转回 `YYYY-MM-DD` 格式。
- 兼容旧写法 `Tags: a, b，c`：首字母大写，用逗号分隔，中英文逗号都支持。
- YAML 解析失败时不会报错，而是退回宽松解析。

调用方在 `search-index.ts:494`：

```ts
const parsed = parseLearningDoc(content, filenameForId);
if (!parsed) return null;
const { meta, bodyExcerpt } = parsed;
const title = meta.title ?? titleFromFilename(filenameForId);
const tags = meta.tags ?? [];
// ...
const domain = inferDomain(rawFrontmatterDomain, tags, absPath, type);
const tokens = [
  ...titleTokens.map((t) => `title:${t}`), ...titleTokens,
  ...tagTokens.map((t) => `tag:${t}`),     ...tagTokens,
  ...bodyTokens,
  `type:${type}`,
];
```

**这就是 frontmatter 必须写的原因**：

- 没有 `title` 时，标题只能从文件名反推（`titleFromFilename`，`:334`）：`api-timeout-修复-2026-03-20-abc123.md` → `api timeout 修复`。信息少了很多。
- 没有 `tags` 时，就拿不到 `tag:` 前缀的 token，这部分的加分没了；领域推断也只能退回到看路径和类型。
- `inferDomain()`（`:236`）的优先级：frontmatter 里显式写的 `domain` > 标签匹配（tie 时 technical > ops > support）> 路径匹配 > 类型兜底（skills/rules → technical，其余 → neutral）。领域会影响检索时的乘数（第 6 篇）。

---

## 6. 一份完整的示例 learning

```markdown
---
title: "teamai pull 在 CodeBuddy 下被 10 秒强杀"
author: maolu
date: 2026-10-17
tags: [typescript, troubleshooting, config]
---

## Context
在 CodeBuddy 里开新会话时偶发 hook 报错，日志显示 SessionStart 超时。

## Solution
- pull 本身不需要给宿主返回结果，确认它已注册为 background（hook-handlers.ts 的 pullHandler）
- 用 `teamai doctor` 检查 hook 是否为最新的 hook-dispatch 形式，旧的独立 hook 需要重新 `teamai pull`

## Lessons
- CodeBuddy 约 10 秒就会强杀 hook，不管声明的 timeout 是多少
- 需要返回提示的 handler 才放前台，其余一律后台

## Related Skills
- teamai
```

（示例内容仅用于演示格式。）

---

## 7. 设计取舍小结

| 决策 | 原因 | 代价 |
| --- | --- | --- |
| stub 与版本无关，内容由 CLI 提供 | 升级 CLI 后指令自动更新，不用重新部署 | 多一次命令调用 |
| 门禁放在 `resolveServableSkill` 一个地方 | `get/path/list/show` 自动继承，不会漏 | 无 |
| 提醒和命令共用 `shareGate` | 不会出现"提醒你分享，结果命令拒绝"的情况 | 每次 Stop 都要加载配置 |
| 用子 agent 写总结 | 主会话上下文保持干净 | 子 agent 只能看到交给它的摘要 |
| frontmatter 必填 | 检索质量依赖 title 和 tags | 写作门槛略高，好在由 AI 代写 |

---

## 8. 常见坑与边界

- **recall 没开**：`skill get share` 直接拒绝，Stop hook 也不会提醒。用 `teamai recall enable` 开启，或者让管理员在 `teamai.yaml` 里设置 `sharing.recall.enabled: true`。
- **HTTP 只读源**：share 永远不可用，learning 只能由管理员加进团队仓库。
- **项目配置文件损坏**：门禁返回 `config`，并打印具体哪个文件读不了。不会悄悄回退到另一个团队的配置，避免把 learning 推给错误的团队（见 `detectTeam` 的注释，`:87-99`）。
- **编造的参数**：只警告不报错。但**名字写错是致命的**（`notFound`），因为 AI 会照着错误的指令去做。
- **忘了写 frontmatter**：`contribute` 照样能提交，只是检索效果变差。
- **`skill list`**：被拒绝的 skill 仍然会列出来，并注明原因（`BLOCK_NOTES`，`:322`），只是不给目录路径。这样 AI 知道有这个 skill，也知道该开什么才能用。

---

## 9. 动手验证

只读命令：

```bash
teamai skill list                    # 看 share 是否被门禁拦住
teamai skill get share               # 打印 share 工作流
teamai skill get learnings           # 别名，内容同上
teamai skill get share --full        # 附带 doc-template.md
teamai skill path share              # 打印包内目录
teamai skill get share --verbose     # 编造参数：只有一行 stderr 警告
```

相关测试：

- `src/__tests__/skill-content.test.ts`：渲染、别名、`--full`、stdout/stderr 分离
- `src/__tests__/skill-recall-gate.test.ts`：recall、read-only、config 三种门禁
- `npx vitest run skill-content skill-recall-gate`

---

## 10. 自测问题

<details>
<summary>1. 为什么 stub 里不直接写 share 的工作流？</summary>

stub 部署到 agent 目录后不会随 CLI 升级而更新。内容由 `teamai skill get` 从包内 `skill-data/` 读取，所以总是和已安装的版本一致。
</details>

<details>
<summary>2. 新装的机器上还没配置 teamai，`skill get share` 会拒绝吗？Stop hook 会提醒吗？</summary>

`skill get share` 不会拒绝（`gateFor` 遇到 `none` 时放行）。Stop hook 不会提醒（`contributeHintAllowed` 在没有配置时返回 false），因为没有团队可以分享。
</details>

<details>
<summary>3. `{SKILL_DIR}` 在哪里被替换？替换成什么？</summary>

在 `renderSkill()` 里，替换成包内 skill 目录的绝对路径。
</details>

<details>
<summary>4. 没写 title 和 tags 会怎样？</summary>

仍然能入库。标题从文件名反推，没有 tag 带来的加分，领域只能按路径和类型推断，所以检索排名会变差。
</details>

<details>
<summary>5. 为什么诊断信息必须写到 stderr？</summary>

保证 stdout 是逐字节一致的 skill 正文，可以重定向保存，AI 读取时也不会混进警告。
</details>

---

## 导航

- 上一步：[02-friction-detection.md](./02-friction-detection.md)
- 下一步：[04-contribute-publish.md](./04-contribute-publish.md)
- 索引：[README.md](./README.md)

---

## 未逐行核实

- `skill show` / `skill list` 的实现（`src/skill-cmd.ts`）：只确认了它们复用 `skillCatalog` / `resolveServableSkill`，没有逐行读。
- `isRecallEnabled`、`isContributeHintEnabled` 在 `src/types.ts` 中的具体优先级（环境变量 > 本机配置 > 团队配置），参考的是用户文档，没有逐行读。
- 两个测试文件的具体用例名没有逐个列出。
- 第 6 节的示例 learning 是虚构的演示内容。
