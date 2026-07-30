# ──── lib/core.ps1 — bsk 操作封装 ────
# 为所有 bsk.exe CLI 命令提供统一的 PowerShell 封装

# ══════════════════════════════════════════════
# 内部辅助：带超时的 bsk 命令调用（.NET Process，非 Start-Job）
# Start-Job 在非交互式进程（任务计划程序）下不保证超时
# ══════════════════════════════════════════════
function Invoke-BskWithTimeout {
    param(
        [Parameter(Mandatory)][string[]]$ArgsList,
        [int]$TimeoutMs = 10000,
        [switch]$NoOutput = $false   # daemon start 等 fork 子进程的场景，不重定向输出
    )
    $cmdStr = ($ArgsList -join " ")
    $sw = [System.Diagnostics.Stopwatch]::StartNew()

    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo.FileName               = $BskPath
    $proc.StartInfo.Arguments              = $cmdStr
    $proc.StartInfo.UseShellExecute        = $false
    $proc.StartInfo.RedirectStandardOutput = -not $NoOutput
    $proc.StartInfo.RedirectStandardError  = -not $NoOutput
    $proc.StartInfo.CreateNoWindow         = $true

    $timedOut = $false
    $stdout   = ""
    $stderr   = ""
    $procId   = 0

    try {
        $proc.Start() | Out-Null
        $procId = $proc.Id
        Write-Log "[bsk] 开始: bsk $cmdStr (PID: $procId, 超时: ${TimeoutMs}ms)" -Level Info

        $timedOut = -not $proc.WaitForExit($TimeoutMs)
        $sw.Stop()

        if ($timedOut) {
            Write-Log "[bsk] 超时! bsk $cmdStr (PID: $procId, 耗时: $($sw.ElapsedMilliseconds)ms)" -Level Warn
            try { $proc.Kill() } catch { Write-Log "[bsk] Kill 失败: $_" -Level Error }
            $stdout = ""
            $stderr = ""
        } elseif (-not $NoOutput) {
            $stdout = $proc.StandardOutput.ReadToEnd()
            $stderr = $proc.StandardError.ReadToEnd()
        }
        Write-Log "[bsk] 完成: bsk $cmdStr (PID: $procId, 耗时: $($sw.ElapsedMilliseconds)ms, 超时: $timedOut, 输出: $(($stdout.Length + $stderr.Length)) 字符)" -Level Info
    } catch {
        $sw.Stop()
        Write-Log "[bsk] 异常: bsk $cmdStr ($_)" -Level Error
        $stdout = ""
        $timedOut = $true
    } finally {
        try { $proc.Dispose() } catch {}
    }

    return @{
        Output  = ($stdout, $stderr -join "`n").Trim()
        TimedOut = $timedOut
    }
}

# ══════════════════════════════════════════════
# 公共函数
# ══════════════════════════════════════════════

function Set-LogFile {
    param([string]$Path)
    $script:LogFilePath = $Path
}

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet("Info","Warn","Error","Success")]
        [string]$Level = "Info"
    )
    $time = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $prefix = switch ($Level) {
        "Info"    { "[INFO]" }
        "Warn"    { "[WARN]" }
        "Error"   { "[ERRO]" }
        "Success" { "[ OK ]" }
    }
    $line = "$time $prefix $Message"
    Write-Host $line
    if ($script:LogFilePath) {
        Add-Content -Path $script:LogFilePath -Value $line -Encoding UTF8
    }
}

# ──── 会话管理 ────

