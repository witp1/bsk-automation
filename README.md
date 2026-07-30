# bsk.exe 报表预热自动化

定时通过 **bsk.exe** 驱动真实浏览器，遍历数据门户报表中心下所有报表，逐一打开触发 Tableau 服务端缓存。

**零依赖部署** — 整个项目拷贝即用，无需安装 Python/Node.js/Selenium/WebDriver。

## 目录结构

```
bsk-automation/
├── bsk.exe                     # bsk CLI 二进制（项目自带）
├── BrowserSkill-0.1.3_0.zip   # browser-skill 扩展离线包
├── config/
│   ├── settings.ps1            # 环境 URL + bsk 路径自动检测
│   ├── credential.ps1          # 账号凭据
│   └── scheduler-config.ps1   # 定时任务配置
├── lib/
│   ├── core.ps1                # bsk 操作封装 + session 自动重启 Chrome
│   └── warmup.ps1              # 预热核心逻辑 + 死锁看门狗 + 三级登录降级
├── logs/                       # 执行日志（按次分目录）
├── run.bat                     # 调试入口：双击运行
├── run.ps1                     # 生产入口（含交互式环境选择菜单）
├── install-scheduler.ps1      # 定时任务一键部署脚本
└── README.md
```

## 前置依赖

| 依赖 | 来源 |
|------|------|
| Chrome | 脚本自动启动 |
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
 0. 检查 daemon → 活着且 pipe 可用则复用，否则杀残留 + 重启
 1. Chrome 兜底启动 → daemon 就绪（daemon.json 检测）
 2. 会话启动 → 自动重试（失败则杀 Chrome 重启扩展）
 3. 登录（三级降级，最多 3 次尝试）：
    L1: bsk fill (CDP 键盘输入) → 验证 DOM → click → 等跳转
    L2: JS evaluate fill (原生 setter) → 验证 DOM → click → 等跳转
    L3: 全栈重启（杀 daemon + 杀 Chrome + 完整重来）
    ├─ 跳转首页 → 继续
    └─ SSO 拦截 → 自动切回重试
 4. 导航首页 → 点击「报表中心」→ snapshot 抓取 AX 树 → 展开 el-tree
 5. 启动死锁看门狗（后台 Job，每 5s 检测 bsk CPU，60s 无变化 → 杀进程）
 6. 遍历报表（轮询 iframe load 事件，15s 超时）
 7. 输出 CSV → logs/
 8. finally: 杀 daemon → 退出登录 → 停止会话
```

### 退出码

| 码 | 含义 |
|----|------|
| 0 | 全部成功 |
| 1 | 环境错误 / 异常 |
| 2 | 存在失败报表 |

## 定时任务

### 配置文件 `config/scheduler-config.ps1`

```powershell
$WarmupSchedule = @{
    Enabled      = $true       # 开关
    Hour         = 8           # 首次触发小时
    Minute       = 30          # 首次触发分钟
    ActiveEnd    = 20          # 截止小时（不含），如 8:30~20:00 则设 20
    RepeatEvery  = 0.25        # 重复间隔（小时；0=不重复）
    Env          = "test"
}
$DaemonAutoStart = @{ Enabled = $true }
```

### 部署（管理员 PowerShell）

```powershell
cd D:\WorkBuddy\报表预热自动化\bsk-automation
.\install-scheduler.ps1
```

修改配置后重跑即可更新。如果任务被手动 `schtasks /change /disable` 禁用过，需先 `schtasks /delete /tn bsk-warmup /f` 再重跑 install。

## 关键设计决策

| 决策 | 原因 |
|------|------|
| daemon 复用（检查 pipe 活性） | 避免每次杀 daemon 导致扩展断连 |
| daemon.json 文件检测代替 bsk status | bsk status 的 named pipe 连接间歇性故障 |
| 登录三级降级（bsk fill / JS fill / 全栈重启） | 锁屏后 CDP 渲染异常，逐级降级保证登录成功 |
| bsk fill 填表单 | CDP 级键盘输入，触发框架内部 state（优于 JS evaluate） |
| session start 失败自动重启 Chrome | 锁屏后扩展断连，重启 Chrome 强制扩展重连 |
| finally 块第一行杀 daemon | 避免后续 bsk evaluate/stop 等命令挂死在死 pipe 上 |
| 启动时杀残留 bsk + 删 daemon.lock + daemon.json | 旧 daemon 子进程可能残存，端口冲突导致新 daemon 失败 |
| 死锁看门狗 | Chrome hung 后 60s 自动杀进程退出，下轮定时续跑 |
| 会话断开检测（`__SESSION_DEAD__`） | 浏览器关闭后不等 15s 逐个超时 |
| 退出登录在当前页 hover 用户菜单 | 不跳转首页，减少页面导航 |
| 全局 MutationObserver + 三重验证 | 区分正常报表与伪加载 |
| `schtasks /du` 实现时间段控制 | Windows 原生，脚本不做运行时检查 |

## 常见问题

| 问题 | 原因 | 解决 |
|------|------|------|
| 锁屏后定时任务登录失败 | Chrome GPU 渲染上下文破坏，CDP fill 不生效 | 三级降级自动处理，最终全栈重启 |
| 定时任务一直"正在运行"不退出 | finally 块 daemon 被杀后 bsk 命令挂死在死 pipe | 已修复：taskkill 移到 finally 第一行 |
| 定时任务不按预期时间触发 | 上一个实例还在跑，计划任务不会启新实例 | 等待上轮结束或手动 taskkill |
| 首次部署定时任务显示 `[!!] failed` | `$LASTEXITCODE` 被 `/delete` 污染 | 不影响实际创建，可用 schtasks /query 验证 |
| daemon 反复启动失败 | 残留 daemon 进程占用 52800 端口 | 管理员 CMD: `taskkill /f /im bsk.exe`，再跑脚本 |
| Chrome 打开后预热卡死 | 连续 220+ 报表高频切换 | 死锁看门狗 60s 自动杀进程退出 |

## 跨机器

| 文件 | 策略 |
|------|------|
| `config/settings.ps1` | 自动检测 bsk 路径，直接拷贝 |
| `config/credential.ps1` | 每台独立配置 |
| `config/scheduler-config.ps1` | 直接拷贝���改时间 |
| 其他所有文件 | 直接拷贝 |
