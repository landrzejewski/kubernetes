# API Extensions and Custom Resources

## Workshop: Understanding Kubernetes API Architecture

The Kubernetes API serves as the primary interface for all cluster interactions, providing RESTful endpoints that enable users and applications to perform operations on cluster resources. The API uses a resource-based model where different components are represented as distinct resource types.

### API Resource Discovery

**Explanation**: These commands help you explore what resources are available in your Kubernetes cluster. Understanding the API structure is crucial before extending it with custom resources.

```bash
# List all available API resources
kubectl api-resources

# Filter by API group
kubectl api-resources --api-group=apps

# Show only namespaced resources
kubectl api-resources --namespaced=true

# Check available API versions
kubectl api-versions

# Get detailed information about a specific resource
kubectl explain deployment
kubectl explain deployment.spec
kubectl explain deployment.spec.template.spec
```

### Understanding API Groups and Versions

**Explanation**: Kubernetes organizes its API into groups for better modularity and independent versioning. The core group (empty string) contains fundamental resources like Pods and Services, while other groups like `apps` contain higher-level resources.

```bash
# Core API group (empty string) - v1
kubectl api-resources --api-group=""

# Apps API group - apps/v1
kubectl api-resources --api-group=apps

# Networking API group - networking.k8s.io/v1
kubectl api-resources --api-group=networking.k8s.io

# Check what versions are available for a group
kubectl api-versions | grep apps
kubectl api-versions | grep networking
```

### API Documentation and Schema

**Explanation**: The OpenAPI schema defines the structure and validation rules for all Kubernetes resources. This is essential for understanding how resources are structured and what fields are available.

```bash
# View the OpenAPI schema for deployments
kubectl get --raw /openapi/v2 | jq '.definitions["io.k8s.api.apps.v1.Deployment"]'

# Get API resource details
kubectl api-resources -o wide

# Understand resource structure
kubectl explain --recursive deployment | head -50
```

## Workshop: Direct API Access with kubectl proxy

**Explanation**: `kubectl proxy` creates a local HTTP proxy to the Kubernetes API server, handling authentication automatically. This allows you to interact with the API using simple HTTP tools like curl, which is useful for understanding the REST API structure and for automation.

```bash
# Start kubectl proxy (runs in background)
kubectl proxy --port=8001 &

# Verify proxy is running
curl http://localhost:8001/api/

# List all API versions
curl http://localhost:8001/api/v1

# Get all pods in default namespace
curl http://localhost:8001/api/v1/namespaces/default/pods

# Get specific pod
curl http://localhost:8001/api/v1/namespaces/default/pods/my-pod

# Get deployments (apps/v1 API group)
curl http://localhost:8001/apis/apps/v1/namespaces/default/deployments

# Access cluster-wide resources
curl http://localhost:8001/api/v1/nodes
```

### API Operations through HTTP

**Explanation**: This demonstrates how kubectl commands translate to HTTP REST operations. Understanding this mapping is crucial for building custom controllers and operators.

```bash
# Create a pod via API
cat <<EOF > pod.json
{
  "apiVersion": "v1",
  "kind": "Pod",
  "metadata": {
    "name": "api-pod",
    "namespace": "default"
  },
  "spec": {
    "containers": [
      {
        "name": "nginx",
        "image": "nginx:1.20",
        "ports": [{"containerPort": 80}]
      }
    ]
  }
}
EOF

# POST to create the pod
curl -X POST \
  -H "Content-Type: application/json" \
  -d @pod.json \
  http://localhost:8001/api/v1/namespaces/default/pods

# GET the created pod
curl http://localhost:8001/api/v1/namespaces/default/pods/api-pod

# DELETE the pod
curl -X DELETE http://localhost:8001/api/v1/namespaces/default/pods/api-pod

# Stop proxy when done
pkill kubectl
```

### Advanced Proxy Configuration

**Explanation**: These options allow you to customize how the proxy behaves, useful for different networking scenarios and security requirements.

```bash
# Bind to specific interface for external access
kubectl proxy --address='0.0.0.0' --port=8001 --accept-hosts='.*'

# Proxy with custom API prefix
kubectl proxy --api-prefix='/k8s-api' --port=8001

# Enable/disable various API paths
kubectl proxy --disable-filter=false --port=8001
```

## Workshop: Creating Custom Resource Definitions

