## Understanding Kubernetes and Its Purpose

### Why Kubernetes Exists

Kubernetes emerged from Google's need to manage billions of containers across thousands of machines. While Docker solved the problem of packaging applications consistently, it didn't address the complexity of running hundreds or thousands of containers in production. Questions like "Which server should run this container?", "What happens when a container crashes?", "How do we update without downtime?", and "How do we scale based on load?" needed systematic answers.

Kubernetes provides these answers through a declarative orchestration system. Instead of telling Kubernetes exactly how to run your applications (imperative), you describe what you want (declarative), and Kubernetes figures out how to achieve and maintain that state. This fundamental shift from "do this" to "make it like this" enables self-healing, auto-scaling, and continuous reconciliation—the core strengths of Kubernetes.

### The Declarative Model in Practice

To understand the declarative model, imagine the difference between giving turn-by-turn driving directions versus providing a destination address to a GPS. With turn-by-turn directions (imperative), any wrong turn requires new instructions from the beginning. With a GPS destination (declarative), the system continuously recalculates the best route regardless of detours, traffic, or mistakes.

Kubernetes works like that GPS. You declare "I want 3 copies of my web application running," and Kubernetes ensures exactly 3 copies run at all times. If one crashes, Kubernetes starts a replacement. If a server fails, Kubernetes reschedules the containers elsewhere. You declare the destination; Kubernetes handles the journey.

## Kubernetes Cluster Architecture

### The Two-Tier Architecture

A Kubernetes cluster consists of two distinct types of machines working in concert: the control plane (the brain) and worker nodes (the muscles). This separation of concerns allows each component to focus on its specific responsibilities while maintaining cluster-wide coordination.

The control plane makes global decisions about the cluster—scheduling applications, maintaining desired state, rolling out updates, and responding to events. Worker nodes provide the computational resources where your actual applications run. This architecture scales elegantly: you can add more worker nodes for capacity without complicating cluster management, and you can replicate control plane components for high availability without affecting application workloads.

### Control Plane Components: The Cluster's Brain

The control plane orchestrates the entire cluster through several specialized components, each handling specific aspects of cluster management. In development environments, all control plane components might run on a single machine. In production, they're distributed across multiple machines for resilience, with components automatically failing over if issues occur.

#### kube-apiserver: The Communication Hub

The API server is the front door to your Kubernetes cluster—every single operation passes through it. When you run a kubectl command, when applications query cluster state, when nodes report status, or when controllers take action, they all communicate through the API server. 

Think of it as the central nervous system of the cluster. It doesn't make decisions itself but provides the communication pathway for all components. The API server validates requests, authenticates users, authorizes actions, and then persists approved changes to etcd. It also serves as the aggregation point for all cluster information, transforming and serving data from etcd in a consumable format.

The API server exposes a RESTful interface, making it accessible to any HTTP client. This design enables the rich ecosystem of Kubernetes tools and allows you to interact with the cluster using any programming language. Every resource in Kubernetes—Pods, Services, Deployments—is accessible through standardized REST endpoints like `/api/v1/pods` or `/apis/apps/v1/deployments`.

#### etcd: The Cluster's Memory

etcd serves as the cluster's source of truth, storing all cluster data in a distributed key-value store. Every piece of information about your cluster—from pod definitions to configuration secrets—lives in etcd. It's the only stateful component in the control plane, making it critically important for cluster operation.

What makes etcd special is its consistency guarantees. Using the Raft consensus algorithm, etcd ensures that data remains consistent across multiple instances even during network partitions or node failures. When you update a Deployment, that change is written to etcd. When the scheduler needs to find nodes for pods, it queries etcd. When controllers check current state, they read from etcd.

The distributed nature of etcd enables high availability. In production clusters, etcd typically runs on 3, 5, or 7 nodes (odd numbers prevent split-brain scenarios). If the leader fails, the remaining nodes quickly elect a new leader, ensuring continuous availability. This resilience makes etcd the foundation of Kubernetes' fault tolerance.

#### kube-scheduler: The Matchmaker

The scheduler has one job: finding the best home for newly created Pods. When you create a Deployment requesting 3 replicas, the scheduler decides which worker nodes should run those Pods. This decision-making process is surprisingly sophisticated.

The scheduler operates in two phases. First, it filters nodes that don't meet the Pod's requirements—nodes without enough CPU or memory, nodes with incompatible hardware, nodes explicitly excluded by node selectors. Second, it scores the remaining nodes based on various factors: spreading Pods across nodes for high availability, bin packing to maximize resource utilization, respecting affinity rules that keep or separate certain Pods.

The scheduler's decisions are optimal at the moment but not permanent. If a better node becomes available later, the scheduler won't move existing Pods (that would be disruptive). However, if a Pod needs to be rescheduled due to node failure or eviction, the scheduler makes a fresh decision based on current cluster state.

#### kube-controller-manager: The Enforcement System

The controller manager runs multiple control loops that continuously monitor cluster state and take corrective action when reality doesn't match desired state. Think of controllers as thermostats—they measure current temperature (state), compare it to desired temperature (spec), and take action (heating/cooling) to close the gap.

The controller manager bundles many controllers:

- **Node Controller**: Monitors node health, marking nodes as unavailable when they stop responding and evicting Pods from unreachable nodes after a timeout.
- **Replication Controller**: Ensures the correct number of Pod replicas exist, creating new Pods when there are too few and deleting excess Pods when there are too many.
- **Endpoints Controller**: Populates the Endpoints object that links Services to Pods, updating these connections as Pods come and go.
- **Service Account Controller**: Creates default service accounts for new namespaces, enabling Pods to authenticate with the API server.

Each controller follows the same pattern: watch for changes, compare desired state with actual state, take action to reconcile differences. This continuous reconciliation loop is the heart of Kubernetes' self-healing capabilities.

### Worker Node Components: Where Applications Run

Worker nodes are the workhorses of the cluster, providing CPU, memory, and storage for your applications. Each worker node runs several components that enable container execution and cluster participation. Unlike control plane components that make cluster-wide decisions, node components focus on local execution and resource management.

