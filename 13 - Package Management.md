# Package Management with Helm and Kustomize

## Understanding Package Management Challenges

Managing Kubernetes applications across different environments presents several challenges that every DevOps engineer encounters. When deploying applications to development, staging, and production environments, each environment typically requires different configurations, resource allocations, and security settings. Without proper tooling, managing these variations becomes error-prone and difficult to maintain.

### Core Challenges in Kubernetes Configuration

Configuration Variations Across Environments  
Each environment requires different settings. Development environments might need debug logging and minimal resources, while production requires optimized performance settings, proper resource limits, and security configurations. Managing these differences manually leads to configuration drift and deployment errors.

Template Management and Reusability  
Applications often share common patterns. A typical web application might include a deployment, service, ingress, and ConfigMap. Creating these resources from scratch for each application wastes time and increases the chance of inconsistencies.

Version Control and Release Management  
Tracking which version of an application is deployed where, managing upgrades, and performing rollbacks when issues arise requires systematic approaches to versioning and release management.

Dependency Management  
Modern applications rarely exist in isolation. They depend on databases, message queues, caching systems, and other services. Managing these dependencies and their configurations adds another layer of complexity.

Environment Promotion  
Moving applications from development through staging to production should be predictable and repeatable. Without proper tooling, promoting applications between environments becomes a manual, error-prone process.

### Two Philosophical Approaches

The Kubernetes ecosystem has developed two primary approaches to solving these challenges:

Helm: The Template-Based Approach  
Helm treats Kubernetes applications as packages called charts. It uses Go templates to parameterize Kubernetes manifests, allowing you to define variables and logic within your configuration files. This approach provides powerful templating capabilities and includes built-in release management.

Kustomize: The Patch-Based Approach  
Kustomize takes a different philosophy. Instead of templates, it uses a base configuration with overlays that patch and modify the base for different environments. This approach keeps configurations in plain Kubernetes YAML, making them easier to read and understand without learning a templating language.

## Helm: The Kubernetes Package Manager

Helm has become the de facto standard for packaging and distributing Kubernetes applications. Think of Helm as the apt or yum for Kubernetes, providing a consistent way to package, configure, share, and deploy applications.

### Understanding Helm Architecture

Helm operates with several key components that work together to manage Kubernetes applications:

The Helm Client  
The Helm command-line interface (CLI) is your primary tool for interacting with Helm. It handles chart development, repository management, and release operations. The CLI communicates directly with your Kubernetes cluster using your kubectl configuration.

Charts: The Heart of Helm  
A chart is a collection of files that describe a related set of Kubernetes resources. Charts contain templates, default configuration values, metadata about the package, and documentation. Charts can be stored locally, in Git repositories, or in dedicated chart repositories.

Templates and Values  
Templates are Kubernetes manifest files with Go template directives. These directives allow dynamic content generation based on values provided during installation. Values files contain the configuration parameters that customize the templates for different deployments.

Repositories  
Chart repositories are HTTP servers that house collections of charts. Charts are also commonly distributed as OCI artifacts in container registries (for example `oci://ghcr.io/nginx/charts/nginx-gateway-fabric`). Artifact Hub (artifacthub.io) indexes thousands of ready-to-use charts for common applications. Organizations often maintain private repositories for internal applications.

### Benefits of Using Helm

Simplified Application Deployment  
Instead of managing multiple YAML files, Helm packages everything into a single unit. Installing a complex application like WordPress or PostgreSQL becomes a single command.

Configuration Management  
Helm separates configuration from templates, making it easy to deploy the same application with different settings. Development, staging, and production can each have their own values files.

Release Management  
Helm tracks every installation as a release, maintaining a history of deployments. You can upgrade applications to new versions, roll back to previous versions, and see what changed between versions.

Dependency Management  
Charts can declare dependencies on other charts. Installing a web application that requires a database automatically installs and configures both components.

Community Ecosystem  
The Helm community has created thousands of production-ready charts for popular applications. These charts incorporate best practices and are continuously improved by the community.

## Workshop: Mastering Helm Fundamentals

This workshop will guide you through installing Helm, using existing charts, and creating your own charts. By the end, you'll understand how to package and deploy applications using Helm.

### Prerequisites and Setup

Before starting, ensure you have:

- A running Kubernetes cluster (the training cluster from module 00: MetalLB, NGINX Gateway Fabric, metrics-server)
- kubectl installed and configured to communicate with your cluster
- Basic familiarity with Kubernetes concepts (pods, deployments, services)
- A text editor for editing YAML files

### Installing Helm

Helm installation varies by operating system. Choose the method that matches your environment:

```bash
# Universal installation script (works on Linux and macOS)
curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-4
chmod 700 get_helm.sh
./get_helm.sh

# macOS using Homebrew
brew install helm

# Windows using Chocolatey
choco install kubernetes-helm

# Ubuntu/Debian using apt (community repository hosted by Buildkite;
# see https://helm.sh/docs/intro/install/ for the key fingerprint check)
sudo apt-get install curl gpg --yes
curl -fsSL https://packages.buildkite.com/helm-linux/helm-debian/gpgkey | sudo tee /etc/apt/keyrings/helm.asc > /dev/null
sudo tee /etc/apt/sources.list.d/helm-stable-debian.sources > /dev/null <<EOF
Types: deb
URIs: https://packages.buildkite.com/helm-linux/helm-debian/any/
Suites: any
Components: main
Signed-By: /etc/apt/keyrings/helm.asc
EOF
sudo apt-get update
sudo apt-get install helm

# Verify the installation
helm version --short
```

Expected output should show version v4.x.x (the training cluster uses v4.3.1). Like Helm 3, Helm 4 has no server-side component (Tiller was removed in Helm 3) - the CLI talks directly to the Kubernetes API using your kubeconfig.

### Working with Helm Repositories

Repositories are collections of charts. Let's add some popular repositories and explore available charts:

```bash
# Add the Bitnami repository
# Note: since August 2025 Bitnami no longer updates its free charts (they stay available, frozen,
# also as OCI artifacts in oci://registry-1.docker.io/bitnamicharts). The free container images
# are limited to "latest" tags of a subset of apps; older version tags moved to docker.io/bitnamilegacy.
# Fine for this workshop, not for production.
helm repo add bitnami https://charts.bitnami.com/bitnami

# Add other useful repositories
# (the old "stable" repo is archived and the ingress-nginx project is retired - don't use them)
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add grafana https://grafana.github.io/helm-charts

# Update your local repository cache
helm repo update

# List all configured repositories
helm repo list

# Search for specific applications
helm search repo wordpress
helm search repo postgresql
helm search repo redis

# Search with more details
helm search repo nginx --versions

# Get detailed information about a specific chart
helm show chart bitnami/nginx
helm show readme bitnami/nginx
helm show values bitnami/nginx > nginx-default-values.yaml
```

