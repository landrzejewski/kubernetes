## Understanding Deployments

### Why Deployments Over Standalone Pods?

Standalone Pods present significant operational challenges in production environments. When a Pod crashes, experiences a node failure, or requires updates, standalone Pods lack the automated management capabilities necessary for maintaining service availability. They provide no inherent scaling mechanisms, making them unsuitable for applications that need to adjust capacity based on demand or maintain high availability through multiple instances.

Deployments represent the standard approach for running scalable, stateless applications in Kubernetes. These applications do not maintain persistent state between requests, allowing any instance to handle any request without requiring session affinity or data synchronization. Common examples include web servers, REST API endpoints, microservices, batch processing workers, and any application where instances are interchangeable and can be horizontally scaled.

### Core Deployment Capabilities

ReplicaSet Management: Deployments create and manage ReplicaSets, which maintain a specified number of Pod replicas. The Deployment controller continuously monitors the cluster state and ensures that the desired number of Pods are running at all times. When Pods fail or nodes become unavailable, the controller automatically creates replacement Pods. This abstraction layer enables Deployments to provide sophisticated features like rolling updates and version rollbacks that ReplicaSets alone cannot offer.

Automatic Scaling Integration: While Deployments define the desired replica count through their specification, they integrate seamlessly with Kubernetes autoscaling mechanisms. HorizontalPodAutoscaler resources can monitor application metrics such as CPU utilization, memory consumption, or custom application metrics, and dynamically adjust the Deployment's replica count to match workload demands. This enables applications to automatically scale up during peak traffic and scale down during quiet periods, optimizing resource utilization and cost.

Zero-Downtime Updates: The deployment strategy field enables zero-downtime application updates by controlling how existing Pod instances are replaced with new versions. The default rolling update strategy gradually replaces instances while maintaining a minimum number of available Pods, ensuring users experience no service interruption during application updates. This controlled update process includes health checks to verify new instances are ready before terminating old ones.

Version History and Rollback: Deployments maintain a configurable history of ReplicaSets, with a default retention of 10 revisions. Each update creates a new ReplicaSet while preserving previous ones (scaled to zero replicas), enabling rapid rollback to any previous version when issues are detected. This versioning system provides a safety net for production deployments, allowing teams to quickly recover from failed updates or configuration changes.

Self-Healing Capabilities: The Deployment controller, working through its ReplicaSet, continuously monitors Pod health and automatically replaces failed, terminated, or unresponsive Pods. This self-healing mechanism operates without manual intervention, ensuring applications maintain their desired state even in the face of infrastructure failures, application crashes, or network partitions.

## Workshop: Creating and Managing Deployments

This workshop provides hands-on experience with Deployments, covering creation, scaling, updates, and management operations essential for running production applications.

### Basic Deployment Creation

Let's start by creating a simple Deployment and examining its components:

```bash
# Create a deployment with nginx web server and 3 replicas
kubectl create deployment webapp --image=nginx:1.20 --replicas=3

# View the deployment status
kubectl get deployments
kubectl get deploy webapp  # Short form of the command

# Display detailed deployment information
kubectl describe deployment webapp

# View all resources created by the deployment
kubectl get all -l app=webapp

# List pods with additional information including node placement
kubectl get pods -l app=webapp -o wide

# Examine the ReplicaSet managing the pods
kubectl get replicasets -l app=webapp
kubectl get rs -l app=webapp  # Short form

# Display the relationship hierarchy
kubectl get deploy,rs,pods -l app=webapp
```

When you run these commands, you'll observe the naming pattern that Kubernetes uses. The Deployment creates a ReplicaSet with a hash suffix (like `webapp-5d4f4b96c`), which in turn creates Pods with an additional random suffix (like `webapp-5d4f4b96c-7kqxz`). This naming hierarchy enables Kubernetes to track ownership and manage rolling updates effectively.

### Deployment YAML Structure

For production deployments, you'll typically define your Deployments using YAML manifests. Create a file named `webapp-deployment.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: webapp
  labels:
    app: webapp
    environment: production
