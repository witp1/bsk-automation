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
│   ├── credential.ps1          # 账号凭据（每台电脑独立配置）
│   └── scheduler-config.ps1   # 定时任务配置
├── lib/
│   ├── core.ps1                # bsk 操作封装 + .NET Process 超时
│   └── warmup.ps1              # 预热核心逻辑
├── logs/                       # 执行日志（按次分目录）
├── run.bat                     # 调试入口：双击运行
├── run.ps1                     # 生产入口（含交互式环境选择菜单）
├── install-scheduler.ps1      # 定时任务一键部署脚本
└── README.md
```

## 前置依赖

| 依赖 | 来源 |
|------|------|
| Chrome | 必须保持打开（bsk 不启动浏览器，只控制已打开的） |
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
.\bsk status     # 应显示 daemon running + browsers connected 1
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
 0. 杀残留 bsk → 清锁 → 启动 daemon → 轮询确认就绪
 1. 启动会话 → 等待浏览器连接（60s）
 2. 导航超管登录页 → 预检 SSO 拦截 → 填凭据 → 点登录
    ├─ 跳转首页 → 继续
    └─ 被 SSO 拦截 → 切回 superLogin 重登一次
 3. 导航首页 → 点击「报表中心」→ 展开树
 4. snapshot 抓取 AX 树 → 解析 depth=2 分类 / depth=3 报表
 5. 注册全局 MutationObserver → 监听 iframe 替换
 6. 遍历报表（每 1s 轮询，15s 超时）：
    ├─ 记录当前 iframe src
    ├─ click 树节点
    ├─ 等 load 事件 → 三重验证（src 变了 + Tableau URL + title=数据可视化）
    └─ 15s 超时 → Failed
 7. 输出 CSV → logs/
 8. 退出登录（hover 用户菜单 → 点「退出」）→ 关闭会话
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
    ActiveEnd    = 20          # 截止小时（不含），如 20=8:30~19:30 重复
    RepeatEvery  = 0.5         # 重复间隔（小时；0=不重复）
    Env          = "test"
}
$DaemonAutoStart = @{ Enabled = $true }   # daemon 开机自启
```

### 部署（管理员 PowerShell）

```powershell
cd D:\WorkBuddy\报表预热自动化\bsk-automation
.\install-scheduler.ps1
```

修改配置后重跑即可更新。验证：

```powershell
schtasks /query /tn "bsk-warmup" /fo list
```

## 工作前提

三个条件缺一不可：
- **Chrome 保持打开**（可最小化）
- **browser-skill 扩展 connected**
- **daemon 进程在运行（bsk-daemon 开机自启任务负责）**

脚本不会启动 Chrome，所以这台电脑的 Chrome 需要一直开着。

## 关于 bsk.exe

腾讯开源项目 [BrowserSkill](https://github.com/Tencent/BrowserSkill)（MIT，Rust，6MB 单文件）。它把「控制浏览器」变成一组 shell 命令：

```
脚本 → bsk CLI → IPC → bsk Daemon → WebSocket (127.0.0.1) → 扩展 → CDP → 浏览器
```

| 命令 | 说明 |
|------|------|
| `bsk session start/stop` | 管理浏览器会话 |
| `bsk navigate <url>` | 导航到 URL |
| `bsk snapshot` | 抓取 AX 无障碍树 |
| `bsk click <ref>` | 点击元素 |
| `bsk evaluate <js>` | 执行 JS |
| `bsk status` | 查看 daemon + 浏览器状态 |

## 关键设计决策

| 决策 | 原因 |
|------|------|
| `.NET Process.WaitForExit(ms)` + `Kill()` | 任务计划程序下可靠硬超时（非 Start-Job） |
| `-NoOutput` 模式（daemon start 不重定向 stdout） | daemon fork 子进程继��管道导致 WaitForExit 死锁 |
| 超时 Kill 后不读 `ReadToEnd()` | 强杀后管道状态不可预测，会永久阻塞 |
| daemon 启动后轮询 `bsk status` 确认就绪 | named pipe 可能未就绪导致 status 命令卡死 |
| 填凭据前预检 SSO 拦截 | 下班后 SSO 会话过期直接跳登录页 |
| JSON 解析 `session_id` 判断成功 | .NET Process 不设 `$LASTEXITCODE` |
| JS evaluate 填凭据 + dispatchEvent | 绕过 `bsk fill` 不生效，触发 Vue 响应式 |
| 全局 MutationObserver + src+URL+title 三重验证 | 区分正常报表与假连接/无效页 |
| `schtasks /du` 实现时间段控制 | Windows 原生，脚本侧不做运行时检查 |
| 结束前 hover 用户菜单 → 点「退出」 | 退出登录清 SSO 会话，下次全新状态 |

## 常见问题

| 问题 | 原因 | 解决 |
|------|------|------|
| `bsk status` 卡死不退 | daemon named pipe 未就绪 | 已改：启动后轮询确认才继续 |
| `bsk daemon start` 死锁 | fork 子进程继承 stdout 管道 | 已改：`-NoOutput` 模式不重定向 |
| 超时后日志突然刷出 | Kill 后 `ReadToEnd()` 阻塞 | 已改：超时后跳过读输出 |
| 会话实际成功但报失败 | `$LASTEXITCODE` 来自旧命令 | 已改：解析 JSON session_id |
| 下班后登录全部失败 | SSO 会话过期，登录被拦截到 portal-hmg | 已改：填凭据前预检 + 登录后重试 |
| 结果 CSV 有空行 | Export-Csv 遇到空元素 | 已加 Where-Object 过滤 |
| install-scheduler 报拒绝访问 | 非管理员 | 右键管理员运行 |

## 跨机器

| 文件 | 策略 |
|------|------|
| `config/settings.ps1` | 自动检测 bsk 路径，直接拷贝 |
| `config/credential.ps1` | 每台独立配置 |
| `config/scheduler-config.ps1` | 直接拷贝，改时间 |
| 其他所有文件 | 直接拷贝 |
