Nice — below is a complete, practical, hands-by-step tutorial for a **vanilla kubeadm** Kubernetes control-plane which covers:

* how to **safely upgrade** the cluster (control plane + nodes),
* how to **backup etcd** (snapshots) and **restore** from them,
* how to **secure / encrypt etcd** (both TLS for etcd communication and data-at-rest options),
* how to **encrypt Kubernetes secrets stored in etcd** (Kubernetes API server envelope encryption),
* verification steps and useful recovery tips.

I assume a kubeadm-managed cluster where the control plane runs as static pods on one or more control-plane hosts (default kubeadm layout). Adapt paths/commands if you run an external etcd cluster or cloud-managed control plane.

---

# 1. Safe preparation checklist (do this first)

1. Work on a maintenance window; notify users.
2. Take an immediate etcd snapshot before any change. (Commands below.)
3. Ensure you have SSH access to control plane and all worker nodes.
4. Back up the `/etc/kubernetes` directory (certs, manifests).

   ```bash
   sudo tar czf /root/k8s-etc-k8s-$(date -I).tgz /etc/kubernetes
   ```
5. Record current versions:

   ```bash
   kubectl version --short
   kubeadm version
   uname -a
   lsb_release -a  # or cat /etc/os-release
   ```
6. If using HA (multiple control planes), read the HA notes later in this doc.

---

# 2. How kubeadm cluster upgrade works (high level)

* `kubeadm upgrade plan` checks available control-plane versions you can upgrade to.
* Upgrade order:

    1. Upgrade `kubeadm` package on control plane node.
    2. Run `kubeadm upgrade apply <version>` on the control-plane node(s) — this updates control plane static manifests (kube-apiserver, kube-controller-manager, kube-scheduler) to the new images.
    3. Upgrade kubelet and kubectl packages and restart kubelet on each node (control plane and workers). Drain workers during kubelet upgrade.
* For HA clusters (multiple control planes), upgrade control planes one at a time.

> Important: always take an etcd snapshot before upgrades.

---

# 3. Upgrade example (Ubuntu/Debian with apt) — step-by-step

> Replace `<K8S_VERSION>` with the target `vX.Y.Z` (e.g. `v1.28.2`). Use the exact semver returned by `kubeadm upgrade plan`.

## 3.1 On the control-plane node — take etcd snapshot first

(We run this on the control plane so we can access the local etcd via the static pod certs.)

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

## 3.2 Upgrade `kubeadm` and plan

```bash
# Update package lists and install desired kubeadm
sudo apt-get update
sudo apt-get install -y --allow-downgrades kubeadm=<K8S_VERSION>-00

# Check upgrade plan
sudo kubeadm upgrade plan
```

Read the output carefully: it will list recommended target version and image pull steps.

## 3.3 Apply control-plane upgrade

```bash
sudo kubeadm upgrade apply <K8S_VERSION>
# e.g. sudo kubeadm upgrade apply v1.28.2
```

This updates the static pod manifests under `/etc/kubernetes/manifests/` to use newer component images. kubelet will restart the static pod.

Verify:

```bash
kubectl get nodes
kubectl get cs
kubectl -n kube-system get pods -o wide
```

## 3.4 Upgrade kubelet & kubectl on control-plane node

```bash
sudo apt-get install -y --allow-downgrades kubelet=<K8S_VERSION>-00 kubectl=<K8S_VERSION>-00
sudo systemctl daemon-reload
sudo systemctl restart kubelet
```

## 3.5 For worker nodes (one-by-one)

For each worker node:

```bash
kubectl drain <node> --ignore-daemonsets --delete-local-data
# On node:
sudo apt-get update
sudo apt-get install -y --allow-downgrades kubelet=<K8S_VERSION>-00 kubectl=<K8S_VERSION>-00
sudo systemctl daemon-reload
sudo systemctl restart kubelet

# back on control plane:
kubectl uncordon <node>
```

---

# 4. etcd — backup (snapshot) and restore (detailed)

## 4.1 Where etcd data is

* For kubeadm-managed stacked etcd, the data dir is usually: `/var/lib/etcd`.
* Static pod manifest for etcd is `/etc/kubernetes/manifests/etcd.yaml`.

## 4.2 Take a consistent etcd snapshot (recommended)

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

# check snapshot status
sudo ETCDCTL_API=3 \
  /usr/bin/etcdctl \
  snapshot status ${SNAPSHOT_DIR}/etcd-snap-*.db \
  --write-out=table
