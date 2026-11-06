# Cluster Administration and Monitoring

This chapter is a practical, step-by-step guide to administering a **vanilla kubeadm** Kubernetes cluster. It covers:

* how to **safely upgrade** the cluster (control plane + nodes),
* how to **backup etcd** (snapshots) and **restore** from them,
* how to **secure / encrypt etcd** (both TLS for etcd communication and data-at-rest options),
* how to **encrypt Kubernetes secrets stored in etcd** (Kubernetes API server encryption at rest),
* verification steps and useful recovery tips,
* how to check and renew the **kubeadm certificates**,
* day-to-day **node administration and monitoring** (node state, static Pods, cordon/drain, Metrics Server, events),
* cluster **monitoring with Prometheus and Grafana** (kube-prometheus-stack, ServiceMonitor, PrometheusRule, alerts),
* **centralized logging with Loki and Grafana Alloy** (LogQL).

We assume a kubeadm-managed cluster where the control plane runs as static pods on one or more control-plane hosts (default kubeadm layout). Adapt paths/commands if you run an external etcd cluster or cloud-managed control plane.

> **Training cluster:** the control-plane commands below run on `master` (`ssh k8s@192.168.1.10`). Most of the files
> involved (`/etc/kubernetes/pki`, `/var/lib/etcd`, `/root/etcd-backups`) are readable for root only - start a root
> shell with `sudo -i` before you begin (otherwise shell globs such as `/root/etcd-backups/*.db` do not expand).
> `kubectl` commands run wherever your kubeconfig is (the master also has one in `~k8s/.kube/config`).
>
> Everything in this chapter was tested on the training cluster (Kubernetes v1.37.1, etcd 3.7.0, CRI-O 1.37).

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
> Since etcd 3.6 only the v3 API exists - the old `ETCDCTL_API=3` variable is not needed any more (etcdctl 3.7 even
> warns `unrecognized environment variable`).
>
> The pkgs.k8s.io packages no longer pull in `crictl`; install it from the same repository, it is used below to watch
> the static Pod containers: `sudo apt-get install -y cri-tools` (then `sudo crictl ps`).

```bash
# Export envs for convenience
export ETCD_CERT_DIR=/etc/kubernetes/pki/etcd
export SNAPSHOT_DIR=/root/etcd-backups
sudo mkdir -p ${SNAPSHOT_DIR}

# snapshot with etcdctl v3; use the certificate files kubeadm created by default
sudo \
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

Read the output carefully: it will list recommended target version and image pull steps. Example from the training
cluster (trimmed):

```
[upgrade/versions] Cluster version: 1.37.1
[upgrade/versions] kubeadm version: v1.37.1
[upgrade/versions] Target version: v1.37.2
...
COMPONENT                 NODE      CURRENT   TARGET
kube-apiserver            master    v1.37.1   v1.37.2
kube-controller-manager   master    v1.37.1   v1.37.2
kube-scheduler            master    v1.37.1   v1.37.2
kube-proxy                          1.37.1    v1.37.2
CoreDNS                             v1.14.6   v1.14.6
etcd                      master    3.7.0-0   3.7.0-0

You can now apply the upgrade by executing the following command:

	kubeadm upgrade apply v1.37.2

Note: Before you can perform this upgrade, you have to update kubeadm to v1.37.2.
```

`kubeadm upgrade plan` asks `dl.k8s.io` for the newest release; the `.deb` packages for it may appear in the
repository a few days later (`apt-cache madison kubeadm`). Upgrade only to a version you can install.

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
export ETCD_CERT_DIR=/etc/kubernetes/pki/etcd
export SNAPSHOT_DIR=/root/etcd-backups
sudo mkdir -p ${SNAPSHOT_DIR}

# snapshot
sudo \
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

> This is destructive for existing etcd - only perform if you need a restore. Everything written to the cluster after
> the snapshot is lost. Practise it on a test cluster first (the training cluster is fine).

To see the effect, create a marker before and after the snapshot - after the restore only the first one exists:

```bash
export ETCD_CERT_DIR=/etc/kubernetes/pki/etcd SNAPSHOT_DIR=/root/etcd-backups
kubectl create namespace before-snapshot

SNAP=${SNAPSHOT_DIR}/etcd-snap-drill.db
sudo /usr/bin/etcdctl --endpoints=https://127.0.0.1:2379 \
  --cacert=${ETCD_CERT_DIR}/ca.crt --cert=${ETCD_CERT_DIR}/server.crt --key=${ETCD_CERT_DIR}/server.key \
  snapshot save ${SNAP}

kubectl create namespace after-snapshot
```

1. Stop etcd and kube-apiserver. They are static pods, so stopping kubelet alone does not stop the running containers - move their manifests out of the manifests directory and kubelet will stop them:

```bash
sudo mkdir -p /root/manifests-backup
sudo mv /etc/kubernetes/manifests/etcd.yaml /etc/kubernetes/manifests/kube-apiserver.yaml /root/manifests-backup/

# wait until both containers are gone (takes up to ~30 s)
while [ -n "$(sudo crictl ps -q --name '^(etcd|kube-apiserver)$')" ]; do sleep 2; done
sudo crictl ps --name '^(etcd|kube-apiserver)$'
```

> Never keep backup copies of manifests **inside** `/etc/kubernetes/manifests` - kubelet would run every file there.

2. Move old data dir (safe copy). `etcdutl snapshot restore` creates the data dir itself and refuses to overwrite an existing one.

```bash
sudo mv /var/lib/etcd /var/lib/etcd-old-$(date +%Y%m%d%H%M%S)
```

3. Restore snapshot to data-dir with `etcdutl snapshot restore`. `--name` and the peer URL must match `--name` and `--initial-advertise-peer-urls` in `etcd.yaml` (kubeadm uses the node name and node IP; check with `sudo grep -E -- '--name|--initial' /root/manifests-backup/etcd.yaml`).

```bash
RESTORE_DIR=/var/lib/etcd
NODE_IP=192.168.1.10   # control-plane node IP (see etcd.yaml)

sudo /usr/bin/etcdutl snapshot restore ${SNAP} \
  --data-dir ${RESTORE_DIR} \
  --name $(hostname -s) \
  --initial-advertise-peer-urls https://${NODE_IP}:2380 \
  --initial-cluster $(hostname -s)=https://${NODE_IP}:2380