Custom Resource Definitions (CRDs) extend the Kubernetes API with new resource types. Let's create a simple CRD for managing web applications:

### Basic CRD Definition

**Explanation**: This CRD defines a new resource type called `WebApp`. The schema validation ensures that only valid data can be stored. The `subresources` section enables status tracking and scaling operations, similar to built-in resources like Deployments.

```yaml
# Create webapp-crd.yaml
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: webapps.example.com  # Must be plural.group format
spec:
  group: example.com
  versions:
  - name: v1
    served: true      # This version can be used
    storage: true     # This version is used for storage
    schema:
      openAPIV3Schema:
        type: object
        properties:
          spec:
            type: object
            properties:
              image:
                type: string
                description: "Container image for the web application"
              replicas:
                type: integer
                minimum: 1
                maximum: 10
                default: 1
                description: "Number of replicas"
              port:
                type: integer
                minimum: 1
                maximum: 65535
                default: 80
                description: "Container port"
              env:
                type: array
                items:
                  type: object
                  properties:
                    name:
                      type: string
                    value:
                      type: string
                  required: ["name", "value"]
            required: ["image"]
          status:
            type: object
            properties:
              ready:
                type: boolean
              replicas:
                type: integer
              readyReplicas:
                type: integer
    subresources:
      status: {}  # Enables status subresource
      scale:      # Enables kubectl scale command
        specReplicasPath: .spec.replicas
        statusReplicasPath: .status.replicas
        labelSelectorPath: .status.labelSelector
  scope: Namespaced  # Resources are namespace-scoped
  names:
    plural: webapps
    singular: webapp
    kind: WebApp
    shortNames:
    - wa
```

Deploy and test the CRD:

```bash
# Create the CRD
kubectl apply -f webapp-crd.yaml

# Verify CRD is installed
kubectl get crd webapps.example.com
kubectl api-resources | grep webapps

# Check the CRD details
kubectl describe crd webapps.example.com

# Test the new resource type
kubectl explain webapp
kubectl explain webapp.spec
```

### Creating Custom Resource Instances

**Explanation**: Once the CRD is installed, you can create instances of your custom resource just like any other Kubernetes resource. The API server will validate them against the schema defined in the CRD.

```yaml
# Create webapp-instance.yaml
apiVersion: example.com/v1
kind: WebApp
metadata:
  name: my-webapp
  namespace: default
spec:
  image: nginx:1.20
  replicas: 3
  port: 80
  env:
  - name: ENV_TYPE
    value: "production"
  - name: LOG_LEVEL
    value: "info"
---
apiVersion: example.com/v1
kind: WebApp
metadata:
  name: api-webapp
  namespace: default
spec:
  image: httpd:2.4
  replicas: 2
  port: 80
  env:
  - name: ENV_TYPE
    value: "staging"
```

Work with custom resource instances:

```bash
# Create custom resource instances
kubectl apply -f webapp-instance.yaml

# List custom resources
kubectl get webapps
kubectl get wa  # Using short name

# Describe custom resource
kubectl describe webapp my-webapp

# Get custom resource in YAML format
kubectl get webapp my-webapp -o yaml

# Edit custom resource
kubectl edit webapp my-webapp

# Delete custom resource
kubectl delete webapp api-webapp
```

### Advanced CRD Features

#### Validation and Defaults

**Explanation**: This advanced CRD demonstrates several important features:
- **Enum validation**: Restricts values to a predefined list
- **Pattern validation**: Uses regex to validate formats
- **Default values**: Automatically applied if not specified
- **Additional printer columns**: Customizes `kubectl get` output
- **Required fields**: Enforces mandatory fields

