# Cluster Setup with kubeadm (Debian/Ubuntu)

## Prerequisites
- **Minimum 2 nodes** (1 control plane + 1 worker)
- **Operating System**: Debian 10+ or Ubuntu 18.04+
- **Hardware per node**:
    - Control plane: 2 CPUs, 2GB RAM minimum
    - Worker nodes: 1 CPU, 1GB RAM minimum
- **Network**: All nodes connected to the same network with full connectivity
- **Root/sudo access** on all nodes
- **Unique hostname** for each node
- **MAC address and product_uuid** must be unique for each node

## Required Network Ports
Ensure the following ports are accessible between nodes:

### Control Plane Node
- **6443**: Kubernetes API server
- **2379-2380**: etcd server client API
- **10250**: kubelet API
- **10259**: kube-scheduler
- **10257**: kube-controller-manager

### Worker Nodes
- **10250**: kubelet API
- **30000-32767**: NodePort Services

### CNI (Flannel) Specific
- **8285/udp**: Flannel VXLAN
- **8472/udp**: Flannel VXLAN

---

## Prepare All Nodes

### Configure System Requirements
On **all nodes**, verify system requirements:

### Disable Swap
Kubernetes requires swap to be disabled:

```bash
# Disable swap temporarily
sudo swapoff -a

# Disable swap permanently by commenting out swap entries in fstab
sudo sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab

# Verify swap is disabled
free -h
# Should show 0B for swap
```

### Set Hostnames (Recommended)
Set meaningful hostnames for your nodes:

```bash
# On control plane node
sudo hostnamectl set-hostname k8s-control

# On worker nodes
sudo hostnamectl set-hostname k8s-worker1
sudo hostnamectl set-hostname k8s-worker2

# Add entries to /etc/hosts for node resolution (optional but helpful)
echo "10.0.0.10 k8s-control" | sudo tee -a /etc/hosts
echo "10.0.0.11 k8s-worker1" | sudo tee -a /etc/hosts
echo "10.0.0.12 k8s-worker2" | sudo tee -a /etc/hosts

# Verify hostname
hostnamectl status
```

---

## Install Container Runtime

### Install containerd
On **all nodes**, install containerd as the container runtime:

```bash
# Update package index
sudo apt-get update

# Install prerequisites
sudo apt-get install -y \
    apt-transport-https \
    ca-certificates \
    curl \
    gnupg \
    lsb-release

# Download and install containerd
CONTAINERD_VERSION="1.7.8"
curl -L "https://github.com/containerd/containerd/releases/download/v${CONTAINERD_VERSION}/containerd-${CONTAINERD_VERSION}-linux-amd64.tar.gz" | sudo tar -C /usr/local -xzv

# Install runc
RUNC_VERSION="1.1.9"
curl -L "https://github.com/opencontainers/runc/releases/download/v${RUNC_VERSION}/runc.amd64" -o runc.amd64
sudo install -m 755 runc.amd64 /usr/local/sbin/runc
rm runc.amd64

# Install CNI plugins
CNI_VERSION="1.3.0"
sudo mkdir -p /opt/cni/bin
curl -L "https://github.com/containernetworking/plugins/releases/download/v${CNI_VERSION}/cni-plugins-linux-amd64-v${CNI_VERSION}.tgz" | sudo tar -C /opt/cni/bin -xz

# Create systemd service file
sudo tee /etc/systemd/system/containerd.service <<EOF
[Unit]
Description=containerd container runtime
Documentation=https://containerd.io
After=network.target local-fs.target

[Service]
ExecStartPre=-/sbin/modprobe overlay
ExecStart=/usr/local/bin/containerd
Type=notify
Delegate=yes
KillMode=process
Restart=always
RestartSec=5
LimitNPROC=infinity
LimitCORE=infinity
LimitCOREDUMP=infinity
TasksMax=infinity
OOMScoreAdjust=-999

[Install]
WantedBy=multi-user.target
EOF

# Reload systemd and start containerd
sudo systemctl daemon-reload
sudo systemctl enable containerd
sudo systemctl start containerd

# Verify containerd is running
sudo systemctl status containerd
```

### Configure containerd for Kubernetes
```bash
# Create containerd configuration directory
sudo mkdir -p /etc/containerd

# Generate default configuration
sudo containerd config default | sudo tee /etc/containerd/config.toml

# Configure systemd cgroup driver (required for kubelet compatibility)
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml

# Restart containerd to apply configuration
sudo systemctl restart containerd

# Verify containerd is working
sudo ctr version
```

---

## Install Kubernetes Tools

