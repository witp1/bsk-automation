# --- run.ps1 - bsk 报表预热自动化 入口 ---
param(
    [ValidateSet('test','prod')]
    [string]$Env = 'test',
    [string]$ResumeFrom = '',
    [string]$ReportFilter = '',
    [switch]$NoLogin,
    [string]$BrowserInstance = ''
)

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. "$ScriptDir\config\settings.ps1"
. "$ScriptDir\config\credential.ps1"
. "$ScriptDir\lib\core.ps1"
. "$ScriptDir\lib\warmup.ps1"

# ---- 交互式环境选择（仅当未显式指定 -Env 时触发）----
if (-not $PSBoundParameters.ContainsKey('Env')) {
    Write-Host "=================================" -ForegroundColor Cyan
    Write-Host "  bsk 报表预热自动化 - 选择运行环境  " -ForegroundColor Cyan
    Write-Host "=================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  0  - 生产环境 (prod)"
    Write-Host "  其他键 - 测试环境 (test, 默认)"
    Write-Host ""
    Write-Host "  等待 15 秒, 超时自动选择 test ..."
    Write-Host ""

    $counter = 15
    $selected = $false
    while ($counter -gt 0 -and -not $selected) {
        if ([Console]::KeyAvailable) {
            $key = [Console]::ReadKey($true)
            if ($key.KeyChar -eq '0') {
                $Env = 'prod'
            } else {
                $Env = 'test'
            }
            $selected = $true
        } else {
            $counter--
            if ($counter -gt 0) { Start-Sleep 1 }
        }
    }
    if (-not $selected) { $Env = 'test' }

    if ($Env -eq 'prod') { Write-Host "  > 选择: 生产环境 (prod)" -ForegroundColor Green }
    else { Write-Host "  > 默认: 测试环境 (test)" -ForegroundColor Green }
    Write-Host ""
}

# ---- 校验并执行 ----
if (-not $BskPath) { Write-Host '[ERROR] bsk.exe 未找到' -ForegroundColor Red; exit 1 }
if (-not $NoLogin) {
    $user = $AccountUser[$Env]
    if ([string]::IsNullOrEmpty($user) -or $user -match '^your_') { Write-Host '[ERROR] 账号未配置' -ForegroundColor Red; exit 1 }
    $pass = $AccountPass[$Env]
    if ([string]::IsNullOrEmpty($pass) -or $pass -match '^your_') { Write-Host '[ERROR] 密码未配置' -ForegroundColor Red; exit 1 }
}
# 设置输出编码为 UTF-8，确保 bsk snapshot 中文能正确解析
[Console]::OutputEncoding = [Text.Encoding]::UTF8
if (-not $NoLogin) { Write-Host ('env: ' + $Env + ' user: ' + $AccountUser[$Env]) -ForegroundColor Cyan }
Write-Host ('bsk: ' + $BskPath) -ForegroundColor Cyan
$result = Invoke-WarmupPipeline -Env $Env -ResumeFrom $ResumeFrom -ReportFilter $ReportFilter -NoLogin:$NoLogin -BrowserInstanceId $BrowserInstance
if ($result) {
    if ($result.Failed -gt 0) { exit 2 }
    exit 0
} else {
    exit 1
}
