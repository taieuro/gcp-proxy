#!/usr/bin/env bash
# Script tạo Proxy V6 (US Green Edition - Low CO2 & Cheapest)
# Region: Mỹ (Năng lượng sạch).
# Cấu hình: e2-micro (Rẻ nhất).
# Core: Python Parser (V5 Logic) - Đảm bảo đọc đúng Quota 100%.
# Cách chạy:
#   curl -s https://raw.githubusercontent.com/taieuro/gcp-proxy/main/create-proxy-vms-us.sh | bash

set -eo pipefail

#######################################
# CẤU HÌNH CHI PHÍ THẤP NHẤT
#######################################
VM_NAME_PREFIX="us-proxy"      # Đổi tên prefix cho dễ phân biệt
REGION=""
ZONE=""
MACHINE_TYPE="e2-micro"        # Gói rẻ nhất, đủ ổn định cho Proxy
IMAGE_FAMILY="debian-12"       # Debian nhẹ, mượt, không tốn phí OS
IMAGE_PROJECT="debian-cloud"
DISK_SIZE="10GB"               # Size nhỏ nhất cho phép
DISK_TYPE="pd-standard"        # Ổ cứng HDD thường (Rẻ hơn SSD)
NETWORK="default"
TAGS="proxy-vm,http-server,https-server,lb-health-check"
FIREWALL_NAME="gcp-proxy-ports"
PROXY_INSTALL_URL="https://raw.githubusercontent.com/taieuro/gcp-proxy/main/install.sh"

#######################################
# KIỂM TRA PROJECT
#######################################
PROJECT="$(gcloud config get-value project 2>/dev/null || echo)"
if [[ -z "$PROJECT" ]]; then
  echo "❌ Không lấy được project hiện tại. Hãy chạy: gcloud config set project <ID>"
  exit 1
fi

#######################################
# BƯỚC 0: MENU CHỌN REGION (US LOW CO2)
#######################################
cat << 'MENU'
=== Chọn Region Mỹ (Low CO2 & Giá Rẻ) ===
  1) US West 1 (Oregon)
     👉 Năng lượng sạch (Hydro), độ trễ thấp về VN (qua cáp quang biển).
  
  2) US Central 1 (Iowa)
     👉 "Thủ phủ" Google, giá rẻ nhất, thường được Free Tier.
  
  3) US East 4 (Northern Virginia)
     👉 Low CO2, kết nối quốc tế rất tốt.
MENU

REGION_CHOICE=""
if [[ -r /dev/tty ]]; then
  printf "Nhập lựa chọn (1/2/3): " > /dev/tty
  read -r REGION_CHOICE < /dev/tty
else
  read -rp "Nhập lựa chọn (1/2/3): " REGION_CHOICE || true
fi

case "$REGION_CHOICE" in
  1) 
    REGION="us-west1"
    REGION_LABEL="Oregon, USA (Low CO2)" 
    ;;
  2) 
    REGION="us-central1"
    REGION_LABEL="Iowa, USA (Low CO2 + Cheapest)" 
    ;;
  3) 
    REGION="us-east4"
    REGION_LABEL="Virginia, USA (Low CO2)" 
    ;;
  *) 
    echo "❌ Lựa chọn không hợp lệ."; exit 1 
    ;;
esac

printf '\nBạn đã chọn: %s (%s)\n\n' "$REGION_LABEL" "$REGION"

#######################################
# BƯỚC 0.1: DÒ QUOTA (LOGIC V5 - PYTHON)
#######################################
echo "=== Bước 0: Tính toán Quota (Sử dụng Python Parser) ==="

NUM_VMS=0
LIMIT_VAL=""
USAGE_VAL=""

# Lấy dữ liệu JSON
JSON_DATA=$(gcloud compute regions describe "$REGION" --project="$PROJECT" --format="json" --quiet 2>/dev/null || true)

