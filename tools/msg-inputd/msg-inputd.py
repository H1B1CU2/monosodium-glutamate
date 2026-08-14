#!/usr/bin/env python3
"""
msg-inputd — injects mouse and keyboard events sent by MSG on the Mac.

Runs on the Fedora machine that shares the monitor. When MSG hands the panel
over, the Mac starts streaming pointer and key events here and this daemon
replays them through a pair of virtual input devices.

Why /dev/uinput and not XTEST: Fedora defaults to Wayland, where no client may
synthesise input for another. uinput sits below the display server — it creates
a real kernel input device — so the compositor treats these events exactly like
a physical mouse and keyboard. Works identically on X11 and Wayland.

Deliberately dependency-free (no python-evdev): stock python3 only, so this
keeps working after a distro upgrade without anyone remembering to reinstall a
pip package.

Pointer positioning is *absolute*, not relative. The monitor is one physical
panel that both machines drive, so a pointer leaving the Mac at 40% down the
shared edge must arrive 40% down the same edge here. Absolute coordinates are
the only way to preserve that; the Mac sends 0.0-1.0 normalised positions and
they are scaled to the device's 0-32767 logical range, which the compositor
maps onto the whole screen. No knowledge of Fedora's resolution is needed.

Usage:
    sudo msg-inputd.py [--port 47654] [--bind 0.0.0.0]
                       [--token-file /etc/msg-inputd/token] [--relative]

Root is required for /dev/uinput. See install.sh for the systemd unit.
"""

import argparse
import errno
import fcntl
import json
import os
import selectors
import signal
import socket
import struct
import sys
import time

# ---------------------------------------------------------------------------
# Linux input / uinput constants
#
# Straight from <linux/input-event-codes.h> and <linux/uinput.h>. Hardcoded
# rather than parsed from the headers so the daemon needs no build step and no
# kernel-headers package.
# ---------------------------------------------------------------------------

EV_SYN, EV_KEY, EV_REL, EV_ABS = 0x00, 0x01, 0x02, 0x03
SYN_REPORT = 0x00
REL_X, REL_Y, REL_HWHEEL, REL_WHEEL = 0x00, 0x01, 0x06, 0x08
ABS_X, ABS_Y = 0x00, 0x01
BTN_LEFT, BTN_RIGHT, BTN_MIDDLE = 0x110, 0x111, 0x112
INPUT_PROP_POINTER = 0x00

# _IOC(dir, type, nr, size) = (dir << 30) | (size << 16) | (type << 8) | nr
# with _IOC_WRITE = 1 and the uinput ioctl type being 'U' (0x55).
UI_DEV_CREATE = 0x5501
UI_DEV_DESTROY = 0x5502
UI_DEV_SETUP = 0x405C5503      # _IOW('U', 3, struct uinput_setup)   — 92 bytes
UI_ABS_SETUP = 0x401C5504      # _IOW('U', 4, struct uinput_abs_setup) — 28 bytes
UI_SET_EVBIT = 0x40045564      # _IOW('U', 100, int)
UI_SET_KEYBIT = 0x40045565     # _IOW('U', 101, int)
UI_SET_RELBIT = 0x40045566     # _IOW('U', 102, int)
UI_SET_ABSBIT = 0x40045567     # _IOW('U', 103, int)
UI_SET_PROPBIT = 0x4004556E    # _IOW('U', 110, int)

BUS_VIRTUAL = 0x06
ABS_MAX_VALUE = 32767          # the conventional logical range for abs pointers

# struct input_event on 64-bit: struct timeval (two 64-bit) + u16 + u16 + s32
INPUT_EVENT = struct.Struct("@llHHi")

BUTTON_CODES = {"left": BTN_LEFT, "right": BTN_RIGHT, "middle": BTN_MIDDLE}

# Highest key code we enable on the virtual keyboard. 255 covers every standard
# KEY_* the Mac side can translate to; beyond that lie the rarely-used extended
# and vendor ranges.
MAX_KEY_CODE = 255


def log(*args):
    """Unbuffered stderr — journald picks this up under systemd."""
    print(time.strftime("%H:%M:%S"), *args, file=sys.stderr, flush=True)


# ---------------------------------------------------------------------------
# Virtual devices
# ---------------------------------------------------------------------------

