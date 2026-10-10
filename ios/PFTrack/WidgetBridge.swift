import Foundation
import WebKit
import WidgetKit

/// `pfWidget` WKScriptMessageHandler (plain WKWebView build). JS: pushWidgetState() in index.html posts
/// `{ action: "widget.update", payload: "<json>" }` on every persist(). We store it in the App Group and
/// ask WidgetKit to reload, throttled so a burst of taps does not burn the widget refresh budget.
final class WidgetBridge: NSObject, WKScriptMessageHandler {
    static let handlerName = "pfWidget"
    private var lastJSON = ""
    private var pending: DispatchWorkItem?

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard message.name == Self.handlerName,
              let body = message.body as? [String: Any],
              (body["action"] as? String) == "widget.update",
              let json = body["payload"] as? String,
              json != lastJSON else { return }
        lastJSON = json
        guard SharedStore.write(json: json) else { return }
        pending?.cancel()
        let work = DispatchWorkItem { WidgetCenter.shared.reloadTimelines(ofKind: "PFTrackWidget") }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }
}
