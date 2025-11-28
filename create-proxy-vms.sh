#!/usr/bin/env bash
# Script chạy trong Cloud Shell để:
# - Hỏi bạn muốn proxy ở đâu (1=Tokyo, 2=Osaka, 3=Seoul)
# - Tự dò quota IN_USE_ADDRESSES trong region đó và đặt NUM_VMS = số VM tối đa có thể tạo thêm
# - Mỗi lần chạy tạo THÊM NUM_VMS VM mới (tên tăng dần: proxy-vm-1,2,3...)
# - Tạo firewall rule chung cho proxy ports (nếu chưa có)
# - SSH song song vào từng VM MỚI và chạy install.sh tạo proxy
# - Cuối cùng in list proxy CỦA CÁC VM MỚI tạo trong lần chạy này
#
# Cách chạy:
#   curl -s https://raw.githubusercontent.com/taieuro/gcp-proxy/main/create-proxy-vms.sh | bash

set -euo pipefail

#######################################
# CẤU HÌNH CÓ THỂ SỬA NHẸ (nếu muốn)
#######################################
VM_NAME_PREFIX="proxy-vm"        # Prefix tên VM: proxy-vm-1, proxy-vm-2, ...

# REGION & ZONE sẽ được chọn bằng menu, nên để trống
REGION=""
ZONE=""

MACHINE_TYPE="e2-micro"          # Loại máy
IMAGE_FAMILY="debian-12"         # Hệ điều hành
IMAGE_PROJECT="debian-cloud"
DISK_SIZE="10GB"
DISK_TYPE="pd-standard"          # New standard persistent disk (New standard persistent disk)

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

#######################################
# BƯỚC 0: MENU CHỌN REGION (1/2/3)
#######################################
echo "=== Chọn location cho proxy ==="
echo "  1) Tokyo, Japan  (asia-northeast1)"
echo "  2) Osaka, Japan  (asia-northeast2)"
echo "  3) Seoul, Korea  (asia-northeast3)"

REGION_CHOICE=""
if [[ -r /dev/tty ]]; then
  printf "Nhập lựa chọn (1/2/3): " > /dev/tty
  read -r REGION_CHOICE < /dev/tty
else
  read -rp "Nhập lựa chọn (1/2/3): " REGION_CHOICE
fi

REGION_LABEL=""
case "$REGION_CHOICE" in
  1)
    REGION="asia-northeast1"
    REGION_LABEL="Tokyo, Japan"
    ;;
  2)
    REGION="asia-northeast2"
    REGION_LABEL="Osaka, Japan"
    ;;
  3)
    REGION="asia-northeast3"
    REGION_LABEL="Seoul, Korea"
    ;;
  *)
    echo "❌ Lựa chọn không hợp lệ. Vui lòng chạy lại và chọn 1, 2 hoặc 3."
    exit 1
    ;;
esac

echo
echo "Bạn đã chọn: $REGION_LABEL ($REGION)"
echo

#######################################
# BƯỚC 0.1: DÒ QUOTA IN_USE_ADDRESSES VÀ ĐẶT NUM_VMS
#######################################
echo "=== Bước 0: Kiểm tra quota IN_USE_ADDRESSES trong region $REGION ==="

NUM_VMS=1  # giá trị mặc định, nếu không đọc được quota

# Lấy limit & usage cho quota IN_USE_ADDRESSES
QUOTA_LINE="$(gcloud compute regions describe "$REGION" \
  --project="$PROJECT" \
  --format='value(quotas[metric=IN_USE_ADDRESSES].limit,quotas[metric=IN_USE_ADDRESSES].usage)' \
  2>/dev/null || echo "")"

if [[ -z "$QUOTA_LINE" ]]; then
  echo "⚠ Không lấy được quota IN_USE_ADDRESSES (có thể do quyền hoặc format)."
  echo "   Tạm dùng NUM_VMS = $NUM_VMS."
