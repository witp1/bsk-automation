# ──── lib/warmup.ps1 — 报表预热核心逻辑 ────
# 依赖 core.ps1, 使用 bsk 真实 CLI 命令
#
# 实测树结构（snapshot depth）:
#   depth=2 treeitem → 分类（经销商/同步生产/财务业务）
#   depth=3 treeitem → 报表（经销商客户分析等）
#   depth=4 treeitem → 子报表（极少数情况）

# ──── 报表树解析 ────

function Get-ReportTree {
    <#
    .SYNOPSIS
        从数据门户页面解析报表树结构
    .DESCRIPTION
        流程：
        1. 确认已在报表中心页面
        2. 展开所有分类节点
        3. snapshot 抓取完整树
        4. 通过 depth 识别分类(depth=2)和报表(depth=3)
    .PARAMETER SessionId
        bsk 会话 ID
    #>
    param([Parameter(Mandatory)][string]$SessionId)

    if ($Diagnostic) { Write-Log "[树扫描] 开始..." }

    # ──── 1. 展开所有分类节点 ────
    # 分类节点是 el-tree-node，点击 el-tree-node__expand-icon 展开
    if ($Diagnostic) { Write-Log "[树扫描] 展开所有分类..." }
    $expandJs = @'
(function() {
    var icons = document.querySelectorAll('.el-tree-node__expand-icon');
    var clicked = 0;
    for (var i = 0; i < icons.length; i++) {
        if (!icons[i].classList.contains('expanded') && icons[i].offsetParent !== null) {
            icons[i].click();
            clicked++;
        }
    }
    return 'expanded_' + clicked;
})();
'@
    # 多轮展开确保所有层级展开
    for ($round = 1; $round -le 4; $round++) {
        $result = Invoke-BskEvaluate -SessionId $SessionId -Script $expandJs
        if ($Diagnostic) { Write-Log "[树扫描] 第${round}轮展开: $result" }
        Start-Sleep -Seconds 1
    }

    # ──── 2. snapshot 抓取完整树 ────
    $treeSnap = Invoke-BskSnapshot -SessionId $SessionId
    if ($Diagnostic) { Write-Log "[树扫描] snapshot 共 $($treeSnap.Count) 个元素" }

    # ──── 3. 解析树结构 ────
    # 遍历所有 treeitem，按 depth 判断层级
    # 注意: treeitem text 前面有图标前缀如 " " (3 chars), 需要剥离
    $parsed = @()
    $currentCategory = ""

    # 按 snapshot 输出顺序遍历，维护当前分类
    foreach ($e in $treeSnap) {
        if ($e.Tag -ne "treeitem") { continue }

        $rawText = $e.Text.Trim()
        $depth  = $e.Depth
        $ref    = $e.Ref

        # 跳过无效项
        if ([string]::IsNullOrEmpty($rawText)) { continue }
        if ($rawText.Length -le 2) { continue }

        # 剥离图标前缀：移除开头的非文字字符（图标字体）和空格
        # 图标如 " " 属于 Unicode 私用区，WinPS 不支持 \x{e000} 语法
        $name = $rawText
        if ($name -match '^[^a-zA-Z0-9\u4e00-\u9fff]\s+(.+)$') {
            $name = $matches[1]
        } elseif ($name -match '^[^a-zA-Z0-9\u4e00-\u9fff]\s*') {
            $name = $name -replace '^[^a-zA-Z0-9\u4e00-\u9fff]\s*', ''
        }
        $name = $name.Trim()
        if ([string]::IsNullOrEmpty($name)) { continue }
        if ($name -match '^\d+$') { continue }

        if ($depth -eq 2) {
            # depth=2: 分类节点
            $currentCategory = $name
            if ($Diagnostic) { Write-Log "[树扫描]   分类: $name" }
        } elseif ($depth -ge 3) {
            # depth>=3: 报表节点（属于当前分类）
            if (-not $currentCategory) { continue }
            $parsed += [PSCustomObject]@{
                Category   = $currentCategory
                ReportName = $name
                Ref        = $ref
            }
            if ($Diagnostic) { Write-Log "[树扫描]     报表: $currentCategory / $name [$ref]" }
        }
    }

    # ──── 4. 去重（同一个报表可能有多个 ref）────
    $seen = @{}
    $unique = @()
    foreach ($r in $parsed) {
        $key = "$($r.Category)/$($r.ReportName)"
        if (-not $seen.ContainsKey($key)) {
            $seen[$key] = $true
            $unique += $r
        }
    }

    if ($Diagnostic) { Write-Log "[树扫描] 解析完成: $($unique.Count) 个唯一报表" }
    return $unique
}

