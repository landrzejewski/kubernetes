# Module 04: Storage

Containers lose their filesystem when they restart, so anything worth keeping, or worth sharing between containers,
has to live in a volume. In this module you move from Pod-scoped scratch space (emptyDir, tmpfs) through node-bound
storage (hostPath, local PersistentVolumes, StatefulSets) to S3 object storage that any Pod on any node can use, and you
finish with backups, restores and file permissions, the problems you meet first in production.

## Prerequisites check

```bash
workstation$ kubectl get nodes                      # master, node1, node2 Ready
workstation$ kubectl get storageclass minio-sc      # PROVISIONER ru.yandex.s3.csi
client-vm$   curl -s http://192.168.1.100:9000/minio/health/live -o /dev/null -w '%{http_code}\n'   # 200
```

Several labs inspect S3 buckets from the client VM with the MinIO client. Define a short alias for it there
(`MC_HOST_m` configures the `mc` alias `m` without `mc alias set`; `-i` lets you pipe data into the container):

```bash
client-vm$ alias mc='docker run --rm -i --network host -e MC_HOST_m=http://minioadmin:minioadmin123@192.168.1.100:9000 pgsty/mc:RELEASE.2026-10-26T00-00-00Z'
client-vm$ mc ls m/                                  # [...] 0B training-bucket/
```

There is **no dynamic block-storage provisioner** in the cluster. Labs that need disk-backed PersistentVolumes create
them statically under `/mnt/lab-04-*` on the worker nodes and remove them in *Clean up*.

## Table of contents