The `helm show values` command is particularly useful as it shows all configurable parameters for a chart. Save this output to understand what you can customize.

### Installing and Managing Charts

Let's install an NGINX web server using Helm and explore various installation options:

```bash
# Simple installation with default values
# (the bitnami/nginx chart creates a LoadBalancer Service by default - MetalLB assigns it an IP from its pool)
helm install my-web-server bitnami/nginx

# Check the installation status
helm status my-web-server

# List all Helm releases in the current namespace
helm list

# Install with custom parameters using --set
helm install custom-nginx bitnami/nginx \
  --set service.type=LoadBalancer \
  --set replicaCount=3 \
  --set resources.limits.cpu=200m \
  --set resources.limits.memory=256Mi

# Install using a custom values file
cat > my-nginx-values.yaml << 'EOF'
# Number of NGINX replicas
replicaCount: 2

# Image configuration
image:
  registry: docker.io
  repository: bitnami/nginx
  tag: latest   # versioned tags are no longer published in the free bitnami/ repository
  pullPolicy: IfNotPresent

# Service configuration
service:
  type: NodePort
  ports:
    http: 80
  nodePorts:
    http: 30080

# Resource limits and requests
resources:
  limits:
    cpu: 250m
    memory: 256Mi
  requests:
    cpu: 100m
    memory: 128Mi

# Autoscaling configuration
autoscaling:
  enabled: true
  minReplicas: 2
  maxReplicas: 5
  targetCPU: 70

# Server block configuration
serverBlock: |-
  server {
    listen 8080;
    server_name _;
    location / {
      default_type text/html;
      return 200 '<html><body><h1>Hello from Helm!</h1></body></html>';
    }
  }
EOF

helm install configured-nginx bitnami/nginx -f my-nginx-values.yaml

# Install in a specific namespace
kubectl create namespace web-apps
helm install -n web-apps namespaced-nginx bitnami/nginx

# Install with a specific version
helm install versioned-nginx bitnami/nginx --version 25.2.12

# Perform a dry run to see what would be installed
helm install test-nginx bitnami/nginx --dry-run=client --debug
```

### Managing Releases

Once applications are installed, Helm provides comprehensive management capabilities:

```bash
# View all releases across all namespaces
helm list --all-namespaces

# Get detailed information about a release
helm get values my-web-server
helm get manifest my-web-server
helm get notes my-web-server
helm get all my-web-server

# View release history
helm history my-web-server

# Upgrade a release with new values
helm upgrade my-web-server bitnami/nginx \
  --set replicaCount=5 \
  --set service.type=LoadBalancer

# Upgrade using a new values file
# (values passed with --set in the previous upgrade are NOT kept - compare "helm get values" before and after)
cat > upgrade-values.yaml << 'EOF'
replicaCount: 4
resources:
  limits:
    cpu: 300m
    memory: 512Mi
EOF

helm upgrade my-web-server bitnami/nginx -f upgrade-values.yaml

# Roll back to the previous revision (omit the revision number)
helm rollback my-web-server

# Roll back to a specific revision
helm rollback my-web-server 2

# Uninstall a release
helm uninstall custom-nginx

# Uninstall and keep history
helm uninstall my-web-server --keep-history

# List all releases including uninstalled ones with kept history
helm list --uninstalled
```

## Creating Custom Helm Charts

While using existing charts is convenient, you'll often need to create custom charts for your applications. Let's build a complete chart from scratch.

### Generating the Chart Structure

```bash
# Create a new chart
helm create webapp-chart

# Examine the generated structure
ls -la webapp-chart/
tree webapp-chart/  # If tree is installed
```

The generated structure includes:

- `Chart.yaml`: Metadata about your chart
- `values.yaml`: Default configuration values
- `templates/`: Directory containing Kubernetes manifest templates
- `charts/`: Directory for chart dependencies
- `.helmignore`: Patterns to ignore when packaging

### Understanding Chart.yaml

Let's create a comprehensive Chart.yaml file:

```yaml
# webapp-chart/Chart.yaml
apiVersion: v2
name: webapp-chart
description: A comprehensive Helm chart for deploying web applications
type: application
version: 1.0.0         # version of the chart itself (bump on every chart change)
appVersion: "6.17.0"   # version of the packaged application (default image tag)
keywords:
  - web
  - application
  - podinfo
home: https://github.com/yourorg/webapp
sources:
  - https://github.com/yourorg/webapp
maintainers:
  - name: DevOps Team
    email: devops@example.com
    url: https://example.com
dependencies:
  - name: redis
    version: 28.x.x
    repository: oci://registry-1.docker.io/bitnamicharts
    condition: redis.enabled
annotations:
  category: WebApplication
  licenses: Apache-2.0
```

### Creating Comprehensive values.yaml

The values.yaml file defines all configurable parameters:

```yaml
# webapp-chart/values.yaml

# Global values that can be accessed by subcharts
global:
  storageClass: ""
  environment: development

# Replica configuration
replicaCount: 2

# Image configuration
# podinfo is a small Go web app made for demos: it listens on 9898, runs as non-root,
# works with a read-only root filesystem and exposes /healthz, /readyz and /metrics
image:
  registry: ghcr.io
  repository: stefanprodan/podinfo
  tag: ""             # empty = use .Chart.AppVersion
  pullPolicy: IfNotPresent
  pullSecrets: []

# Service account configuration
serviceAccount:
  create: true
  annotations: {}
  name: ""
  automount: true

# Pod security context
podSecurityContext:
  runAsNonRoot: true
  runAsUser: 1000
  runAsGroup: 1000
  fsGroup: 1000

# Container security context
securityContext:
  allowPrivilegeEscalation: false
  capabilities:
    drop:
    - ALL
  readOnlyRootFilesystem: true

# Service configuration
service:
  type: ClusterIP
  port: 80
  targetPort: 9898
  nodePort: ""
  loadBalancerIP: ""
  annotations: {}

# Ingress configuration (used by templates/ingress.yaml generated by helm create;
# the training cluster has no Ingress controller - it uses Gateway API, see httpRoute below)
ingress:
  enabled: false
  className: ""
  annotations: {}
  hosts:
    - host: webapp.example.com
      paths:
        - path: /
          pathType: Prefix
  tls:
    - secretName: webapp-tls
      hosts:
        - webapp.example.com

# Gateway API HTTPRoute (used by templates/httproute.yaml generated by helm create)
httpRoute:
  enabled: false
  annotations: {}
  parentRefs:
  - name: shared-gateway       # created in "Testing and Packaging Charts" below
    namespace: shared-gateway
    sectionName: http
  hostnames:
  - webapp.example.com
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /

# Resource limits and requests
resources:
  limits:
    cpu: 200m
    memory: 256Mi
  requests:
    cpu: 100m
    memory: 128Mi

# Horizontal Pod Autoscaler
autoscaling:
  enabled: false
  minReplicas: 2
  maxReplicas: 10
  targetCPUUtilizationPercentage: 70
  targetMemoryUtilizationPercentage: 80

# Persistence configuration
persistence:
  enabled: false
  storageClass: ""
  accessMode: ReadWriteOnce
  size: 8Gi
  mountPath: /data
  annotations: {}

# Probes configuration
livenessProbe:
  enabled: true
  initialDelaySeconds: 30
  periodSeconds: 10
  timeoutSeconds: 5
  failureThreshold: 3
  successThreshold: 1

readinessProbe:
  enabled: true
  initialDelaySeconds: 5
  periodSeconds: 5
  timeoutSeconds: 3
  failureThreshold: 3
  successThreshold: 1

# Node selection
nodeSelector: {}

# Tolerations for pod assignment
tolerations: []

# Affinity rules
affinity: {}

# Additional environment variables
env:
  - name: PODINFO_UI_MESSAGE   # shown by podinfo on its start page and in the JSON response
    value: "Hello from Helm"

# ConfigMap data
configMap:
  enabled: false
  data: {}

# Secret data
secret:
  enabled: false
  data: {}

# Redis subchart configuration
redis:
  enabled: false
  auth:
    enabled: true
    password: "changeme"
```

### Creating Advanced Templates

Let's create sophisticated templates that handle various scenarios:

```yaml
# webapp-chart/templates/deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ include "webapp-chart.fullname" . }}
  labels:
    {{- include "webapp-chart.labels" . | nindent 4 }}
  annotations:
    checksum/config: {{ include (print $.Template.BasePath "/configmap.yaml") . | sha256sum }}
    checksum/secret: {{ include (print $.Template.BasePath "/secret.yaml") . | sha256sum }}
spec:
  {{- if not .Values.autoscaling.enabled }}
  replicas: {{ .Values.replicaCount }}
  {{- end }}
  revisionHistoryLimit: 10
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0
  selector:
    matchLabels:
      {{- include "webapp-chart.selectorLabels" . | nindent 6 }}
  template:
    metadata:
      annotations:
        checksum/config: {{ include (print $.Template.BasePath "/configmap.yaml") . | sha256sum }}
        checksum/secret: {{ include (print $.Template.BasePath "/secret.yaml") . | sha256sum }}
        prometheus.io/scrape: "true"
        prometheus.io/port: {{ .Values.service.targetPort | quote }}
      labels:
        {{- include "webapp-chart.selectorLabels" . | nindent 8 }}
        version: {{ .Values.image.tag | quote }}
    spec:
      {{- with .Values.image.pullSecrets }}
      imagePullSecrets:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      serviceAccountName: {{ include "webapp-chart.serviceAccountName" . }}
      securityContext:
        {{- toYaml .Values.podSecurityContext | nindent 8 }}
      containers:
        - name: {{ .Chart.Name }}
          securityContext:
            {{- toYaml .Values.securityContext | nindent 12 }}
          image: "{{ .Values.image.registry }}/{{ .Values.image.repository }}:{{ .Values.image.tag | default .Chart.AppVersion }}"
          command: ["./podinfo", "--port={{ .Values.service.targetPort }}", "--level=info"]
          imagePullPolicy: {{ .Values.image.pullPolicy }}
          ports:
            - name: http
              containerPort: {{ .Values.service.targetPort }}
              protocol: TCP
          {{- if .Values.livenessProbe.enabled }}
          livenessProbe:
            httpGet:
              path: /healthz
              port: http
            initialDelaySeconds: {{ .Values.livenessProbe.initialDelaySeconds }}
            periodSeconds: {{ .Values.livenessProbe.periodSeconds }}
            timeoutSeconds: {{ .Values.livenessProbe.timeoutSeconds }}
            failureThreshold: {{ .Values.livenessProbe.failureThreshold }}
            successThreshold: {{ .Values.livenessProbe.successThreshold }}
          {{- end }}
          {{- if .Values.readinessProbe.enabled }}
          readinessProbe:
            httpGet:
              path: /readyz
              port: http
            initialDelaySeconds: {{ .Values.readinessProbe.initialDelaySeconds }}
            periodSeconds: {{ .Values.readinessProbe.periodSeconds }}
            timeoutSeconds: {{ .Values.readinessProbe.timeoutSeconds }}
            failureThreshold: {{ .Values.readinessProbe.failureThreshold }}
            successThreshold: {{ .Values.readinessProbe.successThreshold }}
          {{- end }}
          resources:
            {{- toYaml .Values.resources | nindent 12 }}
          env:
            - name: POD_NAME
              valueFrom:
                fieldRef:
                  fieldPath: metadata.name
            - name: POD_NAMESPACE
              valueFrom:
                fieldRef:
                  fieldPath: metadata.namespace
            - name: POD_IP
              valueFrom:
                fieldRef:
                  fieldPath: status.podIP
            {{- range .Values.env }}
            - name: {{ .name }}
              value: {{ .value | quote }}
            {{- end }}
          {{- if or .Values.persistence.enabled .Values.configMap.enabled }}
          volumeMounts:
            {{- if .Values.persistence.enabled }}
            - name: data
              mountPath: {{ .Values.persistence.mountPath }}
            {{- end }}
            {{- if .Values.configMap.enabled }}
            - name: config
              mountPath: /etc/config
              readOnly: true
            {{- end }}
          {{- end }}
      {{- if or .Values.persistence.enabled .Values.configMap.enabled }}
      volumes:
        {{- if .Values.persistence.enabled }}
        - name: data
          persistentVolumeClaim:
            claimName: {{ include "webapp-chart.fullname" . }}
        {{- end }}
        {{- if .Values.configMap.enabled }}
        - name: config
          configMap:
            name: {{ include "webapp-chart.fullname" . }}
        {{- end }}
      {{- end }}
      {{- with .Values.nodeSelector }}
      nodeSelector:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- with .Values.affinity }}
      affinity:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- with .Values.tolerations }}
      tolerations:
        {{- toYaml . | nindent 8 }}
      {{- end }}
```

