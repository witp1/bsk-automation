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

    Write-Log "[树扫描] 开始..."

    # ──── 1. 展开所有分类节点 ────
    # 分类节点是 el-tree-node，点击 el-tree-node__expand-icon 展开
    Write-Log "[树扫描] 展开所有分类..."
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
        Write-Log "[树扫描] 第${round}轮展开: $result"
        Start-Sleep -Seconds 1
    }

    # ──── 2. snapshot 抓取完整树 ────
    $treeSnap = Invoke-BskSnapshot -SessionId $SessionId
    Write-Log "[树扫描] snapshot 共 $($treeSnap.Count) 个元素"

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
            Write-Log "[树扫描]   分类: $name"
        } elseif ($depth -ge 3) {
            # depth>=3: 报表节点（属于当前分类）
            if (-not $currentCategory) { continue }
            $parsed += [PSCustomObject]@{
                Category   = $currentCategory
                ReportName = $name
                Ref        = $ref
            }
            Write-Log "[树扫描]     报表: $currentCategory / $name [$ref]"
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

    Write-Log "[树扫描] 解析完成: $($unique.Count) 个唯一报表"
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
            if ($result -eq "loaded") {
                Write-Log "[预热] iframe 加载完成 ($($t+1)s)" -Level Success
                $loaded = $true
                break
            } elseif ($result -eq "spurious") {
                Write-Log "[预热] iframe load 事件为无关触发，继续等待" -Level Warn
                # 重置标志位，继续等真正的加载
                Invoke-BskEvaluate -SessionId $SessionId -Script "window.__bskLoaded = false"
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

# 共享：登录页 JS 模板（按 {0}/{1} 填用户名密码）
# 用 querySelector 直接定位输入框和按钮，避开 AX ref 顺序漂移问题
$script:fillAndLoginJs = @'
(function() {
    var u = document.querySelector('input[type="text"], input:not([type="password"])');
    var p = document.querySelector('input[type="password"]');
    if (!u || !p) return JSON.stringify({ok:false, msg:'no-inputs'});
    var user = "__USER__", pass = "__PASS__";
    u.value = ''; u.value = user;
    u.dispatchEvent(new Event('input',{bubbles:true}));
    u.dispatchEvent(new Event('change',{bubbles:true}));
    p.value = ''; p.value = pass;
    p.dispatchEvent(new Event('input',{bubbles:true}));
    p.dispatchEvent(new Event('change',{bubbles:true}));
    var btn = Array.from(document.querySelectorAll('button'))
        .find(function(b){return b.textContent.trim()==='登录';});
    if (btn) { btn.click(); return JSON.stringify({ok:true, msg:'submitted'}); }
    return JSON.stringify({ok:false, msg:'no-button'});
})()
'@

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
    Write-Log "清理残留 daemon 并重启..."

    # 杀掉所有残留 bsk 进程（不限路径，避免僵尸进程持有 named pipe）
    Get-Process -Name "bsk" -ErrorAction SilentlyContinue |
        ForEach-Object { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue }
    Write-Log "[诊断] 已杀残留 bsk 进程"

    # 清理锁文件
    $lockFile = "$env:USERPROFILE\.bsk\daemon.lock"
    if (Test-Path $lockFile) {
        Remove-Item $lockFile -Force -ErrorAction SilentlyContinue
        Remove-Item "$env:USERPROFILE\.bsk\daemon.json" -Force -ErrorAction SilentlyContinue
        Write-Log "[诊断] 已清理残留锁文件"
    }

    # 确保 Chrome 在运行（Start-Process 走 ShellExecute → 注册表 App Paths，不依赖 PATH）
    if (-not (Get-Process chrome -ErrorAction SilentlyContinue)) {
        Write-Log "Chrome 未运行，自动启动..."
        try {
            Start-Process "chrome"
            Start-Sleep -Seconds 10
            Write-Log "Chrome 已启动，等待扩展连接..."
        } catch {
            Write-Log "无法启动 Chrome: $_" -Level Error
        }
    }

    # 启动 daemon（-NoOutput：daemon fork 子进程会继承管道导致 WaitForExit 死锁）
    $dr = Invoke-BskWithTimeout -ArgsList @("daemon","start") -TimeoutMs 10000 -NoOutput
    if ($dr.TimedOut) {
        Get-Process -Name "bsk" -ErrorAction SilentlyContinue |
            ForEach-Object { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue }
        Remove-Item $lockFile -Force -ErrorAction SilentlyContinue
        Invoke-BskWithTimeout -ArgsList @("daemon","start") -TimeoutMs 10000 -NoOutput | Out-Null
    }
    # 轮询等待 daemon 真正 ready（named pipe 可能尚未就绪）
    $daemonReady = $false
    for ($i = 0; $i -lt 10; $i++) {
        $check = Invoke-BskWithTimeout -ArgsList @("status") -TimeoutMs 3000
        if ($check.Output -match 'daemon version') {
            $daemonReady = $true
            Write-Log "daemon 已启动 (等待 ${i}s)"
            break
        }
        Start-Sleep -Seconds 1
    }
    if (-not $daemonReady) {
        Write-Log "daemon 第一轮启动无响应，重启 daemon..." -Level Warn
        Get-Process -Name "bsk" -ErrorAction SilentlyContinue |
            ForEach-Object { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue }
        Remove-Item $lockFile -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
        Invoke-BskWithTimeout -ArgsList @("daemon","start") -TimeoutMs 10000 -NoOutput | Out-Null
        for ($i = 0; $i -lt 10; $i++) {
            $check = Invoke-BskWithTimeout -ArgsList @("status") -TimeoutMs 3000
            if ($check.Output -match 'daemon version') {
                $daemonReady = $true
                Write-Log "daemon 已重启 (等待 ${i}s)"
                break
            }
            Start-Sleep -Seconds 1
        }
    }
    if (-not $daemonReady) {
        Write-Log "daemon 启动失败，终止" -Level Error
        return
    }

    # ──── 1. 启动会话 ────
    $sid = Start-BskSession -BrowserInstanceId $BrowserInstanceId
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

            # 一次性 JS 完成：定位输入框 → 填值 → 触发 Vue 事件 → 点登录按钮
            $js = $script:fillAndLoginJs.Replace('__USER__', $loginUser).Replace('__PASS__', $loginPass)
            Write-Log "[诊断] 发送给浏览器的 JS: $js"
            $fillRes = Invoke-BskEvaluate -SessionId $sid -Script $js
            Write-Log "登录提交结果: $fillRes"
            Start-Sleep -Seconds 3

            # 验证（最多重试一次处理 SSO 拦截）
            Write-Log "等待跳转..."
            Start-Sleep -Seconds 5

            $url = Invoke-BskEvaluate -SessionId $sid -Script "window.location.href"
            if ($url -like "*portal-hmg*" -or $url -like "*sso*") {
                Write-Log "检测到 SSO 拦截，切回数据门户重新登录..." -Level Warn
                # 复用同一个 JS 重新填凭据 + 点登录
                Invoke-BskNavigate -SessionId $sid -Url $LoginUrl[$Env] -WaitSec 3
                Invoke-BskEvaluate -SessionId $sid -Script $js | Out-Null
                Start-Sleep -Seconds 5
                $url = Invoke-BskEvaluate -SessionId $sid -Script "window.location.href"
            }

            if ($url -and $url -notlike "*/superLogin*" -and $url -notlike "*/login*") {
                Write-Log "登录成功" -Level Success
            } else {
                Write-Log "登录失败，当前 URL: $url" -Level Error
                # 快照当前页面用于诊断
                $diagSnap = Invoke-BskSnapshot -SessionId $sid -RawText
                Write-Log "[诊断] 登录失败时页面内容:"
                $diagSnap -split "`n" | ForEach-Object { Write-Log "[诊断]   $_" }
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

        for ($i = 0; $i -lt $total; $i++) {
            $r = $reports[$i]
            # 跳过空名称的报表（树解析偶发）
            if ([string]::IsNullOrEmpty($r.ReportName)) { continue }
            Write-Log "--- [$($i+1)/$total] ---"
            $result = Invoke-ReportWarmup -SessionId $sid -Report $r
            $results += $result
            if ($result.Status -eq "Success") { $successCount++ } else { $failCount++ }

            if (($i + 1) % 5 -eq 0 -or $i -eq $total - 1) {
                Write-Log "[统计] $($i+1)/$total | 成功 $successCount | 失败 $failCount"
            }
        }

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
    } finally {
        # 退出登录：hover 右上角用户菜单 → click「退出」
        try {
            Write-Log "退出登录..."
            Invoke-BskNavigate -SessionId $sid -Url $PortalHome[$Env] -WaitSec 3
            $logoutJs = @'
(function() {
    var btn = document.querySelector('button');
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
'@
            Invoke-BskEvaluate -SessionId $sid -Script $logoutJs | Out-Null
            Start-Sleep -Seconds 3
            $url = Invoke-BskEvaluate -SessionId $sid -Script "window.location.href"
            if ($url -match "login") { Write-Log "已退出登录" } else { Write-Log "退出登录完成" }
        } catch {
            Write-Log "退出登录失败: $_" -Level Warn
        }
        Stop-BskSession -SessionId $sid
        Write-Log "流程结束"
    }
}

# functions are available via dot-source
