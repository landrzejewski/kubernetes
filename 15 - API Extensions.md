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
# View the OpenAPI v2 schema for deployments (one big document)
kubectl get --raw /openapi/v2 | jq '.definitions["io.k8s.api.apps.v1.Deployment"].description'

# OpenAPI v3 is split per group/version (used by kubectl explain and server-side apply)
kubectl get --raw /openapi/v3 | jq -r '.paths | keys[]' | grep apps
kubectl get --raw /openapi/v3/apis/apps/v1 | jq '.components.schemas["io.k8s.api.apps.v1.Deployment"].properties | keys'

# Get API resource details
kubectl api-resources -o wide

# Understand resource structure
kubectl explain --recursive deployment | head -50
```

## Workshop: Direct API Access with kubectl proxy

**Explanation**: `kubectl proxy` creates a local HTTP proxy to the Kubernetes API server, handling authentication automatically. This allows you to interact with the API using simple HTTP tools like curl, which is useful for understanding the REST API structure and for automation.

```bash
# Start kubectl proxy (runs in background) and remember its PID
kubectl proxy --port=8001 &
PROXY_PID=$!

# Verify proxy is running
curl http://localhost:8001/api/

# List the resources of the core group v1
curl -s http://localhost:8001/api/v1 | jq -r '.resources[].name' | head

# Get all pods in default namespace
curl http://localhost:8001/api/v1/namespaces/default/pods

# Get a specific pod (replace <pod-name>)
curl http://localhost:8001/api/v1/namespaces/default/pods/<pod-name>

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
        "image": "nginx:1.31-alpine",
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
curl -s http://localhost:8001/api/v1/namespaces/default/pods/api-pod | jq -r '.metadata.name, .status.phase'

# PATCH = kubectl label/annotate/patch (merge patch adds a label)
curl -s -X PATCH -H "Content-Type: application/merge-patch+json" \
  -d '{"metadata":{"labels":{"via":"curl"}}}' \
  http://localhost:8001/api/v1/namespaces/default/pods/api-pod | jq -c .metadata.labels

# LIST with a label selector = kubectl get pods -l via=curl
curl -s "http://localhost:8001/api/v1/namespaces/default/pods?labelSelector=via%3Dcurl" | jq -r '.items[].metadata.name'

# DELETE the pod
curl -s -X DELETE http://localhost:8001/api/v1/namespaces/default/pods/api-pod | jq -r .metadata.deletionTimestamp

# WATCH = kubectl get -w: a stream of ADDED/MODIFIED/DELETED events (controllers are built on this)
curl -s -N "http://localhost:8001/api/v1/namespaces/default/pods?watch=true&timeoutSeconds=5" | jq -r '.type + " " + .object.metadata.name'

# Stop the proxy when done (only this one - not every kubectl process)
kill $PROXY_PID
```

| kubectl | HTTP |
|---------|------|
| `kubectl get pods` | `GET /api/v1/namespaces/{ns}/pods` |
| `kubectl get pod x` | `GET /api/v1/namespaces/{ns}/pods/x` |
| `kubectl create -f` | `POST /api/v1/namespaces/{ns}/pods` |
| `kubectl apply --server-side` | `PATCH ...` with `application/apply-patch+yaml` |
| `kubectl replace` | `PUT /api/v1/namespaces/{ns}/pods/x` |
| `kubectl delete pod x` | `DELETE /api/v1/namespaces/{ns}/pods/x` |
| `kubectl get pods -w` | `GET /api/v1/namespaces/{ns}/pods?watch=true` |
| `kubectl get deploy` | `GET /apis/apps/v1/namespaces/{ns}/deployments` (named groups live under `/apis`) |

### Advanced Proxy Configuration

**Explanation**: These options allow you to customize how the proxy behaves, useful for different networking scenarios and security requirements.

```bash
# Block selected paths (regular expressions) - here: all Secrets
kubectl proxy --port=8001 --reject-paths='^/api/v1/secrets,^/api/v1/namespaces/.*/secrets' &
PROXY_PID=$!; sleep 1
curl -s -o /dev/null -w "%{http_code}\n" http://localhost:8001/api/v1/namespaces/default/secrets      # 403
curl -s -o /dev/null -w "%{http_code}\n" http://localhost:8001/api/v1/namespaces/default/configmaps   # 200
kill $PROXY_PID

# Serve the API under a custom prefix
kubectl proxy --api-prefix=/k8s-api --port=8001 &
PROXY_PID=$!; sleep 1
curl -s http://localhost:8001/k8s-api/version | jq -r .gitVersion
kill $PROXY_PID

# Listen on all interfaces - DANGEROUS: everybody who can reach the port gets YOUR (cluster-admin) rights
# kubectl proxy --address=0.0.0.0 --port=8001 --accept-hosts='.*'
```

### Direct API Access with a Token

Without the proxy, a client authenticates itself - for example with a ServiceAccount token, exactly like a Pod does.
The `default` ServiceAccount has no RBAC rights, so the API server authenticates the request but forbids it:

```bash
APISERVER=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
TOKEN=$(kubectl create token default -n default --duration=10m)
kubectl config view --raw --minify -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' | base64 -d > ca.crt

curl -s --cacert ca.crt -H "Authorization: Bearer $TOKEN" $APISERVER/api/v1/namespaces/default/pods | jq -r .message
```

Expected:

```
pods is forbidden: User "system:serviceaccount:default:default" cannot list resource "pods" in API group "" in the namespace "default"
```

## Workshop: Extending the API with a Custom Resource Definition

A CustomResourceDefinition (CRD) adds a new resource type to the API server. Once it is installed, the new type
behaves like a built-in one: it has a REST endpoint, it is stored in etcd, it works with `kubectl get/apply/edit/delete`,
RBAC, watches, `kubectl explain` and admission control. A CRD alone only **stores data** - the behaviour comes from a
**controller** that watches the objects and makes the cluster match them. A CRD plus a controller with operational
knowledge is what is usually called an **operator**.

In this workshop we build a small but complete platform feature: a `Website` resource. A developer declares the files
of a static site, the number of replicas and optionally a host name:

```yaml
apiVersion: training.example.com/v1
kind: Website
metadata:
  name: shop
spec:
  replicas: 2
  hostname: shop.example.com
  content:
    index.html: "<h1>Shop</h1>"
```

and the `website-controller` (written later in this chapter) creates and maintains everything that is needed to serve
it:

```
Website shop ──owns──▶ ConfigMap shop      (the files)
             ├─owns──▶ Deployment shop     (nginx Pods serving the ConfigMap)
             ├─owns──▶ Service shop
             └─owns──▶ HTTPRoute shop      (only with spec.hostname, attached to the Gateway)