### Creating Helper Templates

Helper templates provide reusable functions:

```yaml
# webapp-chart/templates/_helpers.tpl
{{/*
Expand the name of the chart.
*/}}
{{- define "webapp-chart.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "webapp-chart.fullname" -}}
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
Create chart name and version as used by the chart label.
*/}}
{{- define "webapp-chart.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "webapp-chart.labels" -}}
helm.sh/chart: {{ include "webapp-chart.chart" . }}
{{ include "webapp-chart.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: {{ include "webapp-chart.name" . }}
environment: {{ .Values.global.environment }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "webapp-chart.selectorLabels" -}}
app.kubernetes.io/name: {{ include "webapp-chart.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "webapp-chart.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "webapp-chart.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}
```

### Additional Templates

Create supporting resource templates:

```yaml
# webapp-chart/templates/service.yaml
apiVersion: v1
kind: Service
metadata:
  name: {{ include "webapp-chart.fullname" . }}
  labels:
    {{- include "webapp-chart.labels" . | nindent 4 }}
  {{- with .Values.service.annotations }}
  annotations:
    {{- toYaml . | nindent 4 }}
  {{- end }}
spec:
  type: {{ .Values.service.type }}
  ports:
    - port: {{ .Values.service.port }}
      targetPort: http
      protocol: TCP
      name: http
      {{- if and (eq .Values.service.type "NodePort") .Values.service.nodePort }}
      nodePort: {{ .Values.service.nodePort }}
      {{- end }}
  {{- if and (eq .Values.service.type "LoadBalancer") .Values.service.loadBalancerIP }}
  loadBalancerIP: {{ .Values.service.loadBalancerIP }}
  {{- end }}
  selector:
    {{- include "webapp-chart.selectorLabels" . | nindent 4 }}
```

```yaml
# webapp-chart/templates/hpa.yaml
{{- if .Values.autoscaling.enabled }}
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: {{ include "webapp-chart.fullname" . }}
  labels:
    {{- include "webapp-chart.labels" . | nindent 4 }}
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: {{ include "webapp-chart.fullname" . }}
  minReplicas: {{ .Values.autoscaling.minReplicas }}
  maxReplicas: {{ .Values.autoscaling.maxReplicas }}
  metrics:
    {{- if .Values.autoscaling.targetCPUUtilizationPercentage }}
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: {{ .Values.autoscaling.targetCPUUtilizationPercentage }}
    {{- end }}
    {{- if .Values.autoscaling.targetMemoryUtilizationPercentage }}
    - type: Resource
      resource:
        name: memory
        target:
          type: Utilization
          averageUtilization: {{ .Values.autoscaling.targetMemoryUtilizationPercentage }}
    {{- end }}
{{- end }}
```

```yaml
# webapp-chart/templates/configmap.yaml
{{- if .Values.configMap.enabled }}
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ include "webapp-chart.fullname" . }}
  labels:
    {{- include "webapp-chart.labels" . | nindent 4 }}
data:
  {{- toYaml .Values.configMap.data | nindent 2 }}
{{- end }}
```

```yaml
# webapp-chart/templates/secret.yaml (referenced by the checksum/secret annotation)
{{- if .Values.secret.enabled }}
apiVersion: v1
kind: Secret
metadata:
  name: {{ include "webapp-chart.fullname" . }}
  labels:
    {{- include "webapp-chart.labels" . | nindent 4 }}
type: Opaque
stringData:
  {{- toYaml .Values.secret.data | nindent 2 }}
{{- end }}
```

```yaml
# webapp-chart/templates/pvc.yaml (referenced by the deployment when persistence.enabled=true)
{{- if .Values.persistence.enabled }}
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: {{ include "webapp-chart.fullname" . }}
  labels:
    {{- include "webapp-chart.labels" . | nindent 4 }}
  {{- with .Values.persistence.annotations }}
  annotations:
    {{- toYaml . | nindent 4 }}
  {{- end }}
spec:
  accessModes:
    - {{ .Values.persistence.accessMode }}
  {{- with (.Values.persistence.storageClass | default .Values.global.storageClass) }}
  storageClassName: {{ . }}
  {{- end }}
  resources:
    requests:
      storage: {{ .Values.persistence.size }}
{{- end }}
```

`helm create` also generated `templates/tests/test-connection.yaml`. It uses the unpinned `busybox` image - pin it
and let it check the health endpoint:

```yaml
# webapp-chart/templates/tests/test-connection.yaml
apiVersion: v1
kind: Pod
metadata:
  name: "{{ include "webapp-chart.fullname" . }}-test-connection"
  labels:
    {{- include "webapp-chart.labels" . | nindent 4 }}
  annotations:
    "helm.sh/hook": test
    "helm.sh/hook-delete-policy": before-hook-creation,hook-succeeded
spec:
  containers:
    - name: wget
      image: busybox:1.38
      command: ['wget']
      args: ['-qO-', '{{ include "webapp-chart.fullname" . }}:{{ .Values.service.port }}/healthz']
  restartPolicy: Never
```

The remaining generated files (`serviceaccount.yaml`, `ingress.yaml`, `httproute.yaml`, `NOTES.txt`) work unchanged
with the values above.

### Testing and Packaging Charts

```bash
# Download declared dependencies (redis) into webapp-chart/charts/ - required even if redis.enabled=false
helm dependency update webapp-chart

# Validate chart syntax and structure
helm lint webapp-chart

# Test template rendering with default values
helm template test-release webapp-chart

# Test with custom values
helm template test-release webapp-chart --set replicaCount=5

# Render a single template only
helm template test-release webapp-chart -s templates/deployment.yaml

# Debug template rendering
helm template test-release webapp-chart --debug

# Perform a dry run installation (--dry-run=server also validates the objects against the API server)
helm install test-release webapp-chart --dry-run=server

# Install the chart and wait until all Pods are ready
helm install my-webapp webapp-chart --wait --timeout 3m

# Run the test hook (the test-connection Pod)
helm test my-webapp
```

Expected (trimmed):

```
NAME: my-webapp
...
TEST SUITE:     my-webapp-webapp-chart-test-connection
...
Phase:          Succeeded
```

Now enable the optional parts of the chart. The `httpRoute` values point to a shared Gateway - create it once
(NGINX Gateway Fabric gives it an address from the MetalLB pool):

