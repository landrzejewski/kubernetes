# GitOps with Argo CD

This chapter shows how to run applications on Kubernetes the **GitOps** way: the desired state of the cluster is kept
in Git, and an agent inside the cluster - **Argo CD** - continuously makes the cluster match it. It builds on the
Helm chart and the Kustomize overlays from module 13 and on the CRD/controller concepts from module 15.

You will:

* run a private Git server (Gitea) on the client VM,
* install Argo CD and its CLI,
* deploy, change, roll back and self-heal an application only through Git,
* order deployments with sync waves and hooks,
* deploy the Helm chart and the Kustomize overlays of module 13, using App of Apps and an ApplicationSet,
* restrict teams with AppProjects and RBAC,
* trigger syncs instantly with a webhook and keep Secrets in Git safely with Sealed Secrets.

---

## GitOps Principles

[OpenGitOps](https://opengitops.dev) defines four principles:

1. **Declarative** - the whole system is described declaratively (Kubernetes manifests, Helm charts, Kustomize).
2. **Versioned and immutable** - the desired state is stored in Git: every change is a commit with an author,
   a review (pull request) and a history; a rollback is a `git revert`.
3. **Pulled automatically** - software agents pull the desired state from Git; nobody runs `kubectl apply` against
   production by hand, and the CI system needs no cluster credentials.
4. **Continuously reconciled** - the agents compare the desired and the actual state all the time and correct drift.

**Push vs. pull deployment**

```
Push (classic CI/CD):   developer ─▶ Git ─▶ CI pipeline ──kubectl/helm (cluster credentials in CI)──▶ cluster

Pull (GitOps):          developer ─▶ Git ◀──watch/clone── Argo CD (inside the cluster) ──apply──▶ cluster
                                                          │
                                                          └── reports Synced/OutOfSync + Healthy/Degraded
```

With the pull model the cluster credentials never leave the cluster, the Git history is the audit log, and manual
changes in the cluster ("drift") are detected and can be reverted automatically. CI still builds and tests images;
it only *writes to Git* (e.g. bumps an image tag) instead of deploying.

### Argo CD architecture

Argo CD is itself a set of Kubernetes controllers plus three CRDs:

| Component | Role |
|-----------|------|
| `argocd-server` | API server, web UI, CLI and webhook endpoint |
| `argocd-repo-server` | clones Git repositories and renders manifests (plain YAML, Kustomize, Helm, Jsonnet) |
| `argocd-application-controller` | compares rendered manifests with the live objects, syncs, computes health |
| `argocd-applicationset-controller` | generates `Application` objects from templates (`ApplicationSet`) |
| `argocd-redis` | cache for rendered manifests and cluster state |
| `argocd-dex-server` | optional SSO (OIDC, LDAP, GitHub, ...) |
| `argocd-notifications-controller` | optional notifications (Slack, e-mail, webhooks) |

| CRD | Meaning |
|-----|---------|
| `Application` | *what* (Git repo + revision + path, or a Helm chart) goes *where* (cluster + namespace) and *how* (sync policy) |
| `AppProject` | a group of Applications with guard rails: allowed repos, destinations and resource kinds, RBAC roles |
| `ApplicationSet` | a template + generators (list, Git directories, clusters, ...) that create many Applications |

Every Application has two independent states:

* **sync status** - `Synced` (live objects equal the rendered manifests of the target revision) or `OutOfSync`,
* **health status** - `Healthy`, `Progressing`, `Degraded`, `Suspended`, `Missing` (Argo CD knows how to judge
  Deployments, StatefulSets, Services, Ingresses, PVCs, ... and can be taught custom health checks).

---

## Lab Environment

All commands of this chapter run on the **client VM** (`192.168.1.100`). It is in the cluster network, runs Docker
for the Git server, and has `kubectl` configured as described in module 00. Check the prerequisites:

```bash
kubectl get nodes                                  # 3 nodes Ready
kubectl get gatewayclass nginx                     # NGINX Gateway Fabric (module 08)
kubectl get ipaddresspool -n metallb-system        # MetalLB pool 192.168.1.240-192.168.1.250
docker version --format '{{.Server.Version}}'
git --version
sudo apt-get install -y jq                         # JSON processor used by some commands below
```

### Git server: Gitea

[Gitea](https://about.gitea.com) is a lightweight self-hosted Git service (like a small GitHub). Run it in Docker
on the client VM; its data lives in the Docker volume `gitea-data`:

```bash
docker run -d --name gitea --restart unless-stopped \
  -p 3000:3000 -p 2222:22 \
  -v gitea-data:/data \
  -e GITEA__security__INSTALL_LOCK=true \
  -e GITEA__security__ALLOWED_HOST_LIST=private \
  -e GITEA__server__DOMAIN=192.168.1.100 \
  -e GITEA__server__ROOT_URL=http://192.168.1.100:3000/ \
  -e GITEA__server__SSH_PORT=2222 \
  -e GITEA__service__DISABLE_REGISTRATION=true \
  -e GITEA__webhook__SKIP_TLS_VERIFY=true \
  gitea/gitea:28.3.0

# wait until Gitea answers
until curl -sf http://192.168.1.100:3000/api/healthz >/dev/null; do sleep 2; done; echo "Gitea is up"
```

The `GITEA__<section>__<KEY>` variables are written to Gitea's `app.ini`:
`INSTALL_LOCK` skips the web installer, `ALLOWED_HOST_LIST=private` allows webhooks to private addresses
(the Argo CD server will get a MetalLB IP), `SKIP_TLS_VERIFY` accepts Argo CD's self-signed certificate.

Create a user, a private repository and two access tokens - one with write access for you, one read-only for
Argo CD:

```bash
docker exec -u git gitea gitea admin user create --username gitops --password 'GitOps-2026!' \
  --email gitops@example.com --admin --must-change-password=false

GITEA=http://192.168.1.100:3000
curl -s -u 'gitops:GitOps-2026!' -X POST $GITEA/api/v1/user/repos -H 'Content-Type: application/json' \
  -d '{"name":"gitops-demo","private":true,"default_branch":"main"}' | jq -r .clone_url

GIT_TOKEN=$(curl -s -u 'gitops:GitOps-2026!' -X POST $GITEA/api/v1/users/gitops/tokens \
  -H 'Content-Type: application/json' \
  -d '{"name":"student","scopes":["write:repository"]}' | jq -r .sha1)
ARGOCD_GIT_TOKEN=$(curl -s -u 'gitops:GitOps-2026!' -X POST $GITEA/api/v1/users/gitops/tokens \
  -H 'Content-Type: application/json' \
  -d '{"name":"argocd","scopes":["read:repository"]}' | jq -r .sha1)
echo "GIT_TOKEN=$GIT_TOKEN ARGOCD_GIT_TOKEN=$ARGOCD_GIT_TOKEN" > ~/gitops-tokens.env   # keep them for later shells
```

Expected:

```
http://192.168.1.100:3000/gitops/gitops-demo.git
```

Clone the (still empty) repository - the token in the URL authenticates `git push`:

```bash
cd ~
git clone http://gitops:$GIT_TOKEN@192.168.1.100:3000/gitops/gitops-demo.git
cd gitops-demo
git config user.name "GitOps Student"
git config user.email "student@example.com"
git checkout -b main
```

The web UI is at `http://192.168.1.100:3000` (user `gitops`); from outside the cluster network use an SSH tunnel,
e.g. `ssh -L 3000:192.168.1.100:3000 <jump-host>`.

---

## Installing Argo CD

Install a pinned release from the official manifests. `--server-side` is required: the CRDs are too large for the
`last-applied-configuration` annotation of a client-side apply.

```bash
kubectl create namespace argocd
kubectl apply -n argocd --server-side --force-conflicts \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/v3.6.1/manifests/install.yaml

kubectl -n argocd rollout status deploy/argocd-server --timeout=5m
kubectl -n argocd rollout status statefulset/argocd-application-controller --timeout=5m
kubectl -n argocd get pods
kubectl get crd | grep argoproj.io
```

Expected (trimmed):

```
NAME                                                READY   STATUS    RESTARTS   AGE
argocd-application-controller-0                     1/1     Running   0          48s
argocd-applicationset-controller-794bb95c9d-km2ts   1/1     Running   0          49s
argocd-dex-server-66cf64bfcf-7fs4d                  1/1     Running   0          49s
argocd-notifications-controller-5878c8d644-n8tbt    1/1     Running   0          48s
argocd-redis-5869b7547-m9nl7                        1/1     Running   0          48s
argocd-repo-server-7d55cc466b-8cd6k                 1/1     Running   0          48s
argocd-server-85b849c688-jpmdb                      1/1     Running   0          48s
applications.argoproj.io      ...
applicationsets.argoproj.io   ...
appprojects.argoproj.io       ...
```

> Production installations usually use the Helm chart `argo/argo-cd` (values for HA, ingress/Gateway, SSO) or the
> HA manifests (`manifests/ha/install.yaml`). Argo CD can - and often does - manage its own installation via GitOps.

Expose the API/UI with a MetalLB address and log in with the CLI. The initial `admin` password is generated into
a Secret:

```bash
kubectl -n argocd patch svc argocd-server -p '{"spec":{"type":"LoadBalancer"}}'
kubectl -n argocd get svc argocd-server
ARGOCD_IP=$(kubectl -n argocd get svc argocd-server -o jsonpath='{.status.loadBalancer.ingress[0].ip}'); echo $ARGOCD_IP

# CLI
curl -sSL -o argocd https://github.com/argoproj/argo-cd/releases/download/v3.6.1/argocd-linux-amd64
sudo install -m 0755 argocd /usr/local/bin/argocd && rm argocd
argocd version --client --short

ARGOCD_PASSWORD=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)
argocd login $ARGOCD_IP --username admin --password "$ARGOCD_PASSWORD" --insecure   # self-signed certificate
argocd version --short
argocd cluster list
```

Expected:

```
'admin:login' logged in successfully
Context '192.168.1.24x' updated
argocd: v3.6.1+94037c4
argocd-server: v3.6.1
SERVER                          NAME        VERSION  STATUS   MESSAGE                                                  PROJECT
https://kubernetes.default.svc  in-cluster  1.37.1   Unknown  Cluster has no applications and is not being monitored.
```

`in-cluster` is the cluster Argo CD runs in; more clusters can be added with `argocd cluster add <kube-context>`.
The UI is at `https://<ARGOCD_IP>` (user `admin`, the password above). Change the password and delete the bootstrap
Secret afterwards in a real installation (`argocd account update-password`,
`kubectl -n argocd delete secret argocd-initial-admin-secret`).

---

## Workshop: The First Application

### Put the manifests into Git

```bash
cd ~/gitops-demo
mkdir -p apps/podinfo
```

```yaml
# apps/podinfo/deployment.yaml
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
        env:
        - name: PODINFO_UI_MESSAGE
          value: "Deployed by Argo CD"
        readinessProbe:
          httpGet:
            path: /readyz
            port: http
        livenessProbe:
          httpGet:
            path: /healthz
            port: http
        resources:
          requests:
            cpu: 10m
            memory: 32Mi
          limits:
            cpu: 200m
            memory: 128Mi
```

```yaml
# apps/podinfo/service.yaml
apiVersion: v1
kind: Service
metadata:
  name: podinfo
spec:
  selector:
    app: podinfo
  ports:
  - name: http
    port: 9898
    targetPort: http
```

```bash
git add apps/podinfo
git commit -m "podinfo: initial version"
git push -u origin main
```

### Register the repository

Argo CD needs read access to the private repository. Repository credentials are ordinary Secrets with the label
`argocd.argoproj.io/secret-type: repository` - so they can be managed declaratively, too:

```bash
source ~/gitops-tokens.env
kubectl apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: gitops-demo-repo
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: repository
stringData:
  type: git
  url: http://192.168.1.100:3000/gitops/gitops-demo.git
  username: gitops
  password: $ARGOCD_GIT_TOKEN
EOF

argocd repo list
```

Expected:

```
TYPE  NAME  REPO                                              INSECURE  OCI    LFS    CREDS  STATUS      MESSAGE  PROJECT
git         http://192.168.1.100:3000/gitops/gitops-demo.git  false     false  false  true   Successful
```

The CLI equivalent is `argocd repo add <url> --username gitops --password <token>`.

> Registering an **empty** repository reports `Failed ... remote repository is empty` - push the first commit first.

### Create the Application

The `Application` is also just YAML - keep it in Git as well (`argocd/podinfo.yaml`) and apply it once:

```yaml
# argocd/podinfo.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: podinfo
  namespace: argocd                     # Applications live in the Argo CD namespace
  finalizers:
  - resources-finalizer.argocd.argoproj.io   # deleting the Application deletes its resources, too
spec:
  project: default
  source:
    repoURL: http://192.168.1.100:3000/gitops/gitops-demo.git
    targetRevision: main                # branch, tag or commit SHA
    path: apps/podinfo                  # directory with plain manifests
  destination:
    server: https://kubernetes.default.svc
    namespace: podinfo
  syncPolicy:
    syncOptions:
    - CreateNamespace=true              # create the destination namespace if missing
```

```bash
mkdir -p argocd
# (create argocd/podinfo.yaml with the content above)
git add argocd && git commit -m "argocd: podinfo application" && git push

kubectl apply -f argocd/podinfo.yaml
argocd app get podinfo --refresh
```

Kubernetes 1.37 warns that `resources-finalizer.argocd.argoproj.io` is not a domain-qualified finalizer name
(`prefer a domain-qualified finalizer name including a path`). The warning is harmless - it is the finalizer name
Argo CD uses (foreground cascading deletion; `resources-finalizer.argocd.argoproj.io/background` selects background
deletion).

Expected (trimmed) - the app is known, but nothing is deployed yet (no automated sync):

```
Name:               argocd/podinfo
Project:            default
Server:             https://kubernetes.default.svc
Namespace:          podinfo
Repo:               http://192.168.1.100:3000/gitops/gitops-demo.git
Target:             main
Path:               apps/podinfo
Sync Policy:        Manual
Sync Status:        OutOfSync from main (1a2b3c4)
Health Status:      Missing

GROUP  KIND        NAMESPACE  NAME     STATUS     HEALTH   HOOK  MESSAGE
       Service     podinfo    podinfo  OutOfSync  Missing
apps   Deployment  podinfo    podinfo  OutOfSync  Missing
```

The CLI equivalent of the YAML is
`argocd app create podinfo --repo <url> --path apps/podinfo --dest-server https://kubernetes.default.svc --dest-namespace podinfo --sync-option CreateNamespace=true`.

### Sync, diff and history

```bash
argocd app diff podinfo            # what a sync would change (exit code 1 = there are differences)
argocd app sync podinfo
argocd app wait podinfo --health --timeout 180
argocd app get podinfo
kubectl -n podinfo get deploy,svc,pods
```

Expected (trimmed):

```
Sync Status:        Synced to main (1a2b3c4)
Health Status:      Healthy

GROUP  KIND        NAMESPACE  NAME     STATUS  HEALTH   HOOK  MESSAGE
       Service     podinfo    podinfo  Synced  Healthy        service/podinfo created
apps   Deployment  podinfo    podinfo  Synced  Healthy        deployment.apps/podinfo created
```

Test the application:

```bash
kubectl -n podinfo run curl --rm -i --restart=Never --image=curlimages/curl:8.23.0 -- -s http://podinfo:9898/ | grep message
```

Expected:

```
  "message": "Deployed by Argo CD",
```

Every object deployed by Argo CD carries a tracking annotation, which is how Argo CD knows which live objects
belong to which Application:

```bash
kubectl -n podinfo get deploy podinfo -o jsonpath='{.metadata.annotations.argocd\.argoproj\.io/tracking-id}{"\n"}'
```

Expected:

```
podinfo:apps/Deployment:podinfo/podinfo
```

### The GitOps workflow: change Git, not the cluster

Change the message and the number of replicas - in Git:

```bash
sed -i 's/replicas: 2/replicas: 3/; s/Deployed by Argo CD/Version 2 - deployed from Git/' apps/podinfo/deployment.yaml
git commit -am "podinfo: 3 replicas, new message"
git push

# Argo CD polls Git every 3 minutes; --refresh asks it to check now
argocd app get podinfo --refresh | grep -E 'Sync Status|Health Status'
argocd app diff podinfo
argocd app sync podinfo
argocd app wait podinfo --health --timeout 180
kubectl -n podinfo get deploy podinfo
```

Expected (trimmed):

```
Sync Status:        OutOfSync from main (5d6e7f8)
Health Status:      Healthy
...
===== apps/Deployment podinfo/podinfo ======
...
<   replicas: 2
---
>   replicas: 3
...
NAME      READY   UP-TO-DATE   AVAILABLE   AGE
podinfo   3/3     3            3           2m
```

Look at the deployment history and roll back to the first revision:

```bash
argocd app history podinfo
argocd app rollback podinfo 0       # ID from the first column of "history"
argocd app wait podinfo --health --timeout 180
kubectl -n podinfo get deploy podinfo
argocd app get podinfo | grep 'Sync Status'
```

Expected:

```
ID  DATE                           REVISION
0   2026-11-06 04:10:12 +0100 CET  main (1a2b3c4)
1   2026-11-06 04:13:40 +0100 CET  main (5d6e7f8)
...
podinfo   2/2     2            2           3m
Sync Status:        OutOfSync from main (5d6e7f8)
```

The cluster runs the old version, but the application is `OutOfSync`: Git still says 3 replicas. A rollback in
Argo CD is an emergency switch only (it is refused when automated sync is enabled). The GitOps way to roll back is
`git revert` - then Git and the cluster agree again:

```bash
git revert --no-edit HEAD
git push
argocd app get podinfo --refresh | grep 'Sync Status'
argocd app sync podinfo
argocd app wait podinfo --health --timeout 180
argocd app get podinfo | grep -E 'Sync Status|Health Status'
```

Expected:

```
Sync Status:        Synced to main (9a8b7c6)
Health Status:      Healthy
```

### Automated sync, self-healing and pruning

Turn on automated sync. `selfHeal` reverts changes made directly in the cluster, `prune` deletes objects that were
removed from Git (without it they are only reported as `OutOfSync`):

```bash
# edit argocd/podinfo.yaml - the syncPolicy becomes:
```

```yaml
# argocd/podinfo.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: podinfo
  namespace: argocd
  finalizers:
  - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: http://192.168.1.100:3000/gitops/gitops-demo.git
    targetRevision: main
    path: apps/podinfo
  destination:
    server: https://kubernetes.default.svc
    namespace: podinfo
  syncPolicy:
    automated:
      prune: true          # delete resources removed from Git
      selfHeal: true       # revert manual changes in the cluster
    syncOptions:
    - CreateNamespace=true
```

```bash
git commit -am "argocd: automated sync for podinfo" && git push
kubectl apply -f argocd/podinfo.yaml
argocd app get podinfo | grep 'Sync Policy'
```

**Self-heal** - somebody "fixes" production by hand:

```bash
kubectl -n podinfo scale deployment podinfo --replicas=5
kubectl -n podinfo set env deployment/podinfo PODINFO_UI_MESSAGE="hot fix"
sleep 15
kubectl -n podinfo get deploy podinfo
kubectl -n podinfo get deploy podinfo -o jsonpath='{.spec.template.spec.containers[0].env}{"\n"}'
```

Expected - both changes were reverted to the state in Git:

```
NAME      READY   UP-TO-DATE   AVAILABLE   AGE
podinfo   2/2     2            2           6m
[{"name":"PODINFO_UI_MESSAGE","value":"Deployed by Argo CD"}]
```

**Prune** - add a ConfigMap through Git, then delete it from Git:

```bash
kubectl create configmap feature-flags --from-literal=newCheckout=true --dry-run=client -o yaml \
  > apps/podinfo/feature-flags.yaml
git add apps/podinfo/feature-flags.yaml && git commit -m "podinfo: feature flags" && git push
argocd app get podinfo --refresh >/dev/null; sleep 10
kubectl -n podinfo get configmap feature-flags

git rm -q apps/podinfo/feature-flags.yaml && git commit -m "podinfo: remove feature flags" && git push
argocd app get podinfo --refresh >/dev/null; sleep 10
kubectl -n podinfo get configmap feature-flags
```

Expected:

```
NAME            DATA   AGE
feature-flags   1      8s
Error from server (NotFound): configmaps "feature-flags" not found
```

> Because the remove was pushed to Git, the history shows who deleted the ConfigMap and when - and a `git revert`
> brings it back.

Useful per-resource annotations:

| Annotation | Effect |
|------------|--------|
| `argocd.argoproj.io/sync-options: Prune=false` | never prune this resource (e.g. a PVC with data) |
| `argocd.argoproj.io/compare-options: IgnoreExtraneous` | do not mark the app OutOfSync because of this resource |
| `argocd.argoproj.io/sync-options: ServerSideApply=true` | apply this resource server-side |

Fields changed by other controllers (for example `spec.replicas` managed by an HPA) are excluded from the comparison
with `spec.ignoreDifferences` in the Application.

### Sync waves and hooks

A sync runs in **phases** (`PreSync` -> `Sync` -> `PostSync`, plus `SyncFail` on failure). Within a phase, resources
are applied in **waves** (annotation `argocd.argoproj.io/sync-wave`, lower first, default `0`); Argo CD waits until
a wave is healthy before it starts the next one. **Hooks** are resources - usually Jobs - that run in a phase and are
not part of the normal application state.

Typical use: run database migrations before the new version starts (`PreSync`), and a smoke test afterwards
(`PostSync`).

```yaml
# apps/podinfo/db-migrate.yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: db-migrate
  annotations:
    argocd.argoproj.io/hook: PreSync
    argocd.argoproj.io/hook-delete-policy: BeforeHookCreation   # keep the last run for inspection
spec:
  backoffLimit: 1
  template:
    spec:
      restartPolicy: Never
      containers:
      - name: migrate
        image: busybox:1.38
        command: ["sh", "-c", "echo 'applying schema migrations...'; sleep 5; echo 'schema version 42 applied'"]
```

```yaml
# apps/podinfo/config.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: podinfo-config
  annotations:
    argocd.argoproj.io/sync-wave: "-1"      # before the Deployment (wave 0)
data:
  PODINFO_UI_COLOR: "#2f855a"
```

```yaml
# apps/podinfo/smoke-test.yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: smoke-test
  annotations:
    argocd.argoproj.io/hook: PostSync
    argocd.argoproj.io/hook-delete-policy: HookSucceeded       # remove it when it passed
spec:
  backoffLimit: 2
  template:
    spec:
      restartPolicy: Never
      containers:
      - name: test
        image: curlimages/curl:8.23.0
        command: ["sh", "-c", "curl -sf http://podinfo:9898/readyz && echo SMOKE TEST PASSED"]
```

Make the Deployment read the ConfigMap - add `envFrom` to the container (below `env`):

```bash
sed -i 's/^        env:$/        envFrom:\n        - configMapRef:\n            name: podinfo-config\n        env:/' apps/podinfo/deployment.yaml
grep -A4 envFrom apps/podinfo/deployment.yaml

git add apps/podinfo && git commit -m "podinfo: config, migration and smoke test hooks" && git push
argocd app get podinfo --refresh >/dev/null
argocd app wait podinfo --operation --sync --health --timeout 300   # --operation: wait for the PostSync hook, too
argocd app get podinfo
```

Expected (trimmed) - hooks are listed with their phase:

```
GROUP  KIND        NAMESPACE  NAME            STATUS     HEALTH   HOOK      MESSAGE
batch  Job         podinfo    db-migrate      Succeeded  Synced   PreSync   Reached expected number of succeeded pods
       ConfigMap   podinfo    podinfo-config  Synced                        configmap/podinfo-config created
       Service     podinfo    podinfo         Synced     Healthy            service/podinfo unchanged
apps   Deployment  podinfo    podinfo         Synced     Healthy            deployment.apps/podinfo configured
batch  Job         podinfo    smoke-test      Succeeded  Synced   PostSync  Reached expected number of succeeded pods
```

```bash
kubectl -n podinfo logs job/db-migrate
kubectl -n podinfo get jobs                  # db-migrate kept, smoke-test deleted after success
kubectl -n podinfo get deploy podinfo -o jsonpath='{.spec.template.spec.containers[0].envFrom}{"\n"}'
```

Expected:

```
applying schema migrations...
schema version 42 applied
NAME         STATUS     COMPLETIONS   DURATION   AGE
db-migrate   Complete   1/1           8s         40s
[{"configMapRef":{"name":"podinfo-config"}}]
```

If a `PreSync` hook fails, the sync stops and the running version is not touched - a failed migration never
reaches the Deployment.


---

## Workshop: A Platform Repository - App of Apps, Helm, Kustomize and ApplicationSets

Applying every Application by hand does not scale. In the **App of Apps** pattern a single *root* Application points
to a directory that contains other `Application`, `ApplicationSet` and `AppProject` manifests - the only thing you
apply manually is the root. From then on, adding an application is a commit.

The repository gets this layout:

```
gitops-demo/
├── apps/podinfo/                     # the first application (already there)
├── argocd/
│   ├── podinfo.yaml                  # the first Application (already there)
│   ├── root.yaml                     # root Application -> argocd/platform/   (applied once by hand)
│   └── platform/                     # everything below is created by the root Application
│       ├── project-team-web.yaml     # AppProject: guard rails for the web team
│       ├── infra.yaml                # Application: shared Gateway
│       ├── webapp-helm.yaml          # Application: Helm chart from module 13
│       └── webapp-envs.yaml          # ApplicationSet: Kustomize overlays from module 13
└── platform/
    ├── infra/shared-gateway.yaml
    ├── charts/webapp-chart/          # copied from module 13
    ├── values/webapp-helm.yaml       # Helm values kept next to the chart
    └── kustomize-app/                # copied from module 13
```

Copy the chart and the Kustomize tree you built in module 13 (`webapp-chart/` and `kustomize-app/`; copy them to
the client VM with `scp` if you worked on another machine). Generated chart dependencies (`charts/*.tgz`) do not
belong in Git - Argo CD downloads them when it renders the chart:

```bash
cd ~/gitops-demo
mkdir -p platform/charts platform/infra platform/values argocd/platform
cp -r ~/webapp-chart platform/charts/
cp -r ~/kustomize-app platform/
rm -f platform/charts/webapp-chart/charts/*.tgz
ls platform/charts/webapp-chart platform/kustomize-app/overlays
```

### Shared infrastructure

The Kustomize overlays and the chart attach their HTTPRoutes to `shared-gateway`. Now the Gateway is managed by
Git as well:

```yaml
# platform/infra/shared-gateway.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: shared-gateway
---
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: shared-gateway
  namespace: shared-gateway
spec:
  gatewayClassName: nginx
  listeners:
  - name: http
    port: 80
    protocol: HTTP
    allowedRoutes:
      namespaces:
        from: All
```

```yaml
# argocd/platform/infra.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: infra
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "-1"        # before the applications that use the Gateway
  finalizers:
  - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: http://192.168.1.100:3000/gitops/gitops-demo.git
    targetRevision: main
    path: platform/infra
  destination:
    server: https://kubernetes.default.svc
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

### An AppProject for the web team

The `default` project allows everything. A dedicated project limits what the team's Applications may do - even if
somebody commits a manifest that tries more:

```yaml
# argocd/platform/project-team-web.yaml
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: team-web
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "-2"        # the project must exist before its Applications
  finalizers:
  - resources-finalizer.argocd.argoproj.io    # cannot be deleted while Applications use it
spec:
  description: Web team - the webapp in all environments
  sourceRepos:                                # only this repository
  - http://192.168.1.100:3000/gitops/gitops-demo.git
  destinations:                               # only these namespaces of the local cluster
  - server: https://kubernetes.default.svc
    namespace: development
  - server: https://kubernetes.default.svc
    namespace: staging
  - server: https://kubernetes.default.svc
    namespace: production
  - server: https://kubernetes.default.svc
    namespace: webapp-helm
  clusterResourceWhitelist:                   # cluster-scoped kinds allowed: only Namespaces (CreateNamespace)
  - group: ""
    kind: Namespace
  namespaceResourceBlacklist:                 # the team must not change its own quotas
  - group: ""
    kind: ResourceQuota
  - group: ""
    kind: LimitRange
  roles:
  - name: deployer                            # for CI pipelines: may read and sync, nothing else
    description: Sync access for the CI pipeline
    policies:
    - p, proj:team-web:deployer, applications, get, team-web/*, allow
    - p, proj:team-web:deployer, applications, sync, team-web/*, allow
```

### The Helm chart

The Application uses **two sources**: the chart, and the same repository once more as a `ref` so that a values file
stored in Git can be referenced as `$values/...`. Inline `valuesObject` values have the highest priority.

```yaml
# platform/values/webapp-helm.yaml
replicaCount: 2
fullnameOverride: webapp           # predictable object names instead of <release>-webapp-chart
global:
  environment: helm-demo
httpRoute:
  enabled: true
  hostnames:
  - webapp-helm.example.com
configMap:
  enabled: true
  data:
    app.properties: |
      feature.newCheckout=false
```

```yaml
# argocd/platform/webapp-helm.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: webapp-helm
  namespace: argocd
  finalizers:
  - resources-finalizer.argocd.argoproj.io
spec:
  project: team-web
  sources:
  - repoURL: http://192.168.1.100:3000/gitops/gitops-demo.git
    targetRevision: main
    path: platform/charts/webapp-chart
    helm:
      releaseName: webapp
      valueFiles:
      - $values/platform/values/webapp-helm.yaml
      valuesObject:
        env:
        - name: PODINFO_UI_MESSAGE
          value: "Helm chart deployed by Argo CD"
  - repoURL: http://192.168.1.100:3000/gitops/gitops-demo.git
    targetRevision: main
    ref: values                    # makes $values point to the root of this repository
  destination:
    server: https://kubernetes.default.svc
    namespace: webapp-helm
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
    - CreateNamespace=true
```

Argo CD renders the chart with `helm template` and applies the result itself - the release is **not** visible in
`helm list`, Helm hooks are mapped to Argo CD hooks, and `helm test` hooks are skipped.

### The Kustomize overlays: one ApplicationSet for all environments

Three overlays would need three almost identical Applications. An **ApplicationSet** generates them. The **Git
directory generator** creates one Application per directory that matches the pattern - a new overlay directory
automatically becomes a new Application:

```yaml
# argocd/platform/webapp-envs.yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: webapp-envs
  namespace: argocd
spec:
  goTemplate: true
  goTemplateOptions: ["missingkey=error"]
  generators:
  - git:
      repoURL: http://192.168.1.100:3000/gitops/gitops-demo.git
      revision: main
      directories:
      - path: platform/kustomize-app/overlays/*
  template:
    metadata:
      name: 'webapp-{{ .path.basename }}'          # webapp-development, webapp-staging, webapp-production
      labels:
        team: web
        env: '{{ .path.basename }}'
      finalizers:
      - resources-finalizer.argocd.argoproj.io
    spec:
      project: team-web
      source:
        repoURL: http://192.168.1.100:3000/gitops/gitops-demo.git
        targetRevision: main
        path: '{{ .path.path }}'
      destination:
        server: https://kubernetes.default.svc
        namespace: '{{ .path.basename }}'           # overlay name = namespace name
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
        syncOptions:
        - CreateNamespace=true
```

Other generators: `list` (fixed list of elements), `clusters` (one Application per registered cluster), `matrix` and
`merge` (combinations), `pullRequest` (preview environments per pull request), `scmProvider` (all repositories of an
organization).

### The root Application

```yaml
# argocd/root.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: platform
  namespace: argocd
  finalizers:
  - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: http://192.168.1.100:3000/gitops/gitops-demo.git
    targetRevision: main
    path: argocd/platform
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd               # Applications, ApplicationSets and AppProjects live here
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

Commit everything and apply only the root:

```bash
git add platform argocd
git commit -m "platform: gateway, team-web project, webapp via Helm and Kustomize"
git push

kubectl apply -f argocd/root.yaml
argocd app wait platform --sync --health --timeout 300
argocd app get platform
```

The root created the project, `infra`, `webapp-helm` and the ApplicationSet:

```
GROUP        KIND            NAMESPACE  NAME         STATUS  HEALTH   HOOK  MESSAGE
argoproj.io  AppProject      argocd     team-web     Synced                 appproject.argoproj.io/team-web created
argoproj.io  Application     argocd     infra        Synced                 application.argoproj.io/infra created
argoproj.io  ApplicationSet  argocd     webapp-envs  Synced  Healthy        applicationset.argoproj.io/webapp-envs created
argoproj.io  Application     argocd     webapp-helm  Synced                 application.argoproj.io/webapp-helm created
```

The ApplicationSet generated three more Applications. Wait for all of them:

```bash
for app in infra webapp-helm webapp-development webapp-staging webapp-production; do
  argocd app wait $app --sync --health --timeout 300 >/dev/null && echo "$app ready"
done
argocd app list
```

Expected:

```
NAME                       CLUSTER                         NAMESPACE       PROJECT   STATUS  HEALTH   SYNCPOLICY  ...
argocd/infra               https://kubernetes.default.svc                  default   Synced  Healthy  Auto-Prune  ...
argocd/platform            https://kubernetes.default.svc  argocd          default   Synced  Healthy  Auto-Prune  ...
argocd/podinfo             https://kubernetes.default.svc  podinfo         default   Synced  Healthy  Auto-Prune  ...
argocd/webapp-development  https://kubernetes.default.svc  development     team-web  Synced  Healthy  Auto-Prune  ...
argocd/webapp-helm         https://kubernetes.default.svc  webapp-helm     team-web  Synced  Healthy  Auto-Prune  ...
argocd/webapp-production   https://kubernetes.default.svc  production      team-web  Synced  Healthy  Auto-Prune  ...
argocd/webapp-staging      https://kubernetes.default.svc  staging         team-web  Synced  Healthy  Auto-Prune  ...
```

Check the result:

```bash
argocd appset list
kubectl get httproute -A
GW_IP=$(kubectl -n shared-gateway get gateway shared-gateway -o jsonpath='{.status.addresses[0].value}'); echo $GW_IP

curl -s -H 'Host: webapp-helm.example.com' http://$GW_IP/ | grep message
curl -s -H 'Host: staging.webapp.example.com' http://$GW_IP/health
curl -s -H 'Host: webapp.example.com' http://$GW_IP/health
kubectl -n webapp-helm get deploy,cm
```

Expected (trimmed):

```
NAMESPACE     NAME                 HOSTNAMES                        AGE
production    prod-webapp          ["webapp.example.com"]           1m
staging       staging-webapp       ["staging.webapp.example.com"]   1m
webapp-helm   webapp               ["webapp-helm.example.com"]      1m
...
  "message": "Helm chart deployed by Argo CD",
healthy
healthy
NAME                     READY   UP-TO-DATE   AVAILABLE   AGE
deployment.apps/webapp   2/2     2            2           1m
```

### Promoting a change through the environments

With one overlay per environment, a promotion is a commit to the next overlay. Roll out the NGINX patch version
`1.31.8` - which production already pins - to development and staging:

```bash
sed -i 's/newTag: 1.31-alpine/newTag: 1.31.8-alpine/' platform/kustomize-app/overlays/development/kustomization.yaml
cat >> platform/kustomize-app/overlays/staging/kustomization.yaml <<'EOF'

images:
- name: nginx
  newTag: 1.31.8-alpine
EOF
git commit -am "webapp: nginx 1.31.8 in development and staging" && git push

for env in development staging; do
  argocd app get webapp-$env --refresh >/dev/null
  argocd app wait webapp-$env --sync --health --timeout 300 >/dev/null
done
for ns in development staging production; do
  echo "$ns: $(kubectl -n $ns get deploy -o jsonpath='{.items[0].spec.template.spec.containers[?(@.name=="webapp")].image}')"
done
```

Expected:

```
development: nginx:1.31.8-alpine
staging: nginx:1.31.8-alpine
production: nginx:1.31.8-alpine
```

In real setups the CI pipeline makes these commits -
or Argo CD Image Updater writes a new tag to Git when a new image is pushed to the registry.

### Guard rails: what the AppProject prevents

Try to use the `team-web` project for a namespace it does not own:

```bash
argocd app create rogue --project team-web \
  --repo http://192.168.1.100:3000/gitops/gitops-demo.git --path apps/podinfo \
  --dest-server https://kubernetes.default.svc --dest-namespace kube-system
```

Expected:

```
... application destination server 'https://kubernetes.default.svc' and namespace 'kube-system' do not match any of the allowed destinations in project 'team-web'
```

The project role `deployer` gives a CI pipeline a token that can only read and sync the team's Applications:

```bash
CI_TOKEN=$(argocd proj role create-token team-web deployer --token-only)
argocd app sync webapp-staging --auth-token "$CI_TOKEN" >/dev/null && echo "sync allowed"
argocd app delete webapp-staging --auth-token "$CI_TOKEN" --yes
argocd app get podinfo --auth-token "$CI_TOKEN"
```

Expected:

```
sync allowed
... permission denied: applications, delete, team-web/webapp-staging ...
... permission denied ...
```

### Users and RBAC

Argo CD has its own users (local accounts or SSO via Dex/OIDC) and its own RBAC, configured in two ConfigMaps.
Create a local user `developer` who may see and sync the web team's Applications and read their logs - nothing
else:

```bash
ARGOCD_IP=$(kubectl -n argocd get svc argocd-server -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
ARGOCD_PASSWORD=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)

kubectl -n argocd patch configmap argocd-cm --type=merge -p '{"data":{"accounts.developer":"login"}}'
kubectl -n argocd patch configmap argocd-rbac-cm --type=merge -p '{"data":{"policy.csv":"p, role:web-developer, applications, get, team-web/*, allow\np, role:web-developer, applications, sync, team-web/*, allow\np, role:web-developer, logs, get, team-web/*, allow\np, role:web-developer, projects, get, team-web, allow\ng, developer, role:web-developer\n"}}'

argocd account list
argocd account update-password --account developer --new-password 'Developer-2026!' \
  --current-password "$ARGOCD_PASSWORD"

# check the policy without logging in (reads the ConfigMaps through kubectl)
argocd admin settings rbac can developer sync applications team-web/webapp-staging --namespace argocd
argocd admin settings rbac can developer delete applications team-web/webapp-staging --namespace argocd
argocd admin settings rbac can developer get applications default/podinfo --namespace argocd
```

Expected:

```
NAME       ENABLED  CAPABILITIES
admin      true     login
developer  true     login
Yes
No
No
```

Log in as the developer and look around - only the team's Applications are visible:

```bash
argocd login $ARGOCD_IP --username developer --password 'Developer-2026!' --insecure
argocd app list -o name
argocd app sync webapp-development >/dev/null && echo "sync allowed"
argocd app delete webapp-development --yes

# back to admin
argocd login $ARGOCD_IP --username admin --password "$ARGOCD_PASSWORD" --insecure
```

Expected:

```
argocd/webapp-development
argocd/webapp-helm
argocd/webapp-production
argocd/webapp-staging
sync allowed
... permission denied: applications, delete, team-web/webapp-development, sub: developer ...
```

`policy.default` in `argocd-rbac-cm` sets the role of authenticated users without a matching rule (empty = no access;
`role:readonly` is common). With SSO, `g, <group>, role:...` maps identity-provider groups to roles.

---

## Workshop: Instant Sync with a Webhook

Argo CD polls repositories every 3 minutes (`timeout.reconciliation` in `argocd-cm`). A webhook from the Git server
makes it react within seconds. Gitea's webhooks use the Gogs format, so the shared secret goes to
`webhook.gogs.secret`:

```bash
ARGOCD_IP=$(kubectl -n argocd get svc argocd-server -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
kubectl -n argocd patch secret argocd-secret --type=merge -p '{"stringData":{"webhook.gogs.secret":"webhook-s3cr3t"}}'

curl -s -u 'gitops:GitOps-2026!' -X POST http://192.168.1.100:3000/api/v1/repos/gitops/gitops-demo/hooks \
  -H 'Content-Type: application/json' \
  -d "{\"type\":\"gitea\",\"active\":true,\"events\":[\"push\"],\"config\":{\"url\":\"https://$ARGOCD_IP/api/webhook\",\"content_type\":\"json\",\"secret\":\"webhook-s3cr3t\"}}" \
  | jq -r '.type + " webhook " + (.id|tostring) + " created"'
```

Push a change and watch - no `--refresh` this time:

```bash
sed -i 's/replicas: 2/replicas: 3/' apps/podinfo/deployment.yaml
git commit -qam "podinfo: 3 replicas" && git push -q
sleep 30
kubectl -n podinfo get deploy podinfo
kubectl -n argocd logs deploy/argocd-server --since=2m | grep -E 'Received push event|refreshing app from webhook' | head -3
```

Expected (trimmed):

```
NAME      READY   UP-TO-DATE   AVAILABLE   AGE
podinfo   3/3     3            3           20m
{"level":"info","msg":"Received push event repo: http://192.168.1.100:3000/gitops/gitops-demo, revision: main, touchedHead: true",...}
{"application":"podinfo","level":"info","msg":"refreshing app from webhook",...}
```

(The sync itself takes ~20 s here because of the `PreSync` migration hook.) Webhooks are an optimization - keep
polling enabled as a fallback.

---

## Workshop: Secrets in Git with Sealed Secrets

A plain Secret must never be committed - base64 is not encryption. Common solutions:

| Tool | Idea |
|------|------|
| **Sealed Secrets** | encrypt with the cluster's public key, commit the `SealedSecret`; only the controller in the cluster can decrypt it |
| **External Secrets Operator** | commit only a reference; the operator copies the value from Vault, AWS/GCP/Azure secret managers, ... |
| **SOPS** (+ KSOPS / helm-secrets) | encrypt values in the files with age/PGP/KMS keys; decrypted while rendering |

Install the Sealed Secrets controller and the `kubeseal` CLI:

```bash
kubectl apply -f https://github.com/bitnami/sealed-secrets/releases/download/v0.41.2/controller.yaml
kubectl -n kube-system rollout status deploy/sealed-secrets-controller --timeout=3m

curl -sSL https://github.com/bitnami/sealed-secrets/releases/download/v0.41.2/kubeseal-0.41.2-linux-amd64.tar.gz \
  | tar xz kubeseal
sudo install -m 0755 kubeseal /usr/local/bin/kubeseal && rm kubeseal
kubeseal --version
```

Encrypt a Secret for the `podinfo` namespace - the plain Secret only exists in the pipe, never on disk:

```bash
kubectl create secret generic api-credentials -n podinfo \
  --from-literal=token='s3cr3t-t0ken' --dry-run=client -o yaml \
  | kubeseal --format yaml > apps/podinfo/api-credentials-sealed.yaml

grep -A3 encryptedData apps/podinfo/api-credentials-sealed.yaml
git add apps/podinfo/api-credentials-sealed.yaml && git commit -m "podinfo: sealed API credentials" && git push
sleep 30

kubectl -n podinfo get sealedsecret,secret api-credentials
kubectl -n podinfo get secret api-credentials -o jsonpath='{.data.token}' | base64 -d; echo
```

Expected:

```
  encryptedData:
    token: AgDETF0uCjl2fEoIyQum7DN0J1mq8KgVvTyOt...
NAME                                       AGE
sealedsecret.bitnami.com/api-credentials   20s

NAME                     TYPE     DATA   AGE
secret/api-credentials   Opaque   1      20s
s3cr3t-t0ken
```

The encryption is bound to the name and namespace (default scope `strict`): copying the SealedSecret to another
namespace does not reveal the value. Back up the controller's private key
(`kubectl -n kube-system get secret -l sealedsecrets.bitnami.com/sealed-secrets-key -o yaml`) - without it the
SealedSecrets in Git cannot be decrypted after a cluster rebuild.

---

## Best Practices

* **Separate repositories** for application source code and for deployment configuration (or at least separate
  directories with separate permissions); CI writes image tags to the configuration repository.
* **Protect the main branch** - changes through pull requests with review; Argo CD then deploys only what was reviewed.
* **Pin versions** - chart versions, image tags (or digests) and `targetRevision` for production (tag or commit)
  instead of a moving branch where needed.
* **Projects per team** with explicit source repositories and destinations; do not use the `default` project for teams.
* **Automated sync with self-heal** for everything that has an owner in Git; use `ignoreDifferences` for fields owned
  by other controllers (HPA replicas, injected sidecars).
* **No plain Secrets in Git** - Sealed Secrets, External Secrets or SOPS.
* **Let Argo CD manage itself** (its Helm chart or manifests in Git) and back up its namespace configuration.
* **Sync windows** (`AppProject.spec.syncWindows`) block automated syncs during business-critical hours.
* **Notifications** (`argocd-notifications-cm`) report failed syncs and degraded health to chat or e-mail.

## Troubleshooting

| Symptom | Where to look |
|---------|---------------|
| `ComparisonError`, `Unable to load data` | `argocd app get <app>` conditions; repo credentials (`argocd repo list`); `kubectl -n argocd logs deploy/argocd-repo-server` |
| Manifest generation fails (Helm/Kustomize) | render locally: `helm template` / `kubectl kustomize`; `argocd app manifests <app>` |
| Always `OutOfSync` | `argocd app diff <app>`; fields defaulted or mutated by the cluster -> `ignoreDifferences` or `ServerSideApply=true` |
| Sync hangs in `Running` | a hook or a resource never becomes healthy: `argocd app get <app>`, events of the resource |
| `Progressing` forever | Deployment rollout stuck (image pull, probes); Services of type LoadBalancer without an address |
| Application cannot be deleted | its finalizer waits for resources that cannot be deleted - check `kubectl -n argocd get app <app> -o yaml` |
| Permission denied | `argocd account can-i ...`, `argocd admin settings rbac can ...`, project `destinations`/`sourceRepos` |

```bash
argocd app get podinfo --show-operation
argocd app resources podinfo
argocd app logs podinfo --kind Deployment --name podinfo --tail 5
kubectl -n argocd get applications
kubectl -n argocd logs statefulset/argocd-application-controller --tail=20
```

---

## Clean up

Delete the root Application first: thanks to the finalizers it deletes the child Applications, the ApplicationSet
(and the Applications it generated) and all their Kubernetes resources:

```bash
argocd app delete platform --yes --wait
argocd app delete podinfo --yes --wait
kubectl get all -n staging                     # the Applications' resources are gone

# namespaces created by CreateNamespace=true are not managed resources - Argo CD leaves them
# (shared-gateway was a manifest in Git, so it was deleted)
kubectl delete namespace podinfo development staging production webapp-helm

kubectl delete -f https://github.com/bitnami/sealed-secrets/releases/download/v0.41.2/controller.yaml
kubectl delete -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/v3.6.1/manifests/install.yaml
kubectl delete namespace argocd

docker rm -f gitea && docker volume rm gitea-data
rm -rf ~/gitops-demo ~/gitops-tokens.env ~/.config/argocd
```
