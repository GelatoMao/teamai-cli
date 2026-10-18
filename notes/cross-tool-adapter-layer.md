# 跨工具统一适配层：从零读懂 teamai-cli 如何"一份配置，喂给 30+ 个 AI 工具"

> 面向小白。先讲"为什么"和"整体长什么样"，再一层层往下钻到具体代码。
> 所有代码都摘自本仓库（版本 0.22.0 源码），标注了 `文件:行号`，可以直接跳过去看。
> 摘录为了好读会删掉部分注释、用 `// ...` 省略无关分支，但逻辑没改。

---

## 0. 一句话 + 一个类比

**一句话**：团队在 git 仓库里只维护一份"工具中立"的资源（skills / rules / agents / MCP / hooks），teamai 负责把它**翻译**成每个 AI 编码工具各自认识的文件格式和目录位置，并且在工具运行时把各家不一样的事件输入**归一化**成同一套处理逻辑。

**类比**：把 teamai 想成一个"万能电源适配器"。

- 团队仓库 = 墙上的标准插座（只有一种规格）
- Claude Code、Cursor、Codex、Copilot…… = 各国的电器，插头形状各不相同
- 适配层 = 转换头：插座不变，按电器换不同的头

---

## 1. 先理解问题：为什么需要适配层？

同样是"给 AI 一条团队规则"，不同工具的要求完全不同：

| 工具 | 规则放哪 | 文件格式 |
| --- | --- | --- |
| Claude Code | `.claude/rules/xxx.md` | 普通 Markdown |
| Cursor | `.cursor/rules/xxx.mdc` | 必须带 `globs` / `alwaysApply` frontmatter，否则**被静默忽略** |
| Copilot | `.github/instructions/xxx.instructions.md` | 自己的 frontmatter |
| Codex | **没有规则目录**（`.codex/rules` 是它的执行策略文件） | 只能靠会话启动 hook 注入 |

hooks（生命周期钩子）差异更大：

- Claude：`settings.json` 里 `hooks.SessionStart[]`，事件名 PascalCase
- Cursor：`hooks.json` 里 `hooks.sessionStart[]`，事件名 camelCase，没有 `description` 字段
- Copilot：每条 hook 要同时写 `bash` 和 `powershell` 两个命令
- OpenCode：**根本没有 hook 配置文件**，只能写一个 TS 插件
- ZCode：hook 嵌在 `hooks.events` 下，超时单位是毫秒

如果每加一个工具就在业务代码里到处写 `if (tool === 'cursor')`，代码会迅速失控。适配层要解决的就是：**业务逻辑只写一次，工具差异集中在少数几个"翻译表 / 翻译函数"里。**

---

## 2. 整体架构

适配层是**双向**的：写的方向（pull，把团队资源装进工具），和读的方向（运行时，工具触发 hook 回调 teamai）。

```
                    ┌──────────────────────────────────────────┐
                    │  团队仓库（单一事实来源，工具中立格式）       │
                    │  skills/  rules/*.md  agents/*.yaml        │
                    │  mcp/   hooks/hooks.yaml                   │
                    └───────────────────┬──────────────────────┘
                                        │ teamai pull
 ┌──────────────────────────────────────▼───────────────────────────────────┐
 │ ① 工具注册层（数据）  "有哪些工具？各自的文件放哪？装了没有？"                  │
 │   KNOWN_AGENTS (known-agents.ts)   toolPaths 默认值 (types.ts)              │
 │   scopedToolPaths / resolveBaseDir / isToolInstalledForConfig               │
 ├──────────────────────────────────────────────────────────────────────────┤
 │ ② 资源处理层（流程）  "每类资源怎么扫描、怎么投递"                              │
 │   ResourceHandler 抽象类 (resources/base.ts)                                │
 │   Skills / Rules / Agents / Mcp / Hooks / Docs / Env 七个 Handler           │
 ├──────────────────────────────────────────────────────────────────────────┤
 │ ③ 格式翻译层（策略）  "同一份资源，变成每个工具认识的字节"                       │
 │   rules  → RULE_FORMATS 策略表 (rule-format.ts + cursor-mdc.ts 等)          │
 │   agents → AgentSpec 中间格式 + renderForTool / reverseFrom* (agent-format) │
 │   mcp    → detectMcpFormat + renderXxx (mcp-format.ts)                     │
 │   hooks  → HookDef + detectFormat + toXxxEntry (hooks.ts)                  │
 │            插件型工具单独适配器 (opencode-hooks.ts / hermes-hooks.ts …)       │
 └───────────────────┬──────────────────────────────────────────────────────┘
                     │ 写入
     .claude/  .cursor/  .codex/  .github/  .opencode/plugin/  ...
                     │
                     │ 运行时：工具触发 hook，执行
                     │ bash -lc "teamai hook-dispatch session-start --tool cursor"
 ┌───────────────────▼──────────────────────────────────────────────────────┐
 │ ④ 运行时归一化层  "把各家不一样的输入/输出抹平"                                │
 │   输入：parseStdin + EVENT_MAP、resolveHookCwd、normalizeToolName            │
 │   输出：formatStopHookOutput、stopStdoutUnsupported                         │
 │   之后进入统一的 dispatcher → handlers（与工具无关）                          │
 └──────────────────────────────────────────────────────────────────────────┘
```

记住三个关键设计：

1. **数据驱动**：工具差异尽量写成"表"（`KNOWN_AGENTS`、`toolPaths`、`RULE_FORMATS`、`CLAUDE_TO_CURSOR_EVENTS`），而不是散落的 `if`。
2. **中间表示（IR）**：团队仓库存的是中立格式（rule `.md`、agent `.yaml`、`HookDef`、`McpServerDef`），每个工具只需要实现"IR → 本地格式"（以及可选的反向）。
3. **单一出口**：一个工具"该写到哪、写成什么"只有一个函数回答（`deliveryTargets`、`renderRuleForTool`、`renderForTool`），pull 和 doctor 共用，避免"说同步了但其实没写进去"。

下面按 ①→④ 逐层讲。

---

## 3. 第①层：工具注册层 —— "有哪些工具，文件放哪"

### 3.1 工具清单 `KNOWN_AGENTS`

`src/known-agents.ts:82`

```ts
export interface KnownAgent {
  id: string;           // CLI 里用的 id，例如 --agent cursor
  displayName: string;  // 给人看的名字
  category: AgentCategory; // 'coding' | 'lobster' | 'central'
  skillsPath: string;   // 相对 HOME 的 skills 目录
}

export const KNOWN_AGENTS: KnownAgent[] = [
  { id: 'claude', displayName: 'Claude Code', category: 'coding', skillsPath: '.claude/skills' },
  { id: 'codex',  displayName: 'Codex CLI',   category: 'coding', skillsPath: '.codex/skills' },
  { id: 'cursor', displayName: 'Cursor',      category: 'coding', skillsPath: '.cursor/skills' },
  // ... gemini / kiro / opencode / qoder / trae / windsurf / zcode ...
  { id: 'muse',   displayName: 'Muse Code',   category: 'coding', skillsPath: '.config/muse/skills' },
  { id: 'openclaw', displayName: 'OpenClaw',  category: 'lobster', skillsPath: '.openclaw/skills' },
  { id: 'agents', displayName: 'Central (Agent Skills)', category: 'central', skillsPath: '.agents/skills' },
];
```

小白要点：这只是一张"通讯录"，最小信息只有 skills 目录。完整的路径信息在下一节的 `toolPaths`。

`getEffectiveAgents()`（`known-agents.ts:328`）会把这张内置表和团队 `teamai.yaml` 里的 `toolPaths` **合并**：团队配置优先，并且团队可以声明内置表里没有的新工具。这意味着**加一个新工具不一定要改代码**，管理员在配置里加一行就能用（至少 skills 能用）。