```

Store `*.db` snapshot in immutable off-site storage (scp to backup server, S3, etc).

## 4.3 Restoring etcd from snapshot (single control-plane example)

> This is destructive for existing etcd — only perform if you need a restore.

1. Stop kube-apiserver (kubeadm static pods are managed by kubelet — simplest approach is to stop kubelet so the static pods don't restart while we restore).

```bash
sudo systemctl stop kubelet
```

2. Move old data dir (safe copy)

```bash
sudo mv /var/lib/etcd /var/lib/etcd-old-$(date -Iseconds)
sudo mkdir -p /var/lib/etcd
sudo chown -R etcd:etcd /var/lib/etcd
```

3. Restore snapshot to data-dir with `etcdctl snapshot restore`.

```bash
SNAP=${SNAPSHOT_DIR}/etcd-snap-2025-09-19T12:34:56Z.db  # your snapshot file
RESTORE_DIR=/var/lib/etcd

sudo /usr/bin/etcdctl snapshot restore ${SNAP} \
  --data-dir ${RESTORE_DIR} \
  --name $(hostname -s) \
  --initial-advertise-peer-urls https://127.0.0.1:2380 \
  --initial-cluster $(hostname -s)=https://127.0.0.1:2380 \
  --initial-cluster-token etcd-cluster-1 \
  --initial-cluster-state new
```

> For HA with multiple control-planes, restoring is more involved — you usually restore a snapshot to one member, then rejoin other members or rebuild nodes. See HA notes below.

4. Recreate / adjust ownership:

```bash
sudo chown -R etcd:etcd ${RESTORE_DIR}
```

5. Start kubelet again:

```bash
sudo systemctl start kubelet
```

kubelet will restart static pods (etcd, kube-apiserver). Verify the etcd member is healthy:

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

# 5. Encrypt etcd communication (TLS) — why & how

* By default kubeadm generates TLS certs for etcd under `/etc/kubernetes/pki/etcd/` and configures the static pod to use certs. This secures:

    * peer communication (etcd peer-to-peer),
    * client communication (kube-apiserver <-> etcd),
    * external access to etcd (if you expose it, protect it).
* Verify TLS is enabled: check `/etc/kubernetes/manifests/etcd.yaml` includes `--cert-file`/`--key-file`/`--trusted-ca-file` flags. If not, generate certs and update manifest.

## 5.1 How to generate strong certs (example using cfssl or openssl)

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

# 6. Encrypt etcd data at rest — options & examples

There are three common approaches:

## Option A — Disk-level encryption (LUKS) for `/var/lib/etcd`

Encrypt the underlying disk or partition using LUKS (recommended for on-prem single-host encryption). Example: create encrypted LVM or LUKS partition and mount it to `/var/lib/etcd` before starting etcd.

Quick LUKS example (DESTROYS DEVICE — be careful):

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

## Option B — etcd data encryption using filesystem-level encryption or application-layer encryption

etcd itself doesn't provide built-in general data-at-rest encryption for its files beyond using TLS for in-transit and snapshots; so application-layer encryption (encrypting individual sensitive objects) or disk-level encryption is normally used. For Kubernetes secrets, use Kubernetes API server encryption (Option C below) rather than relying on etcd-level encryption.

## Option C — Kubernetes API server Envelope Encryption (recommended to encrypt Kubernetes Secrets at rest)

This does not encrypt the whole etcd data but encrypts sensitive Kubernetes API resources (Secrets, configmaps, etc) before storing them in etcd. This is typically what people mean by "encrypt etcd data (secrets)". Steps:

### 6.1 Create an encryption config file

Create `/etc/kubernetes/encryption-config.yaml` on the control-plane node(s):

```yaml
kind: EncryptionConfig
apiVersion: v1
resources:
  - resources:
      - secrets
    providers:
      - aescbc:
          keys:
            - name: key1
              secret: <BASE64_32_BYTES>
      - identity: {}
```

`<BASE64_32_BYTES>` must be a 32-byte base64 value. Generate it:

```bash
head -c 32 /dev/urandom | base64
# place that string as the secret value
```

### 6.2 Put the file on the control plane and secure it

```bash
sudo mkdir -p /etc/kubernetes
sudo chown root:root /etc/kubernetes/encryption-config.yaml
sudo chmod 600 /etc/kubernetes/encryption-config.yaml
```

### 6.3 Configure kube-apiserver to use it

Edit `/etc/kubernetes/manifests/kube-apiserver.yaml` — add the flag to the kube-apiserver command args:

```
--encryption-provider-config=/etc/kubernetes/encryption-config.yaml
```

kubelet will restart the kube-apiserver static pod automatically.

### 6.4 Re-encrypt existing secrets

New secrets will be encrypted from now on. To encrypt existing secrets in etcd, you must:

1. Make sure `--encryption-provider-config` is active and kube-apiserver restarted.
2. Re-save all secrets (the easiest approach — this forces them to be written back through the API server and be re-encrypted):

```bash
kubectl get secrets --all-namespaces -o json \
  | jq -c '.items[]' \
  | while read -r secret; do
      ns=$(echo "$secret" | jq -r '.metadata.namespace')
      name=$(echo "$secret" | jq -r '.metadata.name')
      # re-apply each secret's metadata+data (strip metadata managed fields)
      kubectl get secret -n "$ns" "$name" -o yaml \
        | kubectl apply -f -
    done
