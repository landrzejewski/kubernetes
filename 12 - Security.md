## Understanding Cloud-Native Security Architecture

### The Evolution from Traditional to Cloud-Native Security

Traditional infrastructure security relied heavily on perimeter defense, where a strong boundary protected internal resources. This model assumed that threats came primarily from outside the network, and once inside the perimeter, entities could be trusted. However, modern cloud-native environments fundamentally challenge these assumptions.

In Kubernetes environments, workloads are ephemeral, constantly scaling and moving across nodes. Network boundaries become fluid, with services communicating across namespaces, clusters, and even cloud providers. This dynamic nature requires a fundamentally different approach to security.

### Zero-Trust Security Model in Kubernetes

The zero-trust model operates on the principle of "never trust, always verify." In Kubernetes, this means every component, whether internal or external, must authenticate and be authorized for every action. This approach significantly reduces the blast radius of potential security breaches.

Key principles of zero-trust in Kubernetes include:

- Every API request requires authentication, regardless of origin
- Authorization decisions are made for each action, not just at connection time
- Network policies enforce microsegmentation between workloads
- Secrets and sensitive data are encrypted both in transit and at rest
- Regular rotation of credentials and certificates
- Continuous monitoring and auditing of all activities

## ServiceAccounts: Identity for Workloads

### ServiceAccount Architecture and Purpose

ServiceAccounts provide identity for processes running in pods, enabling them to interact with the Kubernetes API and other services. Unlike user accounts, which represent human operators, ServiceAccounts are designed for programmatic access.

Every ServiceAccount consists of several components:

- A Kubernetes API object that defines the account
- An automatically generated token for API authentication
- Optionally, image pull secrets for accessing private registries
- RBAC bindings that grant permissions

### Token Management and Security

Modern Kubernetes uses projected service account tokens, which offer significant security improvements over legacy tokens:

Time-Limited Tokens: Tokens automatically expire and are refreshed by the kubelet. This limits the impact of token compromise.

Audience-Scoped Tokens: Tokens can be restricted to specific audiences, preventing them from being used with unintended services.

Bound Object References: Tokens are bound to specific pods and secrets, making them invalid if those objects are deleted.

## RBAC: Fine-Grained Access Control

Roles and ClusterRoles define sets of permissions. They specify what actions (verbs) can be performed on which resources. Roles are namespace-scoped, while ClusterRoles are cluster-wide.

Subjects are the entities that permissions are granted to. These can be Users (for humans), ServiceAccounts (for pods), or Groups (collections of users or ServiceAccounts).

RoleBindings and ClusterRoleBindings connect subjects to roles. A RoleBinding grants permissions within a namespace, while a ClusterRoleBinding grants cluster-wide permissions.

### Permission Aggregation

RBAC permissions are additive - there are no "deny" rules. If a subject has multiple bindings, they get the union of all permissions. This means:

- Adding a new binding can only increase permissions, never decrease them
- To remove permissions, you must modify or delete existing bindings
- There's no way to create exceptions or override higher-level permissions

### Common RBAC Patterns

Read-Only Access: Granting get, list, and watch verbs allows subjects to view resources without modifying them.

Namespace Admin: Granting all verbs on all resources within a namespace gives full control over that namespace.

Resource-Specific Access: Granting specific verbs on specific resource types allows fine-grained control.

Cross-Namespace Access: Using ClusterRoles with RoleBindings allows reusing permission sets across namespaces.

### RBAC Security Considerations

Several RBAC permissions can lead to privilege escalation:

Creating Workloads: The ability to create pods, deployments, or other workloads implicitly grants access to any secrets or configMaps in the namespace.

Modifying RBAC: The ability to create or modify roles and bindings allows subjects to grant themselves additional permissions.

Impersonation: The impersonate verb allows subjects to perform actions as other users or ServiceAccounts
## Practical Workshop Exercises

### Workshop: ServiceAccount Management

This section demonstrates ServiceAccount creation and token management with comprehensive examples.