```bash
kubectl create namespace shared-gateway
kubectl apply -f - <<'EOF'
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
        from: All      # HTTPRoutes from every namespace may attach
EOF
kubectl -n shared-gateway wait gateway/shared-gateway --for=condition=Programmed --timeout=2m
GW_IP=$(kubectl -n shared-gateway get gateway shared-gateway -o jsonpath='{.status.addresses[0].value}'); echo $GW_IP
```

```bash
cat > webapp-prod-values.yaml <<'EOF'
replicaCount: 3
global:
  environment: production
httpRoute:
  enabled: true
  hostnames:
  - webapp.example.com
configMap:
  enabled: true
  data:
    app.properties: |
      feature.newCheckout=true
secret:
  enabled: true
  data:
    API_KEY: "s3cr3t"
env:
  - name: PODINFO_UI_MESSAGE
    value: "Hello from Helm (production values)"
EOF

helm upgrade my-webapp webapp-chart -f webapp-prod-values.yaml --wait

kubectl get deploy,svc,httproute,configmap,secret -l app.kubernetes.io/instance=my-webapp
kubectl exec deploy/my-webapp-webapp-chart -- cat /etc/config/app.properties
```

From the client VM (it is in the cluster network and can reach the Gateway address; use the `GW_IP` printed above):

```bash
curl -s -H 'Host: webapp.example.com' http://<GW_IP>/ | grep message
```

Expected:

```
  "message": "Hello from Helm (production values)",
```

Changing ConfigMap or Secret values changes the `checksum/*` annotations in the Pod template, so Helm triggers a
rolling update automatically. Note that `helm upgrade` without `-f`/`--reuse-values` would reset all values to the
chart defaults - always pass the full set of values (or use `--reset-then-reuse-values`). ConfigMap data must be
strings: `--set configMap.data.extra=1` would pass the number `1` and Helm 4 (which uses server-side apply) rejects it
with `.data.extra: expected string`, so use `--set-string`:

```bash
helm upgrade my-webapp webapp-chart -f webapp-prod-values.yaml --set-string configMap.data.extra=1 --wait
helm history my-webapp
helm get values my-webapp
```

Package the chart for distribution:

```bash
# Package the chart (creates webapp-chart-1.0.0.tgz)
helm package webapp-chart

# Create an index file for a classic HTTP chart repository
helm repo index . --url https://charts.example.com
cat index.yaml

# Packages can be rendered/installed directly
helm template from-package webapp-chart-1.0.0.tgz | head -20
```

Modern registries store charts as OCI artifacts (`helm push webapp-chart-1.0.0.tgz oci://<registry>/<project>`,
`helm install x oci://<registry>/<project>/webapp-chart --version 1.0.0`) - the same way the redis dependency above
is pulled from `oci://registry-1.docker.io/bitnamicharts`.

### Cleaning up the Helm workshop

```bash
helm uninstall my-webapp
helm uninstall configured-nginx versioned-nginx
helm uninstall -n web-apps namespaced-nginx
helm uninstall my-web-server          # removes the history kept by --keep-history
kubectl delete namespace web-apps
# keep the shared-gateway namespace - the Kustomize workshop below uses it, too
```

## Kustomize: Configuration Management Without Templates

Kustomize offers a different approach to configuration management. Instead of using templates, it works with plain Kubernetes YAML files and applies patches and overlays to customize them for different environments.

### The Kustomize Philosophy

Kustomize follows several key principles that differentiate it from Helm:

Declarative Configuration  
All configurations are expressed as Kubernetes resources. There's no templating language to learn, and all files are valid Kubernetes YAML that can be applied directly.

Composition Over Inheritance  
Rather than inheriting from parent configurations, Kustomize composes final configurations by combining multiple sources and applying transformations.

Patch-Based Customization  
Environment-specific changes are expressed as patches that modify the base configuration. This makes it clear what changes between environments.

Native Kubernetes Integration  
Kustomize is built into kubectl, requiring no additional tools. The `kubectl apply -k` command processes Kustomize directories directly.

### When Kustomize Excels

Kustomize is particularly effective in several scenarios:

GitOps Workflows  
Since all configurations are plain YAML files, Git diffs clearly show what changed. There's no need to render templates to understand modifications.

Simple Configuration Variations  
When differences between environments are straightforward (replica counts, resource limits, image tags), Kustomize's patch approach is cleaner than templating.

Upstream Customization  
You can customize third-party Kubernetes configurations without modifying the original files, making it easy to track upstream changes.

## Workshop: Mastering Kustomize

Let's build a complete application configuration using Kustomize, demonstrating how to manage multiple environments effectively.

### Creating the Project Structure

```bash
# Create the directory structure
mkdir -p kustomize-app/{base,overlays/{development,staging,production},components/monitoring}
cd kustomize-app

# Final structure:
# kustomize-app/
# ├── base/                       # Base configuration shared by all environments
# │   ├── deployment.yaml
# │   ├── service.yaml
# │   ├── nginx.conf
# │   └── kustomization.yaml
# ├── components/                 # Reusable, optional pieces of configuration
# │   └── monitoring/
# │       └── kustomization.yaml
# └── overlays/                   # Environment-specific configurations
#     ├── development/
#     │   ├── kustomization.yaml
#     │   └── deployment-patch.yaml
#     ├── staging/
#     │   ├── kustomization.yaml
#     │   ├── service-patch.yaml
#     │   ├── httproute.yaml
#     │   └── kustomizeconfig.yaml
#     └── production/
#         ├── kustomization.yaml
#         ├── hpa.yaml
#         ├── pdb.yaml
#         ├── httproute.yaml
#         └── kustomizeconfig.yaml
```

All file names below are relative to the `kustomize-app/` directory.

### Building the Base Configuration

Create the foundational resources that will be shared across all environments:

```yaml
# base/deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: webapp
  labels:
    app: webapp
    component: frontend
spec:
  replicas: 1
  selector:
    matchLabels:
      app: webapp
      component: frontend
  template:
    metadata:
      labels:
        app: webapp
        component: frontend
    spec:
      containers:
      - name: webapp
        image: nginx:1.31-alpine
        ports:
        - name: http
          containerPort: 80
          protocol: TCP
        env:
        - name: ENVIRONMENT
          valueFrom:
            configMapKeyRef:
              name: webapp-config
              key: environment
        - name: LOG_LEVEL
          valueFrom:
            configMapKeyRef:
              name: webapp-config
              key: log.level
        - name: API_KEY
          valueFrom:
            secretKeyRef:
              name: webapp-secret
              key: api-key
        resources:
          requests:
            cpu: 50m
            memory: 64Mi
          limits:
            cpu: 100m
            memory: 128Mi
        livenessProbe:
          httpGet:
            path: /health
            port: http
          initialDelaySeconds: 10
          periodSeconds: 10
        readinessProbe:
          httpGet:
            path: /health
            port: http
          initialDelaySeconds: 5
          periodSeconds: 5
        volumeMounts:
        - name: config
          mountPath: /etc/nginx/conf.d
          readOnly: true
      volumes:
      - name: config
        configMap:
          name: webapp-config
          items:
          - key: nginx.conf
            path: default.conf
```

```yaml
# base/service.yaml
apiVersion: v1
kind: Service
metadata:
  name: webapp-service
  labels:
    app: webapp
    component: frontend
spec:
  type: ClusterIP
  selector:
    app: webapp
    component: frontend
  ports:
  - name: http
    port: 80
    targetPort: http
    protocol: TCP
```

The NGINX configuration is kept as a plain file - Kustomize turns it into a ConfigMap:

```nginx
# base/nginx.conf
server {
    listen 80;
    server_name _;

    location / {
        root   /usr/share/nginx/html;
        index  index.html index.htm;
        try_files $uri $uri/ =404;
    }

    location /health {
        access_log off;
        default_type text/plain;
        return 200 "healthy\n";
    }

    # NGINX status counters, read by the metrics exporter of the monitoring component
    location /stub_status {
        stub_status;
        access_log off;
        allow 127.0.0.1;
        deny all;
    }
}
```

```yaml
# base/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
- deployment.yaml
- service.yaml

# generated objects get a content-hash name suffix (webapp-config-<hash>) and all references
# to them are rewritten, so every configuration change rolls out new Pods automatically
configMapGenerator:
- name: webapp-config
  files:
  - nginx.conf
  literals:
  - environment=base
  - log.level=info
  - app.name=webapp

secretGenerator:
- name: webapp-secret
  literals:
  - api-key=base-api-key
  - database-password=base-password

labels:  # replaces the deprecated commonLabels field
- includeSelectors: true
  pairs:
    app.kubernetes.io/name: webapp
    app.kubernetes.io/component: application
    app.kubernetes.io/managed-by: kustomize

commonAnnotations:
  version: "1.0.0"
```

`includeSelectors: true` adds the labels to selectors too (Deployment, Service, PDB...). Selectors of a Deployment are
immutable - never change such labels for an application that is already deployed.

Check that the base renders and is valid on its own:

```bash
kubectl kustomize base
kubectl apply -k base --dry-run=server
```

### Development Environment Overlay

Configure the development environment with debugging features and minimal resources:

```yaml
# overlays/development/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

namespace: development

resources:
- ../../base

namePrefix: dev-

labels:
- includeSelectors: true
  pairs:
    environment: development
    tier: frontend

commonAnnotations:
  environment: "development"

replicas:
- name: webapp
  count: 1

images:
- name: nginx
  newTag: 1.31-alpine

configMapGenerator:
- name: webapp-config
  behavior: merge          # merge these keys into the base ConfigMap
  literals:
  - environment=development
  - log.level=debug
  - debug.enabled=true
  - feature.flags=experimental

secretGenerator:
- name: webapp-secret
  behavior: replace        # replace the whole base Secret
  literals:
  - api-key=dev-api-key-12345
  - database-password=dev-password

patches:
# JSON 6902 patch - precise operations on paths
- target:
    kind: Deployment
    name: webapp
  patch: |-
    - op: replace
      path: /spec/template/spec/containers/0/resources/requests/cpu
      value: "25m"
    - op: replace
      path: /spec/template/spec/containers/0/resources/requests/memory
      value: "32Mi"
    - op: add
      path: /spec/template/spec/containers/0/env/-
      value:
        name: DEBUG
        value: "true"
# Strategic merge patch from a file (replaces the deprecated patchesStrategicMerge field)
- path: deployment-patch.yaml
```

```yaml
# overlays/development/deployment-patch.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: webapp
spec:
  template:
    spec:
      containers:
      - name: webapp       # containers are merged by name, env entries by their name
        env:
        - name: DEV_MODE
          value: "enabled"
        - name: VERBOSE_LOGGING
          value: "true"
```

`behavior: merge` and `behavior: replace` work on objects generated by the base generators. The result again gets
a content hash suffix (`dev-webapp-config-<hash>`) and every reference in the Deployment is rewritten to the new
name. A configuration change therefore creates a new ConfigMap name, which changes the Pod template and triggers a
rolling update. (If the base contained a plain `ConfigMap` manifest instead, the merged object would keep its name
without a hash and a change would **not** restart the Pods.)

### Staging Environment Overlay

Staging mirrors production more closely and is exposed through the shared Gateway created in the Helm workshop
(`shared-gateway` in namespace `shared-gateway`; create it now if you skipped that part).

```yaml
# overlays/staging/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

namespace: staging

resources:
- ../../base
- httproute.yaml

namePrefix: staging-

labels:
- includeSelectors: true
  pairs:
    environment: staging
    tier: frontend

replicas:
- name: webapp
  count: 2

configMapGenerator:
- name: webapp-config
  behavior: merge
  literals:
  - environment=staging
  - log.level=warning
  - cache.enabled=true
  - cache.ttl=300

secretGenerator:
- name: webapp-secret
  behavior: replace
  literals:
  - api-key=staging-api-key-67890
  - database-password=staging-secure-pass

patches:
- target:
    kind: Deployment
    name: webapp
  patch: |-
    - op: replace
      path: /spec/template/spec/containers/0/resources/requests/cpu
      value: "100m"
    - op: replace
      path: /spec/template/spec/containers/0/resources/requests/memory
      value: "128Mi"
    - op: replace
      path: /spec/template/spec/containers/0/resources/limits/cpu
      value: "250m"
    - op: replace
      path: /spec/template/spec/containers/0/resources/limits/memory
      value: "256Mi"
- path: service-patch.yaml

# teach Kustomize that HTTPRoute backendRefs point to Services (see below)
configurations:
- kustomizeconfig.yaml
```

```yaml
# overlays/staging/service-patch.yaml
apiVersion: v1
kind: Service
metadata:
  name: webapp-service
spec:
  type: NodePort
  ports:
  - name: http
    port: 80
    protocol: TCP      # required: Service ports are merged by (port, protocol)
    targetPort: http
    nodePort: 31000
```

