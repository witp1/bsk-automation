# ---- scheduler-config.ps1 - 定时任务配置 ----
# 修改下方配置后，运行 install-scheduler.ps1 即可生效

# 预热执行时间（24 小时制）
$SCRIPT:WarmupSchedule = @{
    Enabled      = $true          # $true / $false
    Hour         = 8              # 0-23
    Minute       = 30             # 0-59
    RepeatEvery  = 0              # 每隔几小时重复执行（0=不重复，只在指定时间跑一次）
    Env          = "test"         # test / prod
    ReportFilter = ""             # 可选，按关键字过滤
}

# daemon 开机自启
$SCRIPT:DaemonAutoStart = @{
    Enabled = $true
}
