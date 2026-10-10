import Foundation

/// App Group bridge between the app (web UI writes) and the WidgetKit extension (reads).
/// Group id must match both targets' entitlements and project.yml.
enum SharedStore {
    static let groupID = "group.pftrack.shared"
    static let key = "pftrack.widget.v1"

    struct Snapshot: Codable, Equatable {
        var v: Int = 1
        var date: String = ""
        var plan: String = ""
        var streak: Int = 0
        var verseRef: String = ""
        var verse: String = ""
        var updated: Double = 0

        static let placeholder = Snapshot(date: "", plan: "Upper A", streak: 3,
                                          verseRef: "Isaiah 40:31",
                                          verse: "but those who wait for Yahweh will renew their strength.")
    }

    static var defaults: UserDefaults? { UserDefaults(suiteName: groupID) }

    /// Called by the app with the JSON string the web UI posts (widgetPayload() in index.html).
    @discardableResult
    static func write(json: String) -> Bool {
        guard json.utf8.count < 8_192,
              let data = json.data(using: .utf8),
              (try? JSONDecoder().decode(Snapshot.self, from: data)) != nil,
              let d = defaults else { return false }
        d.set(data, forKey: key)
        return true
    }

    static func read() -> Snapshot? {
        guard let data = defaults?.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: data)
    }
}
