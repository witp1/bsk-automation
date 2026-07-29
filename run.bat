@echo off
chcp 65001 >nul
powershell -ExecutionPolicy Bypass -File "%~dp0run.ps1" %*
echo.
if %ERRORLEVEL% equ 2 (
    echo [WARN] 部分报表预热失败 (exit 2)^, 详见日志
) else if %ERRORLEVEL% neq 0 (
    echo [ERROR] 脚本退出，错误码: %ERRORLEVEL%
) else (
    echo 完成。
)
echo.
pause
