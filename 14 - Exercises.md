### + Task 1: Basic Namespace and Pod Creation

Create a namespace called "development" and deploy a pod named "web-server" running nginx:latest in that namespace. Verify the pod is running and accessible.

### + Task 2: Working with Labels and Selectors

Create three pods with different labels:

- frontend pod with labels: app=web, tier=frontend, env=prod
- backend pod with labels: app=api, tier=backend, env=prod
- database pod with labels: app=db, tier=data, env=dev Use kubectl selectors to query pods by different label combinations.

### Task 3: ConfigMap Creation and Usage

Create a configuration file with application properties, create a ConfigMap from it, and mount it in a pod at /etc/config. Verify the configuration is accessible inside the container.

### Task 4: Secret Management

Create a secret containing database credentials (username and password) and use it in a pod as environment variables. Verify the secret values are accessible but not visible in pod specifications.

### + Task 5: Multi-Container Pod with Shared Volume

Create a pod with two containers: one that writes timestamps to a shared log file every 5 seconds, and another that reads and displays the log file content. Use an emptyDir volume for sharing data.

### + Task 6: Deployment Creation and Management

Create a deployment with 3 replicas running nginx:1.19. Update it to nginx:1.20, monitor the rollout, then rollback to the previous version. Verify the rollout history.

### + Task 7: Service Creation and Types

Create a deployment and expose it using different service types (ClusterIP, NodePort). Test connectivity to each service type and document the differences.

### Task 8: Persistent Storage with PVC

Create a PersistentVolume using hostPath storage, create a matching PersistentVolumeClaim, and use it in a pod. Write data to the volume and verify it persists after pod restart.

### + Task 9: Job and CronJob

Create a Job that runs a batch task (counting from 1 to 100) and a CronJob that executes every 2 minutes to log the current date and time.

### Task 10: Resource Limits and Requests

Create pods with different CPU and memory requests and limits. Create one pod that exceeds available cluster resources and observe the scheduling behavior.

### + Task 11: Init Containers

Create a pod with two init containers that prepare data and set permissions before the main nginx container starts. Verify the initialization sequence.

### + Task 12: Liveness and Readiness Probes

Configure a pod with HTTP-based liveness and readiness probes. Create a scenario where probes fail and observe Kubernetes behavior.

### Task 13: Resource Quotas and Namespace Limits

Create a namespace with ResourceQuota limiting CPU, memory, and pod count. Create a LimitRange with default values. Test quota enforcement by creating pods.

### Task 14: RBAC Configuration

Create a ServiceAccount, Role with pod read-only permissions, and RoleBinding. Create a pod using this ServiceAccount and test the permissions using kubectl commands.

### + Task 15: StatefulSet Deployment

Deploy a StatefulSet with 3 replicas, each with its own PersistentVolumeClaim. Verify ordered deployment, stable network identities, and persistent storage.

### + Task 16: DaemonSet Implementation

Create a DaemonSet that runs a simple log collector (using busybox) on every node. Include tolerations for control plane nodes if necessary.

### Task 17: Pod Security Context

Create pods with different security contexts:

- Pod running as non-root user (UID 1000)
- Pod with read-only root filesystem
- Pod with dropped capabilities (drop ALL, add NET_BIND_SERVICE)

### Task 18: NetworkPolicy Implementation

Create a namespace with three pods and implement NetworkPolicies to:

- Allow frontend pods to communicate with backend pods only
- Block all other communication
- Allow egress to external DNS servers

### Task 19: Pod Disruption Budget

Create a deployment with 5 replicas and a PodDisruptionBudget ensuring minimum 3 pods remain available. Simulate node maintenance scenarios.

### Task 20: Node Affinity and Pod Anti-Affinity

Create deployments demonstrating:

- Node affinity (schedule pods on specific node types)
- Pod anti-affinity (spread pods across different nodes)
- Pod affinity (co-locate related pods)

### Task 21: Taints and Tolerations

Apply taints to nodes and create pods with appropriate tolerations. Test scenarios where pods can and cannot be scheduled on tainted nodes.

### Task 22: Custom Resource Definition

