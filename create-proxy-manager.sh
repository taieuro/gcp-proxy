#!/usr/bin/env bash
# Script Quản Lý Proxy V16 (Flexible Parser)
# Fix lỗi: ERROR_NO_PORT do Regex tìm port quá chặt.
# Cải tiến: Thuật toán tìm Port thông minh hơn & Chế độ Debug nội dung file.

set +e

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
# LOGIC UPDATE MỚI (V16)
#######################################
generate_remote_script() {
cat << 'EOF'
#!/bin/bash
NEW_USER="$1"
NEW_PASS="$2"

# 1. Tìm file config (Ưu tiên đường dẫn chuẩn)
PATHS=(
  "/etc/3proxy/3proxy.cfg"
  "/usr/local/3proxy/conf/3proxy.cfg"
  "/usr/local/etc/3proxy/3proxy.cfg"
  "/etc/3proxy/conf/3proxy.cfg"
)

CONF=""
for P in "${PATHS[@]}"; do
  if [ -f "$P" ]; then CONF="$P"; break; fi
done

# Fallback: Tìm bằng find nếu không thấy (chỉ tìm trong /etc và /usr để nhanh)
if [ -z "$CONF" ]; then
  CONF=$(find /etc /usr -name "3proxy.cfg" -print -quit 2>/dev/null)
fi

if [ -z "$CONF" ]; then
  echo "ERROR_NO_CONF"
  exit 1
fi

# 2. Thay đổi User/Pass
# Backup file trước khi sửa
cp "$CONF" "${CONF}.bak"
# Regex update user: Tìm dòng users, thay thế toàn bộ
sed -i "s/^\s*users.*/users ${NEW_USER}:CL:${NEW_PASS}/" "$CONF"

# 3. Khởi động lại dịch vụ
if systemctl list-units --full -all | grep -Fq "3proxy.service"; then
    systemctl restart 3proxy
else
    pkill -9 3proxy
    3proxy "$CONF" &
fi

# 4. Lấy Port (FIXED LOGIC V16)
# Tìm dòng bắt đầu bằng proxy hoặc socks, sau đó tìm chuỗi -p theo sau là số
# Cách này bỏ qua các flag khác như -n -a nằm giữa
PORT=$(grep -E "^(proxy|socks)" "$CONF" | grep -oP "\-p\K[0-9]+" | head -1)

# Nếu vẫn không tìm thấy port, thử tìm dòng 'port' (cấu hình kiểu cũ)
if [ -z "$PORT" ]; then
   PORT=$(grep -E "^port" "$CONF" | awk '{print $2}' | head -1)
fi

if [ -n "$PORT" ]; then
  echo "SUCCESS:${PORT}"
else
  echo "ERROR_NO_PORT"
  echo "--- DEBUG CONFIG CONTENT START ---"
  cat "$CONF"
  echo "--- DEBUG CONFIG CONTENT END ---"
fi
EOF
}