# ──── 单个报表预热 ────

function Invoke-ReportWarmup {
    <#
    .SYNOPSIS
        预热单个报表：JS 点击 + 监听 iframe load 事件判断加载完成
    .PARAMETER SessionId
        bsk 会话 ID
    .PARAMETER Report
        报表对象（Category, ReportName, Ref）
    #>
    param(
        [Parameter(Mandatory)][string]$SessionId,
        [Parameter(Mandatory)][PSCustomObject]$Report
    )

    $startTime = Get-Date
    $reportPath = "$($Report.Category)/$($Report.ReportName)"
    Write-Log "──────────────────────────────────────────"
    Write-Log "[预热] $reportPath"

    if (-not $Report.Ref) {
        Write-Log "[预热] 无 ref，跳过" -Level Warn
        return [PSCustomObject]@{
            ReportName = $reportPath
            Status     = "Skipped"
            Duration   = 0
            Error      = "No ref"
        }
    }

    # ──── 点击报表 + 双验证（load 事件 + iframe src 变化）────
    $safeName = $Report.ReportName -replace "'", "\\'"
    Write-Log "[预热] 点击并检测加载..."

    # 1. 记录当前 iframe src，然后注册 load 监听 + 点击
    $registerJs = @"
(function() {
    // 记录点击前的 iframe src，用于后续验证
    var f = document.querySelector('iframe');
    window.__bskBeforeSrc = f ? (f.getAttribute('src') || f.src || '') : '';

    // 重置标志位
    window.__bskLoaded = false;

    // 触发点击
    var all = document.querySelectorAll('.el-tree-node__content');
    var clicked = false;
    for (var i = 0; i < all.length; i++) {
        var t = all[i].querySelector('.f-14')?.innerText || all[i].innerText || '';
        if (t.trim() === '$safeName') { all[i].click(); clicked = true; break; }
    }
    if (!clicked) {
        for (var i = 0; i < all.length; i++) {
            var t = all[i].innerText || '';
            if (t.indexOf('$safeName') >= 0) { all[i].click(); clicked = true; break; }
        }
    }
    return clicked ? 'clicked' : 'not_found';
})();
"@
    $clickResult = Invoke-BskEvaluate -SessionId $SessionId -Script $registerJs
    if ($clickResult -eq '__SESSION_DEAD__') { throw "Session disconnected by user" }

    if ($clickResult -eq "not_found") {
        Write-Log "[预热] 点击未命中，标记失败" -Level Error
        $loaded = $false
    } else {
        # 2. 轮询检测（每 1s，最多 15s）
        #    MutationObserver（全局常驻）会自动给新 iframe 注册 load 监听
        $loaded = $false
        for ($t = 0; $t -lt 15; $t++) {
            Start-Sleep -Seconds 1
            $checkJs = @"
(function() {
    if (!window.__bskLoaded) return 'pending';
    // load 事件触发了，验证 iframe 是否真的加载了报表
    var f = document.querySelector('iframe');
    if (!f || !f.src) return 'spurious';
    var srcChanged = f.src !== window.__bskBeforeSrc;
    var isTableau = f.src.indexOf('/trusted/') >= 0 || f.src.indexOf('/views/') >= 0;
    var hasTitle = f.title && f.title.indexOf('数据可视化') >= 0;
    if (srcChanged && isTableau && hasTitle) {
        return 'loaded';
    }
    return 'spurious';
})();
"@
            $result = Invoke-BskEvaluate -SessionId $SessionId -Script $checkJs
            if ($result -eq '__SESSION_DEAD__') { throw "Session disconnected by user" }
            if ($result -eq "loaded") {
                Write-Log "[预热] iframe 加载完成 ($($t+1)s)" -Level Success
                $loaded = $true
                break
            } elseif ($result -eq "spurious") {
                Write-Log "[预热] iframe load 事件为无关触发，继续等待" -Level Warn
                # 重置标志位，继续等真正的加载
                $resetRes = Invoke-BskEvaluate -SessionId $SessionId -Script "window.__bskLoaded = false"
                if ($resetRes -eq '__SESSION_DEAD__') { throw "Session disconnected by user" }
            }
        }
        if (-not $loaded) {
            Write-Log "[预热] iframe 加载超时 (15s)" -Level Error
        }
    }
    $endTime = Get-Date
    $duration = [math]::Round(($endTime - $startTime).TotalSeconds, 1)

    if ($loaded) {
        Write-Log "[预热] 完成: ${reportPath} (${duration}s)" -Level Success
    } else {
        Write-Log "[预热] 失败: ${reportPath} (${duration}s)" -Level Error
    }

    return [PSCustomObject]@{
        ReportName = $reportPath
        Status     = if ($loaded) { "Success" } else { "Failed" }
        Duration   = $duration
        Error      = if (-not $loaded) { "Iframe load timeout" } else { "" }
    }
}