- [Lab 4.1: Publish a website from Git with a git-sync sidecar](#lab-41-publish-a-website-from-git-with-a-git-sync-sidecar)
- [Lab 4.2: A RAM-backed scratch area for an image-processing job](#lab-42-a-ram-backed-scratch-area-for-an-image-processing-job)
- [Lab 4.3: A node log viewer with hostPath, and the "data stays on the node" trap](#lab-43-a-node-log-viewer-with-hostpath-and-the-data-stays-on-the-node-trap)
- [Lab 4.4: A Postgres database on a static local PersistentVolume](#lab-44-a-postgres-database-on-a-static-local-persistentvolume)
- [Lab 4.5: A Redis StatefulSet with volumeClaimTemplates on pre-provisioned local disks](#lab-45-a-redis-statefulset-with-volumeclaimtemplates-on-pre-provisioned-local-disks)
- [Lab 4.6: Shared uploads across nodes with an S3-backed ReadWriteMany volume](#lab-46-shared-uploads-across-nodes-with-an-s3-backed-readwritemany-volume)
- [Lab 4.7: Nightly Postgres backups to S3 with a CronJob](#lab-47-nightly-postgres-backups-to-s3-with-a-cronjob)
- [Lab 4.8: Restore a dataset from S3 with an init container](#lab-48-restore-a-dataset-from-s3-with-an-init-container)
- [Lab 4.9: Non-root containers and volume permissions](#lab-49-non-root-containers-and-volume-permissions)

---

## Lab 4.1: Publish a website from Git with a git-sync sidecar

**Scenario** – The documentation team edits a static website in a public Git repository and wants every merge to go
live within a minute, without building a new container image. We run nginx next to a
[git-sync](https://github.com/kubernetes/git-sync) sidecar: git-sync clones the repository into an `emptyDir` volume and
pulls new commits periodically, and nginx serves the files from the same volume.

**What you'll learn**
- sharing an `emptyDir` volume between two containers of one Pod
- native sidecars (`initContainers` with `restartPolicy: Always`) plus a `startupProbe` to enforce start order
- how git-sync publishes a new revision atomically (a symlink swap)
- where an `emptyDir` lives on the node and when it disappears

### Steps

1. Create the namespace and the Deployment. git-sync runs as a **native sidecar**: kubelet starts it before nginx and
   waits until its `startupProbe` succeeds. git-sync's HTTP endpoint returns 200 only after the first successful sync, so
   nginx never starts in front of an empty directory.

```bash
workstation$ kubectl create namespace lab-04-01
workstation$ kubectl -n lab-04-01 apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: docs-site
spec:
  replicas: 1
  selector:
    matchLabels: {app: docs-site}
  template:
    metadata:
      labels: {app: docs-site}
    spec:
      initContainers:
      - name: git-sync                      # native sidecar: starts first, keeps running
        image: registry.k8s.io/git-sync/git-sync:v4.8.0
        restartPolicy: Always
        args:
        - --repo=https://github.com/mdn/beginner-html-site-styled
        - --ref=HEAD
        - --root=/git/repo                  # the clone (git-sync creates this directory itself)
        - --link=/git/html                  # symlink -> repo/.worktrees/<commit-sha>
        - --period=60s
        - --depth=1
        - --http-bind=:2020                 # returns 200 after the first successful sync
        ports:
        - {name: git-sync, containerPort: 2020}
        startupProbe:                       # nginx is started only after this probe succeeds
          httpGet: {path: /, port: git-sync}
          periodSeconds: 2
          failureThreshold: 30
        volumeMounts:
        - {name: content, mountPath: /git}
      containers:
      - name: nginx
        image: nginx:1.31-alpine
        ports:
        - containerPort: 80
        volumeMounts:
        - {name: content, mountPath: /usr/share/nginx, readOnly: true}   # nginx root = /usr/share/nginx/html
      volumes:
      - name: content
        emptyDir: {}
EOF
workstation$ kubectl -n lab-04-01 get pods -w
```

Expected:
```
NAME                        READY   STATUS            RESTARTS   AGE
docs-site-bbc4dd4cd-lthg9   0/2     Init:0/1          0          1s
docs-site-bbc4dd4cd-lthg9   0/2     PodInitializing   0          4s
docs-site-bbc4dd4cd-lthg9   1/2     PodInitializing   0          4s
docs-site-bbc4dd4cd-lthg9   2/2     Running           0          5s
```

> **Why `--root=/git/repo` and not `/git`?** An `emptyDir` is created as `root:root 0777`, but git-sync runs as UID
> 65533. Git refuses to work in a repository owned by another user (`fatal: detected dubious ownership in repository at
> '/git'`) and the sidecar crash-loops. Letting git-sync create its own sub-directory avoids that.

2. Look at the shared volume from the nginx side. `html` is a symlink that git-sync swaps atomically when a new commit
   arrives, so nginx never serves a half-updated tree.

```bash
workstation$ kubectl -n lab-04-01 exec deploy/docs-site -c nginx -- ls -la /usr/share/nginx
workstation$ kubectl -n lab-04-01 exec deploy/docs-site -c nginx -- wget -qO- localhost | grep title
workstation$ kubectl -n lab-04-01 logs deploy/docs-site -c git-sync | grep -E 'update required|updated successfully'
```

Expected:
```
drwxrwxrwx    3 root     root          4096 Nov  4 02:23 .
lrwxrwxrwx    1 65533    nogroup         56 Nov  4 02:23 html -> repo/.worktrees/6c7a360ddb4a0d75be06044bf8a914f260ff10c7
drwxr-xr-x    4 65533    nogroup       4096 Nov  4 02:23 repo
    <title>My test page</title>
{..."msg":"update required","ref":"HEAD","local":"","remote":"6c7a360ddb4a0d75be06044bf8a914f260ff10c7","syncCount":0}
{..."msg":"updated successfully","ref":"HEAD","remote":"6c7a360ddb4a0d75be06044bf8a914f260ff10c7","syncCount":1}
```

Every 60 seconds git-sync checks the remote. When someone pushes, a new worktree is checked out next to the old one
and the `html` link is re-pointed. No Pod restart and no image build are involved.

3. Check the start order: nginx started only after git-sync finished the first sync.

```bash
workstation$ kubectl -n lab-04-01 get pod -l app=docs-site -o jsonpath='{.items[0].status.initContainerStatuses[0].state.running.startedAt}  {.items[0].status.containerStatuses[0].state.running.startedAt}{"\n"}'
```

Expected (git-sync first, nginx a few seconds later):
```
2026-11-04T02:26:55Z  2026-11-04T02:26:59Z
```

4. Find the volume on the node. An `emptyDir` is just a directory under the kubelet's Pod directory.

```bash
workstation$ kubectl -n lab-04-01 get pod -l app=docs-site -o jsonpath='{.items[0].spec.nodeName} {.items[0].metadata.uid}{"\n"}'
node2$ sudo ls -la /var/lib/kubelet/pods/<POD_UID>/volumes/kubernetes.io~empty-dir/content
```

Expected:
```
node2 9c27297b-6c98-4e14-9a01-a5e3eb675e0a
drwxrwxrwx 3 root  root  4096 Nov  4 03:23 .
lrwxrwxrwx 1 65533 65533   56 Nov  4 03:23 html -> repo/.worktrees/6c7a360ddb4a0d75be06044bf8a914f260ff10c7
drwxr-xr-x 4 65533 65533 4096 Nov  4 03:23 repo
```

5. Delete the Pod. The `emptyDir` is deleted with it; the replacement Pod gets a fresh, empty volume and clones again.
   That is fine here because Git is the source of truth.

```bash
workstation$ kubectl -n lab-04-01 delete pod -l app=docs-site
workstation$ kubectl -n lab-04-01 logs deploy/docs-site -c git-sync | grep -c 'initializing repo'
```

Expected:
```
1
```

6. A security pitfall: the checkout contains a `.git` file and a `.github/` directory, and nginx happily serves them.

```bash
workstation$ kubectl -n lab-04-01 exec deploy/docs-site -c nginx -- wget -qO- localhost/.git
```

Expected:
```
gitdir: ../../.git/worktrees/6c7a360ddb4a0d75be06044bf8a914f260ff10c7
```

### Clean up

```bash
workstation$ kubectl delete namespace lab-04-01
```

### Your turn

The security review flags the `/.git` leak, and the site needs two replicas behind a Service. Without changing the
image, make nginx return **403** for every path that starts with a dot, scale `docs-site` to 2 replicas, expose it with a
ClusterIP Service `docs-site`, and prove from a throw-away curl Pod that `/` and `/styles/style.css` return 200 while
`/.git` and `/.github/` return 403. Each replica runs its own git-sync. Is that a problem?

<details><summary>Solution</summary>

Mount a ConfigMap with an nginx server block over `/etc/nginx/conf.d` (it replaces `default.conf`):

```bash
workstation$ kubectl -n lab-04-01 apply -f - <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: docs-nginx
data:
  default.conf: |
    server {
      listen 80;
      root /usr/share/nginx/html;
      location ~ /\. { deny all; return 403; }   # .git, .github, .env ...
      location / { try_files $uri $uri/ =404; }
    }
---
apiVersion: v1
kind: Service
metadata:
  name: docs-site
spec:
  selector: {app: docs-site}
  ports:
  - port: 80
EOF
```

In the Deployment from step 1 set `replicas: 2` and extend the nginx container and the volumes:

```yaml
        volumeMounts:
        - {name: content, mountPath: /usr/share/nginx, readOnly: true}
        - {name: nginx-conf, mountPath: /etc/nginx/conf.d, readOnly: true}
      volumes:
      - name: content
        emptyDir: {}
      - name: nginx-conf
        configMap: {name: docs-nginx}
```

Apply it and verify:

```bash
workstation$ kubectl -n lab-04-01 rollout status deploy/docs-site
workstation$ kubectl -n lab-04-01 run curl --rm -i --restart=Never --image=curlimages/curl:8.23.0 -- \
  sh -c 'for p in / /.git /.github/ /styles/style.css; do curl -s -o /dev/null -w "%{http_code} $p\n" http://docs-site$p; done'
```

Expected:
```
200 /
403 /.git
403 /.github/
200 /styles/style.css
```

Each replica has its own `emptyDir` and polls Git on its own schedule, so for up to one `--period` the replicas can
serve different commits. For a docs site that is acceptable; if it is not, publish versioned content (an image or an S3
bucket, see Lab 4.6) instead.

</details>

---

## Lab 4.2: A RAM-backed scratch area for an image-processing job

**Scenario** – A thumbnail worker unpacks uploads into a scratch directory, resizes them and throws the intermediate files
away. The disk on the nodes is slow, so the team wants the scratch area in RAM (`emptyDir` with `medium: Memory`).
Before this goes to production we check what happens when the scratch area fills up, because tmpfs is memory, and
memory has limits.

**What you'll learn**
- `emptyDir.medium: Memory` creates a tmpfs whose size is `sizeLimit`, capped by the Pod's memory limit
- files in tmpfs are charged to the Pod's memory (they show up in `kubectl top` and can cause an OOM kill)
- tmpfs content survives a container restart, so an OOM can keep repeating
- a disk-backed `emptyDir` has no hard cap; the kubelet **evicts** the Pod when it exceeds `sizeLimit`

### Steps

1. Create a worker with 256Mi of memory and a 64Mi tmpfs scratch volume.

```bash
workstation$ kubectl create namespace lab-04-02
workstation$ kubectl -n lab-04-02 apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: thumbnailer
spec:
  containers:
  - name: worker
    image: busybox:1.38
    command: ["sleep", "infinity"]
    resources:
      requests: {memory: 128Mi, cpu: 100m}
      limits:   {memory: 256Mi}
    volumeMounts:
    - {name: scratch, mountPath: /scratch}
  volumes:
  - name: scratch
    emptyDir:
      medium: Memory
      sizeLimit: 64Mi
EOF
workstation$ kubectl -n lab-04-02 exec thumbnailer -- sh -c 'df -h /scratch; mount | grep scratch'
```

Expected:
```
Filesystem                Size      Used Available Use% Mounted on
tmpfs                    64.0M         0     64.0M   0% /scratch
tmpfs on /scratch type tmpfs (rw,relatime,size=65536k,inode64,noswap)
```

2. Write 50 MiB of "intermediate files" and watch the container's memory usage grow, although no process allocated
   that memory.

```bash
workstation$ kubectl -n lab-04-02 exec thumbnailer -- sh -c '
  cat /sys/fs/cgroup/memory.current
  dd if=/dev/zero of=/scratch/a bs=1M count=50
  cat /sys/fs/cgroup/memory.current'
workstation$ kubectl -n lab-04-02 top pod thumbnailer      # after ~30 s
```

Expected:
```
1060864
52428800 bytes (50.0MB) copied, 0.026253 seconds, 1.9GB/s
53657600
NAME          CPU(cores)   MEMORY(bytes)
thumbnailer   6m           64Mi
```

3. Fill the volume past `sizeLimit`. Because the tmpfs itself is only 64 MiB, the write fails cleanly with `ENOSPC`
   and the Pod keeps running.

```bash
workstation$ kubectl -n lab-04-02 exec thumbnailer -- sh -c 'dd if=/dev/zero of=/scratch/b bs=1M count=50; df -h /scratch'
```

Expected:
```
dd: error writing '/scratch/b': No space left on device
14680064 bytes (14.0MB) copied, 0.008046 seconds, 1.7GB/s
tmpfs                    64.0M     64.0M         0 100% /scratch
```

4. Now the common mistake: someone sets `sizeLimit: 1Gi` "to be safe" but leaves the memory limit at 256Mi.

```bash
workstation$ kubectl -n lab-04-02 apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: thumbnailer-big
spec:
  containers:
  - name: worker
    image: busybox:1.38
    command: ["sleep", "infinity"]
    resources:
      requests: {memory: 128Mi, cpu: 100m}
      limits:   {memory: 256Mi}
    volumeMounts:
    - {name: scratch, mountPath: /scratch}
  volumes:
  - name: scratch
    emptyDir:
      medium: Memory
      sizeLimit: 1Gi
EOF
workstation$ kubectl -n lab-04-02 exec thumbnailer-big -- sh -c 'df -h /scratch; dd if=/dev/zero of=/scratch/a bs=1M count=300'
workstation$ kubectl -n lab-04-02 describe pod thumbnailer-big | grep -A3 'Last State'
```

Expected (the tmpfs is capped at the memory limit, and the writer is OOM-killed before it fills it):
```
tmpfs                   256.0M         0    256.0M   0% /scratch
command terminated with exit code 137
    Last State:     Terminated
      Reason:       OOMKilled
      Exit Code:    137
```

5. The container restarted, but the volume belongs to the Pod and was not cleaned. The file still occupies the Pod's
   memory, so the restarted container is OOM-killed as soon as it needs a little memory itself.

```bash
workstation$ kubectl -n lab-04-02 exec thumbnailer-big -- df -h /scratch
workstation$ kubectl -n lab-04-02 exec thumbnailer-big -- dd if=/dev/zero of=/dev/null bs=20M count=1
workstation$ kubectl -n lab-04-02 get pod thumbnailer-big
```

Expected:
```
tmpfs                   256.0M    253.6M      2.4M  99% /scratch
command terminated with exit code 137
NAME              READY   STATUS      RESTARTS      AGE
thumbnailer-big   0/1     OOMKilled   1 (20s ago)   22s
```

> **Why:** tmpfs pages cannot be swapped out (`noswap`) or dropped like page cache, so they count against the Pod's
> memory cgroup just like heap memory. Rule of thumb: memory limit = process working set + `sizeLimit`, and the
> application deletes its scratch files when it is done.

6. Compare with a **disk**-backed `emptyDir`. There is no filesystem limit (`df` shows the node's disk); instead the
   kubelet measures the usage periodically and evicts the whole Pod.

```bash
workstation$ kubectl -n lab-04-02 apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: thumbnailer-disk
spec:
  containers:
  - name: worker
    image: busybox:1.38
    command: ["sleep", "infinity"]
    volumeMounts:
    - {name: scratch, mountPath: /scratch}
  volumes:
  - name: scratch
    emptyDir:
      sizeLimit: 64Mi
EOF
workstation$ kubectl -n lab-04-02 exec thumbnailer-disk -- sh -c 'df -h /scratch; dd if=/dev/zero of=/scratch/a bs=1M count=100'
workstation$ kubectl -n lab-04-02 get pod thumbnailer-disk -w        # wait ~1 minute, then Ctrl+C
workstation$ kubectl -n lab-04-02 describe pod thumbnailer-disk | grep -E '^(Status|Reason|Message):'
```

Expected:
```
/dev/sda1               185.8G      5.0G    171.3G   3% /scratch
104857600 bytes (100.0MB) copied, 0.138744 seconds, 720.8MB/s
thumbnailer-disk   1/1     Running   0          62s
thumbnailer-disk   0/1     Error     0          72s
Status:           Failed
Reason:           Evicted
Message:          Usage of EmptyDir volume "scratch" exceeds the limit "64Mi".
```

An evicted bare Pod is gone for good; a Deployment would create a replacement, with a new empty volume.

### Clean up

```bash
workstation$ kubectl delete namespace lab-04-02
```

### Your turn

Turn the worker into a Job `resize-batch` that writes three 40 MiB intermediate files (`/dev/urandom`) into a tmpfs
scratch directory, prints the `md5sum` of all of them together and then reports how much scratch space and Pod memory it
used (`/sys/fs/cgroup/memory.current` and `memory.peak`). Pick `sizeLimit` and the memory limit so that the Job
completes. Then run a copy with a 96Mi memory limit and predict the result before you look.

<details><summary>Solution</summary>

120 MiB of files plus a few MiB for the shell: `sizeLimit: 128Mi` and a memory limit of `192Mi` leave enough headroom.

```bash
workstation$ kubectl -n lab-04-02 apply -f - <<'EOF'
apiVersion: batch/v1
kind: Job
metadata:
  name: resize-batch
spec:
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      containers:
      - name: worker
        image: busybox:1.38
        command:
        - sh
        - -c
        - |
          for i in 1 2 3; do
            dd if=/dev/urandom of=/scratch/part-$i bs=1M count=40 2>/dev/null
          done
          cat /scratch/part-* | md5sum
          echo "scratch used: $(du -sh /scratch | cut -f1)"
          echo "pod memory now: $(( $(cat /sys/fs/cgroup/memory.current) / 1048576 ))Mi, peak: $(( $(cat /sys/fs/cgroup/memory.peak) / 1048576 ))Mi"
        resources:
          requests: {memory: 192Mi, cpu: 100m}
          limits:   {memory: 192Mi}
        volumeMounts:
        - {name: scratch, mountPath: /scratch}
      volumes:
      - name: scratch
        emptyDir:
          medium: Memory
          sizeLimit: 128Mi
EOF
workstation$ kubectl -n lab-04-02 wait --for=condition=complete job/resize-batch --timeout=90s
workstation$ kubectl -n lab-04-02 logs job/resize-batch
```

Expected:
```
job.batch/resize-batch condition met
8d6c99f1f03b3bcb321bc0a6b5f7533a  -
scratch used: 120.0M
pod memory now: 121Mi, peak: 121Mi
```

The scratch files are the Pod's memory. With `96Mi` in both `requests.memory` and `limits.memory` (same YAML, renamed
to `resize-batch-small`) the tmpfs is capped at 96 MiB and the cgroup hits its limit while the third file is being
written:

```bash
workstation$ kubectl -n lab-04-02 get pods -l job-name=resize-batch-small
```

Expected:
```
NAME                       READY   STATUS      RESTARTS   AGE
resize-batch-small-r85vw   0/1     OOMKilled   0          20s
```

</details>

---

## Lab 4.3: A node log viewer with hostPath, and the "data stays on the node" trap

**Scenario** – Before the platform team rolls out a real log shipper (Fluent Bit, Vector), they want a minimal agent that
proves where container logs live on the nodes and that a DaemonSet can read them. While doing that, a developer asks
whether `hostPath` would be a cheap way to give his app "persistent" storage. We answer him with an experiment.

**What you'll learn**
- how the kubelet stores container logs under `/var/log/pods` and how a log agent reads them
- `hostPath` with `readOnly` and `type` (`Directory`, `DirectoryOrCreate`) as safety nets
- why `hostPath` is not persistent storage: the data stays on one node
- why `hostPath` is a security risk (it is blocked by the Pod Security `baseline` level, see Module 06)

### Steps

1. Create an app that logs one line every 5 s, and a DaemonSet `log-agent` that mounts the node's `/var/log/pods`
   read-only and prints the newest line of every `chatty` container on its node.

```bash
workstation$ kubectl create namespace lab-04-03
workstation$ kubectl -n lab-04-03 apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: chatty
spec:
  replicas: 4
  selector:
    matchLabels: {app: chatty}
  template:
    metadata:
      labels: {app: chatty}
    spec:
      containers:
      - name: app
        image: busybox:1.38
        command: ["sh", "-c", "while true; do echo \"order $RANDOM processed by $HOSTNAME\"; sleep 5; done"]
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: log-agent
spec:
  selector:
    matchLabels: {app: log-agent}
  template:
    metadata:
      labels: {app: log-agent}
    spec:
      containers:
      - name: agent
        image: busybox:1.38
        env:
        - name: NODE
          valueFrom: {fieldRef: {fieldPath: spec.nodeName}}
        command:
        - sh
        - -c
        - |
          # kubelet writes every container's stdout/stderr to /var/log/pods/<ns>_<pod>_<uid>/<container>/<n>.log
          while true; do
            for f in /host/var/log/pods/lab-04-03_chatty-*/app/*.log; do
              [ -f "$f" ] && echo "[$NODE] $(tail -n1 "$f")"
            done
            sleep 10
          done
        volumeMounts:
        - {name: pod-logs, mountPath: /host/var/log/pods, readOnly: true}
      volumes:
      - name: pod-logs
        hostPath:
          path: /var/log/pods
          type: Directory
EOF
workstation$ kubectl -n lab-04-03 rollout status ds/log-agent
workstation$ kubectl -n lab-04-03 logs -l app=log-agent --tail=2 --prefix
```

Expected (each agent sees only the Pods on its own node):
```
[pod/log-agent-6xlzm/agent] [node2] 2026-11-04T03:32:00.857564338+01:00 stdout F order 31644 processed by chatty-5bc8df966f-7lwc5
[pod/log-agent-6xlzm/agent] [node2] 2026-11-04T03:32:01.331306141+01:00 stdout F order 16020 processed by chatty-5bc8df966f-szr96
[pod/log-agent-zz5rh/agent] [node1] 2026-11-04T03:32:00.824563051+01:00 stdout F order 10951 processed by chatty-5bc8df966f-456m8
[pod/log-agent-zz5rh/agent] [node1] 2026-11-04T03:31:56.660964006+01:00 stdout F order 30673 processed by chatty-5bc8df966f-sjjnc
```

> **Why the prefix `stdout F`?** This is the CRI log format: timestamp, stream, `F` (full line) or `P` (partial line),
> message. `kubectl logs` strips it; a log shipper has to parse it. The DaemonSet has no toleration for the
> control-plane taint, so there is no agent on `master` (2 Pods, not 3).

2. The mount is read-only, but the agent still sees the logs of **every** namespace on the node, including
   `kube-system`. That is why log agents are trusted, cluster-wide components.

```bash
workstation$ kubectl -n lab-04-03 exec ds/log-agent -- sh -c 'touch /host/var/log/pods/x; ls /host/var/log/pods | head -3'
```

Expected:
```
touch: /host/var/log/pods/x: Read-only file system
kube-system_calico-node-r5srn_86f2db8b-7eec-41c4-98e0-b4787a104a09
kube-system_csi-s3-ckz6g_f893f7a9-c7fb-4e1c-abde-4a6ee5959710
kube-system_csi-s3-provisioner-0_b91932bc-ffc8-479b-a8a4-e22486c29a0d
```

3. `type: Directory` makes the kubelet check the path before it starts the container. A typo fails loudly instead of
   silently mounting an empty, freshly created directory (which is what the default type `""` would do).

```bash
workstation$ kubectl -n lab-04-03 apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: typo
spec:
  containers:
  - name: agent
    image: busybox:1.38
    command: ["sleep", "infinity"]
    volumeMounts:
    - {name: logs, mountPath: /logs, readOnly: true}
  volumes:
  - name: logs
    hostPath: {path: /var/log/pod, type: Directory}     # typo: pod instead of pods
EOF
workstation$ kubectl -n lab-04-03 get events --field-selector involvedObject.name=typo | grep FailedMount
workstation$ kubectl -n lab-04-03 delete pod typo
```

Expected (the Pod stays in `ContainerCreating`):
```
Warning   FailedMount   pod/typo   MountVolume.SetUp failed for volume "logs" : hostPath type check failed, /var/log/pod is not a directory, unable to determine its type: path "/var/log/pod" does not exist
```

4. Now the developer's idea: a `notes` app that stores its data in `hostPath: /mnt/lab-04-03/notes`. It starts on
   `node1` and writes a record.

```bash
workstation$ kubectl -n lab-04-03 apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: notes
spec:
  replicas: 1
  selector:
    matchLabels: {app: notes}
  template:
    metadata:
      labels: {app: notes}
    spec:
      nodeSelector:
        kubernetes.io/hostname: node1
      containers:
      - name: app
        image: busybox:1.38
        command: ["sleep", "infinity"]
        volumeMounts:
        - {name: data, mountPath: /data}
      volumes:
      - name: data
        hostPath:
          path: /mnt/lab-04-03/notes
          type: DirectoryOrCreate
EOF
workstation$ kubectl -n lab-04-03 rollout status deploy/notes
workstation$ kubectl -n lab-04-03 exec deploy/notes -- sh -c 'echo "invoice 42 paid" >> /data/notes.txt; cat /data/notes.txt'
```

Expected:
```
invoice 42 paid
```

5. Simulate a reschedule (node drain, node failure, or just a new rollout landing elsewhere) by moving the Pod to
   `node2`.

```bash
workstation$ kubectl -n lab-04-03 patch deploy notes -p '{"spec":{"template":{"spec":{"nodeSelector":{"kubernetes.io/hostname":"node2"}}}}}'
workstation$ kubectl -n lab-04-03 rollout status deploy/notes
workstation$ kubectl -n lab-04-03 exec deploy/notes -- sh -c 'ls -la /data; cat /data/notes.txt'
```

Expected:
```
drwxr-xr-x    2 root     root          4096 Nov  4 02:32 .
cat: can't open '/data/notes.txt': No such file or directory
```

6. The data was not lost, it is just on the other node, and `DirectoryOrCreate` silently created an empty directory on
   `node2` (owned by `root`, so a non-root app could not even write to it).

```bash
node1$ cat /mnt/lab-04-03/notes/notes.txt
node2$ ls -la /mnt/lab-04-03/notes
```

Expected:
```
invoice 42 paid
drwxr-xr-x 2 root root 4096 Nov  4 03:32 .
```

> **Takeaway:** `hostPath` is for node agents (logs, metrics, CNI/CSI plugins) that are *meant* to see the node. For
> application data use a PersistentVolume: a `local` PV at least pins the Pod to the node that has the data (Lab 4.4),
> and network storage (Lab 4.6) follows the Pod to any node.

### Clean up

`hostPath` directories are not removed by Kubernetes; clean them up on the nodes.

```bash
workstation$ kubectl delete namespace lab-04-03
node1$ sudo rm -rf /mnt/lab-04-03
node2$ sudo rm -rf /mnt/lab-04-03
```

### Your turn

Before the real log shipper arrives, the team wants a quick capacity report. Write a DaemonSet `disk-report` that runs
on **all three** nodes (including `master`) and every 5 minutes logs one line per node: used/total size of the root
filesystem, the size of `/var/log/pods`, and the size of the CRI-O image store `/var/lib/containers/storage`. Mount
only what you need, read-only, and make the Pod fail fast if a path does not exist.

<details><summary>Solution</summary>

```bash
workstation$ kubectl -n lab-04-03 apply -f - <<'EOF'
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: disk-report
spec:
  selector:
    matchLabels: {app: disk-report}
  template:
    metadata:
      labels: {app: disk-report}
    spec:
      tolerations:                                   # allow scheduling on the control-plane node
      - key: node-role.kubernetes.io/control-plane
        operator: Exists
        effect: NoSchedule
      containers:
      - name: report
        image: busybox:1.38
        env:
        - name: NODE
          valueFrom: {fieldRef: {fieldPath: spec.nodeName}}
        command:
        - sh
        - -c
        - |
          while true; do
            echo "[$NODE] root fs: $(df -h /host/var/log | awk 'NR==2 {print $3 " used of " $2}'), pod logs: $(du -sh /host/var/log/pods | cut -f1), images+layers: $(du -sh /host/var/lib/containers/storage 2>/dev/null | cut -f1)"
            sleep 300
          done
        resources:
          requests: {cpu: 10m, memory: 16Mi}
        volumeMounts:
        - {name: var-log, mountPath: /host/var/log, readOnly: true}
        - {name: containers, mountPath: /host/var/lib/containers, readOnly: true}
      volumes:
      - name: var-log
        hostPath: {path: /var/log, type: Directory}
      - name: containers
        hostPath: {path: /var/lib/containers, type: Directory}
EOF
workstation$ kubectl -n lab-04-03 rollout status ds/disk-report
workstation$ kubectl -n lab-04-03 logs -l app=disk-report
```

Expected (3 Pods, one per node):
```
[master] root fs: 3.3G used of 185.8G, pod logs: 1.4M, images+layers: 2.3G
[node1] root fs: 5.2G used of 185.8G, pod logs: 20.8M, images+layers: 5.5G
[node2] root fs: 5.2G used of 185.8G, pod logs: 2.6M, images+layers: 4.7G
```

`df` on a hostPath mount reports the filesystem behind it, the node's root disk here. Delete the namespace afterwards
(and remove `/mnt/lab-04-03` on the nodes if you skipped *Clean up*).

</details>

---

## Lab 4.4: A Postgres database on a static local PersistentVolume

**Scenario** – The shop team runs a small Postgres database for order data. There is no storage provisioner in the
cluster, but `node1` has a fast local disk. As the cluster admin you carve out a PersistentVolume on that disk,
reserve it for the shop's claim, and prove that the data survives Pod restarts and even an accidentally deleted
PersistentVolumeClaim.

**What you'll learn**
- static provisioning: a `local` PV with `nodeAffinity`, `storageClassName: ""` and a PVC that binds to it
- reserving a PV for one claim with `claimRef`
- `persistentVolumeReclaimPolicy: Retain` and the `Released` state
- how to re-attach a `Released` PV to a new claim without losing data

### Steps

1. Prepare the directory on `node1`. A `local` PV, unlike `hostPath` with `DirectoryOrCreate`, never creates the path:
   it is the admin's job to provide the disk.

```bash
node1$ sudo mkdir -p /mnt/lab-04-04/pgdata
```

2. Create the PersistentVolume (cluster-scoped, so it carries the `lab-04-04-` prefix). `claimRef` reserves it for the
   claim `pg-data` in namespace `lab-04-04`, so no other claim can grab it.

```bash
workstation$ kubectl create namespace lab-04-04
workstation$ kubectl apply -f - <<'EOF'
apiVersion: v1
kind: PersistentVolume
metadata:
  name: lab-04-04-pg
spec:
  capacity:
    storage: 2Gi
  accessModes: [ReadWriteOnce]
  persistentVolumeReclaimPolicy: Retain
  storageClassName: ""                 # static PV, no StorageClass
  claimRef:                            # pre-bind to exactly this claim
    namespace: lab-04-04
    name: pg-data
  local:
    path: /mnt/lab-04-04/pgdata
  nodeAffinity:                        # required for local volumes: the data is on node1 only
    required:
      nodeSelectorTerms:
      - matchExpressions:
        - key: kubernetes.io/hostname
          operator: In
          values: [node1]
EOF
workstation$ kubectl get pv lab-04-04-pg
```

Expected:
```
NAME           CAPACITY   ACCESS MODES   RECLAIM POLICY   STATUS      CLAIM               STORAGECLASS   ...
lab-04-04-pg   2Gi        RWO            Retain           Available   lab-04-04/pg-data                  ...
```

3. Create the claim and the database. `storageClassName: ""` on the PVC is important: without it the claim would ask
   the (non-existent) default StorageClass for a dynamic volume. `strategy: Recreate` makes sure the old Pod releases
   the RWO volume before the new one starts.

```bash
workstation$ kubectl -n lab-04-04 apply -f - <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: pg-data
spec:
  storageClassName: ""
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 2Gi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: postgres
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels: {app: postgres}
  template:
    metadata:
      labels: {app: postgres}
    spec:
      containers:
      - name: postgres
        image: postgres:17
        env:
        - {name: POSTGRES_DB, value: shop}
        - {name: POSTGRES_PASSWORD, value: lab-only-password}     # Module 05 moves this into a Secret
        - {name: PGDATA, value: /var/lib/postgresql/data/pgdata}  # a sub-directory of the mount
        ports:
        - containerPort: 5432
        readinessProbe:
          exec: {command: ["pg_isready", "-U", "postgres"]}
          periodSeconds: 5
        volumeMounts:
        - {name: data, mountPath: /var/lib/postgresql/data}
      volumes:
      - name: data
        persistentVolumeClaim:
          claimName: pg-data
EOF
workstation$ kubectl -n lab-04-04 get pvc
workstation$ kubectl -n lab-04-04 rollout status deploy/postgres
workstation$ kubectl -n lab-04-04 get pod -o wide
```

Expected (the scheduler places the Pod on `node1` because of the PV's node affinity):
```
NAME      STATUS   VOLUME         CAPACITY   ACCESS MODES   STORAGECLASS   ...
pg-data   Bound    lab-04-04-pg   2Gi        RWO                           ...
deployment "postgres" successfully rolled out
NAME                       READY   STATUS    RESTARTS   AGE   IP               NODE    ...
postgres-7b66dbf66-77nk2   1/1     Running   0          12s   172.16.166.186   node1   ...
```

> **Why `PGDATA` in a sub-directory?** Real disks are often mounted with a `lost+found` directory at the top, and
> `initdb` refuses to initialise a non-empty directory. Using a sub-directory is a good habit for every database.

4. Write some orders, kill the Pod and read them back.

```bash
workstation$ kubectl -n lab-04-04 exec deploy/postgres -- psql -U postgres -d shop -c \
  "CREATE TABLE orders(id serial primary key, item text, created timestamptz default now());
   INSERT INTO orders(item) VALUES ('keyboard'),('monitor'),('mouse');"
workstation$ kubectl -n lab-04-04 delete pod -l app=postgres
workstation$ kubectl -n lab-04-04 rollout status deploy/postgres
workstation$ kubectl -n lab-04-04 exec deploy/postgres -- psql -U postgres -d shop -c 'SELECT id, item FROM orders'
```

Expected:
```
 id |   item
----+----------
  1 | keyboard
  2 | monitor
  3 | mouse
(3 rows)
```

5. Look at the files on the node. The data directory belongs to UID 999, the `postgres` user of the image.

```bash
node1$ sudo ls -la /mnt/lab-04-04/pgdata
```

Expected:
```
drwx------ 19  999 root 4096 Nov  4 03:35 pgdata
```

6. An accident: someone deletes the Deployment **and** the PVC. With `Retain` the PV is not wiped; it becomes
   `Released`, and it still remembers the UID of the deleted claim.

```bash
workstation$ kubectl -n lab-04-04 delete deploy postgres
workstation$ kubectl -n lab-04-04 delete pvc pg-data
workstation$ kubectl get pv lab-04-04-pg
workstation$ kubectl get pv lab-04-04-pg -o jsonpath='{.spec.claimRef}{"\n"}'
```

Expected:
```
NAME           CAPACITY   ACCESS MODES   RECLAIM POLICY   STATUS     CLAIM               ...
lab-04-04-pg   2Gi        RWO            Retain           Released   lab-04-04/pg-data   ...
{"apiVersion":"v1","kind":"PersistentVolumeClaim","name":"pg-data","namespace":"lab-04-04","resourceVersion":"12694","uid":"caa1b5d6-1b55-40df-b2e9-884b4624be1e"}
```

7. Re-apply the manifest from step 3 (PVC + Deployment). The new claim has the same name but a new UID, so it does
   **not** bind, and the Pod stays `Pending`.

```bash
workstation$ kubectl -n lab-04-04 get pvc
workstation$ kubectl -n lab-04-04 describe pvc pg-data | tail -1
```

Expected:
```
NAME      STATUS    VOLUME   CAPACITY   ACCESS MODES   STORAGECLASS   ...
pg-data   Pending                                                     ...
  Normal  FailedBinding  1s (x2 over 5s)  persistentvolume-controller  no persistent volumes available for this claim and no storage class is set
```

8. This safety net stops a random new claim from receiving somebody else's data. Once you have decided that the data
   *should* go to the new claim, remove the stale `uid` and `resourceVersion` from `claimRef`.

```bash
workstation$ kubectl patch pv lab-04-04-pg --type=json \
  -p '[{"op":"remove","path":"/spec/claimRef/uid"},{"op":"remove","path":"/spec/claimRef/resourceVersion"}]'
workstation$ kubectl -n lab-04-04 rollout status deploy/postgres
workstation$ kubectl -n lab-04-04 exec deploy/postgres -- psql -U postgres -d shop -tc 'SELECT count(*) FROM orders'
```

Expected (the PV goes `Available` → `Bound`, and all orders are back):
```
persistentvolume/lab-04-04-pg patched
deployment "postgres" successfully rolled out
     3
```

### Clean up

`Retain` means you delete the PV and the data yourself.

```bash
workstation$ kubectl delete namespace lab-04-04
workstation$ kubectl delete pv lab-04-04-pg
node1$ sudo rm -rf /mnt/lab-04-04
```

### Your turn

`node1` is going to be decommissioned. Move the database to `node2` with minimal downtime: give `node2` its own local
PV (`lab-04-04-pg-node2`, reserved for claim `pg-data-node2`), start a second Postgres Deployment `postgres-node2` on it
and copy the data over the network with `pg_dump` piped into `psql`. Verify that the three orders are on `node2`.
Why can't you just change the `nodeAffinity` of the existing PV?

<details><summary>Solution</summary>

```bash
node2$ sudo mkdir -p /mnt/lab-04-04/pgdata
workstation$ kubectl -n lab-04-04 apply -f - <<'EOF'
apiVersion: v1
kind: PersistentVolume
metadata:
  name: lab-04-04-pg-node2
spec:
  capacity:
    storage: 2Gi
  accessModes: [ReadWriteOnce]
  persistentVolumeReclaimPolicy: Retain
  storageClassName: ""
  claimRef:
    namespace: lab-04-04
    name: pg-data-node2
  local:
    path: /mnt/lab-04-04/pgdata
  nodeAffinity:
    required:
      nodeSelectorTerms:
      - matchExpressions:
        - key: kubernetes.io/hostname
          operator: In
          values: [node2]
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: pg-data-node2
spec:
  storageClassName: ""
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 2Gi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: postgres-node2
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels: {app: postgres-node2}
  template:
    metadata:
      labels: {app: postgres-node2}
    spec:
      containers:
      - name: postgres
        image: postgres:17
        env:
        - {name: POSTGRES_DB, value: shop}
        - {name: POSTGRES_PASSWORD, value: lab-only-password}
        - {name: PGDATA, value: /var/lib/postgresql/data/pgdata}
        readinessProbe:
          exec: {command: ["pg_isready", "-U", "postgres"]}
          periodSeconds: 5
        volumeMounts:
        - {name: data, mountPath: /var/lib/postgresql/data}
      volumes:
      - name: data
        persistentVolumeClaim:
          claimName: pg-data-node2
EOF
workstation$ kubectl -n lab-04-04 rollout status deploy/postgres-node2
workstation$ kubectl -n lab-04-04 get pods -o wide
workstation$ kubectl -n lab-04-04 exec deploy/postgres -- pg_dump -U postgres --clean --if-exists shop \
  | kubectl -n lab-04-04 exec -i deploy/postgres-node2 -- psql -q -U postgres -d shop
workstation$ kubectl -n lab-04-04 exec deploy/postgres-node2 -- psql -U postgres -d shop -c 'SELECT id, item FROM orders'
```

Expected:
```
NAME                              READY   STATUS    RESTARTS   AGE   IP               NODE    ...
postgres-7b66dbf66-cb5h8          1/1     Running   0          40s   172.16.166.133   node1   ...
postgres-node2-55d4fd4d85-4pg68   1/1     Running   0          8s    172.16.104.15    node2   ...
 id |   item
----+----------
  1 | keyboard
  2 | monitor
  3 | mouse
(3 rows)
```

In production you would stop writes (scale the app down) before the dump, then point the database Service at the new
Pods. Editing the PV's `nodeAffinity` would not move a single byte: a local PV is a statement about *where the data
already is*, and on `node2` the Pod would find an empty directory (or none at all). Clean up with `kubectl delete namespace lab-04-04`,
`kubectl delete pv lab-04-04-pg lab-04-04-pg-node2` and `sudo rm -rf /mnt/lab-04-04` on both nodes.

</details>

---

## Lab 4.5: A Redis StatefulSet with volumeClaimTemplates on pre-provisioned local disks

**Scenario** – The session store is sharded over several Redis instances, and each shard must keep its append-only file
on the fast local disk of a node. Nobody wants to write one PVC per shard by hand, so the StatefulSet creates the claims
from a template. The storage team pre-creates local PVs on the nodes and publishes them through a StorageClass with no
provisioner. We also decide what happens to the claims when the shard count goes down, or when the StatefulSet is
deleted.

**What you'll learn**
- a `kubernetes.io/no-provisioner` StorageClass with `volumeBindingMode: WaitForFirstConsumer`
- `volumeClaimTemplates`: one PVC per replica (`data-redis-0`, `data-redis-1`, ...), sticky to the Pod's identity
- `persistentVolumeClaimRetentionPolicy` (`whenScaled`, `whenDeleted`) and how it interacts with the PV's `Retain` policy
- why a scale-up can get stuck on `Released` volumes

### Steps

1. Prepare one directory per node.

```bash
node1$ sudo mkdir -p /mnt/lab-04-05/vol-a
node2$ sudo mkdir -p /mnt/lab-04-05/vol-a
```

2. Create the StorageClass and one PV per node. `WaitForFirstConsumer` delays binding until a Pod using the claim is
   scheduled, so the scheduler can choose a node **and** a matching local PV together. With `Immediate` binding, a
   claim could be bound to a PV on a node where the Pod does not fit.

```bash
workstation$ kubectl create namespace lab-04-05
workstation$ kubectl apply -f - <<'EOF'
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: lab-04-05-local
provisioner: kubernetes.io/no-provisioner     # static PVs only
volumeBindingMode: WaitForFirstConsumer
reclaimPolicy: Retain
---
apiVersion: v1
kind: PersistentVolume
metadata:
  name: lab-04-05-node1-a
spec:
  capacity: {storage: 1Gi}
  accessModes: [ReadWriteOnce]
  persistentVolumeReclaimPolicy: Retain
  storageClassName: lab-04-05-local
  local: {path: /mnt/lab-04-05/vol-a}
  nodeAffinity:
    required:
      nodeSelectorTerms:
      - matchExpressions:
        - {key: kubernetes.io/hostname, operator: In, values: [node1]}
---
apiVersion: v1
kind: PersistentVolume
metadata:
  name: lab-04-05-node2-a
spec:
  capacity: {storage: 1Gi}
  accessModes: [ReadWriteOnce]
  persistentVolumeReclaimPolicy: Retain
  storageClassName: lab-04-05-local
  local: {path: /mnt/lab-04-05/vol-a}
  nodeAffinity:
    required:
      nodeSelectorTerms:
      - matchExpressions:
        - {key: kubernetes.io/hostname, operator: In, values: [node2]}
EOF
workstation$ kubectl get pv | grep -E 'NAME|lab-04-05'
```

Expected:
```
NAME                CAPACITY   ACCESS MODES   RECLAIM POLICY   STATUS      CLAIM   STORAGECLASS      ...
lab-04-05-node1-a   1Gi        RWO            Retain           Available           lab-04-05-local   ...
lab-04-05-node2-a   1Gi        RWO            Retain           Available           lab-04-05-local   ...
```

3. Create the headless Service and the StatefulSet. Scaling down deletes the PVC of the removed replica
   (`whenScaled: Delete`); deleting the whole StatefulSet keeps all PVCs (`whenDeleted: Retain`).

```bash
workstation$ kubectl -n lab-04-05 apply -f - <<'EOF'
apiVersion: v1
kind: Service
metadata:
  name: redis
spec:
  clusterIP: None
  selector: {app: redis}
  ports:
  - port: 6379
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: redis
spec:
  serviceName: redis
  replicas: 2
  selector:
    matchLabels: {app: redis}
  persistentVolumeClaimRetentionPolicy:
    whenDeleted: Retain
    whenScaled: Delete
  template:
    metadata:
      labels: {app: redis}
    spec:
      containers:
      - name: redis
        image: redis:8.8
        args: ["--appendonly", "yes"]
        ports:
        - containerPort: 6379
        volumeMounts:
        - {name: data, mountPath: /data}
  volumeClaimTemplates:
  - metadata:
      name: data
    spec:
      storageClassName: lab-04-05-local
      accessModes: [ReadWriteOnce]
      resources:
        requests: {storage: 1Gi}
EOF
workstation$ kubectl -n lab-04-05 rollout status sts/redis
workstation$ kubectl -n lab-04-05 get pods -o wide
workstation$ kubectl -n lab-04-05 get pvc
```

Expected (no anti-affinity rule was needed: after `redis-0` took one PV, the only free PV for `redis-1` was on the
other node):
```
NAME      READY   STATUS    RESTARTS   AGE   IP               NODE    ...
redis-0   1/1     Running   0          6s    172.16.104.8     node2   ...
redis-1   1/1     Running   0          3s    172.16.166.144   node1   ...
NAME           STATUS   VOLUME              CAPACITY   ACCESS MODES   STORAGECLASS      ...
data-redis-0   Bound    lab-04-05-node2-a   1Gi        RWO            lab-04-05-local   ...
data-redis-1   Bound    lab-04-05-node1-a   1Gi        RWO            lab-04-05-local   ...
```

4. Give every shard an identity and restart `redis-0`. The new Pod has the same name, the same claim, and therefore
   the same node and the same data.

```bash
workstation$ for i in 0 1; do kubectl -n lab-04-05 exec redis-$i -- redis-cli SET shard "I am redis-$i"; done
workstation$ kubectl -n lab-04-05 delete pod redis-0
workstation$ kubectl -n lab-04-05 wait --for=condition=Ready pod/redis-0
workstation$ kubectl -n lab-04-05 get pod redis-0 -o wide
workstation$ kubectl -n lab-04-05 exec redis-0 -- redis-cli GET shard
```

Expected:
```
NAME      READY   STATUS    RESTARTS   AGE   IP              NODE    ...
redis-0   1/1     Running   0          1s    172.16.104.17   node2   ...
I am redis-0
```

5. Scale down to one shard. Because of `whenScaled: Delete` the PVC `data-redis-1` is deleted, but the PV has its own
   `Retain` policy, so it becomes `Released` and the files stay on `node1`.

```bash
workstation$ kubectl -n lab-04-05 scale sts redis --replicas=1
workstation$ kubectl -n lab-04-05 get pvc
workstation$ kubectl get pv lab-04-05-node1-a
node1$ sudo ls -la /mnt/lab-04-05/vol-a
```

Expected:
```
NAME           STATUS   VOLUME              CAPACITY   ACCESS MODES   STORAGECLASS      ...
data-redis-0   Bound    lab-04-05-node2-a   1Gi        RWO            lab-04-05-local   ...
NAME                CAPACITY   ACCESS MODES   RECLAIM POLICY   STATUS     CLAIM                    STORAGECLASS      ...
lab-04-05-node1-a   1Gi        RWO            Retain           Released   lab-04-05/data-redis-1   lab-04-05-local   ...
drwx------ 2  999 systemd-journal 4096 Nov  4 03:38 appendonlydir
-rw------- 1  999 systemd-journal  113 Nov  4 03:38 dump.rdb
```

6. Scale back up. The StatefulSet creates a new `data-redis-1` claim, but there is no `Available` PV left, so the
   Pod is stuck.

```bash
workstation$ kubectl -n lab-04-05 scale sts redis --replicas=2
workstation$ kubectl -n lab-04-05 get pods
workstation$ kubectl -n lab-04-05 get events --field-selector involvedObject.name=redis-1 | grep FailedScheduling
```

Expected:
```
NAME      READY   STATUS    RESTARTS   AGE
redis-0   1/1     Running   0          24s
redis-1   0/1     Pending   0          8s
Warning   FailedScheduling   pod/redis-1   0/3 nodes are available: 1 node(s) had untolerated taint(s), 2 node(s) didn't find available persistent volumes to bind. ...
```

7. Static volumes have no automatic recycler. After deciding the old data may be reused (or after wiping the
   directory), the admin makes the PV `Available` again by removing its `claimRef`.

```bash
workstation$ kubectl patch pv lab-04-05-node1-a --type=json -p '[{"op":"remove","path":"/spec/claimRef"}]'
workstation$ kubectl -n lab-04-05 wait --for=condition=Ready pod/redis-1
workstation$ kubectl -n lab-04-05 exec redis-1 -- redis-cli GET shard
```

Expected (surprise: the "deleted" claim's data is back, because only the PVC was deleted, never the files):
```
pod/redis-1 condition met
I am redis-1
```

> **Pitfall:** `whenScaled: Delete` does **not** mean "wipe the data" when the PVs are `Retain`. With a dynamic
> provisioner and `reclaimPolicy: Delete` the disk would really be destroyed. Know which of the two you have before you
> scale a production StatefulSet down.

8. Delete the StatefulSet and recreate it. `whenDeleted: Retain` kept both claims, so the shards come back with
   their data.

```bash
workstation$ kubectl -n lab-04-05 delete sts redis
workstation$ kubectl -n lab-04-05 get pvc
# re-apply the manifest from step 3
workstation$ kubectl -n lab-04-05 rollout status sts/redis
workstation$ kubectl -n lab-04-05 exec redis-0 -- redis-cli GET shard
```

Expected:
```
NAME           STATUS   VOLUME              CAPACITY   ACCESS MODES   STORAGECLASS      ...
data-redis-0   Bound    lab-04-05-node2-a   1Gi        RWO            lab-04-05-local   ...
data-redis-1   Bound    lab-04-05-node1-a   1Gi        RWO            lab-04-05-local   ...
I am redis-0
```

### Clean up

```bash
workstation$ kubectl delete namespace lab-04-05
workstation$ kubectl delete pv lab-04-05-node1-a lab-04-05-node2-a
workstation$ kubectl delete storageclass lab-04-05-local
node1$ sudo rm -rf /mnt/lab-04-05
node2$ sudo rm -rf /mnt/lab-04-05
```

### Your turn

Traffic grows and the team wants a third shard. Scale the StatefulSet to 3 replicas and observe what happens. Then
provide the missing capacity as a second local volume on `node1` (`/mnt/lab-04-05/vol-b`, PV `lab-04-05-node1-b`) and
verify that `redis-2` starts, which node it lands on, and that its database is empty. Predict the node before you look.

<details><summary>Solution</summary>

```bash
workstation$ kubectl -n lab-04-05 scale sts redis --replicas=3
workstation$ kubectl -n lab-04-05 get pod redis-2
workstation$ kubectl -n lab-04-05 get pvc data-redis-2
```

Expected (the claim waits for a PV, the Pod waits for the claim):
```
NAME      READY   STATUS    RESTARTS   AGE
redis-2   0/1     Pending   0          6s
NAME           STATUS    VOLUME   CAPACITY   ACCESS MODES   STORAGECLASS      ...
data-redis-2   Pending                                      lab-04-05-local   ...
```

Add the volume:

```bash
node1$ sudo mkdir -p /mnt/lab-04-05/vol-b
workstation$ kubectl apply -f - <<'EOF'
apiVersion: v1
kind: PersistentVolume
metadata:
  name: lab-04-05-node1-b
spec:
  capacity: {storage: 1Gi}
  accessModes: [ReadWriteOnce]
  persistentVolumeReclaimPolicy: Retain
  storageClassName: lab-04-05-local
  local: {path: /mnt/lab-04-05/vol-b}
  nodeAffinity:
    required:
      nodeSelectorTerms:
      - matchExpressions:
        - {key: kubernetes.io/hostname, operator: In, values: [node1]}
EOF
workstation$ kubectl -n lab-04-05 wait --for=condition=Ready pod/redis-2
workstation$ kubectl -n lab-04-05 get pod -o wide
workstation$ kubectl -n lab-04-05 exec redis-2 -- redis-cli DBSIZE
```

Expected (`node1`, because that is where the only free PV is, even though `node1` already runs `redis-1`):
```
NAME      READY   STATUS    RESTARTS   AGE   IP               NODE    ...
redis-0   1/1     Running   0          21s   172.16.104.29    node2   ...
redis-1   1/1     Running   0          19s   172.16.166.152   node1   ...
redis-2   1/1     Running   0          9s    172.16.166.153   node1   ...
0
```

The scheduler retried on its own; no restart was needed. If two shards on one node is not acceptable, add a
`podAntiAffinity` rule; `redis-2` would then stay `Pending` until a PV appears on a node without a shard. Clean up as
above and also delete `lab-04-05-node1-b`.

</details>

---

## Lab 4.6: Shared uploads across nodes with an S3-backed ReadWriteMany volume

**Scenario** – The invoice-scanning service runs on several nodes, and every replica must see every uploaded file.
Local disks cannot do that, and the cluster has no NFS server, but there is S3 storage (MinIO) and a CSI driver that
mounts a bucket as a filesystem. We create a `ReadWriteMany` claim from the `minio-sc` StorageClass, write to it from
Pods on two different nodes, and look at the result in S3 from the outside.

**What you'll learn**
- dynamic provisioning with a CSI StorageClass and the `ReadWriteMany` access mode
- how csi-s3 maps a PV to a prefix in the bucket `training-bucket`
- verifying the objects with the MinIO client `mc` from the client VM
- the limits of a FUSE-mounted object store: metadata caching, no real POSIX semantics, capacity not enforced

### Steps

1. Create the claim and two replicas that are forced onto different nodes. Each replica writes one file named after
   its node.

```bash
workstation$ kubectl create namespace lab-04-06
workstation$ kubectl -n lab-04-06 apply -f - <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: uploads
spec:
  storageClassName: minio-sc
  accessModes: [ReadWriteMany]
  resources:
    requests:
      storage: 1Gi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: uploader
spec:
  replicas: 2
  selector:
    matchLabels: {app: uploader}
  template:
    metadata:
      labels: {app: uploader}
    spec:
      affinity:
        podAntiAffinity:                       # force the replicas onto different nodes
          requiredDuringSchedulingIgnoredDuringExecution:
          - labelSelector:
              matchLabels: {app: uploader}
            topologyKey: kubernetes.io/hostname
      containers:
      - name: app
        image: busybox:1.38
        env:
        - name: NODE
          valueFrom: {fieldRef: {fieldPath: spec.nodeName}}
        command:
        - sh
        - -c
        - |
          mkdir -p /uploads/incoming
          echo "invoice scanned on $NODE by $HOSTNAME at $(date -u +%T)" > /uploads/incoming/$NODE.txt
          sleep infinity
        volumeMounts:
        - {name: uploads, mountPath: /uploads}
      volumes:
      - name: uploads
        persistentVolumeClaim:
          claimName: uploads
EOF
workstation$ kubectl -n lab-04-06 get pvc
workstation$ kubectl -n lab-04-06 rollout status deploy/uploader
workstation$ kubectl -n lab-04-06 get pods -o wide
```

Expected (the StorageClass uses `Immediate` binding, so the PV is created right away):
```
NAME      STATUS   VOLUME                                     CAPACITY   ACCESS MODES   STORAGECLASS   ...
uploads   Bound    pvc-d8dea454-1e6c-42cf-afa9-893ab8f8bf31   1Gi        RWX            minio-sc       ...
deployment "uploader" successfully rolled out
NAME                        READY   STATUS    RESTARTS   AGE   IP               NODE    ...
uploader-6f6d96657c-hn452   1/1     Running   0          3s    172.16.166.159   node1   ...
uploader-6f6d96657c-rfmld   1/1     Running   0          3s    172.16.104.35    node2   ...
```

2. Look at the mount and the files from both Pods.

```bash
workstation$ for p in $(kubectl -n lab-04-06 get pod -l app=uploader -o name); do
  kubectl -n lab-04-06 exec $p -- sh -c 'echo "== $NODE"; mount | grep uploads; ls /uploads/incoming'
done
```

Expected:
```
== node1
training-bucket on /uploads type fuse.geesefs (rw,relatime,user_id=65534,group_id=65534,default_permissions,allow_other)
node1.txt
== node2
training-bucket on /uploads type fuse.geesefs (rw,relatime,user_id=65534,group_id=65534,default_permissions,allow_other)
node1.txt
node2.txt
```

`node1` does not see `node2.txt` yet. The volume is a FUSE filesystem (GeeseFS) that translates file operations into
S3 requests and caches metadata (directory listings, file attributes) for about a minute.

3. Repeat the loop after a minute. Both nodes now see both files.

```bash
workstation$ kubectl -n lab-04-06 exec uploader-6f6d96657c-hn452 -- ls /uploads/incoming    # your node1 Pod
```

Expected:
```
node1.txt
node2.txt
```

> **Why it matters:** S3 is an object store, not a shared POSIX filesystem. There is no file locking, appending
> rewrites the whole object, renames are copy + delete, and other clients see changes with a delay. RWX over S3 is
> great for write-once, read-many data (uploads, reports, static assets, ML datasets) and a bad idea for databases or
> for several writers updating the same file.

4. Inspect the bucket from the client VM. csi-s3 created one prefix per PV, named like the PV, inside
   `training-bucket`.

```bash
workstation$ kubectl -n lab-04-06 get pvc uploads -o jsonpath='{.spec.volumeName}{"\n"}'
client-vm$ mc ls -r m/training-bucket
```

Expected (you may see prefixes of other PVs, too):
```
pvc-d8dea454-1e6c-42cf-afa9-893ab8f8bf31
[2026-11-04 02:41:10 UTC]     0B STANDARD pvc-d8dea454-1e6c-42cf-afa9-893ab8f8bf31/
[2026-11-04 02:41:12 UTC]     0B STANDARD pvc-d8dea454-1e6c-42cf-afa9-893ab8f8bf31/incoming/
[2026-11-04 02:41:12 UTC]    66B STANDARD pvc-d8dea454-1e6c-42cf-afa9-893ab8f8bf31/incoming/node1.txt
[2026-11-04 02:41:12 UTC]    66B STANDARD pvc-d8dea454-1e6c-42cf-afa9-893ab8f8bf31/incoming/node2.txt
```

5. The data is ordinary S3 objects, so systems outside Kubernetes can take part. The office scanner uploads a file
   directly to S3, and the Pods see it as a file. Replace the PV name with yours.

```bash
client-vm$ echo "invoice from the office scanner" | mc pipe m/training-bucket/pvc-d8dea454-1e6c-42cf-afa9-893ab8f8bf31/incoming/scanner.txt
workstation$ kubectl -n lab-04-06 exec deploy/uploader -- ls /uploads/incoming
```

Expected (within a minute):
```
32 bytes -> `m/training-bucket/pvc-d8dea454-1e6c-42cf-afa9-893ab8f8bf31/incoming/scanner.txt`
node1.txt
node2.txt
scanner.txt
```

6. The `1Gi` in the claim is not enforced: S3 has no block-device size, so `df` inside the Pod shows a huge virtual
   filesystem. Use bucket quotas on the S3 side if you need a hard limit.

```bash
workstation$ kubectl -n lab-04-06 exec deploy/uploader -- df -h /uploads
```

Expected:
```
Filesystem                Size      Used Available Use% Mounted on
training-bucket           1.0P         0      1.0P   0% /uploads
```

### Clean up

The StorageClass has `reclaimPolicy: Delete`, so deleting the claim (with the namespace) deletes the PV **and its
objects** in the bucket.

```bash
workstation$ kubectl delete namespace lab-04-06
client-vm$ mc ls -r m/training-bucket
```

Expected: your `pvc-d8dea454-...` prefix is gone.

### Your turn

Add a read-only `gallery`: an nginx Deployment with 2 replicas spread over both workers (use
`topologySpreadConstraints`) that serves the shared volume as its web root. The gallery must not be able to modify
uploads, even if nginx is compromised. Verify from each gallery Pod that it serves `incoming/node1.txt` and
`incoming/scanner.txt` and that writing to the web root fails.

<details><summary>Solution</summary>

Mark the volume read-only both in the Pod's `persistentVolumeClaim` source and in the `volumeMount`:

```bash
workstation$ kubectl -n lab-04-06 apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: gallery
spec:
  replicas: 2
  selector:
    matchLabels: {app: gallery}
  template:
    metadata:
      labels: {app: gallery}
    spec:
      topologySpreadConstraints:
      - maxSkew: 1
        topologyKey: kubernetes.io/hostname
        whenUnsatisfiable: DoNotSchedule
        nodeTaintsPolicy: Honor               # ignore nodes whose taints we do not tolerate (master)
        labelSelector:
          matchLabels: {app: gallery}
      containers:
      - name: nginx
        image: nginx:1.31-alpine
        volumeMounts:
        - {name: uploads, mountPath: /usr/share/nginx/html, readOnly: true}
      volumes:
      - name: uploads
        persistentVolumeClaim:
          claimName: uploads
          readOnly: true
EOF
workstation$ kubectl -n lab-04-06 rollout status deploy/gallery
workstation$ kubectl -n lab-04-06 get pods -l app=gallery -o wide
workstation$ for p in $(kubectl -n lab-04-06 get pod -l app=gallery -o name); do
  kubectl -n lab-04-06 exec $p -- sh -c 'wget -qO- localhost/incoming/node1.txt; wget -qO- localhost/incoming/scanner.txt; touch /usr/share/nginx/html/x'
done
```

Expected (one Pod per worker, same content, writes rejected):
```
gallery-8664449c8c-nnfgs   1/1     Running   0          1s    172.16.104.46    node2   ...
gallery-8664449c8c-pnxcp   1/1     Running   0          1s    172.16.166.136   node1   ...
invoice scanned on node1 by uploader-6f6d96657c-hn452 at 02:41:12
invoice from the office scanner
touch: /usr/share/nginx/html/x: Read-only file system
invoice scanned on node1 by uploader-6f6d96657c-hn452 at 02:41:12
invoice from the office scanner
touch: /usr/share/nginx/html/x: Read-only file system
```

Why `nodeTaintsPolicy: Honor`? By default (`Ignore`) the spread calculation includes the tainted `master` as a
domain with 0 Pods. Two replicas still work (1/1/0, skew 1), but a third replica would stay `Pending` forever, because
placing it on a worker would make the skew 2 and it cannot go to `master`. With `Honor` only schedulable nodes count.

</details>

---

## Lab 4.7: Nightly Postgres backups to S3 with a CronJob

**Scenario** – The auditors want a nightly backup of the shop database stored off the cluster. Mounting the bucket as a
volume (Lab 4.6) is not needed for this: the backup job can talk to S3 directly. We stream `pg_dump` through `gzip`
straight into MinIO with `mc pipe` (no temporary file, so the size of the database does not matter), schedule it as a
CronJob, and make sure a broken backup is reported as a failure.

**What you'll learn**
- application-level S3 access: credentials in a Secret, the `MC_HOST_<alias>` variable of the MinIO client
- borrowing a static binary from another image with an init container and a shared `emptyDir`
- CronJob settings that matter for backups: `timeZone`, `concurrencyPolicy: Forbid`, history limits, deadlines
- running a CronJob on demand with `kubectl create job --from=cronjob/...`
- why `set -o pipefail` is mandatory in backup scripts, and why it is not enough

On the client VM, use the `mc` alias from the module's *Prerequisites check*.

### Steps

1. Create the backup bucket.

```bash
client-vm$ mc mb m/lab-04-07-backups
```

Expected:
```
Bucket created successfully `m/lab-04-07-backups`.
```

2. Start a database with some data. It uses an `emptyDir` because this lab is about the backup, not the database.

```bash
workstation$ kubectl create namespace lab-04-07
workstation$ kubectl -n lab-04-07 apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: postgres
spec:
  selector:
    matchLabels: {app: postgres}
  template:
    metadata:
      labels: {app: postgres}
    spec:
      containers:
      - name: postgres
        image: postgres:17
        env:
        - {name: POSTGRES_DB, value: shop}
        - {name: POSTGRES_PASSWORD, value: lab-only-password}
        ports:
        - containerPort: 5432
        readinessProbe:
          exec: {command: ["pg_isready", "-U", "postgres"]}
          periodSeconds: 5
        volumeMounts:
        - {name: data, mountPath: /var/lib/postgresql/data}
      volumes:
      - name: data
        emptyDir: {}
---
apiVersion: v1
kind: Service
metadata:
  name: postgres
spec:
  selector: {app: postgres}
  ports:
  - port: 5432
EOF
workstation$ kubectl -n lab-04-07 rollout status deploy/postgres
workstation$ kubectl -n lab-04-07 exec deploy/postgres -- psql -U postgres -d shop -c \
  "CREATE TABLE orders AS SELECT g AS id, md5(g::text) AS item, now() - g * interval '1 hour' AS created
   FROM generate_series(1,5000) g;"
```

Expected:
```
SELECT 5000
```

3. Store the credentials for the job in a Secret. `MC_HOST_s3` defines an `mc` alias `s3` from a URL with embedded
   credentials; `PGPASSWORD` is read by `pg_dump`.

```bash
workstation$ kubectl -n lab-04-07 create secret generic backup-creds \
  --from-literal=PGPASSWORD=lab-only-password \
  --from-literal=MC_HOST_s3=http://minioadmin:minioadmin123@192.168.1.100:9000
```

> In production, give the job its own S3 user with a policy that only allows `PutObject` on this bucket; a backup job
> that can delete backups is a gift to ransomware.

4. Create the CronJob. The `postgres:17` image has `pg_dump` (matching the server's major version) but no `mc`, and
   the `mc` image has no `pg_dump`. The init container copies the static `mc` binary into a shared `emptyDir`, so one
   container can run the whole pipeline.

```bash
workstation$ kubectl -n lab-04-07 apply -f - <<'EOF'
apiVersion: batch/v1
kind: CronJob
metadata:
  name: pg-backup
spec:
  schedule: "0 2 * * *"              # every night at 02:00 ...
  timeZone: Europe/Warsaw            # ... Warsaw time, not the controller's UTC
  concurrencyPolicy: Forbid          # never run two backups at once
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 3
  jobTemplate:
    spec:
      backoffLimit: 1
      activeDeadlineSeconds: 600     # a hanging backup is a failed backup
      template:
        spec:
          restartPolicy: Never
          initContainers:
          - name: get-mc                   # copy the static mc binary into a shared volume
            image: pgsty/mc:RELEASE.2026-10-26T00-00-00Z
            command: ["cp", "/usr/bin/mc", "/tools/mc"]
            volumeMounts:
            - {name: tools, mountPath: /tools}
          containers:
          - name: backup
            image: postgres:17
            envFrom:
            - secretRef: {name: backup-creds}   # PGPASSWORD and MC_HOST_s3
            env:
            - {name: PGHOST, value: postgres}
            - {name: PGUSER, value: postgres}
            - {name: PGDATABASE, value: shop}
            - {name: BUCKET, value: lab-04-07-backups}
            command:
            - bash
            - -c
            - |
              set -euo pipefail
              key="shop/shop-$(date -u +%Y%m%dT%H%M%SZ).sql.gz"
              pg_dump --no-owner | gzip | /tools/mc pipe --quiet "s3/$BUCKET/$key"
              echo "backup written to s3://$BUCKET/$key"
            volumeMounts:
            - {name: tools, mountPath: /tools}
          volumes:
          - name: tools
            emptyDir: {}
EOF
workstation$ kubectl -n lab-04-07 get cronjob
```

Expected:
```
NAME        SCHEDULE    TIMEZONE        SUSPEND   ACTIVE   LAST SCHEDULE   AGE
pg-backup   0 2 * * *   Europe/Warsaw   False     0        <none>          0s
```

5. Nobody waits until 02:00 to test a backup. Create a Job from the CronJob's template now.

```bash
workstation$ kubectl -n lab-04-07 create job --from=cronjob/pg-backup backup-manual-1
workstation$ kubectl -n lab-04-07 wait --for=condition=complete job/backup-manual-1 --timeout=120s
workstation$ kubectl -n lab-04-07 logs job/backup-manual-1
```

Expected:
```
job.batch/backup-manual-1 condition met
Defaulted container "backup" out of: backup, get-mc (init)
130234 bytes -> `s3/lab-04-07-backups/shop/shop-20261104T025014Z.sql.gz`
backup written to s3://lab-04-07-backups/shop/shop-20261104T025014Z.sql.gz
```

6. Check the backup from outside the cluster. Download it, unpack it and look inside.

```bash
client-vm$ mc ls -r m/lab-04-07-backups
client-vm$ mc cat m/lab-04-07-backups/shop/shop-20261104T025014Z.sql.gz | gunzip | grep -E '^(CREATE TABLE|COPY)'
```

Expected:
```
[2026-11-04 02:50:15 UTC] 127KiB STANDARD shop/shop-20261104T025014Z.sql.gz
CREATE TABLE public.orders (
COPY public.orders (id, item, created) FROM stdin;
```

7. Break it: someone rotates the database password but forgets the backup Secret.

```bash
workstation$ kubectl -n lab-04-07 patch secret backup-creds -p '{"stringData":{"PGPASSWORD":"wrong"}}'
workstation$ kubectl -n lab-04-07 create job --from=cronjob/pg-backup backup-manual-2
workstation$ kubectl -n lab-04-07 get jobs                    # after ~30 s
workstation$ kubectl -n lab-04-07 logs -l job-name=backup-manual-2 -c backup
client-vm$ mc ls -r m/lab-04-07-backups
```

Expected:
```
NAME              STATUS     COMPLETIONS   DURATION   AGE
backup-manual-1   Complete   1/1           5s         50s
backup-manual-2   Failed     0/1           25s        25s
pg_dump: error: connection to server at "postgres" (10.97.105.79), port 5432 failed: FATAL:  password authentication failed for user "postgres"
20 bytes -> `s3/lab-04-07-backups/shop/shop-20261104T025039Z.sql.gz`
...
[2026-11-04 02:50:15 UTC] 127KiB STANDARD shop/shop-20261104T025014Z.sql.gz
[...]                       20B STANDARD shop/shop-20261104T025039Z.sql.gz
[...]                       20B STANDARD shop/shop-20261104T025051Z.sql.gz
```

> **Why `pipefail`?** The exit status of a pipeline is the status of its *last* command. Without
> `set -o pipefail`, `gzip` and `mc` succeed on empty input, the Job reports `Complete`, and you find out at restore
> time. With it the Job fails (and your alerting on failed Jobs fires). But look at the bucket: each attempt
> (`backoffLimit: 1` = 2 attempts) still left a 20-byte "backup" next to the good one. A restore script that picks
> "the newest file" would restore nothing.

### Clean up

```bash
workstation$ kubectl delete namespace lab-04-07
client-vm$ mc rb --force m/lab-04-07-backups
```

### Your turn

Make the backup trustworthy. Delete the two 20-byte objects, then change the job so that it streams into
`incomplete/<name>` and only moves the object to `shop/<name>` when the whole pipeline succeeded; a failed run must
not leave anything behind. Also make the bucket expire backups after 7 days (`mc ilm rule add`). Verify with the wrong
password (nothing new in the bucket, the Job fails) and with the right one (a new object in `shop/`).

<details><summary>Solution</summary>

```bash
client-vm$ mc rm m/lab-04-07-backups/shop/shop-20261104T025039Z.sql.gz m/lab-04-07-backups/shop/shop-20261104T025051Z.sql.gz
client-vm$ mc ilm rule add --expire-days 7 m/lab-04-07-backups
client-vm$ mc ilm rule ls m/lab-04-07-backups
```

Expected:
```
Lifecycle configuration rule added with ID `dbl9ranecgus739quke0` to m/lab-04-07-backups.
│ ID                   │ STATUS  │ PREFIX │ TAGS │ DAYS TO EXPIRE │ EXPIRE DELETEMARKER │
│ dbl9ranecgus739quke0 │ Enabled │ -      │ -    │              7 │ false               │
```

Replace the `command` of the `backup` container (everything else in the CronJob stays the same) and re-apply:

```yaml
            command:
            - bash
            - -c
            - |
              set -euo pipefail
              name="shop-$(date -u +%Y%m%dT%H%M%SZ).sql.gz"
              tmp="s3/$BUCKET/incomplete/$name"
              trap '/tools/mc rm --quiet "$tmp" 2>/dev/null || true' EXIT   # never leave a partial object behind
              pg_dump --no-owner | gzip | /tools/mc pipe --quiet "$tmp" >/dev/null
              /tools/mc mv --quiet "$tmp" "s3/$BUCKET/shop/$name" >/dev/null   # "promote" only complete dumps
              echo "backup written to s3://$BUCKET/shop/$name"
```

Test both cases (the Secret still has the wrong password from step 7):

```bash
workstation$ kubectl -n lab-04-07 create job --from=cronjob/pg-backup backup-manual-3
workstation$ kubectl -n lab-04-07 get job backup-manual-3                       # after ~30 s
workstation$ kubectl -n lab-04-07 logs -l job-name=backup-manual-3 -c backup
workstation$ kubectl -n lab-04-07 patch secret backup-creds -p '{"stringData":{"PGPASSWORD":"lab-only-password"}}'
workstation$ kubectl -n lab-04-07 create job --from=cronjob/pg-backup backup-manual-4
workstation$ kubectl -n lab-04-07 wait --for=condition=complete job/backup-manual-4 --timeout=60s
workstation$ kubectl -n lab-04-07 logs job/backup-manual-4 -c backup
client-vm$ mc ls -r m/lab-04-07-backups
```

Expected:
```
NAME              STATUS   COMPLETIONS   DURATION   AGE
backup-manual-3   Failed   0/1           26s        26s
pg_dump: error: connection to server at "postgres" (10.97.105.79), port 5432 failed: FATAL:  password authentication failed for user "postgres"
Removed `s3/lab-04-07-backups/incomplete/shop-20261104T025125Z.sql.gz`.
...
backup written to s3://lab-04-07-backups/shop/shop-20261104T025150Z.sql.gz
[2026-11-04 02:50:15 UTC] 127KiB STANDARD shop/shop-20261104T025014Z.sql.gz
[2026-11-04 02:51:50 UTC] 127KiB STANDARD shop/shop-20261104T025150Z.sql.gz
```

S3 has no atomic rename: `mc mv` is a server-side copy followed by a delete. That is fine here because readers only
look at `shop/`, and the copy appears there completely or not at all. The next lab restores from this layout.

</details>

---

## Lab 4.8: Restore a dataset from S3 with an init container

**Scenario** – QA wants a staging database that always starts with the latest anonymised product catalogue, which the
data team publishes to S3 as `catalog-<date>.sql.gz`. Whatever testers break, a Pod restart must bring back a clean
copy. An init container downloads the newest dump into an `emptyDir` before Postgres starts, and the official Postgres
image imports it on first start.

**What you'll learn**
- init containers as a "prepare the data, then start the app" step that shares an `emptyDir` with the app
- picking the newest object from a bucket with `mc find`
- the Postgres image's `/docker-entrypoint-initdb.d` hook (runs only when the data directory is empty)
- failing closed: no dataset → no Pod, and a rolling update keeps the old Pod running

### Steps

1. On the client VM (with the `mc` alias from the *Prerequisites check*), publish two versions of the dataset.

```bash
client-vm$ mc mb m/lab-04-08-datasets
client-vm$ for d in 2026-11-01:800 2026-11-03:1200; do
  day=${d%:*}; rows=${d#*:}
  {
    echo "CREATE TABLE dataset_info(version text);"
    echo "INSERT INTO dataset_info VALUES ('$day');"
    echo "CREATE TABLE products(id int PRIMARY KEY, name text, price numeric);"
    echo "INSERT INTO products SELECT g, 'product-' || g, round((random()*100)::numeric, 2) FROM generate_series(1,$rows) g;"
  } | gzip | mc pipe m/lab-04-08-datasets/catalog/catalog-$day.sql.gz
done
client-vm$ mc ls m/lab-04-08-datasets/catalog/
```

Expected:
```
Bucket created successfully `m/lab-04-08-datasets`.
215 bytes -> `m/lab-04-08-datasets/catalog/catalog-2026-11-01.sql.gz`
216 bytes -> `m/lab-04-08-datasets/catalog/catalog-2026-11-03.sql.gz`
[2026-11-04 02:53:51 UTC]   215B STANDARD catalog-2026-11-01.sql.gz
[2026-11-04 02:53:52 UTC]   216B STANDARD catalog-2026-11-03.sql.gz
```

2. Create the namespace, the S3 credentials and the staging database.

```bash
workstation$ kubectl create namespace lab-04-08
workstation$ kubectl -n lab-04-08 create secret generic dataset-s3 \
  --from-literal=MC_HOST_s3=http://minioadmin:minioadmin123@192.168.1.100:9000
workstation$ kubectl -n lab-04-08 apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: staging-db
spec:
  replicas: 1
  selector:
    matchLabels: {app: staging-db}
  template:
    metadata:
      labels: {app: staging-db}
    spec:
      initContainers:
      - name: fetch-dataset
        image: pgsty/mc:RELEASE.2026-10-26T00-00-00Z
        envFrom:
        - secretRef: {name: dataset-s3}          # MC_HOST_s3
        env:
        - {name: SOURCE, value: s3/lab-04-08-datasets/catalog}
        command:
        - bash
        - -c
        - |
          set -euo pipefail
          latest=$(mc find "$SOURCE" --name 'catalog-*.sql.gz' | sort | tail -n 1)
          [ -n "$latest" ] || { echo "no dataset found in $SOURCE" >&2; exit 1; }
          echo "restoring $latest"
          mc cp --quiet "$latest" /initdb/
        volumeMounts:
        - {name: initdb, mountPath: /initdb}
      containers:
      - name: postgres
        image: postgres:17
        env:
        - {name: POSTGRES_DB, value: catalog}
        - {name: POSTGRES_PASSWORD, value: lab-only-password}
        readinessProbe:
          exec: {command: ["pg_isready", "-U", "postgres"]}
          periodSeconds: 5
        volumeMounts:
        - {name: initdb, mountPath: /docker-entrypoint-initdb.d, readOnly: true}
        - {name: data, mountPath: /var/lib/postgresql/data}
      volumes:
      - name: initdb                             # filled by the init container
        emptyDir: {}
      - name: data                               # staging data is disposable by design
        emptyDir: {}
EOF
workstation$ kubectl -n lab-04-08 rollout status deploy/staging-db
```

3. Follow the hand-over: the init container picked the newest file, and the Postgres entrypoint imported it.

```bash
workstation$ kubectl -n lab-04-08 logs deploy/staging-db -c fetch-dataset | head -2
workstation$ kubectl -n lab-04-08 logs deploy/staging-db -c postgres | grep initdb.d
workstation$ kubectl -n lab-04-08 exec deploy/staging-db -c postgres -- \
  psql -U postgres -d catalog -tc 'SELECT version, (SELECT count(*) FROM products) FROM dataset_info'
```

Expected:
```
restoring s3/lab-04-08-datasets/catalog/catalog-2026-11-03.sql.gz
`s3/lab-04-08-datasets/catalog/catalog-2026-11-03.sql.gz` -> `/initdb/catalog-2026-11-03.sql.gz`
/usr/local/bin/docker-entrypoint.sh: running /docker-entrypoint-initdb.d/catalog-2026-11-03.sql.gz
 2026-11-03 |  1200
```

> **Why sort by name?** Object timestamps change when someone re-uploads an old file. A sortable date in the object
> name (`YYYY-MM-DD`) is a contract you control.

4. A tester deletes most of the catalogue. Delete the Pod, and the next Pod starts with the clean dataset again.

```bash
workstation$ kubectl -n lab-04-08 exec deploy/staging-db -c postgres -- psql -U postgres -d catalog -c 'DELETE FROM products WHERE id > 100'
workstation$ kubectl -n lab-04-08 delete pod -l app=staging-db
workstation$ kubectl -n lab-04-08 rollout status deploy/staging-db
workstation$ kubectl -n lab-04-08 exec deploy/staging-db -c postgres -- psql -U postgres -d catalog -tc 'SELECT count(*) FROM products'
```

Expected:
```
DELETE 1100
deployment "staging-db" successfully rolled out
  1200
```

The restore happens because both `emptyDir` volumes are new. If only the *container* restarts (crash, OOM), the
data directory survives in the Pod's `emptyDir`, `initdb.d` is skipped, and the tester's changes remain.

5. Fail closed. Someone mistypes the source prefix. The new Pod never starts Postgres, and because the Deployment uses
   a rolling update, the old Pod keeps serving.

```bash
workstation$ kubectl -n lab-04-08 set env deploy/staging-db -c fetch-dataset SOURCE=s3/lab-04-08-datasets/catalogue
workstation$ kubectl -n lab-04-08 get pods                        # after ~20 s
workstation$ kubectl -n lab-04-08 logs -l app=staging-db -c fetch-dataset --prefix | grep ERROR
```

Expected:
```
NAME                          READY   STATUS       RESTARTS      AGE
staging-db-5d8f5f9cf9-hvpwb   0/1     Init:Error   2 (18s ago)   20s
staging-db-7d8ffd799c-gv55c   1/1     Running      0             39s
[pod/staging-db-5d8f5f9cf9-hvpwb/fetch-dataset] mc: <ERROR> Unable to stat `s3/lab-04-08-datasets/catalogue`. Object does not exist.
```

With `strategy: Recreate` the working Pod would have been killed first, and staging would be down until the typo is
fixed. Fix it:

```bash
workstation$ kubectl -n lab-04-08 set env deploy/staging-db -c fetch-dataset SOURCE=s3/lab-04-08-datasets/catalog
workstation$ kubectl -n lab-04-08 rollout status deploy/staging-db
```

### Clean up

```bash
workstation$ kubectl delete namespace lab-04-08
client-vm$ mc rb --force m/lab-04-08-datasets
```

### Your turn

QA needs to reproduce a bug that only happens with the 2026-11-01 catalogue, and security asks you to make sure the
init container never imports a tampered dump. Add an optional `DATASET_VERSION` variable (empty = newest) and verify
each dump against a `<file>.sha256` object (in `sha256sum` format) stored next to it before handing it to Postgres.
Publish the checksum files, roll out with `DATASET_VERSION=2026-11-01`, then overwrite the 2026-11-03 dump with
something else and show that switching back to "newest" is refused.

<details><summary>Solution</summary>

Publish the checksums (computed from the objects that are in the bucket now):

```bash
client-vm$ for f in catalog-2026-11-01.sql.gz catalog-2026-11-03.sql.gz; do
  mc cat m/lab-04-08-datasets/catalog/$f | sha256sum | sed "s|-\$|$f|" | mc pipe m/lab-04-08-datasets/catalog/$f.sha256
done
client-vm$ mc cat m/lab-04-08-datasets/catalog/catalog-2026-11-01.sql.gz.sha256
```

Expected:
```
7eb4456ed8010110d8f7633b189a6bce723ebfe150cded6e434c675984ed0e65  catalog-2026-11-01.sql.gz
```

Replace the init container. The file is downloaded to `/tmp` first and moved into the shared volume only after the
checksum matched, so Postgres never sees an unverified file:

```yaml
      initContainers:
      - name: fetch-dataset
        image: pgsty/mc:RELEASE.2026-10-26T00-00-00Z
        envFrom:
        - secretRef: {name: dataset-s3}
        env:
        - {name: SOURCE, value: s3/lab-04-08-datasets/catalog}
        - {name: DATASET_VERSION, value: "2026-11-01"}     # empty = newest
        command:
        - bash
        - -c
        - |
          set -euo pipefail
          if [ -n "${DATASET_VERSION:-}" ]; then
            file="$SOURCE/catalog-$DATASET_VERSION.sql.gz"
          else
            file=$(mc find "$SOURCE" --name 'catalog-*.sql.gz' | sort | tail -n 1)
          fi
          [ -n "$file" ] || { echo "no dataset found in $SOURCE" >&2; exit 1; }
          echo "restoring $file"
          mc cp --quiet "$file" "$file.sha256" /tmp/ >/dev/null
          cd /tmp && sha256sum -c "$(basename "$file").sha256"
          mv "/tmp/$(basename "$file")" /initdb/
        volumeMounts:
        - {name: initdb, mountPath: /initdb}
```

```bash
workstation$ kubectl -n lab-04-08 apply -f staging-db.yaml       # the Deployment with the new init container
workstation$ kubectl -n lab-04-08 rollout status deploy/staging-db
workstation$ kubectl -n lab-04-08 logs deploy/staging-db -c fetch-dataset
workstation$ kubectl -n lab-04-08 exec deploy/staging-db -c postgres -- \
  psql -U postgres -d catalog -tc 'SELECT version, (SELECT count(*) FROM products) FROM dataset_info'
```

Expected:
```
restoring s3/lab-04-08-datasets/catalog/catalog-2026-11-01.sql.gz
catalog-2026-11-01.sql.gz: OK
 2026-11-01 |   800
```

Tamper with the newest dump and switch to "newest":

```bash
client-vm$ echo "CREATE TABLE pwned(x int);" | gzip | mc pipe m/lab-04-08-datasets/catalog/catalog-2026-11-03.sql.gz
workstation$ kubectl -n lab-04-08 set env deploy/staging-db -c fetch-dataset DATASET_VERSION=
workstation$ kubectl -n lab-04-08 get pods
workstation$ kubectl -n lab-04-08 logs -l app=staging-db -c fetch-dataset --prefix
```

Expected (the verified 2026-11-01 Pod keeps running):
```
NAME                          READY   STATUS       RESTARTS      AGE
staging-db-778d6cb4b7-wh4k2   1/1     Running      0             38s
staging-db-bc49cc8bd-4rhhg    0/1     Init:Error   2 (18s ago)   20s
[pod/staging-db-bc49cc8bd-4rhhg/fetch-dataset] restoring s3/lab-04-08-datasets/catalog/catalog-2026-11-03.sql.gz
[pod/staging-db-bc49cc8bd-4rhhg/fetch-dataset] catalog-2026-11-03.sql.gz: FAILED
[pod/staging-db-bc49cc8bd-4rhhg/fetch-dataset] sha256sum: WARNING: 1 computed checksum did NOT match
```

A checksum stored next to the data only detects accidents and careless tampering; whoever can overwrite the dump can
overwrite the checksum too. Real integrity needs a signature or a write-once (object-lock) bucket.

</details>

---

## Lab 4.9: Non-root containers and volume permissions

**Scenario** – A new security policy says no container may run as root (Module 06 enforces it). The photo service
moves to UID 1000, and on the first day it fails with `Permission denied` on its volume, because the volume belongs to
root. We fix it the Kubernetes way with `fsGroup`, give every replica a private log directory on a shared volume with
`subPathExpr`, protect originals with read-only mounts, and handle a legacy `hostPath` volume where `fsGroup` does
nothing.

**What you'll learn**
- `runAsUser` / `runAsGroup` / `fsGroup` and what the kubelet does to a volume with `fsGroup`
- `fsGroupChangePolicy: OnRootMismatch` for large volumes
- which volume types honour `fsGroup` (emptyDir, local PVs, most block CSI drivers) and which do not (`hostPath`)
- `subPathExpr` for per-Pod directories, `readOnly` mounts, and the meaning of `ReadWriteOnce`

### Steps

1. Prepare two directories on `node1`: one becomes a local PV, the other stays a legacy `hostPath`.

```bash
node1$ sudo mkdir -p /mnt/lab-04-09/photos /mnt/lab-04-09/legacy
```

2. Create the PV, the claim and the app, running as UID/GID 1000.

```bash
workstation$ kubectl create namespace lab-04-09
workstation$ kubectl apply -f - <<'EOF'
apiVersion: v1
kind: PersistentVolume
metadata:
  name: lab-04-09-photos
spec:
  capacity: {storage: 1Gi}
  accessModes: [ReadWriteOnce]
  persistentVolumeReclaimPolicy: Retain
  storageClassName: ""
  claimRef: {namespace: lab-04-09, name: photos}
  local: {path: /mnt/lab-04-09/photos}
  nodeAffinity:
    required:
      nodeSelectorTerms:
      - matchExpressions:
        - {key: kubernetes.io/hostname, operator: In, values: [node1]}
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: photos
  namespace: lab-04-09
spec:
  storageClassName: ""
  accessModes: [ReadWriteOnce]
  resources:
    requests: {storage: 1Gi}
---
apiVersion: v1
kind: Pod
metadata:
  name: photo-app
  namespace: lab-04-09
spec:
  securityContext:
    runAsUser: 1000
    runAsGroup: 1000
    runAsNonRoot: true
  containers:
  - name: app
    image: busybox:1.38
    command: ["sleep", "infinity"]
    volumeMounts:
    - {name: photos, mountPath: /data/photos}
  volumes:
  - name: photos
    persistentVolumeClaim: {claimName: photos}
EOF
workstation$ kubectl -n lab-04-09 wait --for=condition=Ready pod/photo-app
workstation$ kubectl -n lab-04-09 exec photo-app -- sh -c 'id; ls -ld /data/photos; touch /data/photos/cat.jpg'
```

Expected:
```
uid=1000(1000) gid=1000(1000) groups=1000(1000)
drwxr-xr-x    2 root     root          4096 Nov  4 02:58 /data/photos
touch: /data/photos/cat.jpg: Permission denied
```

3. Recreate the Pod with `fsGroup: 2000`, and mount two more volumes for comparison: the legacy `hostPath` and an
   `emptyDir`.

```bash
workstation$ kubectl -n lab-04-09 delete pod photo-app
workstation$ kubectl -n lab-04-09 apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: photo-app
spec:
  nodeSelector:
    kubernetes.io/hostname: node1          # the hostPath directory exists only there
  securityContext:
    runAsUser: 1000
    runAsGroup: 1000
    runAsNonRoot: true
    fsGroup: 2000                          # supplementary group + group ownership of volumes
    fsGroupChangePolicy: OnRootMismatch    # skip the recursive chown if the root dir is already right
  containers:
  - name: app
    image: busybox:1.38
    command: ["sleep", "infinity"]
    volumeMounts:
    - {name: photos, mountPath: /data/photos}
    - {name: legacy, mountPath: /data/legacy}
    - {name: cache, mountPath: /data/cache}
  volumes:
  - name: photos
    persistentVolumeClaim: {claimName: photos}
  - name: legacy
    hostPath: {path: /mnt/lab-04-09/legacy, type: Directory}
  - name: cache
    emptyDir: {}
EOF
workstation$ kubectl -n lab-04-09 wait --for=condition=Ready pod/photo-app
workstation$ kubectl -n lab-04-09 exec photo-app -- sh -c '
  id; ls -ld /data/*
  touch /data/photos/cat.jpg && ls -ln /data/photos
  touch /data/legacy/x'
```

Expected:
```
uid=1000(1000) gid=1000(1000) groups=1000(1000),2000
drwxrwsrwx    2 root     2000          4096 Nov  4 02:58 /data/cache
drwxr-xr-x    2 root     root          4096 Nov  4 02:58 /data/legacy
drwxrwsr-x    2 root     2000          4096 Nov  4 02:58 /data/photos
-rw-r--r--    1 1000     2000             0 Nov  4 02:58 cat.jpg
touch: /data/legacy/x: Permission denied
```

> **Why:** Before starting the containers, the kubelet changes the group of the volume to `fsGroup`, makes it group
> writable and sets the setgid bit (`s`), so new files inherit group 2000. On big volumes this recursive walk can delay
> the start by minutes; `OnRootMismatch` skips it when the top directory is already correct. `hostPath` is never
> touched: the kubelet does not change files on the node that it does not own.

4. Add a worker Deployment with two replicas that share the same claim. Each replica gets a private log directory
   through `subPathExpr`, and the photos are mounted read-only because the worker must never modify originals.

```bash
workstation$ kubectl -n lab-04-09 apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: thumbnailer
spec:
  replicas: 2
  selector:
    matchLabels: {app: thumbnailer}
  template:
    metadata:
      labels: {app: thumbnailer}
    spec:
      securityContext:
        runAsUser: 1000
        runAsGroup: 1000
        runAsNonRoot: true
        fsGroup: 2000
      containers:
      - name: worker
        image: busybox:1.38
        env:
        - name: POD_NAME
          valueFrom: {fieldRef: {fieldPath: metadata.name}}
        command: ["sh", "-c", "while true; do date >> /var/log/thumbnailer/worker.log; sleep 10; done"]
        volumeMounts:
        - name: photos
          mountPath: /var/log/thumbnailer
          subPathExpr: logs/$(POD_NAME)          # one private directory per Pod
        - name: photos
          mountPath: /data/photos
          readOnly: true                         # the worker only reads originals
      volumes:
      - name: photos
        persistentVolumeClaim: {claimName: photos}
EOF
workstation$ kubectl -n lab-04-09 rollout status deploy/thumbnailer
workstation$ kubectl -n lab-04-09 get pods -o wide
workstation$ kubectl -n lab-04-09 exec photo-app -- ls -lnR /data/photos/logs
workstation$ kubectl -n lab-04-09 exec deploy/thumbnailer -- sh -c 'ls /var/log/thumbnailer; touch /data/photos/x'
```

Expected:
```
NAME                           READY   STATUS    RESTARTS   AGE   IP               NODE    ...
photo-app                      1/1     Running   0          12s   172.16.166.189   node1   ...
thumbnailer-59499668ff-jzsxz   1/1     Running   0          1s    172.16.166.187   node1   ...
thumbnailer-59499668ff-vnmmq   1/1     Running   0          1s    172.16.166.183   node1   ...
/data/photos/logs:
drwxrwsr-x    2 0        2000          4096 Nov  4 02:58 thumbnailer-59499668ff-jzsxz
drwxrwsr-x    2 0        2000          4096 Nov  4 02:58 thumbnailer-59499668ff-vnmmq
/data/photos/logs/thumbnailer-59499668ff-jzsxz:
-rw-r--r--    1 1000     2000            29 Nov  4 02:58 worker.log
...
worker.log
touch: /data/photos/x: Read-only file system
```

Three Pods use one `ReadWriteOnce` claim at the same time. That is allowed: RWO means "mounted read-write by **one
node**", not by one Pod. If you need one Pod only, use `ReadWriteOncePod`. The kubelet created the `subPathExpr`
directories as root, but thanks to the setgid bit and group write permission UID 1000 can write into them.

> **Pitfall:** files are created with the process's umask (`-rw-r--r--`). Another app running as a different UID in
> group 2000 could read but not modify them. Shared volumes between different users need a group-writable umask in
> the app, not just `fsGroup`.

### Clean up

```bash
workstation$ kubectl delete namespace lab-04-09
workstation$ kubectl delete pv lab-04-09-photos
node1$ sudo rm -rf /mnt/lab-04-09
```

### Your turn

A legacy importer must keep using the `hostPath` directory `/mnt/lab-04-09/legacy` for now, and it runs as UID 1000.
`fsGroup` does not help there. Write a Pod `legacy-importer` whose app container (non-root) writes `import.log` into
that directory. Prepare the directory from inside Kubernetes with an init container that has exactly the privilege it
needs, and nothing more. The directory must end up owned by 1000:1000 with mode `0750`.

<details><summary>Solution</summary>

The init container runs as root but drops every capability except `CHOWN`. Order matters: once the directory belongs
to UID 1000, root without `CAP_FOWNER` is no longer its owner and `chmod` fails with `Operation not permitted`. So
`chmod` first, then `chown`.

```bash
workstation$ kubectl -n lab-04-09 apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: legacy-importer
spec:
  nodeSelector:
    kubernetes.io/hostname: node1
  securityContext:
    runAsUser: 1000
    runAsGroup: 1000
    runAsNonRoot: true
  initContainers:
  - name: fix-permissions
    image: busybox:1.38
    securityContext:
      runAsUser: 0                     # this one container runs as root ...
      runAsNonRoot: false
      capabilities:
        drop: ["ALL"]
        add: ["CHOWN"]                 # ... but may only change ownership
    command: ["sh", "-c", "chmod 0750 /data/legacy && chown 1000:1000 /data/legacy && ls -ldn /data/legacy"]
    volumeMounts:
    - {name: legacy, mountPath: /data/legacy}
  containers:
  - name: app
    image: busybox:1.38
    command: ["sh", "-c", "echo 'import done' > /data/legacy/import.log && sleep infinity"]
    volumeMounts:
    - {name: legacy, mountPath: /data/legacy}
  volumes:
  - name: legacy
    hostPath: {path: /mnt/lab-04-09/legacy, type: Directory}
EOF
workstation$ kubectl -n lab-04-09 wait --for=condition=Ready pod/legacy-importer
workstation$ kubectl -n lab-04-09 logs legacy-importer -c fix-permissions
workstation$ kubectl -n lab-04-09 exec legacy-importer -- ls -ln /data/legacy
```

Expected:
```
drwxr-x---    2 1000     1000          4096 Nov  4 02:58 /data/legacy
-rw-r--r--    1 1000     1000            12 Nov  4 02:59 import.log
```

This Pod would be rejected in a namespace with the Pod Security `restricted` level (root init container) and even with
`baseline` (`hostPath`). That is the real fix: move the data to a PV, where `fsGroup` works, and delete the
`hostPath`.

</details>
