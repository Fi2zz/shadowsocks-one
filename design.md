# iOS 简易浏览器 Safari 对齐方案（顶部透色 + 底部玻璃栏）

> 状态：已落地（2026-08-31，终态提交 c9b6cda；2026-09-01 修订布局视口通道为
> 公开 `obscuredContentInsets`，见 §4.1/§6）。本文档已从"实施前方案"改写为
> "落地后设计记录"：与代码不一致的初版路线（.never + 手动 contentInset）已被
> 两次实证不可行并移除，见 §6 实施记录。后续改动以本文档为准。

## 1. 项目背景与现状

- 项目：iOS 简易浏览器，SwiftUI + WKWebView，iOS 17+。
- 已跑通：地址栏输入、前进/后退、多 Tab、后台开标签、外部 scheme 交系统。
- 已落地：Safari 同款浏览器栏行为——顶部状态栏区域透网页色、底部液态玻璃
  栏透出滚动内容、页面 fixed 元素自动避让底栏、滚动时底栏折叠/呼出、
  到达页底自动展开完整工具条。

## 2. 任务范围

| 做 | 不做 |
|---|---|
| WebView 全屏布局（延伸进状态栏与底栏底下） | 无痕模式 |
| 顶部状态栏区域完全交给网页（不画任何原生背景） | 下载管理、书签同步 |
| 底部单行工具栏（导航 + 地址胶囊 + 更多），液态玻璃材质 | 阅读模式、查找页内文字 |
| 滚动时底栏折叠成胶囊/呼出动画，避让 inset 同步 | 开发者工具、扩展插件 |
| 状态栏文字深浅色随页面顶部颜色切换 | 请求桌面站点 |
| themeColor KVO 监听 + JS 探针采样顶部背景色 | 桌面端/iPad 适配（本期不验） |

## 3. 已确认决策

- **全 App 无自有品牌色**：浏览器不持有固定栏位颜色；栏位颜色一律来自当前页面
  ——有 theme-color 用 theme-color，没有则用探针采样的页面顶色（仅驱动状态栏
  文字深浅；底部 chrome 不染色，靠玻璃透出内容本身）。
- **顶部 = Safari 路线**：WebView frame 全屏，状态栏区域不放任何原生视图；
  `contentInsetAdjustmentBehavior` 保持默认 `.automatic`。
- **底部避让 = 多通道**（见 §4.1），不是初版的手动 contentInset 路线。
- **公开 contentInset 路线已被证伪**（作为 chrome 避让方案）：
  `scrollView.contentInset.bottom` 无法移动 `position:fixed` 元素、不改变
  `env()` 上报，QQ 新闻 fixed 底条仍被压住。两次验证：4a4a6b5、c98aebd
  （7 分钟后由 d4f552e 回退）。**不要再拿它做避让；它唯一合法的职责是
  滚动停留边界（见 §4.1 通道 2 末尾）。**
- **私有 API 风险已拍板（2026-08-31，2026-09-01 修订）**：布局视口通道在
  iOS 26+ 已改用公开属性 `obscuredContentInsets`，`_setObscuredInsets:` 仅作
  iOS 26 以下回退；`_setUnobscuredSafeAreaInsets:`（env 上报，经 IMP 调用）
  仍为私有，书面记录 App Store 审核风险；选择器不存在时静默降级（不崩溃）。
  若未来决定上架，需重新评估并准备公开 API 降级体验。

## 4. 核心原理

### 4.1 双层模型（落地版）

| 属性 | 决定什么 | 取值 |
|---|---|---|
| WebView frame | 网页**渲染**到哪里 | 全屏（延伸到状态栏与物理底边） |
| chrome 避让 inset | 布局视口**锚定**、fixed 元素位置、滚动**停留**边界 | 顶部 = 真实状态栏高；底部 = chrome 总高，显隐时随 SwiftUI 动画同步 |
| env 上报 | 页面 `env(safe-area-inset-*)` 读到的值 | 真实设备安全区（对齐 Safari），**不注入 chrome 高度** |

避让经 `BrowserChromeViewController` 三通道下发：

