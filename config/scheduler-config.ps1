# ---- scheduler-config.ps1 - 定时任务配置 ----
# 修改下方配置后，运行 install-scheduler.ps1 即可生效

# ──── 预热定时任务（ActiveStart/ActiveEnd 定义时间窗口）────
$SCRIPT:WarmupSchedule = @{
    Enabled      = $true          # $true / $false
    ActiveStart  = 8              # 每天首次执行时间（24 小时制，整点）
    ActiveEnd    = 20             # 结束时间（不含），如 8-20 表示 8:00~19:00 每 RepeatEvery 小时重复
    RepeatEvery  = 1              # 重复间隔（小时，支持小数；0=不重复）
    Env          = "test"         # test / prod
    ReportFilter = ""             # 可选，按关键字过滤
}

# daemon 开机自启
$SCRIPT:DaemonAutoStart = @{
    Enabled = $true
}