### Add Kubernetes Repository
On **all nodes**, add the official Kubernetes package repository:

```bash
# Create keyrings directory
sudo mkdir -p /etc/apt/keyrings

# Download and add Kubernetes GPG key
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.29/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

# Add Kubernetes repository
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.29/deb/ /' | sudo tee /etc/apt/sources.list.d/kubernetes.list

# Update package index
sudo apt-get update
```

### Install kubeadm, kubelet, and kubectl
```bash
# Install Kubernetes tools
sudo apt-get install -y kubelet kubeadm kubectl

# Hold packages to prevent automatic updates (important for cluster stability)
sudo apt-mark hold kubelet kubeadm kubectl

# Enable kubelet service (it will start after kubeadm init)
sudo systemctl enable kubelet

# Verify installation
kubeadm version
kubelet --version
kubectl version --client
```

---

## Initialize the Control Plane

### Preflight Checks
Before initializing, run preflight checks on the control plane node:

```bash
# Run preflight checks without making changes
sudo kubeadm init phase preflight --dry-run

# Check if all required images are available
sudo kubeadm config images list
sudo kubeadm config images pull
```

### Run kubeadm init
On the **control plane node only**:

```bash
# Initialize the cluster with pod network CIDR for Flannel
sudo kubeadm init \
  --pod-network-cidr=10.244.0.0/16 \
  --apiserver-advertise-address=$(hostname -I | awk '{print $1}') \
  --node-name=$(hostname)

# IMPORTANT: Save the join command that appears at the end!
# It will look like this:
# kubeadm join <control-plane-ip>:6443 --token <token> --discovery-token-ca-cert-hash sha256:<hash>
```

**Expected Output**: The initialization will display:
1. Preflight checks
2. Certificate generation
3. Control plane component startup
4. Join command for worker nodes (save this!)

### Configure kubectl for Regular User
```bash
# Create .kube directory
mkdir -p $HOME/.kube

# Copy admin configuration
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config

# Change ownership to current user
sudo chown $(id -u):$(id -g) $HOME/.kube/config

# Verify kubectl access
kubectl cluster-info
```

### Verify Control Plane Status
```bash
# Check node status (will show NotReady until network add-on is installed)
kubectl get nodes

# Check system pods status
kubectl get pods -n kube-system

# Verify API server is accessible
kubectl get componentstatuses
```

---

## Install Network Add-on

### Install Flannel CNI Plugin
Flannel is a simple and reliable network add-on for Kubernetes:

```bash
# Download Flannel manifest
curl -sSL https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml -o kube-flannel.yml

# Review the manifest (optional)
less kube-flannel.yml

# Apply Flannel manifest
kubectl apply -f kube-flannel.yml

# Clean up downloaded file
rm kube-flannel.yml
```

### Verify Network Add-on Installation
```bash
# Wait for Flannel pods to be running (may take 1-2 minutes)
kubectl get pods -n kube-flannel

# Check that all pods are in Running state
kubectl get pods -n kube-flannel -w

# Verify control plane node is now Ready
kubectl get nodes

# Check Flannel logs if there are issues
kubectl logs -n kube-flannel -l app=flannel
```

---

## Join Worker Nodes

### Join Worker Nodes to Cluster
On each **worker node**, run the join command from the control plane initialization:

```bash
# Use the exact command from kubeadm init output
# Example (replace with your actual values):
sudo kubeadm join 10.0.0.10:6443 --token abcdef.1234567890abcdef --discovery-token-ca-cert-hash sha256:1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef
```

### If Join Token is Lost or Expired
If you didn't save the join command or the token expired:

```bash
# On the control plane node, generate a new join command
kubeadm token create --print-join-command

# Or create token and get CA cert hash separately
kubeadm token create
kubeadm token list
openssl x509 -pubkey -in /etc/kubernetes/pki/ca.crt | openssl rsa -pubin -outform der 2>/dev/null | openssl dgst -sha256 -hex | sed 's/^.* //'
```

### Verify Worker Node Join
On the **control plane node**, verify that worker nodes have joined:

```bash
# Check all nodes are present and Ready
kubectl get nodes

# Check detailed node information
kubectl get nodes -o wide

# Verify all system pods are running
kubectl get pods -n kube-system
kubectl get pods -n kube-flannel
```

---

## Verify Cluster Setup

### Comprehensive Cluster Verification
On the **control plane node**:

```bash
# Check cluster information
kubectl cluster-info

# Verify all nodes are Ready
kubectl get nodes

# Check all system pods are running
kubectl get pods --all-namespaces

# Verify cluster components
kubectl get componentstatuses

# Check cluster resource usage
kubectl top nodes
```

