# bsk.exe 报表预热自动化

定时通过 **bsk.exe** 驱动真实浏览器，遍历数据门户报表中心下所有报表，逐一打开触发 Tableau 服务端缓存，提升报表加载速度、优化用户访问体验。

**零依赖部署**——整个项目拷贝即用，无需安装 Python/Node.js/Selenium/WebDriver。

---

## 目录结构

```
bsk-automation/
├── bsk.exe                     # bsk CLI 二进制（项目自带）
├── BrowserSkill-0.1.3_0.zip   # browser-skill 扩展离线包
├── config/
│   ├── settings.ps1            # 环境 URL + bsk 路径自动检测
│   └── credential.ps1          # 账号凭据（每台电脑独立配置）
├── lib/
│   ├── core.ps1                # bsk 操作封装
│   └── warmup.ps1              # 预热核心逻辑
├── logs/                       # 执行日志（按次分目录）
│   └── YYYY-MM-DD_HH-mm-ss/
│       ├── warmup_test.log
│       └── result_test.csv
├── run.bat                     # 调试入口：双击运行，自动进入交互菜单
├── run.ps1                     # 生产入口（含交互式环境选择菜单）
└── README.md
```

---

## 关于 bsk.exe

**bsk.exe** 是腾讯开源项目 [BrowserSkill](https://github.com/Tencent/BrowserSkill) 的核心命令行工具（MIT 协议，Rust 编写）。它的本质是一个「浏览器遥控器」——任何能调 Shell 的程序（PowerShell、AI Agent、批处理脚本）都能通过它控制真实浏览器，无需 WebDriver、无需 Selenium。

### 完整链路

```
你的脚本 / AI Agent
    │  shell 命令: bsk navigate xxx
    ▼
bsk CLI（命令行工具）          ← Rust 二进制，6MB，单文件即拷即用
    │  IPC 本地进程间通信
    ▼
bsk Daemon（后台守护进程）      ← 常驻后台，管理浏览器会话
    │  WebSocket (127.0.0.1)   ← 全在本机，不走外网
    ▼
BrowserSkill 扩展              ← 装在 Chrome/Edge 里的插件
    │  CDP 协议（Chrome DevTools Protocol）
    ▼
Agent Window（独立浏览器窗口）  ← 橙色高亮框，不干扰正常页面
```

### 提供的命令

| 命令 | 说明 |
|------|------|
| `bsk navigate <url>` | 导航到 URL |
| `bsk snapshot` | 抓取页面 AX 无障碍树（结构化文本，非截图） |
| `bsk click <ref>` | 点击页面元素 |
| `bsk fill <ref> <value>` | 填入文本 |
| `bsk evaluate <js>` | 执行任意 JavaScript 并返回结果 |
| `bsk session start/stop` | 管理浏览器会话 |
| `bsk daemon` | 启动后台守护进程 |
| `bsk doctor` | 一键诊断所有组件状态 |

### 与 Selenium/Playwright 的定位区别

| | Selenium / Playwright | bsk.exe |
|---|---|---|
| 目标用户 | 自动化测试工程师 | 脚本 / AI Agent |
| 调用方式 | Python/Node.js API | 命令行 |
| 浏览器 | 新建无头/有头实例 | **复用你已登录的浏览器** |
| 安装 | 安装运行时 + 对应版本 WebDriver | 单文件二进制，即拷即用 |
| 跨域 iframe | 可访问内容 | 检测 load 事件（父页面级） |

> 本项目的 PowerShell 脚本本质上是把 bsk 命令串联成「登录 → 树扫描 → 遍历报表 → 检测加载」的自动化编排器。

---

## 新电脑部署（三步完成）

### 1. 安装 browser-skill 扩展

项目已自带离线包 `BrowserSkill-0.1.3_0.zip`：

- 打开 Chrome → 地址栏输入 `chrome://extensions/` → 回车
- **开启**右上角「开发者模式」
- 将 `BrowserSkill-0.1.3_0.zip` **拖拽**到扩展页面
- 确认浏览器右上角弹窗显示 **`connected`**

> 离线包不能自动安装 bsk.exe，所以项目已自带，无需额外步骤。

### 2. 验证 bsk

项目目录下已包含 `bsk.exe`，打开 cmd / PowerShell 执行：

```bash
.\bsk status
```

返回 `daemon running` 等信息即正常。

### 3. 配置凭据 + 运行

编辑 `config/credential.ps1`，填入对应环境的账号密码，然后双击 `run.bat`。

---

## 前置依赖

| 依赖 | 来源 |
|------|------|
| Chrome 或 Edge | 电脑自带 |
| browser-skill 扩展 | 项目已自带离线包 `.zip`，拖拽安装 |
| bsk.exe | 项目已自带，即拷即用 |
| PowerShell | Windows 自带 |

---

## 使用方式

### 调试阶段（菜单交互，双击 run.bat）

双击 `run.bat`，显示 15 秒倒计时菜单：
- **按 0** → 生产环境
- **按其他任意键** → 测试环境
- **超时** → 默认测试环境

### 生产阶段（跳过菜单，任务计划程序 / 脚本调用）

显式指定 `-Env` 参数时会**直接执行**，不显示菜单：

```powershell
.\run.ps1 -Env test                  # 测试环境（定时任务用）
.\run.ps1 -Env prod                  # 生产环境
.\run.ps1 -Env test -ResumeFrom "分类/报表名"  # 断点恢复
.\run.ps1 -Env test -ReportFilter "销售"       # 按关键字过滤
.\run.ps1 -Env test -NoLogin                 # 跳过登录
```

---

## 核心流程

```
1. bsk session start                         启动浏览器会话
2. navigate → 超级登录页                      导航到登录页
3. evaluate 填凭据 + click 登录               JS 直接操作 DOM 填值
   └─ 自动跳转首页                            登录后自动 redirect
4. click「报表中心」                           进入报表树
5. snapshot 抓取 AX 树                        解析 depth=2 分类 / depth=3 报表
6. 注册全局 MutationObserver                  常驻监听 iframe 替换
7. 遍历每个报表：
    ├─ __bskLoaded = false
    ├─ 监听当前 iframe 的 load 事件
    ├─ evaluate click 树节点
    ├─ 轮询 __bskLoaded（每 1s，最多 15s）
    │   ├─ true  → Success
    │   └─ false → Failed
    └─ 下一个
8. 输出 CSV 到 logs/<时间>/
9. bsk session stop
```

---

## 设计思路

### 架构

```
bsk.exe (浏览器控制层)
    ↓  CLI 命令
PowerShell 脚本 (业务逻辑层)
    ├─ config/         配置驱动
    ├─ lib/core.ps1    操作封装
    └─ lib/warmup.ps1  预热逻辑
```

### 关键决策

| 决策 | 原因 |
|------|------|
| **bsk.exe 驱动浏览器** | 浏览器扩展直连，无需 WebDriver，版本无关 |
| **PowerShell 脚本** | Windows 原生，零运行时依赖 |
| **JS evaluate 操作 DOM** | 绕过 `bsk fill` 写入问题，dispatchEvent 触发 Vue 响应式 |
| **snapshot AX 树解析** | 无需后端 API，自动发现报表增减 |
| **MutationObserver + load 事件** | 跨域 iframe 加载完成的最精确方式，全局常驻不丢事件 |
| **预热 = 触发缓存** | iframe load 即请求已到服务端，不等 viz 渲染 |

### 与传统方案对比

| | Selenium / Playwright | 本方案 |
|---|---|---|
| 安装 | 安装运行时 + 对应版本 WebDriver | 扩展 + 单文件二进制，即拷即用 |
| 跨机器 | 每台装环境 | 整个文件夹拷贝 |
| 页面交互 | CSS/XPath 定位 | snapshot AX 树 + ref |
| 动态内容 | `waitForSelector` | MutationObserver 精准感知 |
| SPA 兼容 | `waitFor` 路由 | evaluate + dispatchEvent |
| 跨域 iframe | 被拦截 | 父页面 MutationObserver + load |
| 报表清单 | 静态文件维护 | 页面动态扫描 |
| 调度 | cron / Airflow | 任务计划程序（原生） |

---

## 日志

每次执行自动创建独立子目录：

```
logs/
└── 2026-07-23_14-21-18/
    ├── warmup_test.log        # 详细执行日志
    └── result_test.csv        # 结果汇总
```

CSV 字段说明：

| 字段 | 说明 |
|------|------|
| ReportName | 分类/报表名 |
| Status | Success（加载成功）/ Failed（超时或点击未命中） |
| Duration | 单个报表耗时（秒） |
| Error | 失败原因 |

---

## 定时任务

Windows 任务计划程序。注意使用 `run.ps1` 而非 `run.bat`，避免 `pause` 阻塞任务：

| 项目 | 配置 |
|------|------|
| 程序 | `powershell.exe` |
| 参数 | `-ExecutionPolicy Bypass -File "D:\bsk-automation\run.ps1" -Env test` |
| 触发器 | 按需设置 |
| 触发器 | 按需设置 |
| 运行用户 | 当前 Windows 用户 |

---

## 跨机器

| 文件 | 策略 |
|------|------|
| `config/settings.ps1` | 自动检测 bsk 路径，直接拷贝 |
| `config/credential.ps1` | 每台电脑独立配置，不拷贝 |
| `bsk.exe` | 直接拷贝，即拷即用 |
| `lib/*.ps1` | 直接拷贝 |
| `logs/` | 按需拷贝 |
