#!/usr/bin/env bash
# Script Quản Lý Proxy V9 (Final Fix: Interactive Mode)
# Fix lỗi: Tự động thoát khi chạy lệnh curl | bash.
# Cơ chế: Buộc đọc input từ /dev/tty.
# Cách chạy:
#   curl -s https://raw.githubusercontent.com/taieuro/gcp-proxy/main/create-proxy-manager.sh | bash

set -eo pipefail

#######################################
# CẤU HÌNH
#######################################
MACHINE_TYPE="e2-micro"
IMAGE_FAMILY="debian-12"
IMAGE_PROJECT="debian-cloud"
DISK_SIZE="10GB"
DISK_TYPE="pd-standard"
NETWORK="default"
TAGS="proxy-vm,http-server,https-server,lb-health-check"
FIREWALL_NAME="gcp-proxy-ports"
PROXY_INSTALL_URL="https://raw.githubusercontent.com/taieuro/gcp-proxy/main/install.sh"

# Màu sắc
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

#######################################
# HÀM HỖ TRỢ NHẬP LIỆU (QUAN TRỌNG)
#######################################
# Hàm này đảm bảo script đọc được phím bấm kể cả khi chạy qua curl | bash
get_input() {
  local prompt="$1"
  local var_name="$2"
  if [[ -r /dev/tty ]]; then
    read -rp "$prompt" "$var_name" < /dev/tty
  else
    echo -e "${RED}❌ Lỗi: Không tìm thấy thiết bị TTY. Không thể chạy tương tác.${NC}"
    exit 1
  fi
}

pause_screen() {
  echo
  if [[ -r /dev/tty ]]; then
    read -rp "Ấn Enter để tiếp tục..." < /dev/tty
  fi
}

#######################################
# CHECK PROJECT
#######################################
check_project() {
  PROJECT="$(gcloud config get-value project 2>/dev/null || echo)"
  if [[ -z "$PROJECT" ]]; then
    echo -e "${RED}❌ Không lấy được project hiện tại.${NC}"
    echo "   Hãy chạy: gcloud config set project <ID>"
    exit 1
  fi
}

#######################################
# CHỨC NĂNG: SCAN
#######################################
scan_proxies() {
  clear
  echo -e "${BLUE}=== DANH SÁCH PROXY ĐANG CHẠY ===${NC}"
  echo "Đang quét toàn bộ Project..."
  echo

  LIST_OUTPUT=$(gcloud compute instances list \
    --project="$PROJECT" \
    --filter="name ~ '^(proxy-vm|us-proxy)-[0-9]+$'" \
    --sort-by=name \
    --format="table[box](name,zone.basename(),networkInterfaces[0].accessConfigs[0].natIP:label=EXTERNAL_IP,status)")

  if [[ -z "$LIST_OUTPUT" ]]; then
    echo -e "${YELLOW}⚠ Không tìm thấy Proxy VM nào.${NC}"
  else
    echo -e "${GREEN}✅ Kết quả:${NC}"
    echo "$LIST_OUTPUT"
  fi
  
  pause_screen
}

#######################################
# CHỨC NĂNG: TẠO PROXY
#######################################
create_proxy_menu() {
  clear
  echo -e "${BLUE}=== TẠO PROXY MỚI ===${NC}"
  cat << 'SUBMENU'
--- CHÂU Á (Ping tốt) ---
  1) Tokyo, Japan
  2) Osaka, Japan
  3) Seoul, Korea

--- MỸ (Giá rẻ & Xanh) ---
  4) Oregon (US West)
  5) Iowa (US Central) [RẺ NHẤT]
  6) Virginia (US East)

  0) Quay lại
