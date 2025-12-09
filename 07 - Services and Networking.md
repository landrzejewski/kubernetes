
## Understanding Kubernetes Networking

### The Foundation of Cluster Communication

Kubernetes networking forms the backbone of how applications communicate within a cluster. At its core, Kubernetes implements a flat networking model where every Pod receives its own IP address and can communicate with any other Pod without Network Address Translation (NAT). This design philosophy simplifies application architecture and removes the complexities traditionally associated with container networking.

The networking layer in Kubernetes is built on several fundamental abstractions that work together to provide a robust, scalable, and flexible communication infrastructure for containerized applications. Understanding these abstractions is crucial for anyone working with Kubernetes, as networking challenges are often the most complex issues to debug in production environments.

### Core Networking Requirements

Kubernetes networking must satisfy four fundamental requirements:

1. Container-to-container communication within a Pod: Containers in the same Pod share the same network namespace, meaning they can communicate via localhost
2. Pod-to-Pod communication: Any Pod can communicate with any other Pod without NAT, regardless of which node they're on
3. Pod-to-Service communication: Pods can reliably reach Services using consistent virtual IPs
4. External-to-Service communication: External traffic can reach Services through various exposure methods

### The Service Abstraction - Solving Dynamic Networking

The Service is perhaps the most fundamental networking concept in Kubernetes. Services solve a critical problem in dynamic containerized environments where Pods are ephemeral and their IP addresses constantly change. When you deploy applications using Deployments or other workload controllers, Pods can be created and destroyed at any moment due to scaling operations, node failures, rolling updates, or cluster maintenance.

Without Services, you would need to track every Pod IP address manually and update your application configuration every time a Pod was replaced. This would be impractical and error-prone. A Service acts as a stable network abstraction that represents a logical set of Pods. It provides a consistent IP address (ClusterIP) and DNS name that remains constant even as the underlying Pods change. The Service uses label selectors to identify which Pods belong to its backend pool. When network traffic arrives at a Service, it gets distributed among the healthy Pods that match the selector criteria.

### How Services Work Under the Hood

When you create a Service, several components work together to make it functional:

1. The Service Controller watches for Service creation and assigns a ClusterIP from the configured service CIDR range
2. The Endpoint Controller (or EndpointSlice controller in newer versions) watches for Pods matching the Service's selector and maintains a list of their IP addresses
3. kube-proxy on each node watches for Service and Endpoint changes and configures the node's networking rules (iptables, IPVS, or userspace proxy) to handle the actual packet forwarding
4. CoreDNS creates DNS records for each Service, enabling name-based service discovery

### Dynamic Endpoint Management

The Service controller continuously monitors the cluster for Pods that match each Service's selector. As Pods come and go, the controller updates the corresponding EndpointSlices to reflect the current set of available backends. This dynamic discovery mechanism ensures that traffic is always routed only to Pods that are ready to handle requests.

The kube-proxy component running on each node watches these EndpointSlices and configures the local networking rules to implement the actual traffic forwarding. By default, kube-proxy uses iptables rules for efficient in-kernel packet processing, though it can also use IPVS for better performance at scale or fall back to userspace proxying. This architecture enables true decoupling between frontend and backend components, allowing them to evolve independently without breaking their network contracts.

## Service Types and Their Use Cases

Kubernetes offers several Service types, each designed for specific networking scenarios. Understanding when to use each type is essential for building robust applications.

### ClusterIP Services

ClusterIP is the default and most commonly used Service type. It allocates an IP address from the cluster's internal IP range (typically 10.96.0.0/12), making the Service accessible only from within the cluster. This type is perfect for internal microservice communication where external access is not required.

The ClusterIP remains stable throughout the Service's lifetime, providing a reliable endpoint for internal clients. Even if all backend Pods are replaced, the ClusterIP stays the same. This stability is crucial for service discovery and allows you to hardcode Service addresses in configuration files if needed (though DNS is preferred).

ClusterIP Services are ideal for:

- Database connections that should only be accessible internally
- Internal APIs between microservices
- Cache servers like Redis or Memcached
- Message queues and event buses

