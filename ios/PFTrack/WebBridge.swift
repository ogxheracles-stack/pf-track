import Foundation
import WebKit
import UIKit

/// WKScriptMessageHandler for the `pfHealth` channel.
/// JS → native: `{ action, id, payload? }`
/// Actions: health.requestAuth | health.getSummary | health.writeWeight | writeWater | writeEnergy | writeSleep | writeWorkout
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
            writeWeight: function(lb, iso) { return post('health.writeWeight', { lb: lb, date: iso || null }); },
            writeWater: function(oz, iso) { return post('health.writeWater', { oz: oz, date: iso || null }); },
            writeSleep: function(bed, wake) { return post('health.writeSleep', { bed: bed, wake: wake }); },
            writeWorkout: function(start, end, kcal) { return post('health.writeWorkout', { start: start, end: end, kcal: kcal || null }); },
            requestWriteOptIn: function() { return post('health.requestWriteOptIn', {}); },
            revokeWrites: function() { return post('health.revokeWrites', {}); }
          };
        })();
        """
    }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard message.name == Self.handlerName,
              let body = message.body as? [String: Any] else { return }
        let action = (body["action"] as? String) ?? ""
        let id = (body["id"] as? String) ?? ""
        let p = body["payload"] as? [String: Any] ?? [:]
        Task { @MainActor in
            do {
                let result = try await self.handle(action, p)
                self.reply(id: id, result)
            } catch {
                self.reply(id: id, ["ok": false, "error": error.localizedDescription])
            }
        }
    }

    /// Writes are gated NATIVELY: `HealthConsent.writesAllowed` lives in the app's own UserDefaults (the web page
    /// cannot read or set it) and is only set by the native UIAlert in `requestWriteOptIn`. Any web-side flag is ignored.
    /// Reads ask HealthKit only for what a feature needs, starting with steps + active energy.
    weak var presenter: UIViewController?

    private func handle(_ action: String, _ p: [String: Any]) async throws -> [String: Any] {
        if action.hasPrefix("health.write") && !HealthConsent.writesAllowed { throw HealthBridge.BridgeError.notOptedIn }
        switch action {
        case "health.requestAuth":
            try await health.requestRead(.recovery); return ["ok": true]
        case "health.revokeWrites":
            // Turning writes OFF is always allowed, from the web toggle or anywhere else.
            HealthConsent.revoke(); return ["ok": true]
        case "health.requestWriteOptIn":
            guard let vc = presenter else { return ["ok": false, "error": "no presenter"] }
            // The native prompt only follows a real touch in the app (UserGesture), never page load or a script on its own.
            guard UserGesture.isRecent else { return ["ok": false, "error": "needs a tap"] }
            let allowed = await HealthConsent.askNatively(from: vc)
            if allowed { try await health.requestWriteAuthorization() }
            return ["ok": allowed]
        case "health.getSummary":
            return await health.summary()
        case "health.writeWeight":
            try await health.writeBodyMass(lb: Self.num(p["lb"]) ?? 0, date: Self.day(p["date"]) ?? .now)
        case "health.writeWater":
            try await health.writeWater(oz: Self.num(p["oz"]) ?? 0, date: Self.day(p["date"]) ?? .now)
        case "health.writeEnergy":
            try await health.writeEnergy(kcal: Self.num(p["kcal"]) ?? 0, start: Self.ms(p["start"]) ?? .now, end: Self.ms(p["end"]) ?? .now)
        case "health.writeSleep":
            guard let bed = Self.ms(p["bed"]), let wake = Self.ms(p["wake"]) else { throw HealthBridge.BridgeError.invalid("sleep") }
            try await health.writeSleep(bed: bed, wake: wake)
        case "health.writeWorkout":
            guard let s = Self.ms(p["start"]), let e = Self.ms(p["end"]) else { throw HealthBridge.BridgeError.invalid("workout") }
            try await health.writeWorkout(start: s, end: e, kcal: Self.num(p["kcal"]))
        default:
            return ["ok": false, "error": "unknown action"]
        }
        return ["ok": true]
    }

    private static func num(_ v: Any?) -> Double? {
        if let n = v as? NSNumber { return n.doubleValue }
        if let s = v as? String { return Double(s) }
        return nil
    }
    /// Epoch milliseconds from JS Date.now()
    private static func ms(_ v: Any?) -> Date? { num(v).map { Date(timeIntervalSince1970: $0 / 1000) } }
    /// "yyyy-MM-dd" local day (noon, so time zones never flip the date)
    private static func day(_ v: Any?) -> Date? {
        guard let s = v as? String, !s.isEmpty else { return nil }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.date(from: s + " 12:00")
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
