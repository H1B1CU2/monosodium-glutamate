#!/usr/bin/env bash
set -euo pipefail
project_root=$(cd "$(dirname "$0")/.." && pwd)
test_stage=$(mktemp -d /tmp/msg-system-event-tests.XXXXXX)
trap 'rm -rf "$test_stage"' EXIT
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
xcrun swiftc "$project_root/MSG/SystemEventNotchNotice.swift" "$project_root/MSG/CloudflareWARP.swift" \
    "$project_root/Tests/SystemEventNotchNoticeTests.swift" \
    -target arm64-apple-macos14.0 -framework AppKit -o "$test_stage/checks"
"$test_stage/checks"