class UInputDevice:
    """One virtual kernel input device, built and torn down over /dev/uinput."""

    def __init__(self, name, vendor=0x1D6B, product=0x0001, version=1):
        try:
            self.fd = os.open("/dev/uinput", os.O_WRONLY | os.O_NONBLOCK)
        except OSError as e:
            if e.errno in (errno.EACCES, errno.EPERM):
                raise SystemExit(
                    "cannot open /dev/uinput: run as root, or add a udev rule "
                    "granting your user access (see install.sh)"
                )
            if e.errno == errno.ENOENT:
                raise SystemExit(
                    "/dev/uinput is missing: run 'sudo modprobe uinput' "
                    "(install.sh sets this up to load at boot)"
                )
            raise
        self.name = name
        self._vendor = vendor
        self._product = product
        self._version = version
        self._created = False
        # Everything currently held down, so it can be released on disconnect.
        self._pressed = set()

    # -- capability declaration (all must happen before create()) --

    def enable_event(self, ev_type):
        fcntl.ioctl(self.fd, UI_SET_EVBIT, ev_type)

    def enable_key(self, code):
        fcntl.ioctl(self.fd, UI_SET_KEYBIT, code)

    def enable_rel(self, code):
        fcntl.ioctl(self.fd, UI_SET_RELBIT, code)

    def enable_prop(self, prop):
        fcntl.ioctl(self.fd, UI_SET_PROPBIT, prop)

    def enable_abs(self, code, minimum=0, maximum=ABS_MAX_VALUE):
        fcntl.ioctl(self.fd, UI_SET_ABSBIT, code)
        # struct uinput_abs_setup { __u16 code; struct input_absinfo absinfo; }
        # input_absinfo is six s32: value, min, max, fuzz, flat, resolution.
        # The u16 is padded to 4 bytes before the struct that follows it.
        payload = struct.pack("@HHiiiiii", code, 0, 0, minimum, maximum, 0, 0, 0)
        fcntl.ioctl(self.fd, UI_ABS_SETUP, payload)

    def create(self):
        # struct uinput_setup { struct input_id id; char name[80]; __u32 ff_effects_max; }
        # struct input_id { __u16 bustype, vendor, product, version; }
        setup = struct.pack(
            "@HHHH80sI",
            BUS_VIRTUAL, self._vendor, self._product, self._version,
            self.name.encode()[:79], 0,
        )
        fcntl.ioctl(self.fd, UI_DEV_SETUP, setup)
        fcntl.ioctl(self.fd, UI_DEV_CREATE)
        self._created = True
        # The compositor needs a moment to notice and open the new device;
        # events written before that are delivered nowhere.
        time.sleep(0.15)
        log(f"created virtual device: {self.name}")

    # -- event emission --

    def write(self, ev_type, code, value):
        os.write(self.fd, INPUT_EVENT.pack(0, 0, ev_type, code, value))

    def sync(self):
        self.write(EV_SYN, SYN_REPORT, 0)

    def key(self, code, pressed):
        """Press or release, tracking state so it can be undone later."""
        self.write(EV_KEY, code, 1 if pressed else 0)
        if pressed:
            self._pressed.add(code)
        else:
            self._pressed.discard(code)

    def release_all(self):
        """
        Let go of everything held down.

        This is the single most important safety property of the daemon. If the
        Mac disappears mid-keystroke — network drop, crash, laptop lid closed —
        a held Ctrl or a held mouse button would otherwise stay down forever
        from the kernel's point of view, and the only cure would be unloading
        the device. Called on disconnect, on error and on shutdown.
        """
        if not self._pressed:
            return
        log(f"{self.name}: releasing {len(self._pressed)} stuck key(s)/button(s)")
        for code in sorted(self._pressed):
            self.write(EV_KEY, code, 0)
        self._pressed.clear()
        self.sync()

    def close(self):
        if self._created:
            self.release_all()
            try:
                fcntl.ioctl(self.fd, UI_DEV_DESTROY)
            except OSError:
                pass
            self._created = False
        try:
            os.close(self.fd)
        except OSError:
            pass