SUBMENU

  get_input "Nhập lựa chọn (0-6): " REGION_CHOICE

  VM_NAME_PREFIX="proxy-vm"
  case "$REGION_CHOICE" in
    1) REGION="asia-northeast1"; REGION_LABEL="Tokyo" ;;
    2) REGION="asia-northeast2"; REGION_LABEL="Osaka" ;;
    3) REGION="asia-northeast3"; REGION_LABEL="Seoul" ;;
    4) REGION="us-west1";    REGION_LABEL="Oregon"; VM_NAME_PREFIX="us-proxy" ;;
    5) REGION="us-central1"; REGION_LABEL="Iowa";   VM_NAME_PREFIX="us-proxy" ;;
    6) REGION="us-east4";    REGION_LABEL="Virginia"; VM_NAME_PREFIX="us-proxy" ;;
    0) return ;;
    *) echo -e "${RED}Sai lựa chọn.${NC}"; sleep 1; return ;;
  esac

  echo -e "\nBạn chọn: ${GREEN}$REGION_LABEL${NC}"

  # --- Check Quota ---
  echo "⏳ Check Quota..."
  JSON_DATA=$(gcloud compute regions describe "$REGION" --project="$PROJECT" --format="json" --quiet 2>/dev/null || true)
  
  NUM_VMS=1 # Mặc định an toàn
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

  if [[ "$LIMIT_VAL" != "ERROR" && -n "$LIMIT_VAL" ]]; then
      LIMIT_INT="${LIMIT_VAL%.*}"
      USAGE_INT="${USAGE_VAL%.*}"
      REMAINING=$((LIMIT_INT - USAGE_INT))
      
      echo -e "📊 Quota: Limit=${YELLOW}$LIMIT_INT${NC}, Used=${YELLOW}$USAGE_INT${NC}, Free=${GREEN}$REMAINING${NC}"
      
      if (( REMAINING <= 0 )); then
          echo -e "${RED}❗ Hết Quota ở Region này.${NC}"
          pause_screen
          return
      fi
      NUM_VMS="$REMAINING"
  fi
  
  echo "=> Sẽ tạo: $NUM_VMS VM."

  # --- Get Zone ---
  ZONE="$(gcloud compute zones list --filter="region:($REGION) AND status=UP" --quiet --format='value(name)' | head -n 1 || true)"
  [[ -z "$ZONE" ]] && echo "❌ Không tìm thấy Zone." && return

  # --- Firewall ---
  if ! gcloud compute firewall-rules describe "$FIREWALL_NAME" --project="$PROJECT" --quiet >/dev/null 2>&1; then
    echo "⏳ Tạo Firewall..."
    gcloud compute firewall-rules create "$FIREWALL_NAME" --project="$PROJECT" --network="$NETWORK" --direction=INGRESS --priority=1000 --action=ALLOW --rules=tcp:20000-60000 --source-ranges=0.0.0.0/0 --target-tags="proxy-vm" --quiet
  fi

  # --- Names ---
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
  for ((i=START_INDEX; i<=END_INDEX; i++)); do NEW_VM_NAMES+=("${VM_NAME_PREFIX}-${i}"); done

  # --- Create VM ---
  echo -e "🚀 Tạo VM: ${GREEN}${NEW_VM_NAMES[*]}${NC} ..."
  TMP_ERR="$(mktemp)"
  if ! gcloud compute instances create "${NEW_VM_NAMES[@]}" \
      --project="$PROJECT" --zone="$ZONE" --machine-type="$MACHINE_TYPE" \
      --image-family="$IMAGE_FAMILY" --image-project="$IMAGE_PROJECT" \
      --boot-disk-size="$DISK_SIZE" --boot-disk-type="$DISK_TYPE" \
      --network="$NETWORK" --tags="$TAGS" --quiet 2>"$TMP_ERR"; then
    if grep -q "IN_USE_ADDRESSES" "$TMP_ERR"; then
      echo -e "${YELLOW}⚠ Google chặn IP mới (Lỗi Quota).${NC}"
    else
      echo -e "${RED}❌ Lỗi tạo VM.${NC}"
    fi
  else
    echo -e "${GREEN}✅ Tạo VM xong.${NC}"
  fi
  rm -f "$TMP_ERR"

  echo "⏳ Đợi 40s..."
  sleep 40

  # --- SSH & Install ---
  if [[ ! -f "$HOME/.ssh/google_compute_engine" ]]; then
    mkdir -p "$HOME/.ssh"
    ssh-keygen -t rsa -f "$HOME/.ssh/google_compute_engine" -N "" -q
  fi
  
  ACTUAL_RUNNING_VMS=()
  for NAME in "${NEW_VM_NAMES[@]}"; do
    STATUS=$(gcloud compute instances describe "$NAME" --zone="$ZONE" --format="value(status)" --quiet 2>/dev/null || true)
    [[ "$STATUS" == "RUNNING" ]] && ACTUAL_RUNNING_VMS+=("$NAME")
  done

  if [[ "${#ACTUAL_RUNNING_VMS[@]}" -gt 0 ]]; then
    echo "📦 Cài Proxy..."
    declare -A LOG_FILES
    declare -A PIDS
    
    for NAME in "${ACTUAL_RUNNING_VMS[@]}"; do
      LOG_FILE="/tmp/${NAME}.proxy.log"
      LOG_FILES["$NAME"]="$LOG_FILE"
      gcloud compute ssh "$NAME" --zone="$ZONE" --project="$PROJECT" --quiet \
        --ssh-flag="-o StrictHostKeyChecking=no" --ssh-flag="-o UserKnownHostsFile=/dev/null" \
        --command="curl -s $PROXY_INSTALL_URL | sudo bash" >"$LOG_FILE" 2>&1 &
      PIDS["$NAME"]=$!
    done

    declare -A PROXIES
    for NAME in "${ACTUAL_RUNNING_VMS[@]}"; do
      wait "${PIDS[$NAME]}"
      LOG_FILE="${LOG_FILES[$NAME]}"
      if grep -q "PROXY:" "$LOG_FILE"; then
        PROXIES["$NAME"]="$(grep 'PROXY:' "$LOG_FILE" | tail -n 1 | sed 's/^.*PROXY:[[:space:]]*//')"
      fi
    done

    echo
    echo -e "${GREEN}=== KẾT QUẢ MỚI ===${NC}"
    for NAME in "${ACTUAL_RUNNING_VMS[@]}"; do
      if [[ -n "${PROXIES[$NAME]:-}" ]]; then
        echo -e "$NAME: ${GREEN}${PROXIES[$NAME]}${NC}"
      else
        echo -e "$NAME: ${RED}FAILED${NC}"
      fi
    done
  fi
  
  pause_screen
}

#######################################
# MAIN LOOP
#######################################
check_project

while true; do
  clear
  echo -e "${BLUE}========================================${NC}"
  echo -e "${BLUE}    GOOGLE CLOUD PROXY MANAGER (V9)     ${NC}"
  echo -e "${BLUE}========================================${NC}"
  echo "1. 🚀 Tạo Proxy Mới"
  echo "2. 🔎 Xem danh sách Proxy (Scan)"
  echo "3. 🚪 Thoát"
  echo
  
  # Dùng hàm get_input đặc biệt để fix lỗi curl pipe
  get_input "Chọn chức năng (1-3): " CHOICE

  case "$CHOICE" in
    1) create_proxy_menu ;;
    2) scan_proxies ;;
    3) echo "Bye!"; exit 0 ;;
    *) echo "Sai rồi."; sleep 1 ;;
  esac
done