1. **公开安全区通道**——`additionalSafeAreaInsets` 抬高 WebView 有效安全区
  （顶部 = 真实状态栏高，底部 = chrome 总高），恢复 SwiftUI `ignoresSafeArea`
  消费掉的安全区；仅在值变化时写入，避免每次布局触发 WebKit 安全区重算。
2. **布局视口通道**——iOS 26 起用公开属性 `obscuredContentInsets`（收缩布局
  视口边界，驱动 fixed/sticky 元素锚定与滚动停留）；iOS 26 以下回退私有
  `_setObscuredInsets:`。**iOS 26 上 `_setObscuredInsets:` 已失效**：只影响
  `innerHeight`，不再约束 fixed 布局视口（实测 clientHeight 恒为全屏 874，
  fixed 底条锚在物理底被 chrome 压住、滚动时布局/视觉视口错位 152pt 致
  fixed 头部飞出屏幕）。公开属性内部会打开
  `_automaticallyAdjustsViewLayoutSizesWithObscuredInset` 才真正生效。
  **top 必须 = 真实状态栏高**：为 0 时非 cover 页（viewport-fit=auto）内容
  直接伸进状态栏（c9b6cda 与 2026-08-31 修复实证，auto 页 innerH=706）。
  另：iOS 26 的 WKWebView scrollView 以 `.never` 调整行为运行，且
  `obscuredContentInsets` 不回写 contentInset（实测 adjustedContentInset=0，
  页底内容会停在物理底边被 chrome 遮盖），滚动停留边界需向
  `scrollView.contentInset.bottom` 手动下发 chrome 总高
  （`verticalScrollIndicatorInsets` 同步，滚动条止于栏顶）；
  页底点胶囊展开时 inset 变大，`BrowserViewModel.expandToolbar` 同步补偿
  contentOffset 到新最大偏移，避免页底内容被展开的栏遮盖。
3. **env 通道**——`_setUnobscuredSafeAreaInsets:` 下发真实设备安全区
  （顶 62 / 底 34，对齐 Safari 语义）。曾错误地下发 chrome 总高（106），
  导致 fixed 底条自带 106pt 内边距、视觉悬空；chrome 避让完全由通道 2 的
  布局视口承担，env 只描述设备安全区。

- 滚动时正文从玻璃底栏底下流过（frame 全屏的自然结果）；
- 松手停稳后内容与 fixed 元素不被栏压住（布局视口的作用）；
- 页面的 fixed 底条相对 inset 调整后的视口定位，自动坐在栏上方；
  与栏顶的距离来自页面自身样式（如腾讯页约 30px），不要读、更不要写死。

### 4.2 顶部「透进状态栏」的三个条件

1. fixed 头部锚定在布局视口顶（= 状态栏下缘），状态栏区域的颜色由 iOS 26
   WebKit 内置的 fixed 边缘取色延展（fixed color extension）自动绘制——
   页面不需要自己往状态栏画颜色；env(top) 由 §4.1 通道 3 保证为真实值；
2. 容器链路 `.ignoresSafeArea([.container, .keyboard])`，安全区由
   `BrowserChromeViewController` 按 §4.1 恢复，而不是系统默认缩放；
3. 状态栏区域不放任何原生视图，状态栏文字直接浮在 WebView 上
   （`BrowserStatusBarGate` 借宿主空 VC 只控制文字样式，不画背景）。

### 4.3 状态栏文字颜色

无公开 API 自动跟随。`BrowserTintProbe` 注入脚本持续采样视口顶边渲染色
（fixed/sticky 覆盖层取色、渐变取首色标、半透明沿祖先链合成、回弹期间冻结、
MutationObserver 跟踪异步换肤），原生侧算亮度切 `preferredStatusBarStyle`。
`webView.themeColor`（KVO）有值时优先于采样结果。

### 4.4 颜色来源优先级

1. `webView.themeColor`（iOS 15+，KVO 监听）；
2. 探针采样页面顶色；
3. `underPageBackgroundColor` **保持默认不设置**——自动跟随页面背景，
   回弹区域免费解决。

## 5. 架构

