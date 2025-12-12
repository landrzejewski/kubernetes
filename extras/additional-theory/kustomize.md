# Tutorial: Kustomize - Zarządzanie konfiguracją Kubernetes

## Spis treści
1. [Wprowadzenie](#wprowadzenie)
2. [Instalacja i weryfikacja](#instalacja-i-weryfikacja)
3. [Podstawowe koncepty](#podstawowe-koncepty)
4. [Przykład 1: Podstawowa struktura](#przykład-1-podstawowa-struktura)
5. [Przykład 2: Overlays dla środowisk](#przykład-2-overlays-dla-środowisk)
6. [Przykład 3: Patches - modyfikacje](#przykład-3-patches---modyfikacje)
7. [Przykład 4: ConfigMap i Secret generators](#przykład-4-configmap-i-secret-generators)
8. [Przykład 5: Zaawansowane transformacje](#przykład-5-zaawansowane-transformacje)
9. [Kustomize vs Helm](#kustomize-vs-helm)
10. [Best Practices](#best-practices)

---

## Wprowadzenie

**Kustomize** to narzędzie do zarządzania konfiguracją Kubernetes, które:
- Nie używa szablonów (template-free)
- Operuje na czystych manifestach YAML
- Umożliwia nakładanie zmian (overlays) na bazową konfigurację
- Jest wbudowane w kubectl (od v1.14)

### Kluczowe różnice: Kustomize vs Helm

| Aspekt | Kustomize | Helm |
|--------|-----------|------|
| **Podejście** | Deklaratywne patches | Szablony Go |
| **Pliki bazowe** | Czyste YAML | Templates z {{ }} |
| **Zarządzanie wersjami** | Brak wbudowanego | Release management |
| **Złożoność** | Prostsze | Bardziej złożone |
| **Integracja** | Wbudowane w kubectl | Zewnętrzny tool |

### Kiedy używać Kustomize?

✅ **Używaj Kustomize gdy:**
- Chcesz prostego rozwiązania bez szablonów
- Masz czyste manifesty YAML do zarządzania
- Potrzebujesz różnych konfiguracji dla środowisk (dev/staging/prod)
- Wolisz deklaratywne podejście GitOps

❌ **Używaj Helm gdy:**
- Potrzebujesz complex templating logic
- Chcesz wersjonowania releases
- Potrzebujesz rollbacków
- Instalujesz aplikacje z publicznych repozytoriów

### Kluczowe koncepty:

- **Base** - bazowa konfiguracja (wspólna dla wszystkich środowisk)
- **Overlay** - nadpisania dla konkretnego środowiska
- **Patch** - modyfikacja istniejących zasobów
- **Generator** - tworzenie ConfigMap/Secret z plików
- **Transformer** - modyfikacje zasobów (labels, annotations, replicas, etc.)

---

## Instalacja i weryfikacja

### Kustomize jest wbudowany w kubectl!

```bash
# Sprawdź wersję kubectl
kubectl version --client

# Kustomize jest dostępny jako:
kubectl kustomize --help

# Lub jako standalone (opcjonalnie):
curl -s "https://raw.githubusercontent.com/kubernetes-sigs/kustomize/master/hack/install_kustomize.sh" | bash
sudo mv kustomize /usr/local/bin/
```

### Weryfikacja:

```bash
# Przez kubectl
kubectl kustomize --help

# Standalone (jeśli zainstalowany)
kustomize version
```

---

## Podstawowe koncepty

### Struktura katalogów

Typowa struktura projektu Kustomize:

```
myapp/
├── base/                    # Bazowa konfiguracja
│   ├── deployment.yaml
│   ├── service.yaml
│   └── kustomization.yaml   # Plik główny base
└── overlays/                # Nakładki dla środowisk
    ├── dev/
    │   ├── kustomization.yaml
    │   └── patches/
    ├── staging/
    │   ├── kustomization.yaml
    │   └── patches/
    └── prod/
        ├── kustomization.yaml
        └── patches/
```

### Plik kustomization.yaml

To główny plik konfiguracyjny Kustomize:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

# Zasoby bazowe
resources:
  - deployment.yaml
  - service.yaml

# Wspólne dla wszystkich zasobów
commonLabels:
  app: myapp
  
namePrefix: myapp-
namespace: default

# Generatory
configMapGenerator:
  - name: app-config
    files:
      - config.properties

# Patches
patchesStrategicMerge:
  - patch-deployment.yaml
```

---

## Przykład 1: Podstawowa struktura

### Scenariusz: Prosta aplikacja nginx

### 1. Utwórz strukturę katalogów

```bash
mkdir -p myapp/base
cd myapp
```

### 2. Utwórz bazowy Deployment

Zapisz jako `base/deployment.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx
spec:
  replicas: 1
  selector:
    matchLabels:
      app: nginx
  template:
    metadata:
      labels:
        app: nginx
    spec:
      containers:
      - name: nginx
        image: nginx:1.25
        ports:
        - containerPort: 80
        resources:
          requests:
            cpu: 100m
            memory: 128Mi
          limits:
            cpu: 200m
            memory: 256Mi
```

### 3. Utwórz bazowy Service

Zapisz jako `base/service.yaml`:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: nginx
spec:
  type: ClusterIP
  ports:
  - port: 80
    targetPort: 80
    protocol: TCP
  selector:
    app: nginx
```

### 4. Utwórz kustomization.yaml

Zapisz jako `base/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - deployment.yaml
  - service.yaml

commonLabels:
  app: nginx
  managed-by: kustomize

namePrefix: web-
```

### 5. Wygeneruj i zastosuj

```bash
# Zobacz wygenerowane manifesty (bez aplikowania)
kubectl kustomize base/

# Zastosuj bezpośrednio
kubectl apply -k base/

# Sprawdź zasoby
kubectl get all -l app=nginx
```

### Wynik:
- Deployment: `web-nginx`
- Service: `web-nginx`
- Wszystkie zasoby mają labele: `app: nginx`, `managed-by: kustomize`

---

## Przykład 2: Overlays dla środowisk

### Scenariusz: Różne konfiguracje dla dev, staging i prod

### 1. Utwórz strukturę overlays

```bash
mkdir -p myapp/overlays/{dev,staging,prod}
```

Struktura:
```
myapp/
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

### 2. Overlay DEV

Zapisz jako `overlays/dev/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

# Wskaż bazę
bases:
  - ../../base

# Namespace dla dev
namespace: development

# Suffix do nazw
nameSuffix: -dev

# Dodatkowe labele
commonLabels:
  environment: dev

# Zmień liczbę replik
replicas:
  - name: web-nginx
    count: 1

# Dodaj adnotacje
commonAnnotations:
  managed-by: kustomize
  environment: development
```

### 3. Overlay STAGING

Zapisz jako `overlays/staging/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

bases:
  - ../../base

namespace: staging

nameSuffix: -staging

commonLabels:
  environment: staging

replicas:
  - name: web-nginx
    count: 2

# Zmień obraz na nowszą wersję
images:
  - name: nginx
    newTag: 1.26-alpine
```

### 4. Overlay PROD

Zapisz jako `overlays/prod/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

bases:
  - ../../base

namespace: production

nameSuffix: -prod

commonLabels:
  environment: production

replicas:
  - name: web-nginx
    count: 3

images:
  - name: nginx
    newTag: 1.26-alpine

# Zmień typ Service na LoadBalancer
patchesJson6902:
  - target:
      group: ""
      version: v1
      kind: Service
      name: web-nginx
    patch: |-
      - op: replace
        path: /spec/type
        value: LoadBalancer
```

### 5. Deploy do różnych środowisk

```bash
# DEV
kubectl apply -k overlays/dev/
kubectl get all -n development

# STAGING
kubectl apply -k overlays/staging/
kubectl get all -n staging

# PROD
kubectl apply -k overlays/prod/
kubectl get all -n production
```

### Porównanie:

```bash
# Zobacz różnice między środowiskami
kubectl kustomize overlays/dev/ > dev.yaml
kubectl kustomize overlays/staging/ > staging.yaml
kubectl kustomize overlays/prod/ > prod.yaml

diff dev.yaml staging.yaml
```

---

## Przykład 3: Patches - modyfikacje

### Rodzaje patches w Kustomize:

1. **Strategic Merge Patch** - merge YAML
2. **JSON Patch (RFC 6902)** - precyzyjne operacje
3. **JSON Merge Patch (RFC 7386)** - uproszczony merge

### Przykład 1: Strategic Merge Patch

Zapisz jako `overlays/prod/increase-resources.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web-nginx
spec:
  template:
    spec:
      containers:
      - name: nginx
        resources:
          requests:
            cpu: 500m
            memory: 512Mi
          limits:
            cpu: 1000m
            memory: 1Gi
```

Dodaj do `overlays/prod/kustomization.yaml`:

```yaml
patchesStrategicMerge:
  - increase-resources.yaml
```

### Przykład 2: JSON Patch (6902)

Zapisz jako `overlays/prod/kustomization.yaml`:

```yaml
patchesJson6902:
  # Dodaj volume
  - target:
      group: apps
      version: v1
      kind: Deployment
      name: web-nginx
    patch: |-
      - op: add
        path: /spec/template/spec/volumes
        value:
          - name: config
            configMap:
              name: nginx-config
      
      # Dodaj volumeMount
      - op: add
        path: /spec/template/spec/containers/0/volumeMounts
        value:
          - name: config
            mountPath: /etc/nginx/conf.d
      
      # Zmień image pull policy
      - op: replace
        path: /spec/template/spec/containers/0/imagePullPolicy
        value: Always
```

### Przykład 3: Inline patches

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

bases:
  - ../../base

# Inline patch
patches:
  - target:
      kind: Deployment
      name: web-nginx
    patch: |-
      apiVersion: apps/v1
      kind: Deployment
      metadata:
        name: web-nginx
      spec:
        template:
          spec:
            containers:
            - name: nginx
              env:
              - name: ENVIRONMENT
                value: production
              - name: LOG_LEVEL
                value: info
```

### Test patches:

```bash
# Zobacz efekt
kubectl kustomize overlays/prod/

# Sprawdź konkretny zasób
kubectl kustomize overlays/prod/ | grep -A 20 "kind: Deployment"
```

---

## Przykład 4: ConfigMap i Secret generators

### ConfigMap Generator

### 1. Z literal values

Zapisz jako `overlays/dev/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

bases:
  - ../../base

configMapGenerator:
  - name: app-config
    literals:
      - DATABASE_URL=postgres://db.dev:5432/mydb
      - API_ENDPOINT=https://api.dev.example.com
      - LOG_LEVEL=debug
      - MAX_CONNECTIONS=10
```

### 2. Z plików

Utwórz plik konfiguracyjny `overlays/dev/config/app.properties`:

```properties
database.host=db.dev.example.com
database.port=5432
database.name=myapp_dev
api.timeout=30
api.retries=3
log.level=DEBUG
```

Zapisz jako `overlays/dev/kustomization.yaml`:

```yaml
configMapGenerator:
  - name: app-config
    files:
      - config/app.properties
      - config/logging.conf
```

### 3. Z plików .env

Utwórz `overlays/dev/config/.env`:

```env
DATABASE_URL=postgres://localhost:5432/dev
REDIS_URL=redis://localhost:6379
API_KEY=dev-api-key-123
DEBUG=true
```

```yaml
configMapGenerator:
  - name: app-env
    envs:
      - config/.env
```

### Secret Generator

### 1. Z literal values

```yaml
secretGenerator:
  - name: db-credentials
    literals:
      - username=admin
      - password=dev-password-123
    type: Opaque
```

### 2. Z plików

Utwórz `overlays/prod/secrets/db-password.txt`:
```
super-secure-password-prod
```

```yaml
secretGenerator:
  - name: db-credentials
    files:
      - username=secrets/db-username.txt
      - password=secrets/db-password.txt
```

### 3. Z certyfikatów TLS

```yaml
secretGenerator:
  - name: tls-cert
    files:
      - tls.crt=certs/server.crt
      - tls.key=certs/server.key
    type: kubernetes.io/tls
```

### Użycie w Deployment

Zapisz jako `overlays/dev/use-configmap-patch.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web-nginx
spec:
  template:
    spec:
      containers:
      - name: nginx
        envFrom:
        - configMapRef:
            name: app-config
        - secretRef:
            name: db-credentials
        volumeMounts:
        - name: config-volume
          mountPath: /app/config
      volumes:
      - name: config-volume
        configMap:
          name: app-config
```

Dodaj do kustomization.yaml:
```yaml
patchesStrategicMerge:
  - use-configmap-patch.yaml
```

### Ważna cecha: Hash suffixes

Kustomize automatycznie dodaje hash do nazw ConfigMap/Secret:

```bash
kubectl kustomize overlays/dev/ | grep ConfigMap
# name: app-config-g7k4h9m2t8
```

Dlaczego? **Immutability** - każda zmiana tworzy nowy ConfigMap/Secret, co powoduje rolling update podów!

---

## Przykład 5: Zaawansowane transformacje

### 1. Images - zarządzanie obrazami

```yaml
# kustomization.yaml
images:
  # Zmień tag
  - name: nginx
    newTag: 1.26-alpine
  
  # Zmień repository i tag
  - name: nginx
    newName: docker.io/library/nginx
    newTag: latest
  
  # Zmień digest
  - name: nginx
    digest: sha256:abcd1234...
```

### 2. Replicas - skalowanie

```yaml
replicas:
  - name: web-nginx
    count: 5
  - name: api-backend
    count: 3
```

### 3. Name prefix/suffix

```yaml
namePrefix: mycompany-
nameSuffix: -v2

# Wynik: mycompany-web-nginx-v2
```

### 4. Namespace

```yaml
namespace: custom-namespace
```

### 5. Labels i Annotations

```yaml
# Dodaj do wszystkich zasobów
commonLabels:
  app: myapp
  team: backend
  version: v1.2.3

commonAnnotations:
  managed-by: kustomize
  contact: team@example.com
```

### 6. Components - reużywalne patches

Struktura:
```
myapp/
├── base/
├── components/
│   ├── monitoring/
│   │   ├── prometheus-annotations.yaml
│   │   └── kustomization.yaml
│   └── security/
│       ├── psp.yaml
│       └── kustomization.yaml
└── overlays/
```

`components/monitoring/kustomization.yaml`:
```yaml
apiVersion: kustomize.config.k8s.io/v1alpha1
kind: Component

patchesStrategicMerge:
  - prometheus-annotations.yaml
```

Użycie w overlay:
```yaml
# overlays/prod/kustomization.yaml
bases:
  - ../../base

components:
  - ../../components/monitoring
  - ../../components/security
```

---

## Praktyczny przykład: Aplikacja 3-warstwowa

### Struktura projektu

```
webapp/
├── base/
│   ├── frontend/
│   │   ├── deployment.yaml
│   │   ├── service.yaml
│   │   └── kustomization.yaml
│   ├── backend/
│   │   ├── deployment.yaml
│   │   ├── service.yaml
│   │   └── kustomization.yaml
│   ├── database/
│   │   ├── statefulset.yaml
│   │   ├── service.yaml
│   │   └── kustomization.yaml
│   └── kustomization.yaml
└── overlays/
    ├── dev/
    │   ├── kustomization.yaml
    │   └── patches/
    ├── staging/
    │   ├── kustomization.yaml
    │   └── patches/
    └── prod/
        ├── kustomization.yaml
        ├── patches/
        └── secrets/
```

### Base - Frontend

`base/frontend/deployment.yaml`:
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: frontend
spec:
  replicas: 1
  selector:
    matchLabels:
      app: frontend
  template:
    metadata:
      labels:
        app: frontend
    spec:
      containers:
      - name: frontend
        image: nginx:alpine
        ports:
        - containerPort: 80
        env:
        - name: BACKEND_URL
          value: http://backend:8080
```

`base/frontend/service.yaml`:
```yaml
apiVersion: v1
kind: Service
metadata:
  name: frontend
spec:
  type: ClusterIP
  ports:
  - port: 80
    targetPort: 80
  selector:
    app: frontend
```

`base/frontend/kustomization.yaml`:
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - deployment.yaml
  - service.yaml

commonLabels:
  tier: frontend
```

### Base - Backend

`base/backend/deployment.yaml`:
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: backend
spec:
  replicas: 1
  selector:
    matchLabels:
      app: backend
  template:
    metadata:
      labels:
        app: backend
    spec:
      containers:
      - name: backend
        image: myapp/backend:latest
        ports:
        - containerPort: 8080
        env:
        - name: DB_HOST
          value: database
        - name: DB_PORT
          value: "5432"
```

`base/backend/service.yaml`:
```yaml
apiVersion: v1
kind: Service
metadata:
  name: backend
spec:
  type: ClusterIP
  ports:
  - port: 8080
    targetPort: 8080
  selector:
    app: backend
```

`base/backend/kustomization.yaml`:
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - deployment.yaml
  - service.yaml

commonLabels:
  tier: backend
```

### Base - Database

`base/database/statefulset.yaml`:
```yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: database
spec:
  serviceName: database
  replicas: 1
  selector:
    matchLabels:
      app: database
  template:
    metadata:
      labels:
        app: database
    spec:
      containers:
      - name: postgres
        image: postgres:15-alpine
        ports:
        - containerPort: 5432
        env:
        - name: POSTGRES_DB
          value: myapp
        - name: POSTGRES_USER
          value: user
        - name: POSTGRES_PASSWORD
          value: password
        volumeMounts:
        - name: data
          mountPath: /var/lib/postgresql/data
  volumeClaimTemplates:
  - metadata:
      name: data
    spec:
      accessModes: [ "ReadWriteOnce" ]
      resources:
        requests:
          storage: 1Gi
```

`base/database/service.yaml`:
```yaml
apiVersion: v1
kind: Service
metadata:
  name: database
spec:
  clusterIP: None
  ports:
  - port: 5432
    targetPort: 5432
  selector:
    app: database
```

`base/database/kustomization.yaml`:
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - statefulset.yaml
  - service.yaml

commonLabels:
  tier: database
```

### Base - główny

`base/kustomization.yaml`:
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - frontend
  - backend
  - database

commonLabels:
  app: webapp
  managed-by: kustomize
```

### Overlay - DEV

`overlays/dev/kustomization.yaml`:
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

bases:
  - ../../base

namespace: development

namePrefix: dev-

commonLabels:
  environment: dev

replicas:
  - name: frontend
    count: 1
  - name: backend
    count: 1

configMapGenerator:
  - name: app-config
    literals:
      - LOG_LEVEL=debug
      - DEBUG=true

patches:
  - target:
      kind: Service
      name: frontend
    patch: |-
      apiVersion: v1
      kind: Service
      metadata:
        name: frontend
      spec:
        type: NodePort
        ports:
        - port: 80
          targetPort: 80
          nodePort: 30080
```

### Overlay - PROD

`overlays/prod/kustomization.yaml`:
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

bases:
  - ../../base

namespace: production

namePrefix: prod-

commonLabels:
  environment: production

replicas:
  - name: frontend
    count: 3
  - name: backend
    count: 3

images:
  - name: myapp/backend
    newTag: v1.2.3
  - name: nginx
    newTag: 1.26-alpine

configMapGenerator:
  - name: app-config
    literals:
      - LOG_LEVEL=info
      - DEBUG=false

secretGenerator:
  - name: db-credentials
    files:
      - secrets/db-password.txt

patchesStrategicMerge:
  - patches/increase-resources.yaml
  - patches/add-monitoring.yaml

patchesJson6902:
  - target:
      kind: Service
      name: frontend
    patch: |-
      - op: replace
        path: /spec/type
        value: LoadBalancer
```

`overlays/prod/patches/increase-resources.yaml`:
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: backend
spec:
  template:
    spec:
      containers:
      - name: backend
        resources:
          requests:
            cpu: 500m
            memory: 512Mi
          limits:
            cpu: 1000m
            memory: 1Gi
```

### Deployment

```bash
# DEV
kubectl apply -k overlays/dev/

# PROD
kubectl apply -k overlays/prod/

# Dry-run
kubectl kustomize overlays/prod/ | kubectl apply --dry-run=client -f -
```

---

## Kustomize vs Helm

### Porównanie szczegółowe

| Feature | Kustomize | Helm |
|---------|-----------|------|
| **Templating** | Brak (pure YAML) | Go templates |
| **Complexity** | Niższa | Wyższa |
| **Learning curve** | Łatwiejszy | Trudniejszy |
| **Base files** | Czyste manifesty | Templates |
| **Versioning** | Brak wbudowanego | Built-in |
| **Rollback** | Przez kubectl/git | `helm rollback` |
| **Package management** | Nie | Tak (Charts) |
| **Dependencies** | Nie | Tak |
| **Integration** | Wbudowane w kubectl | External tool |
| **GitOps** | Doskonałe | Dobre |

### Kiedy co używać?

**Wybierz Kustomize gdy:**
- ✅ Masz proste requirements
- ✅ Wolisz deklaratywne podejście
- ✅ Używasz GitOps (ArgoCD, Flux)
- ✅ Chcesz pure YAML bez szablonów
- ✅ Zarządzasz kilkoma środowiskami

**Wybierz Helm gdy:**
- ✅ Potrzebujesz complex logic w templates
- ✅ Chcesz package management
- ✅ Potrzebujesz versioning i rollbacks
- ✅ Instalujesz 3rd party apps
- ✅ Potrzebujesz dependencies management

### Można łączyć oba!

```bash
# Helm + Kustomize
helm template myapp ./chart | kubectl apply -k -
```

Lub używając Helm post-renderer:
```bash
helm install myapp ./chart --post-renderer ./kustomize.sh
```

---

## Best Practices

### ✅ Dobre praktyki:

#### 1. **Struktura katalogów**

```
project/
├── base/               # Wspólna konfiguracja
├── overlays/           # Środowiska
│   ├── dev/
│   ├── staging/
│   └── prod/
└── components/         # Reużywalne komponenty
    ├── monitoring/
    └── security/
```

#### 2. **Używaj bases, nie resources dla overlays**

```yaml
# ✅ DOBRZE
bases:
  - ../../base

# ❌ ŹLE (duplikacja)
resources:
  - ../../base/deployment.yaml
  - ../../base/service.yaml
```

#### 3. **Generuj ConfigMaps/Secrets zamiast commitować**

```yaml
# ✅ DOBRZE
configMapGenerator:
  - name: config
    files:
      - app.properties

# ❌ ŹLE - nie commituj do git
resources:
  - configmap.yaml  # zawiera dane
```

#### 4. **Używaj nameReference dla cross-references**

```yaml
nameReference:
  - kind: ConfigMap
    version: v1
    fieldSpecs:
    - path: spec/volumes/configMap/name
      kind: Pod
```

#### 5. **Dokumentuj patches**

```yaml
patches:
  - target:
      kind: Deployment
      name: app
    patch: |-
      # Zwiększamy resources dla produkcji
      # Ticket: JIRA-123
      apiVersion: apps/v1
      kind: Deployment
      ...
```

#### 6. **Testuj przed aplikowaniem**

```bash
# Zobacz wygenerowane YAML
kubectl kustomize overlays/prod/

# Walidacja
kubectl kustomize overlays/prod/ | kubectl apply --dry-run=client -f -

# Diff z klastrem
kubectl diff -k overlays/prod/
```

#### 7. **Używaj vars dla cross-cutting concerns**

```yaml
vars:
  - name: SERVICE_NAME
    objref:
      kind: Service
      name: myapp
      apiVersion: v1
    fieldref:
      fieldpath: metadata.name
```

#### 8. **GitOps workflow**

```
git commit → CI/CD → kubectl apply -k overlays/prod/
```

### ❌ Czego unikać:

1. **Za dużo patches** - lepiej użyć separate base
2. **Hardcoded values** - używaj configMapGenerator
3. **Duplikacja** - używaj components
4. **Brak testów** - zawsze rób dry-run
5. **Commiting secrets** - używaj external secret management

---

## Zaawansowane techniki

### 1. Multiple bases

```yaml
bases:
  - ../../base
  - ../../common-config
  - github.com/example/kustomize-configs?ref=v1.0.0
```

### 2. Remote bases

```yaml
bases:
  - github.com/kubernetes-sigs/kustomize//examples/multibases/base
```

### 3. Transformers

`kustomization.yaml`:
```yaml
transformers:
  - transformer.yaml
```

`transformer.yaml`:
```yaml
apiVersion: builtin
kind: PrefixSuffixTransformer
metadata:
  name: customPrefixSuffix
prefix: prod-
suffix: -v2
fieldSpecs:
  - path: metadata/name
```

### 4. Generators (custom)

```yaml
generators:
  - generator.yaml
```

`generator.yaml`:
```yaml
apiVersion: builtin
kind: ConfigMapGenerator
metadata:
  name: my-generator
files:
  - data.txt
```

### 5. Openapi schema validation

```bash
kubectl kustomize --enable-alpha-plugins --enable-exec overlays/prod/
```

---

## Integracja z CI/CD

### GitLab CI

```yaml
# .gitlab-ci.yml
deploy:prod:
  stage: deploy
  script:
    - kubectl kustomize overlays/prod/ | kubectl apply -f -
  only:
    - main
```

### GitHub Actions

```yaml
# .github/workflows/deploy.yml
- name: Deploy to prod
  run: |
    kubectl kustomize overlays/prod/ | kubectl apply -f -
```

### ArgoCD

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: myapp
spec:
  source:
    repoURL: https://github.com/myorg/myapp
    path: overlays/prod
  destination:
    server: https://kubernetes.default.svc
    namespace: production
```

---

## Przydatne komendy

```bash
# === BASIC ===
kubectl kustomize <dir>                  # Zobacz wygenerowane YAML
kubectl apply -k <dir>                   # Zastosuj kustomization
kubectl delete -k <dir>                  # Usuń zasoby
kubectl diff -k <dir>                    # Diff z klastrem

# === DEBUGGING ===
kubectl kustomize <dir> --enable-alpha-plugins  # Alpha features
kubectl kustomize <dir> --load-restrictor none  # Wyłącz ograniczenia
kubectl kustomize <dir> 2>&1 | less             # Debug z paginacją

# === VALIDATION ===
kubectl kustomize <dir> | kubectl apply --dry-run=client -f -
kubectl kustomize <dir> | kubectl apply --server-dry-run -f -
kubectl kustomize <dir> | kubeval -                # Walidacja manifests

# === USEFUL ===
kubectl kustomize <dir> > output.yaml            # Zapisz do pliku
kubectl kustomize <dir> | grep -A 10 "kind: "   # Filtruj resources
kubectl get -k <dir>                              # Get zasobów
```

---

## Zadania praktyczne

### Zadanie 1: Podstawowa aplikacja
Utwórz kustomization dla aplikacji nginx z 3 środowiskami (dev/staging/prod) z różnymi:
- Liczbami replik (1/2/3)
- Namespace'ami
- NodePort (dev), ClusterIP (staging), LoadBalancer (prod)

### Zadanie 2: ConfigMap z plików
Stwórz aplikację, która czyta konfigurację z ConfigMap wygenerowanego z plików `.properties` i `.env`.

### Zadanie 3: Patches
Użyj strategic merge patch do dodania sidecar container do istniejącego Deployment.

### Zadanie 4: Multi-component app
Stwórz 3-warstwową aplikację (frontend/backend/database) z osobnymi kustomization.yaml dla każdej warstwy.

---

## Podsumowanie

**Kustomize** to świetne narzędzie dla:
- ✅ Zarządzania konfiguracją bez szablonów
- ✅ Różnicowania środowisk (dev/staging/prod)
- ✅ GitOps workflows
- ✅ Prostych do średnio złożonych deploymentów

**Key takeaways:**
- Base + Overlays = czysta separacja
- Patches pozwalają na precyzyjne modyfikacje
- Generators upraszczają ConfigMap/Secret
- Wbudowane w kubectl = zero instalacji
- Doskonałe dla GitOps

**Następne kroki:**
1. Przetestuj przykłady z tego tutoriala
2. Przekonwertuj swoje manifesty na Kustomize
3. Zintegruj z CI/CD
4. Sprawdź ArgoCD dla GitOps
5. Porównaj z Helm dla swoich use cases

---

**Przydatne linki:**
- [Oficjalna dokumentacja](https://kubectl.docs.kubernetes.io/references/kustomize/)
- [Kustomize GitHub](https://github.com/kubernetes-sigs/kustomize)
- [Examples repo](https://github.com/kubernetes-sigs/kustomize/tree/master/examples)

Powodzenia! 🚀