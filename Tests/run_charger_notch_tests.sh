#!/usr/bin/env bash
set -euo pipefail
project_root=$(cd "$(dirname "$0")/.." && pwd)
test_stage=$(mktemp -d /tmp/msg-charger-tests.XXXXXX)
trap 'rm -rf "$test_stage"' EXIT
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
xcrun swiftc "$project_root/MSG/ChargerNotchNotice.swift" "$project_root/Tests/ChargerNotchNoticeTests.swift" \
    -target arm64-apple-macos14.0 -framework AppKit -framework IOKit -o "$test_stage/checks"
"$test_stage/checks"
