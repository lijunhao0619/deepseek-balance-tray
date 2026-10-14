# 托盘小部件 UI 设计规格（浅色 · 紧凑弹层）

目标：把现有深色 330×220 弹层改造为浅色、更清晰、更小的版本。

## 1. 参考案例

| 案例 | 链接 | 一句话手法 |
| --- | --- | --- |
| iStat Menus 7 | [bjango.com/help/istatmenus7](https://bjango.com/help/istatmenus7/welcome/#changing-the-layout-and-design) | 高密度弹层靠极细分隔线 + 小号标签字分层，图表只用单一强调色，不靠底色块。 |
| Stats（开源 macOS 菜单栏监控） | [github.com/exelban/stats](https://github.com/exelban/stats) | 固定宽度弹层 + "大数字 / 小标签"配对，单色迷你走势图，极简到几乎无装饰。 |
| CodexBar 菜单栏面板 | [mintlify.wiki/steipete/codexbar](https://mintlify.wiki/steipete/codexbar/features/menu-bar) | 左标签右数值的稳定右对齐基线，纯文本行，留白代替边框。 |
| Dribbble — Menu Overlay | [dribbble.com/shots/2157265](https://dribbble.com/shots/2157265-Menu-Overlay/) | 浮层用一层极轻阴影 + 8px 圆角与背景拉开，而不是靠描粗边框。 |
| Dribbble — UI Challenge: Popover Components | [dribbble.com/shots/24333881](https://dribbble.com/shots/24333881-UI-Challenge-Popover-Components) | 一组 popover 变体示范内边距/箭头/边界的统一节奏，适合做规格基线。 |

## 2. 浅色色板（十六进制）

| Token | 值 | 用途 |
| --- | --- | --- |
| `bg-window` | `#FFFFFF` | 弹层卡片底（不透明，ClearType 可用） |
| `bg-subtle` | `#F7F8FA` | token 数字块、图表底、次级分区 |
| `bg-hover` | `#F2F4F7` | 列表/按钮 hover 底 |
| `border` | `#E4E7EC` | 卡片外框、分区描边（1 物理 px） |
| `divider` | `#EEF0F3` | 行分隔线，比 border 更淡 |
| `text-primary` | `#1F2328` | 主数字、标题（约 14:1） |
| `text-secondary` | `#5B6470` | 次级数字、说明（约 6.0:1） |
| `text-label` | `#6B7280` | 行标签（4.83:1，**下限**） |
| `text-disabled` | `#9AA1AC` | 仅禁用态，勿用于正文 |
| `accent` | `#2563EB` | 走势图线、主按钮、选中态 |
| `accent-hover` | `#1D4ED8` | 主按钮 hover |
| `accent-active` | `#1E40AF` | 按下态 |
| `accent-subtle` | `#EFF4FF` | 强调浅底（选中行、徽标底） |
| `ok` / `ok-text` | `#16A34A` / `#15803D` | 正常状态；**文字必须用深档** |
| `warn` / `warn-text` | `#F59E0B` / `#B45309` | 接近额度；文字用深档 |
| `danger` / `danger-text` | `#EF4444` / `#B91C1C` | 超限；文字用深档 |
| `shadow` | `rgba(16,24,40,.08)` 0 8px 24px + `rgba(16,24,40,.06)` 0 1px 2px | 唯一阴影，极轻 |
| `focus-ring` | `#93B4FD` | 键盘焦点 2px 外环 |

规则：填充用亮档、文字用深档；浅底禁用荧光色（`#00FF00`、`#00E5FF` 一类）。

## 3. 排版规格

| 层级 | 字号 | 字重 | 颜色 | 说明 |
| --- | --- | --- | --- | --- |
| 主数字 ¥5.72 | 24 px | Semibold 600 | `text-primary` | 与 ¥ 符号同族，¥ 用 16px 光学缩进 |
| 标题 | 12 px | Semibold 600 | `text-primary` | 如「今日折算」 |
| 次级数字 | 12 px | Regular 400 | `text-secondary` | token 数，等宽数字 |
| 标签 | 11 px | Regular 400 | `text-label` | 中文标签，不再更淡 |

- 字体族：拉丁/数字 `Segoe UI Variable Text` → 回退 `Segoe UI`；中文 `Microsoft YaHei UI`。**不要**用微软雅黑渲染拉丁数字（笔画偏重、小字号更糊），中英混排建议标签用雅黑 UI、数字用 Segoe UI，系统 FontLink 会处理剩余回退。
- 数字对齐：开启等宽数字（tabular figures）或用 `Cascadia Mono`/`Consolas` 画 token 数，避免数值跳动。
- 行高 16 px（11–12px 文字）、数字行高 28 px；基线清晰优于垂直居中微调。

## 4. 尺寸与栅格（逻辑 px @96dpi）

| 项 | 值 |
| --- | --- |
| 窗口（推荐） | **300 × 188**（较 330×220 面积减约 22%，视觉密度不变） |
| 窗口（上限） | 320 × 200 |
| 内边距 | 12 px（上下左右一致） |
| 内容宽 | 276 px |
| 栅格 | 4 / 8 / 12 / 16 px，间距只用 8 与 12 |
| 圆角 | 窗口 10 px；区块/图表容器 8 px；按钮 6 px；徽标 4 px |
| 主数字区高 | 40 px（主数字 + 右侧箭头） |
| token 行高 | 18 px，行间 4 px |
| 走势图高 | 40 px，上下留 8 px |
| 按钮 | 高 28 px、圆角 6 px、图标按钮 24×24；3 按钮等宽或主按钮 flex |
| 元素间距 | 区块之间 12 px；行内标签↔数值 8 px（右对齐） |

高 DPI：以上全部走 `MulDiv(值, GetDpiForWindow(hwnd), 96)`，150% 时窗口物理尺寸 450×282。

## 5. 让 GDI+/WinForms 显得锐利的具体手法

**R1 · 必须声明 Per-Monitor V2 DPI aware。** 在 app.manifest 中同时写
`<dpiAware>true/pm</dpiAware>`（2005 命名空间）与
`<dpiAwareness>PerMonitorV2</dpiAwareness>`（2016 命名空间）。后果对照：

| 声明 | 后果 |
| --- | --- |
| 不声明（DPI unaware） | 系统按 96 DPI 渲染后位图拉伸，125%/150% 下整体发糊（微软原文 "appearing blurry"） |
| 仅 System aware | 只在登录时主屏 DPI 下锐利；换显示器或改缩放即被位图拉伸变糊 |
| Per-Monitor V2 | Windows 绝不拉伸、改发 `WM_DPICHANGED`；代价是必须自己重算布局，否则元素尺寸/位置错 |

配套：所有 API 换 DPI 感知版本（`GetSystemMetricsForDpi`、`GetDpiForWindow`），布局逻辑抽成函数并在 `WM_DPICHANGED` 里重跑，缓存字号/尺寸在 DPI 变化时全部失效重建。

**R2 · 文本渲染模式按底色选。**
- `TextRenderingHint.ClearTypeGridFit`：仅在**不透明、已知纯色浅底**（`#FFFFFF`/`#F7F8FA`）上用于小字号数字与正文——微软文档称其在多数 LCD 与小字号下质量最好。限制：不可与 `CompositingMode.SourceCopy` 同用；在带 alpha 的分层窗口或半透明底上会出现彩色边纹。
- `TextRenderingHint.AntiAliasGridFit`：底色未知、半透明、画进 Bitmap 再合成、分层窗口时用。灰阶抗锯齿会让深色字在浅底上"变灰变细"，需配更深文字色（用 `#1F2328` 而非 `#333`）。
- 实践：**不透明卡片上的文字优先 `TextRenderer.DrawText`**（走 GDI/ClearType，浅底最锐）；只有画在半透明/分层表面上才用 `Graphics.DrawString` + `AntiAliasGridFit`。两者别在同一张图上混用。旋转文字用 `AntiAlias`（无 hinting）。

**R3 · 1px 边框的像素对齐。** GDI+ 的 Pen 以坐标为中心：`DrawRectangle(0, 0, 100, 50)` 的 1px 笔画落在 y = −0.5…0.5，横跨两个半像素，被渲染成两条 50% 灰 → 又浅又糊。
- 规则 A（推荐）：`PixelOffsetMode.None`，描边坐标统一 `+0.5f`：`DrawRectangle(x+0.5f, y+0.5f, w-1, h-1)`；直线 `DrawLine(x+0.5f, y+0.5f, x2+0.5f, y2+0.5f)`。
- 规则 B（等价）：`PixelOffsetMode.Half`（整体 −0.5 偏移）时整数坐标描边即锐。但 Half 同时偏移填充与图像边缘，易让填充/图标产生半像素模糊，故只在纯描边画布上用 B。
- 最稳的 1px：用 `FillRectangle(brush, x, y, w, 1)` 代替描边，填充矩形不受 Pen 居中影响，天然落在整数像素上。
- **半像素坐标只允许出现在描边**；填充、位图、文字起点必须整数（文字在 .5 上 → 字形糊）。
- 高 DPI：1 逻辑 px 在 150% 等于 1.5 物理 px，永远无法锐利。边框应以**物理像素**定义：`borderPx = max(1, round(scale))`，并把最终矩形 `Math.Round` 对齐到整数物理像素后再画。

**R4 · 位图不缩放。** 图标按目标物理尺寸备 16/20/24/32 档，按 `DeviceDpi` 选档 + `DrawImageUnscaled`。走势图不要用位图，用 `DrawLines` + `SmoothingMode.AntiAlias` 矢量绘制，缩放天然锐利。必须缩放时用 `HighQualityBicubic` + `ImageAttributes.WrapMode = TileFlipXY` 防边缘渗色，绝不用 `NearestNeighbor`（像素画除外）。

**R5 · 双缓冲 + 缓存位图。** `SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer, true)`（或 `DoubleBuffered = true`）；否则托盘弹层每次重绘闪。进一步：整卡渲染进一张按当前 DPI 创建的 32bppPArgb `Bitmap`，`OnPaint` 里 `DrawImageUnscaled` 一次贴出，只有走势图变化时才重画缓存——既免闪又免重复抗锯齿开销。另加 `Application.SetCompatibleTextRenderingDefault(false)`；**不要**对顶层窗用 `WS_EX_COMPOSITED`。圆角：Win11 用 `DwmSetWindowAttribute(DWMWA_WINDOW_CORNER_PREFERENCE, DWMWCP_ROUND)`；要自绘平滑圆角 + 阴影只能 `WS_EX_LAYERED` + `UpdateLayeredWindow`（预乘 ARGB），此时**必须**改用 `AntiAliasGridFit`（ClearType 在 alpha 边缘出彩边）。用 `TransparencyKey` 或 `Region` 抠圆角会得到锯齿边，禁止。

## 6. 浅色主题易翻车点

| 现象 | 原因 | 规避 |
| --- | --- | --- |
| 抗锯齿边缘发灰、字看起来比深色版细 | 灰阶 AA 让深色笔画摊薄；ClearType 用错在 alpha 面上 | 浅底文字用 `TextRenderer`；文字色加深到 `#1F2328`；混排面改 AntiAliasGridFit 并加深一档 |
| 次要文字对比不足 | `#9CA3AF` 在纯白上仅约 2.5:1 | 正文次要色下限 `#6B7280`（4.83:1），说明文字用 `#5B6470` |
| 浅灰边框"看不见" | `#E5E7EB` 对白仅约 1.2:1，低质量屏几乎不可见 | 边框用 `#E4E7EC` 起，优先 `#D0D7DE`；或与极轻阴影二选一，别两者都弱 |
| 阴影过重像脏污 | 浅底上深阴影读作污渍 | 只用一层 `rgba(16,24,40,.08)` 大模糊 + `.06` 贴边微影；边框与阴影择一为主 |
| 语义色在浅底刺眼/发飘 | 深色主题的亮色直接搬到浅底 | 填充保留亮档，**文字一律用深档**（`#15803D`/`#B45309`/`#B91C1C`） |
| 彩色边纹（文字边缘泛红蓝） | ClearType 画在半透明/分层窗口上 | 该表面统一改 `AntiAliasGridFit`，或把文字画进不透明缓存位图 |
| 圆角/图标边缘锯齿 | `Region`、`TransparencyKey` 抠图 | 走 DWM 圆角或分层窗口预乘 ARGB；图标按 DPI 备多档不缩放 |
| 数值滚动时抖动 | 比例数字宽度不一 | 等宽数字或等宽字体 |
| 纯白卡贴在纯白底上"没有边界" | 缺少分离手段 | 卡片 `#FFFFFF` + `bg-subtle` 分区，或换极浅阴影，别同时加粗边框 |

## 来源

- [High DPI Desktop Application Development on Windows](https://learn.microsoft.com/en-us/windows/win32/hidpi/high-dpi-desktop-application-development-on-windows)（DPI 感知模式与后果对照）
- [TextRenderingHint 枚举](https://learn.microsoft.com/en-us/windows/win32/api/gdiplusenums/ne-gdiplusenums-textrenderinghint)（ClearTypeGridFit / AntiAliasGridFit 适用场景与限制）
- [PixelOffsetMode 枚举](https://learn.microsoft.com/en-us/dotnet/api/system.drawing.drawing2d.pixeloffsetmode)
- [ControlStyles 枚举](https://learn.microsoft.com/en-us/dotnet/api/system.windows.forms.controlstyles) / [How to: Double Buffer a Form](https://learn.microsoft.com/en-us/previous-versions/4xew49b4(v=vs.80))
- [High DPI support in Windows Forms](https://learn.microsoft.com/en-us/dotnet/framework/winforms/high-dpi-support-in-windows-forms)
- [Applications look blurry after Windows 8.1](https://learn.microsoft.com/zh-cn/archive/blogs/tip_of_the_day/tip-of-the-day-applications-looks-blurry-after-windows-8-1)
- [Telerik KB：WinForms 意外的 per-monitor DPI 感知](https://www.telerik.com/document-processing-libraries/documentation/knowledge-base/fix-winforms-runtime-dpi-aware-application)
- [WCAG G18：4.5:1 对比度](https://www.w3.org/WAI/WCAG21/Techniques/general/G18.html)
- [Apple NSVisualEffectView.Material（浅色材质参考）](https://developer.apple.com/documentation/appkit/nsvisualeffectview/material-swift.enum)
