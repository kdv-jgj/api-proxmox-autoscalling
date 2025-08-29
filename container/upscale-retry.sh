#!/bin/bash
API_HOST="https://192.168.100.160:8006"
USER="root@pam"
PASSWORD="PassWords"
NODE="node1"
TEMPLATE_ID="121"
START_NEWID=500
CPU_THRESHOLD=70
MEM_THRESHOLD=70

LB_CT_ID=120
LB_USER="root"
LB_PASS="PassWords"
LB_IP="192.168.100.1"
LB_CONF_PATH="/etc/nginx/sites-available/loadbalance"

# Telegram Notification
TG_BOT_TOKEN="8025523205:TOKEN-ID"
TG_CHAT_ID="CHAT-ID"

LOGIN=$(curl -sk -d "username=$USER&password=$PASSWORD" "$API_HOST/api2/json/access/ticket")
TICKET=$(echo "$LOGIN" | jq -r '.data.ticket')
CSRF=$(echo "$LOGIN" | jq -r '.data.CSRFPreventionToken')
COOKIE="PVEAuthCookie=$TICKET"

RETRY_COUNT=0
MAX_RETRY=3
DELAY=60

while (( RETRY_COUNT < MAX_RETRY )); do
  CT_LIST=$(curl -sk -b "$COOKIE" "$API_HOST/api2/json/cluster/resources?type=vm" | \
    jq -c '.data[] | select(.type=="lxc" and .status=="running" and .tags and (.tags | test("(^|;)lbnginx-dhcp(;|$)")))')

  if [[ -z "$CT_LIST" ]]; then
    echo "Tidak ada CT dengan tag 'lbnginx-dhcp' yang sedang running."
    exit 0
  fi

  COUNT_TOTAL=0
  COUNT_HIGH_LOAD=0

  echo "Percobaan $((RETRY_COUNT+1)) - Mengecek CPU & Memory semua CT..."

  while read -r ct; do
    VMID=$(echo "$ct" | jq -r '.vmid')
    CPU=$(echo "$ct" | jq -r '.cpu')
    CPU_PERCENT=$(awk "BEGIN { printf \"%.2f\", $CPU*100 }")
    MEM=$(echo "$ct" | jq -r '.mem')
    MAXMEM=$(echo "$ct" | jq -r '.maxmem')
    MEM_PERCENT=$(awk "BEGIN { printf \"%.2f\", ($MEM/$MAXMEM)*100 }")

    echo "CT $VMID → CPU: $CPU_PERCENT% | MEM: $MEM_PERCENT%"

    ((COUNT_TOTAL++))
    if (( $(echo "$CPU_PERCENT > $CPU_THRESHOLD" | bc -l) )) || \
       (( $(echo "$MEM_PERCENT > $MEM_THRESHOLD" | bc -l) )); then
      ((COUNT_HIGH_LOAD++))
    fi
  done < <(echo "$CT_LIST")

  echo "Total CT: $COUNT_TOTAL | High Load: $COUNT_HIGH_LOAD"

  if [[ "$COUNT_TOTAL" -gt 0 && "$COUNT_TOTAL" -eq "$COUNT_HIGH_LOAD" ]]; then
    ((RETRY_COUNT++))
    if (( RETRY_COUNT < MAX_RETRY )); then
      echo "Semua CT tinggi load, retry lagi setelah $DELAY detik..."
      sleep $DELAY
    else
      echo "CT tetap tinggi setelah $MAX_RETRY percobaan. Melakukan upscale..."

      newid=$START_NEWID
      while curl -sk -b "$COOKIE" "$API_HOST/api2/json/nodes/$NODE/lxc/$newid/status/current" | grep -q '"status"'; do
        ((newid++))
      done

      HOSTNAME="ct$newid"
      echo "Cloning $TEMPLATE_ID → $newid ($HOSTNAME)"

      CLONE_TASK=$(curl -sk -X POST -b "$COOKIE" -H "CSRFPreventionToken: $CSRF" \
        --data "newid=$newid" \
        --data "hostname=$HOSTNAME" \
        --data "target=$NODE" \
        "$API_HOST/api2/json/nodes/$NODE/lxc/$TEMPLATE_ID/clone")

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
        "$API_HOST/api2/json/nodes/$NODE/lxc/$newid/status/start"

      echo "Menunggu IP DHCP muncul di CT $newid..."
      for i in {1..20}; do
        NEW_IP=$(sshpass -p "$PASSWORD" ssh -o StrictHostKeyChecking=no root@192.168.100.160 \
          "pct exec $newid -- ip -4 addr show eth0 | grep -oP '(?<=inet\s)\d+(\.\d+){3}'")

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

      MESSAGE="CT baru ($newid) ditambahkan ke load balancer karena semua CT lbnginx-dhcp melebihi ${CPU_THRESHOLD}% CPU/MEM setelah $MAX_RETRY pengecekan. IP: $NEW_IP"

      curl -s -X POST "https://api.telegram.org/bot$TG_BOT_TOKEN/sendMessage" \
        -d "chat_id=$TG_CHAT_ID" \
        -d "text=$MESSAGE" \
        -d "parse_mode=HTML"

      exit 0
    fi
  else
    echo "Tidak semua CT melebihi threshold. Clone tidak diperlukan."
    exit 0
  fi
done