```
BrowserRootView (SwiftUI)
 ├── BrowserWebViewContainer (UIViewControllerRepresentable)
 │    └── BrowserChromeViewController —— 多通道 inset 下发（§4.1）
 ├── BrowserToolbar —— 单行：前进/后退 + 地址胶囊 + 更多
 ├── 折叠胶囊（compactPill，收起态显示 host）
 ├── BrowserStatusBarGate —— 状态栏文字样式宿主
 ├── BrowserViewModel —— 地址/进度/折叠状态机/themeColor KVO
 └── BrowserTintProbe —— 注入式顶色采样（§4.3）
```

关键归属：

- WebView 只由 `BrowserWebViewFactory` 创建、归 `BrowserTabManager` 缓存所有；
  视图层只挂载，绝不创建（切标签/cover 不销毁页面状态）。
- chrome 高度预算集中在 `BrowserChromeMetrics`（单一来源），
  `BrowserViewModel.bottomChromeHeight` 组合安全区/键盘高度得出总 inset。
- 滚动折叠是阈值 24pt + 迟滞的状态机（方向极值跟随、橡皮筋不跟进、
  折叠态到达页底停留位自动展开、距页底不足一屏为稳定区禁止折叠），
  KVO 监听 `scrollView.contentOffset`，不用 scrollView delegate；
  状态机同时输出连续形变 progress（0=展开、1=折叠，滚动跟手），
  视图层按进度插值缩放/交叉淡入淡出，离散事件（点胶囊展开、页底自动
  展开）走 `collapseSpring`。

## 6. 实施记录

落地提交（2026-08-31）：

- c735eba：玻璃下透内容 + 工具栏折叠稳定化（迟滞/钳制补偿/回弹冻结/UA 冻结令牌）。
- c9b6cda：全屏 Safari 路线终态（chrome VC 双通道，移除顶/底染色层与手动
  contentInset 通道，themeColor KVO 接入）。
- 2026-08-31 修复：`obscured.top` 由 0 改为真实状态栏高——c9b6cda 的 top=0
  使非 cover 页布局视口锚在屏幕 0 点，内容伸进状态栏（模拟器探针页实证，
  修复后 auto 页 innerH 768→706，cover 页视觉不变）。
- 2026-09-01 修复：布局视口通道改用公开 `obscuredContentInsets`——iOS 26 上
  旧私有 `_setObscuredInsets:` 不再约束 fixed 布局视口，导致腾讯参考页
  fixed 头部滚动时飞出屏幕、fixed 底条被 chrome 压住（此前误判为"腾讯的
  设计"）。env 上报同步从 chrome 总高改为真实设备安全区。取证方法：注入
  自建 fixed 探针 div 对照各 inset 通道开关组合（clientHeight / 锚点坐标），
  对照组证实公开属性一条通道即可让 clientHeight=706、底条锚定 chrome 顶、
  滚动时头部钉住不动。
- 2026-09-01 修复（二）：滚动停留边界改由 `scrollView.contentInset` 手动下发——
  iOS 26 上 WKWebView scrollView 以 `.never` 运行且 obscuredContentInsets 不回写
  contentInset（adjustedContentInset 恒 0），页底内容停在物理底边被 chrome
  遮盖（此前被 env=106 带来的页面内边距掩盖，env 回归真实安全区后暴露）。
  附带：页底点胶囊展开时补偿 contentOffset 到新最大偏移。
- 2026-09-01 改进：折叠状态机新增页底自动展开——折叠态到达页底停留位
  （含橡皮筋停稳，容差 2pt）自动展开为完整工具条，ViewModel 同步补偿
  停留偏移；中途橡皮筋越界不在容差窗口内，不提前展开。
- 2026-09-01 修复（三）：页底稳定区——展开态在页底拖动（橡皮筋/小幅来回）
  会触发"折叠→页底自动展开"循环，表现为工具条抖动；距页底不足一屏
  （collapseCeilingOffsetY = 页底停留位 − 屏高）禁止折叠根治。附带：
  iOS 26 的 WebKit scrollView 不即时钳制程序化 contentOffset（越界停在
  内容外空白区、页底事件不触发），调试滚动钩子改为钳到合法范围。
