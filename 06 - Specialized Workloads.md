
## Understanding Workloads

Kubernetes provides several specialized workload controllers designed to handle specific operational patterns that go beyond the capabilities of standard Deployments. While Deployments excel at managing stateless applications that can scale horizontally and tolerate random pod scheduling, many real-world applications require different operational characteristics.

The four primary specialized workload types each address distinct requirements:

Jobs execute tasks that run to completion rather than continuously. These are ideal for batch processing, data migrations, or any operation that has a definitive end state.

CronJobs extend Jobs by adding time-based scheduling, enabling periodic execution of tasks such as backups, report generation, or cleanup operations.

StatefulSets manage applications that require stable network identities and persistent storage, such as databases, distributed systems, and clustered applications where pod identity matters.

DaemonSets ensure that specific pods run on every node (or a subset of nodes) in the cluster, perfect for system-level services like log collectors, monitoring agents, or network plugins.

## Jobs for One-Time Tasks

Jobs in Kubernetes represent a fundamentally different execution model compared to typical pod controllers. While most controllers aim to keep pods running indefinitely, Jobs are designed to run pods that complete their work and then terminate successfully.

### Understanding Job Mechanics

When you create a Job, Kubernetes spawns one or more pods to execute the specified task. The Job controller monitors these pods and ensures they complete successfully. If a pod fails, the Job controller can retry the task based on your configuration. Once the required number of successful completions is achieved, the Job is marked as complete.

The key distinction between Job pods and regular pods lies in their restart policy. Job pods must use either `Never` or `OnFailure` as their restart policy, which tells Kubernetes that these pods are meant to terminate rather than run continuously.

### Job Execution Patterns

Jobs support three primary execution patterns, each suited to different workload types:

Non-parallel Jobs run a single pod to completion. This is the simplest pattern, suitable for tasks that cannot be parallelized or when you need guaranteed sequential execution.

Parallel Jobs with Fixed Completion Count run multiple pods simultaneously, continuing until a specified number of successful completions is achieved. This pattern works well when you have a known number of work items that can be processed independently.

Parallel Jobs with Work Queue pattern involves multiple pods processing items from a shared queue until the queue is empty. This pattern requires coordination between pods, typically through an external work queue system.

## Workshop: Jobs and CronJobs

This workshop demonstrates practical implementations of Jobs and CronJobs in Kubernetes. 

### Basic Job Operations

Let's start by creating and managing simple Jobs to understand their lifecycle and behavior.

#### Creating Your First Job

```bash
# Create a simple job using kubectl
kubectl create job hello --image=busybox:1.36 -- echo "Hello from Kubernetes Job"

# Verify the job was created
kubectl get jobs

# Check the status of the job
kubectl describe job hello

# Find the pod created by the job
kubectl get pods -l job-name=hello

# View the output from the job
kubectl logs job/hello

# Clean up the job and its pods
kubectl delete job hello
```

When you run these commands, you'll notice that unlike regular pods, the job's pod enters a `Completed` state rather than continuously running. The job controller tracks this completion and marks the job as successful.

#### Job YAML Structure

For more complex jobs, you'll want to use YAML manifests. Here's a complete job specification with important configuration options:

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: data-processor
  labels:
    app: batch-processing
spec:
  # Pod template specification
  template:
    metadata:
      labels:
        app: batch-processing
        job-type: data-processor
    spec:
      containers:
      - name: processor
        image: busybox:1.36
        command:
        - /bin/sh
        - -c
        - |
          echo "Job started at $(date)"
          echo "Processing data batch..."
          # Simulate processing time
          sleep 30
          echo "Data processing complete"
          echo "Job completed at $(date)"
        resources:
          requests:
            memory: "64Mi"
            cpu: "250m"
          limits:
            memory: "128Mi"
            cpu: "500m"
      restartPolicy: Never
  # Job-specific configurations
  backoffLimit: 4              # Maximum number of retries before marking job as failed
  activeDeadlineSeconds: 300   # Maximum time the job can run (5 minutes)
  ttlSecondsAfterFinished: 120 # Automatically delete job 2 minutes after completion
```

Deploy and monitor this job:

```bash
# Apply the job configuration
kubectl apply -f data-processor.yaml

# Watch the job progress in real-time
kubectl get jobs data-processor -w

# Monitor the pod status
kubectl get pods -l app=batch-processing -w

# View detailed job information including events
kubectl describe job data-processor

# Check the logs
kubectl logs -l job-name=data-processor

