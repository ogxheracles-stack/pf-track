# PF//TRACK iOS — wrapper, Apple Health bridge, Home Screen widget (v4.76)

Scaffold only: written on Linux and not compiled here. Swift targets iOS 17+ (async HealthKit descriptors,
`HKWorkoutBuilder`, `containerBackground`). Build and review it on a Mac before any real health data touches it.
Privacy rules: on-device only, no cloud, no Face ID, Health **writes off** until the user turns them on in More.
Storage key `pftrack_v3` is never touched by native code; the native side only sees what the page posts.

There are two ways to ship the same `index.html`. Pick one:

| | A. Plain WKWebView (XcodeGen) | B. Capacitor 8.5.3 (recommended by the 2026-10-10 tool review) |
|---|---|---|
| Health | own `HealthBridge.swift` + `WebBridge.swift` (`pfHealth` handler) | `capacitor-health` 8.4.0 (MIT). Audit its Swift before using real data |
| Widget feed | `WidgetBridge.swift` (`pfWidget` handler) | in-house local plugin `cap/native/PFWidgetPlugin.swift` |
| Widget | `PFTrackWidget/` (native WidgetKit), same for both | same |

## Files

```
ios/
  README_IOS.md
  project.yml                     # XcodeGen: PFTrack app + PFTrackWidget extension (build A)
  Shared/SharedStore.swift        # App Group (group.pftrack.shared) snapshot read/write, both targets
  PFTrack/
    Info.plist                    # Health usage strings, pftrack:// URL scheme, UILaunchScreen
    PFTrack.entitlements          # HealthKit + App Group
    AppDelegate.swift  SceneDelegate.swift
    ViewController.swift          # WKWebView host; registers pfHealth + pfWidget handlers
    WebBridge.swift               # WKScriptMessageHandler: health.* actions, writes need optIn
    HealthBridge.swift            # HealthKit: read/write workouts, sleep, body mass, water, energy
    WidgetBridge.swift            # page JSON -> App Group -> WidgetCenter reload (throttled 2 s)
  PFTrackWidget/
    PFTrackWidget.swift           # small + medium: plan, streak, verse; refresh after midnight
    Info.plist                    # com.apple.widgetkit-extension
    PFTrackWidget.entitlements    # App Group
  cap/                            # build B
    package.json                  # exact pins: @capacitor/core|ios|cli 8.5.3, capacitor-health 8.4.0
    capacitor.config.json
    native/PFWidgetPlugin.swift   # local plugin "PFWidget" (no third-party bridge)
    native/MainViewController.swift
```

## Web side (index.html, v4.76)

* `window.PFHealth` shim: native `pfHealth` bridge if injected → else `Capacitor.Plugins.Health`
  (requests only `READ_STEPS`, `READ_ACTIVE_CALORIES`, the two types it reads) → else an inert stub
  (`available:false`, every call resolves `null`). Safari and GitHub Pages never see an error.
* `pushWidgetState()` runs on every save and posts `{v,date,plan,streak,verseRef,verse,updated}` to
  `pfWidget` or `Capacitor.Plugins.PFWidget`. With neither present it does nothing.

## Bridge contract (build A)

| Action | Payload | Result |
|---|---|---|
| `health.requestAuth` | `{}` | `{ok}` |
| `health.getSummary` | `{}` | `{ok, heartRate, restingHR, hrv, sleepHours, steps, activeEnergy, waterOz, bodyMassLb, workouts[]}` |
| `health.writeWeight` | `{lb, date:"yyyy-MM-dd", optIn:true}` | `{ok}` |
| `health.writeWater` | `{oz, date, optIn:true}` | `{ok}` |
| `health.writeEnergy` | `{kcal, start:ms, end:ms, optIn:true}` | `{ok}` |
| `health.writeSleep` | `{bed:ms, wake:ms, optIn:true}` | `{ok}` |
| `health.writeWorkout` | `{start:ms, end:ms, kcal?, optIn:true}` | `{ok}` (traditional strength training) |

Any `health.write*` without `optIn:true` is refused natively (`notOptedIn`). The page only sends weight today,
and only when More → "Write weight to Apple Health" is on.

## Build A — plain WKWebView with XcodeGen

1. Mac with Xcode 16+, `brew install xcodegen`.
2. `cd ios && xcodegen generate && open PFTrack.xcodeproj`
3. Set `DEVELOPMENT_TEAM` (project.yml or Signing tab) for both targets. Change `com.pjperez.*` ids if you like.
4. Signing & Capabilities: **HealthKit** on PFTrack, **App Groups** → `group.pftrack.shared` on PFTrack *and*
   PFTrackWidget (create the group in the developer portal if Xcode asks).
5. Run on a physical iPhone (HealthKit is limited in Simulator). Add the widget: long-press Home → + → PF//TRACK.

## Build B — Capacitor (pinned)

```sh
cd ios/cap
npm ci || npm install --save-exact      # versions are exact in package.json; never @latest, never npx -y
npx cap telemetry off                   # do this first
npm run web                             # copies ../../index.html to www/
npx cap add ios                         # generates ios/cap/App (SPM)
npx cap sync ios
npx cap open ios
```
Then in Xcode:
1. Add `../../Shared/SharedStore.swift`, `native/PFWidgetPlugin.swift`, `native/MainViewController.swift` to the App
   target; in `Main.storyboard` set the root view controller class to `MainViewController`.
2. Capabilities on App: HealthKit + App Groups (`group.pftrack.shared`). Paste the two `NSHealth*UsageDescription`
   strings from `PFTrack/Info.plist` into `App/App/Info.plist`.
3. File → New → Target → Widget Extension "PFTrackWidget" (uncheck Live Activity / intents). Replace its sources
   with `../../PFTrackWidget/PFTrackWidget.swift` + `../../Shared/SharedStore.swift`, add the App Group entitlement.
4. **Before real data:** read `node_modules/capacitor-health/ios/Sources/**/*.swift` (small project, few maintainers):
   check the requested types match `READ_STEPS` + `READ_ACTIVE_CALORIES` and nothing is sent off-device.

## Updating the web build
Build A loads the live Pages build and falls back to the bundled `index.html`. Build B ships `www/index.html`;
rerun `npm run sync` after each web release.