### 3.2 每个工具的"文件地图" `toolPaths`

先看 schema，它规定了一个工具**可能**拥有哪些资源路径（`src/types.ts:15`）：

```ts
export const ToolPathsSchema = z.object({
  skills: z.string().optional(),     // skills 目录
  rules: z.string().optional(),      // 规则目录
  settings: z.string().optional(),   // hooks 所在的 settings 文件
  hooks: z.string().optional(),      // 独立的 hooks 文件（不放在 settings 里的工具）
  claudemd: z.string().optional(),   // 指令文件（CLAUDE.md / AGENTS.md 一类）
  agents: z.string().optional(),     // 子 agent 目录
  mcp: z.string().optional(),        // 用户级 MCP 配置
  mcpProject: z.string().optional(), // 项目级 MCP 配置
  userScope: z.object({ /* 用户级与项目级路径不同时的覆盖 */ }).optional(),
});
```

**字段缺失 = 该工具不支持这类资源**。这是整个适配层最朴素也最重要的约定：后面所有 Handler 都是 `if (!toolPath.rules) continue;` 这样跳过。

再看默认值（`src/types.ts:461` 起），挑几个有代表性的：

```ts
toolPaths: z.record(z.string(), ToolPathsSchema).default({
  // Claude：什么都有，MCP 用户级和项目级文件名还不一样
  claude: { skills: '.claude/skills', rules: '.claude/rules', settings: '.claude/settings.json',
            claudemd: '.claude/CLAUDE.md', agents: '.claude/agents',
            mcp: '.claude.json', mcpProject: '.mcp.json' },

  // Codex：故意没有 rules（.codex/rules 是它的 exec-policy 文件，不能乱写）
  //        用户级才有 AGENTS.md
  codex: { skills: '.codex/skills', settings: '.codex/hooks.json', agents: '.codex/agents',
           mcp: '.codex/config.toml', mcpProject: '.codex/config.toml',
           userScope: { claudemd: '.codex/AGENTS.md' } },

  // Cursor：hooks 在 hooks.json 而不是 settings.json
  cursor: { skills: '.cursor/skills', rules: '.cursor/rules', settings: '.cursor/hooks.json',
            agents: '.cursor/agents', mcp: '.cursor/mcp.json', mcpProject: '.cursor/mcp.json' },

  // Copilot：项目级放 .github/，用户级放 $COPILOT_HOME/，所以用 userScope 覆盖
  copilot: { skills: '.github/skills', rules: '.github/instructions', agents: '.github/agents',
             hooks: '.github/hooks/teamai.json', claudemd: '.github/copilot-instructions.md',
             /* ... */
             userScope: { skills: 'skills', rules: 'instructions', agents: 'agents',
                          hooks: 'hooks/teamai.json', claudemd: 'copilot-instructions.md' } },

  // JoyCode：没有 hooks 系统，所以没有 settings；用户级没有规则目录（rules: null）
  joycode: { skills: '.joycode/skills', rules: '.joycode/rules', agents: '.joycode/agents',
             userScope: { rules: null } },
  // ...
}),
```

注释里能看出很多"踩过的坑"：比如 MCP 路径**只给验证过的工具配**，"猜错了宁可不写，也不要在用户机器上造出垃圾配置文件"（`types.ts:458` 的注释）。

### 3.3 Scope：同一个工具，用户级和项目级路径可能不同

teamai 有两种安装范围（内部叫 `user` / `project`，对用户显示 `workspace`）：

- user：资源写到 `$HOME` 下，所有项目共享
- project：资源写到项目根目录下

**基准目录**由 `resolveBaseDir` 决定（`src/types.ts:2271`）：

```ts
export function resolveBaseDir(localConfig: LocalConfig): string {
  if (localConfig.scope === 'project') {
    if (!localConfig.projectRoot) throw new Error('... refusing to silently fall back to the user home directory ...');
    return localConfig.projectRoot;
  }
  return getUserHome();
}
```

注意它**宁可报错也不默默退回 HOME**，因为写错位置比失败更难排查。

**相对路径**由 `scopedToolPaths` 决定（`src/types.ts:2689`）：

```ts
export function scopedToolPaths(teamConfig, localConfig) {
  if (localConfig.scope !== 'user') return teamConfig.toolPaths;   // 项目级：直接用顶层字段
  const rooted = applyToolRoots(teamConfig.toolPaths, localConfig.toolRoots); // 支持 CLAUDE_CONFIG_DIR 等重定位
  const out = {};
  for (const [tool, paths] of Object.entries(rooted)) {
    const us = paths.userScope;
    if (!us) { out[tool] = paths; continue; }
    const scoped = {
      ...paths,
      ...(us.skills !== undefined ? { skills: us.skills } : {}),
      ...(typeof us.rules === 'string' ? { rules: us.rules } : {}),
      // ... settings / agents / hooks / claudemd 同理
    };
    if (us.rules === null) delete scoped.rules;  // null = 用户级明确没有规则目录
    out[tool] = scoped;
  }
  return out;
}
```

**最终落盘路径 = `resolveToolBaseDir(tool)` + `scopedToolPaths(...)[tool].xxx`**。所有 Handler 都这样拼路径，所以 scope 的复杂度被关在这两个函数里。

### 3.4 "装了没有"门禁：不给没装的工具造目录

teamai 的原则是：**用户没装的工具，绝不替它创建目录**。判断方式很朴素——看工具根目录存不存在（`src/resources/base.ts:190`）：

```ts
static async isToolInstalled(toolPath: string, baseDir?: string, rootSegment?: string) {
  const base = baseDir ?? getUserHome();
  // '.claude/skills' → 检查 '<base>/.claude' 是否存在
  const toolRoot = path.join(base, rootSegment ?? toolInstallRoot(toolPath));
  return pathExists(toolRoot);
}
```

`toolInstallRoot` 取路径的第一段；但 `.config/xxx` 例外，取前两段，因为几乎所有人都有 `~/.config`（`types.ts:2501`）。

真实世界有很多例外，都集中在 `isToolInstalledForConfig`（`base.ts:36`）里用小表处理：

```ts
const INSTALL_ROOTS = { workbuddy: '.workbuddy' };           // WorkBuddy 的项目规则借用 .codebuddy/rules，不能用它判断
const HOME_INSTALL_ROOTS = { muse: '.config/muse' };          // Muse 的项目文件和别的工具共用，只能看 HOME
const EDITION_HOME_ROOTS = { trae: '.trae', 'trae-cn': '.trae-cn', qoder: '.qoder', 'qoder-cn': '.qoder-cn' };
                                                              // 国际版/国内版共用项目目录，只能看各自 HOME 目录

export async function isToolInstalledForConfig(tool, toolPath, localConfig, exactConfigPath?) {
  const baseDir = resolveToolBaseDir(tool, localConfig);
  if (tool === COPILOT_TOOL_ID) { /* 看 enabledAgents 或 $COPILOT_HOME */ }
  const editionHomeRoot = EDITION_HOME_ROOTS[tool];
  if (editionHomeRoot !== undefined) { /* ... */ }
  if (Object.hasOwn(HOME_INSTALL_ROOTS, tool)) return pathExists(path.join(getUserHome(), HOME_INSTALL_ROOTS[tool]));
  const probe = Object.hasOwn(INSTALL_ROOTS, tool) ? INSTALL_ROOTS[tool] : toolPath;
  return ResourceHandler.isToolInstalled(probe, baseDir, toolGateRoot(tool, probe, localConfig.toolRoots));
}
```

另外还有用户的显式开关：`isAgentExcluded`（`types.ts:2481`）= 在 `disabledAgents` 里，或者设置了 `enabledAgents` 白名单但不在其中。