sudo ls ${RESTORE_DIR}        # member
```

> For HA with multiple control-planes, restoring is more involved - you usually restore a snapshot to one member, then rejoin other members or rebuild nodes. See HA notes below.

4. The kubeadm etcd container runs as root, so no ownership change is needed.

5. Move the manifests back:

```bash
sudo mv /root/manifests-backup/etcd.yaml /root/manifests-backup/kube-apiserver.yaml /etc/kubernetes/manifests/
until kubectl get --raw /readyz >/dev/null 2>&1; do sleep 3; done; echo "API server is back"
```

kubelet will start the static pods (etcd, kube-apiserver) again. Verify the etcd member is healthy:

```bash
sudo /usr/bin/etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  endpoint status --write-out=table
```

6. Restart the other control-plane components so they do not work with state cached before the restore (kubelet
restarts the stopped containers immediately):

```bash
for c in $(sudo crictl ps -q --name '^(kube-controller-manager|kube-scheduler)$'); do sudo crictl stop $c; done
```

Then check the cluster and the markers:

```bash
kubectl get nodes
kubectl get pods -A | grep -v -E 'Running|Completed'
kubectl get namespace before-snapshot after-snapshot
```

Expected:

```
NAME              STATUS   AGE
before-snapshot   Active   38s
Error from server (NotFound): namespaces "after-snapshot" not found
```

Clean up the drill: `kubectl delete namespace before-snapshot`. Keep `/var/lib/etcd-old-*` until you are sure the
restore is fine, then delete it.

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
sudo /usr/bin/etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  endpoint status --write-out=table

# These should fail (the timeouts make them fail fast instead of retrying):
# plain HTTP - etcd only speaks TLS on the client port
sudo /usr/bin/etcdctl --endpoints=http://127.0.0.1:2379 --dial-timeout=3s --command-timeout=5s endpoint status
# TLS, but without a client certificate - rejected because of --client-cert-auth=true
sudo /usr/bin/etcdctl --endpoints=https://127.0.0.1:2379 --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --dial-timeout=3s --command-timeout=5s endpoint status
```

Expected for both failing commands:

```
Failed to get the status of endpoint ... (context deadline exceeded)
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

Create `/etc/kubernetes/enc/encryption-config.yaml` on the control-plane node(s). The first provider is used to
**write** data, all listed providers are tried when **reading**. `<BASE64_32_BYTES>` must be a 32-byte base64 value
(for production prefer the `kms` v2 provider with an external KMS - stable since v1.29; `kms` v1 is deprecated):

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

The same file, generated with a fresh random key:

```bash
sudo mkdir -p /etc/kubernetes/enc
KEY=$(head -c 32 /dev/urandom | base64)
sudo tee /etc/kubernetes/enc/encryption-config.yaml >/dev/null <<EOF
apiVersion: apiserver.config.k8s.io/v1
kind: EncryptionConfiguration
resources:
  - resources:
      - secrets
    providers:
      - secretbox:
          keys:
            - name: key1
              secret: ${KEY}
      - identity: {}
EOF
```

##### 6.2 Put the file on the control plane and secure it

```bash
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

Instead of an editor you can make the three changes with `sed`. Keep a copy of the original manifest - **outside** the
manifests directory:

```bash
M=/etc/kubernetes/manifests/kube-apiserver.yaml
sudo cp $M /root/kube-apiserver.yaml.orig

sudo sed -i '/^    - --tls-private-key-file=/a\    - --encryption-provider-config=/etc/kubernetes/enc/encryption-config.yaml' $M
sudo sed -i '/^    volumeMounts:/a\    - mountPath: /etc/kubernetes/enc\n      name: enc\n      readOnly: true' $M
sudo sed -i '/^  volumes:/a\  - hostPath:\n      path: /etc/kubernetes/enc\n      type: DirectoryOrCreate\n    name: enc' $M
sudo diff /root/kube-apiserver.yaml.orig $M
```

kubelet will restart the kube-apiserver static pod automatically. The API is unavailable for ~20-60 seconds - and
right after the change the **old** API server may still answer for a moment. Check that the new container runs with
the flag:

```bash
sleep 20; until kubectl get --raw /readyz >/dev/null 2>&1; do sleep 3; done
sudo crictl ps --name '^kube-apiserver$'           # CREATED: seconds ago
kubectl -n kube-system get pod kube-apiserver-$(hostname -s) -o yaml | grep -- --encryption-provider-config
```

If the API server does not come back, look at the container log - a typo in the config file is the usual cause - and
restore the original manifest (`sudo cp /root/kube-apiserver.yaml.orig $M`):

```bash
sudo crictl ps -a --name kube-apiserver
sudo crictl logs $(sudo crictl ps -a -q --name kube-apiserver | head -1) 2>&1 | tail -5
```

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
  get /registry/secrets/encrypt-test/mysecret | hexdump -C | head -4
```

Expected - the key name is readable, the value is ciphertext:

```
00000000  2f 72 65 67 69 73 74 72  79 2f 73 65 63 72 65 74  |/registry/secret|
00000010  73 2f 65 6e 63 72 79 70  74 2d 74 65 73 74 2f 6d  |s/encrypt-test/m|
00000020  79 73 65 63 72 65 74 0a  6b 38 73 3a 65 6e 63 3a  |ysecret.k8s:enc:|
00000030  73 65 63 72 65 74 62 6f  78 3a 76 31 3a 6b 65 79  |secretbox:v1:key|
```

An unencrypted Secret starts with `k8s` followed by binary protobuf (`6b 38 73 00`) and the values are readable in
the dump. Reading through the API is unchanged:
`kubectl -n encrypt-test get secret mysecret -o jsonpath='{.data.k}' | base64 -d` prints `secret123`.

##### 6.6 Disable encryption (or remove a key) safely

Never just remove the flag - the API server could not decrypt the stored Secrets any more. Reverse the steps:

1. Make `identity` the **first** provider (new writes are plaintext), keep `secretbox` so existing data stays readable:

```bash
KEY=$(sudo grep 'secret:' /etc/kubernetes/enc/encryption-config.yaml | awk '{print $2}')
sudo tee /etc/kubernetes/enc/encryption-config.yaml >/dev/null <<EOF
apiVersion: apiserver.config.k8s.io/v1
kind: EncryptionConfiguration
resources:
  - resources:
      - secrets
    providers:
      - identity: {}
      - secretbox:
          keys:
            - name: key1
              secret: ${KEY}
EOF
```

2. Restart the API server so it reads the file again (kubelet starts the stopped container immediately), then rewrite
all Secrets:

```bash
sudo crictl stop $(sudo crictl ps -q --name '^kube-apiserver$')
sleep 15; until kubectl get --raw /readyz >/dev/null 2>&1; do sleep 3; done
kubectl get secrets --all-namespaces -o json | kubectl replace -f -
```

3. Check that a Secret is stored as plaintext again (`6b 38 73 00` = `k8s.`), then remove the flag and the mount
(restore the original manifest) and the config file:

```bash
sudo /usr/bin/etcdctl --endpoints=https://127.0.0.1:2379 --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt --key=/etc/kubernetes/pki/etcd/server.key \
  get /registry/secrets/encrypt-test/mysecret --print-value-only | head -c 16 | hexdump -C

sudo cp /root/kube-apiserver.yaml.orig /etc/kubernetes/manifests/kube-apiserver.yaml
sleep 30; until kubectl get --raw /readyz >/dev/null 2>&1; do sleep 3; done
kubectl -n kube-system get pod kube-apiserver-$(hostname -s) -o yaml | grep -c -- --encryption-provider-config   # 0
sudo rm -rf /etc/kubernetes/enc
kubectl delete namespace encrypt-test
```

Key rotation works the same way: add the new key as the first key of `secretbox`, restart, `kubectl replace` all
Secrets, then remove the old key and restart again.

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

* Every restart of etcd or kube-apiserver makes the API unavailable for a moment. Controllers that use leader
  election (for example NGINX Gateway Fabric, MetalLB, kube-controller-manager) may exit with
  `leader election lost` and get restarted by Kubernetes - this is expected; check that they are `Running` again
  (`kubectl get pods -A | grep -v Running`) and delete a Pod stuck in `CrashLoopBackOff` back-off to restart it at once.

* Check etcd health:

```bash
sudo /usr/bin/etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  endpoint health
```

* Check cluster members:

```bash
sudo /usr/bin/etcdctl \
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

