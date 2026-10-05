#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
tray_test_stage=$(mktemp -d /tmp/msg-tray-tests.XXXXXX)
trap 'rm -rf "$tray_test_stage"' EXIT
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
python3 - "$root" "$tray_test_stage" <<'PY'
from pathlib import Path
import sys
root, stage=map(Path,sys.argv[1:])
source=(root/'MSG/NotchDropZone.swift').read_text()
pane=source[source.index('final class NotchTrayPane:'):source.index('// MARK: - Tile')]
test=(root/'Tests/NotchTrayAnimationTests.swift').read_text()
(stage/'TrayTests.swift').write_text(test.replace('// PRODUCTION_TRAY_PANE',pane))
PY
if [[ "${1:-}" == "--typecheck" ]]; then
    xcrun swiftc "$tray_test_stage/TrayTests.swift" -parse-as-library -typecheck
else
    xcrun swiftc "$tray_test_stage/TrayTests.swift" -parse-as-library -framework AppKit -o "$tray_test_stage/tests"
    "$tray_test_stage/tests"
fi
