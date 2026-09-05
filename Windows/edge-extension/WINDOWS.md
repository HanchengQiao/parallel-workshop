# Windows 版：Edge 扩展安装与使用指南

> v0.3.0 是当前稳定版。

本版优化下载与安装流程：固定命令获取最新版，增加限时重试、SHA-256 校验、中文/空格路径支持和原子替换，取消等待按键。新增豆包，记住平台选择、分页、缩放与 DeepSeek 模型选择，并改进启动与响应式布局。

## 产品形态对照

| 平台 | 形态 | 登录态 |
|---|---|---|
| macOS | 原生应用（SwiftUI + WKWebView） | 应用内独立 WebKit 持久存储 |
| **Windows** | **Edge 扩展（MV3，本目录）** | **继承 Edge 浏览器** |

两者共用同一套适配器/注入核心（`Sources/WorkbenchCore/Resources/` → `scripts/build-edge-extension.sh` 同步）。

当前内置平台：ChatGPT、DeepSeek、豆包、Kimi、通义千问、文心一言。

## 一键安装最新稳定版

请在 PowerShell 中直接执行下面整行，不要再次包进 `powershell.exe -Command`。

```powershell
$pwbInstaller = Join-Path $env:TEMP ('ParallelWorkbench-install-' + [Guid]::NewGuid().ToString('N') + '.ps1'); try { & curl.exe --fail --location --silent --show-error --retry 3 --retry-max-time 90 --connect-timeout 10 --max-time 60 'https://github.com/porcelaintech/parallel-workshop/releases/latest/download/install-windows.ps1' --output $pwbInstaller; if ($LASTEXITCODE -ne 0) { throw "安装器下载失败（curl 退出码 $LASTEXITCODE）" }; & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $pwbInstaller; if ($LASTEXITCODE -ne 0) { throw "平行工作台安装失败（退出码 $LASTEXITCODE）" } } finally { Remove-Item -LiteralPath $pwbInstaller -Force -ErrorAction SilentlyContinue }
```

安装器会自动完成版本查询、重试下载、SHA-256 校验、解压、原子复制与快捷方式创建，不需要管理员权限，也不会等待“按任意键”而卡住 Agent。

## 在 Windows 上安装（开发者模式侧载）

1. 把整个 `edge-extension/` 目录复制到 Windows 机器（或解压 `build/edge-extension.zip`）
2. 打开 Edge，地址栏输入 `edge://extensions`
3. 打开左下角「开发人员模式」开关
4. 点「加载解压缩的扩展」→ 选择 `edge-extension` 目录
5. 点工具栏的「平行工作台」图标 → 弹出独立工作台窗口（1500×950，应用式窗口）

> 日常使用前：先在 Edge 里正常登录各平台（chat.deepseek.com / doubao.com / kimi.com 等），扩展里的 pane 直接继承这些登录态。

## 自动测试（已在 Mac 上的 Edge 真机通过）

`scripts/edge-e2e.mjs` 在真实 Edge 中验证：UI 对齐（勾选框/按宽度显示1–3窗格/分页）、探测链路（状态角标真实更新）、发送链路（问题真实进入平台对话区并得到回答）。逐项结论：

- [x] 扩展加载、工作台窗口打开
- [x] 各平台 iframe 嵌入（CSP 剥离规则生效）
- [x] 勾选框交互（取消勾选即隐藏）与「1-3 / 6」分页
- [x] 状态角标（就绪/未登录/未找到输入框/无响应）
- [x] 统一输入 → 注入发送 → 平台对话区出现消息气泡

**快捷方式**：install.bat 自动创建「桌面 + 开始菜单」快捷方式，通过 `msedge --app=<工作台URL>` 直接打开应用式窗口，不显示 blank 预热页。

## 首次实测清单（在 Windows Edge 上逐项确认）

- [ ] 扩展加载无报错（edge://extensions 无红色错误）
- [ ] 各平台 pane 能嵌入显示（CSP 剥离规则生效）
- [ ] 登录态继承（Edge 里已登录的平台 pane 内免登录）
- [ ] 统一输入 → 各 pane 注入发送 → 回答生成
- [ ] 状态角标与发送反馈正常

## 附件（多模态）通道设计

