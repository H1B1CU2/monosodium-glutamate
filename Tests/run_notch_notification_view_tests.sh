#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
stage=$(mktemp -d /tmp/msg-notification-view-tests.XXXXXX)
trap 'rm -rf "$stage"' EXIT
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
python3 - "$root" "$stage" <<'PY'
import pathlib, sys
root, stage = map(pathlib.Path, sys.argv[1:])
models = (root / 'MSG/SystemNotificationNotch.swift').read_text()
models = models[models.index('struct NotchNotificationApp:'):models.index('/// AX calls run')]
view = (root / 'MSG/NotchHUD.swift').read_text()
view = view[view.index('private final class NotchNotificationDocumentView:'):view.index('// MARK: - Level bar')]
test = (root / 'Tests/NotchNotificationViewTests.swift').read_text()
(stage / 'main.swift').write_text(test.replace('// PRODUCTION_NOTIFICATION_MODELS', models).replace('// PRODUCTION_NOTIFICATION_VIEW', view))
PY
xcrun swiftc "$stage/main.swift" -parse-as-library -target arm64-apple-macos14.0 -framework AppKit -o "$stage/tests"
"$stage/tests"
