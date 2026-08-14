# msg-inputd

The Fedora half of MSG's cross-machine mouse and keyboard. When MSG hands the
shared monitor over to this machine, the Mac streams pointer and key events
here and this daemon replays them through virtual kernel input devices.

## Install (on the Fedora machine)

Copy this directory over, then:

```bash
sudo ./install.sh
```

It installs the daemon, loads the `uinput` module (and makes that persist across
reboots), generates a token, installs and starts the systemd unit, and opens the
port in firewalld. At the end it prints the host, port and token to enter on the
Mac.

## Verify before touching the Mac

```bash
sudo ./testclient.py
```

The cursor should walk a square and settle in the middle, then scroll. If that
works, the entire Fedora side is proven: uinput device, absolute positioning,
protocol, authentication and firewall. Add `--keys` to also test typing (it goes
into whatever window has focus).

```bash
journalctl -u msg-inputd -f      # watch it live
```

## Design notes

**Why uinput.** Fedora defaults to Wayland, where no client may synthesise input
for another — XTEST is X11-only and dead here. uinput sits below the display
server and creates a real kernel input device, so the compositor cannot tell
these events from a physical mouse. Works the same on X11.

**Why absolute positioning.** Both machines drive the same physical panel. A
pointer leaving the Mac 40% of the way down the shared edge has to arrive 40%
down the same edge, or the handover feels wrong. The Mac sends normalised
0.0–1.0 coordinates, scaled here to the device's 0–32767 logical range, which
the compositor maps to the full screen — so the daemon never needs to know
Fedora's resolution. `--relative` is the fallback if a compositor mishandles
absolute pointers; it costs the exact entry position.

**Release-on-disconnect is the critical safety property.** If the Mac vanishes
mid-keystroke — network drop, lid closed, crash — a held Ctrl or mouse button
would stay down from the kernel's point of view with no way to clear it. Every
disconnect path, plus a 15-second silence timeout, releases everything held.

**Security.** This service can type anything into your session, so treat the
token like a password: it lives in `/etc/msg-inputd/token` at mode 0600 and the
daemon warns if that's loosened. One client at a time; a second is refused
rather than queued. The systemd unit drops every capability and filesystem
privilege it can while keeping the `/dev/uinput` access it can't do without.
It listens on all interfaces by default — pass `--bind` to narrow that if the
machine is on an untrusted network.

## Protocol

Newline-delimited JSON over TCP, port 47654. Chosen over a binary format
because it is debuggable with `nc` and the event rate (~120/s, coalesced on the
Mac) is nowhere near enough for parsing cost to matter.

Client → daemon:

| Message | Meaning |
|---|---|
| `{"t":"hello","v":1,"token":"…"}` | Must be first. Replies `{"t":"welcome","v":1,"mode":"absolute"}` |
| `{"t":"enter","x":0.4,"y":0.2}` | Pointer arrives at a normalised position |
| `{"t":"motion","x":…,"y":…}` | Pointer moves |
| `{"t":"leave"}` | Control returns to the Mac; releases everything held |
| `{"t":"button","b":"left\|right\|middle","s":1\|0}` | Button down/up |
| `{"t":"scroll","dx":0,"dy":1}` | Wheel clicks |
| `{"t":"key","c":30,"s":1}` | Linux keycode down/up (`KEY_A` = 30) |
| `{"t":"ping"}` | Replies `{"t":"pong"}` |

The Mac sends Linux keycodes directly — the macOS→Linux keycode translation
lives on the Mac side, so this daemon stays a dumb, auditable replayer.

Any protocol error drops the connection and releases all held input.
