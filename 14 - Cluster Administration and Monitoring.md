# Cluster Administration and Monitoring

This chapter is a practical, step-by-step guide to administering a **vanilla kubeadm** Kubernetes cluster. It covers:

* how to **safely upgrade** the cluster (control plane + nodes),
* how to **backup etcd** (snapshots) and **restore** from them,
* how to **secure / encrypt etcd** (both TLS for etcd communication and data-at-rest options),
* how to **encrypt Kubernetes secrets stored in etcd** (Kubernetes API server encryption at rest),
* verification steps and useful recovery tips,
* day-to-day **node administration and monitoring** (node state, static Pods, cordon/drain, Metrics Server, events).

We assume a kubeadm-managed cluster where the control plane runs as static pods on one or more control-plane hosts (default kubeadm layout). Adapt paths/commands if you run an external etcd cluster or cloud-managed control plane.

---

## Cluster Upgrade and Backup

### 1. Safe preparation checklist (do this first)

1. Work on a maintenance window; notify users.
2. Take an immediate etcd snapshot before any change. (Commands below.)
3. Ensure you have SSH access to control plane and all worker nodes.
4. Back up the `/etc/kubernetes` directory (certs, manifests).

   ```bash
   sudo tar czf /root/k8s-etc-k8s-$(date -I).tgz /etc/kubernetes
   ```
5. Record current versions:

   ```bash
   kubectl version
   kubeadm version
   uname -a
   lsb_release -a  # or cat /etc/os-release
   ```
6. If using HA (multiple control planes), read the HA notes later in this doc.

---

### 2. How kubeadm cluster upgrade works (high level)

* `kubeadm upgrade plan` checks available control-plane versions you can upgrade to.
* You can upgrade only one MINOR version at a time (e.g. 1.36.x -> 1.37.x); skipping minor versions is unsupported.
* With the `pkgs.k8s.io` package repositories, each minor version has its own repository - switch it to the target minor version first.
* Upgrade order:

    1. Upgrade the `kubeadm` package on the first control-plane node.
    2. Run `kubeadm upgrade apply <version>` on that node - this upgrades the control plane static Pod manifests (kube-apiserver, kube-controller-manager, kube-scheduler, and stacked etcd) and cluster add-ons (CoreDNS, kube-proxy).
    3. On every other control-plane node and on every worker: upgrade `kubeadm`, then run `kubeadm upgrade node`.
    4. Drain each node, upgrade the kubelet and kubectl packages, restart kubelet, uncordon the node.
* For HA clusters (multiple control planes), upgrade control planes one at a time.

> Important: always take an etcd snapshot before upgrades.

---

### 3. Upgrade example (Ubuntu/Debian with apt) - step-by-step

> Replace `<K8S_VERSION>` with the target `vX.Y.Z` (e.g. `v1.37.1`) and `<PKG_VERSION>` with the matching package version without the `v` (e.g. `1.37.1-1.1`; list them with `apt-cache madison kubeadm`). Use the exact version returned by `kubeadm upgrade plan`.

#### 3.1 On the control-plane node - take etcd snapshot first

(We run this on the control plane so we can access the local etcd via the static pod certs.)

> kubeadm does not install `etcdctl`/`etcdutl` on the host. Download the release matching the cluster's etcd version (check with `kubectl -n kube-system get pod etcd-<node> -o jsonpath='{.spec.containers[0].image}'`; Kubernetes 1.37 uses etcd 3.7.0):
>
> ```bash
> ETCD_VER=v3.7.0
> curl -fsSL https://github.com/etcd-io/etcd/releases/download/${ETCD_VER}/etcd-${ETCD_VER}-linux-amd64.tar.gz | tar xz -C /tmp
> sudo install /tmp/etcd-${ETCD_VER}-linux-amd64/etcdctl /tmp/etcd-${ETCD_VER}-linux-amd64/etcdutl /usr/bin/
> ```
>
> Alternatively run them inside the etcd static Pod: `kubectl -n kube-system exec etcd-<node> -- etcdctl ...`.

```bash
# Export envs for convenience
export ETCD_CERT_DIR=/etc/kubernetes/pki/etcd
export SNAPSHOT_DIR=/root/etcd-backups
sudo mkdir -p ${SNAPSHOT_DIR}

# snapshot with etcdctl v3; use the certificate files kubeadm created by default
sudo ETCDCTL_API=3 \
  /usr/bin/etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=${ETCD_CERT_DIR}/ca.crt \
  --cert=${ETCD_CERT_DIR}/server.crt \
  --key=${ETCD_CERT_DIR}/server.key \
  snapshot save ${SNAPSHOT_DIR}/etcd-snap-$(date -Iseconds).db

ls -lh ${SNAPSHOT_DIR}
```

#### 3.2 Upgrade `kubeadm` and plan

```bash
# Point the pkgs.k8s.io repository to the target minor version (example: v1.36 -> v1.37)
sudo sed -i 's#/v1.36/#/v1.37/#' /etc/apt/sources.list.d/kubernetes.list

# Update package lists and install desired kubeadm
sudo apt-mark unhold kubeadm
sudo apt-get update
sudo apt-get install -y kubeadm='<PKG_VERSION>'
sudo apt-mark hold kubeadm

# Check upgrade plan
sudo kubeadm upgrade plan
```

Read the output carefully: it will list recommended target version and image pull steps.

#### 3.3 Apply control-plane upgrade

```bash
sudo kubeadm upgrade apply <K8S_VERSION>
# e.g. sudo kubeadm upgrade apply v1.37.1
```

This updates the static pod manifests under `/etc/kubernetes/manifests/` to use newer component images. kubelet will restart the static pod.

Verify:

```bash
kubectl get nodes
kubectl get --raw='/readyz?verbose'
kubectl -n kube-system get pods -o wide
```

On additional control-plane nodes (HA) run `sudo kubeadm upgrade node` instead of `kubeadm upgrade apply` (after upgrading the `kubeadm` package there).

#### 3.4 Upgrade kubelet & kubectl on control-plane node

```bash
kubectl drain <control-plane-node> --ignore-daemonsets
sudo apt-mark unhold kubelet kubectl
sudo apt-get install -y kubelet='<PKG_VERSION>' kubectl='<PKG_VERSION>'
sudo apt-mark hold kubelet kubectl
sudo systemctl daemon-reload
sudo systemctl restart kubelet
kubectl uncordon <control-plane-node>
```

