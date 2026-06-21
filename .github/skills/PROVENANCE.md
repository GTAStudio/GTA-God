# Skills 溯源与安全审计台账

本目录下的 Agent Skills（`<name>/SKILL.md`）部分来自外部开源仓库。按项目「安装前必须核查后门/恶意内容」的强约束，所有外部引入的 skill 在落地前都经过审计，结论记录于此，保证供应链可溯源。

## 审计方法

1. 经本地代理 `http://127.0.0.1:2080` 将来源仓库浅克隆（sparse）到隔离区 `/.quarantine`（已 gitignore），**不直接安装**。
2. 列出每个 skill 的全部文件与大小，确认**有无脚本/可执行文件**（`.py`/`.sh`/`.ps1`/`.js` 等）。
3. 逐文件审计 `SKILL.md` 与 references：排查提示注入、数据外泄、自动执行破坏性/联网命令、隐藏指令。
4. 仅复制审计通过的 skill 目录到 `.github/skills/`；审计后删除隔离区。

## 已安装 skill 来源与审计结论

| skill | 来源 | 类型 | 含可执行脚本 | 审计结论 |
|---|---|---|---|---|
| `security-review` | [github/awesome-copilot](https://github.com/github/awesome-copilot) `skills/security-review` | 纯 Markdown + references | 否 | ✅ 通过。防御性安全审查指南；明确「绝不自动应用补丁，须人工审阅」，与本项目操作安全约束一致。 |
| `agent-supply-chain` | github/awesome-copilot `skills/agent-supply-chain` | 纯 Markdown（内含示例 Python 片段） | 否（片段仅 SHA-256 哈希/只读审计，非自动执行） | ✅ 通过。供应链完整性（INTEGRITY.json 生成/校验、依赖钉版审计）。直接支撑本审计流程本身。 |
| `dependabot` | github/awesome-copilot `skills/dependabot` | 纯 Markdown + references | 否 | ✅ 通过。Dependabot 配置/分组/安全更新指南，支撑依赖现代化与供应链安全。 |
| `microsoft-skill-creator` | github/awesome-copilot `skills/microsoft-skill-creator` | 纯 Markdown + references | 否 | ✅ 通过（含可选项注记）。指导规范地创作新 skill。注：可选引用 `npx @microsoft/learn-cli` 与 Microsoft Learn MCP——属可选外部工具，使用前按 Pre-flight 门核实，不强制安装。 |
| `apple-appstore-reviewer` | github/awesome-copilot `skills/apple-appstore-reviewer` | 纯 Markdown | 否 | ✅ 通过。App Store 提审前只读自查（拒审风险/合规）；明确「首轮不改任何代码」。 |
| `create-architectural-decision-record` | github/awesome-copilot `skills/create-architectural-decision-record` | 纯 Markdown（单文件） | 否 | ✅ 通过。ADR 生成模板，输出到 `docs/adr/adr-NNNN-*.md`；与 Architect 的 ADR 交付物直接对齐。原文逐字落地。 |
| `agent-owasp-compliance` | github/awesome-copilot `skills/agent-owasp-compliance` | 纯 Markdown（内含只读 Python 示例片段） | 否（片段仅正则扫描/只读，非自动执行） | ✅ 通过。OWASP ASI Top 10（AI Agent 专属安全风险）合规自查；**正好用于审计本仓库自身的 22-agent 体系**（工具白名单/能力边界/供应链完整性/审计日志）。原文逐字落地。 |

> 来源仓库 **github/awesome-copilot** 为 GitHub 官方维护的 Copilot 定制合集（高星、活跃维护），本身可信度高；即便如此仍逐文件审计后才安装。

## 审计后未安装（裁决记录）

| 候选 skill | 来源 | 裁决 | 理由 |
|---|---|---|---|
| `threat-model-analyst` | github/awesome-copilot | ⏸ 缓装 | 纯 Markdown、无可执行脚本，内容安全（STRIDE-A + DFD）；但为多文件 skill（`references/` + `skeletons/` 约 15 个文件），且与已装 `security-review` 部分重叠。仅部分安装会产生断链引用，须整体 vendoring；列入下轮完整引入候选。 |
| `winmd-api-search` | github/awesome-copilot | ❌ 拒绝 | （1）含需 .NET SDK 8 构建缓存生成器的 PowerShell 可执行脚本（`Update-WinMdCache.ps1`/`Invoke-WinMdQuery.ps1`），超出纯 Markdown skill 的供应链面；（2）面向 WinRT/WinAppSDK/.NET API 发现，**与本项目 Rust + Slint 桌面栈无关**。 |

## 既有本地 skill

| skill | 说明 |
|---|---|
| `codeql` | CodeQL 代码扫描配置（来自 awesome-copilot，早前引入）。 |
| `secret-scanning` | GHAS 机密扫描（来自 awesome-copilot）。 |
| `conventional-commit` | 规范化提交信息。**本地审计修订**：已移除上游「自动 `git commit` 无需确认」条款，以符合本项目「难逆操作须显式确认」红线。 |
| `network-troubleshoot` | 网络排障。 |

## 语言最佳实践覆盖（`.github/instructions/`）

GitHub 官方合集中**没有** Kotlin/Android、Swift/iOS/macOS、Windows 桌面的语言级最佳实践 *skill*（其语言指南位于 `instructions/`，且未覆盖上述栈）。因此按本仓库既有约定，以 `instructions/` 形式补齐，并内嵌「联网核实最新官方文档」前置门：

- `rust.instructions.md`、`go.instructions.md`（既有）
- `kotlin-android.instructions.md`、`swift-apple.instructions.md`、`powershell.instructions.md`（本次新增）

## 维护约定

- 新增外部 skill 必须走上述隔离审计流程，并在本表登记来源 + 结论。
- 周期性用 `suggest-awesome-github-copilot-skills` 思路比对上游更新；升级前重新审计 diff。
- skill 治理（发现/审计/登记）归口 `Docs & Memory Curator`。
