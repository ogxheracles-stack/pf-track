import UIKit
import WebKit

/// Hosts the single-file PF//TRACK UI in a WKWebView and exposes HealthKit via WebBridge.
final class ViewController: UIViewController, WKNavigationDelegate {
    private var webView: WKWebView!
    private let bridge = WebBridge()
    private let widgetBridge = WidgetBridge()

    private let remoteURL = URL(string: "https://ogxheracles-stack.github.io/pf-track/")!

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(red: 0.05, green: 0.07, blue: 0.10, alpha: 1)

        let uc = WKUserContentController()
        let script = WKUserScript(
            source: WebBridge.userScriptSource(),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        uc.addUserScript(script)
        uc.add(bridge, name: WebBridge.handlerName)
        uc.add(widgetBridge, name: WidgetBridge.handlerName)

        let config = WKWebViewConfiguration()
        config.userContentController = uc
        config.allowsInlineMediaPlayback = true
        if #available(iOS 14.0, *) {
            config.defaultWebpagePreferences.allowsContentJavaScript = true
        }

        webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.isOpaque = false
        webView.backgroundColor = view.backgroundColor
        webView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: view.topAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])

        bridge.webView = webView
        bridge.presenter = self
        loadApp()
    }

    private func loadApp() {
        // Prefer live Pages build; fall back to bundled index.html for offline / airplane.
        var req = URLRequest(url: remoteURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)
        req.setValue("PFTrack-iOS/4.76", forHTTPHeaderField: "User-Agent")
        webView.load(req)
    }

    private func loadBundledFallback() {
        if let url = Bundle.main.url(forResource: "index", withExtension: "html") {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
            return
        }
        // Last resort: minimal notice page
        let html = """
        <!doctype html><meta name=viewport content="width=device-width,initial-scale=1">
        <body style="font-family:-apple-system;background:#0d1218;color:#e8eef5;padding:2rem">
        <h1>PF//TRACK</h1>
        <p>Could not reach Pages and no bundled index.html was found. Add index.html to the app target Copy Bundle Resources, or check network.</p>
        </body>
        """
        webView.loadHTMLString(html, baseURL: nil)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        loadBundledFallback()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        // Keep current content; only provisional failure swaps to bundle.
    }

    deinit {
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: WebBridge.handlerName)
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: WidgetBridge.handlerName)
    }
}
