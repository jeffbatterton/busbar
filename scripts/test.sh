#!/bin/zsh
# Runs the test suite. With only the Command Line Tools installed (no Xcode),
# Swift Testing lives outside the default search paths, so point at it.
set -euo pipefail
cd "$(dirname "$0")/.."

CLT=/Library/Developer/CommandLineTools/Library/Developer
if [[ -d "$CLT/Frameworks/Testing.framework" ]] && ! xcode-select -p | grep -q Xcode.app; then
  swift test -Xswiftc -F"$CLT/Frameworks" \
    -Xlinker -rpath -Xlinker "$CLT/Frameworks" -Xlinker -rpath -Xlinker "$CLT/usr/lib" "$@"
else
  swift test "$@"
fi