#### 3.5 For worker nodes (one-by-one)

For each worker node:

```bash
# On node (after switching its pkgs.k8s.io repository to the new minor version, as in 3.2):
sudo apt-mark unhold kubeadm
sudo apt-get update
sudo apt-get install -y kubeadm='<PKG_VERSION>'
sudo apt-mark hold kubeadm
sudo kubeadm upgrade node

# On control plane:
kubectl drain <node> --ignore-daemonsets --delete-emptydir-data

# On node:
sudo apt-mark unhold kubelet kubectl
sudo apt-get install -y kubelet='<PKG_VERSION>' kubectl='<PKG_VERSION>'
sudo apt-mark hold kubelet kubectl
sudo systemctl daemon-reload
sudo systemctl restart kubelet

# back on control plane:
kubectl uncordon <node>
```

---

### 4. etcd - backup (snapshot) and restore (detailed)

#### 4.1 Where etcd data is

* For kubeadm-managed stacked etcd, the data dir is usually: `/var/lib/etcd`.
* Static pod manifest for etcd is `/etc/kubernetes/manifests/etcd.yaml`.

#### 4.2 Take a consistent etcd snapshot (recommended)

Use `etcdctl` binary from the node where etcd runs (control-plane node).

```bash
# variables
export ETCDCTL_API=3
export ETCD_CERT_DIR=/etc/kubernetes/pki/etcd
export SNAPSHOT_DIR=/root/etcd-backups
sudo mkdir -p ${SNAPSHOT_DIR}

# snapshot
sudo ETCDCTL_API=3 \
  /usr/bin/etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=${ETCD_CERT_DIR}/ca.crt \
  --cert=${ETCD_CERT_DIR}/server.crt \
  --key=${ETCD_CERT_DIR}/server.key \
  snapshot save ${SNAPSHOT_DIR}/etcd-snap-$(date -Iseconds).db

# check snapshot status (etcdctl snapshot status/restore were removed in etcd 3.6 - use etcdutl)
sudo /usr/bin/etcdutl \
  snapshot status ${SNAPSHOT_DIR}/etcd-snap-*.db \
  --write-out=table
```

Store `*.db` snapshot in immutable off-site storage (scp to backup server, S3, etc).

#### 4.3 Restoring etcd from snapshot (single control-plane example)

> This is destructive for existing etcd - only perform if you need a restore.

1. Stop etcd and kube-apiserver. They are static pods, so stopping kubelet alone does not stop the running containers - move their manifests out of the manifests directory and kubelet will stop them:

```bash
sudo mkdir -p /root/manifests-backup
sudo mv /etc/kubernetes/manifests/etcd.yaml /etc/kubernetes/manifests/kube-apiserver.yaml /root/manifests-backup/
# wait until the etcd and kube-apiserver containers are gone (e.g. sudo crictl ps)
```

2. Move old data dir (safe copy). `etcdutl snapshot restore` creates the data dir itself and refuses to overwrite an existing one.

```bash
sudo mv /var/lib/etcd /var/lib/etcd-old-$(date -Iseconds)
```

3. Restore snapshot to data-dir with `etcdutl snapshot restore`. `--name` and the peer URL must match `--name` and `--initial-advertise-peer-urls` in `etcd.yaml` (kubeadm uses the node name and node IP).

```bash
SNAP=${SNAPSHOT_DIR}/etcd-snap-2026-11-04T12:34:56+00:00.db  # your snapshot file
RESTORE_DIR=/var/lib/etcd
NODE_IP=192.168.1.10   # control-plane node IP (see etcd.yaml)

sudo /usr/bin/etcdutl snapshot restore ${SNAP} \
  --data-dir ${RESTORE_DIR} \
  --name $(hostname -s) \
  --initial-advertise-peer-urls https://${NODE_IP}:2380 \
  --initial-cluster $(hostname -s)=https://${NODE_IP}:2380
```

> For HA with multiple control-planes, restoring is more involved - you usually restore a snapshot to one member, then rejoin other members or rebuild nodes. See HA notes below.

4. The kubeadm etcd container runs as root, so no ownership change is needed.

5. Move the manifests back:

```bash
sudo mv /root/manifests-backup/etcd.yaml /root/manifests-backup/kube-apiserver.yaml /etc/kubernetes/manifests/
```

kubelet will start the static pods (etcd, kube-apiserver) again. Verify the etcd member is healthy:

```bash
sudo ETCDCTL_API=3 /usr/bin/etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  endpoint status --write-out=table
```

Then check `kubectl get nodes` and `kubectl get pods -A`.

---

### 5. Encrypt etcd communication (TLS) - why & how

* By default kubeadm generates TLS certs for etcd under `/etc/kubernetes/pki/etcd/` and configures the static pod to use certs. This secures:

    * peer communication (etcd peer-to-peer),
    * client communication (kube-apiserver <-> etcd),
    * external access to etcd (if you expose it, protect it).
* Verify TLS is enabled: check `/etc/kubernetes/manifests/etcd.yaml` includes `--cert-file`/`--key-file`/`--trusted-ca-file` flags. If not, generate certs and update manifest.

#### 5.1 How to generate strong certs (example using cfssl or openssl)

> Warning: on a kubeadm cluster these certificates already exist and are managed by kubeadm (`sudo kubeadm certs check-expiration`, `sudo kubeadm certs renew etcd-server`). Replacing `/etc/kubernetes/pki/etcd/ca.crt` with a new CA invalidates every other etcd certificate (peer, healthcheck-client, apiserver-etcd-client) and breaks the control plane. Use the manual procedure below only for a self-managed (external) etcd.

