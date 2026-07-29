# bsk.exe 报表预热自动化

定时通过 **bsk.exe** 驱动真实浏览器，遍历数据门户报表中心下所有报表，逐一打开触发 Tableau 服务端缓存。

**零依赖部署** — 整个项目拷贝即用，无需安装 Python/Node.js/Selenium/WebDriver。

## 目录结构

```
bsk-automation/
├── bsk.exe                     # bsk CLI 二进制（项目自带）
├── BrowserSkill-0.1.3_0.zip   # browser-skill 扩展离线包
├── config/
│   ├── settings.ps1            # ���境 URL + bsk 路径自动检测
│   ├── credential.ps1          # 账号凭据（每台电脑独立配置）
│   └── scheduler-config.ps1   # 定时任务配置
├── lib/
│   ├── core.ps1                # bsk 操作封装 + .NET Process 超时 + 会话断开检测
│   └── warmup.ps1              # 预热核心逻辑 + 死锁看门狗
├── logs/                       # 执行日志（按次分目录）
├── run.bat                     # 调试入口：双击运行
├── run.ps1                     # 生产入口（含交互式环境选择菜单）
├── install-scheduler.ps1      # 定时任务一键部署脚本
└── README.md
```

## 前置依赖

| 依赖 | 来源 |
|------|------|
| Chrome | 脚本自动启动（无需手动打开） |
| browser-skill 扩展 | 项目自带离线包 `.zip`，拖拽安装 |
| bsk.exe | 项目自带 |
| PowerShell | Windows 自带 |

## 新电脑部署

### 1. 安装 browser-skill 扩展

- Chrome → `chrome://extensions/` → 开启「开发者模式」
- 拖拽 `BrowserSkill-0.1.3_0.zip` 到扩展页面
- 确认右上角弹窗显示 **connected**

### 2. 验证

```bash
.\bsk daemon start
.\bsk status     # 应显示 daemon version + browsers connected 1
```

### 3. 配置凭据

编辑 `config/credential.ps1`，填入账号密码。双击 `run.bat` 调试。

## 使用方式

### 调试（双击 run.bat）

15 秒倒计时菜单：按 0 → 生产环境 / 其他键 → 测试环境 / 超时 → 测试环境

### 生产（命令行 / 定时任务）

```powershell
.\run.ps1 -Env test                             # 测试环境
.\run.ps1 -Env prod                             # 生产环境
.\run.ps1 -Env test -ResumeFrom "分类/报表名"   # 断点恢复
.\run.ps1 -Env test -ReportFilter "销售"        # 按关键字过滤
.\run.ps1 -Env test -NoLogin                    # 跳过登录
```

## 核心流程

```
 0. 杀残留 bsk → 清锁 → Chrome 兜底启动（轮询进程出现，最多 5s）
 1. 启动 daemon → 轮询确认就绪（最多 6 次 / 3s 间隔）
 2. 会话启动 → 等待浏览器连接
 3. 导航超管登录页 → 预检 SSO 拦截 → 填凭据（JS querySelector + dispatchEvent）
     → CDP 级点击登录按钮（绕过 Vue 虚拟 DOM handler）
    ├─ 跳转首页 → 继续
    └─ 被 SSO 拦截 → 切回 superLogin 重登一次
 4. 导航首页 → 点击「报表中心」→ snapshot 抓取 AX 树 → 展开 el-tree
 5. 启动死锁看门狗（后台 Job，每 5s 检测 bsk CPU，60s 无变化 → 杀进程退出）
 6. 遍历报表（轮询 iframe load 事件，15s 超时）：
    ├─ click 树节点
    ├─ 等 MutationObserver load 事件 → 三重验证（src 变了 + Tableau URL + title）
    └─ 检测到会话断开（__SESSION_DEAD__）→ 终止循环
 7. 输出 CSV → logs/
 8. 停止看门狗 → 退出登录（当前页面 hover 用户菜单 → 点「退出」）→ 关闭会话
```

