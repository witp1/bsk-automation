# ──── lib/core.ps1 — bsk 操作封装 ────
# 为所有 bsk.exe CLI 命令提供统一的 PowerShell 封装
# 实测命令参考：
#   bsk session start         → 返回 session_id (plain text)
#   bsk session stop <sid>    → 停止会话
#   bsk navigate <url>        → 导航（--session, --wait-until, --timeout）
#   bsk snapshot --json       → 返回 {text, ref_count, tab_id, truncated}
#   bsk click <ref>           → 点击（--session, --timeout）
#   bsk fill --value <val>    → 填充表单（--session, --ref, --value）
#   bsk evaluate <expr>       → 执行 JS（--session, --timeout）

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

    # 预检：确认有浏览器连上 daemon（避免空跑等到超时）
    $status = & $BskPath "status" 2>&1 | Out-String
    if ($status -match 'browsers connected\s+(\d+)') {
        $browserCount = [int]$matches[1]
        if ($browserCount -lt 1) {
            Write-Log "无浏览器连接到 daemon，请先打开 Chrome 且扩展处于 connected 状态" -Level Error
            return ""
        }
    } else {
        Write-Log "无法读取 daemon 状态" -Level Error
        return ""
    }

    $argsList = @("session", "start", "--json")
    if ($BrowserInstanceId) {
        $argsList += @("--browser", $BrowserInstanceId)
    }

    # 用 job 加超时（30s），避免浏览器未开时无限等待
    $job = Start-Job -ScriptBlock {
        param($bskPath, $argsList)
        & $bskPath $argsList 2>&1
    } -ArgumentList $BskPath, $argsList
    $jobDone = Wait-Job -Job $job -Timeout 30

    if (-not $jobDone) {
        Stop-Job -Job $job
        Write-Log "bsk 会话启动超时（30s），可能浏览器未开启" -Level Error
        return ""
    }

    $result = Receive-Job -Job $job
    Remove-Job -Job $job
    $output = $result -join "`n" | Out-String

    if ($LASTEXITCODE -ne 0 -or -not $output) {
        Write-Log "bsk 会话启动失败: $output" -Level Error
        return ""
    }

    try {
        $parsed = $output | ConvertFrom-Json
        $sid = $parsed.session_id
        Write-Log "会话启动成功, ID: $sid" -Level Success
        return $sid
    } catch {
        Write-Log "解析 session_id 失败: $output" -Level Error
        return ""
    }
}

function Stop-BskSession {
    <#
    .SYNOPSIS
        停止指定 bsk 会话（session_id 为位置参数）
    .PARAMETER SessionId
        要停止的会话 ID
    #>
    param([Parameter(Mandatory)][string]$SessionId)

    Write-Log "停止会话: $SessionId"
    $result = & $BskPath "session", "stop", $SessionId, "--json" 2>&1
    $output = $result -join "`n" | Out-String

    if ($LASTEXITCODE -ne 0) {
        Write-Log "会话停止异常, 继续流程" -Level Warn
        return $false
    }
    Write-Log "会话已停止" -Level Info
    return $true
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

function Find-ElementByTag {
    <#
    .SYNOPSIS
        按标签类型查找元素
    #>
    param(
        [Parameter(Mandatory)][array]$Elements,
        [Parameter(Mandatory)][string]$Tag
    )
    return $Elements | Where-Object { $_.Tag -eq $Tag }
}