- 2026-09-01 调整：工具条底部贴安全区（对齐 Safari 实测胶囊底边 ~34.7pt）——
  去掉行底外边距 8pt 与区域底垫 4pt，展开态 chrome 内容高 72→64，
  展开/折叠 inset 差相应变为 8pt；Home 指示条同日改为自动隐藏。
- 2026-09-01 调整：收缩胶囊对齐 Safari 实测（高约 30pt、底部间距 ~15pt、
  文字 ~15pt 常规重）——文字 footnote/light → subheadline，垂直内边距 2→7，
  底部间距 10→15；收起态 inset 预算 56→19（总 inset 90→53），展开/折叠
  inset 差变为 45pt，仍在页底稳定区内，补偿滚动不会反折。
- 2026-09-01 调整：折叠/展开切换动画对齐 Safari 形变手感——底部 chrome
  改为常驻单棵视图树（地址胶囊身份跨折叠态保持，尺寸/内边距/间距由
  toolbarCollapsed 的 spring 布局动画插值，按钮与进度条透明度过渡），
  取代原先的"整条滑出 + 胶囊滑入"容器级 transition（中间有空窗、手感生硬）。
  中途弃用过容器 scale+opacity 过渡与 matchedGeometryEffect 两条路线：
  前者仍有空窗，后者被容器 opacity transition 吞掉 hero 层不生效。
  同日再改：布局插值版看起来是"输入框和按钮各动各的"，重构为两个完整
  状态（整条展开栏 / 收缩胶囊）常驻 ZStack、作为**整体** scale + 交叉
  淡入淡出（缩放比 31/52，anchor .bottom），不再有任何按元素形变；
  隐形一侧 `allowsHitTesting(false)` 防止不可见视图拦截触摸。
- 2026-09-01 调整：胶囊材质 regular → clear 玻璃（iOS 26+）——目标是去掉
  工具条区域的奶白底色与投影但保留玻璃质感；regular 在浅色页面呈奶白实底+
  投影，clear 满足需求。中途曾误改为完全去背景（无玻璃），当天纠正。
  低版本回退从纯色 secondarySystemBackground 改为 ultraThinMaterial。
- 2026-09-01 调整：加载进度条从工具栏上方独立行并入地址胶囊内底边
  （对齐 Safari），改为无轨道填充线（Capsule 宽 = progress × 胶囊内宽）；
  按钮图标 title2/title3 → body（17pt），胶囊垂直内边距 14→10
  （胶囊 52→44pt，对齐 Safari 展开栏实测），展开态 chrome 内容高
  64→52（总 inset 98→86），展开/折叠 inset 差变为 33pt，仍在页底稳定区内。
- 2026-09-03 调整：折叠形变从"过阈值后 spring 一次性缩放"改为**滚动连续
  驱动**（用户反馈缩放太突然）——状态机输出 progress（0=展开、1=折叠，
  由基准点余量/阈值连续插值），视图层按进度缩放 + 交叉淡入淡出，滚动跟手；
  点胶囊展开、页底自动展开等离散事件走 `collapseSpring`（response 0.4 /
  damping 0.85）。
- 2026-09-03 丝滑度修复（用户反馈跟手仍不如 Safari）：① contentOffset KVO
  从 `Task { @MainActor }` 跳线改为主线程 `MainActor.assumeIsolated` 同步
  应用——进度与滚动同帧落地，消除 Task 调度的帧延迟抖动；② 两棵视图树
  恒挂 opacity/scaleEffect modifier、静止端为恒等值，替代端点 `@ViewBuilder`
  分支——避免过边界整树重建的闪跳。前提复检：26.5 上常量 transform
  （scale 1.0 / opacity 1.0）在两个静止端实测不压平玻璃（黑底页像素实证
  展开/收缩胶囊 tint 均 154/154/154 存活），§7 旧"常驻变换压平玻璃"结论
  仅适用于 26.0 时代，已随之失效。
- 2026-09-03 调整：玻璃 tint 浓度 50% → 60%（真机反馈加浓，质感更实）。

返工记录（教训：验证结论必须回写本文档，避免重复试错）：