**小结**：一个工具能收到某个资源，要同时满足 ① 没被排除 ② `toolPaths` 里有对应字段 ③ 工具已安装。后面每个 Handler 的循环开头都是这三连。

---

## 4. 第②层：资源处理层 —— `ResourceHandler` 抽象

### 4.1 抽象类：每类资源都要回答的 5 个问题

`src/resources/base.ts:86`

```ts
export abstract class ResourceHandler {
  abstract readonly type: ResourceType;  // 'skills' | 'rules' | 'docs' | 'env' | 'agents' | 'hooks' | 'mcp'

  // push 方向：本地工具目录里有哪些可以推回团队仓库的？
  abstract scanLocalForPush(teamConfig, localConfig, options?): Promise<ResourceItem[]>;
  // pull 方向：团队仓库里有哪些该拉下来的？
  abstract scanTeamForPull(teamConfig, localConfig): Promise<ResourceItem[]>;
  // 把一个本地条目写回团队仓库
  abstract pushItem(item, teamConfig, localConfig): Promise<void>;
  // 把一个团队条目装进各工具目录（ledger 用来保护用户本地改过的副本）
  abstract pullItem(item, teamConfig, localConfig, ledger?): Promise<void>;
  // 从团队仓库和所有工具目录删除
  abstract removeItem(name, teamConfig, localConfig): Promise<string[]>;

  // 只读：这个条目在每个工具上会落到哪里、内容是什么
  async deliveryTargets(teamConfig, localConfig, item, received?): Promise<DeliveryTarget[]> {
    return [];
  }
}
```

注册表（`src/resources/index.ts:11`）——经典的"策略注册表"：

```ts
const handlers: Record<ResourceType, ResourceHandler> = {
  skills: new SkillsHandler(),
  rules: new RulesHandler(),
  docs: new DocsHandler(),
  env: new EnvHandler(),
  agents: new AgentsHandler(),
  hooks: new HooksHandler(),
  mcp: new McpHandler(),
};
export function getAllHandlers(): ResourceHandler[] { return Object.values(handlers); }
```

pull / push 主流程只做 `for (const h of getAllHandlers())`，**完全不知道有哪些工具**。工具差异全部下沉到 Handler 内部和第③层。

### 4.2 `deliveryTargets` 的"只读契约"——为什么重要

`base.ts:152` 的注释是这一层的设计核心，翻译一下：

> 解析目的地**永远不能写盘**，这样同一个答案既能用于同步，也能用于校验。同一个目的地有两套解析逻辑，就是"显示同步了 N 个 skill，但某个工具其实什么都没收到"的根源（#598、#624）。

所以 `pullItem` 的写法是"先问 `deliveryTargets`，再照着写"，而 `teamai doctor` 也调用同一个 `deliveryTargets` 去比对磁盘。下面 Rules 的代码就是这样。

---

## 5. 第③层：格式翻译层 —— 按资源类型逐个看

难度从低到高：Skills（原样复制）→ Rules（策略表）→ Agents（中间格式 + 双向）→ MCP（格式族）→ Hooks（最复杂）。

### 5.1 Skills：几乎不用翻译

Skills 是"目录 + SKILL.md"，各工具格式基本一致，所以适配只体现在**路径**上。`src/resources/skills.ts:1321`：

```ts
async pullItem(item, teamConfig, localConfig, ledger?) {
  for (const target of await this.resolveTargets(teamConfig, localConfig, item, item.sourcePath, ledger?.previous)) {
    const { tool, dest } = target;
    try {
      if (ledger && await keepsEditedCopy(ledger, item, target)) continue; // 用户本地改过，保留
      // ...
      await copyDir(item.sourcePath, dest, /* ... */);   // 整个目录复制过去
      await ensureSkillFrontmatter(dest, item.name);      // 补齐 frontmatter
      if (ledger) await recordDelivered(ledger.hashes, dest, item.sourcePath); // 记账：写了什么 hash
    } catch (e) {
      log.warn(`Failed to sync skill ${item.name} to ${tool}: ...`); // 单个工具失败不影响其他工具
    }
  }
}
```

两个值得学的细节：

- **ledger（投递账本）**：记录"teamai 写进去的是哪个 hash"。下次 pull 时如果磁盘内容 ≠ 账本记录，说明用户手动改过，就不覆盖。
- **单工具失败隔离**：try/catch 包在循环内部，一个工具坏了不会拖垮其他工具。

### 5.2 Rules：策略表 `RULE_FORMATS`

#### 5.2.1 策略接口

团队仓库永远存中立的 `<name>.md`。有自己格式的工具实现一个 `RuleFormat`（`src/resources/rule-format.ts:32`）：

```ts
export interface RuleFormat {
  readonly extension: '.md' | '.mdc' | '.instructions.md';     // 写出去用什么扩展名
  render(rawTeamRule: string): string;                          // 团队 .md → 工具格式（pull）
  bodyEquals(rawToolRule: string, rawTeamRule: string): boolean;// 正文是否一致（判断"有没有改过"）
  mergeBodyIntoTeam(rawToolRule: string, existingTeamMd: string | null): string; // 工具格式 → 团队 .md（push）
  readonly scopeFields: readonly string[];                      // doctor 提示用
  readonly flat?: true;                                         // 工具只读顶层目录，命名空间要拍平
  readonly previousRenders?: readonly ((raw: string) => string)[]; // 老版本 teamai 写过的格式，用于认领旧文件
}
```

#### 5.2.2 策略表

`rule-format.ts:59`：

```ts
const RULE_FORMATS: Readonly<Record<string, RuleFormat>> = {
  cursor: CURSOR_MDC_FORMAT,
  joycode: JOYCODE_RULE_FORMAT,
  copilot: COPILOT_INSTRUCTIONS_FORMAT,
  kiro: KIRO_STEERING_FORMAT,
  qoder: QODER_RULE_FORMAT,  'qoder-cn': QODER_RULE_FORMAT,
  trae: TRAE_RULE_FORMAT,    'trae-cn': TRAE_RULE_FORMAT,
  codebuddy: CODEBUDDY_RULE_FORMAT,
  workbuddy: CODEBUDDY_RULE_FORMAT,   // 同一引擎，复用
  omp: OMP_RULE_FORMAT,
};

// 唯一的"翻译"入口：有格式就 render，没有就原样
export function renderRuleForTool(tool: string, rawTeamRule: string): string {
  return ruleFormatForTool(tool)?.render(rawTeamRule) ?? rawTeamRule;
}
```

不在表里的工具（比如 Claude）就拿到原样 `.md`。文件头注释写得很明白：**这是做这个决定的唯一位置**，所有写、扫描、比较、推送、删除规则文件的地方都必须经过它。

#### 5.2.3 一个具体策略：Cursor `.mdc`

`src/resources/cursor-mdc.ts`。团队规则的 frontmatter 只有一个可选的 `paths:`（限定在哪些文件上生效），Cursor 要的是 `globs` + `alwaysApply`：

```ts
function deriveCursorFrontmatter(data: Record<string, unknown>): CursorFrontmatter {
  const patterns = rulePaths({ paths: data.paths ?? data.globs });
  if (patterns.length > 0) {
    return { globs: patterns.join(', '), alwaysApply: false }; // 有范围 → 自动附加型规则
  }
  return { alwaysApply: true };                                // 无范围 → 强制规则，每次会话都生效
}

function renderCursorMdc(fm: CursorFrontmatter, body: string): string {
  const lines = ['---'];
  // 必须加引号：以 * 开头的 glob 在 YAML 里是 alias 语法，不加引号整个 frontmatter 解析失败
  if (fm.globs !== undefined) lines.push(`globs: ${JSON.stringify(fm.globs)}`);
  lines.push(`alwaysApply: ${fm.alwaysApply}`);
  lines.push('---');
  return `${lines.join('\n')}\n\n${body}\n`;
}

export const CURSOR_MDC_FORMAT: RuleFormat = {
  extension: '.mdc',
  render: teamRuleToCursorMdc,
  bodyEquals: ruleBodyEqualsTeamMd,
  mergeBodyIntoTeam: mergeRuleBodyIntoTeamMd,
  scopeFields: ['globs', 'alwaysApply'],
};
```