```yaml
# Create advanced-crd.yaml
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: databases.example.com
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
            properties:
              engine:
                type: string
                enum: ["mysql", "postgres", "mongodb"]  # Only these values allowed
                description: "Database engine type"
              version:
                type: string
                pattern: '^[0-9]+\.[0-9]+$'  # Must match X.Y format
                description: "Database version (major.minor)"
              storage:
                type: string
                pattern: '^[0-9]+Gi$'  # Must end with Gi
                default: "10Gi"
                description: "Storage size in GiB"
              backupEnabled:
                type: boolean
                default: true
                description: "Enable automated backups"
              config:
                type: object
                additionalProperties:  # Allows any key-value pairs
                  type: string
                description: "Database configuration parameters"
            required: ["engine", "version"]
          status:
            type: object
            properties:
              phase:
                type: string
                enum: ["Pending", "Creating", "Ready", "Failed"]
              message:
                type: string
              lastUpdated:
                type: string
                format: date-time
    additionalPrinterColumns:  # Customizes kubectl get output
    - name: Engine
      type: string
      jsonPath: .spec.engine
    - name: Version
      type: string
      jsonPath: .spec.version
    - name: Storage
      type: string
      jsonPath: .spec.storage
    - name: Status
      type: string
      jsonPath: .status.phase
    - name: Age
      type: date
      jsonPath: .metadata.creationTimestamp
    subresources:
      status: {}
  scope: Namespaced
  names:
    plural: databases
    singular: database
    kind: Database
    shortNames: ["db"]
```

Test advanced CRD features:

```bash
# Apply advanced CRD
kubectl apply -f advanced-crd.yaml

# Create database instances
cat <<EOF | kubectl apply -f -
apiVersion: example.com/v1
kind: Database
metadata:
  name: prod-mysql
spec:
  engine: mysql
  version: "8.0"
  storage: "50Gi"
  config:
    innodb_buffer_pool_size: "1G"
    max_connections: "200"
---
apiVersion: example.com/v1
kind: Database
metadata:
  name: dev-postgres
spec:
  engine: postgres
  version: "14.0"
  backupEnabled: false
  config:
    shared_buffers: "256MB"
    max_connections: "100"
EOF

# View with custom columns
kubectl get databases

# Test validation by creating invalid resource (this will fail)
cat <<EOF | kubectl apply -f -
apiVersion: example.com/v1
kind: Database
metadata:
  name: invalid-db
spec:
  engine: oracle  # Invalid - not in enum
  version: "19c"  # Invalid - doesn't match pattern
EOF
```

## Workshop: Building a Simple Custom Controller

**Explanation**: A controller implements the control loop pattern - it watches for changes to resources and takes action to ensure the actual state matches the desired state. This bash script demonstrates the basic controller logic that production controllers (usually written in Go) implement.

### Basic Controller Logic

