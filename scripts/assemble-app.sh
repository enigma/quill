#!/bin/bash
# Assemble only explicit inputs; no signing, installation, or app launch.
set -euo pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
if [[ $# != 3 ]]; then
    echo "Usage: assemble-app.sh BINARY INFO_PLIST NEW_APP_PATH" >&2
    exit 2
fi
binary="$1"
plist="$2"
app="$3"
cd "$(dirname "$0")/.."
if [[ "$app" != /* || "$app" != *.app || -e "$app" || -L "$app" ]]; then
    echo "App output must be a new absolute .app path." >&2
    exit 1
fi
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/Licenses"
cp "$binary" "$app/Contents/MacOS/quill"
chmod 755 "$app/Contents/MacOS/quill"
cp "$plist" "$app/Contents/Info.plist"
cp LICENSE "$app/Contents/Resources/Licenses/Quill.txt"
cp .build/checkouts/FluidAudio/LICENSE "$app/Contents/Resources/Licenses/FluidAudio.txt"
cp .build/checkouts/swift-argument-parser/LICENSE.txt "$app/Contents/Resources/Licenses/ArgumentParser.txt"