status: replicas, readyReplicas, url, conditions[Ready]
```

Work in a new directory on the workstation:

```bash
mkdir -p ~/website && cd ~/website
```

### The CustomResourceDefinition

The CRD below shows the features you need in practice:

- **structural OpenAPI schema** - every field has a type; unknown fields are pruned (dropped) by the API server,
- **defaults** (`replicas: 1`, `image`) - applied by the API server when the object is stored and read,
- **OpenAPI validation** (`minimum`/`maximum`, `maxLength`, `maxProperties`) and **CEL validation rules**
  (`x-kubernetes-validations`) for checks that need logic, including a **transition rule** with `oldSelf`
  (the host name cannot be changed once set),
- the **`status` subresource** - users change `spec`, the controller changes `status`
  (separate endpoints and RBAC rights, `metadata.generation` increases only on `spec` changes),
- the **`scale` subresource** - `kubectl scale` and the HorizontalPodAutoscaler work with Websites,
- **printer columns**, a **short name** and the `all` **category**.

```yaml
# website-crd.yaml
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: websites.training.example.com   # must be <plural>.<group>
spec:
  group: training.example.com
  scope: Namespaced
  names:
    plural: websites
    singular: website
    kind: Website
    shortNames: ["ws"]
    categories: ["all"]        # "kubectl get all" lists Websites, too
  versions:
  - name: v1
    served: true               # this version is available through the API
    storage: true              # objects are stored in etcd in this version
    schema:
      openAPIV3Schema:
        type: object
        required: ["spec"]
        properties:
          spec:
            type: object
            required: ["content"]
            properties:
              replicas:
                type: integer
                minimum: 0
                maximum: 10
                default: 1
                description: Number of web server Pods.
              image:
                type: string
                default: "nginx:1.31-alpine"
                description: Web server image (must serve /usr/share/nginx/html).
              hostname:
                type: string
                maxLength: 253
                description: Optional host name - the site is then published through the Gateway.
                x-kubernetes-validations:
                - rule: 'self.matches("^[a-z0-9]([-a-z0-9]*[a-z0-9])?(\\.[a-z0-9]([-a-z0-9]*[a-z0-9])?)+$")'
                  message: "hostname must be a fully qualified DNS name, e.g. shop.example.com"
                - rule: "self == oldSelf"          # transition rule - evaluated on updates only
                  message: "hostname is immutable"
              content:
                type: object
                description: Files of the site (file name -> file content).
                maxProperties: 20
                additionalProperties:
                  type: string
                  maxLength: 65536
            x-kubernetes-validations:
            - rule: "'index.html' in self.content"
              message: "content must contain index.html"
            - rule: "self.content.all(f, f.matches('^[A-Za-z0-9][A-Za-z0-9._-]*$'))"
              message: "content keys must be plain file names (letters, digits, '.', '_', '-')"
          status:
            type: object
            properties:
              observedGeneration:
                type: integer
                format: int64
              replicas:
                type: integer
              readyReplicas:
                type: integer
              selector:
                type: string
              url:
                type: string
              conditions:
                type: array
                x-kubernetes-list-type: map
                x-kubernetes-list-map-keys: ["type"]
                items:
                  type: object
                  required: ["type", "status"]
                  properties:
                    type:
                      type: string
                    status:
                      type: string
                      enum: ["True", "False", "Unknown"]
                    reason:
                      type: string
                    message:
                      type: string
                    lastTransitionTime:
                      type: string
                      format: date-time
    subresources:
      status: {}               # /status: spec and status are updated separately
      scale:                   # /scale: kubectl scale and HPA work with Websites
        specReplicasPath: .spec.replicas
        statusReplicasPath: .status.replicas
        labelSelectorPath: .status.selector
    additionalPrinterColumns:
    - name: Replicas
      type: integer
      jsonPath: .spec.replicas
    - name: Ready
      type: integer
      jsonPath: .status.readyReplicas
    - name: Status
      type: string
      jsonPath: .status.conditions[?(@.type=="Ready")].reason
    - name: URL
      type: string
      jsonPath: .status.url
    - name: Age
      type: date
      jsonPath: .metadata.creationTimestamp
```

```bash
kubectl apply -f website-crd.yaml
kubectl wait crd/websites.training.example.com --for=condition=Established

kubectl get crd websites.training.example.com
kubectl api-resources --api-group=training.example.com
# the OpenAPI schema is published a few seconds after "Established" - if explain reports
# "couldn't find resource", just repeat the command
kubectl explain website.spec
```

Expected:

```
NAME       SHORTNAMES   APIVERSION                NAMESPACED   KIND
websites   ws           training.example.com/v1   true         Website
```

The API server publishes the new REST endpoint immediately:

```bash
kubectl get --raw /apis/training.example.com/v1 | jq -r '.resources[].name'
```

Expected:

```
websites
websites/status
websites/scale
```

### Validation in action

Create a namespace for the demo and try an invalid object - all violations are reported at once:

```bash
kubectl create namespace web-demo

kubectl -n web-demo apply -f - <<'EOF'
apiVersion: training.example.com/v1
kind: Website
metadata:
  name: broken
spec:
  replicas: 20
  hostname: "Not_A_Host"
  content:
    about.html: "<h1>About</h1>"
    "../etc/passwd": "x"
EOF
```

Expected:

```
The Website "broken" is invalid:
* spec.replicas: Invalid value: 20: spec.replicas in body should be less than or equal to 10
* spec: Invalid value: content must contain index.html
* spec: Invalid value: content keys must be plain file names (letters, digits, '.', '_', '-')
* spec.hostname: Invalid value: "Not_A_Host": hostname must be a fully qualified DNS name, e.g. shop.example.com
```

A valid object is accepted and the defaults are filled in:

```bash
kubectl -n web-demo apply -f - <<'EOF'
apiVersion: training.example.com/v1
kind: Website
metadata:
  name: hello
spec:
  content:
    index.html: |
      <html><body><h1>Hello from a Website object!</h1></body></html>
EOF

