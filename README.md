# DeepSeek 账号余额托盘（Windows 实时余额/用量显示）

系统托盘常驻，**图标上直接显示账号可用余额**，颜色随余额分级；悬停看汇总，左键打开详情窗口。
零依赖：只用 Windows 自带的 PowerShell 5.1 + WinForms，不需要装 Python / Node / Electron。

**默认走「账号余额」模式 —— 不需要 API Key。** 它直接用 Harness 自己已登录的账号凭据
查询平台钱包余额，也就是 Harness「设置 → 账号与余额」里显示的那个数。

![详情窗口](ui-platform-ok.png)

> 截图统一用演示数据生成（`-SimulateBalance`），不是真实账单。
> 自己重新截图时也请走这个模式，别把真实余额和累计消耗公开出去。

---

## 为什么不需要 API Key

DeepSeek Harness 登录用的就是开放平台账号（`~/.dsh/.credentials.yaml` 里
`issuer = https://platform.deepseek.com`），所以那份登录凭据可以直接用来查账户钱包：

```
GET https://platform.deepseek.com/api/v0/users/get_user_summary
Header: x-dsh-auth-token: <登录 token>
→ normal_wallets (充值余额) / bonus_wallets (赠金) / total_costs (累计消耗)
```

接口地址是从 Harness 自身的 `@deepseek-ai/dsh-deepseek-account-platform` 模块里找到的。

**三种数据源**（右键托盘图标 → **数据源** 切换）：

| 模式 | 需要 Key | 显示什么 | 走势图 |
| --- | --- | --- | --- |
| **`platform`（默认）** | 不需要 | 账号充值余额 + 赠金，同时显示今日折算花费 | 近 14 天花费 |
| `usage` | 不需要 | 今日 token 消耗 + 按官方价目表折算的花费 | 近 14 天花费 |
| `balance` | 需要 `sk-` Key | 开放平台 API 账户余额 | 余额变化 |

---

## 快速开始

**双击 [DeepSeek 用量.lnk](DeepSeek%20用量.lnk)** 或 [Start-BalanceTray.vbs](Start-BalanceTray.vbs)。

启动后会做两件事，让你确信它真的起来了：

1. **自动弹出详情窗口**（显示余额和今日花费）——看完关掉即可，托盘程序继续在后台跑。
2. **托盘弹一次气泡**，告诉你图标在哪儿。

> **Windows 11 注意**：托盘图标默认被折叠进 `^` 溢出菜单。展开后把图标**拖到任务栏上**固定，
> 或去「设置 → 个性化 → 任务栏 → 其他系统托盘图标」里打开。
> 之后想打开详情窗，**左键单击**托盘图标即可。

**重复双击不会开出第二个**：程序带单实例检测，再点一次会弹一个自动关闭的提示框告诉你
「已经在运行了，图标在右下角」。

先确认能读到数据（可选）：双击 **[Check-Usage.cmd](Check-Usage.cmd)**。

---

## 界面说明

![详情窗口](ui-platform-ok.png)

- **大数字** = 账号可用余额（充值 + 赠金）
- **统计条（4 列）** = 今日 token 分解：
  | 缓存命中 | 缓存未命中 | 输出 | 今日合计 |
  |---|---|---|---|
  | 日志里的 `cacheReadTokens` | `inputTokens`（未走缓存的那部分输入） | `outputTokens` | 三者之和 |

  口径核对过：`totalTokens = inputTokens + outputTokens + cacheReadTokens`，
  所以 `inputTokens` 就是**缓存未命中**的输入量，不是总输入。
- **下方小字** = 充值余额 · 赠金余额 · 今日折算花费 · 累计消耗
- **底部走势** = 近 14 天花费（来自本地会话日志，见下）
- **去充值** 按钮直达 <https://platform.deepseek.com/top_up>
- 顶部状态胶囊：正常（>20 元）/ 偏低（≤20）/ 告急（≤5），阈值可在配置里改

界面是**浅色主题、无边框自绘卡片**，且**声明了 DPI 感知**——在 150% 缩放的高分屏上
按物理分辨率原生渲染，不会被系统拉伸成糊的位图。

---

## 右键菜单

