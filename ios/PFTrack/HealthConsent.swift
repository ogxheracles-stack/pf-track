import UIKit
import UIKit.UIGestureRecognizerSubclass

/// Native-only consent for Apple Health WRITES. Stored in the app's standard UserDefaults, which WKWebView content
/// cannot read or write (web storage is separate). Set only from a native UIAlertController the user answers.
enum HealthConsent {
    private static let key = "pftrack.health.writes.allowed.v1"

    static var writesAllowed: Bool { UserDefaults.standard.bool(forKey: key) }

    /// Revoking is always allowed (web toggle off, Settings switch off, "Stop writing to Health").
    static func revoke() {
        UserDefaults.standard.removeObject(forKey: key)
        UserDefaults.standard.set(false, forKey: settingsKey)
    }

    /// Settings.bundle switch "Write to Apple Health" (iOS Settings > PF//TRACK). It can only turn writes OFF:
    /// on every foreground we mirror our consent into it; if the user switched it off we revoke, and if it was
    /// switched on without the native Allow prompt we put it back to off. Granting stays native-alert only.
    static let settingsKey = "health_writes_enabled"
    static func syncWithSettings() {
        let d = UserDefaults.standard
        if writesAllowed && d.object(forKey: settingsKey) != nil && !d.bool(forKey: settingsKey) { revoke(); return }
        d.set(writesAllowed, forKey: settingsKey)
    }

    /// Shows the native prompt and records the answer. Returns true only on an explicit "Allow".
    @MainActor
    static func askNatively(from vc: UIViewController) async -> Bool {
        if writesAllowed { return true }
        return await withCheckedContinuation { cont in
            let a = UIAlertController(
                title: "Save to Apple Health?",
                message: "PF//TRACK will save the workouts, sleep, weight, water and energy you log into Apple Health. Nothing leaves your iPhone. You can turn this off in Settings > Health > Data Access.",
                preferredStyle: .alert)
            a.addAction(UIAlertAction(title: "Not now", style: .cancel) { _ in cont.resume(returning: false) })
            a.addAction(UIAlertAction(title: "Allow", style: .default) { _ in
                UserDefaults.standard.set(true, forKey: key)
                UserDefaults.standard.set(true, forKey: settingsKey)
                cont.resume(returning: true)
            })
            vc.present(a, animated: true)
        }
    }
}

/// Time of the last real touch on the web view, recorded natively (a page script cannot fake it).
enum UserGesture {
    private(set) static var last: Date = .distantPast
    static func mark() { last = Date() }
    static var isRecent: Bool { Date().timeIntervalSince(last) < 2 }
}

/// Watches touches on the web view without stealing them.
final class TouchWatcher: UIGestureRecognizer, UIGestureRecognizerDelegate {
    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        cancelsTouchesInView = false; delaysTouchesBegan = false; delaysTouchesEnded = false; delegate = self
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) { UserGesture.mark(); state = .failed }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) { }
    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
}