function Start-BskSession {
    <#
    .SYNOPSIS
        启动一个新的 bsk 浏览器会话，返回 session_id 字符串
    .PARAMETER BrowserInstanceId
        目标浏览器实例 ID（可选，默认用唯一连接的浏览器）
    #>
    param([string]$BrowserInstanceId = "")

    Write-Log "启动 bsk 会话..."

    # 直接试 session start（跳过 bsk status，pipe 连接不可靠）
    for ($w = 0; $w -lt 12; $w++) {
        $argsList = @("session", "start", "--json")
        if ($BrowserInstanceId) { $argsList += @("--browser", $BrowserInstanceId) }
        $sr = Invoke-BskWithTimeout -ArgsList $argsList -TimeoutMs 30000
        if (-not $sr.TimedOut -and $sr.Output) {
            Write-Log "[诊断] session start 返回: $($sr.Output)"
            try {
                $parsed = $sr.Output | ConvertFrom-Json
                $sid = $parsed.session_id
                if ($sid) {
                    Write-Log "会话启动成功, ID: $sid (等待 ${w}s)" -Level Success
                    return $sid
                }
            } catch {}
        }
        Write-Log "等待 Chrome 扩展连接... ($([int]($w+1))/12)"
        Start-Sleep -Seconds 2
    }
    Write-Log "会话启动失败，请确认 Chrome 已开启且扩展处于 connected 状态" -Level Error
    return ""
}

function Stop-BskSession {
    param([Parameter(Mandatory)][string]$SessionId)

    Write-Log "停止会话: $SessionId"
    $sr = Invoke-BskWithTimeout -ArgsList @("session","stop",$SessionId,"--json") -TimeoutMs 5000
    if ($sr.TimedOut) {
        Write-Log "会话停止超时，跳过" -Level Warn
        return $false
    }
    if ($sr.Output -match '"ok"|"stopped"') {
        Write-Log "会话已停止" -Level Info
        return $true
    }
    Write-Log "会话停止异常: $($sr.Output)" -Level Warn
    return $false
}

# ──── 浏览器操作 ────

function Invoke-BskNavigate {
    <#
    .SYNOPSIS
        导航到指定 URL
    .PARAMETER SessionId
        bsk 会话 ID
    .PARAMETER Url
        目标 URL
    .PARAMETER WaitUntil
        等待条件: load / domcontentloaded / networkidle / commit
    .PARAMETER TimeoutSec
        超时秒数
    .PARAMETER WaitSec
        导航后额外等待秒数作为缓冲
    #>
    param(
        [Parameter(Mandatory)][string]$SessionId,
        [Parameter(Mandatory)][string]$Url,
        [ValidateSet("load","domcontentloaded","networkidle","commit")]
        [string]$WaitUntil = "load",
        [int]$TimeoutSec = 45,
        [int]$WaitSec = 2
    )

    Write-Log "导航: $Url (wait=$WaitUntil, timeout=${TimeoutSec}s)"

    $result = & $BskPath "navigate", "--session", $SessionId, $Url,
                          "--wait-until", $WaitUntil,
                          "--timeout", "${TimeoutSec}s" 2>&1
    $output = $result -join "`n" | Out-String

    if ($LASTEXITCODE -ne 0) {
        Write-Log "导航失败: $output" -Level Error
        return $false
    }

    if ($WaitSec -gt 0) {
        Start-Sleep -Seconds $WaitSec
    }
    return $true
}