kubectl -n web-demo get websites
kubectl -n web-demo get ws hello -o jsonpath='{.spec.image} {.spec.replicas}{"\n"}'
kubectl -n web-demo get deployments,services,configmaps
```

Expected:

```
NAME    REPLICAS   READY   STATUS   URL   AGE
hello   1                                 3s
nginx:1.31-alpine 1
NAME                         DATA   AGE
configmap/kube-root-ca.crt   1      10s
```

The Website is stored, but nothing else happens - there is no controller yet. `READY`, `STATUS` and `URL` are empty
because nobody writes the `status`.

## Workshop: Writing a Controller

A controller runs the **reconciliation loop**:

1. **watch** the resources it is responsible for (the Websites and the objects it created),
2. for every change, **read the desired state** (`spec`) and the actual state,
3. **create/update/delete** objects until both match - the operation must be **idempotent**
   (running it twice gives the same result) because events can repeat or get lost,
4. **report** what it observed in `status` (`observedGeneration`, `conditions`),
5. periodically **resync** everything, so missed events are repaired.

Production controllers are written in Go with `controller-runtime` (scaffolded by **Kubebuilder** or the
**Operator SDK**) which provides informers (cached watches), work queues, retries with back-off, leader election and
metrics. To see the mechanics without a compiler, our controller is a Bash script that uses `kubectl` and `jq` - and it
runs **inside the cluster**, as a Deployment with its own ServiceAccount, like a real operator. It uses the same
building blocks as the Go frameworks:

| Technique | Where in the script | Why |
|-----------|--------------------|-----|
| watches + periodic resync | `watch_websites`, `watch_owned`, `resync` | react quickly, repair lost events |
| single work queue | the final `while read` loop | one reconciliation at a time, no races |
| server-side apply with a field manager | `apply()` | idempotent create-or-update; `--force-conflicts` reverts manual changes |
| `ownerReferences` | `meta` | the garbage collector deletes owned objects together with the Website |
| finalizer | `FINALIZER` | clean-up of things the garbage collector cannot see (a cross-namespace registry) |
| content hash annotation | `training.example.com/content-hash` | new site files trigger a rolling update |
| status subresource + `observedGeneration` + conditions | step 4 | users see whether the controller has processed the latest spec |
| write status only when it changed | step 4 | avoid endless update -> event -> update loops |

Save the script as `controller.sh`:

```bash
cat > controller.sh <<'EOF'
#!/bin/bash
# website-controller - reconciles training.example.com/v1 Website objects.
# For every Website it owns: ConfigMap (site files), Deployment (nginx), Service and - if spec.hostname
# is set - an HTTPRoute attached to the shared Gateway. It also keeps a cluster-wide registry of all
# published sites (a ConfigMap in its own namespace) which needs a finalizer to be cleaned up.
set -uo pipefail

MANAGER=website-controller                               # field manager for server-side apply
FINALIZER=training.example.com/registry-cleanup
GATEWAY_NAME=${GATEWAY_NAME:-website-gateway}
GATEWAY_NAMESPACE=${GATEWAY_NAMESPACE:-website-system}
REGISTRY_NAMESPACE=${REGISTRY_NAMESPACE:-website-system}
REGISTRY=website-registry
RESYNC_SECONDS=${RESYNC_SECONDS:-60}

log() { echo "$(date -u +%H:%M:%S) $*"; }

# bash running as PID 1 ignores SIGTERM - stop all watches promptly when the Pod is deleted
trap 'log "stopping"; kill 0; exit 0' TERM INT

# server-side apply of a JSON object read from stdin; --force-conflicts takes back fields
# that somebody changed by hand (drift correction)
apply() {
  local out
  out=$(kubectl apply --server-side --field-manager="$MANAGER" --force-conflicts -f - 2>&1 >/dev/null) \
    || log "apply failed: $out"
}

registry_set() {      # registry_set <key> <value>  (value "" removes the key)
  local patch
  if [ -n "$2" ]; then patch=$(jq -nc --arg k "$1" --arg v "$2" '{data: {($k): $v}}')
  else patch=$(jq -nc --arg k "$1" '{data: {($k): null}}'); fi
  kubectl -n "$REGISTRY_NAMESPACE" patch configmap "$REGISTRY" --type=merge -p "$patch" >/dev/null
}

