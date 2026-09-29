#!/bin/bash
# =====================================================================
# KUBERNETES CONTROLLER INIT (run ONLY on controller-001, AFTER prep_node.sh)
# Auto-detects the bridged interface IP and subnet; configures kubeadm and Calico to match.
# Usage: bash init_controller.sh
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
IFACE_CIDR="$(ip -4 -o addr show dev "$IFACE" 2>/dev/null | awk '{print $4}' | head -n1)"
if [ -z "$IFACE_CIDR" ]; then
  echo "ERROR: no IP found on $IFACE. Run 'ip -4 addr' to check the interface."
  exit 1
fi

CTRL_IP="${IFACE_CIDR%/*}"
VM_SUBNET="$(python3 -c "import ipaddress,sys; print(ipaddress.ip_interface(sys.argv[1]).network)" "$IFACE_CIDR")"
POD_CIDR="10.244.0.0/16"

echo ">>> Controller IP : $CTRL_IP"
echo ">>> Interface     : $IFACE"
echo ">>> VM subnet     : $VM_SUBNET"
echo ">>> Pod CIDR      : $POD_CIDR"

echo "=== [1/3] Bootstrapping control plane ==="
sudo kubeadm init --apiserver-advertise-address="$CTRL_IP" --pod-network-cidr="$POD_CIDR"

echo "=== [2/3] Exporting admin kubeconfig ==="
mkdir -p "$HOME/.kube"
sudo cp -f /etc/kubernetes/admin.conf "$HOME/.kube/config"
sudo chown "$(id -u):$(id -g)" "$HOME/.kube/config"

echo "=== [3/3] Installing Calico (bound to $VM_SUBNET) ==="
kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/v3.27.0/manifests/tigera-operator.yaml

cat > "$HOME/calico-custom-resources.yaml" <<EOF
apiVersion: operator.tigera.io/v1
kind: Installation
metadata:
  name: default
spec:
  calicoNetwork:
    nodeAddressAutodetectionV4:
      cidrs:
        - $VM_SUBNET
    ipPools:
    - blockSize: 26
      cidr: $POD_CIDR
      encapsulation: VXLANCrossSubnet
      natOutgoing: Enabled
      nodeSelector: all()
---
apiVersion: operator.tigera.io/v1
kind: APIServer
metadata:
  name: default
spec: {}
EOF

# The operator CRDs need a moment to register before the Installation can be created
sleep 20
kubectl create -f "$HOME/calico-custom-resources.yaml"

echo ""
echo "=== CONTROLLER READY ==="
echo "Join command for the workers (run with sudo on each worker):"
sudo kubeadm token create --print-join-command
echo ""
echo "Watch progress with: kubectl get nodes -o wide   and   kubectl get pods -A -w"