
## Blue/Green Deployment Fundamentals

### Understanding Blue/Green Deployments

Blue/Green deployment is a release management strategy that maintains two complete, identical production environments. This approach eliminates deployment downtime and enables instant rollbacks by switching traffic between environments. At any given moment, only one environment (either Blue or Green) actively serves production traffic, while the other remains idle or serves as a staging environment for the next release.

The primary benefits of Blue/Green deployments include zero-downtime deployments, instant rollback capabilities, reduced risk during releases, and the ability to perform comprehensive testing in a production-like environment before switching traffic. This strategy is particularly valuable for applications where even brief downtime windows are unacceptable.

### Implementation Approaches

Kubernetes supports two primary methods for implementing Blue/Green deployments, each with distinct characteristics and use cases:

Service-based Blue/Green Deployment

This approach operates at the infrastructure level by modifying the Service selector to switch between Blue and Green deployments. The implementation is straightforward, requiring only a simple selector update. However, existing connections may experience disruption during the switch as the Service begins routing to different pods. This method works with any protocol and requires minimal configuration complexity.

Ingress-based Blue/Green Deployment

This approach manages traffic routing at the application layer through Ingress controllers. It provides smoother transitions with better connection handling, particularly for HTTP/HTTPS traffic. The Ingress controller can gracefully drain connections from the old version while routing new connections to the new version. However, this approach is limited to HTTP/HTTPS protocols and requires an Ingress controller installation.

### Workshop: Implementing Service-based Blue/Green

Let's implement a complete Blue/Green deployment using Service selectors. This exercise demonstrates the fundamental concepts and provides hands-on experience with the switching mechanism.

First, create the Blue deployment with its associated Service:

```yaml
# blue-deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: app-blue
  labels:
    app: myapp
    version: blue
spec:
  replicas: 3
  selector:
    matchLabels:
      app: myapp
      version: blue
  template:
    metadata:
      labels:
        app: myapp
        version: blue
    spec:
      containers:
      - name: app
        image: nginxdemos/hello:0.2
        ports:
        - containerPort: 80
        env:
        - name: VERSION
          value: "blue-1.0"
        - name: COLOR
          value: "blue"
        resources:
          requests:
            cpu: 50m
            memory: 64Mi
          limits:
            cpu: 100m
            memory: 128Mi
---
apiVersion: v1
kind: Service
metadata:
  name: app-service
spec:
  selector:
    app: myapp
    version: blue  # Service initially points to blue version
  ports:
  - port: 80
    targetPort: 80
    protocol: TCP
  type: ClusterIP
```

Deploy and verify the Blue environment:

```bash
# Deploy the blue version
kubectl apply -f blue-deployment.yaml

# Verify the deployment is running
kubectl get deployments -l version=blue
kubectl get pods -l version=blue

# Check Service endpoints to confirm it's pointing to blue pods
kubectl get endpoints app-service

# Test the blue version using a temporary pod
kubectl run test-blue --image=curlimages/curl:7.85.0 --rm -it --restart=Never -- \
  sh -c 'for i in $(seq 1 5); do curl -s http://app-service/ | grep -E "(Server name|Server address)"; echo "---"; done'
```

Now create the Green deployment (the new version to switch to):

```yaml
# green-deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: app-green
  labels:
    app: myapp
    version: green
spec:
  replicas: 3
  selector:
    matchLabels:
      app: myapp
      version: green
  template:
    metadata:
      labels:
        app: myapp
        version: green
    spec:
      containers:
      - name: app
        image: nginxdemos/hello:0.3
        ports:
        - containerPort: 80
        env:
        - name: VERSION
          value: "green-2.0"
        - name: COLOR
          value: "green"
        resources:
          requests:
            cpu: 50m
            memory: 64Mi
          limits:
            cpu: 100m
            memory: 128Mi
```

Deploy Green and perform the switch:

```bash
# Deploy the green version (runs alongside blue)
kubectl apply -f green-deployment.yaml

# Verify both versions are running simultaneously
kubectl get deployments -l app=myapp --show-labels
kubectl get pods -l app=myapp --show-labels

# Count pods by version
echo "Blue pods: $(kubectl get pods -l version=blue --no-headers | wc -l)"
echo "Green pods: $(kubectl get pods -l version=green --no-headers | wc -l)"

# Perform the Blue/Green switch by updating the Service selector
kubectl patch service app-service -p '{"spec":{"selector":{"version":"green"}}}'

# Verify the Service now points to green pods
kubectl get service app-service -o jsonpath='{.spec.selector}' | jq .

# Check the new endpoints
kubectl get endpoints app-service

# Test that traffic now goes to green version
kubectl run test-green --image=curlimages/curl:7.85.0 --rm -it --restart=Never -- \
  sh -c 'for i in $(seq 1 5); do curl -s http://app-service/ | grep -E "(Server name|Server address)"; echo "---"; done'
```