reconcile() {         # reconcile <namespace> <name>
  local ns=$1 name=$2 ws
  ws=$(kubectl -n "$ns" get website "$name" -o json 2>/dev/null) || return 0   # already gone

  # 1. Deletion: the API server keeps the object while our finalizer is present
  if [ "$(jq -r '.metadata.deletionTimestamp // ""' <<<"$ws")" != "" ]; then
    if jq -e --arg f "$FINALIZER" '.metadata.finalizers // [] | index($f)' <<<"$ws" >/dev/null; then
      log "$ns/$name: deleting - removing registry entry, then the finalizer"
      registry_set "$ns.$name" ""
      local rest
      rest=$(jq -c --arg f "$FINALIZER" '[.metadata.finalizers[] | select(. != $f)]' <<<"$ws")
      kubectl -n "$ns" patch website "$name" --type=json \
        -p "[{\"op\":\"test\",\"path\":\"/metadata/resourceVersion\",\"value\":\"$(jq -r .metadata.resourceVersion <<<"$ws")\"},
             {\"op\":\"replace\",\"path\":\"/metadata/finalizers\",\"value\":$rest}]" >/dev/null
    fi
    return 0   # the garbage collector deletes the owned objects (ownerReferences)
  fi

  # 2. Make sure our finalizer is set before we create anything outside the namespace
  if ! jq -e --arg f "$FINALIZER" '.metadata.finalizers // [] | index($f)' <<<"$ws" >/dev/null; then
    kubectl -n "$ns" patch website "$name" --type=merge \
      -p "$(jq -c --arg f "$FINALIZER" '{metadata: {finalizers: ((.metadata.finalizers // []) + [$f])}}' <<<"$ws")" >/dev/null
    log "$ns/$name: finalizer added"
  fi

  local uid gen replicas image hostname hash selector url
  uid=$(jq -r .metadata.uid <<<"$ws")
  gen=$(jq -r .metadata.generation <<<"$ws")
  replicas=$(jq -r '.spec.replicas // 1' <<<"$ws")
  image=$(jq -r '.spec.image // "nginx:1.31-alpine"' <<<"$ws")
  hostname=$(jq -r '.spec.hostname // ""' <<<"$ws")
  hash=$(jq -cS '.spec.content' <<<"$ws" | sha256sum | cut -c1-16)
  selector="app.kubernetes.io/name=website,app.kubernetes.io/instance=$name"

  # common metadata: labels + ownerReference (garbage collection, "kubectl get -o wide" shows the owner)
  local meta
  meta=$(jq -nc --arg ns "$ns" --arg name "$name" --arg uid "$uid" '{
    namespace: $ns, name: $name,
    labels: {"app.kubernetes.io/name": "website", "app.kubernetes.io/instance": $name,
             "app.kubernetes.io/managed-by": "website-controller"},
    ownerReferences: [{apiVersion: "training.example.com/v1", kind: "Website", name: $name, uid: $uid,
                       controller: true, blockOwnerDeletion: true}]}')

  # 3. Desired state of the owned objects
  jq -c --argjson m "$meta" '{apiVersion: "v1", kind: "ConfigMap", metadata: $m, data: .spec.content}' <<<"$ws" | apply

  jq -nc --argjson m "$meta" --arg name "$name" --arg image "$image" --argjson replicas "$replicas" --arg hash "$hash" '{
    apiVersion: "apps/v1", kind: "Deployment", metadata: $m,
    spec: {
      replicas: $replicas,
      selector: {matchLabels: {"app.kubernetes.io/name": "website", "app.kubernetes.io/instance": $name}},
      template: {
        metadata: {labels: {"app.kubernetes.io/name": "website", "app.kubernetes.io/instance": $name},
                   annotations: {"training.example.com/content-hash": $hash}},   # new content -> rollout
        spec: {containers: [{
          name: "web", image: $image,
          ports: [{name: "http", containerPort: 80}],
          readinessProbe: {httpGet: {path: "/", port: "http"}, periodSeconds: 5},
          resources: {requests: {cpu: "10m", memory: "16Mi"}, limits: {cpu: "100m", memory: "64Mi"}},
          volumeMounts: [{name: "content", mountPath: "/usr/share/nginx/html", readOnly: true}]}],
          volumes: [{name: "content", configMap: {name: $name}}]}}}}' | apply

  jq -nc --argjson m "$meta" --arg name "$name" '{
    apiVersion: "v1", kind: "Service", metadata: $m,
    spec: {selector: {"app.kubernetes.io/name": "website", "app.kubernetes.io/instance": $name},
           ports: [{name: "http", port: 80, targetPort: "http"}]}}' | apply

  if [ -n "$hostname" ]; then
    jq -nc --argjson m "$meta" --arg name "$name" --arg host "$hostname" \
          --arg gw "$GATEWAY_NAME" --arg gwns "$GATEWAY_NAMESPACE" '{
      apiVersion: "gateway.networking.k8s.io/v1", kind: "HTTPRoute", metadata: $m,
      spec: {parentRefs: [{name: $gw, namespace: $gwns}], hostnames: [$host],
             rules: [{backendRefs: [{name: $name, port: 80}]}]}}' | apply
    url="http://$hostname/"
  else
    kubectl -n "$ns" delete httproute "$name" --ignore-not-found >/dev/null
    url="http://$name.$ns.svc.cluster.local/"
  fi
  registry_set "$ns.$name" "$url"

  # 4. Observed state -> status (written only when it changed, otherwise every write would trigger a new event)
  local dep ready total status reason message old_cond new_status
  dep=$(kubectl -n "$ns" get deployment "$name" -o json 2>/dev/null || echo '{}')
  ready=$(jq -r '.status.readyReplicas // 0' <<<"$dep")
  total=$(jq -r '.status.replicas // 0' <<<"$dep")
  if [ "$ready" -ge "$replicas" ]; then
    status=True; reason=Available; message="$ready/$replicas replicas ready"
  else
    status=False; reason=Progressing; message="$ready/$replicas replicas ready"
  fi
  old_cond=$(jq -c '(.status.conditions // [])[] | select(.type == "Ready")' <<<"$ws")
  new_status=$(jq -nc --argjson gen "$gen" --argjson ready "$ready" --argjson total "$total" \
      --arg selector "$selector" --arg url "$url" --arg status "$status" --arg reason "$reason" \
      --arg message "$message" --argjson old "${old_cond:-null}" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '{
    observedGeneration: $gen, replicas: $total, readyReplicas: $ready, selector: $selector, url: $url,
    conditions: [{type: "Ready", status: $status, reason: $reason, message: $message,
      lastTransitionTime: (if $old != null and $old.status == $status then $old.lastTransitionTime else $now end)}]}')
  if [ "$(jq -cS '.status // {}' <<<"$ws")" != "$(jq -cS . <<<"$new_status")" ]; then
    kubectl -n "$ns" patch website "$name" --subresource=status --type=merge \
      -p "$(jq -nc --argjson s "$new_status" '{status: $s}')" >/dev/null
    log "$ns/$name: generation=$gen ready=$ready/$replicas url=$url"
  fi
}

# --- event sources: every source prints "<namespace> <website-name>" lines ---------------------
watch_websites() {      # changes of Website objects
  while true; do
    kubectl get websites -A --watch -o jsonpath='{.metadata.namespace} {.metadata.name}{"\n"}'
    sleep 1             # a watch ends after a while (API server timeout) - just start a new one
  done
}
watch_owned() {         # changes of owned Deployments (Pods became ready, someone edited or deleted one)
  while true; do
    kubectl get deployments -A -l app.kubernetes.io/managed-by=website-controller --watch \
      -o jsonpath='{.metadata.namespace} {.metadata.labels.app\.kubernetes\.io/instance}{"\n"}'
    sleep 1
  done
}
resync() {              # periodic full resync - repairs anything a lost event would leave behind
  while true; do
    sleep "$RESYNC_SECONDS"
    kubectl get websites -A -o jsonpath='{range .items[*]}{.metadata.namespace} {.metadata.name}{"\n"}{end}'
  done
}

log "website-controller starting (gateway $GATEWAY_NAMESPACE/$GATEWAY_NAME, resync ${RESYNC_SECONDS}s)"
kubectl -n "$REGISTRY_NAMESPACE" create configmap "$REGISTRY" >/dev/null 2>&1 && log "registry $REGISTRY created"

# all sources feed one queue; a single worker processes the events one by one
{ watch_websites & watch_owned & resync & wait; } | while read -r ns name; do
  [ -n "$name" ] && reconcile "$ns" "$name"
done
EOF
```

> Why a finalizer? Owned objects in the **same namespace** are deleted by the garbage collector thanks to
> `ownerReferences` - no code needed. The registry entry lives in another namespace (`website-system`) and an owner
> reference cannot point across namespaces. The finalizer makes the API server keep the deleted Website
> (`deletionTimestamp` set, still readable) until the controller has removed the entry and then the finalizer.

### Deploying the controller

The controller needs a namespace, a Gateway to attach the HTTPRoutes to, and RBAC that allows exactly what the script
does - nothing more:

```bash
kubectl create namespace website-system

kubectl apply -f - <<'EOF'
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: website-gateway
  namespace: website-system
spec:
  gatewayClassName: nginx
  listeners:
  - name: http
    port: 80
    protocol: HTTP
    allowedRoutes:
      namespaces:
        from: All          # Websites live in many namespaces