### 退出码

| 码 | 含义 |
|----|------|
| 0 | 全部成功 |
| 1 | 环境错误 / 异常 |
| 2 | 存在失败报表（bat 提示 `[WARN]`，非错误） |

## 定时任务

### 配置文件 `config/scheduler-config.ps1`

```powershell
$WarmupSchedule = @{
    Enabled      = $true       # 开关
    Hour         = 8           # 首次触发小时
    Minute       = 30          # 首次触发分钟
    ActiveEnd    = 20          # 截止小时（不含），时长自动计算
    RepeatEvery  = 0.5         # 重复间隔（小时；0=不重复）
    Env          = "test"
}
$DaemonAutoStart = @{ Enabled = $true }   # daemon 开机自启
```

`/st` 直接在配置的 `Hour:Minute` 触发，时长 = `ActiveEnd - Hour:Minute`。

### 部署（管理员 PowerShell）

```powershell
cd D:\WorkBuddy\报表预热自动化\bsk-automation
.\install-scheduler.ps1
```

修改配置后重跑即可更新。

## 关键设计决策

| 决策 | 原因 |
|------|------|
| Chrome 自动启动（Start-Process "chrome"） | 走注册表 App Paths，无需写死路径 |
| daemon 启动后轮询确认就绪 | named pipe 可能未就绪 |
| 登录拆两步：JS 填值 + CDP 点击 | JS 填值免疫 AX 树偏移；CDP 点击绕过 Vue handler |
| 凭据用 JS 单引号 `'testyure'` | PowerShell `&` 底层会剥掉双引号 |
| 死锁看门狗（后台 Job 监控 bsk CPU） | Chrome hung 后 60s 自动杀进程退出，下轮定时续跑 |
| 会话断开检测（`__SESSION_DEAD__`） | 浏览器关闭后不等 15s 逐个超时，直接终止循环 |
| 退出登录不跳转首页 | 在当前报表页面直接 hover 用户菜单退出 |
| JS evaluate 填凭据 + dispatchEvent | 绕过 bsk fill 不生效，触发 Vue 响应式 |
| 全局 MutationObserver + 三重验证 | 区分正常报表与伪加载 |
| `schtasks /du` 实现时间段控制 | Windows 原生，脚本不做运行时检查 |
| `$LASTEXITCODE` 污染修复 | `/delete` exit code 不干扰 `/create` 判断 |

## 常见问题

| 问题 | 原因 | 解决 |
|------|------|------|
| 定时任务触发后窗口闪退 | PowerShell 语法错误（here-string / 变量拼写） | 查看最新日志，语法错误不会创建日志目录 |
| `daemon.json` 缺失导致 daemon 失败 | 脚本误写 `daemon.json` 而非 `daemon.lock` | 已修复，手动 `bsk daemon start` 恢复 |
| Chrome 打开后仍然卡死 | 连续 220+ 报表高频切换 WebView | 死锁看门狗 60s 自动杀进程退出 |
| 浏览器关闭后脚本不终止 | evaluate 失败但循环继续 | `__SESSION_DEAD__` 检测 → throw 终止 |
| 登录被 SSO 拦截（下班后） | SSO 会话过期 | 填凭据前预检 + 登录后自动切回重试 |
| install-scheduler 报 `Set-ScheduledTask` 拒绝访问 | 非管理员或任务权限冲突 | 不影响 warmup 任务创建，daemon 已有任务无需更新 |
| install-scheduler 显示 `[!!] warmup task failed` | `$LASTEXITCODE` 被 `/delete` 污染 | 已修复，不影响实际创建结果 |

## 跨机器

| 文件 | 策略 |
|------|------|
| `config/settings.ps1` | 自动检测 bsk 路径，直接拷贝 |
| `config/credential.ps1` | 每台独立配置 |
| `config/scheduler-config.ps1` | 直接拷贝，改时间 |
| 其他所有文件 | 直接拷贝 |