### Deploy and Test Sample Application
```bash
# Create a test deployment
kubectl create deployment nginx --image=nginx:1.21

# Scale the deployment to test scheduling
kubectl scale deployment nginx --replicas=3

# Expose the deployment as a NodePort service
kubectl expose deployment nginx --port=80 --type=NodePort

# Get service details
kubectl get svc nginx

# Check pod distribution across nodes
kubectl get pods -o wide

# Test application access (replace <node-ip> and <node-port> with actual values)
NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
NODE_PORT=$(kubectl get svc nginx -o jsonpath='{.spec.ports[0].nodePort}')
curl http://$NODE_IP:$NODE_PORT

# Clean up test resources
kubectl delete deployment nginx
kubectl delete service nginx
```

### Test DNS Resolution
```bash
# Test cluster DNS
kubectl run test-dns --image=busybox --rm -it --restart=Never -- nslookup kubernetes.default

# Test inter-pod communication
kubectl run test-pod1 --image=nginx --port=80
kubectl expose pod test-pod1 --port=80
kubectl run test-pod2 --image=busybox --rm -it --restart=Never -- wget -qO- http://test-pod1

# Clean up
kubectl delete pod test-pod1
kubectl delete service test-pod1
```

---

## Configuration File Alternative

Instead of command-line arguments, you can use a configuration file with `kubeadm init`:

```bash
# Generate default config template
kubeadm config print init-defaults > kubeadm-config.yaml

# Edit the configuration file
cat <<EOF > kubeadm-config.yaml
apiVersion: kubeadm.k8s.io/v1beta3
kind: InitConfiguration
localAPIEndpoint:
  advertiseAddress: $(hostname -I | awk '{print $1}')
  bindPort: 6443
nodeRegistration:
  name: $(hostname)
  criSocket: unix:///var/run/containerd/containerd.sock
---
apiVersion: kubeadm.k8s.io/v1beta3
kind: ClusterConfiguration
kubernetesVersion: v1.29.0
networking:
  serviceSubnet: "10.96.0.0/12"
  podSubnet: "10.244.0.0/16"
  dnsDomain: "cluster.local"
apiServer:
  advertiseAddress: $(hostname -I | awk '{print $1}')
controllerManager: {}
scheduler: {}
etcd:
  local:
    dataDir: "/var/lib/etcd"
---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
cgroupDriver: systemd
EOF

# Use config file for initialization
sudo kubeadm init --config kubeadm-config.yaml
```

---

## Common Issues and Troubleshooting

### Node Not Joining
If worker nodes fail to join the cluster:

```bash
# On worker node, check kubelet logs
sudo journalctl -xeu kubelet

# Reset the node and try again
sudo kubeadm reset --force
sudo systemctl restart containerd
sudo systemctl restart kubelet

# Verify containerd is running
sudo systemctl status containerd

# Check network connectivity to control plane
telnet <control-plane-ip> 6443

# Regenerate join command on control plane
kubeadm token create --print-join-command
```

### Pods Stuck in Pending State
If pods are stuck in pending state:

```bash
# Check node resources and capacity
kubectl describe nodes
kubectl top nodes

# Check for taints on nodes
kubectl get nodes -o json | jq '.items[].spec.taints'

# For single-node testing, remove control plane taint
kubectl taint nodes --all node-role.kubernetes.io/control-plane-

# Check scheduler logs
kubectl logs -n kube-system -l component=kube-scheduler
```

### Network Issues
If you experience network connectivity issues:

```bash
# Check Flannel status
kubectl get pods -n kube-flannel
kubectl get daemonsets -n kube-flannel

# Restart Flannel pods
kubectl delete pods -n kube-flannel -l app=flannel

# Check Flannel logs
kubectl logs -n kube-flannel -l app=flannel

# Verify CNI configuration
sudo ls -la /etc/cni/net.d/
sudo cat /etc/cni/net.d/10-flannel.conflist

# Check iptables rules (should show flannel rules)
sudo iptables -t nat -L
sudo iptables -L
```

### Control Plane Issues
If control plane components are not starting:

```bash
# Check control plane pod logs
kubectl logs -n kube-system <pod-name>

# Check static pod manifests
sudo ls -la /etc/kubernetes/manifests/

# Verify kubelet service
sudo systemctl status kubelet
sudo journalctl -u kubelet

# Check containerd
sudo systemctl status containerd
sudo ctr containers list

# Restart kubelet if needed
sudo systemctl restart kubelet
```