Create a simple CRD for "WebApp" resources with fields for replicas, image, and port. Create instances of your custom resource and verify they're stored.

### Task 23: ConfigMap and Secret Updates

Create pods that use ConfigMaps and Secrets as volumes and environment variables. Update the ConfigMap/Secret and verify how changes propagate to running pods.

### Task 24: Multi-Container Communication

Create a pod with containers that communicate via localhost (shared network namespace) and shared volumes. Implement a simple producer-consumer pattern.

### Task 25: Rolling Updates with Manual Control

Create a deployment and practice different rollout strategies. Implement controlled rollouts with manual verification steps between updates.

### + Task 26: Service Discovery

Create multiple services and demonstrate how pods can discover and communicate with services using DNS names, environment variables, and direct service calls.

### Task 27: Troubleshooting Pod Issues

Intentionally create problematic pods (wrong image tags, missing secrets, resource conflicts) and practice debugging using kubectl describe, logs, and events.

### Task 28: Static Pod Configuration

Create a static pod on a specific worker node using the nginx image. Configure it to restart automatically and mount the host's `/var/log` directory.

### Task 29: Node Drain and Maintenance

Safely drain a worker node, perform maintenance (simulate by cordoning), and then make it schedulable again. Verify that pods are rescheduled appropriately.

### Task 30: Comprehensive Cleanup

Create a cleanup strategy for removing resources in the correct order. Practice identifying and removing orphaned resources, unused ConfigMaps, and completed Jobs.



# Solutions

## Solution 1: Basic Namespace and Pod Creation

Create namespace:

```bash
kubectl create namespace development
```

Create pod YAML:

```yaml
# web-server-pod.yaml
apiVersion: v1
kind: Pod
metadata:
  name: web-server
  namespace: development
spec:
  containers:
    - name: nginx
      image: nginx:latest
      ports:
        - containerPort: 80
```

Deploy and verify:

```bash
kubectl apply -f web-server-pod.yaml
kubectl get pods -n development
kubectl describe pod web-server -n development
```

## Solution 2: Working with Labels and Selectors

Create pods with labels:

```yaml
# labeled-pods.yaml
apiVersion: v1
kind: Pod
metadata:
  name: frontend
  labels:
    app: web
    tier: frontend
    env: prod
spec:
  containers:
    - name: nginx
      image: nginx:latest
---
apiVersion: v1
kind: Pod
metadata:
  name: backend
  labels:
    app: api
    tier: backend
    env: prod
spec:
  containers:
    - name: nginx
      image: nginx:latest
---
apiVersion: v1
kind: Pod
metadata:
  name: database
  labels:
    app: db
    tier: data
    env: dev
spec:
  containers:
    - name: nginx
      image: nginx:latest
```

Query with selectors:

```bash
kubectl apply -f labeled-pods.yaml

# Query by different labels
kubectl get pods -l env=prod
kubectl get pods -l tier=frontend
kubectl get pods -l app=web,env=prod
kubectl get pods -l 'tier in (frontend,backend)'
```

## Solution 3: ConfigMap Creation and Usage

Create config file:

```bash
cat > app.properties << EOF
database.host=localhost
database.port=5432
app.name=MyApplication
debug=true
EOF
```

Create ConfigMap:

```bash
kubectl create configmap app-config --from-file=app.properties
```

Pod using ConfigMap:

```yaml
# configmap-pod.yaml
apiVersion: v1
kind: Pod
metadata:
  name: config-pod
spec:
  containers:
  - name: app
    image: busybox
    command: ['sleep', '3600']
    volumeMounts:
    - name: config-volume
      mountPath: /etc/config
  volumes:
  - name: config-volume
    configMap:
      name: app-config
```

Deploy and verify:

```bash
kubectl apply -f configmap-pod.yaml
kubectl exec config-pod -- cat /etc/config/app.properties
```

## Solution 4: Secret Management

Create secret:

```bash
kubectl create secret generic db-credentials \
  --from-literal=username=admin \
  --from-literal=password=secretpassword
```

Pod using secret:

```yaml
# secret-pod.yaml
apiVersion: v1
kind: Pod
metadata:
  name: secret-pod
spec:
  containers:
  - name: app
    image: busybox
    command: ['sleep', '3600']
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
```