Save as `/usr/local/bin/etcd-backup.sh` (it runs as root, e.g. from cron):

```bash
#!/bin/bash
# etcd-backup.sh - snapshot etcd, verify it, keep the last KEEP snapshots, optionally copy them away
set -euo pipefail
ETCDCTL=/usr/bin/etcdctl
ETCDUTL=/usr/bin/etcdutl
ETCD_CERT_DIR=/etc/kubernetes/pki/etcd
SNAP_DIR=/root/etcd-backups
KEEP=${KEEP:-7}
REMOTE_DEST=${REMOTE_DEST:-}            # e.g. backup@backup.example.com:/backups/etcd (empty = no copy)

mkdir -p "$SNAP_DIR"
chmod 700 "$SNAP_DIR"

TS=$(date -u +"%Y%m%dT%H%M%SZ")
SNAP="${SNAP_DIR}/etcd-snap-${TS}.db"

$ETCDCTL \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=${ETCD_CERT_DIR}/ca.crt \
  --cert=${ETCD_CERT_DIR}/server.crt \
  --key=${ETCD_CERT_DIR}/server.key \
  snapshot save "${SNAP}" >/dev/null

# a snapshot that cannot be read is worthless - check it right away
$ETCDUTL snapshot status "${SNAP}" --write-out=table

# retention: keep the newest $KEEP scheduled snapshots
ls -1t "${SNAP_DIR}"/etcd-snap-2*.db | tail -n +$((KEEP + 1)) | xargs -r rm -f

# optional remote copy
if [ -n "${REMOTE_DEST}" ]; then
  scp "${SNAP}" "${REMOTE_DEST}"
fi
echo "snapshot saved: ${SNAP}"
```

Install and test it, then schedule it (here: every night at 02:30):

```bash
sudo chmod 700 /usr/local/bin/etcd-backup.sh
sudo /usr/local/bin/etcd-backup.sh
echo '30 2 * * * root /usr/local/bin/etcd-backup.sh >> /var/log/etcd-backup.log 2>&1' | sudo tee /etc/cron.d/etcd-backup
```

Expected (after the JSON log lines of `etcdctl`):

```
┌─────────┬──────────┬────────────┬────────────┬─────────┐
│  HASH   │ REVISION │ TOTAL KEYS │ TOTAL SIZE │ VERSION │
├─────────┼──────────┼────────────┼────────────┼─────────┤
│ 86527a8 │   241077 │       1436 │      44 MB │   3.7.0 │
└─────────┴──────────┴────────────┴────────────┴─────────┘
snapshot saved: /root/etcd-backups/etcd-snap-20261106T042437Z.db
```

#### 10.2 Quick restore guide (comments in script)

No automatic destructive restore script is provided here - restores require human checks. Use the manual procedure in section 4.3.

---

### 11. Summary of key commands (cheat-sheet)

Take snapshot:

```bash
sudo /usr/bin/etcdctl \
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

## Certificate Management with kubeadm

kubeadm creates a private PKI in `/etc/kubernetes/pki`: CAs valid for **10 years** and component certificates
valid for **1 year**. Expired certificates are one of the most common reasons why an old kubeadm cluster suddenly
stops working (`x509: certificate has expired or is not yet valid`).

### Checking expiration

```bash
sudo kubeadm certs check-expiration
```

Expected (trimmed):

```
CERTIFICATE                EXPIRES                  RESIDUAL TIME   CERTIFICATE AUTHORITY   EXTERNALLY MANAGED
admin.conf                 Oct 19, 2027 14:52 UTC   347d            ca                      no
apiserver                  Oct 19, 2027 14:52 UTC   347d            ca                      no
apiserver-etcd-client      Oct 19, 2027 14:52 UTC   347d            etcd-ca                 no
...
CERTIFICATE AUTHORITY   EXPIRES                  RESIDUAL TIME   EXTERNALLY MANAGED
ca                      Oct 16, 2036 14:52 UTC   9y              no
etcd-ca                 Oct 16, 2036 14:52 UTC   9y              no
front-proxy-ca          Oct 16, 2036 14:52 UTC   9y              no
```

Any certificate can also be inspected with openssl - including the one the API server presents on the network:

```bash
sudo openssl x509 -in /etc/kubernetes/pki/apiserver.crt -noout -subject -enddate -ext subjectAltName
echo | openssl s_client -connect 192.168.1.10:6443 2>/dev/null | openssl x509 -noout -enddate
```

### Renewing certificates

**`kubeadm upgrade apply`/`upgrade node` renew all certificates automatically** - clusters that are upgraded at least
once a year never run into expiry. Otherwise renew them manually (one certificate or `all`):

```bash
sudo kubeadm certs renew apiserver
sudo kubeadm certs check-expiration | grep -E '^apiserver '
```

Expected:

```
certificate for serving the Kubernetes API renewed
apiserver                  Nov 06, 2027 04:22 UTC   364d            ca                      no
```

The API server reloads its *serving* certificate from disk by itself, but the control-plane components read client
certificates and the kubeconfig files (`controller-manager.conf`, `scheduler.conf`, `admin.conf`) only at start.
After `kubeadm certs renew all` restart them - kubelet starts the stopped static Pod containers again right away -
and refresh your admin kubeconfig:

```bash
for c in $(sudo crictl ps -q --name '^(kube-apiserver|kube-controller-manager|kube-scheduler|etcd)$'); do
  sudo crictl stop $c
done
sleep 20; until kubectl get --raw /readyz >/dev/null 2>&1; do sleep 3; done

