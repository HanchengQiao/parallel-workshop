# 平行工作台 · macOS 版

> 本目录是 **macOS 产品入口**。Windows/Edge 用户请使用仓库根目录下 `Windows/` 目录。

> v0.3.0 是当前上线候选；GitHub 公开稳定版仍为 v0.2.2。一键安装脚本只接受最新稳定 Release。

## 从 GitHub 直接下载安装（命令行）

**方式一：一键安装脚本（推荐）**

```bash
curl -fsSL https://raw.githubusercontent.com/porcelaintech/parallel-workshop/main/install.sh | bash
```

脚本会自动：下载最新版 DMG → 挂载 → 复制「平行工作台.app」到 /Applications → 去除隔离属性 → 启动。

**方式二：手动下载 DMG**

```bash
VERSION=0.2.2
curl -LO "https://github.com/porcelaintech/parallel-workshop/releases/download/v${VERSION}/ParallelWorkbench-${VERSION}.dmg"
open "ParallelWorkbench-${VERSION}.dmg"
# 把「平行工作台」拖进 Applications 即可
```

> npm 包与 Homebrew tap 尚未发布；请勿使用仓库旧文档中出现过的 npx/brew 命令。

## 首次打开提示

应用未签名（开源直发模型）：首次打开若提示「无法验证开发者」，**右键点击 App → 打开 → 再点打开** 即可；或在系统设置 → 隐私与安全性中允许。

## 使用要点

- 登录：在工作台各窗格内直接登录（登录流程被围栏圈禁在窗格内，不会跳出应用），登录态持久保存
- 附件：📎 选择 / 拖入 / ⌘V 粘贴；部分平台（通义/文心）自动注入受限时会明确提示手动添加
- 语音：🎤 开始/停止，首次需授权麦克风与语音识别
- 更新：新版本发布后工作台内提示一键更新（含 SHA-256 校验）

## 源码与构建

macOS 源码位于仓库根目录（`Sources/`、`Package.swift`），构建：

```bash
swift build -c release --arch arm64
bash scripts/package-app.sh
```

详见仓库根 `README.md` 与 `交付说明/产品说明与代码解读.md`。