```

Alternatively, you can export all secrets and reapply them carefully.

### 6.5 Verify encryption

1. Read raw object from etcd (use etcdctl) using the kube-apiserver identity cert; you will see that the secret value in etcd is opaque (Base64) and not the plaintext. Example:

```bash
# Using etcdctl direct access to list keys is complex; instead verify via API:
# Query kube-apiserver / etcd raw storage (not trivial). Practically, you can:
#  - Create a test secret,
kubectl create ns encrypt-test || true
kubectl -n encrypt-test create secret generic mysecret --from-literal=k=secret123

#  - Take an etcd snapshot and check the snapshot content (it will show the secret in encrypted form).
sudo ETCDCTL_API=3 /usr/bin/etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  snapshot save /root/etcd-backups/test.db

# strings test.db | grep -i mysecret || true  # you should not see the cleartext secret value
```

---

# 7. Best practices & verification checklist

* Always take snapshots before upgrades or critical changes.
* Store snapshots off-host (S3, remote storage) and rotate snapshots.
* Test restore on a non-production environment.
* Keep encryption keys (for LUKS and envelope keys) secure and backed up.
* Keep `/etc/kubernetes/encryption-config.yaml` off accessible backups or in a secure secrets manager.
* Periodically test your disaster recovery plan end-to-end.
* Use role-based access and limit etcd access (only kube-apiserver client cert should be able to read/write).

---

# 8. HA cluster notes (multiple control planes)

* For HA, etcd runs as a clustered set across control-plane nodes.
* Backup: you can snapshot any healthy member but prefer leader (or use `ETCDCTL_API=3` with all endpoints).
* Upgrade control planes one at a time: take snapshot, upgrade one control-plane, verify cluster health before moving to the next.
* Restoring HA: usually rebuild one control-plane from snapshot and rejoin the cluster or rebuild cluster from snapshot as a single-member and then re-add members — careful and follow etcd HA protocols.

---

# 9. Quick troubleshooting commands

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

* If kube-apiserver won't start after encryption configuration, check `/var/log/pods/...` or `kubectl -n kube-system get pods` and `docker/ containerd` logs. Common cause: wrong path/permissions of `encryption-config.yaml`.

---

# 10. Example scripts (putting it together)

## 10.1 Snapshot script (save to local and copy to remote)

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

## 10.2 Quick restore guide (comments in script)

I won't provide an automatic destructive restore script here — restores require human checks. Use the manual procedure in section 4.3.

---

# 11. Summary of key commands (cheat-sheet)

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
sudo systemctl stop kubelet
sudo mv /var/lib/etcd /var/lib/etcd-old-$(date -Iseconds)
sudo /usr/bin/etcdctl snapshot restore <snap.db> --data-dir /var/lib/etcd --name <name> --initial-cluster <...> ...
sudo chown -R etcd:etcd /var/lib/etcd
sudo systemctl start kubelet
```

Enable kube-apiserver envelope encryption:

1. create `/etc/kubernetes/encryption-config.yaml` (see section 6)
2. add `--encryption-provider-config=/etc/kubernetes/encryption-config.yaml` to `/etc/kubernetes/manifests/kube-apiserver.yaml`
3. re-apply secrets to re-encrypt.

Upgrade kubeadm control plane:

```bash
sudo apt-get install -y kubeadm=<K8S_VERSION>-00
sudo kubeadm upgrade apply <K8S_VERSION>
sudo apt-get install -y kubelet=<K8S_VERSION>-00 kubectl=<K8S_VERSION>-00
sudo systemctl restart kubelet
```

---

# 12. Final notes, gotchas & recommendations

* If you run an external etcd cluster (not stacked), follow etcd operator or your managed etcd provider docs — backup/restore differs.
* Never expose etcd to the public Internet. Firewall it to only kube-apiserver and trusted admin hosts.
* Keep etcd snapshots in multiple secure locations. Test restore periodically.
* Keep encryption provider keys (for kube-apiserver) backed up in a secure KMS or offline vault. Losing the key means you cannot decrypt older secrets.
* Consider using cloud provider disk encryption + secret management (KMS) for keys for production setups.