### NodePort Services

NodePort Services build upon ClusterIP by additionally exposing the Service on a static port (ranging from 30000-32767 by default) on every node in the cluster. This allows external traffic to reach the Service by connecting to any node's IP address on the designated port. Behind the scenes, a NodePort Service actually creates a ClusterIP Service first, then adds the node port mapping on top.

When traffic arrives at a node port, it gets forwarded to the Service's ClusterIP, which then load balances to the backend Pods. This means the traffic might need to hop between nodes if the selected Pod runs on a different node than where the traffic arrived.

NodePort Services are useful for:

- Development and testing environments where you need quick external access
- On-premises clusters without cloud load balancers
- Specific protocols that require direct node access
- Emergency access when other ingress methods fail

### LoadBalancer Services

LoadBalancer Services extend NodePort functionality by provisioning an external load balancer through the cloud provider's infrastructure. This type is ideal for production workloads that need to be accessible from the internet with high availability and automatic failover. The cloud provider's load balancer distributes traffic across the nodes, which then forward it to the appropriate Pods.

The exact implementation depends on your cloud provider:

- AWS creates an Elastic Load Balancer (Classic or Network)
- GCP creates a Network Load Balancer
- Azure creates an Azure Load Balancer
- On-premises clusters can use MetalLB or similar solutions

LoadBalancer Services are best for:

- Production web applications
- Public-facing APIs
- Services that need a stable external IP
- High-traffic applications requiring cloud-scale load balancing

### ExternalName Services

ExternalName Services are unique in that they don't proxy traffic but instead return a CNAME record for an external DNS name. This allows you to reference external services through the Kubernetes Service abstraction, making it easier to migrate external dependencies into the cluster later. No proxying occurs - it's purely a DNS alias.

ExternalName Services are useful for:

- Referencing external databases or APIs
- Gradual migration of services into Kubernetes
- Creating environment-specific endpoints (dev/staging/prod)
- Abstracting external service locations

### Headless Services and Direct Pod Communication

Headless Services provide a way to directly discover and communicate with individual Pods without going through a proxy. By setting the clusterIP field to "None", you create a Service that doesn't allocate a cluster IP. Instead, DNS queries for the Service return the IP addresses of all Pods that match the selector.

This is particularly useful for stateful applications like databases where clients need to connect to specific Pod instances rather than having their connections load-balanced randomly. Applications can query DNS to get the full list of backend Pods and implement their own connection logic, such as connecting to a primary database for writes and replicas for reads.

Headless Services are essential for:

- StatefulSets where Pod identity matters
- Database clusters requiring direct Pod connections
- Distributed systems needing peer discovery
- Applications implementing custom load balancing

## EndpointSlices - Modern Endpoint Management

EndpointSlices represent a significant evolution in how Kubernetes manages network endpoints. Introduced in Kubernetes 1.17 and becoming the default in 1.19, they replaced the older Endpoints API to address scalability limitations and provide better support for large clusters.

### Why EndpointSlices?

The original Endpoints API stored all endpoints for a Service in a single object. In large clusters with thousands of Pods backing a Service, this created several problems:

- Large Endpoints objects that could exceed etcd size limits
- Frequent updates causing high API server load
- Network traffic amplification as the entire object was sent on each change

EndpointSlices solve these issues by splitting endpoints across multiple smaller objects. Each EndpointSlice can contain up to 100 endpoints by default (configurable via `--max-endpoints-per-slice`), distributing endpoint information across multiple objects and reducing the size of individual API updates.

### EndpointSlice Features

The EndpointSlice API provides rich information about each endpoint:

- Addresses: The IP addresses of the endpoint
- Conditions:
    - ready: Whether the Pod is ready (passes readiness probes)
    - serving: Whether the endpoint can serve traffic
    - terminating: Whether the Pod is shutting down
- Topology: Node name and zone for topology-aware routing
- NodeName: Which node the endpoint Pod runs on
- Zone: The availability zone for multi-zone deployments
- Hints: Topology hints for traffic routing optimization

## Network Policies - Implementing Security Controls

