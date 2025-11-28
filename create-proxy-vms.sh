#!/usr/bin/env bash
# Script tạo Proxy V4 (Final Stable)
# Fix lỗi: Thoát đột ngột ở Bước 0 do lỗi parsing dữ liệu.
# Tính năng: Tự động tính Max Quota, bỏ qua xác thực SSH, chạy song song.

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

# Mặc định tạo 4 VM nếu không dò được Quota (Con số an toàn cho Free Tier)
DEFAULT_NUM_VMS=4 

#######################################
# KIỂM TRA PROJECT
#######################################
PROJECT="$(gcloud config get-value project 2>/dev/null || echo)"
if [[ -z "$PROJECT" ]]; then
  echo "❌ Không lấy được project hiện tại. Hãy chạy: gcloud config set project <ID>"
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
if [[ -r /dev/tty ]]; then
  printf "Nhập lựa chọn (1/2/3): " > /dev/tty
  read -r REGION_CHOICE < /dev/tty
else
  read -rp "Nhập lựa chọn (1/2/3): " REGION_CHOICE || true
fi

case "$REGION_CHOICE" in
  1) REGION="asia-northeast1"; REGION_LABEL="Tokyo, Japan" ;;
  2) REGION="asia-northeast2"; REGION_LABEL="Osaka, Japan" ;;
  3) REGION="asia-northeast3"; REGION_LABEL="Seoul, Korea" ;;
  *) echo "❌ Lựa chọn không hợp lệ."; exit 1 ;;
esac

printf '\nBạn đã chọn: %s (%s)\n\n' "$REGION_LABEL" "$REGION"

#######################################
# BƯỚC 0.1: DÒ QUOTA (SAFE MODE)
#######################################
echo "=== Bước 0: Tính toán số lượng VM tối đa (Quota Check) ==="

NUM_VMS=0

# Lấy trực tiếp Limit và Usage bằng filter của gcloud (tránh dùng grep gây lỗi script)
# Thêm || true để dù lỗi cũng không làm crash script
LIMIT_RAW="$(gcloud compute regions describe "$REGION" --project="$PROJECT" --format="value(quotas[metric='IN_USE_ADDRESSES'].limit)" --quiet 2>/dev/null || true)"
USAGE_RAW="$(gcloud compute regions describe "$REGION" --project="$PROJECT" --format="value(quotas[metric='IN_USE_ADDRESSES'].usage)" --quiet 2>/dev/null || true)"

# Chuyển về số nguyên (loại bỏ .0 nếu có)
LIMIT_INT="${LIMIT_RAW%.*}"
USAGE_INT="${USAGE_RAW%.*}"

if [[ -n "$LIMIT_INT" && -n "$USAGE_INT" ]]; then
    REMAINING=$((LIMIT_INT - USAGE_INT))
    echo "📊 Thống kê Quota IP External:"
    echo "   - Giới hạn (Limit): $LIMIT_INT"
    echo "   - Đang dùng (Used): $USAGE_INT"
    echo "   - Còn dư (Free)   : $REMAINING"
    
    if (( REMAINING <= 0 )); then
        echo "❗ Đã hết sạch Quota IP (0). Không thể tạo thêm VM."
        exit 0
    fi
    NUM_VMS="$REMAINING"
else
    # Fallback: Nếu không lấy được quota, dùng mặc định
    echo "⚠ Không đọc được Quota (do quyền hạn hoặc lỗi API)."
    echo "👉 Chuyển sang chế độ mặc định: Sẽ tạo $DEFAULT_NUM_VMS VM."
    NUM_VMS=$DEFAULT_NUM_VMS
fi

echo "=> Sẽ tiến hành tạo đồng loạt: $NUM_VMS VM."
echo

#######################################
# BƯỚC 0.2: TỰ CHỌN ZONE
#######################################
if [[ -z "$ZONE" ]]; then
  ZONE="$(gcloud compute zones list --filter="region:($REGION) AND status=UP" --quiet --format='value(name)' | head -n 1 || true)"
  [[ -z "$ZONE" ]] && echo "❌ Không tìm thấy Zone nào trong region $REGION." && exit 1
fi
echo "Zone được chọn: $ZONE"

#######################################
# BƯỚC 1: FIREWALL
#######################################
echo "=== Bước 1: Kiểm tra Firewall Rule ==="
if ! gcloud compute firewall-rules describe "$FIREWALL_NAME" --project="$PROJECT" --quiet >/dev/null 2>&1; then
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
echo "=== Bước 2: Khởi tạo các VM mới ==="

