#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SERIAL_PORT="${SERIAL_PORT:-auto}"
SERIAL_BAUD="${SERIAL_BAUD:-921600}"
DASHBOARD_PORT="${DASHBOARD_PORT:-80}"
DASHBOARD_HOST="${DASHBOARD_HOST:-0.0.0.0}"
SERVICE_USER="${AYRMOS_USER:-${SUDO_USER:-$(id -un)}}"
SERVICE_GROUP="${AYRMOS_GROUP:-$(id -gn "$SERVICE_USER")}"

escape_sh() {
  printf "%s" "$1" | sed "s/'/'\\\\''/g"
}

REPO_ESC="$(escape_sh "$REPO_DIR")"

DASHBOARD_CAPABILITY_LINES=""
if (( DASHBOARD_PORT < 1024 )); then
  DASHBOARD_CAPABILITY_LINES="AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE"
fi

sudo apt update
sudo apt install -y git python3
if ! sudo apt install -y python3-gpiozero python3-lgpio; then
  echo "Warning: gpiozero/lgpio was not installed; Raspberry Pi 5 servo control may not work until python3-gpiozero and python3-lgpio are available." >&2
fi
if ! sudo apt install -y python3-rpi.gpio; then
  echo "Warning: python3-rpi.gpio was not installed; older Raspberry Pi OS servo fallback will not be available." >&2
fi

if [[ "$SERVICE_USER" != "root" ]]; then
  sudo usermod -aG dialout "$SERVICE_USER" || true
  SUPPLEMENTARY_GROUPS="dialout"
  if getent group gpio >/dev/null; then
    sudo usermod -aG gpio "$SERVICE_USER" || true
    SUPPLEMENTARY_GROUPS="dialout gpio"
  fi
else
  SUPPLEMENTARY_GROUPS=""
fi

chmod +x "$REPO_DIR/raspi/robstride_usb.py"
chmod +x "$REPO_DIR/raspi/robstride_dashboard.py"
chmod +x "$REPO_DIR/raspi/update_from_github.sh"

sudo tee /usr/local/bin/ayrmos-dashboard >/dev/null <<EOF
#!/usr/bin/env bash
set -euo pipefail
cd '$REPO_ESC'
exec /usr/bin/python3 raspi/robstride_dashboard.py "\$@"
EOF

sudo tee /usr/local/bin/ayrmos-update >/dev/null <<EOF
#!/usr/bin/env bash
set -euo pipefail
cd '$REPO_ESC'
exec bash raspi/update_from_github.sh "\$@"
EOF

sudo tee /usr/local/bin/ayrmos-robstride >/dev/null <<EOF
#!/usr/bin/env bash
set -euo pipefail
cd '$REPO_ESC'
exec /usr/bin/python3 raspi/robstride_usb.py "\$@"
EOF

sudo chmod +x /usr/local/bin/ayrmos-dashboard /usr/local/bin/ayrmos-update /usr/local/bin/ayrmos-robstride
sudo rm -f /usr/local/bin/ayrmos-can-up /usr/local/bin/ayrmos-can-down

sudo tee /usr/local/sbin/ayrmos-restart-dashboard >/dev/null <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exec systemctl restart robstride-dashboard.service
EOF
sudo tee /usr/local/sbin/ayrmos-poweroff >/dev/null <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ -x /usr/bin/systemctl ]]; then
  exec /usr/bin/systemctl poweroff
fi
if [[ -x /bin/systemctl ]]; then
  exec /bin/systemctl poweroff
fi
if [[ -x /usr/sbin/shutdown ]]; then
  exec /usr/sbin/shutdown -h now
fi
exec /sbin/shutdown -h now
EOF
sudo chmod +x /usr/local/sbin/ayrmos-restart-dashboard /usr/local/sbin/ayrmos-poweroff

if [[ "$SERVICE_USER" != "root" ]]; then
  sudo tee /etc/sudoers.d/ayrmos-dashboard >/dev/null <<EOF
$SERVICE_USER ALL=(root) NOPASSWD: /usr/local/sbin/ayrmos-restart-dashboard, /usr/local/sbin/ayrmos-poweroff, /usr/bin/systemctl poweroff, /bin/systemctl poweroff, /usr/sbin/shutdown -h now, /sbin/shutdown -h now
EOF
  sudo chmod 440 /etc/sudoers.d/ayrmos-dashboard
  sudo visudo -cf /etc/sudoers.d/ayrmos-dashboard >/dev/null
  if ! sudo -u "$SERVICE_USER" sudo -n -l /usr/local/sbin/ayrmos-poweroff >/dev/null; then
    echo "Warning: $SERVICE_USER could not validate passwordless /usr/local/sbin/ayrmos-poweroff." >&2
  fi
fi

sudo systemctl disable --now robstride-can.service 2>/dev/null || true
sudo rm -f /etc/systemd/system/robstride-can.service

sudo tee /etc/systemd/system/robstride-dashboard.service >/dev/null <<EOF
[Unit]
Description=AyrmOS web control service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$SERVICE_USER
Group=$SERVICE_GROUP
${SUPPLEMENTARY_GROUPS:+SupplementaryGroups=$SUPPLEMENTARY_GROUPS}
$DASHBOARD_CAPABILITY_LINES
NoNewPrivileges=false
ExecStart=/usr/local/bin/ayrmos-dashboard --host $DASHBOARD_HOST --port $DASHBOARD_PORT --serial-port $SERIAL_PORT --serial-baud $SERIAL_BAUD
Restart=on-failure
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable robstride-dashboard.service
sudo systemctl restart robstride-dashboard.service

PI_IP="$(hostname -I | awk '{print $1}')"
if [[ "$DASHBOARD_PORT" == "80" ]]; then
  DASHBOARD_URL="http://${PI_IP}"
else
  DASHBOARD_URL="http://${PI_IP}:${DASHBOARD_PORT}"
fi

echo "AyrmOS installed."
echo "Open: ${DASHBOARD_URL}"
echo "Update later with: ayrmos-update"
echo "AyrmOS service runs as user: ${SERVICE_USER}"
echo "RobStride USB adapter: ${SERIAL_PORT} at ${SERIAL_BAUD} baud"