sudo cp /etc/kubernetes/admin.conf $HOME/.kube/config && sudo chown $(id -u):$(id -g) $HOME/.kube/config
```

(Copy the renewed `admin.conf` again to every machine that uses it, e.g. the client VM - see module 00.)

### kubelet certificates

The kubelet has two certificates of its own:

* a **client certificate** (`/var/lib/kubelet/pki/kubelet-client-current.pem`, `CN=system:node:<node>`) signed by the
  cluster CA - with `rotateCertificates: true` (kubeadm default) the kubelet requests a new one through a
  CertificateSigningRequest before it expires, and the CSR is approved automatically;
* a **serving certificate** (`kubelet.crt`) that the kubelet generates and signs itself. That is why metrics-server
  needs `--kubelet-insecure-tls` in this cluster (see below). Setting `serverTLSBootstrap: true` makes the kubelet
  request a CA-signed serving certificate instead - those CSRs must then be approved (`kubectl certificate approve`).

```bash
sudo grep -E 'rotateCertificates|serverTLSBootstrap' /var/lib/kubelet/config.yaml
sudo ls -l /var/lib/kubelet/pki/
sudo openssl x509 -in /var/lib/kubelet/pki/kubelet-client-current.pem -noout -subject -enddate
sudo openssl x509 -in /var/lib/kubelet/pki/kubelet.crt -noout -issuer -enddate
kubectl get csr
```

Expected (trimmed):

```
rotateCertificates: true
kubelet-client-2026-10-19-16-52-33.pem
kubelet-client-current.pem -> /var/lib/kubelet/pki/kubelet-client-2026-10-19-16-52-33.pem
...
subject=O=system:nodes, CN=system:node:master
notAfter=Oct 19 14:52:08 2027 GMT
issuer=CN=master-ca@1792421553
```

> The CAs themselves (10 years) are not renewed by kubeadm. Replacing a CA is a manual, multi-step procedure
> (see "Manual rotation of CA certificates" in the Kubernetes documentation) - plan it long before the expiry date.

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
kubectl describe node master

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
# kube-apiserver-master            1/1     Running
# kube-controller-manager-master   1/1     Running
# kube-scheduler-master            1/1     Running
# etcd-master                      1/1     Running

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
    image: nginx:1.31-alpine
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
kubectl cordon node2

# Verify node status shows SchedulingDisabled
# The STATUS column will show "Ready,SchedulingDisabled"
kubectl get nodes

# Check node details
# Look for "Unschedulable: true" in the output
kubectl describe node node2

# Test that new Pods won't schedule to cordoned node
kubectl create deployment test-cordon --image=nginx:1.31-alpine --replicas=3
kubectl get pods -o wide
kubectl delete deployment test-cordon
```

#### Draining Nodes

Remove all Pods from a node and mark it unschedulable. This is essential for node maintenance or decommissioning.

```bash
# Basic drain command
# This will often fail due to DaemonSets and local data
kubectl drain <node-name>
# The node is cordoned, but nothing is evicted - the command lists what blocks it, e.g.:
#   cannot delete Pods with local storage (use --delete-emptydir-data to override): lab-08-shop/shop-gateway-nginx-...
#   cannot delete Pods that declare no controller (use --force to override): lab-08-shop/toolbox
#   cannot delete DaemonSet-managed Pods (use --ignore-daemonsets to ignore): kube-system/calico-node-..., ...

# Drain with common options (recommended)
# --ignore-daemonsets: Continue even if DaemonSet pods exist
# --delete-emptydir-data: Delete pods using emptyDir volumes (data will be lost)
kubectl drain node2 --ignore-daemonsets --delete-emptydir-data

# Drain only some Pods: --pod-selector skips everything that does not match
# (here: keep a bare Pod and finished Job Pods on the node)
kubectl drain node2 --ignore-daemonsets --delete-emptydir-data \
  --pod-selector='app!=toolbox,!batch.kubernetes.io/job-name'

# Drain with additional options
# --force: Delete pods not managed by controllers - they are gone for good, nothing recreates them
# --grace-period: Time to wait for pod termination
# --timeout: Overall operation timeout
kubectl drain node2 \
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
kubectl describe node node2
```

#### Uncordoning Nodes

Restore normal node scheduling after maintenance:

```bash
# Make node schedulable again
kubectl uncordon <node-name>

# Example
kubectl uncordon node2

# Verify node is back to Ready state
# STATUS should show only "Ready"
kubectl get nodes

# Test that new Pods can schedule to uncordoned node
kubectl create deployment test-uncordon --image=nginx:1.31-alpine --replicas=3
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
kubectl describe node node2 | grep -A 5 -B 5 -i taint

# Manually add a custom taint
# Format: key=value:effect
kubectl taint nodes node2 maintenance=true:NoSchedule

# Add taint that evicts existing Pods
# Use with caution - this will remove running pods (bare Pods are deleted permanently)!
kubectl taint nodes node2 maintenance=true:NoExecute
kubectl taint nodes node2 maintenance=true:NoExecute-

# Remove a taint (note the minus sign at the end)
kubectl taint nodes node2 maintenance=true:NoSchedule-

# Remove control plane taint for single-node testing
# Allows regular pods to run on control plane node
kubectl taint nodes master node-role.kubernetes.io/control-plane:NoSchedule-
# ... and put it back
kubectl taint nodes master node-role.kubernetes.io/control-plane:NoSchedule

# Check what a NoExecute taint would do without applying it
kubectl taint nodes node2 maintenance=true:NoExecute --dry-run=server
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

`kubectl top` and the HorizontalPodAutoscaler need Metrics Server. It is an **aggregated API** (`APIService
v1beta1.metrics.k8s.io`, see module 15): the API server forwards `/apis/metrics.k8s.io/...` to it, and it collects
CPU/memory from the kubelets. The training cluster already runs it; the course keeps the manifest in
`k8s/pod-autoscaler/metrics-server.yml` - the official `components.yaml` of v0.9.1 plus `--kubelet-insecure-tls`
(the kubelet serving certificates are self-signed, see "kubelet certificates" above):

```yaml
# metrics-server.yaml
# metrics-server v0.9.1 - official components.yaml
# Source: https://github.com/kubernetes-sigs/metrics-server/releases/download/v0.9.1/components.yaml
# Local modification (training cluster, kubeadm with self-signed kubelet serving certificates):
#   --kubelet-insecure-tls  -> do not verify kubelet serving certificates (they are not signed by the cluster CA)
# Apply: kubectl apply -f metrics-server.yml   Verify: kubectl top nodes
apiVersion: v1
kind: ServiceAccount
metadata:
  labels:
    k8s-app: metrics-server
  name: metrics-server
  namespace: kube-system
---
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
  - watch
---
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
apiVersion: v1
kind: Service
metadata:
  labels:
    k8s-app: metrics-server
  name: metrics-server
  namespace: kube-system
spec:
  ports:
  - appProtocol: https
    name: https
    port: 443
    protocol: TCP
    targetPort: https
  selector:
    k8s-app: metrics-server
---
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
        - --secure-port=10250
        - --kubelet-preferred-address-types=InternalIP,ExternalIP,Hostname
        - --kubelet-use-node-status-port
        - --metric-resolution=15s
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
        - containerPort: 10250
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
          capabilities:
            drop:
            - ALL
          readOnlyRootFilesystem: true
          runAsNonRoot: true
          runAsUser: 1000
          seccompProfile:
            type: RuntimeDefault
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
# Apply the course manifest (identical to the running installation - nothing changes)
kubectl apply -f k8s/pod-autoscaler/metrics-server.yml

# Or: the official manifest of a pinned release, then add the flag for self-signed kubelet certificates
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/download/v0.9.1/components.yaml
kubectl -n kube-system patch deployment metrics-server --type=json \
  -p '[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'

# Wait for metrics-server to be ready
kubectl wait --for=condition=available --timeout=300s deployment/metrics-server -n kube-system