### Rollback Procedures

One of the key advantages of Blue/Green deployment is the ability to instantly rollback if issues are detected:

```bash
# Quick rollback to blue if issues are found
kubectl patch service app-service -p '{"spec":{"selector":{"version":"blue"}}}'

# Verify rollback completed
kubectl get service app-service -o jsonpath='{.spec.selector.version}'
echo "Current active version: $(kubectl get service app-service -o jsonpath='{.spec.selector.version}')"

# Test to confirm traffic is back on blue
kubectl run test-rollback --image=curlimages/curl:7.85.0 --rm -it --restart=Never -- \
  curl -s http://app-service/ | grep VERSION

# After confirming green works correctly, clean up old blue deployment
# kubectl delete deployment app-blue
```

### Workshop: Ingress-based Blue/Green

For production environments with HTTP/HTTPS traffic, Ingress-based Blue/Green provides better traffic management. This approach requires an Ingress controller. If you don't have one installed, you can use NGINX Ingress Controller:

```bash
# Install NGINX Ingress Controller (if not already installed)
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.8.1/deploy/static/provider/cloud/deploy.yaml

# Wait for the controller to be ready
kubectl wait --namespace ingress-nginx \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=120s
```

Create separate Services for Blue and Green deployments:

```yaml
# blue-green-ingress.yaml
apiVersion: v1
kind: Service
metadata:
  name: app-blue-service
spec:
  selector:
    app: myapp
    version: blue
  ports:
  - port: 80
    targetPort: 80
    protocol: TCP
---
apiVersion: v1
kind: Service
metadata:
  name: app-green-service
spec:
  selector:
    app: myapp
    version: green
  ports:
  - port: 80
    targetPort: 80
    protocol: TCP
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: blue-green-ingress
  annotations:
    nginx.ingress.kubernetes.io/rewrite-target: /
spec:
  ingressClassName: nginx
  rules:
  - host: myapp.local
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: app-blue-service  # Initially pointing to blue
            port:
              number: 80
```

Test and switch using Ingress:

```bash
# Apply the Ingress configuration
kubectl apply -f blue-green-ingress.yaml

# Get the Ingress address (may take a moment to be assigned)
kubectl get ingress blue-green-ingress

# Test blue version through Ingress (replace INGRESS_IP with actual IP)
# For local testing, you can use port forwarding
kubectl port-forward -n ingress-nginx service/ingress-nginx-controller 8080:80 &

# Test with curl
curl -H "Host: myapp.local" http://localhost:8080/

# Switch Ingress to green version
kubectl patch ingress blue-green-ingress --type='json' \
  -p='[{"op": "replace", "path": "/spec/rules/0/http/paths/0/backend/service/name", "value":"app-green-service"}]'

# Verify the switch in Ingress configuration
kubectl get ingress blue-green-ingress -o jsonpath='{.spec.rules[0].http.paths[0].backend.service.name}'

# Test green version through Ingress
curl -H "Host: myapp.local" http://localhost:8080/

# Rollback to blue if needed
kubectl patch ingress blue-green-ingress --type='json' \
  -p='[{"op": "replace", "path": "/spec/rules/0/http/paths/0/backend/service/name", "value":"app-blue-service"}]'
```

## Canary Deployment Strategy

### Understanding Canary Deployments

Canary deployment is a progressive delivery strategy that gradually shifts traffic from a stable version to a new version. Named after the historical practice of using canaries in coal mines to detect toxic gases, this approach allows teams to test new releases with a small subset of users before full rollout. If issues arise, the impact is limited to a small percentage of users, and rollback is straightforward.

The key principle of Canary deployment is risk mitigation through gradual exposure. Instead of switching all traffic at once (as in Blue/Green), Canary deployments typically start by routing 5-10% of traffic to the new version, then progressively increase this percentage as confidence grows.

### Canary Implementation Strategies

Kubernetes supports multiple approaches for implementing Canary deployments:

Replica-based Canary: Uses the natural load balancing of Kubernetes Services across pods. By controlling the number of replicas for each version, you control the traffic distribution. This is simple but provides only approximate traffic splitting.

Ingress-based Canary: Uses Ingress controller features to precisely control traffic percentages. This provides exact traffic splitting and supports advanced routing based on headers, cookies, or other request attributes.

### Workshop: Replica-based Canary Deployment

This approach leverages Kubernetes' native Service load balancing. The Service selector matches both stable and canary pods, distributing traffic proportionally based on replica counts.

