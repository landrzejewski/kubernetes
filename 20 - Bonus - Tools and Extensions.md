1. What Rancher is
   Rancher is a container management platform that sits on top of Kubernetes. It is not a replacement for Kubernetes — rather, it enhances and simplifies Kubernetes management.
   Key features of Rancher:
1. Multi-cluster management – You can manage multiple Kubernetes clusters from different providers (on-prem, cloud, or hosted) in one dashboard.
2. Cluster provisioning – Rancher can provision Kubernetes clusters for you on bare metal, VMs, or cloud providers (AWS, GCP, Azure, etc.).
3. Centralized authentication and RBAC – Integrates with LDAP, Active Directory, GitHub, SSO. Manages user access across clusters.
4. UI and dashboards – Provides a web UI to monitor workloads, pods, nodes, namespaces, storage, and networking.
5. App catalogs – Integrates with Helm charts so you can deploy common applications easily.
6. Security and policy – Includes centralized policies, pod security policies, network policies, and security scanning integrations.
   In short: Rancher makes Kubernetes easier to operate and manage at scale, especially if you have multiple clusters.

2. Vanilla Kubernetes
   When we say “vanilla Kubernetes”, we mean a Kubernetes cluster installed using kubeadm, kops, or cloud-managed Kubernetes (EKS, GKE, AKS) without any extra management layer.
   Characteristics:
* You manage the control plane and nodes directly.
* All operations (upgrade, scaling, backup, RBAC) are done manually or scripted by you.
* You get full control, but also full responsibility for maintenance.
* No built-in UI — you can optionally install the Kubernetes Dashboard.

3. Rancher vs Vanilla Kubernetes
   Feature	Vanilla Kubernetes	Rancher
   Cluster installation	Manual (kubeadm) or cloud-managed	Rancher can provision clusters automatically
   Multi-cluster management	Not built-in	Native multi-cluster dashboard
   UI & monitoring	Kubernetes Dashboard (basic)	Full-featured, multi-cluster UI, workload monitoring, metrics
   Authentication	Kubernetes RBAC only	Centralized RBAC, SSO, LDAP, AD across clusters
   Upgrades	Manual	Rancher can coordinate cluster upgrades (control plane + nodes)
   App deployment	Helm, kubectl	Integrated Helm catalog with UI
   Learning curve	Steep	Lower, because UI & automation simplify common tasks
   Customization	Full control	Slightly opinionated; works with multiple clusters and providers
4. How Rancher fits in a workflow
   Think of Rancher as a management layer that makes vanilla Kubernetes clusters easier to:
* deploy,
* monitor,
* secure,
* upgrade,
* manage multiple clusters.
  Rancher does not replace Kubernetes, it orchestrates and enhances it. You can still use kubectl directly on the clusters managed by Rancher.
  Example:
* Vanilla: You install a cluster with kubeadm, upgrade nodes manually, backup etcd manually.
* Rancher: You click “Upgrade cluster” in the UI, Rancher upgrades control plane and nodes safely, and keeps a backup snapshot of etcd automatically.

5. When to use Rancher vs vanilla Kubernetes
   Use Rancher if:
* You manage multiple clusters.
* You want centralized authentication and RBAC.
* You want a UI for operations, monitoring, and app deployment.
* You want automation for upgrades, backups, and security policies.
  Use vanilla Kubernetes if:
* You want full control over every aspect of cluster setup.
* You are running a single cluster and are comfortable managing it manually.
* You want minimal dependencies.

✅ In short: Rancher = management and orchestration layer on top of Kubernetes. Vanilla Kubernetes = the raw platform itself. Rancher adds convenience, security, and multi-cluster capabilities.

If you want, I can also draw a diagram showing the difference visually between vanilla Kubernetes and a Rancher-managed multi-cluster setup — it makes it super clear.
Do you want me to do that?


https://podman.io/
https://github.com/containers/buildah

## Argo CD on Vanilla Kubernetes 