# Verify installation
kubectl get deployment metrics-server -n kube-system
kubectl get apiservice v1beta1.metrics.k8s.io           # AVAILABLE=True
# Wait 30-60 seconds for metrics to be collected
kubectl top nodes
kubectl get --raw /apis/metrics.k8s.io/v1beta1/nodes | jq -r '.items[] | .metadata.name + " " + .usage.cpu + " " + .usage.memory'
```

Without `--kubelet-insecure-tls` the Pod stays unready and its log shows `x509` certificate errors for every node

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
kubectl create deployment maintenance-test --image=nginx:1.31-alpine --replicas=3

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
        image: busybox:1.38
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
        image: nginx:1.31-alpine
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
kubectl run test-dns --image=busybox:1.38 --rm -i --restart=Never -- nslookup kubernetes.default.svc.cluster.local

# Check pod-to-service communication
# (ping is not suitable: ClusterIPs don't answer ICMP and CRI-O doesn't grant NET_RAW by default)
kubectl run test-conn --image=busybox:1.38 --rm -i --restart=Never -- nc -zv -w 3 kubernetes.default.svc.cluster.local 443
```

---

## Monitoring with Prometheus and Grafana

`kubectl top` shows the current CPU and memory usage - nothing more. Real monitoring needs **history**, **queries**,
**dashboards** and **alerts**. The de-facto standard on Kubernetes is Prometheus, installed with the
`kube-prometheus-stack` Helm chart (module 13):

| Component | Role |
|-----------|------|
| **Prometheus Operator** | manages Prometheus/Alertmanager and turns the CRDs `ServiceMonitor`, `PodMonitor`, `PrometheusRule` into configuration |
| **Prometheus** | scrapes `/metrics` endpoints every 30 s, stores time series, evaluates rules |
| **Alertmanager** | groups, silences and routes firing alerts (e-mail, Slack, PagerDuty, webhooks) |
| **Grafana** | dashboards and ad-hoc queries (Explore) for metrics - and logs (next section) |
| **node-exporter** (DaemonSet) | node metrics: CPU, memory, disks, network |
| **kube-state-metrics** | object state as metrics: Deployment replicas, Pod phases, Job results, ... |

Prometheus **pulls** metrics: every target exposes plain-text metrics over HTTP, e.g.

```
http_requests_total{method="GET",status="200"} 1027
```

### Installing kube-prometheus-stack

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
mkdir -p ~/monitoring && cd ~/monitoring
```

```yaml
# kps-values.yaml
grafana:
  adminPassword: "Grafana-2026!"
  service:
    type: LoadBalancer          # MetalLB address, reachable from the client VM
prometheus:
  service:
    type: LoadBalancer
  prometheusSpec:
    retention: 2d
    # by default Prometheus only picks up ServiceMonitors/rules labelled with this Helm release -
    # accept the ones of all teams and namespaces
    serviceMonitorSelectorNilUsesHelmValues: false
    podMonitorSelectorNilUsesHelmValues: false
    ruleSelectorNilUsesHelmValues: false
    resources:
      requests:
        cpu: 200m
        memory: 1Gi
alertmanager:
  service:
    type: LoadBalancer
```

There is no dynamic block storage in the training cluster, so Prometheus, Alertmanager and Grafana keep their data
in `emptyDir` volumes - the data survives container restarts, but not a new Pod. In production set
`prometheus.prometheusSpec.storageSpec` (a PVC template) and `grafana.persistence`.

```bash
helm install monitoring prometheus-community/kube-prometheus-stack --version 92.21.1 \
  -n monitoring --create-namespace -f kps-values.yaml --wait --timeout 10m

kubectl -n monitoring get pods
kubectl -n monitoring get svc | grep LoadBalancer
kubectl get crd | grep monitoring.coreos.com
```

Expected (trimmed):

```
NAME                                                     READY   STATUS    RESTARTS   AGE
alertmanager-monitoring-kube-prometheus-alertmanager-0   2/2     Running   0          81s
monitoring-grafana-bc4cf7788-zftsr                       3/3     Running   0          92s
monitoring-kube-prometheus-operator-64d8f9fb4-bljx5      1/1     Running   0          92s
monitoring-kube-state-metrics-7d94c4cbd8-6bnfr           1/1     Running   0          92s
monitoring-prometheus-node-exporter-hg8hz                1/1     Running   0          93s
monitoring-prometheus-node-exporter-jpcdq                1/1     Running   0          92s
monitoring-prometheus-node-exporter-pxcnq                1/1     Running   0          92s
prometheus-monitoring-kube-prometheus-prometheus-0       2/2     Running   0          80s
monitoring-grafana                        LoadBalancer   10.97.158.108   192.168.1.243   80:31988/TCP
monitoring-kube-prometheus-alertmanager   LoadBalancer   10.102.26.51    192.168.1.242   9093:32336/TCP,8080:32687/TCP
monitoring-kube-prometheus-prometheus     LoadBalancer   10.97.219.175   192.168.1.241   9090:30459/TCP,8080:30960/TCP
```

Note the three addresses. The UIs are `http://<PROMETHEUS_IP>:9090`, `http://<ALERTMANAGER_IP>:9093` and
`http://<GRAFANA_IP>` (user `admin`, password from the values file) - in a browser inside the cluster network, through
an SSH tunnel (`ssh -L 3000:<GRAFANA_IP>:80 <jump-host>`), or with
`kubectl -n monitoring port-forward svc/monitoring-grafana 3000:80`.

```bash
PROM_IP=$(kubectl -n monitoring get svc monitoring-kube-prometheus-prometheus -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
AM_IP=$(kubectl -n monitoring get svc monitoring-kube-prometheus-alertmanager -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
GRAFANA_IP=$(kubectl -n monitoring get svc monitoring-grafana -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
echo "PROM_IP=$PROM_IP AM_IP=$AM_IP GRAFANA_IP=$GRAFANA_IP"
```

The following `curl` commands use the HTTP APIs behind the UIs and run on the **client VM** (export the three
variables there, too; `jq` is needed - `sudo apt-get install -y jq`).

### Scrape targets - and the kubeadm gotcha

List the scrape jobs and their health:

```bash
curl -s "http://$PROM_IP:9090/api/v1/targets?state=active" \
  | jq -r '.data.activeTargets[] | "\(.labels.job) \(.health) \(.lastError)"' | sort | uniq -c
```

Expected on a fresh kubeadm cluster (trimmed):

```
      1 apiserver up
      2 coredns up
      1 kube-controller-manager down Get "https://192.168.1.10:10257/metrics": dial tcp 192.168.1.10:10257: connect: connection refused
      1 kube-etcd down Get "http://192.168.1.10:2381/metrics": dial tcp 192.168.1.10:2381: connect: connection refused
      1 kube-proxy down Get "http://192.168.1.10:10249/metrics": dial tcp 192.168.1.10:10249: connect: connection refused
      1 kube-proxy down Get "http://192.168.1.11:10249/metrics": dial tcp 192.168.1.11:10249: connect: connection refused
      1 kube-proxy down Get "http://192.168.1.12:10249/metrics": dial tcp 192.168.1.12:10249: connect: connection refused
      1 kube-scheduler down Get "https://192.168.1.10:10259/metrics": dial tcp 192.168.1.10:10259: connect: connection refused
      1 kube-state-metrics up
      9 kubelet up
      3 node-exporter up
...
```