#### Container Runtime: The Engine

The container runtime is the software that actually runs containers on each node. While Docker was the original runtime, Kubernetes now supports any runtime implementing the Container Runtime Interface (CRI), including containerd, CRI-O, and others.

The runtime handles the complete container lifecycle: pulling images from registries, creating container sandboxes with proper isolation, starting and stopping containers, managing container resources, and cleaning up terminated containers. It translates high-level Pod specifications into low-level system calls that create isolated processes.

The abstraction of CRI means Kubernetes doesn't care which runtime you use—it speaks CRI, and the runtime translates to its native operations. This flexibility allows you to choose runtimes based on your needs: containerd for simplicity, CRI-O for Red Hat environments, or specialized runtimes for specific security or performance requirements.

#### kubelet: The Node Agent

The kubelet is Kubernetes' agent on each worker node, responsible for ensuring containers run in Pods according to their specifications. It's the component that translates Pod definitions into running containers, bridging the gap between Kubernetes abstractions and system reality.

The kubelet's primary workflow is straightforward but critical:

1. **Registration**: When starting, kubelet registers the node with the API server, advertising available resources and capabilities
2. **Pod Assignment**: kubelet watches the API server for Pods assigned to its node
3. **Container Management**: For each Pod, kubelet ensures all containers are running with correct configurations
4. **Health Monitoring**: kubelet continuously checks container and Pod health, reporting status to the API server
5. **Resource Enforcement**: kubelet enforces resource limits, evicting Pods if the node runs low on resources

The kubelet only manages containers created through Kubernetes. If you manually start a container with Docker, kubelet ignores it. This separation ensures Kubernetes maintains complete control over its managed workloads while allowing other processes to coexist on the same nodes.

#### kube-proxy: The Network Magician

kube-proxy enables the Kubernetes Service abstraction, making network communication seamless despite Pods constantly being created and destroyed. It runs on every node, maintaining network rules that direct traffic to the appropriate Pods.

Understanding kube-proxy requires understanding the problem it solves. Pods are ephemeral—they come and go, getting new IP addresses each time. If your frontend Pod needs to communicate with backend Pods, hardcoding IP addresses won't work. Services provide stable virtual IPs, and kube-proxy makes these virtual IPs actually work.

kube-proxy operates in different modes:

- **iptables mode** (default): Programs Linux iptables rules to redirect Service traffic directly to Pod IPs. Efficient but becomes complex with many Services.
- **IPVS mode**: Uses Linux IPVS for load balancing, providing better performance with thousands of Services and more load balancing algorithms.
- **userspace mode** (legacy): Proxies traffic through a userspace process. Slower but works everywhere.

When you access a Service, kube-proxy's rules intercept the traffic and redirect it to one of the Service's backend Pods, implementing load balancing at the kernel level for maximum performance.

### Cluster Add-ons: Extended Functionality

Add-ons are pods and services that implement cluster features beyond core Kubernetes functionality. While optional, most clusters require several add-ons for practical operation. These components run as regular Kubernetes workloads, managed by the same mechanisms as your applications.

#### DNS: The Name Resolution Service

The DNS add-on (typically CoreDNS) provides crucial name resolution within the cluster. Without DNS, Pods would need to discover each other using IP addresses, which change frequently. DNS enables service discovery through predictable names.

When you create a Service named "database" in the "production" namespace, DNS automatically creates records:
- `database.production` - accessible from within the same namespace
- `database.production.svc.cluster.local` - fully qualified domain name accessible from anywhere in the cluster

Pods can simply reference services by name, and DNS resolves them to the current cluster IP. This abstraction means your application code doesn't need to know about IP addresses or even which namespace it's running in—it just needs to know service names.

#### Dashboard: Visual Cluster Management

The Kubernetes Dashboard provides a web-based UI for cluster management. While kubectl offers complete control, the Dashboard makes common tasks more intuitive, especially for users less comfortable with command-line interfaces.

Through the Dashboard, you can:
- Deploy containerized applications using forms or YAML
- Troubleshoot applications by viewing logs and executing into containers
- Manage cluster resources with visual editors
- Monitor resource usage with built-in graphs
- Scale deployments with simple controls

The Dashboard essentially provides a visual wrapper around kubectl commands, making Kubernetes more accessible while maintaining the same underlying operations.

#### Metrics and Monitoring

Monitoring add-ons collect and aggregate metrics from containers, nodes, and the control plane. The Metrics Server provides basic CPU and memory metrics used by autoscaling. More comprehensive solutions like Prometheus collect detailed metrics for analysis and alerting.

These metrics answer critical questions: Which Pods consume the most resources? When do traffic spikes occur? Are nodes reaching capacity? Is application performance degrading? Without monitoring, you're flying blind in production.

#### Ingress Controllers

Ingress controllers implement the Ingress resource, providing HTTP/HTTPS routing to services. Popular options include NGINX, Traefik, and HAProxy. The controller watches for Ingress resources and configures itself accordingly, automatically updating routing rules as you deploy new applications.

## Kubernetes Objects: The Building Blocks

### Understanding Kubernetes Objects

Kubernetes objects are persistent entities that represent your cluster's state. When you create an object, you're telling Kubernetes "this is what I want to exist in my cluster." Kubernetes then works continuously to ensure that object exists and maintains its specified characteristics.

Objects aren't just data structures—they're living entities with controllers watching them. Create a Deployment object requesting 3 replicas, and the Deployment controller ensures 3 Pods always run. Create a Service object, and the Endpoints controller maintains the connection between the Service and its Pods. This object-controller pattern permeates Kubernetes.

Every object follows the same fundamental pattern:

1. **You declare desired state** through the object's specification
2. **Controllers watch** for objects they manage
3. **Controllers take action** to achieve desired state
4. **The system updates** object status to reflect current state
5. **Controllers continue watching**, repeating the cycle

This pattern enables Kubernetes' self-healing behavior. Objects declare what should exist; controllers make it happen.

### Object Specification and Status: Desired vs. Actual

