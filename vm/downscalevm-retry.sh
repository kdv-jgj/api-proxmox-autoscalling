#!/bin/bash

# --- Konfigurasi ---
API_HOST="https://192.168.101.160:8006"
USER="root@pam"
PASSWORD="PASSword"
NODE="node-pve"
CPU_THRESHOLD_LOW=20
MEM_THRESHOLD_LOW=20

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
COUNT_LOW=0
declare -A LOW_VM_MAP

echo "Mengecek CPU & Memory semua VM lb-vmnginx dengan retry 3x..."
while IFS= read -r vm; do
  VMID=$(echo "$vm" | jq -r '.vmid')
  VM_NAME=$(echo "$vm" | jq -r '.name')
  VM_IP=""

  RETRY_OK=true

  for attempt in {1..3}; do
    STATS=$(curl -sk -b "$COOKIE" "$API_HOST/api2/json/nodes/$NODE/qemu/$VMID/status/current")
    CPU=$(echo "$STATS" | jq -r '.data.cpu')
    MEM=$(echo "$STATS" | jq -r '.data.mem')
    MAXMEM=$(echo "$STATS" | jq -r '.data.maxmem')

    CPU_PERCENT=$(awk "BEGIN { printf \"%.2f\", $CPU*100 }")
    MEM_PERCENT=$(awk "BEGIN { printf \"%.2f\", ($MEM/$MAXMEM)*100 }")

    echo "VM $VMID (Percobaan $attempt) → CPU: $CPU_PERCENT% | MEM: $MEM_PERCENT%"

    if (( $(echo "$CPU_PERCENT > $CPU_THRESHOLD_LOW" | bc -l) )) || \
       (( $(echo "$MEM_PERCENT > $MEM_THRESHOLD_LOW" | bc -l) )); then
      echo "VM $VMID load di atas threshold. Tidak akan dihapus."
      RETRY_OK=false
      break
    fi

    sleep 5
  done

  if [[ "$RETRY_OK" == true ]]; then
    # Ambil IP VM
    VM_IP=$(curl -sk -b "$COOKIE" "$API_HOST/api2/json/nodes/$NODE/qemu/$VMID/agent/network-get-interfaces" | \
      jq -r '
        if (.data.result != null) then
          .data.result[]? | select(.name | test("ens")) | .["ip-addresses"][]? | select(.["ip-address"] | test("^[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+$")) | .["ip-address"]
        else
          empty
        end
      ')
    if [[ -n "$VM_IP" ]]; then
      LOW_VM_MAP["$VM_IP"]="$VMID"
      ((COUNT_LOW++))
    fi
  fi

  ((COUNT_TOTAL++))
done <<< "$VM_LIST"

echo "Total VM lb-vmnginx: $COUNT_TOTAL | Siap dihapus (CPU/MEM < $CPU_THRESHOLD_LOW%): $COUNT_LOW"

# --- Cek jika hanya ada 1 VM, jangan downscale ---
if [[ "$COUNT_TOTAL" -le 1 ]]; then
  echo "Hanya ada 1 VM. Tidak bisa downscale."
  exit 0
fi

# --- Lakukan Downscale jika ada VM low CPU/MEM ---
if [[ "$COUNT_LOW" -ge 1 ]]; then
  echo "VM dengan CPU/MEM rendah terdeteksi. Memulai proses downscale..."

  for ip in "${!LOW_VM_MAP[@]}"; do
    last_octet="${ip##*.}"
    if (( last_octet >= IP_RANGE_START && last_octet <= IP_RANGE_END )); then
      VMID=${LOW_VM_MAP[$ip]}
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

      MESSAGE="VM ($VMID) dengan IP $ip dihentikan dan dihapus dari load balancer karena CPU/MEM rendah (< ${CPU_THRESHOLD_LOW}%)."
      curl -s -X POST "https://api.telegram.org/bot$TG_BOT_TOKEN/sendMessage" \
        -d "chat_id=$TG_CHAT_ID" \
        -d "text=$MESSAGE"
    else
      echo "Lewati IP $ip (di luar range yang diizinkan)"
    fi
  done
else
  echo "Tidak ada VM dengan CPU/MEM rendah. Downscale tidak dilakukan."
fi
