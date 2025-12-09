
## Understanding Ingress

### The External Access Challenge

While Services provide internal networking and basic external access through NodePort and LoadBalancer types, production applications require more sophisticated HTTP/HTTPS traffic management capabilities. These advanced requirements include routing based on URL paths and hostnames, SSL/TLS certificate management, authentication integration, and traffic control features like rate limiting.

Consider a typical scenario: you have multiple microservices that need to be accessible from the internet. Creating a LoadBalancer Service for each microservice would be expensive and inefficient, as each LoadBalancer typically provisions a cloud load balancer with its own public IP address. Additionally, LoadBalancer Services operate at Layer 4 (TCP/UDP), lacking the ability to inspect HTTP headers or perform content-based routing.

### What is Ingress?

Ingress is a Kubernetes API object that manages external HTTP and HTTPS access to services within a cluster. Operating at Layer 7 (application layer), Ingress provides intelligent routing capabilities that examine HTTP requests and make routing decisions based on hostnames, URL paths, headers, and other HTTP attributes.

The Ingress system consists of two main components working together:

1. Ingress Resource: A Kubernetes API object that declaratively defines routing rules using YAML manifests
2. Ingress Controller: A specialized pod that runs in your cluster, watches for Ingress resources, and implements the routing rules by configuring a load balancer or proxy

Think of the Ingress resource as a set of routing instructions, while the Ingress Controller is the actual software that reads these instructions and routes traffic accordingly. Without an Ingress Controller, Ingress resources have no effect.

## Installing and Configuring Ingress

### Installing NGINX Ingress Controller

The NGINX Ingress Controller is the most widely adopted controller. Here's how to install it:

```bash
# For cloud providers (AWS, GCP, Azure)
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.11.2/deploy/static/provider/cloud/deploy.yaml

# For bare metal clusters or local development
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.11.2/deploy/static/provider/baremetal/deploy.yaml

# Verify the controller is running
kubectl get pods -n ingress-nginx
kubectl get svc -n ingress-nginx

# Wait for the controller to be fully ready
kubectl wait --namespace ingress-nginx \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=120s
```

### Creating a Sample Application

First, deploy a simple application to demonstrate Ingress routing:

```yaml
# sample-app.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx-deployment
  namespace: default
spec:
  replicas: 3
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
        image: nginx:1.25-alpine
        ports:
        - containerPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: nginx-service
  namespace: default
spec:
  selector:
    app: nginx
  ports:
  - port: 80
    targetPort: 80
    protocol: TCP
  type: ClusterIP
```

Deploy the application:

```bash
kubectl apply -f sample-app.yaml

# Verify deployment
kubectl get deployment nginx-deployment
kubectl get service nginx-service
kubectl get endpoints nginx-service
```

### Basic Ingress Configuration

Create a basic Ingress resource:

```yaml
# basic-ingress.yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: basic-ingress
  namespace: default
spec:
  ingressClassName: nginx
  rules:
  - host: example.local
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: nginx-service
            port:
              number: 80
```

Apply and test the Ingress:

```bash
# Apply the Ingress
kubectl apply -f basic-ingress.yaml

# Check Ingress status
kubectl get ingress
kubectl describe ingress basic-ingress

# Test the Ingress (using port-forward for local testing)
kubectl port-forward -n ingress-nginx svc/ingress-nginx-controller 8080:80

# In another terminal, test with curl
curl -H "Host: example.local" http://localhost:8080
```

### Path-Based Routing

Create multiple services and route based on URL paths:

```yaml
# path-routing-ingress.yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: path-routing-ingress
  namespace: default
spec:
  ingressClassName: nginx
  rules:
  - host: app.local
    http:
      paths:
      - path: /api
        pathType: Prefix
        backend:
          service:
            name: api-service
            port:
              number: 80
      - path: /
        pathType: Prefix
        backend:
          service:
            name: web-service
            port:
              number: 80
```

### Host-Based Routing

Route different domains to different services:

```yaml
# host-routing-ingress.yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: host-routing-ingress
  namespace: default
spec:
  ingressClassName: nginx
  rules:
  - host: app1.local
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: app1-service
            port:
              number: 80
  - host: app2.local
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: app2-service
            port:
              number: 80
```

### HTTPS/TLS Configuration

Enable HTTPS with TLS certificates:

