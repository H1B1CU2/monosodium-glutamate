#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
notification_test_stage=$(mktemp -d /tmp/msg-notification-tests.XXXXXX)
trap 'rm -rf "$notification_test_stage"' EXIT
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
python3 - "$root" "$notification_test_stage" <<'PY'
import pathlib, sys
root, stage = map(pathlib.Path, sys.argv[1:])
source = (root / 'MSG/SystemNotificationNotch.swift').read_text()
models = source[source.index('struct NotchNotificationApp:'):source.index('/// AX calls run')]
test = (root / 'Tests/SystemNotificationNotchTests.swift').read_text()
(stage / 'main.swift').write_text(test.replace('// PRODUCTION_NOTIFICATION_MODELS', models))
PY
xcrun swiftc "$notification_test_stage/main.swift" -parse-as-library -framework AppKit -o "$notification_test_stage/tests"
"$notification_test_stage/tests"
