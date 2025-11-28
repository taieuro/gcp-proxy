#!/usr/bin/env bash
# Script chạy trong Cloud Shell để:
# - Mỗi lần chạy tạo THÊM NUM_VMS VM mới (tên tăng dần: proxy-vm-1,2,3...)
# - Tạo firewall rule chung cho proxy ports (nếu chưa có)
# - SSH song song vào từng VM MỚI và chạy install.sh tạo proxy
# - Cuối cùng in list proxy CỦA CÁC VM MỚI tạo trong lần chạy này
#
# Cách chạy:
#   curl -s https://raw.githubusercontent.com/taieuro/gcp-proxy/main/create-proxy-vms.sh | bash

set -euo pipefail

#######################################
# CẤU HÌNH CÓ THỂ SỬA
#######################################
NUM_VMS=3                        # Số VM MUỐN TẠO THÊM MỖI LẦN CHẠY
VM_NAME_PREFIX="proxy-vm"        # Prefix tên VM: proxy-vm-1, proxy-vm-2, ...

REGION="asia-northeast2"         # Region
ZONE=""                          # ĐỂ TRỐNG -> script tự chọn 1 zone trong REGION

MACHINE_TYPE="e2-micro"          # Loại máy
IMAGE_FAMILY="debian-12"         # Hệ điều hành
IMAGE_PROJECT="debian-cloud"
DISK_SIZE="10GB"
DISK_TYPE="pd-standard"          # New standard persistent disk (rẻ nhất)

NETWORK="default"                # Tên VPC network

# Networking tags (giống UI):
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

# Nếu ZONE trống, tự chọn 1 zone trong REGION
if [[ -z "${ZONE}" ]]; then
  echo "⏳ Đang tự chọn 1 zone trong region $REGION ..."
  ZONE="$(gcloud compute zones list \
            --filter="region:($REGION) AND status:UP" \
            --format="value(name)" | head -n 1 || true)"
  if [[ -z "$ZONE" ]]; then
    echo "❌ Không tìm được zone nào trong region $REGION. Kiểm tra lại REGION/Zones."
    exit 1
  fi
fi

echo "=== Thông tin cấu hình ==="
echo "Project       : $PROJECT"
echo "Region        : $REGION"
echo "Zone          : $ZONE"
echo "Số VM mới     : $NUM_VMS"
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
# BƯỚC 2: XÁC ĐỊNH CHỈ SỐ VM TIẾP THEO & TẠO VM MỚI
#######################################
echo "=== Bước 2: Tìm chỉ số VM tiếp theo & tạo VM mới ==="

# Lấy danh sách VM hiện có trong ZONE với tên dạng prefix-<số>
EXISTING_NAMES="$(gcloud compute instances list \
  --project="$PROJECT" \
  --filter="zone:($ZONE) AND name ~ '^${VM_NAME_PREFIX}-[0-9]+$'" \
  --format="value(name)" || true)"

MAX_INDEX=0

if [[ -n "$EXISTING_NAMES" ]]; then
  while IFS= read -r NAME; do
    [[ -z "$NAME" ]] && continue
    IDX="${NAME##*-}"
    if [[ "$IDX" =~ ^[0-9]+$ ]]; then
      if (( IDX > MAX_INDEX )); then
        MAX_INDEX=$IDX
      fi
    fi
  done <<< "$EXISTING_NAMES"
fi

START_INDEX=$((MAX_INDEX + 1))
END_INDEX=$((MAX_INDEX + NUM_VMS))

echo "Số index hiện tại lớn nhất: $MAX_INDEX"
echo "Sẽ tạo VM mới từ: ${VM_NAME_PREFIX}-${START_INDEX} đến ${VM_NAME_PREFIX}-${END_INDEX}"
echo

NEW_VM_NAMES=()
for i in $(seq "$START_INDEX" "$END_INDEX"); do
  NEW_VM_NAMES+=("${VM_NAME_PREFIX}-${i}")
done

if [[ "${#NEW_VM_NAMES[@]}" -eq 0 ]]; then
  echo "⚠ Không có VM mới cần tạo (NUM_VMS = 0?). Kết thúc."
  exit 0
fi

echo "⏳ Đang tạo các VM mới: ${NEW_VM_NAMES[*]} ..."

TMP_ERR="$(mktemp)"
# Chỉ redirect stderr vào file để bắt lỗi quota, stdout vẫn in ra console
if ! gcloud compute instances create "${NEW_VM_NAMES[@]}" \
      --project="$PROJECT" \
      --zone="$ZONE" \
      --machine-type="$MACHINE_TYPE" \
      --image-family="$IMAGE_FAMILY" \
      --image-project="$IMAGE_PROJECT" \
      --boot-disk-size="$DISK_SIZE" \
      --boot-disk-type="$DISK_TYPE" \
      --network="$NETWORK" \
      --tags="$TAGS" 2>"$TMP_ERR"; then

  echo "⚠ Lỗi khi tạo các VM mới:"
  cat "$TMP_ERR"

  if grep -q "IN_USE_ADDRESSES" "$TMP_ERR"; then
    echo
    echo "❗ Phát hiện lỗi quota IN_USE_ADDRESSES (hết số lượng IP external trong region $REGION)."
    echo "   Không tạo thêm được VM mới trong region này."
    echo "   Các VM & proxy hiện có vẫn giữ nguyên, chỉ là lần chạy này không thêm VM mới."
    rm -f "$TMP_ERR"
    # Thoát “êm” (exit 0) để lệnh curl | bash không bị báo lỗi đỏ
    exit 0
  fi

  rm -f "$TMP_ERR"
  echo "❌ Lỗi không phải quota IN_USE_ADDRESSES. Thoát."
  exit 1