def make_pointer(relative=False):
    """
    The virtual pointer.

    INPUT_PROP_POINTER is what stops libinput from classifying an absolute
    device as a touchscreen — without it, GNOME would treat every motion as a
    touch and the cursor would not move.
    """
    dev = UInputDevice("MSG Relay Pointer", product=0x0002)
    dev.enable_event(EV_KEY)
    for code in BUTTON_CODES.values():
        dev.enable_key(code)
    dev.enable_prop(INPUT_PROP_POINTER)

    dev.enable_event(EV_REL)
    dev.enable_rel(REL_WHEEL)
    dev.enable_rel(REL_HWHEEL)
    if relative:
        dev.enable_rel(REL_X)
        dev.enable_rel(REL_Y)
    else:
        dev.enable_event(EV_ABS)
        dev.enable_abs(ABS_X)
        dev.enable_abs(ABS_Y)

    dev.create()
    return dev


def make_keyboard():
    dev = UInputDevice("MSG Relay Keyboard", product=0x0003)
    dev.enable_event(EV_KEY)
    for code in range(1, MAX_KEY_CODE + 1):
        dev.enable_key(code)
    dev.create()
    return dev


# ---------------------------------------------------------------------------
# Session — one connected Mac
# ---------------------------------------------------------------------------

class Session:
    """Applies protocol messages from one authenticated client to the devices."""

    def __init__(self, pointer, keyboard, relative):
        self.pointer = pointer
        self.keyboard = keyboard
        self.relative = relative
        self.authenticated = False
        # Last absolute position, so relative mode can derive deltas from the
        # same normalised stream the absolute path uses.
        self._last_xy = None

    def _abs_from_normalised(self, x, y):
        clamp = lambda v: 0.0 if v < 0.0 else (1.0 if v > 1.0 else v)
        return (int(clamp(float(x)) * ABS_MAX_VALUE),
                int(clamp(float(y)) * ABS_MAX_VALUE))

    def _move(self, x, y):
        ax, ay = self._abs_from_normalised(x, y)
        if self.relative:
            # Fallback path: derive a delta. Accurate entry position is lost —
            # that is the trade for compositors that mishandle absolute devices.
            if self._last_xy is not None:
                self.pointer.write(EV_REL, REL_X, ax - self._last_xy[0])
                self.pointer.write(EV_REL, REL_Y, ay - self._last_xy[1])
        else:
            self.pointer.write(EV_ABS, ABS_X, ax)
            self.pointer.write(EV_ABS, ABS_Y, ay)
        self._last_xy = (ax, ay)
        self.pointer.sync()

    def handle(self, msg, token):
        """Returns a reply dict, or None. Raises ValueError to drop the client."""
        kind = msg.get("t")

        if not self.authenticated:
            if kind != "hello":
                raise ValueError("first message must be hello")
            if not isinstance(msg.get("token"), str) or msg["token"] != token:
                raise ValueError("bad token")
            self.authenticated = True
            log("client authenticated")
            return {"t": "welcome", "v": 1,
                    "mode": "relative" if self.relative else "absolute"}

        if kind == "ping":
            return {"t": "pong"}

        if kind == "enter":
            # Place the cursor before anything else happens, so the first click
            # after a handover lands where the user aimed on the Mac.
            self._last_xy = None if self.relative else self._last_xy
            self._move(msg["x"], msg["y"])
            return None

        if kind == "motion":
            self._move(msg["x"], msg["y"])
            return None

        if kind == "leave":
            # Pointer control returns to the Mac. Nothing may stay held here.
            self.pointer.release_all()
            self.keyboard.release_all()
            self._last_xy = None
            return None

        if kind == "button":
            code = BUTTON_CODES.get(msg.get("b"))
            if code is None:
                raise ValueError(f"unknown button {msg.get('b')!r}")
            self.pointer.key(code, bool(msg.get("s")))
            self.pointer.sync()
            return None

        if kind == "scroll":
            dy, dx = int(msg.get("dy", 0)), int(msg.get("dx", 0))
            if dy:
                self.pointer.write(EV_REL, REL_WHEEL, dy)
            if dx:
                self.pointer.write(EV_REL, REL_HWHEEL, dx)
            if dy or dx:
                self.pointer.sync()
            return None

        if kind == "key":
            code = int(msg.get("c", 0))
            if not 1 <= code <= MAX_KEY_CODE:
                raise ValueError(f"key code {code} out of range")
            self.keyboard.key(code, bool(msg.get("s")))
            self.keyboard.sync()
            return None

        raise ValueError(f"unknown message type {kind!r}")

    def end(self):
        self.pointer.release_all()
        self.keyboard.release_all()


