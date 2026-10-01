# PF//TRACK

Offline single-file Planet Fitness training terminal (Marathon Edition v3.0).

Open locally: open `index.html`, or serve with `python3 -m http.server 8080`.

Storage key: `pftrack_v3` · Live session: `sessionStorage` `pftrack_live` · No build step · No accounts · No cloud.

## iOS (Apple Health)

Native WKWebView + HealthKit scaffold lives in `ios/`. See `ios/README_IOS.md` — open on a Mac in Xcode, enable HealthKit, run on device. Web UI talks to the bridge when present; Safari stays manual-only.