# The job will be automatically deleted after 2 minutes due to ttlSecondsAfterFinished
```

### Parallel Jobs

Parallel execution allows Jobs to process multiple work items simultaneously, significantly reducing total execution time for parallelizable tasks.

#### Fixed Completion Count Pattern

This pattern is ideal when you know exactly how many work items need to be processed:

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: parallel-processor
  labels:
    app: parallel-batch
spec:
  parallelism: 3      # Number of pods to run concurrently
  completions: 9      # Total number of successful completions required
  template:
    metadata:
      labels:
        app: parallel-batch
    spec:
      containers:
      - name: worker
        image: busybox:1.36
        command:
        - /bin/sh
        - -c
        - |
          # Generate a unique work item ID
          WORK_ID=$RANDOM
          echo "Worker $(hostname) starting task $WORK_ID"
          
          # Simulate varying processing times
          PROCESS_TIME=$((RANDOM % 20 + 10))
          echo "Processing will take $PROCESS_TIME seconds"
          sleep $PROCESS_TIME
          
          echo "Worker $(hostname) completed task $WORK_ID"
        resources:
          requests:
            memory: "32Mi"
            cpu: "100m"
      restartPolicy: Never
  backoffLimit: 10
```

Deploy and observe parallel execution:

```bash
# Deploy the parallel job
kubectl apply -f parallel-processor.yaml

# Watch pods being created and running in parallel
kubectl get pods -l app=parallel-batch -w

# Monitor job progress
kubectl get job parallel-processor -w

# View logs from all workers
kubectl logs -l job-name=parallel-processor --prefix=true

# Check which pods completed successfully
kubectl get pods -l job-name=parallel-processor -o custom-columns=NAME:.metadata.name,STATUS:.status.phase
```

## CronJobs for Scheduled Tasks

CronJobs extend the Job concept by adding time-based scheduling. They create Job objects according to a schedule defined using standard cron syntax, making them perfect for recurring tasks like backups, reports, and maintenance operations.

### Understanding Cron Syntax

The schedule field uses the standard Unix cron format with five fields:

```
* * * * *
│ │ │ │ │
│ │ │ │ └─── Day of week (0-7, where 0 and 7 represent Sunday)
│ │ │ └───── Month (1-12)
│ │ └─────── Day of month (1-31)
│ └───────── Hour (0-23)
└─────────── Minute (0-59)
```

Special characters:

- `*` matches any value
- `,` separates multiple values
- `-` defines a range
- `/` defines step values

### CronJob Implementation

Here's a comprehensive CronJob example that demonstrates key features:

```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: system-maintenance
  labels:
    app: maintenance
spec:
  schedule: "*/5 * * * *"  # Run every 5 minutes
  jobTemplate:
    metadata:
      labels:
        app: maintenance
        cronjob: system-maintenance
    spec:
      template:
        metadata:
          labels:
            app: maintenance
            cronjob: system-maintenance
        spec:
          containers:
          - name: maintenance
            image: busybox:1.36
            command:
            - /bin/sh
            - -c
            - |
              echo "=== Maintenance Task Started ==="
              echo "Timestamp: $(date '+%Y-%m-%d %H:%M:%S')"
              echo "Hostname: $(hostname)"
              
              # Simulate maintenance tasks
              echo "Cleaning temporary files..."
              sleep 10
              
              echo "Checking system health..."
              sleep 5
              
              echo "Generating report..."
              REPORT_ID=$RANDOM
              echo "Report ID: $REPORT_ID"
              
              echo "=== Maintenance Task Completed ==="
            resources:
              requests:
                memory: "32Mi"
                cpu: "50m"
              limits:
                memory: "64Mi"
                cpu: "100m"
          restartPolicy: OnFailure
      activeDeadlineSeconds: 240        # Job timeout of 4 minutes
      ttlSecondsAfterFinished: 3600    # Clean up completed jobs after 1 hour
  successfulJobsHistoryLimit: 3        # Keep last 3 successful jobs
  failedJobsHistoryLimit: 1            # Keep last 1 failed job
  concurrencyPolicy: Forbid            # Don't run new job if previous is still running
  startingDeadlineSeconds: 60          # Job must start within 60 seconds of schedule
```

Managing CronJobs:

```bash
# Deploy the CronJob
kubectl apply -f system-maintenance.yaml

# View CronJob details
kubectl get cronjobs
kubectl describe cronjob system-maintenance

# Watch jobs being created on schedule
kubectl get jobs --watch

# View recent job executions
kubectl get jobs -l cronjob=system-maintenance

# Check logs from the most recent execution
kubectl logs -l cronjob=system-maintenance --tail=20

# Manually trigger a job from the CronJob
kubectl create job manual-maintenance --from=cronjob/system-maintenance

# Suspend CronJob (stops creating new jobs)
kubectl patch cronjob system-maintenance -p '{"spec":{"suspend":true}}'

# Resume CronJob
kubectl patch cronjob system-maintenance -p '{"spec":{"suspend":false}}'
```