Below an openssl example to create a self-signed CA and certs (replace with a PKI of your choice or use your organization's CA).

```bash
# create work dir
mkdir -p /root/etcd-certs && cd /root/etcd-certs

# 1) CA
openssl genrsa -out ca.key 4096
openssl req -x509 -new -nodes -key ca.key -subj "/CN=etcd-ca" -days 3650 -out ca.crt

# 2) Server key & CSR
openssl genrsa -out server.key 4096
openssl req -new -key server.key -subj "/CN=etcd-server" -out server.csr \
  -addext "subjectAltName = IP:127.0.0.1,IP:$(hostname -I | awk '{print $1}'),DNS:$(hostname -f)"

# 3) Sign server cert
openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
  -out server.crt -days 3650 -sha256 \
  -extfile <(printf "subjectAltName=IP:127.0.0.1,IP:%s,DNS:%s\n" "$(hostname -I | awk '{print $1}')" "$(hostname -f)")
```

Copy `ca.crt`, `server.crt`, `server.key` to `/etc/kubernetes/pki/etcd/` (back up originals first), and adjust ownership:

```bash
sudo cp ca.crt server.crt server.key /etc/kubernetes/pki/etcd/
sudo chown root:root /etc/kubernetes/pki/etcd/*.crt /etc/kubernetes/pki/etcd/*.key
sudo chmod 600 /etc/kubernetes/pki/etcd/*.key
```

Then edit `/etc/kubernetes/manifests/etcd.yaml` to ensure flags include:

```yaml
--cert-file=/etc/kubernetes/pki/etcd/server.crt
--key-file=/etc/kubernetes/pki/etcd/server.key
--trusted-ca-file=/etc/kubernetes/pki/etcd/ca.crt
--client-cert-auth=true
```

kubelet will automatically restart the etcd static pod. Confirm etcd endpoints are accessible only via TLS:

```bash
# This should work
ETCDCTL_API=3 /usr/bin/etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  endpoint status --write-out=table

# This (without certs) should fail
ETCDCTL_API=3 /usr/bin/etcdctl --endpoints=http://127.0.0.1:2379 endpoint status
```

---

### 6. Encrypt etcd data at rest - options & examples

There are three common approaches:

#### Option A - Disk-level encryption (LUKS) for `/var/lib/etcd`

Encrypt the underlying disk or partition using LUKS (recommended for on-prem single-host encryption). Example: create encrypted LVM or LUKS partition and mount it to `/var/lib/etcd` before starting etcd.

Quick LUKS example (DESTROYS DEVICE - be careful):

```bash
# example device: /dev/sdb  -- double-check device!
sudo cryptsetup luksFormat /dev/sdb
sudo cryptsetup luksOpen /dev/sdb etcdcrypt
sudo mkfs.ext4 /dev/mapper/etcdcrypt
sudo mkdir -p /var/lib/etcd
sudo mount /dev/mapper/etcdcrypt /var/lib/etcd
# add /etc/fstab entry and keyscript to unlock on boot if desired (or use systemd-cryptsetup)
```

Pros: full-disk encryption, transparent to etcd. Cons: requires key management at OS level and boot unlock.

#### Option B - etcd data encryption using filesystem-level encryption or application-layer encryption

etcd itself doesn't provide built-in general data-at-rest encryption for its files beyond using TLS for in-transit and snapshots; so application-layer encryption (encrypting individual sensitive objects) or disk-level encryption is normally used. For Kubernetes secrets, use Kubernetes API server encryption (Option C below) rather than relying on etcd-level encryption.

#### Option C - Kubernetes API server encryption at rest (recommended to encrypt Kubernetes Secrets at rest)

This does not encrypt the whole etcd data but encrypts sensitive Kubernetes API resources (Secrets, configmaps, etc) before storing them in etcd. This is typically what people mean by "encrypt etcd data (secrets)". Steps:

##### 6.1 Create an encryption config file

Create `/etc/kubernetes/enc/encryption-config.yaml` on the control-plane node(s):

```yaml
apiVersion: apiserver.config.k8s.io/v1
kind: EncryptionConfiguration
resources:
  - resources:
      - secrets
    providers:
      - secretbox:   # aescbc also works but is no longer recommended (padding oracle attacks)
          keys:
            - name: key1
              secret: <BASE64_32_BYTES>
      - identity: {}
```

`<BASE64_32_BYTES>` must be a 32-byte base64 value (for production prefer the `kms` v2 provider with an external KMS - stable since v1.29; `kms` v1 is deprecated). Generate it:

```bash
head -c 32 /dev/urandom | base64
# place that string as the secret value
```

##### 6.2 Put the file on the control plane and secure it

```bash
sudo mkdir -p /etc/kubernetes/enc
sudo chown root:root /etc/kubernetes/enc/encryption-config.yaml
sudo chmod 600 /etc/kubernetes/enc/encryption-config.yaml
```

##### 6.3 Configure kube-apiserver to use it

Edit `/etc/kubernetes/manifests/kube-apiserver.yaml` - add the flag to the kube-apiserver command args and mount the directory into the static pod (the kubeadm manifest does not mount `/etc/kubernetes/enc` by default):

```yaml
    - --encryption-provider-config=/etc/kubernetes/enc/encryption-config.yaml
    ...
    volumeMounts:
    - name: enc
      mountPath: /etc/kubernetes/enc
      readOnly: true
  ...
  volumes:
  - name: enc
    hostPath:
      path: /etc/kubernetes/enc
      type: DirectoryOrCreate
```

kubelet will restart the kube-apiserver static pod automatically.

##### 6.4 Re-encrypt existing secrets

New secrets will be encrypted from now on. To encrypt existing secrets in etcd, you must:

1. Make sure `--encryption-provider-config` is active and kube-apiserver restarted.
2. Re-save all secrets (the easiest approach - this forces them to be written back through the API server and be re-encrypted):

```bash
kubectl get secrets --all-namespaces -o json | kubectl replace -f -
```

##### 6.5 Verify encryption

1. Create a test secret and read the raw object from etcd with etcdctl; the stored value must start with `k8s:enc:secretbox:v1:key1:` followed by binary data, and the cleartext value must not be visible:

```bash
kubectl create ns encrypt-test || true
kubectl -n encrypt-test create secret generic mysecret --from-literal=k=secret123

sudo /usr/bin/etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  get /registry/secrets/encrypt-test/mysecret | hexdump -C | head
```

---

### 7. Best practices & verification checklist

* Always take snapshots before upgrades or critical changes.
* Store snapshots off-host (S3, remote storage) and rotate snapshots.
* Test restore on a non-production environment.
* Keep encryption keys (for LUKS and API server encryption) secure and backed up.
* Keep `/etc/kubernetes/enc/encryption-config.yaml` off accessible backups or in a secure secrets manager.
* Periodically test your disaster recovery plan end-to-end.
* Use role-based access and limit etcd access (only kube-apiserver client cert should be able to read/write).

---

### 8. HA cluster notes (multiple control planes)

* For HA, etcd runs as a clustered set across control-plane nodes.
* Backup: you can snapshot any healthy member (`etcdctl snapshot save` accepts only a single endpoint); check member health first with `etcdctl endpoint status --cluster`.
* Upgrade control planes one at a time: take snapshot, upgrade one control-plane, verify cluster health before moving to the next.
* Restoring HA: usually rebuild one control-plane from snapshot and rejoin the cluster or rebuild cluster from snapshot as a single-member and then re-add members - careful and follow etcd HA protocols.

---

### 9. Quick troubleshooting commands

* Check etcd health:

```bash
sudo ETCDCTL_API=3 /usr/bin/etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  endpoint health
```

* Check cluster members:

```bash
sudo ETCDCTL_API=3 /usr/bin/etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  member list
```

* If kube-apiserver won't start after encryption configuration, check `/var/log/pods/...`, `sudo crictl ps -a` / `sudo crictl logs <container-id>` (CRI-O, cri-tools package) and `journalctl -u kubelet`. Common cause: wrong path/permissions of `encryption-config.yaml` or a missing volume mount.

---

### 10. Example scripts (putting it together)

#### 10.1 Snapshot script (save to local and copy to remote)

Save as `/usr/local/bin/etcd-backup.sh`:

```bash
#!/bin/bash
set -euo pipefail
ETCDCTL=/usr/bin/etcdctl
ETCD_CERT_DIR=/etc/kubernetes/pki/etcd
SNAP_DIR=/root/etcd-backups
REMOTE_DEST=user@backup.example.com:/backups/etcd

mkdir -p "$SNAP_DIR"

TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
SNAP="${SNAP_DIR}/etcd-snap-${TS}.db"

sudo ETCDCTL_API=3 $ETCDCTL \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=${ETCD_CERT_DIR}/ca.crt \
  --cert=${ETCD_CERT_DIR}/server.crt \
  --key=${ETCD_CERT_DIR}/server.key \
  snapshot save "${SNAP}"

# optional remote copy
scp "${SNAP}" ${REMOTE_DEST}
echo "snapshot saved: ${SNAP}"
```

Make executable: `sudo chmod +x /usr/local/bin/etcd-backup.sh`

#### 10.2 Quick restore guide (comments in script)

No automatic destructive restore script is provided here - restores require human checks. Use the manual procedure in section 4.3.

---

### 11. Summary of key commands (cheat-sheet)

Take snapshot:

```bash
sudo ETCDCTL_API=3 /usr/bin/etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  snapshot save /root/etcd-backups/etcd-snap-$(date -Iseconds).db
```

Restore (manual, read instructions above):

```bash
sudo mv /etc/kubernetes/manifests/{etcd,kube-apiserver}.yaml /root/manifests-backup/
sudo mv /var/lib/etcd /var/lib/etcd-old-$(date -Iseconds)
sudo /usr/bin/etcdutl snapshot restore <snap.db> --data-dir /var/lib/etcd --name <name> --initial-cluster <...> --initial-advertise-peer-urls <...>
sudo mv /root/manifests-backup/{etcd,kube-apiserver}.yaml /etc/kubernetes/manifests/
```

Enable kube-apiserver encryption at rest:

1. create `/etc/kubernetes/enc/encryption-config.yaml` (see section 6)
2. add `--encryption-provider-config=/etc/kubernetes/enc/encryption-config.yaml` (plus the volume mount) to `/etc/kubernetes/manifests/kube-apiserver.yaml`
3. re-apply secrets to re-encrypt.

Upgrade kubeadm control plane:

```bash
# after switching /etc/apt/sources.list.d/kubernetes.list to the new minor version
sudo apt-mark unhold kubeadm kubelet kubectl
sudo apt-get update && sudo apt-get install -y kubeadm='<PKG_VERSION>'
sudo kubeadm upgrade apply <K8S_VERSION>     # other nodes: sudo kubeadm upgrade node
sudo apt-get install -y kubelet='<PKG_VERSION>' kubectl='<PKG_VERSION>'
sudo apt-mark hold kubeadm kubelet kubectl
sudo systemctl daemon-reload && sudo systemctl restart kubelet
```

---

### 12. Final notes, gotchas & recommendations

* If you run an external etcd cluster (not stacked), follow etcd operator or your managed etcd provider docs - backup/restore differs.
* Never expose etcd to the public Internet. Firewall it to only kube-apiserver and trusted admin hosts.
* Keep etcd snapshots in multiple secure locations. Test restore periodically.
* Keep encryption provider keys (for kube-apiserver) backed up in a secure KMS or offline vault. Losing the key means you cannot decrypt older secrets.
* Consider using cloud provider disk encryption + secret management (KMS) for keys for production setups.

---

## Node Administration and Monitoring

### Analyzing Node State

#### Getting Node Information with kubectl

Get detailed information about any node in your cluster:

```bash
# Get basic node information
# Shows: NAME, STATUS, ROLES, AGE, VERSION
kubectl get nodes

# Get detailed output with more columns
# Additionally shows: INTERNAL-IP, EXTERNAL-IP, OS-IMAGE, KERNEL-VERSION, CONTAINER-RUNTIME
kubectl get nodes -o wide

# Get detailed node information including conditions, capacity, and system info
# This is the most comprehensive view of a single node's state
kubectl describe node <node-name>

# Example for control plane node
kubectl describe node k8s-control

# Get node information in JSON format
# Useful for scripting and parsing specific fields
kubectl get nodes -o json

# Get resource usage if Metrics Server is installed
# Shows CPU(cores), CPU%, MEMORY(bytes), MEMORY%
kubectl top nodes

# Check node labels and annotations
# Labels are used for scheduling and node selection
kubectl get nodes --show-labels

# Get specific node capacity and allocatable resources
# Capacity: Total resources on the node
# Allocatable: Resources available for pods (capacity minus system reserved)
kubectl get nodes -o jsonpath='{.items[*].status.capacity}'
kubectl get nodes -o jsonpath='{.items[*].status.allocatable}'
```

#### Node Status and Conditions

Understanding node conditions is crucial for troubleshooting. Kubernetes tracks five main conditions:
- **Ready**: Node is healthy and ready to accept pods
- **MemoryPressure**: Node is running low on memory
- **DiskPressure**: Node is running low on disk space
- **PIDPressure**: Node is running low on process IDs
- **NetworkUnavailable**: Node's network is not correctly configured

```bash
# Check node conditions for all nodes
# Shows which nodes are Ready (True/False/Unknown)
kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}'

# Get detailed condition status for a specific node
kubectl describe node <node-name>

# Check specific conditions
# MemoryPressure should normally be False
kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{": "}{.status.conditions[?(@.type=="MemoryPressure")].status}{"\n"}{end}'

# View all node conditions in table format
# This custom format makes it easy to spot issues at a glance
kubectl get nodes -o custom-columns="NODE:.metadata.name,READY:.status.conditions[?(@.type=='Ready')].status,MEMORY:.status.conditions[?(@.type=='MemoryPressure')].status,DISK:.status.conditions[?(@.type=='DiskPressure')].status"
```

#### System Information via kubectl

```bash
# Check kubelet version on all nodes
# Important for ensuring version compatibility
kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{": "}{.status.nodeInfo.kubeletVersion}{"\n"}{end}'

# Check container runtime information
# Common runtimes: containerd, cri-o (Docker Engine only via cri-dockerd; the training cluster uses cri-o)
kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{": "}{.status.nodeInfo.containerRuntimeVersion}{"\n"}{end}'

# Check OS information
# Helps identify OS-specific issues
kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{": "}{.status.nodeInfo.osImage}{"\n"}{end}'

# Check kernel version
# Important for container compatibility
kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{": "}{.status.nodeInfo.kernelVersion}{"\n"}{end}'

# Check architecture
# Usually amd64, arm64, etc.
kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{": "}{.status.nodeInfo.architecture}{"\n"}{end}'
```

---

### Understanding Static Pods

Static Pods are managed directly by the kubelet on individual nodes, not by the API server. They're typically used for control plane components and are defined by manifest files in `/etc/kubernetes/manifests/`.

#### Identifying Static Pods

```bash
# Static Pods have the node name as suffix
# This naming convention helps identify them
kubectl get pods -n kube-system

# Example output shows static pods:
# kube-apiserver-k8s-control            1/1     Running
# kube-controller-manager-k8s-control   1/1     Running
# kube-scheduler-k8s-control            1/1     Running
# etcd-k8s-control                      1/1     Running

# Check Pod ownership (static Pods are owned by Node, not controllers)
# Regular pods show ReplicaSet, DaemonSet, etc. as owner
kubectl get pods -n kube-system -o yaml | grep -A 5 "ownerReferences"

# List static pods specifically (their mirror Pods are owned by the Node)
kubectl get pods --all-namespaces -o jsonpath='{range .items[?(@.metadata.ownerReferences[0].kind=="Node")]}{.metadata.namespace}{"\t"}{.metadata.name}{"\n"}{end}'
```

#### Creating Custom Static Pods

Create a static Pod manifest:

```yaml
# static-nginx.yaml
apiVersion: v1
kind: Pod
metadata:
  name: static-nginx
  labels:
    app: static-nginx
spec:
  containers:
  - name: nginx
    image: nginx:1.30
    ports:
    - containerPort: 80
    resources:
      requests:
        memory: "64Mi"
        cpu: "250m"
      limits:
        memory: "128Mi"
        cpu: "500m"
    volumeMounts:
    - name: html
      mountPath: /usr/share/nginx/html
  volumes:
  - name: html
    hostPath:
      path: /tmp/nginx-static
      type: DirectoryOrCreate
```

Deploy the static Pod by copying to `/etc/kubernetes/manifests/` on the target node:
```bash
# SSH to the target node first, then:
sudo cp static-nginx.yaml /etc/kubernetes/manifests/
# The kubelet will automatically detect and create the pod
```

#### Static Pod Management

```bash
# View static Pod logs
# Note the node name suffix in the pod name
kubectl logs static-nginx-<node-name>

# Describe static Pod
kubectl describe pod static-nginx-<node-name>

# Try to delete static Pod via kubectl (will fail/restart)
# The pod will be immediately recreated by kubelet
kubectl delete pod static-nginx-<node-name>

# Monitor static Pod recreation
# You'll see the pod being deleted and immediately recreated
kubectl get pods --watch | grep static-nginx
```

#### Control Plane Static Pods

```bash
# View control plane static Pods
kubectl get pods -n kube-system -o wide | grep <control-plane-node-name>

# Check control plane component health
# tier=control-plane label is used for control plane components
kubectl get pods -n kube-system -l tier=control-plane

# View control plane component logs
# Useful for troubleshooting cluster issues
kubectl logs -n kube-system kube-apiserver-<node-name>
kubectl logs -n kube-system kube-controller-manager-<node-name>
kubectl logs -n kube-system kube-scheduler-<node-name>
kubectl logs -n kube-system etcd-<node-name>
```

---

### Managing Node State

#### Cordoning Nodes

Mark a node as unschedulable without affecting existing Pods. This is useful for preventing new workloads during investigation or minor maintenance.

```bash
# Mark node as unschedulable
kubectl cordon <node-name>

# Example
kubectl cordon k8s-worker1

# Verify node status shows SchedulingDisabled
# The STATUS column will show "Ready,SchedulingDisabled"
kubectl get nodes

# Check node details
# Look for "Unschedulable: true" in the output
kubectl describe node k8s-worker1

# Test that new Pods won't schedule to cordoned node
kubectl create deployment test-cordon --image=nginx --replicas=3
kubectl get pods -o wide
kubectl delete deployment test-cordon
```

#### Draining Nodes

Remove all Pods from a node and mark it unschedulable. This is essential for node maintenance or decommissioning.

```bash
# Basic drain command
# This will often fail due to DaemonSets and local data
kubectl drain <node-name>

# Drain with common options (recommended)
# --ignore-daemonsets: Continue even if DaemonSet pods exist
# --delete-emptydir-data: Delete pods using emptyDir volumes (data will be lost)
kubectl drain k8s-worker1 --ignore-daemonsets --delete-emptydir-data

# Drain with additional options
# --force: Delete pods not managed by controllers
# --grace-period: Time to wait for pod termination
# --timeout: Overall operation timeout
kubectl drain k8s-worker1 \
  --ignore-daemonsets \
  --delete-emptydir-data \
  --force \
  --grace-period=60 \
  --timeout=300s

# Monitor the drain process
kubectl get pods -o wide --watch

# Verify node is drained
# Node should show SchedulingDisabled and no pods except DaemonSets
kubectl get nodes
kubectl describe node k8s-worker1
```

#### Uncordoning Nodes

Restore normal node scheduling after maintenance:

```bash
# Make node schedulable again
kubectl uncordon <node-name>

# Example
kubectl uncordon k8s-worker1

# Verify node is back to Ready state
# STATUS should show only "Ready"
kubectl get nodes

# Test that new Pods can schedule to uncordoned node
kubectl create deployment test-uncordon --image=nginx --replicas=3
kubectl get pods -o wide
kubectl delete deployment test-uncordon
```

#### Understanding Node Taints

Taints prevent pods from being scheduled unless they have matching tolerations:
- **NoSchedule**: New pods won't be scheduled
- **PreferNoSchedule**: Scheduler tries to avoid placing pods
- **NoExecute**: Existing pods are evicted, new pods won't be scheduled

```bash
# View all node taints
kubectl describe nodes | grep -i taint

# View taints for a specific node
kubectl describe node k8s-worker1 | grep -A 5 -B 5 -i taint

# Manually add a custom taint
# Format: key=value:effect
kubectl taint nodes k8s-worker1 maintenance=true:NoSchedule

# Add taint that evicts existing Pods
# Use with caution - this will remove running pods!
kubectl taint nodes k8s-worker1 maintenance=true:NoExecute

# Remove a taint (note the minus sign at the end)
kubectl taint nodes k8s-worker1 maintenance=true:NoSchedule-

# Remove control plane taint for single-node testing
# Allows regular pods to run on control plane node
kubectl taint nodes k8s-control node-role.kubernetes.io/control-plane:NoSchedule-
```

---

### Node Resource Monitoring

#### Resource Usage with kubectl

```bash
# Check node resource usage (requires Metrics Server)
# Shows actual CPU and memory usage
kubectl top nodes

# Check Pod resource usage by node
# Helps identify resource-hungry pods
kubectl top pods --all-namespaces --sort-by=memory
kubectl top pods --all-namespaces --sort-by=cpu

# Check resource requests vs limits
# Shows how much resources are reserved vs. actually used
kubectl describe nodes | grep -A 10 "Allocated resources"

# Node capacity and allocatable resources
# Capacity: Total physical resources
# Allocatable: Available for pods after system reservation
kubectl describe nodes | grep -A 5 "Capacity:" 
kubectl describe nodes | grep -A 5 "Allocatable:"
```

#### Installing Metrics Server

If Metrics Server is not available, here's a complete manifest with necessary configurations (the course keeps the maintained version in `k8s/pod-autoscaler/metrics-server.yml`):

```yaml
# metrics-server.yaml
# ServiceAccount for metrics-server
apiVersion: v1
kind: ServiceAccount
metadata:
  labels:
    k8s-app: metrics-server
  name: metrics-server
  namespace: kube-system
---
# ClusterRole for aggregated API discovery
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  labels:
    k8s-app: metrics-server
    rbac.authorization.k8s.io/aggregate-to-admin: "true"
    rbac.authorization.k8s.io/aggregate-to-edit: "true"
    rbac.authorization.k8s.io/aggregate-to-view: "true"
  name: system:aggregated-metrics-reader
rules:
- apiGroups:
  - metrics.k8s.io
  resources:
  - pods
  - nodes
  verbs:
  - get
  - list
---
# ClusterRole for metrics-server
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  labels:
    k8s-app: metrics-server
  name: system:metrics-server
rules:
- apiGroups:
  - ""
  resources:
  - nodes/metrics
  verbs:
  - get
- apiGroups:
  - ""
  resources:
  - pods
  - nodes
  verbs:
  - get
  - list
  - watch
---
# RoleBinding for auth delegation
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  labels:
    k8s-app: metrics-server
  name: metrics-server-auth-reader
  namespace: kube-system
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: extension-apiserver-authentication-reader
subjects:
- kind: ServiceAccount
  name: metrics-server
  namespace: kube-system
---
# ClusterRoleBinding for auth delegation
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  labels:
    k8s-app: metrics-server
  name: metrics-server:system:auth-delegator
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:auth-delegator
subjects:
- kind: ServiceAccount
  name: metrics-server
  namespace: kube-system
---
# ClusterRoleBinding for metrics-server
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  labels:
    k8s-app: metrics-server
  name: system:metrics-server
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:metrics-server
subjects:
- kind: ServiceAccount
  name: metrics-server
  namespace: kube-system
---
# Service for metrics-server
apiVersion: v1
kind: Service
metadata:
  labels:
    k8s-app: metrics-server
  name: metrics-server
  namespace: kube-system
spec:
  ports:
  - name: https
    port: 443
    protocol: TCP
    targetPort: https
  selector:
    k8s-app: metrics-server
---
# Deployment for metrics-server
apiVersion: apps/v1
kind: Deployment
metadata:
  labels:
    k8s-app: metrics-server
  name: metrics-server
  namespace: kube-system
spec:
  selector:
    matchLabels:
      k8s-app: metrics-server
  strategy:
    rollingUpdate:
      maxUnavailable: 0
  template:
    metadata:
      labels:
        k8s-app: metrics-server
    spec:
      containers:
      - args:
        - --cert-dir=/tmp
        - --secure-port=4443
        - --kubelet-preferred-address-types=InternalIP,ExternalIP,Hostname
        - --kubelet-use-node-status-port
        - --metric-resolution=15s
        # --kubelet-insecure-tls is needed for self-signed certificates
        - --kubelet-insecure-tls
        image: registry.k8s.io/metrics-server/metrics-server:v0.9.1
        imagePullPolicy: IfNotPresent
        livenessProbe:
          failureThreshold: 3
          httpGet:
            path: /livez
            port: https
            scheme: HTTPS
          periodSeconds: 10
        name: metrics-server
        ports:
        - containerPort: 4443
          name: https
          protocol: TCP
        readinessProbe:
          failureThreshold: 3
          httpGet:
            path: /readyz
            port: https
            scheme: HTTPS
          initialDelaySeconds: 20
          periodSeconds: 10
        resources:
          requests:
            cpu: 100m
            memory: 200Mi
        securityContext:
          allowPrivilegeEscalation: false
          readOnlyRootFilesystem: true
          runAsNonRoot: true
          runAsUser: 1000
        volumeMounts:
        - mountPath: /tmp
          name: tmp-dir
      nodeSelector:
        kubernetes.io/os: linux
      priorityClassName: system-cluster-critical
      serviceAccountName: metrics-server
      volumes:
      - emptyDir: {}
        name: tmp-dir
---
# APIService registration
apiVersion: apiregistration.k8s.io/v1
kind: APIService
metadata:
  labels:
    k8s-app: metrics-server
  name: v1beta1.metrics.k8s.io
spec:
  group: metrics.k8s.io
  groupPriorityMinimum: 100
  insecureSkipTLSVerify: true
  service:
    name: metrics-server
    namespace: kube-system
  version: v1beta1
  versionPriority: 100
```

Deploy Metrics Server:

```bash
# Apply the metrics server configuration
kubectl apply -f metrics-server.yaml

# Or use the official manifest (may need modifications for self-signed certs)
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml

# For clusters with self-signed certificates, edit the deployment:
kubectl edit deployment metrics-server -n kube-system
# Add --kubelet-insecure-tls to container args

# Wait for metrics-server to be ready
kubectl wait --for=condition=available --timeout=300s deployment/metrics-server -n kube-system

# Verify installation
kubectl get deployment metrics-server -n kube-system
# Wait 30-60 seconds for metrics to be collected
kubectl top nodes
```

---

### Event Monitoring and Debugging

#### Cluster Events

Events provide insight into what's happening in the cluster. They're retained for 1 hour by default.

```bash
# Get all events sorted by timestamp
kubectl get events --sort-by='.lastTimestamp'

# Get the most recent events (sorted oldest first, so take the tail)
kubectl get events --sort-by='.lastTimestamp' | tail -20

# Get Node-specific events
kubectl get events --field-selector involvedObject.kind=Node --sort-by='.lastTimestamp'

# Get Pod-related events
kubectl get events --field-selector involvedObject.kind=Pod --sort-by='.lastTimestamp'

# Get events for a specific node
kubectl get events --field-selector involvedObject.name=<node-name> --sort-by='.lastTimestamp'

# Get events in a specific namespace
kubectl get events -n kube-system --sort-by='.lastTimestamp'

# Watch events in real-time
# Useful for monitoring during deployments or troubleshooting
kubectl get events --watch

# Get events with more details
kubectl get events -o wide --sort-by='.lastTimestamp'
```

#### Pod and Container Monitoring

```bash
# Get all Pods on a specific node
kubectl get pods --all-namespaces --field-selector spec.nodeName=<node-name>

# Get Pod resource usage (requires Metrics Server)
# Note: kubectl top has no node column or node field selector - match the names
# against the Pod list of the node from the previous command
kubectl top pods --all-namespaces

# Check Pod conditions and status
kubectl get pods --all-namespaces --field-selector spec.nodeName=<node-name> -o wide

# Get container logs for Pods on a node
# -f follows the log output (like tail -f)
kubectl logs -f <pod-name> -n <namespace>

# Get previous container logs (useful after container restart)
kubectl logs <pod-name> -n <namespace> --previous

# Check Pod resource requests and limits
kubectl get pods --all-namespaces -o jsonpath='{range .items[*]}{.metadata.namespace}{"\t"}{.metadata.name}{"\t"}{.spec.containers[*].resources}{"\n"}{end}'
```

---

### Node Maintenance Workflows

#### Pre-maintenance Checks

Before performing maintenance, gather information about potential impact:

```bash
# Check what's running on the target node
kubectl get pods -o wide --all-namespaces --field-selector spec.nodeName=<node-name>

# Check critical system Pods
kubectl get pods -n kube-system --field-selector spec.nodeName=<node-name>

# Check DaemonSets that will remain (can't be drained)
kubectl get daemonsets --all-namespaces

# Check PodDisruptionBudgets that might prevent draining
# PDBs define minimum available replicas
kubectl get pdb --all-namespaces
```

#### Maintenance Procedure

Follow this systematic approach for safe node maintenance:

```bash
# Step 1: Cordon the node (prevent new scheduling)
kubectl cordon <node-name>

# Step 2: Check current Pod distribution
kubectl get pods -o wide --all-namespaces | grep <node-name>

# Step 3: Drain the node (move existing Pods)
# This gracefully evicts pods, respecting PodDisruptionBudgets
kubectl drain <node-name> --ignore-daemonsets --delete-emptydir-data

# Step 4: Verify node is drained
# Should only show DaemonSet pods
kubectl get pods -o wide --all-namespaces --field-selector spec.nodeName=<node-name>

# === Perform maintenance work here ===

# Step 5: Uncordon the node after maintenance
kubectl uncordon <node-name>

# Step 6: Verify normal operation
kubectl get nodes
kubectl get pods -o wide --all-namespaces
```

#### Testing Node Recovery

After maintenance, verify the node is functioning correctly:

```bash
# Deploy test workload to verify scheduling
kubectl create deployment maintenance-test --image=nginx --replicas=3

# Check Pod distribution (should include the recovered node)
kubectl get pods -l app=maintenance-test -o wide

# Scale to test further
kubectl scale deployment maintenance-test --replicas=6

# Verify pods are distributed across nodes including the maintained one
kubectl get pods -l app=maintenance-test -o wide

# Cleanup
kubectl delete deployment maintenance-test
```

---

### Node Health Monitoring

#### Health Check Commands

```bash
# Check cluster component health
# Note: componentstatuses is deprecated in newer versions
kubectl get componentstatuses

# For newer versions, check individual components:
kubectl get pods -n kube-system -l component=kube-apiserver
kubectl get pods -n kube-system -l component=kube-controller-manager
kubectl get pods -n kube-system -l component=kube-scheduler

# Check all node conditions in a formatted view
kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{" Ready="}{.status.conditions[?(@.type=="Ready")].status}{" MemoryPressure="}{.status.conditions[?(@.type=="MemoryPressure")].status}{" DiskPressure="}{.status.conditions[?(@.type=="DiskPressure")].status}{" PIDPressure="}{.status.conditions[?(@.type=="PIDPressure")].status}{"\n"}{end}'

# Check for node resource pressure
kubectl describe nodes | grep -A 5 -B 5 "Pressure"

# Monitor node resource allocation
# Shows requests/limits vs capacity
kubectl describe nodes | grep -A 10 "Allocated resources"
```

#### Creating Monitoring Resources

Create a DaemonSet for continuous node monitoring:

```yaml
# node-monitor-daemonset.yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: node-monitor
  namespace: kube-system
  labels:
    app: node-monitor
spec:
  selector:
    matchLabels:
      app: node-monitor
  template:
    metadata:
      labels:
        app: node-monitor
    spec:
      # Access to host process and network namespaces
      hostPID: true
      hostNetwork: true
      containers:
      - name: node-monitor
        image: busybox:1.35
        command:
        - /bin/sh
        - -c
        - |
          while true; do
            echo "Node: $(hostname)"
            echo "Uptime: $(uptime)"
            echo "Memory: $(free -m | awk 'NR==2{printf "%.2f%%", $3*100/$2 }')"
            echo "Disk: $(df -h / | awk 'NR==2{print $5}')"
            echo "---"
            sleep 300
          done
        resources:
          requests:
            memory: 50Mi
            cpu: 50m
          limits:
            memory: 100Mi
            cpu: 100m
        securityContext:
          privileged: true  # Required for host access
        volumeMounts:
        - name: proc
          mountPath: /host/proc
          readOnly: true
        - name: sys
          mountPath: /host/sys
          readOnly: true
      volumes:
      - name: proc
        hostPath:
          path: /proc
      - name: sys
        hostPath:
          path: /sys
      # Tolerations ensure DaemonSet runs on all nodes
      tolerations:
      - effect: NoSchedule
        operator: Exists
      - effect: NoExecute
        operator: Exists
```

Deploy the monitoring DaemonSet:

```bash
# Apply the DaemonSet
kubectl apply -f node-monitor-daemonset.yaml

# Check DaemonSet status
# Should show desired number equals current number
kubectl get daemonset node-monitor -n kube-system

# View logs from monitoring pods
kubectl logs -l app=node-monitor -n kube-system --tail=20

# Follow logs in real-time
kubectl logs -l app=node-monitor -n kube-system -f
```

---

### Verification and Testing

#### Complete Cluster Verification

Comprehensive health check after any major changes:

```bash
# Check cluster overview
kubectl get nodes -o wide
kubectl cluster-info
kubectl version

# Verify all system components
kubectl get pods -n kube-system
# For older versions:
kubectl get componentstatuses
# For newer versions (/healthz is deprecated in favour of /livez and /readyz):
kubectl get --raw='/readyz?verbose'

# Check resource usage (requires Metrics Server)
kubectl top nodes
kubectl top pods -n kube-system

# View recent cluster events
kubectl get events --sort-by='.lastTimestamp' | tail -20
```

#### Node Functionality Testing

Deploy comprehensive test workload to verify all node features:

```yaml
# node-test-deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: node-functionality-test
spec:
  replicas: 3
  selector:
    matchLabels:
      app: node-test
  template:
    metadata:
      labels:
        app: node-test
    spec:
      containers:
      - name: test-container
        image: nginx:1.30
        ports:
        - containerPort: 80
        resources:
          requests:
            memory: "64Mi"
            cpu: "250m"
          limits:
            memory: "128Mi"
            cpu: "500m"
        # Liveness probe ensures container is running
        livenessProbe:
          httpGet:
            path: /
            port: 80
          initialDelaySeconds: 10
          periodSeconds: 30
        # Readiness probe ensures container is ready for traffic
        readinessProbe:
          httpGet:
            path: /
            port: 80
          initialDelaySeconds: 5
          periodSeconds: 10
---
apiVersion: v1
kind: Service
metadata:
  name: node-test-service
spec:
  selector:
    app: node-test
  ports:
  - port: 80
    targetPort: 80
  type: NodePort  # Exposes on all nodes for testing
```

Test node functionality:

```bash
# Deploy test workload
kubectl apply -f node-test-deployment.yaml

# Wait for deployment to be ready
kubectl wait --for=condition=available --timeout=300s deployment/node-functionality-test

# Check Pod distribution across nodes
kubectl get pods -l app=node-test -o wide

# Test scaling (ensures scheduler works properly)
kubectl scale deployment node-functionality-test --replicas=6
kubectl get pods -l app=node-test -o wide

# Test service connectivity
# NodePort allows testing from any node
kubectl get svc node-test-service

# Test node scheduling with affinity
# This adds a preference for Linux nodes (should be all nodes)
kubectl patch deployment node-functionality-test -p '{"spec":{"template":{"spec":{"affinity":{"nodeAffinity":{"preferredDuringSchedulingIgnoredDuringExecution":[{"weight":1,"preference":{"matchExpressions":[{"key":"kubernetes.io/os","operator":"In","values":["linux"]}]}}]}}}}}}'

# Verify affinity is working
kubectl get pods -l app=node-test -o wide

# Cleanup test resources
kubectl delete -f node-test-deployment.yaml
```

#### Final Verification Commands

Complete verification checklist:

```bash
# Comprehensive health check
kubectl get nodes
kubectl get pods --all-namespaces
kubectl get events --sort-by='.lastTimestamp' | tail -10
kubectl top nodes
kubectl cluster-info

# Check for any failing Pods
# Should return empty if all pods are healthy
kubectl get pods --all-namespaces --field-selector=status.phase!=Running,status.phase!=Succeeded

# Verify all nodes are schedulable
# Should show "Unschedulable=" (empty) for all nodes; "true" means the node is cordoned
kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{" Unschedulable="}{.spec.unschedulable}{"\n"}{end}'

# Check cluster DNS is working
# (busybox nslookup does not apply search domains, so use the FQDN)
kubectl run test-dns --image=busybox:1.35 --rm -it --restart=Never -- nslookup kubernetes.default.svc.cluster.local

# Check pod-to-service communication
# (ping is not suitable: ClusterIPs don't answer ICMP and CRI-O doesn't grant NET_RAW by default)
kubectl run test-conn --image=busybox:1.35 --rm -it --restart=Never -- nc -zv -w 3 kubernetes.default.svc.cluster.local 443
```