```yaml
# canary-deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: app-stable
  labels:
    app: myapp
    track: stable
spec:
  replicas: 9  # 90% of total pods (9 out of 10)
  selector:
    matchLabels:
      app: myapp
      track: stable
  template:
    metadata:
      labels:
        app: myapp
        track: stable
    spec:
      containers:
      - name: app
        image: nginxdemos/hello:0.2
        ports:
        - containerPort: 80
        env:
        - name: VERSION
          value: "stable-1.0"
        resources:
          requests:
            cpu: 50m
            memory: 64Mi
          limits:
            cpu: 100m
            memory: 128Mi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: app-canary
  labels:
    app: myapp
    track: canary
spec:
  replicas: 1  # 10% of total pods (1 out of 10)
  selector:
    matchLabels:
      app: myapp
      track: canary
  template:
    metadata:
      labels:
        app: myapp
        track: canary
    spec:
      containers:
      - name: app
        image: nginxdemos/hello:0.3
        ports:
        - containerPort: 80
        env:
        - name: VERSION
          value: "canary-2.0"
        resources:
          requests:
            cpu: 50m
            memory: 64Mi
          limits:
            cpu: 100m
            memory: 128Mi
---
apiVersion: v1
kind: Service
metadata:
  name: app-canary-service
spec:
  selector:
    app: myapp  # Selects both stable and canary pods
  ports:
  - port: 80
    targetPort: 80
    protocol: TCP
  type: ClusterIP
```

Deploy and test the Canary deployment:

```bash
# Deploy both stable and canary versions
kubectl apply -f canary-deployment.yaml

# Verify deployments and pod distribution
kubectl get deployments -l app=myapp
kubectl get pods -l app=myapp --show-labels

# Count pods by track
echo "Stable pods: $(kubectl get pods -l track=stable --no-headers | wc -l)"
echo "Canary pods: $(kubectl get pods -l track=canary --no-headers | wc -l)"

# Test traffic distribution (should see ~90% stable, ~10% canary)
kubectl run canary-test --image=curlimages/curl:7.85.0 --rm -it --restart=Never -- \
  sh -c 'for i in $(seq 1 100); do curl -s http://app-canary-service/ | grep VERSION | cut -d'"' -f4; done | sort | uniq -c'

# The output should show approximately 90 requests to stable-1.0 and 10 to canary-2.0
```

Progressive Canary rollout:

```bash
# Gradually increase canary traffic to 25%
kubectl scale deployment app-canary --replicas=3
kubectl scale deployment app-stable --replicas=9

# Verify new distribution
kubectl get deployments -l app=myapp

# Test new distribution (should see ~75% stable, ~25% canary)
kubectl run canary-test-25 --image=curlimages/curl:7.85.0 --rm -it --restart=Never -- \
  sh -c 'for i in $(seq 1 100); do curl -s http://app-canary-service/ | grep VERSION | cut -d'"' -f4; done | sort | uniq -c'

# Continue to 50/50 split
kubectl scale deployment app-canary --replicas=5
kubectl scale deployment app-stable --replicas=5

# Test 50/50 distribution
kubectl run canary-test-50 --image=curlimages/curl:7.85.0 --rm -it --restart=Never -- \
  sh -c 'for i in $(seq 1 100); do curl -s http://app-canary-service/ | grep VERSION | cut -d'"' -f4; done | sort | uniq -c'

# Complete the canary rollout (100% to new version)
kubectl scale deployment app-stable --replicas=0
kubectl scale deployment app-canary --replicas=10

# Verify complete migration
kubectl get deployments -l app=myapp
```

### Workshop: Ingress-based Canary with Precise Control

NGINX Ingress Controller provides sophisticated canary capabilities with precise traffic control:

```yaml
# ingress-canary.yaml
# Stable service
apiVersion: v1
kind: Service
metadata:
  name: stable-service
spec:
  selector:
    app: myapp
    track: stable
  ports:
  - port: 80
    targetPort: 80
---
# Canary service
apiVersion: v1
kind: Service
metadata:
  name: canary-service
spec:
  selector:
    app: myapp
    track: canary
  ports:
  - port: 80
    targetPort: 80
---
# Main ingress for stable traffic
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: app-stable-ingress
  annotations:
    nginx.ingress.kubernetes.io/rewrite-target: /
spec:
  ingressClassName: nginx
  rules:
  - host: myapp.local
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: stable-service
            port:
              number: 80
---
# Canary ingress with weight-based routing
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: app-canary-ingress
  annotations:
    nginx.ingress.kubernetes.io/canary: "true"
    nginx.ingress.kubernetes.io/canary-weight: "10"  # Start with 10% traffic
spec:
  ingressClassName: nginx
  rules:
  - host: myapp.local
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: canary-service
            port:
              number: 80
```

Test weight-based canary:

```bash
# Apply the Ingress configuration
kubectl apply -f ingress-canary.yaml

# Set up port forwarding for testing
kubectl port-forward -n ingress-nginx service/ingress-nginx-controller 8080:80 &

# Test traffic distribution (should see ~10% canary)
for i in {1..100}; do 
  curl -s -H "Host: myapp.local" http://localhost:8080/ | grep VERSION | cut -d'"' -f4
done | sort | uniq -c

# Increase canary traffic to 25%
kubectl annotate ingress app-canary-ingress \
  nginx.ingress.kubernetes.io/canary-weight="25" --overwrite

# Test new distribution
for i in {1..100}; do 
  curl -s -H "Host: myapp.local" http://localhost:8080/ | grep VERSION | cut -d'"' -f4
done | sort | uniq -c

# Progress to 50%
kubectl annotate ingress app-canary-ingress \
  nginx.ingress.kubernetes.io/canary-weight="50" --overwrite

# Complete canary rollout to 100%
kubectl annotate ingress app-canary-ingress \
  nginx.ingress.kubernetes.io/canary-weight="100" --overwrite
```

### Header-Based and Cookie-Based Canary

Advanced canary routing allows specific users to be routed to the canary version:

```yaml
# header-based-canary.yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: app-canary-header
  annotations:
    nginx.ingress.kubernetes.io/canary: "true"
    nginx.ingress.kubernetes.io/canary-by-header: "X-Canary"
    nginx.ingress.kubernetes.io/canary-by-header-value: "enabled"
spec:
  ingressClassName: nginx
  rules:
  - host: myapp.local
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: canary-service
            port:
              number: 80
```

Test header-based routing:

```bash
# Apply header-based canary
kubectl apply -f header-based-canary.yaml

# Normal request goes to stable
curl -H "Host: myapp.local" http://localhost:8080/ | grep VERSION

# Request with canary header goes to canary version
curl -H "Host: myapp.local" -H "X-Canary: enabled" http://localhost:8080/ | grep VERSION

# Test multiple requests to verify routing
echo "Testing without header (should be stable):"
for i in {1..5}; do
  curl -s -H "Host: myapp.local" http://localhost:8080/ | grep VERSION | cut -d'"' -f4
done

echo "Testing with header (should be canary):"
for i in {1..5}; do
  curl -s -H "Host: myapp.local" -H "X-Canary: enabled" http://localhost:8080/ | grep VERSION | cut -d'"' -f4
done
```

Cookie-based canary for session persistence:

```yaml
# cookie-based-canary.yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: app-canary-cookie
  annotations:
    nginx.ingress.kubernetes.io/canary: "true"
    nginx.ingress.kubernetes.io/canary-by-cookie: "canary-user"
spec:
  ingressClassName: nginx
  rules:
  - host: myapp.local
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: canary-service
            port:
              number: 80
```

Test cookie-based routing:

```bash
# Apply cookie-based canary
kubectl apply -f cookie-based-canary.yaml

# Request without cookie (goes to stable)
curl -H "Host: myapp.local" http://localhost:8080/ | grep VERSION

# Request with cookie (goes to canary)
curl -H "Host: myapp.local" --cookie "canary-user=always" http://localhost:8080/ | grep VERSION

# Simulate a browser session with persistent cookie
curl -c cookies.txt -H "Host: myapp.local" --cookie "canary-user=always" http://localhost:8080/
curl -b cookies.txt -H "Host: myapp.local" http://localhost:8080/ | grep VERSION
```

## Kubernetes Autoscaling Fundamentals

### How the Scheduler Works

The Kubernetes scheduler is the brain behind pod placement decisions in your cluster. Think of it as a sophisticated matchmaker that pairs pods with nodes based on complex criteria. Every time you create a pod, the scheduler springs into action, following a methodical process to find the perfect home for your workload.

The scheduling process operates in cycles, with each cycle handling one pod at a time. When multiple pods are pending, they're placed in a scheduling queue and processed based on priority. The scheduler makes decisions in milliseconds, but these decisions have lasting impacts on cluster performance, resource utilization, and application reliability.

### The Two-Phase Scheduling Process

#### Phase 1: Filtering (Predicates)

During the filtering phase, the scheduler eliminates nodes that cannot run the pod. This is a binary decision - a node either passes all filters or it's out. The scheduler checks multiple criteria:

**Resource Requirements**: The most fundamental check. Can the node accommodate the pod's CPU and memory requests? The scheduler considers not just current usage but also the requests of all pods already scheduled to that node.

**Taints and Tolerations**: Nodes can be "tainted" to repel pods, like a "Do Not Disturb" sign. Only pods with matching tolerations can be scheduled on tainted nodes.

**Node Selectors and Affinity**: Explicit requirements about where pods should run. These range from simple label matching to complex expressions.

**Volume Constraints**: If a pod needs a specific persistent volume, it must run on a node that can access that storage.

**Pod Topology Spread**: Requirements about how pods should be distributed across failure domains.

Let's see this in action with a complete example:

```yaml
# scheduler-demo-resources.yaml
# First, let's label our nodes for demonstration
# Run these commands first:
# kubectl label nodes <node-name> disktype=ssd zone=zone-a
# kubectl label nodes <another-node> disktype=hdd zone=zone-b

---
# A pod that will only schedule on specific nodes
apiVersion: v1
kind: Pod
metadata:
  name: filtered-pod
  labels:
    app: scheduler-demo
spec:
  # This pod MUST run on a node with SSD
  nodeSelector:
    disktype: ssd
  
  # Additional affinity rules
  affinity:
    nodeAffinity:
      # Hard requirement: Linux nodes only
      requiredDuringSchedulingIgnoredDuringExecution:
        nodeSelectorTerms:
        - matchExpressions:
          - key: kubernetes.io/os
            operator: In
            values:
            - linux
      
      # Soft preference: Prefer zone-a
      preferredDuringSchedulingIgnoredDuringExecution:
      - weight: 100
        preference:
          matchExpressions:
          - key: zone
            operator: In
            values:
            - zone-a
  
  containers:
  - name: app
    image: nginx:alpine
    resources:
      requests:
        cpu: 100m
        memory: 128Mi
      limits:
        cpu: 500m
        memory: 512Mi
```

Test the filtering behavior:

```bash
# Deploy the pod
kubectl apply -f scheduler-demo-resources.yaml

# Check where it was scheduled
kubectl get pod filtered-pod -o wide

# See the scheduler's decision-making process
kubectl describe pod filtered-pod | grep -A 10 Events

# Try creating a pod that can't be scheduled
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: unschedulable-pod
spec:
  nodeSelector:
    nonexistent: label
  containers:
  - name: app
    image: nginx:alpine
EOF

# Watch it remain pending
kubectl get pod unschedulable-pod
kubectl describe pod unschedulable-pod | grep -A 5 Events
```

#### Phase 2: Scoring (Priorities)

After filtering, if multiple nodes remain, the scheduler scores each one. Unlike filtering, scoring is nuanced - nodes receive points based on various factors, and the highest-scoring node wins.

Scoring factors include:

**Resource Balance**: The scheduler prefers nodes that would have balanced resource utilization after placing the pod.

**Image Locality**: Nodes with the pod's container images already cached score higher.

**Affinity Scores**: Soft affinity rules contribute to the score.

**Spreading**: The scheduler tries to spread pods from the same deployment across nodes.

Here's a comprehensive example demonstrating scoring preferences:

```yaml
# scoring-demo.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: scoring-demo
spec:
  replicas: 6
  selector:
    matchLabels:
      app: scoring-demo
  template:
    metadata:
      labels:
        app: scoring-demo
    spec:
      # Spread pods across zones
      topologySpreadConstraints:
      - maxSkew: 1
        topologyKey: zone
        whenUnsatisfiable: DoNotSchedule
        labelSelector:
          matchLabels:
            app: scoring-demo
      
      # Prefer to co-locate with cache pods
      affinity:
        podAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
          - weight: 50
            podAffinityTerm:
              labelSelector:
                matchExpressions:
                - key: app
                  operator: In
                  values:
                  - cache
              topologyKey: kubernetes.io/hostname
        
        # But spread this deployment's pods
        podAntiAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
          - weight: 100
            podAffinityTerm:
              labelSelector:
                matchExpressions:
                - key: app
                  operator: In
                  values:
                  - scoring-demo
              topologyKey: kubernetes.io/hostname
      
      containers:
      - name: app
        image: nginx:alpine
        resources:
          requests:
            cpu: 100m
            memory: 128Mi
```

### Advanced Scheduling Controls

#### Inter-Pod Affinity and Anti-Affinity

Inter-pod affinity controls how pods are placed relative to each other. This is crucial for performance (keeping related services close) and reliability (spreading replicas apart).

```yaml
# pod-affinity-complete.yaml
# First, deploy a cache service that our app wants to be near
apiVersion: apps/v1
kind: Deployment
metadata:
  name: cache
spec:
  replicas: 2
  selector:
    matchLabels:
      app: cache
  template:
    metadata:
      labels:
        app: cache
        tier: backend
    spec:
      containers:
      - name: redis
        image: redis:alpine
        resources:
          requests:
            cpu: 100m
            memory: 128Mi
---
# Now deploy an app that prefers to be near cache but spread from itself
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web-app
spec:
  replicas: 3
  selector:
    matchLabels:
      app: web
  template:
    metadata:
      labels:
        app: web
        tier: frontend
    spec:
      affinity:
        # Prefer same node as cache
        podAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
          - labelSelector:
              matchExpressions:
              - key: app
                operator: In
                values:
                - cache
            topologyKey: kubernetes.io/hostname
            # Only consider cache pods in the same namespace
            namespaces:
            - default
        
        # Must not be on same node as other web pods
        podAntiAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
          - labelSelector:
              matchExpressions:
              - key: app
                operator: In
                values:
                - web
            topologyKey: kubernetes.io/hostname
      
      containers:
      - name: nginx
        image: nginx:alpine
        resources:
          requests:
            cpu: 100m
            memory: 128Mi
```

