#!/usr/bin/env bash
# Script Quản Lý Proxy V13 (Rescue Edition)
# Fix lỗi: VM "rỗng" (chưa cài đặt phần mềm).
# Cơ chế:
# 1. Dùng 'find' để tìm file config ở mọi ngóc ngách.
# 2. Nếu không thấy -> TỰ ĐỘNG CÀI LẠI (Rescue Mode).
# curl -s https://raw.githubusercontent.com/taieuro/gcp-proxy/main/create-proxy-manager.sh | bash

set +e # Chạy chế độ mềm dẻo, không tự thoát khi lỗi

#######################################
# CẤU HÌNH & DATABASE
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
DB_FILE="$HOME/.proxy_list.txt"

# Màu sắc
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

#######################################
# HÀM HỖ TRỢ
#######################################
get_input() {
  local prompt="$1"
  local var_name="$2"
  if [[ -r /dev/tty ]]; then
    read -rp "$prompt" "$var_name" < /dev/tty
  else
    echo -e "${RED}❌ Lỗi: Không tìm thấy TTY.${NC}"
    exit 1
  fi
}

pause_screen() {
  echo
  if [[ -r /dev/tty ]]; then
    read -rp "Ấn Enter để tiếp tục..." < /dev/tty
  fi
}

check_project() {
  PROJECT="$(gcloud config get-value project 2>/dev/null || echo)"
  if [[ -z "$PROJECT" ]]; then
    echo -e "${RED}❌ Không lấy được project hiện tại.${NC}"
    exit 1
  fi
}

