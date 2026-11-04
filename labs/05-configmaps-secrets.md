# Module 05: ConfigMaps & Secrets

The same image should run in every environment; what differs is configuration and credentials. In this module you
inject both as files and environment variables, learn which changes reach a running Pod and which need a restart,
use the built-in Secret types for TLS, registries and basic auth, and finally make sure Secrets are encrypted in etcd.

## Prerequisites check

```bash
workstation$ kubectl get nodes                      # master, node1, node2 Ready
workstation$ kubectl version | grep Server          # Server Version: v1.37.x (kustomize is built into kubectl)
workstation$ openssl version; jq --version          # Lab 5.5 creates certificates; several labs decode JSON
master$      sudo ls /etc/kubernetes/manifests       # Lab 5.10 only: kube-apiserver.yaml, etcd.yaml, ...
```

## Table of contents

- [Lab 5.1: Ship an nginx configuration as a ConfigMap and reload it](#lab-51-ship-an-nginx-configuration-as-a-configmap-and-reload-it)
- [Lab 5.2: Environment variables from ConfigMaps, and how to roll them out](#lab-52-environment-variables-from-configmaps-and-how-to-roll-them-out)
- [Lab 5.3: Feature flags that change without a restart](#lab-53-feature-flags-that-change-without-a-restart)
- [Lab 5.4: Database credentials in an Opaque Secret](#lab-54-database-credentials-in-an-opaque-secret)
- [Lab 5.5: HTTPS with a kubernetes.io/tls Secret and certificate rotation](#lab-55-https-with-a-kubernetesiotls-secret-and-certificate-rotation)
- [Lab 5.6: Pull from a private registry with imagePullSecrets on a ServiceAccount](#lab-56-pull-from-a-private-registry-with-imagepullsecrets-on-a-serviceaccount)
- [Lab 5.7: Protect an internal tool with a basic-auth Secret](#lab-57-protect-an-internal-tool-with-a-basic-auth-secret)
- [Lab 5.8: One directory for everything: projected volumes](#lab-58-one-directory-for-everything-projected-volumes)
- [Lab 5.9: Safe config rollouts with Kustomize configMapGenerator](#lab-59-safe-config-rollouts-with-kustomize-configmapgenerator)
- [Lab 5.10: Encrypt Secrets at rest in etcd ⚠ cluster-wide](#lab-510-encrypt-secrets-at-rest-in-etcd--cluster-wide)

---

## Lab 5.1: Ship an nginx configuration as a ConfigMap and reload it

**Scenario** – The shop's front proxy is a stock nginx image, and the ops team keeps its configuration in Git as plain
`nginx.conf` and `default.conf` files. They want to change routing rules without building images, and without
restarting Pods for every small change. We load the files into a ConfigMap, mount them, update them, and find out
which mount style picks up changes and which silently keeps the old file.

**What you'll learn**
- `kubectl create configmap --from-file` and the "dry-run | apply" idiom for updates
- mounting a whole directory vs. a single file with `subPath`
- `items` to project only selected keys
- how updates propagate (the `..data` symlink swap), the delay, and why **`subPath` mounts never update**
- reloading nginx in place, and `kubectl rollout restart` when a restart is needed

### Steps

1. Write the two configuration files on your workstation.

```bash
workstation$ mkdir -p ~/lab-05-01 && cd ~/lab-05-01
workstation$ cat > nginx.conf <<'EOF'
worker_processes 1;
events { worker_connections 256; }
http {
  include /etc/nginx/mime.types;
  server_tokens off;
  log_format main '$remote_addr "$request" $status';
  access_log /dev/stdout main;
  include /etc/nginx/conf.d/*.conf;
}
EOF
workstation$ cat > default.conf <<'EOF'
server {
  listen 80;
  location / {
    return 200 "Welcome to the shop (config v1)\n";
  }
}
EOF
```

2. Create the ConfigMap from the files (the file names become the keys) and the Deployment. `nginx.conf` must sit
   next to `mime.types` in `/etc/nginx`, so it is mounted as a single file with `subPath`. `conf.d` can be replaced
   completely, so it is a directory mount.

```bash
workstation$ kubectl create namespace lab-05-01
workstation$ kubectl -n lab-05-01 create configmap nginx-conf --from-file=nginx.conf --from-file=default.conf
workstation$ kubectl -n lab-05-01 apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
spec:
  replicas: 1
  selector:
    matchLabels: {app: web}
  template:
    metadata:
      labels: {app: web}
    spec:
      containers:
      - name: nginx
        image: nginx:1.31-alpine
        volumeMounts:
        - name: main-conf
          mountPath: /etc/nginx/nginx.conf      # a single file next to mime.types etc.: needs subPath
          subPath: nginx.conf
        - name: site-conf
          mountPath: /etc/nginx/conf.d          # a whole directory: replaced by the ConfigMap
      volumes:
      - name: main-conf
        configMap:
          name: nginx-conf
      - name: site-conf
        configMap:
          name: nginx-conf
          items:                                # only this key, or conf.d/*.conf would include nginx.conf too
          - {key: default.conf, path: default.conf}
EOF
workstation$ kubectl -n lab-05-01 rollout status deploy/web
workstation$ kubectl -n lab-05-01 exec deploy/web -- curl -s localhost
```

Expected:
```
Welcome to the shop (config v1)
```

> **Why two volumes?** A ConfigMap volume projects *every* key unless you list `items`. Without `items`, `conf.d`
> would also contain `nginx.conf`, nginx would include it inside `http {}` and crash with
> `"worker_processes" directive is not allowed here in /etc/nginx/conf.d/nginx.conf:1`.

3. Look at how the directory mount is built. The files are symlinks into a timestamped directory, via `..data`.

```bash
workstation$ kubectl -n lab-05-01 exec deploy/web -- ls -la /etc/nginx/conf.d
```

Expected:
```
drwxr-xr-x    2 root     root          4096 Nov  4 03:02 ..2026_11_04_03_02_28.4249353584
lrwxrwxrwx    1 root     root            32 Nov  4 03:02 ..data -> ..2026_11_04_03_02_28.4249353584
lrwxrwxrwx    1 root     root            19 Nov  4 03:02 default.conf -> ..data/default.conf
```

On an update the kubelet writes a new timestamped directory and then swaps the `..data` link in one atomic rename,
so the application never sees a half-written set of files.

4. Change both files: a redirect in `default.conf`, a response header in `nginx.conf`. Update the ConfigMap with the
   "generate and apply" idiom, which works for create and update alike.

```bash
workstation$ sed -i 's/server_tokens off;/server_tokens off;\n  add_header X-Served-By shop-web always;/' nginx.conf
workstation$ cat > default.conf <<'EOF'
server {
  listen 80;
  location = /old-shop { return 301 /; }
  location / {
    return 200 "Welcome to the shop (config v2)\n";
  }
}
EOF
workstation$ kubectl -n lab-05-01 create configmap nginx-conf --from-file=nginx.conf --from-file=default.conf \
  --dry-run=client -o yaml | kubectl -n lab-05-01 apply -f -
```

(On macOS use `gsed`, or edit the file by hand.)

5. Wait for the change to arrive in the Pod. It is not instant: the kubelet refreshes mounted ConfigMaps during its
   periodic Pod sync, so expect **up to 1–2 minutes**. Here it took about 80 seconds.

```bash
workstation$ kubectl -n lab-05-01 exec deploy/web -- grep v2 /etc/nginx/conf.d/default.conf   # repeat until it matches
workstation$ kubectl -n lab-05-01 exec deploy/web -- curl -s localhost
```

Expected (the file is new, but nginx still serves the old config, because it read its files at start-up):
```
    return 200 "Welcome to the shop (config v2)\n";
Welcome to the shop (config v1)
```

6. Tell nginx to reload. It validates the new config and replaces its workers without dropping connections.

```bash
workstation$ kubectl -n lab-05-01 exec deploy/web -- sh -c 'nginx -t && nginx -s reload'
workstation$ kubectl -n lab-05-01 exec deploy/web -- curl -s localhost
workstation$ kubectl -n lab-05-01 exec deploy/web -- curl -si localhost/old-shop
```

Expected:
```
nginx: configuration file /etc/nginx/nginx.conf test is successful
Welcome to the shop (config v2)
HTTP/1.1 301 Moved Permanently
Location: http://localhost/
```

The `X-Served-By` header is missing. Check the `subPath` file:

```bash
workstation$ kubectl -n lab-05-01 exec deploy/web -- grep -c X-Served-By /etc/nginx/nginx.conf
```

Expected:
```
0
command terminated with exit code 1
```

> **Pitfall:** a `subPath` mount is a bind mount of the file that existed when the container started. The `..data`
> swap happens in the volume directory and never reaches it, no matter how long you wait. Files mounted with
> `subPath` (and environment variables, Lab 5.2) need a container restart.

7. Restart the Pods in a controlled way. `rollout restart` adds a timestamp annotation to the Pod template, so the
   Deployment performs a normal rolling update.

```bash
workstation$ kubectl -n lab-05-01 rollout restart deploy/web
workstation$ kubectl -n lab-05-01 rollout status deploy/web
workstation$ kubectl -n lab-05-01 exec deploy/web -- sh -c 'curl -si localhost | grep -E "^(HTTP|X-Served)"'
```

Expected:
```
HTTP/1.1 200 OK
X-Served-By: shop-web
```

### Clean up

```bash
workstation$ kubectl delete namespace lab-05-01
workstation$ rm -rf ~/lab-05-01
```

### Your turn

Nobody wants to `exec` into every replica to reload nginx. Add a `config-reloader` sidecar that notices when the
files in `conf.d` change and sends `SIGHUP` to the nginx master process (that is what `nginx -s reload` does). Then
change the response to `config v3`, update the ConfigMap and, without touching the Pod, wait until `curl` returns the
new text. Hint: containers in a Pod have separate process namespaces unless you ask otherwise.

<details><summary>Solution</summary>

`shareProcessNamespace: true` puts all containers of the Pod into one PID namespace, so the sidecar can find and
signal the nginx master. Both containers run as root here, which is what allows the signal.

```bash
workstation$ kubectl -n lab-05-01 apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
spec:
  replicas: 1
  selector:
    matchLabels: {app: web}
  template:
    metadata:
      labels: {app: web}
    spec:
      shareProcessNamespace: true             # the sidecar can see (and signal) nginx
      containers:
      - name: nginx
        image: nginx:1.31-alpine
        volumeMounts:
        - {name: main-conf, mountPath: /etc/nginx/nginx.conf, subPath: nginx.conf}
        - {name: site-conf, mountPath: /etc/nginx/conf.d}
      - name: config-reloader
        image: busybox:1.38
        command:
        - sh
        - -c
        - |
          last=$(cat /config/*.conf | md5sum)
          while true; do
            sleep 5
            now=$(cat /config/*.conf | md5sum)
            if [ "$now" != "$last" ]; then
              pid=$(pgrep -o -f 'nginx: master')
              echo "$(date -u +%T) config changed, sending SIGHUP to nginx master (pid $pid)"
              kill -HUP "$pid" && last=$now
            fi
          done
        resources:
          requests: {cpu: 5m, memory: 8Mi}
        volumeMounts:
        - {name: site-conf, mountPath: /config, readOnly: true}
      volumes:
      - name: main-conf
        configMap:
          name: nginx-conf
      - name: site-conf
        configMap:
          name: nginx-conf
          items:
          - {key: default.conf, path: default.conf}
EOF
workstation$ kubectl -n lab-05-01 rollout status deploy/web
workstation$ sed -i 's/config v2/config v3/' default.conf
workstation$ kubectl -n lab-05-01 create configmap nginx-conf --from-file=nginx.conf --from-file=default.conf \
  --dry-run=client -o yaml | kubectl -n lab-05-01 apply -f -
workstation$ kubectl -n lab-05-01 exec deploy/web -c nginx -- curl -s localhost        # repeat for ~2 minutes
workstation$ kubectl -n lab-05-01 logs deploy/web -c config-reloader
```

Expected:
```
Welcome to the shop (config v3)
03:05:52 config changed, sending SIGHUP to nginx master (pid 2)
```

PID 1 in a shared process namespace is the Pod's `pause` container, which is why nginx has PID 2. The sidecar does not
run `nginx -t`; a broken config makes the master keep its old workers and log an error, so a production reloader
should validate first (for example by shipping the nginx binary in the sidecar). Ready-made tools for the same job
are Reloader or the `configmap-reload` sidecar.

</details>

---

## Lab 5.2: Environment variables from ConfigMaps, and how to roll them out

**Scenario** – The shop front end is a twelve-factor app: everything it needs to know comes from environment
variables. Marketing changes the banner text several times a week, and every time someone asks "I updated the
ConfigMap, why is the old banner still there?". We wire the ConfigMaps in with `envFrom` and prefixes, see why the
change does not arrive, and compare two ways to roll it out: `kubectl rollout restart` and the checksum-annotation
pattern used by Helm charts and GitOps tools.

**What you'll learn**
- `envFrom` with `prefix` to map generic keys onto the variable names an app expects
- environment variables are a snapshot taken at container start
- `kubectl rollout restart` and what it changes in the Deployment
- the checksum annotation pattern: roll out **only** when the configuration really changed
- what happens when a referenced ConfigMap is missing

### Steps

1. Create two ConfigMaps and the app. [podinfo](https://github.com/stefanprodan/podinfo) reads `PODINFO_UI_MESSAGE`
   and `PODINFO_UI_COLOR`; the ConfigMap keys stay short and the prefix adds the app-specific part.

```bash
workstation$ kubectl create namespace lab-05-02
workstation$ kubectl -n lab-05-02 apply -f - <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: shop-ui
data:
  UI_MESSAGE: "Autumn sale: -20% on keyboards"
  UI_COLOR: "#34577c"
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: shop-limits
data:
  MAX_CART_ITEMS: "50"
  CHECKOUT_TIMEOUT: "30s"
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: shop
spec:
  replicas: 2
  selector:
    matchLabels: {app: shop}
  template:
    metadata:
      labels: {app: shop}
    spec:
      containers:
      - name: podinfo
        image: ghcr.io/stefanprodan/podinfo:6.17.0
        envFrom:
        - configMapRef: {name: shop-ui}
          prefix: PODINFO_                    # podinfo reads PODINFO_UI_MESSAGE, PODINFO_UI_COLOR
        - configMapRef: {name: shop-limits}
          prefix: SHOP_
        ports:
        - containerPort: 9898
EOF
workstation$ kubectl -n lab-05-02 rollout status deploy/shop
workstation$ kubectl -n lab-05-02 exec deploy/shop -- sh -c 'env | grep -E "^(PODINFO|SHOP)_" | sort'
workstation$ kubectl -n lab-05-02 exec deploy/shop -- sh -c 'curl -s localhost:9898 | grep -E "color|message"'
```

Expected:
```
PODINFO_UI_COLOR=#34577c
PODINFO_UI_MESSAGE=Autumn sale: -20% on keyboards
SHOP_CHECKOUT_TIMEOUT=30s
SHOP_MAX_CART_ITEMS=50
  "color": "#34577c",
  "message": "Autumn sale: -20% on keyboards",
```

2. Marketing updates the banner. Wait a minute or two (longer than a volume update would take) and check.

```bash
workstation$ kubectl -n lab-05-02 patch configmap shop-ui -p '{"data":{"UI_MESSAGE":"Black Friday: -40% on everything"}}'
workstation$ kubectl -n lab-05-02 exec deploy/shop -- sh -c 'curl -s localhost:9898 | grep message; printenv PODINFO_UI_MESSAGE'
```

Expected (nothing changed, and nothing ever will for this container):
```
  "message": "Autumn sale: -20% on keyboards",
Autumn sale: -20% on keyboards
```

> **Why:** the kubelet resolves `env`/`envFrom` once, when it creates the container, and a process's environment
> cannot be changed from outside. Only a new container sees the new value.

3. Roll out with `rollout restart`.

```bash
workstation$ kubectl -n lab-05-02 rollout restart deploy/shop
workstation$ kubectl -n lab-05-02 rollout status deploy/shop
workstation$ kubectl -n lab-05-02 exec deploy/shop -- sh -c 'curl -s localhost:9898 | grep message'
workstation$ kubectl -n lab-05-02 get deploy shop -o jsonpath='{.spec.template.metadata.annotations}{"\n"}'
```

Expected:
```
  "message": "Black Friday: -40% on everything",
{"kubectl.kubernetes.io/restartedAt":"2026-11-04T04:10:24+01:00"}
```

`rollout restart` is a rolling update triggered by a changed annotation. It works, but it restarts every time you run
it, even if nothing changed, and it depends on someone remembering to run it.

4. The checksum pattern ties the rollout to the content instead. Put a hash of the ConfigMaps' data into a Pod
   template annotation: same config, same hash, no rollout; changed config, new hash, rolling update.

```bash
workstation$ roll() {
  sum=$(kubectl -n lab-05-02 get configmap shop-ui shop-limits -o json | jq -S '[.items[] | .data]' | sha256sum | cut -c1-16)
  echo "config checksum: $sum"
  kubectl -n lab-05-02 patch deployment shop -p "{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"checksum/config\":\"$sum\"}}}}}"
}
workstation$ roll; kubectl -n lab-05-02 rollout status deploy/shop
workstation$ roll                                    # run it again without a change
workstation$ kubectl -n lab-05-02 rollout history deploy/shop
```

Expected (the first call rolls out once to record the hash, the second is a no-op):
```
config checksum: db9c05692a0619b5
deployment.apps/shop patched
config checksum: db9c05692a0619b5
deployment.apps/shop patched (no change)
REVISION  CHANGE-CAUSE
1         <none>
2         <none>
3         <none>
```

5. Change a limit and run the same function.

```bash
workstation$ kubectl -n lab-05-02 patch configmap shop-limits -p '{"data":{"MAX_CART_ITEMS":"100"}}'
workstation$ roll; kubectl -n lab-05-02 rollout status deploy/shop
workstation$ kubectl -n lab-05-02 rollout history deploy/shop | tail -2
workstation$ kubectl -n lab-05-02 exec deploy/shop -- printenv SHOP_MAX_CART_ITEMS
```

Expected:
```
config checksum: cebf269a0a85dfed
deployment.apps/shop patched
4         <none>

100
```

In Helm the same idea is one line in the chart:
`checksum/config: {{ include (print $.Template.BasePath "/configmap.yaml") . | sha256sum }}`. Lab 5.9 shows a third
way, generated ConfigMap names.

6. A typo in a ConfigMap name blocks the container from starting.

```bash
workstation$ kubectl -n lab-05-02 run typo --image=ghcr.io/stefanprodan/podinfo:6.17.0 \
  --overrides='{"spec":{"containers":[{"name":"typo","image":"ghcr.io/stefanprodan/podinfo:6.17.0","envFrom":[{"configMapRef":{"name":"shop-limit"}}]}]}}'
workstation$ kubectl -n lab-05-02 get pod typo
workstation$ kubectl -n lab-05-02 get events --field-selector involvedObject.name=typo | grep Failed
workstation$ kubectl -n lab-05-02 delete pod typo
```

Expected:
```
NAME   READY   STATUS                       RESTARTS   AGE
typo   0/1     CreateContainerConfigError   0          8s
Warning   Failed      pod/typo   Error: configmap "shop-limit" not found
```

### Clean up

```bash
workstation$ kubectl delete namespace lab-05-02
```

### Your turn

Create a Deployment `shop-canary` (labels `app: shop, track: canary`) that uses the same two ConfigMaps, but:
- its banner color is always `#e8b03f`, no matter what `shop-ui` says;
- it reads an **optional** ConfigMap `shop-canary-overrides` (prefix `PODINFO_`) that may not exist yet, and if it
  exists, its values beat `shop-ui`;
- it has a variable `CANARY_BANNER` = `canary: <the effective message>`.

Start it without the overrides ConfigMap, then create `shop-canary-overrides` with `UI_MESSAGE=Canary build - report
bugs to #shop` and `UI_COLOR=red`, roll it out and explain the color you get.

<details><summary>Solution</summary>

Precedence rules: within `envFrom`, a later source overwrites an earlier one; anything in `env` overwrites all of
`envFrom`. `$(VAR)` in `env` values expands variables defined before it, including those from `envFrom`.

```bash
workstation$ kubectl -n lab-05-02 apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: shop-canary
spec:
  replicas: 1
  selector:
    matchLabels: {app: shop, track: canary}
  template:
    metadata:
      labels: {app: shop, track: canary}
    spec:
      containers:
      - name: podinfo
        image: ghcr.io/stefanprodan/podinfo:6.17.0
        envFrom:
        - configMapRef: {name: shop-ui}
          prefix: PODINFO_
        - configMapRef: {name: shop-limits}
          prefix: SHOP_
        - configMapRef: {name: shop-canary-overrides, optional: true}   # may or may not exist
          prefix: PODINFO_
        env:
        - name: PODINFO_UI_COLOR                 # env always wins over envFrom
          value: "#e8b03f"
        - name: CANARY_BANNER
          value: "canary: $(PODINFO_UI_MESSAGE)"   # $(VAR) expands variables defined earlier
EOF
workstation$ kubectl -n lab-05-02 rollout status deploy/shop-canary
workstation$ kubectl -n lab-05-02 exec deploy/shop-canary -- sh -c 'curl -s localhost:9898 | grep -E "color|message"; printenv CANARY_BANNER'
```

Expected (the optional ConfigMap is missing, and the Pod starts anyway):
```
  "color": "#e8b03f",
  "message": "Black Friday: -40% on everything",
canary: Black Friday: -40% on everything
```

```bash
workstation$ kubectl -n lab-05-02 create configmap shop-canary-overrides \
  --from-literal=UI_MESSAGE="Canary build - report bugs to #shop" --from-literal=UI_COLOR=red
workstation$ kubectl -n lab-05-02 rollout restart deploy/shop-canary
workstation$ kubectl -n lab-05-02 rollout status deploy/shop-canary
workstation$ kubectl -n lab-05-02 exec deploy/shop-canary -- sh -c 'curl -s localhost:9898 | grep -E "color|message"; printenv CANARY_BANNER'
```

Expected:
```
  "color": "#e8b03f",
  "message": "Canary build - report bugs to #shop",
canary: Canary build - report bugs to #shop
```

The message comes from the overrides ConfigMap (last `envFrom` source), but the color stays `#e8b03f` because `env`
beats every `envFrom` source. The stable `shop` Deployment is unaffected.

</details>

---

## Lab 5.3: Feature flags that change without a restart

**Scenario** – The payments team ships a new checkout flow behind a feature flag. Product wants to switch it on (and,
if something goes wrong, off again) without a deployment. The flags live in a ConfigMap mounted as files, and the app
watches the directory. We measure how long a change takes to reach each replica and learn what this mechanism cannot
guarantee.

**What you'll learn**
- one file per ConfigMap key in a mounted directory, and apps that watch it
- the propagation delay of mounted ConfigMaps (kubelet sync period) and why replicas switch at different moments
- why apps must watch the **directory**, not the file (the `..data` symlink swap)
- what "eventually consistent" means for a kill switch

### Steps

1. Create the flags and the app. podinfo's `--config-path` watches a directory and serves its contents at
   `/configs`, which is exactly what a flag-aware app does.

```bash
workstation$ kubectl create namespace lab-05-03
workstation$ kubectl -n lab-05-03 apply -f - <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: feature-flags
data:
  checkout.new-payment-flow: "false"
  search.fuzzy-matching: "true"
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: shop
spec:
  replicas: 2
  selector:
    matchLabels: {app: shop}
  template:
    metadata:
      labels: {app: shop}
    spec:
      containers:
      - name: podinfo
        image: ghcr.io/stefanprodan/podinfo:6.17.0
        command: ["./podinfo", "--port=9898", "--config-path=/etc/flags"]
        volumeMounts:
        - {name: flags, mountPath: /etc/flags, readOnly: true}
      volumes:
      - name: flags
        configMap:
          name: feature-flags
EOF
workstation$ kubectl -n lab-05-03 rollout status deploy/shop
workstation$ kubectl -n lab-05-03 exec deploy/shop -- curl -s localhost:9898/configs; echo
workstation$ kubectl -n lab-05-03 logs deploy/shop | grep fscache
```

Expected:
```
{
  "checkout.new-payment-flow": "false",
  "search.fuzzy-matching": "true"
}
{"level":"info","ts":"2026-11-04T03:12:19.989Z","caller":"fscache/fscache.go:38","msg":"fscache start watcher for /etc/flags"}
```

2. Switch the flag on and poll both replicas every 3 seconds; print the moment each one sees the new value.

```bash
workstation$ kubectl -n lab-05-03 patch configmap feature-flags -p '{"data":{"checkout.new-payment-flow":"true"}}'; date -u +%T
workstation$ seen=""; for i in $(seq 1 40); do
  for p in $(kubectl -n lab-05-03 get pod -l app=shop -o name); do
    case "$seen" in *"$p"*) continue;; esac
    [ "$(kubectl -n lab-05-03 exec $p -- cat /etc/flags/checkout.new-payment-flow)" = true ] &&
      { echo "$(date -u +%T) $p sees true"; seen="$seen $p"; }
  done
  [ $(echo $seen | wc -w) -eq 2 ] && break; sleep 3
done
```

Expected:
```
configmap/feature-flags patched
03:12:27
03:13:29 pod/shop-77d7f59866-84qpv sees true
03:13:38 pod/shop-77d7f59866-5cr84 sees true
```

It took about a minute, and the two replicas switched 9 seconds apart.

3. Understand the delay. The kubelet does not push ConfigMap changes into volumes immediately; it refreshes them when
   it re-syncs the Pod, every `syncFrequency` (default 1 minute) plus jitter. Look at the node's kubelet
   configuration (read only):

```bash
node1$ sudo grep -E 'syncFrequency|configMapAndSecretChangeDetectionStrategy' /var/lib/kubelet/config.yaml
```

Expected:
```
syncFrequency: 0s
```

`0s` means "default", i.e. 1m, and the missing `configMapAndSecretChangeDetectionStrategy` means `Watch`: the kubelet
already knows the new content, it just writes it at the next sync. Shortening `syncFrequency` makes every kubelet do
more work; do not tune it for one app.

4. The app noticed the change by itself, because it watches the directory:

```bash
workstation$ kubectl -n lab-05-03 logs deploy/shop | grep 'fscache reload'
workstation$ kubectl -n lab-05-03 exec deploy/shop -- curl -s localhost:9898/configs; echo
```

Expected:
```
{"level":"info","ts":"2026-11-04T03:13:37.793Z","caller":"fscache/fscache.go:66","msg":"fscache reload /etc/flags"}
{
  "checkout.new-payment-flow": "true",
  "search.fuzzy-matching": "true"
}
```

> **Pitfall:** `/etc/flags/checkout.new-payment-flow` is a symlink to `..data/checkout.new-payment-flow`, and an
> update replaces `..data`, not the file. An app that put an inotify watch on the *file* never gets an event.
> Watch the directory (or simply re-read the file periodically).

### Clean up

```bash
workstation$ kubectl delete namespace lab-05-03
```

### Your turn

During an incident someone turns the new checkout **off** and, seconds later, back **on** by mistake. Did any replica
ever run with the flag off? Add a `flag-audit` sidecar that logs every value of `checkout.new-payment-flow` it sees
(and where `..data` points), checking once per second. Flip the flag `false` → `true` within 5 seconds, wait two
minutes, read the audit log; then set `false` once and compare. What does this mean for a kill switch?

<details><summary>Solution</summary>

```bash
workstation$ kubectl -n lab-05-03 apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: shop
spec:
  replicas: 2
  selector:
    matchLabels: {app: shop}
  template:
    metadata:
      labels: {app: shop}
    spec:
      containers:
      - name: podinfo
        image: ghcr.io/stefanprodan/podinfo:6.17.0
        command: ["./podinfo", "--port=9898", "--config-path=/etc/flags"]
        volumeMounts:
        - {name: flags, mountPath: /etc/flags, readOnly: true}
      - name: flag-audit
        image: busybox:1.38
        command:
        - sh
        - -c
        - |
          last=""
          while true; do
            now="$(cat /etc/flags/checkout.new-payment-flow)"
            if [ "$now" != "$last" ]; then
              echo "$(date -u +%T) checkout.new-payment-flow=$now (..data -> $(readlink /etc/flags/..data))"
              last="$now"
            fi
            sleep 1
          done
        resources:
          requests: {cpu: 5m, memory: 8Mi}
        volumeMounts:
        - {name: flags, mountPath: /etc/flags, readOnly: true}
      volumes:
      - name: flags
        configMap:
          name: feature-flags
EOF
workstation$ kubectl -n lab-05-03 rollout status deploy/shop
workstation$ kubectl -n lab-05-03 patch configmap feature-flags -p '{"data":{"checkout.new-payment-flow":"false"}}'; date -u +%T
workstation$ sleep 4
workstation$ kubectl -n lab-05-03 patch configmap feature-flags -p '{"data":{"checkout.new-payment-flow":"true"}}'; date -u +%T
workstation$ sleep 100; kubectl -n lab-05-03 logs -l app=shop -c flag-audit --prefix
```

Expected (the `false` was never written to any volume):
```
03:14:12
03:14:16
[pod/shop-5c74b7dc86-4vtxv/flag-audit] 03:14:05 checkout.new-payment-flow=true (..data -> ..2026_11_04_03_14_04.580421053)
[pod/shop-5c74b7dc86-qgpzj/flag-audit] 03:14:06 checkout.new-payment-flow=true (..data -> ..2026_11_04_03_14_05.2507281250)
```

Now a single change:

```bash
workstation$ kubectl -n lab-05-03 patch configmap feature-flags -p '{"data":{"checkout.new-payment-flow":"false"}}'; date -u +%T
workstation$ sleep 90; kubectl -n lab-05-03 logs -l app=shop -c flag-audit --prefix
```

Expected (each Pod switches once, at its own moment):
```
03:15:56
[pod/shop-5c74b7dc86-4vtxv/flag-audit] 03:14:05 checkout.new-payment-flow=true (..data -> ..2026_11_04_03_14_04.580421053)
[pod/shop-5c74b7dc86-4vtxv/flag-audit] 03:16:30 checkout.new-payment-flow=false (..data -> ..2026_11_04_03_16_29.3009727987)
[pod/shop-5c74b7dc86-qgpzj/flag-audit] 03:14:06 checkout.new-payment-flow=true (..data -> ..2026_11_04_03_14_05.2507281250)
[pod/shop-5c74b7dc86-qgpzj/flag-audit] 03:16:26 checkout.new-payment-flow=false (..data -> ..2026_11_04_03_16_25.1770206091)
```

The kubelet writes the *latest* state at its next sync, so intermediate values can be skipped entirely, and replicas
switch up to a minute apart. That is fine for gradual feature rollouts, but a kill switch that must act within seconds
on every replica needs a different channel: the app watching the ConfigMap through the API, or a flag service.

</details>

---

## Lab 5.4: Database credentials in an Opaque Secret

**Scenario** – The orders service and its Postgres database share a password that currently sits in plain text in a
Deployment manifest (as in Module 04). Security wants it out of the manifests, and the DBA wants to know how to rotate
it. We move the credentials into an Opaque Secret, see what "secret" really means for base64-encoded data, consume it
as environment variables and as files, and run a password rotation that goes wrong first.

**What you'll learn**
- `stringData` vs `data`, and why base64 is an encoding, not encryption
- `secretKeyRef` env variables vs. Secret volumes (tmpfs, `defaultMode`, live updates)
- why changing a Secret does not change the password inside the database
- `immutable: true` Secrets and the versioned-name pattern

### Steps

1. Create the Secret, the database and a client app. `stringData` lets you write plain text; the API server stores it
   base64-encoded in `data`. Postgres reads the credentials from env variables (only when it initialises an empty data
   directory). The client reads them from files and re-reads the password on every attempt.

```bash
workstation$ kubectl create namespace lab-05-04
workstation$ kubectl -n lab-05-04 apply -f - <<'EOF'
apiVersion: v1
kind: Secret
metadata:
  name: db-credentials
type: Opaque
stringData:                       # plain text in, base64 in storage
  username: orders
  password: "Kx9#mQ2v!Lw7"
  database: orders
---
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
        - name: POSTGRES_USER
          valueFrom: {secretKeyRef: {name: db-credentials, key: username}}
        - name: POSTGRES_PASSWORD
          valueFrom: {secretKeyRef: {name: db-credentials, key: password}}
        - name: POSTGRES_DB
          valueFrom: {secretKeyRef: {name: db-credentials, key: database}}
        readinessProbe:
          exec: {command: ["sh", "-c", "pg_isready -U $POSTGRES_USER"]}
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
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: orders-api
spec:
  selector:
    matchLabels: {app: orders-api}
  template:
    metadata:
      labels: {app: orders-api}
    spec:
      containers:
      - name: api
        image: postgres:17                # only for psql
        command:
        - bash
        - -c
        - |
          export PGUSER=$(cat /etc/db/username) PGDATABASE=$(cat /etc/db/database)
          while true; do
            export PGPASSWORD=$(cat /etc/db/password)    # re-read: the file follows Secret updates
            if psql -h postgres -tAc 'SELECT 1' >/dev/null 2>/tmp/err; then echo "$(date -u +%T) db OK"
            else echo "$(date -u +%T) db FAIL: $(tail -1 /tmp/err)"; fi
            sleep 5
          done
        volumeMounts:
        - {name: db, mountPath: /etc/db, readOnly: true}
      volumes:
      - name: db
        secret:
          secretName: db-credentials
          defaultMode: 0400
EOF
workstation$ kubectl -n lab-05-04 rollout status deploy/postgres
workstation$ kubectl -n lab-05-04 logs deploy/orders-api --tail=2
```

Expected (the first attempts may fail while Postgres starts):
```
03:18:20 db FAIL: 	Is the server running on that host and accepting TCP/IP connections?
03:18:25 db OK
```

2. Look at what is stored. Anyone who can `get` the Secret can read the password; base64 only makes binary data safe
   for JSON/YAML.

```bash
workstation$ kubectl -n lab-05-04 get secret db-credentials -o yaml | grep -A3 '^data'
workstation$ kubectl -n lab-05-04 get secret db-credentials -o jsonpath='{.data.password}' | base64 -d; echo
```

Expected:
```
data:
  database: b3JkZXJz
  password: S3g5I21RMnYhTHc3
  username: b3JkZXJz
Kx9#mQ2v!Lw7
```

> What actually protects a Secret: RBAC (who may `get`/`list` Secrets, Module 06), encryption at rest in etcd
> (Lab 5.10), and not printing it in logs. `kubectl describe` shows only sizes, but `kubectl exec ... env` in the Pod
> shows everything, so `pods/exec` is as sensitive as `secrets/get`.

3. `describe` hides env values from Secrets; the Secret volume is a **tmpfs**, so the files never touch the node's
   disk.

```bash
workstation$ kubectl -n lab-05-04 describe pod -l app=postgres | grep -A3 'Environment:'
workstation$ kubectl -n lab-05-04 exec deploy/orders-api -- sh -c 'mount | grep /etc/db; ls -l /etc/db/..data/'
```

Expected:
```
    Environment:
      POSTGRES_USER:      <set to the key 'username' in secret 'db-credentials'>  Optional: false
      POSTGRES_PASSWORD:  <set to the key 'password' in secret 'db-credentials'>  Optional: false
      POSTGRES_DB:        <set to the key 'database' in secret 'db-credentials'>  Optional: false
tmpfs on /etc/db type tmpfs (ro,relatime,size=16280936k,inode64,noswap)
-r-------- 1 root root  6 Nov  4 03:18 database
-r-------- 1 root root 12 Nov  4 03:18 password
-r-------- 1 root root  6 Nov  4 03:18 username
```

4. The DBA "rotates" the password by changing the Secret. Watch the client for two minutes.

```bash
workstation$ kubectl -n lab-05-04 patch secret db-credentials -p '{"stringData":{"password":"Rotated-2026-11"}}'
workstation$ sleep 90; kubectl -n lab-05-04 logs deploy/orders-api --tail=20 | uniq -c -f1 | tail -2
```

Expected:
```
     12 03:18:25 db OK
      8 03:19:26 db FAIL: psql: error: connection to server at "postgres" (10.110.13.70), port 5432 failed: FATAL:  password authentication failed for user "orders"
```

The client picked up the new password from its volume within a minute, but the database still has the old one.
`POSTGRES_PASSWORD` is only used by `initdb` on an empty data directory; the running Postgres container even still has
the old value in its environment:

```bash
workstation$ kubectl -n lab-05-04 exec deploy/postgres -- printenv POSTGRES_PASSWORD
```

Expected:
```
Kx9#mQ2v!Lw7
```

5. A Secret is just a copy of the credential. The source of truth is the database, so rotate it there.

```bash
workstation$ kubectl -n lab-05-04 exec deploy/postgres -- psql -U orders -d orders -c "ALTER USER orders PASSWORD 'Rotated-2026-11'"
workstation$ sleep 6; kubectl -n lab-05-04 logs deploy/orders-api --tail=1
```

Expected:
```
ALTER ROLE
03:20:22 db OK
```

6. Make the Secret immutable. The API server then rejects every change to its data (and the flag itself cannot be
   turned off); kubelets also stop watching it, which reduces API server load in large clusters.

```bash
workstation$ kubectl -n lab-05-04 patch secret db-credentials -p '{"immutable":true}'
workstation$ kubectl -n lab-05-04 patch secret db-credentials -p '{"stringData":{"password":"again"}}'
workstation$ kubectl -n lab-05-04 patch secret db-credentials -p '{"immutable":false}'
```

Expected:
```
secret/db-credentials patched
The Secret "db-credentials" is invalid: data: Forbidden: field is immutable when `immutable` is set
The Secret "db-credentials" is invalid: immutable: Forbidden: field is immutable when `immutable` is set
```

### Clean up

```bash
workstation$ kubectl delete namespace lab-05-04
```

### Your turn

With an immutable Secret, rotation means a **new** Secret. Rotate the password to `Nov-2026-b` using a versioned,
immutable Secret `db-credentials-v2`: change the password in the database, move `orders-api` to the new Secret with a
rolling update, delete the old Secret, and show that `v2` cannot be edited. Which Pods fail during the switch, and for
how long?

<details><summary>Solution</summary>

```bash
workstation$ kubectl -n lab-05-04 apply -f - <<'EOF'
apiVersion: v1
kind: Secret
metadata:
  name: db-credentials-v2
type: Opaque
immutable: true
stringData:
  username: orders
  password: "Nov-2026-b"
  database: orders
EOF
workstation$ kubectl -n lab-05-04 exec deploy/postgres -- psql -U orders -d orders -c "ALTER USER orders PASSWORD 'Nov-2026-b'"
workstation$ kubectl -n lab-05-04 patch deployment orders-api --type=json \
  -p '[{"op":"replace","path":"/spec/template/spec/volumes/0/secret/secretName","value":"db-credentials-v2"}]'
workstation$ kubectl -n lab-05-04 rollout status deploy/orders-api
workstation$ kubectl -n lab-05-04 logs -l app=orders-api --tail=2 --prefix
```

Expected:
```
secret/db-credentials-v2 created
ALTER ROLE
deployment "orders-api" successfully rolled out
[pod/orders-api-5dbcffb496-zvtb6/api] 03:22:33 db OK
[pod/orders-api-5dbcffb496-zvtb6/api] 03:22:38 db OK
[pod/orders-api-8655bb9767-njb94/api] 03:22:30 db FAIL: psql: error: ... password authentication failed for user "orders"
[pod/orders-api-8655bb9767-njb94/api] 03:22:35 db FAIL: psql: error: ... password authentication failed for user "orders"
```

```bash
workstation$ kubectl -n lab-05-04 delete secret db-credentials
workstation$ kubectl -n lab-05-04 patch secret db-credentials-v2 -p '{"stringData":{"password":"x"}}'
```

Expected:
```
secret "db-credentials" deleted from lab-05-04 namespace
The Secret "db-credentials-v2" is invalid: data: Forbidden: field is immutable when `immutable` is set
```

The old Pod (still using `v1`) fails from the `ALTER USER` until it is gone, i.e. for the duration of the rollout plus
its termination grace period (the shell loop ignores `SIGTERM`, so up to 30 s). Postgres has one password per role, so
truly zero-downtime rotation needs two roles (`orders_a`/`orders_b`) that you alternate, or a secrets manager that
does exactly that. Also update the `postgres` Deployment's `secretKeyRef`s to `v2` before you delete `v1`, or its next
restart fails with `CreateContainerConfigError`.

</details>

---

## Lab 5.5: HTTPS with a kubernetes.io/tls Secret and certificate rotation

**Scenario** – Internal traffic between services must be encrypted. The shop service gets a certificate from the
company's internal CA, and the certificate is short-lived, so rotation must be routine rather than an emergency. We
store the key pair as a `kubernetes.io/tls` Secret, serve HTTPS from nginx, distribute the CA certificate to clients as
a ConfigMap, and rotate the certificate without restarting the Pod.

**What you'll learn**
- creating a private CA and a server certificate with SANs using `openssl`
- `kubectl create secret tls`: the `tls.crt` / `tls.key` keys and the built-in validation
- trust bundles as ConfigMaps, and verifying TLS from inside the cluster with `curl`
- rotation: Secret update → file update in the Pod → server reload

### Steps

1. Create a CA and a short-lived (2 days) server certificate on your workstation. Clients verify the **SAN**, not the
   CN, so list every name the service is reached by.

```bash
workstation$ mkdir -p ~/lab-05-05 && cd ~/lab-05-05
workstation$ openssl req -x509 -new -nodes -newkey rsa:2048 -keyout ca.key -out ca.crt -days 365 -subj "/CN=Shop Internal CA"
workstation$ printf "subjectAltName=DNS:shop.lab-05-05.svc,DNS:shop.lab-05-05.svc.cluster.local\nextendedKeyUsage=serverAuth\n" > server.ext
workstation$ openssl req -new -nodes -newkey rsa:2048 -keyout tls-v1.key -out tls-v1.csr -subj "/CN=shop.lab-05-05.svc"
workstation$ openssl x509 -req -in tls-v1.csr -CA ca.crt -CAkey ca.key -CAcreateserial -days 2 -extfile server.ext -out tls-v1.crt
workstation$ openssl x509 -in tls-v1.crt -noout -enddate -ext subjectAltName
```

Expected:
```
notAfter=Nov  6 03:24:09 2026 GMT
X509v3 Subject Alternative Name:
    DNS:shop.lab-05-05.svc, DNS:shop.lab-05-05.svc.cluster.local
```

2. Store the key pair as a TLS Secret and the CA certificate (public, not secret) as a ConfigMap. `kubectl` checks that
   the key matches the certificate.

```bash
workstation$ kubectl create namespace lab-05-05
workstation$ kubectl -n lab-05-05 create secret tls shop-tls --cert=tls-v1.crt --key=tls-v1.key
workstation$ kubectl -n lab-05-05 create configmap shop-ca --from-file=ca.crt
workstation$ kubectl -n lab-05-05 get secret shop-tls
workstation$ kubectl -n lab-05-05 create secret tls broken --cert=tls-v1.crt --key=ca.key
```

Expected:
```
NAME       TYPE                DATA   AGE
shop-tls   kubernetes.io/tls   2      0s
error: tls: private key does not match public key
```

3. Run nginx with TLS. The Secret is mounted as a **directory** (never with `subPath`, or rotation cannot work).

```bash
workstation$ kubectl -n lab-05-05 apply -f - <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: shop-nginx
data:
  default.conf: |
    server {
      listen 443 ssl;
      server_name shop.lab-05-05.svc;
      ssl_certificate     /etc/tls/tls.crt;
      ssl_certificate_key /etc/tls/tls.key;
      ssl_protocols       TLSv1.2 TLSv1.3;
      location / { return 200 "secure shop\n"; }
    }
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: shop
spec:
  selector:
    matchLabels: {app: shop}
  template:
    metadata:
      labels: {app: shop}
    spec:
      containers:
      - name: nginx
        image: nginx:1.31-alpine
        ports:
        - containerPort: 443
        volumeMounts:
        - {name: conf, mountPath: /etc/nginx/conf.d, readOnly: true}
        - {name: tls, mountPath: /etc/tls, readOnly: true}
      volumes:
      - name: conf
        configMap: {name: shop-nginx}
      - name: tls
        secret:
          secretName: shop-tls
          defaultMode: 0400
---
apiVersion: v1
kind: Service
metadata:
  name: shop
spec:
  selector: {app: shop}
  ports:
  - port: 443
EOF
workstation$ kubectl -n lab-05-05 rollout status deploy/shop
```

4. Start a client Pod that has the CA bundle mounted, and call the service with and without it.

```bash
workstation$ kubectl -n lab-05-05 run client --image=curlimages/curl:8.23.0 --overrides='{"spec":{"containers":[{"name":"client","image":"curlimages/curl:8.23.0","command":["sleep","infinity"],"volumeMounts":[{"name":"ca","mountPath":"/etc/shop-ca"}]}],"volumes":[{"name":"ca","configMap":{"name":"shop-ca"}}]}}'
workstation$ kubectl -n lab-05-05 wait --for=condition=Ready pod/client
workstation$ kubectl -n lab-05-05 exec client -- curl -sS https://shop.lab-05-05.svc
workstation$ kubectl -n lab-05-05 exec client -- curl -sv --cacert /etc/shop-ca/ca.crt https://shop.lab-05-05.svc 2>&1 \
  | grep -E 'subject:|expire date|issuer|verify result|secure shop'
```

Expected:
```
curl: (60) SSL certificate OpenSSL verify result: unable to get local issuer certificate (20)
command terminated with exit code 60
*   subject: CN=shop.lab-05-05.svc
*   expire date: Nov  6 03:24:09 2026 GMT
*   issuer: CN=Shop Internal CA
* OpenSSL verify result: 0
secure shop
```

5. Rotate: issue a new 90-day certificate (new key, too) and replace the Secret's content in place.

```bash
workstation$ openssl req -new -nodes -newkey rsa:2048 -keyout tls-v2.key -out tls-v2.csr -subj "/CN=shop.lab-05-05.svc"
workstation$ openssl x509 -req -in tls-v2.csr -CA ca.crt -CAkey ca.key -CAcreateserial -days 90 -extfile server.ext -out tls-v2.crt
workstation$ kubectl -n lab-05-05 create secret tls shop-tls --cert=tls-v2.crt --key=tls-v2.key \
  --dry-run=client -o yaml | kubectl -n lab-05-05 apply -f -
workstation$ date -u +%T
```

6. Within about a minute the files in the Pod change. nginx, however, loaded the certificate at start-up and keeps
   serving the old one.

```bash
workstation$ kubectl -n lab-05-05 exec deploy/shop -- cat /etc/tls/tls.crt | openssl x509 -noout -enddate   # repeat until 2027
workstation$ kubectl -n lab-05-05 exec client -- curl -sv --cacert /etc/shop-ca/ca.crt https://shop.lab-05-05.svc 2>&1 | grep 'expire date'
```

Expected:
```
notAfter=Feb  2 03:24:39 2027 GMT
*   expire date: Nov  6 03:24:09 2026 GMT
```

7. Reload nginx, and the new certificate is live, with no dropped connections.

```bash
workstation$ kubectl -n lab-05-05 exec deploy/shop -- nginx -s reload
workstation$ kubectl -n lab-05-05 exec client -- curl -sv --cacert /etc/shop-ca/ca.crt https://shop.lab-05-05.svc 2>&1 | grep 'expire date'
```

Expected:
```
*   expire date: Feb  2 03:24:39 2027 GMT
```

> **Why the Secret update is atomic:** `tls.crt` and `tls.key` switch together with the `..data` link (Lab 5.1).
> Two separately updated files could leave nginx with a new certificate and an old key for a moment. In production,
> cert-manager renews the Secret automatically, and the server either reloads itself (Envoy, Traefik, Go apps with
> `GetCertificate`) or gets a reload sidecar like the one in Lab 5.1.

### Clean up

```bash
workstation$ kubectl delete namespace lab-05-05
workstation$ rm -rf ~/lab-05-05
```

### Your turn

The shop should accept requests only from known services (mutual TLS). Issue a **client** certificate for
`CN=orders-api,O=shop` from the same CA (`extendedKeyUsage=clientAuth`), store it as a TLS Secret
`orders-api-client-tls`, configure nginx to require and verify client certificates, and greet the caller with its
certificate subject. Prove it with a Pod `orders-api` that calls the shop once without and once with its client
certificate.

<details><summary>Solution</summary>

```bash
workstation$ cd ~/lab-05-05
workstation$ printf "extendedKeyUsage=clientAuth\n" > client.ext
workstation$ openssl req -new -nodes -newkey rsa:2048 -keyout client.key -out client.csr -subj "/O=shop/CN=orders-api"
workstation$ openssl x509 -req -in client.csr -CA ca.crt -CAkey ca.key -CAcreateserial -days 30 -extfile client.ext -out client.crt
workstation$ kubectl -n lab-05-05 create secret tls orders-api-client-tls --cert=client.crt --key=client.key
workstation$ kubectl -n lab-05-05 apply -f - <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: shop-nginx
data:
  default.conf: |
    server {
      listen 443 ssl;
      server_name shop.lab-05-05.svc;
      ssl_certificate        /etc/tls/tls.crt;
      ssl_certificate_key    /etc/tls/tls.key;
      ssl_client_certificate /etc/shop-ca/ca.crt;   # trust client certs signed by our CA
      ssl_verify_client      on;
      location / { return 200 "secure shop, hello $ssl_client_s_dn\n"; }
    }
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: shop
spec:
  selector:
    matchLabels: {app: shop}
  template:
    metadata:
      labels: {app: shop}
    spec:
      containers:
      - name: nginx
        image: nginx:1.31-alpine
        ports:
        - containerPort: 443
        volumeMounts:
        - {name: conf, mountPath: /etc/nginx/conf.d, readOnly: true}
        - {name: tls, mountPath: /etc/tls, readOnly: true}
        - {name: ca, mountPath: /etc/shop-ca, readOnly: true}
      volumes:
      - name: conf
        configMap: {name: shop-nginx}
      - name: tls
        secret: {secretName: shop-tls, defaultMode: 0400}
      - name: ca
        configMap: {name: shop-ca}
---
apiVersion: v1
kind: Pod
metadata:
  name: orders-api
spec:
  containers:
  - name: client
    image: curlimages/curl:8.23.0
    command: ["sleep", "infinity"]
    volumeMounts:
    - {name: ca, mountPath: /etc/shop-ca, readOnly: true}
    - {name: client-tls, mountPath: /etc/client-tls, readOnly: true}
  volumes:
  - name: ca
    configMap: {name: shop-ca}
  - name: client-tls
    secret: {secretName: orders-api-client-tls}
EOF
workstation$ kubectl -n lab-05-05 rollout status deploy/shop
workstation$ kubectl -n lab-05-05 wait --for=condition=Ready pod/orders-api
workstation$ kubectl -n lab-05-05 exec orders-api -- curl -sS --cacert /etc/shop-ca/ca.crt https://shop.lab-05-05.svc | grep -o '<title>.*</title>'
workstation$ kubectl -n lab-05-05 exec orders-api -- curl -sS --cacert /etc/shop-ca/ca.crt \
  --cert /etc/client-tls/tls.crt --key /etc/client-tls/tls.key https://shop.lab-05-05.svc
```

Expected:
```
<title>400 No required SSL certificate was sent</title>
secure shop, hello CN=orders-api,O=shop
```

The ConfigMap change made the Deployment roll (a new volume in the template), so no reload was needed. Note that every
client certificate signed by this CA is accepted; to allow only some services, check `$ssl_client_s_dn` in nginx, or
use a dedicated CA per trust domain. Service meshes automate exactly this certificate handling.

</details>

---

## Lab 5.6: Pull from a private registry with imagePullSecrets on a ServiceAccount

**Scenario** – The company's images live behind a registry login, and anonymous Docker Hub pulls are rate-limited, so
every node pull must use the CI robot account. Putting `imagePullSecrets` into every Pod spec does not scale and is
easy to forget. Instead we attach the credentials to the ServiceAccount the workloads run as. We prove that the
kubelet really uses them by giving it **wrong** credentials and watching Docker Hub reject the pull.

**What you'll learn**
- the `kubernetes.io/dockerconfigjson` Secret type and what is inside it
- `imagePullSecrets` on a ServiceAccount, injected into Pods by the ServiceAccount admission plugin
- credentials are matched per registry host
- rotating registry credentials in place

### Steps

1. Create the namespace and a registry Secret for Docker Hub. The password here is deliberately wrong.

```bash
workstation$ kubectl create namespace lab-05-06
workstation$ kubectl -n lab-05-06 create secret docker-registry dockerhub-ci \
  --docker-server=https://index.docker.io/v1/ \
  --docker-username=lab-05-06-bot --docker-password=not-the-real-token --docker-email=ci@example.com
```

2. Look inside. It is the same JSON that `docker login` writes to `~/.docker/config.json`, and `auth` is just
   `user:password` in base64.

```bash
workstation$ kubectl -n lab-05-06 get secret dockerhub-ci -o jsonpath='{.type}{"\n"}'
workstation$ kubectl -n lab-05-06 get secret dockerhub-ci -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d | jq .
workstation$ echo bGFiLTA1LTA2LWJvdDpub3QtdGhlLXJlYWwtdG9rZW4= | base64 -d; echo
```

Expected:
```
kubernetes.io/dockerconfigjson
{
  "auths": {
    "https://index.docker.io/v1/": {
      "username": "lab-05-06-bot",
      "password": "not-the-real-token",
      "email": "ci@example.com",
      "auth": "bGFiLTA1LTA2LWJvdDpub3QtdGhlLXJlYWwtdG9rZW4="
    }
  }
}
lab-05-06-bot:not-the-real-token
```

If you already ran `docker login` on your machine, `kubectl create secret generic regcred
--type=kubernetes.io/dockerconfigjson --from-file=.dockerconfigjson=$HOME/.docker/config.json` turns that file into a
Secret, but check first that it does not contain credentials for other registries.

3. Create the ServiceAccount for the app and attach the Secret to it.

```bash
workstation$ kubectl -n lab-05-06 create serviceaccount shop-api
workstation$ kubectl -n lab-05-06 patch serviceaccount shop-api -p '{"imagePullSecrets":[{"name":"dockerhub-ci"}]}'
```

4. Start a Pod as `shop-api`. `imagePullPolicy: Always` makes the kubelet contact the registry even if the image is
   already cached on the node.

```bash
workstation$ kubectl -n lab-05-06 run api --image=traefik/whoami:v1.12.0 --image-pull-policy=Always \
  --overrides='{"spec":{"serviceAccountName":"shop-api"}}'
workstation$ kubectl -n lab-05-06 get pod api
workstation$ kubectl -n lab-05-06 get pod api -o jsonpath='{.spec.imagePullSecrets}{"\n"}'
workstation$ kubectl -n lab-05-06 get events --field-selector involvedObject.name=api | grep -m1 Failed
```

Expected:
```
NAME   READY   STATUS         RESTARTS   AGE
api    0/1     ErrImagePull   0          12s
[{"name":"dockerhub-ci"}]
Warning   Failed   pod/api   Failed to pull image "traefik/whoami:v1.12.0": ... fetching manifest v1.12.0 in docker.io/traefik/whoami: unable to retrieve auth token: invalid username/password: unauthorized: incorrect username or password ...
```

The Pod spec never mentioned the Secret; the admission plugin copied it from the ServiceAccount when the Pod was
created. And the image is public: without credentials the pull would have worked. With bad credentials Docker Hub
refuses, which proves the kubelet used them.

5. Credentials are selected by registry host. The same ServiceAccount pulls from `registry.k8s.io` without problems,
   because the Secret has no entry for that host.

```bash
workstation$ kubectl -n lab-05-06 run sync --image=registry.k8s.io/git-sync/git-sync:v4.8.0 --image-pull-policy=Always \
  --restart=Never --overrides='{"spec":{"serviceAccountName":"shop-api"}}' -- --version
workstation$ kubectl -n lab-05-06 logs sync | tail -1          # after a few seconds
```

Expected:
```
v4.8.0
```

> **Pitfalls:** `imagePullSecrets` on a ServiceAccount affect only Pods created **after** the change, and only Pods
> in that namespace (Secrets cannot be referenced across namespaces). The Secret is read at pull time, so fixing the
> Secret is enough; the failing Pod picks it up on its next back-off retry.

### Clean up

```bash
workstation$ kubectl delete namespace lab-05-06
```

### Your turn

The platform team moves the images to the company registry `registry.shop.example:5000` (user `shop-ci`, password
`s3cr3t`) and wants the Docker Hub entry gone. Write the `.dockerconfigjson` by hand, replace the contents of
`dockerhub-ci` in place (the ServiceAccount keeps referencing the same name), and show that the `api` Pod (recreate
it) now starts. What does the API server do if the JSON is malformed?

<details><summary>Solution</summary>

```bash
workstation$ cat > /tmp/config.json <<EOF
{
  "auths": {
    "registry.shop.example:5000": {
      "auth": "$(printf 'shop-ci:s3cr3t' | base64)"
    }
  }
}
EOF
workstation$ kubectl -n lab-05-06 create secret generic dockerhub-ci --type=kubernetes.io/dockerconfigjson \
  --from-file=.dockerconfigjson=/tmp/config.json --dry-run=client -o yaml | kubectl -n lab-05-06 apply -f -
workstation$ rm /tmp/config.json
workstation$ kubectl -n lab-05-06 delete pod api
workstation$ kubectl -n lab-05-06 run api --image=traefik/whoami:v1.12.0 --image-pull-policy=Always \
  --overrides='{"spec":{"serviceAccountName":"shop-api"}}'
workstation$ kubectl -n lab-05-06 wait --for=condition=Ready pod/api
workstation$ kubectl -n lab-05-06 get secret dockerhub-ci -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d
```

Expected:
```
secret/dockerhub-ci configured
pod/api condition met
{
  "auths": {
    "registry.shop.example:5000": {
      "auth": "c2hvcC1jaTpzM2NyM3Q="
    }
  }
}
```

No entry matches `docker.io` any more, so the public image is pulled anonymously. A typed Secret is validated:

```bash
workstation$ kubectl -n lab-05-06 create secret generic broken --type=kubernetes.io/dockerconfigjson \
  --from-literal=.dockerconfigjson='{"auths": {'
```

Expected:
```
error: failed to create secret Secret "broken" is invalid: data[.dockerconfigjson]: Invalid value: "<secret contents redacted>": unexpected end of JSON input
```

Real-world follow-ups: use short-lived registry tokens (cloud registries, or a CronJob that refreshes the Secret), and
remember that an image cached on a node can be started by any Pod on that node with `imagePullPolicy: IfNotPresent`.
Kubelet's image pull credential verification (`imagePullCredentialsVerificationPolicy`) or the `AlwaysPullImages`
admission plugin closes that gap.

</details>

---

## Lab 5.7: Protect an internal tool with a basic-auth Secret

**Scenario** – An internal admin dashboard has no login of its own, and it must not be reachable without a password,
even from inside the cluster. We put an nginx auth proxy next to it in the same Pod. The credentials live in a
`kubernetes.io/basic-auth` Secret, and nginx needs them as an `htpasswd` file with a hashed password, so an init
container converts one into the other at start-up.

**What you'll learn**
- the `kubernetes.io/basic-auth` Secret type and its validation
- generating derived files from Secrets in an init container (into a memory-backed `emptyDir`)
- the auth-proxy sidecar pattern, and binding the app to `127.0.0.1` so it cannot be bypassed
- why the derived file does not follow Secret updates

### Steps

1. Create the namespace, the Secret, the proxy config, the Deployment and a Service. The app listens on `127.0.0.1`
   only, so the one way in is through nginx on port 80.

```bash
workstation$ kubectl create namespace lab-05-07
workstation$ kubectl -n lab-05-07 apply -f - <<'EOF'
apiVersion: v1
kind: Secret
metadata:
  name: admin-ui-credentials
type: kubernetes.io/basic-auth
stringData:
  username: ops
  password: "Corr3ct-Horse-Battery"
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: auth-proxy
data:
  default.conf: |
    server {
      listen 80;
      location / {
        auth_basic           "Shop admin";
        auth_basic_user_file /etc/nginx/auth/htpasswd;
        proxy_pass           http://127.0.0.1:9898;
        proxy_set_header     Authorization "";       # do not forward the password to the app
      }
    }
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: admin-ui
spec:
  selector:
    matchLabels: {app: admin-ui}
  template:
    metadata:
      labels: {app: admin-ui}
    spec:
      initContainers:
      - name: htpasswd
        image: busybox:1.38
        command:
        - sh
        - -c
        - |
          set -e
          printf '%s:%s\n' "$(cat /creds/username)" "$(cryptpw -m sha512 < /creds/password)" > /auth/htpasswd
          chmod 0444 /auth/htpasswd
          echo "htpasswd entry created for $(cat /creds/username)"
        volumeMounts:
        - {name: creds, mountPath: /creds, readOnly: true}
        - {name: auth, mountPath: /auth}
      containers:
      - name: app                                 # the tool we protect; listens on localhost only
        image: ghcr.io/stefanprodan/podinfo:6.17.0
        command: ["./podinfo", "--port=9898", "--host=127.0.0.1"]
      - name: auth-proxy
        image: nginx:1.31-alpine
        ports:
        - containerPort: 80
        volumeMounts:
        - {name: proxy-conf, mountPath: /etc/nginx/conf.d, readOnly: true}
        - {name: auth, mountPath: /etc/nginx/auth, readOnly: true}
      volumes:
      - name: creds
        secret: {secretName: admin-ui-credentials}
      - name: auth                                # the hash never touches the node's disk
        emptyDir: {medium: Memory, sizeLimit: 1Mi}
      - name: proxy-conf
        configMap: {name: auth-proxy}
---
apiVersion: v1
kind: Service
metadata:
  name: admin-ui
spec:
  selector: {app: admin-ui}
  ports:
  - port: 80
EOF
workstation$ kubectl -n lab-05-07 rollout status deploy/admin-ui
workstation$ kubectl -n lab-05-07 logs deploy/admin-ui -c htpasswd
workstation$ kubectl -n lab-05-07 exec deploy/admin-ui -c auth-proxy -- cat /etc/nginx/auth/htpasswd
```

Expected (a salted SHA-512 crypt hash; the plain password is not in the file):
```
htpasswd entry created for ops
ops:$6$U4PFNr2PzT6Ee7qh$FY4haweO8S8CeUCAYSR/D6.jvlZsAs4MreGr3a8MG7syR8O2NOxGjofmtm3IK6d9MKCCa1W8XSWjsW0GmwViE0
```

> **Why `< /creds/password`?** Passing the password as a command-line argument would make it visible in the process
> list of the node for a moment. `cryptpw` reads it from stdin instead.

2. Test from a client Pod: no credentials, wrong credentials, correct credentials.

```bash
workstation$ kubectl -n lab-05-07 run curl --image=curlimages/curl:8.23.0 --command -- sleep infinity
workstation$ kubectl -n lab-05-07 wait --for=condition=Ready pod/curl
workstation$ kubectl -n lab-05-07 exec curl -- curl -s -o /dev/null -w '%{http_code} no credentials\n' http://admin-ui
workstation$ kubectl -n lab-05-07 exec curl -- curl -s -o /dev/null -w '%{http_code} wrong password\n' -u ops:guess http://admin-ui
workstation$ kubectl -n lab-05-07 exec curl -- curl -s -u ops:Corr3ct-Horse-Battery http://admin-ui | head -3
```

Expected:
```
401 no credentials
401 wrong password
{
  "hostname": "admin-ui-69dff5d67-n76mj",
  "version": "6.17.0",
```

3. Try to bypass the proxy and talk to the app directly on its Pod IP.

```bash
workstation$ POD_IP=$(kubectl -n lab-05-07 get pod -l app=admin-ui -o jsonpath='{.items[0].status.podIP}')
workstation$ kubectl -n lab-05-07 exec curl -- curl -sS -m 3 http://$POD_IP:9898
```

Expected:
```
curl: (7) Failed to connect to 172.16.104.14:9898 after 0 ms: Could not connect to server
```

Containers of a Pod share the network namespace, so nginx reaches the app on `127.0.0.1`, while nobody outside the
Pod can. Without `--host=127.0.0.1` the auth proxy would be decoration.

4. The Secret type is validated: a `basic-auth` Secret must have `username` or `password`.

```bash
workstation$ kubectl -n lab-05-07 create secret generic bad --type=kubernetes.io/basic-auth --from-literal=user=ops
```

Expected:
```
error: failed to create secret Secret "bad" is invalid: [data[username]: Required value, data[password]: Required value]
```

Basic auth sends the password with every request (base64, not encrypted). Use it only over TLS (Lab 5.5) or inside a
trusted network, as here.

### Clean up

```bash
workstation$ kubectl delete namespace lab-05-07
```

### Your turn

An external auditor needs access as well, with credentials of their own in a separate basic-auth Secret
`admin-ui-auditor` (user `auditor`, password `Read-0nly-2026`), so that you can revoke them independently. Extend the
init container to build `htpasswd` from **all** mounted credential Secrets, and verify that both users get 200. Then
change the `ops` password to `N3w-Horse-2026` in its Secret, wait two minutes, and test the old and the new password.
Explain the result and fix it.

<details><summary>Solution</summary>

```bash
workstation$ kubectl -n lab-05-07 create secret generic admin-ui-auditor --type=kubernetes.io/basic-auth \
  --from-literal=username=auditor --from-literal=password='Read-0nly-2026'
```

Mount each Secret into its own sub-directory and loop over them. Change these parts of the Deployment and apply it:

```yaml
      initContainers:
      - name: htpasswd
        image: busybox:1.38
        command:
        - sh
        - -c
        - |
          set -e
          : > /auth/htpasswd
          for d in /creds/*/; do                        # one directory per basic-auth Secret
            printf '%s:%s\n' "$(cat $d/username)" "$(cryptpw -m sha512 < $d/password)" >> /auth/htpasswd
            echo "htpasswd entry created for $(cat $d/username)"
          done
          chmod 0444 /auth/htpasswd
        volumeMounts:
        - {name: creds-ops, mountPath: /creds/ops, readOnly: true}
        - {name: creds-auditor, mountPath: /creds/auditor, readOnly: true}
        - {name: auth, mountPath: /auth}
...
      volumes:
      - name: creds-ops
        secret: {secretName: admin-ui-credentials}
      - name: creds-auditor
        secret: {secretName: admin-ui-auditor}
```

```bash
workstation$ kubectl -n lab-05-07 rollout status deploy/admin-ui
workstation$ kubectl -n lab-05-07 logs deploy/admin-ui -c htpasswd
workstation$ for u in ops:Corr3ct-Horse-Battery auditor:Read-0nly-2026; do
  kubectl -n lab-05-07 exec curl -- curl -s -o /dev/null -w "%{http_code} ${u%%:*}\n" -u "$u" http://admin-ui
done
```

Expected:
```
htpasswd entry created for auditor
htpasswd entry created for ops
200 ops
200 auditor
```

Rotate the `ops` password:

```bash
workstation$ kubectl -n lab-05-07 patch secret admin-ui-credentials -p '{"stringData":{"password":"N3w-Horse-2026"}}'
workstation$ sleep 120
workstation$ for u in ops:Corr3ct-Horse-Battery ops:N3w-Horse-2026; do
  kubectl -n lab-05-07 exec curl -- curl -s -o /dev/null -w "%{http_code} $u\n" -u "$u" http://admin-ui
done
```

Expected (the **old** password still works):
```
200 ops:Corr3ct-Horse-Battery
401 ops:N3w-Horse-2026
```

The Secret volume in `/creds/ops` was updated, but nobody reads it any more: the init container ran once, when the Pod
started, and `htpasswd` is a derived copy. Restart the Pods to re-derive it (or use the checksum pattern from Lab 5.2
to do it automatically):

```bash
workstation$ kubectl -n lab-05-07 rollout restart deploy/admin-ui
workstation$ kubectl -n lab-05-07 rollout status deploy/admin-ui
workstation$ for u in ops:Corr3ct-Horse-Battery ops:N3w-Horse-2026; do
  kubectl -n lab-05-07 exec curl -- curl -s -o /dev/null -w "%{http_code} $u\n" -u "$u" http://admin-ui
done
```

Expected:
```
401 ops:Corr3ct-Horse-Battery
200 ops:N3w-Horse-2026
```

Revoking the auditor works the same way: delete the Secret and its volume from the Deployment, then roll out.

</details>

---

## Lab 5.8: One directory for everything: projected volumes

**Scenario** – The checkout service was written for VMs and expects everything under `/etc/app`: its config file,
its API key, facts about itself (tenant, build number, memory limit) and a token for calling the payment provider.
Four separate mounts would not fit into one directory. A **projected volume** combines a ConfigMap, a Secret, Downward
API fields and a ServiceAccount token with a custom audience into a single directory with chosen file names and
permissions.

**What you'll learn**
- `projected` sources: `configMap`, `secret`, `downwardAPI`, `serviceAccountToken`
- `items` to rename and select keys, `defaultMode` and per-item `mode`, and how `fsGroup` changes them
- Downward API fields and resources (with `divisor`), and live label updates
- bound ServiceAccount tokens: audience, expiry, binding to the Pod
- `automountServiceAccountToken: false` to drop the default API token

### Steps

1. Create the ServiceAccount (without the default token mount), the config, the Secret and the Pod.

```bash
workstation$ kubectl create namespace lab-05-08
workstation$ kubectl -n lab-05-08 apply -f - <<'EOF'
apiVersion: v1
kind: ServiceAccount
metadata:
  name: checkout
automountServiceAccountToken: false
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: checkout-config
data:
  app.yaml: |
    currency: EUR
    paymentProvider: https://payments.shop.example
  unused.txt: "not projected"
---
apiVersion: v1
kind: Secret
metadata:
  name: checkout-secrets
type: Opaque
stringData:
  api-key: "pk_live_9f8e7d6c5b4a"
  webhook-secret: "whsec_0a1b2c3d"
---
apiVersion: v1
kind: Pod
metadata:
  name: checkout
  labels:
    app: checkout
    tenant: acme
    region: eu-central
  annotations:
    shop.example/build: "2026.11.4-1"
spec:
  serviceAccountName: checkout
  securityContext:
    runAsUser: 1000
    runAsGroup: 1000
    fsGroup: 1000
  containers:
  - name: app
    image: busybox:1.38
    command: ["sleep", "infinity"]
    resources:
      requests: {cpu: 250m, memory: 64Mi}
      limits:   {cpu: 500m, memory: 128Mi}
    volumeMounts:
    - {name: app, mountPath: /etc/app, readOnly: true}
  volumes:
  - name: app
    projected:
      defaultMode: 0440                     # owner + group (fsGroup) may read
      sources:
      - configMap:
          name: checkout-config
          items:
          - {key: app.yaml, path: config.yaml}             # renamed, unused.txt is left out
      - secret:
          name: checkout-secrets
          items:
          - {key: api-key, path: secrets/api-key, mode: 0400}   # webhook-secret is left out
      - downwardAPI:
          items:
          - {path: pod/name, fieldRef: {fieldPath: metadata.name}}
          - {path: pod/labels, fieldRef: {fieldPath: metadata.labels}}
          - {path: pod/build, fieldRef: {fieldPath: "metadata.annotations['shop.example/build']"}}
          - path: pod/memory-limit-mi
            resourceFieldRef: {containerName: app, resource: limits.memory, divisor: 1Mi}
          - path: pod/cpu-limit-millicores
            resourceFieldRef: {containerName: app, resource: limits.cpu, divisor: 1m}
      - serviceAccountToken:
          path: tokens/payments
          audience: payments.shop.example     # only valid for this audience
          expirationSeconds: 3600
EOF
workstation$ kubectl -n lab-05-08 wait --for=condition=Ready pod/checkout
```

2. Look at the directory and the file permissions.

```bash
workstation$ kubectl -n lab-05-08 exec checkout -- ls -lL /etc/app /etc/app/secrets /etc/app/tokens
```

Expected:
```
/etc/app:
-r--r-----    1 root     1000            61 Nov  4 03:30 config.yaml
drwxr-sr-x    2 root     1000           140 Nov  4 03:30 pod
drwxr-sr-x    2 root     1000            60 Nov  4 03:30 secrets
drwxr-sr-x    2 root     1000            60 Nov  4 03:30 tokens

/etc/app/secrets:
-r--r-----    1 root     1000            20 Nov  4 03:30 api-key

/etc/app/tokens:
-rw-r-----    1 1000     1000          1094 Nov  4 03:30 payments
```

> **Pitfall:** `api-key` asked for `mode: 0400` but got `0440`. With `fsGroup` set, the kubelet makes every file
> group-readable so that the `fsGroup` can read it. Without `fsGroup`, a file owned by root with mode `0400` would not
> be readable by UID 1000 at all, so the two settings must be planned together.

3. Read the files the app sees.

```bash
workstation$ kubectl -n lab-05-08 exec checkout -- sh -c 'cd /etc/app
  for f in config.yaml pod/name pod/labels pod/build pod/memory-limit-mi pod/cpu-limit-millicores; do
    echo "== $f"; cat $f; echo
  done'
```

Expected:
```
== config.yaml
currency: EUR
paymentProvider: https://payments.shop.example

== pod/name
checkout
== pod/labels
app="checkout"
region="eu-central"
tenant="acme"
== pod/build
2026.11.4-1
== pod/memory-limit-mi
128
== pod/cpu-limit-millicores
500
```

Why `metadata.annotations['shop.example/build']` and not all annotations? The full set includes whatever tools add,
for example Calico's Pod IP and `kubectl.kubernetes.io/last-applied-configuration`, which is the entire manifest.

4. Decode the payload of the projected token (it is a JWT; only the signature part is secret-ish).

```bash
workstation$ kubectl -n lab-05-08 exec checkout -- cat /etc/app/tokens/payments \
  | jq -R 'split(".")[1] | @base64d | fromjson | {aud, exp, iat, sub, pod: .["kubernetes.io"].pod.name}'
workstation$ kubectl -n lab-05-08 exec checkout -- ls /var/run/secrets/kubernetes.io/serviceaccount
```

Expected:
```
{
  "aud": [
    "payments.shop.example"
  ],
  "exp": 1793766627,
  "iat": 1793763027,
  "sub": "system:serviceaccount:lab-05-08:checkout",
  "pod": "checkout"
}
ls: /var/run/secrets/kubernetes.io/serviceaccount: No such file or directory
```

The token is valid for one hour (`exp - iat = 3600`), only for the audience `payments.shop.example`, and bound to this
Pod. The kubelet refreshes it automatically when 80 % of its lifetime has passed, so the app must re-read the file
instead of caching it forever. Because of `automountServiceAccountToken: false` there is no Kubernetes API token in
the Pod at all.

5. Labels and annotations in a Downward API volume are updated live (environment variables would not be).

```bash
workstation$ kubectl -n lab-05-08 label pod checkout tenant=globex --overwrite
workstation$ sleep 70; kubectl -n lab-05-08 exec checkout -- cat /etc/app/pod/labels; echo
```

Expected:
```
app="checkout"
region="eu-central"
tenant="globex"
```

### Clean up

```bash
workstation$ kubectl delete namespace lab-05-08
```

### Your turn

The payment provider runs its own service in the cluster and must decide whether a call really comes from the
checkout Pod. It cannot verify the token offline without the cluster's keys, so it asks the API server with a
`TokenReview`. Submit a TokenReview for the projected token (as cluster-admin) once with the audience
`payments.shop.example` and once with the API server's default audience
`https://kubernetes.default.svc.cluster.local`. Then delete the Pod and review the same token again. Explain all
three answers.

<details><summary>Solution</summary>

```bash
workstation$ TOKEN=$(kubectl -n lab-05-08 exec checkout -- cat /etc/app/tokens/payments)
workstation$ review() {
  kubectl create -o json -f - <<EOF | jq -c '.status | {authenticated, user: .user.username, audiences, pod: .user.extra["authentication.kubernetes.io/pod-name"], error}'
apiVersion: authentication.k8s.io/v1
kind: TokenReview
spec:
  token: $TOKEN
  audiences: ["$1"]
EOF
}
workstation$ review payments.shop.example
workstation$ review https://kubernetes.default.svc.cluster.local
workstation$ kubectl -n lab-05-08 delete pod checkout
workstation$ review payments.shop.example
```

Expected:
```
{"authenticated":true,"user":"system:serviceaccount:lab-05-08:checkout","audiences":["payments.shop.example"],"pod":["checkout"],"error":null}
{"authenticated":null,"user":null,"audiences":null,"pod":null,"error":"[invalid bearer token, token audiences [\"payments.shop.example\"] is invalid for the target audiences [\"https://kubernetes.default.svc.cluster.local\"]]"}
pod "checkout" deleted from lab-05-08 namespace
{"authenticated":null,"user":null,"audiences":null,"pod":null,"error":"[invalid bearer token, service account token has been invalidated]"}
```

1. Valid: right audience, and the review even tells the provider *which Pod* sent it.
2. Rejected: a token minted for the payment provider cannot be replayed against the Kubernetes API (or any other
   audience). If the provider leaks it, the cluster is not exposed.
3. Rejected: a bound token dies with its Pod, long before `exp`. Compare that with the old long-lived token Secrets,
   which stayed valid until someone deleted them.

In a real setup the provider's ServiceAccount needs RBAC permission `create` on `tokenreviews` (ClusterRole
`system:auth-delegator`), and it can alternatively verify tokens offline through the API server's OIDC discovery
endpoint (`/.well-known/openid-configuration`).

</details>

---

## Lab 5.9: Safe config rollouts with Kustomize configMapGenerator

**Scenario** – The shop team keeps its manifests in Git and wants two guarantees: every config change rolls the Pods
automatically (no forgotten `rollout restart`, Lab 5.2), and a bad config can be rolled back as quickly as a bad image.
Kustomize's `configMapGenerator` gives both: it names each ConfigMap after a hash of its content and rewrites every
reference to it.

**What you'll learn**
- `kustomization.yaml` with `configMapGenerator` (literals and files) and `kubectl apply -k`
- hash-suffixed names: new content → new ConfigMap → changed Pod template → rolling update
- why `kubectl rollout undo` now also rolls back the config
- a YAML pitfall in literals, and the clean-up problem of old generated ConfigMaps

### Steps

1. Create the base directory with a Deployment, a pricing file and the kustomization. The Deployment references the
   ConfigMaps by their plain names.

```bash
workstation$ mkdir -p ~/lab-05-09/shop && cd ~/lab-05-09/shop
workstation$ cat > deployment.yaml <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: shop
spec:
  replicas: 2
  selector:
    matchLabels: {app: shop}
  template:
    metadata:
      labels: {app: shop}
    spec:
      containers:
      - name: podinfo
        image: ghcr.io/stefanprodan/podinfo:6.17.0
        envFrom:
        - configMapRef: {name: shop-config}      # kustomize rewrites this to shop-config-<hash>
          prefix: PODINFO_
        volumeMounts:
        - {name: pricing, mountPath: /etc/pricing}
      volumes:
      - name: pricing
        configMap: {name: shop-pricing}          # ... and this one too
EOF
workstation$ cat > pricing.yaml <<'EOF'
vat: 0.23
shipping:
  free_above: 100
EOF
workstation$ cat > kustomization.yaml <<'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: lab-05-09
resources:
- deployment.yaml
configMapGenerator:
- name: shop-config
  literals:
  - UI_MESSAGE=Welcome to the shop
  - UI_COLOR=#34577c
- name: shop-pricing
  files:
  - pricing.yaml
EOF
```

2. Render without applying, to see what Kustomize generates.

```bash
workstation$ kubectl kustomize . | grep -E '^kind|  name: shop|configMapRef|name: shop-'
```

Expected:
```
kind: ConfigMap
  name: shop-config-hf8thcdg67
kind: ConfigMap
  name: shop-pricing-26m52mf49h
kind: Deployment
  name: shop
        - configMapRef:
            name: shop-config-hf8thcdg67
          name: shop-pricing-26m52mf49h
```

3. Apply it.

```bash
workstation$ kubectl create namespace lab-05-09
workstation$ kubectl apply -k .
workstation$ kubectl -n lab-05-09 rollout status deploy/shop
workstation$ kubectl -n lab-05-09 get configmap
```

Expected:
```
configmap/shop-config-hf8thcdg67 created
configmap/shop-pricing-26m52mf49h created
deployment.apps/shop created
NAME                      DATA   AGE
kube-root-ca.crt          1      1s
shop-config-hf8thcdg67    2      1s
shop-pricing-26m52mf49h   1      1s
```

4. Change the banner. Edit the literal in `kustomization.yaml` to `UI_MESSAGE=Cyber Monday: free shipping` and apply.

```bash
workstation$ sed -i 's/UI_MESSAGE=Welcome to the shop/UI_MESSAGE=Cyber Monday: free shipping/' kustomization.yaml
workstation$ kubectl apply -k .
```

Expected:
```
error: invalid Kustomization: json: cannot unmarshal object into Go struct field ConfigMapArgs.configMapGenerator.GeneratorArgs.KvPairSources.literals of type string
```

> **Pitfall:** `- UI_MESSAGE=Cyber Monday: free shipping` contains `: `, so YAML reads it as a map, not a string.
> Quote literals that contain `: ` or start with special characters.

```bash
workstation$ sed -i 's/  - UI_MESSAGE=Cyber Monday: free shipping/  - "UI_MESSAGE=Cyber Monday: free shipping"/' kustomization.yaml
workstation$ kubectl apply -k .
workstation$ kubectl -n lab-05-09 rollout status deploy/shop
workstation$ kubectl -n lab-05-09 get configmap
workstation$ kubectl -n lab-05-09 exec deploy/shop -- sh -c 'curl -s localhost:9898 | grep message'
```

Expected (a new ConfigMap; the unchanged pricing ConfigMap keeps its name; the Deployment rolled by itself):
```
configmap/shop-config-dmf658942t created
configmap/shop-pricing-26m52mf49h unchanged
deployment.apps/shop configured
NAME                      DATA   AGE
kube-root-ca.crt          1      13s
shop-config-dmf658942t    2      3s
shop-config-hf8thcdg67    2      13s
shop-pricing-26m52mf49h   1      13s
  "message": "Cyber Monday: free shipping",
```

5. Marketing changed its mind. Because the old ConfigMap still exists under its old name, the previous ReplicaSet
   still works, and `rollout undo` brings back the old configuration together with the old Pod template.

```bash
workstation$ kubectl -n lab-05-09 rollout undo deploy/shop
workstation$ kubectl -n lab-05-09 rollout status deploy/shop
workstation$ kubectl -n lab-05-09 exec deploy/shop -- sh -c 'curl -s localhost:9898 | grep message'
workstation$ kubectl -n lab-05-09 get deploy shop -o jsonpath='{.spec.template.spec.containers[0].envFrom[0].configMapRef.name}{"\n"}'
```

Expected:
```
deployment.apps/shop rolled back
  "message": "Welcome to the shop",
shop-config-hf8thcdg67
```

Compare with Lab 5.2: there the ConfigMap was edited in place, so an undo would restore the old template but read the
*new* values. Note also the warning `kubectl` prints: the cluster now differs from Git. The next `kubectl apply -k .`
restores the Git state (Cyber Monday) again, so a real rollback is a revert commit.

6. Old generated ConfigMaps are never deleted by `apply`. Keep them for a few revisions (they make undo possible),
   then remove them, for example with a GitOps tool's pruning, `kubectl apply --prune`, or by hand.

### Clean up

```bash
workstation$ kubectl delete namespace lab-05-09
```

### Your turn

The same base must run as **staging** (namespace `lab-05-09-staging`, banner `STAGING - test data only`, 2 replicas)
and **prod** (namespace `lab-05-09-prod`, green color `#2e7d32`, 3 replicas, the base's message). Create two overlays
under `~/lab-05-09/overlays/` that reuse `~/lab-05-09/shop` unchanged and override only what differs. Deploy both
and compare the generated ConfigMap names and the served color and message.

<details><summary>Solution</summary>

`behavior: merge` modifies the base's generated ConfigMap instead of creating a second one with the same name. The
overlay's `namespace` overrides the base's.

```bash
workstation$ cd ~/lab-05-09 && mkdir -p overlays/staging overlays/prod
workstation$ cat > overlays/staging/kustomization.yaml <<'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: lab-05-09-staging
resources:
- ../../shop
configMapGenerator:
- name: shop-config
  behavior: merge                 # change one key, keep the rest from the base
  literals:
  - "UI_MESSAGE=STAGING - test data only"
EOF
workstation$ cat > overlays/prod/kustomization.yaml <<'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: lab-05-09-prod
resources:
- ../../shop
replicas:
- name: shop
  count: 3
configMapGenerator:
- name: shop-config
  behavior: merge
  literals:
  - UI_COLOR=#2e7d32
EOF
workstation$ kubectl create namespace lab-05-09-staging
workstation$ kubectl create namespace lab-05-09-prod
workstation$ kubectl apply -k overlays/staging
workstation$ kubectl apply -k overlays/prod
workstation$ kubectl -n lab-05-09-prod rollout status deploy/shop
workstation$ for ns in lab-05-09-staging lab-05-09-prod; do
  echo "== $ns: $(kubectl -n $ns get deploy shop -o jsonpath='{.status.readyReplicas}') replicas, $(kubectl -n $ns get cm -o name | grep shop-config)"
  kubectl -n $ns exec deploy/shop -- sh -c 'curl -s localhost:9898 | grep -E "color|message"'
done
```

Expected:
```
== lab-05-09-staging: 2 replicas, configmap/shop-config-7d925t9b25
  "color": "#34577c",
  "message": "STAGING - test data only",
== lab-05-09-prod: 3 replicas, configmap/shop-config-989798d4dh
  "color": "#2e7d32",
  "message": "Cyber Monday: free shipping",
```

Each environment gets its own hash, and `shop-pricing-26m52mf49h` has the same name in both, because its content is
identical. Clean up with `kubectl delete namespace lab-05-09-staging lab-05-09-prod` and `rm -rf ~/lab-05-09`.

</details>

---

## Lab 5.10: Encrypt Secrets at rest in etcd ⚠ cluster-wide

**Scenario** – An auditor asks: "if someone copies an etcd backup or the etcd data directory, can they read your
database passwords?" Today the answer is yes, because Secrets are stored in etcd unencrypted. We prove it by reading a
Secret directly from etcd, enable encryption at rest in the API server of our kubeadm cluster, re-encrypt existing
Secrets, and learn how to roll the change back safely.

> **⚠ cluster-wide:** this lab edits the kube-apiserver static Pod manifest on `master`. The API server restarts
> (about a minute without API access), and every Secret written while encryption is on must be rewritten before you
> can switch it off again. Do it only on the training cluster, and always run *Clean up*.

**What you'll learn**
- how to look at raw objects in etcd with `etcdctl` (read-only)
- `EncryptionConfiguration`: provider order, keys, the `identity` provider
- enabling `--encryption-provider-config` on a kubeadm control plane, with a backup of the manifest
- encryption applies on **write**: re-encrypting existing data, and the safe rollback order

### Steps

1. Create a Secret and read it straight from etcd. The `etcd` static Pod contains `etcdctl`, and its client
   certificates are mounted in it.

```bash
workstation$ kubectl create namespace lab-05-10
workstation$ kubectl -n lab-05-10 create secret generic payment-gateway --from-literal=api-key=pk_live_TOPSECRET_42
workstation$ etcdget() {
  kubectl -n kube-system exec etcd-master -- etcdctl --endpoints=https://127.0.0.1:2379 \
    --cacert=/etc/kubernetes/pki/etcd/ca.crt --cert=/etc/kubernetes/pki/etcd/server.crt \
    --key=/etc/kubernetes/pki/etcd/server.key get "$1" --print-value-only
}
workstation$ etcdget /registry/secrets/lab-05-10/payment-gateway | od -c | head -3
workstation$ etcdget /registry/secrets/lab-05-10/payment-gateway | grep -a -o 'pk_live_[A-Z_0-9]*'
```

Expected (a protobuf-encoded object starting with `k8s\0`, and the password in clear text):
```
0000000   k   8   s  \0  \n  \f  \n 002   v   1 022 006   S   e   c   r
0000020   e   t 022 347 001  \n 273 001  \n 017   p   a   y   m   e   n
0000040   t   -   g   a   t   e   w   a   y 022  \0 032  \t   l   a   b
pk_live_TOPSECRET_42
```

Anyone with a copy of `/var/lib/etcd` or of an etcd snapshot can do the same, without any Kubernetes credentials.

2. On `master`, generate a 32-byte key and write the encryption configuration. The file goes into
   `/etc/kubernetes/pki`, which the API server Pod already mounts (read-only), so the manifest needs no new volume.

```bash
master$ KEY=$(head -c 32 /dev/urandom | base64)
master$ sudo install -m 600 /dev/null /etc/kubernetes/pki/encryption-config.yaml
master$ sudo tee /etc/kubernetes/pki/encryption-config.yaml >/dev/null <<EOF
apiVersion: apiserver.config.k8s.io/v1
kind: EncryptionConfiguration
resources:
- resources: [secrets]
  providers:
  - secretbox:                  # first provider = used for all new writes
      keys:
      - name: key1
        secret: $KEY
  - identity: {}                # still able to read data that is not encrypted yet
EOF
master$ unset KEY
```

> **Why this order?** The first provider encrypts every write. All providers are tried for reads, so `identity`
> at the end lets the API server read the Secrets that are still stored in plain text. `secretbox` (XSalsa20 +
> Poly1305) is the recommended local provider; in production, a KMS v2 provider keeps the key outside the node.
> **Losing this file means losing every Secret**: back it up like a CA key, and never into the same place as etcd
> backups.

3. Back up the API server manifest **outside** `/etc/kubernetes/manifests` (the kubelet would start every YAML file
   in that directory as a static Pod, including a `.bak` copy), then add the two flags.

```bash
master$ sudo cp /etc/kubernetes/manifests/kube-apiserver.yaml /root/kube-apiserver.yaml.orig
master$ sudo sed -i 's|^    - kube-apiserver$|    - kube-apiserver\n    - --encryption-provider-config=/etc/kubernetes/pki/encryption-config.yaml\n    - --encryption-provider-config-automatic-reload=true|' \
  /etc/kubernetes/manifests/kube-apiserver.yaml
master$ sudo diff /root/kube-apiserver.yaml.orig /etc/kubernetes/manifests/kube-apiserver.yaml
```

Expected:
```
14a15,16
>     - --encryption-provider-config=/etc/kubernetes/pki/encryption-config.yaml
>     - --encryption-provider-config-automatic-reload=true
```

`--encryption-provider-config-automatic-reload` makes the API server re-read the file when it changes, so key rotation
and rollback (below) do not need further restarts.

4. The kubelet notices the changed manifest and recreates the API server. Wait until it answers again.

```bash
workstation$ sleep 20; until kubectl get --raw=/readyz >/dev/null 2>&1; do sleep 5; done; echo API server ready
workstation$ kubectl -n kube-system get pod kube-apiserver-master -o yaml | grep encryption-provider
```

Expected:
```
API server ready
    - --encryption-provider-config=/etc/kubernetes/pki/encryption-config.yaml
    - --encryption-provider-config-automatic-reload=true
```

The `kube-apiserver-master` object is a *mirror Pod* that the kubelet updates a little later than the real process.
If `grep` prints nothing right after `API server ready`, wait 30 s and repeat it. (On the training cluster the new
API server was already encrypting while the mirror Pod still showed the old spec.)

If the API server does not come back within 2–3 minutes, restore the backup at once
(`sudo cp /root/kube-apiserver.yaml.orig /etc/kubernetes/manifests/kube-apiserver.yaml`) and check the file for typos.

5. Existing data is not touched: the old Secret is still readable in etcd. A new Secret is stored encrypted.

```bash
workstation$ kubectl -n lab-05-10 create secret generic payment-gateway-v2 --from-literal=api-key=pk_live_TOPSECRET_43
workstation$ etcdget /registry/secrets/lab-05-10/payment-gateway | grep -a -c TOPSECRET
workstation$ etcdget /registry/secrets/lab-05-10/payment-gateway-v2 | head -c 26; echo
workstation$ etcdget /registry/secrets/lab-05-10/payment-gateway-v2 | grep -a -c TOPSECRET
```

Expected:
```
1
k8s:enc:secretbox:v1:key1:
0
```

6. Rewrite the existing Secrets so that they are encrypted, too. A `replace` without changes is enough: the API server
   reads, then writes them with the first provider. In a real cluster you run it for all namespaces (`-A`).

```bash
workstation$ kubectl -n lab-05-10 get secrets -o json | kubectl replace -f -
workstation$ etcdget /registry/secrets/lab-05-10/payment-gateway | head -c 26; echo
workstation$ kubectl -n lab-05-10 get secret payment-gateway -o jsonpath='{.data.api-key}' | base64 -d; echo
```

Expected (encrypted in etcd, transparent for API clients):
```
secret/payment-gateway replaced
secret/payment-gateway-v2 replaced
k8s:enc:secretbox:v1:key1:
pk_live_TOPSECRET_42
```

Encryption at rest protects etcd files and backups. It does **not** protect against anyone who may `get` Secrets
through the API; that is RBAC's job (Module 06).

### Clean up

Do the steps in this order. Removing the flag first would leave the API server unable to decrypt every Secret written
in the meantime, including ServiceAccount and Helm Secrets of other workloads.

1. Make `identity` the first provider (new writes are plain text again, the key stays for reading), and wait for the
   automatic reload. A new test Secret shows when it is active.

```bash
master$ sudo sed -i -e '/^  - identity: {}/d' -e 's/^  providers:$/  providers:\n  - identity: {}/' \
  /etc/kubernetes/pki/encryption-config.yaml
workstation$ sleep 60
workstation$ kubectl -n lab-05-10 create secret generic probe --from-literal=x=1
workstation$ etcdget /registry/secrets/lab-05-10/probe | head -c 4 | od -c | head -1
```

Expected (plain `k8s\0`, not `k8s:enc:`; if it is still encrypted, delete `probe`, wait a little longer and repeat):
```
0000000   k   8   s  \0
```

2. Rewrite **all** Secrets in the cluster so that they are decrypted (rerun if some report a conflict), and check one.

```bash
workstation$ kubectl get secrets -A -o json | kubectl replace -f - >/dev/null && echo all secrets rewritten
workstation$ etcdget /registry/secrets/lab-05-10/payment-gateway | head -c 4 | od -c | head -1
```

Expected:
```
all secrets rewritten
0000000   k   8   s  \0
```

3. Restore the original manifest, wait for the API server, and remove the files.

```bash
master$ sudo cp /root/kube-apiserver.yaml.orig /etc/kubernetes/manifests/kube-apiserver.yaml
workstation$ sleep 20; until kubectl get --raw=/readyz >/dev/null 2>&1; do sleep 5; done; echo API server ready
workstation$ kubectl -n kube-system get pod kube-apiserver-master -o yaml | grep -c encryption-provider
master$ sudo rm /etc/kubernetes/pki/encryption-config.yaml /root/kube-apiserver.yaml.orig
workstation$ kubectl delete namespace lab-05-10
```

Expected (`0`: the flags are gone):
```
API server ready
0
```

### Your turn

Do this before *Clean up*. The security policy requires rotating the encryption key every 90 days. Rotate from
`key1` to a new `key2` without making any Secret unreadable at any time, and prove that `payment-gateway` ends up
encrypted with `key2`. In which order must the keys appear in the file during the rotation, and when may `key1` be
removed?

<details><summary>Solution</summary>

1. Add `key2` as the **first** key of the `secretbox` provider and keep `key1` as the second, so that new writes use
   `key2` and old data can still be decrypted with `key1`. With automatic reload, the API server picks it up within a
   minute (with several API servers, every one of them must have both keys before any of them writes with `key2`).

```bash
master$ KEY2=$(head -c 32 /dev/urandom | base64)
master$ sudo sed -i "s|^      keys:\$|      keys:\n      - name: key2\n        secret: $KEY2|" /etc/kubernetes/pki/encryption-config.yaml
master$ unset KEY2
master$ sudo sed 's/secret: .*/secret: <redacted>/' /etc/kubernetes/pki/encryption-config.yaml
```

Expected:
```
  providers:
  - secretbox:                  # first provider = used for all new writes
      keys:
      - name: key2
        secret: <redacted>
      - name: key1
        secret: <redacted>
  - identity: {}                # still able to read data that is not encrypted yet
```

2. Wait about a minute, then rewrite the Secrets and check the key name in the prefix.

```bash
workstation$ sleep 60
workstation$ kubectl -n lab-05-10 get secrets -o json | kubectl replace -f -
workstation$ etcdget /registry/secrets/lab-05-10/payment-gateway | head -c 26; echo
```

Expected (if it still says `key1`, the reload has not happened yet; wait and repeat the `replace`):
```
k8s:enc:secretbox:v1:key2:
```

3. Only after **all** Secrets in the cluster were rewritten with `key2` (`kubectl get secrets -A -o json | kubectl
   replace -f -`) may `key1` be removed from the file; anything still encrypted with `key1` would become unreadable.

```bash
master$ sudo sed -i '/- name: key1/,+1d' /etc/kubernetes/pki/encryption-config.yaml
```

Expected (after the reload, every Secret is still readable, now with only `key2` in the file):
```
workstation$ sleep 60; kubectl get secrets -A >/dev/null && echo "all secrets still readable after removing key1"
all secrets still readable after removing key1
```

Then continue with *Clean up*: its `sed` command works with any number of keys.

</details>