```bash
# Create simple-controller.sh
#!/bin/bash

NAMESPACE=${NAMESPACE:-default}
CRD_GROUP="example.com"
CRD_VERSION="v1"
CRD_PLURAL="webapps"

echo "Starting WebApp Controller for namespace: $NAMESPACE"

# Function to create deployment from webapp spec
create_deployment() {
    local webapp_name=$1
    local webapp_spec=$2
    
    # Extract values from webapp spec
    local image=$(echo "$webapp_spec" | jq -r '.spec.image')
    local replicas=$(echo "$webapp_spec" | jq -r '.spec.replicas // 1')
    local port=$(echo "$webapp_spec" | jq -r '.spec.port // 80')
    
    echo "Creating deployment for WebApp: $webapp_name"
    
    # Create deployment YAML
    cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: $webapp_name-deployment
  namespace: $NAMESPACE
  labels:
    webapp: $webapp_name
    managed-by: webapp-controller
spec:
  replicas: $replicas
  selector:
    matchLabels:
      webapp: $webapp_name
  template:
    metadata:
      labels:
        webapp: $webapp_name
    spec:
      containers:
      - name: app
        image: $image
        ports:
        - containerPort: $port
EOF

    # Create service
    cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: $webapp_name-service
  namespace: $NAMESPACE
  labels:
    webapp: $webapp_name
    managed-by: webapp-controller
spec:
  selector:
    webapp: $webapp_name
  ports:
  - port: 80
    targetPort: $port
EOF
}

# Function to update webapp status
update_status() {
    local webapp_name=$1
    local ready_replicas=$2
    local total_replicas=$3
    
    local ready_status="false"
    if [ "$ready_replicas" = "$total_replicas" ] && [ "$ready_replicas" != "0" ]; then
        ready_status="true"
    fi
    
    # Update status subresource
    kubectl patch webapp "$webapp_name" -n "$NAMESPACE" --type='merge' --subresource=status -p "{
        \"status\": {
            \"ready\": $ready_status,
            \"replicas\": $total_replicas,
            \"readyReplicas\": $ready_replicas
        }
    }"
}

# Main controller loop - reconciliation logic
while true; do
    echo "Controller loop iteration at $(date)"
    
    # Get all webapps in namespace
    webapps=$(kubectl get webapp -n "$NAMESPACE" -o json 2>/dev/null || echo '{"items":[]}')
    
    # Process each webapp
    echo "$webapps" | jq -c '.items[]' | while read -r webapp; do
        webapp_name=$(echo "$webapp" | jq -r '.metadata.name')
        
        echo "Processing WebApp: $webapp_name"
        
        # Check if deployment exists
        if ! kubectl get deployment "$webapp_name-deployment" -n "$NAMESPACE" >/dev/null 2>&1; then
            echo "Deployment doesn't exist, creating..."
            create_deployment "$webapp_name" "$webapp"
        else
            echo "Deployment exists, checking for updates..."
            
            # Get current deployment spec
            current_image=$(kubectl get deployment "$webapp_name-deployment" -n "$NAMESPACE" -o jsonpath='{.spec.template.spec.containers[0].image}')
            current_replicas=$(kubectl get deployment "$webapp_name-deployment" -n "$NAMESPACE" -o jsonpath='{.spec.replicas}')
            
            # Get desired spec from webapp
            desired_image=$(echo "$webapp" | jq -r '.spec.image')
            desired_replicas=$(echo "$webapp" | jq -r '.spec.replicas // 1')
            
            # Update if needed
            if [ "$current_image" != "$desired_image" ]; then
                echo "Updating image from $current_image to $desired_image"
                kubectl set image deployment/"$webapp_name-deployment" app="$desired_image" -n "$NAMESPACE"
            fi
            
            if [ "$current_replicas" != "$desired_replicas" ]; then
                echo "Scaling from $current_replicas to $desired_replicas replicas"
                kubectl scale deployment "$webapp_name-deployment" --replicas="$desired_replicas" -n "$NAMESPACE"
            fi
        fi
        
        # Update status
        ready_replicas=$(kubectl get deployment "$webapp_name-deployment" -n "$NAMESPACE" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
        total_replicas=$(kubectl get deployment "$webapp_name-deployment" -n "$NAMESPACE" -o jsonpath='{.status.replicas}' 2>/dev/null || echo "0")
        
        echo "Updating status: ready=$ready_replicas, total=$total_replicas"
        update_status "$webapp_name" "$ready_replicas" "$total_replicas"
    done
    
    # Clean up orphaned resources
    echo "Checking for orphaned resources..."
    kubectl get deployments -n "$NAMESPACE" -l managed-by=webapp-controller -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' | while read -r deployment; do
        if [ -n "$deployment" ]; then
            webapp_name=${deployment%-deployment}
            if ! kubectl get webapp "$webapp_name" -n "$NAMESPACE" >/dev/null 2>&1; then
                echo "Cleaning up orphaned deployment: $deployment"
                kubectl delete deployment "$deployment" -n "$NAMESPACE"
                kubectl delete service "$webapp_name-service" -n "$NAMESPACE" 2>/dev/null || true
            fi
        fi
    done
    
    sleep 30  # Wait before next reconciliation
done
```

### Running the Controller

**Explanation**: This demonstrates the controller in action - it creates deployments for WebApps, updates them when specs change, and cleans up resources when WebApps are deleted.

```bash
# Make the controller executable
chmod +x simple-controller.sh

# Run controller in background
./simple-controller.sh &
CONTROLLER_PID=$!

# Create a webapp and watch the controller work
kubectl apply -f - <<EOF
apiVersion: example.com/v1
kind: WebApp
metadata:
  name: test-webapp
spec:
  image: nginx:1.20
  replicas: 2
  port: 80
EOF

# Watch resources being created
kubectl get webapps
kubectl get deployments -l managed-by=webapp-controller
kubectl get services -l managed-by=webapp-controller
kubectl get pods -l webapp=test-webapp

# Test updates
kubectl patch webapp test-webapp --type='merge' -p '{"spec":{"replicas":3}}'

# Watch status updates
kubectl get webapp test-webapp -o yaml | grep -A 10 status:

# Test image updates
kubectl patch webapp test-webapp --type='merge' -p '{"spec":{"image":"nginx:1.21"}}'

# Clean up
kubectl delete webapp test-webapp
kill $CONTROLLER_PID
```
