# 智囊 · Braintrust — Edge/Chrome 扩展（MV3）

与 macOS 应用共享同一套适配器/注入核心（`Sources/WorkbenchCore/Resources/`），单一事实来源。

当前内置平台：ChatGPT、DeepSeek、豆包、Kimi、通义千问、文心一言。

## 安装（开发者模式）

仓库用户优先执行固定的一键安装命令：

请在 PowerShell 中直接执行下面整行，不要再次包进 `powershell.exe -Command`。

```powershell
$pwbInstaller = Join-Path $env:TEMP ('ParallelWorkbench-install-' + [Guid]::NewGuid().ToString('N') + '.ps1'); try { & curl.exe --fail --location --silent --show-error --retry 3 --retry-max-time 90 --connect-timeout 10 --max-time 60 'https://github.com/porcelaintech/parallel-workshop/releases/latest/download/install-windows.ps1' --output $pwbInstaller; if ($LASTEXITCODE -ne 0) { throw "安装器下载失败（curl 退出码 $LASTEXITCODE）" }; & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $pwbInstaller; if ($LASTEXITCODE -ne 0) { throw "智囊安装失败（退出码 $LASTEXITCODE）" } } finally { Remove-Item -LiteralPath $pwbInstaller -Force -ErrorAction SilentlyContinue }
```

已下载本 ZIP 的用户直接运行 `install.bat`。首次按界面提示加载扩展，之后双击桌面或开始菜单中的「智囊」即可打开，无需寻找拼图菜单。新启动页会显示准备进度并核对运行版本。

让 Agent 安装时，复制仓库的 [Windows 极简 Prompt](https://github.com/porcelaintech/parallel-workshop/blob/main/AGENT_INSTALL_PROMPT.md#windows--复制以下整段)。

源码目录手动侧载：

1. Edge 打开 `edge://extensions`（Chrome 打开 `chrome://extensions`）
2. 开启「开发人员模式」
3. 「加载解压缩的扩展」→ 选择 `edge-extension/` 目录
4. 已创建快捷方式时从桌面「智囊」打开；也可点击扩展工具栏入口

## 更新

点击工作台顶部 `Update` 下载并校验新版 ZIP，解压后运行新版 `install.bat`。更新后从桌面「智囊」重新打开，启动页核对实际加载版本，并重新加载仍在运行的旧版本。安装保留浏览器登录和界面偏好。

## 构建（开发者）

```sh
bash scripts/build-edge-extension.sh   # 复制共享核心 → edge-extension/lib/
```

## 架构

- `workbench.html/js/css`：工作台页面（iframe pane + 统一输入框 + 状态角标 + 发送反馈）
- `start.html`：本地桌面启动入口，显示加载状态并等待扩展就绪
- `launch.html`：扩展启动页，核对实际运行版本后进入工作台
- `content.js`：隔离世界注入核心；工作台用 `chrome.tabs.sendMessage` 指定 frame 并直接取得回执，页面脚本无法伪造
- `auth-bridge.js`：把 MAIN world 捕获的 DeepSeek 微信 callback 候选转交后台做第二次白名单验证
- `background.js`：仅为已注册的工作台 tab 动态创建 session DNR rule，剥离该 tab 内目标 iframe 的 XFO/CSP；普通标签页和商店分配的新扩展 ID 均不受影响
- `lib/`：构建脚本从共享核心复制的 adapter JSON + inject/probe JS
- 侧载包用 manifest key 保持快捷方式 ID 稳定；商店可分配新 ID，session DNR 不依赖固定 ID

## 验证状态

- ✅ JS 语法 + manifest/rules JSON 校验
- ✅ content.js 胶水层 Node+jsdom 冒烟测试（模板拉取 → `__CFG__` 替换 → 注入 → 结果回传；顺带修复了 `String.replace` 只替换注释里首个 `__CFG__` 的真 bug）
- ⏳ 真机加载测试：本机 Chrome 151 官方版已移除 `--load-extension` 命令行能力，无法自动化加载；需在 Edge/Chrome 开发者模式手动加载后实测（iframe 嵌入、登录态继承、注入发送）

## 已知注意

- 国际平台（chatgpt）走浏览器既有代理环境，扩展不做任何代理
- 登录态继承自浏览器日常使用（未登录的平台在 pane 里登录一次即可）
