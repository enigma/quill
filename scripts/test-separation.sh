#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/quill-separation-tests.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT
swiftc -swift-version 6 Sources/quill/Config.swift Sources/quill/RecordingRootLock.swift \
    Tests/QuillTests/SeparationTests.swift -o "$test_dir/separation-tests"
printf '{"transcription":{"enabled":false},"recordings_dir":"/must-not-be-used"}\n' > "$test_dir/config.json"
QUILL_CONFIG_PATH="$test_dir/config.json" QUILL_RECORDINGS_DIR="$test_dir/recordings" \
    "$test_dir/separation-tests" "$test_dir"
