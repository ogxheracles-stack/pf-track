# PF//TRACK iOS — Apple Health bridge

Thin native shell: **WKWebView** loads the live Pages build (`https://ogxheracles-stack.github.io/pf-track/`) with a bundled `index.html` fallback, plus **HealthKit** read/write exposed to the web UI via `webkit.messageHandlers.pfHealth` / `window.PFHealth`.

Privacy-first. No Face ID. No cloud. No paywall on health.

## Files

```
ios/
  README_IOS.md
  PFTrack/
    Info.plist                 # NSHealthShare/UpdateUsageDescription
    PFTrack.entitlements       # HealthKit capability stub
    AppDelegate.swift
    SceneDelegate.swift
    ViewController.swift       # WKWebView host
    HealthBridge.swift         # HK auth + summary + write weight
    WebBridge.swift            # WKScriptMessageHandler
```

Copy `../index.html` into the app target (Copy Bundle Resources) for offline fallback.

## Open in Xcode (Mac)

1. **File → New → Project → iOS → App**
   - Product Name: `PFTrack`
   - Interface: **Storyboard** (or Empty — we set the root VC in code)
   - Language: **Swift**
   - Uncheck Core Data / Tests if you want a minimal target
2. Replace generated sources with the files in `ios/PFTrack/`.
   - Keep or delete Main.storyboard; SceneDelegate already sets `ViewController` as root.
   - Point Info.plist at `PFTrack/Info.plist` (or merge the Health usage strings + scene manifest into the project plist).
3. **Signing & Capabilities**
   - Select your **Team**
   - **+ Capability → HealthKit** (entitlements file is already stubbed)
4. **Bundle identifier**: e.g. `com.yourname.pftrack` (HealthKit requires a real team + device)
5. Drag repo-root `index.html` into the target → check **Copy Bundle Resources**
6. Run on a **physical iPhone** (HealthKit is limited / unavailable in many Simulator configs)

Minimum: iOS 15+ recommended (sleep stage values). Device required for real HR / HRV / sleep.

## Bridge contract (web ↔ native)

| Action | Direction | Payload | Result |
|--------|-----------|---------|--------|
| `health.requestAuth` | JS → native | `{}` | `{ ok, error? }` |
| `health.getSummary` | JS → native | `{}` | `{ ok, heartRate?, restingHR?, hrv?, sleepHours?, steps?, activeEnergy?, bodyMassLb? }` |
| `health.writeWeight` | JS → native | `{ lb, date? }` ISO date optional | `{ ok, error? }` |

Detection in JS:

```js
window.webkit?.messageHandlers?.pfHealth  // or
window.PFHealth?.available === true
```

Native injects `window.PFHealth` at document-start (see `WebBridge.userScriptSource()`).

### Read types
heartRate, restingHeartRate, heartRateVariabilitySDNN, sleepAnalysis, activeEnergyBurned, stepCount, bodyMass

### Write types (optional, user-gated in web UI)
bodyMass, workouts (entitled; web currently writes weight only)

## Safari / Pages

Opening the site in Safari has **no** HealthKit bridge. The web UI shows “Requires PF//TRACK iOS app” and never error-toasts on missing bridge.

## Doctrine

Keep the single-file web app as the product UI. This folder is a thin HealthKit + WebView shell only.
