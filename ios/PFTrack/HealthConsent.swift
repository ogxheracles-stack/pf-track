import UIKit

/// Native-only consent for Apple Health WRITES. Stored in the app's standard UserDefaults, which WKWebView content
/// cannot read or write (web storage is separate). Set only from a native UIAlertController the user answers.
enum HealthConsent {
    private static let key = "pftrack.health.writes.allowed.v1"

    static var writesAllowed: Bool { UserDefaults.standard.bool(forKey: key) }

    static func revoke() { UserDefaults.standard.removeObject(forKey: key) }

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
                cont.resume(returning: true)
            })
            vc.present(a, animated: true)
        }
    }
}