```bash
# First, examine the default ServiceAccount that exists in every namespace
kubectl get sa default -o yaml
kubectl describe sa default

# Check current cluster authentication info
kubectl config view --minify
kubectl auth whoami

# Create a new namespace for security demonstrations
kubectl create namespace security-workshop

# Create a custom ServiceAccount with annotations
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: app-service-account
  namespace: security-workshop
  annotations:
    description: "ServiceAccount for application workloads"
    owner: "platform-team"
    purpose: "workshop-demo"
EOF

# Create a long-lived token for the ServiceAccount
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: app-service-account-token
  namespace: security-workshop
  annotations:
    kubernetes.io/service-account.name: app-service-account
type: kubernetes.io/service-account-token
EOF

# Retrieve and decode the token
TOKEN=$(kubectl get secret app-service-account-token -n security-workshop -o jsonpath='{.data.token}' | base64 -d)
echo "Token length: ${#TOKEN}"

# Test API access with the token
APISERVER=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
echo "API Server: $APISERVER"

# Test unauthenticated access (should fail)
curl -k $APISERVER/api/v1/namespaces/security-workshop/pods

# Test with ServiceAccount token (should get 403 Forbidden - authenticated but not authorized)
curl -k -H "Authorization: Bearer $TOKEN" $APISERVER/api/v1/namespaces/security-workshop/pods

# Create multiple ServiceAccounts for different purposes
kubectl create sa monitoring-sa -n security-workshop
kubectl create sa deployment-sa -n security-workshop
kubectl create sa readonly-sa -n security-workshop

# List all ServiceAccounts
kubectl get sa -n security-workshop
```

### Workshop: RBAC Configuration

This section demonstrates comprehensive RBAC setup with progressive permission grants.

```bash
# Create a Role with specific permissions
cat <<EOF | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  namespace: security-workshop
  name: pod-reader
rules:
- apiGroups: [""]
  resources: ["pods"]
  verbs: ["get", "watch", "list"]
- apiGroups: [""]
  resources: ["pods/log"]
  verbs: ["get"]
EOF

# Create a Role for ConfigMap management
cat <<EOF | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  namespace: security-workshop
  name: configmap-manager
rules:
- apiGroups: [""]
  resources: ["configmaps"]
  verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
EOF

# Create RoleBindings
cat <<EOF | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: read-pods
  namespace: security-workshop
subjects:
- kind: ServiceAccount
  name: readonly-sa
  namespace: security-workshop
roleRef:
  kind: Role
  name: pod-reader
  apiGroup: rbac.authorization.k8s.io
EOF

# Bind configmap-manager role
cat <<EOF | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: manage-configmaps
  namespace: security-workshop
subjects:
- kind: ServiceAccount
  name: app-service-account
  namespace: security-workshop
roleRef:
  kind: Role
  name: configmap-manager
  apiGroup: rbac.authorization.k8s.io
EOF

# Test permissions using impersonation
echo "Testing readonly-sa permissions:"
kubectl auth can-i get pods --as=system:serviceaccount:security-workshop:readonly-sa -n security-workshop
kubectl auth can-i create pods --as=system:serviceaccount:security-workshop:readonly-sa -n security-workshop
kubectl auth can-i get configmaps --as=system:serviceaccount:security-workshop:readonly-sa -n security-workshop

echo "Testing app-service-account permissions:"
kubectl auth can-i get configmaps --as=system:serviceaccount:security-workshop:app-service-account -n security-workshop
kubectl auth can-i create configmaps --as=system:serviceaccount:security-workshop:app-service-account -n security-workshop

# Create a ClusterRole for node information
cat <<EOF | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: node-viewer
rules:
- apiGroups: [""]
  resources: ["nodes"]
  verbs: ["get", "list"]
- apiGroups: ["metrics.k8s.io"]
  resources: ["nodes"]
  verbs: ["get", "list"]
EOF

# Create ClusterRoleBinding
cat <<EOF | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: view-nodes
subjects:
- kind: ServiceAccount
  name: monitoring-sa
  namespace: security-workshop
roleRef:
  kind: ClusterRole
  name: node-viewer
  apiGroup: rbac.authorization.k8s.io
EOF

# Verify cluster-level permissions
kubectl auth can-i get nodes --as=system:serviceaccount:security-workshop:monitoring-sa

# Create an aggregated ClusterRole
cat <<EOF | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: monitoring-endpoints
  labels:
    rbac.authorization.k8s.io/aggregate-to-monitoring: "true"
rules:
- apiGroups: [""]
  resources: ["services/endpoints"]
  verbs: ["get", "list"]
EOF

# Create the parent aggregated role
cat <<EOF | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: monitoring-aggregated
aggregationRule:
  clusterRoleSelectors:
  - matchLabels:
      rbac.authorization.k8s.io/aggregate-to-monitoring: "true"
rules: []
EOF

# Deploy a pod with custom ServiceAccount
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: rbac-test-pod
  namespace: security-workshop
spec:
  serviceAccountName: app-service-account
  containers:
  - name: kubectl
    image: bitnami/kubectl:latest
    command: ["sleep", "3600"]
EOF

# Wait for pod to be ready
kubectl wait --for=condition=ready pod/rbac-test-pod -n security-workshop --timeout=60s

# Test in-pod permissions
kubectl exec -it rbac-test-pod -n security-workshop -- kubectl get configmaps
kubectl exec -it rbac-test-pod -n security-workshop -- kubectl get pods
```