kubeadm makes controller-manager, scheduler, etcd metrics and kube-proxy listen on `127.0.0.1` only, so Prometheus
(running in a Pod) cannot reach them. Either disable those scrape jobs (`kubeControllerManager.enabled: false` etc. in
the chart values) or let the components listen on the node address. **⚠ cluster-wide** - on `master` (keep copies of
the manifests outside the manifests directory):

```bash
cd /etc/kubernetes/manifests
for f in kube-controller-manager kube-scheduler etcd; do sudo cp $f.yaml /root/$f.yaml.orig; done

# controller-manager and scheduler: serve metrics (HTTPS + authentication) on all addresses
sudo sed -i 's/--bind-address=127.0.0.1/--bind-address=0.0.0.0/' kube-controller-manager.yaml kube-scheduler.yaml
# etcd: additionally serve the (plain HTTP) metrics endpoint on the node address
sudo sed -i 's#--listen-metrics-urls=http://127.0.0.1:2381#--listen-metrics-urls=http://127.0.0.1:2381,http://192.168.1.10:2381#' etcd.yaml

sleep 30; until kubectl get --raw /readyz >/dev/null 2>&1; do sleep 3; done
sudo ss -ltnp | grep -E ':(10257|10259|2381) '
```

kube-proxy reads its configuration from a ConfigMap (workstation):

```bash
kubectl -n kube-system get configmap kube-proxy -o yaml > ~/monitoring/kube-proxy-cm.orig.yaml   # for reference
kubectl -n kube-system get configmap kube-proxy -o yaml \
  | sed 's/metricsBindAddress: ""/metricsBindAddress: 0.0.0.0:10249/' | kubectl apply -f -
kubectl -n kube-system rollout restart daemonset kube-proxy
kubectl -n kube-system rollout status daemonset kube-proxy
```

After a minute all targets are `up`:

```
      1 apiserver up
      2 coredns up
      1 kube-controller-manager up
      1 kube-etcd up
      3 kube-proxy up
      1 kube-scheduler up
      1 kube-state-metrics up
      9 kubelet up
...
```

> The etcd metrics endpoint is unauthenticated - in production restrict port 2381 with a firewall to the
> monitoring nodes. Manifest edits are overwritten by `kubeadm upgrade`; make them permanent in the `kubeadm-config`
> ConfigMap (`controllerManager.extraArgs`, `scheduler.extraArgs`, `etcd.local.extraArgs`, each as a list of
> `name`/`value` pairs in `kubeadm.k8s.io/v1beta4`).

### PromQL basics

PromQL selects time series by metric name and labels and computes with them. Try the queries in the Prometheus UI
(*Graph*) or through the API:

```bash
q() { curl -s --get "http://$PROM_IP:9090/api/v1/query" --data-urlencode "query=$1" \
        | jq -r '.data.result[] | "\(.metric | del(.__name__) | tostring) \(.value[1])"'; }

q 'up{job="kubelet"}'                                                           # instant vector: 1 = target up
q '100 * (1 - avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[5m])))'   # CPU usage % per node
q 'node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes * 100'            # free memory %
q 'topk(3, sum by (namespace) (rate(container_cpu_usage_seconds_total{container!=""}[5m])))'
q 'sum by (namespace) (kube_pod_status_phase{phase="Running"})'                 # from kube-state-metrics
q 'kube_deployment_status_replicas_available{namespace="kube-system"}'
```

Expected (trimmed):

```
{"instance":"192.168.1.12:9100"} 10.52777
{"instance":"192.168.1.11:9100"} 13.04629
{"instance":"192.168.1.10:9100"} 19.70185
...
{"namespace":"kube-system"} 0.487421
{"namespace":"monitoring"} 0.078966
{"namespace":"metallb-system"} 0.035091
```

| Construct | Meaning |
|-----------|---------|
| `metric{label="x", other=~"a|b"}` | select series (`=`, `!=`, `=~` regex, `!~`) |
| `rate(counter[5m])` | per-second increase of a counter over 5 minutes |
| `sum by (label) (...)`, `avg`, `max`, `topk(n, ...)` | aggregate across series |
| `histogram_quantile(0.95, sum by (le) (rate(x_bucket[5m])))` | 95th percentile from a histogram |

### Monitoring your own application: ServiceMonitor

The Prometheus Operator discovers targets through **ServiceMonitors**: "scrape the Services with these labels, on
this port and path". podinfo exposes Prometheus metrics on `/metrics`:

```bash
kubectl create namespace demo-app
kubectl -n demo-app apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: podinfo
spec:
  replicas: 2
  selector:
    matchLabels:
      app: podinfo
  template:
    metadata:
      labels:
        app: podinfo
    spec:
      containers:
      - name: podinfo
        image: ghcr.io/stefanprodan/podinfo:6.17.0
        ports:
        - name: http
          containerPort: 9898
        readinessProbe:
          httpGet:
            path: /readyz
            port: http
        resources:
          requests:
            cpu: 10m
            memory: 32Mi
---
apiVersion: v1
kind: Service
metadata:
  name: podinfo
  labels:
    app: podinfo            # the ServiceMonitor selects this label
spec:
  selector:
    app: podinfo
  ports:
  - name: http              # ... and this port name
    port: 9898
    targetPort: http
---
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: podinfo
spec:
  selector:
    matchLabels:
      app: podinfo
  endpoints:
  - port: http
    path: /metrics
    interval: 15s
EOF
kubectl -n demo-app rollout status deploy/podinfo

# some traffic
kubectl -n demo-app run load --image=curlimages/curl:8.23.0 --restart=Never -- \
  sh -c 'for i in $(seq 1 600); do curl -s -o /dev/null http://podinfo:9898/; sleep 0.2; done'
```

After about a minute (client VM):

```bash
q 'up{namespace="demo-app"}'
q 'sum by (pod) (rate(http_requests_total{namespace="demo-app"}[1m]))'
```

Expected:

```
{"container":"podinfo","endpoint":"http","instance":"172.16.104.36:9898","job":"podinfo","namespace":"demo-app","pod":"podinfo-64db545d-rqxpj","service":"podinfo"} 1
{"container":"podinfo","endpoint":"http","instance":"172.16.166.146:9898","job":"podinfo","namespace":"demo-app","pod":"podinfo-64db545d-k2dwr","service":"podinfo"} 1
{"pod":"podinfo-64db545d-rqxpj"} 2.688888
{"pod":"podinfo-64db545d-k2dwr"} 2.333333
```

The operator added labels such as `namespace`, `pod`, `service` and `job` (the Service name) automatically.

### Recording rules and alerts: PrometheusRule

A **recording rule** precomputes an expensive query under a new name; an **alerting rule** fires when its
expression returns a result for longer than `for:`:

```bash
kubectl -n demo-app apply -f - <<'EOF'
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: podinfo
spec:
  groups:
  - name: podinfo
    rules:
    - record: namespace_job:http_requests:rate5m
      expr: sum by (namespace, job) (rate(http_requests_total[5m]))
    - alert: PodinfoReplicasMissing
      expr: sum(up{namespace="demo-app", job="podinfo"}) < 2
      for: 1m
      labels:
        severity: warning
      annotations:
        summary: "podinfo has fewer than 2 healthy targets"
        description: "Only {{ $value }} podinfo target(s) are up in namespace demo-app."
EOF
```

