# Node Administration and Monitoring

## Analyzing Node State

### Getting Node Information with kubectl

Get detailed information about any node in your cluster:

```bash
# Get basic node information
# Shows: NAME, STATUS, ROLES, AGE, VERSION
kubectl get nodes

# Get detailed output with more columns
# Additionally shows: INTERNAL-IP, EXTERNAL-IP, OS-IMAGE, KERNEL-VERSION, CONTAINER-RUNTIME
kubectl get nodes -o wide

# Get detailed node information including conditions, capacity, and system info
# This is the most comprehensive view of a single node's state
kubectl describe node <node-name>

# Example for control plane node
kubectl describe node k8s-control

# Get node information in JSON format
# Useful for scripting and parsing specific fields
kubectl get nodes -o json

# Get resource usage if Metrics Server is installed
# Shows CPU(cores), CPU%, MEMORY(bytes), MEMORY%
kubectl top nodes

# Check node labels and annotations
# Labels are used for scheduling and node selection
kubectl get nodes --show-labels

# Get specific node capacity and allocatable resources
# Capacity: Total resources on the node
# Allocatable: Resources available for pods (capacity minus system reserved)
kubectl get nodes -o jsonpath='{.items[*].status.capacity}'
kubectl get nodes -o jsonpath='{.items[*].status.allocatable}'
```

### Node Status and Conditions

Understanding node conditions is crucial for troubleshooting. Kubernetes tracks five main conditions:
- **Ready**: Node is healthy and ready to accept pods
- **MemoryPressure**: Node is running low on memory
- **DiskPressure**: Node is running low on disk space
- **PIDPressure**: Node is running low on process IDs
- **NetworkUnavailable**: Node's network is not correctly configured

```bash
# Check node conditions for all nodes
# Shows which nodes are Ready (True/False/Unknown)
kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}'

# Get detailed condition status for a specific node
kubectl describe node <node-name>

# Check specific conditions
# MemoryPressure should normally be False
kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{": "}{.status.conditions[?(@.type=="MemoryPressure")].status}{"\n"}{end}'

# View all node conditions in table format
# This custom format makes it easy to spot issues at a glance
kubectl get nodes -o custom-columns="NODE:.metadata.name,READY:.status.conditions[?(@.type=='Ready')].status,MEMORY:.status.conditions[?(@.type=='MemoryPressure')].status,DISK:.status.conditions[?(@.type=='DiskPressure')].status"
```

### System Information via kubectl

```bash
# Check kubelet version on all nodes
# Important for ensuring version compatibility
kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{": "}{.status.nodeInfo.kubeletVersion}{"\n"}{end}'

# Check container runtime information
# Common runtimes: containerd, docker, cri-o
kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{": "}{.status.nodeInfo.containerRuntimeVersion}{"\n"}{end}'

# Check OS information
# Helps identify OS-specific issues
kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{": "}{.status.nodeInfo.osImage}{"\n"}{end}'

# Check kernel version
# Important for container compatibility
kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{": "}{.status.nodeInfo.kernelVersion}{"\n"}{end}'

# Check architecture
# Usually amd64, arm64, etc.
kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{": "}{.status.nodeInfo.architecture}{"\n"}{end}'
```

---

## Understanding Static Pods

Static Pods are managed directly by the kubelet on individual nodes, not by the API server. They're typically used for control plane components and are defined by manifest files in `/etc/kubernetes/manifests/`.

### Identifying Static Pods

```bash
# Static Pods have the node name as suffix
# This naming convention helps identify them
kubectl get pods -n kube-system

# Example output shows static pods:
# kube-apiserver-k8s-control            1/1     Running
# kube-controller-manager-k8s-control   1/1     Running
# kube-scheduler-k8s-control            1/1     Running
# etcd-k8s-control                      1/1     Running

# Check Pod ownership (static Pods are owned by Node, not controllers)
# Regular pods show ReplicaSet, DaemonSet, etc. as owner
kubectl get pods -n kube-system -o yaml | grep -A 5 "ownerReferences"

# List static pods specifically
# Note: This command needs correction - it should check for Node ownership differently
kubectl get pods --all-namespaces -o jsonpath='{range .items[?(@.metadata.ownerReferences[0].kind=="Node")]}{.metadata.namespace}{"\t"}{.metadata.name}{"\n"}{end}'
```

### Creating Custom Static Pods

