# 平行工作台（多模型平行比较工作台）

> **你是哪个平台？**
> - 🖥️ **macOS 用户** → 看 [`macOS/`](macOS/README.md) 目录（一键安装：`curl -fsSL https://raw.githubusercontent.com/HanchengQiao/parallel-workshop/main/install.sh | bash`）
> - 🪟 **Windows 用户** → 看 [`Windows/`](Windows/README.md) 目录（下载 `edge-extension.zip` 侧载到 Edge）
> - 两个目录各自独立完整，**fork/下载时请按你的平台选择对应目录**

> **发布状态：** v0.2.0 已标记为预发布，存在 Edge/DeepSeek 微信扫码回调缺陷。`main` 已包含修复，新的稳定资产将在双端回归完成后以 v0.2.1 发布；在此之前请勿向普通用户推荐 v0.2.0。

---

多模型平行问答工作台：一个窗口平行排布多个 AI 平台的官方网页客户端，顶部统一输入框一键同步发送（⌘↩），回答在各平台原生界面中平行展示。

## 核心设计

- **不调 API、无付费依赖**：嵌入各平台官方网页客户端
- **登录态持久（应用内）**：macOS 版使用应用自带的 WebKit 持久存储（`~/Library/WebKit/ParallelWorkbench`），登录请在工作台窗格内完成（登录围栏保证不出框），每个平台登录一次后持久；Windows/Edge 版与浏览器共享登录态
- **登录态备份/恢复**：`--backup-auth` / `--restore-auth`，防应用存储损坏/系统重装导致全部登录失效（已实战验证）
- **脱离谷歌生态**：macOS 原生 SwiftUI 应用；Windows 侧后续走 Edge 扩展（微软生态），共享本仓库 adapter/injection 核心
- **不提供代理服务**：国际平台走用户系统里已有的代理环境
- **风险管控**：不自动化任何登录/验证流程（人工在 pane 内完成）；注入只做「定位输入框→设值→发送」，不轮询、不自动重试

## 安装（下一个稳定版发布后）

开源仓库发布后（见 `RELEASE.md`），用户可选任一种方式安装：

```sh
# macOS：从最新稳定 Release 下载、强制校验 SHA-256 后原子安装；当前修复阶段会拒绝安装预发布版
curl -fsSL https://raw.githubusercontent.com/HanchengQiao/parallel-workshop/main/install.sh | bash
```

> 未签名开源分发：install.sh 校验 GitHub 资产摘要后安装并移除隔离属性；正式对外分发仍建议签名公证。npm 包和 Homebrew tap 尚未发布，因此不再宣传对应命令。

## 运行（开发者）

```sh
cd parallel-workbench
swift build && open -n .build/arm64-apple-macosx/debug/ParallelWorkbench
# 或 swift run ParallelWorkbench
```

每个 pane 有独立标题栏：平台名、状态角标（绿=就绪 / 橙=未登录 / 红=需验证或不可达 / 紫=未找到输入框）、放大/缩小按钮（登录或读长回答时放大该 pane）、刷新按钮、发送结果反馈提示（5 秒自动消失）。

## 无人值守验收测试

```sh
swift run WorkbenchTester [--probe-only] [--only=id1,id2] [--cookies] [--backup-auth] [--restore-auth] [问题文本]
```

- 默认对全部平台：加载官网 → 输入框就绪 → 自动注入发送 → 取证（消息气泡/输入框清空/回答标志/回答原文）+ 截图到 `test-output/`
- `--probe-only`：只取证不发送（输入框候选/全部按钮/登录入口/编辑器结构/链接清单/页面文本）
- `--only=deepseek,kimi`：只测指定平台；`--cookies`：各平台登录 cookie 审计
- `--attach=文件路径 --attach-only`：附件接受度验收（注入附件不发送，取证输入框状态/文件名是否出现在页面）——macOS 侧逐平台附件矩阵
- Edge 侧逐平台附件矩阵：`node scripts/edge-attach-matrix.mjs [扩展ID] [--full]`（--full 才做全平台真实发送）

**⚠️ 运营规则：测试器与 GUI 同名（ParallelWorkbench）共享 WebKit 数据目录，禁止并发运行**（测试器有单实例守护自动拒绝）。先退 GUI 再跑测试，测完再启 GUI。

## 验收记录（自动测试）

| 平台 | 状态 | 发送机制 | 证据 |
|---|---|---|---|
| DeepSeek | ✅ 通过 | 合成回车 | 输入框清空、回答"我是DeepSeek，随时为你答疑解惑。" |
| Kimi | ✅ 通过 | 点击 `div.send-button-container` | 输入框清空、回答"我是Kimi，由月之暗面开发的AI助手。" |
| ChatGPT | ✅ 通过（游客） | 点击 `button[aria-label='Send message']` | 回答标志"ChatGPT said"出现 |
| 通义千问 | ✅ 通过 | 预动作「新建对话」+ 指针事件序列点发送 | 消息气泡 + 自动会话标题 |
| 文心一言 | ✅ 通过（游客模式） | 合成回车 | 输入框清空、回答"我是百度自研的文心助手，随时为你服务~" |