### Certificate Issues
If you encounter certificate-related errors:

```bash
# Check certificate expiration
sudo kubeadm certs check-expiration

# Renew certificates if needed
sudo kubeadm certs renew all

# Restart control plane components
sudo systemctl restart kubelet
```

---

## Security Hardening (Basic)

### Enable Audit Logging
```bash
# Create audit policy
sudo mkdir -p /etc/kubernetes/audit
sudo tee /etc/kubernetes/audit/audit-policy.yaml <<EOF
apiVersion: audit.k8s.io/v1
kind: Policy
rules:
- level: Request
  resources:
  - group: ""
    resources: ["pods", "services"]
  namespaces: ["default"]
EOF

# Add audit configuration to kube-apiserver
# Edit /etc/kubernetes/manifests/kube-apiserver.yaml and add:
# --audit-log-path=/var/log/audit.log
# --audit-policy-file=/etc/kubernetes/audit/audit-policy.yaml
```

### Network Policies (Optional)
```bash
# Example: Deny all network traffic by default
kubectl apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: default
spec:
  podSelector: {}
  policyTypes:
  - Ingress
  - Egress
EOF
```

---

## Maintenance Commands

### Useful Day-2 Operations
```bash
# Drain a node for maintenance
kubectl drain <node-name> --ignore-daemonsets --delete-emptydir-data

# Uncordon a node after maintenance
kubectl uncordon <node-name>

# Get cluster events
kubectl get events --sort-by='.lastTimestamp'

# View resource usage
kubectl top nodes
kubectl top pods --all-namespaces

# Backup etcd (control plane node)
sudo ETCDCTL_API=3 etcdctl snapshot save backup.db \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/healthcheck-client.crt \
  --key=/etc/kubernetes/pki/etcd/healthcheck-client.key

# Check cluster version
kubectl version
kubeadm version
```

### Cluster Upgrade (Overview)
```bash
# Check available versions
kubeadm upgrade plan

# Upgrade control plane (example for patch version)
sudo kubeadm upgrade apply v1.29.1

# Upgrade kubelet and kubectl
sudo apt-mark unhold kubelet kubectl
sudo apt-get update
sudo apt-get install -y kubelet=1.29.1-* kubectl=1.29.1-*
sudo apt-mark hold kubelet kubectl
sudo systemctl restart kubelet
```

This completes a comprehensive Kubernetes cluster setup using kubeadm with all necessary configurations, verifications, and troubleshooting steps for Debian/Ubuntu systems.
# Check if MAC address and product_uuid are unique
ip link show
sudo cat /sys/class/dmi/id/product_uuid

# Verify system meets minimum requirements
free -h
nproc
```

### Configure Firewall
On **all nodes**, configure firewall rules using ufw:

```bash
# Control plane node
sudo ufw allow 22/tcp       # SSH
sudo ufw allow 6443/tcp     # Kubernetes API server
sudo ufw allow 2379:2380/tcp # etcd server client API  
sudo ufw allow 10250/tcp    # kubelet API
sudo ufw allow 10259/tcp    # kube-scheduler
sudo ufw allow 10257/tcp    # kube-controller-manager
sudo ufw allow 8285/udp     # Flannel VXLAN
sudo ufw allow 8472/udp     # Flannel VXLAN
sudo ufw allow 30000:32767/tcp # NodePort services

# Worker nodes (skip etcd, scheduler, controller ports)
sudo ufw allow 22/tcp       # SSH
sudo ufw allow 10250/tcp    # kubelet API
sudo ufw allow 8285/udp     # Flannel VXLAN
sudo ufw allow 8472/udp     # Flannel VXLAN
sudo ufw allow 30000:32767/tcp # NodePort services

# Enable firewall
sudo ufw --force enable

# Verify firewall status
sudo ufw status verbose
```

### Configure Kernel Settings
On **all nodes**, configure kernel parameters for Kubernetes networking:

```bash
# Load required kernel modules
sudo modprobe overlay
sudo modprobe br_netfilter

# Ensure modules load on boot
cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

# Configure sysctl parameters
cat <<EOF | sudo tee /etc/sysctl.d/99-kubernetes-cri.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
net.ipv6.ip_forward                 = 1
EOF

# Apply sysctl parameters without reboot
sudo sysctl --system

# Verify settings are applied
lsmod | grep br_netfilter
lsmod | grep overlay
sysctl net.bridge.bridge-nf-call-iptables net.bridge.bridge-nf-call-ip6tables net.ipv4.ip_forward
```

### Disable Swap
Kubernetes requires swap to be disabled:

```bash