Create a static Pod manifest:

```yaml
# static-nginx.yaml
apiVersion: v1
kind: Pod
metadata:
  name: static-nginx
  labels:
    app: static-nginx
spec:
  containers:
  - name: nginx
    image: nginx:1.21
    ports:
    - containerPort: 80
    resources:
      requests:
        memory: "64Mi"
        cpu: "250m"
      limits:
        memory: "128Mi"
        cpu: "500m"
    volumeMounts:
    - name: html
      mountPath: /usr/share/nginx/html
  volumes:
  - name: html
    hostPath:
      path: /tmp/nginx-static
      type: DirectoryOrCreate
```

Deploy the static Pod by copying to `/etc/kubernetes/manifests/` on the target node:
```bash
# SSH to the target node first, then:
sudo cp static-nginx.yaml /etc/kubernetes/manifests/
# The kubelet will automatically detect and create the pod
```

### Static Pod Management

```bash
# View static Pod logs
# Note the node name suffix in the pod name
kubectl logs static-nginx-<node-name>

# Describe static Pod
kubectl describe pod static-nginx-<node-name>

# Try to delete static Pod via kubectl (will fail/restart)
# The pod will be immediately recreated by kubelet
kubectl delete pod static-nginx-<node-name>

# Monitor static Pod recreation
# You'll see the pod being deleted and immediately recreated
kubectl get pods --watch | grep static-nginx
```

### Control Plane Static Pods

```bash
# View control plane static Pods
kubectl get pods -n kube-system -o wide | grep <control-plane-node-name>

# Check control plane component health
# tier=control-plane label is used for control plane components
kubectl get pods -n kube-system -l tier=control-plane

# View control plane component logs
# Useful for troubleshooting cluster issues
kubectl logs -n kube-system kube-apiserver-<node-name>
kubectl logs -n kube-system kube-controller-manager-<node-name>
kubectl logs -n kube-system kube-scheduler-<node-name>
kubectl logs -n kube-system etcd-<node-name>
```

---

## Managing Node State

### Cordoning Nodes

Mark a node as unschedulable without affecting existing Pods. This is useful for preventing new workloads during investigation or minor maintenance.

```bash
# Mark node as unschedulable
kubectl cordon <node-name>

# Example
kubectl cordon k8s-worker1

# Verify node status shows SchedulingDisabled
# The STATUS column will show "Ready,SchedulingDisabled"
kubectl get nodes

# Check node details
# Look for "Unschedulable: true" in the output
kubectl describe node k8s-worker1

# Test that new Pods won't schedule to cordoned node
kubectl create deployment test-cordon --image=nginx --replicas=3
kubectl get pods -o wide
kubectl delete deployment test-cordon
```

### Draining Nodes

Remove all Pods from a node and mark it unschedulable. This is essential for node maintenance or decommissioning.

```bash
# Basic drain command
# This will often fail due to DaemonSets and local data
kubectl drain <node-name>

# Drain with common options (recommended)
# --ignore-daemonsets: Continue even if DaemonSet pods exist
# --delete-emptydir-data: Delete pods using emptyDir volumes (data will be lost)
kubectl drain k8s-worker1 --ignore-daemonsets --delete-emptydir-data

# Drain with additional options
kubectl drain k8s-worker1 \
  --ignore-daemonsets \
  --delete-emptydir-data \
  --force \                    # Delete pods not managed by controllers
  --grace-period=60 \          # Time to wait for pod termination
  --timeout=300s               # Overall operation timeout

# Monitor the drain process
kubectl get pods -o wide --watch

# Verify node is drained
# Node should show SchedulingDisabled and no pods except DaemonSets
kubectl get nodes
kubectl describe node k8s-worker1
```

### Uncordoning Nodes

Restore normal node scheduling after maintenance:

```bash
# Make node schedulable again
kubectl uncordon <node-name>

# Example
kubectl uncordon k8s-worker1

# Verify node is back to Ready state
# STATUS should show only "Ready"
kubectl get nodes

# Test that new Pods can schedule to uncordoned node
kubectl create deployment test-uncordon --image=nginx --replicas=3
kubectl get pods -o wide
kubectl delete deployment test-uncordon
```

### Understanding Node Taints

Taints prevent pods from being scheduled unless they have matching tolerations:
- **NoSchedule**: New pods won't be scheduled
- **PreferNoSchedule**: Scheduler tries to avoid placing pods
- **NoExecute**: Existing pods are evicted, new pods won't be scheduled