function Invoke-BskSnapshot {
    <#
    .SYNOPSIS
        获取当前页面的可访问性快照, 返回解析后的结构化元素列表
    .DESCRIPTION
        bsk snapshot 返回文本树格式。本函数解析文本树,
        返回 PSCustomObject 数组: { ref, tag, text, depth }
    .PARAMETER SessionId
        bsk 会话 ID
    .PARAMETER MaxDepth
        最大深度限制（默认 10）
    .PARAMETER RawText
        仅返回原始文本树而不解析
    #>
    param(
        [Parameter(Mandatory)][string]$SessionId,
        [int]$MaxDepth = 10,
        [switch]$RawText
    )

    $result = & $BskPath "snapshot", "--session", $SessionId,
                          "--max-depth", $MaxDepth, "--json" 2>&1
    $output = $result -join "`n" | Out-String

    if ($LASTEXITCODE -ne 0 -or -not $output) {
        Write-Log "snapshot 失败" -Level Error
        if ($RawText) { return "" } else { return @() }
    }

    try {
        $parsed = $output | ConvertFrom-Json
        $text = $parsed.text
        if ($RawText) { return $text }

        # 解析文本树格式为结构化对象
        $elements = @()
        $linePattern = '^(\s*)@e(\d+)\s+(\S+)\s+"([^"]*)"'

        foreach ($line in $text -split "`n") {
            if ($line -match $linePattern) {
                $indent = $matches[1]
                $refNum = [int]$matches[2]
                $tag    = $matches[3]
                $elemText = $matches[4]
                $depth = ($indent.Length / 2)  # 每个缩进2空格

                $elements += [PSCustomObject]@{
                    Ref   = "@e$refNum"
                    RefNum = $refNum
                    Tag   = $tag
                    Text  = $elemText
                    Depth = [int]$depth
                }
            }
        }
        Write-Log "snapshot 解析: $($elements.Count) 个元素 (共 $($parsed.ref_count) refs)"
        return $elements

    } catch {
        Write-Log "snapshot 解析失败: $_" -Level Error
        if ($RawText) { return $output.Trim() } else { return @() }
    }
}

function Invoke-BskClick {
    <#
    .SYNOPSIS
        通过 snapshot ref 点击元素
    .PARAMETER SessionId
        bsk 会话 ID
    .PARAMETER Ref
        目标元素的 ref，如 "@e12"
    .PARAMETER TimeoutSec
        点击超时（默认 30s）
    .PARAMETER WaitSec
        点击后额外等待秒数
    #>
    param(
        [Parameter(Mandatory)][string]$SessionId,
        [Parameter(Mandatory)][string]$Ref,
        [int]$TimeoutSec = 30,
        [int]$WaitSec = 1
    )

    Write-Log "点击: $Ref"
    $result = & $BskPath "click", "--session", $SessionId, $Ref,
                          "--timeout", "${TimeoutSec}s" 2>&1
    $output = $result -join "`n" | Out-String

    if ($LASTEXITCODE -ne 0) {
        Write-Log "点击 $Ref 失败: $output" -Level Error
        return $false
    }

    if ($WaitSec -gt 0) { Start-Sleep -Seconds $WaitSec }
    return $true
}

function Invoke-BskEvaluate {
    <#
    .SYNOPSIS
        在页面中执行 JavaScript
    .PARAMETER SessionId
        bsk 会话 ID
    .PARAMETER Script
        JS 表达式（函数体需要显式 return）
    .PARAMETER TimeoutSec
        执行超时（默认 30s）
    .RETURNS
        表达式求值结果的纯文本
    #>
    param(
        [Parameter(Mandatory)][string]$SessionId,
        [Parameter(Mandatory)][string]$Script,
        [string]$TimeoutSec = "30s"
    )

    $result = & $BskPath "evaluate", "--session", $SessionId,
                          $Script, "--timeout", $TimeoutSec 2>&1
    $output = $result -join "`n" | Out-String

    if ($LASTEXITCODE -ne 0) {
        # 检测会话/浏览器断开（非普通超时）
        if ($output -match 'session|closed|disconnect|no such session') {
            Write-Log "evaluate 失败（会话已断开）" -Level Error
            return '__SESSION_DEAD__'
        }
        Write-Log "evaluate 失败" -Level Error
        return $null
    }

    return $output.Trim()
}

# ──── 元素查找 ────

function Find-ElementByText {
    <#
    .SYNOPSIS
        在解析后的 snapshot 元素列表中按文本查找
    .PARAMETER Elements
        Invoke-BskSnapshot 返回的元素数组
    .PARAMETER Text
        搜索文本（模糊匹配）
    .PARAMETER Exact
        精确匹配
    #>
    param(
        [Parameter(Mandatory)][array]$Elements,
        [Parameter(Mandatory)][string]$Text,
        [switch]$Exact
    )

    if ($Exact) {
        return $Elements | Where-Object { $_.Text -eq $Text }
    } else {
        return $Elements | Where-Object { $_.Text -like "*$Text*" }
    }
}