#######################################
# CHỨC NĂNG 2: SCAN & RESCUE (V13)
#######################################
scan_proxies() {
  clear
  echo -e "${BLUE}=== DANH SÁCH PROXY (IP:PORT:USER:PASS) ===${NC}"
  echo "Đang kiểm tra hệ thống..."

  # 1. Lấy danh sách VM đang chạy
  LIVE_VMS=$(gcloud compute instances list --project="$PROJECT" \
    --filter="name ~ '^(proxy-vm|us-proxy)-[0-9]+$' AND status=RUNNING" \
    --format="value(name,networkInterfaces[0].accessConfigs[0].natIP)" 2>/dev/null || true)

  if [[ -z "$LIVE_VMS" ]]; then
    echo -e "${YELLOW}⚠ Không có Proxy VM nào đang chạy.${NC}"
    pause_screen
    return
  fi

  declare -A VM_IPS
  declare -A MISSING_CREDENTIALS
  
  mkdir -p "$(dirname "$DB_FILE")"
  touch "$DB_FILE"
  
  while read -r NAME IP; do
    VM_IPS["$NAME"]="$IP"
    if grep -q "$IP" "$DB_FILE" 2>/dev/null; then
      : # Đã có trong DB
    else
      MISSING_CREDENTIALS["$NAME"]="$IP"
    fi
  done <<< "$LIVE_VMS"

  # 2. Xử lý VM thiếu thông tin
  if [[ ${#MISSING_CREDENTIALS[@]} -gt 0 ]]; then
    echo -e "${YELLOW}🔎 Phát hiện ${#MISSING_CREDENTIALS[@]} VM chưa có thông tin.${NC}"
    echo "⏳ Đang quét sâu (Deep Scan) để tìm file cấu hình..."
    
    if [[ ! -f "$HOME/.ssh/google_compute_engine" ]]; then
      mkdir -p "$HOME/.ssh"; ssh-keygen -t rsa -f "$HOME/.ssh/google_compute_engine" -N "" -q
    fi

    declare -A PIDS
    declare -A LOGS
    
    # Bước 2a: Thử đọc file config bằng lệnh 'find' (quét toàn ổ đĩa)
    for NAME in "${!MISSING_CREDENTIALS[@]}"; do
      LOG_FILE="/tmp/${NAME}.scan.log"
      LOGS["$NAME"]="$LOG_FILE"
      
      # Lệnh tìm file 3proxy.cfg ở bất cứ đâu và in nội dung ra
      CMD="sudo find / -name '3proxy.cfg' -print -quit | xargs sudo cat 2>/dev/null"
      
      gcloud compute ssh "$NAME" --zone="$(gcloud compute instances list --filter="name=$NAME" --format="value(zone)" --quiet)" \
        --project="$PROJECT" --quiet \
        --ssh-flag="-o StrictHostKeyChecking=no" --ssh-flag="-o UserKnownHostsFile=/dev/null" \
        --command="$CMD" > "$LOG_FILE" 2>&1 &
      PIDS["$NAME"]=$!
    done

    # Bước 2b: Xử lý kết quả Scan
    RESCUE_LIST=()
    
    for NAME in "${!MISSING_CREDENTIALS[@]}"; do
      wait "${PIDS[$NAME]}" || true
      LOG="${LOGS[$NAME]}"
      IP="${MISSING_CREDENTIALS[$NAME]}"
      
      FOUND_CONF=false
      if [[ -s "$LOG" ]]; then
        # Parse Config
        RAW_USER=$(grep ":CL:" "$LOG" | head -n 1) 
        RAW_PORT=$(grep -E "(proxy|socks) -p" "$LOG" | head -n 1)

        if [[ -n "$RAW_USER" && -n "$RAW_PORT" ]]; then
          PORT=$(echo "$RAW_PORT" | grep -oP '\-p\K[0-9]+')
          USER_PASS=$(echo "$RAW_USER" | awk '{print $2}')
          USER=$(echo "$USER_PASS" | awk -F:CL: '{print $1}')
          PASS=$(echo "$USER_PASS" | awk -F:CL: '{print $2}')
          
          if [[ -n "$USER" && -n "$PASS" && -n "$PORT" ]]; then
             FULL_PROXY="$IP:$PORT:$USER:$PASS"
             if ! grep -q "$FULL_PROXY" "$DB_FILE"; then echo "$FULL_PROXY" >> "$DB_FILE"; fi
             FOUND_CONF=true
          fi
        fi
      fi
      
      if [[ "$FOUND_CONF" == "false" ]]; then
         echo -e "${RED}⚠ VM '$NAME' rỗng (chưa cài phần mềm).${NC}"
         RESCUE_LIST+=("$NAME")
      fi
      rm -f "$LOG"
    done

    # Bước 3: CỨU HỘ (RESCUE MODE) - Cài lại cho VM rỗng
    if [[ ${#RESCUE_LIST[@]} -gt 0 ]]; then
        echo
        echo -e "${CYAN}🚑 ĐANG KÍCH HOẠT CHẾ ĐỘ CỨU HỘ (RESCUE MODE)...${NC}"
        echo "Hệ thống sẽ cài đặt lại Proxy cho ${#RESCUE_LIST[@]} VM bị lỗi."
        echo "Vui lòng đợi khoảng 1 phút..."
        
        declare -A RESCUE_PIDS
        declare -A RESCUE_LOGS

        for NAME in "${RESCUE_LIST[@]}"; do
            R_LOG="/tmp/${NAME}.rescue.log"
            RESCUE_LOGS["$NAME"]="$R_LOG"
            ZONE_R="$(gcloud compute instances list --filter="name=$NAME" --format="value(zone)" --quiet)"
            
            echo "▶ Đang cài đặt lại cho: $NAME ..."
            gcloud compute ssh "$NAME" --zone="$ZONE_R" --project="$PROJECT" --quiet \
            --ssh-flag="-o StrictHostKeyChecking=no" --ssh-flag="-o UserKnownHostsFile=/dev/null" \
            --command="curl -s $PROXY_INSTALL_URL | sudo bash" > "$R_LOG" 2>&1 &
            RESCUE_PIDS["$NAME"]=$!
        done

        # Đợi cài xong và lấy thông tin
        for NAME in "${RESCUE_LIST[@]}"; do
            wait "${RESCUE_PIDS[$NAME]}" || true
            R_LOG="${RESCUE_LOGS[$NAME]}"
            IP="${MISSING_CREDENTIALS[$NAME]}"

            if grep -q "PROXY:" "$R_LOG"; then
                PROXY_LINE="$(grep 'PROXY:' "$R_LOG" | tail -n 1 | sed 's/^.*PROXY:[[:space:]]*//')"
                if ! grep -q "$PROXY_LINE" "$DB_FILE"; then echo "$PROXY_LINE" >> "$DB_FILE"; fi
                echo -e "${GREEN}✅ Đã cứu hộ thành công $NAME.${NC}"
            else
                echo -e "${RED}❌ Cứu hộ thất bại $NAME.${NC} (Xem log: $R_LOG)"
            fi
        done
    fi
    echo
  fi

  # 4. IN KẾT QUẢ CUỐI CÙNG
  echo -e "${GREEN}--------------------------------------------------${NC}"
  COUNT=0
  for NAME in "${!VM_IPS[@]}"; do
    IP="${VM_IPS[$NAME]}"
    # Tìm dòng chứa IP trong DB (ưu tiên dòng mới nhất)
    INFO=$(grep "$IP" "$DB_FILE" | tail -n 1 || true)
    
    if [[ -n "$INFO" ]]; then
      echo "$INFO"
      ((COUNT++))
    else
      echo -e "${RED}$IP:ERROR${NC} (Vẫn lỗi - Hãy xóa VM này và tạo mới)"
    fi
  done
  echo -e "${GREEN}--------------------------------------------------${NC}"
  echo "Tổng: $COUNT proxy hoạt động."
  
  pause_screen
}

#######################################
# CHỨC NĂNG 1: TẠO PROXY
#######################################
create_proxy_menu() {
  clear
  echo -e "${BLUE}=== TẠO PROXY MỚI ===${NC}"
  cat << 'SUBMENU'
--- CHÂU Á ---
  1) Tokyo
  2) Osaka
  3) Seoul

--- MỸ (Rẻ & Xanh) ---
  4) Oregon   (Low CO2)
  5) Iowa     (RẺ NHẤT)
  6) Virginia (Low CO2)

  0) Quay lại