```bash
# View all node taints
kubectl describe nodes | grep -i taint

# View taints for a specific node
kubectl describe node k8s-worker1 | grep -A 5 -B 5 -i taint

# Manually add a custom taint
# Format: key=value:effect
kubectl taint nodes k8s-worker1 maintenance=true:NoSchedule

# Add taint that evicts existing Pods
# Use with caution - this will remove running pods!
kubectl taint nodes k8s-worker1 maintenance=true:NoExecute

# Remove a taint (note the minus sign at the end)
kubectl taint nodes k8s-worker1 maintenance=true:NoSchedule-

# Remove control plane taint for single-node testing
# Allows regular pods to run on control plane node
kubectl taint nodes k8s-control node-role.kubernetes.io/control-plane:NoSchedule-
```

---

## Node Resource Monitoring

### Resource Usage with kubectl

```bash
# Check node resource usage (requires Metrics Server)
# Shows actual CPU and memory usage
kubectl top nodes

# Check Pod resource usage by node
# Helps identify resource-hungry pods
kubectl top pods --all-namespaces --sort-by=memory
kubectl top pods --all-namespaces --sort-by=cpu

# Check resource requests vs limits
# Shows how much resources are reserved vs. actually used
kubectl describe nodes | grep -A 10 "Allocated resources"

# Node capacity and allocatable resources
# Capacity: Total physical resources
# Allocatable: Available for pods after system reservation
kubectl describe nodes | grep -A 5 "Capacity:" 
kubectl describe nodes | grep -A 5 "Allocatable:"
```

### Installing Metrics Server

If Metrics Server is not available, here's a complete manifest with necessary configurations:

```yaml
# metrics-server.yaml
# ServiceAccount for metrics-server
apiVersion: v1
kind: ServiceAccount
metadata:
  labels:
    k8s-app: metrics-server
  name: metrics-server
  namespace: kube-system
---
# ClusterRole for aggregated API discovery
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  labels:
    k8s-app: metrics-server
    rbac.authorization.k8s.io/aggregate-to-admin: "true"
    rbac.authorization.k8s.io/aggregate-to-edit: "true"
    rbac.authorization.k8s.io/aggregate-to-view: "true"
  name: system:aggregated-metrics-reader
rules:
- apiGroups:
  - metrics.k8s.io
  resources:
  - pods
  - nodes
  verbs:
  - get
  - list
---
# ClusterRole for metrics-server
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  labels:
    k8s-app: metrics-server
  name: system:metrics-server
rules:
- apiGroups:
  - ""
  resources:
  - nodes/metrics
  verbs:
  - get
- apiGroups:
  - ""
  resources:
  - pods
  - nodes
  verbs:
  - get
  - list
  - watch
---
# RoleBinding for auth delegation
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  labels:
    k8s-app: metrics-server
  name: metrics-server-auth-reader
  namespace: kube-system
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: extension-apiserver-authentication-reader
subjects:
- kind: ServiceAccount
  name: metrics-server
  namespace: kube-system
---
# ClusterRoleBinding for auth delegation
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  labels:
    k8s-app: metrics-server
  name: metrics-server:system:auth-delegator
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:auth-delegator
subjects:
- kind: ServiceAccount
  name: metrics-server
  namespace: kube-system
---
# ClusterRoleBinding for metrics-server
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  labels:
    k8s-app: metrics-server
  name: system:metrics-server
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:metrics-server
subjects:
- kind: ServiceAccount
  name: metrics-server
  namespace: kube-system
---
# Service for metrics-server
apiVersion: v1
kind: Service
metadata:
  labels:
    k8s-app: metrics-server
  name: metrics-server
  namespace: kube-system
spec:
  ports:
  - name: https
    port: 443
    protocol: TCP
    targetPort: https
  selector:
    k8s-app: metrics-server
---
# Deployment for metrics-server
apiVersion: apps/v1
kind: Deployment
metadata:
  labels:
    k8s-app: metrics-server
  name: metrics-server
  namespace: kube-system
spec:
  selector:
    matchLabels:
      k8s-app: metrics-server
  strategy:
    rollingUpdate:
      maxUnavailable: 0
  template:
    metadata:
      labels:
        k8s-app: metrics-server
    spec:
      containers:
      - args:
        - --cert-dir=/tmp
        - --secure-port=4443
        - --kubelet-preferred-address-types=InternalIP,ExternalIP,Hostname
        - --kubelet-use-node-status-port
        - --metric-resolution=15s
        # --kubelet-insecure-tls is needed for self-signed certificates
        - --kubelet-insecure-tls
        image: registry.k8s.io/metrics-server/metrics-server:v0.6.4
        imagePullPolicy: IfNotPresent
        livenessProbe:
          failureThreshold: 3
          httpGet:
            path: /livez
            port: https
            scheme: HTTPS
          periodSeconds: 10
        name: metrics-server
        ports:
        - containerPort: 4443
          name: https
          protocol: TCP
        readinessProbe:
          failureThreshold: 3
          httpGet:
            path: /readyz
            port: https
            scheme: HTTPS
          initialDelaySeconds: 20
          periodSeconds: 10
        resources:
          requests:
            cpu: 100m
            memory: 200Mi
        securityContext:
          allowPrivilegeEscalation: false
          readOnlyRootFilesystem: true
          runAsNonRoot: true
          runAsUser: 1000
        volumeMounts:
        - mountPath: /tmp
          name: tmp-dir
      nodeSelector:
        kubernetes.io/os: linux
      priorityClassName: system-cluster-critical
      serviceAccountName: metrics-server
      volumes:
      - emptyDir: {}
        name: tmp-dir
---
# APIService registration
apiVersion: apiregistration.k8s.io/v1
kind: APIService
metadata:
  labels:
    k8s-app: metrics-server
  name: v1beta1.metrics.k8s.io
spec:
  group: metrics.k8s.io
  groupPriorityMinimum: 100
  insecureSkipTLSVerify: true
  service:
    name: metrics-server
    namespace: kube-system
  version: v1beta1
  versionPriority: 100
```