EOF
```

```yaml
# controller-deploy.yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: website-controller
  namespace: website-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: website-controller
rules:
# the custom resource: read, set finalizers (update/patch) and write the status subresource
- apiGroups: ["training.example.com"]
  resources: ["websites"]
  verbs: ["get", "list", "watch", "update", "patch"]
- apiGroups: ["training.example.com"]
  resources: ["websites/status"]
  verbs: ["get", "update", "patch"]
# the objects it creates for every Website
- apiGroups: [""]
  resources: ["configmaps", "services"]
  verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
- apiGroups: ["apps"]
  resources: ["deployments"]
  verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
- apiGroups: ["gateway.networking.k8s.io"]
  resources: ["httproutes"]
  verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: website-controller
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: website-controller
subjects:
- kind: ServiceAccount
  name: website-controller
  namespace: website-system
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: website-controller
  namespace: website-system
  labels:
    app: website-controller
spec:
  replicas: 1                 # exactly one active controller (no leader election in this simple version)
  strategy:
    type: Recreate            # never run the old and the new controller at the same time
  selector:
    matchLabels:
      app: website-controller
  template:
    metadata:
      labels:
        app: website-controller
    spec:
      serviceAccountName: website-controller   # kubectl in the Pod uses this identity (in-cluster config)
      containers:
      - name: controller
        image: alpine/k8s:1.37.1                # kubectl, jq, bash
        command: ["bash", "/scripts/controller.sh"]
        env:
        - name: HOME                            # kubectl caches API discovery in $HOME/.kube
          value: /tmp
        - name: GATEWAY_NAME
          value: website-gateway
        - name: GATEWAY_NAMESPACE
          value: website-system
        - name: RESYNC_SECONDS
          value: "60"
        resources:
          requests:
            cpu: 50m
            memory: 64Mi
          limits:
            cpu: 500m
            memory: 256Mi
        securityContext:
          runAsNonRoot: true
          runAsUser: 65534
          allowPrivilegeEscalation: false
          capabilities:
            drop: ["ALL"]
        volumeMounts:
        - name: scripts
          mountPath: /scripts
      volumes:
      - name: scripts
        configMap:
          name: website-controller-script
```

```bash
# the script is delivered as a ConfigMap (create-or-update, so you can rerun it after editing controller.sh)
kubectl -n website-system create configmap website-controller-script --from-file=controller.sh \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl apply -f controller-deploy.yaml
kubectl -n website-system rollout status deploy/website-controller
kubectl -n website-system wait gateway/website-gateway --for=condition=Programmed --timeout=2m
GW_IP=$(kubectl -n website-system get gateway website-gateway -o jsonpath='{.status.addresses[0].value}'); echo $GW_IP

# check the RBAC: allowed / not allowed
kubectl auth can-i patch websites/status --as=system:serviceaccount:website-system:website-controller -A
kubectl auth can-i get secrets --as=system:serviceaccount:website-system:website-controller -A
```

Watch the controller pick up the Website created before it existed (open a second terminal for the logs):

```bash
kubectl -n website-system logs -f deploy/website-controller
```

Expected:

```
02:27:58 website-controller starting (gateway website-system/website-gateway, resync 60s)
02:27:59 registry website-registry created
02:28:00 web-demo/hello: finalizer added
02:28:02 web-demo/hello: generation=1 ready=0/1 url=http://hello.web-demo.svc.cluster.local/
02:28:05 web-demo/hello: generation=1 ready=1/1 url=http://hello.web-demo.svc.cluster.local/
```

`kubectl wait` works with the conditions of custom resources, too:

```bash
kubectl -n web-demo wait website/hello --for=condition=Ready --timeout=2m
kubectl -n web-demo get websites
kubectl -n web-demo get deploy,svc,cm,pods
kubectl -n web-demo get deploy hello -o jsonpath='{.metadata.ownerReferences}{"\n"}'
kubectl -n web-demo get ws hello -o jsonpath='{.metadata.finalizers}{"\n"}{.status}{"\n"}'
kubectl -n website-system get configmap website-registry -o jsonpath='{.data}{"\n"}'

# the site answers inside the cluster
kubectl -n web-demo run curl --rm -i --restart=Never --image=curlimages/curl:8.23.0 -- -s http://hello/
```

Expected (trimmed):

```
NAME    REPLICAS   READY   STATUS      URL                                        AGE
hello   1          1       Available   http://hello.web-demo.svc.cluster.local/   43s
...
[{"apiVersion":"training.example.com/v1","blockOwnerDeletion":true,"controller":true,"kind":"Website","name":"hello","uid":"..."}]
["training.example.com/registry-cleanup"]
{"conditions":[{"lastTransitionTime":"...","message":"1/1 replicas ready","reason":"Available","status":"True","type":"Ready"}],"observedGeneration":1,...}
{"web-demo.hello":"http://hello.web-demo.svc.cluster.local/"}
<html><body><h1>Hello from a Website object!</h1></body></html>
```

### Publishing a site through the Gateway

```bash
kubectl -n web-demo apply -f - <<'EOF'
apiVersion: training.example.com/v1
kind: Website
metadata:
  name: shop
spec:
  replicas: 2
  hostname: shop.example.com
  content:
    index.html: |
      <html><body><h1>Shop</h1><p>Version 1</p></body></html>
    health.txt: "ok\n"
EOF

kubectl -n web-demo wait website/shop --for=condition=Ready --timeout=2m
kubectl -n web-demo get ws
kubectl -n web-demo get httproute
```

From the client VM (use the `GW_IP` printed above):

```bash
curl -s -H 'Host: shop.example.com' http://<GW_IP>/
curl -s -H 'Host: shop.example.com' http://<GW_IP>/health.txt
```

Expected:

```
<html><body><h1>Shop</h1><p>Version 1</p></body></html>
ok
```

### Changing, scaling and breaking things

**New content** - the content hash in the Pod template changes, so the Deployment rolls out new Pods:

```bash
kubectl -n web-demo patch website shop --type=merge \
  -p '{"spec":{"content":{"index.html":"<html><body><h1>Shop</h1><p>Version 2</p></body></html>\n"}}}'