fi
rm -f "$TMP_ERR"

echo "✅ Đã tạo xong các VM mới."
echo

# ĐỢI VM KHỞI ĐỘNG SSH
echo "⏳ Đợi 30 giây để các VM mới khởi động dịch vụ SSH..."
sleep 30
echo

#######################################
# BƯỚC 3: CHUẨN BỊ SSH KEY CHO GCLOUD (TRÁNH LỖI OVERWRITE)
#######################################
echo "=== Bước 3: Kiểm tra/generate SSH key cho gcloud ==="

SSH_KEY_PRIV="$HOME/.ssh/google_compute_engine"
SSH_KEY_PUB="$HOME/.ssh/google_compute_engine.pub"

mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"

if [[ ! -f "$SSH_KEY_PRIV" || ! -f "$SSH_KEY_PUB" ]]; then
  echo "⏳ Đang tạo SSH key $SSH_KEY_PRIV ..."
  ssh-keygen -t rsa -f "$SSH_KEY_PRIV" -N "" -q
  echo "✅ Đã tạo SSH key cho gcloud."
else
  echo "✅ SSH key đã tồn tại: $SSH_KEY_PRIV"
fi

echo

#######################################
# BƯỚC 4: SSH SONG SONG VÀO TỪNG VM MỚI, CHẠY install.sh
#######################################
echo "=== Bước 4: Cài proxy trên các VM mới (SSH song song) ==="
echo

declare -A LOG_FILES
declare -A PIDS

for VM_NAME in "${NEW_VM_NAMES[@]}"; do
  LOG_FILE="/tmp/${VM_NAME}.proxy.log"
  LOG_FILES["$VM_NAME"]="$LOG_FILE"

  echo "▶ Bắt đầu cài proxy trên VM '$VM_NAME' (log: $LOG_FILE)..."

  gcloud compute ssh "$VM_NAME" \
        --zone="$ZONE" \
        --project="$PROJECT" \
        --quiet \
        --command="curl -s $PROXY_INSTALL_URL | sudo bash" \
        >"$LOG_FILE" 2>&1 &

  PIDS["$VM_NAME"]=$!
done

echo
echo "⏳ Đang đợi các VM mới cài proxy xong..."
echo

declare -A PROXIES
FAILED_VMS=()

for VM_NAME in "${NEW_VM_NAMES[@]}"; do
  PID="${PIDS[$VM_NAME]}"
  LOG_FILE="${LOG_FILES[$VM_NAME]}"

  if wait "$PID"; then
    if grep -q "PROXY:" "$LOG_FILE"; then
      PROXY_LINE=$(grep "PROXY:" "$LOG_FILE" | tail -n 1 | sed 's/^.*PROXY:[[:space:]]*//')
      PROXIES["$VM_NAME"]="$PROXY_LINE"
      echo "✅ VM '$VM_NAME' cài proxy thành công."
    else
      FAILED_VMS+=("$VM_NAME")
      echo "⚠ VM '$VM_NAME' KHÔNG tìm thấy dòng PROXY trong log. Kiểm tra: $LOG_FILE"
      echo "---- Tail log $VM_NAME ----"
      tail -n 20 "$LOG_FILE" || true
      echo "----------------------------"
    fi
  else
    FAILED_VMS+=("$VM_NAME")
    echo "⚠ VM '$VM_NAME' cài proxy lỗi. Kiểm tra: $LOG_FILE"
    echo "---- Tail log $VM_NAME ----"
    tail -n 20 "$LOG_FILE" || true
    echo "----------------------------"
  fi
done

echo
echo "================= TỔNG HỢP PROXY MỚI ĐÃ TẠO ================="
for VM_NAME in "${NEW_VM_NAMES[@]}"; do
  if [[ -n "${PROXIES[$VM_NAME]:-}" ]]; then
    echo "$VM_NAME: ${PROXIES[$VM_NAME]}"
  else
    echo "$VM_NAME: (FAILED - xem log: ${LOG_FILES[$VM_NAME]})"
  fi
done
echo "============================================================="
echo

if [[ "${#FAILED_VMS[@]}" -gt 0 ]]; then
  echo "Một số VM bị lỗi: ${FAILED_VMS[*]}"
  echo "Bạn có thể SSH vào và chạy lại thủ công, ví dụ:"
  echo "  gcloud compute ssh ${FAILED_VMS[0]} --zone=$ZONE --project=$PROJECT"
  echo "  curl -s $PROXY_INSTALL_URL | sudo bash"
  echo
fi

echo "Hoàn tất."
