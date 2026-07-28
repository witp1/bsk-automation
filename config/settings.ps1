# ──── bsk.exe 报表预热自动化 — 环境配置 ────
# 本文件会在 run.ps1 中被点引入（dot-source），变量需加 $SCRIPT: 作用域
# 跨机器直接拷贝，无需修改（bsk 路径自动检测）

# ──── 环境 URL ────
$SCRIPT:PortalHome = @{
    "test" = "https://dataportal-test.fuchuang.work/dataport/homepage"
    "prod" = "https://dataportal.fuchuang.com/dataport/homepage"
}

$SCRIPT:LoginUrl   = @{
    "test" = "https://dataportal-test.fuchuang.work/dataport/superLogin"
    "prod" = "https://dataportal.fuchuang.com/dataport/superLogin"
}

# ──── 日志 ────
$SCRIPT:LogDir = Join-Path (Join-Path $PSScriptRoot "..") "logs"

# ──── bsk.exe 路径（优先项目目录，支持离线拷贝）────
$ProjectDir = Split-Path -Parent $PSScriptRoot
$bskCandidates = @(
    "$ProjectDir\bsk.exe"               # 项目自带（离线安装，最优先）
    "$env:USERPROFILE\.local\bin\bsk.exe"
    "$env:LOCALAPPDATA\bsk\bsk.exe"
    "bsk.exe"
)
$SCRIPT:BskPath = ($bskCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1)

if (-not $SCRIPT:BskPath) {
    Write-Host "[错误] 未找到 bsk.exe，请手动配置 config/settings.ps1 中的 `$SCRIPT:BskPath" -ForegroundColor Red
    Write-Host "      常见安装位置：$env:USERPROFILE\.local\bin\bsk.exe" -ForegroundColor Yellow
    Write-Host "      手动配置方法：在 config/settings.ps1 文件末尾添加一行：" -ForegroundColor Yellow
    Write-Host "      `$SCRIPT:BskPath = 'D:\your\path\to\bsk.exe'" -ForegroundColor Yellow
}
