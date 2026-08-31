@echo off
chcp 65001 >nul
rem 直接以 Edge 应用窗口打开工作台；不创建 blank 预热页、不做固定延迟。
set "WB_URL=chrome-extension://eeppnjgcjioaohaaoaknkkafhodccmmf/workbench.html"
start "" msedge --app="%WB_URL%"
