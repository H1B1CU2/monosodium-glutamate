#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
test_stage=$(mktemp -d /tmp/msg-tab-group-tests.XXXXXX)
trap 'rm -rf "$test_stage"' EXIT
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
/usr/bin/python3 - "$root" "$test_stage" <<'PY'
import pathlib, sys
root, stage = map(pathlib.Path, sys.argv[1:])
controller = (root / 'MSG/TilingController.swift').read_text()
types = controller[controller.index('struct TilingBarWindow {'):controller.index('/// Automatic tiling')]
bar = (root / 'MSG/TilingControlBar.swift').read_text()
group_type = bar[bar.index('struct TilingTabGroup {'):bar.index('final class TilingControlBarController')]
method = bar[bar.index('    func tabGroup('):bar.index('    /// Brings a tab forward')]
test = (root / 'Tests/TilingTabGroupTests.swift').read_text()
(stage / 'Tests.swift').write_text(test.replace('// PRODUCTION_TAB_TYPES', types + group_type)
                                     .replace('// PRODUCTION_TAB_GROUP', method))
PY
xcrun swiftc "$test_stage/Tests.swift" -parse-as-library -framework AppKit -o "$test_stage/tests"
"$test_stage/tests"
