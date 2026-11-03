#!/bin/zsh
# Builds Busbar and wraps the executable in build/Busbar.app.
#   scripts/bundle.sh            release build into build/
#   scripts/bundle.sh --install  also copy to /Applications and relaunch
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
APP="build/Busbar.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release --show-bin-path)/Busbar" "$APP/Contents/MacOS/Busbar"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# Sign with a real certificate when there is one: the Keychain trusts an app by its
# signature, and an ad-hoc one changes every build, so each build would have to be
# allowed to read the keys again.
IDENTITY="${BUSBAR_SIGN_IDENTITY:-$(security find-identity -v -p codesigning \
  | awk -F'"' '/Apple Development|Developer ID Application/ { print $2; exit }')}"
codesign --force --sign "${IDENTITY:--}" "$APP" >/dev/null
echo "Built $APP${IDENTITY:+ (signed by $IDENTITY)}"

if [[ "${1:-}" == "--install" ]]; then
  pkill -x Busbar || true
  # Opening it while the old copy is still quitting fails with error -600.
  while pgrep -x Busbar >/dev/null; do sleep 0.2; done
  rm -rf /Applications/Busbar.app
  cp -R "$APP" /Applications/
  open /Applications/Busbar.app
  echo "Installed to /Applications/Busbar.app"
fi
