import UIKit
import Capacitor

/// Set as the root view controller class in App/Main.storyboard (replaces CAPBridgeViewController)
/// so the local PFWidget plugin is registered. capacitor-health registers itself via SPM/CocoaPods.
class MainViewController: CAPBridgeViewController {
    override open func capacitorDidLoad() {
        bridge?.registerPluginInstance(PFWidgetPlugin())
    }
}