- c98aebd → d4f552e：公开 contentInset 路线第二次尝试，7 分钟回退（同 4a4a6b5
  结论：管不了 fixed 元素与 env 上报）。
- eefb267 → 3aa3a13：顶部 frame 裁剪路线，14 分钟 revert。
- 21d7da8：frame 钉安全区下的过渡方案，被 c9b6cda 全屏路线整体取代。
- WKColorExtensionView 隐藏（c735eba 引入）已随 c9b6cda 的双通道方案移除，
  不再需要。

## 7. 边界与坑清单

- **WKWebView 不消费安全区**（iOS 26 实测）：只设 `additionalSafeAreaInsets`
  页面 env/布局视口不变，必须走 §4.1 通道 2/3。
- **iOS 26 上 `_setObscuredInsets:` 半失效**（2026-09-01 实证）：`innerHeight`
  与滚动边界仍响应，但 fixed 布局视口（`documentElement.clientHeight`、fixed
  元素锚定）恒为全屏，且滚动 + inset 变化时布局/视觉视口错位（vvTop=152），
  fixed 顶元素飞出屏幕。iOS 26+ 必须用公开 `obscuredContentInsets`。
- **`obscuredContentInsets` 同值早退陷阱**：旧私有调用先写入同值后，公开
  setter 会因值相同 early-return，漏掉打开
  `_automaticallyAdjustsViewLayoutSizesWithObscuredInset`——两条路不要混用，
  iOS 26+ 只走公开属性。
- **布局视口 top 不能为 0**：为 0 时非 cover 页（viewport-fit=auto，不读 env）
  内容伸进状态栏；顶部固定为真实状态栏高，cover/auto 页一致（状态栏区域由
  WebKit fixed 边缘取色延展绘制，对齐 iOS 26 Safari）。
- **env 不注入 chrome 高度**：`env(safe-area-inset-*)` 必须是真实设备安全区
  （顶 62 / 底 34）；注入 chrome 总高会让 fixed 底条自带超长内边距、视觉悬空
  （曾误记为"腾讯页面 fixed bottom: 32px"，实际页面 CSS 是 bottom: 0）。
- **私有 API 风险**：`_setUnobscuredSafeAreaInsets:`（及 iOS 26 以下回退的
  `_setObscuredInsets:`）有 App Store 审核风险（决策见 §3）；经
  `NSSelectorFromString` + IMP 调用，方法不存在时降级，不崩溃。
- **公开 contentInset 管不了 fixed 元素**：不影响 fixed 布局视口与 env() 上报
  （两次实证，见 §3）；但滚动停留边界恰恰是它的合法职责——iOS 26 `.never`
  行为下 adjustedContentInset 恒 0，必须手动下发（见 §4.1 通道 2）。
- **底栏不透明 = 穿透效果死亡**：滚动内容从栏下滑过依赖栏位透明，
  画底色/材质会看到「内容消失一块」。胶囊统一 `glassEffect(.clear)`
  （iOS 26+）：保留玻璃的边缘折射与质感，但去掉 regular 玻璃的
  奶白底色与投影（真机实测反馈，2026-09-01）；低版本回退
  `ultraThinMaterial`，禁用纯色背景。
- **clear 玻璃全透会与内容糊在一起**：滚动正文从胶囊底下流过时与地址文字
  重叠难读；给 clear 玻璃加 `systemBackground` tint 薄纱——折射质感
  保留、无奶白无投影，穿透度降下来且随深浅色自适应（2026-09-01 反馈调整，
  浓度经 40% 试看后定为 70%）。