Deploy Metrics Server:

```bash
# Apply the metrics server configuration
kubectl apply -f metrics-server.yaml

# Or use the official manifest (may need modifications for self-signed certs)
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml

# For clusters with self-signed certificates, edit the deployment:
kubectl edit deployment metrics-server -n kube-system
# Add --kubelet-insecure-tls to container args

# Wait for metrics-server to be ready
kubectl wait --for=condition=available --timeout=300s deployment/metrics-server -n kube-system

# Verify installation
kubectl get deployment metrics-server -n kube-system
# Wait 30-60 seconds for metrics to be collected
kubectl top nodes
```

---

## Event Monitoring and Debugging

### Cluster Events

Events provide insight into what's happening in the cluster. They're retained for 1 hour by default.

```bash
# Get all events sorted by timestamp
kubectl get events --sort-by='.lastTimestamp'

# Get events for the last hour
# This command needs correction - should focus on recent events
kubectl get events --sort-by='.lastTimestamp' | head -20

# Get Node-specific events
kubectl get events --field-selector involvedObject.kind=Node --sort-by='.lastTimestamp'

# Get Pod-related events
kubectl get events --field-selector involvedObject.kind=Pod --sort-by='.lastTimestamp'

# Get events for a specific node
kubectl get events --field-selector involvedObject.name=<node-name> --sort-by='.lastTimestamp'

# Get events in a specific namespace
kubectl get events -n kube-system --sort-by='.lastTimestamp'

# Watch events in real-time
# Useful for monitoring during deployments or troubleshooting
kubectl get events --watch

# Get events with more details
kubectl get events -o wide --sort-by='.lastTimestamp'
```

### Pod and Container Monitoring

```bash
# Get all Pods on a specific node
kubectl get pods --all-namespaces --field-selector spec.nodeName=<node-name>

# Get Pod resource usage on a specific node (requires Metrics Server)
# Note: field-selector doesn't work with kubectl top, use grep instead
kubectl top pods --all-namespaces | grep <node-name>

# Check Pod conditions and status
kubectl get pods --all-namespaces --field-selector spec.nodeName=<node-name> -o wide

# Get container logs for Pods on a node
# -f follows the log output (like tail -f)
kubectl logs -f <pod-name> -n <namespace>

# Get previous container logs (useful after container restart)
kubectl logs <pod-name> -n <namespace> --previous

# Check Pod resource requests and limits
kubectl get pods --all-namespaces -o jsonpath='{range .items[*]}{.metadata.namespace}{"\t"}{.metadata.name}{"\t"}{.spec.containers[*].resources}{"\n"}{end}'
```