# Python Parser
if [[ -n "$JSON_DATA" ]]; then
  read -r LIMIT_VAL USAGE_VAL <<< $(echo "$JSON_DATA" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    found = False
    for q in data.get('quotas', []):
        if q['metric'] == 'IN_USE_ADDRESSES':
            print(f\"{q['limit']} {q['usage']}\")
            found = True
            break
    if not found:
        print(\"ERROR ERROR\")
except:
    print(\"ERROR ERROR\")
")
fi

if [[ "$LIMIT_VAL" == "ERROR" || -z "$LIMIT_VAL" ]]; then
    echo "⚠ Không đọc được Quota. Chuyển sang chế độ an toàn: Tạo 1 VM."
    NUM_VMS=1
else
    LIMIT_INT="${LIMIT_VAL%.*}"
    USAGE_INT="${USAGE_VAL%.*}"
    REMAINING=$((LIMIT_INT - USAGE_INT))
    
    echo "📊 Thống kê Quota IP ($REGION):"
    echo "   - Giới hạn : $LIMIT_INT"
    echo "   - Đang dùng: $USAGE_INT"
    echo "   - Còn dư   : $REMAINING"
    
    if (( REMAINING <= 0 )); then
        echo "❗ Đã hết Quota (0). Không thể tạo thêm VM tại $REGION."
        exit 0
    fi
    NUM_VMS="$REMAINING"
fi

echo "=> Sẽ tạo thêm: $NUM_VMS VM."
echo

#######################################
# BƯỚC 0.2: TỰ CHỌN ZONE
#######################################
if [[ -z "$ZONE" ]]; then
  ZONE="$(gcloud compute zones list --filter="region:($REGION) AND status=UP" --quiet --format='value(name)' | head -n 1 || true)"
  [[ -z "$ZONE" ]] && echo "❌ Không tìm thấy Zone nào." && exit 1
fi
echo "Zone được chọn: $ZONE"

#######################################
# BƯỚC 1: FIREWALL
#######################################
echo "=== Bước 1: Kiểm tra Firewall Rule ==="
if ! gcloud compute firewall-rules describe "$FIREWALL_NAME" --project="$PROJECT" --quiet >/dev/null 2>&1; then
  echo "⏳ Đang tạo firewall rule..."
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

# Tìm index lớn nhất (Lọc theo prefix mới: us-proxy)
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

echo "⏳ Đang gửi lệnh tạo ${#NEW_VM_NAMES[@]} VM: ${NEW_VM_NAMES[*]} ..."

TMP_ERR="$(mktemp)"
if ! gcloud compute instances create "${NEW_VM_NAMES[@]}" \
    --project="$PROJECT" --zone="$ZONE" --machine-type="$MACHINE_TYPE" \
    --image-family="$IMAGE_FAMILY" --image-project="$IMAGE_PROJECT" \
    --boot-disk-size="$DISK_SIZE" --boot-disk-type="$DISK_TYPE" \
    --network="$NETWORK" --tags="$TAGS" --quiet 2>"$TMP_ERR"; then
  
  cat "$TMP_ERR"
  if grep -q "IN_USE_ADDRESSES" "$TMP_ERR"; then
    echo "❗ Lỗi Quota IP (Hết IP)."
  else
    echo "❌ Lỗi tạo VM."
  fi
  rm -f "$TMP_ERR"
else
  rm -f "$TMP_ERR"
  echo "✅ Đã gửi lệnh tạo xong."
fi

echo
echo "⏳ Đợi 40 giây cho các VM khởi động..."
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
# BƯỚC 4: CÀI PROXY
#######################################
echo "=== Bước 4: Cài đặt Proxy song song ==="
declare -A LOG_FILES
declare -A PIDS

# Lọc VM đang chạy
ACTUAL_RUNNING_VMS=()
for NAME in "${NEW_VM_NAMES[@]}"; do
  STATUS=$(gcloud compute instances describe "$NAME" --zone="$ZONE" --format="value(status)" --quiet 2>/dev/null || true)
  if [[ "$STATUS" == "RUNNING" ]]; then
    ACTUAL_RUNNING_VMS+=("$NAME")
  fi
done

if [[ "${#ACTUAL_RUNNING_VMS[@]}" -eq 0 ]]; then
    echo "❌ Không có VM nào chạy để cài đặt."
    exit 0
fi

for NAME in "${ACTUAL_RUNNING_VMS[@]}"; do
  LOG_FILE="/tmp/${NAME}.proxy.log"
  LOG_FILES["$NAME"]="$LOG_FILE"
  echo "▶ Đang cài trên $NAME (Low CO2 Config)..."

  gcloud compute ssh "$NAME" \
    --zone="$ZONE" --project="$PROJECT" --quiet \
    --ssh-flag="-o StrictHostKeyChecking=no" \
    --ssh-flag="-o UserKnownHostsFile=/dev/null" \
    --command="curl -s $PROXY_INSTALL_URL | sudo bash" \
    >"$LOG_FILE" 2>&1 &
  
  PIDS["$NAME"]=$!
done

echo
echo "⏳ Đang cài đặt..."
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
echo "================= KẾT QUẢ PROXY US ================="
for NAME in "${ACTUAL_RUNNING_VMS[@]}"; do
  if [[ -n "${PROXIES[$NAME]:-}" ]]; then
    echo "$NAME: ${PROXIES[$NAME]}"
  else
    echo "$NAME: FAILED"
  fi
done
echo "===================================================="
