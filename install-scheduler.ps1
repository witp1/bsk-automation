# --- install-scheduler.ps1 - 一键配置定时任务 ---
# 根据 scheduler-config.ps1 自动创建/更新 Windows 任务计划程序
# 以管理员身份运行（Register-ScheduledTask 需要管理员权限）

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. "$ScriptDir\config\scheduler-config.ps1"

$ProjectDir = $ScriptDir
$BskExe = "$ProjectDir\bsk.exe"
$RunPs1 = "$ProjectDir\run.ps1"

# --- 1. daemon 开机自启 ---
$daemonTaskName = "bsk-daemon"
$daemonExists = Get-ScheduledTask -TaskName $daemonTaskName -ErrorAction SilentlyContinue

if ($DaemonAutoStart.Enabled) {
    $action = New-ScheduledTaskAction -Execute $BskExe -Argument "daemon start"
    $trigger = New-ScheduledTaskTrigger -AtLogOn
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable

    if ($daemonExists) {
        Set-ScheduledTask -TaskName $daemonTaskName -Action $action -Trigger $trigger -Settings $settings
        Write-Host "[OK] daemon auto-start updated" -ForegroundColor Green
    } else {
        try {
            Register-ScheduledTask -TaskName $daemonTaskName -Action $action -Trigger $trigger -Settings $settings -User $env:USERNAME -RunLevel Highest
            Write-Host "[OK] daemon auto-start created" -ForegroundColor Green
        } catch {
            Write-Host "[!!] daemon auto-start failed: $_" -ForegroundColor Red
        }
    }
} else {
    if ($daemonExists) {
        Unregister-ScheduledTask -TaskName $daemonTaskName -Confirm:$false
        Write-Host "[--] daemon auto-start removed" -ForegroundColor Yellow
    }
}

# --- 2. 预热定时任务 ---
$warmupTaskName = "bsk-warmup"
$warmupExists = Get-ScheduledTask -TaskName $warmupTaskName -ErrorAction SilentlyContinue

if ($WarmupSchedule.Enabled) {
    $envArg = "-Env $($WarmupSchedule.Env)"
    if ($WarmupSchedule.ReportFilter) { $envArg += " -ReportFilter `"$($WarmupSchedule.ReportFilter)`"" }

    $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-ExecutionPolicy Bypass -File `"$RunPs1`" $envArg"
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Hours 4)

    $trigger = New-ScheduledTaskTrigger -Daily -At "$($WarmupSchedule.Hour):$($WarmupSchedule.Minute)"
    if ($WarmupSchedule.RepeatEvery -gt 0) {
        $trigger.RepetitionInterval = New-TimeSpan -Hours $WarmupSchedule.RepeatEvery
        $trigger.RepetitionDuration = New-TimeSpan -Days 1
    }

    if ($warmupExists) { Unregister-ScheduledTask -TaskName $warmupTaskName -Confirm:$false }
    try {
        Register-ScheduledTask -TaskName $warmupTaskName -Action $action -Trigger $trigger -Settings $settings -User $env:USERNAME -RunLevel Highest -Force
        Write-Host "[OK] warmup task created" -ForegroundColor Green
    } catch {
        Write-Host "[!!] warmup task failed: $_" -ForegroundColor Red
    }

    Write-Host ""
    Write-Host "  env: $($WarmupSchedule.Env)"
    Write-Host "  time: $($WarmupSchedule.Hour):$($WarmupSchedule.Minute.ToString('D2'))" -NoNewline
    if ($WarmupSchedule.RepeatEvery -gt 0) { Write-Host " (repeat every $($WarmupSchedule.RepeatEvery) h)" -NoNewline }
    Write-Host ""
    if ($WarmupSchedule.ReportFilter) { Write-Host "  filter: $($WarmupSchedule.ReportFilter)" }
} else {
    if ($warmupExists) {
        Unregister-ScheduledTask -TaskName $warmupTaskName -Confirm:$false
        Write-Host "[--] warmup task removed" -ForegroundColor Yellow
    }
}

# --- 3. 确认 ---
Write-Host ""
Write-Host "Scheduled tasks status:" -ForegroundColor Cyan
Get-ScheduledTask -TaskName "bsk-*" | Select-Object TaskName, State, @{N='NextRun';E={$_.NextRunTime}}
