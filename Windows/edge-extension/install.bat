@echo off
chcp 65001 >nul
setlocal
set "TARGET=%LOCALAPPDATA%\ParallelWorkbench\edge-extension"
set "WB_URL=chrome-extension://eeppnjgcjioaohaaoaknkkafhodccmmf/workbench.html"
echo ==========================================
echo   平行工作台 - Windows 一键安装
echo ==========================================
echo.

echo [1/4] 复制扩展文件到 %TARGET%
if not exist "%LOCALAPPDATA%\ParallelWorkbench" mkdir "%LOCALAPPDATA%\ParallelWorkbench"
if exist "%TARGET%" rmdir /s /q "%TARGET%"
xcopy /e /i /q "%~dp0*" "%TARGET%" >nul
echo        完成。

echo [2/4] 创建快捷方式（桌面 + 开始菜单，指向防白屏启动器）
powershell -NoProfile -Command "$ws=New-Object -ComObject WScript.Shell; $desk=[Environment]::GetFolderPath('Desktop'); $sm=[Environment]::GetFolderPath('StartMenu'); foreach($dir in @($desk,$sm)){ $lnk=$ws.CreateShortcut((Join-Path $dir '平行工作台.lnk')); $lnk.TargetPath='%TARGET%\launch.bat'; $lnk.WorkingDirectory='%TARGET%'; $lnk.Save() }; Write-Output '        已创建：桌面 + 开始菜单 平行工作台.lnk（防白屏启动）'"
echo.

echo [3/4] 已把扩展路径复制到剪贴板（下一步直接粘贴）
echo %TARGET%| clip
echo        路径：%TARGET%
echo.

echo [4/4] 即将打开 Edge 扩展管理页，请完成两步（每个用户只需一次）：
echo        1. 打开页面左下角「开发人员模式」开关
echo        2. 点「加载解压缩的扩展」- 在文件夹选择框地址栏粘贴（Ctrl+V）并回车
echo.
echo 之后：双击桌面的「平行工作台」快捷方式即可使用。
echo.
start msedge "edge://extensions"
echo 按任意键关闭本窗口...
pause >nul
