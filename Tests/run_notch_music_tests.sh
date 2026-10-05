#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
test_stage=$(mktemp -d /tmp/msg-music-tests.XXXXXX)
trap 'rm -rf "$test_stage"' EXIT
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
/usr/bin/python3 - "$root" "$test_stage" <<'PY'
import pathlib, sys
root, stage = map(pathlib.Path, sys.argv[1:])
source = (root / 'MSG/NotchPanes.swift').read_text()
music = source[source.index('private final class NotchMusicButton:'):source.index('// MARK: - Audio')]
hud = (root / 'MSG/NotchHUD.swift').read_text()
change = hud[hud.index('struct NotchMusicTrackChange {'):hud.index('final class NotchHUD {')]
test = (root / 'Tests/NotchMusicTests.swift').read_text()
(stage / 'MusicTests.swift').write_text(test.replace('// PRODUCTION_MUSIC_PANE', change + music))
PY
xcrun swiftc "$test_stage/MusicTests.swift" -parse-as-library \
  -target arm64-apple-macos14.0 -framework AppKit -o "$test_stage/music-tests"
"$test_stage/music-tests"
