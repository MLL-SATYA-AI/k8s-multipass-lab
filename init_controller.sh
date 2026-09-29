#!/bin/bash
# =====================================================================
# KUBERNETES CONTROLLER INIT (run ONLY on controller-001, AFTER prep_node.sh)
# Auto-detects the enp0s8 IP and subnet; configures kubeadm and Calico to match.
# Usage: bash init_controller.sh
# =====================================================================

set -e

IFACE_CIDR="$(ip -4 -o addr show enp0s8 2>/dev/null | awk '{print $4}' | head -n1)"
if [ -z "$IFACE_CIDR" ]; then
  echo "ERROR: no IP found on enp0s8. Run 'ip -4 addr' to check the interface."
  exit 1
fi

CTRL_IP="${IFACE_CIDR%/*}"
VM_SUBNET="$(python3 -c "import ipaddress,sys; print(ipaddress.ip_interface(sys.argv[1]).network)" "$IFACE_CIDR")"
POD_CIDR="10.244.0.0/16"

echo ">>> Controller IP : $CTRL_IP"
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