import WidgetKit
import SwiftUI

/// Home Screen widget (small + medium): today's plan, streak, daily verse. Reads the App Group snapshot the app
/// writes from the web UI (SharedStore). Calm by design: no animation, no countdowns, system colours only.
struct PFEntry: TimelineEntry {
    let date: Date
    let snap: SharedStore.Snapshot
}

struct PFProvider: TimelineProvider {
    func placeholder(in context: Context) -> PFEntry { PFEntry(date: .now, snap: .placeholder) }

    func getSnapshot(in context: Context, completion: @escaping (PFEntry) -> Void) {
        completion(PFEntry(date: .now, snap: SharedStore.read() ?? .placeholder))
    }

    /// One entry now; refresh just after local midnight so the plan/verse roll over even if the app is not opened.
    func getTimeline(in context: Context, completion: @escaping (Timeline<PFEntry>) -> Void) {
        let entry = PFEntry(date: .now, snap: SharedStore.read() ?? .placeholder)
        let next = Calendar.current.nextDate(after: .now, matching: DateComponents(hour: 0, minute: 5), matchingPolicy: .nextTime) ?? .now.addingTimeInterval(6 * 3600)
        completion(Timeline(entries: [entry], policy: .after(next)))
    }
}

struct PFWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: PFEntry

    var body: some View {
        let s = entry.snap
        VStack(alignment: .leading, spacing: 6) {
            Text("PF//TRACK").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            Text(s.plan.isEmpty ? "Open the app" : s.plan)
                .font(.headline).lineLimit(2).minimumScaleFactor(0.8)
            Label("\(s.streak) day streak", systemImage: "flame")
                .font(.caption).foregroundStyle(.secondary)
            if family == .systemMedium, !s.verse.isEmpty {
                Spacer(minLength: 2)
                Text(s.verse).font(.footnote).lineLimit(3)
                Text(s.verseRef).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .containerBackground(.background, for: .widget) // required on iOS 17+
        .widgetURL(URL(string: "pftrack://home"))
        .accessibilityElement(children: .combine)
    }
}

struct PFTrackWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "PFTrackWidget", provider: PFProvider()) { PFWidgetView(entry: $0) }
            .configurationDisplayName("PF//TRACK Today")
            .description("Today's plan, your streak and the daily verse.")
            .supportedFamilies([.systemSmall, .systemMedium])
    }
}

@main
struct PFTrackWidgetBundle: WidgetBundle {
    var body: some Widget { PFTrackWidget() }
}

#Preview(as: .systemMedium) { PFTrackWidget() } timeline: { PFEntry(date: .now, snap: .placeholder) }