```bash
# Generate a self-signed certificate for testing
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout tls.key -out tls.crt \
  -subj "/CN=example.local/O=example"

# Create TLS secret
kubectl create secret tls example-tls --cert=tls.crt --key=tls.key

# Clean up certificate files
rm tls.key tls.crt
```

```yaml
# tls-ingress.yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: tls-ingress
  namespace: default
spec:
  ingressClassName: nginx
  tls:
  - hosts:
    - example.local
    secretName: example-tls
  rules:
  - host: example.local
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: nginx-service
            port:
              number: 80
```

Test HTTPS:

```bash
# Apply TLS Ingress
kubectl apply -f tls-ingress.yaml

# Port-forward HTTPS port
kubectl port-forward -n ingress-nginx svc/ingress-nginx-controller 8443:443

# Test HTTPS
curl -k -H "Host: example.local" https://localhost:8443
```

### URL Rewriting with Ingress

URL rewriting allows you to modify the request path before it reaches the backend service. This is useful when your external API structure differs from your internal service paths.

#### Simple URL Rewrite Example

The most common use case is removing a path prefix before forwarding to the backend:

```yaml
# url-rewrite-ingress.yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: rewrite-ingress
  namespace: default
  annotations:
    nginx.ingress.kubernetes.io/rewrite-target: /
spec:
  ingressClassName: nginx
  rules:
  - host: app.local
    http:
      paths:
      - path: /app
        pathType: Prefix
        backend:
          service:
            name: nginx-service
            port:
              number: 80
```

With this configuration:

- Request to `/app` → Backend receives `/`
- Request to `/app/page1` → Backend receives `/page1`
- Request to `/app/api/users` → Backend receives `/api/users`

#### URL Rewrite with Capture Groups

For more control, use regular expressions with capture groups:

```yaml
# capture-rewrite-ingress.yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: capture-rewrite-ingress
  namespace: default
  annotations:
    nginx.ingress.kubernetes.io/use-regex: "true"
    nginx.ingress.kubernetes.io/rewrite-target: /$2
spec:
  ingressClassName: nginx
  rules:
  - host: app.local
    http:
      paths:
      - path: /api(/|$)(.*)
        pathType: ImplementationSpecific
        backend:
          service:
            name: api-service
            port:
              number: 80
      - path: /web(/|$)(.*)
        pathType: ImplementationSpecific
        backend:
          service:
            name: web-service
            port:
              number: 80
```

This configuration:

- `/api/v1/users` → Backend receives `/v1/users`
- `/web/home` → Backend receives `/home`
- The `$2` refers to the second capture group `(.*)`

#### Testing URL Rewrites

```bash
# Apply the rewrite ingress
kubectl apply -f url-rewrite-ingress.yaml

# Test the rewrite
kubectl port-forward -n ingress-nginx svc/ingress-nginx-controller 8080:80

# Original path /app/test gets rewritten to /test
curl -H "Host: app.local" http://localhost:8080/app/test

# Original path /api/v1/users gets rewritten to /v1/users
curl -H "Host: app.local" http://localhost:8080/api/v1/users
```

## Gateway API: The Evolution of Ingress

### Understanding Gateway API

Gateway API represents the next evolution in Kubernetes traffic management. It addresses limitations of the Ingress API by providing a more expressive, extensible, and role-oriented approach to managing ingress traffic.

The key innovation of Gateway API is its role-oriented design with three main resource types:

1. GatewayClass: Defines a class of Gateways (similar to StorageClass for volumes)
2. Gateway: Represents the actual load balancer or proxy instance
3. HTTPRoute: Defines application-level routing rules

This separation allows infrastructure teams to manage Gateways while application teams manage HTTPRoutes.

### Gateway API vs Ingress Comparison

| Feature            | Ingress                       | Gateway API                             |
| ------------------ | ----------------------------- | --------------------------------------- |
| API Design         | Single resource               | Multiple role-based resources           |
| Expressiveness     | Limited, requires annotations | Rich, typed fields                      |
| Protocol Support   | HTTP/HTTPS only               | HTTP, TCP, UDP, gRPC                    |
| Role Separation    | Mixed responsibilities        | Clear infrastructure/app separation     |
| Traffic Management | Basic                         | Advanced (weights, header manipulation) |
| Cross-namespace    | Limited                       | Built-in with ReferenceGrants           |

## Installing and Configuring Gateway API

### Step 1: Install Gateway API CRDs

Gateway API resources are not included in Kubernetes by default:

