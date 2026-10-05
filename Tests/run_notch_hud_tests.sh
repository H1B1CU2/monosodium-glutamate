#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
test_stage=$(mktemp -d /tmp/msg-hud-tests.XXXXXX)
trap 'rm -rf "$test_stage"' EXIT
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
/usr/bin/python3 - "$root" "$test_stage" <<'PY'
import pathlib, sys
root, stage = map(pathlib.Path, sys.argv[1:])
source = (root / 'MSG/NotchHUD.swift').read_text()
helpers = source[source.index('struct NotchMusicTrackChange {'):source.index('enum CortexWing {')]
controller = source[source.index('final class NotchHUD {'):source.index('// MARK: - Keyboard input sources')]
power = (root / 'MSG/ChargerNotchNotice.swift').read_text()
power_state = power[power.index('struct ChargerPowerState:'):power.index('/// An event-driven power listener')]
events = (root / 'MSG/SystemEventNotchNotice.swift').read_text().split('/// Read-only event monitoring:')[0].replace('import AppKit', '')
notifications = (root / 'MSG/SystemNotificationNotch.swift').read_text()
notification_models = notifications[notifications.index('struct NotchNotificationApp:'):notifications.index('/// AX calls run')]
test = (root / 'Tests/NotchHUDControllerTests.swift').read_text()
(stage / 'HUDTests.swift').write_text(test.replace('// PRODUCTION_NOTCH_HUD_CONTROLLER', power_state + events + notification_models + helpers + controller))
PY
hud_check_flags=(-o "$test_stage/hud-tests")
if [[ "${1:-}" == "--typecheck" ]]; then hud_check_flags=(-typecheck); fi
xcrun swiftc "$test_stage/HUDTests.swift" -parse-as-library \
  -target arm64-apple-macos14.0 -framework AppKit -framework Carbon -framework AudioToolbox -framework IOKit \
  "${hud_check_flags[@]}"
if [[ "${1:-}" != "--typecheck" ]]; then "$test_stage/hud-tests"; fi
