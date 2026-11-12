#!/bin/bash
# Sourced by packaging scripts after cd to the repository root.
# Identity policy lives in Sources/quill/Info.plist; this file only applies it.
identity_value() {
    local prefix
    case "$1" in
        Local) prefix=QuillLocal ;;
        Distribution) prefix=CFBundle ;;
        *) return 1 ;;
    esac
    /usr/libexec/PlistBuddy -c "Print :${prefix}${2}" Sources/quill/Info.plist
}

write_app_plist() {
    local variant="$1" output="$2" prefix identifier name
    case "$variant" in
        local) prefix=Local ;;
        distribution) prefix=Distribution ;;
        *) echo "Unknown app variant: $variant" >&2; return 1 ;;
    esac
    identifier="${3:-$(identity_value "$prefix" Identifier)}"
    name="$(identity_value "$prefix" Name)"
    cp Sources/quill/Info.plist "$output"
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $identifier" "$output"
    /usr/libexec/PlistBuddy -c "Set :CFBundleName $name" "$output"
    /usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string $name" "$output"
    /usr/libexec/PlistBuddy -c 'Add :CFBundleExecutable string quill' "$output"
    /usr/libexec/PlistBuddy -c 'Add :CFBundlePackageType string APPL' "$output"
    /usr/libexec/PlistBuddy -c "Add :QuillVariant string $variant" "$output"
    /usr/libexec/PlistBuddy -c 'Add :LSUIElement bool true' "$output"
    /usr/libexec/PlistBuddy -c 'Add :LSMinimumSystemVersion string 15.0' "$output"
}
