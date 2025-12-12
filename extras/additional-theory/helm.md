# Tutorial: Helm - Package Manager dla Kubernetes

## Spis treści
1. [Wprowadzenie](#wprowadzenie)
2. [Instalacja Helm](#instalacja-helm)
3. [Podstawowe operacje](#podstawowe-operacje)
4. [Praca z repozytoriami](#praca-z-repozytoriami)
5. [Tworzenie własnego Chart](#tworzenie-własnego-chart)
6. [Values i Templating](#values-i-templating)
7. [Praktyczny przykład - Aplikacja wielowarstwowa](#praktyczny-przykład---aplikacja-wielowarstwowa)
8. [Zaawansowane funkcje](#zaawansowane-funkcje)
9. [Best Practices](#best-practices)

---

## Wprowadzenie

**Helm** to package manager dla Kubernetes, który:
- Upraszcza wdrażanie aplikacji
- Zarządza wersjami i zależnościami
- Umożliwia łatwe aktualizacje i rollbacki
- Pozwala na parametryzację konfiguracji

### Kluczowe koncepty:

- **Chart** - paczka Helm (jak package w npm, apt)
- **Release** - instancja Chart zainstalowana w klastrze
- **Repository** - miejsce przechowywania Charts (jak DockerHub dla obrazów)
- **Values** - parametry konfiguracyjne Chart

### Architektura Helm 3:
```
helm CLI → Kubernetes API → Cluster
          (nie ma Tiller!)
```

---

## Instalacja Helm

### Na maszynie admin (192.168.1.100)

```bash
# Pobierz najnowszą wersję
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# Lub ręcznie:
wget https://get.helm.sh/helm-v3.13.0-linux-amd64.tar.gz
tar -zxvf helm-v3.13.0-linux-amd64.tar.gz
sudo mv linux-amd64/helm /usr/local/bin/helm
```

### Weryfikacja instalacji:

```bash
helm version
# version.BuildInfo{Version:"v3.13.0", ...}

# Sprawdź połączenie z klastrem
helm list
# (powinna być pusta lista - nie ma jeszcze instalacji)
```

### Konfiguracja bash completion:

```bash
echo "source <(helm completion bash)" >> ~/.bashrc
source ~/.bashrc
```

---

## Podstawowe operacje

### 1. Wyszukiwanie Charts

```bash
# Dodaj oficjalne repozytorium
helm repo add stable https://charts.helm.sh/stable
helm repo add bitnami https://charts.bitnami.com/bitnami

# Aktualizuj listę charts
helm repo update

# Szukaj chart
helm search repo nginx
helm search repo mysql
helm search hub wordpress  # przeszukuj Artifact Hub
```

### 2. Instalacja Chart

```bash
# Podstawowa instalacja
helm install my-nginx bitnami/nginx

# Z namespace
helm install my-nginx bitnami/nginx --namespace web --create-namespace

# Z customowymi wartościami
helm install my-nginx bitnami/nginx --set service.type=NodePort

# Z pliku values
helm install my-nginx bitnami/nginx -f custom-values.yaml

# Dry-run (test bez instalacji)
helm install my-nginx bitnami/nginx --dry-run --debug
```

### 3. Sprawdzanie statusu

```bash
# Lista wszystkich releases
helm list
helm list --all-namespaces
helm list -n web

# Status konkretnego release
helm status my-nginx

# Historia release
helm history my-nginx
```

### 4. Upgrade (aktualizacja)

```bash
# Zmień wartości
helm upgrade my-nginx bitnami/nginx --set replicaCount=3

# Z nowego pliku values
helm upgrade my-nginx bitnami/nginx -f new-values.yaml

# Upgrade z nowej wersji chart
helm upgrade my-nginx bitnami/nginx --version 15.0.0

# Upgrade lub install jeśli nie istnieje
helm upgrade --install my-nginx bitnami/nginx
```

### 5. Rollback (cofnięcie)

```bash
# Zobacz historię
helm history my-nginx

# Rollback do poprzedniej wersji
helm rollback my-nginx

# Rollback do konkretnej rewizji
helm rollback my-nginx 2
```

### 6. Uninstall (usunięcie)

```bash
# Usuń release
helm uninstall my-nginx

# Usuń i zachowaj historię
helm uninstall my-nginx --keep-history
```

---

## Praca z repozytoriami

### Zarządzanie repozytoriami:

```bash
# Dodaj repo
helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add grafana https://grafana.github.io/helm-charts

# Lista repozytoriów
helm repo list

# Aktualizuj
helm repo update

# Usuń repo
helm repo remove stable
```

### Inspekcja Chart przed instalacją:

```bash
# Zobacz szczegóły chart
helm show chart bitnami/nginx

# Zobacz domyślne values
helm show values bitnami/nginx

# Zobacz README
helm show readme bitnami/nginx

# Zobacz wszystko
helm show all bitnami/nginx > nginx-info.txt
```

---

## Tworzenie własnego Chart

### 1. Generowanie podstawowej struktury

```bash
# Utwórz nowy chart
helm create myapp

# Struktura katalogów:
myapp/
├── Chart.yaml          # Metadata chart
├── values.yaml         # Domyślne wartości
├── charts/             # Zależności
├── templates/          # Szablony K8s
│   ├── deployment.yaml
│   ├── service.yaml
│   ├── ingress.yaml
│   ├── _helpers.tpl    # Template helpers
│   └── NOTES.txt       # Informacje po instalacji
└── .helmignore         # Ignorowane pliki
```

### 2. Struktura Chart.yaml

Zapisz jako `myapp/Chart.yaml`:

```yaml
apiVersion: v2
name: myapp
description: Moja pierwsza aplikacja Helm
type: application

# Wersja Chart (zmienia się przy update Chart)
version: 0.1.0

# Wersja aplikacji (zmienia się przy update aplikacji)
appVersion: "1.0.0"

# Metadata
keywords:
  - demo
  - tutorial
home: https://example.com
sources:
  - https://github.com/example/myapp
maintainers:
  - name: Your Name
    email: your.email@example.com

# Zależności (opcjonalne)
dependencies:
  - name: postgresql
    version: 12.x.x
    repository: https://charts.bitnami.com/bitnami
    condition: postgresql.enabled
```

### 3. Podstawowy values.yaml

Zapisz jako `myapp/values.yaml`:

```yaml
# Domyślne wartości dla Chart

# Replikacja
replicaCount: 1

# Obraz Docker
image:
  repository: nginx
  pullPolicy: IfNotPresent
  tag: "1.25-alpine"

# Service
service:
  type: ClusterIP
  port: 80

# Ingress (wyłączony domyślnie)
ingress:
  enabled: false
  className: ""
  annotations: {}
  hosts:
    - host: myapp.local
      paths:
        - path: /
          pathType: Prefix
  tls: []

# Zasoby
resources:
  limits:
    cpu: 100m
    memory: 128Mi
  requests:
    cpu: 100m
    memory: 128Mi

# Autoscaling
autoscaling:
  enabled: false
  minReplicas: 1
  maxReplicas: 10
  targetCPUUtilizationPercentage: 80

# Zmienne środowiskowe
env:
  - name: ENVIRONMENT
    value: "production"

# ConfigMap data
configData:
  app.conf: |
    server {
      listen 80;
      server_name localhost;
    }
```

### 4. Template Deployment

Zapisz jako `myapp/templates/deployment.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ include "myapp.fullname" . }}
  labels:
    {{- include "myapp.labels" . | nindent 4 }}
spec:
  {{- if not .Values.autoscaling.enabled }}
  replicas: {{ .Values.replicaCount }}
  {{- end }}
  selector:
    matchLabels:
      {{- include "myapp.selectorLabels" . | nindent 6 }}
  template:
    metadata:
      labels:
        {{- include "myapp.selectorLabels" . | nindent 8 }}
    spec:
      containers:
      - name: {{ .Chart.Name }}
        image: "{{ .Values.image.repository }}:{{ .Values.image.tag | default .Chart.AppVersion }}"
        imagePullPolicy: {{ .Values.image.pullPolicy }}
        ports:
        - name: http
          containerPort: 80
          protocol: TCP
        {{- if .Values.env }}
        env:
          {{- toYaml .Values.env | nindent 10 }}
        {{- end }}
        resources:
          {{- toYaml .Values.resources | nindent 10 }}
        livenessProbe:
          httpGet:
            path: /
            port: http
        readinessProbe:
          httpGet:
            path: /
            port: http
```

### 5. Template Service

Zapisz jako `myapp/templates/service.yaml`:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: {{ include "myapp.fullname" . }}
  labels:
    {{- include "myapp.labels" . | nindent 4 }}
spec:
  type: {{ .Values.service.type }}
  ports:
    - port: {{ .Values.service.port }}
      targetPort: http
      protocol: TCP
      name: http
  selector:
    {{- include "myapp.selectorLabels" . | nindent 4 }}
```

### 6. Template Helpers

Zapisz jako `myapp/templates/_helpers.tpl`:

```yaml
{{/*
Expand the name of the chart.
*/}}
{{- define "myapp.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "myapp.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "myapp.labels" -}}
helm.sh/chart: {{ include "myapp.chart" . }}
{{ include "myapp.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "myapp.selectorLabels" -}}
app.kubernetes.io/name: {{ include "myapp.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "myapp.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}
```

---

## Values i Templating

### Hierarchia Values (priorytet od najwyższego):

1. `--set` parametry z linii komend
2. `-f custom-values.yaml` pliki
3. `values.yaml` w Chart
4. Wartości domyślne w templates

### Przykłady templating:

#### 1. Podstawowe zmienne:

```yaml
# Odwołanie do values
{{ .Values.replicaCount }}

# Odwołanie do Chart metadata
{{ .Chart.Name }}
{{ .Chart.Version }}

# Odwołanie do Release
{{ .Release.Name }}
{{ .Release.Namespace }}
```

#### 2. Warunki (if/else):

```yaml
{{- if .Values.ingress.enabled }}
apiVersion: networking.k8s.io/v1
kind: Ingress
# ...
{{- end }}

{{- if eq .Values.service.type "NodePort" }}
  nodePort: {{ .Values.service.nodePort }}
{{- else if eq .Values.service.type "LoadBalancer" }}
  loadBalancerIP: {{ .Values.service.loadBalancerIP }}
{{- end }}
```

#### 3. Pętle (range):

```yaml
# Z listy
{{- range .Values.env }}
- name: {{ .name }}
  value: {{ .value | quote }}
{{- end }}

# Z mapy
{{- range $key, $value := .Values.labels }}
{{ $key }}: {{ $value }}
{{- end }}
```

#### 4. Funkcje:

```yaml
# Quote (dodaj cudzysłowy)
value: {{ .Values.myValue | quote }}

# Default (wartość domyślna)
tag: {{ .Values.image.tag | default "latest" }}

# Upper/Lower
name: {{ .Values.name | upper }}

# Indent (wcięcie)
data:
  {{- toYaml .Values.config | nindent 2 }}

# Trim (usuń spacje)
name: {{ .Values.name | trim }}
```

#### 5. Named templates (z _helpers.tpl):

```yaml
# Wywołanie
labels:
  {{- include "myapp.labels" . | nindent 4 }}

# Definicja w _helpers.tpl
{{- define "myapp.labels" -}}
app: {{ .Chart.Name }}
version: {{ .Chart.Version }}
{{- end }}
```

---

## Praktyczny przykład - Aplikacja wielowarstwowa

### Scenariusz: Blog z Frontend, Backend i Database

### 1. Struktura projektu

```bash
helm create blog-app
cd blog-app
```

### 2. Chart.yaml

```yaml
apiVersion: v2
name: blog-app
description: Wielowarstwowa aplikacja blog
type: application
version: 1.0.0
appVersion: "1.0.0"

dependencies:
  - name: postgresql
    version: "12.x.x"
    repository: "https://charts.bitnami.com/bitnami"
    condition: postgresql.enabled
```

### 3. values.yaml (blog-app/values.yaml)

```yaml
# === FRONTEND ===
frontend:
  enabled: true
  replicaCount: 2
  image:
    repository: nginx
    tag: alpine
  service:
    type: NodePort
    port: 80
    nodePort: 30080
  resources:
    limits:
      cpu: 200m
      memory: 256Mi
    requests:
      cpu: 100m
      memory: 128Mi
  env:
    - name: BACKEND_URL
      value: "http://blog-app-backend:8080"

# === BACKEND ===
backend:
  enabled: true
  replicaCount: 2
  image:
    repository: myapp/backend
    tag: "1.0"
  service:
    type: ClusterIP
    port: 8080
  resources:
    limits:
      cpu: 500m
      memory: 512Mi
    requests:
      cpu: 250m
      memory: 256Mi
  env:
    - name: DB_HOST
      value: "blog-app-postgresql"
    - name: DB_PORT
      value: "5432"
    - name: DB_USER
      value: "bloguser"
    - name: DB_PASSWORD
      valueFrom:
        secretKeyRef:
          name: blog-app-db-secret
          key: password

# === DATABASE (PostgreSQL) ===
postgresql:
  enabled: true
  auth:
    username: bloguser
    password: blogpass
    database: blogdb
  primary:
    persistence:
      enabled: true
      size: 8Gi
  resources:
    limits:
      cpu: 500m
      memory: 512Mi
    requests:
      cpu: 250m
      memory: 256Mi
```

### 4. Template Frontend Deployment

Zapisz jako `templates/frontend-deployment.yaml`:

```yaml
{{- if .Values.frontend.enabled }}
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ include "blog-app.fullname" . }}-frontend
  labels:
    app.kubernetes.io/component: frontend
    {{- include "blog-app.labels" . | nindent 4 }}
spec:
  replicas: {{ .Values.frontend.replicaCount }}
  selector:
    matchLabels:
      app.kubernetes.io/component: frontend
      {{- include "blog-app.selectorLabels" . | nindent 6 }}
  template:
    metadata:
      labels:
        app.kubernetes.io/component: frontend
        {{- include "blog-app.selectorLabels" . | nindent 8 }}
    spec:
      containers:
      - name: frontend
        image: "{{ .Values.frontend.image.repository }}:{{ .Values.frontend.image.tag }}"
        ports:
        - name: http
          containerPort: 80
        env:
        {{- toYaml .Values.frontend.env | nindent 8 }}
        resources:
        {{- toYaml .Values.frontend.resources | nindent 10 }}
{{- end }}
```

### 5. Template Backend Deployment

Zapisz jako `templates/backend-deployment.yaml`:

```yaml
{{- if .Values.backend.enabled }}
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ include "blog-app.fullname" . }}-backend
  labels:
    app.kubernetes.io/component: backend
    {{- include "blog-app.labels" . | nindent 4 }}
spec:
  replicas: {{ .Values.backend.replicaCount }}
  selector:
    matchLabels:
      app.kubernetes.io/component: backend
      {{- include "blog-app.selectorLabels" . | nindent 6 }}
  template:
    metadata:
      labels:
        app.kubernetes.io/component: backend
        {{- include "blog-app.selectorLabels" . | nindent 8 }}
    spec:
      containers:
      - name: backend
        image: "{{ .Values.backend.image.repository }}:{{ .Values.backend.image.tag }}"
        ports:
        - name: http
          containerPort: 8080
        env:
        {{- toYaml .Values.backend.env | nindent 8 }}
        resources:
        {{- toYaml .Values.backend.resources | nindent 10 }}
{{- end }}
```

### 6. Template Services

Zapisz jako `templates/services.yaml`:

```yaml
{{- if .Values.frontend.enabled }}
---
apiVersion: v1
kind: Service
metadata:
  name: {{ include "blog-app.fullname" . }}-frontend
  labels:
    app.kubernetes.io/component: frontend
    {{- include "blog-app.labels" . | nindent 4 }}
spec:
  type: {{ .Values.frontend.service.type }}
  ports:
    - port: {{ .Values.frontend.service.port }}
      targetPort: http
      {{- if eq .Values.frontend.service.type "NodePort" }}
      nodePort: {{ .Values.frontend.service.nodePort }}
      {{- end }}
  selector:
    app.kubernetes.io/component: frontend
    {{- include "blog-app.selectorLabels" . | nindent 4 }}
{{- end }}

{{- if .Values.backend.enabled }}
---
apiVersion: v1
kind: Service
metadata:
  name: {{ include "blog-app.fullname" . }}-backend
  labels:
    app.kubernetes.io/component: backend
    {{- include "blog-app.labels" . | nindent 4 }}
spec:
  type: {{ .Values.backend.service.type }}
  ports:
    - port: {{ .Values.backend.service.port }}
      targetPort: http
  selector:
    app.kubernetes.io/component: backend
    {{- include "blog-app.selectorLabels" . | nindent 4 }}
{{- end }}
```

### 7. Instalacja aplikacji

```bash
# Pobierz zależności (PostgreSQL)
helm dependency update

# Test czy działa
helm install blog-app . --dry-run --debug

# Instalacja
helm install blog-app . --namespace blog --create-namespace

# Zobacz status
helm status blog-app -n blog

# Zobacz zasoby
kubectl get all -n blog
```

### 8. Customizacja instalacji

Zapisz jako `custom-prod-values.yaml`:

```yaml
frontend:
  replicaCount: 3
  service:
    type: LoadBalancer

backend:
  replicaCount: 3
  resources:
    limits:
      cpu: 1000m
      memory: 1Gi

postgresql:
  primary:
    persistence:
      size: 20Gi
  resources:
    limits:
      cpu: 1000m
      memory: 2Gi
```

```bash
# Instalacja z custom values
helm install blog-app . -f custom-prod-values.yaml -n blog-prod --create-namespace

# Lub upgrade istniejącej instalacji
helm upgrade blog-app . -f custom-prod-values.yaml -n blog
```

---

## Zaawansowane funkcje

### 1. Hooks (lifecycle hooks)

Zapisz jako `templates/db-init-job.yaml`:

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: {{ include "blog-app.fullname" . }}-db-init
  annotations:
    "helm.sh/hook": post-install
    "helm.sh/hook-weight": "1"
    "helm.sh/hook-delete-policy": hook-succeeded
spec:
  template:
    spec:
      restartPolicy: Never
      containers:
      - name: db-init
        image: postgres:15-alpine
        command: ['sh', '-c', 'echo "Database initialized"']
```

**Hook types:**
- `pre-install` - przed instalacją
- `post-install` - po instalacji
- `pre-upgrade` - przed upgrade
- `post-upgrade` - po upgrade
- `pre-delete` - przed usunięciem
- `post-delete` - po usunięciu
- `pre-rollback` - przed rollback
- `post-rollback` - po rollback

### 2. Tests

Zapisz jako `templates/tests/test-connection.yaml`:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: "{{ include "blog-app.fullname" . }}-test-connection"
  annotations:
    "helm.sh/hook": test
spec:
  restartPolicy: Never
  containers:
  - name: wget
    image: busybox
    command: ['wget']
    args: ['{{ include "blog-app.fullname" . }}-frontend:80']
```

Uruchom test:
```bash
helm test blog-app -n blog
```

### 3. Subcharts i zależności

```bash
# Dodaj zależność do Chart.yaml
dependencies:
  - name: redis
    version: "17.x.x"
    repository: "https://charts.bitnami.com/bitnami"

# Pobierz zależności
helm dependency update

# Zobacz zależności
helm dependency list

# Disable subchart
helm install myapp . --set redis.enabled=false
```

### 4. Helm Secrets (opcjonalne)

```bash
# Instalacja helm-secrets plugin
helm plugin install https://github.com/jkroepke/helm-secrets

# Szyfruj values
helm secrets encrypt secrets.yaml

# Instalacja z zaszyfrowanymi wartościami
helm secrets install myapp . -f secrets.yaml.enc
```

### 5. Packaging i sharing

```bash
# Spakuj chart
helm package blog-app/
# Tworzy: blog-app-1.0.0.tgz

# Instalacja z paczki
helm install my-blog blog-app-1.0.0.tgz

# Utworzenie własnego repo
helm repo index . --url https://myrepo.example.com/charts

# Dodanie jako repo
helm repo add myrepo https://myrepo.example.com/charts
```

---

## Best Practices

### ✅ Dobre praktyki:

#### 1. **Wersjonowanie**
```yaml
# Chart.yaml
version: 1.2.3        # Wersja Chart (Semantic Versioning)
appVersion: "2.0.1"   # Wersja aplikacji
```

#### 2. **Używaj named templates**
```yaml
# _helpers.tpl
{{- define "myapp.labels" -}}
app.kubernetes.io/name: {{ include "myapp.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}
```

#### 3. **Zawsze definiuj Resources**
```yaml
resources:
  limits:
    cpu: 500m
    memory: 512Mi
  requests:
    cpu: 250m
    memory: 256Mi
```

#### 4. **Używaj Liveness i Readiness Probes**
```yaml
livenessProbe:
  httpGet:
    path: /health
    port: http
  initialDelaySeconds: 30
readinessProbe:
  httpGet:
    path: /ready
    port: http
  initialDelaySeconds: 10
```

#### 5. **Dokumentuj wartości**
```yaml
# values.yaml
# -- Liczba replik aplikacji
replicaCount: 1

# -- Konfiguracja obrazu Docker
image:
  # -- Repozytorium obrazu
  repository: nginx
  # -- Tag obrazu (domyślnie appVersion z Chart.yaml)
  tag: ""
```

#### 6. **Używaj .helmignore**
```
# .helmignore
*.md
.git/
.gitignore
tests/
docs/
```

#### 7. **Walidacja**
```bash
# Lint chart (sprawdzenie błędów)
helm lint myapp/

# Template z debugowaniem
helm template myapp . --debug

# Dry-run instalacji
helm install myapp . --dry-run --debug
```

#### 8. **Schema validation**

Zapisz jako `myapp/values.schema.json`:

```json
{
  "$schema": "https://json-schema.org/draft-07/schema#",
  "type": "object",
  "required": ["replicaCount", "image"],
  "properties": {
    "replicaCount": {
      "type": "integer",
      "minimum": 1,
      "maximum": 10
    },
    "image": {
      "type": "object",
      "required": ["repository", "tag"],
      "properties": {
        "repository": {
          "type": "string"
        },
        "tag": {
          "type": "string"
        }
      }
    }
  }
}
```

### ❌ Czego unikać:

1. **Hardcodowane wartości w templates**
   ```yaml
   # ❌ ŹLE
   replicas: 3
   
   # ✅ DOBRZE
   replicas: {{ .Values.replicaCount }}
   ```

2. **Brak wartości domyślnych**
   ```yaml
   # ❌ ŹLE
   tag: {{ .Values.image.tag }}
   
   # ✅ DOBRZE
   tag: {{ .Values.image.tag | default .Chart.AppVersion }}
   ```

3. **Za dużo logiki w templates**
   ```yaml
   # ❌ ŹLE - skomplikowana logika w template
   # ✅ DOBRZE - przenieś do _helpers.tpl
   ```

4. **Brak dokumentacji NOTES.txt**

5. **Brak testów helm test**

---

## Przydatne komendy (cheat sheet)

```bash
# === INSTALACJA I ZARZĄDZANIE ===
helm install <name> <chart>                    # Instalacja
helm install <name> <chart> -f values.yaml     # Z custom values
helm upgrade <name> <chart>                    # Upgrade
helm upgrade --install <name> <chart>          # Install lub upgrade
helm rollback <name>                           # Rollback
helm uninstall <name>                          # Usunięcie
helm list                                      # Lista releases
helm status <name>                             # Status release
helm history <name>                            # Historia release
helm get values <name>                         # Pobierz values
helm get manifest <name>                       # Pobierz manifesty

# === REPOZYTORIA ===
helm repo add <name> <url>                     # Dodaj repo
helm repo update                               # Aktualizuj repos
helm repo list                                 # Lista repos
helm search repo <keyword>                     # Szukaj w repo
helm search hub <keyword>                      # Szukaj w Artifact Hub

# === TWORZENIE CHARTS ===
helm create <name>                             # Nowy chart
helm lint <chart>                              # Walidacja
helm template <name> <chart>                   # Render templates
helm package <chart>                           # Spakuj chart
helm dependency update                         # Pobierz zależności
helm test <name>                               # Uruchom testy

# === DEBUGOWANIE ===
helm install <name> <chart> --dry-run --debug  # Test instalacji
helm get all <name>                            # Wszystkie info o release
helm show values <chart>                       # Pokaż values
helm show chart <chart>                        # Pokaż metadata
```

---

## Praktyczne ćwiczenia

### Ćwiczenie 1: Instalacja gotowego Chart

```bash
# 1. Dodaj repo i zainstaluj WordPress
helm repo add bitnami https://charts.bitnami.com/bitnami
helm install my-wordpress bitnami/wordpress \
  --set service.type=NodePort \
  --set wordpressUsername=admin \
  --set wordpressPassword=admin123 \
  -n wordpress --create-namespace

# 2. Sprawdź status
helm status my-wordpress -n wordpress

# 3. Pobierz hasło
kubectl get secret my-wordpress -n wordpress -o jsonpath="{.data.wordpress-password}" | base64 -d

# 4. Zobacz aplikację
kubectl get svc -n wordpress
# Otwórz w przeglądarce NodePort
```

### Ćwiczenie 2: Utworzenie własnego Chart

```bash
# 1. Stwórz chart dla prostej aplikacji
helm create my-simple-app

# 2. Zmodyfikuj values.yaml
replicaCount: 2
service:
  type: NodePort
  nodePort: 30090

# 3. Test i instalacja
helm lint my-simple-app/
helm install simple my-simple-app/ -n apps --create-namespace

# 4. Upgrade z nowymi wartościami
helm upgrade simple my-simple-app/ --set replicaCount=3

# 5. Rollback
helm rollback simple
```

### Ćwiczenie 3: Chart z zależnościami

```bash
# 1. Dodaj PostgreSQL jako zależność do Chart.yaml
# 2. Pobierz zależności
helm dependency update

# 3. Instalacja z wyłączoną bazą
helm install myapp . --set postgresql.enabled=false

# 4. Upgrade z włączoną bazą
helm upgrade myapp . --set postgresql.enabled=true
```

---

## Podsumowanie

Helm to potężne narzędzie, które:
- ✅ Upraszcza deployment aplikacji
- ✅ Zarządza wersjami i rollbackami
- ✅ Parametryzuje konfigurację
- ✅ Umożliwia reużycie konfiguracji
- ✅ Obsługuje złożone zależności

### Następne kroki:

1. Przećwicz przykłady z tego tutoriala
2. Stwórz własny Chart dla swojej aplikacji
3. Zobacz [Artifact Hub](https://artifacthub.io/) dla gotowych Charts
4. Poczytaj o [Helmfile](https://github.com/helmfile/helmfile) dla zarządzania wieloma releases
5. Sprawdź [ChartMuseum](https://chartmuseum.com/) dla własnego repozytorium Charts

---

**Autor:** Tutorial Kubernetes  
**Data:** 2024  
**Wersja:** 1.0