#!/usr/bin/env python3
"""
Proves msg-inputd can actually drive the Fedora pointer, without needing the
Mac side to exist yet. Run it on the Fedora machine:

    sudo ./testclient.py            # pointer only — safe, nothing is typed
    sudo ./testclient.py --keys     # also types "msg" into whatever has focus

sudo is only needed to read the token file (mode 0600).

If the cursor walks a square and lands in the middle, the whole Fedora half is
working: uinput device, absolute positioning, protocol, auth, firewall.
"""

import argparse
import json
import socket
import sys
import time


def send(sock, **msg):
    sock.sendall((json.dumps(msg) + "\n").encode())


def read_reply(sock, timeout=5.0):
    sock.settimeout(timeout)
    buf = b""
    while b"\n" not in buf:
        chunk = sock.recv(4096)
        if not chunk:
            raise SystemExit("daemon closed the connection — check: "
                             "journalctl -u msg-inputd -n 20")
        buf += chunk
    return json.loads(buf.split(b"\n", 1)[0])


def glide(sock, x0, y0, x1, y1, seconds=0.6, rate=120):
    """Interpolated motion, so the movement is visible rather than a teleport."""
    steps = max(2, int(seconds * rate))
    for i in range(steps + 1):
        t = i / steps
        send(sock, t="motion", x=x0 + (x1 - x0) * t, y=y0 + (y1 - y0) * t)
        time.sleep(seconds / steps)


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--host", default="127.0.0.1")
    p.add_argument("--port", type=int, default=47654)
    p.add_argument("--token-file", default="/etc/msg-inputd/token")
    p.add_argument("--keys", action="store_true",
                   help="also type 'msg' — goes into the focused window")
    args = p.parse_args()

    try:
        with open(args.token_file) as f:
            token = f.read().strip()
    except PermissionError:
        raise SystemExit(f"cannot read {args.token_file} — re-run with sudo")
    except FileNotFoundError:
        raise SystemExit(f"{args.token_file} not found — run install.sh first")

    with socket.create_connection((args.host, args.port), timeout=5) as sock:
        send(sock, t="hello", v=1, token=token)
        welcome = read_reply(sock)
        if welcome.get("t") != "welcome":
            raise SystemExit(f"unexpected reply: {welcome}")
        print(f"connected — pointer mode: {welcome.get('mode')}")

        print("entering at the top-left quarter…")
        send(sock, t="enter", x=0.25, y=0.25)
        time.sleep(0.4)

        print("walking a square…")
        glide(sock, 0.25, 0.25, 0.75, 0.25)
        glide(sock, 0.75, 0.25, 0.75, 0.75)
        glide(sock, 0.75, 0.75, 0.25, 0.75)
        glide(sock, 0.25, 0.75, 0.25, 0.25)

        print("centring…")
        glide(sock, 0.25, 0.25, 0.5, 0.5)

        print("scrolling…")
        for _ in range(3):
            send(sock, t="scroll", dy=-1)
            time.sleep(0.08)
        for _ in range(3):
            send(sock, t="scroll", dy=1)
            time.sleep(0.08)

        if args.keys:
            print("typing 'msg'…")
            # Linux keycodes: KEY_M=50, KEY_S=31, KEY_G=34
            for code in (50, 31, 34):
                send(sock, t="key", c=code, s=1)
                time.sleep(0.03)
                send(sock, t="key", c=code, s=0)
                time.sleep(0.06)

        send(sock, t="ping")
        if read_reply(sock).get("t") != "pong":
            raise SystemExit("no pong — daemon is not healthy")

        print("releasing…")
        send(sock, t="leave")
        time.sleep(0.2)

    print("\nOK — the Fedora side works.")


if __name__ == "__main__":
    sys.exit(main())