The operator renders the rule into the Prometheus configuration, which is reloaded within a minute or two. Then check
the rules (client VM) - the alert is `inactive` while both replicas run:

```bash
curl -s "http://$PROM_IP:9090/api/v1/rules" \
  | jq -r '.data.groups[] | select(.name=="podinfo") | .rules[] | "\(.name) \(.state // "-") \(.health)"'
q 'namespace_job:http_requests:rate5m'
```

Expected:

```
namespace_job:http_requests:rate5m - ok
PodinfoReplicasMissing inactive ok
{"job":"podinfo","namespace":"demo-app"} 0.460440
```

Break the application and watch the alert go `pending` (condition true, `for:` not yet over) and then `firing`:

```bash
kubectl -n demo-app scale deploy podinfo --replicas=1      # workstation
sleep 110
curl -s "http://$PROM_IP:9090/api/v1/alerts" | jq -r '.data.alerts[] | select(.labels.alertname=="PodinfoReplicasMissing") | .state'
curl -s "http://$AM_IP:9093/api/v2/alerts" | jq -r '.[] | "\(.labels.alertname) \(.status.state) \(.annotations.description // "")"'
```

Expected:

```
firing
PodinfoReplicasMissing active Only 1 podinfo target(s) are up in namespace demo-app.
Watchdog active This is an alert meant to ensure that the entire alerting pipeline is functional. ...
```

`Watchdog` always fires on purpose - an external "dead man's switch" can alert when it stops arriving. The chart
also ships ~150 ready-made alerts for the cluster (`KubePodCrashLooping`, `KubeNodeNotReady`, `etcdNoLeader`, ...).
Notifications are configured in Alertmanager (`alertmanager.config` in the chart values or `AlertmanagerConfig`
objects). Restore the application:

```bash
kubectl -n demo-app scale deploy podinfo --replicas=2
```

### Dashboards in Grafana

The chart provisions a Prometheus data source and ~30 dashboards (cluster, nodes, namespaces, Pods, API server, etcd,
CoreDNS, ...). Check them through the Grafana API (client VM):

```bash
curl -s -u 'admin:Grafana-2026!' http://$GRAFANA_IP/api/datasources | jq -r '.[] | .name + " " + .type'
curl -s -u 'admin:Grafana-2026!' "http://$GRAFANA_IP/api/search?type=dash-db" | jq -r '.[].title' | head
```

Expected (trimmed):

```
Alertmanager alertmanager
Prometheus prometheus
Alertmanager / Overview
CoreDNS
etcd
Grafana Overview
Kubernetes / API server
...
```

In the UI open **Dashboards -> Kubernetes / Compute Resources / Namespace (Pods)** and select `demo-app`, or
**Node Exporter / Nodes**. **Explore** runs ad-hoc PromQL queries.

---

## Centralized Logging with Loki and Grafana Alloy

`kubectl logs` shows the log of one container - and only while the Pod exists. Central logging collects the logs of
all Pods, keeps them after the Pods are gone and makes them searchable:

```
Pod logs ──▶ Grafana Alloy (DaemonSet) ──push──▶ Loki ◀──LogQL── Grafana
```

* **Loki** stores log lines grouped into *streams* by a few labels (`namespace`, `pod`, `app`, ...); the line itself is
  not indexed, which keeps Loki cheap. Queries are written in **LogQL**.
* **Grafana Alloy** is Grafana's collector (successor of Promtail and Grafana Agent): it discovers Pods, attaches
  Kubernetes labels and ships the logs.

### Installing Loki

Loki in **SingleBinary** mode (one Pod with all components) with the local filesystem as storage - enough for a
training cluster. Production setups use the scalable modes with object storage (S3, MinIO, GCS):

```bash
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update
cd ~/monitoring
```

```yaml
# loki-values.yaml
deploymentMode: SingleBinary
loki:
  auth_enabled: false                # single tenant
  commonConfig:
    replication_factor: 1
  storage:
    type: filesystem
  schemaConfig:
    configs:
    - from: "2024-04-01"
      store: tsdb
      object_store: filesystem
      schema: v13
      index:
        prefix: loki_index_
        period: 24h
  limits_config:
    retention_period: 48h
singleBinary:
  replicas: 1
  persistence:
    enabled: false          # no dynamic block storage in the training cluster
  extraVolumes:             # -> keep the data in an emptyDir (lost when the Pod is recreated)
  - name: data
    emptyDir: {}
  extraVolumeMounts:
  - name: data
    mountPath: /var/loki
# the scalable components and the optional extras are not needed
read:
  replicas: 0
write:
  replicas: 0
backend:
  replicas: 0
gateway:
  enabled: false
chunksCache:
  enabled: false
resultsCache:
  enabled: false
lokiCanary:
  enabled: false
test:
  enabled: false
```

```bash
helm install loki grafana/loki --version 7.5.0 -n monitoring -f loki-values.yaml --wait --timeout 10m
kubectl -n monitoring get pods -l app.kubernetes.io/name=loki
kubectl -n monitoring get svc loki
```

Expected:

```
NAME     READY   STATUS    RESTARTS   AGE
loki-0   2/2     Running   0          42s
NAME   TYPE        CLUSTER-IP       EXTERNAL-IP   PORT(S)             AGE
loki   ClusterIP   10.106.255.230   <none>        3100/TCP,9095/TCP   1m
```

> Without the `extraVolumes` block (and with `persistence.enabled: false`) Loki crashes with
> `mkdir /var/loki: read-only file system`; with persistence enabled it waits for a PVC that no provisioner creates.

### Collecting logs with Grafana Alloy

Alloy runs as a DaemonSet. Every instance discovers the Pods **of its own node** (field selector on `spec.nodeName`,
otherwise each instance would ship every log), turns Kubernetes metadata into Loki labels, reads the logs through the
Kubernetes API and pushes them to Loki. The configuration language is Alloy's own (components wired together by
their exports):

```yaml
# alloy-values.yaml
controller:
  type: daemonset          # one Alloy per node
  tolerations:             # ... including the control-plane node
  - key: node-role.kubernetes.io/control-plane
    operator: Exists
    effect: NoSchedule
alloy:
  extraEnv:
  - name: NODE_NAME        # lets every Alloy instance collect only the Pods of its own node
    valueFrom:
      fieldRef:
        fieldPath: spec.nodeName
  configMap:
    content: |
      // 1. find the Pods running on this node
      discovery.kubernetes "pods" {
        role = "pod"
        selectors {
          role  = "pod"
          field = "spec.nodeName=" + sys.env("NODE_NAME")
        }
      }

      // 2. turn Kubernetes metadata into Loki labels
      discovery.relabel "pods" {
        targets = discovery.kubernetes.pods.targets
        rule {
          source_labels = ["__meta_kubernetes_namespace"]
          target_label  = "namespace"
        }
        rule {
          source_labels = ["__meta_kubernetes_pod_name"]
          target_label  = "pod"
        }
        rule {
          source_labels = ["__meta_kubernetes_pod_container_name"]
          target_label  = "container"
        }
        rule {
          source_labels = ["__meta_kubernetes_pod_label_app"]
          target_label  = "app"
        }
        rule {
          source_labels = ["__meta_kubernetes_pod_node_name"]
          target_label  = "node"
        }
      }

      // 3. read the container logs through the Kubernetes API (like kubectl logs)
      loki.source.kubernetes "pods" {
        targets    = discovery.relabel.pods.output
        forward_to = [loki.write.default.receiver]
      }

      // 4. push them to Loki
      loki.write "default" {
        endpoint {
          url = "http://loki.monitoring.svc.cluster.local:3100/loki/api/v1/push"
        }
      }
```