> Service ports are a list merged by the key pair `port` + `protocol`. Without `protocol: TCP` in the patch,
> Kustomize does not match the entry from the base and silently drops `nodePort` (the API server then picks a random
> port). Always repeat the full merge key in strategic merge patches.

```yaml
# overlays/staging/httproute.yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: webapp
spec:
  parentRefs:
  - name: shared-gateway
    namespace: shared-gateway
    sectionName: http
  hostnames:
  - staging.webapp.example.com
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /
    backendRefs:
    - name: webapp-service      # rewritten to staging-webapp-service by Kustomize
      port: 80
```

Kustomize knows which fields of built-in kinds reference other objects (e.g. `configMapKeyRef.name` in a
Deployment), so `namePrefix` and the generators rewrite them. It does **not** know CRDs like `HTTPRoute`: without help
the route would keep pointing to `webapp-service`, which does not exist in the `staging` namespace. A
`configurations` file adds that knowledge:

```yaml
# overlays/staging/kustomizeconfig.yaml
nameReference:
- kind: Service
  fieldSpecs:
  - kind: HTTPRoute
    path: spec/rules/backendRefs/name
```

### Production Environment Overlay

Configure production with high availability, autoscaling, a disruption budget and a pinned image:

```yaml
# overlays/production/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

namespace: production

resources:
- ../../base
- hpa.yaml
- pdb.yaml
- httproute.yaml

components:
- ../../components/monitoring

namePrefix: prod-

labels:
- includeSelectors: true
  pairs:
    environment: production
    tier: frontend
    criticality: high

replicas:
- name: webapp
  count: 3

images:
- name: nginx
  newTag: 1.31.8-alpine   # pin an exact version in production
  # digest: sha256:<real-image-digest>  # or pin a digest (overrides newTag)

configMapGenerator:
- name: webapp-config
  behavior: merge
  literals:
  - environment=production
  - log.level=error
  - cache.enabled=true
  - cache.ttl=3600
  - database.host=placeholder   # overwritten by the replacements below
  - database.name=placeholder
# connection data owned by the database team - the source of the replacements
- name: database-config
  literals:
  - host=postgres.databases.svc.cluster.local
  - name=webapp_prod

secretGenerator:
- name: webapp-secret
  behavior: replace
  literals:
  - api-key=prod-api-key-secure-xyz
  - database-password=prod-ultra-secure-pass

patches:
- target:
    kind: Deployment
    name: webapp
  patch: |-
    - op: replace
      path: /spec/template/spec/containers/0/resources/requests/cpu
      value: "200m"
    - op: replace
      path: /spec/template/spec/containers/0/resources/requests/memory
      value: "256Mi"
    - op: replace
      path: /spec/template/spec/containers/0/resources/limits/cpu
      value: "500m"
    - op: replace
      path: /spec/template/spec/containers/0/resources/limits/memory
      value: "512Mi"
    - op: add
      path: /spec/template/spec/affinity
      value:
        podAntiAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
          - weight: 100
            podAffinityTerm:
              labelSelector:
                matchLabels:
                  app: webapp
                  environment: production
              topologyKey: kubernetes.io/hostname

# copy values from one object into another (replaces the deprecated "vars")
replacements:
- source:
    kind: ConfigMap
    name: database-config
    fieldPath: data.host
  targets:
  - select:
      kind: ConfigMap
      name: webapp-config
    fieldPaths:
    - data.[database.host]
- source:
    kind: ConfigMap
    name: database-config
    fieldPath: data.name
  targets:
  - select:
      kind: ConfigMap
      name: webapp-config
    fieldPaths:
    - data.[database.name]

configurations:
- kustomizeconfig.yaml
```

```yaml
# overlays/production/hpa.yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: webapp-hpa
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: webapp           # rewritten to prod-webapp by Kustomize
  minReplicas: 3
  maxReplicas: 10
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: 70
  - type: Resource
    resource:
      name: memory
      target:
        type: Utilization
        averageUtilization: 80
  behavior:
    scaleDown:
      stabilizationWindowSeconds: 300
      policies:
      - type: Percent
        value: 50
        periodSeconds: 60
    scaleUp:
      stabilizationWindowSeconds: 0
      policies:
      - type: Percent
        value: 100
        periodSeconds: 30
```

```yaml
# overlays/production/pdb.yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: webapp-pdb
spec:
  minAvailable: 2
  selector:
    matchLabels:
      app: webapp          # Kustomize adds the common labels (includeSelectors) here as well
```

```yaml
# overlays/production/httproute.yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: webapp
spec:
  parentRefs:
  - name: shared-gateway
    namespace: shared-gateway
    sectionName: http
  hostnames:
  - webapp.example.com
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /
    backendRefs:
    - name: webapp-service
      port: 80
```

```yaml
# overlays/production/kustomizeconfig.yaml
nameReference:
- kind: Service
  fieldSpecs:
  - kind: HTTPRoute
    path: spec/rules/backendRefs/name
```

For HTTPS terminate TLS on the Gateway (a `HTTPS` listener with a certificate Secret - see module 08); the route
itself does not change.

#### The monitoring component

Components are reusable pieces of configuration that an overlay can opt into (production does, development does
not). This one adds the official NGINX Prometheus exporter as a sidecar - it reads `/stub_status` from the base
`nginx.conf` and exposes Prometheus metrics on port 9113:

```yaml
# components/monitoring/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1alpha1
kind: Component

patches:
# strategic merge patch: annotations are merged into the existing map,
# the new container is added to the list (containers are merged by name)
- target:
    kind: Deployment
    name: webapp
  patch: |-
    apiVersion: apps/v1
    kind: Deployment
    metadata:
      name: webapp
    spec:
      template:
        metadata:
          annotations:
            prometheus.io/scrape: "true"
            prometheus.io/port: "9113"
        spec:
          containers:
          - name: nginx-exporter
            image: nginx/nginx-prometheus-exporter:1.5.3
            args:
            - --nginx.scrape-uri=http://127.0.0.1:80/stub_status
            ports:
            - name: metrics
              containerPort: 9113
            resources:
              requests:
                cpu: 10m
                memory: 16Mi
              limits:
                cpu: 50m
                memory: 32Mi
```

### Deploying with Kustomize