Deploy and verify:

```bash
kubectl apply -f secret-pod.yaml
kubectl exec secret-pod -- env | grep DB_
```

## Solution 5: Multi-Container Pod with Shared Volume

```yaml
# multi-container-pod.yaml
apiVersion: v1
kind: Pod
metadata:
  name: multi-container-pod
spec:
  containers:
  - name: writer
    image: busybox
    command: ['sh', '-c', 'while true; do echo "$(date): Hello from writer" >> /var/log/app.log; sleep 5; done']
    volumeMounts:
    - name: shared-log
      mountPath: /var/log
  - name: reader
    image: busybox
    command: ['sh', '-c', 'tail -f /var/log/app.log']
    volumeMounts:
    - name: shared-log
      mountPath: /var/log
  volumes:
  - name: shared-log
    emptyDir: {}
```

Deploy and verify:

```bash
kubectl apply -f multi-container-pod.yaml
kubectl logs multi-container-pod -c writer
kubectl logs multi-container-pod -c reader
```

## Solution 6: Deployment Creation and Management

```yaml
# nginx-deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx-deployment
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
        image: nginx:1.19
        ports:
        - containerPort: 80
```

Deploy, update, and rollback:

```bash
kubectl apply -f nginx-deployment.yaml
kubectl rollout status deployment/nginx-deployment

# Update to nginx:1.20
kubectl set image deployment/nginx-deployment nginx=nginx:1.20
kubectl rollout status deployment/nginx-deployment

# Check rollout history
kubectl rollout history deployment/nginx-deployment

# Rollback to previous version
kubectl rollout undo deployment/nginx-deployment
kubectl rollout status deployment/nginx-deployment
```

## Solution 7: Service Creation and Types

```yaml
# services.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: app-deployment
spec:
  replicas: 2
  selector:
    matchLabels:
      app: myapp
  template:
    metadata:
      labels:
        app: myapp
    spec:
      containers:
      - name: nginx
        image: nginx:latest
        ports:
        - containerPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: app-clusterip
spec:
  type: ClusterIP
  selector:
    app: myapp
  ports:
  - port: 80
    targetPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: app-nodeport
spec:
  type: NodePort
  selector:
    app: myapp
  ports:
  - port: 80
    targetPort: 80
    nodePort: 30080
```

Deploy and test:

```bash
kubectl apply -f services.yaml

# Test ClusterIP (from within cluster)
kubectl run test-pod --image=busybox --rm -it -- wget -qO- app-clusterip

# Test NodePort
NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[0].address}')
curl http://$NODE_IP:30080
```

## Solution 8: Persistent Storage with PVC

```yaml
# storage.yaml
apiVersion: v1
kind: PersistentVolume
metadata:
  name: my-pv
spec:
  capacity:
    storage: 1Gi
  accessModes:
  - ReadWriteOnce
  hostPath:
    path: /mnt/k8s-data
  persistentVolumeReclaimPolicy: Retain
  storageClassName: manual
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: my-pvc
spec:
  accessModes:
  - ReadWriteOnce
  resources:
    requests:
      storage: 1Gi
  storageClassName: manual
---
apiVersion: v1
kind: Pod
metadata:
  name: pvc-pod
spec:
  containers:
  - name: app
    image: busybox
    command: ['sleep', '3600']
    volumeMounts:
    - name: storage
      mountPath: /data
  volumes:
  - name: storage
    persistentVolumeClaim:
      claimName: my-pvc
```

Deploy and test persistence:

```bash
kubectl apply -f storage.yaml
kubectl exec pvc-pod -- sh -c 'echo "persistent data" > /data/test.txt'
kubectl delete pod pvc-pod
# Recreate the pod (PV and PVC still exist)
kubectl apply -f storage.yaml
kubectl exec pvc-pod -- cat /data/test.txt
```

## Solution 9: Job and CronJob