kubectl -n web-demo rollout status deploy/shop
```

The client VM now gets `Version 2`.

**Scaling through the scale subresource** - the same endpoint the HPA uses:

```bash
kubectl -n web-demo scale website shop --replicas=4
kubectl -n web-demo wait website/shop --for=jsonpath='{.status.readyReplicas}'=4 --timeout=2m
kubectl -n web-demo get ws shop
kubectl get --raw /apis/training.example.com/v1/namespaces/web-demo/websites/shop/scale | jq -c '.spec, .status'
```

Expected:

```
NAME   REPLICAS   READY   STATUS      URL                        AGE
shop   4          4       Available   http://shop.example.com/   53s
{"replicas":4}
{"replicas":4,"selector":"app.kubernetes.io/name=website,app.kubernetes.io/instance=shop"}
```

**Transition rule** - the host name is immutable:

```bash
kubectl -n web-demo patch website shop --type=merge -p '{"spec":{"hostname":"other.example.com"}}'
```

Expected:

```
The Website "shop" is invalid: spec.hostname: Invalid value: "other.example.com": hostname is immutable
```

**Drift** - change or delete an owned object by hand. The Deployment watch triggers a reconciliation and server-side
apply restores the desired state:

```bash
kubectl -n web-demo scale deployment shop --replicas=1
sleep 5; kubectl -n web-demo get deploy shop        # back to 4

kubectl -n web-demo delete deployment shop
sleep 5; kubectl -n web-demo get deploy shop        # recreated
kubectl -n website-system logs deploy/website-controller --tail=5
```

### Deletion: garbage collection and the finalizer

```bash
kubectl -n web-demo delete website hello
kubectl -n web-demo get deploy,svc,cm               # hello-* objects are gone (garbage collector)
kubectl -n website-system get configmap website-registry -o jsonpath='{.data}{"\n"}'   # entry removed
```

Now see what a finalizer means when its controller is not running:

```bash
kubectl -n website-system scale deploy website-controller --replicas=0
kubectl -n website-system wait --for=delete pod -l app=website-controller --timeout=60s

kubectl -n web-demo delete website shop --wait=false
kubectl -n web-demo get website shop -o jsonpath='{.metadata.deletionTimestamp} {.metadata.finalizers}{"\n"}'
kubectl -n web-demo get ws,deploy                    # still there - the deletion waits for the finalizer
```

Expected:

```
2026-11-06T02:32:54Z ["training.example.com/registry-cleanup"]
NAME                                REPLICAS   READY   STATUS      URL                        AGE
website.training.example.com/shop   2          2       Available   http://shop.example.com/   45s
...
```

Start the controller again - it finishes the clean-up and removes the finalizer, then the garbage collector deletes
the owned objects:

```bash
kubectl -n website-system scale deploy website-controller --replicas=1
kubectl -n web-demo wait --for=delete website/shop --timeout=90s
kubectl -n web-demo get all
kubectl -n website-system logs deploy/website-controller
```

Expected:

```
website.training.example.com/shop condition met
No resources found in web-demo namespace.
... web-demo/shop: deleting - removing registry entry, then the finalizer
```

> A Website stuck in `Terminating` because its controller was uninstalled can be released by removing the finalizer
> by hand (`kubectl patch website shop --type=json -p '[{"op":"remove","path":"/metadata/finalizers"}]'`) - but then
> the clean-up it guarded is skipped. Always delete the custom resources **before** you uninstall their controller.

### Where to go from here

The Bash controller is a teaching tool. Limits you would hit in production and what the frameworks give you:

- **one object at a time, no caching** - every reconciliation calls the API server several times;
  `controller-runtime` keeps an informer cache and runs several workers,
- **no leader election** - therefore `replicas: 1` and `strategy: Recreate`; real controllers run 2+ replicas and use
  a `Lease` to elect the active one,
- **no events and metrics** - real controllers emit Kubernetes Events and expose Prometheus metrics,
- **one API version** - when the schema changes incompatibly, a CRD serves several versions (`served: true`, only one
  `storage: true`) and a **conversion webhook** converts between them; old versions are marked `deprecated: true`.

```bash
# Kubebuilder (Go) scaffolds the same resource in a few commands
kubebuilder init --domain example.com --repo example.com/website-operator
kubebuilder create api --group training --version v1 --kind Website
```

Many well-known projects are operators built this way: cert-manager (`Certificate`), CloudNativePG (`Cluster`),
Prometheus Operator (`ServiceMonitor`, used in module 14), Argo CD (`Application`, module 16).

## Workshop: Admission Control with CEL Policies

Every write request passes the **admission chain** after authentication and authorization and before it is stored:

```
request ─▶ authN ─▶ authZ ─▶ mutating admission ─▶ schema validation ─▶ validating admission ─▶ etcd
                             (MutatingAdmission-     (OpenAPI + CRD       (ValidatingAdmission-
                              Policy, webhooks)       CEL rules)           Policy, webhooks)
```

Kubernetes offers two ways to plug your own rules into it:

| | Admission policies (CEL) | Admission webhooks |
|---|---|---|
| Where the logic runs | inside the API server | your HTTPS service in or outside the cluster |
| Language | CEL expressions in YAML | any (Go, Python, ...) |
| Operations | validate (`ValidatingAdmissionPolicy`), mutate (`MutatingAdmissionPolicy`) | validate and mutate |
| Availability risk | none - no extra network hop | webhook down + `failurePolicy: Fail` blocks the matched requests |
| Typical use | most policies (labels, images, limits, defaults) | checks needing external data, image signature verification, complex logic |

Both policy kinds are stable (`admissionregistration.k8s.io/v1`) in Kubernetes 1.37 - check it:

```bash
kubectl api-resources --api-group=admissionregistration.k8s.io
```

A **policy** describes the rule and what it matches; a **binding** activates it, optionally only for some namespaces
and with parameters. One policy can have several bindings (e.g. `Warn` for everybody, `Deny` for production).

Prepare a tenant namespace. The labels drive the bindings below:

```bash
kubectl create namespace team-a
kubectl label namespace team-a team=team-a training.example.com/policy=enforced
```

### ValidatingAdmissionPolicy with parameters: per-team limits for Websites

Different teams get different limits. The rule is written once; the limits are **parameters** - a ConfigMap in each
team namespace. Namespaces without the ConfigMap are not restricted (`parameterNotFoundAction: Allow`).

```yaml
# website-limits.yaml
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicy
metadata:
  name: website-limits
spec:
  failurePolicy: Fail
  paramKind:                        # the type of the parameter objects
    apiVersion: v1
    kind: ConfigMap
  matchConstraints:
    resourceRules:
    - apiGroups: ["training.example.com"]
      apiVersions: ["v1"]
      operations: ["CREATE", "UPDATE"]
      resources: ["websites", "websites/scale"]   # include the scale subresource - otherwise "kubectl scale" bypasses the rule
  validations:
  # for websites/scale the object is an autoscaling/v1 Scale - it also has spec.replicas
  - expression: "object.spec.replicas <= int(params.data.maxReplicas)"
    messageExpression: "'at most ' + params.data.maxReplicas + ' replicas are allowed in namespace ' + request.namespace"
    reason: Forbidden
  - expression: "!has(object.spec.hostname) || object.spec.hostname.endsWith('.' + params.data.domain)"
    messageExpression: "'hostname must end with .' + params.data.domain"