# ──── 完整预热管道 ────

function Invoke-WarmupPipeline {
    <#
    .SYNOPSIS
        完整预热流水线
    .PARAMETER Env
        环境 "test" / "prod"
    .PARAMETER ResumeFrom
        断点恢复路径 "分类/报表名"
    .PARAMETER ReportFilter
        报表名称过滤关键词
    .PARAMETER NoLogin
        跳过登录
    .PARAMETER BrowserInstanceId
        浏览器实例 ID（可选）
    #>
    param(
        [Parameter(Mandatory)][ValidateSet("test","prod")][string]$Env,
        [string]$ResumeFrom = "",
        [string]$ReportFilter = "",
        [switch]$NoLogin,
        [string]$BrowserInstanceId = ""
    )

    $pipelineStart = Get-Date
    $startFmt = $pipelineStart.ToString("yyyy-MM-dd_HH-mm-ss")

    # ──── 准备日志：每次执行独立子目录 ────
    $logParent = $LogDir
    if (-not (Test-Path $logParent)) { New-Item -ItemType Directory -Path $logParent -Force | Out-Null }
    $runDir = Join-Path $logParent $startFmt
    New-Item -ItemType Directory -Path $runDir -Force | Out-Null
    $logFile = Join-Path $runDir "warmup_${Env}.log"
    $resultFile = Join-Path $runDir "result_${Env}.csv"
    Set-LogFile -Path $logFile

    Write-Log "╔══════════════════════════════════════╗"
    Write-Log "║  bsk 报表预热自动化                  ║"
    Write-Log "╚══════════════════════════════════════╝"
    Write-Log "环境: $Env"
    Write-Log "时间: $startFmt"
    if ($ResumeFrom)   { Write-Log "断点恢复: $ResumeFrom" }
    if ($ReportFilter) { Write-Log "过滤: $ReportFilter" }

    # ──── 0. 确保 daemon 在运行 ────
    Write-Log "检查 daemon 状态..."

    $lockFile = "$env:USERPROFILE\.bsk\daemon.lock"
    $stateFile = "$env:USERPROFILE\.bsk\daemon.json"
    $daemonRunning = $false

    # 检查已有 daemon 是否活着且 pipe 可用（不杀健康 daemon，避免扩展断连）
    $bskProcs = Get-Process -Name "bsk" -ErrorAction SilentlyContinue
    if ($bskProcs) {
        $testSid = Invoke-BskWithTimeout -ArgsList @("session","start","--json") -TimeoutMs 5000
        if (-not $testSid.TimedOut -and $testSid.Output -and $testSid.Output -notmatch '"exit_code":\s*2') {
            $daemonRunning = $true
            Write-Log "daemon 已在运行且可用 (PID: $($bskProcs[0].Id))，复用"
            # 关掉健康检查创建的测试 session
            try { $testParsed = $testSid.Output | ConvertFrom-Json; $tsid = $testParsed.session_id; if ($tsid) { Stop-BskSession -SessionId $tsid } } catch {}
        } else {
            Write-Log "daemon 存在但 pipe 无响应，重启..." -Level Warn
            Kill-BskProcesses
            Start-Sleep -Seconds 2
        }
    }

    if (-not $daemonRunning) {
        # 清理锁文件和旧 daemon 状态文件
        if (Test-Path $lockFile) {
            Remove-Item $lockFile -Force -ErrorAction SilentlyContinue
        }
        if (Test-Path $stateFile) {
            Remove-Item $stateFile -Force -ErrorAction SilentlyContinue
        }

        # 启动 daemon（Start-Process 脱离计划任务生命周期）
        Start-Process -FilePath $BskPath -ArgumentList @("daemon","start") -WindowStyle Hidden
        Start-Sleep -Seconds 2
        for ($i = 0; $i -lt 6; $i++) {
            if ((Test-Path $stateFile) -and ((Get-Item $stateFile).Length -gt 0)) {
                $daemonRunning = $true
                Write-Log "daemon 已启动 (等待 ${i}s)"
                break
            }
            Write-Log "等待 daemon.json... ($([int]($i+1))/6)"
            Start-Sleep -Seconds 1
        }
        if (-not $daemonRunning) {
            Write-Log "daemon 启动失败，终止" -Level Error
            Kill-BskProcesses
            return
        }
    }

    # 确保 Chrome 在运行
    if (-not (Get-Process chrome -ErrorAction SilentlyContinue)) {
        Write-Log "Chrome 未运行，自动启动..."
        try {
            Start-Process "chrome"; Wait-ChromeReady
            Write-Log "Chrome 已启动"
        } catch {
            Write-Log "无法启动 Chrome: $_" -Level Error
        }
    }

    # ──── 1. 启动会话 ────
    $sid = Start-BskSession
    if (-not $sid) {
        Write-Log "会话启动失败，终止" -Level Error
        return
    }

    try {
        # ──── 2. 登录 ────
        if ($NoLogin) {
            Write-Log "跳过登录"
            Invoke-BskNavigate -SessionId $sid -Url $PortalHome[$Env] -WaitSec 3
        } else {
            $loginUser  = $AccountUser[$Env]
            $loginPass  = $AccountPass[$Env]
            if ([string]::IsNullOrEmpty($loginUser) -or $loginUser -match "^your_") {
                Write-Log "账号未配置，终止" -Level Error
                return
            }
            Write-Log "登录: $loginUser"

            # 导航到登录页
            $navOk = Invoke-BskNavigate -SessionId $sid -Url $LoginUrl[$Env]
            if (-not $navOk) { Write-Log "导航到登录页失败" -Level Error; return }
            Start-Sleep -Seconds 2

            # 确认没有跳转到 SSO（会话过期时会重定向到 SSO 页面）
            $preUrl = Invoke-BskEvaluate -SessionId $sid -Script "window.location.href"
            if ($preUrl -like "*portal-hmg*" -or $preUrl -like "*sso*") {
                Write-Log "登录页被 SSO 拦截，切回数据门户..." -Level Warn
                Invoke-BskNavigate -SessionId $sid -Url $LoginUrl[$Env] -WaitSec 3
            }

            # 登录（三级降级：bsk fill → JS fill → 全栈重启）
            $loginOk = $false
            for ($loginAttempt = 0; $loginAttempt -lt 3; $loginAttempt++) {
                $snap2 = Invoke-BskSnapshot -SessionId $sid
                $userInp = Find-ElementByText -Elements $snap2 -Text "请输入用户名"
                $passInp = Find-ElementByText -Elements $snap2 -Text "请输入密码"
                $btn     = Find-ElementByText -Elements $snap2 -Text "登录" -Exact
                if ($userInp.Count -eq 0 -or $passInp.Count -eq 0 -or $btn.Count -eq 0) {
                    Write-Log "未找到登录表单元素" -Level Error; break
                }

                # 填值策略：第 1 次用 bsk fill，后续用 JS evaluate（锁屏后 CDP 不生效）
                if ($loginAttempt -eq 0) {
                    Write-Log "填充凭据 (bsk fill)..."
                    Invoke-BskWithTimeout -ArgsList @("fill","--session",$sid,$userInp[0].Ref,$loginUser) -TimeoutMs 5000 | Out-Null
                    Invoke-BskWithTimeout -ArgsList @("fill","--session",$sid,$passInp[0].Ref,$loginPass) -TimeoutMs 5000 | Out-Null
                } else {
                    Write-Log "填充凭据 (JS evaluate)..."
                    Invoke-BskEvaluate -SessionId $sid -Script @"
(function(){var s=Object.getOwnPropertyDescriptor(HTMLInputElement.prototype,'value').set;var u=document.querySelector('input[type=text],input:not([type=password])');var p=document.querySelector('input[type=password]');s.call(u,'$loginUser');u.dispatchEvent(new Event('input',{bubbles:true}));u.dispatchEvent(new Event('change',{bubbles:true}));s.call(p,'$loginPass');p.dispatchEvent(new Event('input',{bubbles:true}));p.dispatchEvent(new Event('change',{bubbles:true}));return'ok';})()
"@ | Out-Null
                }

                # 验证填值
                $fillCheckU = Invoke-BskEvaluate -SessionId $sid -Script "(function(){var u=document.querySelector('input[type=text],input:not([type=password])');return u?u.value:'no-input';})()"
                $fillCheckP = Invoke-BskEvaluate -SessionId $sid -Script "(function(){var p=document.querySelector('input[type=password]');return p?p.value:'no-input';})()"
                if ($Diagnostic) { Write-Log "[诊断] 填值: user='$fillCheckU' pass_ok=$($fillCheckP.Length -gt 0)" }

                if ($fillCheckU -ne "" -and $fillCheckU -ne "no-input" -and $fillCheckP.Length -gt 0) {
                    Write-Log "点击登录..."
                    Invoke-BskClick -SessionId $sid -Ref $btn[0].Ref -WaitSec 3
                    Start-Sleep -Seconds 5
                    $url = Invoke-BskEvaluate -SessionId $sid -Script "window.location.href"

                    if ($url -like "*portal-hmg*" -or $url -like "*sso*") {
                        Write-Log "SSO 拦截，切回重试" -Level Warn
                        Invoke-BskNavigate -SessionId $sid -Url $LoginUrl[$Env] -WaitSec 3
                        $sr = Invoke-BskSnapshot -SessionId $sid
                        $br = Find-ElementByText -Elements $sr -Text "登录" -Exact
                        Invoke-BskEvaluate -SessionId $sid -Script @"
(function(){var s=Object.getOwnPropertyDescriptor(HTMLInputElement.prototype,'value').set;var u=document.querySelector('input[type=text],input:not([type=password])');s.call(u,'$loginUser');u.dispatchEvent(new Event('input',{bubbles:true}));var p=document.querySelector('input[type=password]');s.call(p,'$loginPass');p.dispatchEvent(new Event('input',{bubbles:true}));return'ok';})()
"@ | Out-Null
                        if ($br.Count -gt 0) { Invoke-BskClick -SessionId $sid -Ref $br[0].Ref -WaitSec 3 }
                        Start-Sleep -Seconds 5
                        $url = Invoke-BskEvaluate -SessionId $sid -Script "window.location.href"
                    }

                    if ($url -and $url -notlike "*/superLogin*" -and $url -notlike "*/login*") {
                        Write-Log "登录成功" -Level Success
                        $loginOk = $true
                        break
                    }
                    Write-Log "登录失败: $url" -Level Error
                } else {
                    Write-Log "填值未生效" -Level Warn
                }

                # 本次 attempt 失败 → 降级
                Stop-BskSession -SessionId $sid -ErrorAction SilentlyContinue
                if ($loginAttempt -eq 0) {
                    Write-Log "降级：bsk fill 失败，尝试 JS fill..."
                    $sid = Start-BskSession
                    if (-not $sid) { Write-Log "会话重建失败" -Level Error; break }
                    Invoke-BskNavigate -SessionId $sid -Url $LoginUrl[$Env] -WaitSec 5
                } elseif ($loginAttempt -eq 1) {
                    Write-Log "全栈重启：杀 daemon + Chrome..."
                    Kill-BskProcesses
                    Get-Process chrome -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
                    Start-Sleep -Seconds 5
                    Start-Process "chrome"; Wait-ChromeReady
                    Start-Sleep -Seconds 5
                    # 重新走 daemon 启动流程
                    Start-Process -FilePath $BskPath -ArgumentList @("daemon","start") -WindowStyle Hidden
                    Start-Sleep -Seconds 2
                    $df = "$env:USERPROFILE\.bsk\daemon.json"
                    for ($i = 0; $i -lt 6; $i++) {
                        if ((Test-Path $df) -and ((Get-Item $df).Length -gt 0)) { break }
                        Start-Sleep -Seconds 1
                    }
                    Start-Sleep -Seconds 5
                    $sid = Start-BskSession
                    if (-not $sid) { Write-Log "全栈重启后会话失败" -Level Error; break }
                    Invoke-BskNavigate -SessionId $sid -Url $LoginUrl[$Env] -WaitSec 5
                }
            }

            if (-not $loginOk) {
                if ($Diagnostic) {
                    $diagSnap = Invoke-BskSnapshot -SessionId $sid -RawText
                    Write-Log "[诊断] 登录失败时页面内容:"
                    $diagSnap -split "`n" | ForEach-Object { Write-Log "[诊断]   $_" }
                }
                return
            }
        }

        # ──── 3. 点击「报表中心」导航项（已自动跳转到首页）────
        Write-Log "查找并点击「报表中心」..."
        $navSnap = Invoke-BskSnapshot -SessionId $sid
        $reportCenterItem = Find-ElementByText -Elements $navSnap -Text "报表中心" -Exact
        if ($reportCenterItem.Count -gt 0) {
            Invoke-BskClick -SessionId $sid -Ref $reportCenterItem[0].Ref -WaitSec 3
        } else {
            Write-Log "未找到「报表中心」导航项" -Level Warn
        }

        # ──── 4. 扫描树 ────
        $reports = Get-ReportTree -SessionId $sid
        if ($reports.Count -eq 0) {
            Write-Log "未找到报表，终止" -Level Error
            return
        }

        # ──── 6. 过滤 ────
        if ($ReportFilter) {
            $reports = $reports | Where-Object {
                $_.ReportName -like "*$ReportFilter*" -or $_.Category -like "*$ReportFilter*"
            }
            Write-Log "过滤后: $($reports.Count) 个"
        }

        # ──── 7. 断点恢复 ────
        if ($ResumeFrom) {
            $skipCount = 0
            $found = $false
            $filtered = @()
            foreach ($r in $reports) {
                $rp = "$($r.Category)/$($r.ReportName)"
                if (-not $found) {
                    if ($rp -eq $ResumeFrom) { $found = $true; $filtered += $r }
                    else { $skipCount++ }
                } else {
                    $filtered += $r
                }
            }
            $reports = $filtered
            Write-Log "断点恢复: 跳过 ${skipCount}个, 从「${ResumeFrom}」开始, 剩余 $($reports.Count) 个"
        }

        # ──── 8. 遍历预热 ────
        $results = @()
        $total = $reports.Count
        $successCount = 0
        $failCount = 0

        Write-Log "=============================="
        Write-Log "开始预热 $total 个报表"
        Write-Log "=============================="

        # 注册全局 MutationObserver 监听 iframe load（整个预热过程常驻）
        Write-Log "注册 iframe load 监听器..."
        Invoke-BskEvaluate -SessionId $sid -Script @"
window.__bskLoaded = false;
if (window.__bskObserver) window.__bskObserver.disconnect();
window.__bskObserver = new MutationObserver(function(muts) {
    for (var m of muts) {
        for (var n of m.addedNodes) {
            if (n.tagName === 'IFRAME') {
                n.addEventListener('load', function() { window.__bskLoaded = true; });
            }
        }
    }
});
window.__bskObserver.observe(document.body, {childList: true, subtree: true});
"@

        # ──── 5. 死锁看门狗 ────
        $deadlockFile = "$LogDir\deadlock.flag"
        $bskPid = (Get-Process -Name bsk -ErrorAction SilentlyContinue | Select-Object -First 1).Id
        $watchdog = Start-Job -Name "bsk-watchdog" -ScriptBlock {
            param($pid, $flagFile)
            $idleCount = 0
            $lastCpu = $null
            while ($true) {
                Start-Sleep -Seconds 5
                $p = Get-Process -Id $pid -ErrorAction SilentlyContinue
                if (-not $p) { break }  # 进程已死，退出
                $cpu = $p.CPU
                if ($lastCpu -ne $null -and $cpu -eq $lastCpu) {
                    $idleCount++
                    if ($idleCount -ge 12) {
                        "DEADLOCK" | Out-File -FilePath $flagFile -Encoding ascii
                        Stop-Process -Id $pid -Force -ErrorAction SilentlyContinue
                        Stop-Process -Name chrome -Force -ErrorAction SilentlyContinue
                        break
                    }
                } else {
                    $idleCount = 0
                }
                $lastCpu = $cpu
            }
        } -ArgumentList $bskPid, $deadlockFile

        for ($i = 0; $i -lt $total; $i++) {
            $r = $reports[$i]
            # 跳过空名称的报表（树解析偶发）
            if ([string]::IsNullOrEmpty($r.ReportName)) { continue }

            # 检查死锁标记
            if (Test-Path $deadlockFile) {
                Write-Log "[死锁检测] bsk 进程 60s 无响应，Chrome 已 frozen，终止本轮" -Level Error
                throw "Deadlock detected"
            }

            Write-Log "--- [$($i+1)/$total] ---"
            $result = Invoke-ReportWarmup -SessionId $sid -Report $r
            $results += $result
            if ($result.Status -eq "Success") { $successCount++ } else { $failCount++ }

            if (($i + 1) % 5 -eq 0 -or $i -eq $total - 1) {
                Write-Log "[统计] $($i+1)/$total | 成功 $successCount | 失败 $failCount"
            }
        }

        # 停止死锁看门狗
        Stop-Job -Name "bsk-watchdog" -ErrorAction SilentlyContinue
        Remove-Job -Name "bsk-watchdog" -ErrorAction SilentlyContinue
        Remove-Item $deadlockFile -Force -ErrorAction SilentlyContinue

        # ──── 9. 输出结果 ────
        $pipelineEnd = Get-Date
        $totalDuration = [math]::Round(($pipelineEnd - $pipelineStart).TotalSeconds, 1)
        $totalMinutes = [math]::Round($totalDuration / 60, 1)

        Write-Log "══════════════════════════════"
        Write-Log "预热完成"
        Write-Log "总计: $total | 成功: $successCount | 失败: $failCount"
        Write-Log "耗时: ${totalDuration}s (${totalMinutes}min)"
        Write-Log "结果: $resultFile"

        $results | Where-Object { $_.ReportName } |
            Select-Object ReportName, Status, Duration, Error |
            Export-Csv -Path $resultFile -NoTypeInformation -Encoding UTF8

        return @{ Success = $successCount; Failed = $failCount }

    } catch {
        Write-Log "[异常] $_" -Level Error
        Write-Log "[堆栈] $($_.ScriptStackTrace)" -Level Error
        # 异常时也要停 watchdog（死锁检测触发的 throw 会走到这里）
        Stop-Job -Name "bsk-watchdog" -ErrorAction SilentlyContinue
        Remove-Job -Name "bsk-watchdog" -ErrorAction SilentlyContinue
        Remove-Item $deadlockFile -Force -ErrorAction SilentlyContinue
    } finally {
        # 退出登录
        try {
            Write-Log "退出登录..."
            Invoke-BskEvaluate -SessionId $sid -Script @'
(function() {
    var btn = document.querySelector('header button, .v-toolbar button, .v-app-bar button');
    if (!btn) return 'no-button';
    btn.dispatchEvent(new MouseEvent('mouseenter', {bubbles:true}));
    var start = Date.now();
    var iv = setInterval(function() {
        var items = document.querySelectorAll('.v-menu__content .v-list-item');
        if (items.length > 0) {
            clearInterval(iv);
            items[items.length-1].click();
        } else if (Date.now() - start > 3000) {
            clearInterval(iv);
        }
    }, 200);
    return 'sent';
})();
'@ | Out-Null
            Start-Sleep -Seconds 3
            $url = Invoke-BskEvaluate -SessionId $sid -Script "window.location.href"
            if ($url -match "login") { Write-Log "已退出登录" } else { Write-Log "退出登录完成" }
        } catch {
            Write-Log "退出登录失败: $_" -Level Warn
        }
        Write-Log "流程结束"
    }
}

# functions are available via dot-source