## StatefulSets for Stateful Applications

StatefulSets are a specialized workload controller designed for applications that require one or more of the following characteristics: stable and unique network identifiers, stable and persistent storage, ordered and graceful deployment and scaling, and ordered automated rolling updates.

### Understanding StatefulSet Identity

Each pod in a StatefulSet receives a unique, stable identity that consists of an ordinal index appended to the StatefulSet name. For example, a StatefulSet named `database` with three replicas creates pods named `database-0`, `database-1`, and `database-2`. These identities are maintained across pod rescheduling, ensuring that applications can rely on consistent naming.

### StatefulSet Components

A complete StatefulSet deployment requires several components working together:

Headless Service: A service with `clusterIP: None` that provides network identity and DNS entries for StatefulSet pods. This enables direct pod-to-pod communication using predictable DNS names.

Volume Claim Templates: Define persistent storage requirements for each pod. Unlike Deployments that might share volumes, each StatefulSet pod gets its own persistent volume claim.

Pod Management Policy: Controls whether pods are created/deleted in order (OrderedReady) or in parallel (Parallel).

### StatefulSet Implementation

Here's a complete example of a StatefulSet simulating a distributed database:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: database-service
  labels:
    app: distributed-db
spec:
  clusterIP: None  # Headless service for StatefulSet
  selector:
    app: distributed-db
  ports:
  - port: 5432
    targetPort: 5432
    name: postgres
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: distributed-db
  labels:
    app: distributed-db
spec:
  serviceName: database-service  # Must match the headless service name
  replicas: 3
  selector:
    matchLabels:
      app: distributed-db
  podManagementPolicy: OrderedReady  # Create/delete pods in order
  updateStrategy:
    type: RollingUpdate
    rollingUpdate:
      partition: 0  # Update all pods
  template:
    metadata:
      labels:
        app: distributed-db
    spec:
      containers:
      - name: database
        image: busybox:1.36
        command:
        - /bin/sh
        - -c
        - |
          # Get pod ordinal from hostname
          ORDINAL=${HOSTNAME##*-}
          echo "Database instance $ORDINAL starting"
          
          # Create data directory
          mkdir -p /data/db
          
          # Write instance configuration
          cat > /data/db/config.txt << EOF
          Instance ID: $ORDINAL
          Hostname: $HOSTNAME
          Started: $(date)
          Role: $([ "$ORDINAL" = "0" ] && echo "PRIMARY" || echo "REPLICA")
          EOF
          
          # Simulate database operations
          while true; do
            echo "$(date '+%Y-%m-%d %H:%M:%S') - Instance $ORDINAL: Processing queries" | tee -a /data/db/activity.log
            
            # Simulate different behavior for primary vs replicas
            if [ "$ORDINAL" = "0" ]; then
              echo "  PRIMARY: Accepting writes" | tee -a /data/db/activity.log
            else
              echo "  REPLICA: Syncing from primary" | tee -a /data/db/activity.log
            fi
            
            sleep 30
          done
        ports:
        - containerPort: 5432
          name: postgres
        volumeMounts:
        - name: data-volume
          mountPath: /data
        resources:
          requests:
            memory: "128Mi"
            cpu: "100m"
          limits:
            memory: "256Mi"
            cpu: "200m"
        livenessProbe:
          exec:
            command:
            - sh
            - -c
            - "[ -f /data/db/config.txt ]"
          initialDelaySeconds: 10
          periodSeconds: 10
        readinessProbe:
          exec:
            command:
            - sh
            - -c
            - "[ -f /data/db/activity.log ]"
          initialDelaySeconds: 15
          periodSeconds: 5
  volumeClaimTemplates:
  - metadata:
      name: data-volume
      labels:
        app: distributed-db
    spec:
      accessModes: ["ReadWriteOnce"]
      resources:
        requests:
          storage: 1Gi
```

Deploy and manage the StatefulSet:

```bash
# Deploy the StatefulSet and its headless service
kubectl apply -f distributed-db.yaml

# Watch pods being created in order (0, then 1, then 2)
kubectl get pods -l app=distributed-db -w

# Verify ordered creation
kubectl get events --sort-by='.lastTimestamp' | grep distributed-db

# Check StatefulSet status
kubectl get statefulset distributed-db

# Verify each pod has its own persistent volume
kubectl get pvc

# Check pod identities
for i in 0 1 2; do
  kubectl exec distributed-db-$i -- cat /data/db/config.txt
done

# Test DNS resolution for pods
kubectl run -it --rm debug --image=busybox:1.36 --restart=Never -- nslookup distributed-db-0.database-service

# Verify data persistence by deleting and recreating a pod
kubectl exec distributed-db-1 -- sh -c "echo 'Important data' > /data/db/important.txt"
kubectl delete pod distributed-db-1
kubectl get pods -l app=distributed-db -w  # Wait for recreation
kubectl exec distributed-db-1 -- cat /data/db/important.txt  # Data persists
```

### StatefulSet Scaling Operations

StatefulSets handle scaling differently than Deployments, maintaining order and identity:

```bash
# Scale up (adds distributed-db-3)
kubectl scale statefulset distributed-db --replicas=4

# Watch the new pod being created
kubectl get pods -l app=distributed-db -w

# Scale down (removes distributed-db-3 first)
kubectl scale statefulset distributed-db --replicas=3

# Observe reverse-order deletion
kubectl get pods -l app=distributed-db -w
```

### StatefulSet Update Strategies

StatefulSets support controlled rolling updates:

```yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: versioned-app
spec:
  serviceName: versioned-service
  replicas: 3
  updateStrategy:
    type: RollingUpdate
    rollingUpdate:
      partition: 2  # Only update pods with ordinal >= 2
  selector:
    matchLabels:
      app: versioned
  template:
    metadata:
      labels:
        app: versioned
    spec:
      containers:
      - name: app
        image: busybox:1.35  # Initial version
        command:
        - sh
        - -c
        - |
          echo "App version: 1.35"
          echo "Pod: $HOSTNAME"
          tail -f /dev/null
```

Perform a partitioned update:

```bash
# Deploy initial version
kubectl apply -f versioned-app.yaml

# Update image but only for pod with ordinal >= 2
kubectl set image statefulset/versioned-app app=busybox:1.36

# Only versioned-app-2 gets updated
kubectl get pods -l app=versioned -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.containers[0].image}{"\n"}{end}'