Test affinity behavior:

```bash
# Deploy both services
kubectl apply -f pod-affinity-complete.yaml

# Watch pods being scheduled
kubectl get pods -o wide --watch

# Verify web pods are on same nodes as cache pods
kubectl get pods -l app=cache -o wide
kubectl get pods -l app=web -o wide

# Check that web pods are spread across different nodes
kubectl get pods -l app=web -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.nodeName}{"\n"}{end}'

# See the scheduler's decisions
kubectl describe pod -l app=web | grep -E "Node:|Successfully assigned"
```

#### Taints and Tolerations

Taints and tolerations provide a flexible way to influence scheduling. Taints repel pods from nodes, while tolerations allow pods to overcome taints.

```yaml
# taints-demo.yaml
# First, taint a node (run this command with your actual node name)
# kubectl taint nodes <node-name> workload=gpu:NoSchedule
# kubectl taint nodes <node-name> environment=production:NoExecute

---
# Pod that tolerates GPU workload taint
apiVersion: v1
kind: Pod
metadata:
  name: gpu-pod
spec:
  tolerations:
  # Tolerate GPU workload taint
  - key: workload
    operator: Equal
    value: gpu
    effect: NoSchedule
  
  # Tolerate production environment taint
  - key: environment
    operator: Equal
    value: production
    effect: NoExecute
    # Pod can stay for 300 seconds if node gets this taint
    tolerationSeconds: 300
  
  containers:
  - name: gpu-app
    image: nvidia/cuda:11.0-base
    command: ["sleep", "3600"]
    resources:
      requests:
        cpu: 100m
        memory: 128Mi
---
# Pod that doesn't tolerate taints (will not schedule on tainted nodes)
apiVersion: v1
kind: Pod
metadata:
  name: regular-pod
spec:
  containers:
  - name: app
    image: nginx:alpine
    resources:
      requests:
        cpu: 100m
        memory: 128Mi
```

Complete taint management example:

```bash
# Add taints to a node
NODE_NAME=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')
kubectl taint nodes $NODE_NAME workload=gpu:NoSchedule
kubectl taint nodes $NODE_NAME environment=production:NoExecute

# Deploy pods
kubectl apply -f taints-demo.yaml

# Check pod status
kubectl get pods -o wide

# The gpu-pod should schedule, regular-pod might not (depends on other nodes)
kubectl describe pod gpu-pod | grep -A 5 Tolerations
kubectl describe pod regular-pod | grep -A 5 Events

# Remove taints when done
kubectl taint nodes $NODE_NAME workload=gpu:NoSchedule-
kubectl taint nodes $NODE_NAME environment=production:NoExecute-
```

## Horizontal Pod Autoscaler (HPA)

### Understanding HPA in Depth

The Horizontal Pod Autoscaler is like a thermostat for your applications. Just as a thermostat maintains room temperature by controlling heating and cooling, HPA maintains application performance by controlling the number of pod replicas.

HPA continuously monitors metrics and makes scaling decisions based on mathematical calculations. It's important to understand that HPA doesn't just react to current load - it tries to anticipate and maintain stable performance.

### HPA Architecture and Components

The HPA system consists of several components working together:

1. **Metrics Server**: Collects resource metrics from kubelets
2. **HPA Controller**: Makes scaling decisions
3. **Custom Metrics API**: For application-specific metrics
4. **External Metrics API**: For metrics from external systems

### Complete HPA Setup and Configuration

Let's build a complete autoscaling setup from scratch:

