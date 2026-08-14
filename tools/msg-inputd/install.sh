#!/usr/bin/env bash
#
# Installs msg-inputd on the Fedora machine. Run with sudo, from this directory:
#
#     sudo ./install.sh
#
# Idempotent — re-run it after editing msg-inputd.py to deploy the new version.

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "run me with sudo" >&2
    exit 1
fi

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN=/usr/local/bin/msg-inputd
CONF_DIR=/etc/msg-inputd
TOKEN_FILE="$CONF_DIR/token"
UNIT=/etc/systemd/system/msg-inputd.service
PORT=47654

echo "==> installing daemon to $BIN"
install -m 0755 "$SRC_DIR/msg-inputd.py" "$BIN"

echo "==> ensuring the uinput module is loaded now and at boot"
# Fedora does not load uinput by default; without it /dev/uinput never appears.
modprobe uinput
echo uinput > /etc/modules-load.d/msg-inputd.conf

echo "==> configuring $CONF_DIR"
install -d -m 0700 "$CONF_DIR"
if [[ -f "$TOKEN_FILE" ]]; then
    echo "    token already exists, keeping it"
else
    # This token is the only thing standing between the network and a service
    # that can type anything into your session. Generate it, never pick it.
    head -c 32 /dev/urandom | base64 | tr -d '/+=' | head -c 40 > "$TOKEN_FILE"
    echo "    generated a new token"
fi
chmod 0600 "$TOKEN_FILE"

echo "==> installing systemd unit"
install -m 0644 "$SRC_DIR/msg-inputd.service" "$UNIT"
systemctl daemon-reload
systemctl enable msg-inputd.service
systemctl restart msg-inputd.service

if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    echo "==> opening port $PORT/tcp in firewalld"
    # Fedora ships firewalld on by default and it will silently swallow the
    # connection otherwise — the single most confusing way for this to fail.
    firewall-cmd --add-port=$PORT/tcp --permanent >/dev/null
    firewall-cmd --reload >/dev/null
else
    echo "==> firewalld not active; make sure $PORT/tcp is reachable"
fi

sleep 1
echo
if systemctl is-active --quiet msg-inputd.service; then
    echo "msg-inputd is running."
else
    echo "msg-inputd FAILED to start. Recent log:" >&2
    journalctl -u msg-inputd.service -n 20 --no-pager >&2
    exit 1
fi

echo
echo "Configure MSG on the Mac with:"
echo
echo "    host:  $(hostname -I 2>/dev/null | awk '{print $1}')"
echo "    port:  $PORT"
echo "    token: $(cat "$TOKEN_FILE")"
echo
echo "Verify injection without the Mac:  sudo ./testclient.py"
echo "Watch the log:                     journalctl -u msg-inputd -f"
