# Busbar

A macOS menu bar app that monitors the bus's EcoFlow Delta Pro (plus extra battery and
alternator charger) through EcoFlow's IoT Open Platform API.

## Build & run

Only the Xcode Command Line Tools are needed.

```sh
scripts/bundle.sh             # builds build/Busbar.app
scripts/bundle.sh --install   # also installs to /Applications and launches it
scripts/test.sh               # runs the tests
```

Until EcoFlow developer access is approved, the app runs on simulated data using the
real Delta Pro field names. Once you have keys, open Settings from the dropdown, enter the
access key and secret key, click **Test connection** to pick the Delta Pro from your device
list, and turn off **Use simulated data**.

## Layout

- `Sources/BusbarCore`: UI-free logic (EcoFlow signing and client, quota parsing, alert
  rules). Kept separate so a future iOS app or history logger can reuse it.
- `Sources/Busbar`: the menu bar app (SwiftUI `MenuBarExtra`, settings, notifications).

## Notes

- EcoFlow's Delta Pro docs: https://developer.ecoflow.com/us/document/PP?id=2058836526572933122
- The 800W Alternator Charger isn't in EcoFlow's API docs. Its output shows up as
  "Alternator / DC": Delta Pro input not accounted for by solar or AC.
- `bmsSlave1.*` (extra battery %) is undocumented; if it's missing, the extra battery
  shows as "Connected".
