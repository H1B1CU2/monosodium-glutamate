#!/usr/bin/env bash
set -euo pipefail
project_root=$(cd "$(dirname "$0")/.." && pwd)
test_stage=$(mktemp -d /tmp/msg-settings-controls.XXXXXX)
trap 'rm -rf "$test_stage"' EXIT
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
python3 - "$project_root/MSG/SettingsWindow.swift" "$test_stage/Controls.swift" <<'PY'
from pathlib import Path
import sys
source = Path(sys.argv[1]).read_text()
start = source.index('struct SettingsSegment<Value: Hashable>')
end = source.index('// MARK: - Visual Effect Blur', start)
Path(sys.argv[2]).write_text('import AppKit\nimport SwiftUI\n' + source[start:end])
PY
xcrun swiftc "$test_stage/Controls.swift" "$project_root/Tests/SettingsControlsTests.swift" \
  -target arm64-apple-macos14.0 -framework AppKit -framework SwiftUI -o "$test_stage/checks"
"$test_stage/checks"
