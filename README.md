# bsk.exe 报表预热自动化

定时通过 **bsk.exe** 驱动真实浏览器，遍历数据门户报表中心下所有报表，逐一打开触发 Tableau 服务端缓存，提升报表加载速度、优化用户访问体验。

**零依赖部署** — 整个项目拷贝即用，无需安装 Python/Node.js/Selenium/WebDriver。

## 目录结构

```
bsk-automation/
├── bsk.exe                     # bsk CLI 二进制（项目自带）
├── BrowserSkill-0.1.3_0.zip   # browser-skill 扩展离线包
├── config/
│   ├── settings.ps1            # 环境 URL + bsk 路径自动检测
│   ├── credential.ps1          # 账号凭据（每台电脑独立配置）
│   └── scheduler-config.ps1   # 定时任务配置文件
├── lib/
│   ├── core.ps1                # bsk 操作封装（会话管理、浏览器操作）
│   └── warmup.ps1              # 预热核心逻辑（树扫描 + iframe 检测）
├── logs/                       # 执行日志（按次分目录）
│   └── YYYY-MM-DD_HH-mm-ss/
│       ├── warmup_test.log
│       └── result_test.csv
├── run.bat                     # 调试入口：双击运行
├── run.ps1                     # 生产入口（含交互式环境选择菜单）
├── install-scheduler.ps1      # 定时任务一键部署脚本
└── README.md
```

## 前置依赖

| 依赖 | 来源 |
|------|------|
| Chrome 或 Edge | 电脑自带 |
| browser-skill 扩展 | 项目已自带离线包 `.zip`，拖拽安装 |
| bsk.exe | 项目已自带，即拷即用 |
| PowerShell | Windows 自带 |

## 新电脑部署

### 1. 安装 browser-skill 扩展

- 打开 Chrome → `chrome://extensions/` → 回车
- **开启**右上角「开发者模式」
- 将 `BrowserSkill-0.1.3_0.zip` **拖拽**到扩展页面
- 确认浏览器右上角弹窗显示 **connected**

> 离线包不能自动安装 bsk.exe，所以项目已自带。

### 2. 验证 bsk

```bash
.\bsk daemon start
.\bsk status     # 应显示 daemon running + browsers connected 1
```

### 3. 配置凭据 + 运行

编辑 `config/credential.ps1`，填入对应环境的账号密码，双击 `run.bat`。

## 使用方式

### 调试阶段（双击 run.bat）

双击 `run.bat`，显示 15 秒倒计时菜单：
- **按 0** → 生产环境
- **按其他任意键** → 测试环境
- **超时** → 默认测试环境

### 生产阶段（任务计划程序 / 脚本调用）

显式指定 `-Env` 参数时**直接执行**，不显示菜单：

```powershell
.\run.ps1 -Env test                             # 测试环境
.\run.ps1 -Env prod                             # 生产环境
.\run.ps1 -Env test -ResumeFrom "分类/报表名"   # 断点恢复
.\run.ps1 -Env test -ReportFilter "销售"        # 按关键字过滤
.\run.ps1 -Env test -NoLogin                    # 跳过登录
```

### 权限

若提示"禁止运行脚本"，执行（仅首次需要）：

```powershell
Set-ExecutionPolicy RemoteSigned -Scope CurrentUser
```

## 核心流程

```
 0. 预热启动
    ├─ daemon 自愈
    │   ├─ bsk status → 没在跑 → 清残留锁文件 → bsk daemon start
    │   └─ 已在跑 → 跳过
    │
    ├─ 等待浏览器连接（轮询每 3s，最多 60s）
    │   ├─ bsk status → browsers connected ≥ 1 → 继续
    │   └─ 超时 → 报错退出
    │
    ├─ bsk session start（30s 超时 via Start-Job）
    │   └─ 拿到 session_id → 继续
    │
 1. navigate → 超级登录页
 2. JS evaluate 填凭据 + click 登录 → 自动跳转首页
 3. click「报表中心」→ 展开所有节点
 4. snapshot 抓取 AX 树 → 解析 depth=2 分类 / depth=3 报表
 5. 注册全局 MutationObserver → 常驻监听 iframe 替换
 6. 遍历每个报表（每 1s 轮询，最多 15s）：
    ├─ 记录点击前 iframe src（__bskBeforeSrc）
    ├─ evaluate click 树节点
    ├─ 等待 load 事件（__bskLoaded）
    │   └─ 触发后 → 三重验证
    │       ├─ src 变了
    │       ├─ 是 Tableau URL（/trusted/ 或 /views/）
    │       └─ iframe title = "数据可视化"
    │       → 全部满足 → Success；否则重置标志位继续等
    └─ 15s 超时 → Failed
 7. 输出 CSV → logs/<时间>/result_<env>.csv
 8. bsk session stop
```

### 退出码

| 退出码 | 含义 |
|--------|------|
| 0 | 全部成功 |
| 1 | 环境错误（bsk.exe 未找到 / 凭据未配置 / 异常） |
| 2 | 存在失败的报表 |

## 定时任务

### 配置

编辑 `config/scheduler-config.ps1`：

```powershell
$WarmupSchedule = @{
    Enabled      = $true       # 开启定时任务
    Hour         = 8           # 执行时间（24 小时制）
    Minute       = 30
    RepeatEvery  = 0           # 重复间隔（小时，支持小数）
                               # 0=不重复；0.5=每30分钟；1=每1小时
    Env          = "test"      # 执行环境：test / prod
    ReportFilter = ""          # 可选，按关键字过滤
}

$DaemonAutoStart = @{
    Enabled = $true            # bsk daemon 开机自启
}
```

### 部署

**以管理员身份运行** PowerShell：

