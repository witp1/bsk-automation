# ---- scheduler-config.ps1 - 定时任务配置 ----
# 修改下方配置后，运行 install-scheduler.ps1 即可生效

# 预热执行时间（24 小时制）
$SCRIPT:WarmupSchedule = @{
    Enabled      = $true          # $true / $false
    Hour         = 09              # 0-23
    Minute       = 40             # 0-59
    RepeatEvery  = 1              # 每隔几小时重复执行（0=不重复；0.5=每30分钟；2=每2小时）
    Env          = "test"         # test / prod
    ReportFilter = ""             # 可选，按关键字过滤
    ActiveStart  = 7              # 允许执行起始小时（含），23:00-07:00 不执行
    ActiveEnd    = 23             # 允许执行结束小时（不含）
}

# daemon 开机自启
$SCRIPT:DaemonAutoStart = @{
    Enabled = $true
}