update_vm_credentials() {
  local VM_NAME="$1"
  local NEW_USER="$2"
  local NEW_PASS="$3"
  local VM_IP="$4"

  echo -e "▶ Đang xử lý VM: ${CYAN}$VM_NAME${NC} ($VM_IP)..."

  ZONE="$(gcloud compute instances list --filter="name=$VM_NAME" --format="value(zone)" --quiet)"
  
  # Tạo script inject
  LOCAL_SCRIPT="/tmp/update_helper_v16.sh"
  generate_remote_script > "$LOCAL_SCRIPT"

  # Đẩy script lên VM
  gcloud compute ssh "$VM_NAME" --zone="$ZONE" --project="$PROJECT" --quiet \
    --ssh-flag="-o StrictHostKeyChecking=no" --ssh-flag="-o UserKnownHostsFile=/dev/null" \
    --command="cat > /tmp/update_helper_v16.sh" < "$LOCAL_SCRIPT"

  # Chạy script
  LOG_FILE="/tmp/${VM_NAME}.passwd.log"
  gcloud compute ssh "$VM_NAME" --zone="$ZONE" --project="$PROJECT" --quiet \
    --ssh-flag="-o StrictHostKeyChecking=no" --ssh-flag="-o UserKnownHostsFile=/dev/null" \
    --command="sudo bash /tmp/update_helper_v16.sh '$NEW_USER' '$NEW_PASS' && rm /tmp/update_helper_v16.sh" > "$LOG_FILE" 2>&1

  # Xử lý kết quả
  if grep -q "SUCCESS" "$LOG_FILE"; then
    PORT=$(grep "SUCCESS" "$LOG_FILE" | cut -d: -f2 | tr -d '\r')
    NEW_PROXY_STR="$VM_IP:$PORT:$NEW_USER:$NEW_PASS"
    
    # Cập nhật DB
    if [[ -f "$DB_FILE" ]]; then sed -i "/$VM_IP/d" "$DB_FILE"; fi
    echo "$NEW_PROXY_STR" >> "$DB_FILE"
    echo -e "   ✅ Thành công: ${GREEN}$NEW_PROXY_STR${NC}"

  elif grep -q "ERROR_NO_PORT" "$LOG_FILE"; then
    # Trường hợp đổi pass OK nhưng không đọc được port -> Cố gắng lấy port cũ từ DB
    echo -e "   ⚠ Đổi mật khẩu thành công nhưng không đọc được Port từ config."
    OLD_PORT_INFO=$(grep "$VM_IP" "$DB_FILE" | head -1)
    
    if [[ -n "$OLD_PORT_INFO" ]]; then
        OLD_PORT=$(echo "$OLD_PORT_INFO" | cut -d: -f2)
        NEW_PROXY_STR="$VM_IP:$OLD_PORT:$NEW_USER:$NEW_PASS"
        if [[ -f "$DB_FILE" ]]; then sed -i "/$VM_IP/d" "$DB_FILE"; fi
        echo "$NEW_PROXY_STR" >> "$DB_FILE"
        echo -e "   ✅ Đã dùng Port cũ: ${GREEN}$NEW_PROXY_STR${NC}"
    else
        echo -e "   ❌ Thất bại: Không xác định được Port. (Xem log để debug)"
        echo "---------------------------------------------------"
        cat "$LOG_FILE"
        echo "---------------------------------------------------"
    fi
  else
    echo -e "   ❌ Lỗi hệ thống. (Xem log: $LOG_FILE)"
  fi
  rm -f "$LOG_FILE" "$LOCAL_SCRIPT"
}