```powershell
cd D:\WorkBuddy\报表预热自动化\bsk-automation
.\install-scheduler.ps1
```

每次修改配置后重跑一次即可更新任务。

### 验证

```powershell
Get-ScheduledTask -TaskName "bsk-*"
```

或：

```cmd
schtasks /query /tn "bsk-warmup" /fo list
```

状态 `Ready` = 等待触发，`Running` = 正在执行。

### 工作原理

```
开机 → bsk-daemon 任务启动 daemon（用户登录时触发）

到点 → bsk-warmup 任务调用 run.ps1 -Env test
     → 脚本自愈 daemon → 等待浏览器重连 → 预热 → logs/ → 退出
```

- `run.bat` — 给人双击调试（有 pause，防窗口闪退）
- `run.ps1` — 给定时任务调度（无交互阻塞，显式传 -Env 跳过菜单）

## 关于 bsk.exe

**bsk.exe** 是腾讯开源项目 [BrowserSkill](https://github.com/Tencent/BrowserSkill) 的核心 CLI 工具（MIT 协议，Rust 编写，6MB 单文件二进制）。它把「控制浏览器」变成了一组 shell 命令。

### 架构链路

```
你的脚本 / AI Agent
    │  shell 命令: bsk xxx
    ▼
bsk CLI → IPC → bsk Daemon → WebSocket (127.0.0.1)
    ▼
BrowserSkill 扩展 → CDP 协议 → Agent Window
```

全链路在本机，不走外网。

### 提供的命令

| 命令 | 说明 |
|------|------|
| `bsk session start/stop` | 管理浏览器会话 |
| `bsk navigate <url>` | 导航到 URL |
| `bsk snapshot` | 抓取页面 AX 无障碍树 |
| `bsk click <ref>` | 点击页面元素 |
| `bsk evaluate <js>` | 执行任意 JavaScript |
| `bsk daemon` | 管理后台守护进程 |
| `bsk doctor` | 一键诊断 |
| `bsk status` | 查看 daemon + 浏览器连接状态 |

> 本项目本质上是把 bsk 命令串联成「登录 → 树扫描 → 遍历报表 → 检测加载」的自动化编排器。

## 设计思路

### 与传统方案对比

| | Selenium / Playwright | 本方案 |
|---|---|---|
| 安装 | 安装运行时 + 对应版本 WebDriver | 扩展 + 单文件二进制，即拷即用 |
| 浏览器 | 新建实例，需要额外登录 | **复用已登录的浏览器** |
| 跨域 iframe | `frame.contentWindow` 可访问 | 父页面 MutationObserver + load + title |
| 报表清单 | 维护静态文件 | 页面树动态扫描，自动发现 |
| 调度 | cron / Airflow | Windows 任务计划程序（原生） |

### 关键决策

| 决策 | 原因 |
|------|------|
| `[Console]::OutputEncoding = UTF8` | 解决 bsk snapshot JSON 中文乱码 |
| JS evaluate 操作 DOM | 绕过 `bsk fill` 写入不生效，dispatchEvent 触发 Vue 响应式 |
| MutationObserver + 三重验证（src + URL + title） | 区分正常报表与假连接/打不开的无效报表 |
| `Start-Job` + `Wait-Job -Timeout 30` | 避免 `bsk session start` 无浏览器时无限等待 |
| 轮询 `bsk status`（每 3s，最多 60s） | daemon 启动后等待浏览器扩展自动重连 |
| daemon 启动时清残留锁文件 | 解决上次异常退出后 daemon 无法启动的问题 |
| `schtasks.exe` 创建定时任务 | 回避 PowerShell 5.1 `RepetitionInterval` 的兼容性问题 |

## 日志

每次执行自动创建独立子目录，按开始时间命名 `yyyy-MM-dd_HH-mm-ss`。

```
logs/
└── 2026-07-28_10-08-00/
    ├── warmup_test.log        # 详细执行日志
    └── result_test.csv        # 结果汇总
```

CSV 字段：

| 字段 | 说明 |
|------|------|
| ReportName | 分类/报表名 |
| Status | Success / Failed / Skipped |
| Duration | 单个报表耗时（秒） |
| Error | 失败原因 |

## 常见问题

| 问题 | 原因 | 解决 |
|------|------|------|
| `bsk daemon start` 报 `no valid daemon.json` | 上次异常退出残留锁文件 | 删 `~/.bsk/daemon.lock` 和 `daemon.json`（脚本已自动处理） |
| 浏览器扩展显示 connected 但脚本报无浏览器 | daemon 与扩展 WebSocket 假连接 | 点扩展图标断开再重连 |
| daemon 自己停了 | 空闲 600 秒后自动退出 | 脚本已自动检测并重启 |
| 定时任务卡住不退出 | 之前代码无超时，`session start` 死等 | 已改为 job + 30s 超时 |
| snapshot 解析中文乱码 | PowerShell 输出编码问题 | 已在 run.ps1 设置 `OutputEncoding = UTF8` |
| 结果 CSV 有空行 | Export-Csv 遇到空元素 | 已加 `Where-Object { $_.ReportName }` 过滤 |
| install-scheduler 报拒绝访问 | 非管理员身份 | 右键 PowerShell → 以管理员身份运行 |

## 跨机器

| 文件 | 策略 |
|------|------|
| `config/settings.ps1` | 自动检测 bsk 路径，直接拷贝 |
| `config/credential.ps1` | 每台电脑独立配置 |
| `config/scheduler-config.ps1` | 直接拷贝，部署时改执行时间 |
| `bsk.exe` | 直接拷贝，即拷即用 |
| `lib/*.ps1` | 直接拷贝 |
| `logs/` | 按需拷贝 |