发送带附件的问题时，按平台选择注入通道（**互斥，杜绝双重注入**），并做接受度验证 + 诚实降级：

| 通道 | 适用平台 | 原理 | 状态 |
|---|---|---|---|
| 文件输入框赋值 | 适配器配置了选择器（Kimi `input.hidden-input`、ChatGPT `input.wm-composer-srOnly`）；无选择器时自动兜底页内任一 file input（含隐藏） | 隔离世界重建 File → `input.files = dt.files` → change 事件 → 平台原生上传管线 | ✅ 已实测：ChatGPT 附件 chip 出现；Kimi 赋值成功 |
| CDP 拖放（WB_ATTACH） | 无文件输入框的平台（DeepSeek/通义/文心） | 页面侧计算坐标（iframe 框 × CSS zoom + 帧内编辑器中心）→ chrome.debugger `Input.dispatchDragEvent` 在页面坐标派发（命中测试跨 OOPIF 投进对应帧） | ⚠️ 尽力而为 |

- **CDP 拖放的平台限制**：`DragData.files` 要求磁盘文件路径，扩展无文件系统权限 → 只能投递 MIME 数据（`types=['image/png']` 而非 `'Files'`）；严格检查 File 类型的平台（如文心）会拒绝 → 工作台诚实提示「附件未被平台接受，请手动添加」
- **Edge 152 注意**：`Page.getFrameTree` 对 chrome-extension 页面里的跨域 iframe（OOPIF）不返回子帧 → CDP 帧树发现不可用，必须用 `webNavigation.getAllFrames` + 坐标命中
- 接受度验证：内容脚本 `WB_ATTACH_CHECK`（隔离世界可读宿主 DOM，检查文件名是否出现在页面）
- 逐平台矩阵测试：`scripts/edge-attach-matrix.mjs`（通道级验证，不发送真实消息；`--full` 才做全平台真实发送）

## 扩展开发/测试陷阱

- **MV3 缓存（worker 与 manifest）**：改动 background.js / manifest.json 后即使重启 Edge 也可能仍跑旧代码——真正的缓存源是扩展目录里的 `_metadata/`（含 DNR 规则集缓存）。可靠刷新：manifest 版本号 +1，删除 `edge-extension/_metadata` 与 profile 下的 `Service Worker`、`Extension State`、`Extension Scripts`，重启 Edge
- **重定向域名**：帧 URL 与适配器 origin 可能不同（tongyi.com → qianwen.com、yiyan → wenxin），帧匹配必须用 homeHosts 兜底

## 登录围栏与 DeepSeek 微信回调

- 平台 iframe 保持 sandbox，禁止认证子帧导航整个工作台。
- DeepSeek 微信授权完成后，认证桥严格校验 `open.weixin.qq.com` 来源与 DeepSeek callback 白名单，只导航 DeepSeek pane。
- 问答注入/探测通过 `chrome.tabs.sendMessage` 直达隔离 content script，页面主世界无法读取或伪造回执。
- DNR 规则与 host_permissions 需覆盖认证域名（appleid.apple.com / auth.openai.com / open.weixin.qq.com / passport.baidu.com 等），否则认证页在帧内被 X-Frame-Options 拦截
- 已实测：DeepSeek「使用 Apple 账号登录」→ 无新开标签页，Apple 认证页在帧内完整渲染 ✅

## 已知差异与注意

- ChatGPT 等国际平台：走 Edge 自身网络环境（你的代理），扩展不提供任何代理能力
- 游客模式平台（ChatGPT/文心）：未登录也能问答，登录后功能完整
- 若某平台 pane 空白：先在该平台官网正常访问一次确认网络可达，再刷新 pane

## 后续路线

1. **上架 Microsoft Edge 加载项商店**（正式分发，无需开发者模式）：按微软商店审核要求补充隐私说明等材料
2. **（可选）Windows 原生应用**：Edge WebView2（`CoreWebView2Environment` 指向 Edge 用户数据目录可继承 Edge 登录态，但有"Edge 需先关闭/独立配置目录"的限制）；工程量大，仅在扩展形态不能满足时考虑
3. 平台改版导致适配器失效：改 `lib/adapters/*.json`（或同步回 macOS 侧统一改），重新加载扩展即可
