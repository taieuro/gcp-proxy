#!/usr/bin/env bash
# Script Quản Lý Proxy V8 (Manager Edition)
# Tính năng mới: Menu chính, Scan tìm toàn bộ Proxy đã tạo, Hiển thị bảng IP.
# Core: V7 Logic (Python Parser + US Low Cost).
# Cách chạy:
#   curl -s https://raw.githubusercontent.com/taieuro/gcp-proxy/main/create-proxy-v8-manager.sh | bash

set -eo pipefail

#######################################
# CẤU HÌNH CƠ BẢN
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

# Màu sắc cho đẹp
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

#######################################
# HÀM: KIỂM TRA PROJECT
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
# HÀM: SCAN VÀ LIỆT KÊ PROXY
#######################################
scan_proxies() {
  clear
  echo -e "${BLUE}=== ĐANG QUÉT HỆ THỐNG TÌM PROXY VM... ===${NC}"
  echo "Đang tìm các VM có tên bắt đầu bằng 'proxy-vm' hoặc 'us-proxy'..."
  echo

  # Lấy danh sách VM khớp filter
  # Filter: Name chứa proxy-vm HOẶC us-proxy
  LIST_OUTPUT=$(gcloud compute instances list \
    --project="$PROJECT" \
    --filter="name ~ '^(proxy-vm|us-proxy)-[0-9]+$'" \
    --sort-by=name \
    --format="table[box](name,zone.basename(),networkInterfaces[0].accessConfigs[0].natIP:label=EXTERNAL_IP,status)")

  if [[ -z "$LIST_OUTPUT" ]]; then
    echo -e "${YELLOW}⚠ Không tìm thấy Proxy VM nào trong Project này.${NC}"
  else
    echo -e "${GREEN}✅ Đã tìm thấy các Proxy sau:${NC}"
    echo "$LIST_OUTPUT"
    echo
    echo -e "${YELLOW}💡 Gợi ý:${NC} Copy cột 'EXTERNAL_IP' để sử dụng."
  fi
  
  echo
  read -rp "Ấn Enter để quay lại Menu chính..."
}

#######################################
# HÀM: TẠO PROXY (LOGIC V7)
#######################################
create_proxy_menu() {
  clear
  echo -e "${BLUE}=== TẠO PROXY MỚI ===${NC}"
  cat << 'SUBMENU'
--- KHU VỰC CHÂU Á (Tốc độ cao) ---
  1) Tokyo, Japan (asia-northeast1)
  2) Osaka, Japan (asia-northeast2)
  3) Seoul, Korea (asia-northeast3)

--- KHU VỰC MỸ (Giá rẻ & Xanh) ---
  4) Oregon, US West (us-west1)    [Low CO2]
  5) Iowa, US Central (us-central1) [RẺ NHẤT]
  6) Virginia, US East (us-east4)

  0) Quay lại
