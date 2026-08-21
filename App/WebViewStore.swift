import WebKit

@MainActor
final class WebViewStore: ObservableObject, Identifiable {
    let id = UUID()
    let webView = WKWebView()

    @Published private(set) var title = "新标签页"
    @Published private(set) var currentURL: URL?
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    @Published private(set) var loadError: String?
    @Published private(set) var progress: Double = 0

    var onFinishNavigation: ((URL, String) -> Void)?

    private var progressObservation: NSKeyValueObservation?

    init() {
        progressObservation = webView.observe(\.estimatedProgress, options: [.new]) { [weak self] webView, _ in
            Task { @MainActor in
                self?.progress = webView.estimatedProgress
            }
        }
    }

    func load(_ url: URL) {
        webView.load(URLRequest(url: url))
    }

    func goBack() {
        webView.goBack()
    }

    func goForward() {
        webView.goForward()
    }

    func reload() {
        webView.reload()
    }

    func syncState() {
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
        currentURL = webView.url
        if let pageTitle = webView.title, !pageTitle.isEmpty {
            title = pageTitle
        }
    }

    func clearLoadError() {
        loadError = nil
    }

    func reportFailure(_ error: Error) {
        let nsError = error as NSError
        loadError = "\(error.localizedDescription) (\(nsError.domain) \(nsError.code))"
    }

    func reportFinishedNavigation() {
        guard let url = webView.url else {
            return
        }
        onFinishNavigation?(url, webView.title ?? url.host ?? url.absoluteString)
    }
}