[Argo CD](https://argo-cd.readthedocs.io/) is a declarative GitOps continuous delivery tool for Kubernetes.  
It continuously monitors Git repositories and ensures the Kubernetes cluster state matches the desired state stored in Git.

This tutorial covers:

1. Install Argo CD
2. Access Argo CD UI/API
3. Install Argo CD CLI
4. Deploy an Application from Git
5. Sync & Manage Applications
6. (Optional) Namespace & RBAC

---

## 1. Prerequisites

- Vanilla Kubernetes cluster (e.g., kubeadm, kind, minikube, k3s, etc.)
- `kubectl` configured
- (Optional) GitHub/GitLab repository with Kubernetes manifests

---

## 2. Install Argo CD

### Step 1: Create namespace
```bash
kubectl create namespace argocd
````

### Step 2: Install Argo CD

```bash
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
```

This deploys all Argo CD components in the `argocd` namespace.

---

## 3. Access Argo CD UI/API

By default, Argo CD API server is a **ClusterIP** service.

### Option A: Port-forward (for local clusters)

```bash
kubectl port-forward svc/argocd-server -n argocd 8080:443
```

Now open: [https://localhost:8080](https://localhost:8080)

### Option B: Change to LoadBalancer or NodePort

```bash
kubectl patch svc argocd-server -n argocd \
  -p '{"spec": {"type": "NodePort"}}'
```

Check service:

```bash
kubectl get svc -n argocd argocd-server
```

---

## 4. Login to Argo CD

### Step 1: Get initial admin password

```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d
```

### Step 2: Login (via CLI or UI)

#### CLI:

```bash
argocd login <ARGOCD_SERVER>
# Example (port-forwarded):
argocd login localhost:8080 --username admin --password <password> --insecure
```

#### UI:

Go to `https://<ARGOCD_SERVER>` → login as `admin` with the password.

---

## 5. Install Argo CD CLI

Download from [releases](https://github.com/argoproj/argo-cd/releases):

```bash
# Linux
wget https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-amd64 -O argocd
chmod +x argocd
sudo mv argocd /usr/local/bin/
```

Verify:

```bash
argocd version
```

---

## 6. Deploy an App with Argo CD

### Step 1: Prepare a Git repo

Example repo structure:

```
gitops-demo/
  ├── nginx/
  │    └── deployment.yaml
  │    └── service.yaml
```

Push this repo to GitHub/GitLab.

### Step 2: Register the Git repo

```bash
argocd repo add https://github.com/<user>/gitops-demo.git
```

### Step 3: Create Argo CD application

```bash
argocd app create nginx-app \
  --repo https://github.com/<user>/gitops-demo.git \
  --path nginx \
  --dest-server https://kubernetes.default.svc \
  --dest-namespace default
```

### Step 4: Sync the application

```bash
argocd app sync nginx-app
```

Now `nginx-app` is deployed from Git into Kubernetes.

---

## 7. Verify Deployment

Check resources in Kubernetes:

```bash
kubectl get pods,svc -n default
```

Check application status in Argo CD UI:

* Healthy ✅ → Deployment matches Git
* OutOfSync ⚠️ → Changes detected in Git or cluster

---

## 8. GitOps Workflow

* Edit manifests in Git (e.g., change Nginx image).
* Commit & push to repo.
* Argo CD detects change → marks app **OutOfSync**.
* Either:

    * Manually sync (`argocd app sync nginx-app`)
    * Or enable **auto-sync**:

      ```bash
      argocd app set nginx-app --sync-policy automated
      ```

---

## 9. (Optional) Namespace-Scoped Argo CD

If you want teams to manage their own apps:

* Install **Argo CD in each namespace** or
* Use **AppProjects** + RBAC rules.

Example: create a project `team-a` that allows apps only in `team-a` namespace.

```yaml
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: team-a
  namespace: argocd
spec:
  destinations:
  - namespace: team-a
    server: https://kubernetes.default.svc
  sourceRepos:
  - '*'
```


## 1. How images are stored in Kubernetes

* Kubernetes **doesn’t store images itself**; images are stored on each **node** by the container runtime (Docker, containerd, or CRI-O).
* When a Pod is scheduled on a node:

    1. Kubelet checks if the image exists locally.
    2. If not, the runtime pulls the image from the registry.
* Each node may have multiple images for different Pods, versions, or tags.

---

## 2. Automatic image cleanup in Kubernetes (garbage collection)

**Kubelet** is responsible for cleaning up unused images and containers. It uses **image and container garbage collection**:

### 2.1 Kubelet flags controlling cleanup

| Flag                                      | Description                                                                |
| ----------------------------------------- | -------------------------------------------------------------------------- |
| `--image-gc-high-threshold`               | Node disk usage % at which kubelet starts garbage collection (default 85%) |
| `--image-gc-low-threshold`                | Node disk usage % to stop garbage collection (default 80%)                 |
| `--maximum-dead-containers-per-container` | How many dead containers to keep per container type                        |
| `--minimum-container-ttl-duration`        | Minimum age of stopped containers before deletion                          |

**Mechanism:**

* When disk usage > high threshold → kubelet deletes **unused images** until usage < low threshold.
* Only **images not currently used by running containers** are deleted.

---

## 3. How to clean up images manually

### 3.1 With Docker

```bash
# List all images
docker images -a

# Remove a specific image
docker rmi <IMAGE_ID_OR_NAME>

# Remove unused images (dangling)
docker image prune

# Remove all unused images (dangling + unreferenced)
docker image prune -a

# Check disk usage
docker system df
```

### 3.2 With containerd (common in modern Kubernetes)

```bash
# List images
sudo crictl images

# Remove an image
sudo crictl rmi <IMAGE_NAME>

# Remove all unused images
sudo crictl image prune
```

> Note: `crictl` talks directly to the container runtime (CRI).


## Harbor as Private Image Repository with Kubernetes (CRI-O Runtime)

## 1. Prerequisites

- Linux server with:
    - **Docker** & **Docker Compose**
    - **Harbor installer**
- **Kubernetes cluster** using **CRI-O runtime**
- **kubectl** configured
- (Optional) `/etc/hosts` entry for `harbor.local`

---

## 2. Install Harbor

### Step 1: Download Harbor
```bash
wget https://github.com/goharbor/harbor/releases/download/v2.10.0/harbor-online-installer-v2.10.0.tgz
tar xzvf harbor-online-installer-v2.10.0.tgz
cd harbor

### Step 2: Configure Harbor

```bash
cp harbor.yml.tmpl harbor.yml
```

Edit `harbor.yml`:

#### Option A: Development (HTTP only)

```yaml
hostname: harbor.local
http:
  port: 8080
harbor_admin_password: "Harbor12345"
```

#### Option B: Production (HTTPS with certs)

```yaml
hostname: harbor.local
https:
  port: 443
  certificate: /data/certs/harbor.crt
  private_key: /data/certs/harbor.key
harbor_admin_password: "Harbor12345"
```

### Step 3: Install Harbor

```bash
./install.sh
```

---

## 3. Configure Harbor

1. Login to Harbor web UI:

    * **User**: `admin`
    * **Password**: `Harbor12345`
2. Create a **project** called `demo`

    * Choose **public** (test) or **private** (requires auth).

---

## 4. Push Images to Harbor

On your workstation:

```bash
docker login harbor.local:8080    # for HTTP setup
# OR
docker login harbor.local        # for HTTPS setup

docker pull nginx:latest
docker tag nginx:latest harbor.local:8080/demo/nginx:latest   # HTTP
docker tag nginx:latest harbor.local/demo/nginx:latest        # HTTPS
docker push harbor.local:8080/demo/nginx:latest
```

---

## 5. Configure CRI-O to Trust Harbor

### Case A: Harbor with HTTP (dev/test)

By default, CRI-O only accepts **HTTPS** registries. For testing with **HTTP**, mark Harbor as **insecure**.

Edit `/etc/containers/registries.conf` (or a file in `/etc/containers/registries.conf.d/`):

```toml
unqualified-search-registries = ["harbor.local:443", "docker.io"]

[[registry]]
prefix = "harbor.local:443"
location = "harbor.local:443"
insecure = true
blocked = false
```

Restart CRI-O:

```bash
sudo systemctl restart crio
```

---

### Case B: Harbor with HTTPS (prod-ready)

If Harbor uses **TLS**, you must trust the certificate on all CRI-O nodes.

#### Step 1: Generate self-signed cert

```bash
mkdir -p /data/certs
cd /data/certs

openssl req -newkey rsa:4096 -nodes -sha256 -keyout harbor.key \
  -x509 -days 365 -out harbor.crt \
  -subj "/C=US/ST=CA/L=SanFrancisco/O=DemoOrg/OU=IT/CN=harbor.local"
```

#### Step 2: Place cert in Harbor config

Update `harbor.yml` to point to `/data/certs/harbor.crt` and `/data/certs/harbor.key`.

Re-run:

```bash
./install.sh --with-notary --with-trivy
```

#### Step 3: Distribute cert to Kubernetes nodes

Copy cert to CRI-O trust store on **each node**:

```bash
sudo mkdir -p /etc/pki/ca-trust/source/anchors/
sudo cp harbor.crt /etc/pki/ca-trust/source/anchors/
sudo update-ca-trust
sudo systemctl restart crio
```

Now CRI-O trusts Harbor’s TLS certificate.

---

## 6. Create Kubernetes Secret for Harbor

If your Harbor project is **private**, create a secret:

```bash
kubectl create secret docker-registry harbor-secret \
  --docker-server=harbor.local:8080 \   # for HTTP
  --docker-server=harbor.local \        # for HTTPS
  --docker-username=admin \
  --docker-password=Harbor12345 \
  --docker-email=admin@local \
  -n default
```

---

## 7. Deploy Pods Using Harbor Images

### Option A: Use Secret per Pod

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: nginx-harbor
spec:
  containers:
  - name: nginx
    image: harbor.local:8080/demo/nginx:latest  # HTTP
    # image: harbor.local/demo/nginx:latest     # HTTPS
  imagePullSecrets:
  - name: harbor-secret
```

Apply it:

```bash
kubectl apply -f nginx-pod.yaml
```

### Option B: Use Secret Namespace-Wide

Patch the default service account:

```bash
kubectl patch serviceaccount default \
  -p '{"imagePullSecrets": [{"name": "harbor-secret"}]}' \
  -n default
```
