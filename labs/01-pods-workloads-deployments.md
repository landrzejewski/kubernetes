# Module 01: Pods, Workloads, Deployments

This module is about the everyday life of workloads: why Pods fail and how to read the signals, how probes, sidecars
and resource settings change Pod behaviour, how Deployments roll out (and roll back) safely, and when to reach for Jobs,
CronJobs, DaemonSets and StatefulSets instead. The last lab shows how to debug running Pods and nodes without
rebuilding images.

### Prerequisites check

```bash
workstation$ kubectl get nodes                 # master, node1, node2 Ready
workstation$ kubectl top nodes                 # metrics-server works (needed in Lab 1.4)
workstation$ kubectl auth can-i '*' '*' -A     # yes
```

### Table of contents

- [Lab 1.1: 2 AM On-call: Triage a Broken Shop](#lab-11-2-am-on-call-triage-a-broken-shop)
- [Lab 1.2: Native Sidecars: Log Shipper and "Wait for Redis"](#lab-12-native-sidecars-log-shipper-and-wait-for-redis)
- [Lab 1.3: Probes That Tell the Truth](#lab-13-probes-that-tell-the-truth)
- [Lab 1.4: Requests, Limits and QoS: OOMKilled vs Throttled](#lab-14-requests-limits-and-qos-oomkilled-vs-throttled)
- [Lab 1.5: Zero-downtime Shutdown](#lab-15-zero-downtime-shutdown)
- [Lab 1.6: Rollout Control: Surge, Pause, Stuck, Undo](#lab-16-rollout-control-surge-pause-stuck-undo)
- [Lab 1.7: Batch Work: Indexed Jobs and Database Backups](#lab-17-batch-work-indexed-jobs-and-database-backups)
- [Lab 1.8: A Node Agent on Every Node with a DaemonSet](#lab-18-a-node-agent-on-every-node-with-a-daemonset)
- [Lab 1.9: Redis Primary/Replica with a StatefulSet](#lab-19-redis-primaryreplica-with-a-statefulset)
- [Lab 1.10: Live Debugging with Ephemeral Containers](#lab-110-live-debugging-with-ephemeral-containers)

---

## Lab 1.1: 2 AM On-call: Triage a Broken Shop

**Scenario** – You are on call. A late-night release of the web shop went wrong: the `checkout`, `catalog`,
`recommender` and `cart` Deployments are all down, and each one is broken in a different way. You have to find the
root cause of each failure from the Pod status, events and logs, without guessing, and fix them one by one.

**What you'll learn**
- Read Pod `STATUS` values: `CrashLoopBackOff`/`Error`, `ImagePullBackOff`, `OOMKilled`, `CreateContainerError`
- Where each kind of failure shows up: `describe` events, `logs`, `logs --previous`, `lastState`
- Fix live Deployments with `kubectl set env|image|resources` and `kubectl patch`

### Steps

1. Create the namespace and deploy the broken release:

```bash
workstation$ kubectl create namespace lab-01-01
workstation$ kubectl config set-context --current --namespace=lab-01-01
workstation$ kubectl apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: checkout
spec:
  selector:
    matchLabels: {app: checkout}
  template:
    metadata:
      labels: {app: checkout}
    spec:
      containers:
      - name: app
        image: busybox:1.38
        command: ["sh", "-c"]
        args:
        - |
          echo "checkout v2.3 starting"
          if [ -z "$PAYMENT_API_URL" ]; then
            echo "FATAL: PAYMENT_API_URL is not set, refusing to start" >&2
            exit 1
          fi
          echo "connected to $PAYMENT_API_URL"; exec sleep infinity
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: catalog
spec:
  selector:
    matchLabels: {app: catalog}
  template:
    metadata:
      labels: {app: catalog}
    spec:
      containers:
      - name: web
        image: nginx:1.31-alpline
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: recommender
spec:
  selector:
    matchLabels: {app: recommender}
  template:
    metadata:
      labels: {app: recommender}
    spec:
      containers:
      - name: model
        image: polinux/stress:1.0.4
        command: ["stress", "--vm", "1", "--vm-bytes", "200M", "--vm-hang", "0"]
        resources:
          requests: {memory: 64Mi, cpu: 50m}
          limits:   {memory: 128Mi}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: cart
spec:
  selector:
    matchLabels: {app: cart}
  template:
    metadata:
      labels: {app: cart}
    spec:
      containers:
      - name: redis
        image: redis:8.8
        command: ["redis-sever", "--appendonly", "yes"]
EOF
```

2. Get the big picture. Wait a minute so every failure has time to show itself:

```bash
workstation$ kubectl get pods
```

Expected:
```
NAME                          READY   STATUS                 RESTARTS      AGE
cart-6485cd54c5-496zf         0/1     CreateContainerError   0             63s
catalog-7f895996bd-lhwxl      0/1     ErrImagePull           0             64s
checkout-6f5c8bffcf-vqtvb     0/1     Error                  3 (48s ago)   64s
recommender-5cf75dbcc-fcr5b   0/1     OOMKilled              3 (41s ago)   63s
```

**Why:** `STATUS` is a summary. For a crashing container it flips between the reason of the last exit (`Error`,
`OOMKilled`) right after a crash and `CrashLoopBackOff` while the kubelet waits before the next restart (10 s, 20 s,
40 s … up to 5 min). `ErrImagePull` similarly becomes `ImagePullBackOff`. A `RESTARTS` count above zero means the
container **did start**, so the problem is inside the app. A count of zero with a waiting reason means the
container never started at all.

3. A custom-columns view shows the current and the *last* state side by side, which is much faster than four
`describe` calls:

```bash
workstation$ kubectl get pods -o custom-columns='POD:.metadata.name,WAITING:.status.containerStatuses[0].state.waiting.reason,LAST:.status.containerStatuses[0].lastState.terminated.reason,EXIT:.status.containerStatuses[0].lastState.terminated.exitCode,RESTARTS:.status.containerStatuses[0].restartCount'
```

Expected:
```
POD                           WAITING                LAST        EXIT     RESTARTS
cart-6485cd54c5-496zf         CreateContainerError   <none>      <none>   0
catalog-7f895996bd-lhwxl      ImagePullBackOff       <none>      <none>   0
checkout-6f5c8bffcf-vqtvb     <none>                 Error       1        3
recommender-5cf75dbcc-fcr5b   <none>                 OOMKilled   137      3
```

(`WAITING` for the two crashing Pods shows `CrashLoopBackOff` while they are in back-off and `<none>` right
after a crash.)

Exit code `137` = 128 + 9 (SIGKILL). Together with `OOMKilled` it means the kernel's OOM killer stopped the
process because it hit the memory **limit**. Exit code `1` is the application's own decision to quit.

4. **checkout** – the app started and exited, so the answer is in its logs:

```bash
workstation$ kubectl logs deploy/checkout --previous
```

Expected:
```
checkout v2.3 starting
FATAL: PAYMENT_API_URL is not set, refusing to start
```

**Pitfall:** `--previous` reads the logs of the *previous* container instance. If you run it a second after a crash
you may get `unable to retrieve container logs for cri-o://…`: the newest dead container is then the "current" one
and the one before has already been garbage collected. Plain `kubectl logs deploy/checkout` shows the crashed
instance in that moment; a few seconds later (state `CrashLoopBackOff`) both commands work.

5. **catalog** – never started (0 restarts). The events tell why:

```bash
workstation$ kubectl describe pod -l app=catalog | sed -n '/Events:/,$p'
```

Expected:
```
  Normal   Pulling    23s (x3 over 67s)  kubelet  spec.containers{web}: Pulling image "nginx:1.31-alpline"
  Warning  Failed     21s (x3 over 65s)  kubelet  spec.containers{web}: Failed to pull image "nginx:1.31-alpline": ... reading manifest 1.31-alpline in docker.io/library/nginx: manifest unknown
  Warning  Failed     21s (x3 over 65s)  kubelet  spec.containers{web}: Error: ErrImagePull
  Normal   BackOff    11s (x3 over 65s)  kubelet  spec.containers{web}: Back-off pulling image "nginx:1.31-alpline"
```

`manifest unknown` = the tag does not exist (a typo here). Other common messages: `unauthorized` / `denied`
(private registry, missing `imagePullSecrets`), `toomanyrequests` (Docker Hub rate limit), `i/o timeout` (no
egress from the node).

6. **cart** – also never started, but the image *was* pulled. The container runtime could not create it:

```bash
workstation$ kubectl describe pod -l app=cart | sed -n '/Command:/,/Ready:/p;/Events:/,$p'
```

Expected:
```
    Command:
      redis-sever
      --appendonly
      yes
    State:          Waiting
      Reason:       CreateContainerError
...
  Warning  Failed     9s (x7 over 66s)   kubelet  spec.containers{redis}: Error: container create failed: executable file `redis-sever` not found in $PATH: No such file or directory
```

**Why:** `command` replaces the image's `ENTRYPOINT`. A wrong binary name fails *before* the process exists, so
there are no logs at all. `kubectl logs` would only print `container "redis" ... is waiting to start`.

7. **recommender** – the `lastState` already said `OOMKilled`. Compare what the process wants with the limit:

```bash
workstation$ kubectl get deploy recommender -o jsonpath='{.spec.template.spec.containers[0].command}{"\n"}{.spec.template.spec.containers[0].resources}{"\n"}'
```

Expected:
```
["stress","--vm","1","--vm-bytes","200M","--vm-hang","0"]
{"limits":{"memory":"128Mi"},"requests":{"cpu":"50m","memory":"64Mi"}}
```

The model loads 200 MB into memory, the limit is 128 MiB. Lab 1.4 goes deeper into limits.

8. Fix all four. Each command changes the Pod template, so each Deployment rolls out a new ReplicaSet:

```bash
workstation$ kubectl set env deploy/checkout PAYMENT_API_URL=http://payments.lab-01-01.svc:8080
workstation$ kubectl set image deploy/catalog web=nginx:1.31-alpine
workstation$ kubectl set resources deploy/recommender -c model --limits=memory=256Mi
workstation$ kubectl patch deploy cart --type=json \
  -p '[{"op":"replace","path":"/spec/template/spec/containers/0/command/0","value":"redis-server"}]'
workstation$ for d in checkout catalog recommender cart; do kubectl rollout status deploy/$d --timeout=120s; done
workstation$ kubectl get pods
workstation$ kubectl logs deploy/checkout
```

Expected:
```
deployment "checkout" successfully rolled out
...
NAME                           READY   STATUS    RESTARTS   AGE
cart-54f56899d5-jrp4q          1/1     Running   0          4s
catalog-5984664596-twm9p       1/1     Running   0          5s
checkout-7d5ffc6d5b-r8k27      1/1     Running   0          5s
recommender-6db5c7c7d7-jp5f8   1/1     Running   0          5s

checkout v2.3 starting
connected to http://payments.lab-01-01.svc:8080
```

**Why `kubectl patch`?** `kubectl set` has no sub-command for `command`/`args`. A JSON patch changes a single list
element without re-sending the whole manifest. In real life you fix the manifest in Git and re-apply it; the
imperative commands are for the 2 AM emergency, and you must back-port them, or the next `apply` reverts your fix.

### Clean up

```bash
workstation$ kubectl delete namespace lab-01-01
workstation$ kubectl config set-context --current --namespace=default
```

### Your turn

The next morning two new services are deployed into the same namespace, and both are stuck, but neither shows any
restarts. Deploy them, find the root causes and fix them **without editing the `notifications` Deployment**:

```bash
workstation$ kubectl apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: notifications
spec:
  selector:
    matchLabels: {app: notifications}
  template:
    metadata:
      labels: {app: notifications}
    spec:
      containers:
      - name: app
        image: busybox:1.38
        command: ["sh", "-c", "echo using SMTP password of length ${#SMTP_PASSWORD}; exec sleep infinity"]
        env:
        - name: SMTP_PASSWORD
          valueFrom:
            secretKeyRef: {name: smtp-credentials, key: password}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: invoices
spec:
  selector:
    matchLabels: {app: invoices}
  template:
    metadata:
      labels: {app: invoices}
    spec:
      containers:
      - name: app
        image: busybox:1.38
        command: ["sleep", "infinity"]
        resources:
          requests: {cpu: "6", memory: 1Gi}
EOF
```

Bonus: write a single `kubectl … -o json | jq` command that prints every not-ready Pod of the namespace with its
reason and message, so the next on-call engineer gets the triage list in one go.

<details><summary>Solution</summary>

Triage one-liner (works for Pending, waiting and crashing Pods):

```bash
workstation$ kubectl get pods -o json | jq -r '.items[]
  | select(any(.status.containerStatuses[]?; .ready==false) or .status.phase=="Pending")
  | [.metadata.name, .status.phase,
     (.status.containerStatuses[0].state.waiting.reason // .status.conditions[0].reason // "-"),
     ((.status.containerStatuses[0].state.waiting.message // .status.conditions[0].message // "-")[0:90])]
  | @tsv'
```

Expected:
```
invoices-7c785fdd99-tvl66       Pending  Unschedulable               0/3 nodes are available: 1 node(s) had untolerated taint(s), 2 Insufficient cpu. preemptio
notifications-84c45cd648-ck2t4  Pending  CreateContainerConfigError  secret "smtp-credentials" not found
```

- `invoices` is **Pending** and not even scheduled: it requests 6 CPUs, the workers have 4 each, and the master has
  the control-plane taint. The scheduler only looks at *requests* (not real usage). Check node capacity with
  `kubectl describe node node1 | grep -A6 "Allocated resources"`. Fix: request what the app really needs.
- `notifications` is scheduled, but the kubelet cannot build the container config because the referenced Secret is
  missing. Fix: create the Secret. The kubelet keeps retrying, so the Pod starts **by itself**, with no rollout.

```bash
workstation$ kubectl set resources deploy/invoices --requests=cpu=500m,memory=256Mi
workstation$ kubectl create secret generic smtp-credentials --from-literal=password=s3cr3t-smtp
workstation$ kubectl get pods -l 'app in (invoices,notifications)'
workstation$ kubectl logs deploy/notifications
```

Expected:
```
NAME                             READY   STATUS    RESTARTS   AGE
invoices-548846cd69-pdkgh        1/1     Running   0          16s
notifications-84c45cd648-ck2t4   1/1     Running   0          44s

using SMTP password of length 11
```

Note that the `notifications` Pod name did not change: it is the same Pod that was stuck before.

</details>

---

## Lab 1.2: Native Sidecars: Log Shipper and "Wait for Redis"

**Scenario** – The `order-worker` writes its business log to a file, not to stdout, and the platform team wants
those lines shipped by Fluent Bit. The worker also crashes noisily when Redis is not up yet, which happens after
every cluster restart. We will add an init container that waits for Redis and a **native sidecar** (an init
container with `restartPolicy: Always`) that ships the log file, and then see why native sidecars matter for Jobs.

**What you'll learn**
- Init containers run in order, and each must finish before the next one starts
- Native sidecars: start before the app, run for the whole Pod lifetime, stop after the app
- Sharing files between containers with an `emptyDir` volume
- An init container is a one-time gate, not a health check

### Steps

1. Create the namespace, the Fluent Bit configuration and the worker. Do **not** deploy Redis yet:

```bash
workstation$ kubectl create namespace lab-01-02
workstation$ kubectl config set-context --current --namespace=lab-01-02
workstation$ kubectl apply -f - <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: fluent-bit-config
data:
  fluent-bit.conf: |
    [SERVICE]
        Flush        1
        Log_Level    warn
    [INPUT]
        Name             tail
        Path             /var/log/app/*.log
        Read_from_Head   true
        Refresh_Interval 2
    [FILTER]
        Name   record_modifier
        Match  *
        Record pod ${POD_NAME}
    [OUTPUT]
        Name    stdout
        Match   *
        Format  json_lines
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: order-worker
spec:
  selector:
    matchLabels: {app: order-worker}
  template:
    metadata:
      labels: {app: order-worker}
    spec:
      initContainers:
      - name: wait-for-redis
        image: redis:8.8
        command: ["sh", "-c"]
        args:
        - |
          until redis-cli -h redis -t 2 ping 2>/dev/null | grep -q PONG; do
            echo "$(date +%T) redis not reachable yet, retrying in 3s"; sleep 3
          done
          echo "redis is up"
      - name: log-shipper
        image: fluent/fluent-bit:4.2.0
        restartPolicy: Always          # <- this makes it a native sidecar
        env:
        - name: POD_NAME
          valueFrom: {fieldRef: {fieldPath: metadata.name}}
        volumeMounts:
        - {name: logs, mountPath: /var/log/app}
        - {name: config, mountPath: /fluent-bit/etc}
      containers:
      - name: worker
        image: redis:8.8
        command: ["sh", "-c"]
        args:
        - |
          while true; do
            n=$(redis-cli -h redis INCR orders)
            echo "$(date -Iseconds) order=$n status=processed" >> /var/log/app/orders.log
            sleep 2
          done
        volumeMounts:
        - {name: logs, mountPath: /var/log/app}
      volumes:
      - name: logs
        emptyDir: {}
      - name: config
        configMap: {name: fluent-bit-config}
EOF
```

2. The Pod is stuck in the first init container:

```bash
workstation$ kubectl get pods
workstation$ kubectl logs deploy/order-worker -c wait-for-redis --tail=3
```

Expected:
```
NAME                            READY   STATUS     RESTARTS   AGE
order-worker-86b4b655d9-ck5lx   0/2     Init:0/2   0          25s

02:33:57 redis not reachable yet, retrying in 3s
02:34:00 redis not reachable yet, retrying in 3s
02:34:04 redis not reachable yet, retrying in 3s
```

`Init:0/2` = zero of two init containers are done. The sidecar is counted as an init container here, and `READY`
says `0/2` because the sidecar also counts as a container that must be ready. The worker itself has not started, so it
cannot crash.

3. Watch the Pod in one terminal and deploy Redis in a second one:

```bash
workstation$ kubectl get pods -w        # terminal 1
workstation$ kubectl apply -f - <<'EOF' # terminal 2
apiVersion: apps/v1
kind: Deployment
metadata:
  name: redis
spec:
  selector:
    matchLabels: {app: redis}
  template:
    metadata:
      labels: {app: redis}
    spec:
      containers:
      - name: redis
        image: redis:8.8
        ports:
        - containerPort: 6379
---
apiVersion: v1
kind: Service
metadata:
  name: redis
spec:
  selector: {app: redis}
  ports:
  - port: 6379
EOF
```

Expected (terminal 1):
```
NAME                            READY   STATUS            RESTARTS   AGE
order-worker-86b4b655d9-ck5lx   0/2     Init:0/2          0          33s
redis-78c8fcb445-6d68k          1/1     Running           0          2s
order-worker-86b4b655d9-ck5lx   0/2     Init:1/2          0          36s
order-worker-86b4b655d9-ck5lx   1/2     PodInitializing   0          44s
order-worker-86b4b655d9-ck5lx   2/2     Running           0          44s
```

`Init:1/2` → `wait-for-redis` exited 0. `1/2 PodInitializing` → the sidecar has **started**, and only then does the
kubelet start the `worker` container. With a second regular container instead of a sidecar, there is no ordering:
the worker could write (and rotate) files before the shipper is up.

4. Look at the init container statuses and the shipped log lines:

```bash
workstation$ kubectl get pod -l app=order-worker -o jsonpath='{range .items[0].status.initContainerStatuses[*]}{.name}{" started="}{.started}{" state="}{.state}{"\n"}{end}'
workstation$ kubectl logs deploy/order-worker -c log-shipper --tail=2
```

Expected:
```
wait-for-redis started=false state={"terminated":{...,"exitCode":0,...,"reason":"Completed",...}}
log-shipper started=true state={"running":{"startedAt":"2026-11-04T02:34:24Z"}}

{"date":1793759724.090137,"log":"2026-11-04T02:35:23+00:00 order=30 status=processed","pod":"order-worker-86b4b655d9-ck5lx"}
{"date":1793759725.985415,"log":"2026-11-04T02:35:25+00:00 order=31 status=processed","pod":"order-worker-86b4b655d9-ck5lx"}
```

**Pitfall:** the first version of this lab had no `Refresh_Interval`. Fluent Bit started *before* the worker
created `orders.log` and re-scans the glob only every 60 s by default, so nothing was shipped for a whole
minute. A sidecar that starts first sees an empty directory. Design for that.

5. An init container is a **one-time** gate. Take Redis away and see what the worker does:

```bash
workstation$ kubectl scale deploy/redis --replicas=0
workstation$ sleep 15; kubectl get pods -l app=order-worker
workstation$ kubectl logs deploy/order-worker -c log-shipper --tail=1
workstation$ kubectl scale deploy/redis --replicas=1
workstation$ sleep 15; kubectl logs deploy/order-worker -c log-shipper --tail=1
```

Expected:
```
NAME                            READY   STATUS    RESTARTS   AGE
order-worker-7b6d5bff64-tpn74   2/2     Running   0          109s
{..."log":"2026-11-04T02:37:26+00:00 order= status=processed",...}
{..."log":"2026-11-04T02:37:40+00:00 order=6 status=processed",...}
```

**Why:** init containers are not re-run when a dependency disappears later. The Pod stays `2/2 Running` while it
"processes" orders with an empty ID. And when Redis comes back, the counter restarts from 1 because this Redis has
no persistent storage. Runtime dependency checks belong in readiness probes and in the application's
retry logic (Lab 1.3). State belongs on a volume (Lab 1.9 and module 04).

### Clean up

```bash
workstation$ kubectl delete namespace lab-01-02
workstation$ kubectl config set-context --current --namespace=default
```

### Your turn

Finance wants a `daily-report` Job that reads the order counter and writes a report line to
`/var/log/app/report.log`, shipped by the same Fluent Bit setup. A colleague wrote it with Fluent Bit as a
second regular container:

```bash
workstation$ kubectl apply -f - <<'EOF'
apiVersion: batch/v1
kind: Job
metadata:
  name: daily-report
spec:
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      containers:
      - name: report
        image: redis:8.8
        command: ["sh", "-c"]
        args:
        - |
          total=$(redis-cli -h redis GET orders)
          echo "$(date -Iseconds) daily report: total_orders=$total" >> /var/log/app/report.log
          sleep 5   # give the shipper time to read the file
        volumeMounts:
        - {name: logs, mountPath: /var/log/app}
      - name: log-shipper
        image: fluent/fluent-bit:4.2.0
        env:
        - name: POD_NAME
          valueFrom: {fieldRef: {fieldPath: metadata.name}}
        volumeMounts:
        - {name: logs, mountPath: /var/log/app}
        - {name: config, mountPath: /fluent-bit/etc}
      volumes:
      - name: logs
        emptyDir: {}
      - name: config
        configMap: {name: fluent-bit-config}
EOF
```

Run it before you clean up the Steps (it needs Redis and the ConfigMap). Explain what you see after a minute, then fix
the Job so it completes and the report line still gets shipped.

<details><summary>Solution</summary>

The Job never finishes:

```bash
workstation$ kubectl get job,pods -l job-name=daily-report
```

Expected:
```
NAME                     STATUS    COMPLETIONS   DURATION   AGE
job.batch/daily-report   Running   0/1           45s        45s

NAME                     READY   STATUS     RESTARTS   AGE
pod/daily-report-fthcr   1/2     NotReady   0          45s
```

A Job is complete only when its Pod **succeeds**, which means that *all* regular containers have exited. `report`
is done, but Fluent Bit is a daemon and never exits, so the Pod runs forever. Before native sidecars existed,
people worked around this with "kill the sidecar through a shared file" hacks. Today you move the shipper to
`initContainers` with `restartPolicy: Always`. The kubelet stops sidecars automatically, in reverse order, after the
last regular container exits. A Job's Pod template is immutable, so delete and recreate the Job:

```bash
workstation$ kubectl delete job daily-report
workstation$ kubectl apply -f - <<'EOF'
apiVersion: batch/v1
kind: Job
metadata:
  name: daily-report
spec:
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      initContainers:
      - name: log-shipper
        image: fluent/fluent-bit:4.2.0
        restartPolicy: Always
        env:
        - name: POD_NAME
          valueFrom: {fieldRef: {fieldPath: metadata.name}}
        volumeMounts:
        - {name: logs, mountPath: /var/log/app}
        - {name: config, mountPath: /fluent-bit/etc}
      containers:
      - name: report
        image: redis:8.8
        command: ["sh", "-c"]
        args:
        - |
          total=$(redis-cli -h redis GET orders)
          echo "$(date -Iseconds) daily report: total_orders=$total" >> /var/log/app/report.log
          sleep 5   # give the shipper time to read the file
        volumeMounts:
        - {name: logs, mountPath: /var/log/app}
      volumes:
      - name: logs
        emptyDir: {}
      - name: config
        configMap: {name: fluent-bit-config}
EOF
workstation$ kubectl wait --for=condition=complete job/daily-report --timeout=90s
workstation$ kubectl get job,pods -l job-name=daily-report
workstation$ kubectl logs job/daily-report -c log-shipper | grep report
```

Expected:
```
job.batch/daily-report condition met
NAME                     STATUS     COMPLETIONS   DURATION   AGE
job.batch/daily-report   Complete   1/1           9s         10s

NAME                     READY   STATUS      RESTARTS   AGE
pod/daily-report-z2cpf   0/2     Completed   0          10s

{"date":1793759818.090751,"log":"2026-11-04T02:36:56+00:00 daily report: total_orders=90","pod":"daily-report-z2cpf"}
```

After `report` exited, Fluent Bit got SIGTERM, flushed its buffer (`service will shutdown in max 5 seconds`)
and exited, so the Pod is `Completed`. Then run the *Clean up* of this lab.

</details>

---

## Lab 1.3: Probes That Tell the Truth

**Scenario** – The `catalog-api` warms a large cache for about 30 seconds before it opens its HTTP port. Somebody
added a liveness probe "for safety", and now the Pods restart forever and never serve a single request. Even worse,
during the warm-up the Pods look `1/1 Ready` and the Service sends traffic to them. We will design startup,
readiness and liveness probes that each answer the right question, and watch how readiness drives the
EndpointSlice of the Service.

**What you'll learn**
- Startup vs readiness vs liveness: what each one controls and what happens on failure
- How a too-early liveness probe causes a restart loop
- Readiness removes a Pod from the Service's EndpointSlice **without** restarting it
- Liveness restarts a hung process, and probe-level `terminationGracePeriodSeconds`

### Steps

1. Create the namespace, a client Pod and the first (bad) version of the API. The `sh -c` wrapper simulates the
cache warm-up (the `trap … wait` pattern makes the shell react to SIGTERM during the `sleep`):

```bash
workstation$ kubectl create namespace lab-01-03
workstation$ kubectl config set-context --current --namespace=lab-01-03
workstation$ kubectl run client --image=curlimages/curl:8.23.0 --command -- sleep infinity
workstation$ kubectl apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: catalog-api
spec:
  replicas: 3
  selector:
    matchLabels: {app: catalog-api}
  template:
    metadata:
      labels: {app: catalog-api}
    spec:
      containers:
      - name: podinfo
        image: ghcr.io/stefanprodan/podinfo:6.17.0
        # simulate a 30 s cache warm-up before the HTTP server starts listening
        command: ["sh", "-c", "trap 'exit 0' TERM; echo warming up cache; sleep 30 & wait $!; exec ./podinfo --port=9898"]
        ports:
        - {name: http, containerPort: 9898}
        livenessProbe:
          httpGet: {path: /healthz, port: http}
          initialDelaySeconds: 5
          periodSeconds: 5
          failureThreshold: 3
---
apiVersion: v1
kind: Service
metadata:
  name: catalog-api
spec:
  selector: {app: catalog-api}
  ports:
  - {name: http, port: 80, targetPort: http}
EOF
```

2. Problem one: right away the Pods claim to be ready, but the Service does not work:

```bash
workstation$ kubectl get pods -l app=catalog-api
workstation$ kubectl exec client -- curl -sS -m 2 http://catalog-api/ -o /dev/null -w '%{http_code}\n'
```

Expected:
```
NAME                          READY   STATUS    RESTARTS   AGE
catalog-api-5f47557df-kmhsd   1/1     Running   0          16s
catalog-api-5f47557df-lw8hj   1/1     Running   0          16s
catalog-api-5f47557df-wpq2t   1/1     Running   0          16s

curl: (7) Failed to connect to catalog-api:80 after 7 ms: Could not connect to server
000
```

**Why:** without a readiness probe, a container is "ready" as soon as its process runs. The Service sends traffic
to it even though nothing listens yet.

3. Problem two: wait about 90 seconds and check again:

```bash
workstation$ kubectl get pods -l app=catalog-api
workstation$ kubectl get events --sort-by=.lastTimestamp | grep -E 'Unhealthy|Killing' | tail -3
```

Expected:
```
NAME                          READY   STATUS    RESTARTS      AGE
catalog-api-5f47557df-kmhsd   1/1     Running   4 (16s ago)   96s
catalog-api-5f47557df-lw8hj   1/1     Running   4 (16s ago)   96s
catalog-api-5f47557df-wpq2t   1/1     Running   4 (16s ago)   96s

16s   Normal    Killing     pod/catalog-api-5f47557df-lw8hj   Container podinfo failed liveness probe, will be restarted
1s    Warning   Unhealthy   pod/catalog-api-5f47557df-lw8hj   Liveness probe failed: Get "http://172.16.104.36:9898/healthz": dial tcp 172.16.104.36:9898: connect: connection refused
```

The liveness probe kills the container after 5 s + 3 × 5 s = 20 s, before the 30 s warm-up is over. The app can
**never** start. Increasing `initialDelaySeconds` only "works" until the warm-up gets slower on a busy node.

4. Fix it with three probes, each with its own job:

```bash
workstation$ kubectl apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: catalog-api
spec:
  replicas: 3
  selector:
    matchLabels: {app: catalog-api}
  template:
    metadata:
      labels: {app: catalog-api}
    spec:
      shareProcessNamespace: true      # only so that we can freeze the process in step 6
      containers:
      - name: podinfo
        image: ghcr.io/stefanprodan/podinfo:6.17.0
        command: ["sh", "-c", "trap 'exit 0' TERM; echo warming up cache; sleep 30 & wait $!; exec ./podinfo --port=9898"]
        ports:
        - {name: http, containerPort: 9898}
        startupProbe:                  # gives the app up to 12 x 5 s = 60 s to start
          httpGet: {path: /healthz, port: http}
          periodSeconds: 5
          failureThreshold: 12
        readinessProbe:                # "may I get traffic right now?"
          httpGet: {path: /readyz, port: http}
          periodSeconds: 2
          failureThreshold: 1
        livenessProbe:                 # "are you hopelessly stuck?"
          httpGet: {path: /healthz, port: http}
          periodSeconds: 5
          timeoutSeconds: 1
          failureThreshold: 3
          terminationGracePeriodSeconds: 5
EOF
workstation$ kubectl rollout status deploy/catalog-api --timeout=180s
workstation$ kubectl get pods -l app=catalog-api
```

Expected (the rollout takes ~2 minutes because each new Pod needs 30 s to become ready):
```
deployment "catalog-api" successfully rolled out
NAME                           READY   STATUS    RESTARTS   AGE
catalog-api-77787fd69c-hpwj4   1/1     Running   0          106s
catalog-api-77787fd69c-m9lr6   1/1     Running   0          35s
catalog-api-77787fd69c-wsmd4   1/1     Running   0          71s
```

**Why:** liveness and readiness probes do not run until the startup probe has succeeded once. The startup probe
can be generous (60 s) without making the liveness probe slow to detect a hang later. Readiness also makes the
rolling update safe: an old Pod is only removed after a new one is *ready*.

5. Take one Pod out of the load balancer, the way an app does when it loses a backend or starts to shut down.
podinfo has an endpoint that makes `/readyz` return 503:

```bash
workstation$ P=$(kubectl get pod -l app=catalog-api -o jsonpath='{.items[0].metadata.name}')
workstation$ IP=$(kubectl get pod $P -o jsonpath='{.status.podIP}')
workstation$ kubectl exec client -- curl -s -X POST http://$IP:9898/readyz/disable -w '%{http_code}\n'
workstation$ kubectl get pods -l app=catalog-api
workstation$ kubectl get endpointslice -l kubernetes.io/service-name=catalog-api \
  -o jsonpath='{range .items[0].endpoints[*]}{.targetRef.name}{" ready="}{.conditions.ready}{"\n"}{end}'
workstation$ kubectl exec client -- sh -c 'for i in $(seq 1 30); do curl -s http://catalog-api/ | grep -o "catalog-api-[a-z0-9-]*"; done | sort | uniq -c'
```

Expected:
```
202
NAME                           READY   STATUS    RESTARTS   AGE
catalog-api-77787fd69c-hpwj4   0/1     Running   0          2m
catalog-api-77787fd69c-m9lr6   1/1     Running   0          49s
catalog-api-77787fd69c-wsmd4   1/1     Running   0          85s

catalog-api-77787fd69c-hpwj4 ready=false
catalog-api-77787fd69c-wsmd4 ready=true
catalog-api-77787fd69c-m9lr6 ready=true

     14 catalog-api-77787fd69c-m9lr6
     16 catalog-api-77787fd69c-wsmd4
```

The Pod is still `Running` with 0 restarts, but it is marked `ready=false` in the EndpointSlice, and kube-proxy
no longer sends it traffic. Put it back with `/readyz/enable`:

```bash
workstation$ kubectl exec client -- curl -s -X POST http://$IP:9898/readyz/enable
workstation$ kubectl get pods -l app=catalog-api      # all 1/1 again after ~2 s
```

6. Now simulate a deadlock: freeze the process with `SIGSTOP`. It still "exists", but it no longer answers. (This
works because `shareProcessNamespace: true` makes `pause` PID 1, so podinfo is an ordinary process we may stop.)

```bash
workstation$ P=$(kubectl get pod -l app=catalog-api -o jsonpath='{.items[1].metadata.name}')
workstation$ kubectl exec $P -- sh -c 'kill -STOP $(pidof podinfo)'
workstation$ kubectl get pod $P -w
```

Expected:
```
NAME                           READY   STATUS    RESTARTS      AGE
catalog-api-77787fd69c-m9lr6   1/1     Running   0             61s
catalog-api-77787fd69c-m9lr6   0/1     Running   0             62s
catalog-api-77787fd69c-m9lr6   0/1     Running   1 (1s ago)    82s
catalog-api-77787fd69c-m9lr6   1/1     Running   1 (34s ago)   115s
```

Show the timeline (Ctrl+C the watch first):

```bash
workstation$ kubectl get events --field-selector involvedObject.name=$P -o json \
  | jq -r '.items | sort_by(.lastTimestamp)[] | [.lastTimestamp, (.count|tostring), .reason, .message[0:100]] | @tsv'
```

Expected (trimmed):
```
2026-11-04T02:46:06Z  11  Unhealthy  Readiness probe failed: Get "http://172.16.166.141:9898/readyz": context deadline exceeded (Client.Timeout exceeded ...
2026-11-04T02:46:02Z  3   Unhealthy  Liveness probe failed: Get "http://172.16.166.141:9898/healthz": context deadline exceeded (Client.Timeout exceeded ...
2026-11-04T02:46:02Z  1   Killing    Container podinfo failed liveness probe, will be restarted
2026-11-04T02:46:08Z  2   Started    Container started
```

**Why:** readiness reacted within ~2 s (out of the Service), liveness after 3 × 5 s (restart). A frozen process
ignores SIGTERM, so the kubelet has to wait for the grace period before it sends SIGKILL (`exitCode: 137` in
`lastState`). The probe-level `terminationGracePeriodSeconds: 5` shortens that wait for liveness kills only;
normal shutdowns still get the Pod's 30 s. You may see one or two stray `connection refused` probe events right
after the restart; they do not count toward a new restart.

**Pitfall:** never point a liveness probe at something *outside* the container (database, another API). When the
database goes down, every Pod gets restarted at the same time and recovery gets slower. Dependencies belong in
readiness, if anywhere.

### Clean up

```bash
workstation$ kubectl delete namespace lab-01-03
workstation$ kubectl config set-context --current --namespace=default
```

### Your turn

Two new requirements for `catalog-api` (keep working in `lab-01-03`):

1. The catalog doubled in size: the warm-up now takes **70 s** (change `sleep 30` to `sleep 70`). The rollout must
   finish without a single restart.
2. Operations wants to **drain** a single Pod for debugging, without restarting it and without calling the app's
   API: `kubectl exec <pod> -- touch /tmp/drain` must take the Pod out of the Service, and removing the file must bring
   it back. The app's own `/readyz` must still be respected.

<details><summary>Solution</summary>

- Startup budget = `periodSeconds × failureThreshold` must be safely above 70 s: 5 s × 24 = 120 s.
- Readiness becomes an `exec` probe that combines both conditions. The podinfo image has `wget`. Exec probes run inside
  the container, so `localhost` is the container itself.
- `shareProcessNamespace` and the probe-level grace period were only needed for the freeze demo.

```bash
workstation$ kubectl apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: catalog-api
spec:
  replicas: 3
  selector:
    matchLabels: {app: catalog-api}
  template:
    metadata:
      labels: {app: catalog-api}
    spec:
      containers:
      - name: podinfo
        image: ghcr.io/stefanprodan/podinfo:6.17.0
        command: ["sh", "-c", "trap 'exit 0' TERM; echo warming up cache; sleep 70 & wait $!; exec ./podinfo --port=9898"]
        ports:
        - {name: http, containerPort: 9898}
        startupProbe:                  # 24 x 5 s = 120 s budget for a 70 s warm-up
          httpGet: {path: /healthz, port: http}
          periodSeconds: 5
          failureThreshold: 24
        readinessProbe:                # not ready if draining OR the app says so
          exec:
            command: ["sh", "-c", "test ! -f /tmp/drain && wget -q -O /dev/null http://localhost:9898/readyz"]
          periodSeconds: 2
          failureThreshold: 1
        livenessProbe:
          httpGet: {path: /healthz, port: http}
          periodSeconds: 5
          timeoutSeconds: 1
          failureThreshold: 3
EOF
workstation$ kubectl rollout status deploy/catalog-api --timeout=400s
workstation$ kubectl get pods -l app=catalog-api
```

Expected (about 4 minutes, 0 restarts; if an old Pod is still `Terminating`, wait until it is gone before the next step):
```
deployment "catalog-api" successfully rolled out
NAME                           READY   STATUS    RESTARTS   AGE
catalog-api-84ffdf955d-8g8w6   1/1     Running   0          2m40s
catalog-api-84ffdf955d-slw5q   1/1     Running   0          84s
catalog-api-84ffdf955d-vz5lz   1/1     Running   0          3m55s
```

Drain one Pod and undrain it again:

```bash
workstation$ P=$(kubectl get pod -l app=catalog-api -o jsonpath='{.items[0].metadata.name}')
workstation$ kubectl exec $P -- touch /tmp/drain; sleep 4
workstation$ kubectl get endpointslice -l kubernetes.io/service-name=catalog-api \
  -o jsonpath='{range .items[0].endpoints[*]}{.targetRef.name}{" ready="}{.conditions.ready}{"\n"}{end}'
workstation$ kubectl exec $P -- rm /tmp/drain; sleep 4
workstation$ kubectl get pods -l app=catalog-api
```

Expected:
```
catalog-api-84ffdf955d-vz5lz ready=true
catalog-api-84ffdf955d-8g8w6 ready=false
catalog-api-84ffdf955d-slw5q ready=true

NAME                           READY   STATUS    RESTARTS   AGE
catalog-api-84ffdf955d-8g8w6   1/1     Running   0          3m10s
catalog-api-84ffdf955d-slw5q   1/1     Running   0          114s
catalog-api-84ffdf955d-vz5lz   1/1     Running   0          4m25s
```

The file lives in the container's writable layer, so a restart would also "undrain" the Pod. For a drain that
survives restarts, use a label change instead: remove the Pod from the Service selector with
`kubectl label pod $P app-` (the ReplicaSet then creates a replacement, and the drained Pod stays around for
debugging).

</details>

---

## Lab 1.4: Requests, Limits and QoS: OOMKilled vs Throttled

**Scenario** – Two tickets arrive on the same day. "The thumbnailer is 4× slower in Kubernetes than on my laptop"
and "the session cache restarts randomly during traffic peaks". Both are about resource limits, but they fail in
completely different ways. We will reproduce both, read the evidence straight from the cgroup files, and see
how requests and limits decide a Pod's QoS class and who dies first when a node runs out of memory.

**What you'll learn**
- Requests are for the scheduler, limits are enforced by the kernel (cgroups v2)
- CPU over the limit = **throttled** (slow); memory over the limit = **OOMKilled**
- QoS classes `Guaranteed` / `Burstable` / `BestEffort` and their `oom_score_adj`
- Reading `cpu.stat`, `cpu.max` and `memory.events` inside a container

### Steps

1. Create the namespace and three Pods with different resource settings:

```bash
workstation$ kubectl create namespace lab-01-04
workstation$ kubectl config set-context --current --namespace=lab-01-04
workstation$ kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: thumbnailer
  labels: {app: thumbnailer}
spec:
  containers:
  - name: worker
    image: polinux/stress:1.0.4
    command: ["stress", "--cpu", "2"]          # wants 2 full CPUs
    resources:
      requests: {cpu: 500m, memory: 64Mi}
      limits:   {cpu: 500m, memory: 64Mi}
---
apiVersion: v1
kind: Pod
metadata:
  name: session-cache
  labels: {app: session-cache}
spec:
  containers:
  - name: cache
    image: polinux/stress:1.0.4
    command: ["stress", "--vm", "1", "--vm-bytes", "150M", "--vm-hang", "0"]
    resources:
      requests: {cpu: 100m, memory: 128Mi}
      limits:   {memory: 256Mi}
---
apiVersion: v1
kind: Pod
metadata:
  name: debug-shell
spec:
  containers:
  - name: shell
    image: busybox:1.38
    command: ["sleep", "infinity"]
EOF
workstation$ kubectl wait --for=condition=Ready pod --all --timeout=60s
```

2. Check the QoS class Kubernetes derived from the resource settings, and what it means for the kernel's
OOM killer:

```bash
workstation$ kubectl get pods -o custom-columns=NAME:.metadata.name,QOS:.status.qosClass,NODE:.spec.nodeName
workstation$ for p in thumbnailer session-cache debug-shell; do echo "$p: $(kubectl exec $p -- cat /proc/1/oom_score_adj)"; done
```

Expected:
```
NAME            QOS          NODE
debug-shell     BestEffort   node2
session-cache   Burstable    node2
thumbnailer     Guaranteed   node1

thumbnailer: -997
session-cache: 992
debug-shell: 1000
```

**Why:** `Guaranteed` = every container has requests == limits for CPU *and* memory. `BestEffort` = no requests or
limits at all. Everything else is `Burstable`. The kubelet sets `oom_score_adj` from the class. When the **node**
runs out of memory, the kernel kills the highest score first (BestEffort), and Guaranteed Pods last. The node-pressure
eviction of the kubelet uses the same order.

3. **Ticket 1, the slow thumbnailer.** Wait ~45 s for metrics-server, then compare usage with the limit and read the
CPU controller of the container's cgroup:

```bash
workstation$ kubectl top pods
workstation$ kubectl exec thumbnailer -- sh -c 'cat /sys/fs/cgroup/cpu.max; cat /sys/fs/cgroup/cpu.stat'
```

Expected:
```
NAME            CPU(cores)   MEMORY(bytes)
debug-shell     0m           0Mi
session-cache   0m           150Mi
thumbnailer     497m         0Mi

50000 100000
usage_usec 22116224
...
nr_periods 463
nr_throttled 411
throttled_usec 17876199
```

`cpu.max` = `50000 100000`: at most 50 ms of CPU time per 100 ms period, which is 500m. The process wants two
cores, so it uses up its quota early in almost every period (`nr_throttled` 411 of 463) and then waits. It is
never killed, only **slowed down**. On a laptop without limits it would get two full cores, which explains the
"4× slower" ticket. Many teams set CPU *requests* (for fair scheduling) but no CPU *limits* for latency-sensitive
services. Memory limits stay, because memory cannot be throttled.

4. **Ticket 2, the restarting cache.** It uses 150 Mi of its 256 Mi limit. Simulate a traffic peak by
starting a second 150 MB allocation inside the same container:

```bash
workstation$ kubectl exec session-cache -- cat /sys/fs/cgroup/memory.max /sys/fs/cgroup/memory.oom.group
workstation$ kubectl exec session-cache -- stress --vm 1 --vm-bytes 150M --vm-hang 0 --timeout 30
workstation$ kubectl get pod session-cache
workstation$ kubectl get pod session-cache -o jsonpath='{.status.containerStatuses[0].lastState}{"\n"}'
```

Expected:
```
268435456
1
stress: info: [7] dispatching hogs: 0 cpu, 0 io, 1 vm, 0 hdd
command terminated with exit code 137

NAME            READY   STATUS    RESTARTS     AGE
session-cache   1/1     Running   1 (3s ago)   62s
{"terminated":{...,"exitCode":137,"finishedAt":"2026-11-04T02:53:18Z","reason":"OOMKilled",...}}
```

**Why:** 150 Mi + 150 Mi > 256 Mi (`memory.max` = 268435456 bytes). The kernel cannot slow down memory
allocation, so it kills. `memory.oom.group = 1` (the kubelet's default on cgroup v2) means that the **whole
container** is killed, not only the process that asked for the memory. So the original cache process died too,
and the container restarted with an empty cache. That is the "random restart" in the ticket. The only fixes are
a higher limit or an app that uses less memory (e.g. a `maxmemory` setting for Redis).

**Pitfall:** `OOMKilled` in `lastState` means the *container's* limit was hit. If a Pod instead shows
`Status: Failed, Reason: Evicted`, the *node* ran out of memory and the kubelet evicted it, starting with
BestEffort Pods and Pods that use more than they requested.

5. Requests are what the scheduler counts, no matter what the Pods really use. Look at the node that runs the
thumbnailer:

```bash
workstation$ kubectl describe node $(kubectl get pod thumbnailer -o jsonpath='{.spec.nodeName}') \
  | sed -n '/Non-terminated Pods/,$p' | grep -E 'Namespace|lab-01-04|Allocated|cpu |memory '
```

Expected (the totals include the system Pods on that node):
```
  Namespace   Name          CPU Requests  CPU Limits  Memory Requests  Memory Limits  Age
  lab-01-04   thumbnailer   500m (12%)    500m (12%)  64Mi (0%)        64Mi (0%)      3s
Allocated resources:
  cpu                950m (23%)  500m (12%)
  memory             328Mi (2%)  320Mi (2%)
```

The thumbnailer burns only 500m, but even if it were idle, those 500m would stay reserved. Over-sized requests waste
capacity, and under-sized ones overload nodes. Lab 1.1's `invoices` Pod could not be scheduled for this reason.

### Clean up

```bash
workstation$ kubectl delete namespace lab-01-04
workstation$ kubectl config set-context --current --namespace=default
```

### Your turn

The namespace is shared by several teams, and people keep deploying Pods without any resources (like
`debug-shell`). These Pods are first in line to be killed, and the scheduler cannot place them sensibly. Make sure
that **every new container** in `lab-01-04` gets a request of 100m CPU / 128Mi and a limit of 500m / 256Mi when
it does not specify them, and that nobody can set a limit above 1 CPU or 1Gi. Prove it with a Pod without resources
(`report-gen`) and a Pod that asks for a 2 CPU limit (`greedy`). What happens to `debug-shell`?

<details><summary>Solution</summary>

A `LimitRange` is enforced by an admission plugin when a Pod is created:

```bash
workstation$ kubectl apply -f - <<'EOF'
apiVersion: v1
kind: LimitRange
metadata:
  name: container-defaults
spec:
  limits:
  - type: Container
    defaultRequest: {cpu: 100m, memory: 128Mi}   # used when requests are missing
    default:        {cpu: 500m, memory: 256Mi}   # used when limits are missing
    max:            {cpu: "1",  memory: 1Gi}     # nobody may ask for more
EOF
workstation$ kubectl describe limitrange container-defaults
workstation$ kubectl run report-gen --image=busybox:1.38 -- sleep infinity
workstation$ kubectl get pod report-gen -o jsonpath='{.status.qosClass}{"\n"}{.spec.containers[0].resources}{"\n"}'
workstation$ kubectl run greedy --image=polinux/stress:1.0.4 --overrides='{"spec":{"containers":[{"name":"greedy","image":"polinux/stress:1.0.4","command":["stress","--cpu","4"],"resources":{"limits":{"cpu":"2"}}}]}}'
workstation$ kubectl get pod debug-shell -o jsonpath='{.status.qosClass}{"\n"}'
```

Expected:
```
Type        Resource  Min  Max  Default Request  Default Limit  Max Limit/Request Ratio
----        --------  ---  ---  ---------------  -------------  -----------------------
Container   cpu       -    1    100m             500m           -
Container   memory    -    1Gi  128Mi            256Mi          -

Burstable
{"limits":{"cpu":"500m","memory":"256Mi"},"requests":{"cpu":"100m","memory":"128Mi"}}

Error from server (Forbidden): pods "greedy" is forbidden: maximum cpu usage per Container is 1, but limit is 2

BestEffort
```

`debug-shell` stays `BestEffort`: admission only changes objects when they are created, and the resources of
a running Pod are not rewritten. Recreate old Pods (or roll out their Deployments) to pick up the defaults. Note
that defaults are a safety net, not sizing: a Java service that silently gets the default 256Mi limit will be
OOM-killed at start-up. Per-namespace totals (`ResourceQuota`) are covered in module 06.

</details>

---

## Lab 1.5: Zero-downtime Shutdown

**Scenario** – Customers report failed payments "every time you deploy". Two things are going on in the `checkout`
service. Its Pods need 30 seconds to stop, which makes every rollout slow. And when a Pod stops, requests that are
still in flight are cut off. We will measure both under a load loop, fix the signal handling, and use a `preStop`
hook and `terminationGracePeriodSeconds` until a rollout causes zero errors.

**What you'll learn**
- What happens when a Pod is deleted: endpoint removal and SIGTERM happen **at the same time**
- Why a shell wrapper as PID 1 makes Pods hang for 30 s (and how `exec` fixes it)
- `preStop` hooks (the built-in `sleep` action) and the termination grace period budget
- EndpointSlice conditions `ready` / `serving` / `terminating`

### Steps

1. Create the namespace, a client Pod and the first version of the service. Note the start command: the shell
runs podinfo and then prints a message, a pattern often found in entrypoint scripts:

```bash
workstation$ kubectl create namespace lab-01-05
workstation$ kubectl config set-context --current --namespace=lab-01-05
workstation$ kubectl run client --image=curlimages/curl:8.23.0 --command -- sleep infinity
workstation$ kubectl apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: checkout
spec:
  replicas: 3
  selector:
    matchLabels: {app: checkout}
  template:
    metadata:
      labels: {app: checkout}
    spec:
      containers:
      - name: api
        image: ghcr.io/stefanprodan/podinfo:6.17.0
        command: ["sh", "-c", "echo starting checkout; ./podinfo --port=9898; echo checkout exited with $?"]
        ports:
        - {name: http, containerPort: 9898}
        readinessProbe:
          httpGet: {path: /readyz, port: http}
          periodSeconds: 2
---
apiVersion: v1
kind: Service
metadata:
  name: checkout
spec:
  selector: {app: checkout}
  ports:
  - {name: http, port: 80, targetPort: http}
EOF
workstation$ kubectl rollout status deploy/checkout
```

2. Problem one: deleting a Pod takes suspiciously long:

```bash
workstation$ P=$(kubectl get pod -l app=checkout -o name | head -1)
workstation$ kubectl exec $P -- ps
workstation$ time kubectl delete $P
```

Expected:
```
PID   USER     TIME  COMMAND
    1 app       0:00 sh -c echo starting checkout; ./podinfo --port=9898; echo checkout exited with $?
    2 app       0:00 ./podinfo --port=9898
   10 app       0:00 ps

pod "checkout-95cf84875-jq5rr" deleted from lab-01-05 namespace
real	0m30,839s
```

**Why:** the kubelet sends SIGTERM to **PID 1** of the container only. Here that is `sh`, and a shell running as
PID 1 does not forward signals to its children. The Linux kernel also does not apply the default "terminate"
action to PID 1. Nothing happens until `terminationGracePeriodSeconds` (30 s) runs out and SIGKILL kills everything.
The fix is `exec ./podinfo …`, which replaces the shell so the app *is* PID 1. (busybox `sh` does this by itself
when the program is the last command, which is why the extra `echo` is enough to break it.)

3. Fix the signal handling. To make the second problem visible, the app is now started with
`--server-shutdown-timeout=0s`: like many real apps, it stops shortly after SIGTERM and does not wait for
requests that are still running:

```bash
workstation$ kubectl apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: checkout
spec:
  replicas: 3
  selector:
    matchLabels: {app: checkout}
  template:
    metadata:
      labels: {app: checkout}
    spec:
      containers:
      - name: api
        image: ghcr.io/stefanprodan/podinfo:6.17.0
        # exec: podinfo becomes PID 1 and receives SIGTERM itself
        # --server-shutdown-timeout=0s: simulate an app that does not drain in-flight requests
        command: ["sh", "-c", "echo starting checkout; exec ./podinfo --port=9898 --server-shutdown-timeout=0s"]
        ports:
        - {name: http, containerPort: 9898}
        readinessProbe:
          httpGet: {path: /readyz, port: http}
          periodSeconds: 2
EOF
workstation$ kubectl rollout status deploy/checkout
```

4. Create a small load generator in the client Pod: 8 parallel clients, and each request takes 5 s
(`/delay/5` simulates a slow payment provider). It prints how often each HTTP code came back (`000` = connection
reset or refused):

```bash
workstation$ kubectl exec -i client -- sh -c 'cat > /tmp/load.sh' <<'EOF'
# usage: sh load.sh <seconds> <path>   -- 8 parallel clients, prints a histogram of HTTP codes
end=$(( $(date +%s) + $1 ))
for w in 1 2 3 4 5 6 7 8; do
  ( while [ $(date +%s) -lt $end ]; do
      curl -s -o /dev/null -m 10 -w '%{http_code}\n' "http://checkout$2"
    done ) &
done | sort | uniq -c
EOF
```

5. Run the load for 50 s, and roll out a restart in a second terminal while it runs:

```bash
workstation$ kubectl exec client -- sh /tmp/load.sh 50 /delay/5     # terminal 1
workstation$ kubectl rollout restart deploy/checkout                 # terminal 2, a few seconds later
```

Expected (terminal 1):
```
      4 000
     80 200
```

Pods now stop in ~3 s, but in-flight requests are cut off. (With `/delay/1` you would see almost no errors. The
problem gets worse the longer your requests take.)

**Why:** when a Pod is deleted, two things happen **in parallel**. The kubelet runs `preStop` and then sends
SIGTERM, and the EndpointSlice controller marks the endpoint as not ready, so kube-proxy on *every* node updates
its rules. Nothing makes the kubelet wait for the network side, and nothing waits for running requests.

6. Add a `preStop` hook. During the sleep the Pod is already out of the load balancer, but the process still
runs and finishes what it is doing. SIGTERM is sent only after the hook ends. The `sleep` action is built into the
kubelet, so it also works in distroless images without a `sleep` binary:

```bash
workstation$ kubectl apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: checkout
spec:
  replicas: 3
  selector:
    matchLabels: {app: checkout}
  template:
    metadata:
      labels: {app: checkout}
    spec:
      terminationGracePeriodSeconds: 30     # budget for preStop + app shutdown (default 30)
      containers:
      - name: api
        image: ghcr.io/stefanprodan/podinfo:6.17.0
        command: ["sh", "-c", "echo starting checkout; exec ./podinfo --port=9898 --server-shutdown-timeout=0s"]
        ports:
        - {name: http, containerPort: 9898}
        readinessProbe:
          httpGet: {path: /readyz, port: http}
          periodSeconds: 2
        lifecycle:
          preStop:
            sleep: {seconds: 10}            # keep serving in-flight requests while endpoints are updated
EOF
workstation$ kubectl rollout status deploy/checkout
```

Wait until the old Pods are gone, then repeat the test with a longer load window:

```bash
workstation$ kubectl exec client -- sh /tmp/load.sh 70 /delay/5     # terminal 1
workstation$ kubectl rollout restart deploy/checkout                 # terminal 2
```

Expected:
```
    112 200
```

7. Look at a terminating Pod from the Service's point of view:

```bash
workstation$ P=$(kubectl get pod -l app=checkout -o name | head -1)
workstation$ kubectl delete $P --wait=false
workstation$ kubectl get endpointslice -l kubernetes.io/service-name=checkout \
  -o jsonpath='{range .items[0].endpoints[*]}{.targetRef.name}{" "}{.conditions}{"\n"}{end}'
workstation$ time kubectl wait --for=delete $P --timeout=60s
```

Expected:
```
checkout-8794c957b-4fspx {"ready":true,"serving":true,"terminating":false}
checkout-8794c957b-28kqj {"ready":true,"serving":true,"terminating":false}
checkout-8794c957b-g8z2r {"ready":false,"serving":true,"terminating":true}
checkout-8794c957b-vf4ss {"ready":true,"serving":true,"terminating":false}

real	0m11,829s
```

The terminating Pod is `ready=false` (no new traffic) but `serving=true` (it would still pass readiness).
Load balancers that support it can use `serving` endpoints as a last resort when no ready ones are left.
The Pod takes ~13 s to go away: 10 s preStop + about 3 s of podinfo's own shutdown.

**Pitfall:** the grace period covers preStop **and** the app's shutdown together. If `preStop` sleeps 30 s
with the default 30 s grace period, the app gets SIGTERM and SIGKILL almost at once (the kubelet adds only a one-time
2 s extension).

### Clean up

```bash
workstation$ kubectl delete namespace lab-01-05
workstation$ kubectl config set-context --current --namespace=default
```

### Your turn

Finance has added an **export** endpoint whose requests take up to 20 s (`/delay/20`). With the configuration
from step 6, every export running during a rollout fails:

```bash
workstation$ kubectl exec client -- sh -c 'for i in 1 2 3 4 5 6; do curl -s -o /dev/null -m 60 -w "export $i: %{http_code} in %{time_total}s\n" http://checkout/delay/20 & done; wait'   # terminal 1
workstation$ kubectl rollout restart deploy/checkout     # terminal 2, ~2 s later
```

```
export 1: 000 in 16.443847s
export 6: 000 in 17.606374s
...
```

The developers have now implemented proper draining: with `--server-shutdown-timeout=25s` the app waits up to
25 s for running requests after SIGTERM. Change the Deployment so that exports survive a rollout, keeping the
`preStop` only as long as needed for endpoint propagation. Work out the grace period you need.

<details><summary>Solution</summary>

Budget: 5 s `preStop` (endpoint propagation) + ~3 s podinfo shutdown delay + up to 25 s drain = 33 s. That is more
than the default 30 s, so raise `terminationGracePeriodSeconds` and leave some margin:

```bash
workstation$ kubectl apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: checkout
spec:
  replicas: 3
  selector:
    matchLabels: {app: checkout}
  template:
    metadata:
      labels: {app: checkout}
    spec:
      terminationGracePeriodSeconds: 45     # 5 s preStop + 3 s podinfo delay + 25 s drain + margin
      containers:
      - name: api
        image: ghcr.io/stefanprodan/podinfo:6.17.0
        command: ["sh", "-c", "echo starting checkout; exec ./podinfo --port=9898 --server-shutdown-timeout=25s"]
        ports:
        - {name: http, containerPort: 9898}
        readinessProbe:
          httpGet: {path: /readyz, port: http}
          periodSeconds: 2
        lifecycle:
          preStop:
            sleep: {seconds: 5}             # only covers endpoint propagation now
EOF
workstation$ kubectl rollout status deploy/checkout
```

Wait until the old Pods are gone, then repeat the export test:

```bash
workstation$ kubectl exec client -- sh -c 'for i in 1 2 3 4 5 6; do curl -s -o /dev/null -m 60 -w "export $i: %{http_code} in %{time_total}s\n" http://checkout/delay/20 & done; wait'   # terminal 1
workstation$ kubectl rollout restart deploy/checkout     # terminal 2
```

Expected:
```
export 3: 200 in 20.006608s
export 4: 200 in 20.008038s
export 1: 200 in 20.008288s
export 5: 200 in 20.008832s
export 6: 200 in 20.009334s
export 2: 200 in 20.008249s
```

`kubectl get pods` right after the test still shows old Pods `Terminating`: they wait for their last
connections and then exit on their own, well before the 45 s SIGKILL. You could also just raise the `preStop` to
25 s with the old app, but then *every* Pod takes 25 s to stop even when it is idle. Draining in the app is the
better fix.

</details>

---

## Lab 1.6: Rollout Control: Surge, Pause, Stuck, Undo

**Scenario** – The `storefront` runs 6 replicas and the business does not accept *any* capacity loss during a
release. In this lab you are the release manager for a week. You ship a normal upgrade, then bundle three changes
into a single rollout, then a release references an image tag that was never pushed, and finally you roll back to
a specific older revision. The tools are the `RollingUpdate` knobs, `kubectl rollout` and the
Deployment's conditions.

**What you'll learn**
- `maxSurge` / `maxUnavailable` / `minReadySeconds`, and how ReplicaSets are scaled step by step
- Recording why a revision exists (`kubernetes.io/change-cause`)
- `rollout pause` / `resume` to batch several changes into one rollout
- `progressDeadlineSeconds` and detecting a stuck rollout, `rollout undo` and `--to-revision`

### Steps

1. Create the namespace, a client and the first release:

```bash
workstation$ kubectl create namespace lab-01-06
workstation$ kubectl config set-context --current --namespace=lab-01-06
workstation$ kubectl run client --image=curlimages/curl:8.23.0 --command -- sleep infinity
workstation$ kubectl apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: storefront
  annotations:
    kubernetes.io/change-cause: "initial release 6.15.0"
spec:
  replicas: 6
  revisionHistoryLimit: 5
  progressDeadlineSeconds: 60
  minReadySeconds: 5
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1          # at most 7 Pods during the rollout
      maxUnavailable: 0    # never fewer than 6 available Pods
  selector:
    matchLabels: {app: storefront}
  template:
    metadata:
      labels: {app: storefront}
    spec:
      containers:
      - name: web
        image: ghcr.io/stefanprodan/podinfo:6.15.0
        ports:
        - {name: http, containerPort: 9898}
        readinessProbe:
          httpGet: {path: /readyz, port: http}
          periodSeconds: 2
        resources:
          requests: {cpu: 20m, memory: 32Mi}
---
apiVersion: v1
kind: Service
metadata:
  name: storefront
spec:
  selector: {app: storefront}
  ports:
  - {name: http, port: 80, targetPort: http}
EOF
workstation$ kubectl rollout status deploy/storefront
workstation$ kubectl exec client -- sh -c 'for i in $(seq 20); do curl -s storefront | grep -o "\"version\": \"[0-9.]*\""; done | sort | uniq -c'
```

Expected:
```
deployment "storefront" successfully rolled out
     20 "version": "6.15.0"
```

`progressDeadlineSeconds: 60` is short on purpose for the lab (the default is 600). `minReadySeconds: 5` means a new
Pod has to stay ready for 5 s before it counts as *available*, which catches Pods that crash right after their
first successful probe.

2. Ship 6.16.0 and watch the ReplicaSets in a second terminal:

```bash
workstation$ kubectl get rs -w                                          # terminal 2
workstation$ kubectl annotate deploy/storefront kubernetes.io/change-cause="upgrade to 6.16.0 (JIRA-1234)"
workstation$ kubectl set image deploy/storefront web=ghcr.io/stefanprodan/podinfo:6.16.0
workstation$ kubectl rollout status deploy/storefront
```

Expected (terminal 2, trimmed):
```
NAME                    DESIRED   CURRENT   READY   AGE
storefront-7fd74f4847   6         6         6       20s
storefront-67d54755bd   1         1         0       0s
storefront-67d54755bd   1         1         1       1s
storefront-7fd74f4847   5         6         6       26s
storefront-67d54755bd   2         2         1       6s
storefront-7fd74f4847   5         5         5       26s
...
storefront-67d54755bd   6         6         6       36s
storefront-7fd74f4847   0         0         0       56s
```

**Why:** with `maxSurge: 1, maxUnavailable: 0` the controller may create one extra Pod, waits until it is
*available* (ready + 5 s), then removes one old Pod, and repeats. That takes 6 × ~6 s ≈ 36 s. Bigger surge values
make this faster but need spare cluster capacity. The old ReplicaSet is kept with 0 replicas, and it is what makes
a rollback instant.

3. The marketing team wants three changes at once: the new version, a sale banner and a memory limit. Applied one
by one, they would cause three rollouts. Pause the Deployment, make the changes, then resume:

```bash
workstation$ kubectl rollout pause deploy/storefront
workstation$ kubectl set image deploy/storefront web=ghcr.io/stefanprodan/podinfo:6.17.0
workstation$ kubectl set env deploy/storefront PODINFO_UI_MESSAGE="Black Friday sale"
workstation$ kubectl set resources deploy/storefront -c web --limits=memory=128Mi
workstation$ kubectl annotate deploy/storefront kubernetes.io/change-cause="6.17.0 + sale banner + memory limit"
workstation$ kubectl get rs
workstation$ kubectl rollout resume deploy/storefront
workstation$ kubectl rollout status deploy/storefront
workstation$ kubectl rollout history deploy/storefront
workstation$ kubectl exec client -- curl -s storefront | grep -E 'version|message'
```

Expected:
```
NAME                    DESIRED   CURRENT   READY   AGE
storefront-67d54755bd   6         6         6       47s
storefront-7fd74f4847   0         0         0       67s
...
REVISION  CHANGE-CAUSE
1         initial release 6.15.0
2         upgrade to 6.16.0 (JIRA-1234)
3         6.17.0 + sale banner + memory limit

  "version": "6.17.0",
  "message": "Black Friday sale",
```

While the Deployment was paused, no new ReplicaSet appeared. Changes to the Pod template are only recorded. One
resume gives one revision. (`kubectl rollout status` on a paused Deployment just waits, so use a `--timeout`
in scripts.)

4. The next release references `6.18.0`, a tag that the CI pipeline announced but never pushed:

```bash
workstation$ kubectl annotate deploy/storefront kubernetes.io/change-cause="upgrade to 6.18.0"
workstation$ kubectl set image deploy/storefront web=ghcr.io/stefanprodan/podinfo:6.18.0
workstation$ time kubectl rollout status deploy/storefront --timeout=120s; echo "exit code: $?"
```

Expected:
```
Waiting for deployment "storefront" rollout to finish: 1 out of 6 new replicas have been updated...
error: deployment "storefront" exceeded its progress deadline
real	1m0,136s
exit code: 1
```

`rollout status` fails with exit code 1 after `progressDeadlineSeconds`. This is how a CI/CD pipeline detects a
failed deployment. Look at the state:

```bash
workstation$ kubectl get deploy storefront
workstation$ kubectl get pods -l app=storefront
workstation$ kubectl get deploy storefront -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.reason}: {.message}{"\n"}{end}'
workstation$ kubectl exec client -- sh -c 'for i in $(seq 20); do curl -s storefront | grep -o "\"version\": \"[0-9.]*\""; done | sort | uniq -c'
```

Expected:
```
NAME         READY   UP-TO-DATE   AVAILABLE   AGE
storefront   6/6     1            6           2m57s

NAME                          READY   STATUS         RESTARTS   AGE
storefront-5955d766cc-qvslb   0/1     ErrImagePull   0          61s
storefront-b95f76c5d-8gfxf    1/1     Running        0          105s
... 5 more Running 6.17.0 Pods

Available=True MinimumReplicasAvailable: Deployment has minimum availability.
Progressing=False ProgressDeadlineExceeded: ReplicaSet "storefront-5955d766cc" has timed out progressing.

     20 "version": "6.17.0"
```

**Why:** thanks to `maxUnavailable: 0` the broken release never took a single old Pod away. Users saw no
impact. Kubernetes does **not** roll back by itself after the deadline. It only reports `Progressing=False`.
Deciding what to do is up to you (or your pipeline).

5. Roll back. `undo` goes to the previous revision; `--to-revision` goes to any revision still in the history:

```bash
workstation$ kubectl rollout undo deploy/storefront
workstation$ kubectl rollout status deploy/storefront
workstation$ kubectl rollout history deploy/storefront
```

Expected:
```
Warning: resource deployments/storefront was previously managed with 'kubectl apply'. Rolling back will not update the kubectl.kubernetes.io/last-applied-configuration annotation, ...
deployment.apps/storefront rolled back
deployment "storefront" successfully rolled out

REVISION  CHANGE-CAUSE
1         initial release 6.15.0
2         upgrade to 6.16.0 (JIRA-1234)
4         upgrade to 6.18.0
5         6.17.0 + sale banner + memory limit
```

Revision 3 has become revision 5: a rollback does not create a new ReplicaSet, it scales the old one back up
and gives it the next number. Now suppose 6.17.0 also turns out to be bad. Inspect revision 2 and go there:

```bash
workstation$ kubectl rollout history deploy/storefront --revision=2 | grep -E 'Image|change-cause'
workstation$ kubectl rollout undo deploy/storefront --to-revision=2
workstation$ kubectl rollout status deploy/storefront
workstation$ kubectl get rs -o wide
```

Expected:
```
  Annotations:	kubernetes.io/change-cause: upgrade to 6.16.0 (JIRA-1234)
    Image:	ghcr.io/stefanprodan/podinfo:6.16.0

NAME                    DESIRED   CURRENT   READY   AGE     CONTAINERS   IMAGES
storefront-5955d766cc   0         0         0       104s    web          ghcr.io/stefanprodan/podinfo:6.18.0
storefront-67d54755bd   6         6         6       3m20s   web          ghcr.io/stefanprodan/podinfo:6.16.0
storefront-7fd74f4847   0         0         0       3m40s   web          ghcr.io/stefanprodan/podinfo:6.15.0
storefront-b95f76c5d    0         0         0       2m28s   web          ghcr.io/stefanprodan/podinfo:6.17.0
```

**Pitfall:** read the warning from `undo`. The live object no longer matches your YAML in Git, and the next
`kubectl apply` of the old file redeploys whatever the file says. After an emergency rollback, always fix the
source of truth too. `revisionHistoryLimit` (here 5) decides how far back you can go.

### Clean up

```bash
workstation$ kubectl delete namespace lab-01-06
workstation$ kubectl config set-context --current --namespace=default
```

### Your turn

Black Friday is coming. The storefront is scaled to **10 replicas**. The new rule: during a rollout there may be
**at most 12 Pods** (the cluster has limited spare capacity), and **never fewer than 9 available**. Go back to the
declarative way of working: write a manifest (no imperative `set` commands) that ships 6.17.0 to all 10 replicas
under these rules with a proper change-cause, apply it, and *prove* both limits by sampling the Deployment status
during the rollout.

<details><summary>Solution</summary>

`maxSurge: 2` → 10 + 2 = 12 Pods at most; `maxUnavailable: 1` → 10 − 1 = 9 available at least. The controller can
now replace up to 3 Pods per step, so the rollout is faster than with 1/0. Percentages work too, but they are
rounded (surge **up**, unavailable **down**), so absolute numbers are clearer here.

```bash
workstation$ kubectl scale deploy/storefront --replicas=10
workstation$ kubectl rollout status deploy/storefront
workstation$ kubectl apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: storefront
  annotations:
    kubernetes.io/change-cause: "6.17.0 for Black Friday, 10 replicas"
spec:
  replicas: 10
  revisionHistoryLimit: 5
  progressDeadlineSeconds: 60
  minReadySeconds: 5
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 2          # at most 12 Pods during the rollout
      maxUnavailable: 1    # never fewer than 9 available Pods
  selector:
    matchLabels: {app: storefront}
  template:
    metadata:
      labels: {app: storefront}
    spec:
      containers:
      - name: web
        image: ghcr.io/stefanprodan/podinfo:6.17.0
        ports:
        - {name: http, containerPort: 9898}
        readinessProbe:
          httpGet: {path: /readyz, port: http}
          periodSeconds: 2
        resources:
          requests: {cpu: 20m, memory: 32Mi}
EOF
workstation$ (while true; do kubectl get deploy storefront -o jsonpath='{.status.replicas} {.status.availableReplicas}{"\n"}'; sleep 0.5; done > /tmp/samples.txt) & SAMPLER=$!
workstation$ time kubectl rollout status deploy/storefront >/dev/null; kill $SAMPLER
workstation$ echo "max pods: $(sort -n /tmp/samples.txt | tail -1 | cut -d' ' -f1)  min available: $(sort -k2 -n /tmp/samples.txt | head -1 | cut -d' ' -f2)"
workstation$ kubectl rollout history deploy/storefront | tail -2
```

Expected:
```
real	0m25,861s
max pods: 12  min available: 9
7         6.17.0 for Black Friday, 10 replicas
```

`replicas: 10` is in the manifest on purpose. If the Deployment were managed by an HPA (module 07), you would
leave `replicas` out of the manifest so that `apply` does not fight the autoscaler. Delete `/tmp/samples.txt`
afterwards.

</details>

---

## Lab 1.7: Batch Work: Indexed Jobs and Database Backups

**Scenario** – Month-end at the billing team. Invoices must be rendered for six regions in parallel. One region's
input file is known to be corrupt sometimes, and that must not burn retries or block the other regions. Node
maintenance must not count as a failure either. The same team also needs a regular `pg_dump` of the orders
database to S3 (MinIO), with no overlapping runs and a way to pause backups during a migration.

**What you'll learn**
- Indexed Jobs: `JOB_COMPLETION_INDEX`, `completions` / `parallelism`, per-index status
- `backoffLimitPerIndex`, `maxFailedIndexes` and `podFailurePolicy` (`FailIndex`, `Ignore` on `DisruptionTarget`)
- CronJob `concurrencyPolicy`, `startingDeadlineSeconds`, `timeZone`, history limits, `suspend`
- Running a CronJob on demand with `kubectl create job --from=cronjob/…`

### Steps

**Part A: month-end invoice run**

1. Create the namespace, the work list and the Job. Each Pod handles the line of `regions.txt` that matches its
index. Exit code 42 means "bad input". The `trap` makes an interrupted Pod exit with 143 instead of finishing
during its grace period:

```bash
workstation$ kubectl create namespace lab-01-07
workstation$ kubectl config set-context --current --namespace=lab-01-07
workstation$ kubectl apply -f - <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: billing-regions
data:
  regions.txt: |
    eu-north
    eu-west
    eu-central
    us-east   corrupt
    us-west
    ap-south
---
apiVersion: batch/v1
kind: Job
metadata:
  name: monthly-invoices
spec:
  completionMode: Indexed
  completions: 6              # one Pod per line of regions.txt, index 0..5
  parallelism: 3
  backoffLimitPerIndex: 1     # each index may be retried once
  maxFailedIndexes: 2         # give up on the whole Job if more than 2 indexes fail
  podFailurePolicy:
    rules:
    - action: FailIndex       # bad input: retrying will not help
      onExitCodes:
        containerName: render
        operator: In
        values: [42]
    - action: Ignore          # evicted / preempted: does not count as a failure
      onPodConditions:
      - type: DisruptionTarget
  template:
    spec:
      restartPolicy: Never    # required for podFailurePolicy
      containers:
      - name: render
        image: busybox:1.38
        command: ["sh", "-c"]
        args:
        - |
          trap 'echo "[index $JOB_COMPLETION_INDEX] interrupted"; exit 143' TERM
          line=$(sed -n "$((JOB_COMPLETION_INDEX + 1))p" /work/regions.txt)
          region=${line%% *}
          echo "[index $JOB_COMPLETION_INDEX] rendering invoices for $region"
          case "$line" in *corrupt*) echo "input for $region is corrupt" >&2; exit 42;; esac
          sleep 20 & wait $!
          echo "[index $JOB_COMPLETION_INDEX] $region done: $((RANDOM % 500 + 100)) invoices"
        volumeMounts:
        - {name: work, mountPath: /work}
      volumes:
      - name: work
        configMap: {name: billing-regions}
EOF
```

2. Within the first 20 s, simulate node maintenance: **evict** the Pod of index 1 through the Eviction API
(this is what `kubectl drain` does for every Pod on a node):

```bash
workstation$ P=$(kubectl get pod -l batch.kubernetes.io/job-completion-index=1 -o jsonpath='{.items[0].metadata.name}')
workstation$ echo "{\"apiVersion\":\"policy/v1\",\"kind\":\"Eviction\",\"metadata\":{\"name\":\"$P\"}}" \
  | kubectl create --raw /api/v1/namespaces/lab-01-07/pods/$P/eviction -f -
workstation$ kubectl get pods -L batch.kubernetes.io/job-completion-index
```

Expected:
```
{"kind":"Status","apiVersion":"v1","metadata":{},"status":"Success","code":201}
NAME                       READY   STATUS    RESTARTS   AGE   JOB-COMPLETION-INDEX
monthly-invoices-0-wpsk7   1/1     Running   0          11s   0
monthly-invoices-1-n9plq   0/1     Error     0          11s   1
monthly-invoices-2-fk6pp   1/1     Running   0          11s   2
```

3. Wait for the Job to finish and look at the per-index result:

```bash
workstation$ kubectl wait --for=condition=Failed job/monthly-invoices --timeout=180s
workstation$ kubectl get job monthly-invoices
workstation$ kubectl get job monthly-invoices -o jsonpath='completed={.status.completedIndexes} failed={.status.failedIndexes} failedPods={.status.failed}{"\n"}{range .status.conditions[*]}{.type}: {.reason}{"\n"}{end}'
workstation$ kubectl get pods -L batch.kubernetes.io/job-completion-index
workstation$ kubectl logs -l batch.kubernetes.io/job-completion-index=3
```

Expected:
```
NAME               STATUS   COMPLETIONS   DURATION   AGE
monthly-invoices   Failed   5/6           52s        52s

completed=0-2,4,5 failed=3 failedPods=1
FailureTarget: FailedIndexes
Failed: FailedIndexes

NAME                       READY   STATUS      RESTARTS   AGE   JOB-COMPLETION-INDEX
monthly-invoices-0-wpsk7   0/1     Completed   0          52s   0
monthly-invoices-1-qk9fr   0/1     Completed   0          34s   1
monthly-invoices-2-fk6pp   0/1     Completed   0          52s   2
monthly-invoices-3-4rd9g   0/1     Error       0          28s   3
monthly-invoices-4-2wvgq   0/1     Completed   0          28s   4
monthly-invoices-5-l86df   0/1     Completed   0          24s   5

[index 3] rendering invoices for us-east
input for us-east is corrupt
```

**Why:**
- **Index 1** was evicted. The Pod got the `DisruptionTarget` condition, the `Ignore` rule matched, and a new Pod
  (`-qk9fr`) did the work. `failedPods=1` shows that the eviction did not count.
- **Index 3** exited with 42, `FailIndex` matched, and the index was marked failed **at once**, without using its one
  retry. With a classic `backoffLimit` the whole Job would have been retried, or failed, as one unit.
- The other indexes finished, and you know exactly which region to re-run (`failedIndexes=3`). The Job's final
  state is `Failed` because at least one index failed. If more than `maxFailedIndexes` had failed, the Job would
  have stopped early.

**Part B: nightly database backup**

4. Deploy a small Postgres (disposable `emptyDir` storage, module 04 covers real volumes) with 1000 orders, a
Secret with the DB and S3 credentials, and a MinIO client Pod that creates the backup bucket:

```bash
workstation$ kubectl delete job monthly-invoices
workstation$ kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Secret
metadata:
  name: backup-credentials
stringData:
  PGPASSWORD: shop-secret
  MC_HOST_s3: http://minioadmin:minioadmin123@192.168.1.100:9000
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: orders-db
spec:
  selector:
    matchLabels: {app: orders-db}
  template:
    metadata:
      labels: {app: orders-db}
    spec:
      containers:
      - name: postgres
        image: postgres:17
        env:
        - {name: POSTGRES_DB, value: shop}
        - name: POSTGRES_PASSWORD
          valueFrom: {secretKeyRef: {name: backup-credentials, key: PGPASSWORD}}
        ports:
        - containerPort: 5432
        readinessProbe:
          exec: {command: ["pg_isready", "-U", "postgres"]}
          periodSeconds: 5
        volumeMounts:
        - {name: data, mountPath: /var/lib/postgresql/data}
      volumes:
      - name: data
        emptyDir: {}          # storage is module 04: this database is disposable
---
apiVersion: v1
kind: Service
metadata:
  name: orders-db
spec:
  selector: {app: orders-db}
  ports:
  - port: 5432
EOF
workstation$ kubectl rollout status deploy/orders-db
workstation$ kubectl exec deploy/orders-db -- psql -U postgres -d shop \
  -c "CREATE TABLE orders (id serial PRIMARY KEY, customer text, total numeric(10,2), created timestamptz DEFAULT now());" \
  -c "INSERT INTO orders (customer, total) SELECT 'customer-' || g, round((random()*500)::numeric, 2) FROM generate_series(1,1000) g;" \
  -c "SELECT count(*), sum(total) FROM orders;"
workstation$ kubectl run mc --image=pgsty/mc:RELEASE.2026-10-26T00-00-00Z \
  --env=MC_HOST_s3=http://minioadmin:minioadmin123@192.168.1.100:9000 --command -- sleep infinity
workstation$ kubectl wait --for=condition=Ready pod/mc
workstation$ kubectl exec mc -- mc mb s3/lab-01-07-backups
```

Expected:
```
 count |    sum
-------+-----------
  1000 | 249960.73
Bucket created successfully `s3/lab-01-07-backups`.
```

5. Create the backup CronJob. The init container writes the dump to a shared `emptyDir`, and the main container
uploads it with the MinIO client (the `MC_HOST_s3` variable configures the S3 alias):

```bash
workstation$ kubectl apply -f - <<'EOF'
apiVersion: batch/v1
kind: CronJob
metadata:
  name: orders-db-backup
spec:
  schedule: "*/2 * * * *"          # every 2 minutes for the lab; nightly would be "0 2 * * *"
  timeZone: "Europe/Warsaw"
  concurrencyPolicy: Forbid        # never run two backups at the same time
  startingDeadlineSeconds: 60      # skip a run that cannot start within 60 s
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 2
  jobTemplate:
    spec:
      backoffLimit: 2
      activeDeadlineSeconds: 600   # kill a hanging backup after 10 min
      template:
        spec:
          restartPolicy: Never
          initContainers:
          - name: dump
            image: postgres:17
            command: ["sh", "-c"]
            args:
            - |
              f=/backup/shop-$(date +%Y%m%d-%H%M%S).dump
              pg_dump -h orders-db -U postgres -d shop -Fc -f "$f" && ls -l "$f"
              sleep "${EXTRA_SECONDS:-0}"     # used later to simulate a slow backup
            env:
            - name: PGPASSWORD
              valueFrom: {secretKeyRef: {name: backup-credentials, key: PGPASSWORD}}
            volumeMounts:
            - {name: backup, mountPath: /backup}
          containers:
          - name: upload
            image: pgsty/mc:RELEASE.2026-10-26T00-00-00Z
            args: ["cp", "--recursive", "/backup/", "s3/lab-01-07-backups/"]
            env:
            - name: MC_HOST_s3
              valueFrom: {secretKeyRef: {name: backup-credentials, key: MC_HOST_s3}}
            volumeMounts:
            - {name: backup, mountPath: /backup}
          volumes:
          - name: backup
            emptyDir: {}
EOF
```

6. Don't wait for the schedule. Before a risky migration you want a backup *now*:

```bash
workstation$ kubectl create job --from=cronjob/orders-db-backup backup-manual-1
workstation$ kubectl wait --for=condition=complete job/backup-manual-1 --timeout=120s
workstation$ kubectl logs job/backup-manual-1 -c dump
workstation$ kubectl exec mc -- mc ls s3/lab-01-07-backups
```

Expected:
```
-rw-r--r-- 1 root root 11025 Nov  4 03:14 /backup/shop-20261104-031413.dump
[2026-11-04 03:14:14 UTC]  11KiB STANDARD shop-20261104-031413.dump
```

The file name is in UTC: `timeZone` only applies to the *schedule*. The containers keep the node's time zone.

7. Now the database has grown and a backup takes longer than the 2-minute interval. Simulate that and observe
`concurrencyPolicy: Forbid` for ~6 minutes:

```bash
workstation$ kubectl set env cronjob/orders-db-backup -c dump EXTRA_SECONDS=150
workstation$ kubectl get jobs -w                 # Ctrl+C after ~6 minutes
workstation$ kubectl get events --field-selector involvedObject.kind=CronJob
```

Expected (trimmed):
```
LAST SEEN   TYPE      REASON             OBJECT                     MESSAGE
6m46s       Warning   UnexpectedJob      cronjob/orders-db-backup   Saw a job that the controller did not create or forgot: backup-manual-1
5m2s        Normal    SuccessfulCreate   cronjob/orders-db-backup   Created job orders-db-backup-29896036
62s         Normal    JobAlreadyActive   cronjob/orders-db-backup   Not starting job because prior execution is running and concurrency policy is Forbid
2m27s       Normal    SawCompletedJob    cronjob/orders-db-backup   Saw completed job: orders-db-backup-29896036, condition: Complete
2m27s       Normal    SuccessfulCreate   cronjob/orders-db-backup   Created job orders-db-backup-29896038
```

**Why:** at the 04:18 tick the 04:16 backup was still running, so the run was not started (`JobAlreadyActive`).
When the first backup finished ~35 s later, the controller started the missed run *late*, because it was still
inside `startingDeadlineSeconds: 60`. With a shorter deadline the run would simply be skipped. The Job name suffix
is the scheduled time in minutes since the epoch, so you can see which tick a Job belongs to. The
`UnexpectedJob` warning is harmless: the manual Job carries an owner reference to the CronJob, which did not create it.
`Allow` (the default) would have run two `pg_dump`s in parallel. `Replace` would have killed the running backup.
Both are wrong for backups.

8. Migration window: suspend the backups, then remove the artificial delay:

```bash
workstation$ kubectl patch cronjob orders-db-backup -p '{"spec":{"suspend":true}}'
workstation$ kubectl set env cronjob/orders-db-backup -c dump EXTRA_SECONDS-
workstation$ kubectl get cronjob
workstation$ kubectl exec mc -- mc ls s3/lab-01-07-backups
```

Expected:
```
NAME               SCHEDULE      TIMEZONE        SUSPEND   ACTIVE   LAST SCHEDULE   AGE
orders-db-backup   */2 * * * *   Europe/Warsaw   True      0        3m21s           7m9s

[2026-11-04 03:14:14 UTC]  11KiB STANDARD shop-20261104-031413.dump
[2026-11-04 03:18:32 UTC]  11KiB STANDARD shop-20261104-031601.dump
[2026-11-04 03:21:07 UTC]  11KiB STANDARD shop-20261104-031835.dump
```

`suspend` does not stop a Job that is already running, it only prevents new ones. When you un-suspend, runs missed
during the window are started only if they are still within `startingDeadlineSeconds`.

### Clean up

```bash
workstation$ kubectl exec mc -- mc rb --force s3/lab-01-07-backups
workstation$ kubectl delete namespace lab-01-07
workstation$ kubectl config set-context --current --namespace=default
```

### Your turn

A backup you have never restored is only a hope. Write a **restore drill** Job (run it before the clean-up) that:

1. downloads the dumps from `s3/lab-01-07-backups`,
2. starts a *throw-away* Postgres inside the same Pod (do not touch `orders-db`),
3. restores the **newest** dump into it and fails unless the `orders` table has at least 1000 rows,
4. and finishes as `Complete`, leaving nothing running.

Hint: you combined exactly these building blocks in Lab 1.2.

<details><summary>Solution</summary>

Init container `fetch` downloads the files. The scratch database is a **native sidecar** with a `startupProbe`, so the
`verify` container only starts once Postgres accepts TCP connections. When `verify` exits, the kubelet stops the
sidecar and the Job completes.

```bash
workstation$ kubectl apply -f - <<'EOF'
apiVersion: batch/v1
kind: Job
metadata:
  name: restore-drill
spec:
  backoffLimit: 0
  activeDeadlineSeconds: 300
  template:
    spec:
      restartPolicy: Never
      initContainers:
      - name: fetch                      # 1. download all dumps from S3
        image: pgsty/mc:RELEASE.2026-10-26T00-00-00Z
        args: ["mirror", "s3/lab-01-07-backups", "/backup"]
        env:
        - name: MC_HOST_s3
          valueFrom: {secretKeyRef: {name: backup-credentials, key: MC_HOST_s3}}
        volumeMounts:
        - {name: backup, mountPath: /backup}
      - name: scratch-db                 # 2. throw-away Postgres as a native sidecar
        image: postgres:17
        restartPolicy: Always
        env:
        - {name: POSTGRES_PASSWORD, value: drill}
        - {name: POSTGRES_DB, value: shop}
        startupProbe:                    # the verify container starts only when this passes
          exec: {command: ["pg_isready", "-h", "127.0.0.1", "-U", "postgres"]}
          periodSeconds: 2
          failureThreshold: 30
      containers:
      - name: verify                     # 3. restore the newest dump and check it
        image: postgres:17
        env:
        - {name: PGPASSWORD, value: drill}
        command: ["sh", "-c"]
        args:
        - |
          latest=$(ls /backup/*.dump | sort | tail -1)
          echo "restoring $latest"
          pg_restore -h 127.0.0.1 -U postgres -d shop --no-owner "$latest" || exit 1
          rows=$(psql -h 127.0.0.1 -U postgres -d shop -tAc "SELECT count(*) FROM orders")
          echo "restored rows: $rows"
          [ "$rows" -ge 1000 ] && echo "RESTORE DRILL PASSED" || { echo "RESTORE DRILL FAILED"; exit 1; }
        volumeMounts:
        - {name: backup, mountPath: /backup}
      volumes:
      - name: backup
        emptyDir: {}
EOF
workstation$ kubectl wait --for=condition=complete job/restore-drill --timeout=180s
workstation$ kubectl get pods -l job-name=restore-drill
workstation$ kubectl logs job/restore-drill -c verify
```

Expected:
```
job.batch/restore-drill condition met
NAME                  READY   STATUS      RESTARTS   AGE
restore-drill-lcpgv   0/2     Completed   0          9s

restoring /backup/shop-20261104-031835.dump
restored rows: 1000
RESTORE DRILL PASSED
```

`pg_isready -h 127.0.0.1` matters: during its first start the Postgres image runs a temporary server on the Unix
socket only, so a socket check could pass too early. To run the drill every week, wrap the same Pod template in a
CronJob (`schedule: "0 6 * * 1"`) and alert on failed Jobs.

</details>

---

## Lab 1.8: A Node Agent on Every Node with a DaemonSet

**Scenario** – The monitoring team runs Prometheus *outside* the cluster, on the admin VM `192.168.1.100`. They
want hardware and OS metrics from **every** node, including the control plane, on a fixed address
`http://<node-ip>:9100/metrics`, and they want new nodes to show up automatically. We deploy Prometheus'
node-exporter as a DaemonSet on the host network, scrape it from the client VM, and look at how DaemonSets schedule and
roll out.

**What you'll learn**
- DaemonSets: one Pod per node, tolerations for the control-plane taint
- `hostNetwork`, `hostPID` and read-only `hostPath` mounts for node agents
- Host-port conflicts and why a DaemonSet with host ports cannot surge
- Rolling updates of a DaemonSet

### Steps

1. Create the namespace and the DaemonSet:

```bash
workstation$ kubectl create namespace lab-01-08
workstation$ kubectl config set-context --current --namespace=lab-01-08
workstation$ kubectl apply -f - <<'EOF'
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: node-exporter
spec:
  selector:
    matchLabels: {app: node-exporter}
  updateStrategy:
    type: RollingUpdate
    rollingUpdate: {maxUnavailable: 1}
  template:
    metadata:
      labels: {app: node-exporter}
    spec:
      hostNetwork: true          # listen on the node's IP, port 9100
      hostPID: true              # see the node's processes
      tolerations:               # also run on the control-plane node
      - key: node-role.kubernetes.io/control-plane
        operator: Exists
        effect: NoSchedule
      containers:
      - name: node-exporter
        image: prom/node-exporter:v1.12.1
        args:
        - --path.procfs=/host/proc
        - --path.sysfs=/host/sys
        - --path.rootfs=/host/root
        - --web.listen-address=:9100
        ports:
        - {name: metrics, containerPort: 9100}
        resources:
          requests: {cpu: 50m, memory: 32Mi}
          limits:   {memory: 128Mi}
        securityContext:
          readOnlyRootFilesystem: true
        volumeMounts:
        - {name: proc, mountPath: /host/proc, readOnly: true}
        - {name: sys,  mountPath: /host/sys,  readOnly: true}
        - {name: root, mountPath: /host/root, readOnly: true, mountPropagation: HostToContainer}
      volumes:
      - {name: proc, hostPath: {path: /proc}}
      - {name: sys,  hostPath: {path: /sys}}
      - {name: root, hostPath: {path: /}}
EOF
workstation$ kubectl rollout status ds/node-exporter
workstation$ kubectl get pods -o wide
```

Expected:
```
daemon set "node-exporter" successfully rolled out
NAME                  READY   STATUS    RESTARTS   AGE   IP             NODE     NOMINATED NODE   READINESS GATES
node-exporter-jlp9r   1/1     Running   0          4s    192.168.1.11   node1    <none>           <none>
node-exporter-lk95l   1/1     Running   0          4s    192.168.1.12   node2    <none>           <none>
node-exporter-xzjm2   1/1     Running   0          4s    192.168.1.10   master   <none>           <none>
```

The Pod IPs are the **node** IPs: with `hostNetwork: true` the container shares the node's network namespace.
`hostPID` and the `/proc`, `/sys` and `/` mounts let the exporter see the real host instead of its own
container. All mounts are read-only, and the exporter needs no privileges.

2. Scrape the nodes the way the external Prometheus would, from the client VM:

```bash
client-vm$ for ip in 192.168.1.10 192.168.1.11 192.168.1.12; do echo "== $ip"; \
  curl -s http://$ip:9100/metrics | grep -E '^node_(load1 |memory_MemAvailable_bytes|uname_info)'; done
```

Expected:
```
== 192.168.1.10
node_load1 2.51
node_memory_MemAvailable_bytes 1.4982356992e+10
node_uname_info{domainname="(none)",machine="x86_64",nodename="master",release="6.12.113+deb13-amd64",...} 1
== 192.168.1.11
node_load1 3.45
node_memory_MemAvailable_bytes 1.5752454144e+10
node_uname_info{...,nodename="node1",...} 1
== 192.168.1.12
...
```

3. Why does the master get a Pod? Compare with a DaemonSet **without** the toleration:

```bash
workstation$ kubectl describe node master | grep Taints
workstation$ kubectl create -f - <<'EOF'
apiVersion: apps/v1
kind: DaemonSet
metadata: {name: probe}
spec:
  selector: {matchLabels: {app: probe}}
  template:
    metadata: {labels: {app: probe}}
    spec:
      containers: [{name: c, image: "busybox:1.38", command: [sleep, infinity]}]
EOF
workstation$ kubectl get ds probe
workstation$ kubectl delete ds probe
```

Expected:
```
Taints:             node-role.kubernetes.io/control-plane:NoSchedule
NAME    DESIRED   CURRENT   READY   UP-TO-DATE   AVAILABLE   NODE SELECTOR   AGE
probe   2         2         2       2            2           <none>          5s
```

DaemonSets respect taints like any other Pod. For a monitoring agent you *want* the control plane too, so the
toleration is required. A log or security agent that skips the masters creates a blind spot.

4. A colleague wants to try a new exporter version side by side, as a second DaemonSet:

```bash
workstation$ kubectl get ds node-exporter -o yaml \
  | sed -e 's/name: node-exporter$/name: node-exporter-v2/' -e 's/app: node-exporter$/app: node-exporter-v2/' \
  | grep -v -E 'resourceVersion|uid:|creationTimestamp' | kubectl apply -f -
workstation$ kubectl get ds
workstation$ kubectl get events --field-selector reason=FailedScheduling -o custom-columns=MSG:.message | tail -1
```

Expected:
```
NAME               DESIRED   CURRENT   READY   UP-TO-DATE   AVAILABLE   NODE SELECTOR   AGE
node-exporter      3         3         3       3            3           <none>          51s
node-exporter-v2   3         3         0       3            0           <none>          8s

0/3 nodes are available: 1 node(s) didn't have free ports for the requested pod ports, 2 node(s) didn't satisfy plugin(s) [NodeAffinity]. ...
```

**Why:** with `hostNetwork`, a `containerPort` is also a **host port**, and the scheduler tracks it. Every node
already has a process on 9100, so the new Pods stay `Pending`. ("2 nodes didn't satisfy NodeAffinity": each
DaemonSet Pod is pinned to exactly one node with node affinity.) The same rule explains the update strategy:
a host-port DaemonSet cannot use `maxSurge` (new Pod next to the old one), only `maxUnavailable`. Each node has a
short gap in its metrics during an update. Remove the experiment:

```bash
workstation$ kubectl delete ds node-exporter-v2
```

5. Roll out a configuration change (enable the `processes` collector) and watch the update move node by node:

```bash
workstation$ kubectl patch ds node-exporter --type=json \
  -p '[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--collector.processes"}]'
workstation$ kubectl rollout status ds/node-exporter
client-vm$ curl -s http://192.168.1.11:9100/metrics | grep -E '^node_processes_(state|threads )'
```

Expected:
```
Waiting for daemon set "node-exporter" rollout to finish: 0 out of 3 new pods have been updated...
Waiting for daemon set "node-exporter" rollout to finish: 1 out of 3 new pods have been updated...
Waiting for daemon set "node-exporter" rollout to finish: 2 out of 3 new pods have been updated...
Waiting for daemon set "node-exporter" rollout to finish: 2 of 3 updated pods are available...
daemon set "node-exporter" successfully rolled out

node_processes_state{state="I"} 81
node_processes_state{state="S"} 111
node_processes_threads 372
```

With `kubectl get pods -w` you would see the order: old Pod `Terminating` → new Pod `Pending` → `Running`, then
the next node. With many nodes, raise `maxUnavailable` (e.g. `10%`) to speed this up.

### Clean up

```bash
workstation$ kubectl delete namespace lab-01-08
workstation$ kubectl config set-context --current --namespace=default
```

### Your turn

The on-call team wants an alert when a node needs a reboot after a kernel update. Debian creates
`/run/reboot-required` when that is the case. node-exporter has no collector for this, but it can read custom
metrics from `*.prom` files with its **textfile collector** (`--collector.textfile.directory`). Extend the
DaemonSet with a small helper that checks the file every minute and publishes `node_reboot_required 0|1`.
Keep node-exporter's root file system read-only. Verify the metric on all three nodes from the client VM.

<details><summary>Solution</summary>

A native sidecar (busybox) and node-exporter share an `emptyDir`. The sidecar sees the host's `/run` read-only
and writes the metric file **atomically** (temp file + `mv`), so the exporter never reads a half-written file.

```bash
workstation$ kubectl apply -f - <<'EOF'
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: node-exporter
spec:
  selector:
    matchLabels: {app: node-exporter}
  updateStrategy:
    type: RollingUpdate
    rollingUpdate: {maxUnavailable: 1}
  template:
    metadata:
      labels: {app: node-exporter}
    spec:
      hostNetwork: true
      hostPID: true
      tolerations:
      - key: node-role.kubernetes.io/control-plane
        operator: Exists
        effect: NoSchedule
      initContainers:
      - name: reboot-check                 # native sidecar that feeds the textfile collector
        image: busybox:1.38
        restartPolicy: Always
        command: ["sh", "-c"]
        args:
        - |
          trap 'exit 0' TERM
          while true; do
            v=0; [ -f /host/run/reboot-required ] && v=1
            printf '# HELP node_reboot_required 1 if the node needs a reboot (Debian /run/reboot-required).\n# TYPE node_reboot_required gauge\nnode_reboot_required %s\n' "$v" > /textfile/reboot.prom.tmp
            mv /textfile/reboot.prom.tmp /textfile/reboot.prom    # atomic: never a half-written file
            sleep 60 & wait $!
          done
        resources:
          requests: {cpu: 5m, memory: 8Mi}
          limits:   {memory: 16Mi}
        volumeMounts:
        - {name: textfile, mountPath: /textfile}
        - {name: run, mountPath: /host/run, readOnly: true}
      containers:
      - name: node-exporter
        image: prom/node-exporter:v1.12.1
        args:
        - --path.procfs=/host/proc
        - --path.sysfs=/host/sys
        - --path.rootfs=/host/root
        - --web.listen-address=:9100
        - --collector.processes
        - --collector.textfile.directory=/textfile
        ports:
        - {name: metrics, containerPort: 9100}
        resources:
          requests: {cpu: 50m, memory: 32Mi}
          limits:   {memory: 128Mi}
        securityContext:
          readOnlyRootFilesystem: true
        volumeMounts:
        - {name: proc, mountPath: /host/proc, readOnly: true}
        - {name: sys,  mountPath: /host/sys,  readOnly: true}
        - {name: root, mountPath: /host/root, readOnly: true, mountPropagation: HostToContainer}
        - {name: textfile, mountPath: /textfile, readOnly: true}
      volumes:
      - {name: proc, hostPath: {path: /proc}}
      - {name: sys,  hostPath: {path: /sys}}
      - {name: root, hostPath: {path: /}}
      - {name: run,  hostPath: {path: /run}}
      - {name: textfile, emptyDir: {}}
EOF
workstation$ kubectl rollout status ds/node-exporter
workstation$ kubectl get pods -o wide
client-vm$ for ip in 192.168.1.10 192.168.1.11 192.168.1.12; do \
  echo "$ip: $(curl -s http://$ip:9100/metrics | grep -E '^node_reboot_required|^node_textfile_scrape_error')"; done
```

Expected:
```
NAME                  READY   STATUS    RESTARTS   AGE   IP             NODE     ...
node-exporter-57jc4   2/2     Running   0          1s    192.168.1.10   master
node-exporter-ckg2n   2/2     Running   0          3s    192.168.1.12   node2
node-exporter-vjjp2   2/2     Running   0          4s    192.168.1.11   node1

192.168.1.10: node_reboot_required 0
node_textfile_scrape_error 0
192.168.1.11: node_reboot_required 0
node_textfile_scrape_error 0
192.168.1.12: node_reboot_required 0
node_textfile_scrape_error 0
```

`node_textfile_scrape_error 0` proves that the file was parsed. A Prometheus rule `node_reboot_required == 1`
would then page the team. Do **not** create `/run/reboot-required` on a node just to test this: on hosts with
automatic updates, that file can trigger a real reboot.

</details>

---

## Lab 1.9: Redis Primary/Replica with a StatefulSet

**Scenario** – The shopping-cart team wants Redis with one primary for writes and two read replicas. Replicas
must find the primary by a **stable name**, not by an IP that changes on every restart. An upgrade from Redis 8.6
to 8.8 must be tested on one replica first, and the primary must be upgraded last. A Deployment cannot do this.
Its Pods are interchangeable and have random names. A StatefulSet gives every Pod a fixed identity.

**What you'll learn**
- StatefulSet identities: ordinal names, `apps.kubernetes.io/pod-index`, ordered start and scale-down
- Headless Services and the per-Pod DNS names `<pod>.<service>`
- Partitioned rolling updates (canary on the highest ordinal, primary last)
- Why a stable *name* is not stable *data* (`emptyDir` vs persistent volumes)

### Steps

1. Create the namespace, the headless Service and the StatefulSet. Each Pod decides its role from its index,
which the StatefulSet controller writes into a label:

```bash
workstation$ kubectl create namespace lab-01-09
workstation$ kubectl config set-context --current --namespace=lab-01-09
workstation$ kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Service
metadata:
  name: redis
spec:
  clusterIP: None            # headless: DNS returns the Pod IPs, plus one name per Pod
  selector: {app: redis}
  ports:
  - {name: redis, port: 6379}
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: redis
spec:
  serviceName: redis         # gives Pods the DNS names redis-N.redis.<ns>.svc.cluster.local
  replicas: 3
  selector:
    matchLabels: {app: redis}
  template:
    metadata:
      labels: {app: redis}
    spec:
      containers:
      - name: redis
        image: redis:8.6
        env:
        - name: POD_INDEX
          valueFrom: {fieldRef: {fieldPath: "metadata.labels['apps.kubernetes.io/pod-index']"}}
        command: ["sh", "-c"]
        args:
        - |
          if [ "$POD_INDEX" = "0" ]; then
            echo "I am $HOSTNAME, starting as PRIMARY"
            exec redis-server --protected-mode no
          else
            echo "I am $HOSTNAME, starting as REPLICA of redis-0"
            exec redis-server --protected-mode no --replicaof redis-0.redis 6379
          fi
        ports:
        - {name: redis, containerPort: 6379}
        readinessProbe:
          exec: {command: ["redis-cli", "ping"]}
          periodSeconds: 3
        volumeMounts:
        - {name: data, mountPath: /data}
      volumes:
      - name: data
        emptyDir: {}         # module 04 replaces this with volumeClaimTemplates
EOF
workstation$ kubectl get pods -w        # Ctrl+C when redis-2 is ready
```

Expected (trimmed):
```
NAME      READY   STATUS              RESTARTS   AGE
redis-0   0/1     ContainerCreating   0          0s
redis-0   1/1     Running             0          6s
redis-1   0/1     Pending             0          0s
redis-1   1/1     Running             0          4s
redis-2   0/1     Pending             0          0s
redis-2   1/1     Running             0          1s
```

**Why:** with the default `podManagementPolicy: OrderedReady`, `redis-1` is created only after `redis-0` is
*ready*. This matters here: a replica that starts before the primary has a DNS name cannot connect.

2. Look at the identities through DNS:

```bash
workstation$ kubectl get pods -o wide
workstation$ kubectl run dns --image=busybox:1.38 --restart=Never --rm -it -- \
  sh -c 'nslookup redis.lab-01-09.svc.cluster.local; nslookup redis-1.redis.lab-01-09.svc.cluster.local'
```

Expected:
```
NAME      READY   STATUS    RESTARTS   AGE   IP               NODE
redis-0   1/1     Running   0          46s   172.16.104.22    node2
redis-1   1/1     Running   0          40s   172.16.166.162   node1
redis-2   1/1     Running   0          36s   172.16.104.31    node2

Name:	redis.lab-01-09.svc.cluster.local
Address: 172.16.104.31
Name:	redis.lab-01-09.svc.cluster.local
Address: 172.16.166.162
Name:	redis.lab-01-09.svc.cluster.local
Address: 172.16.104.22

Name:	redis-1.redis.lab-01-09.svc.cluster.local
Address: 172.16.166.162
```

A headless Service has no virtual IP. The Service name resolves to *all* ready Pods, and each Pod also gets its own
record. Clients that must reach one specific instance (the primary) use `redis-0.redis`. Within the same
namespace the short form `redis-0.redis` works because of the DNS search path.

3. Check replication: write to the primary, read from a replica, and try to write to a replica:

```bash
workstation$ kubectl exec redis-0 -- redis-cli INFO replication | head -5
workstation$ kubectl exec redis-0 -- redis-cli SET cart:42 "3 items"
workstation$ kubectl exec redis-2 -- redis-cli GET cart:42
workstation$ kubectl exec redis-1 -- redis-cli SET cart:43 x
```

Expected:
```
# Replication
role:master
connected_slaves:2
slave0:ip=172.16.166.162,port=6379,state=online,offset=56,lag=1,io-thread=0
slave1:ip=172.16.104.31,port=6379,state=online,offset=56,lag=1,io-thread=0
OK
3 items
READONLY You can't write against a read only replica.
```

4. Kill a replica. It comes back with the **same name**, a new IP, and finds the primary by name again:

```bash
workstation$ kubectl delete pod redis-1
workstation$ kubectl wait --for=condition=Ready pod/redis-1
workstation$ kubectl get pods -o wide
workstation$ kubectl exec redis-1 -- redis-cli INFO replication | grep -E 'role|master_host|master_link_status'
workstation$ sleep 5; kubectl exec redis-1 -- redis-cli GET cart:42
```

Expected:
```
NAME      READY   STATUS    RESTARTS   AGE   IP               NODE
redis-0   1/1     Running   0          57s   172.16.104.22    node2
redis-1   1/1     Running   0          1s    172.16.166.182   node1
redis-2   1/1     Running   0          47s   172.16.104.31    node2

role:slave
master_host:redis-0.redis
master_link_status:down

3 items
```

**Pitfall:** look at `master_link_status:down`. The Pod was already `Ready` while it was still syncing, because
`redis-cli ping` only proves that the process answers. For a few seconds, reads from this replica would have
returned nothing. You will fix that in *Your turn*.

5. Upgrade to Redis 8.8, but only on the replica with the highest ordinal first. A `partition` of N means: "only
Pods with ordinal ≥ N get the new template":

```bash
workstation$ kubectl patch sts redis -p '{"spec":{"updateStrategy":{"type":"RollingUpdate","rollingUpdate":{"partition":2}}}}'
workstation$ kubectl set image sts/redis redis=redis:8.8
workstation$ sleep 15; kubectl get pods -L controller-revision-hash
workstation$ for p in redis-0 redis-1 redis-2; do echo "$p $(kubectl exec $p -- redis-cli INFO server | grep redis_version) $(kubectl exec $p -- redis-cli INFO replication | grep role)"; done
workstation$ kubectl get sts redis -o jsonpath='current={.status.currentRevision} update={.status.updateRevision} updated={.status.updatedReplicas}{"\n"}'
```

Expected:
```
NAME      READY   STATUS    RESTARTS   AGE   CONTROLLER-REVISION-HASH
redis-0   1/1     Running   0          92s   redis-9bd5589df
redis-1   1/1     Running   0          36s   redis-9bd5589df
redis-2   1/1     Running   0          14s   redis-6d898cd5f5

redis-0 redis_version:8.6.8 role:master
redis-1 redis_version:8.6.8 role:slave
redis-2 redis_version:8.8.4 role:slave
current=redis-9bd5589df update=redis-6d898cd5f5 updated=1
```

`redis-2` is the canary: an 8.8 replica that replicates from an 8.6 primary. Watch it for a while. Then release the
rest. The controller updates from the highest ordinal down, one Pod at a time, so the **primary is last**:

```bash
workstation$ kubectl patch sts redis -p '{"spec":{"updateStrategy":{"rollingUpdate":{"partition":0}}}}'
workstation$ kubectl rollout status sts/redis
workstation$ sleep 5; for p in redis-0 redis-1 redis-2; do echo "$p $(kubectl exec $p -- redis-cli INFO server | grep redis_version) dbsize=$(kubectl exec $p -- redis-cli DBSIZE)"; done
```

Expected:
```
Waiting for partitioned roll out to finish: 1 out of 3 new pods have been updated...
Waiting for partitioned roll out to finish: 2 out of 3 new pods have been updated...
partitioned roll out complete: 3 new pods have been updated...
redis-0 redis_version:8.8.4 dbsize=0
redis-1 redis_version:8.8.4 dbsize=0
redis-2 redis_version:8.8.4 dbsize=0
```

**Why is the cart gone?** The stable *identity* survived the update, but the data did not. `emptyDir` lives and dies
with the Pod. `redis-0` came back empty, and the replicas did what replicas do: they synced the empty dataset
(`MASTER <-> REPLICA sync: Flushing old data` in their logs). A real primary needs a PersistentVolume per Pod
(`volumeClaimTemplates`, module 04) and a failover mechanism such as Redis Sentinel.

6. Scale down and up. StatefulSets remove the **highest** ordinal first and add the missing ordinal back:

```bash
workstation$ kubectl scale sts redis --replicas=2
workstation$ sleep 6; kubectl get pods
workstation$ kubectl exec redis-0 -- redis-cli INFO replication | grep connected_slaves
workstation$ kubectl scale sts redis --replicas=3
workstation$ kubectl rollout status sts/redis
```

Expected:
```
NAME      READY   STATUS    RESTARTS   AGE
redis-0   1/1     Running   0          29s
redis-1   1/1     Running   0          36s
connected_slaves:1
```

### Clean up

```bash
workstation$ kubectl delete namespace lab-01-09
workstation$ kubectl config set-context --current --namespace=default
```

### Your turn

Fix the pitfall from step 4. A replica must only be `Ready` (and thus listed in the headless Service's DNS) while
its replication link to the primary is **up**. The primary is ready when it answers `PING`. Make the change with a
single declarative `apply`. Then prove it: point `redis-1` at a primary that does not exist
(`redis-cli REPLICAOF redis-9.redis 6379`), check the Pod and the EndpointSlice, and repair it
(`REPLICAOF redis-0.redis 6379`).

<details><summary>Solution</summary>

The readiness probe uses the same `POD_INDEX` variable as the start script. `partition: 0` is written down on
purpose: you patched the partition by hand in step 5, and the manifest should describe the full desired state.

```bash
workstation$ kubectl apply -f - <<'EOF'
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: redis
spec:
  serviceName: redis
  replicas: 3
  updateStrategy:
    type: RollingUpdate
    rollingUpdate: {partition: 0}
  selector:
    matchLabels: {app: redis}
  template:
    metadata:
      labels: {app: redis}
    spec:
      containers:
      - name: redis
        image: redis:8.8
        env:
        - name: POD_INDEX
          valueFrom: {fieldRef: {fieldPath: "metadata.labels['apps.kubernetes.io/pod-index']"}}
        command: ["sh", "-c"]
        args:
        - |
          if [ "$POD_INDEX" = "0" ]; then
            echo "I am $HOSTNAME, starting as PRIMARY"
            exec redis-server --protected-mode no
          else
            echo "I am $HOSTNAME, starting as REPLICA of redis-0"
            exec redis-server --protected-mode no --replicaof redis-0.redis 6379
          fi
        ports:
        - {name: redis, containerPort: 6379}
        readinessProbe:              # primary: answers PING; replica: has a working link to the primary
          exec:
            command:
            - sh
            - -c
            - |
              if [ "$POD_INDEX" = "0" ]; then
                redis-cli ping | grep -q PONG
              else
                redis-cli INFO replication | grep -q "master_link_status:up"
              fi
          periodSeconds: 3
        volumeMounts:
        - {name: data, mountPath: /data}
      volumes:
      - name: data
        emptyDir: {}
EOF
workstation$ kubectl rollout status sts/redis
workstation$ kubectl exec redis-1 -- redis-cli REPLICAOF redis-9.redis 6379
workstation$ sleep 8; kubectl get pods
workstation$ kubectl get endpointslice -l kubernetes.io/service-name=redis \
  -o jsonpath='{range .items[0].endpoints[*]}{.targetRef.name}{" ready="}{.conditions.ready}{"\n"}{end}'
workstation$ kubectl exec redis-1 -- redis-cli REPLICAOF redis-0.redis 6379
workstation$ sleep 10; kubectl get pods
```

Expected:
```
OK
NAME      READY   STATUS    RESTARTS   AGE
redis-0   1/1     Running   0          10s
redis-1   0/1     Running   0          20s
redis-2   1/1     Running   0          28s

redis-2 ready=true
redis-1 ready=false
redis-0 ready=true

OK
NAME      READY   STATUS    RESTARTS   AGE
redis-0   1/1     Running   0          27s
redis-1   1/1     Running   0          37s
redis-2   1/1     Running   0          45s
```

`redis-1` left the `redis` DNS answer while it had no primary and came back once `master_link_status:up`. No
restart happened, because readiness never restarts anything. Applications that read from "any replica" through
the headless name now avoid stale or empty replicas. (Changing the probe is a template change, so the `apply` itself
rolled all three Pods, again losing the `emptyDir` data.)

</details>

---

## Lab 1.10: Live Debugging with Ephemeral Containers

**Scenario** – Security hardened the images: `payments` now ships as a single static binary with no shell,
no `ls`, no `curl`. That is great until something breaks. Today you have to inspect the running `payments` Pod
without restarting it, debug a crash-looping `inventory` Pod that dies too fast to `exec` into, and check what is
going on at the node level, all without SSH access to the nodes.

**What you'll learn**
- `kubectl debug` with ephemeral containers and `--target` (shared process namespace)
- `--copy-to` to debug a crashing Pod with a changed command
- `kubectl debug node/…` with `--profile=sysadmin` and `chroot /host`
- Debug profiles and capabilities (`netadmin` for tcpdump)

### Steps

1. Create the namespace and the two apps:

```bash
workstation$ kubectl create namespace lab-01-10
workstation$ kubectl config set-context --current --namespace=lab-01-10
workstation$ kubectl apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: payments
spec:
  replicas: 1
  selector:
    matchLabels: {app: payments}
  template:
    metadata:
      labels: {app: payments}
    spec:
      containers:
      - name: whoami
        image: traefik/whoami:v1.12.0      # a single static binary, no shell, no tools
        args: ["--port", "8080"]
        ports:
        - containerPort: 8080
---
apiVersion: v1
kind: Service
metadata:
  name: payments
spec:
  selector: {app: payments}
  ports:
  - {port: 80, targetPort: 8080}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: inventory
spec:
  selector:
    matchLabels: {app: inventory}
  template:
    metadata:
      labels: {app: inventory}
    spec:
      containers:
      - name: app
        image: busybox:1.38
        command: ["sh", "-c"]
        args:
        - |
          echo "loading /etc/inventory/stock.csv"
          [ -s /etc/inventory/stock.csv ] || { echo "stock file missing or empty"; exit 3; }
          exec sleep infinity
        volumeMounts:
        - {name: stock, mountPath: /etc/inventory}
      volumes:
      - name: stock
        configMap:
          name: inventory-stock
          optional: true
EOF
workstation$ kubectl rollout status deploy/payments
```

2. The classic approach fails on a minimal image:

```bash
workstation$ P=$(kubectl get pod -l app=payments -o name)
workstation$ kubectl exec -it $P -- sh
workstation$ kubectl exec $P -- ls /
```

Expected:
```
executable file `sh` not found in $PATH: No such file or directory
command terminated with exit code 255
executable file `ls` not found in $PATH: No such file or directory
```

3. Add an **ephemeral container** with a full toolbox to the *running* Pod. `--target` puts it into the process
namespace of the `whoami` container:

```bash
workstation$ kubectl debug -it $P --image=nicolaka/netshoot:v0.16 --target=whoami -c debugger
debugger# ps aux
debugger# ss -ltnp
debugger# curl -s localhost:8080/ | head -3
debugger# ls /proc/1/root/
debugger# exit
```

Expected:
```
Targeting container "whoami". If you don't see processes from this container it may be because the container runtime doesn't support this feature.
PID   USER     TIME  COMMAND
    1 root      0:00 /whoami --port 8080
...
State  Recv-Q Send-Q Local Address:Port Peer Address:PortProcess
LISTEN 0      4096               *:8080            *:*    users:(("whoami",pid=1,fd=4))
Hostname: payments-6d6597bbcc-wch5d
IP: 127.0.0.1
IP: ::1
dev
etc
proc
...
whoami
```

**Why:** containers of a Pod already share the network namespace, so `ss` and `curl localhost` see the app.
`--target` also shares the **process** namespace with one container, so you see its PID 1. Its file system
is reachable through `/proc/1/root`. The Pod was not restarted: `RESTARTS` is still 0.

4. Ephemeral containers are part of the Pod spec, and they stay there:

```bash
workstation$ kubectl get $P -o jsonpath='{range .spec.ephemeralContainers[*]}{.name} {.image}{"\n"}{end}'
workstation$ kubectl get $P -o jsonpath='{range .status.ephemeralContainerStatuses[*]}{.name}: {.state}{"\n"}{end}'
```

Expected:
```
debugger nicolaka/netshoot:v0.16
debugger: {"terminated":{...,"exitCode":0,"reason":"Completed",...}}
```

You cannot remove or restart an ephemeral container. Use a new name (`-c debugger2`) for the next session. The
container disappears only when the Pod is replaced, e.g. by the next rollout.

5. Now the `inventory` Pod. It crashes within milliseconds, so `exec` is a lottery:

```bash
workstation$ kubectl get pods -l app=inventory
workstation$ kubectl logs deploy/inventory
```

Expected:
```
NAME                       READY   STATUS   RESTARTS      AGE
inventory-68467c75-kd55x   0/1     Error    2 (18s ago)   20s

loading /etc/inventory/stock.csv
stock file missing or empty
```

Make a **copy** of the Pod with the same volumes and environment, but with a command that does not crash:

```bash
workstation$ I=$(kubectl get pod -l app=inventory -o name)
workstation$ kubectl debug $I --copy-to=inventory-debug --container=app -- sleep 1h
workstation$ kubectl wait --for=condition=Ready pod/inventory-debug
workstation$ kubectl get pods --show-labels
workstation$ kubectl exec inventory-debug -- sh -c 'ls -la /etc/inventory/; mount | grep inventory'
```

Expected:
```
NAME                        READY   STATUS    RESTARTS      AGE   LABELS
inventory-68467c75-kd55x    0/1     Error     2 (19s ago)   21s   app=inventory,pod-template-hash=68467c75
inventory-debug             1/1     Running   0             1s    <none>
payments-6d6597bbcc-wch5d   1/1     Running   0             44s   app=payments,pod-template-hash=6d6597bbcc

drwxrwxrwx    3 root     root          4096 Nov  4 03:33 .
drwxr-xr-x    2 root     root          4096 Nov  4 03:33 ..2026_11_04_03_33_49.1760485209
lrwxrwxrwx    1 root     root            32 Nov  4 03:33 ..data -> ..2026_11_04_03_33_49.1760485209
/dev/sda1 on /etc/inventory type ext4 (ro,relatime,errors=remount-ro)
```

The mount exists but is **empty**: the ConfigMap `inventory-stock` does not exist, and `optional: true` told the
kubelet to mount an empty directory instead of refusing to start (`CreateContainerConfigError` as in Lab 1.1).
`optional` turned a clear platform error into a confusing app crash. Note `LABELS <none>`: `kubectl debug` drops
the labels of the copy by default (`--keep-labels=false`). Otherwise the Service and the ReplicaSet would select
your debug Pod.

Fix the cause and remove the copy. The kubelet refreshes ConfigMap volumes on its periodic sync, so the
crashing Pod recovers by itself after its next restart (about a minute):

```bash
workstation$ kubectl create configmap inventory-stock --from-literal=stock.csv=$'sku,qty\nA-100,42'
workstation$ kubectl delete pod inventory-debug
workstation$ sleep 60; kubectl get pods -l app=inventory
```

Expected:
```
NAME                       READY   STATUS    RESTARTS      AGE
inventory-68467c75-kd55x   1/1     Running   4 (83s ago)   2m
```

6. Finally, the node. `kubectl debug node/` starts a Pod on that node with host namespaces and the node's root file
system mounted at `/host`. `--profile=sysadmin` makes it privileged:

```bash
workstation$ NODE=$(kubectl get pod -l app=payments -o jsonpath='{.items[0].spec.nodeName}')
workstation$ kubectl debug node/$NODE -it --image=busybox:1.38 --profile=sysadmin
/ # chroot /host
root@node1:/# ps -eo pid,user,cmd | grep [w]hoami
root@node1:/# ls /var/log/pods/ | grep lab-01-10
root@node1:/# tail -2 /var/log/pods/lab-01-10_payments-*/whoami/0.log
root@node1:/# systemctl is-active kubelet crio
root@node1:/# df -h /var/lib/containers | tail -1
root@node1:/# exit
/ # exit
```

Expected:
```
Creating debugging pod node-debugger-node1-pkq98 with container debugger on node node1.
  85744 root     /usr/libexec/crio/conmon -b /run/containers/storage/overlay-containers/6041aa1f.../userdata -c 6041aa1f... -l /var/log/pods/lab-01-10_payments-6d6597bbcc-wch5d_14f1d380-.../whoami/0.log ...
  85748 root     /whoami --port 8080
lab-01-10_node-debugger-node1-pkq98_7e5e9d0f-...
lab-01-10_payments-6d6597bbcc-wch5d_14f1d380-...
2026-11-04T04:33:07.533602544+01:00 stderr F 2026/11/04 03:33:07 Starting up on port 8080
active
active
/dev/sda1       186G  6.6G  170G   4% /
```

You see the container from the host's point of view: the app process, its `conmon` monitor, and the log file
that `kubectl logs` actually reads. **Pitfall:** this cluster has no `crictl` on the nodes
(`sh: crictl: not found`), so you cannot list containers with it. The tools available are those of the host OS
after `chroot /host`, or those of the debug image before it.

The debugger Pod stays behind as `Completed`. Clean it up, because it is privileged and runs with host namespaces:

```bash
workstation$ kubectl get pods -o name | grep node-debugger | xargs kubectl delete
```

### Clean up

```bash
workstation$ kubectl delete namespace lab-01-10
workstation$ kubectl config set-context --current --namespace=default
```

### Your turn

The payments team sees a steady stream of unexpected `/charge` calls and wants to know **who** is calling. Start the
mystery client (in another namespace, as in real life) and find out from inside the `payments` Pod which
User-Agent and client ID it sends, and which Pod and namespace it is. Restart nothing:

```bash
workstation$ kubectl create namespace lab-01-10-legacy
workstation$ kubectl -n lab-01-10-legacy run nightly-sync --image=curlimages/curl:8.23.0 --command -- sh -c \
  'while true; do curl -s -o /dev/null -A legacy-sync/0.9 -H "X-Client-Id: crm-batch" http://payments.lab-01-10/charge?amount=1; sleep 2; done'
```

Hint: the first `tcpdump` attempt will probably fail. Read the error.

<details><summary>Solution</summary>

A plain ephemeral container is not allowed to capture packets:

```bash
workstation$ P=$(kubectl get pod -l app=payments -o name)
workstation$ kubectl debug $P --image=nicolaka/netshoot:v0.16 --target=whoami -c sniff1 -- tcpdump -i eth0 -c 2 -nn port 8080
workstation$ kubectl logs $P -c sniff1
```

```
tcpdump: eth0: You don't have permission to perform this capture on that device
(Attempt to create packet socket failed - CAP_NET_RAW may be required)
```

CRI-O's default capability set does not include `NET_RAW`. The `netadmin` profile adds `NET_ADMIN` and `NET_RAW`
to the debug container only. Capture only packets that carry data (`PSH` flag) and print them as ASCII:

```bash
workstation$ kubectl debug $P --image=nicolaka/netshoot:v0.16 --target=whoami -c sniff2 --profile=netadmin -- \
  tcpdump -i eth0 -A -s 0 -c 30 -nn 'tcp port 8080 and tcp[tcpflags] & tcp-push != 0'
workstation$ sleep 15; kubectl logs $P -c sniff2 | grep -E 'IP |GET|User-Agent|X-Client' | head -4
workstation$ kubectl get $P -o jsonpath='{.spec.ephemeralContainers[?(@.name=="sniff2")].securityContext}{"\n"}'
```

Expected:
```
03:35:09.733737 IP 172.16.166.178.36628 > 172.16.166.171.8080: Flags [P.], ..., length 125: HTTP: GET /charge?amount=1 HTTP/1.1
User-Agent: legacy-sync/0.9
X-Client-Id: crm-batch
03:35:09.734163 IP 172.16.166.171.8080 > 172.16.166.178.36628: Flags [P.], ..., length 383: HTTP: HTTP/1.1 200 OK

{"capabilities":{"add":["NET_ADMIN","NET_RAW"]}}
```

Map the source IP to a Pod across all namespaces:

```bash
workstation$ kubectl get pods -A -o wide | grep 172.16.166.178
```

Expected:
```
lab-01-10-legacy   nightly-sync   1/1   Running   0   27s   172.16.166.178   node1   <none>   <none>
```

Calls from Pods arrive with the Pod IP as the source (no NAT inside the cluster), which makes this mapping
possible. Module 02 shows how to block such callers with NetworkPolicies. Clean up the extra namespace:

```bash
workstation$ kubectl delete namespace lab-01-10-legacy
```

</details>