Network Policies provide a way to control traffic flow at the IP address and port level (OSI Layer 3/4), implementing network segmentation within the cluster. By default, Kubernetes allows all Pods to communicate with each other freely, following a "flat network" model. Network Policies change this by defining rules that specify which connections are allowed.

### How Network Policies Work

Network Policies are implemented by the Container Network Interface (CNI) plugin, not by Kubernetes itself. This means:

- You need a CNI plugin that supports Network Policies (Calico, Cilium, Weave Net, etc.)
- Policies are enforced at the network level, not application level
- They work by programming iptables or eBPF rules on nodes

When you apply a Network Policy:

1. It selects target Pods using label selectors
2. For selected Pods, it changes the default from "allow all" to "deny all"
3. It then explicitly allows traffic matching the policy rules
4. Multiple policies are additive - traffic is allowed if ANY policy permits it

### Zero-Trust Networking

Network Policies enable zero-trust networking by implementing the principle of least privilege:

- Start with default deny policies that block all traffic
- Explicitly authorize only required communication paths
- Use label selectors for dynamic policy application
- Separate ingress and egress controls for fine-grained security

This approach significantly reduces the attack surface within your cluster and helps meet compliance requirements for network segmentation.

## Service Discovery Mechanisms

Kubernetes provides multiple mechanisms for service discovery, each with different trade-offs:

### DNS-Based Discovery

DNS is the primary and most flexible service discovery mechanism. CoreDNS (or kube-dns in older clusters) runs as a cluster addon and provides:

Service DNS Records:

- A records for standard Services: `service.namespace.svc.cluster.local` → ClusterIP
- A records for Headless Services: `service.namespace.svc.cluster.local` → Pod IPs
- SRV records for named ports: `_port-name._protocol.service.namespace.svc.cluster.local`
- PTR records for reverse lookups

Pod DNS Records (if enabled):

- `pod-ip-address.namespace.pod.cluster.local`
- Useful for StatefulSets with predictable Pod names

DNS Search Domains: Pods get a resolv.conf with search domains allowing short names:

```
search default.svc.cluster.local svc.cluster.local cluster.local
```

This means from the default namespace, you can use:

- `myservice` (same namespace)
- `myservice.other-namespace` (cross-namespace)
- `myservice.other-namespace.svc.cluster.local` (FQDN)

### Environment Variables

The kubelet injects environment variables for each Service into new Pods:

```
{SVCNAME}_SERVICE_HOST=10.96.123.45
{SVCNAME}_SERVICE_PORT=80
{SVCNAME}_PORT=tcp://10.96.123.45:80
{SVCNAME}_PORT_80_TCP=tcp://10.96.123.45:80
{SVCNAME}_PORT_80_TCP_PROTO=tcp
{SVCNAME}_PORT_80_TCP_PORT=80
{SVCNAME}_PORT_80_TCP_ADDR=10.96.123.45
```

Limitations:

- Only works for Services existing when Pod starts
- Can cause environment variable explosion with many Services
- Doesn't update if Service addresses change

## Traffic Policies and Session Management

### External Traffic Policy

The `externalTrafficPolicy` field controls how NodePort and LoadBalancer Services handle external traffic:

Cluster (default):

- Traffic can be routed to any node then forwarded to Pods
- Better load distribution
- Preserves source IP requires cloud provider support
- Additional network hop possible

Local:

- Traffic only goes to Pods on the same node
- Preserves source IP naturally
- No additional network hops
- Can cause imbalanced load distribution

### Internal Traffic Policy

The `internalTrafficPolicy` field controls cluster-internal traffic routing:

Cluster (default):

- Route to any eligible Pod in the cluster
- Better load distribution

Local:

- Route only to Pods on the same node
- Reduces inter-node traffic
- Better performance for node-local communication

### Session Affinity

Session affinity (sticky sessions) ensures requests from the same client go to the same backend Pod:

```yaml
spec:
  sessionAffinity: ClientIP
  sessionAffinityConfig:
    clientIP:
      timeoutSeconds: 10800  # 3 hours
```

Important considerations:

- Only supports ClientIP affinity (cookie-based requires Ingress)
- Timeout is configurable (default 10800 seconds)
- Works with all Service types
- Can impact load distribution

## Workshop: Services and Networking

This workshop provides hands-on experience with Kubernetes Services and networking concepts. 

## Service Types and Port Configuration

Understanding how Services route traffic through different port configurations is essential for debugging connectivity issues.

### Understanding Port Types

Services work with three types of ports that often cause confusion:

- targetPort: The port on the container where your application listens
- port: The port on the Service's ClusterIP where clients connect
- nodePort: For NodePort services, the port exposed on each cluster node (30000-32767)

The traffic flow is: Client → Service Port → Target Port → Container

### Creating Services Imperatively

Let's start by creating a deployment and exposing it as a Service:

```bash
# Create a deployment with 3 replicas
kubectl create deployment nginxsvc --image=nginx:1.21 --replicas=3

# Wait for deployment to be ready
kubectl wait --for=condition=available --timeout=60s deployment/nginxsvc

# Verify deployment is running
kubectl get deployment nginxsvc
kubectl get pods -l app=nginxsvc

# Check pod IPs (note they're all different and from Pod network CIDR)
kubectl get pods -l app=nginxsvc -o wide

# Look at pod details with cleaner output
kubectl get pods -l app=nginxsvc -o=custom-columns='NAME:.metadata.name,IP:.status.podIP,NODE:.spec.nodeName'

# Create a Service using kubectl expose
kubectl expose deployment nginxsvc --port=80 --target-port=80

# Examine the created Service
kubectl get services nginxsvc
kubectl describe service nginxsvc

# View service endpoints (should match pod IPs)
kubectl get endpoints nginxsvc
kubectl get endpointslices -l kubernetes.io/service-name=nginxsvc
```

Understanding the output:

```bash
NAME       TYPE        CLUSTER-IP      EXTERNAL-IP   PORT(S)   AGE
nginxsvc   ClusterIP   10.96.123.45    <none>        80/TCP    30s

# The Endpoints show actual Pod IPs
NAME       ENDPOINTS                                      AGE  
nginxsvc   10.244.1.4:80,10.244.2.3:80,10.244.3.5:80    30s
```

### Testing Service Connectivity

```bash
# Create a test pod to verify Service connectivity
kubectl run testpod --image=nicolaka/netshoot:latest --rm -it --restart=Never -- /bin/bash

# Inside the test pod, try these commands:
# Check DNS resolution
nslookup nginxsvc
dig nginxsvc.default.svc.cluster.local

# Test HTTP connectivity
curl http://nginxsvc
curl -I http://nginxsvc  # Headers only

# Test direct pod IP access (replace with actual pod IP)
curl http://10.244.1.4

# Trace network path
traceroute nginxsvc

# Exit the test pod
exit
```

## Service Types Deep Dive

Let's explore each Service type with practical examples and understand their use cases.

### 1. ClusterIP Service (Default)

ClusterIP Services provide internal-only access, perfect for microservice communication:

Deploy and test:

```bash
# Apply the ClusterIP service
kubectl apply -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: clusterip-service
  labels:
    app: demo
spec:
  type: ClusterIP
  selector:
    app: nginxsvc
  ports:
  - name: http
    port: 8080
    targetPort: 80
    protocol: TCP
EOF

# Examine the service
kubectl get svc clusterip-service
kubectl get endpoints clusterip-service

# Test internal access (note we use port 8080, not 80)
kubectl run test --image=busybox:1.35 --rm -it --restart=Never -- wget -O- http://clusterip-service:8080

# Verify no external access (this will fail as expected)
# Get a node IP first
NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
echo "Node IP: $NODE_IP"
# This won't work - internal only
curl http://$NODE_IP:8080 2>/dev/null || echo "Failed as expected - ClusterIP is internal only"
```

### 2. NodePort Service

NodePort Services expose applications on static ports across all nodes:

Deploy and test:

```bash
# Apply NodePort service
kubectl apply -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: nodeport-service
  labels:
    app: demo
spec:
  type: NodePort
  selector:
    app: nginxsvc
  ports:
  - name: http
    port: 80
    targetPort: 80
    nodePort: 30080
    protocol: TCP
EOF

# Check the service (note the PORT(S) column shows both ports)
kubectl get svc nodeport-service

# Get node information
kubectl get nodes -o wide

# Test with node IP
NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
echo "Testing NodePort on $NODE_IP:30080"

# For minikube users:
if command -v minikube &> /dev/null; then
  minikube service nodeport-service --url
else
  # For other clusters, test with curl
  curl http://$NODE_IP:30080
fi

# Test internal access still works
kubectl run test --image=busybox:1.35 --rm -it --restart=Never -- wget -O- http://nodeport-service
```

### 3. LoadBalancer Service with MetalLB

For LoadBalancer Services in bare-metal clusters, we'll use MetalLB. In cloud environments, skip the MetalLB installation.

#### Installing MetalLB

MetalLB provides a network load balancer implementation for bare metal Kubernetes clusters using standard routing protocols.

```bash
# Install MetalLB v0.15.2
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.15.2/config/manifests/metallb-native.yaml

# Wait for MetalLB pods to be ready
kubectl wait --namespace metallb-system \
  --for=condition=ready pod \
  --selector=app=metallb \
  --timeout=90s

# Verify MetalLB installation
kubectl get pods -n metallb-system
kubectl get crd | grep metallb
```

#### Configuring MetalLB

Configure MetalLB with an IP address pool. Adjust the IP range based on your network:

```yaml
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: first-pool
  namespace: metallb-system
spec:
  addresses:
  # CRITICAL: You MUST change this IP range to match YOUR network!
  # Example for 192.168.1.x network: 192.168.1.240-192.168.1.250
  # Example for 10.0.0.x network: 10.0.0.240-10.0.0.250
  # Use IP addresses that your router won't assign via DHCP
  - 10.10.10.200-10.10.10.250  # CHANGE THIS TO MATCH YOUR NETWORK!
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: example
  namespace: metallb-system
spec:
  ipAddressPools:
  - first-pool
```

Apply MetalLB configuration:

```bash
# IMPORTANT: Edit the IP range below to match your network before applying!
cat <<EOF
# WARNING: You MUST edit the IP range in the following configuration
# to match your local network before applying it!
EOF

kubectl apply -f - <<EOF
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: first-pool
  namespace: metallb-system
spec:
  addresses:
  - 192.168.1.240-192.168.1.250  # CHANGE THIS!
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: example
  namespace: metallb-system
spec:
  ipAddressPools:
  - first-pool
EOF

# Verify configuration
kubectl get ipaddresspool -n metallb-system
kubectl get l2advertisement -n metallb-system
```

#### Creating LoadBalancer Service

Deploy and test:

```bash
# Apply LoadBalancer service
kubectl apply -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: loadbalancer-service
  labels:
    app: demo
spec:
  type: LoadBalancer
  selector:
    app: nginxsvc
  ports:
  - name: http
    port: 80
    targetPort: 80
    protocol: TCP
EOF

# Watch for external IP assignment
kubectl get svc loadbalancer-service -w

# Once EXTERNAL-IP is assigned, test it (Ctrl+C to stop watching)
EXTERNAL_IP=$(kubectl get svc loadbalancer-service -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
echo "External IP: $EXTERNAL_IP"

# Test external access
if [ -n "$EXTERNAL_IP" ]; then
  curl http://$EXTERNAL_IP
else
  echo "Waiting for LoadBalancer IP assignment..."
fi

# Check MetalLB allocated IPs
kubectl get svc -o wide | grep LoadBalancer

# See MetalLB events
kubectl describe svc loadbalancer-service
kubectl get events -n metallb-system
```

### 4. ExternalName Service

ExternalName Services create DNS aliases to external services:

