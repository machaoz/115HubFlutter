@echo off
REM cmd/PowerShell 入口：转发到 bash 版 lunch（Git Bash 环境需在 PATH）
where bash >nul 2>nul || (echo [fail] 找不到 bash，请在 Git Bash 环境运行或安装 Git for Windows & exit /b 1)
bash "%~dp0lunch" %*
