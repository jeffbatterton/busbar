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

## Web app

`web/` is the same dashboard for a phone: static files, no build step and no server of
its own. EcoFlow's API allows cross-origin requests, so the page signs and sends them
itself. The keys are kept in the browser's local storage on that phone.

```sh
cd web && python3 -m http.server 8790   # then open http://localhost:8790/?demo
(cd web && node --test)                  # tests for signing and parsing
swift scripts/make-web-icons.swift       # re-renders the icons and launch images
```

`?demo` runs on simulated data. On an iPhone, Share › Add to Home Screen opens it
full-screen with its own icon and launch image.

## History logger

`logger/` is a Cloudflare Worker that records the charge every minute into a D1 database,
so the apps can chart history even while the Mac is asleep or the phone app is closed. It
imports `web/ecoflow.js`, so signing and parsing are shared with the web app. It runs at
https://busbar-logger.jeffbatterton.workers.dev.

```sh
cd logger
node --test                                  # tests
npx wrangler deploy                          # deploys it
npx wrangler secret put READ_TOKEN           # what the apps send to read history
npx wrangler secret put ECOFLOW_ACCESS_KEY   # also ECOFLOW_SECRET_KEY, ECOFLOW_SERIAL_NUMBER
```

Without the EcoFlow secrets it records simulated readings; the first real one deletes them.
`GET /readings?since=<ms>[&until=<ms>]` with `Authorization: Bearer <READ_TOKEN>` answers
`{ simulated, readings: [[time ms, charge %, watts in, watts out], …] }`, at most 8 days at
a time.

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
