#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
test_stage=$(mktemp -d /tmp/msg-notch-tests.XXXXXX)
trap 'rm -rf "$test_stage"' EXIT
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
# Compile the production card without its unrelated lock-screen controller.
/usr/bin/python3 - "$root/MSG/AgentLockScreen.swift" "$test_stage/ActivityCard.swift" <<'PY'
import pathlib, sys
source = pathlib.Path(sys.argv[1]).read_text()
card = source[source.index('final class AgentActivityCardView:'):source.index('/// Quota status has its own glass card')]
helpers = source[source.index('/// Rows lay out top-down like the card itself.'):]
pathlib.Path(sys.argv[2]).write_text('import AppKit\nimport QuartzCore\n' + card + helpers)
PY
/usr/bin/python3 - "$root/MSG/AgentNotchCard.swift" "$test_stage/NotchHost.swift" <<'PY'
import pathlib, sys
source = pathlib.Path(sys.argv[1]).read_text()
session = source[source.index('struct CortexNotchSession {'):source.index('final class AgentNotchCard {')]
host = session + source[source.index('final class NotchCardHostView:'):]
pathlib.Path(sys.argv[2]).write_text('import AppKit\nimport QuartzCore\n' + host)
PY
/usr/bin/python3 - "$root/MSG/NotchPanes.swift" "$test_stage/PageDots.swift" <<'PY'
import pathlib, sys
source = pathlib.Path(sys.argv[1]).read_text()
dots = source[source.index('final class NotchPageDots:'):source.index('// MARK: - Calendar')]
pathlib.Path(sys.argv[2]).write_text('import AppKit\nimport QuartzCore\n' + dots)
PY
/usr/bin/python3 - "$root/MSG/NotchPanes.swift" "$test_stage/CalendarView.swift" <<'PY'
import pathlib, sys
source = pathlib.Path(sys.argv[1]).read_text()
calendar = source[source.index('/// A real AppKit button accepts'):source.index('// MARK: - Clipboard history')]
pathlib.Path(sys.argv[2]).write_text('import AppKit\nimport SwiftUI\n' + calendar)
PY
/usr/bin/python3 - "$root/MSG/AgentDoneNotice.swift" "$test_stage/SessionLink.swift" <<'PY'
import pathlib, sys
source = pathlib.Path(sys.argv[1]).read_text()
pathlib.Path(sys.argv[2]).write_text('import AppKit\n' + source[source.index('struct AgentSessionLink:'):])
PY
notch_check_flags=(-o /tmp/msg-notch-usage-tests)
if [[ "${1:-}" == "--typecheck" ]]; then notch_check_flags=(-typecheck); fi
xcrun swiftc "$root/MSG/AIUsageFeed.swift" "$test_stage/ActivityCard.swift" "$test_stage/SessionLink.swift" \
  "$root/MSG/TilingDisplayClock.swift" "$root/MSG/AgentNotchDashboard.swift" \
  "$test_stage/NotchHost.swift" "$test_stage/PageDots.swift" "$test_stage/CalendarView.swift" "$root/Tests/NotchUsageTests.swift" \
  -target arm64-apple-macos13.0 -framework AppKit -framework SwiftUI \
  "${notch_check_flags[@]}"
if [[ "${1:-}" != "--typecheck" ]]; then /tmp/msg-notch-usage-tests "$@"; fi
