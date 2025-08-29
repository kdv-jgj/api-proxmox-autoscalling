#!/bin/bash
API_HOST="https://192.168.101.160:8006"
USER="root@pam"
PASSWORD="PASSword"
NODE="node-pve"
TEMPLATE_ID="105"
START_NEWID=600

LB_USER="root"
LB_PASS="PASSword"
LB_IP="192.168.101.121"
LB_CONF_PATH="/etc/nginx/sites-available/loadbalancer.conf"

TG_BOT_TOKEN="8025****:******Roz3gM"
TG_CHAT_ID="-4607*****"

# Login Proxmox API
LOGIN=$(curl -sk -d "username=$USER&password=$PASSWORD" "$API_HOST/api2/json/access/ticket")
TICKET=$(echo "$LOGIN" | jq -r '.data.ticket')
CSRF=$(echo "$LOGIN" | jq -r '.data.CSRFPreventionToken')
COOKIE="PVEAuthCookie=$TICKET"

# List VM dengan tag lb-vmnginx
mapfile -t VM_LIST < <(curl -sk -b "$COOKIE" "$API_HOST/api2/json/cluster/resources?type=vm" | \
  jq -c '.data[] | select(.type=="qemu" and .status=="running" and ((.tags // "") | tostring | test("lb-vmnginx")))')

if [[ ${#VM_LIST[@]} -eq 0 ]]; then
  echo "Tidak ada VM dengan tag 'lb-vmnginx' yang sedang running."
  exit 0
fi

for vm in "${VM_LIST[@]}"; do
  VMID=$(echo "$vm" | jq -r '.vmid')
  
  # Ambil IP via QEMU Agent
  VM_IP=$(curl -sk -b "$COOKIE" "$API_HOST/api2/json/nodes/$NODE/qemu/$VMID/agent/network-get-interfaces" | \
  jq -r '.data.result[]? | select(.name | test("ens|eth|enp")) | .["ip-addresses"][]?.["ip-address"]' | \
  grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | grep -v '^127\.' | head -n1)


  if [[ -z "$VM_IP" ]]; then
    echo "Tidak dapat menemukan IP VM $VMID, lewati..."
    continue
  fi

  echo "Healthcheck VM $VMID ($VM_IP)..."

  RETRIES=3
  SUCCESS=0

  for ((i=1; i<=RETRIES; i++)); do
    STATUS=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "http://$VM_IP:80")
    if [[ "$STATUS" == "200" ]]; then
      echo "Percobaan $i: VM $VMID sehat (HTTP 200)."
      SUCCESS=1
      break
    else
      echo "Percobaan $i: VM $VMID ($VM_IP) tidak sehat (HTTP $STATUS)."
      sleep 5
    fi
  done

  if [[ $SUCCESS -eq 0 ]]; then
    echo "VM $VMID dianggap down. Stop, delete, clone, dan replace."

    # Stop & Delete VM
    curl -sk -X POST -b "$COOKIE" -H "CSRFPreventionToken: $CSRF" \
      "$API_HOST/api2/json/nodes/$NODE/qemu/$VMID/status/stop"
    sleep 5
    curl -sk -X DELETE -b "$COOKIE" -H "CSRFPreventionToken: $CSRF" \
      "$API_HOST/api2/json/nodes/$NODE/qemu/$VMID"
    sleep 5

    # Cari ID baru
    newid=$START_NEWID
    while curl -sk -b "$COOKIE" "$API_HOST/api2/json/nodes/$NODE/qemu/$newid/status/current" | grep -q '"status"'; do
      ((newid++))
    done

    HOSTNAME="vm$newid"
    CLONE_TASK=$(curl -sk -X POST -b "$COOKIE" -H "CSRFPreventionToken: $CSRF" \
      --data "newid=$newid" --data "name=$HOSTNAME" --data "target=$NODE" \
      "$API_HOST/api2/json/nodes/$NODE/qemu/$TEMPLATE_ID/clone")
    UPID=$(echo "$CLONE_TASK" | jq -r '.data')

    echo "Menunggu clone selesai..."
    while true; do
      STATUS=$(curl -sk -b "$COOKIE" "$API_HOST/api2/json/nodes/$NODE/tasks/$UPID/status" | jq -r '.data.status')
      [[ "$STATUS" == "stopped" ]] && break
      [[ "$STATUS" != "running" ]] && echo "Gagal clone: $STATUS" && exit 1
      sleep 2
    done

    curl -sk -X POST -b "$COOKIE" -H "CSRFPreventionToken: $CSRF" \
      "$API_HOST/api2/json/nodes/$NODE/qemu/$newid/status/start"

    echo "Menunggu IP baru..."
    for i in {1..20}; do

      NEW_IP=$(curl -sk -b "$COOKIE" "$API_HOST/api2/json/nodes/$NODE/qemu/$newid/agent/network-get-interfaces" | \
        jq -r '.data.result[]? | select(.name | test("ens|eth|enp")) | .["ip-addresses"][]?.["ip-address"]' | \
        grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | grep -v '^127\.' | head -n1)

      if [[ -n "$NEW_IP" ]]; then
        echo "VM $newid mendapat IP $NEW_IP"
        break
      fi
      echo "Menunggu DHCP (percobaan $i)..."
      sleep 3
    done

    echo "Update Nginx di Load Balancer..."
    sshpass -p "$LB_PASS" ssh -o StrictHostKeyChecking=no "$LB_USER@$LB_IP" bash -c "'
      sed -i \"/server $VM_IP;/d\" $LB_CONF_PATH
      grep -q \"$NEW_IP\" $LB_CONF_PATH || sed -i \"/^upstream backend_servers {/a \    server $NEW_IP;\" $LB_CONF_PATH
      nginx -s reload
    '"

    MESSAGE="VM $VMID ($VM_IP) down, diganti VM $newid ($NEW_IP) aktif dan dimasukkan ke load balancer."
    curl -s -X POST "https://api.telegram.org/bot$TG_BOT_TOKEN/sendMessage" -d "chat_id=$TG_CHAT_ID" -d "text=$MESSAGE"
  fi
done