# Update partition to roll out to more pods
kubectl patch statefulset versioned-app -p '{"spec":{"updateStrategy":{"rollingUpdate":{"partition":0}}}}'
```

## DaemonSets for Node-Level Services

DaemonSets ensure that a copy of a specific pod runs on all (or selected) nodes in the cluster. As nodes are added to the cluster, pods are automatically added to them. As nodes are removed, those pods are garbage collected.

### DaemonSet Use Cases

DaemonSets are ideal for cluster-wide services that need to run on every node:

System Monitoring: Deploy monitoring agents that collect metrics from each node's resources and running containers.

Log Collection: Run log aggregation agents that gather logs from all containers on each node and forward them to a central logging system.

Network Services: Deploy network plugins, proxy services, or load balancers that must be present on every node.

Security Agents: Run security scanning, intrusion detection, or compliance checking software on every node.

Storage Providers: Deploy storage daemons that provide or manage node-local storage for other applications.

### DaemonSet Implementation

Here's a comprehensive DaemonSet example that demonstrates monitoring capabilities:

```yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: node-monitor
  labels:
    app: monitoring
    component: node-agent
spec:
  selector:
    matchLabels:
      app: node-monitor
  updateStrategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 1  # Update one node at a time
  template:
    metadata:
      labels:
        app: node-monitor
    spec:
      hostNetwork: true  # Use host network for system monitoring
      hostPID: true      # Access host process namespace
      containers:
      - name: monitor
        image: busybox:1.36
        command:
        - /bin/sh
        - -c
        - |
          echo "Node monitor started on $(hostname)"
          NODE_NAME=${NODE_NAME:-$(hostname)}
          
          # Create monitoring directory
          mkdir -p /var/log/monitoring
          
          while true; do
            echo "==================== $(date '+%Y-%m-%d %H:%M:%S') ====================" | tee -a /var/log/monitoring/node-stats.log
            
            # Collect node information
            echo "Node: $NODE_NAME" | tee -a /var/log/monitoring/node-stats.log
            
            # System load
            echo "Load Average: $(cat /proc/loadavg | cut -d' ' -f1-3)" | tee -a /var/log/monitoring/node-stats.log
            
            # Memory usage
            MEMINFO=$(cat /proc/meminfo)
            TOTAL_MEM=$(echo "$MEMINFO" | grep MemTotal | awk '{print $2}')
            FREE_MEM=$(echo "$MEMINFO" | grep MemAvailable | awk '{print $2}')
            USED_MEM=$((TOTAL_MEM - FREE_MEM))
            MEM_PERCENT=$((USED_MEM * 100 / TOTAL_MEM))
            echo "Memory Usage: ${MEM_PERCENT}% (${USED_MEM}KB used of ${TOTAL_MEM}KB)" | tee -a /var/log/monitoring/node-stats.log
            
            # Disk usage for root filesystem
            DF_OUTPUT=$(df -h / | tail -1)
            DISK_USAGE=$(echo "$DF_OUTPUT" | awk '{print $5}')
            echo "Root Disk Usage: $DISK_USAGE" | tee -a /var/log/monitoring/node-stats.log
            
            # Count running containers
            CONTAINER_COUNT=$(ls -1 /proc/*/cgroup 2>/dev/null | xargs grep -l docker 2>/dev/null | wc -l)
            echo "Running Containers: $CONTAINER_COUNT" | tee -a /var/log/monitoring/node-stats.log
            
            echo "=======================================================" | tee -a /var/log/monitoring/node-stats.log
            
            sleep 60  # Collect stats every minute
          done
        env:
        - name: NODE_NAME
          valueFrom:
            fieldRef:
              fieldPath: spec.nodeName
        volumeMounts:
        - name: proc
          mountPath: /proc
          readOnly: true
        - name: var-log
          mountPath: /var/log
        - name: root-fs
          mountPath: /host/root
          readOnly: true
        resources:
          requests:
            memory: "64Mi"
            cpu: "50m"
          limits:
            memory: "128Mi"
            cpu: "100m"
        securityContext:
          privileged: true  # Required for system monitoring
      volumes:
      - name: proc
        hostPath:
          path: /proc
      - name: var-log
        hostPath:
          path: /var/log
      - name: root-fs
        hostPath:
          path: /
      tolerations:
      # Allow scheduling on control plane nodes
      - key: node-role.kubernetes.io/control-plane
        operator: Exists
        effect: NoSchedule
      # Allow scheduling on nodes with NoExecute taints
      - operator: Exists
        effect: NoExecute
      # Ensure DaemonSet pods are not evicted
      priorityClassName: system-node-critical
```

Deploy and manage the DaemonSet:

```bash
# Deploy the DaemonSet
kubectl apply -f node-monitor.yaml

# Verify pods are running on all nodes
kubectl get pods -l app=node-monitor -o wide

# Check DaemonSet status
kubectl get daemonset node-monitor

# View logs from all monitoring pods
kubectl logs -l app=node-monitor --tail=10 --prefix=true

# Check monitoring data from a specific node
NODE_POD=$(kubectl get pods -l app=node-monitor -o jsonpath='{.items[0].metadata.name}')
kubectl exec $NODE_POD -- tail -20 /var/log/monitoring/node-stats.log

# Update DaemonSet image
kubectl set image daemonset/node-monitor monitor=busybox:1.36

# Monitor rolling update progress
kubectl rollout status daemonset/node-monitor
```

### Node Selection with DaemonSets

DaemonSets can be configured to run only on specific nodes using node selectors or node affinity:

```yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: gpu-monitor
  labels:
    app: gpu-monitoring
spec:
  selector:
    matchLabels:
      app: gpu-monitor
  template:
    metadata:
      labels:
        app: gpu-monitor
    spec:
      nodeSelector:
        hardware-type: gpu  # Only run on GPU nodes
      containers:
      - name: gpu-monitor
        image: busybox:1.36
        command:
        - /bin/sh
        - -c
        - |
          echo "GPU monitor started on $(hostname)"
          while true; do
            echo "$(date): Monitoring GPU on node $(hostname)"
            # Simulate GPU monitoring
            echo "GPU Temperature: $((RANDOM % 30 + 50))°C"
            echo "GPU Utilization: $((RANDOM % 100))%"
            echo "GPU Memory: $((RANDOM % 16))GB / 16GB"
            sleep 30
          done
        resources:
          requests:
            memory: "32Mi"
            cpu: "50m"
```

Label nodes and deploy selective DaemonSet:

```bash
# Label specific nodes for GPU monitoring
kubectl label nodes <node-name> hardware-type=gpu

# Deploy GPU monitor DaemonSet
kubectl apply -f gpu-monitor.yaml

# Verify pods only run on labeled nodes
kubectl get pods -l app=gpu-monitor -o wide

# Remove label to stop DaemonSet pod on that node
kubectl label nodes <node-name> hardware-type-
```
