import SwiftUI
import WebKit

struct WebViewRepresentable: UIViewRepresentable {
    let store: WebViewStore

    func makeUIView(context: Context) -> WKWebView {
        store.webView.navigationDelegate = context.coordinator
        return store.webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(store: store)
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        private let store: WebViewStore

        init(store: WebViewStore) {
            self.store = store
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            store.clearLoadError()
            store.syncState()
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            store.syncState()
            store.reportFinishedNavigation()
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            store.syncState()
            store.reportFailure(error)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            store.syncState()
            store.reportFailure(error)
        }
    }
}
