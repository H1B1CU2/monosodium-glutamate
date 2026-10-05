#!/usr/bin/env bash
set -euo pipefail
project_root=$(cd "$(dirname "$0")/.." && pwd)
test_stage=$(mktemp -d /tmp/msg-warp-tests.XXXXXX)
trap 'rm -rf "$test_stage"' EXIT
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
xcrun swiftc "$project_root/MSG/CloudflareWARP.swift" "$project_root/Tests/CloudflareWARPTests.swift" \
    -target arm64-apple-macos13.0 -o "$test_stage/checks"
"$test_stage/checks"