```bash
# Preview what will be deployed for each environment
kubectl kustomize overlays/development/
kubectl kustomize overlays/staging/
kubectl kustomize overlays/production/

# Compare two environments
diff <(kubectl kustomize overlays/staging) <(kubectl kustomize overlays/production)

# The overlays set "namespace:", but do not create the namespaces
kubectl create namespace development
kubectl create namespace staging
kubectl create namespace production

# Deploy to development
kubectl apply -k overlays/development/

# Deploy to staging
kubectl apply -k overlays/staging/

# Deploy to production
kubectl apply -k overlays/production/

# View deployed resources in each environment
kubectl get all -n development -l environment=development
kubectl get all,httproute,pdb -n staging -l environment=staging
kubectl get all,httproute,pdb -n production -l environment=production
```

Verify the result:

```bash
# generated names with hash suffixes and the values merged by the generators
kubectl -n development get configmap,secret
kubectl -n development exec deploy/dev-webapp -- env | grep -E 'ENVIRONMENT|LOG_LEVEL|API_KEY|DEBUG|DEV_MODE'

# replacements: values copied from database-config
kubectl -n production get configmap -l environment=production \
  -o jsonpath='{range .items[*]}{.metadata.name}: {.data.database\.host} {.data.database\.name}{"\n"}{end}'

# HTTPRoute backendRefs rewritten by the nameReference configuration
kubectl -n production get httproute prod-webapp -o jsonpath='{.spec.rules[0].backendRefs[0].name}{"\n"}'

# exporter sidecar from the monitoring component (2 containers per Pod)
kubectl -n production get pods
# (the exporter image has no shell tools; containers of a Pod share the network, so ask from the nginx container)
kubectl -n production exec deploy/prod-webapp -c webapp -- wget -qO- http://127.0.0.1:9113/metrics | grep nginx_up
```

Expected (trimmed):

```
ENVIRONMENT=development
LOG_LEVEL=debug
API_KEY=dev-api-key-12345
DEBUG=true
DEV_MODE=enabled
...
prod-database-config-49k7g6c55f:
prod-webapp-config-5g9ckb4556: postgres.databases.svc.cluster.local webapp_prod
...
prod-webapp-service
...
nginx_up 1
```

Test the routes from the client VM (`<GW_IP>` is the address of `shared-gateway`) and the staging NodePort:

```bash
curl -s -H 'Host: staging.webapp.example.com' http://<GW_IP>/health
curl -s -H 'Host: webapp.example.com' http://<GW_IP>/health
curl -s http://192.168.1.11:31000/health
```

Every command prints `healthy`.

Change the configuration and redeploy - the new ConfigMap hash triggers a rolling update:

```bash
sed -i 's/log.level=debug/log.level=trace/' overlays/development/kustomization.yaml
kubectl apply -k overlays/development/
kubectl -n development rollout status deploy/dev-webapp
kubectl -n development get configmap      # the old ConfigMap is still there (kubectl apply does not prune it)
```

### Clean up the Kustomize workshop

```bash
kubectl delete -k overlays/development/
kubectl delete -k overlays/staging/
kubectl delete -k overlays/production/
kubectl delete namespace development staging production
kubectl delete namespace shared-gateway
cd ..
```

## Comparing Helm and Kustomize

Both tools solve configuration management but with different approaches and trade-offs.

### Feature Comparison

|Aspect|Helm|Kustomize|
|---|---|---|
|Philosophy|Package manager with templates|Configuration overlay system|
|Learning Curve|Moderate (Go templates)|Low (plain YAML)|
|Installation|Separate CLI tool|Built into kubectl|
|Configuration Method|Templates with values|Base plus patches|
|Package Distribution|Chart repositories|Git repositories|
|Release Management|Built-in versioning and rollback|External tooling needed|
|Dependency Management|Native chart dependencies|Manual composition|
|Community Ecosystem|Extensive chart library|Growing adoption|
|Dry Run Capability|Native support|Native support|
|Secret Management|Values files (caution needed)|SecretGenerator (still plain base64 in the cluster)|
|Debugging|Template rendering can be complex|Straightforward YAML|

### Decision Framework

Choose Helm When:

- You need sophisticated templating with conditional logic
- Managing third-party applications from public repositories
- Release management with versioning and rollbacks is critical
- Your team is comfortable with Go templates
- You need dependency management between charts
- Distributing applications to external users

Choose Kustomize When:

- You prefer working with plain Kubernetes YAML
- Git-based workflows and clear diffs are important
- Configuration differences between environments are straightforward
- You want to customize upstream configurations without forking
- Built-in kubectl integration is valuable
- Your team is new to Kubernetes configuration management

Consider Using Both: Many organizations use both tools for different purposes. Helm for third-party applications and complex internal services, Kustomize for environment-specific configuration management. You can even use Helm to generate base configurations and Kustomize to customize them per environment.

## Best Practices for Package Management

### General Best Practices

Version Everything  
Track all configurations in version control. Tag releases and maintain clear commit messages describing changes.

Separate Configuration from Code  
Keep application images separate from configuration. Use image tags or digests to reference specific versions.

Use Namespaces  
Deploy different environments to separate namespaces. This provides isolation and makes management easier.

Implement GitOps  
Use Git as the source of truth for your configurations. Tools like Argo CD or Flux can automatically sync Git repositories with your clusters (see module 16).

Security First  
Never commit secrets to Git. Use sealed-secrets, external-secrets, or cloud provider secret management solutions.

### Helm Best Practices

Chart Development

- Keep charts simple and focused on a single application
- Provide comprehensive default values with documentation
- Use semantic versioning for charts and applications
- Include NOTES.txt to guide users after installation
- Test charts across different Kubernetes versions

Values Management

- Document all values in values.yaml with comments
- Use `values.schema.json` for validation
- Keep environment-specific values in separate files
- Never put secrets directly in values files

Template Best Practices

- Use helper templates to avoid repetition
- Include proper labels and annotations
- Make resource names predictable and consistent
- Handle optional features with conditional blocks

### Kustomize Best Practices

Structure Organization

- Keep base configurations minimal and environment-agnostic
- Use overlays for all environment-specific changes
- Organize components for reusable functionality
- Maintain clear directory structures

Patch Management

- Prefer strategic merge patches over JSON patches when possible
- Keep patches small and focused
- Document why patches are needed
- Test patches across all environments

Configuration Generation

- Use ConfigMapGenerator and SecretGenerator instead of static files
- Use `replacements` (not the deprecated `vars`) to copy values between objects
- Teach Kustomize about references in CRDs (e.g. HTTPRoute `backendRefs`) with `configurations`
- Prefer `labels` / `patches` over the deprecated `commonLabels` / `patchesStrategicMerge` / `patchesJson6902`