```yaml
# hpa-complete-demo.yaml
# A PHP application that consumes CPU when accessed
apiVersion: apps/v1
kind: Deployment
metadata:
  name: php-apache
  labels:
    app: php-apache
spec:
  replicas: 1
  selector:
    matchLabels:
      app: php-apache
  template:
    metadata:
      labels:
        app: php-apache
    spec:
      containers:
      - name: php-apache
        image: registry.k8s.io/hpa-example
        ports:
        - containerPort: 80
        resources:
          requests:
            cpu: 200m
            memory: 256Mi
          limits:
            cpu: 500m
            memory: 512Mi
        # Liveness and readiness probes for production readiness
        livenessProbe:
          httpGet:
            path: /
            port: 80
          initialDelaySeconds: 30
          periodSeconds: 10
        readinessProbe:
          httpGet:
            path: /
            port: 80
          initialDelaySeconds: 5
          periodSeconds: 5
---
apiVersion: v1
kind: Service
metadata:
  name: php-apache
  labels:
    app: php-apache
spec:
  selector:
    app: php-apache
  ports:
  - port: 80
    targetPort: 80
  type: ClusterIP
---
# HPA with multiple metrics
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: php-apache
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: php-apache
  minReplicas: 1
  maxReplicas: 10
  metrics:
  # Scale based on CPU utilization
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: 50
  # Also consider memory
  - type: Resource
    resource:
      name: memory
      target:
        type: Utilization
        averageUtilization: 80
  # Advanced scaling behavior
  behavior:
    scaleDown:
      # Wait 60 seconds before scaling down
      stabilizationWindowSeconds: 60
      policies:
      # Scale down maximum 2 pods per 60 seconds
      - type: Pods
        value: 2
        periodSeconds: 60
      # Or 10% of current pods
      - type: Percent
        value: 10
        periodSeconds: 60
      selectPolicy: Min  # Use the most conservative policy
    scaleUp:
      # Faster scale up - wait only 30 seconds
      stabilizationWindowSeconds: 30
      policies:
      # Scale up maximum 4 pods per 60 seconds
      - type: Pods
        value: 4
        periodSeconds: 60
      # Or 100% of current pods (double)
      - type: Percent
        value: 100
        periodSeconds: 60
      selectPolicy: Max  # Use the most aggressive policy
```

Deploy and test the complete HPA setup:

```bash
# First, ensure metrics-server is installed and working
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/download/v0.6.4/components.yaml

# For local clusters, patch metrics-server for insecure TLS
kubectl patch deployment metrics-server -n kube-system --type='json' \
  -p='[{"op": "add", "path": "/spec/template/spec/containers/0/args/-", "value": "--kubelet-insecure-tls"}]'

# Wait for metrics to be available
kubectl wait --for=condition=ready pod -l k8s-app=metrics-server -n kube-system --timeout=180s

# Deploy the application with HPA
kubectl apply -f hpa-complete-demo.yaml

# Verify deployment
kubectl get deployment php-apache
kubectl get hpa php-apache

# Monitor HPA status in real-time
watch -n 2 'kubectl get hpa php-apache'
```

### Advanced Load Testing and Scaling Behavior

Let's create a comprehensive load testing scenario:

```yaml
# load-test-advanced.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: load-test-script
data:
  load.sh: |
    #!/bin/sh
    echo "Starting gradual load increase..."
    
    # Warm-up phase - light load
    echo "Phase 1: Warm-up (1 request/second for 30 seconds)"
    for i in $(seq 1 30); do
      wget -q -O- http://php-apache.default.svc.cluster.local/ &
      sleep 1
    done
    
    # Moderate load
    echo "Phase 2: Moderate load (5 requests/second for 60 seconds)"
    for i in $(seq 1 60); do
      for j in $(seq 1 5); do
        wget -q -O- http://php-apache.default.svc.cluster.local/ &
      done
      sleep 1
    done
    
    # Heavy load
    echo "Phase 3: Heavy load (20 requests/second for 120 seconds)"
    for i in $(seq 1 120); do
      for j in $(seq 1 20); do
        wget -q -O- http://php-apache.default.svc.cluster.local/ &
      done
      sleep 1
    done
    
    # Burst load
    echo "Phase 4: Burst load (100 concurrent requests)"
    for i in $(seq 1 100); do
      wget -q -O- http://php-apache.default.svc.cluster.local/ &
    done
    wait
    
    # Cool down
    echo "Phase 5: Cool down (no load for 300 seconds)"
    sleep 300
    
    echo "Load test complete!"
---
apiVersion: batch/v1
kind: Job
metadata:
  name: load-tester
spec:
  template:
    spec:
      containers:
      - name: busybox
        image: busybox:1.35
        command: ["/bin/sh"]
        args: ["/scripts/load.sh"]
        volumeMounts:
        - name: script
          mountPath: /scripts
      volumes:
      - name: script
        configMap:
          name: load-test-script
          defaultMode: 0755
      restartPolicy: Never
  backoffLimit: 1
```

Run the comprehensive load test:

```bash
# Deploy the load tester
kubectl apply -f load-test-advanced.yaml

# Monitor in multiple terminals:

# Terminal 1: Watch HPA status
watch -n 1 'kubectl get hpa php-apache'

# Terminal 2: Watch pod count
watch -n 1 'kubectl get pods -l app=php-apache'

# Terminal 3: Monitor resource usage
watch -n 2 'kubectl top pods -l app=php-apache'

# Terminal 4: Watch events
kubectl get events --watch | grep -E "Scaled|HorizontalPodAutoscaler"

# Terminal 5: Check load tester logs
kubectl logs -f job/load-tester

# After test completes, analyze scaling behavior
kubectl describe hpa php-apache
```

## Vertical Pod Autoscaler (VPA)

### Understanding VPA

While HPA scales the number of pods, VPA adjusts the resource requests and limits of existing pods. This is crucial for right-sizing applications where you don't know the optimal resource requirements upfront.

