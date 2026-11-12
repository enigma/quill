#!/bin/bash
# Standalone Foundation tests: works with Command Line Tools, no XCTest needed.
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/quill-capture-tests.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT
swiftc -swift-version 6 \
    Sources/quill/Audio/CaptureActivity.swift \
    Tests/QuillTests/CaptureActivityTests.swift \
    -o "$test_dir/capture-tests"
"$test_dir/capture-tests"