| 菜单项 | 说明 |
| --- | --- |
| 顶部文字 | 当前数值 + 刷新时间 |
| 立即刷新 | 立刻重新取数 |
| 显示详情… | 打开详情窗口 |
| 复制当前数据 | 复制一行文字到剪贴板 |
| 数据源 | 账号余额 / 本地用量 / 开放平台 API 余额 |
| 刷新间隔 | 15 秒 / 30 秒 / 1 / 2 / 5 / 15 分钟 |
| 阈值提醒 | 余额跌破阈值时弹气泡，跨阈值只提醒一次 |
| 扣费提醒 | 仅 API Key 模式有意义 |
| 随 Windows 启动 | 开机自启开关（静默启动，不弹窗） |
| 图标上显示金额 | 关掉就只显示一个纯色圆点 |
| 加密保存 API Key | 仅 API Key 模式需要 |
| 打开开放平台 / 配置文件 / 日志 | 常用入口 |
| 退出 | 关闭托盘程序 |

---

## 配置项（config.json）

| 字段 | 默认 | 说明 |
| --- | --- | --- |
| `dataSource` | `platform` | `platform`=账号余额，`usage`=本地用量，`balance`=API Key |
| `refreshSeconds` | `60` | 刷新间隔（秒） |
| `lowThreshold` | `20.0` | 可用余额 ≤ 此值 → 琥珀色 + 提醒 |
| `criticalThreshold` | `5.0` | ≤ 此值 → 红色 + 告警 |
| `dailyWarnCost` / `dailyCriticalCost` | `5.0` / `20.0` | 仅 `usage` 模式：今日花费分级阈值 |
| `usageIconMetric` | `cost` | 仅 `usage` 模式：图标显示 `cost` 还是 `tokens` |
| `usageHistoryDays` | `14` | 走势图天数 |
| `nodePath` | `""` | 留空自动找 DSH 自带运行时 |
| `iconMode` / `iconShowSymbol` | `amount` / `false` | 图标形态 |
| `notifyOnLow` / `notifyOnStart` | `true` / `true` | 阈值提醒 / 启动气泡 |
| `apiKey` / `baseUrl` / `proxy` / `timeoutSeconds` | — | 仅 `balance` 模式 |

---

## 文件说明

| 文件 | 作用 |
| --- | --- |
| `Start-BalanceTray.vbs` | **双击这个启动**（无控制台窗口，会自动弹出详情窗） |
| `BalanceTray.ps1` | 托盘主程序：DPI 声明、取数调度、图标、菜单、提醒 |
| `DetailsWindow.ps1` | 详情窗口：无边框自绘卡片（GDI+ 手绘，浅色主题，DPI 缩放） |
| `Platform.ps1` | 账号余额：读 Harness 凭据 + 调平台接口 |
| `UsageCollector.js` | 用量采集器（Node）：解压会话日志、按天聚合、计价 |
| `Usage.ps1` | 采集器的 PowerShell 桥接层 + state 标准化 |
| `DeepSeekBalance.ps1` | 核心库：配置、图标渲染、格式化、API Key 余额 |
| `Autostart.ps1` | 开机自启（静默路径） |
| `Create-DesktopShortcut.ps1` / `创建桌面快捷方式.cmd` | 生成桌面快捷方式 + 图标 |
| `Test-Usage.ps1` / `Check-Usage.cmd` | 命令行查看用量 |
| `Test-Balance.ps1` / `Check-Balance.cmd` | 命令行查看 API Key 余额 |
| `config.json` | 配置（**不要提交到 git**） |
| `usage-cache.json` | 会话解析缓存（按 mtime+size 命中） |
| `run.log` | 运行日志（自动截断） |

调试参数：

```powershell
# 离线演示：不联网、不读日志，用假数据跑完整流程
.\BalanceTray.ps1 -SimulateBalance 88.00 -ExitAfterSeconds 8
# 把详情窗口画成 PNG（自动化验收用）
.\BalanceTray.ps1 -CaptureUi .\shot.png
```

---

## 工作原理

**账号余额（platform）**

读 `~/.dsh/.credentials.yaml` 里的 `deepseek-account-platform/default` 记录拿到 token 和 issuer，
按 Harness 自己的请求头（`x-dsh-auth-token` + 一组 `x-client-*`）调
`/api/v0/users/get_user_summary`，从 `data.biz_data` 里取 `normal_wallets` / `bonus_wallets` / `total_costs`。
token 只用于这一处请求，不写日志、不外传。

