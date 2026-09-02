# 给安装 Agent 的固定 Prompt

请在当前电脑安装并启动「平行工作台」的 GitHub 最新稳定版本。不要硬编码版本号，不要安装 prerelease，也不要修改产品源码。

仓库：<https://github.com/porcelaintech/parallel-workshop>

1. 识别当前操作系统。
2. macOS 执行：

   ```bash
   curl -fsSL https://raw.githubusercontent.com/porcelaintech/parallel-workshop/main/install.sh | bash
   ```

3. Windows：在当前 PowerShell 中直接执行下面整行；不要再把它嵌进另一层 `powershell.exe -Command`：

   ```powershell
   [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12; $pwbInstaller = Join-Path $env:TEMP ('ParallelWorkbench-install-' + [Guid]::NewGuid().ToString('N') + '.ps1'); try { Invoke-WebRequest -UseBasicParsing 'https://raw.githubusercontent.com/porcelaintech/parallel-workshop/main/install-windows.ps1' -OutFile $pwbInstaller -ErrorAction Stop; & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $pwbInstaller; if ($LASTEXITCODE -ne 0) { throw "平行工作台安装失败（退出码 $LASTEXITCODE）" } } finally { Remove-Item -LiteralPath $pwbInstaller -Force -ErrorAction SilentlyContinue }
   ```

4. Windows 首次安装若打开 `edge://extensions`，只引导用户完成一次“开发人员模式 → 加载解压缩的扩展”，路径已经复制到剪贴板。不要反复下载、不要更换 Edge profile、不要删除浏览器数据。
5. 验证实际安装版本来自最新稳定 Release，并启动平行工作台。
6. 最后只报告：系统、版本、安装位置、总用时、启动是否成功；若失败，报告具体步骤、退出码和日志，不要无限重试。