```yaml
# jobs.yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: counting-job
spec:
  template:
    spec:
      containers:
      - name: counter
        image: busybox
        command: ['sh', '-c', 'for i in $(seq 1 100); do echo "Count: $i"; sleep 1; done']
      restartPolicy: Never
  backoffLimit: 4
---
apiVersion: batch/v1
kind: CronJob
metadata:
  name: datetime-cronjob
spec:
  schedule: "*/2 * * * *"
  jobTemplate:
    spec:
      template:
        spec:
          containers:
          - name: logger
            image: busybox
            command: ['sh', '-c', 'echo "Current date and time: $(date)"']
          restartPolicy: OnFailure
```

Deploy and monitor:

```bash
kubectl apply -f jobs.yaml
kubectl get jobs
kubectl logs job/counting-job
kubectl get cronjobs
```

## Solution 10: Resource Limits and Requests

```yaml
# resource-pods.yaml
apiVersion: v1
kind: Pod
metadata:
  name: resource-pod
spec:
  containers:
  - name: app
    image: nginx:latest
    resources:
      requests:
        memory: "128Mi"
        cpu: "100m"
      limits:
        memory: "256Mi"
        cpu: "200m"
---
apiVersion: v1
kind: Pod
metadata:
  name: high-resource-pod
spec:
  containers:
  - name: app
    image: nginx:latest
    resources:
      requests:
        memory: "8Gi"
        cpu: "4"
```

Deploy and observe:

```bash
kubectl apply -f resource-pods.yaml
kubectl get pods
kubectl describe pod high-resource-pod
```

## Solution 11: Init Containers

```yaml
# init-containers-pod.yaml
apiVersion: v1
kind: Pod
metadata:
  name: init-containers-pod
spec:
  initContainers:
  - name: data-prepare
    image: busybox
    command: ['sh', '-c', 'echo "<h1>Initial data</h1>" > /shared/index.html']
    volumeMounts:
    - name: shared-data
      mountPath: /shared
  - name: permissions-setup
    image: busybox
    command: ['sh', '-c', 'chmod 755 /shared/index.html']
    volumeMounts:
    - name: shared-data
      mountPath: /shared
  containers:
  - name: nginx
    image: nginx:latest
    volumeMounts:
    - name: shared-data
      mountPath: /usr/share/nginx/html
    ports:
    - containerPort: 80
  volumes:
  - name: shared-data
    emptyDir: {}
```

Deploy and verify:

```bash
kubectl apply -f init-containers-pod.yaml
kubectl get pods -w
kubectl logs init-containers-pod -c data-prepare
kubectl logs init-containers-pod -c permissions-setup
```

## Solution 12: Liveness and Readiness Probes

```yaml
# probes-pod.yaml
apiVersion: v1
kind: Pod
metadata:
  name: probes-pod
spec:
  containers:
  - name: nginx
    image: nginx:latest
    ports:
    - containerPort: 80
    livenessProbe:
      httpGet:
        path: /
        port: 80
      initialDelaySeconds: 30
      periodSeconds: 10
      failureThreshold: 3
    readinessProbe:
      httpGet:
        path: /
        port: 80
      initialDelaySeconds: 5
      periodSeconds: 5
```

Deploy and test:

```bash
kubectl apply -f probes-pod.yaml

# Simulate failure
kubectl exec probes-pod -- rm /usr/share/nginx/html/index.html

# Watch for restart
kubectl get pods -w
kubectl describe pod probes-pod
```

## Solution 13: Resource Quotas and Namespace Limits

```yaml
# quotas.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: quota-demo
---
apiVersion: v1
kind: ResourceQuota
metadata:
  name: compute-quota
  namespace: quota-demo
spec:
  hard:
    requests.cpu: "2"
    requests.memory: 2Gi
    limits.cpu: "4"
    limits.memory: 4Gi
    pods: "10"
---
apiVersion: v1
kind: LimitRange
metadata:
  name: default-limits
  namespace: quota-demo
spec:
  limits:
  - default:
      memory: "256Mi"
      cpu: "200m"
    defaultRequest:
      memory: "128Mi"
      cpu: "100m"
    type: Container
```

Deploy and test:

```bash
kubectl apply -f quotas.yaml
kubectl describe namespace quota-demo
kubectl describe resourcequota compute-quota -n quota-demo
```

## Solution 14: RBAC Configuration

