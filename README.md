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
│   ├── core.ps1                # bsk 操作封装
│   └── warmup.ps1              # 预热核心逻辑
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
.\bsk status     # 返回 daemon running + browsers connected 即正常
```

### 3. 配置凭据 + 运行

编辑 `config/credential.ps1`，填入对应环境的账号密码，双击 `run.bat`。

---

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

若提示"禁止运行脚本"，先执行（仅首次需要）：

```powershell
Set-ExecutionPolicy RemoteSigned -Scope CurrentUser
```

---

## 核心流程

```
1. bsk session start                    启动浏览器会话
2. navigate → 超级登录页                 导航到登录页
3. evaluate 填凭据 + click 登录          JS 直接操作 DOM（绕过 bsk fill 写入问题）
   └─ 自动跳转首页
4. click「报表中心」                      进入报表树
5. 展开所有节点 → snapshot 抓取 AX 树    解析 depth=2 分类 / depth=3 报表
6. 注册全局 MutationObserver             常驻监听 iframe 替换
7. 遍历每个报表：
    ├─ __bskBeforeSrc = 当前 iframe src
    ├─ evaluate click 树节点
    ├─ 轮询 __bskLoaded（每 1s，最多 15s）
    │   ├─ load 事件触发 → 三重验证
    │   │   ├─ src 确实变了
    │   │   ├─ 是有效的 Tableau URL（/trusted/ 或 /views/）
    │   │   └─ iframe title = "数据可视化"
    │   │   → 全部满足 → Success
    │   └─ 15s 超时 → Failed
    └─ 下一个
8. 输出 CSV 到 logs/<时间>/
9. bsk session stop
```

### 加载判定逻辑

| 检测手段 | 目的 |
|----------|------|
| MutationObserver | 捕捉 SPA 替换 iframe 元素的时机 |
| iframe `load` 事件 | 跨域 iframe 加载完成的最精确信号 |
| src 变化验证 | 排除"假连接"旧 load 事件误触 |
| `/trusted/` 或 `/views/` 检查 | 确保是 Tableau 报表 URL |
| title="数据可视化" | 区分正常报表与打不开的无效报表 |

### 退出码

| 退出码 | 含义 |
|--------|------|
| 0 | 全部成功 |
| 1 | 环境错误（bsk.exe 未找到 / 凭据未配置 / 异常） |
| 2 | 存在失败的报表 |

---

## 定时任务

### 配置

编辑 `config/scheduler-config.ps1`：

```powershell
$WarmupSchedule = @{
    Enabled      = $true           # 开启定时任务
    Hour         = 8               # 执行时间（24 小时制）
    Minute       = 30
    RepeatEvery  = 0               # 重复间隔（小时，支持小数）
                                   # 0=不重复；0.5=每30分钟；1=每1小时
    Env          = "test"          # 执行环境：test / prod
    ReportFilter = ""              # 可选，按关键字过滤
}

$DaemonAutoStart = @{
    Enabled = $true                # bsk daemon 开机自启
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
# 查看任务状态
Get-ScheduledTask -TaskName "bsk-*"

# 或 cmd 下
schtasks /query /tn "bsk-warmup"
```

状态 `Ready` = 等待触发，`Running` = 正在执行。执行后在 `logs/` 目录看有无新文件夹。

### 工作原理

```
开机 → bsk-daemon 任务启动 daemon（用户登录时）
     → 浏览器手动打开 + 扩展保持连接

到点 → bsk-warmup 任务调用 run.ps1 -Env test
     → 自动预热 → 输出结果到 logs/ → 退出
```

- `run.bat` — 给人双击调试（有 pause，防窗口闪退）
- `run.ps1` — 给定时任务调度（无交互阻塞，显式传 -Env 跳过菜单）

---

## 关于 bsk.exe

**bsk.exe** 是腾讯开源项目 [BrowserSkill](https://github.com/Tencent/BrowserSkill) 的核心 CLI 工具（MIT 协议，Rust 编写，6MB 单文件二进制）。

### 架构链路

```
你的脚本 / AI Agent
    │  shell 命令: bsk navigate xxx
    ▼
bsk CLI     →  IPC  →  bsk Daemon  →  WebSocket (127.0.0.1)
    ▼
BrowserSkill 扩展  →  CDP 协议  →  Agent Window（独立窗口，不干扰正常页面）
```

全链路在本机，不走外网。

### 提供的命令

| 命令 | 说明 |
|------|------|
| `bsk session start/stop` | 管理浏览器会话 |
| `bsk navigate <url>` | 导航到 URL |
| `bsk snapshot` | 抓取页面 AX 无障碍树（结构化文本） |
| `bsk click <ref>` | 点击页面元素 |
| `bsk evaluate <js>` | 执行任意 JavaScript 并返回结果 |
| `bsk daemon` | 管理后台守护进程 |
| `bsk doctor` | 一键诊断所有组件状态 |

> 本项目本质上是把 bsk 命令串联成「登录 → 树扫描 → 遍历报表 → 检测加载」的自动化编排器。

---

## 设计思路

### 与传统方案对比

| | Selenium / Playwright | 本方案 |
|---|---|---|
| 安装 | 安装运行时 + 对应版本 WebDriver | 扩展 + 单文件二进制，即拷即用 |
| 浏览器 | 新建实例，需要额外登录 | **复用已登录的浏览器** |
| 页面交互 | CSS/XPath 定位 | snapshot AX 树 + ref |
| SPA 兼容 | `waitFor` 路由等待 | evaluate 直接设值 + dispatchEvent |
| 跨域 iframe | `frame.contentWindow` 可访问 | 父页面 MutationObserver + load + title |
| 报表清单 | 维护静态文件 | 页面树动态扫描，自动发现 |
| 调度 | cron / Airflow | Windows 任务计划程序（原生） |

### 关键决策

| 决策 | 原因 |
|------|------|
| `[Console]::OutputEncoding = UTF8` | 解决 bsk snapshot JSON 中文乱码导致解析失败 |
| JS evaluate 操作 DOM | 绕过 `bsk fill` 写入不生效，dispatchEvent 触发 Vue 响应式 |
| 全局常驻 MutationObserver | 避免每次点击重建 listener 的间隙漏判 |
| 三重验证（src + URL + title） | 区分正常报、假连接误触、打不开的无效报表 |

---

## 日志

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

---

## 常见问题

| 问题 | 原因 | 解决 |
|------|------|------|
| 浏览器扩展显示 connected 但脚本报 no browser | daemon 与扩展 WebSocket 假连接 | 点扩展图标断开再重连 |
| snapshot 解析中文乱码 | PowerShell 输出编码非 UTF-8 | 已在 run.ps1 中设置 `[Console]::OutputEncoding = UTF8` |
| 结果 CSV 有空行 | Export-Csv 遇到空元素 | 已在导出处加 `Where-Object { $_.ReportName }` 过滤 |
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
