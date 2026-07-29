# ---- scheduler-config.ps1 - 定时任务配置 ----
# 修改下方配置后，运行 install-scheduler.ps1 即可生效

# ──── 预热定时任务 ────
$SCRIPT:WarmupSchedule = @{
    Enabled      = $true          # $true / $false
    Hour         = 10              # 首次触发小时（24 小时制）
    Minute       = 10             # 首次触发分钟
    ActiveStart  = 8              # 允许执行起始小时（含），只影响重复时长
    ActiveEnd    = 20             # 允许执行结束小时（不含）
    RepeatEvery  = 1              # 重复间隔（小时，支持小数；0=不重复）
    Env          = "test"         # test / prod
    ReportFilter = ""             # 可选，按关键字过滤
}

# daemon 开机自启
$SCRIPT:DaemonAutoStart = @{
    Enabled = $true
}
