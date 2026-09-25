# Vorssaint attribution

Switcher event-tap architecture, search filtering, input sanitization, and search chip adapted from Vorssaint v3.3.2, commit fc302b67b509bf20fdb10132d8df2c23fb492ece.
https://github.com/vorssaintapp/vorssaint-utils

Copyright (C) 2026 Vorssaint. SPDX-License-Identifier: GPL-3.0-or-later.
See LICENSE in this directory. Modified for MSG: fixed Cmd-Tab shortcut, two layouts, asynchronous input routing, existing MSG capture/activation and thumbnail components. Adapted code is in MSG/AppSwitcherPreview.swift.

Native symbolic hotkey takeover, crash recovery transitions, and runtime symbol resolution also adapted from Vorssaint commit ac98c8963d3b7ab010fc8c0d50bd3cc45d4f43e6 (Core/SymbolicHotKeys.swift, Services/SystemShortcutTakeover.swift, Services/SystemShortcutTakeoverSupport.swift). MSG limits ownership to Cmd-Tab and Cmd-Shift-Tab and uses its own recovery marker.