- **iOS 26 glassEffect 滚动后压平：26.0 时代复现，26.5 已不复现（恢复 live glass）**：
  玻璃对 WebView 进程外渲染内容采样，仅加载后存活；页面一滚动（WebKit 图层树
  更替）采样失效，整组玻璃永久压平成透明（用户体感："缩放回来后玻璃变透明"）。
  2026-09-01 在 26.0 时代模拟器：排查证伪三条路径（静止态变换、tint 换衬底、
  不可见重叠玻璃去玻璃化），对照实验（仅加载 vs 滚动）锁定滚动为触发条件，
  当日弃用 live glass 改走 `ultraThinMaterial` 薄纱。2026-09-03 在 iOS 26.5
  模拟器用黑底测试页复测：下滚折叠、上滚展开（缩放回来）后三胶囊玻璃完整
  存活（tint 像素实证 131/131/131 vs 页底 0/0/0），判定为系统侧已修复，
  恢复 live glass：胶囊统一 `glassEffect(.clear.tint(systemBackground 50%))`
  ——玻璃质感（折射）保留，50% tint 兼顾穿透度与文字可读性，随深浅色自适应；
  低版本回退 `ultraThinMaterial`。真机如仍见滚动后压平，先确认系统版本 ≥ 26.5。
- **iOS 26 底部 scroll edge effect 也是奶白来源**：WKWebView scrollView
  默认在底部 obscured 区域叠加 automatic `UIScrollEdgeEffect`（模糊带+软
  阴影），与胶囊玻璃无关；必须 `scrollView.bottomEdgeEffect.isHidden = true`，
  否则 chrome 区看起来仍有一层奶白（真机实测反馈，2026-09-01）。
- **页面自有的 fixed 白底元素会原形毕露**：QQ 新闻文章页
  `interaction-bottom` 互动条底衬（fixed、纯白、94pt 高、约 85pt 故意悬在
  布局视口之下）是给 QQ/微信内置浏览器设计的，依赖宿主原生底栏遮盖；
  Safari 用磨砂标签栏藏住它，透明 chrome 下它盖住流过的正文。由
  `BrowserSiteQuirks` 注入窄规则把该元素背景透明化（2026-09-01 真机探针
  实证：元素 bottom 超出 innerH 85pt，透明化后 bg=rgba(0,0,0,0)）。
- **fixed 元素参照系**：相对 inset 调整后的视口，不是屏幕底边；页面自己的
  padding 不要读、不要写死。
- **第三方键盘安全区残缺**（实测约 136pt，远小于实际 424pt）：根层级
  `.ignoresSafeArea(.keyboard)`，避让统一由 `KeyboardHeightObserver` 手动垫高，
  防止双重叠加。
- **采样回弹冻结**：顶部橡皮筋期间视口顶边探出内容，采样会回落 body 底色
  导致状态栏闪烁，`scrollY < 0` 时冻结。
- **状态栏样式宿主**：`preferredStatusBarStyle` 要设在顶层 controller 上，
  SwiftUI 场景用 `BrowserStatusBarGate` 借宿主空 VC 承接。
- **回弹区域**靠 `underPageBackgroundColor` 默认值，不要手动设任何固定色。
- WebContent 进程被系统回收会白屏：`webViewWebContentProcessDidTerminate` → `reload()`。
- **chrome 高度预算**集中在 `BrowserChromeMetrics`：改工具栏/胶囊布局必须同步
  该文件，否则避让 inset 与实际 chrome 高度漂移。

## 8. 验收标准（用腾讯参考页逐项过）

参考页：https://view.inews.qq.com/k/20260827A09I2M00?scene=wap

1. 打开参考页：状态栏区域显示页面蓝色头部，状态栏文字为白色；
2. 下滑滚动：底栏折叠成胶囊，fixed 蓝条跟随动画滑向屏幕底；
3. 上滑：底栏呼出，fixed 蓝条回到栏上方（间距为页面自身样式，约 30px），
   不被压住、无额外悬空；
4. 快速滚动长文：正文从底栏底下模糊滑过（穿透），松手后底部文字不被栏压住；
5. 彻底拉到页底：底栏自动展开为完整工具条，页脚内容完整停在栏上方不被遮盖；
6. 页底停留后拖动/橡皮筋：工具条保持稳定，无折叠-展开抖动；
7. 右侧滚动条止于栏顶；
8. 页面拉到底/顶回弹：露出区域颜色与页面背景一致，无任何固定色残块；
9. 蓝头滚出视口后：状态栏文字切回深色，带过渡动画；
10. 全 App 任意页面（含起始页）不出现与当前页面无关的固定色；
11. 深色模式：玻璃材质自动变深，无额外色块；
12. Xcode 无编译警告，无 Auto Layout 冲突日志。