```yaml
# rbac.yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: pod-reader
  namespace: default
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  namespace: default
  name: pod-reader-role
rules:
- apiGroups: [""]
  resources: ["pods"]
  verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: read-pods
  namespace: default
subjects:
- kind: ServiceAccount
  name: pod-reader
  namespace: default
roleRef:
  kind: Role
  name: pod-reader-role
  apiGroup: rbac.authorization.k8s.io
---
apiVersion: v1
kind: Pod
metadata:
  name: rbac-pod
spec:
  serviceAccountName: pod-reader
  containers:
  - name: kubectl
    image: bitnami/kubectl:latest
    command: ['sleep', '3600']
```

Test permissions:

```bash
kubectl apply -f rbac.yaml
kubectl exec rbac-pod -- kubectl get pods
kubectl exec rbac-pod -- kubectl get secrets # Should fail
```

## Solution 15: StatefulSet Deployment

```yaml
# statefulset.yaml
apiVersion: v1
kind: Service
metadata:
  name: web
spec:
  ports:
  - port: 80
  clusterIP: None
  selector:
    app: web
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: web-statefulset
spec:
  serviceName: "web"
  replicas: 3
  selector:
    matchLabels:
      app: web
  template:
    metadata:
      labels:
        app: web
    spec:
      containers:
      - name: nginx
        image: nginx:latest
        ports:
        - containerPort: 80
        volumeMounts:
        - name: www
          mountPath: /usr/share/nginx/html
  volumeClaimTemplates:
  - metadata:
      name: www
    spec:
      accessModes: ["ReadWriteOnce"]
      resources:
        requests:
          storage: 1Gi
      storageClassName: manual
```

Deploy and verify:

```bash
kubectl apply -f statefulset.yaml
kubectl get statefulsets
kubectl get pods -l app=web
kubectl get pvc
```

## Solution 16: DaemonSet Implementation

```yaml
# daemonset.yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: log-collector
spec:
  selector:
    matchLabels:
      name: log-collector
  template:
    metadata:
      labels:
        name: log-collector
    spec:
      tolerations:
      - key: node-role.kubernetes.io/control-plane
        operator: Exists
        effect: NoSchedule
      - key: node-role.kubernetes.io/master
        operator: Exists
        effect: NoSchedule
      containers:
      - name: log-collector
        image: busybox
        command: ['sh', '-c', 'while true; do echo "Collecting logs from $(hostname)"; sleep 30; done']
        resources:
          limits:
            memory: 128Mi
            cpu: 100m
```

Deploy:

```bash
kubectl apply -f daemonset.yaml
kubectl get daemonsets
kubectl get pods -l name=log-collector -o wide
```

## Solution 17: Pod Security Context

```yaml
# security-contexts.yaml
apiVersion: v1
kind: Pod
metadata:
  name: nonroot-pod
spec:
  securityContext:
    runAsUser: 1000
    runAsGroup: 1000
    fsGroup: 1000
  containers:
  - name: app
    image: busybox
    command: ['sleep', '3600']
---
apiVersion: v1
kind: Pod
metadata:
  name: readonly-pod
spec:
  containers:
  - name: app
    image: nginx:latest
    securityContext:
      readOnlyRootFilesystem: true
    volumeMounts:
    - name: tmp
      mountPath: /tmp
    - name: var-cache
      mountPath: /var/cache/nginx
    - name: var-run
      mountPath: /var/run
  volumes:
  - name: tmp
    emptyDir: {}
  - name: var-cache
    emptyDir: {}
  - name: var-run
    emptyDir: {}
---
apiVersion: v1
kind: Pod
metadata:
  name: capabilities-pod
spec:
  containers:
  - name: app
    image: nginx:latest
    securityContext:
      capabilities:
        drop:
        - ALL
        add:
        - NET_BIND_SERVICE
```

Deploy and test:

```bash
kubectl apply -f security-contexts.yaml
kubectl exec nonroot-pod -- id
```

## Solution 18: NetworkPolicy Implementation

