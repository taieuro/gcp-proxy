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

set -eo pipefail

#######################################
# CẤU HÌNH
#######################################
VM_NAME_PREFIX="proxy-vm"
REGION=""
ZONE=""
MACHINE_TYPE="e2-micro"
IMAGE_FAMILY="debian-12"
IMAGE_PROJECT="debian-cloud"
DISK_SIZE="10GB"
DISK_TYPE="pd-standard"
NETWORK="default"
TAGS="proxy-vm,http-server,https-server,lb-health-check"
FIREWALL_NAME="gcp-proxy-ports"
PROXY_INSTALL_URL="https://raw.githubusercontent.com/taieuro/gcp-proxy/main/install.sh"

#######################################
# KIỂM TRA PROJECT
#######################################
PROJECT="$(gcloud config get-value project 2>/dev/null || echo)"
if [[ -z "$PROJECT" ]]; then
  echo "❌ Không lấy được project hiện tại."
  echo "   Hãy chạy: gcloud config set project <PROJECT_ID>"
  exit 1
fi

#######################################
# BƯỚC 0: MENU CHỌN REGION
#######################################
cat << 'MENU'
=== Chọn location cho proxy ===
  1) Tokyo, Japan  (asia-northeast1)
  2) Osaka, Japan  (asia-northeast2)
  3) Seoul, Korea  (asia-northeast3)
MENU

REGION_CHOICE=""

# Xử lý input khi chạy qua curl | bash
if [[ -r /dev/tty ]]; then
  printf "Nhập lựa chọn (1/2/3): " > /dev/tty
  read -r REGION_CHOICE < /dev/tty
else
  # Fallback nếu không tìm thấy TTY, nhưng thường sẽ fail nếu pipe
  echo "⚠ Không tìm thấy thiết bị nhập liệu (TTY). Đang chạy chế độ không tương tác?"
  read -rp "Nhập lựa chọn (1/2/3): " REGION_CHOICE || true
fi

case "$REGION_CHOICE" in
  1) REGION="asia-northeast1"; REGION_LABEL="Tokyo, Japan" ;;
  2) REGION="asia-northeast2"; REGION_LABEL="Osaka, Japan" ;;
  3) REGION="asia-northeast3"; REGION_LABEL="Seoul, Korea" ;;
  *) echo "❌ Lựa chọn không hợp lệ. Vui lòng chạy lại."; exit 1 ;;
esac

printf '\nBạn đã chọn: %s (%s)\n\n' "$REGION_LABEL" "$REGION"

#######################################
# BƯỚC 0.1: DÒ QUOTA
#######################################
echo "=== Bước 0: Kiểm tra quota IN_USE_ADDRESSES ==="

NUM_VMS=1
QUOTA_LINE="$(gcloud compute regions describe "$REGION" \
  --project="$PROJECT" \
  --format='value(quotas[metric=IN_USE_ADDRESSES].limit,quotas[metric=IN_USE_ADDRESSES].usage)' \
  2>/dev/null || true)"

if [[ -n "$QUOTA_LINE" ]]; then
  # Đọc Limit và Usage, loại bỏ phần thập phân nếu có
  read -r LIMIT USAGE <<< "$QUOTA_LINE"
  LIMIT_INT="${LIMIT%.*}"
  USAGE_INT="${USAGE%.*}"

  if [[ -n "$LIMIT_INT" && -n "$USAGE_INT" ]]; then
    REMAINING=$((LIMIT_INT - USAGE_INT))
    echo "Quota IP External: Limit=$LIMIT_INT, Used=$USAGE_INT, Free=$REMAINING"
    
    if (( REMAINING <= 0 )); then
      echo "❗ Đã hết Quota IP External trong region này. Không thể tạo thêm VM."
      exit 0
    fi
    NUM_VMS="$REMAINING"
    echo "=> Sẽ tạo $NUM_VMS VM mới."
  fi
else
  echo "⚠ Không lấy được quota, mặc định tạo 1 VM."
fi
echo

#######################################
# BƯỚC 0.2: TỰ CHỌN ZONE
#######################################
if [[ -z "$ZONE" ]]; then
  ZONE="$(gcloud compute zones list --filter="region:($REGION) AND status=UP" --format='value(name)' | head -n 1 || true)"
  [[ -z "$ZONE" ]] && echo "❌ Không tìm thấy Zone nào." && exit 1
fi
echo "Zone được chọn: $ZONE"

#######################################
# BƯỚC 1: FIREWALL
#######################################
echo "=== Bước 1: Kiểm tra Firewall Rule ==="
if ! gcloud compute firewall-rules describe "$FIREWALL_NAME" --project="$PROJECT" >/dev/null 2>&1; then
  echo "⏳ Đang tạo firewall rule '$FIREWALL_NAME'..."
  gcloud compute firewall-rules create "$FIREWALL_NAME" \
    --project="$PROJECT" --network="$NETWORK" --direction=INGRESS --priority=1000 \
    --action=ALLOW --rules=tcp:20000-60000 --source-ranges=0.0.0.0/0 --target-tags="proxy-vm" --quiet
  echo "✅ Đã tạo firewall."