spec:
  replicas: 3
  selector:
    matchLabels:
      app: webapp
  template:
    metadata:
      labels:
        app: webapp
        version: "1.20"
    spec:
      containers:
      - name: nginx
        image: nginx:1.20
        ports:
        - containerPort: 80
          protocol: TCP
        resources:
          requests:
            memory: "64Mi"
            cpu: "100m"
          limits:
            memory: "128Mi"
            cpu: "200m"
```

Understanding the key components of this YAML:

- apiVersion: apps/v1: Specifies the stable API version for Deployments
- metadata.labels: Labels attached to the Deployment object itself, used for organizing and selecting Deployments
- spec.replicas: Defines the desired number of Pod instances to maintain
- spec.selector.matchLabels: Defines how the Deployment identifies its Pods; these labels must match those in the Pod template
- spec.template: The Pod template used to create new Pod instances
- spec.template.metadata.labels: Labels applied to each Pod created from this template; must include all labels specified in the selector
- resources: Resource requests influence Pod scheduling decisions, while limits enforce maximum resource consumption

Apply the configuration and verify the deployment:

```bash
# Apply the YAML configuration
kubectl apply -f webapp-deployment.yaml

# Verify the deployment was created successfully
kubectl get deployment webapp

# Check the deployment status in detail
kubectl get deployment webapp -o yaml | head -30
```

## Manual Application Scaling

Scaling is a fundamental capability of Deployments, allowing applications to adapt to varying workload demands. When you scale a Deployment, Kubernetes orchestrates a series of operations to reach the desired state while maintaining application availability.

### Understanding Scaling Mechanics

The scaling process involves several Kubernetes components working in coordination:

1. When you issue a scale command, the Deployment controller updates the desired replica count in the Deployment specification
2. The Deployment controller then updates the associated ReplicaSet's desired replica count
3. The ReplicaSet controller detects the discrepancy between desired and actual Pod count
4. For scale-up operations, the ReplicaSet controller creates new Pod objects
5. The Kubernetes scheduler identifies suitable nodes for new Pods based on resource availability and constraints
6. The kubelet on each selected node pulls container images and starts the containers
7. For scale-down operations, the ReplicaSet controller selects Pods for termination and initiates graceful shutdown

### Scaling Operations

Let's explore various scaling scenarios:

```bash
# Create a deployment for scaling demonstrations
kubectl create deployment scaledapp --image=nginx:1.20 --replicas=3

# Display current deployment status with replica information
kubectl get deploy scaledapp -o wide

# Scale the deployment up to 5 replicas
kubectl scale deployment scaledapp --replicas=5

# Monitor the scaling operation in real-time
kubectl get pods -l app=scaledapp -w
# Press Ctrl+C to stop watching

# Verify the scaling operation completed
kubectl get deployment scaledapp
kubectl get pods -l app=scaledapp --no-headers | wc -l

# Scale down to 2 replicas
kubectl scale deployment scaledapp --replicas=2

# Review events to see which pods were terminated
kubectl get events --field-selector involvedObject.kind=Pod | grep scaledapp | tail -5

# Scale to zero replicas (useful for maintenance or cost optimization)
kubectl scale deployment scaledapp --replicas=0
kubectl get pods -l app=scaledapp  # Should show no pods

# Scale back up to 3 replicas
kubectl scale deployment scaledapp --replicas=3
```

### Monitoring Scaling Operations

Effective monitoring helps ensure scaling operations complete successfully:

```bash
# Monitor pods with custom columns showing key information
kubectl get pods -l app=scaledapp -w -o custom-columns=NAME:.metadata.name,STATUS:.status.phase,NODE:.spec.nodeName

# Review deployment events for scaling history
kubectl describe deploy scaledapp | grep -A10 Events

# Examine ReplicaSet events
kubectl describe replicaset -l app=scaledapp | grep -A10 Events

# Check cluster capacity to ensure sufficient resources for scaling
kubectl top nodes
```

### Demonstrating Self-Healing

Self-healing ensures application availability by automatically replacing failed Pods:

```bash
# Create a deployment for self-healing demonstration
kubectl create deployment healingapp --image=nginx:1.20 --replicas=3