转换例子：

```markdown
<!-- 团队仓库 rules/api-style.md -->
---
paths: ["src/api/**"]
---
接口统一返回 { code, data, message }
```

```markdown
<!-- pull 之后 .cursor/rules/api-style.mdc -->
---
globs: "src/api/**"
alwaysApply: false
---

接口统一返回 { code, data, message }
```

**关键设计**：只有**正文**双向流动，两边的 frontmatter 各归各的。push 回去时团队文件保留自己的 `paths:`、只替换正文，所以一次 pull→push 往返不会产生假 diff，也不会丢掉团队的作用范围。

#### 5.2.4 Handler 怎么用这个策略

`src/resources/rules.ts:297`，就是第 3.4 节说的"三连检查" + 第 4.2 节说的"只读解析"：

```ts
async deliveryTargets(teamConfig, localConfig, item, receivedNames?) {
  const source = await readFileSafe(item.sourcePath);
  const targets: DeliveryTarget[] = [];
  for (const [tool, toolPath] of Object.entries(scopedToolPaths(teamConfig, localConfig))) {
    if (isAgentExcluded(localConfig, tool)) continue;                          // ① 用户排除了
    if (!toolPath.rules) continue;                                              // ② 工具没有规则目录
    if (!await isToolInstalledForConfig(tool, toolPath.rules, localConfig)) continue; // ③ 没装

    const destDir = path.join(resolveToolBaseDir(tool, localConfig), toolPath.rules);
    const ext = ruleFileExtensionForTool(tool);          // .md / .mdc / .instructions.md
    // ... flat 工具把 fe/style 拍平成 fe.style ...
    const dest = path.join(destDir, `${stem}${ext}`);
    const content = source === null ? undefined : renderRuleForTool(tool, source); // 翻译

    // 两个工具读同一个目录、同一种格式 → 共用一个副本（WorkBuddy 和 CodeBuddy）
    const shared = targets.find((t) => t.dest === dest && t.content === content);
    if (shared) { (shared.sharedWith ??= []).push(tool); continue; }

    targets.push({ tool, dest, content, /* ... */ });
  }
  return targets;
}

async pullItem(item, teamConfig, localConfig, ledger?, received?) {
  for (const target of await this.deliveryTargets(teamConfig, localConfig, item, received)) {
    // 照着 target 写盘；内容读不到就报错，绝不写一个空的"强制规则"
  }
}
```

#### 5.2.5 没有规则格式的工具怎么办？

Codex 没有规则目录，那团队规则怎么进去？`rule-format.ts:80` 给出了"第二、第三条通道"：

```ts
// 通道 2：会话启动 hook 把规则作为上下文注入
const SESSION_HOOK_RULE_TOOLS = new Set(['codex', 'codex-internal', 'tcodex', 'zcode', 'dsh', 'muse']);
// 通道 3：teamai 写给它的扩展（插件）把规则拼进系统提示词
const EXTENSION_RULE_TOOLS = new Set(['pi']);
```

用户级还有第四条：写进工具自己的指令文件里的一个**受管块**，例如 `~/.codex/AGENTS.md`、`~/.joycode/rules.txt`。teamai 用 HTML 注释标记圈出自己的地盘（`src/types.ts:1488` 起）：

```ts
export const TEAMAI_TEAM_RULES_START = '<!-- [teamai:team-rules:start] -->';
export const TEAMAI_TEAM_RULES_END   = '<!-- [teamai:team-rules:end] -->';
export const TEAMAI_CULTURE_START    = '<!-- [teamai:culture:start] -->';
// ...
```

标记之间的内容归 teamai，每次 pull 重写；标记外是用户自己的内容，**永远不碰**。决定"每个工具的指令块写到哪个文件"的逻辑集中在 `src/instruction-targets.ts`，它的原则写在开头注释里：只写已安装的工具，**绝不写项目或其他工具共享的文件**（#945）——比如项目根目录的 `AGENTS.md` 是项目所有者的文件，而且多个工具都会读，所以 Codex 的项目级规则走 hook 而不是写进去。

所以 Rules 的完整投递图是：

```
团队 rules/*.md
  ├─ 有 RuleFormat 的工具（Cursor/Copilot/Kiro/Qoder/...）→ render 成各自格式写进规则目录
  ├─ 有 rules 路径但无格式（Claude）                      → 原样 .md 写进规则目录
  ├─ SESSION_HOOK_RULE_TOOLS（Codex/ZCode/DSH/Muse）     → 项目级：session-start hook 注入上下文
  ├─ EXTENSION_RULE_TOOLS（Pi）                          → 项目级：扩展拼进系统提示词
  └─ 用户级无规则目录的工具                                 → 指令文件中的 [teamai:team-rules] 受管块
```

#### 5.2.6 历史包袱：`LEGACY_RULE_DIRS`

`rule-format.ts:276` 记录了"老版本 teamai 往哪些工具根本不读的目录写过规则"（比如 #938 之前给 Codex 写过 `.codex/rules/*.md`）。每次 pull 会**认领并清理**那些没被用户改过的旧副本，改过的保留并给出警告。这说明适配层不仅要支持新格式，还要负责**迁移**。

### 5.3 Agents（子 agent）：中间格式 + 双向转换

Agent 的差异比规则大得多：有的是 Markdown + frontmatter，Codex 是 TOML，Kiro 是 JSON，Copilot 用 `.agent.md`，Cursor 用 `agent_id` 而不是 `name`。所以这里用了编译器里常见的 **IR（中间表示）** 思路。

#### 5.3.1 中间格式 `AgentSpec`

团队仓库存 `agents/<name>.yaml`，解析成（`src/resources/agent-format.ts:75`）：

```ts
export interface AgentSpec {
  name: string;
  description: string;
  instructions: string;      // 主提示词
  model?: string;
  tools?: string[];          // 工具白名单
  tool_extras?: {            // 各工具私有字段，原样透传
    claude?: Record<string, unknown>;
    codex?: Record<string, unknown>;
    cursor?: Record<string, unknown>;
    // ... 每个支持的工具一个 key
  };
  targets?: ToolName[];      // 只投递给这些工具；不写 = 全部已安装的
}
```

`tool_extras` 是精髓：**公共字段放顶层，私有字段放各自的格子里**。这样 IR 不会因为某个工具多一个字段就膨胀，也不会丢信息。

例子：

```yaml
# 团队仓库 agents/reviewer.yaml
name: reviewer
description: 代码评审助手
instructions: |
  你是一个严格的代码评审者……
tools: [Read, Grep]
tool_extras:
  codex:
    sandbox_mode: read-only
```

#### 5.3.2 正向：`renderForTool` 一个 switch 搞定分发

`agent-format.ts:1024`：

```ts
export function renderForTool(spec: AgentSpec, tool: ToolName, resolved?: ResolvedAgentModel): RenderResult {
  const target = resolved ? withModel(spec, resolved.model) : spec;   // 模型别名解析后的 model
  const ext = agentFileExtensionForTool(tool);
  switch (tool) {
    case 'claude': case 'claude-internal': case 'tclaude':
      return { ext, content: renderMarkdownAgent(target, toolExtrasFor(spec, tool), fields) };
    case 'codex': case 'codex-internal': case 'tcodex':
      return { ext, content: renderTomlAgent(target, toolExtrasFor(spec, tool), fields) };
    case 'codebuddy': case 'qoder': case 'qoder-cn': case 'zcode': case 'omp':
      return { ext, content: renderMarkdownAgent(target, toolExtrasFor(spec, tool), fields) };
    case 'cursor':   return renderForCursor(target);
    case 'copilot':  return renderForCopilot(target);
    case 'kiro':     return renderForKiro(target);
    case 'opencode': return renderForOpencode(target, fields);
    // ... joycode / workbuddy / muse
  }
}
```