```bash
helm install alloy grafana/alloy --version 1.15.0 -n monitoring -f alloy-values.yaml --wait --timeout 5m
kubectl -n monitoring get pods -l app.kubernetes.io/name=alloy -o wide
kubectl -n monitoring logs ds/alloy -c alloy --tail=3
```

Expected - one Alloy per node:

```
NAME          READY   STATUS    RESTARTS   AGE   IP               NODE
alloy-2p272   2/2     Running   0          40s   172.16.166.150   node1
alloy-7tkbx   2/2     Running   0          40s   172.16.104.41    node2
alloy-lqj5p   2/2     Running   0          40s   172.16.219.90    master
```

Check that Loki receives streams (the label values are the namespaces whose Pods logged something):

```bash
kubectl -n monitoring run lokiq --rm -i --restart=Never --image=curlimages/curl:8.23.0 -- \
  -s http://loki:3100/loki/api/v1/label/namespace/values
```

Expected (trimmed):

```
{"status":"success","data":["demo-app","kube-system","lab-08-shop","metallb-system","monitoring","nginx-gateway"]}
```

### Loki in Grafana

Add Loki as a data source of the Grafana installed by kube-prometheus-stack - with an extra values file, so
`kps-values.yaml` stays unchanged:

```yaml
# grafana-loki.yaml
grafana:
  additionalDataSources:
  - name: Loki
    type: loki
    uid: loki
    url: http://loki.monitoring.svc.cluster.local:3100
    access: proxy
```

```bash
helm upgrade monitoring prometheus-community/kube-prometheus-stack --version 92.21.1 \
  -n monitoring -f kps-values.yaml -f grafana-loki.yaml --wait --timeout 10m
```

A demo application that writes structured (JSON) logs - every fifth order fails:

```bash
kubectl -n demo-app apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: log-generator
spec:
  replicas: 1
  selector:
    matchLabels:
      app: log-generator
  template:
    metadata:
      labels:
        app: log-generator
    spec:
      containers:
      - name: generator
        image: busybox:1.38
        command:
        - sh
        - -c
        - |
          i=0
          while true; do
            i=$((i+1))
            if [ $((i % 5)) -eq 0 ]; then
              echo "{\"level\":\"error\",\"msg\":\"payment failed\",\"order\":$i,\"reason\":\"card declined\"}"
            else
              echo "{\"level\":\"info\",\"msg\":\"order processed\",\"order\":$i,\"amount\":$((i * 7 % 100))}"
            fi
            sleep 1
          done
        resources:
          requests:
            cpu: 5m
            memory: 8Mi
EOF
kubectl -n demo-app rollout status deploy/log-generator
```

### LogQL

In Grafana open **Explore**, choose the **Loki** data source and run the queries below (switch the editor to *Code*).
The same queries work against the API - here through Grafana's data source proxy (client VM, after ~1 minute):

```bash
lq() { curl -s -u 'admin:Grafana-2026!' -G "http://$GRAFANA_IP/api/datasources/proxy/uid/loki/loki/api/v1/$1" \
         --data-urlencode "query=$2" --data-urlencode limit=2 \
       | jq -r '.data.result[] | if .values then .values[][1] else "\(.metric | tostring) \(.value[1])" end'; }

# 1. stream selector: all logs of the app
lq query_range '{namespace="demo-app", app="log-generator"}'
# 2. line filter: lines containing "payment"
lq query_range '{app="log-generator"} |= "payment"'
# 3. parser + label filter + formatting
lq query_range '{app="log-generator"} | json | level="error" | line_format "order {{.order}}: {{.reason}}"'
# 4. metric query: log lines per level in the last minute
lq query 'sum by (level) (count_over_time({app="log-generator"} | json [1m]))'
# 5. the noisiest namespaces
lq query 'topk(3, sum by (namespace) (count_over_time({namespace=~".+"}[5m])))'
```

Expected (trimmed):

```
{"level":"info","msg":"order processed","order":72,"amount":4}
{"level":"info","msg":"order processed","order":71,"amount":97}
{"level":"error","msg":"payment failed","order":70,"reason":"card declined"}
{"level":"error","msg":"payment failed","order":65,"reason":"card declined"}
order 70: card declined
order 65: card declined
{"level":"error"} 12
{"level":"info"} 48
{"namespace":"kube-system"} 906
{"namespace":"monitoring"} 589
{"namespace":"metallb-system"} 76
```

| LogQL | Meaning |
|-------|---------|
| `{label="value"}` | stream selector (required, uses the index) |
| `\|= "text"`, `!= "text"`, `\|~ "regex"` | line filters |
| `\| json`, `\| logfmt`, `\| pattern "<ip> - <_>"` | parse the line into labels |
| `\| level="error"`, `\| amount > 50` | filter on parsed labels |
| `\| line_format "{{.order}}"` | rewrite the output line |
| `count_over_time(...[5m])`, `rate(...[1m])` | turn logs into metrics (for dashboards and alerts) |

Keep the number of stream labels small (namespace, app, pod, container): high-cardinality values such as user or
order IDs belong into the log line, not into labels.

---

## Clean up the monitoring workshop

Remove the demo application and the monitoring stack (workstation):

```bash
kubectl delete namespace demo-app
helm uninstall alloy loki monitoring -n monitoring
kubectl delete namespace monitoring
# the chart CRDs stay installed (Helm never deletes CRDs) - remove them if you do not need them any more
kubectl get crd -o name | grep monitoring.coreos.com | xargs kubectl delete
```

Put the control-plane metrics settings back (or keep them if you keep Prometheus). On `master`:

```bash
for f in kube-controller-manager kube-scheduler etcd; do
  sudo cp /root/$f.yaml.orig /etc/kubernetes/manifests/$f.yaml
done
sleep 30; until kubectl get --raw /readyz >/dev/null 2>&1; do sleep 3; done
sudo ss -ltnp | grep -E ':(10257|10259|2381) '      # 127.0.0.1 only again
```

On the workstation:

```bash
kubectl -n kube-system get configmap kube-proxy -o yaml \
  | sed 's/metricsBindAddress: 0.0.0.0:10249/metricsBindAddress: ""/' | kubectl apply -f -
kubectl -n kube-system rollout restart daemonset kube-proxy
kubectl -n kube-system rollout status daemonset kube-proxy
```