**本地用量（usage）**

1. DSH 把每个会话写成 `~/.dsh/sessions/<项目>/<会话id>/session.v4.jsonl.zstd`。
2. 日志是 **zstd 压缩**的，而且是**多帧拼接**的 seekable 格式 —— `zlib.zstdDecompressSync` 只吃第一帧，
   必须先扫描所有帧头（魔数 `28 B5 2F FD`）逐帧解压再拼接。
3. 每条 `type=assistant/message` 记录里带 `data.usage`。
   **注意**：`data.stream[*].chunk.usage` 是流式分片里的重复值，用了就会翻倍。
4. 按记录时间判断高峰/空闲分档计价（[官方价目表](https://api-docs.deepseek.com/zh-cn/quick_start/pricing/)：空闲价，高峰 ×2），再按天聚合。

**为什么要借 Node**：Windows PowerShell 5.1 没有 zstd 能力。DSH 自带的 `node.exe`（v24）内置
`zlib.zstdDecompressSync`，所以采集器用 Node 写。`Find-NodeRuntime` 会自动去找。

**锐利度（DPI）**：进程启动时先声明 `PER_MONITOR_AWARE_V2`，然后所有布局按
`GetDpiForSystem()/96` 缩放。不声明的后果是系统按 96 DPI 渲染再整张位图拉伸 ——
150% 缩放下就是整体发糊。托盘图标也按 `16 × 缩放` 渲染（150% → 24px），正好是
Windows 想要的尺寸，不需要它再缩放一次。

**其他取舍**

- 1px 边框用「填充圆环」画（外圈填边框色 + 内圈填底色），避开 GDI+ Pen 居中的半像素灰边
- 浅色主题的语义色分两档：填充用亮色、文字用深色（`#16A34A` 填充 / `#15803D` 文字）
- 悬停提示是单行的（Win32 `szTip` 本质是单行字符串）
- 图标数字用 `StringFormatFlags.NoWrap`（`DrawString` 默认会在矩形内折行）
- 哈希表不能相加：`$a + $b` 是 `.Add()` 语义，键重复会抛异常，所以有 `Merge-Hashtable`

---

## 常见问题

**双击了，好像什么都没发生？**
托盘程序无窗口启动，「没反应」是正常的——真正要看的是**右下角通知区域**。双击会自动弹出详情窗，
窗口出现了就说明启动成功，图标只是被 Win11 收进 `^` 里了。再双击一次会弹提示框告诉你这一点。

**图标显示灰色 `!`** —— 左键点开详情窗看具体原因：

| 提示 | 处理 |
| --- | --- |
| Harness 登录已失效 | 重新登录 DeepSeek Harness |
| 找不到 Harness 登录凭据 | 确认 `~/.dsh/.credentials.yaml` 存在且已登录 |
| 平台响应结构不符 | 接口可能变了，改用 `usage` 模式 |
| 找不到带 zstd 支持的 node.exe | 确认 `~/.dsh/dsh-runtimes` 存在；或填 `nodePath` |

**数字和网页上对不上** —— 余额是平台返回的原始值（含小数），网页可能做了四舍五入；
「今日折算花费」是按官方价目表**估算**的，不是真实扣款。

**改了 config.json 不生效** —— 程序启动时读一次配置；改完右键 → 退出，再双击一次。

**托盘里没有图标** —— 展开通知区域的 `^` 溢出菜单；Win11 需要手动拖出来固定。

---

## 参考的开源项目

- [SrtaEstrella/DeepSeekBalanceMonitor](https://github.com/SrtaEstrella/DeepSeekBalanceMonitor) —— Windows 托盘画数字 + Rainmeter 皮肤，交互形态参考
- [FuyuMikanLab/ai-credit-bar](https://github.com/FuyuMikanLab/ai-credit-bar) —— macOS 菜单栏，支持 DeepSeek/Moonshot/OpenAI
- [steipete/CodexBar](https://github.com/steipete/CodexBar) —— 失败退避 + last-good 快照
- [ccusage/ccusage](https://github.com/ccusage/ccusage) —— 「解析本地日志算用量、不需要 key」的思路来源
- 界面设计参考：[iStat Menus](https://bjango.com/help/istatmenus7/welcome/)、[exelban/stats](https://github.com/exelban/stats)（大数字 + 小标签 + 单一强调色）