---

## Node Maintenance Workflows

### Pre-maintenance Checks

Before performing maintenance, gather information about potential impact:

```bash
# Check what's running on the target node
kubectl get pods -o wide --all-namespaces --field-selector spec.nodeName=<node-name>

# Check critical system Pods
kubectl get pods -n kube-system --field-selector spec.nodeName=<node-name>

# Check DaemonSets that will remain (can't be drained)
kubectl get daemonsets --all-namespaces

# Check PodDisruptionBudgets that might prevent draining
# PDBs define minimum available replicas
kubectl get pdb --all-namespaces
```

### Maintenance Procedure

Follow this systematic approach for safe node maintenance:

```bash
# Step 1: Cordon the node (prevent new scheduling)
kubectl cordon <node-name>

# Step 2: Check current Pod distribution
kubectl get pods -o wide --all-namespaces | grep <node-name>

# Step 3: Drain the node (move existing Pods)
# This gracefully evicts pods, respecting PodDisruptionBudgets
kubectl drain <node-name> --ignore-daemonsets --delete-emptydir-data

# Step 4: Verify node is drained
# Should only show DaemonSet pods
kubectl get pods -o wide --all-namespaces --field-selector spec.nodeName=<node-name>

# === Perform maintenance work here ===

# Step 5: Uncordon the node after maintenance
kubectl uncordon <node-name>

# Step 6: Verify normal operation
kubectl get nodes
kubectl get pods -o wide --all-namespaces
```

### Testing Node Recovery

After maintenance, verify the node is functioning correctly:

```bash
# Deploy test workload to verify scheduling
kubectl create deployment maintenance-test --image=nginx --replicas=3

# Check Pod distribution (should include the recovered node)
kubectl get pods -l app=maintenance-test -o wide

# Scale to test further
kubectl scale deployment maintenance-test --replicas=6

# Verify pods are distributed across nodes including the maintained one
kubectl get pods -l app=maintenance-test -o wide

# Cleanup
kubectl delete deployment maintenance-test
```

---

## Node Health Monitoring

### Health Check Commands

```bash
# Check cluster component health
# Note: componentstatuses is deprecated in newer versions
kubectl get componentstatuses

# For newer versions, check individual components:
kubectl get pods -n kube-system -l component=kube-apiserver
kubectl get pods -n kube-system -l component=kube-controller-manager
kubectl get pods -n kube-system -l component=kube-scheduler

# Check all node conditions in a formatted view
kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{" Ready="}{.status.conditions[?(@.type=="Ready")].status}{" MemoryPressure="}{.status.conditions[?(@.type=="MemoryPressure")].status}{" DiskPressure="}{.status.conditions[?(@.type=="DiskPressure")].status}{" PIDPressure="}{.status.conditions[?(@.type=="PIDPressure")].status}{"\n"}{end}'

# Check for node resource pressure
kubectl describe nodes | grep -A 5 -B 5 "Pressure"

# Monitor node resource allocation
# Shows requests/limits vs capacity
kubectl describe nodes | grep -A 10 "Allocated resources"
```

### Creating Monitoring Resources

Create a DaemonSet for continuous node monitoring:

```yaml
# node-monitor-daemonset.yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: node-monitor
  namespace: kube-system
  labels:
    app: node-monitor
spec:
  selector:
    matchLabels:
      app: node-monitor
  template:
    metadata:
      labels:
        app: node-monitor
    spec:
      # Access to host process and network namespaces
      hostPID: true
      hostNetwork: true
      containers:
      - name: node-monitor
        image: busybox:1.35
        command:
        - /bin/sh
        - -c
        - |
          while true; do
            echo "Node: $(hostname)"
            echo "Uptime: $(uptime)"
            echo "Memory: $(free -m | awk 'NR==2{printf "%.2f%%", $3*100/$2 }')"
            echo "Disk: $(df -h / | awk 'NR==2{print $5}')"
            echo "---"
            sleep 300
          done
        resources:
          requests:
            memory: 50Mi
            cpu: 50m
          limits:
            memory: 100Mi
            cpu: 100m
        securityContext:
          privileged: true  # Required for host access
        volumeMounts:
        - name: proc
          mountPath: /host/proc
          readOnly: true
        - name: sys
          mountPath: /host/sys
          readOnly: true
      volumes:
      - name: proc
        hostPath:
          path: /proc
      - name: sys
        hostPath:
          path: /sys
      # Tolerations ensure DaemonSet runs on all nodes
      tolerations:
      - effect: NoSchedule
        operator: Exists
      - effect: NoExecute
        operator: Exists
```

