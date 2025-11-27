#!/usr/bin/env bash
# Auto-create HTTP proxy on Google Cloud VM using 3proxy
# Outputs: ip:port:user:pass

set -e

echo "=== Installing 3proxy (auto proxy generator) ==="

# Ensure root
if [ "$EUID" -ne 0 ]; then
  echo "Please run using: curl -s URL | sudo bash"
  exit 1
fi

apt-get update -y
apt-get install -y build-essential curl wget openssl

# Official working version with stable build folder
VERSION="0.9.5"
SRC="/usr/local/src"
CONF="/usr/local/etc/3proxy"
LOG="/var/log/3proxy"
BIN="/usr/local/bin/3proxy"

mkdir -p "$SRC" "$CONF" "$LOG"

echo "[1/4] Downloading 3proxy ${VERSION}..."
cd "$SRC"
wget "https://github.com/3proxy/3proxy/archive/refs/tags/${VERSION}.tar.gz" -O 3proxy.tar.gz

rm -rf "3proxy-${VERSION}"
tar xzf 3proxy.tar.gz
cd "3proxy-${VERSION}"

echo "[2/4] Building 3proxy..."
make -f Makefile.Linux

# FIXED: binary is in bin/ now, not in src/
cp bin/3proxy "$BIN"
chmod +x "$BIN"

echo "[3/4] Generating random credentials..."
PORT=$(shuf -i 20000-60000 -n 1)
USER=$(openssl rand -hex 4)
PASS=$(openssl rand -hex 8)

echo "  Port: $PORT"
echo "  User: $USER"
echo "  Pass: $PASS"

cat > "$CONF/3proxy.cfg" <<EOF
daemon
nserver 8.8.8.8
nserver 1.1.1.1
auth strong
users $USER:CL:$PASS
allow $USER
proxy -n -a -p$PORT
EOF

echo "[4/4] Creating systemd service..."

cat > /etc/systemd/system/3proxy.service <<EOF
[Unit]
Description=3proxy proxy
After=network.target

[Service]
ExecStart=$BIN $CONF/3proxy.cfg
Restart=always

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable 3proxy >/dev/null
systemctl restart 3proxy

# Fetch external IP
IP=$(curl -s -H "Metadata-Flavor: Google" \
  http://169.254.169.254/computeMetadata/v1/instance/network-interfaces/0/access-configs/0/external-ip)

PROXY="${IP}:${PORT}:${USER}:${PASS}"

echo ""
echo "============== PROXY CREATED =============="
echo "$PROXY"
echo "==========================================="
echo ""
echo "$PROXY" > /root/proxy_info.txt
echo "Saved to /root/proxy_info.txt"
echo ""
echo "⚠ Make sure your VPC firewall allows TCP port $PORT"
