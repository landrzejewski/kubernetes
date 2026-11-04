# Module 08: End-to-end Scenarios

These scenarios combine everything from modules 01–07 into larger, realistic projects. Each takes about 1–2 hours.
Every scenario starts with a **story**, an architecture diagram and a **requirements checklist**. You then build the
solution in phases, with an acceptance test after each phase, and finish with **challenges** (solutions are collapsed).
The scenarios are independent of each other. Scenarios 5 and 6 are especially useful as a final exam.

## Prerequisites check

```bash
workstation$ kubectl get nodes                     # master, node1, node2 Ready
workstation$ kubectl get gatewayclass nginx        # ACCEPTED True
workstation$ kubectl get storageclass minio-sc
workstation$ kubectl top nodes                     # metrics-server works
client-vm$ docker run --rm --network host --entrypoint sh pgsty/mc:RELEASE.2026-10-26T00-00-00Z -c \
  'mc alias set m http://192.168.1.100:9000 minioadmin minioadmin123 && mc ls m'
```

The scenarios create Gateways that get an address from the MetalLB pool. The examples show `192.168.1.241`; always use the
address that `kubectl get gateway` prints in your cluster.

## Contents

1. [Scenario 1: Cloud Native Shop – from zero to production-ready](#scenario-1-cloud-native-shop--from-zero-to-production-ready)
2. [Scenario 2: Self-service platform – onboarding development teams](#scenario-2-self-service-platform--onboarding-development-teams)
3. [Scenario 3: A release pipeline with automatic rollback](#scenario-3-a-release-pipeline-with-automatic-rollback)
4. [Scenario 4: Nightly data pipeline – S3 in, parallel processing, reports out](#scenario-4-nightly-data-pipeline--s3-in-parallel-processing-reports-out)
5. [Scenario 5: Game day – ten faults, one hour](#scenario-5-game-day--ten-faults-one-hour)
6. [Scenario 6: Patch night – node maintenance without downtime](#scenario-6-patch-night--node-maintenance-without-downtime)


## Scenario 1: Cloud Native Shop – from zero to production-ready

**Story.** Your company is moving its online shop to Kubernetes. The business has four requirements: the shop must be
reachable only over HTTPS at `shop.example.test`; one node may fail without anyone noticing; the
database must be backed up every night to S3 (MinIO); and a compromised frontend must not be able to reach the database.
You are the platform engineer who builds it, tier by tier.

```mermaid
flowchart LR
  client([client VM 192.168.1.100]) -- HTTPS --> gw[shop-gateway<br/>NGF + MetalLB IP]
  gw -- "/" --> sf[storefront x2]
  gw -- "/api/catalog" --> api[catalog-api x2..6<br/>HPA]
  sf -- /echo --> api
  api -- cache --> redis[(redis)]
  backup[[CronJob db-backup]] --> pg[(postgres<br/>StatefulSet, PV on node1)]
  backup -- S3 --> minio[(MinIO 192.168.1.100:9000)]
```

```
client-vm ──HTTPS──▶ shop-gateway ──/──────────────▶ storefront ──▶ catalog-api ──▶ redis
                                  └─/api/catalog──▶ catalog-api
CronJob db-backup ──▶ postgres (PV on node1)      db-backup ──S3──▶ MinIO (192.168.1.100:9000)
```

**Uses:** StatefulSet, static PV, Secrets, ConfigMaps, probes, topology spread, Gateway API (TLS, redirect, URLRewrite),
NetworkPolicies (default deny), HPA, PDB, CronJob, S3 backup.

### Requirements checklist

| # | Requirement | Verified in |
|---|-------------|-------------|
| R1 | Postgres keeps its data on a dedicated disk (`/mnt/lab-08-shop/pgdata` on node1) and survives pod restarts | Phase 1 |
| R2 | Frontend and API run 2+ replicas spread across both workers | Phase 2 |
| R3 | Only `https://shop.example.test` is served; HTTP is redirected with 301 | Phase 3 |
| R4 | Zero-trust network: every flow not explicitly needed is blocked | Phase 4 |
| R5 | API scales 2 → 6 under load; voluntary disruptions keep at least 1 pod | Phase 5 |
| R6 | Nightly `pg_dump` lands in the `lab-08-shop-backups` bucket in MinIO | Phase 6 |

### Phase 1 – Data tier: Postgres on a pinned PersistentVolume and Redis cache

There is no dynamic block-storage provisioner in this cluster, so we pre-create a PV and pre-bind it to the PVC that the
StatefulSet will generate (`<template>-<sts>-<ordinal>` = `pgdata-postgres-0`) with `claimRef`. The PV has `nodeAffinity`,
so the scheduler will always place `postgres-0` on node1, where the data lives.

```bash
workstation$ kubectl apply -f - <<'YAML'
apiVersion: v1
kind: Namespace
metadata:
  name: lab-08-shop
  labels:
    app.kubernetes.io/part-of: shop
---
apiVersion: v1
kind: PersistentVolume
metadata:
  name: lab-08-shop-pgdata
spec:
  capacity:
    storage: 2Gi
  accessModes: ["ReadWriteOnce"]
  persistentVolumeReclaimPolicy: Retain
  storageClassName: lab-08-manual
  claimRef:
    namespace: lab-08-shop
    name: pgdata-postgres-0
  hostPath:
    path: /mnt/lab-08-shop/pgdata
    type: DirectoryOrCreate
  nodeAffinity:
    required:
      nodeSelectorTerms:
      - matchExpressions:
        - key: kubernetes.io/hostname
          operator: In
          values: ["node1"]
---
apiVersion: v1
kind: Secret
metadata:
  name: postgres-credentials
  namespace: lab-08-shop
type: Opaque
stringData:
  POSTGRES_USER: shop
  POSTGRES_PASSWORD: S3cr3t-Shop-Pass
  POSTGRES_DB: shop
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: postgres-init
  namespace: lab-08-shop
data:
  01-schema.sql: |
    CREATE TABLE products (id SERIAL PRIMARY KEY, name TEXT NOT NULL, price NUMERIC(10,2) NOT NULL);
    INSERT INTO products (name, price) VALUES ('Kubernetes mug', 39.00), ('Gopher plush', 79.00), ('Helm sticker pack', 9.99);
---
apiVersion: v1
kind: Service
metadata:
  name: postgres
  namespace: lab-08-shop
spec:
  clusterIP: None
  selector:
    app: postgres
  ports:
  - name: pg
    port: 5432
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: postgres
  namespace: lab-08-shop
spec:
  serviceName: postgres
  replicas: 1
  selector:
    matchLabels:
      app: postgres
  template:
    metadata:
      labels:
        app: postgres
        tier: data
    spec:
      containers:
      - name: postgres
        image: postgres:17
        envFrom:
        - secretRef:
            name: postgres-credentials
        env:
        - name: PGDATA
          value: /var/lib/postgresql/data/pgdata
        ports:
        - name: pg
          containerPort: 5432
        readinessProbe:
          exec:
            command: ["sh", "-c", "pg_isready -U \"$POSTGRES_USER\" -d \"$POSTGRES_DB\""]
          periodSeconds: 5
        resources:
          requests: {cpu: 100m, memory: 256Mi}
          limits: {memory: 512Mi}
        volumeMounts:
        - name: pgdata
          mountPath: /var/lib/postgresql/data
        - name: init
          mountPath: /docker-entrypoint-initdb.d
      volumes:
      - name: init
        configMap:
          name: postgres-init
  volumeClaimTemplates:
  - metadata:
      name: pgdata
    spec:
      storageClassName: lab-08-manual
      accessModes: ["ReadWriteOnce"]
      resources:
        requests:
          storage: 2Gi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: redis
  namespace: lab-08-shop
spec:
  replicas: 1
  selector:
    matchLabels:
      app: redis
  template:
    metadata:
      labels:
        app: redis
        tier: cache
    spec:
      containers:
      - name: redis
        image: redis:8.8
        args: ["--save", "", "--appendonly", "no", "--maxmemory", "64mb", "--maxmemory-policy", "allkeys-lru"]
        ports:
        - name: redis
          containerPort: 6379
        resources:
          requests: {cpu: 50m, memory: 64Mi}
          limits: {memory: 128Mi}
---
apiVersion: v1
kind: Service
metadata:
  name: redis
  namespace: lab-08-shop
spec:
  selector:
    app: redis
  ports:
  - name: redis
    port: 6379
YAML
workstation$ kubectl -n lab-08-shop rollout status sts/postgres --timeout=180s
workstation$ kubectl -n lab-08-shop get pvc,pods -o wide
workstation$ kubectl -n lab-08-shop exec postgres-0 -- psql -U shop -d shop -c 'select * from products'
```

Expected:
```
persistentvolumeclaim/pgdata-postgres-0   Bound    lab-08-shop-pgdata   2Gi        RWO   lab-08-manual
pod/postgres-0               1/1     Running   0     27s   172.16.166.136   node1
 id |       name        | price
----+-------------------+-------
  1 | Kubernetes mug    | 39.00
  2 | Gopher plush      | 79.00
  3 | Helm sticker pack |  9.99
```

> **Why `PGDATA=/var/lib/postgresql/data/pgdata`?** Postgres refuses to initialise a non-empty directory. Pointing it at a
> sub-directory of the mount avoids problems with `lost+found` or other files at the volume root.

Prove R1: delete the pod and check that the data survives.

```bash
workstation$ kubectl -n lab-08-shop delete pod postgres-0
workstation$ kubectl -n lab-08-shop wait --for=condition=Ready pod/postgres-0 --timeout=120s
workstation$ kubectl -n lab-08-shop exec postgres-0 -- psql -U shop -d shop -tAc 'select count(*) from products'
3
```

### Phase 2 – Application tier: storefront and catalog API

Both tiers use `podinfo`: the **catalog-api** uses Redis as its cache (`--cache-server`), and the **storefront** calls the API as its
backend (`--backend-url`, exposed as `POST /api/echo`). The UI texts come from a ConfigMap. `topologySpreadConstraints`
with `DoNotSchedule` guarantees one replica per worker (R2).

```bash
workstation$ kubectl apply -f - <<'YAML'
apiVersion: v1
kind: ConfigMap
metadata:
  name: shop-config
  namespace: lab-08-shop
data:
  PODINFO_UI_MESSAGE: "Welcome to the Cloud Native Shop"
  PODINFO_UI_COLOR: "#2e7d32"
  PODINFO_LEVEL: "info"
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: catalog-api
  namespace: lab-08-shop
spec:
  replicas: 2
  selector:
    matchLabels:
      app: catalog-api
  template:
    metadata:
      labels:
        app: catalog-api
        tier: backend
    spec:
      topologySpreadConstraints:
      - maxSkew: 1
        topologyKey: kubernetes.io/hostname
        whenUnsatisfiable: DoNotSchedule
        labelSelector:
          matchLabels:
            app: catalog-api
      containers:
      - name: api
        image: ghcr.io/stefanprodan/podinfo:6.17.0
        command: ["./podinfo", "--port=9898", "--cache-server=tcp://redis:6379"]
        ports:
        - name: http
          containerPort: 9898
        readinessProbe:
          httpGet: {path: /readyz, port: http}
        livenessProbe:
          httpGet: {path: /healthz, port: http}
        resources:
          requests: {cpu: 100m, memory: 64Mi}
          limits: {memory: 128Mi}
---
apiVersion: v1
kind: Service
metadata:
  name: catalog-api
  namespace: lab-08-shop
spec:
  selector:
    app: catalog-api
  ports:
  - name: http
    port: 80
    targetPort: http
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: storefront
  namespace: lab-08-shop
spec:
  replicas: 2
  selector:
    matchLabels:
      app: storefront
  template:
    metadata:
      labels:
        app: storefront
        tier: frontend
    spec:
      topologySpreadConstraints:
      - maxSkew: 1
        topologyKey: kubernetes.io/hostname
        whenUnsatisfiable: DoNotSchedule
        labelSelector:
          matchLabels:
            app: storefront
      containers:
      - name: web
        image: ghcr.io/stefanprodan/podinfo:6.17.0
        command: ["./podinfo", "--port=9898", "--backend-url=http://catalog-api/echo"]
        envFrom:
        - configMapRef:
            name: shop-config
        ports:
        - name: http
          containerPort: 9898
        readinessProbe:
          httpGet: {path: /readyz, port: http}
        resources:
          requests: {cpu: 100m, memory: 64Mi}
          limits: {memory: 128Mi}
---
apiVersion: v1
kind: Service
metadata:
  name: storefront
  namespace: lab-08-shop
spec:
  selector:
    app: storefront
  ports:
  - name: http
    port: 80
    targetPort: http
YAML
workstation$ kubectl -n lab-08-shop rollout status deploy/catalog-api
workstation$ kubectl -n lab-08-shop rollout status deploy/storefront
workstation$ kubectl -n lab-08-shop get pods -o wide -l 'tier in (frontend,backend)'
```

Expected (one replica of each app per node):
```
catalog-api-7ddf98cd5d-cvmbm   1/1   Running   node1
catalog-api-7ddf98cd5d-zshx8   1/1   Running   node2
storefront-5b6f8bcb8f-kndf6    1/1   Running   node2
storefront-5b6f8bcb8f-zzlws    1/1   Running   node1
```

Smoke-test the whole chain from a toolbox pod. The toolbox is used again in Phase 4.

```bash
workstation$ kubectl -n lab-08-shop run toolbox --image=nicolaka/netshoot:v0.16 --labels=app=toolbox -- sleep infinity
workstation$ kubectl -n lab-08-shop wait --for=condition=Ready pod/toolbox
workstation$ kubectl -n lab-08-shop exec toolbox -- curl -s -XPOST -d hello storefront/api/echo
[
  "hello"
]
workstation$ kubectl -n lab-08-shop exec toolbox -- curl -s -XPOST -d basket-42 catalog-api/cache/user-1
workstation$ kubectl -n lab-08-shop exec toolbox -- curl -s catalog-api/cache/user-1
basket-42
```

### Phase 3 – Edge: HTTPS Gateway with redirect and path routing

```bash
workstation$ openssl req -x509 -newkey rsa:2048 -nodes -days 365 -keyout shop.key -out shop.crt \
  -subj "/CN=shop.example.test" -addext "subjectAltName=DNS:shop.example.test"
workstation$ kubectl -n lab-08-shop create secret tls shop-tls --cert=shop.crt --key=shop.key
workstation$ kubectl apply -f - <<'YAML'
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: shop-gateway
  namespace: lab-08-shop
spec:
  gatewayClassName: nginx
  listeners:
  - name: http
    protocol: HTTP
    port: 80
    hostname: shop.example.test
  - name: https
    protocol: HTTPS
    port: 443
    hostname: shop.example.test
    tls:
      mode: Terminate
      certificateRefs:
      - name: shop-tls
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: shop-https-redirect
  namespace: lab-08-shop
spec:
  parentRefs:
  - name: shop-gateway
    sectionName: http
  rules:
  - filters:
    - type: RequestRedirect
      requestRedirect:
        scheme: https
        statusCode: 301
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: shop
  namespace: lab-08-shop
spec:
  parentRefs:
  - name: shop-gateway
    sectionName: https
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /api/catalog
    filters:
    - type: URLRewrite
      urlRewrite:
        path:
          type: ReplacePrefixMatch
          replacePrefixMatch: /
    backendRefs:
    - name: catalog-api
      port: 80
  - matches:
    - path:
        type: PathPrefix
        value: /
    backendRefs:
    - name: storefront
      port: 80
YAML
workstation$ kubectl -n lab-08-shop wait --for=condition=Programmed gateway/shop-gateway --timeout=120s
workstation$ kubectl -n lab-08-shop get gateway shop-gateway
NAME           CLASS   ADDRESS         PROGRAMMED   AGE
shop-gateway   nginx   192.168.1.241   True         1s
```

> The redirect route attaches only to the `http` listener (`sectionName: http`) and the application route only to `https`.
> If the application route had no `sectionName`, it would attach to both listeners, and the plain-HTTP shop would still work.

Acceptance test from the client VM (use the address you got):

```bash
client-vm$ IP=192.168.1.241
client-vm$ curl -s -o /dev/null -w '%{http_code} -> %{redirect_url}\n' -H 'Host: shop.example.test' http://$IP/products
301 -> https://shop.example.test/products
client-vm$ curl -sk --resolve shop.example.test:443:$IP https://shop.example.test/ | grep -E 'hostname|message'
  "hostname": "storefront-5b6f8bcb8f-kndf6",
  "message": "Welcome to the Cloud Native Shop",
client-vm$ curl -sk --resolve shop.example.test:443:$IP https://shop.example.test/api/catalog/version
{
  "commit": "fd3a834ed8d14b80ea334cf8a2fddd4597924da6",
  "version": "6.17.0"
}
client-vm$ curl -sk --resolve other.example.test:443:$IP https://other.example.test/ || echo "rejected (exit $?)"
rejected (exit 35)
```

The last call fails during the TLS handshake: no listener matches the SNI `other.example.test`.

### Phase 4 – Zero-trust networking

Start with **deny everything** (ingress *and* egress), then allow DNS, then allow each required flow:

| From → To | Port |
|-----------|------|
| anyone → gateway pods | 80, 443 |
| gateway → storefront, catalog-api | 9898 |
| gateway → NGF control plane (`nginx-gateway` ns) | 8443 |
| storefront → catalog-api | 9898 |
| catalog-api → redis | 6379 |
| db-backup → postgres | 5432 (Phase 6) |

> **Pitfall:** the NGF data plane (`shop-gateway-nginx` pod) receives its configuration from the control plane in
> namespace `nginx-gateway` over gRPC (Service port 443 → pod port **8443**). With default-deny egress, it must be allowed
> explicitly, or new routes would stop being programmed. NetworkPolicies match the pod port, not the Service port.

```bash
workstation$ kubectl apply -f - <<'YAML'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: lab-08-shop
spec:
  podSelector: {}
  policyTypes: ["Ingress", "Egress"]
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-dns
  namespace: lab-08-shop
spec:
  podSelector: {}
  policyTypes: ["Egress"]
  egress:
  - to:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: kube-system
      podSelector:
        matchLabels:
          k8s-app: kube-dns
    ports:
    - {protocol: UDP, port: 53}
    - {protocol: TCP, port: 53}
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: gateway
  namespace: lab-08-shop
spec:
  podSelector:
    matchLabels:
      gateway.networking.k8s.io/gateway-name: shop-gateway
  policyTypes: ["Ingress", "Egress"]
  ingress:
  - ports:
    - {protocol: TCP, port: 80}
    - {protocol: TCP, port: 443}
  egress:
  - to:
    - podSelector:
        matchExpressions:
        - {key: app, operator: In, values: ["storefront", "catalog-api"]}
    ports:
    - {protocol: TCP, port: 9898}
  - to:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: nginx-gateway
    ports:
    - {protocol: TCP, port: 8443}
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: storefront
  namespace: lab-08-shop
spec:
  podSelector:
    matchLabels:
      app: storefront
  policyTypes: ["Ingress", "Egress"]
  ingress:
  - from:
    - podSelector:
        matchLabels:
          gateway.networking.k8s.io/gateway-name: shop-gateway
    ports:
    - {protocol: TCP, port: 9898}
  egress:
  - to:
    - podSelector:
        matchLabels:
          app: catalog-api
    ports:
    - {protocol: TCP, port: 9898}
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: catalog-api
  namespace: lab-08-shop
spec:
  podSelector:
    matchLabels:
      app: catalog-api
  policyTypes: ["Ingress", "Egress"]
  ingress:
  - from:
    - podSelector:
        matchLabels:
          gateway.networking.k8s.io/gateway-name: shop-gateway
    - podSelector:
        matchLabels:
          app: storefront
    ports:
    - {protocol: TCP, port: 9898}
  egress:
  - to:
    - podSelector:
        matchLabels:
          app: redis
    ports:
    - {protocol: TCP, port: 6379}
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: redis
  namespace: lab-08-shop
spec:
  podSelector:
    matchLabels:
      app: redis
  policyTypes: ["Ingress"]
  ingress:
  - from:
    - podSelector:
        matchLabels:
          app: catalog-api
    ports:
    - {protocol: TCP, port: 6379}
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: postgres
  namespace: lab-08-shop
spec:
  podSelector:
    matchLabels:
      app: postgres
  policyTypes: ["Ingress"]
  ingress:
  - from:
    - podSelector:
        matchLabels:
          app: db-backup
    ports:
    - {protocol: TCP, port: 5432}
YAML
```

Prove R4 from the toolbox (no rule allows it anything) and from a compromised storefront pod:

```bash
workstation$ kubectl -n lab-08-shop exec toolbox -- sh -c 'curl -s -m 3 storefront >/dev/null && echo OPEN || echo "toolbox -> storefront BLOCKED"'
toolbox -> storefront BLOCKED
workstation$ SF=$(kubectl -n lab-08-shop get pod -l app=storefront -o name | head -1)
workstation$ kubectl -n lab-08-shop exec $SF -- sh -c '
  wget -q -T 3 -O- catalog-api/version >/dev/null && echo "storefront -> api OK"
  nc -z -w 3 redis 6379    && echo OPEN || echo "storefront -> redis BLOCKED"
  nc -z -w 3 postgres 5432 && echo OPEN || echo "storefront -> postgres BLOCKED"'
storefront -> api OK
storefront -> redis BLOCKED
storefront -> postgres BLOCKED
client-vm$ curl -sk --resolve shop.example.test:443:$IP https://shop.example.test/api/catalog/cache/user-1
basket-42
```

### Phase 5 – Elasticity and disruption budgets

```bash
workstation$ kubectl apply -f - <<'YAML'
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: catalog-api
  namespace: lab-08-shop
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: catalog-api
  minReplicas: 2
  maxReplicas: 6
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: 60
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: catalog-api
  namespace: lab-08-shop
spec:
  minAvailable: 1
  selector:
    matchLabels:
      app: catalog-api
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: storefront
  namespace: lab-08-shop
spec:
  minAvailable: 1
  selector:
    matchLabels:
      app: storefront
YAML
workstation$ kubectl -n lab-08-shop get hpa,pdb
```

Generate load from the client VM (fortio runs in Docker there) and watch the HPA in a second terminal:

```bash
client-vm$ docker run --rm --network host --add-host shop.example.test:$IP fortio/fortio:1.76.0 \
  load -k -qps 0 -c 16 -t 75s https://shop.example.test/api/catalog/
workstation$ kubectl -n lab-08-shop get hpa catalog-api -w
```

Expected after about a minute:
```
NAME          REFERENCE                TARGETS         MINPODS   MAXPODS   REPLICAS
catalog-api   Deployment/catalog-api   cpu: 537%/60%   2         6         6
...
All done 119389 calls (plus 16 warmup) 10.050 ms avg, 1591.8 qps
Code 200 : 119389 (100.0 %)
```

After the load stops, the HPA scales back to 2, by default after a 5-minute stabilisation window.

### Phase 6 – Nightly backup to S3

Create the bucket once on the client VM, then deploy the CronJob. It runs in two steps: an **init container** writes
`pg_dump` to an `emptyDir`, and the **main container** (MinIO client) uploads it. The `MC_HOST_<alias>` environment
variable configures `mc` without a config file. The `db-backup` NetworkPolicy allows exactly two egress flows: Postgres and MinIO.

```bash
client-vm$ docker run --rm --network host --entrypoint sh pgsty/mc:RELEASE.2026-10-26T00-00-00Z -c \
  'mc alias set m http://192.168.1.100:9000 minioadmin minioadmin123 && mc mb m/lab-08-shop-backups'
Bucket created successfully `m/lab-08-shop-backups`.
workstation$ kubectl apply -f - <<'YAML'
apiVersion: v1
kind: Secret
metadata:
  name: backup-s3
  namespace: lab-08-shop
type: Opaque
stringData:
  MC_HOST_backup: http://minioadmin:minioadmin123@192.168.1.100:9000
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: db-backup
  namespace: lab-08-shop
spec:
  podSelector:
    matchLabels:
      app: db-backup
  policyTypes: ["Egress"]
  egress:
  - to:
    - podSelector:
        matchLabels:
          app: postgres
    ports:
    - {protocol: TCP, port: 5432}
  - to:
    - ipBlock:
        cidr: 192.168.1.100/32
    ports:
    - {protocol: TCP, port: 9000}
---
apiVersion: batch/v1
kind: CronJob
metadata:
  name: db-backup
  namespace: lab-08-shop
spec:
  schedule: "30 2 * * *"
  timeZone: "Europe/Warsaw"
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 1
  jobTemplate:
    spec:
      backoffLimit: 2
      activeDeadlineSeconds: 600
      template:
        metadata:
          labels:
            app: db-backup
        spec:
          restartPolicy: Never
          initContainers:
          - name: dump
            image: postgres:17
            command: ["sh", "-c", "pg_dump -h postgres -U \"$POSTGRES_USER\" -d \"$POSTGRES_DB\" --format=custom -f /backup/shop.dump && ls -l /backup"]
            env:
            - name: POSTGRES_USER
              valueFrom: {secretKeyRef: {name: postgres-credentials, key: POSTGRES_USER}}
            - name: POSTGRES_DB
              valueFrom: {secretKeyRef: {name: postgres-credentials, key: POSTGRES_DB}}
            - name: PGPASSWORD
              valueFrom: {secretKeyRef: {name: postgres-credentials, key: POSTGRES_PASSWORD}}
            volumeMounts:
            - {name: backup, mountPath: /backup}
          containers:
          - name: upload
            image: pgsty/mc:RELEASE.2026-10-26T00-00-00Z
            command: ["sh", "-c", "mc cp /backup/shop.dump backup/lab-08-shop-backups/shop-$(date +%Y%m%d-%H%M%S).dump && mc ls backup/lab-08-shop-backups"]
            envFrom:
            - secretRef: {name: backup-s3}
            volumeMounts:
            - {name: backup, mountPath: /backup}
          volumes:
          - name: backup
            emptyDir: {}
YAML
workstation$ kubectl -n lab-08-shop create job backup-manual --from=cronjob/db-backup
workstation$ kubectl -n lab-08-shop wait --for=condition=Complete job/backup-manual --timeout=180s
workstation$ kubectl -n lab-08-shop logs job/backup-manual -c upload
`/backup/shop.dump` -> `backup/lab-08-shop-backups/shop-20261104-022709.dump`
[2026-11-04 02:27:09 UTC] 2.7KiB STANDARD shop-20261104-022709.dump
```

All six requirements are now met. 🎉

### Challenges

1. **Restore drill.** A backup you have never restored isn't really a backup. Write a Job that downloads the newest dump from
   the bucket, restores it into a new database `shop_restore_test` and prints the product count of both databases.
   The Job must work with the existing NetworkPolicies, without adding new ones.
2. **Node failure budget.** Without running it, explain what happens to each component when `kubectl drain node2` is executed:
   which pods move, which drain step blocks and why, and what happens to `postgres-0` if node1 is drained instead.
3. **Secret hygiene.** `backup-s3` holds root MinIO credentials. Describe how you would replace them with a least-privilege
   identity and how the CronJob would pick up the rotated Secret.

<details><summary>Solution 1 – restore drill</summary>

Labelling the Job's pod `app: db-backup` reuses the existing policy (egress to Postgres + MinIO; Postgres ingress allows
`app: db-backup`). `pgsty/mc` is a minimal image without `awk`, so the init container mirrors the bucket and the
Postgres container (full Debian userland) picks the newest file.

```bash
workstation$ kubectl apply -f - <<'YAML'
apiVersion: batch/v1
kind: Job
metadata:
  name: restore-drill
  namespace: lab-08-shop
spec:
  backoffLimit: 0
  template:
    metadata:
      labels:
        app: db-backup
    spec:
      restartPolicy: Never
      initContainers:
      - name: download
        image: pgsty/mc:RELEASE.2026-10-26T00-00-00Z
        command: ["mc", "mirror", "--quiet", "backup/lab-08-shop-backups", "/restore"]
        envFrom:
        - secretRef: {name: backup-s3}
        volumeMounts:
        - {name: restore, mountPath: /restore}
      containers:
      - name: restore
        image: postgres:17
        command:
        - sh
        - -c
        - |
          set -e
          LATEST=$(ls /restore/*.dump | sort | tail -1)
          echo "restoring $LATEST"
          psql -h postgres -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "DROP DATABASE IF EXISTS shop_restore_test"
          psql -h postgres -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "CREATE DATABASE shop_restore_test"
          pg_restore -h postgres -U "$POSTGRES_USER" -d shop_restore_test --no-owner "$LATEST"
          echo "live:     $(psql -h postgres -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tAc 'select count(*) from products') products"
          echo "restored: $(psql -h postgres -U "$POSTGRES_USER" -d shop_restore_test -tAc 'select count(*) from products') products"
        env:
        - name: POSTGRES_USER
          valueFrom: {secretKeyRef: {name: postgres-credentials, key: POSTGRES_USER}}
        - name: POSTGRES_DB
          valueFrom: {secretKeyRef: {name: postgres-credentials, key: POSTGRES_DB}}
        - name: PGPASSWORD
          valueFrom: {secretKeyRef: {name: postgres-credentials, key: POSTGRES_PASSWORD}}
        volumeMounts:
        - {name: restore, mountPath: /restore}
      volumes:
      - name: restore
        emptyDir: {}
YAML
workstation$ kubectl -n lab-08-shop wait --for=condition=Complete job/restore-drill --timeout=180s
workstation$ kubectl -n lab-08-shop logs job/restore-drill -c restore
restoring /restore/shop-20261104-022709.dump
CREATE DATABASE
live:     3 products
restored: 3 products
```
</details>

<details><summary>Solution 2 – node failure budget</summary>

- `storefront` and `catalog-api`: the PDBs (`minAvailable: 1`) allow evicting the node2 replica, because the node1 replica stays
  up, so the drain proceeds. The replacement pod, however, stays **Pending**: `topologySpreadConstraints` uses
  `nodeTaintsPolicy: Ignore` by default, so the cordoned node2 still counts as a topology domain with 0 pods. Placing the
  second replica on node1 would make the skew 2 > `maxSkew: 1`, and `DoNotSchedule` forbids that. Capacity is halved until
  `kubectl uncordon node2`. (The tainted master counts as a domain with 0 Pods, too.) Verified on the training cluster:
  `0/3 nodes are available: 1 node(s) didn't match pod topology spread constraints, 1 node(s) had untolerated taint(s),
  1 node(s) were unschedulable`. Use `nodeTaintsPolicy: Honor` (see Scenario 6) or `whenUnsatisfiable: ScheduleAnyway`
  if you prefer availability.
- `redis` and the gateway data plane: single replicas without a PDB are evicted immediately, causing a short cache and
  edge outage. Production would run 2 replicas + a PDB.
- `postgres-0` (draining **node1**): the pod is evicted but stays `Pending`, because its PV has `nodeAffinity` to node1, which
  is cordoned. The database is down until `kubectl uncordon node1`. That's the price of node-local storage. Replication
  or network storage removes it.
- The toolbox is a bare pod (no controller), so `kubectl drain` refuses to delete it without `--force`.
</details>

<details><summary>Solution 3 – secret hygiene</summary>

Create a dedicated MinIO user with a policy limited to `s3:PutObject`/`s3:ListBucket` on `lab-08-shop-backups`
(`mc admin user add`, `mc admin policy create`, `mc admin policy attach`). Then replace the Secret:

```bash
workstation$ kubectl -n lab-08-shop create secret generic backup-s3 \
  --from-literal=MC_HOST_backup='http://shop-backup:<password>@192.168.1.100:9000' \
  --dry-run=client -o yaml | kubectl apply -f -
```

No restart is needed: every CronJob run creates a new pod, and `envFrom` is resolved when the pod starts, so the next
backup uses the new credentials. (Long-running Deployments would need `kubectl rollout restart`.)
</details>

### Clean up

```bash
workstation$ kubectl delete namespace lab-08-shop
workstation$ kubectl delete pv lab-08-shop-pgdata
node1$ sudo rm -rf /mnt/lab-08-shop
client-vm$ docker run --rm --network host --entrypoint sh pgsty/mc:RELEASE.2026-10-26T00-00-00Z -c \
  'mc alias set m http://192.168.1.100:9000 minioadmin minioadmin123 && mc rb --force m/lab-08-shop-backups'
```


---

## Scenario 2: Self-service platform – onboarding development teams

**Story.** Three teams are about to share the cluster. The platform team (you) wants onboarding to be one command that
gives each team a "landing zone": its own namespace with sane defaults, people who can deploy without asking for help,
and guard-rails that stop one team from hurting another. Teams publish their apps on the shared Gateway as
`<team>.apps.example.test`.

```mermaid
flowchart TB
  subgraph infra[lab-08-infra]
    gw[apps-gateway<br/>*.apps.example.test<br/>allowedRoutes: label selector]
  end
  subgraph a[lab-08-team-a  PSA restricted, quota, netpol]
    ra[HTTPRoute team-a.apps…] --> wa[web]
  end
  subgraph b[lab-08-team-b  PSA restricted, quota, netpol]
    rb[HTTPRoute team-b.apps…] --> wb[web]
  end
  gw --> ra & rb
  alice((alice<br/>O=team-a)) -. edit .-> a
  bob((bob<br/>O=team-b)) -. edit .-> b
  wb -. blocked .-x wa
```

**Uses:** Namespaces and labels, Pod Security Admission, ResourceQuota, LimitRange, NetworkPolicy, X.509 users and groups (CSR API),
RBAC (ClusterRole + RoleBindings), Gateway API `allowedRoutes`, ValidatingAdmissionPolicy (challenge).

### Requirements checklist

| # | Requirement |
|---|-------------|
| R1 | One script onboards a team: namespace, quota, defaults, isolation, permissions |
| R2 | Team members authenticate as themselves (certificate, group = team) and can deploy only into their own namespace |
| R3 | Pods must comply with the `restricted` Pod Security Standard; teams cannot weaken it |
| R4 | Teams cannot create LoadBalancer/NodePort Services; the shared Gateway is the only way in |
| R5 | Pods of one team cannot reach another team's pods |
| R6 | Only onboarded namespaces can attach routes to the shared Gateway |

### Phase 1 – Platform building blocks

The shared Gateway accepts routes only from namespaces labelled `platform.example.test/shared-gateway-access=true`.
The built-in `edit` ClusterRole does not cover Gateway API resources, so we add a small ClusterRole for HTTPRoutes.

```bash
workstation$ mkdir -p ~/lab-08-platform && cd ~/lab-08-platform
workstation$ kubectl apply -f - <<'YAML'
apiVersion: v1
kind: Namespace
metadata:
  name: lab-08-infra
---
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: apps-gateway
  namespace: lab-08-infra
spec:
  gatewayClassName: nginx
  listeners:
  - name: http
    protocol: HTTP
    port: 80
    hostname: "*.apps.example.test"
    allowedRoutes:
      namespaces:
        from: Selector
        selector:
          matchLabels:
            platform.example.test/shared-gateway-access: "true"
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: lab-08-route-editor
rules:
- apiGroups: ["gateway.networking.k8s.io"]
  resources: ["httproutes"]
  verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
- apiGroups: ["gateway.networking.k8s.io"]
  resources: ["gateways"]
  verbs: ["get", "list"]
YAML
workstation$ kubectl -n lab-08-infra wait --for=condition=Programmed gateway/apps-gateway --timeout=120s
workstation$ kubectl -n lab-08-infra get gateway apps-gateway
NAME           CLASS   ADDRESS         PROGRAMMED   AGE
apps-gateway   nginx   192.168.1.241   True         17s
```

### Phase 2 – The onboarding script (R1, R3, R4, R5)

```bash
workstation$ cat > onboard-team.sh <<'SCRIPT'
#!/usr/bin/env bash
# Usage: ./onboard-team.sh <team> <cpu-quota> <memory-quota>
# Example: ./onboard-team.sh team-a 2 4Gi
set -euo pipefail
TEAM=$1 CPU=${2:-2} MEM=${3:-4Gi}
NS=lab-08-$TEAM
kubectl apply -f - <<YAML
apiVersion: v1
kind: Namespace
metadata:
  name: $NS
  labels:
    platform.example.test/tenant: "$TEAM"
    platform.example.test/shared-gateway-access: "true"
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/enforce-version: latest
    pod-security.kubernetes.io/warn: restricted
---
apiVersion: v1
kind: ResourceQuota
metadata:
  name: team-quota
  namespace: $NS
spec:
  hard:
    requests.cpu: "$CPU"
    requests.memory: $MEM
    limits.memory: $MEM
    pods: "20"
    services.loadbalancers: "0"
    services.nodeports: "0"
---
apiVersion: v1
kind: LimitRange
metadata:
  name: defaults
  namespace: $NS
spec:
  limits:
  - type: Container
    defaultRequest: {cpu: 50m, memory: 64Mi}
    default: {memory: 128Mi}
    max: {cpu: "1", memory: 1Gi}
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: tenant-isolation
  namespace: $NS
spec:
  podSelector: {}
  policyTypes: ["Ingress"]
  ingress:
  - from:
    - podSelector: {}
  - from:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: lab-08-infra
      podSelector:
        matchLabels:
          gateway.networking.k8s.io/gateway-name: apps-gateway
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: team-edit
  namespace: $NS
subjects:
- kind: Group
  name: $TEAM
  apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: ClusterRole
  name: edit
  apiGroup: rbac.authorization.k8s.io
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: team-routes
  namespace: $NS
subjects:
- kind: Group
  name: $TEAM
  apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: ClusterRole
  name: lab-08-route-editor
  apiGroup: rbac.authorization.k8s.io
YAML
echo "Team $TEAM onboarded into namespace $NS"
SCRIPT
workstation$ chmod +x onboard-team.sh
workstation$ ./onboard-team.sh team-a 2 4Gi
workstation$ ./onboard-team.sh team-b 1 2Gi
```

Design notes:
- **`services.loadbalancers: "0"` / `services.nodeports: "0"`** – a quota of zero is the simplest way to forbid a resource type (R4).
- **LimitRange defaults** – the quota covers `requests.cpu`/`requests.memory`, so every pod must declare them. The
  LimitRange injects defaults, so teams don't get `must specify requests` errors for every quick test.
- **`tenant-isolation` NetworkPolicy** – ingress only from the same namespace and from the shared Gateway's data-plane
  pods (R5). Egress stays open (DNS, external APIs).
- **Why teams can't switch PSA off** – PSA is configured by *namespace labels*. `edit` gives no rights on the
  Namespace object, so the team can't relabel it (R3).

### Phase 3 – People: certificate-based users (R2)

Kubernetes has no user database. A user is whoever presents a certificate signed by the cluster CA: **CN = user name,
O = groups**. The script below uses the CSR API, so you never touch the CA key.

```bash
workstation$ cat > new-user.sh <<'SCRIPT'
#!/usr/bin/env bash
# Usage: ./new-user.sh <user> <group>   -> writes ./<user>.kubeconfig
set -euo pipefail
USER=$1 GROUP=$2
openssl genrsa -out $USER.key 2048 2>/dev/null
openssl req -new -key $USER.key -subj "/CN=$USER/O=$GROUP" -out $USER.csr
kubectl apply -f - <<YAML
apiVersion: certificates.k8s.io/v1
kind: CertificateSigningRequest
metadata:
  name: lab-08-$USER
spec:
  request: $(base64 -w0 < $USER.csr)
  signerName: kubernetes.io/kube-apiserver-client
  expirationSeconds: 86400
  usages: ["client auth"]
YAML
kubectl certificate approve lab-08-$USER
kubectl wait --for=jsonpath='{.status.certificate}' csr/lab-08-$USER --timeout=30s >/dev/null
kubectl get csr lab-08-$USER -o jsonpath='{.status.certificate}' | base64 -d > $USER.crt
SERVER=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
kubectl config view --minify --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' | base64 -d > ca.crt
KCFG=$USER.kubeconfig
kubectl --kubeconfig=$KCFG config set-cluster training --server=$SERVER --certificate-authority=ca.crt --embed-certs=true >/dev/null
kubectl --kubeconfig=$KCFG config set-credentials $USER --client-certificate=$USER.crt --client-key=$USER.key --embed-certs=true >/dev/null
kubectl --kubeconfig=$KCFG config set-context $USER --cluster=training --user=$USER >/dev/null
kubectl --kubeconfig=$KCFG config use-context $USER >/dev/null
rm -f $USER.csr ca.crt
echo "Created $KCFG for $USER (group $GROUP)"
SCRIPT
workstation$ chmod +x new-user.sh
workstation$ ./new-user.sh alice team-a
workstation$ ./new-user.sh bob team-b
workstation$ kubectl --kubeconfig alice.kubeconfig auth whoami
ATTRIBUTE                                           VALUE
Username                                            alice
Groups                                              [team-a system:authenticated]
```

> `expirationSeconds: 86400` makes the certificate valid for one day. Client certificates **cannot be revoked** in
> Kubernetes. Short lifetimes and removing RBAC bindings are your only levers (see Challenge 2).

### Phase 4 – Acceptance tests: a day in the life of a team

**Alice tries the "it works on my laptop" manifest**:

```bash
workstation$ kubectl --kubeconfig alice.kubeconfig -n lab-08-team-a apply -f - <<'YAML'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
spec:
  replicas: 2
  selector:
    matchLabels: {app: web}
  template:
    metadata:
      labels: {app: web}
    spec:
      containers:
      - name: web
        image: ghcr.io/stefanprodan/podinfo:6.17.0
YAML
Warning: would violate PodSecurity "restricted:latest": allowPrivilegeEscalation != false (...), unrestricted capabilities (...),
runAsNonRoot != true (...), seccompProfile (...)
deployment.apps/web created
workstation$ kubectl --kubeconfig alice.kubeconfig -n lab-08-team-a get deploy web
NAME   READY   UP-TO-DATE   AVAILABLE   AGE
web    0/2     0            0           3s
workstation$ kubectl --kubeconfig alice.kubeconfig -n lab-08-team-a get events --field-selector reason=FailedCreate -o custom-columns=MSG:.message
Error creating: pods "web-56f896b866-9c2w9" is forbidden: violates PodSecurity "restricted:latest": ...
workstation$ kubectl --kubeconfig alice.kubeconfig -n lab-08-team-a delete deploy web
```

> PSA validates **pods**, not Deployments. The Deployment is accepted (you only get a warning) and the ReplicaSet fails
> to create pods. Always check `kubectl get events` when a Deployment sits at `0/N`.

**Both teams deploy a compliant app** (a template with `TEAM`/`HOST` placeholders):

```bash
workstation$ cat > app.yaml <<'YAML'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
spec:
  replicas: 2
  selector:
    matchLabels: {app: web}
  template:
    metadata:
      labels: {app: web}
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 10001
        seccompProfile: {type: RuntimeDefault}
      containers:
      - name: web
        image: ghcr.io/stefanprodan/podinfo:6.17.0
        env:
        - name: PODINFO_UI_MESSAGE
          value: "Hello from TEAM"
        ports:
        - {name: http, containerPort: 9898}
        readinessProbe:
          httpGet: {path: /readyz, port: http}
        securityContext:
          allowPrivilegeEscalation: false
          readOnlyRootFilesystem: true
          capabilities: {drop: ["ALL"]}
---
apiVersion: v1
kind: Service
metadata:
  name: web
spec:
  selector: {app: web}
  ports:
  - {name: http, port: 80, targetPort: http}
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: web
spec:
  parentRefs:
  - name: apps-gateway
    namespace: lab-08-infra
  hostnames: ["HOST"]
  rules:
  - backendRefs:
    - name: web
      port: 80
YAML
workstation$ sed -e 's/TEAM/team-a/; s/HOST/team-a.apps.example.test/' app.yaml | kubectl --kubeconfig alice.kubeconfig -n lab-08-team-a apply -f -
workstation$ sed -e 's/TEAM/team-b/; s/HOST/team-b.apps.example.test/' app.yaml | kubectl --kubeconfig bob.kubeconfig -n lab-08-team-b apply -f -
workstation$ kubectl --kubeconfig alice.kubeconfig -n lab-08-team-a rollout status deploy/web
client-vm$ for t in team-a team-b; do curl -s -H "Host: $t.apps.example.test" http://192.168.1.241/ | grep message; done
  "message": "Hello from team-a",
  "message": "Hello from team-b",
```

> `runAsUser: 10001` is needed because the podinfo image declares a *non-numeric* user. With `runAsNonRoot: true`, the
> kubelet can only verify a numeric UID.

**Guard-rails**:

```bash
workstation$ kubectl --kubeconfig alice.kubeconfig get pods -n lab-08-team-b
Error from server (Forbidden): pods is forbidden: User "alice" cannot list resource "pods" in API group "" in the namespace "lab-08-team-b"
workstation$ kubectl --kubeconfig alice.kubeconfig auth can-i patch namespaces/lab-08-team-a
no
workstation$ kubectl --kubeconfig bob.kubeconfig -n lab-08-team-b expose deploy web --name=web-lb --type=LoadBalancer --port=80 --target-port=9898
Error from server (Forbidden): services "web-lb" is forbidden: exceeded quota: team-quota, requested: services.loadbalancers=1,services.nodeports=1, ...
workstation$ kubectl --kubeconfig alice.kubeconfig -n lab-08-team-a describe quota team-quota
Resource                Used   Hard
--------                ----   ----
limits.memory           256Mi  4Gi
pods                    2      20
requests.cpu            100m   2
requests.memory         128Mi  4Gi
services.loadbalancers  0      0
services.nodeports      0      0
```

The 100m/128Mi in use came from the LimitRange defaults, because the app manifest declares no resources.

**Network isolation (R5).** Bob starts a restricted-compliant curl pod in his namespace:

```bash
workstation$ kubectl --kubeconfig bob.kubeconfig -n lab-08-team-b apply -f - <<'YAML'
apiVersion: v1
kind: Pod
metadata:
  name: probe
spec:
  securityContext:
    runAsNonRoot: true
    runAsUser: 100
    seccompProfile: {type: RuntimeDefault}
  containers:
  - name: curl
    image: curlimages/curl:8.23.0
    command: ["sleep", "3600"]
    securityContext:
      allowPrivilegeEscalation: false
      capabilities: {drop: ["ALL"]}
YAML
workstation$ kubectl --kubeconfig bob.kubeconfig -n lab-08-team-b exec probe -- sh -c '
  curl -s -m 3 web.lab-08-team-b | grep message
  curl -s -m 3 web.lab-08-team-a || echo "team-b -> team-a BLOCKED"'
  "message": "Hello from team-b",
team-b -> team-a BLOCKED
```

**Rogue namespace (R6).** An admin creates a namespace by hand, skipping onboarding:

```bash
workstation$ kubectl create namespace lab-08-rogue
workstation$ sed -e 's/TEAM/rogue/; s/HOST/rogue.apps.example.test/' app.yaml | kubectl -n lab-08-rogue apply -f -
workstation$ kubectl -n lab-08-rogue get httproute web -o jsonpath='{range .status.parents[*].conditions[*]}{.type}={.status} ({.reason}){"\n"}{end}'
ResolvedRefs=True (ResolvedRefs)
Accepted=False (NotAllowedByListeners)
```

The rogue pods run normally (no PSA label → privileged by default!). That's exactly why namespace creation should go
through the onboarding script.

### Challenges

1. **Hostname ownership.** Today Bob can create a route for `team-a.apps.example.test` and steal Alice's traffic. Write a
   ValidatingAdmissionPolicy that allows tenant HTTPRoutes only for `<tenant>.apps.example.test` and its subdomains.
   It applies only to namespaces with the `platform.example.test/tenant` label.
2. **Offboarding.** Team B is dissolved. Write `offboard-team.sh` that removes the team's landing zone. Prove that Bob's
   certificate still *authenticates* but no longer *authorises* anything, and explain why.
3. **Auditors.** The security team (group `auditors`) needs read-only access to *all* tenant namespaces, including
   ones onboarded in the future. Sketch two approaches and their trade-offs.

<details><summary>Solution 1 – hostname ownership with CEL</summary>

`namespaceObject` gives the policy access to the namespace labels, so one policy works for every tenant.

```bash
workstation$ kubectl apply -f - <<'YAML'
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicy
metadata:
  name: lab-08-tenant-hostnames
spec:
  failurePolicy: Fail
  matchConstraints:
    resourceRules:
    - apiGroups: ["gateway.networking.k8s.io"]
      apiVersions: ["v1"]
      operations: ["CREATE", "UPDATE"]
      resources: ["httproutes"]
  variables:
  - name: tenant
    expression: "namespaceObject.metadata.labels['platform.example.test/tenant']"
  validations:
  - expression: "has(object.spec.hostnames) && size(object.spec.hostnames) > 0"
    message: "HTTPRoutes in tenant namespaces must declare spec.hostnames"
  - expression: >-
      object.spec.hostnames.all(h, h == variables.tenant + '.apps.example.test' ||
      h.endsWith('.' + variables.tenant + '.apps.example.test'))
    messageExpression: "'hostnames must be ' + variables.tenant + '.apps.example.test or a subdomain of it'"
---
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicyBinding
metadata:
  name: lab-08-tenant-hostnames
spec:
  policyName: lab-08-tenant-hostnames
  validationActions: ["Deny"]
  matchResources:
    namespaceSelector:
      matchExpressions:
      - key: platform.example.test/tenant
        operator: Exists
YAML
workstation$ sed -e 's/TEAM/team-b/; s/HOST/team-a.apps.example.test/' app.yaml | kubectl --kubeconfig bob.kubeconfig -n lab-08-team-b apply -f -
The httproutes "web" is invalid: : ValidatingAdmissionPolicy 'lab-08-tenant-hostnames' with binding 'lab-08-tenant-hostnames'
denied request: hostnames must be team-b.apps.example.test or a subdomain of it
workstation$ sed -e 's/TEAM/team-b/; s/HOST/shop.team-b.apps.example.test/' app.yaml | kubectl --kubeconfig bob.kubeconfig -n lab-08-team-b apply -f -
httproute.gateway.networking.k8s.io/web configured
client-vm$ curl -s -o /dev/null -w '%{http_code}\n' -H 'Host: shop.team-b.apps.example.test' http://192.168.1.241/
200
```

In Gateway API, the wildcard listener `*.apps.example.test` also matches multi-label subdomains such as
`shop.team-b.apps.example.test`.
</details>

<details><summary>Solution 2 – offboarding</summary>

```bash
workstation$ cat > offboard-team.sh <<'SCRIPT'
#!/usr/bin/env bash
# Usage: ./offboard-team.sh <team> <user>...
set -euo pipefail
TEAM=$1; shift
kubectl delete namespace lab-08-$TEAM --wait=true
for U in "$@"; do kubectl delete csr lab-08-$U --ignore-not-found; done
echo "Remaining bindings for group $TEAM:"
kubectl get rolebindings,clusterrolebindings -A -o json \
  | jq -r --arg g "$TEAM" '.items[] | select(any(.subjects[]?; .kind=="Group" and .name==$g)) | "\(.metadata.namespace // "-")/\(.metadata.name)"'
SCRIPT
workstation$ chmod +x offboard-team.sh && ./offboard-team.sh team-b bob
namespace "lab-08-team-b" deleted
certificatesigningrequest.certificates.k8s.io "lab-08-bob" deleted
Remaining bindings for group team-b:
workstation$ kubectl --kubeconfig bob.kubeconfig auth whoami | sed -n 2p
Username                                            bob
workstation$ kubectl --kubeconfig bob.kubeconfig get pods -n lab-08-team-b
Error from server (Forbidden): pods is forbidden: User "bob" cannot list resource "pods" ...
```

Authentication (who you are) is the certificate, and it stays valid until it expires, even after the CSR object is
deleted. Authorisation (what you may do) is RBAC: the RoleBindings disappeared with the namespace, and the jq check
confirms that no ClusterRoleBinding references the group. That's why certificates should be short-lived.
</details>

<details><summary>Solution 3 – auditors</summary>

- **A RoleBinding per tenant namespace** (add it to `onboard-team.sh`): `RoleBinding auditors-view → ClusterRole view, Group auditors`.
  Least privilege, and new tenants are covered automatically because onboarding creates the binding. The downside is that
  existing namespaces need a one-off loop:
  `for ns in $(kubectl get ns -l platform.example.test/tenant -o name | cut -d/ -f2); do kubectl -n $ns create rolebinding auditors-view --clusterrole=view --group=auditors; done`
- **A ClusterRoleBinding to `view`**: one object, but it grants read access to *every* namespace, including
  `kube-system` and the platform's own namespaces. Note that `view` deliberately excludes Secrets in both cases.
</details>

### Clean up

```bash
workstation$ kubectl delete namespace lab-08-team-a lab-08-team-b lab-08-rogue lab-08-infra --ignore-not-found
workstation$ kubectl delete validatingadmissionpolicybinding,validatingadmissionpolicy lab-08-tenant-hostnames --ignore-not-found
workstation$ kubectl delete clusterrole lab-08-route-editor
workstation$ kubectl delete csr lab-08-alice lab-08-bob --ignore-not-found
workstation$ rm -rf ~/lab-08-platform
```


---

## Scenario 3: A release pipeline with automatic rollback

**Story.** Releases of the shop are done by hand on Friday evenings and roll back by heroics. Management wants
"push a button, and the platform either finishes the release or puts everything back by itself". You build a small
pipeline: it runs **inside the cluster** as a Job under a least-privilege ServiceAccount and does blue/green deployment with
canary steps on the Gateway, checking a health gate after every step.

```mermaid
sequenceDiagram
  participant CI as release Job (SA deployer)
  participant K as API server
  participant GW as release-gw
  CI->>K: patch idle Deployment (new release)
  CI->>K: rollout status
  CI->>K: point preview route at idle
  CI->>GW: 200 requests to preview.shop.example.test
  loop 10% → 50% → 100%
    CI->>K: patch HTTPRoute weights
    CI->>GW: 200 requests to shop.example.test
    alt error rate > 2%
      CI->>K: weights back to live (rollback) and exit 1
    end
  end
  CI->>K: annotate route live=<idle>
```

**Uses:** Deployments, Services, HPA, Gateway API (weights, multiple routes), ServiceAccount + Role, short-lived tokens,
Jobs, ConfigMap-mounted scripts.

### Phase 1 – Two colours behind one Gateway

Both colours are permanent Deployments with their own HPA. The route annotation `release.example.test/live` records which
colour is live, so the pipeline is stateless.

```bash
workstation$ kubectl apply -f - <<'YAML'
apiVersion: v1
kind: Namespace
metadata:
  name: lab-08-release
---
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: release-gw
  namespace: lab-08-release
spec:
  gatewayClassName: nginx
  listeners:
  - name: http
    protocol: HTTP
    port: 80
    hostname: "*.example.test"
YAML
workstation$ cat > color.yaml <<'YAML'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: shop-COLOR
  namespace: lab-08-release
  labels: {app: shop, color: COLOR}
spec:
  replicas: 2
  selector:
    matchLabels: {app: shop, color: COLOR}
  template:
    metadata:
      labels: {app: shop, color: COLOR}
    spec:
      containers:
      - name: shop
        image: ghcr.io/stefanprodan/podinfo:6.17.0
        command: ["./podinfo", "--port=9898"]
        env:
        - name: PODINFO_UI_MESSAGE
          value: "shop v1 (COLOR)"
        ports:
        - {name: http, containerPort: 9898}
        readinessProbe:
          httpGet: {path: /readyz, port: http}
        lifecycle:
          preStop:
            sleep: {seconds: 5}   # keep serving until the Gateway has removed the endpoint
        resources:
          requests: {cpu: 50m, memory: 32Mi}
          limits: {memory: 128Mi}
---
apiVersion: v1
kind: Service
metadata:
  name: shop-COLOR
  namespace: lab-08-release
spec:
  selector: {app: shop, color: COLOR}
  ports:
  - {name: http, port: 80, targetPort: http}
---
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: shop-COLOR
  namespace: lab-08-release
spec:
  scaleTargetRef: {apiVersion: apps/v1, kind: Deployment, name: shop-COLOR}
  minReplicas: 2
  maxReplicas: 5
  metrics:
  - type: Resource
    resource:
      name: cpu
      target: {type: Utilization, averageUtilization: 70}
YAML
workstation$ for c in blue green; do sed "s/COLOR/$c/g" color.yaml | kubectl apply -f -; done
workstation$ kubectl apply -f - <<'YAML'
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: shop
  namespace: lab-08-release
  annotations:
    release.example.test/live: blue
spec:
  parentRefs: [{name: release-gw}]
  hostnames: ["shop.example.test"]
  rules:
  - backendRefs:
    - {name: shop-blue, port: 80, weight: 100}
    - {name: shop-green, port: 80, weight: 0}
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: shop-preview
  namespace: lab-08-release
spec:
  parentRefs: [{name: release-gw}]
  hostnames: ["preview.shop.example.test"]
  rules:
  - backendRefs:
    - {name: shop-green, port: 80}
YAML
workstation$ kubectl -n lab-08-release wait --for=condition=Programmed gateway/release-gw --timeout=120s
workstation$ kubectl -n lab-08-release get gateway,httproute
NAME                                           CLASS   ADDRESS         PROGRAMMED
gateway.gateway.networking.k8s.io/release-gw   nginx   192.168.1.241   True
NAME                                               HOSTNAMES
httproute.gateway.networking.k8s.io/shop           ["shop.example.test"]
httproute.gateway.networking.k8s.io/shop-preview   ["preview.shop.example.test"]
```

> **Why a weight-0 backend?** Keeping both colours in the route all the time means a release only changes two numbers.
> Every step, including rollback, is a single idempotent `kubectl patch`.

> **Why `preStop: sleep 5`?** Without it, the first pipeline run on this cluster failed its smoke test with 6/200 errors.
> When a rollout terminates an old pod, the kubelet stops it at the same moment the endpoint is removed, and the Gateway still
> sends a few requests to the dying pod before its configuration is updated. The native `sleep` pre-stop hook keeps the
> old pod serving for five more seconds. That's the standard fix for 502s during rollouts.

### Phase 2 – The CI identity

The pipeline may patch Deployments and HTTPRoutes **in this namespace only**: no create/delete, no Secrets, no pods.

```bash
workstation$ kubectl apply -f - <<'YAML'
apiVersion: v1
kind: ServiceAccount
metadata:
  name: deployer
  namespace: lab-08-release
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: deployer
  namespace: lab-08-release
rules:
- apiGroups: ["apps"]
  resources: ["deployments"]
  verbs: ["get", "list", "watch", "patch"]
- apiGroups: ["apps"]
  resources: ["replicasets"]
  verbs: ["get", "list", "watch"]
- apiGroups: ["gateway.networking.k8s.io"]
  resources: ["httproutes"]
  verbs: ["get", "patch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: deployer
  namespace: lab-08-release
subjects:
- {kind: ServiceAccount, name: deployer, namespace: lab-08-release}
roleRef:
  kind: Role
  name: deployer
  apiGroup: rbac.authorization.k8s.io
YAML
```

The same identity can also be used by an *external* CI system (GitLab, GitHub Actions) with a short-lived token:

```bash
workstation$ TOKEN=$(kubectl -n lab-08-release create token deployer --duration=10m)
workstation$ SERVER=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
workstation$ kubectl config view --minify --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' | base64 -d > ca.crt
workstation$ kubectl --kubeconfig ci.kubeconfig config set-cluster training --server=$SERVER --certificate-authority=ca.crt --embed-certs
workstation$ kubectl --kubeconfig ci.kubeconfig config set-credentials ci --token=$TOKEN
workstation$ kubectl --kubeconfig ci.kubeconfig config set-context ci --cluster=training --user=ci --namespace=lab-08-release
workstation$ kubectl --kubeconfig ci.kubeconfig config use-context ci && rm ca.crt
workstation$ for c in "patch deployments" "delete deployments" "get secrets" "patch httproutes" "create pods"; do
  echo "$c: $(kubectl --kubeconfig ci.kubeconfig auth can-i $c)"; done
patch deployments: yes
delete deployments: no
get secrets: no
patch httproutes: yes
create pods: no
workstation$ echo $TOKEN | cut -d. -f2 | tr '_-' '/+' | base64 -d 2>/dev/null | jq '{exp, iat, sub}'
{
  "exp": 1793760846,
  "iat": 1793760246,
  "sub": "system:serviceaccount:lab-08-release:deployer"
}
```

`exp - iat = 600` seconds: a leaked token is useless ten minutes later.

> **Security note.** "Only patch Deployments" is still powerful: whoever can change a pod template can run any image
> with the Deployment's ServiceAccount and mounted Secrets. Keep application namespaces free of high-privilege
> ServiceAccounts, and consider an admission policy that pins allowed registries.

### Phase 3 – The pipeline

```bash
workstation$ cat > release.sh <<'SCRIPT'
#!/usr/bin/env bash
# Blue/green + canary release pipeline. Inputs (env): RELEASE_MESSAGE, RELEASE_ARGS (extra podinfo flags)
set -euo pipefail
NS=lab-08-release
GW=http://release-gw-nginx.$NS.svc            # in-cluster address of the Gateway data plane
MAX_ERRORS_PCT=${MAX_ERRORS_PCT:-2}           # health gate: max % of failed requests per step
SAMPLES=${SAMPLES:-200}
log() { echo "[$(date +%H:%M:%S)] $*"; }

LIVE=$(kubectl -n $NS get httproute shop -o jsonpath='{.metadata.annotations.release\.example\.test/live}')
IDLE=$([ "$LIVE" = blue ] && echo green || echo blue)
log "live=$LIVE idle=$IDLE release='$RELEASE_MESSAGE' args='${RELEASE_ARGS:-}'"

set_weights() {   # $1 = weight for blue, $2 = weight for green
  kubectl -n $NS patch httproute shop --type=json -p "[
    {\"op\":\"replace\",\"path\":\"/spec/rules/0/backendRefs/0/weight\",\"value\":$1},
    {\"op\":\"replace\",\"path\":\"/spec/rules/0/backendRefs/1/weight\",\"value\":$2}]" >/dev/null
}
weights_for_idle() {  # $1 = % of traffic for the idle color
  if [ "$IDLE" = green ]; then set_weights $((100-$1)) $1; else set_weights $1 $((100-$1)); fi
}
failed_requests() {   # $1 = host header
  local fails=0
  for _ in $(seq "$SAMPLES"); do
    code=$(curl -s -o /dev/null -m 2 -w '%{http_code}' -H "Host: $1" $GW/api/info || true)
    [ "$code" = 200 ] || fails=$((fails+1))
  done
  echo $fails
}
rollback() {
  log "ROLLBACK: $1"
  weights_for_idle 0
  exit 1
}

# 1. Deploy the new release to the idle color
ARGS_JSON=$(printf '"%s",' ./podinfo --port=9898 ${RELEASE_ARGS:-}); ARGS_JSON="[${ARGS_JSON%,}]"
kubectl -n $NS patch deployment shop-$IDLE --type=json -p "[
  {\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/command\",\"value\":$ARGS_JSON},
  {\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/env/0/value\",\"value\":\"$RELEASE_MESSAGE ($IDLE)\"}]" >/dev/null
kubectl -n $NS rollout status deployment/shop-$IDLE --timeout=180s

# 2. Smoke test through the preview hostname
kubectl -n $NS patch httproute shop-preview --type=json \
  -p "[{\"op\":\"replace\",\"path\":\"/spec/rules/0/backendRefs/0/name\",\"value\":\"shop-$IDLE\"}]" >/dev/null
sleep 5
F=$(failed_requests preview.shop.example.test)
log "smoke test on preview: $F/$SAMPLES failed"
[ $((F*100)) -le $((MAX_ERRORS_PCT*SAMPLES)) ] || rollback "smoke test failed"

# 3. Progressive traffic shift with a health gate after every step
for PCT in 10 50 100; do
  weights_for_idle $PCT
  sleep 5
  F=$(failed_requests shop.example.test)
  log "canary $PCT%: $F/$SAMPLES failed"
  [ $((F*100)) -le $((MAX_ERRORS_PCT*SAMPLES)) ] || rollback "error budget exceeded at $PCT%"
done

# 4. Promote
kubectl -n $NS annotate httproute shop --overwrite release.example.test/live=$IDLE >/dev/null
log "SUCCESS: $IDLE is live with '$RELEASE_MESSAGE'"
SCRIPT
workstation$ kubectl -n lab-08-release create configmap release-pipeline --from-file=release.sh
workstation$ cat > run-release.sh <<'SCRIPT'
#!/usr/bin/env bash
# Usage: ./run-release.sh "<release message>" "[extra podinfo args]"  -> starts the pipeline Job and follows its log
set -euo pipefail
JOB=$(kubectl create -o name -f - <<YAML
apiVersion: batch/v1
kind: Job
metadata:
  generateName: release-
  namespace: lab-08-release
spec:
  backoffLimit: 0
  ttlSecondsAfterFinished: 3600
  template:
    spec:
      serviceAccountName: deployer
      restartPolicy: Never
      containers:
      - name: pipeline
        image: alpine/k8s:1.37.1
        command: ["bash", "/pipeline/release.sh"]
        env:
        - {name: RELEASE_MESSAGE, value: "$1"}
        - {name: RELEASE_ARGS, value: "${2:-}"}
        volumeMounts:
        - {name: pipeline, mountPath: /pipeline}
      volumes:
      - name: pipeline
        configMap:
          name: release-pipeline
YAML
)
kubectl -n lab-08-release wait --for=condition=Ready pod -l batch.kubernetes.io/job-name=${JOB#job.batch/} --timeout=60s >/dev/null
kubectl -n lab-08-release logs -f $JOB
SCRIPT
workstation$ chmod +x run-release.sh
```

> The pipeline tests through `release-gw-nginx.lab-08-release.svc`, the in-cluster Service of the Gateway data plane,
> with a `Host` header. It exercises exactly the same routing as external users, without leaving the cluster.

### Phase 4 – Release day

**A good release (v2):**

```bash
workstation$ ./run-release.sh "shop v2"
[02:52:14] live=blue idle=green release='shop v2' args=''
deployment "shop-green" successfully rolled out
[02:52:30] smoke test on preview: 0/200 failed
[02:52:39] canary 10%: 0/200 failed
[02:52:48] canary 50%: 0/200 failed
[02:52:58] canary 100%: 0/200 failed
[02:52:58] SUCCESS: green is live with 'shop v2'
client-vm$ for i in $(seq 20); do curl -s -H 'Host: shop.example.test' http://192.168.1.241/ | grep -o '"message": "[^"]*"'; done | sort | uniq -c
     20 "message": "shop v2 (green)"
```

While the canary runs, watch the traffic shift from the client VM in a second terminal:
`while true; do curl -s -H 'Host: shop.example.test' http://192.168.1.241/ | grep -o 'shop v[0-9] ([a-z]*)'; sleep 0.2; done`

**A broken release (v3).** podinfo's `--random-error` flag makes about a third of the requests fail, our stand-in for a bug that
slipped through code review:

```bash
workstation$ ./run-release.sh "shop v3" "--random-error"
[02:53:08] live=green idle=blue release='shop v3' args='--random-error'
deployment "shop-blue" successfully rolled out
[02:53:22] smoke test on preview: 69/200 failed
[02:53:22] ROLLBACK: smoke test failed
workstation$ kubectl -n lab-08-release get jobs
NAME            STATUS     COMPLETIONS   DURATION   AGE
release-f5ppj   Failed     0/1           25s        25s
release-ljs7g   Complete   1/1           49s        80s
workstation$ kubectl -n lab-08-release get httproute shop -o jsonpath='{.metadata.annotations.release\.example\.test/live} {range .spec.rules[0].backendRefs[*]}{.name}={.weight} {end}{"\n"}'
green shop-blue=0 shop-green=100
```

Production traffic never touched v3 (green stayed live with v2), and the job failed, so a CI system would turn red.
Live and idle alternate with every successful release: the next release goes to blue again.

### Challenges

1. **Header canary before weights.** Before any real users get the new version, internal testers should reach it with
   the header `X-Canary: always`. Add this to the route and the pipeline.
2. **Latency is an error too.** Release `"shop v4" "--random-delay"` (0–5 s random delay). Does the pipeline catch it? Which
   line of `release.sh` makes it a latency gate, and how would you make the threshold explicit?
3. **Autoscaling during a canary.** At 10% the idle colour still runs two pods (HPA `minReplicas: 2`), and at 100% the old colour
   keeps two idle pods. Explain how weights and HPA interact, and what you would change for a 20× bigger shop.

<details><summary>Solution 1 – header canary</summary>

Add a second rule. A rule with a header match is more specific than the catch-all rule, so it wins for matching
requests regardless of order:

```bash
workstation$ kubectl -n lab-08-release patch httproute shop --type=json -p '[{"op":"add","path":"/spec/rules/-","value":
  {"matches":[{"headers":[{"name":"X-Canary","value":"always"}]}],"backendRefs":[{"name":"shop-blue","port":80}]}}]'
client-vm$ for i in 1 2 3 4 5 6; do curl -s -o /dev/null -w '%{http_code} ' -H 'Host: shop.example.test' -H 'X-Canary: always' http://192.168.1.241/; done; echo
200 500 409 200 200 200
client-vm$ curl -s -H 'Host: shop.example.test' http://192.168.1.241/ | grep message
  "message": "shop v2 (green)",
```

Testers with the header hit the idle colour, which still runs the broken v3, so they see its errors. Customers keep
getting v2.

In `release.sh`, after the smoke test, point the header rule at the idle colour and gate on it:

```bash
kubectl -n $NS patch httproute shop --type=json \
  -p "[{\"op\":\"replace\",\"path\":\"/spec/rules/1/backendRefs/0/name\",\"value\":\"shop-$IDLE\"}]" >/dev/null
# failed_requests() with an extra header: curl ... -H "X-Canary: always" ...
```
</details>

<details><summary>Solution 2 – latency gate</summary>

Yes, it is caught: `curl -m 2` aborts requests slower than 2 s, so they don't return `200` and count as failures:

```
[02:53:40] live=green idle=blue release='shop v4' args='--random-delay'
deployment "shop-blue" successfully rolled out
[03:00:32] smoke test on preview: 137/200 failed
[03:00:32] ROLLBACK: smoke test failed
```

The smoke test took almost 7 minutes, because every slow request waits up to 2 s. Make the gate **fail fast**: inside the
loop, stop as soon as `fails` exceeds the budget (`[ $((fails*100)) -gt $((MAX_ERRORS_PCT*SAMPLES)) ] && break`).

To make it explicit, add `MAX_LATENCY=${MAX_LATENCY:-2}` and use `curl -m "$MAX_LATENCY"`. Or measure
`-w '%{time_total}'` and compute a p95 (`sort -n | awk 'NR==int(0.95*NR_TOTAL)'`). Real pipelines read these SLIs from
Prometheus instead of probing themselves (that's what tools like Argo Rollouts and Flagger automate).
</details>

<details><summary>Solution 3 – HPA and weights</summary>

Weights split **requests**, not pods. Each colour's HPA scales on its own CPU, so as the weight moves to 50% and 100%, the idle
colour's CPU rises and its HPA adds pods, while the old colour's HPA scales down to `minReplicas`. Two effects to watch:
- HPA reacts with a delay (metrics window plus the default scale-up behaviour). Jumping from 10% to 100% in 5 s can overload the
  new colour before it scales. For a big shop, pre-scale the idle colour (`kubectl scale` or a temporarily raised
  `minReplicas` equal to the live colour's current replicas) before shifting, and use smaller steps with longer pauses.
- After promotion, the old colour keeps `minReplicas` pods as an instant-rollback reserve. That's the cost of blue/green.
</details>

### Clean up

```bash
workstation$ kubectl delete namespace lab-08-release
workstation$ rm -f color.yaml release.sh run-release.sh ci.kubeconfig
```


---

## Scenario 4: Nightly data pipeline – S3 in, parallel processing, reports out

**Story.** Every night the regional shops upload their sales as CSV files to an S3 bucket. Finance wants a JSON report per
region on an internal URL by 6 AM. Security has one rule: the batch workers process customer data, so **they may talk to the
S3 server and nothing else**.

```mermaid
flowchart LR
  up([client VM: upload CSVs]) --> raw[(MinIO bucket<br/>lab-08-raw)]
  cron[[CronJob nightly-sales-report<br/>Indexed Job, 4 completions, parallelism 2]] -- init: mc mirror --> raw
  cron -- write JSON --> pvc[(PVC reports<br/>minio-sc, RWX)]
  web[reports-web x2<br/>nginx, read-only] -- read --> pvc
  gw[data-gw<br/>reports.example.test] --> web
  client([finance on client VM]) --> gw
```

**Uses:** CronJob with an Indexed Job (`JOB_COMPLETION_INDEX`, `backoffLimitPerIndex`), init containers, emptyDir,
ReadWriteMany S3 volume (csi-s3), ConfigMap scripts, Gateway API, NetworkPolicy egress lockdown with `ipBlock`.

### Phase 1 – Raw data in the bucket

On the client VM, generate a month of sales for four regions and upload them:

```bash
client-vm$ cat > gen-sales.sh <<'SCRIPT'
mkdir -p ~/lab-08-raw && cd ~/lab-08-raw
products="mug plush sticker hoodie"
i=0
for region in north south east west; do
  f=$(printf '%02d' $i)-$region.csv; i=$((i+1))
  echo "date,product,qty,unit_price" > $f
  for day in $(seq -w 1 28); do
    for p in $products; do
      echo "2026-10-$day,$p,$(( (RANDOM % 20) + 1 )),$(( (RANDOM % 50) + 5 )).99" >> $f
    done
  done
done
wc -l *.csv
docker run --rm --network host -v ~/lab-08-raw:/data:ro --entrypoint sh pgsty/mc:RELEASE.2026-10-26T00-00-00Z -c \
  'mc alias set m http://192.168.1.100:9000 minioadmin minioadmin123 >/dev/null && mc mb m/lab-08-raw && mc cp /data/*.csv m/lab-08-raw/ >/dev/null && mc ls m/lab-08-raw'
SCRIPT
client-vm$ bash gen-sales.sh
  113 00-north.csv
  113 01-south.csv
  113 02-east.csv
  113 03-west.csv
  452 total
Bucket created successfully `m/lab-08-raw`.
[2026-11-04 03:01:41 UTC] 2.8KiB STANDARD 00-north.csv
...
```

### Phase 2 – The processing job

Each pod of an **Indexed Job** gets its index in `JOB_COMPLETION_INDEX` (0…3). The worker processes "the N-th file in
sorted order", so four pods split four files with no coordination. The init container downloads the inputs into an
`emptyDir`, and the busybox worker computes revenue and the top product with `awk`.

```bash
workstation$ kubectl apply -f - <<'YAML'
apiVersion: v1
kind: Namespace
metadata:
  name: lab-08-data
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: reports
  namespace: lab-08-data
spec:
  accessModes: ["ReadWriteMany"]
  storageClassName: minio-sc
  resources:
    requests:
      storage: 1Gi
---
apiVersion: v1
kind: Secret
metadata:
  name: raw-bucket
  namespace: lab-08-data
type: Opaque
stringData:
  MC_HOST_raw: http://minioadmin:minioadmin123@192.168.1.100:9000
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: report-worker
  namespace: lab-08-data
data:
  process.sh: |
    #!/bin/sh
    # Processes the N-th input file (N = JOB_COMPLETION_INDEX) and writes a JSON report.
    set -eu
    FILE=$(ls /input/*.csv | sort | sed -n "$((JOB_COMPLETION_INDEX + 1))p")
    [ -n "$FILE" ] || { echo "no input file for index $JOB_COMPLETION_INDEX"; exit 1; }
    REGION=$(basename "$FILE" .csv | cut -d- -f2)
    echo "worker $JOB_COMPLETION_INDEX on $(hostname) processing $FILE"
    awk -F, -v region="$REGION" -v worker="$HOSTNAME" 'NR > 1 {
          rev = $3 * $4; total += rev; qty[$2] += $3; byprod[$2] += rev }
        END {
          best = ""; for (p in byprod) if (best == "" || byprod[p] > byprod[best]) best = p
          printf "{\"region\":\"%s\",\"revenue\":%.2f,\"top_product\":\"%s\",\"top_product_revenue\":%.2f,\"worker\":\"%s\"}\n",
                 region, total, best, byprod[best], worker
        }' "$FILE" > "/tmp/$REGION.json"
    cp "/tmp/$REGION.json" "/reports/$REGION.json"   # write once to S3, no partial files
    cat "/reports/$REGION.json"
---
apiVersion: batch/v1
kind: CronJob
metadata:
  name: nightly-sales-report
  namespace: lab-08-data
spec:
  schedule: "0 3 * * *"
  concurrencyPolicy: Forbid
  jobTemplate:
    spec:
      completionMode: Indexed
      completions: 4
      parallelism: 2
      backoffLimitPerIndex: 1
      maxFailedIndexes: 1
      template:
        metadata:
          labels:
            app: report-worker
        spec:
          restartPolicy: Never
          initContainers:
          - name: fetch
            image: pgsty/mc:RELEASE.2026-10-26T00-00-00Z
            command: ["mc", "mirror", "--quiet", "raw/lab-08-raw", "/input"]
            envFrom:
            - secretRef: {name: raw-bucket}
            volumeMounts:
            - {name: input, mountPath: /input}
          containers:
          - name: worker
            image: busybox:1.38
            command: ["sh", "/scripts/process.sh"]
            volumeMounts:
            - {name: input, mountPath: /input, readOnly: true}
            - {name: reports, mountPath: /reports}
            - {name: scripts, mountPath: /scripts}
          volumes:
          - name: input
            emptyDir: {}
          - name: reports
            persistentVolumeClaim:
              claimName: reports
          - name: scripts
            configMap:
              name: report-worker
YAML
workstation$ kubectl -n lab-08-data create job report-manual --from=cronjob/nightly-sales-report
workstation$ kubectl -n lab-08-data wait --for=condition=Complete job/report-manual --timeout=180s
workstation$ kubectl -n lab-08-data get pods -l job-name=report-manual -o wide
NAME                    READY   STATUS      RESTARTS   AGE   IP               NODE
report-manual-0-sdt2x   0/1     Completed   0          31s   172.16.104.62    node2
report-manual-1-nx7wk   0/1     Completed   0          31s   172.16.166.134   node1
report-manual-2-2sxz6   0/1     Completed   0          25s   172.16.166.168   node1
report-manual-3-w6jsw   0/1     Completed   0          25s   172.16.104.41    node2
workstation$ kubectl -n lab-08-data logs job/report-manual -c worker --all-pods
[pod/report-manual-0-sdt2x/worker] worker 0 on report-manual-0 processing /input/00-north.csv
[pod/report-manual-0-sdt2x/worker] {"region":"north","revenue":35503.50,"top_product":"plush","top_product_revenue":10031.12,"worker":"report-manual-0"}
...
```

Two at a time (`parallelism: 2`), on both nodes, all writing into **the same** ReadWriteMany volume.

> **S3 is not a disk.** csi-s3 (geesefs) turns a bucket prefix into a filesystem, but renames are copy+delete and readers on
> other nodes see changes with a delay. The worker writes to local `/tmp` and copies the finished file *once*. While
> building this lab, a job that read and wrote files in the same S3 directory at the same time hung on `cat`.

### Phase 3 – Publishing the reports

```bash
workstation$ kubectl apply -f - <<'YAML'
apiVersion: v1
kind: ConfigMap
metadata:
  name: reports-nginx
  namespace: lab-08-data
data:
  default.conf: |
    server {
      listen 8080;
      location /reports/ {
        alias /usr/share/nginx/reports/;
        autoindex on;
        autoindex_format json;
        default_type application/json;
      }
    }
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: reports-web
  namespace: lab-08-data
spec:
  replicas: 2
  selector:
    matchLabels: {app: reports-web}
  template:
    metadata:
      labels: {app: reports-web}
    spec:
      containers:
      - name: nginx
        image: nginxinc/nginx-unprivileged:1.31-alpine
        ports:
        - {name: http, containerPort: 8080}
        volumeMounts:
        - {name: reports, mountPath: /usr/share/nginx/reports, readOnly: true}
        - {name: conf, mountPath: /etc/nginx/conf.d}
      volumes:
      - name: reports
        persistentVolumeClaim:
          claimName: reports
          readOnly: true
      - name: conf
        configMap:
          name: reports-nginx
---
apiVersion: v1
kind: Service
metadata:
  name: reports-web
  namespace: lab-08-data
spec:
  selector: {app: reports-web}
  ports:
  - {name: http, port: 80, targetPort: http}
---
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: data-gw
  namespace: lab-08-data
spec:
  gatewayClassName: nginx
  listeners:
  - name: http
    protocol: HTTP
    port: 80
    hostname: reports.example.test
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: reports
  namespace: lab-08-data
spec:
  parentRefs: [{name: data-gw}]
  rules:
  - matches:
    - path: {type: PathPrefix, value: /reports/}
    backendRefs:
    - {name: reports-web, port: 80}
YAML
workstation$ kubectl -n lab-08-data wait --for=condition=Programmed gateway/data-gw --timeout=120s
client-vm$ curl -s -H 'Host: reports.example.test' http://192.168.1.241/reports/
[
{ "name":"east.json", "type":"file", "mtime":"Wed, 04 Nov 2026 03:02:25 GMT", "size":116 },
{ "name":"north.json", "type":"file", "mtime":"Wed, 04 Nov 2026 03:02:00 GMT", "size":118 },
{ "name":"south.json", "type":"file", "mtime":"Wed, 04 Nov 2026 03:01:59 GMT", "size":120 },
{ "name":"west.json", "type":"file", "mtime":"Wed, 04 Nov 2026 03:02:25 GMT", "size":115 }
]
client-vm$ curl -s -H 'Host: reports.example.test' http://192.168.1.241/reports/west.json
{"region":"west","revenue":38536.09,"top_product":"mug","top_product_revenue":10420.85,"worker":"report-manual-3"}
client-vm$ curl -s -o /dev/null -w '%{http_code}\n' -H 'Host: reports.example.test' http://192.168.1.241/
404
```

The volume is mounted **read-only twice**: `persistentVolumeClaim.readOnly: true` and `volumeMounts.readOnly: true`. A
compromised web pod cannot tamper with finance's numbers.

### Phase 4 – Lock it down

```bash
workstation$ kubectl apply -f - <<'YAML'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: lab-08-data
spec:
  podSelector: {}
  policyTypes: ["Ingress", "Egress"]
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-dns
  namespace: lab-08-data
spec:
  podSelector: {}
  policyTypes: ["Egress"]
  egress:
  - to:
    - namespaceSelector:
        matchLabels: {kubernetes.io/metadata.name: kube-system}
      podSelector:
        matchLabels: {k8s-app: kube-dns}
    ports:
    - {protocol: UDP, port: 53}
    - {protocol: TCP, port: 53}
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: workers-to-minio-only
  namespace: lab-08-data
spec:
  podSelector:
    matchLabels: {app: report-worker}
  policyTypes: ["Egress"]
  egress:
  - to:
    - ipBlock: {cidr: 192.168.1.100/32}
    ports:
    - {protocol: TCP, port: 9000}
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: gateway
  namespace: lab-08-data
spec:
  podSelector:
    matchLabels:
      gateway.networking.k8s.io/gateway-name: data-gw
  policyTypes: ["Ingress", "Egress"]
  ingress:
  - ports:
    - {protocol: TCP, port: 80}
  egress:
  - to:
    - podSelector:
        matchLabels: {app: reports-web}
    ports:
    - {protocol: TCP, port: 8080}
  - to:
    - namespaceSelector:
        matchLabels: {kubernetes.io/metadata.name: nginx-gateway}
    ports:
    - {protocol: TCP, port: 8443}
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: reports-web
  namespace: lab-08-data
spec:
  podSelector:
    matchLabels: {app: reports-web}
  policyTypes: ["Ingress"]
  ingress:
  - from:
    - podSelector:
        matchLabels:
          gateway.networking.k8s.io/gateway-name: data-gw
    ports:
    - {protocol: TCP, port: 8080}
YAML
workstation$ kubectl -n lab-08-data create job report-run2 --from=cronjob/nightly-sales-report
workstation$ kubectl -n lab-08-data wait --for=condition=Complete job/report-run2 --timeout=180s
job.batch/report-run2 condition met
```

Prove the egress rule with a pod that *pretends* to be a worker (same label):

```bash
workstation$ kubectl -n lab-08-data run egress-test --image=curlimages/curl:8.23.0 --labels=app=report-worker --restart=Never --command -- sh -c '
  curl -s -m 3 -o /dev/null -w "minio %{http_code}\n" http://192.168.1.100:9000/minio/health/live
  curl -s -m 3 https://github.com >/dev/null && echo "internet OPEN" || echo "internet BLOCKED"'
workstation$ kubectl -n lab-08-data logs egress-test
minio 200
internet BLOCKED
workstation$ kubectl -n lab-08-data delete pod egress-test
```

> **Why do writes to the S3 volume still work under default-deny egress?** The pod never talks to S3 for its volume. The
> mount is served by the csi-s3 node plugin (namespace `kube-system`), and the pod just sees a local filesystem.
> NetworkPolicies only govern the pod's own sockets. The `init` container's `mc mirror` *does* open a socket, and that's why
> the `ipBlock` rule is needed.

### Challenges

1. **Fan-in.** Finance also wants `summary.json` with the total revenue and the best region. Write a Job that builds it from
   the per-region files. Why can't a regular Indexed Job "just do it in the last pod"?
2. **Bad data and new regions.** A new region `04-central.csv` arrives, together with a broken file `05-islands.csv`
   (semicolons, wrong header). Change the pipeline so that it processes 6 files, rejects invalid files, and still publishes
   every valid region.
3. **Where is the data?** Find the objects behind the `reports` PVC in MinIO, and explain what happens to them when the
   namespace is deleted.

<details><summary>Solution 1 – fan-in</summary>

Indexes run in parallel, in any order and on any node, so there is no "last pod". A fan-in step must start *after*
the Job completes: a second Job here, or a workflow engine (Argo Workflows, Tekton) in production.

```bash
workstation$ kubectl apply -f - <<'YAML'
apiVersion: batch/v1
kind: Job
metadata:
  name: sales-summary
  namespace: lab-08-data
spec:
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      containers:
      - name: summary
        image: busybox:1.38
        command:
        - sh
        - -c
        - |
          set -eu
          for f in /reports/*.json; do [ "$f" = /reports/summary.json ] || cat "$f"; done | sed 's/[{}"]//g' | awk -F, '
            { for (i = 1; i <= NF; i++) { split($i, kv, ":"); v[kv[1]] = kv[2] }
              total += v["revenue"]
              if (v["revenue"] > best) { best = v["revenue"]; region = v["region"] } }
            END { printf "{\"regions\":%d,\"total_revenue\":%.2f,\"best_region\":\"%s\",\"generated\":\"%s\"}\n",
                         NR, total, region, strftime("%Y-%m-%dT%H:%M:%SZ") }' > /tmp/summary.json
          cp /tmp/summary.json /reports/summary.json
          cat /reports/summary.json
        volumeMounts:
        - {name: reports, mountPath: /reports}
      volumes:
      - name: reports
        persistentVolumeClaim:
          claimName: reports
YAML
workstation$ kubectl -n lab-08-data wait --for=condition=Complete job/sales-summary --timeout=90s
workstation$ kubectl -n lab-08-data logs job/sales-summary
{"regions":4,"total_revenue":147149.37,"best_region":"west","generated":"2026-11-04T03:07:53Z"}
client-vm$ curl -s -H 'Host: reports.example.test' http://192.168.1.241/reports/summary.json
```

The loop skips `summary.json` itself, so the job can be re-run safely (idempotent).
</details>

<details><summary>Solution 2 – bad data and new regions</summary>

Upload the files (client VM, in `~/lab-08-raw`):

```bash
client-vm$ { echo "date,product,qty,unit_price"; for d in $(seq -w 1 28); do echo "2026-10-$d,mug,$((RANDOM%20+1)),19.99"; done; } > 04-central.csv
client-vm$ printf 'DATE;PRODUCT;QTY\n2026-10-01;mug;3\n' > 05-islands.csv
client-vm$ docker run --rm --network host -v ~/lab-08-raw:/data:ro --entrypoint sh pgsty/mc:RELEASE.2026-10-26T00-00-00Z -c \
  'mc alias set m http://192.168.1.100:9000 minioadmin minioadmin123 && mc cp /data/04-central.csv /data/05-islands.csv m/lab-08-raw/'
```

Add a header check to `process.sh` (right after `FILE=...`) and set `completions: 6` in the CronJob, then re-apply the
Phase 2 manifest:

```sh
head -1 "$FILE" | grep -qx 'date,product,qty,unit_price' || { echo "invalid header in $FILE"; exit 1; }
```

```bash
workstation$ kubectl -n lab-08-data create job report-run4 --from=cronjob/nightly-sales-report
workstation$ kubectl -n lab-08-data wait --for=condition=Failed job/report-run4 --timeout=180s
workstation$ kubectl -n lab-08-data get job report-run4 -o jsonpath='completed={.status.completedIndexes} failed={.status.failedIndexes}{"\n"}'
completed=0-4 failed=5
workstation$ kubectl -n lab-08-data get pods -l job-name=report-run4
report-run4-0-hflmk   0/1     Completed   0          25s
...
report-run4-4-j6z6j   0/1     Completed   0          16s
report-run4-5-c8mdw   0/1     Error       0          16s
report-run4-5-n7t8d   0/1     Error       0          4s
```

`backoffLimitPerIndex: 1` retried index 5 once, and then only that index was marked failed, while `central.json` was published.
The Job ends `Failed` (reason `FailedIndexes`), so monitoring alerts, but the good data is not held back by one bad file.
`maxFailedIndexes: 1` additionally stops the whole Job early if *more* than one file is bad, which usually means a broken
upload rather than a broken file.

> Hard-coding `completions` is the weak spot. A production pipeline would first count the files (a small "plan" Job, or the CronJob
> replaced by an operator), or use a work queue.
</details>

<details><summary>Solution 3 – where is the data?</summary>

```bash
workstation$ kubectl get pv $(kubectl -n lab-08-data get pvc reports -o jsonpath='{.spec.volumeName}') -o jsonpath='{.spec.csi.volumeHandle}{"\n"}'
training-bucket/pvc-a24702db-1116-41fd-81d7-d2ab1fd6e38c
client-vm$ docker run --rm --network host --entrypoint sh pgsty/mc:RELEASE.2026-10-26T00-00-00Z -c \
  'mc alias set m http://192.168.1.100:9000 minioadmin minioadmin123 >/dev/null && mc ls -r m/training-bucket/pvc-a24702db-1116-41fd-81d7-d2ab1fd6e38c/'
[2026-11-04 03:08:44 UTC]   114B STANDARD central.json
[2026-11-04 03:08:40 UTC]   114B STANDARD east.json
...
```

Each PVC is a *prefix* in the shared `training-bucket`. The StorageClass uses the default `reclaimPolicy: Delete`, so deleting
the namespace deletes the PVC, then the PV, and csi-s3 removes the prefix. After cleanup, `mc ls` on it returns nothing.
For reports you must keep, use a StorageClass with `reclaimPolicy: Retain`.
</details>

### Clean up

```bash
workstation$ kubectl delete namespace lab-08-data
client-vm$ docker run --rm --network host --entrypoint sh pgsty/mc:RELEASE.2026-10-26T00-00-00Z -c \
  'mc alias set m http://192.168.1.100:9000 minioadmin minioadmin123 && mc rb --force m/lab-08-raw'
client-vm$ rm -rf ~/lab-08-raw gen-sales.sh
```


---

## Scenario 5: Game day – ten faults, one hour

**Story.** It's 9 AM on Monday. Over the weekend, an intern "cleaned up" the manifests of the ticket-shop and redeployed it.
Nothing works, the on-call pager is screaming, and the intern is on holiday. Your job: get `http://tickets.example.test`
fully working again. There are **ten** independent faults, and some hide behind others.

Rules of the game:
- Treat the stack as a black box. **Don't read the incident manifest.** Diagnose from cluster state only, as you would in
  a real incident.
- Fix the live objects (`kubectl patch/set/apply/edit`), and write down symptom → evidence → fix for each fault.
- Run `verify.sh` at any time. You're done when it prints `12 passed, 0 failed`.

### Setup

<details><summary>Incident manifest (contains spoilers, so just copy it and apply it)</summary>

```bash
workstation$ kubectl apply -f - <<'YAML'
apiVersion: v1
kind: Namespace
metadata:
  name: lab-08-gameday
---
apiVersion: v1
kind: ResourceQuota
metadata:
  name: team-budget
  namespace: lab-08-gameday
spec:
  hard:
    requests.memory: 1Gi
---
apiVersion: v1
kind: Secret
metadata:
  name: frontend-secrets
  namespace: lab-08-gameday
stringData:
  api-token: "s3cr3t-token"
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: redis
  namespace: lab-08-gameday
spec:
  replicas: 1
  selector:
    matchLabels: {app: redis}
  template:
    metadata:
      labels: {app: redis}
    spec:
      containers:
      - name: redis
        image: redis:8.8-alpinee
        ports: [{containerPort: 6379}]
        resources:
          requests: {cpu: 50m, memory: 64Mi}
---
apiVersion: v1
kind: Service
metadata:
  name: redis
  namespace: lab-08-gameday
spec:
  selector: {app: redis}
  ports: [{port: 6379}]
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: api
  namespace: lab-08-gameday
spec:
  replicas: 2
  selector:
    matchLabels: {app: api}
  template:
    metadata:
      labels: {app: api, tier: backend}
    spec:
      containers:
      - name: api
        image: ghcr.io/stefanprodan/podinfo:6.17.0
        command: ["./podinfo", "--port=9898", "--cache-server=tcp://redis:6379"]
        ports: [{name: http, containerPort: 9898}]
        readinessProbe:
          httpGet: {path: /ready, port: http}
          periodSeconds: 5
        resources:
          requests: {cpu: 50m, memory: 64Mi}
---
apiVersion: v1
kind: Service
metadata:
  name: api
  namespace: lab-08-gameday
spec:
  selector: {app: api-server}
  ports: [{name: http, port: 80, targetPort: http}]
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: frontend
  namespace: lab-08-gameday
spec:
  replicas: 2
  selector:
    matchLabels: {app: frontend}
  template:
    metadata:
      labels: {app: frontend, tier: frontend}
    spec:
      containers:
      - name: web
        image: ghcr.io/stefanprodan/podinfo:6.17.0
        command: ["./podinfo", "--port=9898", "--backend-url=http://api/echo"]
        env:
        - name: API_TOKEN
          valueFrom:
            secretKeyRef: {name: frontend-secrets, key: API_TOKEN}
        ports: [{name: http, containerPort: 9898}]
        resources:
          requests: {cpu: 50m, memory: 64Mi}
---
apiVersion: v1
kind: Service
metadata:
  name: frontend
  namespace: lab-08-gameday
spec:
  selector: {app: frontend}
  ports: [{name: http, port: 80, targetPort: http}]
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: frontend-egress
  namespace: lab-08-gameday
spec:
  podSelector:
    matchLabels: {app: frontend}
  policyTypes: ["Egress"]
  egress:
  - to:
    - podSelector:
        matchLabels: {app: api}
    ports:
    - {protocol: TCP, port: 9898}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: report-generator
  namespace: lab-08-gameday
spec:
  replicas: 1
  selector:
    matchLabels: {app: report-generator}
  template:
    metadata:
      labels: {app: report-generator}
    spec:
      nodeSelector:
        disktype: nvme
      containers:
      - name: gen
        image: busybox:1.38
        command: ["sh", "-c", "while true; do echo generating report; sleep 30; done"]
        resources:
          requests: {cpu: 10m, memory: 16Mi}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: analytics
  namespace: lab-08-gameday
spec:
  replicas: 2
  selector:
    matchLabels: {app: analytics}
  template:
    metadata:
      labels: {app: analytics}
    spec:
      containers:
      - name: analytics
        image: busybox:1.38
        command: ["sh", "-c", "while true; do sleep 60; done"]
        resources:
          requests: {cpu: 10m, memory: 512Mi}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: thumbnailer
  namespace: lab-08-gameday
spec:
  replicas: 1
  selector:
    matchLabels: {app: thumbnailer}
  template:
    metadata:
      labels: {app: thumbnailer}
    spec:
      containers:
      - name: thumbnailer
        image: polinux/stress:1.0.4
        command: ["stress", "--vm", "1", "--vm-bytes", "96M", "--vm-hang", "0"]
        resources:
          requests: {cpu: 10m, memory: 32Mi}
          limits: {memory: 64Mi}
---
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: tickets-gw
  namespace: lab-08-gameday
spec:
  gatewayClassName: nginx
  listeners:
  - {name: http, protocol: HTTP, port: 80, hostname: tickets.example.test}
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: tickets
  namespace: lab-08-gameday
spec:
  parentRefs: [{name: tickets-gw}]
  rules:
  - backendRefs:
    - {name: frontend, port: 9898}
YAML
```
</details>

The acceptance test:

```bash
workstation$ cat > verify.sh <<'SCRIPT'
#!/usr/bin/env bash
# Game-day acceptance test: prints PASS/FAIL per check
NS=lab-08-gameday; ok=0; fail=0
kubectl -n $NS apply -f - >/dev/null <<YAML
apiVersion: v1
kind: Pod
metadata: {name: probe, namespace: $NS}
spec:
  containers:
  - name: curl
    image: curlimages/curl:8.23.0
    command: ["sleep", "86400"]
    resources: {requests: {cpu: 10m, memory: 16Mi}}
YAML
kubectl -n $NS wait --for=condition=Ready pod/probe --timeout=60s >/dev/null
check() { if eval "$2" >/dev/null 2>&1; then echo "PASS  $1"; ok=$((ok+1)); else echo "FAIL  $1"; fail=$((fail+1)); fi; }
for d in redis api frontend report-generator analytics thumbnailer; do
  check "deployment $d available" "kubectl -n $NS wait --for=condition=Available deploy/$d --timeout=5s"
done
check "thumbnailer has no restarts in the last minute" \
  "[ \"\$(kubectl -n $NS get pods -l app=thumbnailer -o jsonpath='{.items[0].status.containerStatuses[0].restartCount}')\" = 0 ]"
check "gateway data plane running" "kubectl -n $NS wait --for=condition=Available deploy/tickets-gw-nginx --timeout=5s"
check "route backends resolved" \
  "kubectl -n $NS get httproute tickets -o jsonpath='{.status.parents[0].conditions[?(@.type==\"ResolvedRefs\")].status}' | grep -qx True"
check "api has ready endpoints" \
  "kubectl -n $NS get endpointslices -l kubernetes.io/service-name=api -o jsonpath='{.items[*].endpoints[?(@.conditions.ready==true)].addresses[0]}' | grep -q ."
check "end-to-end: frontend -> api via gateway" \
  "kubectl -n $NS exec probe -- curl -sf -m 5 -H 'Host: tickets.example.test' -d ping http://tickets-gw-nginx/api/echo"
check "end-to-end: api cache (redis)" \
  "kubectl -n $NS exec probe -- curl -sf -m 5 -d ok http://api/cache/gameday"
echo "---- $ok passed, $fail failed"
[ $fail -eq 0 ]
SCRIPT
workstation$ chmod +x verify.sh && ./verify.sh
FAIL  deployment redis available
FAIL  deployment api available
...
---- 0 passed, 12 failed
```

### The tickets that came in

| Ticket | Reported by | Text |
|--------|-------------|------|
| #1 | Customer | "tickets.example.test doesn't load at all." |
| #2 | QA | "Even when the page loads, booking (`POST /api/echo`) fails." |
| #3 | Finance | "The nightly report generator hasn't produced anything." |
| #4 | Data team | "Analytics runs with half of its workers." |
| #5 | Media team | "Thumbnailer keeps restarting." |

### Triage toolkit

```bash
workstation$ kubectl -n lab-08-gameday get deploy,pods,endpointslices
workstation$ kubectl -n lab-08-gameday get events --sort-by=.lastTimestamp | tail -30
workstation$ kubectl -n lab-08-gameday get events --field-selector reason=FailedCreate -o custom-columns=OBJ:.involvedObject.name,MSG:.message
workstation$ kubectl -n lab-08-gameday describe pod <pod>              # Events, State, Last State, Reason
workstation$ kubectl -n lab-08-gameday get httproute,gateway -o yaml    # status.conditions
workstation$ kubectl -n lab-08-gameday describe quota
workstation$ kubectl -n lab-08-gameday get networkpolicy
workstation$ kubectl -n lab-08-gameday exec probe -- curl -sv -m 3 http://<service>   # probe pod is created by verify.sh
```

Work outside-in: **Gateway → route → Service → endpoints → pods → dependencies**. Then handle the "side" workloads.

### Hints (open only when stuck)

<details><summary>Hint – the Gateway is Programmed, but there is no data-plane pod</summary>

Look at the events of the `tickets-gw-nginx` ReplicaSet. Who creates that pod, and what does every pod in this namespace need?
</details>

<details><summary>Hint – I fixed the quota problem but nothing happens</summary>

The ReplicaSet controller retries failed pod creations with an exponential backoff that can grow to many minutes.
Something has to make it reconcile again.
</details>

### Solution

<details><summary>Fault 1 – route points to a port the Service doesn't have</summary>

- **Symptom:** ticket #1. `HTTPRoute` status `ResolvedRefs=False`.
- **Evidence:**
  ```bash
  workstation$ kubectl -n lab-08-gameday get httproute tickets -o jsonpath='{range .status.parents[*].conditions[*]}{.type}={.status} {.reason}: {.message}{"\n"}{end}'
  Accepted=True Accepted: The Route is accepted
  ResolvedRefs=False BackendNotFound: No matching port for Service frontend and port 9898
  ```
  `backendRefs.port` is the **Service** port (80), not the container port (9898).
- **Fix:**
  ```bash
  workstation$ kubectl -n lab-08-gameday patch httproute tickets --type=json -p '[{"op":"replace","path":"/spec/rules/0/backendRefs/0/port","value":80}]'
  ```
</details>

<details><summary>Fault 2 – the Gateway's data-plane pod is blocked by the ResourceQuota</summary>

- **Symptom:** ticket #1, still. The Gateway reports `Programmed=True` and has an address, but `deploy/tickets-gw-nginx` is `0/1`.
- **Evidence:**
  ```
  tickets-gw-nginx-6c7f596f85   Error creating: pods "tickets-gw-nginx-..." is forbidden: failed quota: team-budget: must specify requests.memory for: init,nginx
  ```
  A quota on `requests.memory` makes the field **mandatory for every pod** in the namespace, including pods you didn't write
  (NGF creates the data plane in the Gateway's namespace).
- **Fix:** a LimitRange that injects default requests:

```bash
workstation$ kubectl apply -f - <<'YAML'
apiVersion: v1
kind: LimitRange
metadata:
  name: defaults
  namespace: lab-08-gameday
spec:
  limits:
  - type: Container
    defaultRequest: {cpu: 50m, memory: 64Mi}
YAML
```

  LimitRange defaults apply only to *new* pods, and the ReplicaSet is in back-off (see Fault 9 for the nudge).
</details>

<details><summary>Fault 3 – frontend references a Secret key that doesn't exist</summary>

- **Symptom:** frontend pods in `CreateContainerConfigError`.
- **Evidence:** `kubectl describe pod` shows `API_TOKEN: <set to the key 'API_TOKEN' in secret 'frontend-secrets'>` and the event
  `Error: couldn't find key API_TOKEN in Secret lab-08-gameday/frontend-secrets`. Compare with
  `kubectl -n lab-08-gameday get secret frontend-secrets -o jsonpath='{.data}'`: the key is `api-token`. Keys are case-sensitive.
- **Fix:**
  ```bash
  workstation$ kubectl -n lab-08-gameday patch deploy frontend --type=json -p '[{"op":"replace","path":"/spec/template/spec/containers/0/env/0/valueFrom/secretKeyRef/key","value":"api-token"}]'
  ```
</details>

<details><summary>Fault 4 – egress policy without DNS</summary>

- **Symptom:** ticket #2. The page loads, but `POST /api/echo` hangs until the client times out
  (`curl -m 10 … → HTTP 000`), and the frontend logs `"msg":"backend call failed","error":"Post \"http://api/echo\": context canceled"`.
  Nothing is refused; the packets are silently dropped. That's the signature of a NetworkPolicy.
- **Evidence:** `kubectl get networkpolicy frontend-egress -o yaml` allows egress only to `app=api:9898`. Once a pod is selected
  by an Egress policy, everything else is denied, including UDP/TCP 53 to CoreDNS.
- **Fix:**

```bash
workstation$ kubectl apply -f - <<'YAML'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: frontend-allow-dns
  namespace: lab-08-gameday
spec:
  podSelector:
    matchLabels: {app: frontend}
  policyTypes: ["Egress"]
  egress:
  - to:
    - namespaceSelector:
        matchLabels: {kubernetes.io/metadata.name: kube-system}
      podSelector:
        matchLabels: {k8s-app: kube-dns}
    ports:
    - {protocol: UDP, port: 53}
    - {protocol: TCP, port: 53}
YAML
```
</details>

<details><summary>Fault 5 – Service selector doesn't match the pods</summary>

- **Symptom:** ticket #2. `endpointslices -l kubernetes.io/service-name=api` shows no endpoints.
- **Evidence:** `kubectl get svc api -o jsonpath='{.spec.selector}'` gives `{"app":"api-server"}`, but the pods are labelled `app=api`
  (`kubectl get pods --show-labels`).
- **Fix:**
  ```bash
  workstation$ kubectl -n lab-08-gameday patch svc api -p '{"spec":{"selector":{"app":"api"}}}'
  ```
</details>

<details><summary>Fault 6 – readiness probe on a path that doesn't exist</summary>

- **Symptom:** even with the right selector, the api endpoints are `ready=false`, and the pods are `0/1 Running` with 0 restarts.
- **Evidence:** `Readiness probe failed: HTTP probe failed with statuscode: 404`. The probe uses `/ready`, while podinfo serves `/readyz`.
  A failing *readiness* probe never restarts a container. It only keeps the pod out of the Service.
- **Fix:**
  ```bash
  workstation$ kubectl -n lab-08-gameday patch deploy api --type=json -p '[{"op":"replace","path":"/spec/template/spec/containers/0/readinessProbe/httpGet/path","value":"/readyz"}]'
  ```
</details>

<details><summary>Fault 7 – typo in the Redis image tag</summary>

- **Symptom:** the cache check fails, and redis is `ErrImagePull`/`ImagePullBackOff`.
- **Evidence:** `reading manifest 8.8-alpinee in docker.io/library/redis: manifest unknown`.
- **Fix:**
  ```bash
  workstation$ kubectl -n lab-08-gameday set image deploy/redis redis=redis:8.8-alpine
  ```
</details>

<details><summary>Fault 8 – nodeSelector for a label no node has</summary>

- **Symptom:** ticket #3. `report-generator` is `Pending`.
- **Evidence:** `0/3 nodes are available: 1 node(s) had untolerated taint(s), 2 node(s) didn't match Pod's node affinity/selector.`
  `kubectl get nodes -L disktype` shows the label isn't set anywhere.
- **Fix:** the report generator doesn't need special disks, so remove the selector. (Labelling a node would also work, but it changes the
  cluster for everybody.)
  ```bash
  workstation$ kubectl -n lab-08-gameday patch deploy report-generator --type=json -p '[{"op":"remove","path":"/spec/template/spec/nodeSelector"}]'
  ```
</details>

<details><summary>Fault 9 – quota exceeded, and the rollout deadlock it causes</summary>

- **Symptom:** ticket #4. `analytics` is `1/2`.
- **Evidence:** `exceeded quota: team-budget, requested: requests.memory=512Mi, used: requests.memory=880Mi, limited: requests.memory=1Gi`.
- **Fix, part 1:** analytics doesn't need 512Mi per worker:
  ```bash
  workstation$ kubectl -n lab-08-gameday set resources deploy/analytics --requests=memory=128Mi
  ```
- **The trap:** the rolling update keeps the old 512Mi pod until a new pod is ready, and then there is no room for the second new
  pod (or for the gateway pod). With every fix above applied, the quota showed `1Gi/1Gi` and the rollout stalled. Let the
  update replace pods instead of adding them first:
  ```bash
  workstation$ kubectl -n lab-08-gameday patch deploy analytics -p '{"spec":{"strategy":{"rollingUpdate":{"maxSurge":0,"maxUnavailable":1}}}}'
  ```
- **The second trap:** quota usage drops to 512Mi, but nothing happens for many minutes. The ReplicaSet controller is in
  back-off after dozens of failed creations. Nudge both stuck workloads:
  ```bash
  workstation$ kubectl -n lab-08-gameday rollout restart deploy/analytics deploy/tickets-gw-nginx
  workstation$ kubectl -n lab-08-gameday describe quota team-budget | tail -1
  requests.memory  832Mi  1Gi
  ```
  (`tickets-gw-nginx` is managed by NGF, and restarting it is harmless.)
</details>

<details><summary>Fault 10 – memory limit lower than the working set</summary>

- **Symptom:** ticket #5. `thumbnailer` is `OOMKilled` / `CrashLoopBackOff`.
- **Evidence:** `lastState.terminated.reason=OOMKilled exitCode=137`. The process allocates ~96M with a 64Mi limit.
- **Fix:**
  ```bash
  workstation$ kubectl -n lab-08-gameday set resources deploy/thumbnailer --limits=memory=128Mi
  ```
</details>

Final check:

```bash
workstation$ ./verify.sh
PASS  deployment redis available
...
PASS  end-to-end: frontend -> api via gateway
PASS  end-to-end: api cache (redis)
---- 12 passed, 0 failed
client-vm$ curl -s -H 'Host: tickets.example.test' -d 'hello from client' http://192.168.1.241/api/echo
[
  "hello from client"
]
```

### Debrief questions

1. Which faults would a CI pipeline have caught *before* deployment (`kubeconform`, `kubectl apply --dry-run=server`, policy checks)?
2. Which ones only show up at runtime, and which signal (event, condition, metric) would you alert on for each?
3. Two faults masked others (route → endpoints → readiness; quota → gateway pod). How does "outside-in" triage help here?

### Clean up

```bash
workstation$ kubectl delete namespace lab-08-gameday
workstation$ rm -f verify.sh
```


---

## Scenario 6: Patch night – node maintenance without downtime

**Story.** A kernel CVE was published this morning, and both workers must be patched and rebooted tonight. The SLO for the
web shop is "no failed requests". You'll find out the hard way which parts of the stack are *not* ready for that:
a singleton Gateway, a database pinned to one node, a bare Pod left by a colleague, and two subtle topology-spread pitfalls. Then you
fix them, and finally you run an unplanned-failure drill.

**⚠ cluster-wide:** this scenario cordons and drains node2 and stops the kubelet on node1. Run it when nobody else
uses the cluster, and always run *Clean up*.

```mermaid
flowchart LR
  client([client VM<br/>probe.sh]) --> gw[maint-gw data plane]
  gw --> web[web x4<br/>PDB maxUnavailable 1<br/>topology spread]
  web -.-> db[(db-0 redis<br/>PV pinned to node2)]
  agent[legacy-agent<br/>bare Pod on node2]
```

**Uses:** cordon/drain, PodDisruptionBudgets, topology spread (`nodeTaintsPolicy`, `matchLabelKeys`), local PVs,
NoExecute tolerations, NGINX Gateway Fabric `NginxProxy` (data-plane replicas and PDB).

### Phase 1 – Deploy, and the first surprise

```bash
workstation$ kubectl apply -f - <<'YAML'
apiVersion: v1
kind: Namespace
metadata:
  name: lab-08-maint
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
  namespace: lab-08-maint
spec:
  replicas: 4
  selector:
    matchLabels: {app: web}
  template:
    metadata:
      labels: {app: web}
    spec:
      topologySpreadConstraints:
      - maxSkew: 1
        topologyKey: kubernetes.io/hostname
        whenUnsatisfiable: DoNotSchedule
        labelSelector:
          matchLabels: {app: web}
      tolerations:
      - {key: node.kubernetes.io/unreachable, operator: Exists, effect: NoExecute, tolerationSeconds: 30}
      - {key: node.kubernetes.io/not-ready, operator: Exists, effect: NoExecute, tolerationSeconds: 30}
      containers:
      - name: web
        image: ghcr.io/stefanprodan/podinfo:6.17.0
        ports: [{name: http, containerPort: 9898}]
        readinessProbe:
          httpGet: {path: /readyz, port: http}
          periodSeconds: 2
        lifecycle:
          preStop:
            sleep: {seconds: 5}
        resources:
          requests: {cpu: 50m, memory: 32Mi}
---
apiVersion: v1
kind: Service
metadata:
  name: web
  namespace: lab-08-maint
spec:
  selector: {app: web}
  ports: [{name: http, port: 80, targetPort: http}]
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: web
  namespace: lab-08-maint
spec:
  maxUnavailable: 1
  selector:
    matchLabels: {app: web}
---
apiVersion: v1
kind: PersistentVolume
metadata:
  name: lab-08-maint-db
spec:
  capacity: {storage: 1Gi}
  accessModes: ["ReadWriteOnce"]
  persistentVolumeReclaimPolicy: Retain
  storageClassName: lab-08-maint-local
  claimRef: {namespace: lab-08-maint, name: data-db-0}
  hostPath:
    path: /mnt/lab-08-maint/db
    type: DirectoryOrCreate
  nodeAffinity:
    required:
      nodeSelectorTerms:
      - matchExpressions:
        - {key: kubernetes.io/hostname, operator: In, values: ["node2"]}
---
apiVersion: v1
kind: Service
metadata:
  name: db
  namespace: lab-08-maint
spec:
  clusterIP: None
  selector: {app: db}
  ports: [{port: 6379}]
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: db
  namespace: lab-08-maint
spec:
  serviceName: db
  replicas: 1
  selector:
    matchLabels: {app: db}
  template:
    metadata:
      labels: {app: db}
    spec:
      containers:
      - name: redis
        image: redis:8.8
        args: ["--appendonly", "yes"]
        ports: [{containerPort: 6379}]
        volumeMounts:
        - {name: data, mountPath: /data}
  volumeClaimTemplates:
  - metadata: {name: data}
    spec:
      storageClassName: lab-08-maint-local
      accessModes: ["ReadWriteOnce"]
      resources: {requests: {storage: 1Gi}}
---
apiVersion: v1
kind: Pod
metadata:
  name: legacy-agent
  namespace: lab-08-maint
spec:
  nodeName: node2
  containers:
  - name: agent
    image: busybox:1.38
    command: ["sh", "-c", "while true; do date >> /scratch/heartbeat; sleep 10; done"]
    volumeMounts:
    - {name: scratch, mountPath: /scratch}
  volumes:
  - name: scratch
    emptyDir: {}
---
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: maint-gw
  namespace: lab-08-maint
spec:
  gatewayClassName: nginx
  infrastructure:
    labels: {app: maint-gw}
  listeners:
  - {name: http, protocol: HTTP, port: 80, hostname: web.example.test}
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: web
  namespace: lab-08-maint
spec:
  parentRefs: [{name: maint-gw}]
  rules:
  - backendRefs: [{name: web, port: 80}]
YAML
workstation$ kubectl -n lab-08-maint get pods -o wide --no-headers | awk '{print $1, $3, $7}'
db-0 Running node2
legacy-agent Running node2
maint-gw-nginx-767954656d-xg8vb Running node2
web-7b95744d8b-cvrrm Pending <none>
web-7b95744d8b-hg2tz Running node2
web-7b95744d8b-jj6h6 Pending <none>
web-7b95744d8b-wqv54 Running node1
workstation$ kubectl -n lab-08-maint get events --field-selector reason=FailedScheduling -o custom-columns=MSG:.message | tail -1
0/3 nodes are available: 1 node(s) had untolerated taint(s), 2 node(s) didn't match pod topology spread constraints. ...
```

Two of four replicas are Pending although both workers have plenty of room. **Why:** `topologySpreadConstraints`
counts *every node with the topology label* as a domain, by default even nodes the Pod can't run on
(`nodeTaintsPolicy: Ignore`). The tainted master is a domain with 0 Pods, so a third replica would create a skew of
2 − 0 = 2 > `maxSkew`. Tell the scheduler to ignore nodes whose taints the Pod does not tolerate:

```bash
workstation$ kubectl -n lab-08-maint patch deploy web --type=json \
  -p '[{"op":"add","path":"/spec/template/spec/topologySpreadConstraints/0/nodeTaintsPolicy","value":"Honor"}]'
workstation$ kubectl -n lab-08-maint rollout status deploy/web
workstation$ kubectl -n lab-08-maint get pods -l app=web -o wide --no-headers | awk '{print $3, $7}'
Running node2
Running node1
Running node2
Running node2
Terminating node2
Terminating node1
```

**Second surprise:** 3 + 1, not 2 + 2. During the rollout, the *old* Pods still match `app: web` and were counted when the new
ones were placed. `matchLabelKeys: [pod-template-hash]` makes the constraint count only Pods of the same ReplicaSet:

```bash
workstation$ kubectl -n lab-08-maint patch deploy web --type=json \
  -p '[{"op":"add","path":"/spec/template/spec/topologySpreadConstraints/0/matchLabelKeys","value":["pod-template-hash"]}]'
workstation$ kubectl -n lab-08-maint rollout status deploy/web
workstation$ sleep 15; kubectl -n lab-08-maint get pods -l app=web -o wide --no-headers | awk '{print $7}' | sort | uniq -c
      2 node1
      2 node2
```

Note the Gateway's address and store some "business data" in the database:

```bash
workstation$ kubectl -n lab-08-maint get gateway maint-gw
NAME       CLASS   ADDRESS         PROGRAMMED   AGE
maint-gw   nginx   192.168.1.240   True         2m
workstation$ kubectl -n lab-08-maint exec db-0 -- redis-cli set orders:last 42
OK
```

### Phase 2 – The availability probe

On the client VM, a probe sends 5 requests per second and reports every failure:

```bash
client-vm$ cat > probe.sh <<'SCRIPT'
#!/bin/sh
# Usage: GW=<gateway-ip> ./probe.sh <seconds>  - one request every 0.2 s, prints failures and a summary
end=$(( $(date +%s) + ${1:-120} )); ok=0; fail=0
while [ "$(date +%s)" -lt "$end" ]; do
  code=$(curl -s -o /dev/null -m 2 -w '%{http_code}' -H 'Host: web.example.test' "http://$GW/")
  if [ "$code" = 200 ]; then ok=$((ok+1)); else fail=$((fail+1)); echo "$(date +%T) $code"; fi
  sleep 0.2
done
echo "ok=$ok failed=$fail"
SCRIPT
client-vm$ chmod +x probe.sh
```

### Phase 3 – Patch node2

Start the probe in one terminal (`client-vm$ GW=192.168.1.240 ./probe.sh 240`) and drain node2 in another:

```bash
workstation$ kubectl drain node2 --ignore-daemonsets --delete-emptydir-data --timeout=60s
error: unable to drain node "node2" due to error: cannot delete Pods that declare no controller (use --force to override): lab-08-maint/legacy-agent, continuing command...
There are pending nodes to be drained:
 node2
```

The colleague's bare Pod blocks the drain, because without a controller nobody would recreate it. Its "heartbeat" data lives in an
`emptyDir`, so it is disposable. Decide consciously and force it:

```bash
workstation$ kubectl drain node2 --ignore-daemonsets --delete-emptydir-data --force --timeout=180s
node/node2 already cordoned
Warning: ignoring DaemonSet-managed Pods: kube-system/calico-node-r5srn, kube-system/csi-s3-ckz6g, kube-system/kube-proxy-jpvmr, metallb-system/speaker-rs7gh; deleting Pods that declare no controller: lab-08-maint/legacy-agent
evicting pod lab-08-maint/web-56979844bf-lrfdq
evicting pod lab-08-maint/legacy-agent
evicting pod lab-08-maint/maint-gw-nginx-767954656d-xg8vb
evicting pod lab-08-maint/db-0
evicting pod lab-08-maint/web-56979844bf-fxb56
error when evicting pods/"web-56979844bf-lrfdq" -n "lab-08-maint" (will retry after 5s): Cannot evict pod as it would violate the pod's disruption budget.
pod/db-0 evicted
pod/maint-gw-nginx-767954656d-xg8vb evicted
evicting pod lab-08-maint/web-56979844bf-lrfdq
pod/web-56979844bf-fxb56 evicted
pod/web-56979844bf-lrfdq evicted
pod/legacy-agent evicted
node/node2 drained
workstation$ kubectl -n lab-08-maint get pods -o wide --no-headers | awk '{print $1, $3, $7}'
db-0 Pending <none>
maint-gw-nginx-767954656d-thvtz Running node1
web-56979844bf-2qrbv Running node1
web-56979844bf-8zcgz Running node1
web-56979844bf-m2tqz Running node1
web-56979844bf-tnbxm Running node1
workstation$ kubectl -n lab-08-maint get events --field-selector involvedObject.name=db-0,reason=FailedScheduling -o custom-columns=MSG:.message | tail -1
0/3 nodes are available: 1 node(s) didn't match PersistentVolume's node affinity, 1 node(s) had untolerated taint(s), 1 node(s) were unschedulable. ...
```

What happened:
- **web:** the PDB let drain evict only one Pod at a time. Thanks to `nodeTaintsPolicy: Honor`, the cordoned node2
  (taint `node.kubernetes.io/unschedulable`) no longer counts as a domain, so all replacements could go to node1.
  (Without it, the replacement would stay Pending: that's the default behaviour from Scenario 1, Solution 2.)
- **db-0:** evicted and **Pending**. Its data lives on node2's disk, and the database is down until node2 is back.
  That is an accepted trade-off of node-local storage, not a bug, but it must be in the maintenance plan.
- **The probe** tells the real story:

```
06:13:47 000
06:13:47 000
06:13:48 000
...
06:14:00 000
ok=271 failed=11
```

13 seconds of errors: the **Gateway data plane is a single Pod**, and draining its node takes the edge down until the
replacement is ready. The SLO is violated.

Now "patch" the node (on a real system `sudo reboot`; here a kubelet restart is enough), bring it back and check the data:

```bash
node2$ sudo systemctl restart kubelet
workstation$ kubectl wait --for=condition=Ready node/node2 --timeout=120s
workstation$ kubectl uncordon node2
workstation$ kubectl -n lab-08-maint wait --for=condition=Ready pod/db-0 --timeout=120s
workstation$ kubectl -n lab-08-maint exec db-0 -- redis-cli get orders:last
42
workstation$ kubectl -n lab-08-maint get pods -l app=web -o wide --no-headers | awk '{print $7}' | sort | uniq -c
      4 node1
```

Kubernetes never moves running Pods back. Rebalance explicitly:

```bash
workstation$ kubectl -n lab-08-maint rollout restart deploy/web
workstation$ kubectl -n lab-08-maint rollout status deploy/web
workstation$ sleep 15; kubectl -n lab-08-maint get pods -l app=web -o wide --no-headers | awk '{print $3, $7}' | sort | uniq -c
      2 Running node1
      2 Running node2
```

### Phase 4 – A highly available edge

NGINX Gateway Fabric configures the data plane through an `NginxProxy` resource referenced by the Gateway. Two
replicas, a PDB and a spread constraint (again with `Honor` and `matchLabelKeys`) make the edge drain-safe:

```bash
workstation$ kubectl apply -f - <<'YAML'
apiVersion: gateway.nginx.org/v1alpha2
kind: NginxProxy
metadata:
  name: maint-proxy
  namespace: lab-08-maint
spec:
  kubernetes:
    deployment:
      replicas: 2
      podDisruptionBudget:
        maxUnavailable: 1
      pod:
        topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: kubernetes.io/hostname
          whenUnsatisfiable: DoNotSchedule
          nodeTaintsPolicy: Honor
          matchLabelKeys: ["pod-template-hash"]
          labelSelector:
            matchLabels:
              gateway.networking.k8s.io/gateway-name: maint-gw
YAML
workstation$ kubectl -n lab-08-maint patch gateway maint-gw --type=merge \
  -p '{"spec":{"infrastructure":{"parametersRef":{"group":"gateway.nginx.org","kind":"NginxProxy","name":"maint-proxy"}}}}'
workstation$ kubectl -n lab-08-maint rollout status deploy/maint-gw-nginx
workstation$ kubectl -n lab-08-maint get pods -l gateway.networking.k8s.io/gateway-name=maint-gw -o wide --no-headers | awk '{print $1, $3, $7}'
maint-gw-nginx-5d455c875f-2fqrv Running node1
maint-gw-nginx-5d455c875f-sk6xb Running node2
workstation$ kubectl -n lab-08-maint get pdb
NAME             MIN AVAILABLE   MAX UNAVAILABLE   ALLOWED DISRUPTIONS   AGE
maint-gw-nginx   N/A             1                 1                     27s
web              N/A             1                 1                     6m13s
```

Patch night, take two. Probe in one terminal (`GW=192.168.1.240 ./probe.sh 150`), drain in the other:

```bash
workstation$ kubectl drain node2 --ignore-daemonsets --delete-emptydir-data --timeout=180s
evicting pod lab-08-maint/web-788847dfb4-nc8v2
evicting pod lab-08-maint/maint-gw-nginx-5d455c875f-sk6xb
evicting pod lab-08-maint/web-788847dfb4-fx8l8
evicting pod lab-08-maint/db-0
error when evicting pods/"web-788847dfb4-fx8l8" -n "lab-08-maint" (will retry after 5s): Cannot evict pod as it would violate the pod's disruption budget.
pod/maint-gw-nginx-5d455c875f-sk6xb evicted
pod/db-0 evicted
...
node/node2 drained
workstation$ kubectl uncordon node2
```

```
client-vm$ GW=192.168.1.240 ./probe.sh 150
ok=251 failed=0
```

**Zero failed requests.** (`db-0` was down again during the window, as planned and announced.)

### Phase 5 – Unplanned failure drill

Rebalance first (`kubectl -n lab-08-maint rollout restart deploy/web deploy/maint-gw-nginx`), start the probe for 170 s,
and then "crash" node1 by stopping its kubelet:

```bash
node1$ date -u +%T; sudo systemctl stop kubelet
05:19:11
workstation$ kubectl get node node1; kubectl -n lab-08-maint get pods -o wide --no-headers | awk '{print $1, $3, $7}'
```

Expected about 90 s later:
```
node1   NotReady   <none>   15d   v1.37.1
db-0 Running node2
maint-gw-nginx-75778fbf69-5r2mx Running node2
maint-gw-nginx-75778fbf69-pfp9n Running node1
web-7b894ccbf6-49ntz Terminating node1
web-7b894ccbf6-9vw26 Terminating node1
web-7b894ccbf6-d767c Running node2
web-7b894ccbf6-d97bf Running node2
web-7b894ccbf6-nxpvv Running node2
web-7b894ccbf6-szrdj Running node2
```

Restore the node within ~3 minutes:

```bash
node1$ sudo systemctl start kubelet
workstation$ kubectl wait --for=condition=Ready node/node1 --timeout=120s
```

```
client-vm$ GW=192.168.1.240 ./probe.sh 170
ok=583 failed=0
```

Why zero errors this time?
- The `web` Pods tolerate `unreachable`/`not-ready` for only **30 s** (instead of 300 s), so replacements started on node2
  soon after the node went `NotReady`.
- A stopped kubelet does **not** stop containers. The Pods and the data-plane replica on node1 kept serving, and the node
  lifecycle controller set their `Ready` condition to `False`, so they left the Service endpoints cleanly.
- `maint-gw-nginx` on node1 has the default 300 s toleration, so it was not even replaced, and it didn't need to be.

A real power loss would also kill the containers on node1. Requests in flight to them would fail until the endpoints
are updated (~40–50 s node-monitor grace period). That's why redundancy at *every* tier matters.

### Challenges

1. **Maintenance checklist.** From what you saw, write a 6–8 point checklist that a platform team runs before patch night.
2. **The database.** `db-0` was down twice. Propose two different ways to keep it available during node maintenance and
   name the trade-off of each.
3. **Too strict.** What happens to the drain if the `web` PDB is changed to `minAvailable: 4`? Predict it, then verify with
   `kubectl drain node2 --ignore-daemonsets --dry-run=server`.

<details><summary>Solution 1 – checklist</summary>

1. No bare Pods (`kubectl get pods -A -o json | jq -r '.items[] | select(.metadata.ownerReferences == null) | "\(.metadata.namespace)/\(.metadata.name)"'`).
2. Every multi-replica workload has a PDB that allows ≥ 1 disruption (`kubectl get pdb -A`, look for `ALLOWED DISRUPTIONS 0`).
3. Edge components (Gateway data plane, ingress, DNS) run ≥ 2 replicas spread across nodes.
4. Topology spread uses `nodeTaintsPolicy: Honor` (or `ScheduleAnyway`) and `matchLabelKeys: [pod-template-hash]`.
5. There is enough spare capacity on the remaining nodes to host the drained Pods (`kubectl describe node`, Allocated resources).
6. Stateful workloads on node-local storage are listed, with an announced downtime or a replica on another node.
7. Run `kubectl drain --dry-run=server` first, then drain one node at a time and uncordon it.
8. Rebalance afterwards (`rollout restart`), and verify with an external probe during the whole window.
</details>

<details><summary>Solution 2 – the database</summary>

- **Replication** (e.g. a Redis primary/replica StatefulSet with Sentinel, or a Postgres operator) with replicas on different
  nodes, each on its own local PV, plus a PDB with `maxUnavailable: 1`. The database survives the node, at the cost of more complexity,
  more storage, and failover logic in the client.
- **Network-attached storage** (a CSI driver backed by Ceph, NFS or a SAN, `ReadWriteOnce` but attachable from any node):
  the Pod can be rescheduled to another node within seconds. This costs a storage system to operate and usually adds latency.
  (`minio-sc` from this cluster is object storage: fine for files, **not** for database files.)
</details>

<details><summary>Solution 3 – too strict</summary>

With `minAvailable: 4` and 4 replicas, `ALLOWED DISRUPTIONS` is 0. Every eviction of a `web` Pod is refused, and a real
drain would retry `Cannot evict pod as it would violate the pod's disruption budget` until `--timeout`. The server dry
run shows the same refusals without touching the node (see Lab 7.19). A PDB must always leave room for at least one
voluntary disruption. Use `maxUnavailable: 1`.
</details>

### Clean up

```bash
workstation$ kubectl uncordon node1 node2                # safe to repeat
node1$ sudo systemctl is-active kubelet                  # must be "active" (also check node2)
workstation$ kubectl delete namespace lab-08-maint
workstation$ kubectl delete pv lab-08-maint-db
node2$ sudo rm -rf /mnt/lab-08-maint
client-vm$ rm -f probe.sh
```

