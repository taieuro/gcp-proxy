#!/usr/bin/env bash
# Auto-create HTTP proxy on Google Cloud VM using 3proxy
# - First run: install 3proxy, create user/pass/port, systemd service
# - Next runs: detect existing proxy, restart service, print proxy
# Output format: ip:port:user:pass

set -e

INFO_FILE="/root/proxy_info.txt"
CONF="/usr/local/etc/3proxy"
LOG="/var/log/3proxy"
BIN="/usr/local/bin/3proxy"
SRC="/usr/local/src"
VERSION="0.9.5"

# 0. Must run as root
if [ "$EUID" -ne 0 ]; then
  echo "❌ Please run using: curl -s URL | sudo bash"
  exit 1
fi

# 1. Nếu đã có proxy_info.txt -> chỉ restart service + in lại proxy
if [ -f "$INFO_FILE" ]; then
  echo
  echo "=== Existing 3proxy configuration detected ==="

  if systemctl list-unit-files | grep -q '^3proxy\.service'; then
    echo "Restarting 3proxy service..."
    systemctl reset-failed 3proxy >/dev/null 2>&1 || true
    systemctl restart 3proxy >/dev/null 2>&1 || true
  else
    echo "⚠ 3proxy.service not found, but proxy_info.txt exists."
  fi

  echo
  echo "Your proxy:"
  cat "$INFO_FILE"
  echo
  echo "(Run this same command anytime to show it again.)"
  exit 0
fi

# 2. Lần đầu: cài đặt & tạo proxy
echo "=== 3proxy auto proxy installer (first-time setup) ==="

apt-get update -y
apt-get install -y build-essential curl wget openssl

mkdir -p "$SRC" "$CONF" "$LOG"

# 2.1 Build 3proxy nếu chưa có
if [ -x "$BIN" ]; then
  echo "[1/3] 3proxy binary already exists at $BIN, skipping build."
else
  echo "[1/3] Downloading 3proxy ${VERSION}..."
  cd "$SRC"
  wget -q "https://github.com/3proxy/3proxy/archive/refs/tags/${VERSION}.tar.gz" -O 3proxy.tar.gz

  rm -rf "3proxy-${VERSION}"
  tar xzf 3proxy.tar.gz
  cd "3proxy-${VERSION}"

  echo "[2/3] Building 3proxy..."
  make -f Makefile.Linux

  cp bin/3proxy "$BIN"
  chmod +x "$BIN"
fi

# 2.2 Tạo port / user / pass + config
echo "[3/3] Generating random credentials..."
PORT=$(shuf -i 20000-60000 -n 1)
USER=$(openssl rand -hex 4)
PASS=$(openssl rand -hex 8)

echo "  Port: $PORT"
echo "  User: $USER"
echo "  Pass: $PASS"

cat > "$CONF/3proxy.cfg" <<EOF
nserver 8.8.8.8
nserver 1.1.1.1
auth strong
users $USER:CL:$PASS
allow $USER
proxy -n -a -p$PORT
EOF

# 2.3 Tạo systemd service
cat > /etc/systemd/system/3proxy.service <<EOF
[Unit]
Description=3proxy proxy
After=network.target

[Service]
Type=simple
ExecStart=$BIN $CONF/3proxy.cfg
Restart=always

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable 3proxy >/dev/null
systemctl reset-failed 3proxy >/dev/null 2>&1 || true
systemctl restart 3proxy

# 2.4 Lấy IP public & in ra proxy + lưu lại
METADATA_HEADER="Metadata-Flavor: Google"
IP=$(curl -s -H "$METADATA_HEADER" \
  http://169.254.169.254/computeMetadata/v1/instance/network-interfaces/0/access-configs/0/external-ip || true)

if [ -z "$IP" ]; then
  IP=$(curl -s ifconfig.me || echo "YOUR_VM_IP")
fi

PROXY="${IP}:${PORT}:${USER}:${PASS}"

echo
echo "============== NEW PROXY CREATED =============="
echo "$PROXY"
echo "==============================================="
echo
echo "$PROXY" > "$INFO_FILE"
echo "Saved to $INFO_FILE"

# 👉 Thêm dòng này (rất quan trọng để script Cloud Shell đọc lại)
echo "PROXY: $PROXY"

echo
echo "TIP:"
echo "- Next time, just run the same command again to show this proxy:"
echo "  curl -s https://raw.githubusercontent.com/taieuro/gcp-proxy/main/install.sh | sudo bash"
echo
echo "NOTE:"
echo "- Make sure you have a VPC firewall rule allowing tcp:20000-60000 from 0.0.0.0/0 to this network."
echo
