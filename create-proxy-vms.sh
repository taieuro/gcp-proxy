#!/usr/bin/env bash
# Script chạy trong Cloud Shell để:
# - Tạo nhiều VM GCP cho proxy
# - Tạo firewall rule chung cho proxy ports
# - SSH tự động vào từng VM và chạy install.sh tạo proxy
#
# Cách chạy (sau khi file này ở trên GitHub):
#   curl -s https://raw.githubusercontent.com/taieuro/gcp-proxy/main/create-proxy-vms.sh | bash

set -euo pipefail

#######################################
# CẤU HÌNH CÓ THỂ SỬA
#######################################
NUM_VMS=3                        # Số VM muốn tạo
VM_NAME_PREFIX="proxy-vm"        # Prefix tên VM: proxy-vm-1, proxy-vm-2, ...
ZONE="asia-southeast1-b"         # Zone
MACHINE_TYPE="e2-micro"          # Loại máy
IMAGE_FAMILY="debian-12"         # Hệ điều hành
IMAGE_PROJECT="debian-cloud"
DISK_SIZE="10GB"
DISK_TYPE="pd-standard"          # New standard persistent disk (rẻ nhất)
NETWORK="default"                # Tên VPC network

# Networking tags:
# - proxy-vm: dùng cho firewall rule gcp-proxy-ports (tcp:20000-60000)
# - http-server, https-server, lb-health-check: tương đương tick 3 checkbox trong UI
TAGS="proxy-vm,http-server,https-server,lb-health-check"

FIREWALL_NAME="gcp-proxy-ports"  # Tên firewall rule cho proxy port
PROXY_INSTALL_URL="https://raw.githubusercontent.com/taieuro/gcp-proxy/main/install.sh"

#######################################
# THÔNG TIN PROJECT
#######################################
PROJECT="$(gcloud config get-value project 2>/dev/null || echo "")"
if [[ -z "$PROJECT" ]]; then
  echo "❌ Không lấy được project hiện tại."
  echo "   Hãy chạy: gcloud config set project <PROJECT_ID>"
  exit 1
fi

echo "=== Thông tin cấu hình ==="
echo "Project       : $PROJECT"
echo "Zone          : $ZONE"
echo "Số VM         : $NUM_VMS"
echo "VM name prefix: $VM_NAME_PREFIX"
echo "Machine type  : $MACHINE_TYPE"
echo "Disk size     : $DISK_SIZE"
echo "Disk type     : $DISK_TYPE (New standard persistent disk)"
echo "Network       : $NETWORK"
echo "Tags          : $TAGS"
echo "Firewall rule : $FIREWALL_NAME (tcp:20000-60000, 0.0.0.0/0, target tag=proxy-vm)"
echo "Proxy script  : $PROXY_INSTALL_URL"
echo

#######################################
# BƯỚC 1: TẠO FIREWALL RULE (DÙNG CHUNG)
#######################################
echo "=== Bước 1: Tạo (hoặc dùng lại) firewall rule ==="

if gcloud compute firewall-rules describe "$FIREWALL_NAME" \
    --project="$PROJECT" >/dev/null 2>&1; then
  echo "✅ Firewall rule '$FIREWALL_NAME' đã tồn tại, dùng lại."
else
  echo "⏳ Đang tạo firewall rule '$FIREWALL_NAME' ..."
  gcloud compute firewall-rules create "$FIREWALL_NAME" \
    --project="$PROJECT" \
    --network="$NETWORK" \
    --direction=INGRESS \
    --priority=1000 \
    --action=ALLOW \
    --rules=tcp:20000-60000 \
    --source-ranges=0.0.0.0/0 \
    --target-tags="proxy-vm"
  echo "✅ Đã tạo firewall rule '$FIREWALL_NAME'."
fi

echo

#######################################
# BƯỚC 2: TẠO CÁC VM
#######################################
echo "=== Bước 2: Tạo các VM (nếu chưa tồn tại) ==="

VM_NAMES=()

for i in $(seq 1 "$NUM_VMS"); do
  VM_NAME="${VM_NAME_PREFIX}-${i}"
  VM_NAMES+=("$VM_NAME")

  if gcloud compute instances describe "$VM_NAME" \
      --zone="$ZONE" \
      --project="$PROJECT" >/dev/null 2>&1; then
    echo "⚠ VM '$VM_NAME' đã tồn tại, bỏ qua tạo mới."
    continue
  fi

  echo "⏳ Đang tạo VM '$VM_NAME' ..."
  gcloud compute instances create "$VM_NAME" \
    --project="$PROJECT" \
    --zone="$ZONE" \
    --machine-type="$MACHINE_TYPE" \
    --image-family="$IMAGE_FAMILY" \
    --image-project="$IMAGE_PROJECT" \
    --boot-disk-size="$DISK_SIZE" \
    --boot-disk-type="$DISK_TYPE" \
    --network="$NETWORK" \
    --tags="$TAGS"

  echo "✅ Đã tạo VM '$VM_NAME'."
done

echo
#######################################
# BƯỚC 3: SSH TỰ ĐỘNG VÀO TỪNG VM, CHẠY install.sh
#######################################
echo "=== Bước 3: Cài proxy trên từng VM (tự động SSH + curl | sudo bash) ==="
echo

for VM_NAME in "${VM_NAMES[@]}"; do
  echo "---------------------------------------------"
  echo "▶ VM: $VM_NAME"
  echo "---------------------------------------------"

  # install.sh được thiết kế idempotent:
  # - Nếu lần đầu: cài 3proxy, tạo proxy, in ip:port:user:pass
  # - Nếu đã có: chỉ restart service và in lại proxy
  if gcloud compute ssh "$VM_NAME" \
        --zone="$ZONE" \
        --project="$PROJECT" \
        --quiet \
        --command="curl -s $PROXY_INSTALL_URL | sudo bash"; then
    echo "✅ Hoàn tất cài proxy trên VM '$VM_NAME'."
  else
    echo "⚠ Lỗi khi SSH/chạy script trên VM '$VM_NAME'."
    echo "  Bạn có thể thử lại thủ công bằng:"
    echo "    gcloud compute ssh $VM_NAME --zone=$ZONE --project=$PROJECT"
    echo "    curl -s $PROXY_INSTALL_URL | sudo bash"
  fi

  echo
done

echo "=== Tất cả bước đã hoàn tất. Xem log phía trên để biết proxy từng VM (ip:port:user:pass). ==="
