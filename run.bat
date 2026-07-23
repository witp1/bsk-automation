@echo off
chcp 65001 >nul
powershell -ExecutionPolicy Bypass -File "%~dp0run.ps1" %*
echo.
if %ERRORLEVEL% neq 0 (
    echo [ERROR] 脚本异常退出，错误码: %ERRORLEVEL%
) else (
    echo 完成。
)
echo.
pause