else
  # QUOTA_LINE dạng: "4.0 2.0"
  LIMIT=""
  USAGE=""
  read -r LIMIT USAGE <<< "$QUOTA_LINE"

  # Bỏ phần thập phân nếu có (4.0 -> 4)
  LIMIT_INT="${LIMIT%.*}"
  USAGE_INT="${USAGE%.*}"

  if [[ -z "$LIMIT_INT" || -z "$USAGE_INT" ]]; then
    echo "⚠ Không parse được quota IN_USE_ADDRESSES (LIMIT=$LIMIT, USAGE=$USAGE)."
    echo "   Tạm dùng NUM_VMS = $NUM_VMS."
  else
    if (( USAGE_INT >= LIMIT_INT )); then
      echo "❗ Quota IN_USE_ADDRESSES trong region $REGION đã đầy."
      echo "   Limit: $LIMIT_INT, đang dùng: $USAGE_INT, còn lại: 0."
      echo "   Không thể tạo thêm VM với external IP trong region này."
      exit 0
    fi

    REMAINING=$((LIMIT_INT - USAGE_INT))

    echo "Quota IN_USE_ADDRESSES:"
    echo "  - Limit : $LIMIT_INT"
    echo "  - Đang dùng: $USAGE_INT"
    echo "  - Còn lại : $REMAINING (external IP có thể dùng thêm)"

    NUM_VMS=$REMAINING

    echo "=> Sẽ tạo NUM_VMS = $NUM_VMS VM mới trong lần chạy này."
  fi
fi

echo

#######################################
# BƯỚC 0.2: TỰ CHỌN ZONE TRONG REGION
#######################################
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
echo "Region        : $REGION ($REGION_LABEL)"
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
  while IFS= read -r EXISTING_NAME; do
    [[ -z "$EXISTING_NAME" ]] && continue
    IDX="${EXISTING_NAME##*-}"
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

for VM_NAME_LOCAL in "${NEW_VM_NAMES[@]}"; do
  LOG_FILE="/tmp/${VM_NAME_LOCAL}.proxy.log"
  LOG_FILES["$VM_NAME_LOCAL"]="$LOG_FILE"

  echo "▶ Bắt đầu cài proxy trên VM '$VM_NAME_LOCAL' (log: $LOG_FILE)..."

  gcloud compute ssh "$VM_NAME_LOCAL" \
        --zone="$ZONE" \
        --project="$PROJECT" \
        --quiet \
        --command="curl -s $PROXY_INSTALL_URL | sudo bash" \
        >"$LOG_FILE" 2>&1 &

  PIDS["$VM_NAME_LOCAL"]=$!
done

echo
echo "⏳ Đang đợi các VM mới cài proxy xong..."
echo

declare -A PROXIES
FAILED_VMS=()

for VM_NAME_LOCAL in "${NEW_VM_NAMES[@]}"; do
  PID="${PIDS[$VM_NAME_LOCAL]}"
  LOG_FILE="${LOG_FILES[$VM_NAME_LOCAL]}"

  if wait "$PID"; then
    if grep -q "PROXY:" "$LOG_FILE"; then
      PROXY_LINE=$(grep "PROXY:" "$LOG_FILE" | tail -n 1 | sed 's/^.*PROXY:[[:space:]]*//')
      PROXIES["$VM_NAME_LOCAL"]="$PROXY_LINE"
      echo "✅ VM '$VM_NAME_LOCAL' cài proxy thành công."
    else
      FAILED_VMS+=("$VM_NAME_LOCAL")
      echo "⚠ VM '$VM_NAME_LOCAL' KHÔNG tìm thấy dòng PROXY trong log. Kiểm tra: $LOG_FILE"
      echo "---- Tail log $VM_NAME_LOCAL ----"
      tail -n 20 "$LOG_FILE" || true
      echo "----------------------------"
    fi
  else
    FAILED_VMS+=("$VM_NAME_LOCAL")
    echo "⚠ VM '$VM_NAME_LOCAL' cài proxy lỗi. Kiểm tra: $LOG_FILE"
    echo "---- Tail log $VM_NAME_LOCAL ----"
    tail -n 20 "$LOG_FILE" || true
    echo "----------------------------"
  fi
done

echo
echo "================= TỔNG HỢP PROXY MỚI ĐÃ TẠO ================="
for VM_NAME_LOCAL in "${NEW_VM_NAMES[@]}"; do
  if [[ -n "${PROXIES[$VM_NAME_LOCAL]:-}" ]]; then
    echo "$VM_NAME_LOCAL: ${PROXIES[$VM_NAME_LOCAL]}"
  else
    echo "$VM_NAME_LOCAL: (FAILED - xem log: ${LOG_FILES[$VM_NAME_LOCAL]})"
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