```yaml
# vpa-demo.yaml
# First install VPA (run these commands):
# git clone https://github.com/kubernetes/autoscaler.git
# cd autoscaler/vertical-pod-autoscaler
# ./hack/vpa-up.sh

---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: vpa-demo
spec:
  replicas: 2
  selector:
    matchLabels:
      app: vpa-demo
  template:
    metadata:
      labels:
        app: vpa-demo
    spec:
      containers:
      - name: app
        image: nginx:alpine
        resources:
          requests:
            cpu: 100m
            memory: 50Mi
          limits:
            cpu: 200m
            memory: 100Mi
---
apiVersion: autoscaling.k8s.io/v1
kind: VerticalPodAutoscaler
metadata:
  name: vpa-demo
spec:
  targetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: vpa-demo
  updatePolicy:
    updateMode: "Auto"  # Can be "Off", "Initial", or "Auto"
  resourcePolicy:
    containerPolicies:
    - containerName: app
      minAllowed:
        cpu: 50m
        memory: 30Mi
      maxAllowed:
        cpu: 1
        memory: 1Gi
      controlledResources: ["cpu", "memory"]
```

## Pod Priority and Preemption

### Implementing a Complete Priority System

Pod priority enables sophisticated resource management in resource-constrained clusters:

```yaml
# priority-system.yaml
# Define a complete priority class hierarchy
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata:
  name: system-critical
value: 2000
globalDefault: false
description: "Critical system components"
---
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata:
  name: production-high
value: 1500
globalDefault: false
description: "Production workloads - high priority"
---
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata:
  name: production-normal
value: 1000
globalDefault: true
description: "Production workloads - normal priority"
---
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata:
  name: development
value: 500
globalDefault: false
description: "Development workloads"
preemptionPolicy: Never  # Won't evict other pods
---
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata:
  name: batch
value: 100
globalDefault: false
description: "Batch jobs and low priority work"
preemptionPolicy: Never
---
# Example deployments using priority classes
apiVersion: apps/v1
kind: Deployment
metadata:
  name: critical-app
spec:
  replicas: 2
  selector:
    matchLabels:
      app: critical
  template:
    metadata:
      labels:
        app: critical
    spec:
      priorityClassName: production-high
      containers:
      - name: app
        image: nginx:alpine
        resources:
          requests:
            cpu: 500m
            memory: 512Mi
---
apiVersion: batch/v1
kind: Job
metadata:
  name: batch-job
spec:
  template:
    spec:
      priorityClassName: batch
      containers:
      - name: batch
        image: busybox
        command: ["sh", "-c", "echo 'Processing batch job...' && sleep 300"]
        resources:
          requests:
            cpu: 1000m
            memory: 1Gi
      restartPolicy: Never
```

Test priority and preemption:

```bash
# Apply priority classes
kubectl apply -f priority-system.yaml

# Check priority classes
kubectl get priorityclasses

# In a resource-constrained scenario, high-priority pods will preempt low-priority ones
# Simulate by creating many pods that exhaust resources

# First, check current resource usage
kubectl top nodes

# Create low-priority pods that consume resources
for i in {1..10}; do
  kubectl run batch-pod-$i --image=busybox \
    --overrides='{"spec":{"priorityClassName":"batch"}}' \
    --requests='cpu=200m,memory=256Mi' \
    -- sleep 3600
done

# Now create a high-priority pod that needs resources
kubectl run critical-pod --image=nginx \
  --overrides='{"spec":{"priorityClassName":"production-high"}}' \
  --requests='cpu=500m,memory=512Mi'

# Watch preemption happen
kubectl get events --sort-by='.lastTimestamp' | grep Preempted
```

## Node Pressure and Eviction

### Understanding and Configuring Eviction

Kubernetes protects nodes from resource exhaustion through intelligent eviction policies:

```yaml
# eviction-demo.yaml
# Deploy pods with different QoS classes
# Guaranteed QoS - will be evicted last
apiVersion: v1
kind: Pod
metadata:
  name: guaranteed-pod
spec:
  containers:
  - name: app
    image: nginx:alpine
    resources:
      requests:
        cpu: 100m
        memory: 128Mi
      limits:
        cpu: 100m
        memory: 128Mi
---
# Burstable QoS - will be evicted before Guaranteed
apiVersion: v1
kind: Pod
metadata:
  name: burstable-pod
spec:
  containers:
  - name: app
    image: nginx:alpine
    resources:
      requests:
        cpu: 50m
        memory: 64Mi
      limits:
        cpu: 200m
        memory: 256Mi
---
# BestEffort QoS - will be evicted first
apiVersion: v1
kind: Pod
metadata:
  name: besteffort-pod
spec:
  containers:
  - name: app
    image: nginx:alpine
    # No resource requests or limits
```
