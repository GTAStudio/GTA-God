---
description: 'Windows PowerShell 脚本与桌面打包/签名最佳实践（构建与 DevOps 用途）'
applyTo: '**/*.ps1,**/*.psm1,**/*.psd1'
---

# PowerShell / Windows 脚本与分发约定

> **Pre-flight 强制门（继承自 [copilot-instructions.md](../copilot-instructions.md)）**：涉及 Windows 构建链/签名/打包前，经本地代理 `http://127.0.0.1:2080` 联网核实 **PowerShell、Authenticode/signtool、Windows 分发**的官方最新文档与推荐做法。**具体版本号以联网核实结果为准。**

参考来源：[PowerShell 文档](https://learn.microsoft.com/powershell/)、[Strongly Encouraged Development Guidelines](https://learn.microsoft.com/powershell/scripting/developer/cmdlet/strongly-encouraged-development-guidelines)、[SignTool](https://learn.microsoft.com/windows/win32/seccrypto/signtool)。

## 红线（项目强约束）

- **严禁用 PowerShell 编辑/生成项目文件**（`Out-File`、`Set-Content`、`echo >`、`>>`）——会破坏 UTF-8/中文/BOM。文件改动一律用编辑器工具。本指令仅适用于**构建/DevOps 自动化脚本**本身。
- 联网命令前先导出代理环境变量（`HTTP_PROXY`/`HTTPS_PROXY`/`ALL_PROXY` 及小写、`CARGO_HTTP_PROXY`），全部经 `http://127.0.0.1:2080`，不得直连。
- PowerShell 管道退出码不可靠：判断成功看实际产物/`Finished`/`test result:` 输出，不要只看 `$?`。

## 脚本约定

- 脚本顶部加 `Set-StrictMode -Version Latest` 与 `$ErrorActionPreference = 'Stop'`，让错误尽早暴露。
- 用完整 cmdlet 名（`Get-ChildItem` 而非 `ls`/`dir`），用 approved verbs（`Get-`/`Set-`/`New-`/`Invoke-`）。
- 参数用 `[CmdletBinding()]` + 类型化 `param()` + 校验属性（`[ValidateNotNullOrEmpty()]` 等）；带空格路径必须加引号。
- 优先对象管道而非文本解析；输出用 `Write-Output`，诊断用 `Write-Verbose`/`Write-Error`，不要 `Write-Host` 当数据通道。
- 不在脚本内明文凭据/口令；经环境变量或 Windows 凭据管理器/CI secret 注入，日志不打印机密。
- 难逆/破坏性操作（删除、`git push --force`、`Remove-Item -Recurse`）需显式确认，不做隐式兜底。

## Windows 桌面分发（配合 Slint / Rust 产物）

- release 二进制用 **Authenticode（signtool）** 签名并加可信时间戳（RFC 3161）；签名后用 `signtool verify /pa` 校验。
- 证书/口令经 CI secret 注入、绝不入库；可选 MSIX/installer 打包遵循各自最新规范。
- 跨平台产物保持可复现：固定工具链版本、记录构建环境。

## 技术债

- 遇到过时写法（`Invoke-Expression` 拼接、未校验的外部输入、`Write-Host` 当返回值）优先重构为安全惯用法，并在 `docs/` 记录依据。
