# 实时显示 AI API 余额（Windows 自用）技术调研

调研时间：2026-10-14。所有 star 数为当日通过 GitHub API 实测。

## 1. DeepSeek 官方余额接口规格（已查证官方文档页）

官方文档页**存在**：[Get User Balance](https://api-docs.deepseek.com/api/get-user-balance/)（[中文页](https://api-docs.deepseek.com/zh-cn/api/get-user-balance/)）。

| 项目 | 值 |
|---|---|
| 完整 URL | `https://api.deepseek.com/user/balance`（`base_url` 见 [Your First API Call](https://api-docs.deepseek.com/)） |
| HTTP 方法 | `GET`（文档页标题旁标注 `GET /user/balance`） |
| 鉴权 header | `Authorization: Bearer <API key>`（余额页未重复列出，鉴权方式取自同站 Quick Start 的 curl 示例） |
| 流式 | 否，单次 JSON 响应；文档**未**声明任何特殊/beta header |
| Rate limit | 文档未给 RPM/TPM，只有账户级**并发**上限（deepseek-flash 2500 / deepseek-v4-pro 500，[Rate Limit](https://api-docs.deepseek.com/quick_start/rate_limit)） |

请求示例（按文档 base_url + 鉴权头拼装；`Accept` 为常规写法，文档未明示要求）：

```bash
curl https://api.deepseek.com/user/balance \
  -H "Accept: application/json" \
  -H "Authorization: Bearer ${DEEPSEEK_API_KEY}"
```

响应字段（文档 Schema 原文）：

| 字段 | 类型 | 含义 |
|---|---|---|
| `is_available` | boolean | 余额是否足以调用 API |
| `balance_infos` | object[] | **数组**，元素含 `currency` / `total_balance` / `granted_balance` / `topped_up_balance` |
| `balance_infos[].currency` | string | 取值 `CNY` 或 `USD` |
| `balance_infos[].total_balance` | string | 总可用余额 = 赠金 + 充值余额 |
| `balance_infos[].granted_balance` | string | 未过期赠金余额 |
| `balance_infos[].topped_up_balance` | string | 充值余额 |

注意：所有金额字段是**字符串**，不是数字；`balance_infos` 是数组，可能含多币种。文档页的 200 示例 JSON 由前端脚本渲染，我抓取到的 HTML 只含 Schema（Example 页签为空），因此**未取得官方示例 JSON 原文**——以 Schema 为准。

错误码（[Error Codes](https://api-docs.deepseek.com/quick_start/error_codes)）：400 格式错误、401 鉴权失败、402 余额不足、422 参数非法、429 触发限流、500 服务错误、503 过载。对余额轮询而言，401 应视为"密钥失效/被撤销"并停止重试，429/5xx 应退避重试。

## 2. OpenAI / Anthropic 是否有等价余额接口

**结论：都没有可用的"余额"接口。** OpenAI 的 `/v1/dashboard/billing/credit_grants`（含 `/usage`、`/subscription`）是 platform 站点给浏览器用的 dashboard 端点，需 session key 与 bot 校验，官方社区明确答复"不可编程调用"；现在唯一可编程的是 **Admin API** 的 `GET /v1/organization/costs`（与 `/v1/organization/usage/completions`），必须用组织级 `sk-admin-` key，只有组织管理员能建，散户 API key 拿不到余额（[OpenAI 社区帖](https://community.openai.com/t/issue-in-fetching-openai-api-usage-billing-cost-and-credit-balance-programmatically-for-backend-monitoring/1379947)、[Get Costs 参考](https://developers.openai.com/api/reference/cli/resources/admin/subresources/organization/subresources/usage/methods/costs)）。第三方实现也把 `credit_grants` 降级为 "legacy fallback，且不在 OpenAI 当前公开 API 参考内"（[CodexBar docs/openai.md](https://github.com/steipete/CodexBar/blob/main/docs/openai.md)）。

Anthropic 只有 Admin API 的用量/成本报表（[Get Messages Usage Report](https://platform.claude.com/docs/en/api/admin/usage_report/retrieve_messages)、[用量和成本 API](https://docs.claude.com/zh-TW/api/usage-cost-api)），**没有 credit balance 端点**：社区仍在 open 状态请求暴露余额（[claude-code#95713](https://github.com/anthropics/claude-code/issues/95713)），余额只能看 console.anthropic.com，余额耗尽的报错是 `credit_balance_too_low`。

## 3. GitHub 相关开源项目（链接均已实测可访问）

| 仓库 | Star | 技术栈 | 形态 | 刷新 / 密钥存储 |
|---|---|---|---|---|
| [SrtaEstrella/DeepSeekBalanceMonitor](https://github.com/SrtaEstrella/DeepSeekBalanceMonitor) | 17★ / 5 fork | Python(pystray+Tkinter, PyInstaller) + Rust 原生 Windows 版 | Windows 系统托盘（图标上直接画余额数字）+ 可选 Rainmeter 皮肤 + KDE Plasma | 默认 10 分钟轮询；密钥 Fernet+SQLite（Py）/ SQLite+DPAPI（Rust Win）/ Keychain（mac）；配置在 `%APPDATA%\...\config.json`（**密钥不写该文件**）；开机自启走注册表 Run 键 |
| [steipete/CodexBar](https://github.com/steipete/CodexBar) | 22.5k★ | Swift | macOS 菜单栏 | 首选 Admin key（env 或 `~/.codexbar/config.json`）；限流时轮询间隔从 30s **翻倍至最多 5 分钟**，成功即恢复；失败保留 last-good 快照 |
| [Leiuo/deepseek-monitor](https://github.com/Leiuo/deepseek-monitor) | 1★ | Vue3 + Vite + Electron, MIT | Electron 桌面应用 | README 未取到（GitHub HTML/raw 拉取失败）→ 细节**未验证**；最后 push 2026-08-03 |
| [3867586496/deepseek-api-monitor](https://github.com/3867586496/deepseek-api-monitor) | 1★ | Qt6 / C++ | Windows 托盘 + 窗口 + 折线图 + 历史 | 仓库仅 16KB、仅 1 次 push → 基本是骨架，**不宜作依赖** |
| [badpx/CostWatch](https://github.com/badpx/CostWatch) | 1★ | Rust, MIT | macOS 菜单栏 popover, 插件架构 | 每个 provider 一个插件，API token 在设置里配置 |
| [vishnualpha/alpha-cost-hud](https://github.com/vishnualpha/alpha-cost-hud) | 0★ | Tauri (TypeScript + Rust), MIT | 桌面**置顶悬浮 HUD** | 自述体积 ~6MB；**只读本地日志**，不碰密钥 |
| [ccusage/ccusage](https://github.com/ccusage/ccusage)（思路参考） | 19k★ | Rust/TS CLI | 命令行 | 解析本地 Claude Code 日志算花费，**完全不需要 API key** |
| [aaronpiipponen/quota-monitor](https://github.com/aaronpiipponen/quota-monitor) | 0★ | Python + PySide6 | Windows/Linux 托盘，多 provider（Claude/Codex/DeepSeek） | README 拉取失败 → **未验证** |

值得抄：① 用**颜色+数字**表达状态（正常青、低额红、接口降级暖灰、无数据灰）；② **last-good 快照 + 退避**（CodexBar）；③ 附带"消耗速率 / 预计可用天数"比余额本身更有用；④ Rainmeter/Plasma 小组件**不接触密钥**，只读本地回环接口；⑤ demo 模式便于无 key 调试。
值得避：① 把余额写进配置文件明文本；② 秒级轮询（余额变化极慢，纯浪费）；③ 依赖 16KB 级别的空壳仓库；④ 该 repo 近期修的一个真实漏洞——**本地状态 HTTP 端点曾对任意浏览器开放**，现已收口（配合防 DNS rebinding）。

## 4. Windows 常驻形态对比

| 方案 | 实现难度 | 依赖体积 | 常驻 | 置顶 | 任务栏/托盘可见性 | 主要坑 |
|---|---|---|---|---|---|---|
| (a) Python + pystray 托盘 | 低 | 小（pystray+Pillow+requests），PyInstaller exe 约 15–30MB | 是 | 不适用（托盘无窗口） | Win11 新图标默认落进托盘溢出浮出菜单，需用户在"设置→个性化→任务栏→其他系统托盘图标"手动固定 | pystray 在 Windows 图标刷新/通知区有历史缺陷：[#6 图标莫名消失](https://github.com/moses-palmer/pystray/issues/6)、[#74 拖入折叠区后图标空白不可点](https://github.com/moses-palmer/pystray/issues/74)；改图标要重新设置 icon 对象 |
| (b) Electron / Tauri 悬浮窗 | 中 | Electron 打包 100MB+ 且内存高；Tauri 约 6MB（见 alpha-cost-hud 自述）但需 Rust 工具链 + WebView2 运行时 | 是 | 可以（always-on-top） | 窗口可置顶常显，不受托盘折叠影响 | Electron 体积/内存/签名更新成本；Tauri 构建环境重；悬浮窗会挡内容，需要"穿透点击/半透明"细节 |
| (c) 本地 Python HTTP 服务 + 浏览器页 | 低–中 | 最小（stdlib `http.server` 即可） | 需常驻进程或计划任务，浏览器标签页易被关 | 不可能 | 取决于浏览器窗口，不在任务栏 | **必须要有本地服务**：前端直连 API 会被 CORS 拦且密钥暴露（见第 5 节）；本地端口要只监听 127.0.0.1 并校验 Origin/Host 防 DNS rebinding（DeepSeekBalanceMonitor 正是这样改的） |
| (d) Rainmeter 皮肤 / Win11 小组件 | 低（Rainmeter）/ 高（小组件） | 需另装 Rainmeter 本体 | 是 | 桌面层显示，默认会被其他窗口遮挡，需置顶/桌面层技巧 | 桌面可见，不在托盘 | Rainmeter 已被开源项目实证可行（`.rmskin` 发布、走 `127.0.0.1:17654` 本地接口，皮肤本身不持有密钥）；高 DPI 需 2x 缩放 ini；Win11 第三方小组件生态限制**未验证**，不建议作为首选 |

## 5. 工程注意事项

- **前端直连 API 不可行**：两条独立原因叠加。(1) 密钥泄露——放进浏览器 JS/localStorage 就等于公开，任何 XSS 或装过的扩展都能读；(2) CORS——从任意网页 `fetch https://api.deepseek.com/user/balance` 需要对方返回 `Access-Control-Allow-Origin`，DeepSeek 并未把它当作浏览器 API 开放，社区普遍结论是跨域被拦、必须经后端/本地服务中转（[参考](https://m.php.cn/faq/2451409.html)）。**诚实标注**：我在沙箱内用 `Invoke-WebRequest -Method Options` 实测预检请求失败（连接被断开，环境限制），所以"当前是否返回 CORS 头"属**未实测**；但"密钥不能进前端"这一条无论如何都成立，所以架构结论不变——任何浏览器界面都必须接本地回环服务。
- **轮询频率**：官方余额文档未声明限流；官方只有并发限制，且 `/user/balance` 是轻量读接口。参考实现默认 **10 分钟**（DeepSeekBalanceMonitor，可配），CodexBar 对用量接口用 30s 并在 429 时指数退避到 5 分钟。建议：默认 5–10 分钟；失败按 2 倍退避、上限 5–10 分钟；手动"立即刷新"按钮；**不要**做成秒级。
- **API key 存放**（安全性从高到低）：Windows 凭据管理器 / DPAPI 加密文件（Rust 版就是这么做的）> 环境变量（用户级）> 权限收紧的本地配置文件（`%APPDATA%`，ACL 只给当前用户）。切勿：写进前端、写进会被 git 跟踪的仓库、明文写进日志或错误上报。
- **币种混排**：`balance_infos` 是数组，按 `currency` 分组**分别显示**，绝不做跨币种求和；官方未提供汇率，不要自动折算成单一币种（要折算就必须显示汇率来源与时间戳）。金额是字符串，解析后按两位小数显示，并注意负值/过期赠金语义（该项目就修过"负值充值抵消赠金导致总额错误"的问题）。

## 推荐方案

对 **Windows 单人自用**，推荐 **(a) Python + pystray 系统托盘，图标上直接渲染余额数字**，并按需附一个**只监听 127.0.0.1 的只读状态 HTTP 接口**（若要 Rainmeter 皮肤或浏览器页面再复用）。理由：① 依赖与打包体积最小、常驻开销可忽略，符合"单人自用"的成本约束；② 托盘常驻 + 任务栏悬浮提示正对"实时看一眼余额"的诉求，且已有 17★ 的同定位项目把路子走通（含开机自启、加密存 key、余额历史、消耗速率估算）；③ 避开 Electron 的 100MB+ 体积与 Tauri 的构建链；④ 浏览器直连在 CORS 与密钥安全上双重不可行，本地服务是唯一干净的浏览器入口。若用户更在意"悬浮在屏幕角落一直看得见"，退一步选 **Tauri 置顶悬浮 HUD**（约 6MB，参考 alpha-cost-hud 的形态）；不要把 Rainmeter/小组件当主形态，它更适合做附带的桌面展示层。

## 来源链接

- DeepSeek 官方：[Get User Balance](https://api-docs.deepseek.com/api/get-user-balance/) / [查询余额](https://api-docs.deepseek.com/zh-cn/api/get-user-balance/) / [Your First API Call](https://api-docs.deepseek.com/) / [Rate Limit](https://api-docs.deepseek.com/quick_start/rate_limit) / [Error Codes](https://api-docs.deepseek.com/quick_start/error_codes)
- OpenAI：[社区帖：无法程序化取余额](https://community.openai.com/t/issue-in-fetching-openai-api-usage-billing-cost-and-credit-balance-programmatically-for-backend-monitoring/1379947) / [Get Costs（Admin API）](https://developers.openai.com/api/reference/cli/resources/admin/subresources/organization/subresources/usage/methods/costs)
- Anthropic：[Get Messages Usage Report](https://platform.claude.com/docs/en/api/admin/usage_report/retrieve_messages) / [用量和成本 API](https://docs.claude.com/zh-TW/api/usage-cost-api) / [claude-code#95713 余额暴露请求](https://github.com/anthropics/claude-code/issues/95713)
- 项目：[DeepSeekBalanceMonitor](https://github.com/SrtaEstrella/DeepSeekBalanceMonitor) / [CodexBar + OpenAI 数据源文档](https://github.com/steipete/CodexBar/blob/main/docs/openai.md) / [deepseek-monitor](https://github.com/Leiuo/deepseek-monitor) / [deepseek-api-monitor](https://github.com/3867586496/deepseek-api-monitor) / [CostWatch](https://github.com/badpx/CostWatch) / [alpha-cost-hud](https://github.com/vishnualpha/alpha-cost-hud) / [ccusage](https://github.com/ccusage/ccusage) / [quota-monitor](https://github.com/aaronpiipponen/quota-monitor)
- 平台坑：[pystray#6](https://github.com/moses-palmer/pystray/issues/6) / [pystray#74](https://github.com/moses-palmer/pystray/issues/74) / [DeepSeek CORS 讨论](https://m.php.cn/faq/2451409.html)

未验证清单：`api.deepseek.com` 当前实际 CORS 响应头（沙箱内网络探测失败）；`Leiuo/deepseek-monitor`、`aaronpiipponen/quota-monitor` 的实现细节（README 拉取失败）；Win11 第三方小组件生态限制。