# Tìm index lớn nhất hiện tại
EXISTING_NAMES="$(gcloud compute instances list --project="$PROJECT" --filter="zone:($ZONE) AND name ~ ^${VM_NAME_PREFIX}-[0-9]+$" --format='value(name)' --quiet || true)"
MAX_INDEX=0
if [[ -n "$EXISTING_NAMES" ]]; then
  while IFS= read -r E_NAME; do
    [[ -z "$E_NAME" ]] && continue
    IDX="${E_NAME##*-}"
    [[ "$IDX" =~ ^[0-9]+$ ]] && (( IDX > MAX_INDEX )) && MAX_INDEX=$IDX
  done <<< "$EXISTING_NAMES"
fi

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

echo "⏳ Đang gửi lệnh tạo ${#NEW_VM_NAMES[@]} VM cùng lúc: ${NEW_VM_NAMES[*]} ..."
echo "   (Quá trình này có thể mất 1-2 phút, vui lòng đợi)"

TMP_ERR="$(mktemp)"
if ! gcloud compute instances create "${NEW_VM_NAMES[@]}" \
    --project="$PROJECT" --zone="$ZONE" --machine-type="$MACHINE_TYPE" \
    --image-family="$IMAGE_FAMILY" --image-project="$IMAGE_PROJECT" \
    --boot-disk-size="$DISK_SIZE" --boot-disk-type="$DISK_TYPE" \
    --network="$NETWORK" --tags="$TAGS" --quiet 2>"$TMP_ERR"; then
  
  cat "$TMP_ERR"
  if grep -q "IN_USE_ADDRESSES" "$TMP_ERR"; then
    echo
    echo "❗ Lỗi Quota từ Google Cloud (Hết IP)!"
    echo "   Các VM đã kịp tạo trước khi lỗi vẫn sẽ hoạt động."
  else
    echo "❌ Có lỗi xảy ra khi tạo VM (nhưng không dừng script, sẽ thử cài proxy cho các VM đã tạo được)."
  fi
  rm -f "$TMP_ERR"
else
  rm -f "$TMP_ERR"
  echo "✅ Đã gửi lệnh tạo xong."
fi

echo
echo "⏳ Đợi 40 giây cho các VM khởi động dịch vụ..."
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
else
  echo "✅ SSH key đã có sẵn."
fi

#######################################
# BƯỚC 4: CÀI PROXY (SSH FIX)
#######################################
echo "=== Bước 4: Cài đặt Proxy song song ==="
declare -A LOG_FILES
declare -A PIDS

# Lọc lại danh sách VM thực tế đang chạy
ACTUAL_RUNNING_VMS=()
for NAME in "${NEW_VM_NAMES[@]}"; do
  # Kiểm tra nhanh xem VM có tồn tại và đang chạy không
  STATUS=$(gcloud compute instances describe "$NAME" --zone="$ZONE" --format="value(status)" --quiet 2>/dev/null || true)
  if [[ "$STATUS" == "RUNNING" ]]; then
    ACTUAL_RUNNING_VMS+=("$NAME")
  fi
done

if [[ "${#ACTUAL_RUNNING_VMS[@]}" -eq 0 ]]; then
    echo "❌ Không có VM nào ở trạng thái RUNNING để cài đặt."
    echo "   (Có thể do lỗi Quota nên không VM nào được tạo thành công)"
    exit 0
fi

for NAME in "${ACTUAL_RUNNING_VMS[@]}"; do
  LOG_FILE="/tmp/${NAME}.proxy.log"
  LOG_FILES["$NAME"]="$LOG_FILE"
  echo "▶ Đang cài trên $NAME (log: $LOG_FILE)..."

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
echo "⏳ Đang chạy script cài đặt trên ${#ACTUAL_RUNNING_VMS[@]} VM..."
declare -A PROXIES
FAILED_VMS=()

for NAME in "${ACTUAL_RUNNING_VMS[@]}"; do
  wait "${PIDS[$NAME]}"
  LOG_FILE="${LOG_FILES[$NAME]}"
  
  if grep -q "PROXY:" "$LOG_FILE"; then
    PROXY_LINE="$(grep 'PROXY:' "$LOG_FILE" | tail -n 1 | sed 's/^.*PROXY:[[:space:]]*//')"
    PROXIES["$NAME"]="$PROXY_LINE"
    echo "✅ $NAME: Thành công."
  else
    FAILED_VMS+=("$NAME")
    echo "❌ $NAME: Thất bại (Xem log: $LOG_FILE)"
  fi
done

echo
echo "================= KẾT QUẢ PROXY ================="
for NAME in "${ACTUAL_RUNNING_VMS[@]}"; do
  if [[ -n "${PROXIES[$NAME]:-}" ]]; then
    echo "$NAME: ${PROXIES[$NAME]}"
  else
    echo "$NAME: FAILED"
  fi
done
echo "================================================="