---
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicyBinding
metadata:
  name: website-limits
spec:
  policyName: website-limits
  validationActions: ["Deny"]
  paramRef:
    name: website-limits            # the ConfigMap named website-limits in the namespace of the request
    parameterNotFoundAction: Allow
```

```bash
kubectl apply -f website-limits.yaml
kubectl -n team-a create configmap website-limits --from-literal=maxReplicas=3 --from-literal=domain=team-a.example.com
sleep 10     # new policies and bindings become active in the API server within a few seconds
```

Test it:

```bash
# too many replicas, foreign domain
kubectl -n team-a apply -f - <<'EOF'
apiVersion: training.example.com/v1
kind: Website
metadata:
  name: big
spec:
  replicas: 5
  hostname: big.example.com
  content:
    index.html: "<h1>Big</h1>"
EOF

# within the limits
kubectl -n team-a apply -f - <<'EOF'
apiVersion: training.example.com/v1
kind: Website
metadata:
  name: blog
spec:
  replicas: 2
  hostname: blog.team-a.example.com
  content:
    index.html: "<h1>Blog of team A</h1>"
EOF

kubectl -n team-a scale website blog --replicas=5     # denied through the scale subresource as well
kubectl -n team-a scale website blog --replicas=3     # allowed

# web-demo has no website-limits ConfigMap -> no limit
kubectl -n web-demo apply -f - <<'EOF'
apiVersion: training.example.com/v1
kind: Website
metadata:
  name: big
spec:
  replicas: 5
  content:
    index.html: "<h1>Big</h1>"
EOF
kubectl -n web-demo wait website/big --for=condition=Ready --timeout=2m
kubectl get ws -A
```

Expected (trimmed):

```
Error from server (Forbidden): ... websites.training.example.com "big" is forbidden: ValidatingAdmissionPolicy 'website-limits' with binding 'website-limits' denied request: at most 3 replicas are allowed in namespace team-a
website.training.example.com/blog created
Error from server (Forbidden): websites.training.example.com "blog" is forbidden: ... at most 3 replicas are allowed in namespace team-a
website.training.example.com/blog scaled
website.training.example.com/big created
NAMESPACE   NAME   REPLICAS   READY   STATUS      URL                                      AGE
team-a      blog   3          3       Available   http://blog.team-a.example.com/          11s
web-demo    big    5          5       Available   http://big.web-demo.svc.cluster.local/   10s
```

### Roll out a policy safely: Warn and Audit before Deny

A new rule can break existing deployment pipelines. Start with `validationActions: ["Warn", "Audit"]`: the request is
allowed, the client prints a warning, and the violation is recorded in the API server audit log (if audit logging is
enabled). Switch to `Deny` when nobody gets warnings any more.

The policy below forbids unpinned images (no tag, or `:latest`) in Deployments, StatefulSets, DaemonSets **and**
Websites. `variables` keep the expressions readable:

```yaml
# pinned-images.yaml
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicy
metadata:
  name: pinned-images
spec:
  failurePolicy: Fail
  matchConstraints:
    resourceRules:
    - apiGroups: ["apps"]
      apiVersions: ["v1"]
      operations: ["CREATE", "UPDATE"]
      resources: ["deployments", "statefulsets", "daemonsets"]
    - apiGroups: ["training.example.com"]
      apiVersions: ["v1"]
      operations: ["CREATE", "UPDATE"]
      resources: ["websites"]
  variables:
  - name: images
    expression: >-
      object.kind == 'Website'
        ? [object.spec.image]
        : object.spec.template.spec.containers.map(c, c.image)
  - name: unpinned          # no digest and (":latest" or no tag in the last path segment)
    expression: >-
      variables.images.filter(i, !i.contains('@') &&
        (i.endsWith(':latest') || !i.split('/')[i.split('/').size() - 1].contains(':')))
  validations:
  - expression: "size(variables.unpinned) == 0"
    messageExpression: "'images must use a fixed tag or digest (not :latest): ' + variables.unpinned.join(', ')"
---
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicyBinding
metadata:
  name: pinned-images
spec:
  policyName: pinned-images
  validationActions: ["Warn", "Audit"]
  matchResources:
    namespaceSelector:              # only namespaces that opted in
      matchLabels:
        training.example.com/policy: enforced
```

```bash
kubectl apply -f pinned-images.yaml
sleep 10

kubectl -n team-a create deployment latest-app --image=nginx:latest      # warning, but created
kubectl -n team-a create deployment notag-app --image=nginx              # warning, but created
kubectl -n team-a create deployment pinned-app --image=nginx:1.31-alpine # fine
kubectl -n web-demo create deployment latest-app --image=nginx:latest    # namespace not selected - no warning
```

Expected:

```
Warning: Validation failed for ValidatingAdmissionPolicy 'pinned-images' with binding 'pinned-images': images must use a fixed tag or digest (not :latest): nginx:latest
deployment.apps/latest-app created
Warning: Validation failed for ValidatingAdmissionPolicy 'pinned-images' with binding 'pinned-images': images must use a fixed tag or digest (not :latest): nginx
deployment.apps/notag-app created
deployment.apps/pinned-app created
deployment.apps/latest-app created
```

Now enforce it:

```bash
kubectl patch validatingadmissionpolicybinding pinned-images --type=merge -p '{"spec":{"validationActions":["Deny"]}}'
sleep 10

kubectl -n team-a create deployment latest-app2 --image=nginx:latest
kubectl -n team-a apply -f - <<'EOF'
apiVersion: training.example.com/v1
kind: Website
metadata:
  name: legacy
spec:
  image: "registry.example.com:5000/nginx"   # the ":5000" is a port, not a tag
  content:
    index.html: "<h1>Legacy</h1>"
EOF

