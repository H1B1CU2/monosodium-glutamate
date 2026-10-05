#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
snapshot_stage=$(mktemp -d /tmp/msg-music-snapshot.XXXXXX)
trap 'rm -rf "$snapshot_stage"' EXIT
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
python3 - "$root" "$snapshot_stage" <<'PY'
from pathlib import Path
import sys
root, stage = map(Path, sys.argv[1:])
source=(root/'MSG/MusicMonitor.swift').read_text()
production=source[source.index('struct AppleMusicSnapshot {'):source.index('// MARK: - MusicMonitor')]
test=(root/'Tests/AppleMusicSnapshotTests.swift').read_text()
(stage/'SnapshotTests.swift').write_text(test.replace('// PRODUCTION_APPLE_MUSIC_SNAPSHOT',production))
PY
if [[ "${1:-}" == "--typecheck" ]]; then
    xcrun swiftc "$snapshot_stage/SnapshotTests.swift" -parse-as-library -typecheck
else
    xcrun swiftc "$snapshot_stage/SnapshotTests.swift" -parse-as-library -framework AppKit -o "$snapshot_stage/tests"
    "$snapshot_stage/tests"
fi
