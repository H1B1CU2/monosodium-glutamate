# DDC on the MSI MP341CQ — diagnosis and design

MSG drives the external monitor over DDC/CI: speaker volume from the volume
keys, backlight that follows the MacBook's brightness, and input switching.
Getting there meant finding out why DDC to this particular monitor "worked,
then stopped" — for MSG and, before that, for MonitorControl. This is the
record of that diagnosis (2026-09-30) and the rules it produced. Read it
before touching `DisplayInput.swift`, `BrightnessSync.swift` or the DDC paths
in `SystemHUDMonitor.swift`.

---

## Setup

| | |
|---|---|
| Mac | MacBook Pro, M5 Pro (Apple silicon — DDC goes through the DCP) |
| Monitor | MSI PRO MP341CQ — 34" VA, 3440×1440 @100 Hz, 2× HDMI 2.0b + 1× DP 1.2a, 2 W speakers, no USB |
| Link | USB-C → HDMI adapter with USB-C PD pass-through, into the monitor's HDMI |
| Audio | CoreAudio device "MSI MP341CQ", transport `hdmi`, **no volume control** (why macOS greys out the volume keys for it) |

## How DDC works here

Apple publishes no I2C API on Apple silicon. The private `IOAVService` family in
IOKit.framework is the only route, resolved at runtime with `dlsym`:

- Services: IORegistry class `DCPAVServiceProxy`, `Location` = `External`
  (the built-in panel has one too, `Embedded`, with no DDC behind it).
- `IOAVServiceCreateWithService`, `IOAVServiceCopyEDID` (served from the link
  cache — no I2C), `IOAVServiceWriteI2C`, `IOAVServiceReadI2C`.
- DDC/CI: chip address `0x37` (0x6E >> 1), sub-address `0x51`, checksum seeded
  with `0x6E ^ 0x51`, ≥ 40 ms before a reply and ≥ 50 ms between messages
  (MSG uses 60 ms for both).

What the MP341CQ answers:

| VCP | Meaning | MP341CQ |
|---|---|---|
| `0x10` | Brightness | 0–100 |
| `0x62` | Speaker volume | 0–100 |
| `0x8D` | Mute | **unsupported** (result code 1) — MSG mutes by writing 0 and remembering the level |
| `0x60` | Input select | writes work; reads return `0xFF` forever |
| `0xF3` | Capability string | readable, but dozens of 40-byte reads — see below |

## Symptoms

- MonitorControl never worked reliably; DDC "worked for a while, then stopped".
- Once stopped, nothing DDC answered again until something was replugged or
  the Mac rebooted.

## Diagnosis

1. **A read-only probe hung in the kernel.** A standalone Swift probe (the same
   IOAVService calls, reading `0x10`, `0x62`, `0x8D`) never returned. `sample`
   showed it parked in `IOAVServiceWriteI2C → IOConnectCallMethod →
   mach_msg2_trap`. Not an error — a call that does not come back. Killing the
   process was the only way out. Kernel logs had nothing on I2C, AUX or DCP.

2. **A monitor power cycle once brought reads back** (brightness 100/100,
   volume 100/100, mute unsupported — all on the first try). The first *write*
   (`0x62` = 30) then returned `0xE0114101` (the monitor NACKing at 0x37) and the
   read after it hung again.

3. **The next monitor power cycle didn't help** — reads still hung. What
   wedges is the adapter, which is powered from the Mac, not the monitor.
   **Unplugging the adapter from the Mac** cleared it every time; the PD cable
   can stay plugged into the adapter.

4. **Everything worked with MSG quit.** Adapter replugged, MSG not running:
   reads, then `0x62` = 30 and back to 100 with read-back, all first try.
   With MSG running, a second probe hung within seconds, and a stale reply
   showed up (asking for volume returned the brightness reply) — two clients
   interleaving on one link.

