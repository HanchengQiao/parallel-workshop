# 给 Agent 的安装 Prompt · 智囊 Braintrust

按用户电脑选择一段，整段复制给 Agent。两段都直接安装 GitHub 最新稳定版，发布新版后无需修改。

## Windows · 复制以下整段

```text
请在这台 Windows 电脑安装并打开「智囊」。请直接使用你的本机 PowerShell 工具执行下面整行；如果平台弹出执行授权，按平台正常授权继续。

$pwbInstaller = Join-Path $env:TEMP ('ParallelWorkbench-install-' + [Guid]::NewGuid().ToString('N') + '.ps1'); try { & curl.exe --fail --location --silent --show-error --retry 3 --retry-max-time 90 --connect-timeout 10 --max-time 60 'https://github.com/porcelaintech/parallel-workshop/releases/latest/download/install-windows.ps1' --output $pwbInstaller; if ($LASTEXITCODE -ne 0) { throw "安装器下载失败（curl 退出码 $LASTEXITCODE）" }; & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $pwbInstaller; if ($LASTEXITCODE -ne 0) { throw "智囊安装失败（退出码 $LASTEXITCODE）" } } finally { Remove-Item -LiteralPath $pwbInstaller -Force -ErrorAction SilentlyContinue }

安装器负责下载、版本查询和校验。执行失败后再根据具体错误处理；完成后简短报告结果。如果你只有云端终端、不能操作本机，请立即说明。
```

## macOS · 复制以下整段

```text
请在这台 Mac 安装并打开「智囊」。请直接使用你的本机终端工具执行下面命令；如果平台弹出执行授权，按平台正常授权继续。

curl -fsSL https://raw.githubusercontent.com/porcelaintech/parallel-workshop/main/install.sh | bash

安装器负责下载、版本查询和校验。执行失败后再根据具体错误处理；完成后简短报告结果。如果你只有云端终端、不能操作本机，请立即说明。
```

## 分享说明

同一段可交给支持本机终端的不同 Agent；无需为每个 Agent 安装额外工具或连接另一台 Windows 设备。仅有云端终端的 Agent 不能把产品直接装到用户电脑，应立即说明这一点。安装器已负责下载重试、版本查询和摘要校验，Agent 无需重复执行这些准备流程。
