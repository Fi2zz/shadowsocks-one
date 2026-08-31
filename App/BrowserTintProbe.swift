import WebKit

/// Safari 式状态栏染色探针。注入页面的脚本持续采样「内容区顶边的渲染颜色」：
/// 1. 顶边命中元素若处于 fixed/sticky 覆盖层内 → 采用其背景色（渐变取首个色标）；
/// 2. 否则（普通文档流元素，对齐 Safari 静态头部不染色的行为）→ 回退 body → html 背景；
/// 3. 半透明背景沿祖先链逐级合成，最终不透明色经 ssOneTint 消息上报，变化时才发送。
enum BrowserTintProbe {
    static let messageHandlerName = "ssOneTint"

    static func install(into configuration: WKWebViewConfiguration, handler: WKScriptMessageHandler) {
        let controller = configuration.userContentController
        controller.addUserScript(
            WKUserScript(source: javaScript, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        )
        controller.add(handler, name: messageHandlerName)
    }

    /// 原生侧主动触发（切标签后重发当前色，force=true 绕过去重）
    static let reprobeScript = "__ssOneProbeTint && __ssOneProbeTint(true)"

    static let javaScript = """
      (function () {
      'use strict';
      var LAST_TOP = null;
      var LAST_BOTTOM = null;
      function colorOf(css) {
        if (!css) return null;
        var m = /rgba?\\(([^)]+)\\)/.exec(css);
        if (m) {
          var p = m[1].split(/[,\\/\\s]+/).filter(Boolean).map(Number);
          if (p.length < 3 || p.slice(0, 3).some(isNaN)) return null;
          var a = p.length > 3 ? p[3] : 1;
          if (a === 0) return null;
          return { r: p[0], g: p[1], b: p[2], a: a };
        }
        if (css.charAt(0) === '#') {
          var h = css.slice(1);
          if (h.length === 3) h = h[0] + h[0] + h[1] + h[1] + h[2] + h[2];
          var n = parseInt(h, 16);
          if (isNaN(n)) return null;
          return { r: (n >> 16) & 255, g: (n >> 8) & 255, b: n & 255, a: 1 };
        }
        return null;
      }
      function gradientTop(css) {
        if (!css || css.indexOf('gradient') === -1) return null;
        var m = /(rgba?\\([^)]+\\)|#[0-9a-fA-F]{3,8})/.exec(css);
        return m ? colorOf(m[1]) : null;
      }
      function blend(fg, bg) {
        return {
          r: fg.r * fg.a + bg.r * (1 - fg.a),
          g: fg.g * fg.a + bg.g * (1 - fg.a),
          b: fg.b * fg.a + bg.b * (1 - fg.a),
          a: 1
        };
      }
      function edgeColorOf(el) {
        var cur = el, inOverlay = false, acc = null;
        for (var depth = 0; cur && cur.nodeType === 1 && depth < 16; depth++) {
          var cs = getComputedStyle(cur);
          if (cs.position === 'fixed' || cs.position === 'sticky') inOverlay = true;
          // 颜色凑满不透明即可停，但 fixed/sticky 判定必须走完整条祖先链
          //（QQ 新闻：static 蓝色 header 的祖父才是 fixed wrapper）
          if (!acc || acc.a < 1) {
            var c = colorOf(cs.backgroundColor) || gradientTop(cs.backgroundImage);
            if (c) {
              acc = acc ? blend(c, acc) : c;
            }
          }
          cur = cur.parentElement;
        }
        if (!acc) return null;
        // 对齐 Safari：只有固定/粘滞覆盖层染色，文档流元素一律回退 body 背景
        return inOverlay ? acc : null;
      }
      function edgeColorAt(y, w) {
        var result = null;
        var xs = [w / 2, 12, w - 12];
        for (var i = 0; i < xs.length && !result; i++) {
          var el = document.elementFromPoint(xs[i], y);
          if (el) result = edgeColorOf(el);
        }
        if (!result) {
          var order = [document.body, document.documentElement];
          for (var j = 0; j < order.length && !result; j++) {
            if (order[j]) result = colorOf(getComputedStyle(order[j]).backgroundColor);
          }
        }
        return result;
      }
      function keyOf(c) {
        return c ? [c.r, c.g, c.b, c.a].join(',') : 'none';
      }
      function probe(force) {
        var w = document.documentElement.clientWidth;
        var h = document.documentElement.clientHeight;
        // 顶部回弹期间视口顶边已探出内容之外，采样会回落到 body 底色导致
        // 状态栏色块闪烁丢失；回弹期间冻结采样，保持回弹前的顶色（对齐 Safari）
        var sy = window.scrollY || 0;
        if (sy < 0) return;
        var top = edgeColorAt(2, w);
        var bottom = edgeColorAt(h - 2, w);
        var tKey = keyOf(top), bKey = keyOf(bottom);
        if (force || tKey !== LAST_TOP || bKey !== LAST_BOTTOM) {
          LAST_TOP = tKey;
          LAST_BOTTOM = bKey;
          if (window.webkit && window.webkit.messageHandlers.ssOneTint) {
            window.webkit.messageHandlers.ssOneTint.postMessage({ t: tKey, b: bKey });
          }
        }
      }
      window.__ssOneProbeTint = probe;
      ['DOMContentLoaded', 'load', 'pageshow'].forEach(function (name) {
        window.addEventListener(name, function () { probe(false); }, true);
      });
      // 主题色常由页面 JS 在加载后异步注入（如 QQ 新闻 hydration 后请求换肤
      // 接口再改深层元素的内联 style），监听根节点属性、head 子树、以及 body
      // 子树内任意元素的 style/class 变化，并在 pageshow 后补采几次
      var pending = false;
      function scheduleProbe() {
        if (pending) return;
        pending = true;
        requestAnimationFrame(function () { pending = false; probe(false); });
      }
      var observer = new MutationObserver(scheduleProbe);
      function observeRoot() {
        var filter = { attributes: true, attributeFilter: ['style', 'class'] };
        observer.observe(document.documentElement, filter);
        if (document.body) observer.observe(document.body, filter);
      }
      observeRoot();
      document.addEventListener('DOMContentLoaded', observeRoot);
      if (document.head) observer.observe(document.head, { childList: true, subtree: true });
      if (document.body) {
        observer.observe(document.body, {
          attributes: true, attributeFilter: ['style', 'class'], subtree: true
        });
      }
      window.addEventListener('pageshow', function () {
        [400, 1200, 3000].forEach(function (delay) {
          setTimeout(function () { probe(false); }, delay);
        });
      });
      window.addEventListener('scroll', scheduleProbe, { passive: true });
    })();
    """
}