5. **MSG alone wedged it too.** With no other client, `sample MSG` showed the
   `H1D3S1GN.MSG.displayinput` queue stuck in `DisplayInputEngine.refresh →
   getVCP → IOAVServiceWriteI2C`. The old `refresh()` did a full probe
   (brightness, input select, the whole capability string) at launch and 2.5 s
   after *every* screen-parameter change. `~/Library/Logs/MSG/displays.log`
   showed why that was the worst possible moment: after a plug, MSG's own
   "wake up a newly plugged display" disables and re-enables the display about
   two seconds later, so the rescan landed while the link was renegotiating.

6. **Ruled out:** the monitor's OSD (DDC/CI is on by default and reads work, so
   it is on; HDMI CEC is off), and firmware — MSI publishes none for the
   MP341CQ (its support page lists only a monitor driver and Display Kit, and
   the monitor has no USB port to flash from).

### Root cause

This monitor behind this adapter wedges under **bursts or overlaps of I2C**:
a burst of transactions (a capability-string read), two clients interleaving,
or traffic while the link is still coming up. A wedged transaction blocks in
the kernel until the adapter loses power. MonitorControl failed the same way:
it was running alongside MSG's scans.

## What MSG does now

`DisplayInput.swift`:

- **Discovery without DDC.** `refresh()` — launch and every display change —
  lists panels from the IORegistry and their EDID (link cache, no I2C) and
  takes each panel's inputs from a catalog persisted in
  `displayInput.lastKnown`. Only a panel never seen before gets a one-time
  probe. A full re-probe happens only from **Settings → Displays → Rescan**.
- **One road for every transaction: `runDDC`.** A single serial queue, so
  nothing in MSG overlaps. It waits out a **6-second settle window** after any
  display reconfiguration, plug or wake (`noteDisplayChange()`, called from
  AppDelegate's screen-parameter, reconfiguration-callback and wake observers).
- **Stall detection.** A transaction running longer than 3 s marks the link
  stalled (`isStalled`); new work is refused instead of queuing behind a call
  that won't return, and the HUD shows a dimmed bar.
- **Quit drains.** `drainBeforeExit()` gives an in-flight transaction up to
  1.5 s to finish rather than dying mid-transaction.
- **Writes coalesce.** Held keys fire faster than DDC takes writes; each write
  sends whatever level is latest. Levels are fractions of the panel's own
  reported maximum.
- `DisplayLog` records `ddc:` lines for probes and any transaction slower than
  2 s.

The only routine DDC is now:

| Feature | VCP | Rate |
|---|---|---|
| Volume keys (HDMI/DP audio) | `0x62` | per key press, coalesced. The bar is an audio taper (30 dB over 16 steps): panel values 100, 81, 65, 52, 42, 34, 27, 22, 18, 14, 12, 9, 7, 6, 5, 4, 0 — the panel's own scale is linear gain, where the whole top half is ~6 dB |
| Brightness follows the MacBook (incl. auto-brightness) | `0x10` | only on a change of ≥ 3 units, at most once a second (`BrightnessSync.swift`, fed by DisplayServices brightness notifications — nothing polls) |
| Lid closed: brightness keys | `0x10` | per key press |
| Input switching | `0x60` | per switch |

## If it wedges again

- **Symptom:** volume or brightness keys do nothing on the MSI; the HUD shows a
  dimmed bar.
- **Check:** `sample $(pgrep -x MSG) 1 | grep -A10 displayinput` — a stack
  ending in `IOAVServiceWriteI2C` / `IOAVServiceReadI2C` means the link is
  wedged.
- **Fix:** unplug the USB-C adapter from the Mac and plug it back in (the PD
  cable can stay). Turning the monitor off and on usually doesn't help.

## Rules

- Never poll DDC, and never rescan automatically.
- Every I2C transaction goes through `runDDC`.
- Never run another DDC client — MonitorControl, BetterDisplay, Lunar, a test
  probe — while MSG is running. Test DDC tools with MSG quit and the adapter
  freshly replugged.
- Keep capability-string reads out of routine paths.
- A direct HDMI port on the Mac, or a USB-C → DisplayPort cable into the
  monitor's DP input, would likely be a sturdier link. Untested.
