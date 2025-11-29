#!/bin/bash
# Cài đặt proxy

# 1. Đường dẫn tải file
URL="https://github.com/taieuro/gcp-proxy/releases/download/gcp-manager/gcp-managerv17"
FILE="/tmp/gcp-managerv17"

# 2. Cài file tạm
echo "⏳ Chuẩn bị công cụ tạo proxy..."
curl -L -s "$URL" -o "$FILE"

# 3. Kiểm tra tải file
if [ ! -f "$FILE" ]; then
    echo "❌ Lỗi tải công cụ. Kiểm tra lại đường truyền."
    exit 1
fi

# 4. Cấp quyền thực thi và CHẠY
chmod +x "$FILE"
"$FILE"

# 5. Xóa file tạm đã tạo
# rm -f "$FILE"