# List current pods and select one for deletion
kubectl get pods -l app=healingapp
POD_TO_DELETE=$(kubectl get pods -l app=healingapp -o jsonpath='{.items[0].metadata.name}')
echo "Will delete pod: $POD_TO_DELETE"

# Start monitoring pods in background
kubectl get pods -l app=healingapp -w &

# Delete the pod to simulate failure
kubectl delete pod $POD_TO_DELETE

# Observe automatic Pod recreation in the watch output
# You'll see: pod terminating, new pod pending, new pod running

# Stop the background watch
kill %1

# Verify three pods are still running
kubectl get pods -l app=healingapp

# Clean up
kubectl delete deployment healingapp
```

## Application Update Strategies

Deployments support two primary update strategies that control how new application versions are rolled out. The choice of strategy depends on your application's architecture, compatibility requirements, and tolerance for downtime.

### Rolling Update Strategy (Default)

Rolling updates incrementally replace old Pods with new ones, maintaining service availability throughout the update process. This strategy is the default and most commonly used approach for stateless applications.

The rolling update process carefully orchestrates Pod replacement:

- New Pods are created with the updated configuration
- Kubernetes waits for new Pods to pass readiness checks
- Old Pods receive termination signals and are given time to complete existing requests
- The process continues until all Pods run the new version

Key configuration parameters control the update behavior:

- maxSurge: Specifies how many Pods can be created above the desired replica count during updates
- maxUnavailable: Defines the maximum number of Pods that can be unavailable during the update process

```bash
# Create a deployment for rolling update demonstration
kubectl create deployment rollingapp --image=nginx:1.20 --replicas=6

# Examine the default update strategy
kubectl get deployment rollingapp -o jsonpath='{.spec.strategy}' | python3 -m json.tool

# Perform a rolling update to a new version with an annotation instead of --record
kubectl set image deployment/rollingapp nginx=nginx:1.21 \
  --dry-run=client -o yaml | kubectl apply -f -

# Optionally, annotate the deployment to record the change
kubectl annotate deployment rollingapp kubernetes.io/change-cause="Updated nginx to 1.21" --overwrite

# Monitor the rollout progress
kubectl rollout status deployment/rollingapp --watch

# In another terminal, watch pods being replaced
kubectl get pods -l app=rollingapp -w

# Review rollout history
kubectl rollout history deployment rollingapp
```

### Customized Rolling Update Configuration

Create `rolling-update-deployment.yaml` to demonstrate fine-tuned rolling update control:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: rolling-app
  labels:
    app: rolling-app
spec:
  replicas: 10
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 3        # Can create up to 3 extra pods during update
      maxUnavailable: 2  # Maximum 2 pods can be unavailable
  selector:
    matchLabels:
      app: rolling-app
  template:
    metadata:
      labels:
        app: rolling-app
        version: "1.20"
    spec:
      containers:
      - name: nginx
        image: nginx:1.20
        ports:
        - containerPort: 80
        readinessProbe:
          httpGet:
            path: /
            port: 80
          initialDelaySeconds: 5
          periodSeconds: 3
        livenessProbe:
          httpGet:
            path: /
            port: 80
          initialDelaySeconds: 10
          periodSeconds: 5
```

Apply and test the configuration:

```bash
# Deploy the application
kubectl apply -f rolling-update-deployment.yaml

# Trigger an update and observe the controlled rollout
kubectl set image deployment/rolling-app nginx=nginx:1.21
kubectl get pods -l app=rolling-app -w
```

### Recreate Strategy

The recreate strategy terminates all existing Pods before creating new ones. While this approach causes downtime, it's necessary for certain applications that cannot tolerate multiple versions running simultaneously.

Use cases for the recreate strategy include:

- Applications with binary incompatible changes between versions
- Database schema migrations that break backward compatibility
- Applications with strict resource constraints where running extra Pods is not feasible
- Development or testing environments where brief downtime is acceptable