扩展名表（`agent-format.ts:53`）：

```ts
export function agentFileExtensionForTool(tool: ToolName): AgentFileExtension {
  switch (tool) {
    case 'copilot': return '.agent.md';
    case 'codex': case 'codex-internal': case 'tcodex': return '.toml';
    case 'kiro': return '.json';
    default: return '.md';
  }
}
```

两个"基础渲染器"被多数工具复用（`agent-format.ts:462`、`:524`）：

```ts
// Markdown 家族：frontmatter = 公共字段 + 私有字段拍平；正文 = instructions
function renderMarkdownAgent(spec, extras?, resolved?) {
  const frontmatterData = { name: spec.name, description: spec.description };
  if (spec.model !== undefined) frontmatterData['model'] = spec.model;
  if (spec.tools?.length) frontmatterData['tools'] = spec.tools;
  Object.assign(frontmatterData, resolved);
  if (extras) for (const [k, v] of Object.entries(extras)) frontmatterData[k] = v; // 私有字段覆盖
  return matter.stringify(spec.instructions, frontmatterData);
}

// TOML 家族（Codex）：instructions 变成 developer_instructions 字段
function renderTomlAgent(spec, extras?, resolved?) {
  const tomlData = { name: spec.name, description: spec.description,
                     developer_instructions: spec.instructions };
  // ... model / resolved / extras 同理
  const rendered = stringifyToml(tomlData);
  // ... 多行字符串改用 TOML 字面量形式，便于阅读
}
```

上面的 reviewer 渲染给 Codex 后大致是：

```toml
# .codex/agents/reviewer.toml
name = "reviewer"
description = "代码评审助手"
developer_instructions = '''
你是一个严格的代码评审者……
'''
sandbox_mode = "read-only"
```

注意 Codex 的 TOML 里**没有** `tools`——`renderTomlAgent` 本来就不输出它，Codex 的 agent 格式里没有这个概念。

一个有意思的特例 `renderForKiro`（`agent-format.ts:249`）：Kiro 的 agent JSON 里能内嵌 hooks，teamai 顺手往 `hooks.agentSpawn` 里塞一条 `teamai hook-dispatch session-start --tool kiro`，同时**先过滤掉旧的 teamai 条目**、保留用户自己的 hook。这说明"资源"和"hook"两个适配维度在某些工具上是交织的。

#### 5.3.3 反向：从工具格式还原 IR（push 用）

用户可能在 Claude 里改了 agent，也可能在 Codex 里改了。push 时要把它们**还原成 AgentSpec**（`src/resources/agents.ts:1821`）：

```ts
function reverseByParser(tool: ToolName, filePath: string, content: string): ReverseResult {
  switch (tool) {
    case 'claude': case 'claude-internal': case 'tclaude': return reverseFromClaude(filePath, content);
    case 'codebuddy': return reverseFromCodebuddy(filePath, content);
    case 'codex': case 'codex-internal': case 'tcodex': return reverseFromCodex(filePath, content);
    // ...
  }
}
```

如果多个工具里都有同一个 agent，`mergeReverseResults`（`agent-format.ts:910`）负责合并：

```ts
export function mergeReverseResults(perTool) {
  // 公共字段（name/description/instructions/...）逐个比较
  for (const field of MERGE_COMMON_FIELDS) {
    const uniqueValues = new Set(Object.values(valuesByTool).map((v) => JSON.stringify(v)));
    if (uniqueValues.size > 1) conflicts.push({ field, values: valuesByTool }); // 不一致 → 报冲突，交给人决定
  }
  if (conflicts.length > 0) return { ok: false, conflicts };
  // 一致 → 取第一份，tool_extras 按工具取并集（各工具私有字段互不干扰）
}
```

**设计取舍**：公共字段冲突不自动合并，而是报给用户——因为自动猜"哪边是对的"风险太大。

### 5.4 MCP：先归"格式族"，再渲染

很多工具的 MCP 配置其实"长得差不多"，所以先把工具归到几个格式族里（`src/resources/mcp-format.ts:18`）：

```ts
export type McpFormat = 'claude' | 'cursor' | 'buddy' | 'codex' | 'opencode' | 'copilot' | 'pi' | 'muse';

const CLAUDE_TOOLS = new Set(['claude', 'claude-internal', 'tclaude', 'qoder', 'qoder-cn', 'kiro', 'zcode', 'omp', 'trae', 'trae-cn']);
const CODEX_TOOLS  = new Set(['codex', 'codex-internal', 'tcodex']);
const BUDDY_TOOLS  = new Set(['codebuddy', 'workbuddy']);
// ...

export function detectMcpFormat(tool: string): McpFormat | null {
  if (tool === 'pi') return 'pi';
  if (tool === 'muse') return 'muse';
  if (CLAUDE_TOOLS.has(tool)) return 'claude';
  if (CURSOR_TOOLS.has(tool)) return 'cursor';
  if (CODEX_TOOLS.has(tool)) return 'codex';
  // ...
  return null;            // 不认识 → 不写（宁缺毋滥）
}
```

10 个工具共用 Claude 格式，这就是"格式族"的价值：**新工具如果兼容 Claude 格式，加进 Set 就完事**。

同一个 `McpServerDef` 在不同族的差异（摘自 `mcp-format.ts:203` 起）：

```ts
function renderClaude(def) {                // { type, command/args/env 或 url/headers }
  const e = { type: def.transport };
  // ...
}
function renderCursor(def) {                // stdio 不写 type；${VAR} 要改写成 ${env:VAR}
  // ...
  e.url = def.url ? toCursorEnvSyntax(def.url) : def.url;
}
function renderCopilot(def) {               // stdio 叫 'local'，并且必须显式写 tools: ['*']
  const e = { type: def.transport === 'stdio' ? 'local' : def.transport, tools: ['*'] };
  // ...
}
// Codex 是 TOML 的 [mcp_servers.<name>] 表，单独由 renderCodexBlock 处理
```

还有**能力表**：不是每个工具都支持每种传输方式（`mcp-format.ts:62`）：

```ts
const SUPPORTED_TRANSPORTS: Record<McpFormat, Set<McpTransport>> = {
  claude: new Set(['stdio', 'http', 'sse']),
  codex:  new Set(['stdio', 'http']),   // Codex 没有 SSE
  muse:   new Set(['stdio', 'http']),   // Muse 遇到一个 sse 会导致所有 MCP 都加载失败
  // ...
};
```

不支持的就跳过这个 server，而不是写进去把工具弄坏。**"能力声明表"是适配层处理"工具能力不对等"的通用手段**，后面 hooks 里的 `STOP_STDOUT_TOOLS`、`SUBAGENT_STOP_TOOLS` 也是同一个思路。

### 5.5 Hooks：最复杂的适配

hooks 是适配层里差异最大的一块，因为它不只是"写一个文件"，还决定了**运行时工具怎么回调 teamai**。

#### 5.5.1 第一步：生成"统一的命令"

不管什么工具，teamai 装进去的 hook 命令长得都一样（`src/builtin-hooks.ts:215`）：

```ts
export function getDispatchCommand(event: string, tool: string, matcher?: string, binPath?: string): string {
  const bin = binPath ?? 'teamai';
  const matcherArg = matcher && matcher !== '*' ? ` --matcher ${matcher}` : '';
  const shell = isCodexTool(tool) ? 'bash' : getHookShellCommand();  // Windows 上会解析成 Git Bash 路径
  return `${shell} -lc "${bin} hook-dispatch ${event} --tool ${tool}${matcherArg} 2>/dev/null" || true`;
}
// 例：bash -lc "teamai hook-dispatch session-start --tool cursor 2>/dev/null" || true
```

