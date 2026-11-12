#!/bin/bash
# Run either app with explicit test data, without editing its signed bundle.
set -euo pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
if [[ $# -lt 2 || $# -gt 3 || ( $# == 3 && "$3" != --check ) ]]; then
    echo 'Usage: run-isolated.sh /absolute/Quill.app /absolute/test-directory [--check]' >&2
    exit 2
fi
app="$1"
root="$2"
if [[ "$app" != /* || "$app" != *.app || ! -x "$app/Contents/MacOS/quill" || "$root" != /* ]]; then
    echo 'Supply an existing app and an absolute test-directory path.' >&2
    exit 2
fi
if [[ -L "$root/recordings" ]]; then
    echo 'Test recordings directory must not be a symlink.' >&2
    exit 1
fi
mkdir -p "$root/recordings"
root="$(cd "$root" && pwd -P)"
config="$root/config.json"
if [[ ! -e "$config" && ! -L "$config" ]]; then
    (set -o noclobber; printf '{}\n' > "$config")
fi
if [[ ! -f "$config" || -L "$config" ]]; then
    echo 'Test config must be a regular file, not a symlink.' >&2
    exit 1
fi
export QUILL_CONFIG_PATH="$config"
export QUILL_RECORDINGS_DIR="$root/recordings"
echo "Config: $QUILL_CONFIG_PATH"
echo "Recordings: $QUILL_RECORDINGS_DIR"
if [[ "${3:-}" == --check ]]; then
    exec "$app/Contents/MacOS/quill" doctor --paths-only
fi
# LaunchServices gives capture permissions the same app context as Finder.
# A new instance is required for these environment overrides to take effect.
echo 'Opening Quill as an app; quit it through its menu when finished.'
exec /usr/bin/open -n -a "$app" \
    --env "QUILL_CONFIG_PATH=$QUILL_CONFIG_PATH" \
    --env "QUILL_RECORDINGS_DIR=$QUILL_RECORDINGS_DIR" \
    --args run