SUBMENU

  read -rp "Nhập lựa chọn (0-6): " REGION_CHOICE || true

  VM_NAME_PREFIX="proxy-vm"
  case "$REGION_CHOICE" in
    1) REGION="asia-northeast1"; REGION_LABEL="Tokyo, Japan" ;;
    2) REGION="asia-northeast2"; REGION_LABEL="Osaka, Japan" ;;
    3) REGION="asia-northeast3"; REGION_LABEL="Seoul, Korea" ;;
    4) REGION="us-west1";    REGION_LABEL="Oregon, US West";    VM_NAME_PREFIX="us-proxy" ;;
    5) REGION="us-central1"; REGION_LABEL="Iowa, US Central";   VM_NAME_PREFIX="us-proxy" ;;
    6) REGION="us-east4";    REGION_LABEL="Virginia, US East";  VM_NAME_PREFIX="us-proxy" ;;
    0) return ;;
    *) echo -e "${RED}Lựa chọn không hợp lệ.${NC}"; sleep 1; return ;;
  esac

  # --- BẮT ĐẦU LOGIC TẠO VM ---
  printf "\nBạn đã chọn: ${GREEN}%s (%s)${NC}\n" "$REGION_LABEL" "$REGION"

  # 1. Dò Quota (Python)
  echo "⏳ Đang tính toán Quota IP..."
  JSON_DATA=$(gcloud compute regions describe "$REGION" --project="$PROJECT" --format="json" --quiet 2>/dev/null || true)
  
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
      echo -e "${YELLOW}⚠ Không đọc được Quota. Chế độ an toàn: Tạo 1 VM.${NC}"
      NUM_VMS=1
  else
      LIMIT_INT="${LIMIT_VAL%.*}"
      USAGE_INT="${USAGE_VAL%.*}"
      REMAINING=$((LIMIT_INT - USAGE_INT))
      
      echo -e "📊 Quota tại $REGION: Limit=${YELLOW}$LIMIT_INT${NC}, Used=${YELLOW}$USAGE_INT${NC}, Free=${GREEN}$REMAINING${NC}"
      
      if (( REMAINING <= 0 )); then
          echo -e "${RED}❗ Đã hết Quota tại Region này. Vui lòng chọn Region khác.${NC}"
          read -rp "Ấn Enter để quay lại..."
          return
      fi
      NUM_VMS="$REMAINING"
  fi
  
  echo "=> Sẽ tạo thêm: $NUM_VMS VM."

  # 2. Chọn Zone
  ZONE="$(gcloud compute zones list --filter="region:($REGION) AND status=UP" --quiet --format='value(name)' | head -n 1 || true)"
  [[ -z "$ZONE" ]] && echo -e "${RED}❌ Không tìm thấy Zone.${NC}" && return

  # 3. Firewall
  if ! gcloud compute firewall-rules describe "$FIREWALL_NAME" --project="$PROJECT" --quiet >/dev/null 2>&1; then
    echo "⏳ Đang tạo Firewall..."
    gcloud compute firewall-rules create "$FIREWALL_NAME" --project="$PROJECT" --network="$NETWORK" --direction=INGRESS --priority=1000 --action=ALLOW --rules=tcp:20000-60000 --source-ranges=0.0.0.0/0 --target-tags="proxy-vm" --quiet
  fi

  # 4. Tìm tên VM
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

  # 5. Tạo VM
  echo -e "🚀 Đang khởi tạo ${GREEN}${NEW_VM_NAMES[*]}${NC} ..."
  TMP_ERR="$(mktemp)"
  if ! gcloud compute instances create "${NEW_VM_NAMES[@]}" \
      --project="$PROJECT" --zone="$ZONE" --machine-type="$MACHINE_TYPE" \
      --image-family="$IMAGE_FAMILY" --image-project="$IMAGE_PROJECT" \
      --boot-disk-size="$DISK_SIZE" --boot-disk-type="$DISK_TYPE" \
      --network="$NETWORK" --tags="$TAGS" --quiet 2>"$TMP_ERR"; then
    if grep -q "IN_USE_ADDRESSES" "$TMP_ERR"; then
      echo -e "${YELLOW}⚠ Google chặn tạo thêm do hết IP. (Các VM đã tạo thành công vẫn OK)${NC}"
    else
      echo -e "${RED}❌ Lỗi tạo VM.${NC}"
    fi
  else
    echo -e "${GREEN}✅ Đã tạo VM thành công.${NC}"
  fi
  rm -f "$TMP_ERR"

  echo "⏳ Đợi 40s khởi động..."
  sleep 40

  # 6. SSH & Cài Proxy
  check_ssh_key
  
  ACTUAL_RUNNING_VMS=()
  for NAME in "${NEW_VM_NAMES[@]}"; do
    STATUS=$(gcloud compute instances describe "$NAME" --zone="$ZONE" --format="value(status)" --quiet 2>/dev/null || true)
    [[ "$STATUS" == "RUNNING" ]] && ACTUAL_RUNNING_VMS+=("$NAME")
  done

  if [[ "${#ACTUAL_RUNNING_VMS[@]}" -gt 0 ]]; then
    echo "📦 Đang cài đặt phần mềm Proxy..."
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
    echo -e "${GREEN}=== KẾT QUẢ PROXY MỚI ===${NC}"
    for NAME in "${ACTUAL_RUNNING_VMS[@]}"; do
      if [[ -n "${PROXIES[$NAME]:-}" ]]; then
        echo -e "$NAME: ${GREEN}${PROXIES[$NAME]}${NC}"
      else
        echo -e "$NAME: ${RED}FAILED${NC} (Check log /tmp/${NAME}.proxy.log)"
      fi
    done
    echo "========================="
  fi
  
  echo
  read -rp "Ấn Enter để quay lại Menu..."
}

check_ssh_key() {
  if [[ ! -f "$HOME/.ssh/google_compute_engine" ]]; then
    mkdir -p "$HOME/.ssh"
    ssh-keygen -t rsa -f "$HOME/.ssh/google_compute_engine" -N "" -q
  fi
}

#######################################
# MAIN MENU
#######################################
check_project

while true; do
  clear
  echo -e "${BLUE}========================================${NC}"
  echo -e "${BLUE}    GOOGLE CLOUD PROXY MANAGER (V8)     ${NC}"
  echo -e "${BLUE}========================================${NC}"
  echo "1. 🚀 Tạo Proxy Mới (Create New)"
  echo "2. 🔎 Quét & Xem danh sách Proxy (Scan All)"
  echo "3. 🚪 Thoát (Exit)"
  echo
  read -rp "Chọn chức năng (1-3): " CHOICE

  case "$CHOICE" in
    1)
      create_proxy_menu
      ;;
    2)
      scan_proxies
      ;;
    3)
      echo "Tạm biệt!"
      exit 0
      ;;
    *)
      echo "Không hợp lệ."
      sleep 1
      ;;
  esac
done
