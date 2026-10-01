import Foundation
import WebKit

/// WKScriptMessageHandler for the `pfHealth` channel.
/// JS → native: `{ action, id, payload? }`
/// Actions: `health.requestAuth` | `health.getSummary` | `health.writeWeight`
/// Native → JS: `window.__pfHealthReply(id, result)`
final class WebBridge: NSObject, WKScriptMessageHandler {
    weak var webView: WKWebView?
    private let health = HealthBridge.shared

    static let handlerName = "pfHealth"

    /// Injected at document-start so the page sees the bridge before boot.
    static func userScriptSource() -> String {
        """
        (function(){
          if (window.PFHealth && window.PFHealth.__native) return;
          var pending = {};
          function settle(id, result) {
            var p = pending[id];
            if (!p) return;
            delete pending[id];
            if (result && result.ok === false) p.reject(result);
            else p.resolve(result || {});
          }
          window.__pfHealthReply = function(id, result) {
            try { settle(id, typeof result === 'string' ? JSON.parse(result) : result); }
            catch (e) { settle(id, { ok:false, error: String(e) }); }
          };
          function post(action, payload) {
            return new Promise(function(resolve, reject) {
              var id = 'h' + Date.now().toString(36) + Math.random().toString(36).slice(2, 8);
              pending[id] = { resolve: resolve, reject: reject };
              try {
                if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.pfHealth) {
                  window.webkit.messageHandlers.pfHealth.postMessage({
                    action: action,
                    id: id,
                    payload: payload || {}
                  });
                } else {
                  reject({ ok:false, error:'no messageHandlers' });
                }
              } catch (e) {
                reject({ ok:false, error: String(e) });
              }
              setTimeout(function() {
                if (pending[id]) {
                  delete pending[id];
                  reject({ ok:false, error:'timeout' });
                }
              }, 20000);
            });
          }
          window.PFHealth = {
            available: true,
            __native: true,
            post: post,
            requestAuth: function() { return post('health.requestAuth', {}); },
            getSummary: function() { return post('health.getSummary', {}); },
            writeWeight: function(lb, iso) {
              return post('health.writeWeight', { lb: lb, date: iso || null });
            }
          };
        })();
        """
    }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard message.name == Self.handlerName else { return }
        guard let body = message.body as? [String: Any] else { return }
        let action = (body["action"] as? String) ?? ""
        let id = (body["id"] as? String) ?? ""
        let payload = body["payload"] as? [String: Any] ?? [:]

        switch action {
        case "health.requestAuth":
            health.requestAuthorization { ok, err in
                var r: [String: Any] = ["ok": ok]
                if let err = err { r["error"] = err }
                self.reply(id: id, r)
            }

        case "health.getSummary":
            health.fetchSummary { summary in
                self.reply(id: id, summary)
            }

        case "health.writeWeight":
            let lb: Double? = {
                if let d = payload["lb"] as? Double { return d }
                if let n = payload["lb"] as? NSNumber { return n.doubleValue }
                if let s = payload["lb"] as? String { return Double(s) }
                return nil
            }()
            guard let lb = lb, lb > 40, lb < 700 else {
                self.reply(id: id, ["ok": false, "error": "invalid weight"])
                return
            }
            var date = Date()
            if let iso = payload["date"] as? String, !iso.isEmpty {
                let f = DateFormatter()
                f.calendar = Calendar(identifier: .gregorian)
                f.locale = Locale(identifier: "en_US_POSIX")
                f.timeZone = TimeZone.current
                f.dateFormat = "yyyy-MM-dd"
                if let d = f.date(from: iso) { date = d }
            }
            health.writeWeight(lb: lb, date: date) { ok, err in
                var r: [String: Any] = ["ok": ok]
                if let err = err { r["error"] = err }
                self.reply(id: id, r)
            }

        default:
            reply(id: id, ["ok": false, "error": "unknown action"])
        }
    }

    private func reply(id: String, _ result: [String: Any]) {
        guard let webView = webView, !id.isEmpty else { return }
        guard let data = try? JSONSerialization.data(withJSONObject: result, options: []),
              let json = String(data: data, encoding: .utf8) else { return }
        let js = "window.__pfHealthReply && window.__pfHealthReply(\(Self.jsString(id)), \(json));"
        DispatchQueue.main.async {
            webView.evaluateJavaScript(js, completionHandler: nil)
        }
    }

    private static func jsString(_ s: String) -> String {
        let escaped = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "\"\(escaped)\""
    }
}
