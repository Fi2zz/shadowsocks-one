import WebKit

/// 调试探针：`SSBrowserProbeBottom` 启动后对活动 WebView 底部区域取证（6s/12s 各一次）——
/// 输出 bottomEdgeEffect 隐藏状态、contentInset，以及页面布局视口底部 320pt 内的
/// fixed/sticky 元素与底部中心点元素链。结果同时写 print 与
/// Documents/bottom_probe.txt（真机 devicectl --console 不可用时用
/// `devicectl device copy from --domain-type appDataContainer` 拉回）
enum BrowserBottomProbe {
    static func runIfRequested() {
        guard BrowserDebugFlags.value(forKey: "SSBrowserProbeBottom") != nil else { return }
        // 真机经隧道加载较慢，探两次：覆盖"刚到滚动位"与"页面稳定后"
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { run() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) { run() }
    }

    @MainActor
    private static func run() {
        guard let webView = BrowserTabManager.shared.activeWebView else { return }
        report(nativeState(of: webView))
        webView.evaluateJavaScript(script) { result, error in
            report("dom: \(result ?? "nil") jsError: \(error?.localizedDescription ?? "nil")")
        }
    }

    private static func nativeState(of webView: WKWebView) -> String {
        let scrollView = webView.scrollView
        var text = "contentInset: \(scrollView.contentInset) adjusted: \(scrollView.adjustedContentInset)"
        if #available(iOS 26.0, *) {
            text += " bottomEdgeEffect.isHidden: \(scrollView.bottomEdgeEffect.isHidden)"
        }
        return text
    }

    private static func report(_ line: String) {
        let stamped = "[BottomProbe] \(line)"
        print(stamped)
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("bottom_probe.txt")
        let data = (stamped + "\n").data(using: .utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            if let data { handle.write(data) }
            try? handle.close()
        } else {
            try? data?.write(to: url)
        }
    }

    private static let script = """
    (function () {
      const H = window.innerHeight;
      const near = Array.from(document.querySelectorAll('body *')).filter(el => {
        const p = getComputedStyle(el).position;
        return p === 'fixed' || p === 'sticky';
      }).map(el => {
        const r = el.getBoundingClientRect();
        const s = getComputedStyle(el);
        return { tag: el.tagName.toLowerCase(), cls: String(el.className).slice(0, 40),
          pos: s.position, top: Math.round(r.top), bottom: Math.round(r.bottom),
          bg: s.backgroundColor, z: s.zIndex };
      }).filter(e => e.bottom > H - 320 && e.top < H + 20);
      const chain = [];
      let el = document.elementFromPoint(window.innerWidth / 2, H - 16);
      while (el && chain.length < 6) {
        const s = getComputedStyle(el);
        chain.push({ tag: el.tagName.toLowerCase(), cls: String(el.className).slice(0, 40),
          bg: s.backgroundColor, pos: s.position });
        el = el.parentElement;
      }
      const bodyBg = getComputedStyle(document.body).backgroundColor;
      return JSON.stringify({ innerH: H, clientH: document.documentElement.clientHeight,
        scrollY: Math.round(window.scrollY), bodyBg, fixedNearBottom: near,
        atBottomCenter: chain });
    })()
    """
}