## Creating Users and Managing Contexts

### Method 1: Certificate-Based Users

#### Step 1: Create Keys and CSRs

```bash
mkdir -p ~/k8s-users && cd ~/k8s-users

# Jane (developer)
openssl genrsa -out jane.key 2048
openssl req -new -key jane.key -out jane.csr -subj "/CN=jane/O=developers"

# Bob (operations)
openssl genrsa -out bob.key 2048
openssl req -new -key bob.key -out bob.csr -subj "/CN=bob/O=operations"

# Alice (multi-namespace admin)
openssl genrsa -out alice.key 2048
openssl req -new -key alice.key -out alice.csr -subj "/CN=alice/O=admins"
```

#### Step 2: Create Kubernetes CSRs

```bash
CSR=$(base64 -w0 jane.csr)
kubectl apply -f - <<EOF
apiVersion: certificates.k8s.io/v1
kind: CertificateSigningRequest
metadata:
  name: jane
spec:
  request: $CSR
  signerName: kubernetes.io/kube-apiserver-client
  expirationSeconds: 86400
  usages:
  - client auth
EOF

CSR=$(base64 -w0 bob.csr)
kubectl apply -f - <<EOF
apiVersion: certificates.k8s.io/v1
kind: CertificateSigningRequest
metadata:
  name: bob
spec:
  request: $CSR
  signerName: kubernetes.io/kube-apiserver-client
  expirationSeconds: 86400
  usages:
  - client auth
EOF

CSR=$(base64 -w0 alice.csr)
kubectl apply -f - <<EOF
apiVersion: certificates.k8s.io/v1
kind: CertificateSigningRequest
metadata:
  name: alice
spec:
  request: $CSR
  signerName: kubernetes.io/kube-apiserver-client
  expirationSeconds: 86400
  usages:
  - client auth
EOF
```

#### Step 3: Approve CSRs

```bash
kubectl get csr
kubectl certificate approve jane bob alice
kubectl get csr
```

#### Step 4: Extract Certificates

```bash
kubectl get csr jane -o jsonpath='{.status.certificate}' | base64 -d > jane.crt
kubectl get csr bob -o jsonpath='{.status.certificate}' | base64 -d > bob.crt
kubectl get csr alice -o jsonpath='{.status.certificate}' | base64 -d > alice.crt
```

#### Step 5: Create Contexts

```bash
CLUSTER_NAME=$(kubectl config view --minify -o jsonpath='{.clusters[0].name}')
CLUSTER_SERVER=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')

# Set credentials
kubectl config set-credentials jane --client-certificate=jane.crt --client-key=jane.key
kubectl config set-credentials bob --client-certificate=bob.crt --client-key=bob.key
kubectl config set-credentials alice --client-certificate=alice.crt --client-key=alice.key

# Set contexts
kubectl config set-context jane-context --cluster=$CLUSTER_NAME --user=jane
kubectl config set-context bob-context --cluster=$CLUSTER_NAME --user=bob
kubectl config set-context alice-context --cluster=$CLUSTER_NAME --user=alice

# Verify
kubectl config get-contexts
```

#### Step 6: Test Access

```bash
kubectl config use-context jane-context
kubectl get pods  # should fail

# Return to admin
ADMIN_CONTEXT=$(kubectl config view --minify -o jsonpath='{.current-context}')
kubectl config use-context "$ADMIN_CONTEXT"

# Give jane access to pods

cat <<EOF | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  namespace: training
  name: pod-reader
rules:
- apiGroups: [""]
  resources: ["pods"]
  verbs: ["get", "list", "watch"]
- apiGroups: [""]
  resources: ["pods/log"]
  verbs: ["get", "list"]
EOF 

cat <<EOF | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: jane-pod-reader
  namespace: training
subjects:
- kind: User
  name: jane
  apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: Role
  name: pod-reader
  apiGroup: rbac.authorization.k8s.io
EOF

kubectl get role -n training
kubectl get rolebinding -n training
kubectl describe rolebinding jane-pod-reader -n training

kubectl get pods -n training

kubectl config use-context jane-context

kubectl get pods -n training
kubectl get pods -n training -o wide
kubectl logs deployment/nginx-test -n training

kubectl get pods -n default

kubectl config use-context "$ADMIN_CONTEXT"

```

### Method 2: Service Accounts (for automation)

```bash
kubectl create serviceaccount automation-user -n rbac-demo
kubectl create token automation-user -n rbac-demo --duration=8760h

kubectl config set-credentials automation-user --token=$(kubectl create token automation-user -n rbac-demo)
kubectl config set-context automation-context --cluster=$CLUSTER_NAME --user=automation-user --namespace=rbac-demo
```
