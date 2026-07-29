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

if ($WarmupSchedule.Enabled) {
    # 起始时间 + 重复时长（从 Hour:Minute 到 ActiveEnd:00）
    $time = $WarmupSchedule.Hour.ToString('D2') + ":" + $WarmupSchedule.Minute.ToString('D2')
    $activeEnd = if ($WarmupSchedule.ContainsKey('ActiveEnd')) { $WarmupSchedule.ActiveEnd } else { 20 }
    $durationMin = ($activeEnd * 60) - ($WarmupSchedule.Hour * 60 + $WarmupSchedule.Minute)
    if ($durationMin -le 0) { $durationMin += 1440 }
    $durationStr = ([int]($durationMin / 60)).ToString('D2') + ':' + ($durationMin % 60).ToString('D2')

    # 构造命令参数
    $taskArgs = "-ExecutionPolicy Bypass -File `"$RunPs1`" -Env $($WarmupSchedule.Env)"
    if ($WarmupSchedule.ReportFilter) { $taskArgs += " -ReportFilter `"$($WarmupSchedule.ReportFilter)`"" }

    # 先删旧任务
    schtasks /delete /tn $warmupTaskName /f 2>&1 | Out-Null

    # 用 schtasks 创建（/ri 重复间隔，/du 可执行时长）
    if ($WarmupSchedule.RepeatEvery -gt 0) {
        $intervalMin = [int]($WarmupSchedule.RepeatEvery * 60)
        schtasks /create /tn $warmupTaskName /tr "powershell $taskArgs" /sc daily /st $time /ri $intervalMin /du $durationStr /ru $env:USERNAME /rl highest /f 2>&1 | Out-Null
    } else {
        schtasks /create /tn $warmupTaskName /tr "powershell $taskArgs" /sc daily /st $time /ru $env:USERNAME /rl highest /f 2>&1 | Out-Null
    }

    if ($LASTEXITCODE -eq 0) {
        Write-Host "[OK] warmup task created" -ForegroundColor Green
    } else {
        Write-Host "[!!] warmup task failed" -ForegroundColor Red
    }

    Write-Host ""
    Write-Host "  env: $($WarmupSchedule.Env)"
    Write-Host "  time: $time" -NoNewline
    if ($WarmupSchedule.RepeatEvery -gt 0) { Write-Host " (repeat every $($WarmupSchedule.RepeatEvery) h)" -NoNewline }
    Write-Host ""
    if ($WarmupSchedule.ReportFilter) { Write-Host "  filter: $($WarmupSchedule.ReportFilter)" }
} else {
    schtasks /delete /tn $warmupTaskName /f 2>&1 | Out-Null
    Write-Host "[--] warmup task removed" -ForegroundColor Yellow
}

# --- 3. 确认 ---
Write-Host ""
Write-Host "Scheduled tasks status:" -ForegroundColor Cyan
Get-ScheduledTask -TaskName "bsk-*" | Select-Object TaskName, State, @{N='NextRun';E={$_.NextRunTime}}
