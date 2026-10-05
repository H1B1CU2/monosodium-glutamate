"""Guard the modifier-release ordering in both Edge Keys event paths."""

from pathlib import Path


source = (Path(__file__).resolve().parents[1] / "MSG" / "EdgeKeyStrip.swift").read_text()
aux = source.split("func auxKeyOverride(", 1)[1].split("// MARK: Media sources", 1)[0]
keyboard = source.split("private func handleKey(", 1)[1].split("// MARK: Levels and playback", 1)[0]

assert aux.index("isTrigger(key)") < aux.index("takenAuxCodes[code] = EdgeKeyAction.none")
assert aux.index("isTrigger(key)") < aux.index("if !isDown")
assert keyboard.index("Self.keyCodes[code], isTrigger(key)") < keyboard.index("takenKeyCodes.removeValue")
assert keyboard.index("Self.keyCodes[code], isTrigger(key)") < keyboard.index("takenKeyCodes[code] = EdgeKeyAction.none")

print("Edge Keys modifier release ordering: PASS")
