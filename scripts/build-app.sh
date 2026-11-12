#!/bin/bash
# Development artifact only. Production signing/notarization is a later milestone.
set -euo pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
cd "$(dirname "$0")/.."
version="${QUILL_VERSION:-0.1.0}"
build="${QUILL_BUILD_NUMBER:-1}"
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ || ! "$build" =~ ^[1-9][0-9]*$ ]]; then
    echo "QUILL_VERSION must be X.Y.Z; QUILL_BUILD_NUMBER must be a positive integer." >&2
    exit 2
fi
if [[ -L dist || ( -e dist && ! -d dist ) ]]; then
    echo "dist must be a real directory, not a symlink or file." >&2
    exit 1
fi
mkdir -p dist
for output in dist/Quill-macos-arm64-preview.zip dist/Quill-macos-arm64-preview.zip.sha256; do
    if [[ -L "$output" || ( -e "$output" && ! -f "$output" ) ]]; then
        echo "Refusing non-file output: $output" >&2
        exit 1
    fi
done
staging="$(mktemp -d "$PWD/dist/.build-app.XXXXXX")"
trap 'rm -rf "$staging"' EXIT
plist="$staging/Info.plist"
cp Sources/quill/Info.plist "$plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier io.github.enigma.quill.preview' "$plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleName Quill Preview' "$plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundleExecutable string quill' "$plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundlePackageType string APPL' "$plist"
/usr/libexec/PlistBuddy -c 'Add :LSUIElement bool true' "$plist"
/usr/libexec/PlistBuddy -c 'Add :LSMinimumSystemVersion string 15.0' "$plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $version" "$plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $build" "$plist"
swift_bin="$(xcrun --find swift)"
flags=(--force-resolved-versions)
# Safehouse already supplies the outer sandbox; nested sandbox creation is denied.
if [[ "${QUILL_DISABLE_SWIFTPM_SANDBOX:-0}" == 1 ]]; then flags+=(--disable-sandbox); fi
cp Package.resolved "$staging/Package.resolved"
QUILL_BUNDLE_PLIST="$plist" "$swift_bin" build -c release "${flags[@]}"
cmp Package.resolved "$staging/Package.resolved"
bin_dir="$(QUILL_BUNDLE_PLIST="$plist" "$swift_bin" build -c release "${flags[@]}" --show-bin-path)"
if [[ "$(lipo -archs "$bin_dir/quill")" != arm64 ]]; then
    echo "This prototype packages arm64 only." >&2
    exit 1
fi
/bin/bash scripts/assemble-app.sh "$bin_dir/quill" "$plist" "$staging/Quill.app"
cp Package.resolved "$staging/Quill.app/Contents/Resources/Package.resolved"
# Ad-hoc signing permits local execution; it is NOT Developer ID signing.
codesign --force --sign - "$staging/Quill.app"
codesign --verify --deep --strict "$staging/Quill.app"
"$staging/Quill.app/Contents/MacOS/quill" --help > /dev/null
cat > "$staging/BUILD.txt" <<REPORT
Quill development preview — not notarized; not a production release.
Version: $version ($build)
Architecture: arm64
Minimum macOS: 15.0
Source commit: $(GIT_CONFIG_GLOBAL=/dev/null git rev-parse HEAD)
Working tree changed paths: $(GIT_CONFIG_GLOBAL=/dev/null git status --porcelain | wc -l | tr -d ' ')
$("$swift_bin" --version 2>&1)
SDK: $(xcrun --show-sdk-version)
REPORT
mkdir "$staging/download"
mv "$staging/Quill.app" "$staging/BUILD.txt" "$staging/download/"
ditto -c -k --sequesterRsrc --keepParent "$staging/download" "$staging/Quill-macos-arm64-preview.zip"
# Replace only our named generated archive, never recursively remove a user path.
(cd "$staging" && shasum -a 256 Quill-macos-arm64-preview.zip > Quill-macos-arm64-preview.zip.sha256)
mv -f "$staging/Quill-macos-arm64-preview.zip" dist/Quill-macos-arm64-preview.zip
mv -f "$staging/Quill-macos-arm64-preview.zip.sha256" dist/Quill-macos-arm64-preview.zip.sha256
echo "Built dist/Quill-macos-arm64-preview.zip (ad-hoc signed, not notarized)."