拆开看每一部分的用意：

- `bash -lc`：用登录 shell，确保能读到用户 PATH，找到 `teamai`
- `--tool cursor`：**把"我是谁"写死在命令里**，运行时 teamai 就知道该用哪套输入/输出规则
- `2>/dev/null` 和 `|| true`：teamai 出任何错都不能影响 AI 工具本身

这就是"一个入口"的设计：所有工具最终都调用 `teamai hook-dispatch`，差异只在参数。

几个变体（同一文件）：

- `getTeamHookDispatchCommand`（`:253`）：团队自定义 hook，**保留** stderr 和退出码，因为退出码 2 代表"阻断"
- `getRawDispatchCommand`（`:263`）：不带 shell 包装，给 ZCode 用（它的 hook 是 argv 数组）
- GUI 工具（WorkBuddy/CodeBuddy）用 wrapper 脚本，因为从 GUI 启动拿不到完整 PATH（`SHELL_DEPENDENT_TOOLS`，`:44`）

#### 5.5.2 第二步：统一的 hook 定义 `HookDef`

内置 hook 规格是一张表（`builtin-hooks.ts:316`）：

```ts
const BUILTIN_HOOK_SPECS: BuiltinHookSpec[] = [
  { key: 'Hook dispatch session-start', event: 'SessionStart', dispatchEvent: 'session-start', matcher: '*', timeoutSec: 15 },
  { key: 'Hook dispatch stop',          event: 'Stop',         dispatchEvent: 'stop',          matcher: '*', timeoutSec: 15 },
  { key: 'Hook dispatch post-tool-use wildcard', event: 'PostToolUse', dispatchEvent: 'post-tool-use', matcher: '*', timeoutSec: 10 },
  { key: 'Hook dispatch post-tool-use Skill',    event: 'PostToolUse', dispatchEvent: 'post-tool-use', matcher: 'Skill', timeoutSec: 10 },
  // ... TodoWrite / prompt-submit
];
```

事件名统一用 Claude 的 PascalCase 作为"标准语言"。`builtinHookDefs(tool)`（`:392`）根据工具做增减，同样是查表：

```ts
// Skill 工具在不同工具里叫法不同
const SKILL_TOOL_MATCHER = { cursor: 'Read', copilot: 'skill', muse: 'read_skill' };
// 只有这些工具支持 SubagentStop 并带父会话 id
const SUBAGENT_STOP_TOOLS = new Set(['claude', 'claude-internal', 'tclaude', ...CODEX_TOOL_IDS, 'codebuddy', 'qoder', 'qoder-cn']);
// SubagentStart 只给 Codex；SessionEnd 只给 Copilot
```

#### 5.5.3 第三步：按"格式族"写进不同形状的文件

先识别格式（`src/hooks.ts:202`、`:215`）：

```ts
type ToolFormat = 'claude' | 'cursor' | 'codex' | 'copilot' | 'zcode';

function detectFormat(tool: string): ToolFormat {
  if (tool === COPILOT_TOOL_ID) return 'copilot';
  if (CODEX_FORMAT_TOOLS.has(tool)) return 'codex';   // codex 全家 + muse
  if (ZCODE_TOOLS.has(tool)) return 'zcode';
  return CURSOR_TOOLS.has(tool) ? 'cursor' : 'claude'; // 默认按 Claude
}
```

再用 TypeScript 接口把每种磁盘形状写清楚（`hooks.ts:95-186`），这是最好的"格式说明书"：

```ts
interface HookMatcher        { matcher: string; hooks: HookEntry[]; description?: string }     // Claude
interface CursorHookEntry    { command: string; timeout?: number; matcher?: string }          // Cursor：扁平，无 description
interface CodexHookEntry     { type: string; command: string; commandWindows?: string; timeout?: number } // Codex：Windows 单独一条命令
interface CopilotHookEntry   { type: 'command'; bash: string; powershell: string; command: string; timeoutSec?: number } // Copilot
interface ZcodeHookEntry     { type: string; command: string; args?: string[]; timeoutMs?: number } // ZCode：毫秒
```

每种形状一个转换函数（`hooks.ts:1500` 起）：

```ts
function toClaudeEntry(def: HookDef): HookMatcher {
  return {
    matcher: def.matcher ?? '*',
    hooks: [{ type: 'command', command: def.command, ...(def.timeout !== undefined ? { timeout: def.timeout } : {}) }],
    description: def.description,     // Claude 有 description，teamai 用它做标记
  };
}

function toCursorEntry(def: HookDef): CursorHookEntry {
  const entry: CursorHookEntry = { command: def.command };
  if (def.timeout !== undefined) entry.timeout = def.timeout;
  if (def.matcher && def.matcher !== '*') entry.matcher = def.matcher;   // 通配符直接省略
  return entry;
}

function toCopilotEntry(def: HookDef, globalSource?: string): CopilotHookEntry {
  // ...
  return {
    type: 'command',
    bash: command,
    powershell: copilotPowershellCommand(command),   // 把 `bash -lc "..." || true` 改写成 `...; exit 0`
    command,
    ...(def.matcher && def.matcher !== '*' ? { matcher: def.matcher } : {}),
    ...(def.timeout !== undefined ? { timeoutSec: def.timeout } : {}),  // 字段名都不一样
  };
}
```

事件名映射表（`hooks.ts:72`）：

```ts
export const CLAUDE_TO_CURSOR_EVENTS = {
  SessionStart: 'sessionStart',
  Stop: 'stop',
  PostToolUse: 'postToolUse',
  UserPromptSubmit: 'beforeSubmitPrompt',  // 不只是大小写，连名字都不同
};
```

最后由 `reconcileHooks`（`hooks.ts:2468`）按格式分发：

```ts
const format = detectFormat(tool);
if (format === 'cursor')       await reconcileCursorFormat(settingsPath, tool, scopedDefs, opts, priorTeamCommands, isHeld);
else if (format === 'copilot') await reconcileCopilotFormat(/* ... */);
else if (format === 'codex')   codexRecords = await reconcileCodexFormat(/* ... */);
else if (format === 'zcode')   await reconcileZcodeFormat(/* ... */);
else                           await reconcileClaudeFormat(/* ... */);
```

#### 5.5.4 "这条 hook 是我写的吗？"——标记与 manifest

settings 文件是**用户和 teamai 共用的**，teamai 只能改自己的条目。怎么认出自己的？`hooks.ts:188` 的注释说明了两种手段：

```
- 内置 hook：description 以 "[teamai] " 开头 / command 匹配 hook-dispatch
- 团队 hook：description 以 "[teamai:hook:<id>]" 开头
- Cursor 和 Codex 的 hooks 文件没有 description 字段 → 改用 managed-hooks manifest（旁路记账文件）
```

也就是说：**工具格式支持打标记就打标记，不支持就在外面记账**。同一段注释还强调 reconcile 是**幂等**的，只在内容真正变化时才写盘——升级 CLI 后重复执行，文件零 diff。

#### 5.5.5 没有 hook 配置文件的工具：插件型适配器

有些工具根本没有"settings.json 里写一条命令"的机制。`reconcileHooksToAllTools`（`hooks.ts:2972`）在主循环里把它们分流出去：

```ts
for (const [tool, paths] of Object.entries(toolPaths)) {
  if (tool === 'hermes')   { /* config.yaml + 脚本目录 + 白名单 → hermes-hooks.ts */ continue; }
  if (tool === 'openclaw') { /* HOOK.md + handler.ts      → openclaw-hooks.ts */ continue; }
  if (tool === 'opencode') { await reconcileOpencodePlugin(baseDir, opts.removeAll, opts.installedBaseDir); continue; }
  // OMP / Pi / DSH 同理……
  // 其余工具 → reconcileHooks(settingsPath, tool, ...) 走 5.5.3 的通用路径
}
```

