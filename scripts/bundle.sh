#!/bin/zsh
# Builds Busbar and wraps the executable in build/Busbar.app.
#   scripts/bundle.sh            release build into build/
#   scripts/bundle.sh --install  also copy to /Applications and relaunch
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
APP="build/Busbar.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$(swift build -c release --show-bin-path)/Busbar" "$APP/Contents/MacOS/Busbar"
cp Resources/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP" >/dev/null
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
  pkill -x Busbar || true
  rm -rf /Applications/Busbar.app
  cp -R "$APP" /Applications/
  open /Applications/Busbar.app
  echo "Installed to /Applications/Busbar.app"
fi
