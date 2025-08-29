#!/bin/bash
API_HOST="https://192.168.101.160:8006"
USER="root@pam"
PASSWORD="PASSword"
NODE="node-pve"
TEMPLATE_ID="105"
START_NEWID=600
CPU_THRESHOLD=70
MEM_THRESHOLD=70

LB_VM_ID=125
LB_USER="root"
LB_PASS="PASSword"
LB_IP="192.168.101.121"
LB_CONF_PATH="/etc/nginx/sites-available/loadbalancer.conf"

# Telegram Notification
TG_BOT_TOKEN="8025****:******Roz3gM"
TG_CHAT_ID="-4607*****"


cek_load() {
VM_LIST=$(curl -sk -b "$COOKIE" "$API_HOST/api2/json/cluster/resources?type=vm" | \
  jq -c '.data[] | select(.type=="qemu" and .status=="running" and .tags and (.tags | test("(^|;)lb-vmnginx(;|$)")))')

if [[ -z "$VM_LIST" ]]; then
  echo "Tidak ada VM dengan tag 'lb-vmnginx' yang sedang running."
  return 1
fi

COUNT_TOTAL=0
COUNT_HIGH_LOAD=0

echo "Mengecek CPU & Memory semua VM..."

while read -r vm; do
  VMID=$(echo "$vm" | jq -r '.vmid')
  CPU=$(echo "$vm" | jq -r '.cpu')
  CPU_PERCENT=$(awk "BEGIN { printf \"%.2f\", $CPU*100 }")
  MEM=$(echo "$vm" | jq -r '.mem')
  MAXMEM=$(echo "$vm" | jq -r '.maxmem')
  MEM_PERCENT=$(awk "BEGIN { printf \"%.2f\", ($MEM/$MAXMEM)*100 }")

  echo "CT $VMID → CPU: $CPU_PERCENT% | MEM: $MEM_PERCENT%"

  ((COUNT_TOTAL++))
  if (( $(echo "$CPU_PERCENT > $CPU_THRESHOLD" | bc -l) )) || \
     (( $(echo "$MEM_PERCENT > $MEM_THRESHOLD" | bc -l) )); then
    ((COUNT_HIGH_LOAD++))
  fi
done < <(echo "$VM_LIST")

echo "Total VM: $COUNT_TOTAL | High Load: $COUNT_HIGH_LOAD"

if [[ "$COUNT_TOTAL" -gt 0 && "$COUNT_TOTAL" -eq "$COUNT_HIGH_LOAD" ]]; then
  return 0
else
  return 1
fi
}

LOGIN=$(curl -sk -d "username=$USER&password=$PASSWORD" "$API_HOST/api2/json/access/ticket")
TICKET=$(echo "$LOGIN" | jq -r '.data.ticket')
CSRF=$(echo "$LOGIN" | jq -r '.data.CSRFPreventionToken')
COOKIE="PVEAuthCookie=$TICKET"

RETRY_COUNT=0
MAX_RETRIES=3
SLEEP_BETWEEN=5

echo "Mulai cek load VM (max $MAX_RETRIES kali)..."

while (( RETRY_COUNT < MAX_RETRIES )); do
  ((RETRY_COUNT++))
  echo "Cek load ke-$RETRY_COUNT..."

  if cek_load; then
    echo "semua VM tinggi load ($RETRY_COUNT/$MAX_RETRIES)."
  else
    echo "Tidak semua VM tinggi load pada cek ke-$RETRY_COUNT. Abort!"
    exit 0
  fi

  if (( RETRY_COUNT == MAX_RETRIES )); then
    echo "Semua VM tinggi load selama $MAX_RETRIES kali. Lanjut clone!"
    break
  fi

  sleep "$SLEEP_BETWEEN"
done


  newid=$START_NEWID
  while curl -sk -b "$COOKIE" "$API_HOST/api2/json/nodes/$NODE/qemu/$newid/status/current" | grep -q '"status"'; do
    ((newid++))
  done

  HOSTNAME="vm$newid"
  echo "Cloning $TEMPLATE_ID → $newid ($HOSTNAME)"

  CLONE_TASK=$(curl -sk -X POST -b "$COOKIE" -H "CSRFPreventionToken: $CSRF" \
    --data "newid=$newid" \
    --data "name=$HOSTNAME" \
    --data "target=$NODE" \
    "$API_HOST/api2/json/nodes/$NODE/qemu/$TEMPLATE_ID/clone")

echo "CLONE_TASK: $CLONE_TASK"
  UPID=$(echo "$CLONE_TASK" | jq -r '.data')

  echo "Menunggu clone selesai..."
  while true; do
    STATUS=$(curl -sk -b "$COOKIE" "$API_HOST/api2/json/nodes/$NODE/tasks/$UPID/status" | jq -r '.data.status')
    [[ "$STATUS" == "stopped" ]] && break
    [[ "$STATUS" != "running" ]] && echo "Gagal clone: $STATUS" && exit 1
    sleep 2
  done

  echo "Menyalakan CT $newid..."
  curl -sk -X POST -b "$COOKIE" -H "CSRFPreventionToken: $CSRF" \
    "$API_HOST/api2/json/nodes/$NODE/qemu/$newid/status/start"

  echo "Menunggu IP DHCP muncul di CT $newid..."

  for i in {1..20}; do
  NEW_IP=$(curl -sk -b "$COOKIE" "$API_HOST/api2/json/nodes/$NODE/qemu/$newid/agent/network-get-interfaces" | \
    jq -r '
      if (.data.result != null) then
        .data.result[]? | select(.name | test("ens")) | .["ip-addresses"][]? | select(.["ip-address"] | test("^[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+$")) | .["ip-address"]
      else
        empty
      end
    ')

  if [[ -n "$NEW_IP" ]]; then
    echo "CT $newid mendapatkan IP: $NEW_IP"
    break
  fi

  echo "Menunggu DHCP (percobaan $i)..."
  sleep 3
done


  echo "Menambahkan $NEW_IP ke load balancer config..."
  sshpass -p "$LB_PASS" ssh -o StrictHostKeyChecking=no "$LB_USER@$LB_IP" bash -c "'
    grep -q \"$NEW_IP\" $LB_CONF_PATH || \
    sed -i \"/^upstream backend_servers {/a \    server $NEW_IP;\" $LB_CONF_PATH && \
    nginx -s reload
  '"

  MESSAGE="VM baru ($newid) ditambahkan ke load balancer karena semua VM lb-vmnginx melebihi ${CPU_THRESHOLD}% CPU/MEM. IP: $NEW_IP"

  curl -s -X POST "https://api.telegram.org/bot$TG_BOT_TOKEN/sendMessage" \
    -d "chat_id=$TG_CHAT_ID" \
    -d "text=$MESSAGE" \
    -d "parse_mode=HTML"