```yaml
# network-policy.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: netpol-demo
---
apiVersion: v1
kind: Pod
metadata:
  name: frontend
  namespace: netpol-demo
  labels:
    tier: frontend
spec:
  containers:
  - name: nginx
    image: nginx:latest
---
apiVersion: v1
kind: Pod
metadata:
  name: backend
  namespace: netpol-demo
  labels:
    tier: backend
spec:
  containers:
  - name: nginx
    image: nginx:latest
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: frontend-to-backend
  namespace: netpol-demo
spec:
  podSelector:
    matchLabels:
      tier: backend
  policyTypes:
  - Ingress
  ingress:
  - from:
    - podSelector:
        matchLabels:
          tier: frontend
```

Deploy and test:

```bash
kubectl apply -f network-policy.yaml
# Test connectivity if NetworkPolicy is supported
kubectl exec -n netpol-demo frontend -- wget -qO- --timeout=5 backend
```

## Solution 19: Pod Disruption Budget

```yaml
# pdb.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: pdb-deployment
spec:
  replicas: 5
  selector:
    matchLabels:
      app: pdb-app
  template:
    metadata:
      labels:
        app: pdb-app
    spec:
      containers:
      - name: nginx
        image: nginx:latest
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: pdb-budget
spec:
  minAvailable: 3
  selector:
    matchLabels:
      app: pdb-app
```

Deploy and test:

```bash
kubectl apply -f pdb.yaml
kubectl get pdb
```

## Solution 20: Node Affinity and Pod Anti-Affinity

```yaml
# affinity.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: node-affinity-deployment
spec:
  replicas: 2
  selector:
    matchLabels:
      app: node-affinity-app
  template:
    metadata:
      labels:
        app: node-affinity-app
    spec:
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
            - matchExpressions:
              - key: kubernetes.io/os
                operator: In
                values:
                - linux
      containers:
      - name: nginx
        image: nginx:latest
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: pod-antiaffinity-deployment
spec:
  replicas: 3
  selector:
    matchLabels:
      app: antiaffinity-app
  template:
    metadata:
      labels:
        app: antiaffinity-app
    spec:
      affinity:
        podAntiAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
          - weight: 100
            podAffinityTerm:
              labelSelector:
                matchExpressions:
                - key: app
                  operator: In
                  values:
                  - antiaffinity-app
              topologyKey: kubernetes.io/hostname
      containers:
      - name: nginx
        image: nginx:latest
```

Deploy:

```bash
kubectl apply -f affinity.yaml
kubectl get pods -o wide
```

## Solution 21: Taints and Tolerations

```bash
# Apply taint to node
NODE_NAME=$(kubectl get nodes --no-headers -o custom-columns=NAME:.metadata.name | head -1)
kubectl taint nodes $NODE_NAME special=true:NoSchedule
```

```yaml
# tolerations.yaml
apiVersion: v1
kind: Pod
metadata:
  name: no-toleration-pod
spec:
  containers:
  - name: nginx
    image: nginx:latest
---
apiVersion: v1
kind: Pod
metadata:
  name: toleration-pod
spec:
  tolerations:
  - key: "special"
    operator: "Equal"
    value: "true"
    effect: "NoSchedule"
  containers:
  - name: nginx
    image: nginx:latest
```

Test and cleanup:

```bash
kubectl apply -f tolerations.yaml
kubectl get pods -o wide

# Remove taint
kubectl taint nodes $NODE_NAME special=true:NoSchedule-
```

## Solution 22: Custom Resource Definition

```yaml
# webapp-crd.yaml
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: webapps.example.com
spec:
  group: example.com
  versions:
  - name: v1
    served: true
    storage: true
    schema:
      openAPIV3Schema:
        type: object
        properties:
          spec:
            type: object
            required:
            - replicas
            - image
            - port
            properties:
              replicas:
                type: integer
                minimum: 1
                maximum: 10
              image:
                type: string
              port:
                type: integer
                minimum: 1
                maximum: 65535
  scope: Namespaced
  names:
    plural: webapps
    singular: webapp
    kind: WebApp
---
apiVersion: example.com/v1
kind: WebApp
metadata:
  name: my-webapp
spec:
  replicas: 3
  image: nginx:latest
  port: 80
```

Deploy and verify:

```bash
kubectl apply -f webapp-crd.yaml
kubectl get webapps
kubectl describe webapp my-webapp
```

## Solution 23: ConfigMap and Secret Updates

```yaml
# config-updates.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: app-configmap
data:
  config.properties: |
    app.name=MyApp
    app.version=1.0
---
apiVersion: v1
kind: Secret
metadata:
  name: app-secret
type: Opaque
data:
  username: YWRtaW4=  # admin
  password: cGFzc3dvcmQ=  # password
---
apiVersion: v1
kind: Pod
metadata:
  name: config-secret-pod
spec:
  containers:
  - name: app
    image: busybox
    command: ['sleep', '3600']
    env:
    - name: USERNAME
      valueFrom:
        secretKeyRef:
          name: app-secret
          key: username
    volumeMounts:
    - name: config-volume
      mountPath: /etc/config
    - name: secret-volume
      mountPath: /etc/secrets
  volumes:
  - name: config-volume
    configMap:
      name: app-configmap
  - name: secret-volume
    secret:
      secretName: app-secret
```

Deploy and update:

```bash
kubectl apply -f config-updates.yaml

# Update ConfigMap
kubectl patch configmap app-configmap --patch '{"data":{"config.properties":"app.name=MyApp\napp.version=2.0"}}'

# Verify changes propagate (for volumes, not env vars)
sleep 10
kubectl exec config-secret-pod -- cat /etc/config/config.properties
```

## Solution 24: Multi-Container Communication

```yaml
# producer-consumer.yaml
apiVersion: v1
kind: Pod
metadata:
  name: producer-consumer-pod
spec:
  containers:
  - name: producer
    image: busybox
    command: ['sh', '-c', 'while true; do echo "Message $(date)" >> /shared/messages.txt; sleep 5; done']
    volumeMounts:
    - name: shared-data
      mountPath: /shared
  - name: consumer
    image: busybox
    command: ['sh', '-c', 'while true; do if [ -f /shared/messages.txt ]; then tail -5 /shared/messages.txt; fi; sleep 10; done']
    volumeMounts:
    - name: shared-data
      mountPath: /shared
  - name: web-server
    image: nginx:alpine
    ports:
    - containerPort: 80
  volumes:
  - name: shared-data
    emptyDir: {}
```

Deploy and monitor:

```bash
kubectl apply -f producer-consumer.yaml
kubectl logs producer-consumer-pod -c producer
kubectl logs producer-consumer-pod -c consumer
```

## Solution 25: Rolling Updates with Manual Control

```bash
#!/bin/bash
# Deploy initial version
kubectl create deployment rolling-app --image=nginx:1.19 --replicas=5

# Start update and pause
kubectl set image deployment/rolling-app nginx=nginx:1.20
kubectl rollout pause deployment/rolling-app

echo "Rollout paused. Check status:"
kubectl rollout status deployment/rolling-app

# Resume after verification
read -p "Press Enter to continue rollout..."
kubectl rollout resume deployment/rolling-app
kubectl rollout status deployment/rolling-app

# View history
kubectl rollout history deployment/rolling-app
```

## Solution 26: Service Discovery

```yaml
# service-discovery.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: backend
spec:
  replicas: 2
  selector:
    matchLabels:
      app: backend
  template:
    metadata:
      labels:
        app: backend
    spec:
      containers:
      - name: nginx
        image: nginx:latest
---
apiVersion: v1
kind: Service
metadata:
  name: backend-service
spec:
  selector:
    app: backend
  ports:
  - port: 80
---
apiVersion: v1
kind: Pod
metadata:
  name: client-pod
spec:
  containers:
  - name: client
    image: busybox
    command: ['sleep', '3600']
```

Test service discovery:

```bash
kubectl apply -f service-discovery.yaml

# DNS discovery
kubectl exec client-pod -- nslookup backend-service

# HTTP test
kubectl exec client-pod -- wget -qO- http://backend-service

# Environment variables
kubectl exec client-pod -- env | grep SERVICE
```

## Solution 27: Troubleshooting Pod Issues

