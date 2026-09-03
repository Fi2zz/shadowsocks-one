import Foundation

/// 主框架加载失败时渲染进 WebView 的内嵌错误页（Safari 式）。
/// 纯 HTML 字符串组装，不依赖 WebKit；「重新载入」用原始 URL 的链接实现，
/// 避免在 HTML 里内嵌需要转义的 JS 字符串。
enum BrowserErrorPage {
    static func html(url: URL, message: String) -> String {
        """
        <!DOCTYPE html><html><head><meta charset="utf-8">\
        <meta name="viewport" content="width=device-width, initial-scale=1">\
        <style>\(css)</style></head>\
        <body><div class="card">\
        <h1>无法打开此页面</h1>\
        <p class="host">\(escapeHTML(url.absoluteString))</p>\
        <p class="msg">\(escapeHTML(message))</p>\
        <a class="btn" href="\(escapeHTML(url.absoluteString))">重新载入</a>\
        </div></body></html>
        """
    }

    private static let css = """
        body { margin: 0; min-height: 100vh; display: flex; align-items: center; \
        justify-content: center; background: #f2f2f7; color: #1c1c1e; \
        font-family: -apple-system, sans-serif; }
        .card { max-width: 340px; padding: 32px 24px; text-align: center; \
        background: #fff; border-radius: 16px; }
        h1 { font-size: 20px; margin: 0 0 12px; }
        p { font-size: 13px; color: #8e8e93; word-break: break-all; margin: 4px 0; }
        .btn { display: inline-block; margin-top: 16px; padding: 10px 28px; \
        background: #0a84ff; color: #fff; border-radius: 10px; \
        text-decoration: none; font-size: 15px; }
        @media (prefers-color-scheme: dark) {
          body { background: #000; color: #f2f2f7; }
          .card { background: #1c1c1e; }
        }
        """

    private static func escapeHTML(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