else
  echo "✅ Firewall đã tồn tại."
fi
echo

#######################################
# BƯỚC 2: TẠO VM MỚI
#######################################
echo "=== Bước 2: Tạo các VM mới ==="

# Tìm index lớn nhất hiện tại
EXISTING_NAMES="$(gcloud compute instances list --project="$PROJECT" --filter="zone:($ZONE) AND name ~ ^${VM_NAME_PREFIX}-[0-9]+$" --format='value(name)' || true)"
MAX_INDEX=0
while IFS= read -r E_NAME; do
  [[ -z "$E_NAME" ]] && continue
  IDX="${E_NAME##*-}"
  [[ "$IDX" =~ ^[0-9]+$ ]] && (( IDX > MAX_INDEX )) && MAX_INDEX=$IDX
done <<< "$EXISTING_NAMES"

START_INDEX=$((MAX_INDEX + 1))
END_INDEX=$((MAX_INDEX + NUM_VMS))

NEW_VM_NAMES=()
for ((i=START_INDEX; i<=END_INDEX; i++)); do
  NEW_VM_NAMES+=("${VM_NAME_PREFIX}-${i}")
done

if [[ "${#NEW_VM_NAMES[@]}" -eq 0 ]]; then
  echo "⚠ Không có VM cần tạo."
  exit 0
fi

echo "⏳ Đang tạo VM: ${NEW_VM_NAMES[*]} ..."
TMP_ERR="$(mktemp)"
if ! gcloud compute instances create "${NEW_VM_NAMES[@]}" \
    --project="$PROJECT" --zone="$ZONE" --machine-type="$MACHINE_TYPE" \
    --image-family="$IMAGE_FAMILY" --image-project="$IMAGE_PROJECT" \
    --boot-disk-size="$DISK_SIZE" --boot-disk-type="$DISK_TYPE" \
    --network="$NETWORK" --tags="$TAGS" --quiet 2>"$TMP_ERR"; then
  
  cat "$TMP_ERR"
  if grep -q "IN_USE_ADDRESSES" "$TMP_ERR"; then
    echo "❗ Lỗi Quota IP. Dừng script."
    rm -f "$TMP_ERR"
    exit 0
  fi
  rm -f "$TMP_ERR"
  exit 1
fi
rm -f "$TMP_ERR"
echo "✅ Tạo VM thành công."

echo
echo "⏳ Đợi 40 giây cho VM khởi động hoàn tất..."
sleep 40 
echo

#######################################
# BƯỚC 3: SSH KEY
#######################################
echo "=== Bước 3: Cấu hình SSH ==="
if [[ ! -f "$HOME/.ssh/google_compute_engine" ]]; then
  mkdir -p "$HOME/.ssh"
  ssh-keygen -t rsa -f "$HOME/.ssh/google_compute_engine" -N "" -q
  echo "✅ Đã tạo SSH key."
fi

#######################################
# BƯỚC 4: CÀI PROXY (SSH FIX)
#######################################
echo "=== Bước 4: Cài đặt Proxy song song ==="
declare -A LOG_FILES
declare -A PIDS

for NAME in "${NEW_VM_NAMES[@]}"; do
  LOG_FILE="/tmp/${NAME}.proxy.log"
  LOG_FILES["$NAME"]="$LOG_FILE"
  echo "▶ Đang cài trên $NAME (log: $LOG_FILE)..."

  # FIX QUAN TRỌNG: Thêm StrictHostKeyChecking=no để không bị hỏi yes/no
  gcloud compute ssh "$NAME" \
    --zone="$ZONE" \
    --project="$PROJECT" \
    --quiet \
    --ssh-flag="-o StrictHostKeyChecking=no" \
    --ssh-flag="-o UserKnownHostsFile=/dev/null" \
    --command="curl -s $PROXY_INSTALL_URL | sudo bash" \
    >"$LOG_FILE" 2>&1 &
  
  PIDS["$NAME"]=$!
done

echo
echo "⏳ Đang đợi tiến trình cài đặt..."
declare -A PROXIES
FAILED_VMS=()

for NAME in "${NEW_VM_NAMES[@]}"; do
  wait "${PIDS[$NAME]}"
  LOG_FILE="${LOG_FILES[$NAME]}"
  
  if grep -q "PROXY:" "$LOG_FILE"; then
    PROXY_LINE="$(grep 'PROXY:' "$LOG_FILE" | tail -n 1 | sed 's/^.*PROXY:[[:space:]]*//')"
    PROXIES["$NAME"]="$PROXY_LINE"
    echo "✅ $NAME: Xong."
  else
    FAILED_VMS+=("$NAME")
    echo "❌ $NAME: Lỗi (Xem log: $LOG_FILE)"
  fi
done

echo
echo "================= KẾT QUẢ ================="
for NAME in "${NEW_VM_NAMES[@]}"; do
  if [[ -n "${PROXIES[$NAME]:-}" ]]; then
    echo "$NAME: ${PROXIES[$NAME]}"
  else
    echo "$NAME: FAILED"
  fi
done
echo "==========================================="
