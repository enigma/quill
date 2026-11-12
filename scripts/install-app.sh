#!/bin/bash
# Build only repository-owned files into a fresh, certificate-signed app.
set -euo pipefail
# Set this before invoking even dirname; never resolve tools from caller PATH.
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
readonly PATH
umask 077
cd "$(dirname "$0")/.."

app="${QUILL_APP_PATH:-$HOME/Applications/Quill.app}"
if [[ "$app" != /* || "$app" != *.app || -L "$app" ]]; then
    echo "QUILL_APP_PATH must be an absolute .app path, not a symlink." >&2
    exit 1
fi
installed=false
bundle_id=local.quill.app
requirement=""
if [[ -e "$app" ]]; then
    if [[ ! -d "$app" ]]; then
        echo "Install destination exists and is not an app directory." >&2
        exit 1
    fi
    installed=true
    codesign --verify --deep --strict "$app"
    # Only carry forward this validated scalar, never code, resources, or
    # arbitrary Info.plist settings from the installed bundle.
    bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")"
    if [[ ! "$bundle_id" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]]; then
        echo "Installed app has an unsupported bundle identifier." >&2
        exit 1
    fi
    signature="$(codesign -dv "$app" 2>&1)"
    if ! [[ "$signature" == *"Signature=adhoc"* ]]; then
        requirement="$(codesign -d -r- "$app" 2>&1 | sed -n 's/^designated => //p')"
        if [[ -z "$requirement" ]]; then
            echo "Cannot read the installed app's signing requirement." >&2
            exit 1
        fi
    fi
fi

if pgrep -x quill >/dev/null; then
    echo "Quit quill from its menu first, so any recording finishes cleanly." >&2
    exit 1
else
    process_status=$?
    if [[ "$process_status" != 1 ]]; then
        echo "Cannot check whether quill is running; leaving the installed app unchanged." >&2
        exit 1
    fi
fi

identity="${QUILL_SIGNING_IDENTITY-}"
if [[ ! ${QUILL_SIGNING_IDENTITY+x} ]]; then
    # Local self-signed identities need not be trusted roots. Do not use -v,
    # which would filter out these usable but untrusted identities.
    identities="$(security find-identity -p codesigning)"
    for name in QuillLocalDev 'Quill Development'; do
        matches="$(printf '%s\n' "$identities" | awk -F '"' -v name="$name" '
            $2 == name { split($1, fields, " "); print fields[2] }
        ' | sort -u)"
        if [[ -n "$matches" ]]; then
            if [[ "$matches" == *$'\n'* ]]; then
                echo "Multiple keys named $name; set QUILL_SIGNING_IDENTITY to the desired fingerprint." >&2
                exit 1
            fi
            identity="$matches"
            echo "Reusing $name ($identity)."
            break
        fi
    done
    if [[ -z "$identity" && "$installed" == true ]]; then
        echo "No Quill key found. Set QUILL_SIGNING_IDENTITY to the existing signing identity; a replacement key will not be created for an installed app." >&2
        exit 1
    fi
elif [[ "$identity" == "-" || -z "$identity" ]]; then
    echo "Use a code-signing certificate, not an ad-hoc signature (-)." >&2
    exit 1
fi

swift_bin="$(/usr/bin/xcrun --find swift)"
if [[ "$swift_bin" != /* || ! -x "$swift_bin" ]]; then
    echo "xcrun did not resolve an executable Swift compiler at an absolute path." >&2
    exit 1
fi
"$swift_bin" build -c release
bin_dir="$("$swift_bin" build -c release --show-bin-path)"
parent="$(dirname "$app")"
mkdir -p "$parent"
staging="$(mktemp -d "$parent/.quill-install.XXXXXX")"
cleanup() {
    # Remove temporary private-key material even if a backup must be retained.
    rm -rf "$staging/signing"
    if [[ -d "$staging/Previous.app" ]]; then
        echo "Previous app retained at $staging/Previous.app" >&2
    else
        rm -rf "$staging"
    fi
}
trap cleanup EXIT
staged_app="$staging/Quill.app"

if [[ -z "$identity" ]]; then
    # First install only. Retain the key in the user's default Keychain;
    # private files exist only in a mode-700 staging directory during import.
    mkdir "$staging/signing"
    cat > "$staging/signing/openssl.cnf" <<'CONFIG'
[req]
distinguished_name = subject
x509_extensions = signing
prompt = no
[subject]
CN = QuillLocalDev
[signing]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CONFIG
    openssl req -new -newkey rsa:2048 -nodes -x509 -sha256 -days 3650 \
        -config "$staging/signing/openssl.cnf" \
        -keyout "$staging/signing/key.pem" -out "$staging/signing/cert.pem" 2>"$staging/signing/generate.log" || {
        cat "$staging/signing/generate.log" >&2
        exit 1
    }
    openssl pkcs12 -export -name QuillLocalDev \
        -inkey "$staging/signing/key.pem" -in "$staging/signing/cert.pem" \
        -out "$staging/signing/identity.p12" -passout pass:
    keychain="$(security default-keychain -d user | sed 's/^[[:space:]]*"//; s/"[[:space:]]*$//')"
    security import "$staging/signing/identity.p12" -k "$keychain" -P '' -T /usr/bin/codesign
    identity="$(openssl x509 -in "$staging/signing/cert.pem" -noout -fingerprint -sha1 | cut -d= -f2 | tr -d ':')"
    rm -rf "$staging/signing"
    echo "Created QuillLocalDev in your Keychain; future builds will reuse it."
fi

mkdir -p "$staged_app/Contents/MacOS"
cp Sources/quill/Info.plist "$staged_app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $bundle_id" "$staged_app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundleExecutable string quill' "$staged_app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundlePackageType string APPL' "$staged_app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :LSUIElement bool true' "$staged_app/Contents/Info.plist"
cp "$bin_dir/quill" "$staged_app/Contents/MacOS/quill"
codesign --force --sign "$identity" --timestamp=none "$staged_app"
codesign --verify --deep --strict --verbose=2 "$staged_app"
if [[ -n "$requirement" ]]; then
    # The leading = marks inline requirement text; otherwise codesign opens a file.
    codesign --verify -R "=$requirement" "$staged_app"
fi

# Abort if another install appeared during the build instead of overwriting it.
if [[ "$installed" == false && ( -e "$app" || -L "$app" ) ]]; then
    echo "An app appeared at the destination during the build; leaving it unchanged." >&2
    exit 1
fi
if [[ "$installed" == true ]]; then
    mv "$app" "$staging/Previous.app"
fi
if ! mv "$staged_app" "$app"; then
    if [[ -d "$staging/Previous.app" ]]; then
        mv "$staging/Previous.app" "$app"
    fi
    exit 1
fi
rm -rf "$staging/Previous.app"
open "$app"
echo "Installed and opened $app (signed with $identity)."