```bash
# Create ExternalName service
kubectl apply -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: external-google
spec:
  type: ExternalName
  externalName: www.google.com
EOF

# Check the service (note no ClusterIP)
kubectl get svc external-google

# Test DNS resolution (returns CNAME)
kubectl run test --image=busybox:1.35 --rm -it --restart=Never -- nslookup external-google

# The DNS returns the external name, not an IP
kubectl run test --image=nicolaka/netshoot:latest --rm -it --restart=Never -- dig external-google.default.svc.cluster.local

# Test connectivity (will connect to google.com)
kubectl run test --image=busybox:1.35 --rm -it --restart=Never -- wget -O- -T 2 http://external-google 2>&1 | head -10
```

### 5. Headless Service

Headless Services enable direct Pod discovery without load balancing:

```bash
# Create headless service
kubectl apply -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: headless-service
  labels:
    app: demo
spec:
  clusterIP: None
  selector:
    app: nginxsvc
  ports:
  - name: http
    port: 80
    targetPort: 80
EOF

# Check the service (note clusterIP is None)
kubectl get svc headless-service

# DNS returns all pod IPs, not a single service IP
kubectl run test --image=busybox:1.35 --rm -it --restart=Never -- nslookup headless-service

# Compare with regular ClusterIP service
kubectl run test --image=busybox:1.35 --rm -it --restart=Never -- nslookup clusterip-service

# Get detailed DNS records
kubectl run test --image=nicolaka/netshoot:latest --rm -it --restart=Never -- dig headless-service.default.svc.cluster.local A +short

# Each pod is also individually addressable
kubectl get pods -l app=nginxsvc -o jsonpath='{range .items[*]}{.status.podIP}{"\n"}{end}'
```

## Multi-Port Services

Real applications often expose multiple ports for different purposes:

```bash
# Deploy multi-port application
kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: multi-port-app
spec:
  replicas: 2
  selector:
    matchLabels:
      app: multi-port-app
  template:
    metadata:
      labels:
        app: multi-port-app
    spec:
      containers:
      - name: app
        image: nginxdemos/nginx-hello:latest
        ports:
        - containerPort: 8080
          name: http
        - containerPort: 8443
          name: https
      - name: metrics
        image: prom/node-exporter:latest
        ports:
        - containerPort: 9100
          name: metrics
---
apiVersion: v1
kind: Service
metadata:
  name: multi-port-service
spec:
  selector:
    app: multi-port-app
  ports:
  - name: http
    port: 80
    targetPort: http
  - name: https  
    port: 443
    targetPort: https
  - name: metrics
    port: 9090
    targetPort: 9100
EOF

# Wait for pods to be ready
kubectl wait --for=condition=ready pod -l app=multi-port-app --timeout=60s

# Check service endpoints for all ports
kubectl describe service multi-port-service
kubectl get endpointslices -l kubernetes.io/service-name=multi-port-service -o yaml

# Test each port
kubectl run test --image=busybox:1.35 --rm -it --restart=Never -- wget -O- http://multi-port-service:80
kubectl run test --image=busybox:1.35 --rm -it --restart=Never -- wget -O- http://multi-port-service:9090/metrics 2>&1 | head -20

# Check SRV records for named ports
kubectl run test --image=nicolaka/netshoot:latest --rm -it --restart=Never -- dig _http._tcp.multi-port-service.default.svc.cluster.local SRV
```

## DNS and Service Discovery

### Understanding Kubernetes DNS

CoreDNS provides automatic DNS resolution for Services and Pods. Let's explore how it works:

```bash
# Check DNS service in kube-system
kubectl get svc -n kube-system kube-dns
kubectl get deployment -n kube-system coredns

# Verify CoreDNS is running
kubectl get pods -n kube-system -l k8s-app=kube-dns

# Check CoreDNS configuration
kubectl get configmap -n kube-system coredns -o yaml

# See DNS configuration injected into pods
kubectl run dnstest --image=busybox:1.35 --rm -it --restart=Never -- cat /etc/resolv.conf
```

### DNS Resolution Patterns

Services get DNS names in multiple formats for flexibility:

```bash
# Create a test namespace
kubectl create namespace dns-test

# Create services in different namespaces
kubectl create deployment web --image=nginx:1.21 -n dns-test
kubectl expose deployment web --port=80 -n dns-test

kubectl create deployment app --image=nginx:1.21
kubectl expose deployment app --port=80

# Wait for deployments
kubectl wait --for=condition=available deployment/web -n dns-test --timeout=60s
kubectl wait --for=condition=available deployment/app --timeout=60s

# Test DNS resolution from default namespace
kubectl run test --image=nicolaka/netshoot:latest --rm -it --restart=Never -- /bin/bash

# Inside the pod, test different DNS formats:
# Same namespace (short name)
nslookup app
curl http://app

# Different namespace (namespace qualified)
nslookup web.dns-test
curl http://web.dns-test

# Fully qualified domain name
nslookup web.dns-test.svc.cluster.local
curl http://web.dns-test.svc.cluster.local

# Cluster DNS suffix
nslookup web.dns-test.svc
curl http://web.dns-test.svc

# Exit the test pod
exit
```

### Cross-Namespace Communication

```bash
# Create a more complex cross-namespace scenario
kubectl create namespace frontend
kubectl create namespace backend
kubectl create namespace database

# Deploy services in each namespace
kubectl create deployment frontend --image=nginx:1.21 -n frontend
kubectl expose deployment frontend --port=80 -n frontend

kubectl create deployment api --image=kong/httpbin:latest -n backend
kubectl expose deployment api --port=80 --target-port=80 -n backend

# Deploy database with required environment variable
kubectl create deployment db --image=postgres:13-alpine -n database --env="POSTGRES_PASSWORD=testpass"
kubectl expose deployment db --port=5432 -n database

# Wait for deployments to be ready
kubectl wait --for=condition=available deployment/frontend -n frontend --timeout=60s
kubectl wait --for=condition=available deployment/api -n backend --timeout=60s
kubectl wait --for=condition=available deployment/db -n database --timeout=60s

# Create a debug pod in frontend namespace
kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: debug-pod
  namespace: frontend
spec:
  containers:
  - name: debug
    image: nicolaka/netshoot:latest
    command: ["/bin/sleep", "3600"]
EOF

# Wait for pod to be ready
kubectl wait --for=condition=ready pod/debug-pod -n frontend --timeout=60s

# Test cross-namespace communication
kubectl exec -n frontend debug-pod -- nslookup api.backend
kubectl exec -n frontend debug-pod -- curl -s http://api.backend/headers
kubectl exec -n frontend debug-pod -- nslookup db.database
```

## Network Policies

Network Policies provide Layer 3/4 network security within the cluster. They require a CNI plugin that supports them.

### Checking Network Policy Support

```bash
# Check if your CNI supports NetworkPolicies
# Look for a network plugin that supports policies
echo "Checking for NetworkPolicy-capable CNI..."
kubectl get pods -n kube-system | grep -E 'calico|cilium|weave|canal' || echo "Warning: Your CNI might not support Network Policies"

# Try creating a test policy
kubectl apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: test-network-policy
spec:
  podSelector:
    matchLabels:
      app: test
  policyTypes:
  - Ingress
EOF

# If it creates successfully, your CNI supports policies
kubectl get networkpolicy

# Clean up test policy
kubectl delete networkpolicy test-network-policy
```

### Network Policy Scenarios

#### Scenario 1: Default Deny All

Start with a zero-trust approach by denying all traffic:

```bash
# Create a test namespace with isolated networking
kubectl create namespace secure-app

# Deploy test applications
kubectl create deployment web --image=nginx:1.21 --replicas=2 -n secure-app
kubectl expose deployment web --port=80 -n secure-app

kubectl create deployment backend --image=kong/httpbin:latest -n secure-app
kubectl expose deployment backend --port=80 -n secure-app

# Wait for deployments
kubectl wait --for=condition=available deployment/web -n secure-app --timeout=60s
kubectl wait --for=condition=available deployment/backend -n secure-app --timeout=60s

# Create test client pod
kubectl run client --image=busybox:1.35 -n secure-app --command -- sleep 3600

# Wait for client pod
kubectl wait --for=condition=ready pod/client -n secure-app --timeout=60s

# Test connectivity before policies (should work)
kubectl exec -n secure-app client -- wget --timeout=2 -O- http://web
kubectl exec -n secure-app client -- wget --timeout=2 -O- http://backend

# Apply default deny all policy
kubectl apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: secure-app
spec:
  podSelector: {}
  policyTypes:
  - Ingress
  - Egress
EOF

# Test connectivity after policy (should fail)
kubectl exec -n secure-app client -- wget --timeout=2 -O- http://web 2>&1 || echo "Blocked as expected"
kubectl exec -n secure-app client -- wget --timeout=2 -O- http://backend 2>&1 || echo "Blocked as expected"
```