Every Kubernetes object contains two critical nested structures that work together to enable declarative management:

#### The Spec Field: What You Want

The spec defines your desired state—the characteristics you want the object to have. When you create a Deployment with `replicas: 3`, you're populating the spec. When you set `image: nginx:latest`, you're defining the spec. The spec is your declaration of intent.

Different object types have different spec structures:
- Pod specs define containers, volumes, and scheduling constraints
- Service specs define ports, selectors, and service types  
- Deployment specs define replica counts, update strategies, and Pod templates
- ConfigMap specs contain configuration data

The spec is immutable for some fields (you can't change a Pod's nodeName once scheduled) but mutable for others (you can update a Deployment's replica count anytime). These mutability rules prevent impossible state transitions while enabling dynamic management.

#### The Status Field: What Actually Is

The status reflects current observed state as determined by controllers and the kubelet. While you define the spec, Kubernetes manages the status. You can read the status, but you can't directly modify it—it's the system's record of reality.

Status information varies by object type:
- Pod status includes phase (Pending, Running, Succeeded, Failed), conditions, and container states
- Deployment status shows available replicas, updated replicas, and deployment conditions
- Node status reports capacity, allocatable resources, and node conditions
- Service status might include load balancer endpoints once provisioned

The continuous reconciliation between spec and status drives everything in Kubernetes. When they don't match, controllers take action. This gap between desired and actual state is where Kubernetes does its work.

### Required Object Fields

Every Kubernetes object must include four fields that provide essential metadata and typing information:

#### apiVersion: The API Contract

The apiVersion specifies which version of the Kubernetes API you're using to create the object. This isn't just bureaucracy—it's a contract between you and Kubernetes about what fields are available and how they behave.

API versions follow a progression:
- `v1alpha1`: Early experimental API, may change dramatically
- `v1beta1`: More stable but still evolving
- `v1`: Stable API with backward compatibility guarantees

Different resources live at different API versions. Core resources like Pods and Services use `v1`. Deployments use `apps/v1`. Ingresses use `networking.k8s.io/v1`. This versioning allows Kubernetes to evolve APIs without breaking existing configurations.

#### kind: The Object Type

The kind field specifies what type of object you're creating. This determines which controller manages the object, what fields are valid in the spec, and how the object behaves. Common kinds include Pod, Service, Deployment, ConfigMap, Secret, and dozens more.

The kind is immutable—you can't change a Deployment into a Service. Each kind has specific behaviors and purposes that define its role in the cluster.

#### metadata: The Object's Identity

The metadata section contains information that uniquely identifies the object:

- **name**: The object's name within its namespace (must be unique)
- **namespace**: Which namespace contains the object (defaults to "default")
- **uid**: A system-generated unique identifier
- **labels**: Key-value pairs for organization and selection
- **annotations**: Key-value pairs for storing additional information

Metadata provides the framework for finding, organizing, and managing objects throughout their lifecycle.

#### spec: The Desired State

The spec contains the desired state specific to the object's kind. This is where you define what you want: which containers to run, how many replicas, what ports to expose, which nodes to use. The spec structure varies completely between different kinds—a Pod spec looks nothing like a Service spec.

## Core Kubernetes Resources

### Pods: The Atomic Unit

Pods are Kubernetes' fundamental execution unit, but they're often misunderstood. A Pod isn't just a container—it's a collection of one or more containers that are tightly coupled and need to work together. These containers share networking (same IP address and port space) and storage (can mount the same volumes).

Why not just run containers directly? Pods provide several critical capabilities:

**Shared Networking**: Containers in a Pod communicate via localhost, eliminating complex service discovery between tightly coupled components. A web server and its logging sidecar can communicate directly without network overhead.

**Shared Storage**: Containers can share volumes, enabling patterns like web servers serving static files while other containers update those files.

**Atomic Scheduling**: All containers in a Pod are scheduled to the same node and start/stop together, ensuring coupled components aren't separated.

**Shared Lifecycle**: The Pod's containers live and die together, simplifying coordination between interdependent processes.

Here's a complete Pod example showing these concepts:

```yaml
# File: pod-example.yaml
apiVersion: v1
kind: Pod
metadata:
  name: web-app
  labels:
    app: nginx
    environment: production
spec:
  # All containers share the Pod's network namespace
  containers:
  # Main application container
  - name: nginx
    image: nginx:1.21
    ports:
    - containerPort: 80
      name: http
    volumeMounts:
    - name: shared-data
      mountPath: /usr/share/nginx/html
    resources:
      requests:
        memory: "64Mi"
        cpu: "250m"
      limits:
        memory: "128Mi"
        cpu: "500m"
  
  # Sidecar container that updates content
  - name: content-updater
    image: busybox
    command: ["/bin/sh"]
    args: ["-c", "while true; do echo $(date) > /data/index.html; sleep 30; done"]
    volumeMounts:
    - name: shared-data
      mountPath: /data
  
  # Shared volume accessible to both containers
  volumes:
  - name: shared-data
    emptyDir: {}
```

Despite being fundamental, you rarely create Pods directly. They're ephemeral by design—when a Pod dies, it's gone forever. Higher-level controllers like Deployments create and manage Pods, providing durability through replacement rather than resurrection.

### Deployments: Production-Ready Applications

Deployments solve the limitations of raw Pods by adding production-essential features: maintaining desired replica counts, rolling updates, rollback capabilities, and self-healing. When you want to run a stateless application in Kubernetes, Deployment is your go-to resource.

A Deployment manages Pods through a template and replica count. It ensures the specified number of Pods always run, replacing failed Pods automatically. During updates, it orchestrates the controlled replacement of old Pods with new ones, maintaining availability throughout.

Here's a comprehensive Deployment example:

```yaml
# File: deployment-example.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web-frontend
  labels:
    app: web-frontend
    tier: frontend
spec:
  # Desired number of replicas
  replicas: 3
  
  # How Deployment finds its Pods
  selector:
    matchLabels:
      app: web-frontend
  
  # Rolling update strategy
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1        # Max pods above desired count during update
      maxUnavailable: 1  # Max pods unavailable during update
  
  # Pod template - Deployment creates Pods from this
  template:
    metadata:
      labels:
        app: web-frontend
        tier: frontend
        version: v2
    spec:
      containers:
      - name: webapp
        image: nginx:1.21
        ports:
        - containerPort: 80
          name: http
        
        # Liveness probe - container is restarted if this fails
        livenessProbe:
          httpGet:
            path: /healthz
            port: 80
          initialDelaySeconds: 30
          periodSeconds: 10
        
        # Readiness probe - pod isn't sent traffic until this succeeds
        readinessProbe:
          httpGet:
            path: /ready
            port: 80
          initialDelaySeconds: 5
          periodSeconds: 5
        
        # Environment variables
        env:
        - name: ENVIRONMENT
          value: "production"
        - name: LOG_LEVEL
          value: "info"
        
        # Resource management
        resources:
          requests:
            memory: "128Mi"
            cpu: "100m"
          limits:
            memory: "256Mi"
            cpu: "200m"
```

Deployments excel at managing stateless applications—web servers, APIs, microservices—where any replica can handle any request. The Deployment controller continuously ensures the desired number of healthy Pods run, automatically replacing any that fail or are evicted.

### Services: Stable Network Endpoints

Services solve a fundamental networking challenge: Pods are ephemeral with changing IP addresses, but applications need stable endpoints for communication. A Service provides a constant virtual IP address and DNS name that automatically routes traffic to healthy Pods.

Services use label selectors to identify their backend Pods dynamically. As Pods come and go, the Service automatically updates its endpoints. This decoupling between service identity and Pod instances enables zero-downtime deployments and automatic failover.

Kubernetes offers several Service types for different use cases:

```yaml
# File: service-examples.yaml
---
# ClusterIP Service - Internal cluster communication
apiVersion: v1
kind: Service
metadata:
  name: backend-service
spec:
  type: ClusterIP  # Default type, only accessible within cluster
  selector:
    app: backend   # Routes to all Pods with this label
  ports:
  - port: 80       # Service port
    targetPort: 8080  # Pod port
    protocol: TCP

---
# NodePort Service - External access via node ports
apiVersion: v1
kind: Service
metadata:
  name: web-nodeport
spec:
  type: NodePort
  selector:
    app: web-frontend
  ports:
  - port: 80
    targetPort: 80
    nodePort: 30080  # Accessible on every node at this port (30000-32767)

---
# LoadBalancer Service - Cloud provider load balancer
apiVersion: v1
kind: Service
metadata:
  name: web-loadbalancer
spec:
  type: LoadBalancer
  selector:
    app: web-frontend
  ports:
  - port: 80
    targetPort: 80
  # Cloud provider assigns external IP

---
# Headless Service - For direct Pod access
apiVersion: v1
kind: Service
metadata:
  name: database-headless
spec:
  clusterIP: None  # No virtual IP, just DNS records for Pods
  selector:
    app: database
  ports:
  - port: 5432
    targetPort: 5432
```

Services implement load balancing at the connection level, distributing traffic across healthy backend Pods. The kube-proxy component on each node maintains the networking rules that make Services work, ensuring traffic reaches the right destinations.

### ConfigMaps: Externalizing Configuration

ConfigMaps decouple configuration from container images, enabling the same image to run across different environments with different configurations. Instead of baking configuration into images or using complex templating, ConfigMaps provide a clean separation of concerns.

ConfigMaps can store entire configuration files, individual key-value pairs, or both. Pods consume ConfigMaps either as environment variables or mounted files, allowing flexible configuration injection:

```yaml
# File: configmap-example.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: app-config
data:
  # Key-value pairs
  database_url: "postgres://localhost:5432/myapp"
  log_level: "debug"
  max_connections: "100"
  
  # Complete configuration file
  app.properties: |
    # Application Configuration
    server.port=8080
    server.host=0.0.0.0
    
    # Database Settings
    db.pool.min=10
    db.pool.max=100
    db.timeout=30s
    
    # Feature Flags
    feature.newUI=true
    feature.analytics=false
  
  # JSON configuration
  features.json: |
    {
      "featureFlags": {
        "newUI": true,
        "analytics": false,
        "betaFeatures": true
      },
      "limits": {
        "maxUsers": 1000,
        "maxRequests": 10000
      }
    }
```

Using ConfigMaps in Pods:

```yaml
# File: pod-with-configmap.yaml
apiVersion: v1
kind: Pod
metadata:
  name: configured-app
spec:
  containers:
  - name: app
    image: myapp:latest
    
    # Mount entire ConfigMap as environment variables
    envFrom:
    - configMapRef:
        name: app-config
    
    # Mount specific keys as environment variables
    env:
    - name: DB_URL
      valueFrom:
        configMapKeyRef:
          name: app-config
          key: database_url
    
    # Mount ConfigMap as files
    volumeMounts:
    - name: config-volume
      mountPath: /etc/config
  
  volumes:
  - name: config-volume
    configMap:
      name: app-config
      items:
      - key: app.properties
        path: application.properties
      - key: features.json
        path: features.json
```

ConfigMaps enable configuration hot-reloading when mounted as volumes—update the ConfigMap, and files in Pods automatically update (though applications must watch for changes). This enables dynamic reconfiguration without Pod restarts.

### Secrets: Sensitive Data Management

Secrets work like ConfigMaps but are designed for sensitive data like passwords, tokens, and keys. While ConfigMaps store data in plain text, Secrets encode data in base64 and can be encrypted at rest in etcd.

```yaml
# File: secret-example.yaml
apiVersion: v1
kind: Secret
metadata:
  name: db-credentials
type: Opaque
data:
  # Values must be base64 encoded
  username: YWRtaW4=  # admin
  password: cGFzc3dvcmQxMjM=  # password123

---
# Using stringData for automatic encoding
apiVersion: v1
kind: Secret
metadata:
  name: api-keys
type: Opaque
stringData:  # Kubernetes encodes these automatically
  api-key: "sk_live_abcd1234"
  webhook-secret: "whsec_xyz789"
```

Secrets integrate with Pods similarly to ConfigMaps but with additional security considerations:

```yaml
# File: pod-with-secrets.yaml
apiVersion: v1
kind: Pod
metadata:
  name: secure-app
spec:
  containers:
  - name: app
    image: myapp:latest
    
    # Mount secrets as environment variables
    env:
    - name: DB_USERNAME
      valueFrom:
        secretKeyRef:
          name: db-credentials
          key: username
    - name: DB_PASSWORD
      valueFrom:
        secretKeyRef:
          name: db-credentials
          key: password
    
    # Mount secrets as files (more secure than env vars)
    volumeMounts:
    - name: secret-volume
      mountPath: /etc/secrets
      readOnly: true
  
  volumes:
  - name: secret-volume
    secret:
      secretName: api-keys
      defaultMode: 0400  # Read-only for owner only
```

Kubernetes provides several Secret types for specific use cases:
- `Opaque`: Arbitrary user-defined data (default)
- `kubernetes.io/service-account-token`: Service account tokens
- `kubernetes.io/dockercfg`: Docker registry credentials
- `kubernetes.io/tls`: TLS certificates and keys

### Persistent Volumes: Durable Storage

PersistentVolumes (PVs) and PersistentVolumeClaims (PVCs) abstract storage details from Pod definitions. Instead of Pods directly referencing storage implementations, they claim storage with certain characteristics, and Kubernetes provisions appropriate volumes.

This abstraction enables portability—the same Pod definition works whether storage comes from AWS EBS, Google Persistent Disks, NFS, or local SSDs. The cluster administrator configures available storage; developers just request what they need.

```yaml
# File: storage-example.yaml
---
# PersistentVolume - Actual storage resource
apiVersion: v1
kind: PersistentVolume
metadata:
  name: data-pv
spec:
  capacity:
    storage: 10Gi
  accessModes:
    - ReadWriteOnce  # Single node read-write
  persistentVolumeReclaimPolicy: Retain  # Keep data after claim deletion
  storageClassName: fast-ssd
  # Actual storage implementation (varies by provider)
  hostPath:  # For testing only!
    path: /mnt/data

---
# PersistentVolumeClaim - Request for storage
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: data-claim
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 5Gi
  storageClassName: fast-ssd

---
# Pod using the PVC
apiVersion: v1
kind: Pod
metadata:
  name: database-pod
spec:
  containers:
  - name: postgres
    image: postgres:13
    volumeMounts:
    - name: data-volume
      mountPath: /var/lib/postgresql/data
  volumes:
  - name: data-volume
    persistentVolumeClaim:
      claimName: data-claim
```

Storage classes enable dynamic provisioning—instead of pre-creating PVs, the cluster automatically provisions storage when PVCs are created:

```yaml
# File: storageclass-example.yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: fast-ssd
provisioner: kubernetes.io/aws-ebs  # Cloud-specific provisioner
parameters:
  type: gp3
  iopsPerGB: "100"
reclaimPolicy: Delete
volumeBindingMode: WaitForFirstConsumer  # Provision only when Pod is scheduled
```

## Labels and Selectors: Organizing Your Cluster

### Understanding Labels

Labels are key-value pairs attached to Kubernetes objects that enable flexible, multi-dimensional organization. Unlike hierarchical naming systems that force single classification paths, labels allow objects to belong to multiple overlapping categories simultaneously.

Consider a microservices application: a single Pod might need classification by application component (frontend), environment (production), version (v2.1), customer (customer-a), and team ownership (platform-team). Hierarchical naming can't elegantly represent these overlapping dimensions, but labels handle them naturally:

```yaml
# File: labeled-resources.yaml
apiVersion: v1
kind: Pod
metadata:
  name: frontend-pod-1
  labels:
    app: shopping-cart
    component: frontend
    environment: production
    version: v2.1.0
    customer: customer-a
    team: platform-team
    tier: web
    release-track: stable
spec:
  containers:
  - name: web
    image: frontend:v2.1.0
```

Labels enable powerful organizational patterns:

**Environmental Progression**: Label resources with `environment: dev`, `environment: staging`, or `environment: prod` to distinguish deployment stages.

**Version Management**: Track multiple versions simultaneously with labels like `version: v1.0`, `version: v2.0-beta`.

**Team Ownership**: Identify responsible teams with `team: payments`, `team: inventory`.

**Cost Attribution**: Track resource costs with `cost-center: marketing`, `project: black-friday`.

**Architectural Tiers**: Organize by application layer with `tier: frontend`, `tier: backend`, `tier: cache`.

### Label Selectors: Finding What You Need

Label selectors are the query language for finding Kubernetes objects. They come in two flavors, each with different capabilities:

#### Equality-Based Selectors

Equality-based selectors use simple matching:

```bash
# Select all production resources
kubectl get pods -l environment=production

# Select non-production resources
kubectl get pods -l environment!=production

# Multiple requirements (AND logic)
kubectl get pods -l environment=production,tier=frontend

# In Service definition
apiVersion: v1
kind: Service
metadata:
  name: production-frontend
spec:
  selector:
    environment: production
    tier: frontend
```

#### Set-Based Selectors

Set-based selectors offer more sophisticated matching:

```bash
# Select resources in specific environments
kubectl get pods -l 'environment in (production, staging)'

# Exclude certain versions
kubectl get pods -l 'version notin (v1.0, v1.1)'

# Select resources with a label regardless of value
kubectl get pods -l 'customer'

# Combine multiple selectors
kubectl get pods -l 'environment in (production),tier=frontend,!canary'
```

In YAML manifests:

```yaml
# File: deployment-with-selectors.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web-deployment
spec:
  replicas: 3
  selector:
    matchLabels:
      app: web
    matchExpressions:
    - key: environment
      operator: In
      values: [production, staging]
    - key: tier
      operator: NotIn
      values: [database]
    - key: canary
      operator: DoesNotExist
```

### Practical Labeling Strategies

Effective labeling requires planning and consistency. Here are proven patterns:

```yaml
# File: labeling-strategy.yaml
# Comprehensive labeling example
apiVersion: apps/v1
kind: Deployment
metadata:
  name: payment-service
  labels:
    # Technical labels
    app.kubernetes.io/name: payment-service
    app.kubernetes.io/instance: payment-prod-us-east
    app.kubernetes.io/version: "2.1.0"
    app.kubernetes.io/component: backend
    app.kubernetes.io/part-of: e-commerce
    app.kubernetes.io/managed-by: helm
    
    # Business labels
    customer: enterprise
    cost-center: engineering
    compliance: pci-dss
    
    # Operational labels
    environment: production
    region: us-east-1
    availability-zone: us-east-1a
    
spec:
  replicas: 3
  selector:
    matchLabels:
      app.kubernetes.io/name: payment-service
      app.kubernetes.io/instance: payment-prod-us-east
  template:
    metadata:
      labels:
        app.kubernetes.io/name: payment-service
        app.kubernetes.io/instance: payment-prod-us-east
        app.kubernetes.io/version: "2.1.0"
    spec:
      containers:
      - name: payment
        image: payment:2.1.0
```

## Namespaces: Virtual Clusters Within Clusters

### The Namespace Concept

Namespaces provide logical isolation within a Kubernetes cluster, creating virtual clusters that share physical resources but maintain separation. Think of namespaces as apartments in a building—each has its own space and privacy, but they share the building's infrastructure.

Namespaces solve several problems:

**Multi-tenancy**: Different teams or projects can use the same cluster without interfering with each other.

**Environment Separation**: Development, staging, and production can coexist in one cluster (though separate clusters are often preferred for production).

**Resource Organization**: Related resources can be grouped together for easier management.

**Access Control**: Permissions can be scoped to namespaces, limiting what users can see and modify.

**Resource Quotas**: Limits can be applied per namespace to prevent resource hogging.

### Working with Namespaces

Kubernetes starts with four default namespaces, each serving specific purposes:

```bash
# View all namespaces
kubectl get namespaces

# Detailed namespace information
kubectl describe namespace default
```

The default namespaces:

1. **default**: Where resources go when no namespace is specified
2. **kube-system**: Kubernetes system components (DNS, metrics-server, etc.)
3. **kube-public**: Resources readable by all users, even unauthenticated
4. **kube-node-lease**: Node heartbeat data for efficient node health monitoring

Creating and using custom namespaces:

```yaml
# File: namespace-example.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: development
  labels:
    environment: dev
    team: platform
---
apiVersion: v1
kind: Namespace
metadata:
  name: production
  labels:
    environment: prod
    team: platform
```

Working with namespaced resources:

```bash
# Create namespace
kubectl create namespace testing

# Deploy to specific namespace
kubectl apply -f deployment.yaml -n testing

# List resources in namespace
kubectl get all -n testing

# Set default namespace for kubectl
kubectl config set-context --current --namespace=testing

# Delete namespace (deletes all resources within!)
kubectl delete namespace testing
```

### Namespace Scope

Not all resources are namespaced. Understanding the distinction is crucial:

**Namespaced Resources** (isolated per namespace):
- Pods, Deployments, Services
- ConfigMaps, Secrets
- PersistentVolumeClaims
- ServiceAccounts, Roles, RoleBindings

**Cluster-Scoped Resources** (global):
- Nodes, PersistentVolumes
- StorageClasses
- ClusterRoles, ClusterRoleBindings
- Namespaces themselves

### Cross-Namespace Communication

While namespaces provide isolation, services can communicate across namespace boundaries using fully qualified domain names:

```yaml
# File: cross-namespace-example.yaml
---
# Service in 'backend' namespace
apiVersion: v1
kind: Service
metadata:
  name: database
  namespace: backend
spec:
  selector:
    app: postgres
  ports:
  - port: 5432

---
# Pod in 'frontend' namespace connecting to backend
apiVersion: v1
kind: Pod
metadata:
  name: web-app
  namespace: frontend
spec:
  containers:
  - name: app
    image: webapp:latest
    env:
    - name: DATABASE_URL
      # Full DNS name for cross-namespace access
      value: "postgres://database.backend.svc.cluster.local:5432/mydb"
```

## Deployment Options for Kubernetes Applications

### Choosing the Right Controller

Kubernetes offers multiple controllers for running applications, each optimized for specific use cases. Choosing the right controller is crucial for application reliability and operational efficiency.

#### Direct Pod Creation (Not Recommended for Production)

Creating Pods directly is the simplest approach but lacks production features:

```yaml
# File: direct-pod.yaml
apiVersion: v1
kind: Pod
metadata:
  name: simple-web
spec:
  containers:
  - name: nginx
    image: nginx:latest
    ports:
    - containerPort: 80
```

Problems with direct Pods:
- No automatic restart if the Pod fails
- No easy scaling
- No rolling updates
- No self-healing

Direct Pods are only suitable for debugging or very specific use cases like batch jobs that should run once.

#### Deployments for Stateless Applications

Deployments are the workhorses of Kubernetes, perfect for stateless applications:

```yaml
# File: stateless-deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: api-server
spec:
  replicas: 5
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 2
      maxUnavailable: 1
  selector:
    matchLabels:
      app: api-server
  template:
    metadata:
      labels:
        app: api-server
    spec:
      containers:
      - name: api
        image: api:v2.0
        ports:
        - containerPort: 8080
        livenessProbe:
          httpGet:
            path: /health
            port: 8080
          initialDelaySeconds: 30
          periodSeconds: 10
        readinessProbe:
          httpGet:
            path: /ready
            port: 8080
          initialDelaySeconds: 5
          periodSeconds: 5
```

Deployments excel at:
- Maintaining desired replica count
- Rolling updates with zero downtime
- Automatic rollback on failures
- Horizontal scaling

#### StatefulSets for Stateful Applications

StatefulSets manage applications requiring persistent storage, stable network identities, or ordered deployment:

```yaml
# File: stateful-application.yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: postgres-cluster
spec:
  serviceName: postgres
  replicas: 3
  selector:
    matchLabels:
      app: postgres
  template:
    metadata:
      labels:
        app: postgres
    spec:
      containers:
      - name: postgres
        image: postgres:13
        ports:
        - containerPort: 5432
        env:
        - name: POSTGRES_DB
          value: mydb
        - name: POSTGRES_PASSWORD
          valueFrom:
            secretKeyRef:
              name: postgres-secret
              key: password
        volumeMounts:
        - name: postgres-storage
          mountPath: /var/lib/postgresql/data
  volumeClaimTemplates:
  - metadata:
      name: postgres-storage
    spec:
      accessModes: ["ReadWriteOnce"]
      resources:
        requests:
          storage: 10Gi
```

StatefulSets provide:
- Stable, unique network identifiers (postgres-0, postgres-1, postgres-2)
- Stable, persistent storage
- Ordered, graceful deployment and scaling
- Ordered, automated rolling updates

#### DaemonSets for Node-Level Services

DaemonSets ensure a Pod runs on every node (or selected nodes):

```yaml
# File: daemonset-example.yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: log-collector
spec:
  selector:
    matchLabels:
      app: log-collector
  template:
    metadata:
      labels:
        app: log-collector
    spec:
      containers:
      - name: fluentd
        image: fluentd:latest
        volumeMounts:
        - name: varlog
          mountPath: /var/log
        - name: dockercontainers
          mountPath: /var/lib/docker/containers
          readOnly: true
      volumes:
      - name: varlog
        hostPath:
          path: /var/log
      - name: dockercontainers
        hostPath:
          path: /var/lib/docker/containers
```

DaemonSets are perfect for:
- Log collection agents
- Monitoring agents
- Network plugins
- Storage drivers

#### Jobs and CronJobs for Batch Processing

Jobs run Pods to completion, while CronJobs run Jobs on schedules:

```yaml
# File: job-examples.yaml
---
# One-time Job
apiVersion: batch/v1
kind: Job
metadata:
  name: backup-job
spec:
  completions: 1
  parallelism: 1
  backoffLimit: 3
  template:
    spec:
      containers:
      - name: backup
        image: backup-tool:latest
        command: ["./backup.sh"]
      restartPolicy: OnFailure

---
# Scheduled CronJob
apiVersion: batch/v1
kind: CronJob
metadata:
  name: nightly-backup
spec:
  schedule: "0 2 * * *"  # 2 AM daily
  jobTemplate:
    spec:
      template:
        spec:
          containers:
          - name: backup
            image: backup-tool:latest
            command: ["./backup.sh"]
          restartPolicy: OnFailure
```

## Working with kubectl: The Kubernetes CLI

### Understanding kubectl

kubectl is your primary interface to Kubernetes clusters. It translates your commands into API calls, handles authentication, and formats responses for human consumption. Mastering kubectl is essential for effective Kubernetes management.

kubectl follows a consistent syntax pattern:
```bash
kubectl [action] [resource] [name] [flags]
```

Examples:
- `kubectl get pods` - List pods
- `kubectl describe service web` - Show service details
- `kubectl delete deployment app` - Remove deployment
- `kubectl apply -f config.yaml` - Apply configuration

### Essential kubectl Commands

#### Cluster Information and Discovery

Understanding your cluster starts with information gathering:

```bash
# Cluster connection and component status
kubectl cluster-info
kubectl cluster-info dump > cluster-state.txt  # Full cluster state

# Node information
kubectl get nodes
kubectl get nodes -o wide  # Additional details
kubectl describe node <node-name>  # Complete node details
kubectl top nodes  # Resource usage (requires metrics-server)

# API resources discovery
kubectl api-resources  # All available resources
kubectl api-resources --namespaced=true  # Namespaced resources only
kubectl api-resources --verbs=list,get  # Resources you can read

# API versions
kubectl api-versions  # Supported API versions

# Explain resource fields
kubectl explain pod
kubectl explain pod.spec
kubectl explain pod.spec.containers
kubectl explain deployment.spec.strategy --recursive
```

#### Resource Management Commands

Creating and managing resources:

```bash
# Create resources
kubectl create deployment web --image=nginx
kubectl create service clusterip web --tcp=80:80
kubectl create namespace development
kubectl create configmap config --from-file=config.properties

# Apply configurations (declarative)
kubectl apply -f manifest.yaml
kubectl apply -f ./configs/  # Apply all files in directory
kubectl apply -f https://example.com/manifest.yaml  # From URL

# Update resources
kubectl set image deployment/web nginx=nginx:1.21
kubectl scale deployment web --replicas=5
kubectl autoscale deployment web --min=2 --max=10 --cpu-percent=80

# Delete resources
kubectl delete pod web-xyz
kubectl delete deployment web
kubectl delete -f manifest.yaml
kubectl delete pods --all
kubectl delete namespace testing  # Deletes everything in namespace!
```

#### Viewing and Finding Resources

Discovering what's running in your cluster:

```bash
# Basic viewing
kubectl get all  # Common resources in current namespace
kubectl get all -A  # All namespaces
kubectl get pods
kubectl get pods -o wide  # More details
kubectl get pods -o yaml  # Full YAML output
kubectl get pods -o json  # JSON output

# Custom columns
kubectl get pods -o custom-columns=\
  NAME:.metadata.name,\
  STATUS:.status.phase,\
  NODE:.spec.nodeName

# Filtering with labels
kubectl get pods -l app=web
kubectl get pods -l 'environment in (production, staging)'
kubectl get all -l app=web

# Field selectors
kubectl get pods --field-selector status.phase=Running
kubectl get pods --field-selector metadata.name=web

# Sorting
kubectl get pods --sort-by=.metadata.creationTimestamp
kubectl get pods --sort-by=.status.startTime

# Watching resources
kubectl get pods -w  # Watch for changes
kubectl get events -w  # Watch cluster events
```

#### Detailed Resource Information

When you need deep insights:

```bash
# Describe shows events and details
kubectl describe pod web-xyz
kubectl describe node worker-1
kubectl describe service web

# Logs from containers
kubectl logs pod-name
kubectl logs pod-name -c container-name  # Specific container
kubectl logs -f pod-name  # Follow logs
kubectl logs --tail=50 pod-name  # Last 50 lines
kubectl logs --since=1h pod-name  # Last hour
kubectl logs -p pod-name  # Previous container instance
kubectl logs -l app=web  # All pods with label

# Execute commands in containers
kubectl exec pod-name -- ls /app
kubectl exec -it pod-name -- /bin/bash  # Interactive shell
kubectl exec -it pod-name -c container -- /bin/sh  # Specific container

# Copy files
kubectl cp pod-name:/path/to/file ./local-file
kubectl cp ./local-file pod-name:/path/to/file
kubectl cp pod-name:/dir ./local-dir

# Port forwarding for debugging
kubectl port-forward pod-name 8080:80
kubectl port-forward service/web 8080:80
kubectl port-forward deployment/web 8080:80
```

#### Debugging and Troubleshooting

When things go wrong:

```bash
# Debug pods
kubectl describe pod failing-pod
kubectl logs failing-pod --previous
kubectl get events --sort-by=.lastTimestamp
kubectl get events --field-selector involvedObject.name=pod-name

# Resource usage
kubectl top pods
kubectl top pods -A
kubectl top nodes

# Debugging with ephemeral containers (K8s 1.23+)
kubectl debug pod-name -it --image=busybox

# Network debugging
kubectl run tmp-shell --rm -i --tty --image nicolaka/netshoot
kubectl exec -it tmp-shell -- nslookup kubernetes

# Check rollout status
kubectl rollout status deployment/web
kubectl rollout history deployment/web
kubectl rollout undo deployment/web
kubectl rollout restart deployment/web

# Diff changes before applying
kubectl diff -f updated-manifest.yaml

# Dry run to test commands
kubectl create deployment test --image=nginx --dry-run=client -o yaml
kubectl apply -f manifest.yaml --dry-run=server
```

### Advanced kubectl Usage

#### Working with Contexts and Configurations

Managing multiple clusters:

```bash
# View current configuration
kubectl config view
kubectl config current-context

# Switch contexts
kubectl config get-contexts
kubectl config use-context production

# Set namespace for context
kubectl config set-context --current --namespace=development

# Create new context
kubectl config set-context dev --cluster=dev-cluster --user=dev-user

# Direct cluster access
kubectl --kubeconfig=/path/to/config get pods
```

#### Output Formatting and Processing

Getting data in useful formats:

```bash
# JSONPath queries
kubectl get pods -o jsonpath='{.items[*].metadata.name}'
kubectl get pods -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.phase}{"\n"}{end}'

# Go templates
kubectl get pods -o go-template='{{range .items}}{{.metadata.name}}{{"\n"}}{{end}}'

# Combining with standard tools
kubectl get pods -o json | jq '.items[].metadata.name'
kubectl get pods -o yaml | yq '.items[0].spec.containers[0].image'

# Export resources (remove cluster-specific fields)
kubectl get deployment web -o yaml --export > deployment.yaml  # Deprecated
kubectl get deployment web -o yaml | kubectl neat  # Using kubectl-neat plugin
```

#### Resource Editing and Patching

Modifying resources in place:

```bash
# Edit resource interactively
kubectl edit deployment web
KUBE_EDITOR="code --wait" kubectl edit deployment web  # Custom editor

# Patch resources
kubectl patch deployment web -p '{"spec":{"replicas":5}}'
kubectl patch deployment web --type='json' \
  -p='[{"op":"replace","path":"/spec/replicas","value":10}]'

# Label and annotate
kubectl label pods web-xyz version=v2
kubectl label pods --all environment=testing
kubectl annotate pods web-xyz description="Web server pod"
```

### kubectl Productivity Tips

Boost your kubectl efficiency:

```bash
# Set up alias
alias k=kubectl
alias kgp='kubectl get pods'
alias kgs='kubectl get services'
alias kgd='kubectl get deployments'

# Enable auto-completion
source <(kubectl completion bash)  # Bash
source <(kubectl completion zsh)   # Zsh

# Use kubectl plugins
kubectl krew install neat  # Clean YAML output
kubectl krew install tree  # Tree view of resources
kubectl krew install access-matrix  # RBAC access matrix

# Quick temporary resources
# Run temporary pod for debugging
kubectl run tmp --rm -i --tty --image=alpine -- /bin/sh

# Quick port-forward for testing
kubectl port-forward svc/web 8080:80 &

# Generate YAML templates
kubectl create deployment web --image=nginx --dry-run=client -o yaml > deployment.yaml
kubectl create service clusterip web --tcp=80 --dry-run=client -o yaml > service.yaml

# Watch multiple resources
watch kubectl get pods,services,deployments

# Quick resource deletion
kubectl delete pods --grace-period=0 --force pod-name  # Force delete stuck pod
```

### Common kubectl Patterns

Practical patterns for daily use:

```bash
# Verify deployment succeeded
kubectl rollout status deployment/web
if [ $? -eq 0 ]; then
  echo "Deployment successful"
fi

# Wait for pod to be ready
kubectl wait --for=condition=ready pod -l app=web --timeout=60s

# Scale based on load
CURRENT_PODS=$(kubectl get deployment web -o jsonpath='{.spec.replicas}')
if [ $CURRENT_PODS -lt 10 ]; then
  kubectl scale deployment web --replicas=$((CURRENT_PODS + 2))
fi

# Backup resource configurations
kubectl get all,cm,secret -o yaml > backup.yaml

# Apply with pruning (remove resources not in files)
kubectl apply -f configs/ --prune -l app=myapp

# Rolling restart without changing configuration
kubectl rollout restart deployment/web

# Check resource consumption
kubectl top pods --all-namespaces | sort -k3 -rn | head -10  # Top 10 CPU consumers
kubectl top pods --all-namespaces | sort -k4 -rn | head -10  # Top 10 memory consumers
```