#!/bin/bash
# =====================================================================
# KUBERNETES NODE PREP (run on controller AND every worker)
# Auto-detects the bridged interface IP and pins kubelet to it.
# Usage: bash prep_node.sh            (auto-detect)
#        bash prep_node.sh <static-ip>   (manual IP override)
# =====================================================================

set -e

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
NODE_IP="${1:-$(ip -4 -o addr show dev "$IFACE" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1)}"

if [ -z "$NODE_IP" ]; then
  echo "ERROR: could not detect an IPv4 address on $IFACE. Run 'ip -4 addr' and pass the IP as an argument."
  exit 1
fi
echo ">>> Using node interface: $IFACE"
echo ">>> Using node IP: $NODE_IP"

echo "=== [1/4] Disabling Swap & Tuning Kernel ==="
sudo swapoff -a
sudo sed -i '/swap/d' /etc/fstab

sudo tee /etc/modules-load.d/k8s.conf > /dev/null <<EOF
overlay
br_netfilter
EOF
sudo modprobe overlay
sudo modprobe br_netfilter

sudo tee /etc/sysctl.d/k8s.conf > /dev/null <<EOF
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sudo sysctl --system > /dev/null

echo "=== [2/4] Installing Containerd (SystemdCgroup enabled) ==="
sudo apt-get update
sudo apt-get install -y containerd
sudo mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml > /dev/null
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml
sudo systemctl restart containerd
sudo systemctl enable containerd

echo "=== [3/4] Installing kubelet, kubeadm, kubectl (v1.32) ==="
sudo apt-get install -y apt-transport-https ca-certificates curl gpg
sudo mkdir -p -m 755 /etc/apt/keyrings
sudo rm -f /etc/apt/sources.list.d/kubernetes.list
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.32/deb/Release.key | sudo gpg --dearmor --yes -o /usr/share/keyrings/kubernetes-archive-keyring.gpg
sudo chmod 644 /usr/share/keyrings/kubernetes-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/kubernetes-archive-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.32/deb/ /" | sudo tee /etc/apt/sources.list.d/kubernetes.list > /dev/null
sudo apt-get update
sudo apt-get install -y kubelet kubeadm kubectl
sudo apt-mark hold kubelet kubeadm kubectl

echo "=== [4/4] Pinning kubelet to $NODE_IP ==="
echo "KUBELET_EXTRA_ARGS=--node-ip=$NODE_IP" | sudo tee /etc/default/kubelet > /dev/null
sudo systemctl enable --now kubelet

echo "=== NODE PREP COMPLETE (IP: $NODE_IP) ==="