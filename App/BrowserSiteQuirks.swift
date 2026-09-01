import WebKit

/// 站点怪癖修正：以 user script 注入窄规则样式。
/// REASON: QQ 新闻文章页的 `interaction-bottom` 互动条底衬是给 QQ/微信内置
/// 浏览器设计的——94pt 高、纯白背景、约 85pt 故意悬在布局视口之下，依赖宿主
/// 原生底栏遮盖（2026-09-01 真机探针实证：元素 bottom 超出 innerH 85pt）。
/// Safari 用磨砂标签栏遮住它；本浏览器 chrome 全透明，白底会盖住流过的正文。
/// 只把该元素背景透明化，不动布局与子元素；页面结构不变则长期需要。
enum BrowserSiteQuirks {
    static func install(into configuration: WKWebViewConfiguration) {
        configuration.userContentController.addUserScript(
            WKUserScript(source: javaScript, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        )
    }

    private static let javaScript = """
      (function () {
      'use strict';
      var style = document.createElement('style');
      style.textContent =
        'div[class*="interaction-bottom_interaction"] { background: transparent !important; }';
      (document.head || document.documentElement).appendChild(style);
    })();
    """
}
