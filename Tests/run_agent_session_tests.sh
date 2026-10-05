#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
test_stage=$(mktemp -d /tmp/msg-agent-session-tests.XXXXXX)
trap 'rm -rf "$test_stage"' EXIT
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}"
tokenbar="$root/../TokenBar"
xcrun swiftc -parse-as-library "$tokenbar/Tests/SessionDestinationTests.swift" \
    "$tokenbar/TokenBar/ProcessingSleepMonitor.swift" "$tokenbar/TokenBar/AgentHooks.swift" \
    "$tokenbar/TokenBar/ThreadOpener.swift" -o "$test_stage/tokenbar-tests"
"$test_stage/tokenbar-tests" "$test_stage/snapshot.json"
cat "$root/MSG/AgentDoneNotice.swift" "$root/Tests/AgentSessionLinkTests.swift" > "$test_stage/NoticeTests.swift"
xcrun swiftc -parse-as-library "$root/MSG/AIUsageFeed.swift" "$test_stage/NoticeTests.swift" \
    -o "$test_stage/msg-tests"
"$test_stage/msg-tests" "$test_stage/snapshot.json"