# ---------------------------------------------------------------------------
# Server
# ---------------------------------------------------------------------------

def load_token(path):
    try:
        with open(path) as f:
            token = f.read().strip()
    except FileNotFoundError:
        raise SystemExit(f"token file {path} not found — run install.sh first")
    if len(token) < 16:
        raise SystemExit(f"token in {path} is too short; use at least 16 characters")
    mode = os.stat(path).st_mode & 0o777
    if mode & 0o077:
        log(f"WARNING: {path} is mode {mode:o}; it grants input injection, "
            f"so it should be 0600")
    return token


def serve(args, token, pointer, keyboard):
    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind((args.bind, args.port))
    server.listen(1)          # one Mac at a time, by design
    server.setblocking(False)
    log(f"listening on {args.bind}:{args.port}")

    sel = selectors.DefaultSelector()
    sel.register(server, selectors.EVENT_READ, "server")

    conn = None
    session = None
    buf = b""
    last_seen = 0.0

    def drop(reason):
        nonlocal conn, session, buf
        if conn is None:
            return
        log(f"client disconnected: {reason}")
        if session:
            session.end()
        sel.unregister(conn)
        conn.close()
        conn = None
        session = None
        buf = b""

    try:
        while True:
            for key, _ in sel.select(timeout=1.0):
                if key.data == "server":
                    new, addr = server.accept()
                    if conn is not None:
                        # Refuse rather than queue: two Macs fighting over one
                        # pointer is never what anyone wants.
                        log(f"refusing {addr[0]} — already serving a client")
                        new.close()
                        continue
                    new.setblocking(False)
                    new.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
                    conn = new
                    session = Session(pointer, keyboard, args.relative)
                    buf = b""
                    last_seen = time.monotonic()
                    sel.register(conn, selectors.EVENT_READ, "client")
                    log(f"client connected from {addr[0]}")
                    continue

                try:
                    chunk = conn.recv(65536)
                except (BlockingIOError, InterruptedError):
                    continue
                except OSError as e:
                    drop(f"socket error: {e}")
                    continue

                if not chunk:
                    drop("closed by peer")
                    continue

                last_seen = time.monotonic()
                buf += chunk
                if len(buf) > 1 << 20:
                    drop("oversized message")
                    continue

                while b"\n" in buf:
                    line, buf = buf.split(b"\n", 1)
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        msg = json.loads(line)
                        if not isinstance(msg, dict):
                            raise ValueError("message must be an object")
                        reply = session.handle(msg, token)
                    except (ValueError, KeyError, TypeError) as e:
                        # An unauthenticated peer gets nothing back that would
                        # help it guess the token.
                        drop(f"protocol error: {e}")
                        break
                    if reply is not None:
                        try:
                            conn.sendall((json.dumps(reply) + "\n").encode())
                        except OSError as e:
                            drop(f"send failed: {e}")
                            break

            # A Mac that vanishes without closing the socket (lid shut, Wi-Fi
            # drop) would otherwise leave keys held down indefinitely.
            if conn is not None and time.monotonic() - last_seen > args.timeout:
                drop(f"no traffic for {args.timeout}s")
    finally:
        drop("shutting down")
        sel.close()
        server.close()


def main():
    p = argparse.ArgumentParser(description="MSG cross-machine input receiver")
    p.add_argument("--port", type=int, default=47654)
    p.add_argument("--bind", default="0.0.0.0",
                   help="address to listen on (default: all interfaces)")
    p.add_argument("--token-file", default="/etc/msg-inputd/token")
    p.add_argument("--timeout", type=float, default=15.0,
                   help="seconds of silence before assuming the Mac is gone")
    p.add_argument("--relative", action="store_true",
                   help="fall back to a relative pointer; loses exact entry "
                        "position but avoids absolute-device quirks")
    args = p.parse_args()

    token = load_token(args.token_file)

    pointer = make_pointer(relative=args.relative)
    keyboard = make_keyboard()

    def shutdown(signum, _frame):
        log(f"signal {signum} — releasing input and exiting")
        pointer.close()
        keyboard.close()
        sys.exit(0)

    signal.signal(signal.SIGTERM, shutdown)
    signal.signal(signal.SIGINT, shutdown)

    try:
        serve(args, token, pointer, keyboard)
    finally:
        pointer.close()
        keyboard.close()


if __name__ == "__main__":
    main()
