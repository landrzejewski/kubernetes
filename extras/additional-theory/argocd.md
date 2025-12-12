# Tutorial: Argo CD - GitOps dla Kubernetes

## Spis treści
1. [Wprowadzenie do GitOps](#wprowadzenie-do-gitops)
2. [Czym jest Argo CD](#czym-jest-argo-cd)
3. [Instalacja Argo CD](#instalacja-argo-cd)
4. [Pierwsze kroki - UI i CLI](#pierwsze-kroki---ui-i-cli)
5. [Przykład 1: Deploy z Git (plain YAML)](#przykład-1-deploy-z-git-plain-yaml)
6. [Przykład 2: Deploy z Kustomize](#przykład-2-deploy-z-kustomize)
7. [Przykład 3: Deploy z Helm](#przykład-3-deploy-z-helm)
8. [Application resources](#application-resources)
9. [Sync strategies i policies](#sync-strategies-i-policies)
10. [Multi-environment setup](#multi-environment-setup)
11. [Zaawansowane funkcje](#zaawansowane-funkcje)
12. [Best Practices](#best-practices)

---

## Wprowadzenie do GitOps

### Czym jest GitOps?

**GitOps** to metodologia zarządzania infrastrukturą i aplikacjami, gdzie:
- **Git** jest single source of truth
- **Deklaratywne** opisy infrastruktury (YAML)
- **Automatyczna synchronizacja** między Git a klastrem
- **Pull-based** deployment (klaster pobiera zmiany z Git)

### Tradycyjny CD vs GitOps

```
=== Tradycyjny CI/CD ===
Developer → Git → CI → kubectl apply → Cluster
                        (push model)

=== GitOps ===
Developer → Git → Argo CD watches → Argo CD pulls → Cluster
                  (pull model)
```

### Korzyści GitOps:

✅ **Version control** - cała historia zmian w Git  
✅ **Audytowalność** - kto, co, kiedy zmienił  
✅ **Rollback** - łatwy powrót do poprzedniej wersji  
✅ **Disaster recovery** - klaster z Git w minuty  
✅ **Security** - brak credentials w CI/CD  
✅ **Developer experience** - git commit = deployment

---

## Czym jest Argo CD

**Argo CD** to declarative, GitOps continuous delivery tool dla Kubernetes.

### Kluczowe cechy:

- 🔄 Automatyczna synchronizacja z Git
- 🎯 Support dla Kustomize, Helm, plain YAML
- 🖥️ Web UI + CLI
- 🔐 RBAC i SSO
- 🔔 Notifications i webhooks
- 🏥 Health assessment aplikacji
- 🔙 Rollback jednym kliknięciem

### Architektura:

```
┌─────────────────────────────────────────────┐
│            Argo CD Architecture              │
├─────────────────────────────────────────────┤
│                                              │
│  ┌──────────┐         ┌──────────┐         │
│  │   Git    │────────▶│ Argo CD  │         │
│  │Repository│         │ Server   │         │
│  └──────────┘         └────┬─────┘         │
│                            │                │
│                            ▼                │
│                   ┌─────────────────┐      │
│                   │ Application     │      │
│                   │ Controller      │      │
│                   └────┬────────────┘      │
│                        │                   │
│                        ▼                   │
│                ┌───────────────┐          │
│                │  Kubernetes   │          │
│                │   Cluster     │          │
│                └───────────────┘          │
└─────────────────────────────────────────────┘
```

### Komponenty:

- **API Server** - Web UI i API
- **Repository Server** - zarządza połączeniami do Git
- **Application Controller** - monitoruje aplikacje i synchronizuje

---

## Instalacja Argo CD

### 1. Utwórz namespace

```bash
kubectl create namespace argocd
```

### 2. Instalacja Argo CD

```bash
# Instalacja stabilnej wersji
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# Sprawdź instalację
kubectl get pods -n argocd

# Poczekaj aż wszystkie pody będą ready
kubectl wait --for=condition=Ready pods --all -n argocd --timeout=300s
```

### 3. Dostęp do API Server

#### Opcja A: Port Forward (dla dev)

```bash
kubectl port-forward svc/argocd-server -n argocd 8080:443
# Otwórz: https://localhost:8080
```

#### Opcja B: NodePort (dla VirtualBox)

```bash
# Zmień Service na NodePort
kubectl patch svc argocd-server -n argocd -p '{"spec": {"type": "NodePort"}}'

# Sprawdź port
kubectl get svc argocd-server -n argocd
# Example output: 443:30443/TCP

# Dostęp przez: https://<MASTER_IP>:30443
```

#### Opcja C: LoadBalancer (dla chmury)

```bash
kubectl patch svc argocd-server -n argocd -p '{"spec": {"type": "LoadBalancer"}}'
```

### 4. Pobierz hasło admina

```bash
# Hasło jest w Secret
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d; echo

# Zapisz hasło, będzie potrzebne do logowania
```

### 5. Zaloguj się do Web UI

```
URL: https://localhost:8080 (lub https://<MASTER_IP>:30443)
Username: admin
Password: <hasło z poprzedniego kroku>
```

**WAŻNE**: Zaakceptuj self-signed certificate w przeglądarce!

### 6. Instalacja Argo CD CLI

```bash
# Na maszynie admin
curl -sSL -o argocd-linux-amd64 https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-amd64
sudo install -m 555 argocd-linux-amd64 /usr/local/bin/argocd
rm argocd-linux-amd64

# Weryfikacja
argocd version
```

### 7. Logowanie przez CLI

```bash
# Zaloguj się
argocd login localhost:8080 --insecure
# Username: admin
# Password: <hasło>

# Lub dla NodePort
argocd login <MASTER_IP>:30443 --insecure

# Zmień hasło (zalecane!)
argocd account update-password
```

---

## Pierwsze kroki - UI i CLI

### Web UI - Podstawowe elementy

Po zalogowaniu zobaczysz:

1. **Applications** - lista aplikacji
2. **Settings** - konfiguracja (Repositories, Clusters, Projects)
3. **User Info** - informacje o użytkowniku

### Dodanie repozytorium Git

#### Przez UI:

```
Settings → Repositories → Connect Repo
- Method: HTTPS
- Type: git
- Repository URL: https://github.com/your-org/your-repo
- Username: (opcjonalnie)
- Password/Token: (opcjonalnie dla private repo)
```

#### Przez CLI:

```bash
# Public repo
argocd repo add https://github.com/argoproj/argocd-example-apps.git

# Private repo (HTTPS)
argocd repo add https://github.com/your-org/your-repo.git \
  --username <username> \
  --password <token>

# Private repo (SSH)
argocd repo add git@github.com:your-org/your-repo.git \
  --ssh-private-key-path ~/.ssh/id_rsa

# Lista repozytoriów
argocd repo list
```

---

## Przykład 1: Deploy z Git (plain YAML)

### Scenariusz: Deploy prostej aplikacji nginx z publicznego repo

### 1. Przygotuj strukturę w Git

Struktura repo (możesz użyć example repo):
```
argocd-demo/
├── guestbook/
│   ├── guestbook-ui-deployment.yaml
│   ├── guestbook-ui-svc.yaml
│   └── README.md
```

Lub użyj oficjalnego example repo:
```
https://github.com/argoproj/argocd-example-apps.git
```

### 2. Utwórz aplikację przez UI

```
Applications → New App

General:
- Application Name: guestbook
- Project: default
- Sync Policy: Manual

Source:
- Repository URL: https://github.com/argoproj/argocd-example-apps.git
- Revision: HEAD
- Path: guestbook

Destination:
- Cluster URL: https://kubernetes.default.svc
- Namespace: default

→ Create
```

### 3. Lub przez CLI

```bash
argocd app create guestbook \
  --repo https://github.com/argoproj/argocd-example-apps.git \
  --path guestbook \
  --dest-server https://kubernetes.default.svc \
  --dest-namespace default

# Zobacz status
argocd app get guestbook

# Lista aplikacji
argocd app list
```

### 4. Synchronizacja

#### Przez UI:
```
Applications → guestbook → Sync → Synchronize
```

#### Przez CLI:
```bash
argocd app sync guestbook

# Watch status
argocd app wait guestbook
```

### 5. Sprawdź deployment

```bash
kubectl get all -n default -l app=guestbook

# Zobacz w UI
# Applications → guestbook → (piękna wizualizacja!)
```

### 6. Cleanup

```bash
# Delete app (zostaw zasoby w klastrze)
argocd app delete guestbook --cascade=false

# Delete app i zasoby
argocd app delete guestbook
```

---

## Przykład 2: Deploy z Kustomize

### Scenariusz: Multi-environment app z Kustomize

### 1. Struktura Git repo

```
myapp-kustomize/
├── base/
│   ├── deployment.yaml
│   ├── service.yaml
│   └── kustomization.yaml
└── overlays/
    ├── dev/
    │   └── kustomization.yaml
    ├── staging/
    │   └── kustomization.yaml
    └── prod/
        └── kustomization.yaml
```

### 2. Przykładowe pliki

`base/deployment.yaml`:
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: myapp
spec:
  replicas: 1
  selector:
    matchLabels:
      app: myapp
  template:
    metadata:
      labels:
        app: myapp
    spec:
      containers:
      - name: myapp
        image: nginx:alpine
        ports:
        - containerPort: 80
```

`base/service.yaml`:
```yaml
apiVersion: v1
kind: Service
metadata:
  name: myapp
spec:
  type: ClusterIP
  ports:
  - port: 80
    targetPort: 80
  selector:
    app: myapp
```

`base/kustomization.yaml`:
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - deployment.yaml
  - service.yaml
```

`overlays/dev/kustomization.yaml`:
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

bases:
  - ../../base

namespace: development

namePrefix: dev-

replicas:
  - name: myapp
    count: 1
```

`overlays/prod/kustomization.yaml`:
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

bases:
  - ../../base

namespace: production

namePrefix: prod-

replicas:
  - name: myapp
    count: 3
```

### 3. Commit do Git

```bash
git add .
git commit -m "Add kustomize structure"
git push
```

### 4. Utwórz aplikacje w Argo CD

```bash
# DEV environment
argocd app create myapp-dev \
  --repo https://github.com/your-org/myapp-kustomize.git \
  --path overlays/dev \
  --dest-server https://kubernetes.default.svc \
  --dest-namespace development \
  --sync-policy automated

# PROD environment
argocd app create myapp-prod \
  --repo https://github.com/your-org/myapp-kustomize.git \
  --path overlays/prod \
  --dest-server https://kubernetes.default.svc \
  --dest-namespace production \
  --sync-policy automated
```

### 5. Automatyczna synchronizacja

Przy `--sync-policy automated` Argo CD:
- Automatycznie wykrywa zmiany w Git
- Synchronizuje klaster z Git
- Można dodać self-healing i pruning

### 6. Test workflow

```bash
# 1. Zmień replicas w Git dla prod
# overlays/prod/kustomization.yaml
replicas:
  - name: myapp
    count: 5

# 2. Commit i push
git commit -am "Scale prod to 5 replicas"
git push

# 3. Argo CD automatycznie zsynchronizuje!
argocd app wait myapp-prod

# 4. Sprawdź
kubectl get deployment -n production
```

---

## Przykład 3: Deploy z Helm

### Scenariusz: Deploy aplikacji z Helm Chart

### 1. Struktura Git repo

```
myapp-helm/
├── Chart.yaml
├── values.yaml
├── values-dev.yaml
├── values-prod.yaml
└── templates/
    ├── deployment.yaml
    └── service.yaml
```

### 2. Przykładowe pliki

`Chart.yaml`:
```yaml
apiVersion: v2
name: myapp
description: My Application
type: application
version: 1.0.0
appVersion: "1.0.0"
```

`values.yaml`:
```yaml
replicaCount: 1

image:
  repository: nginx
  tag: alpine
  pullPolicy: IfNotPresent

service:
  type: ClusterIP
  port: 80

resources:
  limits:
    cpu: 100m
    memory: 128Mi
  requests:
    cpu: 100m
    memory: 128Mi
```

`values-prod.yaml`:
```yaml
replicaCount: 3

image:
  tag: 1.26-alpine

service:
  type: LoadBalancer

resources:
  limits:
    cpu: 500m
    memory: 512Mi
  requests:
    cpu: 250m
    memory: 256Mi
```

### 3. Commit do Git

```bash
git add .
git commit -m "Add Helm chart"
git push
```

### 4. Deploy z Helm przez Argo CD

```bash
# DEV (default values.yaml)
argocd app create myapp-helm-dev \
  --repo https://github.com/your-org/myapp-helm.git \
  --path . \
  --dest-server https://kubernetes.default.svc \
  --dest-namespace development \
  --helm-set replicaCount=1

# PROD (z values-prod.yaml)
argocd app create myapp-helm-prod \
  --repo https://github.com/your-org/myapp-helm.git \
  --path . \
  --dest-server https://kubernetes.default.svc \
  --dest-namespace production \
  --values values-prod.yaml
```

### 5. Deploy z publicznego Helm repo

```bash
# Dodaj Helm repo do Argo CD
argocd repo add https://charts.bitnami.com/bitnami \
  --type helm \
  --name bitnami

# Deploy WordPress z Helm repo
argocd app create wordpress \
  --repo https://charts.bitnami.com/bitnami \
  --helm-chart wordpress \
  --revision 15.2.0 \
  --dest-server https://kubernetes.default.svc \
  --dest-namespace wordpress \
  --helm-set service.type=NodePort
```

---

## Application resources

### Application CRD

Aplikacje Argo CD to custom resources w Kubernetes:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: myapp
  namespace: argocd
spec:
  # Project
  project: default
  
  # Source (Git)
  source:
    repoURL: https://github.com/your-org/myapp.git
    targetRevision: HEAD
    path: k8s/overlays/prod
    
    # Dla Kustomize
    kustomize:
      namePrefix: prod-
      commonLabels:
        environment: production
    
    # Dla Helm
    # helm:
    #   valueFiles:
    #     - values-prod.yaml
    #   parameters:
    #     - name: replicaCount
    #       value: "3"
  
  # Destination (Cluster)
  destination:
    server: https://kubernetes.default.svc
    namespace: production
  
  # Sync policy
  syncPolicy:
    automated:
      prune: true        # Usuń zasoby nie w Git
      selfHeal: true     # Auto-sync przy drift
      allowEmpty: false
    syncOptions:
      - CreateNamespace=true
    retry:
      limit: 5
      backoff:
        duration: 5s
        factor: 2
        maxDuration: 3m
```

### Zastosowanie przez kubectl

```bash
# Zapisz jako myapp.yaml
kubectl apply -f myapp.yaml -n argocd

# Zobacz aplikacje jako CRD
kubectl get applications -n argocd

# Szczegóły
kubectl describe application myapp -n argocd
```

---

## Sync strategies i policies

### Manual Sync

```bash
# Manual sync (default)
argocd app create myapp --sync-policy manual

# Trigger sync
argocd app sync myapp
```

### Automated Sync

```bash
# Auto sync
argocd app create myapp --sync-policy automated

# Auto sync + prune + self-heal
argocd app set myapp \
  --sync-policy automated \
  --auto-prune \
  --self-heal
```

### Sync Options

```yaml
syncPolicy:
  syncOptions:
    - CreateNamespace=true    # Utwórz namespace jeśli nie istnieje
    - PruneLast=true          # Usuń zasoby na końcu
    - RespectIgnoreDifferences=true
    - ServerSideApply=true
    - Validate=false          # Wyłącz walidację
```

### Sync Phases

```yaml
metadata:
  annotations:
    argocd.argoproj.io/sync-wave: "1"  # Kolejność sync (niższe pierwsze)
```

Przykład:
```yaml
# 1. Najpierw namespace (wave: 0)
apiVersion: v1
kind: Namespace
metadata:
  name: myapp
  annotations:
    argocd.argoproj.io/sync-wave: "0"

---
# 2. Potem secrets (wave: 1)
apiVersion: v1
kind: Secret
metadata:
  name: db-creds
  annotations:
    argocd.argoproj.io/sync-wave: "1"

---
# 3. Na końcu deployment (wave: 2)
apiVersion: apps/v1
kind: Deployment
metadata:
  name: myapp
  annotations:
    argocd.argoproj.io/sync-wave: "2"
```

### Resource Hooks

```yaml
metadata:
  annotations:
    argocd.argoproj.io/hook: PreSync        # Przed sync
    argocd.argoproj.io/hook: Sync           # Podczas sync
    argocd.argoproj.io/hook: PostSync       # Po sync
    argocd.argoproj.io/hook: SyncFail       # Gdy sync fail
    argocd.argoproj.io/hook-delete-policy: HookSucceeded  # Usuń po sukcesie
```

Przykład - DB migration job:
```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: db-migration
  annotations:
    argocd.argoproj.io/hook: PreSync
    argocd.argoproj.io/hook-delete-policy: HookSucceeded
spec:
  template:
    spec:
      containers:
      - name: migrate
        image: myapp/migrations:latest
        command: ["./migrate.sh"]
      restartPolicy: Never
```

---

## Multi-environment setup

### App of Apps pattern

Zarządzaj wieloma aplikacjami przez jedną "główną" aplikację:

```
apps/
├── app-of-apps.yaml      # Główna aplikacja
└── applications/
    ├── myapp-dev.yaml
    ├── myapp-staging.yaml
    ├── myapp-prod.yaml
    ├── monitoring.yaml
    └── logging.yaml
```

`app-of-apps.yaml`:
```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: app-of-apps
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/your-org/argocd-apps.git
    targetRevision: HEAD
    path: applications
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

`applications/myapp-dev.yaml`:
```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: myapp-dev
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/your-org/myapp.git
    targetRevision: develop
    path: k8s/overlays/dev
  destination:
    server: https://kubernetes.default.svc
    namespace: development
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

Deploy:
```bash
# Deploy tylko app-of-apps
argocd app create app-of-apps \
  --repo https://github.com/your-org/argocd-apps.git \
  --path applications \
  --dest-server https://kubernetes.default.svc \
  --dest-namespace argocd

argocd app sync app-of-apps
# Wszystkie child apps zostaną automatycznie utworzone!
```

### ApplicationSet

Bardziej zaawansowana metoda dla wielu aplikacji:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: myapp-all-envs
  namespace: argocd
spec:
  generators:
  - list:
      elements:
      - env: dev
        namespace: development
        replicas: "1"
      - env: staging
        namespace: staging
        replicas: "2"
      - env: prod
        namespace: production
        replicas: "3"
  template:
    metadata:
      name: 'myapp-{{env}}'
    spec:
      project: default
      source:
        repoURL: https://github.com/your-org/myapp.git
        targetRevision: HEAD
        path: k8s/overlays/{{env}}
      destination:
        server: https://kubernetes.default.svc
        namespace: '{{namespace}}'
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
```

---

## Zaawansowane funkcje

### 1. Projects - RBAC i izolacja

```yaml
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: team-alpha
  namespace: argocd
spec:
  description: Team Alpha Project
  
  # Dozwolone source repos
  sourceRepos:
  - 'https://github.com/team-alpha/*'
  
  # Dozwolone destinations
  destinations:
  - namespace: 'team-alpha-*'
    server: https://kubernetes.default.svc
  
  # Dozwolone resource types
  clusterResourceWhitelist:
  - group: ''
    kind: Namespace
  namespaceResourceWhitelist:
  - group: 'apps'
    kind: Deployment
  - group: ''
    kind: Service
  
  # Deny specific resources
  namespaceResourceBlacklist:
  - group: ''
    kind: ResourceQuota
```

Użycie:
```bash
argocd app create myapp \
  --project team-alpha \
  --repo https://github.com/team-alpha/myapp.git \
  ...
```

### 2. Diff customization

Ignoruj różnice w określonych polach:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: myapp
  annotations:
    argocd.argoproj.io/compare-options: IgnoreExtraneous
    # Ignoruj różnice w tych ścieżkach
spec:
  # ...
```

Lub globalnie:
```yaml
# argocd-cm ConfigMap
data:
  resource.customizations: |
    admissionregistration.k8s.io/MutatingWebhookConfiguration:
      ignoreDifferences: |
        jsonPointers:
        - /webhooks/0/clientConfig/caBundle
```

### 3. Health assessment custom

```yaml
# argocd-cm ConfigMap
data:
  resource.customizations: |
    argoproj.io/Rollout:
      health.lua: |
        hs = {}
        if obj.status ~= nil then
          if obj.status.phase == "Healthy" then
            hs.status = "Healthy"
            hs.message = "Rollout is healthy"
            return hs
          end
        end
        hs.status = "Progressing"
        hs.message = "Waiting for rollout"
        return hs
```

### 4. Notifications

Konfiguracja notyfikacji (Slack, email, etc.):

```bash
# Zainstaluj Argo CD Notifications
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj-labs/argocd-notifications/stable/manifests/install.yaml

# Konfiguracja Slack
kubectl patch cm argocd-notifications-cm -n argocd --type merge -p '{
  "data": {
    "service.slack": "token: $slack-token\n",
    "template.app-deployed": "message: Application {{.app.metadata.name}} is now running.\n",
    "trigger.on-deployed": "- when: app.status.operationState.phase in ['Succeeded']\n  send: [app-deployed]\n"
  }
}'
```

### 5. Web Terminal

```bash
# Enable web terminal
kubectl patch cm argocd-cm -n argocd --type merge -p '{
  "data": {
    "exec.enabled": "true"
  }
}'

# W UI: Application → terminal icon
```

### 6. Progressive Delivery (Rollouts)

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Rollout
metadata:
  name: myapp
spec:
  replicas: 5
  strategy:
    canary:
      steps:
      - setWeight: 20
      - pause: {duration: 1m}
      - setWeight: 40
      - pause: {duration: 1m}
      - setWeight: 60
      - pause: {duration: 1m}
      - setWeight: 80
      - pause: {duration: 1m}
  template:
    spec:
      containers:
      - name: myapp
        image: myapp:v2
```

---

## Best Practices

### ✅ Dobre praktyki:

#### 1. **Struktura Git repo**

```
# Monorepo
company-apps/
├── apps/
│   ├── myapp1/
│   ├── myapp2/
│   └── myapp3/
└── argocd/
    └── applications/

# Lub separate repos per app
myapp/
├── src/              # Application code
├── k8s/              # Kubernetes manifests
│   ├── base/
│   └── overlays/
└── .gitlab-ci.yml
```

#### 2. **Używaj branches dla środowisk**

```
main → production
develop → staging
feature/* → dev
```

Lub:
```
main → wszystkie środowiska
overlays/dev → dev
overlays/prod → prod
```

#### 3. **Automated sync z ostrożnością**

```yaml
# ✅ DOBRZE dla dev/staging
syncPolicy:
  automated:
    prune: true
    selfHeal: true

# ⚠️ OSTROŻNIE dla prod
syncPolicy:
  automated:
    prune: false      # Manual prune
    selfHeal: false   # Manual healing
```

#### 4. **Używaj sync waves**

```yaml
# Kolejność: namespace → secrets → configs → apps
metadata:
  annotations:
    argocd.argoproj.io/sync-wave: "0"  # Najpierw
```

#### 5. **Health checks**

Zawsze definiuj:
```yaml
spec:
  template:
    spec:
      containers:
      - name: myapp
        livenessProbe:
          httpGet:
            path: /health
            port: 8080
        readinessProbe:
          httpGet:
            path: /ready
            port: 8080
```

#### 6. **Resource quotas per project**

```yaml
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: team-alpha
spec:
  # Limit resources
  namespaceResourceWhitelist:
  - group: ''
    kind: Pod
  clusterResourceWhitelist: []
```

#### 7. **Backup aplikacji**

```bash
# Export wszystkich aplikacji
argocd app list -o yaml > apps-backup.yaml

# Export projektu
argocd proj get default -o yaml > project-backup.yaml
```

#### 8. **Monitoruj Argo CD**

```bash
# Logi
kubectl logs -n argocd -l app.kubernetes.io/name=argocd-server

# Metrics
kubectl port-forward -n argocd svc/argocd-metrics 8082:8082
# Prometheus metrics: http://localhost:8082/metrics
```

### ❌ Czego unikać:

1. **Hardcoded secrets w Git** - używaj Sealed Secrets lub External Secrets
2. **Brak resource limits** - zawsze definiuj limits
3. **Auto-prune na prod bez testów** - może usunąć ważne zasoby
4. **Single branch dla wszystkich środowisk** - trudne rollbacki
5. **Brak health checks** - Argo nie wie czy app działa
6. **Za duże aplikacje** - lepiej podzielić na mniejsze
7. **Ignorowanie drift** - monitoruj OutOfSync status

---

## Monitoring i Debugging

### Status aplikacji

```bash
# Status aplikacji
argocd app get myapp

# Health status
argocd app get myapp --output json | jq '.status.health'

# Sync status
argocd app get myapp --output json | jq '.status.sync'

# Lista zasobów
argocd app resources myapp
```

### Logs

```bash
# Logi sync
argocd app logs myapp

# Logi konkretnego poda
argocd app logs myapp --kind Deployment --name myapp

# Follow logs
argocd app logs myapp --follow
```

### Diff

```bash
# Zobacz różnice między Git a klastrem
argocd app diff myapp

# Diff dla konkretnego zasobu
argocd app manifests myapp | kubectl diff -f -
```

### Troubleshooting

```bash
# Sprawdź sync errors
argocd app get myapp --output json | jq '.status.conditions'

# Force refresh z Git
argocd app get myapp --refresh

# Hard refresh (ignore cache)
argocd app get myapp --hard-refresh

# Terminate sync
argocd app terminate-op myapp
```

### Common issues

**Problem: App stuck in "Progressing"**
```bash
# Check events
kubectl get events -n <namespace> --sort-by='.lastTimestamp'

# Check pod status
kubectl describe pod <pod-name> -n <namespace>
```

**Problem: OutOfSync ale nic się nie zmieniło**
```bash
# Check ignoreDifferences
argocd app diff myapp

# Może być drift w klastrze - użyj self-heal
argocd app set myapp --self-heal
```

**Problem: Sync fails z permission error**
```bash
# Check project permissions
argocd proj get <project-name>

# Check RBAC
kubectl auth can-i create deployment --as=system:serviceaccount:argocd:argocd-application-controller
```

---

## Integracja z CI/CD

### GitLab CI

```yaml
# .gitlab-ci.yml
stages:
  - build
  - deploy

build:
  stage: build
  script:
    - docker build -t myapp:${CI_COMMIT_SHA} .
    - docker push myapp:${CI_COMMIT_SHA}

deploy:dev:
  stage: deploy
  script:
    # Update image in Git
    - git clone https://gitlab.com/your-org/k8s-manifests.git
    - cd k8s-manifests
    - yq -i '.images[0].newTag = "${CI_COMMIT_SHA}"' overlays/dev/kustomization.yaml
    - git commit -am "Update dev image to ${CI_COMMIT_SHA}"
    - git push
    # Argo CD auto-syncs!
  only:
    - develop

deploy:prod:
  stage: deploy
  script:
    # Trigger Argo CD sync via API
    - |
      curl -X POST \
        -H "Authorization: Bearer $ARGOCD_TOKEN" \
        -H "Content-Type: application/json" \
        https://argocd.example.com/api/v1/applications/myapp-prod/sync
  only:
    - main
  when: manual
```

### GitHub Actions

```yaml
# .github/workflows/deploy.yml
name: Deploy
on:
  push:
    branches: [main]

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v2
      
      - name: Update image tag
        run: |
          cd k8s/overlays/prod
          kustomize edit set image myapp=myapp:${{ github.sha }}
          
      - name: Commit changes
        run: |
          git config user.name "GitHub Actions"
          git config user.email "actions@github.com"
          git commit -am "Update prod image to ${{ github.sha }}"
          git push
```

### Image Updater

Argo CD Image Updater automatycznie aktualizuje tagi obrazów:

```bash
# Instalacja
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj-labs/argocd-image-updater/stable/manifests/install.yaml

# Konfiguracja w aplikacji
kubectl patch app myapp -n argocd --type merge -p '{
  "metadata": {
    "annotations": {
      "argocd-image-updater.argoproj.io/image-list": "myapp=myregistry/myapp",
      "argocd-image-updater.argoproj.io/myapp.update-strategy": "latest"
    }
  }
}'
```

---

## Praktyczne ćwiczenia

### Ćwiczenie 1: Podstawowy deployment

1. Stwórz Git repo z prostą aplikacją (nginx)
2. Dodaj repo do Argo CD
3. Utwórz aplikację
4. Zsynchronizuj
5. Zmień liczbę replik w Git
6. Obserwuj auto-sync

### Ćwiczenie 2: Multi-environment z Kustomize

1. Stwórz base + overlays (dev/prod)
2. Utwórz 2 aplikacje w Argo CD
3. Różne konfiguracje dla każdego środowiska
4. Test rollback

### Ćwiczenie 3: App of Apps

1. Stwórz app-of-apps pattern
2. Deploy 3 aplikacje przez jedną główną
3. Test cascade delete

### Ćwiczenie 4: Hooks i Waves

1. Dodaj PreSync hook (database migration)
2. Użyj sync waves dla kolejności
3. Test failed sync i rollback

---

## Podsumowanie

**Argo CD** to must-have dla GitOps workflow:

✅ **Korzyści:**
- Automatyzacja deployments
- Git jako source of truth
- Łatwe rollbacks
- Audytowalność
- Self-healing
- Multi-environment support

🎯 **Use cases:**
- Continuous Delivery
- Multi-environment management
- Multi-cluster deployments
- GitOps implementation
- Disaster recovery

📚 **Następne kroki:**
1. Zainstaluj Argo CD na swoim klastrze
2. Przećwicz przykłady
3. Zintegruj z CI/CD
4. Sprawdź Argo Rollouts dla progressive delivery
5. Rozważ Argo CD Notifications
6. Zobacz Argo Workflows dla CI

**Przydatne linki:**
- [Oficjalna dokumentacja](https://argo-cd.readthedocs.io/)
- [GitHub](https://github.com/argoproj/argo-cd)
- [Examples](https://github.com/argoproj/argocd-example-apps)
- [Best Practices](https://argo-cd.readthedocs.io/en/stable/user-guide/best_practices/)

Powodzenia z GitOps! 🚀