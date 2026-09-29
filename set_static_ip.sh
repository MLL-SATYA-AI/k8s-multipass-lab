#!/bin/bash
# =====================================================================
# SET A STATIC IP ON THE BRIDGED INTERFACE OF A MULTIPASS VM
# Merges with cloud-init's "extra0" netplan entry (same ID) and turns DHCP off.
# Usage: bash set_static_ip.sh <static-ip>
# =====================================================================

set -e

IP="${1:?Usage: bash set_static_ip.sh <static-ip>}"

find_bridged_iface() {
  if [ -n "${K8S_INTERFACE:-}" ]; then
    ip link show "$K8S_INTERFACE" > /dev/null 2>&1 || {
      echo "ERROR: interface $K8S_INTERFACE not found." >&2
      return 1
    }
    printf '%s\n' "$K8S_INTERFACE"
    return
  fi

  local default_iface
  local -a candidates
  default_iface="$(ip -4 route show default 2>/dev/null | awk 'NR == 1 { for (i=1; i<=NF; i++) if ($i == "dev") { print $(i+1); exit } }')"
  mapfile -t candidates < <(ip -o -4 addr show scope global 2>/dev/null | awk -v default_iface="$default_iface" '$2 != default_iface { sub(/@.*/, "", $2); print $2 }' | sort -u)

  if [ "${#candidates[@]}" -ne 1 ]; then
    echo "ERROR: could not uniquely detect the bridged interface. Run 'ip -4 -o addr show scope global' and set K8S_INTERFACE to the bridged interface name." >&2
    return 1
  fi
  printf '%s\n' "${candidates[0]}"
}

IFACE="$(find_bridged_iface)"
if ! ip -4 -o addr show dev "$IFACE" scope global | grep -q .; then
  echo "ERROR: no global IPv4 address found on $IFACE. Check the bridged network." >&2
  exit 1
fi

MAC="$(cat "/sys/class/net/$IFACE/address")"
PREFIX="$(ip -4 -o addr show dev "$IFACE" | awk '{print $4}' | cut -d/ -f2 | head -n1)"
PREFIX="${PREFIX:-24}"

echo ">>> Interface : $IFACE"
echo ">>> MAC       : $MAC"
echo ">>> Static IP : $IP/$PREFIX"

sudo tee /etc/netplan/60-static-extra0.yaml > /dev/null <<EOF
network:
  version: 2
  ethernets:
    extra0:
      match:
        macaddress: "$MAC"
      dhcp4: false
      addresses: [$IP/$PREFIX]
EOF

sudo chmod 600 /etc/netplan/60-static-extra0.yaml
sudo netplan generate
sudo netplan apply

sleep 3
echo ">>> Result:"
ip -4 addr show dev "$IFACE"