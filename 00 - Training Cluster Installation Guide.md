## VirtualBox Configuration

- Disable Hyper-V on Windows if necessary (execute from PowerShell)

```bash
bcdedit /set hypervisorlaunchtype off
```
- Go to File->Tools->Network manager menu
- Create a new NAT network and name it `kubernetes`
- Configure the created network
    - Network address: 192.168.1.0/24
    - Port forwarding rules:

| Name   |  Protocol  |  Host IP    | Host Port  |   Guest IP    | Guest Port  |
|:------:|:----------:|:-----------:|:----------:|:-------------:|:-----------:|
| Rule 1 |    TCP     |  127.0.0.1  |   10022    | 192.168.1.100 |     22      |
| Rule 2 |    TCP     |  127.0.0.1  |   10023    | 192.168.1.10  |     22      |
| Rule 3 |    TCP     |  127.0.0.1  |   10024    | 192.168.1.11  |     22      |
| Rule 4 |    TCP     |  127.0.0.1  |   10025    | 192.168.1.12  |     22      |

## Base machine preparation

- Configure new machine:
    - Name: Debian
    - Type/Version: Debian (64-bit)
    - RAM: 4096 MB
    - Processor: 2 CPU
    - Hard disk: 512 GB, dynamically allocated
    - Network card: NAT network named `kubernetes`
- Install Debian system
    - Root password: k8s
    - User: k8s
    - Password: k8s
    - Hostname: debian
    - Packages to install:
        - SSH Server
        - Basic system utilities
- Disable cd/dvd as package source - remove line starting with `deb cdrom`
```bash
nano /etc/apt/sources.list
```
- Update system and install basic tools
```bash
apt update 
```
```bash
apt install sudo net-tools curl git gnupg
```
- Add user k8s to sudo group
```bash
usermod -aG sudo k8s
```
- Disable dhcp and set static IP address
```bash
sudo nano /etc/network/interfaces
```
```bash
# iface enp0s3 inet dhcp
iface enp0s3 inet static
      address 192.168.1.100
      netmask 255.255.255.0
      gateway 192.168.1.1
```
# Cluster installation
- Clone base machine and name it master
```bash
sudo hostnamectl set-hostname master
```
- Disable swap
```bash
swapoff -a
```
```bash
sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab
```
- Install Kubernetes tools and CRI-O https://github.com/cri-o/packaging?tab=readme-ov-file
```bash
apt-get update
apt-get install -y software-properties-common

KUBERNETES_VERSION=v1.34
CRIO_VERSION=v1.34

curl -fsSL https://pkgs.k8s.io/core:/stable:/$KUBERNETES_VERSION/deb/Release.key |
    gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/$KUBERNETES_VERSION/deb/ /" |
    tee /etc/apt/sources.list.d/kubernetes.list
    
curl -fsSL https://download.opensuse.org/repositories/isv:/cri-o:/stable:/$CRIO_VERSION/deb/Release.key |
    gpg --dearmor -o /etc/apt/keyrings/cri-o-apt-keyring.gpg

echo "deb [signed-by=/etc/apt/keyrings/cri-o-apt-keyring.gpg] https://download.opensuse.org/repositories/isv:/cri-o:/stable:/$CRIO_VERSION/deb/ /" |
    tee /etc/apt/sources.list.d/cri-o.list
    
apt-get update
apt-get install -y cri-o kubelet kubeadm kubectl

systemctl start crio.service    
systemctl enable crio.service    

sysctl -w net.ipv4.ip_forward=1

cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

sudo modprobe overlay
sudo modprobe br_netfilter

cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

sudo sysctl --system
```
- Set IP address
```bash
sudo nano /etc/network/interfaces
```
```bash
# iface enp0s3 inet dhcp
iface enp0s3 inet static
      address 192.168.1.10
      netmask 255.255.255.0
      gateway 192.168.1.1
```
- Define addresses of remaining machines
```bash
sudo nano /etc/hosts
```
```bash
192.168.1.10 master    
192.168.1.11 node1    
192.168.1.12 node2    
```
- Clone master machine twice and set names and IP addresses for node1 and node2
- Initialize cluster on master machine
```bash
sudo kubeadm init --control-plane-endpoint=master
```
```bash
mkdir -p $HOME/.kube
```
```bash
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
```
```bash
sudo chown $(id -u):$(id -g) $HOME/.kube/config
```
- Join remaining machines (node1, node2) following the displayed instructions
- Install network layer
```bash
kubectl apply -f https://projectcalico.docs.tigera.io/manifests/calico.yaml
```
- Allow root user login on master machine
```bash
nano /etc/ssh/sshd_config  (set PermitRootLogin yes)
```
```bash
/etc/init.d/ssh restart
```
- Clone base machine and set name and IP address for admin
- Install kubectl https://kubernetes.io/docs/tasks/tools/install-kubectl-linux/
```bash
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
```
```bash
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
```
- Copy configuration from master machine
```bash
mkdir ~/.kube
```
```bash
scp root@192.168.1.10:/etc/kubernetes/admin.conf ~/.kube/local
```
```bash
echo export KUBECONFIG=~/.kube/local >> ~/.bashrc
```
- Configure bash completion
```bash
echo "source <(kubectl completion bash)" >> ~/.bashrc
```
```bash
source .bash_profile
```
