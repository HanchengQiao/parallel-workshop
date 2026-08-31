@echo off
chcp 65001 >nul
rem 平行工作台启动器：
rem 1) 用 --no-startup-window 预热 Edge（后台进程完成扩展注册，不弹任何窗口）
rem 2) 稍候再打开工作台——避免冷启动竞态被 blank，且全程只出现一个窗口
start msedge --no-startup-window
timeout /t 3 /nobreak >nul
start msedge "chrome-extension://eeppnjgcjioaohaaoaknkkafhodccmmf/workbench.html"