SUBMENU

  get_input "Chọn (0-6): " REGION_CHOICE

  VM_NAME_PREFIX="proxy-vm"
  case "$REGION_CHOICE" in
    1) REGION="asia-northeast1"; LBL="Tokyo" ;;
    2) REGION="asia-northeast2"; LBL="Osaka" ;;
    3) REGION="asia-northeast3"; LBL="Seoul" ;;
    4) REGION="us-west1";    LBL="Oregon"; VM_NAME_PREFIX="us-proxy" ;;
    5) REGION="us-central1"; LBL="Iowa";   VM_NAME_PREFIX="us-proxy" ;;
    6) REGION="us-east4";    LBL="Virginia"; VM_NAME_PREFIX="us-proxy" ;;
    0) return ;;
    *) echo "Sai."; sleep 1; return ;;
  esac

  echo -e "\nKhu vực: ${GREEN}$LBL${NC}"

  # Check Quota
  JSON_DATA=$(gcloud compute regions describe "$REGION" --project="$PROJECT" --format="json" --quiet 2>/dev/null || true)
  NUM_VMS=1
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
      LIMIT_INT="${LIMIT_VAL%.*}"; USAGE_INT="${USAGE_VAL%.*}"
      REMAINING=$((LIMIT_INT - USAGE_INT))
      echo -e "Quota: Free=${GREEN}$REMAINING${NC}"
      if (( REMAINING <= 0 )); then echo "Hết Quota."; pause_screen; return; fi
      NUM_VMS="$REMAINING"
  fi
  
  echo "=> Tạo: $NUM_VMS VM."

  # Create
  ZONE="$(gcloud compute zones list --filter="region:($REGION) AND status=UP" --quiet --format='value(name)' | head -n 1 || true)"
  [[ -z "$ZONE" ]] && echo "Lỗi Zone." && return

  if ! gcloud compute firewall-rules describe "$FIREWALL_NAME" --project="$PROJECT" --quiet >/dev/null 2>&1; then
    gcloud compute firewall-rules create "$FIREWALL_NAME" --project="$PROJECT" --network="$NETWORK" --direction=INGRESS --priority=1000 --action=ALLOW --rules=tcp:20000-60000 --source-ranges=0.0.0.0/0 --target-tags="proxy-vm" --quiet
  fi

  EXISTING_NAMES="$(gcloud compute instances list --project="$PROJECT" --filter="zone:($ZONE) AND name ~ ^${VM_NAME_PREFIX}-[0-9]+$" --format='value(name)' --quiet || true)"
  MAX_INDEX=0
  if [[ -n "$EXISTING_NAMES" ]]; then
    while IFS= read -r E_NAME; do
      [[ -z "$E_NAME" ]] && continue
      IDX="${E_NAME##*-}"
      [[ "$IDX" =~ ^[0-9]+$ ]] && (( IDX > MAX_INDEX )) && MAX_INDEX=$IDX
    done <<< "$EXISTING_NAMES"
  fi

  START_INDEX=$((MAX_INDEX + 1)); END_INDEX=$((MAX_INDEX + NUM_VMS))
  NEW_VM_NAMES=()
  for ((i=START_INDEX; i<=END_INDEX; i++)); do NEW_VM_NAMES+=("${VM_NAME_PREFIX}-${i}"); done

  echo -e "🚀 Đang tạo VM..."
  TMP_ERR="$(mktemp)"
  if ! gcloud compute instances create "${NEW_VM_NAMES[@]}" --project="$PROJECT" --zone="$ZONE" --machine-type="$MACHINE_TYPE" --image-family="$IMAGE_FAMILY" --image-project="$IMAGE_PROJECT" --boot-disk-size="$DISK_SIZE" --boot-disk-type="$DISK_TYPE" --network="$NETWORK" --tags="$TAGS" --quiet 2>"$TMP_ERR"; then
    cat "$TMP_ERR"
  fi
  rm -f "$TMP_ERR"

  echo "⏳ Đợi 40s..."
  sleep 40

  # Install
  if [[ ! -f "$HOME/.ssh/google_compute_engine" ]]; then
    mkdir -p "$HOME/.ssh"; ssh-keygen -t rsa -f "$HOME/.ssh/google_compute_engine" -N "" -q
  fi
  
  ACTUAL_RUNNING_VMS=()
  for NAME in "${NEW_VM_NAMES[@]}"; do
    STATUS=$(gcloud compute instances describe "$NAME" --zone="$ZONE" --format="value(status)" --quiet 2>/dev/null || true)
    [[ "$STATUS" == "RUNNING" ]] && ACTUAL_RUNNING_VMS+=("$NAME")
  done

  if [[ "${#ACTUAL_RUNNING_VMS[@]}" -gt 0 ]]; then
    echo "📦 Cài đặt..."
    declare -A LOG_FILES; declare -A PIDS
    for NAME in "${ACTUAL_RUNNING_VMS[@]}"; do
      LOG_FILE="/tmp/${NAME}.proxy.log"
      LOG_FILES["$NAME"]="$LOG_FILE"
      gcloud compute ssh "$NAME" --zone="$ZONE" --project="$PROJECT" --quiet --ssh-flag="-o StrictHostKeyChecking=no" --ssh-flag="-o UserKnownHostsFile=/dev/null" --command="curl -s $PROXY_INSTALL_URL | sudo bash" >"$LOG_FILE" 2>&1 &
      PIDS["$NAME"]=$!
    done

    mkdir -p "$(dirname "$DB_FILE")"; touch "$DB_FILE"
    for NAME in "${ACTUAL_RUNNING_VMS[@]}"; do
      wait "${PIDS[$NAME]}" || true
      LOG_FILE="${LOG_FILES[$NAME]}"
      if grep -q "PROXY:" "$LOG_FILE"; then
        PROXY_LINE="$(grep 'PROXY:' "$LOG_FILE" | tail -n 1 | sed 's/^.*PROXY:[[:space:]]*//')"
        echo "$PROXY_LINE" >> "$DB_FILE"
        echo -e "$NAME: ${GREEN}$PROXY_LINE${NC}"
      else
        echo -e "$NAME: ${RED}FAILED${NC}"
      fi
    done
  fi
  pause_screen
}

#######################################
# MAIN
#######################################
check_project
while true; do
  clear
  echo -e "${BLUE}========================================${NC}"
  echo -e "${BLUE}   GOOGLE CLOUD PROXY MANAGER (V13)     ${NC}"
  echo -e "${BLUE}========================================${NC}"
  echo "1. 🚀 Tạo Proxy Mới"
  echo "2. 🚑 Quét & Cứu Hộ Proxy Lỗi (Scan & Repair)"
  echo "3. 🚪 Thoát"
  echo
  get_input "Chọn (1-3): " CHOICE
  case "$CHOICE" in
    1) create_proxy_menu ;;
    2) scan_proxies ;;
    3) exit 0 ;;
    *) ;;
  esac
done