kubectl -n team-a delete deployment latest-app notag-app pinned-app
kubectl -n web-demo delete deployment latest-app
```

Expected:

```
error: failed to create deployment: deployments.apps "latest-app2" is forbidden: ValidatingAdmissionPolicy 'pinned-images' with binding 'pinned-images' denied request: images must use a fixed tag or digest (not :latest): nginx:latest
The websites "legacy" is invalid: : ValidatingAdmissionPolicy 'pinned-images' with binding 'pinned-images' denied request: images must use a fixed tag or digest (not :latest): registry.example.com:5000/nginx
```

Existing objects are not re-checked - a policy acts only on new write requests. Note also that Pods created by the
Deployment controller are not affected, because the policy matches the Deployment, not the Pods.

### MutatingAdmissionPolicy: defaults and labels without a webhook

A `MutatingAdmissionPolicy` changes the object before it is validated and stored. A mutation is one of:

- `ApplyConfiguration` - a CEL `Object{...}` that is merged like a server-side apply patch (maps are merged,
  lists of named items are merged by key) - the most convenient way to *add* fields,
- `JSONPatch` - a list of RFC 6902 operations (`add`, `replace`, `remove`, ...) for precise changes.

**Example 1 (`ApplyConfiguration`)** - copy the `team` label of the namespace to the Pod template of every Deployment,
so every Pod can be attributed to a team (cost reports, network policies, dashboards). `namespaceObject` is the
Namespace of the request. The binding selects only namespaces that have a `team` label, so the expression can rely on
it:

```yaml
# team-label.yaml
apiVersion: admissionregistration.k8s.io/v1
kind: MutatingAdmissionPolicy
metadata:
  name: team-label
spec:
  failurePolicy: Fail
  reinvocationPolicy: IfNeeded       # run again if a later mutation changed the object
  matchConstraints:
    resourceRules:
    - apiGroups: ["apps"]
      apiVersions: ["v1"]
      operations: ["CREATE", "UPDATE"]
      resources: ["deployments"]
  mutations:
  - patchType: ApplyConfiguration
    applyConfiguration:
      expression: >-
        Object{
          spec: Object.spec{
            template: Object.spec.template{
              metadata: Object.spec.template.metadata{
                labels: {"team": namespaceObject.metadata.labels["team"]}
              }
            }
          }
        }
---
apiVersion: admissionregistration.k8s.io/v1
kind: MutatingAdmissionPolicyBinding
metadata:
  name: team-label
spec:
  policyName: team-label
  matchResources:
    namespaceSelector:
      matchExpressions:
      - key: team
        operator: Exists
```

> Be careful with broad mutating policies and `failurePolicy: Fail`: if the expression fails at runtime (for example
> it reads a label that does not exist), **every matching request is rejected** - here every Deployment write in the
> cluster, including system components. Narrow the policy with the binding's `namespaceSelector`/`objectSelector` or
> `matchConditions`, and test it on a single namespace first.

**Example 2 (`JSONPatch`)** - every Website in an enforced namespace gets a default `robots.txt` that blocks search
engines, unless the team provides its own. `matchConditions` decide whether the policy applies at all:

```yaml
# website-robots.yaml
apiVersion: admissionregistration.k8s.io/v1
kind: MutatingAdmissionPolicy
metadata:
  name: website-robots
spec:
  failurePolicy: Fail
  reinvocationPolicy: Never
  matchConstraints:
    resourceRules:
    - apiGroups: ["training.example.com"]
      apiVersions: ["v1"]
      operations: ["CREATE", "UPDATE"]
      resources: ["websites"]
  matchConditions:
  - name: no-robots-file
    expression: "!('robots.txt' in object.spec.content)"
  mutations:
  - patchType: JSONPatch
    jsonPatch:
      expression: >-
        [
          JSONPatch{
            op: "add",
            path: "/spec/content/robots.txt",
            value: "User-agent: *\nDisallow: /\n"
          }
        ]
---
apiVersion: admissionregistration.k8s.io/v1
kind: MutatingAdmissionPolicyBinding
metadata:
  name: website-robots
spec:
  policyName: website-robots
  matchResources:
    namespaceSelector:
      matchLabels:
        training.example.com/policy: enforced
```

```bash
kubectl apply -f team-label.yaml -f website-robots.yaml
sleep 10

# Example 1
kubectl -n team-a create deployment api --image=nginx:1.31-alpine
kubectl -n team-a get deploy api -o jsonpath='{.spec.template.metadata.labels}{"\n"}'
kubectl -n web-demo create deployment api --image=nginx:1.31-alpine     # namespace without "team" label
kubectl -n web-demo get deploy api -o jsonpath='{.spec.template.metadata.labels}{"\n"}'

# Example 2 - any update of the existing Website passes the admission chain again
kubectl -n team-a annotate website blog reviewed=yes
kubectl -n team-a get website blog -o jsonpath='{.spec.content}{"\n"}'
```

Expected:

```
{"app":"api","team":"team-a"}
{"app":"api"}
{"index.html":"<h1>Blog of team A</h1>","robots.txt":"User-agent: *\nDisallow: /\n"}
```

The two policies also work together with the controller: the `blog` Deployment written by the website-controller
gets the `team` label, and the new `robots.txt` is served after the rollout:

```bash
kubectl -n team-a rollout status deploy/blog
kubectl -n team-a get pods --show-labels
```

From the client VM:

```bash
curl -s -H 'Host: blog.team-a.example.com' http://<GW_IP>/robots.txt
```

Expected:

```
User-agent: *
Disallow: /
```

### Admission webhooks in a nutshell

When CEL is not enough, register an HTTPS service as a webhook with a `ValidatingWebhookConfiguration` or
`MutatingWebhookConfiguration`. The API server sends it an `AdmissionReview` request and expects an
`AdmissionReview` response (`allowed`, optional `patch`). Important settings:

- `failurePolicy: Fail | Ignore` - what happens when the webhook is unreachable or times out,
- `timeoutSeconds` (default 10, max 30) - every matched request waits for the webhook,
- `namespaceSelector` / `objectSelector` / `matchConditions` - always exclude `kube-system` and the webhook's own
  namespace, otherwise the webhook can block its own restart,
- `sideEffects: None` and `admissionReviewVersions: ["v1"]`,
- TLS: the API server must trust the webhook certificate (`caBundle`; cert-manager can inject it).

```bash
# webhooks installed in the cluster (e.g. by NGINX Gateway Fabric, MetalLB, cert-manager)
kubectl get validatingwebhookconfigurations,mutatingwebhookconfigurations
```

## Clean up

```bash
kubectl delete -f team-label.yaml -f website-robots.yaml -f pinned-images.yaml -f website-limits.yaml
kubectl delete namespace team-a web-demo          # Websites are deleted while the controller still runs
kubectl delete -f controller-deploy.yaml
kubectl delete namespace website-system
kubectl delete -f website-crd.yaml                # deletes the CRD and all remaining Website objects
cd ~ && rm -rf ~/website
```