以 OpenCode 为例（`src/opencode-hooks.ts`）。它只会自动加载 `.opencode/plugin/*.ts`，所以 teamai **生成一个 TS 插件**，订阅 OpenCode 自己的事件，再转调同一个 `teamai hook-dispatch`：

```
OpenCode 事件             →  teamai dispatch 事件
session.created          →  session-start
session.idle             →  stop
chat.message             →  prompt-submit
tool.execute.after       →  post-tool-use
```

生成的插件源码里（`opencode-hooks.ts:94` `buildPluginSource`）有两座"桥"：

```js
/** OpenCode 小写工具 id → Claude 风格的 matcher 名 */
const TOOL_MATCHER = { skill: 'Skill', todowrite: 'TodoWrite' };

const TeamaiHooks = async ({ directory, worktree }) => {
  const cwd = directory || worktree;
  const dispatch = async (event, matcher, payload) => {
    // spawn('teamai', ['hook-dispatch', event, '--tool', 'opencode', ...])
    // 通过 STDIN 喂和其他工具一样的 JSON：cwd / tool_name / tool_input / prompt / session_id
  };
  // ...
};
```

**这就是适配器模式最直观的样子**：OpenCode 的事件模型和 Claude 完全不同，但插件把它"翻译"成了 Claude 风格的 STDIN JSON，下游 handler 一行都不用改。

注释里还诚实记录了一个限制：OpenCode 的 `event` hook 没有把 stdout 注回会话的通道，所以这个插件是"只为副作用而跑"，无法像 Claude 那样往对话里注入提示。

---

## 6. 第④层：运行时归一化 —— 把"各说各话"的输入翻译成一种语言

工具触发 hook 后，进入 `teamai hook-dispatch <event> --tool <tool>`（`src/hook-dispatch-cli.ts:416`）。在交给与工具无关的 dispatcher 之前，有几道归一化。

### 6.1 事件名补全

有的工具 STDIN 里不带 `hook_event_name`，就用 CLI 参数补上（`hook-dispatch-cli.ts:340` `parseStdin`）：

```ts
if (!stdin.hook_event_name) {
  const EVENT_MAP: Record<string, string> = {
    'session-start': 'SessionStart',
    'session-end': 'SessionEnd',
    'stop': 'Stop',
    // ...
    'post-tool-use': 'PostToolUse',
    'prompt-submit': 'UserPromptSubmit',
  };
  stdin.hook_event_name = EVENT_MAP[event] ?? event;
}
const cwd = resolveHookCwd(stdin);
if (cwd) stdin.cwd = cwd;
```

### 6.2 工作目录归一化

Cursor 的 SessionStart 不发 `cwd`，而是发 `workspace_roots`，并且进程的 cwd 是 `~/.cursor`（`src/utils/hook-cwd.ts:9`）：

```ts
export function resolveHookCwd(data: Record<string, unknown>): string | undefined {
  if (typeof data.cwd === 'string') {
    const trimmed = data.cwd.trim();
    if (trimmed) return trimmed;          // 空字符串当作没有（Cursor 某些事件会发空串）
  }
  const roots = data.workspace_roots;
  if (!Array.isArray(roots)) return undefined;
  for (const root of roots) {
    if (typeof root === 'string' && root.trim()) return root.trim();
  }
  return undefined;
}
```

cwd 很关键：teamai 靠它判断"当前在哪个项目"，进而加载项目级配置。拿错了就会用错团队配置。

### 6.3 工具名归一化

CodeBuddy IDE 传的工具名是 `execute_command`、`read_file`，而 handler 认的是 Claude 风格的 `Bash`、`Read`（`src/utils/tool-names.ts:11`）：

```ts
const IDE_TO_CLI: Record<string, string> = {
  execute_command: 'Bash',
  search_content: 'Grep',
  write_to_file: 'Write',
  replace_in_file: 'Edit',
  read_file: 'Read',
  skill: 'Skill',
  read_skill: 'Skill', // Muse Code
  // ...
};
export function normalizeToolName(name: string): string {
  return IDE_TO_CLI[name] ?? name;
}

// 内部版本 / 变体归到同一家族
const AGENT_TYPE_ALIASES = { tcodex: 'codex', 'codex-internal': 'codex', tclaude: 'claude', 'claude-internal': 'claude' };
```

### 6.4 输出适配：同一条消息，不同的回传方式

Stop 时 teamai 可能想提示"这次会话有值得分享的经验"。但各工具对 Stop 输出的处理完全不同：

**能力表**（`tool-names.ts:72`）——只有确认过的工具才在白名单里：

```ts
const STOP_STDOUT_TOOLS = new Set<string>([
  'claude', 'claude-internal', 'tclaude', 'cursor', 'copilot',
  'qoder', 'qoder-cn', 'zcode', 'omp', 'pi', 'opencode', 'dsh',
]);
export function stopStdoutUnsupported(tool: string | undefined): boolean {
  return !STOP_STDOUT_TOOLS.has((tool ?? 'claude').toLowerCase());
}
```

不在名单里的（CodeBuddy/WorkBuddy 忽略 Stop 输出；Codex/Muse 拒绝 Stop 的 additionalContext）→ 把消息**暂存**，等下一次 `UserPromptSubmit` 再注入。注释解释了为什么用白名单而不是黑名单：漏掉一个工具，最坏是提示晚一轮；错放进名单，提示就直接丢了。**对不确定的情况选"代价小的那边"**。

**格式**（`src/utils/hook-output.ts:54`）：

```ts
export function formatStopHookOutput(message: string, tool: string): string {
  if (tool?.toLowerCase() === 'cursor') {
    return JSON.stringify({ followup_message: message });            // Cursor 的协议
  }
  return JSON.stringify({
    hookSpecificOutput: { hookEventName: 'Stop', additionalContext: message }, // Claude 的协议
  });
}
```

同文件的 `relayWhenHidden` 还处理了一个细节：Cursor 把 `followup_message` 只给模型、不给用户看，所以要加一句"请把下面这段原样告诉用户"。

### 6.5 归一化之后

经过上面几步，所有工具的输入都变成了"Claude 风格的 STDIN JSON + 标准事件名 + 正确的 cwd"。之后的 `createDispatcher`（`src/hook-dispatch.ts`）按 `event + matcher` 匹配 handler，**handler 代码里基本不需要关心是哪个工具**。这就是第④层存在的意义。

---

## 7. 串起来：一条规则的完整旅程

假设团队有 `rules/api-style.md`，成员机器上装了 Claude、Cursor、Codex，scope 为 project。

```
teamai pull
 └─ pullForScope()
     └─ for handler of getAllHandlers()          ← 第②层，不知道有哪些工具
         └─ RulesHandler.pullItem(api-style)
             └─ deliveryTargets()                ← 只读解析
                 for tool of scopedToolPaths()   ← 第①层
                   claude : 有 rules、已安装 → dest=.claude/rules/api-style.md
                            renderRuleForTool('claude') → 无 RuleFormat → 原样
                   cursor : 有 rules、已安装 → dest=.cursor/rules/api-style.mdc
                            renderRuleForTool('cursor') → CURSOR_MDC_FORMAT.render ← 第③层
                   codex  : toolPaths.codex 没有 rules → 跳过
             └─ 按 targets 写盘，记入 ledger

（之后，Codex 会话启动）
bash -lc "teamai hook-dispatch session-start --tool codex"
 └─ parseStdin / resolveHookCwd                  ← 第④层
 └─ teamRulesHandler：codex ∈ SESSION_HOOK_RULE_TOOLS
     → 把团队规则作为 additionalContext 输出给 Codex
```