```bash
# Install Gateway API CRDs
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.0/standard-install.yaml

# Verify CRD installation
kubectl get crd | grep gateway.networking.k8s.io

# Expected output:
# gatewayclasses.gateway.networking.k8s.io
# gateways.gateway.networking.k8s.io
# httproutes.gateway.networking.k8s.io
# referencegrants.gateway.networking.k8s.io
```

### Step 2: Install a Gateway Controller

For this example, we'll use NGINX Gateway Fabric:

```bash
# Add Helm repository
helm repo add ngf https://nginxinc.github.io/nginx-gateway-fabric
helm repo update

# Install NGINX Gateway Fabric
helm install ngf ngf/nginx-gateway-fabric \
  --create-namespace \
  --namespace nginx-gateway \
  --set service.type=NodePort

# Wait for controller to be ready
kubectl wait --for=condition=available --timeout=60s \
  deployment/ngf-nginx-gateway-fabric -n nginx-gateway

# Verify installation
kubectl get pods -n nginx-gateway
kubectl get gatewayclass
```

### Step 3: Create a Sample Application

Deploy a simple application for testing:

```yaml
# gateway-sample-app.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: hello-app
  namespace: default
spec:
  replicas: 3
  selector:
    matchLabels:
      app: hello
  template:
    metadata:
      labels:
        app: hello
    spec:
      containers:
      - name: nginx
        image: nginx:1.25-alpine
        ports:
        - containerPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: hello-service
  namespace: default
spec:
  selector:
    app: hello
  ports:
  - port: 80
    targetPort: 80
    protocol: TCP
```

```bash
kubectl apply -f gateway-sample-app.yaml

# Verify deployment
kubectl get deployment hello-app
kubectl get service hello-service
```

### Step 4: Create a Gateway

Define the Gateway resource:

```yaml
# basic-gateway.yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: example-gateway
  namespace: default
spec:
  gatewayClassName: nginx
  listeners:
  - name: http
    port: 80
    protocol: HTTP
    allowedRoutes:
      namespaces:
        from: Same
```

```bash
# Apply the Gateway
kubectl apply -f basic-gateway.yaml

# Check Gateway status
kubectl get gateway example-gateway
kubectl describe gateway example-gateway
```

### Step 5: Create an HTTPRoute

Define routing rules with HTTPRoute:

```yaml
# basic-httproute.yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: example-route
  namespace: default
spec:
  parentRefs:
  - name: example-gateway
    namespace: default
  hostnames:
  - "hello.example.com"
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /
    backendRefs:
    - name: hello-service
      port: 80
```

```bash
# Apply the HTTPRoute
kubectl apply -f basic-httproute.yaml

# Check HTTPRoute status
kubectl get httproute example-route
kubectl describe httproute example-route
```

### Testing Gateway API

```bash
# Get the Gateway service NodePort
GATEWAY_PORT=$(kubectl get svc -n nginx-gateway ngf-nginx-gateway-fabric \
  -o jsonpath='{.spec.ports[?(@.port==80)].nodePort}')

echo "Gateway is accessible on port: $GATEWAY_PORT"

# Test the routing
curl -H "Host: hello.example.com" http://localhost:$GATEWAY_PORT
```

### Path-Based Routing with Gateway API

```yaml
# gateway-path-routing.yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: path-route
  namespace: default
spec:
  parentRefs:
  - name: example-gateway
  hostnames:
  - "app.example.com"
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /api
    backendRefs:
    - name: api-service
      port: 80
  - matches:
    - path:
        type: PathPrefix
        value: /
    backendRefs:
    - name: web-service
      port: 80
```

### Traffic Splitting with Gateway API

Gateway API natively supports weighted traffic distribution:

```yaml
# gateway-traffic-split.yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: split-route
  namespace: default
spec:
  parentRefs:
  - name: example-gateway
  hostnames:
  - "split.example.com"
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /
    backendRefs:
    - name: service-v1
      port: 80
      weight: 90  # 90% of traffic
    - name: service-v2
      port: 80
      weight: 10  # 10% of traffic
```

## When to Use Ingress vs Gateway API

### Use Ingress When:

- Working with existing applications already using Ingress
- Need simple HTTP/HTTPS routing
- Team is familiar with Ingress patterns
- Using tools that only support Ingress

### Use Gateway API When:

- Starting new projects
- Need advanced traffic management features
- Require clear separation between infrastructure and application teams
- Working with multiple protocols (TCP, UDP, gRPC)
- Building multi-tenant platforms