Create `recreate-deployment.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: recreate-app
  labels:
    app: recreate-app
spec:
  replicas: 5
  strategy:
    type: Recreate  # All pods terminated before creating new ones
  selector:
    matchLabels:
      app: recreate-app
  template:
    metadata:
      labels:
        app: recreate-app
        version: "1.20"
    spec:
      containers:
      - name: nginx
        image: nginx:1.20
        ports:
        - containerPort: 80
```

Test the recreate strategy:

```bash
# Deploy the application
kubectl apply -f recreate-deployment.yaml

# Start monitoring pods
kubectl get pods -l app=recreate-app -w &

# Trigger an update to observe the recreate behavior
kubectl set image deployment/recreate-app nginx=nginx:1.21

# Notice the period where all pods terminate before new ones start
# Stop watching
kill %1
```

## Deployment History and Rollback Management

Kubernetes maintains deployment history through ReplicaSets, enabling version tracking and rapid rollback capabilities. This sophisticated versioning system provides a safety net for production deployments.

### Understanding Revision History

Each Deployment update creates a new ReplicaSet while preserving previous ones (scaled to zero replicas). This approach enables instant rollbacks and provides a complete audit trail of changes.

```bash
# Create a deployment with change tracking
kubectl create deployment versioned-app --image=nginx:1.20 --replicas=4
kubectl annotate deployment versioned-app kubernetes.io/change-cause="Initial deployment with nginx 1.20"

# View initial revision
kubectl rollout history deployment versioned-app

# Perform first update
kubectl set image deployment/versioned-app nginx=nginx:1.21
kubectl annotate deployment versioned-app kubernetes.io/change-cause="Updated to nginx 1.21"

# Perform second update
kubectl set image deployment/versioned-app nginx=nginx:1.22
kubectl annotate deployment versioned-app kubernetes.io/change-cause="Updated to nginx 1.22"

# View complete history with change descriptions
kubectl rollout history deployment versioned-app

# Examine details of a specific revision
kubectl rollout history deployment versioned-app --revision=2

# List all ReplicaSets to see version history
kubectl get replicasets -l app=versioned-app
```

### Performing Rollbacks

Rollbacks allow rapid recovery from problematic updates:

```bash
# Rollback to the previous revision
kubectl rollout undo deployment versioned-app

# Monitor rollback progress
kubectl rollout status deployment versioned-app

# Verify the current image version
kubectl get deployment versioned-app -o jsonpath='{.spec.template.spec.containers[0].image}'
echo ""

# Rollback to a specific revision
kubectl rollout undo deployment versioned-app --to-revision=1

# Verify pods are running the correct image version
kubectl get pods -l app=versioned-app -o jsonpath='{range .items[*]}{.metadata.name}: {.spec.containers[0].image}{"\n"}{end}'

# Review updated history (revision numbers change after rollback)
kubectl rollout history deployment versioned-app
```

### Managing Revision History Limits

Control how many old ReplicaSets are retained:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: history-limited-app
spec:
  revisionHistoryLimit: 3  # Keep only 3 old ReplicaSets
  replicas: 3
  selector:
    matchLabels:
      app: history-limited-app
  template:
    metadata:
      labels:
        app: history-limited-app
    spec:
      containers:
      - name: nginx
        image: nginx:1.20
```

### Pausing and Resuming Deployments

Pausing allows multiple changes to be batched into a single rollout:

```bash
# Create a deployment
kubectl create deployment pausable-app --image=nginx:1.20 --replicas=3

# Pause the deployment to prevent rollouts
kubectl rollout pause deployment pausable-app

# Make multiple changes without triggering updates
kubectl set image deployment/pausable-app nginx=nginx:1.21
kubectl set resources deployment/pausable-app -c nginx --limits=memory=256Mi,cpu=500m
kubectl scale deployment pausable-app --replicas=5

# Resume deployment to apply all changes at once
kubectl rollout resume deployment pausable-app

# Verify only one rollout occurred
kubectl rollout history deployment pausable-app
```