三个工具、三种拿到规则的方式，但团队只维护了一个 `.md` 文件。

Codex 那一步对应的 handler 在 `src/hook-handlers.ts:940`（`teamRulesHandler`）：只在 project scope、非 resume 会话、且 `getsRulesFromSessionHook(tool)` 为真时才输出。

---

## 8. 设计思想总结（可以直接用来答面试）

| 思想 | 在代码里的体现 |
| --- | --- |
| **中间表示（IR）** | 团队仓库存中立格式：rule `.md`、`AgentSpec` YAML、`HookDef`、`McpServerDef`；N 个工具只需 N 个转换器，而不是 N×N |
| **策略模式 + 注册表** | `handlers` 注册表、`RULE_FORMATS`、`renderForTool` 的 switch、`detectFormat` / `detectMcpFormat` |
| **数据驱动优于条件分支** | `KNOWN_AGENTS`、`toolPaths`、`CLAUDE_TO_CURSOR_EVENTS`、`IDE_TO_CLI`、`SKILL_TOOL_MATCHER` |
| **能力声明表** | `SUPPORTED_TRANSPORTS`、`STOP_STDOUT_TOOLS`、`SUBAGENT_STOP_TOOLS`、`SESSION_HOOK_RULE_TOOLS`；字段缺失 = 不支持 |
| **单一出口 / 只读解析** | `deliveryTargets` 只读，pull 和 doctor 共用；`renderRuleForTool` 是规则翻译唯一入口 |
| **适配器模式** | OpenCode/OpenClaw/Hermes 没有 hook 配置，就生成插件把它们的事件翻成统一 STDIN |
| **最小所有权** | 只改自己的条目：`[teamai]` 标记、`[teamai:hook:<id>]`、`<!-- [teamai:xxx:start] -->` 受管块、manifest 旁路记账 |
| **幂等** | reconcile 只在内容变化时写；重复执行零 diff |
| **安全的默认值** | 没装不建目录；不认识的 MCP 格式不写；`resolveBaseDir` 缺 projectRoot 宁可报错；能力白名单宁小勿大 |
| **保护用户修改** | ledger 记录投递 hash，改过的副本保留；agent 反向合并有冲突交给人 |
| **故障隔离** | 每个工具一个 try/catch；hook 命令 `2>/dev/null \|\| true` 永不拖垮宿主 |
| **可迁移** | `previousRenders`、`LEGACY_RULE_DIRS`、legacy manifest 迁移，老版本写的东西也能认领清理 |

一句话版本：**用"中间格式 + 按工具查表的转换器"把 N×M（工具 × 资源类型）的组合复杂度，降成 N + M 的线性复杂度。**

---

## 9. 如果要新接入一个工具，要改哪些地方？

按需选做，不是每项都要（工具不支持的资源就不配）：

1. `src/known-agents.ts`：`KNOWN_AGENTS` 加一行（id、显示名、skills 路径）
2. `src/types.ts`：`toolPaths` 默认值加一项，**只填验证过的路径**
3. 安装判断特殊？→ `resources/base.ts` 的 `INSTALL_ROOTS` / `HOME_INSTALL_ROOTS` / `EDITION_HOME_ROOTS`
4. 规则有自己的格式？→ 写一个 `xxx-rule.ts` 导出 `RuleFormat`，在 `RULE_FORMATS` 加一项；没有规则目录？→ 加到 `SESSION_HOOK_RULE_TOOLS` 或走用户级指令块
5. 子 agent：`agent-format.ts` 的 `ToolName`、`ALL_SUPPORTED_TOOLS`、`agentFileExtensionForTool`、`renderForTool`，以及 `agents.ts` 的 `reverseByParser`
6. MCP：兼容某个格式族就加进对应 Set；否则在 `mcp-format.ts` 新增渲染函数和 `SUPPORTED_TRANSPORTS`
7. Hooks：settings 型 → 看能否归入 `detectFormat` 的现有格式；插件型 → 仿照 `opencode-hooks.ts` 写适配器，并在 `reconcileHooksToAllTools` 分流
8. 运行时：工具名特殊 → `IDE_TO_CLI`；Stop 输出确认可用 → 加入 `STOP_STDOUT_TOOLS`
9. 测试：`src/__tests__/` 下找同类工具的测试照抄；按 AGENTS.md 要求，改了运行时行为还要做一次真实 CLI 验证

真实的参考：`git log --oneline -- src/resources/kiro-steering.ts` 或搜 `#946`、`#938` 相关提交，看别人是怎么一步步接入的。

---

## 10. 推荐阅读顺序与动手练习

**阅读顺序**（由浅入深，每步 15~30 分钟）：

1. `src/known-agents.ts` 前 135 行 —— 认识有哪些工具
2. `src/types.ts:15-60`（ToolPathsSchema）和 `:461-560`（toolPaths 默认值）—— 读注释，里面全是"为什么"
3. `src/resources/base.ts` 全文（240 行）—— 抽象类和安装门禁
4. `src/resources/rule-format.ts` + `cursor-mdc.ts` —— 最清晰的策略模式样板
5. `src/resources/agent-format.ts:1-300` 和 `:1024` —— IR + 渲染
6. `src/resources/mcp-format.ts:1-90`、`:200-330` —— 格式族
7. `src/hooks.ts:60-230`（形状定义 + detectFormat）、`:1500-1600`（toXxxEntry）、`:2468`（reconcileHooks）
8. `src/opencode-hooks.ts:1-120` —— 插件型适配器
9. `src/utils/{hook-cwd,tool-names,hook-output}.ts` —— 运行时归一化，三个文件加起来不到 200 行

**动手练习**（只读 / 本地实验，不改源码）：

```bash
# 1. 看 Cursor 规则渲染的单元测试，理解输入输出
npx vitest run cursor-mdc

# 2. 找出所有"能力表"，体会数据驱动
grep -rn "new Set(\[" src/resources/rule-format.ts src/resources/mcp-format.ts src/utils/tool-names.ts src/builtin-hooks.ts

# 3. 模拟 Cursor 发来的 SessionStart（没有 cwd，只有 workspace_roots）
#    注意：session-start 会在后台触发真实的 pull
echo '{"workspace_roots":["'"$PWD"'"],"session_id":"test"}' \
  | teamai --verbose hook-dispatch session-start --tool cursor

# 4. 在一个测试项目里 init 后，对比三个工具收到的同一条规则
diff .claude/rules/xxx.md .cursor/rules/xxx.mdc
```

> 练习 1 需要先 `npm install`（对应测试 `src/__tests__/cursor-mdc.test.ts`；规则格式升级的端到端行为可看 `pull-rule-format-upgrade.test.ts`）。练习 3 用全局安装的 teamai 也行，但全局版本 0.27.0 和源码 0.22.0 不一致，行为可能有差异。

---

## 11. 自测问题

1. 为什么 Codex 的 `toolPaths` 里故意不配 `rules`？那它怎么拿到团队规则？
2. `deliveryTargets` 为什么必须是只读的？如果 pull 和 doctor 各写一套路径解析，会出什么 bug？
3. Cursor 的 hooks 文件没有 `description` 字段，teamai 怎么区分哪些条目是自己写的？
4. 团队规则从 `.md` 转 `.mdc`，push 回去时为什么只同步正文、不同步 frontmatter？
5. `STOP_STDOUT_TOOLS` 为什么是白名单而不是黑名单？
6. 一个新工具 MCP 格式和 Claude 一模一样，最少改几行代码就能支持？
7. OpenCode 没有 hook 配置文件，teamai 是怎么让它也能触发 `hook-dispatch` 的？有什么能力上的损失？

（答案都在上文对应章节里。）

