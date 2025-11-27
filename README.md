# gcp-proxy
1 cmd 1 prxy
curl -s https://raw.githubusercontent.com/taieuro/gcp-proxy/main/install.sh | sudo bash

Maybe you have to create Firewall rule in:
https://console.cloud.google.com/net-security/firewall-manager/firewall-policies

INTRODUCTION
===============================================
🟢 Lần đầu chạy:
curl -s https://raw.githubusercontent.com/taieuro/gcp-proxy/main/install.sh | sudo bash

Cài dependency

Build 3proxy

Tạo config + service

Auto firewall (nếu được)

Tạo /root/proxy_info.txt

In:

============== NEW PROXY CREATED ==============
IP:PORT:USER:PASS
===============================================
Saved to /root/proxy_info.txt

🟢 Lần sau (quên proxy, chạy lại cùng lệnh):

Script thấy /root/proxy_info.txt tồn tại, không cài lại, không build lại, không đụng firewall.

Chỉ:

restart 3proxy cho chắc

in lại nội dung /root/proxy_info.txt:

=== Detected existing proxy info at /root/proxy_info.txt ===

Your proxy:
IP:PORT:USER:PASS
