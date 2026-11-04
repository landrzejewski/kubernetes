# Kubernetes Hands-on Labs

Self-study, scenario-driven labs for the training cluster built in
[00 - Training Cluster Installation Guide](../00%20-%20Training%20Cluster%20Installation%20Guide.md).
Every lab starts with a short **Scenario** (what problem we solve and why), continues with guided **Steps**
(commands, manifests, expected output), and ends with a **Your turn** task with a hidden **Solution**.
Try the task on your own before you expand the solution.

## Modules

<!-- INDEX:BEGIN -->
| # | Module | Topics |
|---|--------|--------|
| 01 | [Pods, Workloads, Deployments](01-pods-workloads-deployments.md) | troubleshooting, probes, sidecars, resources, rollouts, Jobs, DaemonSets, StatefulSets, debugging |
| 02 | [Services & Network Policies](02-services-network-policies.md) | ClusterIP/NodePort/LoadBalancer, DNS, EndpointSlices, external services, zero-trust networking |
| 03 | [Gateway API](03-gateway-api.md) | Gateway/HTTPRoute, host/path/header routing, TLS, filters, multi-tenancy, ReferenceGrant |
| 04 | [Storage](04-storage.md) | emptyDir (disk/memory), hostPath, static/local PVs, StatefulSet volumes, S3 (MinIO) volumes and backups |
| 05 | [ConfigMaps & Secrets](05-configmaps-secrets.md) | config files & env, reloads, Secret types, projected volumes, generators, encryption at rest |
| 06 | [Security](06-security-rbac.md) | ServiceAccounts, users & certificates, RBAC, Pod Security, securityContext, quotas, admission policies |
| 07 | [Release Strategies, Autoscaling & Scheduling](07-release-strategies-autoscaling-scheduling.md) | blue/green & canary with Gateway API, HPA/VPA, in-place resize, node selection, taints, affinity, spreading |
| 08 | [End-to-end Scenarios](08-end-to-end-scenarios.md) | larger scenarios combining everything above |
<!-- INDEX:END -->

## Lab environment

| Machine | IP | Role in the labs |
|---------|----|------------------|
| `master` | 192.168.1.10 | control plane (kubeadm, CRI-O, Calico) |
| `node1` | 192.168.1.11 | worker |
| `node2` | 192.168.1.12 | worker |
| `debian` / admin VM | 192.168.1.100 | **client VM**: external client inside the cluster network, runs MinIO (S3) in Docker |

Cluster add-ons the labs rely on (install them as described in [k8s/kubernets.md](../k8s/kubernets.md) and
[k8s/config-and-storage/minio](../k8s/config-and-storage/minio/setup-minio.md)):

| Add-on | Details |
|--------|---------|
| Kubernetes | v1.37, full `cluster-admin` access |
| MetalLB | L2 mode, address pool `192.168.1.240-192.168.1.250` |
| Gateway API | v1.7.0 standard CRDs |
| NGINX Gateway Fabric | GatewayClass `nginx`; every `Gateway` gets its own `<gateway-name>-nginx` Deployment and LoadBalancer Service |
| metrics-server | [k8s/pod-autoscaler/metrics-server.yml](../k8s/pod-autoscaler/metrics-server.yml) (`kubectl top` works) |
| MinIO (S3) | `http://192.168.1.100:9000`, console `http://192.168.1.100:9001`, user `minioadmin` / `minioadmin123` |
| csi-s3 | StorageClass `minio-sc` (bucket `training-bucket`, ReadWriteMany) |

There is **no dynamic block-storage provisioner** in this cluster: labs that need disk-backed persistent volumes
create static (hostPath / local) PersistentVolumes themselves.

### Quick prerequisites check

```bash
kubectl get nodes                                   # 3 nodes Ready, v1.37.x
kubectl get gatewayclass nginx                      # ACCEPTED=True
kubectl get ipaddresspool -n metallb-system         # 192.168.1.240-192.168.1.250
kubectl get storageclass minio-sc                   # provisioner ru.yandex.s3.csi
kubectl top nodes                                   # metrics-server works
curl -s http://192.168.1.100:9000/minio/health/live -o /dev/null -w '%{http_code}\n'   # run on the client VM: 200
```

## Conventions

- **Two terminals.** Commands prefixed with `workstation$` run wherever your `kubectl` is configured.
  Commands prefixed with `client-vm$` run on the client VM `192.168.1.100`, which sits in the cluster network
  and can reach NodePorts, MetalLB and Gateway addresses. If your kubectl runs on the client VM itself,
  both terminals are the same machine.
- Commands prefixed with `master$`, `node1$` or `node2$` run on that node over SSH (`ssh k8s@192.168.1.11` etc.),
  usually with `sudo`.
- **One namespace per lab** (`lab-01-03` = module 01, lab 3). Every lab begins by creating it and ends with
  `kubectl delete namespace …`. Labs are independent, so you can do them in any order (unless a lab says otherwise).
- Manifests are inline (`kubectl apply -f - <<'EOF' … EOF`), so you can copy and paste them. Saving them to files is
  a good habit, too.
- `Expected:` blocks show trimmed real output. Names with random suffixes, IPs and ages will differ.
- Labs that change nodes or the control plane (labels, taints, drains, stopping the kubelet, API server flags) are marked
  **⚠ cluster-wide**. Always run their *Clean up* section.
- Only public images with pinned tags are used, for example `ghcr.io/stefanprodan/podinfo:6.17.0`,
  `traefik/whoami:v1.12.0`, `nginx:1.31-alpine`, `nginxinc/nginx-unprivileged:1.31-alpine`, `redis:8.8`, `postgres:17`,
  `busybox:1.38`, `curlimages/curl:8.23.0`, `nicolaka/netshoot:v0.16`, `alpine/k8s:1.37.1` (kubectl, helm, jq) and
  `pgsty/mc:RELEASE.2026-10-26T00-00-00Z` (MinIO client).

### Handy aliases

```bash
alias k=kubectl
export do='--dry-run=client -o yaml'      # k create deploy x --image=nginx $do
kns() { kubectl config set-context --current --namespace="$1"; }   # switch default namespace
```

### Lab structure

```
## Lab N.M: <title>
Scenario            – the real-world problem
What you'll learn   – concepts
Steps               – guided walk-through with verification
Clean up
Your turn           – follow-up task
Solution            – collapsed, click to expand
```