## 结构

```
Sources/
├── WorkbenchCore/              # 核心库（GUI 与测试器共享）
│   ├── Adapter.swift           # 适配器模型（input/send/probe/verify/prepare）
│   ├── InjectionScripts.swift  # 脚本模板加载与 __CFG__ 注入
│   ├── PaneController.swift    # WKWebView 注入引擎、状态探测、测试辅助
│   ├── Resources.swift         # 资源根目录多路回退定位
│   └── Resources/
│       ├── adapters/*.json     # 每平台一份适配器配置
│       └── injection/*.js      # 纯 JS 注入/探测核心（异步，适配 React/Slate/Lexical）
├── ParallelWorkbench/          # macOS GUI 应用（SwiftUI）
└── WorkbenchTester/            # 无人值守验收测试器（CLI）
```

## 适配器 schema

```jsonc
{
  "id": "tongyi",
  "name": "通义千问",
  "origin": "https://www.tongyi.com/qianwen/",
  "input": { "selectors": ["CSS 或 xpath: 前缀的 fallback 链"] },
  "send": {
    "type": "enter|button|pointer|paragraph|combo",
    "selectors": ["发送按钮 fallback 链（button/pointer/combo 用）"]
  },
  "probe": { "loggedOut": [], "loginModal": [], "challenge": [] },
  "verify": { "responseIndicator": "回答标志文本（发送后不清空输入框的平台用）" },
  "prepare": { "clickSelector": "发送前预动作（如点「新建对话」）", "waitSeconds": 3 },
  "international": false
}
```

## Windows/Edge 扩展

Edge/Chrome MV3 扩展位于 `Windows/edge-extension/`，复用同一套 adapter/注入核心（`scripts/build-edge-extension.sh` 同步）。Edge 开发者模式「加载解压缩的扩展」即可安装。详见 `Windows/edge-extension/README.md`。

## 打包

```sh
bash scripts/package-app.sh   # 生成 build/ParallelWorkbench.app（未签名）
```

签名 + 公证（对外分发，需 Apple 开发者账号）：`codesign --deep --force --sign "Developer ID" build/ParallelWorkbench.app && xcrun notarytool submit ...`

## 多模态与语音

- **附件（文件/图片）**：输入框下方附件栏（选择/拖放/⌘V 粘贴图片），随问题发送给所有勾选平台；自动注入按平台选择通道，并做接受度验证与诚实降级：
  - **Kimi ✅**：文件进入解析管线（macOS 实测上传卡「wb-tiny Parsing failed」）；**ChatGPT ✅**：文件进入上传管线（Edge 实测附件 chip 出现）
  - **DeepSeek ⚠️**：赋值成功但平台未展示上传卡（疑似要求真实用户手势）；**通义/文心 ❌**：无 file input 且拒绝合成拖放 → 提示「请手动添加」
  - 通道机制：有文件输入框的平台走 `input.files` 原生上传管线；其余走 CDP 拖放（尽力而为——扩展无文件系统权限，CDP 只能投递 MIME 数据，无法构造真实 File）
- **语音输入**：macOS 使用系统 `SFSpeechRecognizer`，Edge 使用 Web Speech API；是否完全在设备端处理取决于系统、语言与浏览器能力。点击 🎤 开始，实时转写进输入框，再点一次结束
- 首次使用语音：macOS 需授权麦克风与语音识别（系统设置 → 隐私与安全性）

## 版本更新

- **macOS**：启动时自动检查 GitHub Releases 最新版，顶栏出现「更新到 vX」按钮，一键下载 → 覆盖安装 → 去隔离 → 自动重启（适配开源未签名分发；仓库可通过环境变量 `PWB_REPO` 配置）
- **Edge 扩展**：工作台页定期检查 GitHub Releases，出现「🆕 新版本」横幅，一键下载 zip 并逐步引导（双击 install.bat → 扩展页点「重新加载」；侧载扩展受平台限制无法全自动重载）
- **install.sh**：不再写死版本，自动拉取最新 Release（下载即最新）

## 已知限制与后续

- 文心一言 / DeepSeek 登录：用户回来后各扫码一次（角标与引导已就绪）
- 应用数据目录损坏/重装系统 → 用 `--restore-auth` 一键恢复
- 平台改版导致选择器失效 → 配置外置，测试器取证输出可直接用于修复
- Edge 扩展真机加载测试：本机 Chrome 151 官方版已移除 `--load-extension` 命令行能力，需在 Edge/Chrome 开发者模式手动加载后实测
