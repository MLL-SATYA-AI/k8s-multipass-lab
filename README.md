# Kubernetes Multipass Lab

Build a three-node Kubernetes cluster on Windows using Multipass with the VirtualBox driver. The VMs use a bridged Ethernet interface for node-to-node traffic; static IPs keep the cluster working after restarts.

The interactive [HTML guide](k8s_multipass_cluster_guide.html) contains the same walkthrough and downloadable script contents.

## Requirements

- Windows with PowerShell, [VirtualBox](https://www.virtualbox.org/wiki/Downloads), and [Multipass](https://canonical.com/multipass/install).
- A wired network adapter named `Ethernet` in `multipass networks`.
- About 6 GB free RAM (2 GB per VM).
- Three scripts in this repository's root: `prep_node.sh`, `init_controller.sh`, and `set_static_ip.sh`.

`prep_node.sh` and `init_controller.sh` are included in this repository. `set_static_ip.sh` is currently embedded in the HTML guide; use its **Download set_static_ip.sh** button and save the file in this repository's root. Run all PowerShell commands below from the repository root. Substitute your actual repository path when changing directories.

## 1. Install and check prerequisites

Install VirtualBox before Multipass so Multipass can use VirtualBox as its driver. In PowerShell, check the driver:

```powershell
multipass get local.driver
multipass version
```

The driver should be `virtualbox`. If it is `hyperv`, change it before creating any VMs:

```powershell
multipass set local.driver=virtualbox
```

Install `kubectl` on Windows (it is used later):

```powershell
winget install -e --id Kubernetes.kubectl
kubectl version --client
```

Open a new PowerShell window after installation if `kubectl` is not found.

## 2. Create the virtual machines

The `--network Ethernet` option adds the bridged interface needed for the cluster. Accept any Windows prompt about network bridging.

```powershell
multipass launch --name controller-001 --cpus 2 --memory 2G --disk 20G --network Ethernet
multipass launch --name worker-node1 --cpus 2 --memory 2G --disk 20G --network Ethernet
multipass launch --name worker-node2 --cpus 2 --memory 2G --disk 20G --network Ethernet
multipass list
```

Each VM should show two IPv4 addresses. The shared NAT address `10.0.2.15` is not used for cluster communication.

## 3. Check connectivity and choose static addresses

Find the controller's bridged address on `enp0s8`:

```powershell
multipass exec controller-001 -- ip -4 addr show enp0s8
```

Ping that address from both workers, replacing the example IP with the controller's current address:

```powershell
multipass exec worker-node1 -- ping -c 2 192.168.137.101
multipass exec worker-node2 -- ping -c 2 192.168.137.101
```

Do not continue until both pings succeed. Identify the subnet from the address on `enp0s8` (for example, `192.168.137.63/24` belongs to `192.168.137.0/24`). Pick three unused IPs within your own subnet and outside your router's DHCP range. The following are examples only:

| VM | Example static IP |
| --- | --- |
| `controller-001` | `192.168.137.101` |
| `worker-node1` | `192.168.137.102` |
| `worker-node2` | `192.168.137.103` |

Check that your chosen addresses are free. Replace these examples with your addresses:

```powershell
ping 192.168.137.101
ping 192.168.137.102
ping 192.168.137.103
```

Timeouts or "destination host unreachable" usually mean an address is unused. Avoid addresses already used by another device.

Transfer and run the static IP script, replacing the example IPs with your own:

```powershell
multipass transfer .\set_static_ip.sh controller-001:/home/ubuntu/
multipass transfer .\set_static_ip.sh worker-node1:/home/ubuntu/
multipass transfer .\set_static_ip.sh worker-node2:/home/ubuntu/

multipass exec controller-001 -- bash set_static_ip.sh 192.168.137.101
multipass exec worker-node1 -- bash set_static_ip.sh 192.168.137.102
multipass exec worker-node2 -- bash set_static_ip.sh 192.168.137.103
```

Restart the VMs and confirm their addresses remain set and that workers can reach the controller:

```powershell
multipass restart --all
multipass list
multipass exec worker-node1 -- ping -c 2 192.168.137.101
multipass exec worker-node2 -- ping -c 2 192.168.137.101
```

Do not continue until the static addresses are shown after restart and both pings succeed. If bash reports a `\r` line-ending error, normalize the script inside each VM:

```powershell
multipass exec <vm-name> -- sed -i 's/\r$//' set_static_ip.sh
```

## 4. Copy and prepare the node scripts

From the repository root, transfer the scripts:

```powershell
multipass transfer .\prep_node.sh controller-001:/home/ubuntu/
multipass transfer .\prep_node.sh worker-node1:/home/ubuntu/
multipass transfer .\prep_node.sh worker-node2:/home/ubuntu/
multipass transfer .\init_controller.sh controller-001:/home/ubuntu/
```

Prepare all three nodes:

```powershell
multipass exec controller-001 -- bash prep_node.sh
multipass exec worker-node1 -- bash prep_node.sh
multipass exec worker-node2 -- bash prep_node.sh
```

Check each run's output. The reported node IP must match that VM's static `enp0s8` address, not `10.0.2.15`.

## 5. Initialize the controller and join workers

Initialize the control plane and install Calico on the controller:

```powershell
multipass exec controller-001 -- bash init_controller.sh
```

At the end, the script prints a `kubeadm join` command. Use the complete command it prints on each worker, with `sudo`:

```powershell
multipass exec worker-node1 -- sudo kubeadm join <controller-ip>:6443 --token <token> --discovery-token-ca-cert-hash sha256:<hash>
multipass exec worker-node2 -- sudo kubeadm join <controller-ip>:6443 --token <token> --discovery-token-ca-cert-hash sha256:<hash>
```

Replace the placeholders with the exact values printed by the controller script. Join tokens expire after 24 hours. To print a fresh join command:

```powershell
multipass exec controller-001 -- sudo kubeadm token create --print-join-command
```

## 6. Verify the cluster

Calico may take 2 to 4 minutes to start. During that time, workers can temporarily show `NotReady`.

```powershell
multipass exec controller-001 -- kubectl get nodes -o wide
multipass exec controller-001 -- kubectl get pods -A
```

All three nodes should eventually show `Ready`, with their static addresses as internal IPs. Optionally label the workers and deploy a test workload:

```powershell
multipass exec controller-001 -- kubectl label node worker-node1 node-role.kubernetes.io/worker=
multipass exec controller-001 -- kubectl label node worker-node2 node-role.kubernetes.io/worker=
multipass exec controller-001 -- kubectl create deployment nginx --image=nginx --replicas=2
multipass exec controller-001 -- kubectl get pods -o wide
```

Delete the test deployment when finished:

```powershell
multipass exec controller-001 -- kubectl delete deployment nginx
```

## 7. Use kubectl from Windows (optional)

The Windows host must be able to reach the controller on port `6443`. Replace the example IP with your controller's static IP:

```powershell
Test-NetConnection 192.168.137.101 -Port 6443
```

`TcpTestSucceeded` should be `True`. Copy the controller kubeconfig to a local directory. The ASCII encoding is required by Windows PowerShell 5.1:

```powershell
New-Item -ItemType Directory -Force C:\k8s
multipass exec controller-001 -- sudo cat /etc/kubernetes/admin.conf | Out-File -Encoding ascii C:\k8s\admin.conf
Get-Content C:\k8s\admin.conf -TotalCount 5
```

Point `kubectl` at the file in the current PowerShell window, or set it for future windows:

```powershell
$env:KUBECONFIG = "C:\k8s\admin.conf"
[Environment]::SetEnvironmentVariable("KUBECONFIG", "C:\k8s\admin.conf", "User")
```

Open a new PowerShell window after setting the user variable. Check the context and nodes:

```powershell
kubectl config get-contexts
kubectl config use-context kubernetes-admin@kubernetes
kubectl get nodes -o wide
```

The kubeconfig grants cluster-admin access. Keep it private and never commit `C:\k8s\admin.conf` to Git. If the controller IP changes, copy the kubeconfig again. If you already have other clusters in your kubeconfig, see the HTML guide's kubeconfig merge instructions rather than replacing your existing config.

## 8. Snapshot and restore

Multipass snapshots require stopped VMs. Stop workers first and the controller last, then create a same-named snapshot for all three VMs:

```powershell
multipass stop worker-node1 worker-node2
multipass stop controller-001

$date = Get-Date -Format "yyyy-MM-dd"
$comment = "Kubernetes cluster, 3 nodes ready, taken " + (Get-Date -Format "yyyy-MM-dd HH:mm")
foreach ($vm in "controller-001", "worker-node1", "worker-node2") {
    multipass snapshot $vm --name "cluster-ready-$date" --comment $comment
}

multipass start --all
```

List snapshots:

```powershell
multipass list --snapshots
multipass info controller-001 --snapshots
```

To restore, replace the example date with the snapshot name you created. Restoring with `--destructive` discards the current VM state:

```powershell
multipass stop --all
foreach ($vm in "controller-001", "worker-node1", "worker-node2") {
    multipass restore "$vm.cluster-ready-2026-09-21" --destructive
}
multipass start --all
kubectl get nodes
```

Snapshots are stored on the same disk as the VMs, so they are not backups. Purging a VM also removes its snapshots. VirtualBox driver support for snapshots may vary.

## Troubleshooting

- **Workers cannot ping the controller:** Check that each VM has an `enp0s8` address with `multipass exec <vm-name> -- ip -4 addr`. If the interface is missing, recreate the VM with `--network Ethernet`. Check Windows Firewall rules for ICMP on the bridged adapter.
- **A node is `NotReady`:** Wait a few minutes for Calico and image pulls. Inspect pods with `kubectl get pods -A -o wide` and kubelet logs with `sudo journalctl -u kubelet -n 30 --no-pager` on the affected VM.
- **Join command fails or times out:** Confirm it targets the controller's bridged static IP on port `6443`, not `10.0.2.15`. Generate a fresh token if needed with the command above.
- **Cluster breaks after VM restart:** Verify `multipass list` still shows the static IPs. Kubernetes certificates and kubeconfig depend on the controller IP. Correct the static addressing, reset Kubernetes, then rebuild the cluster.
- **Windows `kubectl` uses `localhost:8080` or cannot find a context:** Check `echo $env:KUBECONFIG`, `Test-Path C:\k8s\admin.conf`, and `kubectl config get-contexts`. Recreate the kubeconfig with `Out-File -Encoding ascii` if it was saved as UTF-16.
- **Windows cannot reach the API server:** Run `Test-NetConnection <controller-ip> -Port 6443`. If the controller IP changed, update the kubeconfig.
- **Static IP did not apply:** Inspect `/etc/netplan/60-static-extra0.yaml` in the VM and confirm the bridged interface is named `enp0s8`. The guide's script expects cloud-init's netplan entry to use the `extra0` ID.

## Reset or remove the cluster

Reset a worker's Kubernetes join:

```powershell
multipass exec worker-node1 -- sudo kubeadm reset -f
```

Wipe Kubernetes state but keep the VMs:

```powershell
multipass exec worker-node1 -- sudo kubeadm reset -f
multipass exec worker-node2 -- sudo kubeadm reset -f
multipass exec controller-001 -- sudo kubeadm reset -f
multipass exec controller-001 -- sudo rm -rf /etc/cni/net.d /home/ubuntu/.kube
multipass exec worker-node1 -- sudo rm -rf /etc/cni/net.d
multipass exec worker-node2 -- sudo rm -rf /etc/cni/net.d
multipass restart --all
```

Then repeat controller initialization, worker joins, and verification. Delete the entire cluster and its VM data with:

```powershell
multipass delete --purge controller-001 worker-node1 worker-node2
```

## Configuration reference

| Setting | Value |
| --- | --- |
| Kubernetes | v1.32 |
| Calico | v3.27.0 |
| Pod network | `10.244.0.0/16` |
| Example VM subnet | `192.168.137.0/24` (use your own) |
| Example static IPs | Controller `.101`, workers `.102` and `.103` (choose free addresses) |
| Windows kubeconfig | `C:\k8s\admin.conf` |
| Default Kubernetes context | `kubernetes-admin@kubernetes` |
