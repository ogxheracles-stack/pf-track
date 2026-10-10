import Foundation
import Capacitor
import WidgetKit

/// In-house local Capacitor plugin (no third-party bridge): JS `Capacitor.Plugins.PFWidget.update({ json })`
/// (pushWidgetState() in index.html) -> App Group UserDefaults -> WidgetKit reload. Needs SharedStore.swift
/// (ios/Shared) in the App target and the group.pftrack.shared App Group on App + widget.
@objc(PFWidgetPlugin)
public class PFWidgetPlugin: CAPPlugin, CAPBridgedPlugin {
    public let identifier = "PFWidgetPlugin"
    public let jsName = "PFWidget"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "update", returnType: CAPPluginReturnPromise)
    ]
    private var lastJSON = ""

    @objc func update(_ call: CAPPluginCall) {
        guard let json = call.getString("json") else { return call.reject("json required") }
        guard json != lastJSON else { return call.resolve(["changed": false]) }
        guard SharedStore.write(json: json) else { return call.reject("invalid payload or App Group missing") }
        lastJSON = json
        WidgetCenter.shared.reloadTimelines(ofKind: "PFTrackWidget")
        call.resolve(["changed": true])
    }
}