#### Scenario 2: Allow Specific Ingress

Selectively allow traffic to specific services:

```bash
# Allow ingress to web from client only
kubectl apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: web-allow-client
  namespace: secure-app
spec:
  podSelector:
    matchLabels:
      app: web
  policyTypes:
  - Ingress
  ingress:
  - from:
    - podSelector:
        matchLabels:
          run: client
    ports:
    - protocol: TCP
      port: 80
EOF

# Allow DNS for all pods (required for service discovery)
kubectl apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-dns-access
  namespace: secure-app
spec:
  podSelector: {}
  policyTypes:
  - Egress
  egress:
  - to:
    - namespaceSelector: {}
      podSelector:
        matchLabels:
          k8s-app: kube-dns
    ports:
    - protocol: UDP
      port: 53
    - protocol: TCP
      port: 53
EOF

# Allow client to reach web
kubectl apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: client-allow-egress-to-web
  namespace: secure-app
spec:
  podSelector:
    matchLabels:
      run: client
  policyTypes:
  - Egress
  egress:
  - to:
    - podSelector:
        matchLabels:
          app: web
    ports:
    - protocol: TCP
      port: 80
  - to:  # Always allow DNS
    - namespaceSelector: {}
      podSelector:
        matchLabels:
          k8s-app: kube-dns
    ports:
    - protocol: UDP
      port: 53
EOF

# Test connectivity (web should work, backend should fail)
kubectl exec -n secure-app client -- wget --timeout=2 -O- http://web
kubectl exec -n secure-app client -- wget --timeout=2 -O- http://backend 2>&1 || echo "Backend blocked as expected"
```

#### Scenario 3: Cross-Namespace Policies

Control traffic between namespaces:

```bash
# Label namespaces for selection
kubectl label namespace secure-app environment=secure --overwrite
kubectl label namespace default environment=default --overwrite
kubectl label namespace kube-system name=kube-system --overwrite

# Allow ingress from specific namespace
kubectl apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-from-default
  namespace: secure-app
spec:
  podSelector:
    matchLabels:
      app: backend
  policyTypes:
  - Ingress
  ingress:
  - from:
    - namespaceSelector:
        matchLabels:
          environment: default
    ports:
    - protocol: TCP
      port: 80
EOF

# Test from default namespace (should work for backend)
kubectl run test-default --image=busybox:1.35 --rm -it --restart=Never -- wget --timeout=2 -O- http://backend.secure-app
```

#### Scenario 4: Egress to External Services

Control outbound traffic to the internet:

```bash
# Allow egress to specific external IPs only
kubectl apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-external-egress
  namespace: secure-app
spec:
  podSelector:
    matchLabels:
      app: web
  policyTypes:
  - Egress
  egress:
  - to:
    - ipBlock:
        cidr: 0.0.0.0/0
        except:
        - 169.254.169.254/32  # Block metadata service
        - 10.0.0.0/8          # Block internal networks
        - 192.168.0.0/16
        - 172.16.0.0/12
    ports:
    - protocol: TCP
      port: 80
    - protocol: TCP
      port: 443
  - to:  # Always allow DNS
    - namespaceSelector: {}
      podSelector:
        matchLabels:
          k8s-app: kube-dns
    ports:
    - protocol: UDP
      port: 53
EOF

# Test external connectivity from web pods
kubectl exec -n secure-app deploy/web -- sh -c 'wget --timeout=2 -O- http://example.com 2>/dev/null | head -5 || echo "Connection may be blocked by policy"'
```
