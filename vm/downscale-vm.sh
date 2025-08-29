#!/bin/bash

# --- Konfigurasi ---
API_HOST="https://192.168.101.160:8006"
USER="root@pam"
PASSWORD="PASSword"
NODE="node-pve"
CPU_THRESHOLD_LOW=20

IP_RANGE_START=3
IP_RANGE_END=10

LB_USER="root"
LB_PASS="PASSword"
LB_IP="192.168.101.121"
LB_CONF_PATH="/etc/nginx/sites-available/loadbalancer.conf"

# Telegram Notification
TG_BOT_TOKEN="8025****:******Roz3gM"
TG_CHAT_ID="-4607*****"

# --- Login ke Proxmox API ---
LOGIN=$(curl -sk -d "username=$USER&password=$PASSWORD" "$API_HOST/api2/json/access/ticket")
TICKET=$(echo "$LOGIN" | jq -r '.data.ticket')
CSRF=$(echo "$LOGIN" | jq -r '.data.CSRFPreventionToken')
COOKIE="PVEAuthCookie=$TICKET"

# --- Ambil Daftar VM dengan tag lb-vmnginx ---
VM_LIST=$(curl -sk -b "$COOKIE" "$API_HOST/api2/json/cluster/resources?type=vm" | \
  jq -c '.data[] | select(.type=="qemu" and .status=="running" and .tags and (.tags | test("(^|;)lb-vmnginx(;|$)")))')

if [[ -z "$VM_LIST" ]]; then
  echo "Tidak ada VM lb-vmnginx yang sedang berjalan."
  exit 0
fi

COUNT_TOTAL=0
COUNT_LOW_CPU=0
declare -A LOW_CPU_MAP

echo "Mengecek CPU dan IP semua VM lb-vmnginx..."
while IFS= read -r vm; do
  VMID=$(echo "$vm" | jq -r '.vmid')
  CPU=$(echo "$vm" | jq -r '.cpu')
  CPU_PERCENT=$(awk "BEGIN { printf \"%.2f\", $CPU * 100 }")

  # Ambil IP VM
  VM_IP=$(curl -sk -b "$COOKIE" "$API_HOST/api2/json/nodes/$NODE/qemu/$VMID/agent/network-get-interfaces" | \
    jq -r '
      if (.data.result != null) then
        .data.result[]? | select(.name | test("ens")) | .["ip-addresses"][]? | select(.["ip-address"] | test("^[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+$")) | .["ip-address"]
      else
        empty
      end
    ')

  echo "VM $VMID ($VM_IP) → CPU: $CPU_PERCENT%"

  ((COUNT_TOTAL++))

  if [[ -n "$VM_IP" ]] && (( $(echo "$CPU_PERCENT < $CPU_THRESHOLD_LOW" | bc -l) )); then
    ((COUNT_LOW_CPU++))
    LOW_CPU_MAP["$VM_IP"]="$VMID"
  fi
done <<< "$VM_LIST"

echo "Total VM lb-vmnginx: $COUNT_TOTAL | CPU < $CPU_THRESHOLD_LOW%: $COUNT_LOW_CPU"

# --- Cek jika hanya ada 1 VM, jangan downscale ---
if [[ "$COUNT_TOTAL" -le 1 ]]; then
  echo "Hanya ada 1 VM. Tidak bisa downscale."
  exit 0
fi

# --- Lakukan Downscale jika ada VM low CPU ---
if [[ "$COUNT_LOW_CPU" -ge 1 ]]; then
  echo "VM dengan CPU < $CPU_THRESHOLD_LOW% ditemukan. Melakukan downscale pada semuanya..."

  for ip in "${!LOW_CPU_MAP[@]}"; do
    last_octet="${ip##*.}"
    if (( last_octet >= IP_RANGE_START && last_octet <= IP_RANGE_END )); then
      VMID=${LOW_CPU_MAP[$ip]}
      echo "Mematikan VM $VMID dengan IP $ip..."
      curl -sk -X POST -b "$COOKIE" -H "CSRFPreventionToken: $CSRF" \
        "$API_HOST/api2/json/nodes/$NODE/qemu/$VMID/status/stop"

      sleep 5

      echo "Menghapus VM $VMID..."
      curl -sk -X DELETE -b "$COOKIE" -H "CSRFPreventionToken: $CSRF" \
        "$API_HOST/api2/json/nodes/$NODE/qemu/$VMID"

      echo "Menghapus IP $ip dari konfigurasi Nginx load balancer..."
      sshpass -p "$LB_PASS" ssh -o StrictHostKeyChecking=no "$LB_USER@$LB_IP" bash -c "'
        sed -i \"/server $ip;/d\" $LB_CONF_PATH && nginx -s reload
      '"

      MESSAGE="VM ($VMID) dengan IP $ip dihentikan dan dihapus dari load balancer karena CPU load < ${CPU_THRESHOLD_LOW}%."
      curl -s -X POST "https://api.telegram.org/bot$TG_BOT_TOKEN/sendMessage" \
        -d "chat_id=$TG_CHAT_ID" \
        -d "text=$MESSAGE"

    else
      echo "Lewati IP $ip (di luar range yang diizinkan)"
    fi
  done
else
  echo "Tidak ada VM dengan CPU < $CPU_THRESHOLD_LOW%. Downscale tidak dilakukan."
fi