Deploy the monitoring DaemonSet:

```bash
# Apply the DaemonSet
kubectl apply -f node-monitor-daemonset.yaml

# Check DaemonSet status
# Should show desired number equals current number
kubectl get daemonset node-monitor -n kube-system

# View logs from monitoring pods
kubectl logs -l app=node-monitor -n kube-system --tail=20

# Follow logs in real-time
kubectl logs -l app=node-monitor -n kube-system -f
```

---

## Verification and Testing

### Complete Cluster Verification

Comprehensive health check after any major changes:

```bash
# Check cluster overview
kubectl get nodes -o wide
kubectl cluster-info
kubectl version

# Verify all system components
kubectl get pods -n kube-system
# For older versions:
kubectl get componentstatuses
# For newer versions:
kubectl get --raw /healthz

# Check resource usage (requires Metrics Server)
kubectl top nodes
kubectl top pods -n kube-system

# View recent cluster events
kubectl get events --sort-by='.lastTimestamp' | head -20
```

### Node Functionality Testing

Deploy comprehensive test workload to verify all node features:

```yaml
# node-test-deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: node-functionality-test
spec:
  replicas: 3
  selector:
    matchLabels:
      app: node-test
  template:
    metadata:
      labels:
        app: node-test
    spec:
      containers:
      - name: test-container
        image: nginx:1.21
        ports:
        - containerPort: 80
        resources:
          requests:
            memory: "64Mi"
            cpu: "250m"
          limits:
            memory: "128Mi"
            cpu: "500m"
        # Liveness probe ensures container is running
        livenessProbe:
          httpGet:
            path: /
            port: 80
          initialDelaySeconds: 10
          periodSeconds: 30
        # Readiness probe ensures container is ready for traffic
        readinessProbe:
          httpGet:
            path: /
            port: 80
          initialDelaySeconds: 5
          periodSeconds: 10
---
apiVersion: v1
kind: Service
metadata:
  name: node-test-service
spec:
  selector:
    app: node-test
  ports:
  - port: 80
    targetPort: 80
  type: NodePort  # Exposes on all nodes for testing
```

Test node functionality:

```bash
# Deploy test workload
kubectl apply -f node-test-deployment.yaml

# Wait for deployment to be ready
kubectl wait --for=condition=available --timeout=300s deployment/node-functionality-test

# Check Pod distribution across nodes
kubectl get pods -l app=node-test -o wide

# Test scaling (ensures scheduler works properly)
kubectl scale deployment node-functionality-test --replicas=6
kubectl get pods -l app=node-test -o wide

# Test service connectivity
# NodePort allows testing from any node
kubectl get svc node-test-service

# Test node scheduling with affinity
# This adds a preference for Linux nodes (should be all nodes)
kubectl patch deployment node-functionality-test -p '{"spec":{"template":{"spec":{"affinity":{"nodeAffinity":{"preferredDuringSchedulingIgnoredDuringExecution":[{"weight":1,"preference":{"matchExpressions":[{"key":"kubernetes.io/os","operator":"In","values":["linux"]}]}}]}}}}}}'

# Verify affinity is working
kubectl get pods -l app=node-test -o wide

# Cleanup test resources
kubectl delete -f node-test-deployment.yaml
```

### Final Verification Commands

Complete verification checklist:

```bash
# Comprehensive health check
kubectl get nodes
kubectl get pods --all-namespaces
kubectl get events --sort-by='.lastTimestamp' | head -10
kubectl top nodes
kubectl cluster-info

# Check for any failing Pods
# Should return empty if all pods are healthy
kubectl get pods --all-namespaces --field-selector=status.phase!=Running,status.phase!=Succeeded

# Verify all nodes are schedulable
# Should show "Schedulable=true" or empty for all nodes
kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{" Schedulable="}{.spec.unschedulable}{"\n"}{end}'

# Check cluster DNS is working
kubectl run test-dns --image=busybox:1.35 --rm -it --restart=Never -- nslookup kubernetes.default

# Check inter-pod communication
kubectl run test-ping --image=busybox:1.35 --rm -it --restart=Never -- ping -c 3 kubernetes.default
```