```yaml
# problematic-pods.yaml
apiVersion: v1
kind: Pod
metadata:
  name: wrong-image-pod
spec:
  containers:
  - name: app
    image: nginx:nonexistent-tag
---
apiVersion: v1
kind: Pod
metadata:
  name: missing-secret-pod
spec:
  containers:
  - name: app
    image: nginx:latest
    env:
    - name: SECRET_VALUE
      valueFrom:
        secretKeyRef:
          name: nonexistent-secret
          key: value
---
apiVersion: v1
kind: Pod
metadata:
  name: resource-conflict-pod
spec:
  containers:
  - name: app
    image: nginx:latest
    resources:
      requests:
        memory: "4Gi"
        cpu: "2"
```

Debug commands:

```bash
kubectl apply -f problematic-pods.yaml

# Check pod status
kubectl get pods

# Describe pods for details
kubectl describe pod wrong-image-pod
kubectl describe pod missing-secret-pod
kubectl describe pod resource-conflict-pod

# Check events
kubectl get events --sort-by=.metadata.creationTimestamp
```

## Solution 28: Static Pod Configuration

```yaml
# /etc/kubernetes/manifests/monitoring-pod.yaml (on target node)
apiVersion: v1
kind: Pod
metadata:
  name: monitoring-pod
  namespace: kube-system
spec:
  containers:
  - name: nginx
    image: nginx
    volumeMounts:
    - name: host-logs
      mountPath: /var/log/host
      readOnly: true
  volumes:
  - name: host-logs
    hostPath:
      path: /var/log
  restartPolicy: Always
```

Deploy:

```bash
# On the target worker node:
sudo cp monitoring-pod.yaml /etc/kubernetes/manifests/
sudo systemctl restart kubelet

# Verify from master:
kubectl get pods -n kube-system | grep monitoring
```

## Solution 29: Node Drain and Maintenance

```bash
# Create test deployment
kubectl create deployment test-app --image=nginx --replicas=6

# List nodes
kubectl get nodes

# Drain node (replace 'worker-1' with actual node name)
kubectl drain worker-1 --ignore-daemonsets --delete-emptydir-data

# Verify pods moved
kubectl get pods -o wide

# Simulate maintenance
echo "Performing maintenance..."
sleep 10

# Uncordon node
kubectl uncordon worker-1

# Verify node is ready
kubectl get nodes

# Cleanup
kubectl delete deployment test-app
```

## Solution 30: Comprehensive Cleanup

```bash
#!/bin/bash
echo "=== Kubernetes Resource Cleanup Script ==="
echo "WARNING: This will delete resources. Press Ctrl+C to abort, or Enter to continue..."
read

# Delete pods
kubectl delete pods --all --timeout=30s

# Delete deployments
kubectl delete deployment --all --timeout=60s

# Delete services (keep default kubernetes service)
kubectl delete service --all --ignore-not-found=true
kubectl get service kubernetes -o yaml | kubectl apply -f -

# Delete configmaps and secrets
kubectl delete configmap --all --ignore-not-found=true
kubectl delete secret --all --ignore-not-found=true

# Delete jobs and cronjobs
kubectl delete jobs --all --timeout=30s
kubectl delete cronjobs --all

# Delete statefulsets and daemonsets
kubectl delete statefulsets --all --timeout=60s
kubectl delete daemonsets --all --timeout=60s

# Delete PVCs and PVs
kubectl delete pvc --all --timeout=30s
kubectl delete pv --all --timeout=30s

# Delete custom resources
kubectl delete webapps --all 2>/dev/null || true
kubectl delete crd webapps.example.com 2>/dev/null || true

# Delete NetworkPolicies
kubectl delete networkpolicies --all 2>/dev/null || true

# Delete ResourceQuotas and LimitRanges
kubectl delete resourcequotas --all
kubectl delete limitranges --all

# Delete PodDisruptionBudgets
kubectl delete pdb --all

# Remove node taints
for node in $(kubectl get nodes -o name); do
  kubectl taint nodes ${node#*/} special- 2>/dev/null || true
done

# Delete custom namespaces
kubectl delete namespace development netpol-demo quota-demo 2>/dev/null || true

echo "=== Cleanup Complete ==="
kubectl get all --all-namespaces
```