change_password_menu() {
  clear
  echo -e "${BLUE}=== ĐỔI USER:PASS PROXY (V16 FIXED) ===${NC}"
  
  LIVE_VMS=$(gcloud compute instances list --project="$PROJECT" \
    --filter="name ~ '^(proxy-vm|us-proxy)-[0-9]+$' AND status=RUNNING" \
    --format="value(name,networkInterfaces[0].accessConfigs[0].natIP)" 2>/dev/null || true)

  if [[ -z "$LIVE_VMS" ]]; then
    echo -e "${YELLOW}⚠ Không có Proxy VM nào đang chạy.${NC}"
    pause_screen; return
  fi

  mapfile -t VM_ARRAY <<< "$LIVE_VMS"
  TOTAL_VMS=${#VM_ARRAY[@]}

  echo "Tìm thấy $TOTAL_VMS Proxy đang hoạt động."
  echo "1. 🔄 Đổi đồng loạt cho TẤT CẢ ($TOTAL_VMS VM)"
  echo "2. 🎯 Chọn từng VM để đổi"
  echo "0. Quay lại"
  echo
  get_input "Lựa chọn (0-2): " MODE

  if [[ "$MODE" == "0" ]]; then return; fi

  echo; echo -e "${YELLOW}Nhập thông tin xác thực mới:${NC}"
  get_input "New Username: " NEW_USER
  get_input "New Password: " NEW_PASS

  if [[ -z "$NEW_USER" || -z "$NEW_PASS" ]]; then
    echo -e "${RED}Lỗi: Không được để trống.${NC}"; pause_screen; return
  fi
  if [[ ! "$NEW_USER" =~ ^[a-zA-Z0-9_]+$ || ! "$NEW_PASS" =~ ^[a-zA-Z0-9_]+$ ]]; then
     echo -e "${YELLOW}⚠ Cảnh báo: Chỉ nên dùng chữ cái và số.${NC}"
  fi

  echo
  if [[ "$MODE" == "1" ]]; then
    echo "🚀 Bắt đầu cập nhật..."
    for LINE in "${VM_ARRAY[@]}"; do
      NAME=$(echo "$LINE" | awk '{print $1}')
      IP=$(echo "$LINE" | awk '{print $2}')
      update_vm_credentials "$NAME" "$NEW_USER" "$NEW_PASS" "$IP"
    done
  elif [[ "$MODE" == "2" ]]; then
    echo "--- Danh sách VM ---"
    i=1
    for LINE in "${VM_ARRAY[@]}"; do
      NAME=$(echo "$LINE" | awk '{print $1}')
      IP=$(echo "$LINE" | awk '{print $2}')
      echo "$i) $NAME - $IP"
      ((i++))
    done
    echo "--------------------"
    get_input "Chọn số thứ tự (1-$TOTAL_VMS): " VM_INDEX
    if [[ ! "$VM_INDEX" =~ ^[0-9]+$ ]] || (( VM_INDEX < 1 || VM_INDEX > TOTAL_VMS )); then
      echo -e "${RED}Số không hợp lệ.${NC}"; pause_screen; return
    fi
    SELECTED_LINE="${VM_ARRAY[$((VM_INDEX-1))]}"
    NAME=$(echo "$SELECTED_LINE" | awk '{print $1}')
    IP=$(echo "$SELECTED_LINE" | awk '{print $2}')
    update_vm_credentials "$NAME" "$NEW_USER" "$NEW_PASS" "$IP"
  fi
  echo; echo -e "${GREEN}Hoàn tất.${NC}"; pause_screen
}

#######################################
# SCAN & RESCUE (V16)
#######################################
scan_proxies() {
  clear
  echo -e "${BLUE}=== DANH SÁCH PROXY (IP:PORT:USER:PASS) ===${NC}"
  echo "Đang kiểm tra hệ thống..."

  LIVE_VMS=$(gcloud compute instances list --project="$PROJECT" \
    --filter="name ~ '^(proxy-vm|us-proxy)-[0-9]+$' AND status=RUNNING" \
    --format="value(name,networkInterfaces[0].accessConfigs[0].natIP)" 2>/dev/null || true)

  if [[ -z "$LIVE_VMS" ]]; then
    echo -e "${YELLOW}⚠ Không có Proxy VM nào đang chạy.${NC}"; pause_screen; return
  fi

  declare -A VM_IPS; declare -A MISSING_CREDENTIALS
  mkdir -p "$(dirname "$DB_FILE")"; touch "$DB_FILE"
  
  while read -r NAME IP; do
    VM_IPS["$NAME"]="$IP"
    if grep -q "$IP" "$DB_FILE" 2>/dev/null; then :; else MISSING_CREDENTIALS["$NAME"]="$IP"; fi
  done <<< "$LIVE_VMS"

  if [[ ${#MISSING_CREDENTIALS[@]} -gt 0 ]]; then
    echo -e "${YELLOW}🔎 Phát hiện ${#MISSING_CREDENTIALS[@]} VM chưa có thông tin.${NC}"
    echo "⏳ Deep Scan..."
    if [[ ! -f "$HOME/.ssh/google_compute_engine" ]]; then
      mkdir -p "$HOME/.ssh"; ssh-keygen -t rsa -f "$HOME/.ssh/google_compute_engine" -N "" -q
    fi
    declare -A PIDS; declare -A LOGS
    for NAME in "${!MISSING_CREDENTIALS[@]}"; do
      LOG_FILE="/tmp/${NAME}.scan.log"; LOGS["$NAME"]="$LOG_FILE"
      CMD="sudo cat /etc/3proxy/3proxy.cfg 2>/dev/null || sudo cat /usr/local/etc/3proxy/3proxy.cfg 2>/dev/null || sudo find / -name '3proxy.cfg' -print -quit | xargs sudo cat 2>/dev/null"
      gcloud compute ssh "$NAME" --zone="$(gcloud compute instances list --filter="name=$NAME" --format="value(zone)" --quiet)" \
        --project="$PROJECT" --quiet \
        --ssh-flag="-o StrictHostKeyChecking=no" --ssh-flag="-o UserKnownHostsFile=/dev/null" \
        --command="$CMD" > "$LOG_FILE" 2>&1 &
      PIDS["$NAME"]=$!
    done
    RESCUE_LIST=()
    for NAME in "${!MISSING_CREDENTIALS[@]}"; do
      wait "${PIDS[$NAME]}" || true
      LOG="${LOGS[$NAME]}"; IP="${MISSING_CREDENTIALS[$NAME]}"
      FOUND_CONF=false
      if [[ -s "$LOG" ]]; then
        RAW_USER=$(grep ":CL:" "$LOG" | head -n 1) 
        RAW_PORT=$(grep -E "(proxy|socks) -p" "$LOG" | head -n 1)
        if [[ -n "$RAW_USER" ]]; then
          PORT=$(echo "$RAW_PORT" | grep -oP '\-p\K[0-9]+')
          USER_PASS=$(echo "$RAW_USER" | awk '{print $2}')
          USER=$(echo "$USER_PASS" | awk -F:CL: '{print $1}')
          PASS=$(echo "$USER_PASS" | awk -F:CL: '{print $2}')
          # Fallback nếu không regex được port
          [[ -z "$PORT" ]] && PORT="30000" 
          
          if [[ -n "$USER" && -n "$PASS" ]]; then
             FULL_PROXY="$IP:$PORT:$USER:$PASS"
             if ! grep -q "$FULL_PROXY" "$DB_FILE"; then echo "$FULL_PROXY" >> "$DB_FILE"; fi
             FOUND_CONF=true
          fi
        fi
      fi
      if [[ "$FOUND_CONF" == "false" ]]; then RESCUE_LIST+=("$NAME"); fi
      rm -f "$LOG"
    done
    if [[ ${#RESCUE_LIST[@]} -gt 0 ]]; then
        echo; echo -e "${CYAN}🚑 ĐANG CỨU HỘ ${#RESCUE_LIST[@]} VM...${NC}"
        declare -A RESCUE_PIDS; declare -A RESCUE_LOGS
        for NAME in "${RESCUE_LIST[@]}"; do
            R_LOG="/tmp/${NAME}.rescue.log"; RESCUE_LOGS["$NAME"]="$R_LOG"
            ZONE_R="$(gcloud compute instances list --filter="name=$NAME" --format="value(zone)" --quiet)"
            gcloud compute ssh "$NAME" --zone="$ZONE_R" --project="$PROJECT" --quiet \
            --ssh-flag="-o StrictHostKeyChecking=no" --ssh-flag="-o UserKnownHostsFile=/dev/null" \
            --command="curl -s $PROXY_INSTALL_URL | sudo bash" > "$R_LOG" 2>&1 &
            RESCUE_PIDS["$NAME"]=$!
        done
        for NAME in "${RESCUE_LIST[@]}"; do
            wait "${RESCUE_PIDS[$NAME]}" || true
            R_LOG="${RESCUE_LOGS[$NAME]}"; IP="${MISSING_CREDENTIALS[$NAME]}"
            if grep -q "PROXY:" "$R_LOG"; then
                PROXY_LINE="$(grep 'PROXY:' "$R_LOG" | tail -n 1 | sed 's/^.*PROXY:[[:space:]]*//')"
                if ! grep -q "$PROXY_LINE" "$DB_FILE"; then echo "$PROXY_LINE" >> "$DB_FILE"; fi
                echo -e "${GREEN}✅ Xong $NAME.${NC}"
            else echo -e "${RED}❌ Lỗi $NAME.${NC}"; fi
        done
    fi
    echo
  fi
  echo -e "${GREEN}--------------------------------------------------${NC}"
  COUNT=0
  for NAME in "${!VM_IPS[@]}"; do
    IP="${VM_IPS[$NAME]}"
    INFO=$(grep "$IP" "$DB_FILE" | tail -n 1 || true)
    if [[ -n "$INFO" ]]; then echo "$INFO"; ((COUNT++)); else echo -e "${RED}$IP:ERROR${NC}"; fi
  done
  echo -e "${GREEN}--------------------------------------------------${NC}"
  echo "Tổng: $COUNT proxy hoạt động."; pause_screen
}

#######################################
# CREATE PROXY (V16)
#######################################
create_proxy_menu() {
  clear
  echo -e "${BLUE}=== TẠO PROXY MỚI ===${NC}"
  cat << 'SUBMENU'
--- CHÂU Á ---
  1) Tokyo
  2) Osaka
  3) Seoul
--- MỸ ---
  4) Oregon (Low CO2)
  5) Iowa   (RẺ NHẤT)
  6) Virginia
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
    if not found: print(\"ERROR ERROR\")
except: print(\"ERROR ERROR\")")
  fi
  if [[ "$LIMIT_VAL" != "ERROR" && -n "$LIMIT_VAL" ]]; then
      LIMIT_INT="${LIMIT_VAL%.*}"; USAGE_INT="${USAGE_VAL%.*}"
      REMAINING=$((LIMIT_INT - USAGE_INT))
      echo -e "Quota: Free=${GREEN}$REMAINING${NC}"
      if (( REMAINING <= 0 )); then echo "Hết Quota."; pause_screen; return; fi
      NUM_VMS="$REMAINING"
  fi
  echo "=> Tạo: $NUM_VMS VM."
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
  if ! gcloud compute instances create "${NEW_VM_NAMES[@]}" --project="$PROJECT" --zone="$ZONE" --machine-type="$MACHINE_TYPE" --image-family="$IMAGE_FAMILY" --image-project="$IMAGE_PROJECT" --boot-disk-size="$DISK_SIZE" --boot-disk-type="$DISK_TYPE" --network="$NETWORK" --tags="$TAGS" --quiet 2>"$TMP_ERR"; then cat "$TMP_ERR"; fi
  rm -f "$TMP_ERR"
  echo "⏳ Đợi 40s..."; sleep 40
  if [[ ! -f "$HOME/.ssh/google_compute_engine" ]]; then mkdir -p "$HOME/.ssh"; ssh-keygen -t rsa -f "$HOME/.ssh/google_compute_engine" -N "" -q; fi
  ACTUAL_RUNNING_VMS=()
  for NAME in "${NEW_VM_NAMES[@]}"; do
    STATUS=$(gcloud compute instances describe "$NAME" --zone="$ZONE" --format="value(status)" --quiet 2>/dev/null || true)
    [[ "$STATUS" == "RUNNING" ]] && ACTUAL_RUNNING_VMS+=("$NAME")
  done
  if [[ "${#ACTUAL_RUNNING_VMS[@]}" -gt 0 ]]; then
    echo "📦 Cài đặt..."
    declare -A LOG_FILES; declare -A PIDS
    for NAME in "${ACTUAL_RUNNING_VMS[@]}"; do
      LOG_FILE="/tmp/${NAME}.proxy.log"; LOG_FILES["$NAME"]="$LOG_FILE"
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
      else echo -e "$NAME: ${RED}FAILED${NC}"; fi
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
  echo -e "${BLUE}   GOOGLE CLOUD PROXY MANAGER (V16)     ${NC}"
  echo -e "${BLUE}========================================${NC}"
  echo "1. 🚀 Tạo Proxy Mới"
  echo "2. 📋 Xem Danh Sách & Cứu Hộ"
  echo "3. 🔑 Đổi Mật Khẩu Proxy (Fix Port)"
  echo "4. 🚪 Thoát"
  echo
  get_input "Chọn (1-4): " CHOICE
  case "$CHOICE" in
    1) create_proxy_menu ;;
    2) scan_proxies ;;
    3) change_password_menu ;;
    4) exit 0 ;;
    *) ;;
  esac
done
