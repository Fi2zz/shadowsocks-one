# iOS 简易浏览器 Safari 对齐方案（顶部透色 + 底部玻璃栏）

> 状态：已落地（2026-08-31，终态提交 c9b6cda）。本文档已从"实施前方案"改写为
> "落地后设计记录"：与代码不一致的初版路线（.never + 手动 contentInset）已被
> 两次实证不可行并移除，见 §6 实施记录。后续改动以本文档为准。

## 1. 项目背景与现状

- 项目：iOS 简易浏览器，SwiftUI + WKWebView，iOS 17+。
- 已跑通：地址栏输入、前进/后退、多 Tab、后台开标签、外部 scheme 交系统。
- 已落地：Safari 同款浏览器栏行为——顶部状态栏区域透网页色、底部液态玻璃
  栏透出滚动内容、页面 fixed 元素自动避让底栏、滚动时底栏折叠/呼出。

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
- **底部避让 = 双通道**（见 §4.1），不是初版的手动 contentInset 路线。
- **公开 contentInset 路线已被证伪**：`scrollView.contentInset.bottom` 无法移动
  `position:fixed` 元素、不改变 `env()` 上报，QQ 新闻 fixed 底条仍被压住。
  两次验证：4a4a6b5、c98aebd（7 分钟后由 d4f552e 回退）。**不要再试第三次。**
- **私有 API 风险已拍板（2026-08-31）**：保留 `_setObscuredInsets:` /
  `_setUnobscuredSafeAreaInsets:`（经 IMP 调用），书面记录 App Store 审核风险；
  选择器不存在时静默降级为无避让（不崩溃）。若未来决定上架，需重新评估并
  准备公开 API 降级体验。

## 4. 核心原理

### 4.1 双层模型（落地版）

| 属性 | 决定什么 | 取值 |
|---|---|---|
| WebView frame | 网页**渲染**到哪里 | 全屏（延伸到状态栏与物理底边） |
| chrome 避让 inset | fixed 元素**锚定**位置、滚动**停留**边界、`env()` 上报 | 底部 = chrome 总高，显隐时随 SwiftUI 动画同步 |

避让经 `BrowserChromeViewController` 双通道下发：

1. **公开通道**——`additionalSafeAreaInsets` 抬高 WebView 有效安全区
  （顶部 = 真实状态栏高，底部 = chrome 总高），恢复 SwiftUI `ignoresSafeArea`
  消费掉的安全区；仅在值变化时写入，避免每次布局触发 WebKit 安全区重算。
2. **显式通道**——iOS 26 实测 WKWebView 不会自发消费安全区进入页面
  （env/布局视口均不变），需经 `_setObscuredInsets:`（fixed 元素布局视口与
  滚动范围）与 `_setUnobscuredSafeAreaInsets:`（env 上报值）显式下发。
  验证记录见 c9b6cda 提交信息（env(top)=状态栏高，env(bottom)=chrome 高，
  布局视口高度 874→768）。

- 滚动时正文从玻璃底栏底下流过（frame 全屏的自然结果）；
- 松手停稳后内容与 fixed 元素不被栏压住（inset 的作用）；
- 页面的 `fixed bottom: 32px` 相对 inset 调整后的视口定位，自动坐在栏上方
  ——不要读这个 32px，更不要写死。

### 4.2 顶部「透进状态栏」的三个条件

1. 网页声明 `viewport-fit=cover` + fixed 头部用 `env(safe-area-inset-top)` 自己
   把颜色画进状态栏区域（腾讯新闻这类站点已做）；env(top) 由双通道保证非 0；
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
 │    └── BrowserChromeViewController —— 双通道 inset 下发（§4.1）
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
  inset 钳制补偿），KVO 监听 `scrollView.contentOffset`，不用 scrollView delegate。

## 6. 实施记录

落地提交（2026-08-31）：

- c735eba：玻璃下透内容 + 工具栏折叠稳定化（迟滞/钳制补偿/回弹冻结/UA 冻结令牌）。
- c9b6cda：全屏 Safari 路线终态（chrome VC 双通道，移除顶/底染色层与手动
  contentInset 通道，themeColor KVO 接入）。

返工记录（教训：验证结论必须回写本文档，避免重复试错）：

- c98aebd → d4f552e：公开 contentInset 路线第二次尝试，7 分钟回退（同 4a4a6b5
  结论：管不了 fixed 元素与 env 上报）。
- eefb267 → 3aa3a13：顶部 frame 裁剪路线，14 分钟 revert。
- 21d7da8：frame 钉安全区下的过渡方案，被 c9b6cda 全屏路线整体取代。
- WKColorExtensionView 隐藏（c735eba 引入）已随 c9b6cda 的双通道方案移除，
  不再需要。

## 7. 边界与坑清单

- **WKWebView 不消费安全区**（iOS 26 实测）：只设 `additionalSafeAreaInsets`
  页面 env/布局视口不变，必须走 §4.1 显式通道。
- **私有 API 风险**：`_setObscuredInsets:` / `_setUnobscuredSafeAreaInsets:` 有
  App Store 审核风险（决策见 §3）；经 `NSSelectorFromString` + IMP 调用，
  方法不存在时降级为无避让，不崩溃。
- **公开 contentInset 管不了 fixed 元素**：只影响滚动停留边界，不影响 fixed
  布局视口与 env() 上报（两次实证，见 §3）。
- **底栏不透明 = 穿透效果死亡**：滚动内容从栏下滑过依赖玻璃半透明，
  画纯色会看到「内容消失一块」。
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
3. 上滑：底栏呼出，fixed 蓝条回到栏上方约 32px，不被压住；
4. 快速滚动长文：正文从底栏底下模糊滑过（穿透），松手后底部文字不被栏压住；
5. 右侧滚动条止于栏顶；
6. 页面拉到底/顶回弹：露出区域颜色与页面背景一致，无任何固定色残块；
7. 蓝头滚出视口后：状态栏文字切回深色，带过渡动画；
8. 全 App 任意页面（含起始页）不出现与当前页面无关的固定色；
9. 深色模式：玻璃材质自动变深，无额外色块；
10. Xcode 无编译警告，无 Auto Layout 冲突日志。
