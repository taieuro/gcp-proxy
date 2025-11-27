#!/usr/bin/env bash
# Auto-create HTTP proxy on Google Cloud VM using 3proxy
# - Lần đầu: cài 3proxy, tạo user/pass/port, systemd service, firewall rule
# - Các lần sau: tự phát hiện proxy cũ, in lại thông tin ngay lập tức
# Proxy output: ip:port:user:pass

set -e

INFO_FILE="/root/proxy_info.txt"
CONF="/usr/local/etc/3proxy"
LOG="/var/log/3proxy"
BIN="/usr/local/bin/3proxy"

echo "=== 3proxy auto proxy installer ==="

#--------------------------------------------------
# 0. Đảm bảo đang chạy với quyền root
#--------------------------------------------------
if [ "$EUID" -ne 0 ]; then
  echo "❌ Please run using: curl -s URL | sudo bash"
  exit 1
fi

#--------------------------------------------------
# 1. Nếu đã có proxy_info.txt -> in lại proxy, không cài lại
#--------------------------------------------------
if [ -f "$INFO_FILE" ]; then
  echo
  echo "=== Detected existing proxy info at $INFO_FILE ==="
  # Nếu có service 3proxy thì restart cho chắc
  if systemctl list-unit-files | grep -q '^3proxy\.service'; then
    echo "Restarting 3proxy service..."
    systemctl reset-failed 3proxy >/dev/null 2>&1 || true
    systemctl restart 3proxy >/dev/null 2>&1 || true
  fi
  echo
  echo "Your proxy:"
  cat "$INFO_FILE"
  echo
  echo "You can reuse the same command (curl ... | sudo bash) anytime to see this again."
  exit 0
fi

echo "No existing proxy detected. Creating a new one..."

#--------------------------------------------------
# 2. Cài các package cần thiết (chỉ lần đầu)
#--------------------------------------------------
apt-get update -y
apt-get install -y build-essential curl wget openssl

#--------------------------------------------------
# 3. Tải & build 3proxy (nếu chưa có)
#--------------------------------------------------
VERSION="0.9.5"       # phiên bản stable, binary nằm ở bin/3proxy
SRC="/usr/local/src"

mkdir -p "$SRC" "$CONF" "$LOG"

if [ -x "$BIN" ]; then
  echo "[1/4] 3proxy binary already exists at $BIN, skipping build."
else
  echo "[1/4] Downloading 3proxy ${VERSION}..."
  cd "$SRC"
  wget "https://github.com/3proxy/3proxy/archive/refs/tags/${VERSION}.tar.gz" -O 3proxy.tar.gz

  rm -rf "3proxy-${VERSION}"
  tar xzf 3proxy.tar.gz
  cd "3proxy-${VERSION}"

  echo "[2/4] Building 3proxy..."
  make -f Makefile.Linux

  # Binary ở bin/3proxy (không phải src/3proxy)
  cp bin/3proxy "$BIN"
  chmod +x "$BIN"
fi

#--------------------------------------------------
# 4. Tạo port / user / pass ngẫu nhiên + config mới
#--------------------------------------------------
echo "[3/4] Generating random credentials..."
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

#--------------------------------------------------
# 5. Tạo systemd service (không dùng daemon trong config)
#--------------------------------------------------
echo "[4/4] Creating systemd service..."

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

#--------------------------------------------------
# 6. Tự động tạo firewall rule nếu có gcloud & đủ quyền
#--------------------------------------------------
create_firewall_rule() {
  echo
  echo "=== Checking/creating firewall rule gcp-proxy-ports (tcp:20000-60000) ==="

  if ! command -v gcloud >/dev/null 2>&1; then
    echo "⚠ gcloud not found on this VM. Skipping auto firewall rule."
    return
  fi

  METADATA_HEADER="Metadata-Flavor: Google"

  PROJECT_ID=$(curl -s -H "$METADATA_HEADER" \
    http://169.254.169.254/computeMetadata/v1/project/project-id || true)

  NETWORK_URL=$(curl -s -H "$METADATA_HEADER" \
    http://169.254.169.254/computeMetadata/v1/instance/network-interfaces/0/network || true)

  NETWORK=${NETWORK_URL##*/}

  if [ -z "$PROJECT_ID" ] || [ -z "$NETWORK" ]; then
    echo "⚠ Cannot detect project/network from metadata. Skipping auto firewall rule."
    return
  fi

  echo "Project: $PROJECT_ID"
  echo "Network: $NETWORK"

  if gcloud compute firewall-rules describe gcp-proxy-ports \
      --project="$PROJECT_ID" >/dev/null 2>&1; then
    echo "✅ Firewall rule gcp-proxy-ports already exists. Skipping creation."
    return
  fi

  echo "Creating firewall rule gcp-proxy-ports (tcp:20000-60000 from 0.0.0.0/0)..."

  if gcloud compute firewall-rules create gcp-proxy-ports \
      --project="$PROJECT_ID" \
      --network="$NETWORK" \
      --allow=tcp:20000-60000 \
      --direction=INGRESS \
      --source-ranges=0.0.0.0/0 >/dev/null 2>&1; then
    echo "✅ Firewall rule gcp-proxy-ports created successfully."
  else
    echo "⚠ Failed to create firewall rule automatically."
    echo "  Please create this rule manually in VPC firewall:"
    echo "  - Name: gcp-proxy-ports"
    echo "  - Network: $NETWORK"
    echo "  - Direction: INGRESS"
    echo "  - Source: 0.0.0.0/0"
    echo "  - Allowed: tcp:20000-60000"
  fi
}

create_firewall_rule

#--------------------------------------------------
# 7. Lấy IP public & in ra proxy + lưu vào /root/proxy_info.txt
#--------------------------------------------------
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
echo
echo "TIP:"
echo "- Next time, just run the same command again to show this proxy:"
echo "  curl -s https://raw.githubusercontent.com/taieuro/gcp-proxy/main/install.sh | sudo bash"
echo
