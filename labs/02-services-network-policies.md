# Module 02: Services & Network Policies

Pods come and go, and their IPs change every time. Services give them a stable name and a virtual IP, EndpointSlices
track which Pods are behind it, and NetworkPolicies decide who may talk to whom. In this module you will expose apps
inside and outside the cluster, wire up external systems, and lock the network down to a zero-trust model, using
Calico (which enforces NetworkPolicy in this cluster) and MetalLB.

## Prerequisites check

```bash
workstation$ kubectl get nodes                                      # 3 nodes Ready
workstation$ kubectl get ipaddresspool -n metallb-system            # 192.168.1.240-192.168.1.250
workstation$ kubectl -n kube-system get ds calico-node              # 3/3 ready, Calico enforces NetworkPolicy
workstation$ kubectl -n kube-system get svc kube-dns                # CoreDNS on 10.96.0.10
client-vm$   curl -s -o /dev/null -w '%{http_code}\n' http://192.168.1.100:9000/minio/health/live   # 200
```

## Table of contents

- [Lab 2.1: The shop cannot find the catalog: ClusterIP, DNS and EndpointSlices](#lab-21-the-shop-cannot-find-the-catalog-clusterip-dns-and-endpointslices)
- [Lab 2.2: Exposing an app to the outside world: NodePort, LoadBalancer and the lost client IP](#lab-22-exposing-an-app-to-the-outside-world-nodeport-loadbalancer-and-the-lost-client-ip)
- [Lab 2.3: Peer discovery for a clustered app with a headless Service](#lab-23-peer-discovery-for-a-clustered-app-with-a-headless-service)
- [Lab 2.4: Bringing a legacy system outside the cluster into service discovery](#lab-24-bringing-a-legacy-system-outside-the-cluster-into-service-discovery)
- [Lab 2.5: Sticky sessions and node-local traffic](#lab-25-sticky-sessions-and-node-local-traffic)
- [Lab 2.6: Default deny and the DNS egress gotcha](#lab-26-default-deny-and-the-dns-egress-gotcha)
- [Lab 2.7: Zero-trust networking for a three-tier app](#lab-27-zero-trust-networking-for-a-three-tier-app)
- [Lab 2.8: Letting monitoring in: namespaceSelector and podSelector, AND vs OR](#lab-28-letting-monitoring-in-namespaceselector-and-podselector-and-vs-or)
- [Lab 2.9: Egress lockdown: the backup job may only talk to S3](#lab-29-egress-lockdown-the-backup-job-may-only-talk-to-s3)
- [Lab 2.10: Admin panel reachable only from the office network](#lab-210-admin-panel-reachable-only-from-the-office-network)

---

## Lab 2.1: The shop cannot find the catalog: ClusterIP, DNS and EndpointSlices

**Scenario** – The `catalog` team runs its API in namespace `lab-02-01`, the `shop` frontend lives in
`lab-02-01-shop`. The shop developers configured `http://catalog` as the backend URL, and it works on their laptop
with docker-compose but fails in the cluster. You will find out why, learn how Service DNS names and search domains
work, see how EndpointSlices track the Pods behind a Service, and debug the classic "Service with no endpoints".

**What you'll learn**
- How a ClusterIP Service load-balances across Pods and how it is named in DNS (`<svc>.<ns>.svc.cluster.local`)
- Search domains and `ndots:5` in `/etc/resolv.conf`, and why short names only work inside the same namespace
- Reading EndpointSlices, named `targetPort`s and the "selector does not match" pitfall
- Why Service environment variables are not a discovery mechanism you should rely on

### Steps

1. Create both namespaces and deploy the catalog API (podinfo) with a Service. The Service port `80` maps to the
   container port **by name** (`targetPort: http`), so the container port can change without touching the Service.

   ```bash
   workstation$ kubectl create namespace lab-02-01
   workstation$ kubectl create namespace lab-02-01-shop
   workstation$ kubectl apply -f - <<'EOF'
   apiVersion: apps/v1
   kind: Deployment
   metadata:
     name: catalog
     namespace: lab-02-01
   spec:
     replicas: 3
     selector:
       matchLabels:
         app: catalog
     template:
       metadata:
         labels:
           app: catalog
       spec:
         containers:
         - name: podinfo
           image: ghcr.io/stefanprodan/podinfo:6.17.0
           command: ["./podinfo", "--port=9898"]
           ports:
           - name: http
             containerPort: 9898
           readinessProbe:
             httpGet:
               path: /readyz
               port: http
   ---
   apiVersion: v1
   kind: Service
   metadata:
     name: catalog
     namespace: lab-02-01
   spec:
     selector:
       app: catalog
     ports:
     - name: http
       port: 80
       targetPort: http
   EOF
   workstation$ kubectl -n lab-02-01 rollout status deploy/catalog
   workstation$ kubectl -n lab-02-01 get svc,pods -o wide
   ```

   Expected:
   ```
   NAME              TYPE        CLUSTER-IP      EXTERNAL-IP   PORT(S)   AGE   SELECTOR
   service/catalog   ClusterIP   10.104.238.98   <none>        80/TCP    3s    app=catalog

   NAME                          READY   STATUS    RESTARTS   AGE   IP               NODE
   pod/catalog-975db8587-4wkpf   1/1     Running   0          3s    172.16.104.27    node2
   pod/catalog-975db8587-82zp2   1/1     Running   0          3s    172.16.166.150   node1
   pod/catalog-975db8587-dcqjl   1/1     Running   0          3s    172.16.104.26    node2
   ```

2. Look at the EndpointSlice. This is what kube-proxy actually programs into iptables: the ClusterIP is only a
   virtual address, the real destinations are these Pod IPs on port 9898.

   ```bash
   workstation$ kubectl -n lab-02-01 get endpointslices -l kubernetes.io/service-name=catalog
   workstation$ kubectl -n lab-02-01 get endpointslices -l kubernetes.io/service-name=catalog -o yaml | grep -A12 'addresses:' | head -14
   ```

   Expected:
   ```
   NAME            ADDRESSTYPE   PORTS   ENDPOINTS                                    AGE
   catalog-4njjh   IPv4          9898    172.16.104.26,172.16.104.27,172.16.166.150   8s

     - addresses:
       - 172.16.104.26
       conditions:
         ready: true
         serving: true
         terminating: false
       nodeName: node2
       targetRef:
         kind: Pod
         name: catalog-975db8587-dcqjl
   ```

   Why: each endpoint carries its readiness (`ready`/`serving`/`terminating`) and its node. Only `ready` endpoints
   receive new traffic; `nodeName` is used by traffic policies (Labs 2.2 and 2.5).

3. Start a debug shell in the shop namespace and reproduce the bug.

   ```bash
   workstation$ kubectl -n lab-02-01-shop run shell --image=nicolaka/netshoot:v0.16 --command -- sleep infinity
   workstation$ kubectl -n lab-02-01-shop wait --for=condition=Ready pod/shell
   workstation$ kubectl -n lab-02-01-shop exec shell -- curl -sS -m 3 http://catalog/
   workstation$ kubectl -n lab-02-01-shop exec shell -- cat /etc/resolv.conf
   ```

   Expected:
   ```
   curl: (6) Could not resolve host: catalog
   command terminated with exit code 6

   search lab-02-01-shop.svc.cluster.local svc.cluster.local cluster.local
   nameserver 10.96.0.10
   options ndots:5
   ```

   Why: a short name is expanded with the search domains, the first being *the Pod's own namespace*. `catalog` becomes
   `catalog.lab-02-01-shop.svc.cluster.local`, which does not exist. Short names only work inside the same namespace.

4. Use the namespace-qualified name and watch the resolver walk the search list.

   ```bash
   workstation$ kubectl -n lab-02-01-shop exec shell -- dig +search +showsearch catalog.lab-02-01 | grep -E '^;catalog|status:'
   workstation$ kubectl -n lab-02-01-shop exec shell -- sh -c 'for i in 1 2 3 4 5 6; do curl -s http://catalog.lab-02-01/ | grep hostname; done'
   ```

   Expected:
   ```
   ;; ->>HEADER<<- opcode: QUERY, status: NXDOMAIN, id: 15014
   ;catalog.lab-02-01.lab-02-01-shop.svc.cluster.local. IN A
   ;; ->>HEADER<<- opcode: QUERY, status: NOERROR, id: 31640
   ;catalog.lab-02-01.svc.cluster.local. IN	A

     "hostname": "catalog-975db8587-4wkpf",
     "hostname": "catalog-975db8587-82zp2",
     "hostname": "catalog-975db8587-4wkpf",
     "hostname": "catalog-975db8587-4wkpf",
     "hostname": "catalog-975db8587-4wkpf",
     "hostname": "catalog-975db8587-82zp2",
   ```

   Why: `catalog.lab-02-01` has fewer than 5 dots (`ndots:5`), so the resolver tries every search domain first: the
   first lookup fails with NXDOMAIN, the second one hits. Each name with < 5 dots costs extra DNS queries, which is
   why high-traffic apps use the FQDN with a trailing dot (`catalog.lab-02-01.svc.cluster.local.`). Load balancing is
   random per connection (iptables mode), not strict round robin.

5. Scale the catalog and watch the EndpointSlice follow.

   ```bash
   workstation$ kubectl -n lab-02-01 scale deploy catalog --replicas=5
   workstation$ kubectl -n lab-02-01 get endpointslices -l kubernetes.io/service-name=catalog
   ```

   Expected:
   ```
   NAME            ADDRESSTYPE   PORTS   ENDPOINTS                                                AGE
   catalog-4njjh   IPv4          9898    172.16.104.26,172.16.104.27,172.16.166.150 + 2 more...   25s
   ```

6. The second classic: "the Service exists but nothing answers". A colleague creates `catalog-v2` imperatively.
   `kubectl create service` sets the selector to `app=<service-name>`, which matches no Pod.

   ```bash
   workstation$ kubectl -n lab-02-01 create service clusterip catalog-v2 --tcp=80:9898
   workstation$ kubectl -n lab-02-01-shop exec shell -- curl -sS -m 3 http://catalog-v2.lab-02-01/
   workstation$ kubectl -n lab-02-01 describe svc catalog-v2 | grep -E 'Selector|Endpoints'
   workstation$ kubectl -n lab-02-01 get endpointslices -l kubernetes.io/service-name=catalog-v2
   ```

   Expected:
   ```
   curl: (7) Failed to connect to catalog-v2.lab-02-01:80 after 36 ms: Could not connect to server

   Selector:                 app=catalog-v2
   Endpoints:

   NAME               ADDRESSTYPE   PORTS     ENDPOINTS   AGE
   catalog-v2-4845h   IPv4          <unset>   <unset>     0s
   ```

   Why: DNS works (the Service exists), but kube-proxy has no endpoint to forward to, so it actively rejects the
   connection ("Could not connect" immediately, not a timeout). Empty endpoints = check the selector and Pod
   readiness first. Fix the selector:

   ```bash
   workstation$ kubectl -n lab-02-01 set selector svc catalog-v2 app=catalog
   workstation$ kubectl -n lab-02-01-shop exec shell -- curl -sS http://catalog-v2.lab-02-01/version
   ```

   Expected:
   ```
   {
     "commit": "fd3a834ed8d14b80ea334cf8a2fddd4597924da6",
     "version": "6.17.0"
   }
   ```

   If you are very quick you may still get one more "Could not connect": kube-proxy needs a moment to sync.

7. Service environment variables: the kubelet injects `<SVC>_SERVICE_HOST/PORT` only for Services in the **same
   namespace** that existed **before** the Pod started.

   ```bash
   workstation$ kubectl -n lab-02-01 run envcheck --image=busybox:1.38 --restart=Never --rm -it -- sh -c 'env | grep ^CATALOG_SERVICE'
   workstation$ kubectl -n lab-02-01-shop exec shell -- sh -c 'env | grep -c CATALOG'
   ```

   Expected:
   ```
   CATALOG_SERVICE_HOST=10.104.238.98
   CATALOG_SERVICE_PORT=80
   CATALOG_SERVICE_PORT_HTTP=80

   0
   ```

   Why: use DNS. Environment variables are a legacy Docker-links feature and are a startup-order trap.

### Clean up

```bash
workstation$ kubectl delete namespace lab-02-01 lab-02-01-shop
```

### Your turn

The observability team wants to scrape catalog metrics through the same Service, and their scraper discovers the
port with a DNS **SRV** query instead of a hard-coded number. Start podinfo with `--port-metrics=9797`, expose it
as a second Service port called `metrics`, and prove that `_metrics._tcp.catalog.lab-02-01.svc.cluster.local`
returns port 9797 and that `/metrics` answers through the Service. While the Deployment rolls out, list the
EndpointSlices again: what do you notice?

<details>
<summary>Solution</summary>

Re-run steps 1 and 3 if you already cleaned up. Then apply the extended Deployment and Service. A Service with more
than one port must name every port, and the SRV record name is built from that port name and protocol.

```bash
workstation$ kubectl apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: catalog
  namespace: lab-02-01
spec:
  replicas: 3
  selector:
    matchLabels:
      app: catalog
  template:
    metadata:
      labels:
        app: catalog
    spec:
      containers:
      - name: podinfo
        image: ghcr.io/stefanprodan/podinfo:6.17.0
        command: ["./podinfo", "--port=9898", "--port-metrics=9797"]
        ports:
        - name: http
          containerPort: 9898
        - name: metrics
          containerPort: 9797
        readinessProbe:
          httpGet:
            path: /readyz
            port: http
---
apiVersion: v1
kind: Service
metadata:
  name: catalog
  namespace: lab-02-01
spec:
  selector:
    app: catalog
  ports:
  - name: http
    port: 80
    targetPort: http
  - name: metrics
    port: 9797
    targetPort: metrics
EOF
workstation$ kubectl -n lab-02-01 get endpointslices -l kubernetes.io/service-name=catalog
```

Expected (during the rollout):
```
NAME            ADDRESSTYPE   PORTS       ENDPOINTS                                     AGE
catalog-4njjh   IPv4          9898        172.16.104.27,172.16.166.150,172.16.166.152   63s
catalog-m6xtf   IPv4          9797,9898   172.16.166.156,172.16.104.32,172.16.166.157   3s
```

An EndpointSlice groups endpoints that share **the same set of ports**. Old Pods have no `metrics` port, so they get a
separate slice; when the rollout finishes only `catalog-m6xtf` (9797,9898) remains.

Verify:
```bash
workstation$ kubectl -n lab-02-01-shop exec shell -- dig +short SRV _metrics._tcp.catalog.lab-02-01.svc.cluster.local
workstation$ kubectl -n lab-02-01-shop exec shell -- dig +short SRV _http._tcp.catalog.lab-02-01.svc.cluster.local
workstation$ kubectl -n lab-02-01-shop exec shell -- sh -c 'curl -s http://catalog.lab-02-01:9797/metrics | grep -m2 ^http_request'
```

Expected:
```
0 100 9797 catalog.lab-02-01.svc.cluster.local.
0 100 80 catalog.lab-02-01.svc.cluster.local.
http_request_duration_seconds_bucket{method="GET",path="readyz",status="200",le="0.005"} 1
http_request_duration_seconds_bucket{method="GET",path="readyz",status="200",le="0.01"} 1
```

Clean up with `kubectl delete namespace lab-02-01 lab-02-01-shop`.
</details>

---

## Lab 2.2: Exposing an app to the outside world: NodePort, LoadBalancer and the lost client IP

**Scenario** – The security team wants the "who is calling" audit log of the new `whoami` edge service to contain
real client IPs. The first version was exposed with a NodePort, then with a MetalLB LoadBalancer, and in both cases
the log shows strange `172.16.x.x` and node addresses instead of the office machine (the client VM `192.168.1.100`).
You will see how external traffic is forwarded and SNATed, and fix it with `externalTrafficPolicy: Local`,
including the trade-offs that come with it.

**What you'll learn**
- How a NodePort opens the same port on *every* node and forwards to Pods on *any* node
- How MetalLB (L2 mode) assigns an IP and which node answers ARP for it
- Why `externalTrafficPolicy: Cluster` hides the client IP (SNAT) and how `Local` preserves it
- The cost of `Local`: nodes without a local Pod drop traffic, and the `healthCheckNodePort` that load balancers use

### Steps

1. Deploy a single replica of `traefik/whoami` (it echoes the TCP peer address as `RemoteAddr`) behind a NodePort.

   ```bash
   workstation$ kubectl create namespace lab-02-02
   workstation$ kubectl apply -f - <<'EOF'
   apiVersion: apps/v1
   kind: Deployment
   metadata:
     name: whoami
     namespace: lab-02-02
   spec:
     replicas: 1
     selector:
       matchLabels:
         app: whoami
     template:
       metadata:
         labels:
           app: whoami
       spec:
         containers:
         - name: whoami
           image: traefik/whoami:v1.12.0
           ports:
           - name: http
             containerPort: 80
   ---
   apiVersion: v1
   kind: Service
   metadata:
     name: whoami
     namespace: lab-02-02
   spec:
     type: NodePort
     selector:
       app: whoami
     ports:
     - name: http
       port: 80
       targetPort: http
   EOF
   workstation$ kubectl -n lab-02-02 get svc whoami
   workstation$ kubectl -n lab-02-02 get pods -o wide
   ```

   Expected:
   ```
   NAME     TYPE       CLUSTER-IP     EXTERNAL-IP   PORT(S)        AGE
   whoami   NodePort   10.96.206.64   <none>        80:31380/TCP   1s

   NAME                      READY   STATUS    RESTARTS   AGE   IP              NODE
   whoami-65b8985959-pb269   1/1     Running   0          2s    172.16.104.39   node2
   ```

   Note your node port (here `31380`) and the node that runs the Pod (here `node2`).

2. From the client VM, call the NodePort on every node, including the control-plane node.

   ```bash
   client-vm$ NP=31380      # your node port
   client-vm$ for n in 192.168.1.10 192.168.1.11 192.168.1.12; do echo "== $n"; curl -s -m 3 http://$n:$NP/ | grep -E 'Hostname|RemoteAddr'; done
   ```

   Expected:
   ```
   == 192.168.1.10
   Hostname: whoami-65b8985959-pb269
   RemoteAddr: 172.16.219.64:64040
   == 192.168.1.11
   Hostname: whoami-65b8985959-pb269
   RemoteAddr: 172.16.166.128:21439
   == 192.168.1.12
   Hostname: whoami-65b8985959-pb269
   RemoteAddr: 192.168.1.12:45749
   ```

   Why: every node answers, even the one without the Pod. kube-proxy DNATs the packet to the Pod IP and also
   **SNATs** it to the forwarding node's address, so the reply comes back the same way. Traffic that has to cross to
   node2 leaves through the Calico IPIP tunnel, so the source becomes that node's `tunl0` address (`172.16.219.64` on
   master, `172.16.166.128` on node1). Even on node2 itself the source is rewritten to the node IP.

3. Turn the Service into a LoadBalancer. MetalLB assigns an address from its pool and one node starts answering ARP
   for it.

   ```bash
   workstation$ kubectl -n lab-02-02 patch svc whoami -p '{"spec":{"type":"LoadBalancer"}}'
   workstation$ kubectl -n lab-02-02 get svc whoami
   workstation$ kubectl -n lab-02-02 describe svc whoami | sed -n '/Events/,$p'
   ```

   Expected:
   ```
   NAME     TYPE           CLUSTER-IP     EXTERNAL-IP     PORT(S)        AGE
   whoami   LoadBalancer   10.96.206.64   192.168.1.242   80:31380/TCP   15s

   Events:
     Type    Reason        Age   From                Message
     ----    ------        ----  ----                -------
     Normal  IPAllocated   4s    metallb-controller  Assigned IP ["192.168.1.242"]
     Normal  nodeAssigned  4s    metallb-speaker     announcing from node "node1" with protocol "layer2"
   ```

   Why: a LoadBalancer Service is a NodePort Service plus an external IP. In L2 mode MetalLB elects **one** node to
   own the IP; here it picked node1 although the Pod runs on node2.

4. Call the LoadBalancer IP from the client VM and check who owns it in the ARP table.

   ```bash
   client-vm$ LB=192.168.1.242   # your EXTERNAL-IP
   client-vm$ for i in 1 2 3; do curl -s -m 3 http://$LB/ | grep RemoteAddr; done
   client-vm$ ip neigh show $LB; ip neigh show 192.168.1.11
   ```

   Expected:
   ```
   RemoteAddr: 172.16.166.128:1292
   RemoteAddr: 172.16.166.128:35513
   RemoteAddr: 172.16.166.128:4086
   192.168.1.242 dev enp0s3 lladdr 08:00:27:15:29:b2 REACHABLE
   192.168.1.11 dev enp0s3 lladdr 08:00:27:15:29:b2 REACHABLE
   ```

   The LB IP has node1's MAC address. node1 receives the packet and forwards it (SNATed) to node2. Same problem as
   before: the client IP is lost.

5. Switch to `externalTrafficPolicy: Local`: nodes only forward external traffic to Pods **on the same node**, so no
   SNAT is needed.

   ```bash
   workstation$ kubectl -n lab-02-02 patch svc whoami -p '{"spec":{"externalTrafficPolicy":"Local"}}'
   workstation$ kubectl -n lab-02-02 get svc whoami -o jsonpath='{.spec.externalTrafficPolicy} hc={.spec.healthCheckNodePort}{"\n"}'
   workstation$ kubectl -n lab-02-02 describe svc whoami | sed -n '/Events/,$p'
   client-vm$   for i in 1 2 3; do curl -s -m 3 http://$LB/ | grep RemoteAddr; done
   ```

   Expected:
   ```
   Local hc=30999

     Normal  nodeAssigned  20s   metallb-speaker     announcing from node "node1" with protocol "layer2"
     Normal  nodeAssigned  6s    metallb-speaker     announcing from node "node2" with protocol "layer2"

   RemoteAddr: 192.168.1.100:59670
   RemoteAddr: 192.168.1.100:59682
   RemoteAddr: 192.168.1.100:59698
   ```

   Why: the audit log now shows the real client. MetalLB noticed that only node2 has a local endpoint and moved the
   announcement there, otherwise the traffic would be black-holed.

6. Look at the price of `Local`. NodePorts on nodes without a local Pod no longer work, and a new
   `healthCheckNodePort` tells external load balancers which nodes are usable.

   ```bash
   client-vm$ HC=30999    # your healthCheckNodePort
   client-vm$ for n in 192.168.1.11 192.168.1.12; do echo "== $n"; curl -sS -m 3 http://$n:$NP/ 2>&1 | grep -E 'RemoteAddr|curl'; curl -s -m 3 -w ' HTTP %{http_code}\n' http://$n:$HC/healthz | grep -E 'localEndpoints|HTTP'; done
   ```

   Expected:
   ```
   == 192.168.1.11
   curl: (28) Connection timed out after 3128 milliseconds
   	"localEndpoints": 0,
   } HTTP 503
   == 192.168.1.12
   RemoteAddr: 192.168.1.100:49308
   	"localEndpoints": 1,
   } HTTP 200
   ```

   Pitfalls of `Local`:
   - Load is spread per **node**, not per Pod: a node with 1 Pod gets as much traffic as a node with 10 Pods.
   - During a rollout the Pod can move to another node; until the LB re-checks health, connections can fail.
   - Cloud load balancers use the health check port. MetalLB L2 looks at the endpoints directly.

### Clean up

```bash
workstation$ kubectl delete namespace lab-02-02     # releases the MetalLB IP
```

### Your turn

The security review continues: "Why is port 31380 open on all three nodes when the only entry point is the
LoadBalancer IP? Also, the edge service must listen on port 8080." Change the Service so that **no node ports are
allocated** (`allocateLoadBalancerNodePorts`), it listens on 8080, and it still preserves the client IP. Check that
the old node port is closed and the LB answers on 8080. Is `healthCheckNodePort` still allocated? Why?

<details>
<summary>Solution</summary>

Pitfall first: if you only patch `allocateLoadBalancerNodePorts: false` into the existing Service, the already
allocated `nodePort` stays (`80:31380/TCP`). You must remove the `nodePort` from every port as well, or recreate
the Service. Recreating it declaratively is the cleanest (redo step 1 if you already cleaned up):

```bash
workstation$ kubectl -n lab-02-02 delete svc whoami
workstation$ kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Service
metadata:
  name: whoami
  namespace: lab-02-02
spec:
  type: LoadBalancer
  externalTrafficPolicy: Local
  allocateLoadBalancerNodePorts: false
  selector:
    app: whoami
  ports:
  - name: http
    port: 8080
    targetPort: http
EOF
workstation$ kubectl -n lab-02-02 get svc whoami
workstation$ kubectl -n lab-02-02 get svc whoami -o jsonpath='hc={.spec.healthCheckNodePort}{"\n"}'
```

Expected:
```
NAME     TYPE           CLUSTER-IP      EXTERNAL-IP     PORT(S)    AGE
whoami   LoadBalancer   10.96.178.227   192.168.1.242   8080/TCP   4s
hc=32092
```

Verify from the client VM (`LB` = new EXTERNAL-IP, `HC` = new health check port):
```bash
client-vm$ curl -s -m 3 http://$LB:8080/ | grep -E 'Hostname|RemoteAddr'
client-vm$ curl -sS -m 3 http://192.168.1.12:31380/
client-vm$ curl -s -m 3 http://192.168.1.12:$HC/healthz | grep localEndpoints
```

Expected:
```
Hostname: whoami-65b8985959-pb269
RemoteAddr: 192.168.1.100:54514
curl: (7) Failed to connect to 192.168.1.12 port 31380 after 5 ms: Could not connect to server
	"localEndpoints": 1,
```

The `healthCheckNodePort` is still allocated because it belongs to `externalTrafficPolicy: Local`, not to the
service ports: load balancers need it to find the nodes that have local endpoints. Without node ports, the
load balancer implementation must be able to deliver traffic for the LB IP directly to the nodes, which MetalLB does.
Clean up with `kubectl delete namespace lab-02-02`.
</details>

---

## Lab 2.3: Peer discovery for a clustered app with a headless Service

**Scenario** – A distributed cache (think Hazelcast, Infinispan or a Raft-based store) must find **all** its peers
to form a cluster. With a normal Service each lookup returns one virtual IP and kube-proxy picks a random Pod, so the
members never see each other. You will publish the Pods individually with a headless Service, query A and SRV
records, and learn how readiness interacts with peer discovery during bootstrap.

**What you'll learn**
- The difference between a ClusterIP Service (one VIP, kube-proxy load balancing) and a headless one (`clusterIP: None`, DNS returns Pod IPs)
- SRV and per-Pod records generated for headless Services
- Why not-ready Pods disappear from DNS and when `publishNotReadyAddresses: true` is the right fix
- Giving a single Pod a stable DNS name with `hostname` + `subdomain`

### Steps

1. Deploy three cache members with two Services: `cache` for clients (ClusterIP) and `cache-peers` for the members
   (headless). Both select the same Pods.

   ```bash
   workstation$ kubectl create namespace lab-02-03
   workstation$ kubectl apply -f - <<'EOF'
   apiVersion: apps/v1
   kind: Deployment
   metadata:
     name: cache
     namespace: lab-02-03
   spec:
     replicas: 3
     selector:
       matchLabels:
         app: cache
     template:
       metadata:
         labels:
           app: cache
       spec:
         containers:
         - name: podinfo
           image: ghcr.io/stefanprodan/podinfo:6.17.0
           ports:
           - name: http
             containerPort: 9898
           readinessProbe:
             httpGet:
               path: /readyz
               port: http
             periodSeconds: 2
   ---
   apiVersion: v1
   kind: Service
   metadata:
     name: cache
     namespace: lab-02-03
   spec:
     selector:
       app: cache
     ports:
     - name: http
       port: 80
       targetPort: http
   ---
   apiVersion: v1
   kind: Service
   metadata:
     name: cache-peers
     namespace: lab-02-03
   spec:
     clusterIP: None          # headless
     selector:
       app: cache
     ports:
     - name: http
       port: 9898
       targetPort: http
   EOF
   workstation$ kubectl -n lab-02-03 run shell --image=nicolaka/netshoot:v0.16 --command -- sleep infinity
   workstation$ kubectl -n lab-02-03 rollout status deploy/cache
   workstation$ kubectl -n lab-02-03 get svc
   workstation$ kubectl -n lab-02-03 get pods -l app=cache -o wide
   ```

   Expected:
   ```
   NAME          TYPE        CLUSTER-IP     EXTERNAL-IP   PORT(S)    AGE
   cache         ClusterIP   10.109.29.72   <none>        80/TCP     23s
   cache-peers   ClusterIP   None           <none>        9898/TCP   23s

   NAME                     READY   STATUS    RESTARTS   AGE   IP               NODE
   cache-7549b96f9d-64lsd   1/1     Running   0          23s   172.16.166.183   node1
   cache-7549b96f9d-s2wcj   1/1     Running   0          23s   172.16.166.182   node1
   cache-7549b96f9d-wcqn8   1/1     Running   0          23s   172.16.104.59    node2
   ```

2. Compare the DNS answers.

   ```bash
   workstation$ kubectl -n lab-02-03 exec shell -- dig +short cache.lab-02-03.svc.cluster.local
   workstation$ kubectl -n lab-02-03 exec shell -- dig +short cache-peers.lab-02-03.svc.cluster.local
   workstation$ kubectl -n lab-02-03 exec shell -- dig +short SRV _http._tcp.cache-peers.lab-02-03.svc.cluster.local
   workstation$ kubectl -n lab-02-03 exec shell -- dig +short -x 172.16.166.183      # one of your Pod IPs
   ```

   Expected:
   ```
   10.109.29.72

   172.16.166.182
   172.16.104.59
   172.16.166.183

   0 33 9898 172-16-166-182.cache-peers.lab-02-03.svc.cluster.local.
   0 33 9898 172-16-166-183.cache-peers.lab-02-03.svc.cluster.local.
   0 33 9898 172-16-104-59.cache-peers.lab-02-03.svc.cluster.local.

   172-16-166-183.cache-peers.lab-02-03.svc.cluster.local.
   172-16-166-183.cache.lab-02-03.svc.cluster.local.
   ```

   Why: a headless Service has no virtual IP, kube-proxy ignores it, and CoreDNS answers with one A record per ready
   endpoint. The SRV records give every member a name and the port. Pods of a Deployment get IP-based names
   (`172-16-166-182...`); StatefulSets get stable names like `redis-0.<svc>` (see module 01).

3. Simulate what a cluster member does at startup: resolve the peers and contact each of them directly.

   ```bash
   workstation$ kubectl -n lab-02-03 exec shell -- sh -c 'for ip in $(dig +short cache-peers.lab-02-03.svc.cluster.local); do echo -n "$ip -> "; curl -s http://$ip:9898/ | grep hostname; done'
   ```

   Expected:
   ```
   172.16.166.183 ->   "hostname": "cache-7549b96f9d-64lsd",
   172.16.104.59 ->   "hostname": "cache-7549b96f9d-wcqn8",
   172.16.166.182 ->   "hostname": "cache-7549b96f9d-s2wcj",
   ```

   Pitfall: the client sees all IPs and must do its own balancing and retries. Many clients resolve once and cache
   the result, and CoreDNS answers carry a 30 s TTL, so newly scaled Pods are not seen immediately.

4. Make one member unready (podinfo lets you flip readiness at runtime) and watch it vanish from DNS.

   ```bash
   workstation$ kubectl -n lab-02-03 exec shell -- curl -s -X POST -w '%{http_code}\n' http://172.16.104.59:9898/readyz/disable   # one of your Pod IPs
   workstation$ kubectl -n lab-02-03 get pods -l app=cache
   workstation$ kubectl -n lab-02-03 exec shell -- dig +short cache-peers.lab-02-03.svc.cluster.local
   workstation$ kubectl -n lab-02-03 get endpointslices -l kubernetes.io/service-name=cache-peers \
     -o jsonpath='{range .items[*].endpoints[*]}{.addresses[0]} ready={.conditions.ready}{"\n"}{end}'
   ```

   Expected:
   ```
   202
   NAME                     READY   STATUS    RESTARTS   AGE
   cache-7549b96f9d-64lsd   1/1     Running   0          37s
   cache-7549b96f9d-s2wcj   1/1     Running   0          37s
   cache-7549b96f9d-wcqn8   0/1     Running   0          37s

   172.16.166.183
   172.16.166.182

   172.16.166.182 ready=true
   172.16.166.183 ready=true
   172.16.104.59 ready=false
   ```

   Why: that is correct for *clients*, but a chicken-and-egg problem for *peers*: many clustered apps only report
   ready **after** they have joined the cluster, and they cannot join if nobody can find them.

5. Publish not-ready members on the peer Service only. Clients keep using `cache`, which still hides the unready Pod.

   ```bash
   workstation$ kubectl -n lab-02-03 patch svc cache-peers -p '{"spec":{"publishNotReadyAddresses":true}}'
   workstation$ kubectl -n lab-02-03 exec shell -- dig +short cache-peers.lab-02-03.svc.cluster.local
   workstation$ kubectl -n lab-02-03 get endpointslices -l kubernetes.io/service-name=cache-peers \
     -o jsonpath='{range .items[*].endpoints[*]}{.addresses[0]} ready={.conditions.ready} serving={.conditions.serving}{"\n"}{end}'
   workstation$ kubectl -n lab-02-03 exec shell -- sh -c 'for i in 1 2 3 4 5 6; do curl -s http://cache/ | grep hostname; done'
   ```

   Expected:
   ```
   172.16.166.182
   172.16.166.183
   172.16.104.59

   172.16.166.182 ready=true serving=true
   172.16.166.183 ready=true serving=true
   172.16.104.59 ready=true serving=false

   "hostname": "cache-7549b96f9d-64lsd",
   "hostname": "cache-7549b96f9d-s2wcj",
   "hostname": "cache-7549b96f9d-s2wcj",
   "hostname": "cache-7549b96f9d-s2wcj",
   "hostname": "cache-7549b96f9d-64lsd",
   "hostname": "cache-7549b96f9d-s2wcj",
   ```

   Why: with `publishNotReadyAddresses` the controller reports every endpoint as `ready=true`, while `serving`
   still shows the real probe result. The client Service `cache` never routes to `wcqn8`. Two Services over the same
   Pods with different semantics is the standard pattern (StatefulSet-based databases do exactly this).

### Clean up

```bash
workstation$ kubectl delete namespace lab-02-03
```

### Your turn

The cache needs a small Redis "coordinator" that runs as a single bare Pod (not a StatefulSet), and the members
must reach it as `primary.db.lab-02-03.svc.cluster.local`. That name must survive Pod re-creation even though the
IP changes. Build it with a headless Service `db` and the Pod fields `hostname` and `subdomain`, then verify with
`dig`, `hostname -f` inside the Pod and a Redis `PING` from the shell Pod. Delete and recreate the Pod: does the
name still resolve?

<details>
<summary>Solution</summary>

`subdomain` must equal the name of a headless Service in the same namespace that selects the Pod. CoreDNS then
publishes `<hostname>.<subdomain>.<namespace>.svc.cluster.local`.

```bash
workstation$ kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Service
metadata:
  name: db
  namespace: lab-02-03
spec:
  clusterIP: None
  selector:
    app: db
  ports:
  - name: redis
    port: 6379
---
apiVersion: v1
kind: Pod
metadata:
  name: db-primary
  namespace: lab-02-03
  labels:
    app: db
spec:
  hostname: primary
  subdomain: db
  containers:
  - name: redis
    image: redis:8.8
    ports:
    - name: redis
      containerPort: 6379
EOF
workstation$ kubectl -n lab-02-03 wait --for=condition=Ready pod/db-primary
workstation$ kubectl -n lab-02-03 exec shell -- dig +short primary.db.lab-02-03.svc.cluster.local
workstation$ kubectl -n lab-02-03 exec db-primary -- hostname -f
workstation$ kubectl -n lab-02-03 exec shell -- sh -c 'echo PING | nc -w2 primary.db 6379'
```

Expected:
```
172.16.104.61
primary.db.lab-02-03.svc.cluster.local
+PONG
```

Recreate the Pod (`kubectl -n lab-02-03 delete pod db-primary`, then apply the same manifest again) and query again:

```
172.16.104.62
```

The IP changed, the name stayed. Clean up with `kubectl delete namespace lab-02-03`.
</details>

---

## Lab 2.4: Bringing a legacy system outside the cluster into service discovery

**Scenario** – The company's object storage (MinIO on the "legacy" box `192.168.1.100:9000`) will not move into
Kubernetes this year. Today every app has the IP hard-coded, so when the box is replaced, dozens of configs must
change. You will give it a cluster-internal name with a **selectorless Service and a hand-made EndpointSlice**, then
compare that with an **ExternalName** Service that points at a DNS name, and learn the trade-offs of both.

**What you'll learn**
- Services without a selector and managing EndpointSlices yourself (labels, port names, conditions)
- Port remapping for an external backend (Service port 80 → backend port 9000)
- ExternalName Services: a DNS CNAME, no proxying, no port mapping, and the "IP address" pitfall
- When to choose which

### Steps

1. Create a namespace, a debug shell, and check that the legacy system is reachable directly.

   ```bash
   workstation$ kubectl create namespace lab-02-04
   workstation$ kubectl -n lab-02-04 run shell --image=nicolaka/netshoot:v0.16 --command -- sleep infinity
   workstation$ kubectl -n lab-02-04 wait --for=condition=Ready pod/shell
   workstation$ kubectl -n lab-02-04 exec shell -- curl -s -m3 -w '%{http_code}\n' http://192.168.1.100:9000/minio/health/live
   ```

   Expected:
   ```
   200
   ```

2. Create a Service **without a selector** and an EndpointSlice that points to the legacy box. The Service listens
   on port 80, the backend listens on 9000.

   ```bash
   workstation$ kubectl apply -f - <<'EOF'
   apiVersion: v1
   kind: Service
   metadata:
     name: legacy-s3
     namespace: lab-02-04
   spec:                       # no selector: Kubernetes will not manage endpoints
     ports:
     - name: s3
       port: 80
       targetPort: 9000
   ---
   apiVersion: discovery.k8s.io/v1
   kind: EndpointSlice
   metadata:
     name: legacy-s3-1
     namespace: lab-02-04
     labels:
       kubernetes.io/service-name: legacy-s3                   # links the slice to the Service
       endpointslice.kubernetes.io/managed-by: lab-admins      # anything but the controller's name
   addressType: IPv4
   ports:
   - name: s3                  # must equal the Service port name
     protocol: TCP
     port: 9000
   endpoints:
   - addresses:
     - 192.168.1.100
     conditions:
       ready: true
   EOF
   workstation$ kubectl -n lab-02-04 get svc,endpointslices
   ```

   Expected:
   ```
   NAME                TYPE        CLUSTER-IP    EXTERNAL-IP   PORT(S)   AGE
   service/legacy-s3   ClusterIP   10.99.33.84   <none>        80/TCP    0s

   NAME                                         ADDRESSTYPE   PORTS   ENDPOINTS       AGE
   endpointslice.discovery.k8s.io/legacy-s3-1   IPv4          9000    192.168.1.100   0s
   ```

   Why: kube-proxy does not care who wrote the slice. It finds it through the `kubernetes.io/service-name` label and
   matches ports **by name**. The `managed-by` label tells the EndpointSlice controller to keep its hands off.
   With a wrong port name or a missing label, the Service silently has no endpoints.

3. Use the legacy system through its new name, first with curl, then with a real S3 client.

   ```bash
   workstation$ kubectl -n lab-02-04 exec shell -- curl -s -m3 -w '%{http_code}\n' http://legacy-s3/minio/health/live
   workstation$ kubectl -n lab-02-04 run mc --image=pgsty/mc:RELEASE.2026-10-26T00-00-00Z --restart=Never --rm -it \
       --env=MC_HOST_legacy=http://minioadmin:minioadmin123@legacy-s3 -- ls legacy
   ```

   Expected:
   ```
   200
   [2026-11-04 02:18:28 UTC]     0B training-bucket/
   ```

   The apps now use `legacy-s3.lab-02-04.svc.cluster.local`. When the storage box changes its IP, you edit one
   EndpointSlice instead of every app.

4. The legacy Endpoints API is deprecated. Selectorless Services work fine with EndpointSlices only; nothing creates
   an `Endpoints` object for you any more.

   ```bash
   workstation$ kubectl -n lab-02-04 get endpoints legacy-s3
   ```

   Expected:
   ```
   Warning: v1 Endpoints is deprecated in v1.33+; use discovery.k8s.io/v1 EndpointSlice
   Error from server (NotFound): endpoints "legacy-s3" not found
   ```

5. Now the alternative: the storage team publishes a DNS name for the box. Here we use the public wildcard DNS
   `nip.io` (`192-168-1-100.nip.io` resolves to `192.168.1.100`). In a company this would be something like
   `s3.corp.example.com`.

   ```bash
   workstation$ kubectl -n lab-02-04 create service externalname s3-dns --external-name=192-168-1-100.nip.io
   workstation$ kubectl -n lab-02-04 get svc s3-dns
   workstation$ kubectl -n lab-02-04 exec shell -- dig +noall +answer s3-dns.lab-02-04.svc.cluster.local
   ```

   Expected:
   ```
   NAME     TYPE           CLUSTER-IP   EXTERNAL-IP            PORT(S)   AGE
   s3-dns   ExternalName   <none>       192-168-1-100.nip.io   <none>    0s

   s3-dns.lab-02-04.svc.cluster.local. 30 IN CNAME	192-168-1-100.nip.io.
   192-168-1-100.nip.io.	30	IN	A	192.168.1.100
   ```

   Why: an ExternalName Service is just a **CNAME** in CoreDNS. There is no ClusterIP, no kube-proxy rule and no
   EndpointSlice.

6. Discover the ExternalName limits.

   ```bash
   workstation$ kubectl -n lab-02-04 exec shell -- curl -s -m3 -w '%{http_code}\n' http://s3-dns:9000/minio/health/live
   workstation$ kubectl -n lab-02-04 exec shell -- curl -sS -m3 http://s3-dns/minio/health/live
   workstation$ kubectl -n lab-02-04 exec shell -- sh -c 'curl -sv -m3 -o /dev/null http://s3-dns:9000/minio/health/live 2>&1 | grep "> Host"'
   ```

   Expected:
   ```
   200
   curl: (7) Failed to connect to s3-dns:80 after 23 ms: Could not connect to server
   > Host: s3-dns:9000
   ```

   Why: there is no port mapping, the client must use the real port. The client also sends the *alias* as `Host`
   header (and as TLS SNI), so backends with virtual hosts or certificates for `s3.corp.example.com` will reject it.
   MinIO does not care, many HTTPS services do.

7. The most common ExternalName mistake: putting an IP address into it.

   ```bash
   workstation$ kubectl -n lab-02-04 create service externalname s3-ip --external-name=192.168.1.100
   workstation$ kubectl -n lab-02-04 exec shell -- curl -sS -m3 http://s3-ip:9000/minio/health/live
   workstation$ kubectl -n lab-02-04 delete svc s3-ip
   ```

   Expected:
   ```
   curl: (6) Could not resolve host: s3-ip (Domain name not found)
   ```

   The API accepts the value, but CoreDNS creates a CNAME to the *hostname* `192.168.1.100.`, which does not
   exist. For an IP, use a selectorless Service with an EndpointSlice.

   | | Selectorless + EndpointSlice | ExternalName |
   |---|---|---|
   | Target | IP addresses | DNS name |
   | Port mapping | yes | no |
   | ClusterIP / kube-proxy | yes | no (DNS only) |
   | Host header / TLS SNI | Service name | Service name (often a problem) |
   | NetworkPolicy target | `ipBlock` of the endpoint | `ipBlock` of whatever the name resolves to |

### Clean up

```bash
workstation$ kubectl delete namespace lab-02-04
```

### Your turn

Two requests from the storage team:
1. Operators want the MinIO console (port 9001 on the same box) under the same name: `http://legacy-s3:9001`.
2. During their maintenance window they want to **drain** the backend without deleting any object, so that apps get
   an immediate "connection refused" instead of hanging, and then bring it back.

Implement both on the selectorless Service and verify each.

<details>
<summary>Solution</summary>

Add a second, named port to both the Service and the EndpointSlice (redo steps 1 and 2 first if you cleaned up):

```bash
workstation$ kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Service
metadata:
  name: legacy-s3
  namespace: lab-02-04
spec:
  ports:
  - name: s3
    port: 80
    targetPort: 9000
  - name: console
    port: 9001
    targetPort: 9001
---
apiVersion: discovery.k8s.io/v1
kind: EndpointSlice
metadata:
  name: legacy-s3-1
  namespace: lab-02-04
  labels:
    kubernetes.io/service-name: legacy-s3
    endpointslice.kubernetes.io/managed-by: lab-admins
addressType: IPv4
ports:
- name: s3
  protocol: TCP
  port: 9000
- name: console
  protocol: TCP
  port: 9001
endpoints:
- addresses:
  - 192.168.1.100
  conditions:
    ready: true
EOF
workstation$ kubectl -n lab-02-04 get endpointslices
workstation$ kubectl -n lab-02-04 exec shell -- curl -s -m3 -o /dev/null -w 'console %{http_code}\n' http://legacy-s3:9001/
```

Expected:
```
NAME          ADDRESSTYPE   PORTS       ENDPOINTS       AGE
legacy-s3-1   IPv4          9000,9001   192.168.1.100   42s
console 200
```

Drain by marking the endpoint not ready (kube-proxy removes it, the Service then rejects connections), and undo:

```bash
workstation$ kubectl -n lab-02-04 patch endpointslice legacy-s3-1 --type=json \
    -p '[{"op":"replace","path":"/endpoints/0/conditions/ready","value":false}]'
workstation$ kubectl -n lab-02-04 exec shell -- curl -sS -m3 http://legacy-s3/minio/health/live
workstation$ kubectl -n lab-02-04 patch endpointslice legacy-s3-1 --type=json \
    -p '[{"op":"replace","path":"/endpoints/0/conditions/ready","value":true}]'
workstation$ kubectl -n lab-02-04 exec shell -- curl -s -m3 -o /dev/null -w 's3 %{http_code}\n' http://legacy-s3/minio/health/live
```

Expected:
```
curl: (7) Failed to connect to legacy-s3:80 after 17 ms: Could not connect to server
s3 200
```

This is exactly what the EndpointSlice controller does for unready Pods. Clean up with
`kubectl delete namespace lab-02-04`.
</details>

---

## Lab 2.5: Sticky sessions and node-local traffic

**Scenario** – The legacy `cart` service keeps shopping carts in memory. Behind a Service, every request lands on a
random replica, and customers complain that items "disappear" from their cart. Until the team moves the state to
Redis, you will pin each client to one replica with `sessionAffinity: ClientIP`. Then the platform team asks to keep
traffic on the same node where possible to save cross-node hops, which is what `trafficDistribution` is for.

**What you'll learn**
- How `sessionAffinity: ClientIP` works, its timeout, and why it is not a real session mechanism
- `trafficDistribution: PreferSameNode` and the per-node hints it writes into EndpointSlices
- Why `PreferSameZone` (`PreferClose`) does nothing in a cluster without zone labels
- The difference between a *preference* (`trafficDistribution`) and a *hard rule* (`internalTrafficPolicy: Local`)

### Steps

1. Deploy four `cart` replicas spread across both workers, a Service, and one client Pod pinned to each worker.

   ```bash
   workstation$ kubectl create namespace lab-02-05
   workstation$ kubectl apply -f - <<'EOF'
   apiVersion: apps/v1
   kind: Deployment
   metadata:
     name: cart
     namespace: lab-02-05
   spec:
     replicas: 4
     selector:
       matchLabels:
         app: cart
     template:
       metadata:
         labels:
           app: cart
       spec:
         topologySpreadConstraints:
         - maxSkew: 1
           topologyKey: kubernetes.io/hostname
           whenUnsatisfiable: DoNotSchedule
           nodeTaintsPolicy: Honor      # do not count the tainted master as a domain
           labelSelector:
             matchLabels:
               app: cart
         containers:
         - name: whoami
           image: traefik/whoami:v1.12.0
           ports:
           - name: http
             containerPort: 80
   ---
   apiVersion: v1
   kind: Service
   metadata:
     name: cart
     namespace: lab-02-05
   spec:
     selector:
       app: cart
     ports:
     - name: http
       port: 80
       targetPort: http
   ---
   apiVersion: v1
   kind: Pod
   metadata:
     name: client-node1
     namespace: lab-02-05
   spec:
     nodeName: node1
     containers:
     - name: curl
       image: curlimages/curl:8.23.0
       command: ["sleep", "infinity"]
   ---
   apiVersion: v1
   kind: Pod
   metadata:
     name: client-node2
     namespace: lab-02-05
   spec:
     nodeName: node2
     containers:
     - name: curl
       image: curlimages/curl:8.23.0
       command: ["sleep", "infinity"]
   EOF
   workstation$ kubectl -n lab-02-05 rollout status deploy/cart
   workstation$ kubectl -n lab-02-05 get pods -o wide
   ```

   Expected:
   ```
   NAME                    READY   STATUS    RESTARTS   AGE   IP               NODE
   cart-6974ccbfcf-7pmk7   1/1     Running   0          20s   172.16.104.38    node2
   cart-6974ccbfcf-bjqjl   1/1     Running   0          20s   172.16.104.37    node2
   cart-6974ccbfcf-mqkc4   1/1     Running   0          20s   172.16.166.165   node1
   cart-6974ccbfcf-xvplz   1/1     Running   0          20s   172.16.166.160   node1
   client-node1            1/1     Running   0          20s   172.16.166.155   node1
   client-node2            1/1     Running   0          20s   172.16.104.20    node2
   ```

   Pitfall: without `nodeTaintsPolicy: Honor`, the scheduler counts the master (0 Pods, but tainted) as a topology
   domain. With `maxSkew: 1` only one Pod per worker can be placed and the other two stay `Pending` forever.

2. Reproduce the customer complaint: 20 requests from each client are spread over all replicas.

   ```bash
   workstation$ for c in client-node1 client-node2; do echo "== $c"; kubectl -n lab-02-05 exec $c -- sh -c 'for i in $(seq 20); do curl -s http://cart/ | grep Hostname; done | sort | uniq -c'; done
   ```

   Expected:
   ```
   == client-node1
         4 Hostname: cart-6974ccbfcf-7pmk7
         5 Hostname: cart-6974ccbfcf-bjqjl
         3 Hostname: cart-6974ccbfcf-mqkc4
         8 Hostname: cart-6974ccbfcf-xvplz
   == client-node2
         3 Hostname: cart-6974ccbfcf-7pmk7
         6 Hostname: cart-6974ccbfcf-bjqjl
         3 Hostname: cart-6974ccbfcf-mqkc4
         8 Hostname: cart-6974ccbfcf-xvplz
   ```

3. Enable client-IP affinity with a short timeout so you can observe it expire.

   ```bash
   workstation$ kubectl -n lab-02-05 patch svc cart -p '{"spec":{"sessionAffinity":"ClientIP","sessionAffinityConfig":{"clientIP":{"timeoutSeconds":60}}}}'
   workstation$ for c in client-node1 client-node2; do echo "== $c"; kubectl -n lab-02-05 exec $c -- sh -c 'for i in $(seq 20); do curl -s http://cart/ | grep Hostname; done | sort | uniq -c'; done
   ```

   Expected:
   ```
   == client-node1
        20 Hostname: cart-6974ccbfcf-bjqjl
   == client-node2
        20 Hostname: cart-6974ccbfcf-mqkc4
   ```

   Why: kube-proxy remembers the source IP of each client (iptables `recent` module) and sends it to the same
   endpoint until no packet has been seen for `timeoutSeconds` (default 10800 = 3 h).

4. Affinity is not durable state. Kill the replica that `client-node1` is pinned to.

   ```bash
   workstation$ kubectl -n lab-02-05 delete pod cart-6974ccbfcf-bjqjl      # the Pod client-node1 sticks to
   workstation$ kubectl -n lab-02-05 exec client-node1 -- sh -c 'for i in $(seq 10); do curl -s http://cart/ | grep Hostname; done | sort | uniq -c'
   ```

   Expected:
   ```
        10 Hostname: cart-6974ccbfcf-8ltp8
   ```

   The client is re-pinned to another Pod and the in-memory cart is gone. Other pitfalls: all clients behind one
   NAT or proxy (for example every request that comes through a single Gateway Pod) share one source IP and land on
   **one** replica, and affinity is per Service IP, not per user. Real session stickiness belongs in the L7 layer
   (cookies in the Gateway) or, better, in shared state.

5. Switch from affinity to a topology preference: keep traffic on the client's node when there is a local endpoint.

   ```bash
   workstation$ kubectl -n lab-02-05 patch svc cart -p '{"spec":{"sessionAffinity":"None","sessionAffinityConfig":null,"trafficDistribution":"PreferSameNode"}}'
   workstation$ kubectl -n lab-02-05 get endpointslices -l kubernetes.io/service-name=cart \
     -o jsonpath='{range .items[*].endpoints[*]}{.addresses[0]} node={.nodeName} hints={.hints}{"\n"}{end}'
   workstation$ for c in client-node1 client-node2; do echo "== $c"; kubectl -n lab-02-05 exec $c -- sh -c 'for i in $(seq 20); do curl -s http://cart/ | grep Hostname; done | sort | uniq -c'; done
   ```

   Expected:
   ```
   172.16.104.38 node=node2 hints={"forNodes":[{"name":"node2"}]}
   172.16.166.160 node=node1 hints={"forNodes":[{"name":"node1"}]}
   172.16.166.165 node=node1 hints={"forNodes":[{"name":"node1"}]}
   172.16.104.40 node=node2 hints={"forNodes":[{"name":"node2"}]}

   == client-node1
        10 Hostname: cart-6974ccbfcf-mqkc4
        10 Hostname: cart-6974ccbfcf-xvplz
   == client-node2
        10 Hostname: cart-6974ccbfcf-7pmk7
        10 Hostname: cart-6974ccbfcf-8ltp8
   ```

   Why: the EndpointSlice controller writes a `forNodes` hint on each endpoint, and kube-proxy on each node only
   programs the endpoints hinted for that node. Each client now only talks to the replicas on its own node.

6. Try the zone-based variant, which is what most cloud clusters use.

   ```bash
   workstation$ kubectl -n lab-02-05 patch svc cart -p '{"spec":{"trafficDistribution":"PreferSameZone"}}'
   workstation$ kubectl -n lab-02-05 get endpointslices -l kubernetes.io/service-name=cart \
     -o jsonpath='{range .items[*].endpoints[*]}{.addresses[0]} zone={.zone} hints={.hints}{"\n"}{end}'
   workstation$ kubectl get nodes -L topology.kubernetes.io/zone
   ```

   Expected:
   ```
   172.16.104.38 zone= hints=
   172.16.166.160 zone= hints=
   172.16.166.165 zone= hints=
   172.16.104.40 zone= hints=

   NAME     STATUS   ROLES           AGE   VERSION   ZONE
   master   Ready    control-plane   15d   v1.37.1
   node1    Ready    <none>          15d   v1.37.1
   node2    Ready    <none>          15d   v1.37.1
   ```

   Why: zone hints need the `topology.kubernetes.io/zone` node label, which cloud providers set and kubeadm does
   not. Without it the setting is silently a no-op and traffic is spread cluster-wide again. (`PreferClose` is the
   older name of `PreferSameZone`.)

### Clean up

```bash
workstation$ kubectl delete namespace lab-02-05
```

### Your turn

A colleague says: "`PreferSameNode` and `internalTrafficPolicy: Local` are the same thing." Prove them wrong. Run a
client Pod on a node that has **no** `cart` replica (the master: give the Pod a toleration for the
`node-role.kubernetes.io/control-plane:NoSchedule` taint and `nodeName: master`). Compare what this client gets with
`trafficDistribution: PreferSameNode` and with `internalTrafficPolicy: Local`, and check that clients on the workers
are unaffected. Which one would you use for a node-local agent (for example a log collector DaemonSet)?

<details>
<summary>Solution</summary>

Redo step 1 if you already cleaned up. Then start a client on the master:

```bash
workstation$ kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: client-master
  namespace: lab-02-05
spec:
  nodeName: master
  tolerations:
  - key: node-role.kubernetes.io/control-plane
    operator: Exists
    effect: NoSchedule
  containers:
  - name: curl
    image: curlimages/curl:8.23.0
    command: ["sleep", "infinity"]
EOF
workstation$ kubectl -n lab-02-05 patch svc cart -p '{"spec":{"trafficDistribution":"PreferSameNode"}}'
workstation$ kubectl -n lab-02-05 exec client-master -- sh -c 'for i in $(seq 20); do curl -s http://cart/ | grep Hostname; done | sort | uniq -c'
```

Expected (a preference falls back to all endpoints when there is no local one):
```
      7 Hostname: cart-6974ccbfcf-7pmk7
      3 Hostname: cart-6974ccbfcf-8ltp8
      5 Hostname: cart-6974ccbfcf-mqkc4
      5 Hostname: cart-6974ccbfcf-xvplz
```

Now replace it with the hard rule:

```bash
workstation$ kubectl -n lab-02-05 patch svc cart --type=json -p '[{"op":"remove","path":"/spec/trafficDistribution"},{"op":"replace","path":"/spec/internalTrafficPolicy","value":"Local"}]'
workstation$ kubectl -n lab-02-05 exec client-master -- curl -sS -m 3 http://cart/
workstation$ kubectl -n lab-02-05 exec client-node1 -- sh -c 'for i in $(seq 10); do curl -s http://cart/ | grep Hostname; done | sort | uniq -c'
```

Expected:
```
curl: (28) Connection timed out after 3001 milliseconds
command terminated with exit code 28
      6 Hostname: cart-6974ccbfcf-mqkc4
      4 Hostname: cart-6974ccbfcf-xvplz
```

With `internalTrafficPolicy: Local` a node without a local endpoint **drops** the traffic. That is the right choice
for a node-local agent: you *want* every Pod to talk to the agent on its own node, and you would rather fail than
send logs of node1 to the collector on node2. `PreferSameNode` is the right choice for normal apps: lower latency
when possible, availability always. Clean up with `kubectl delete namespace lab-02-05`.
</details>

---

## Lab 2.6: Default deny and the DNS egress gotcha

**Scenario** – After a security audit, every namespace must start from **default deny** and open only what is
needed. The team rolls it out on Friday afternoon, adds an "allow client → web" rule, and nothing works any more,
not even name resolution. You will build the policy set step by step and hit the three classic mistakes: forgetting
DNS, allowing the *Service* port instead of the *Pod* port, and allowing DNS over UDP only.

**What you'll learn**
- How a namespace-wide default-deny policy for Ingress and Egress works (`podSelector: {}`)
- That NetworkPolicies are allow-lists that add up, and that a connection needs egress **and** ingress to be allowed
- That policies see the Pod IP and **container port** after the Service DNAT, not the ClusterIP/Service port
- How to allow DNS correctly (CoreDNS in `kube-system`, UDP **and** TCP 53)

### Steps

1. Deploy a web app (`nginx-unprivileged` listens on 8080, the Service on 80) and a client, and check that it works.

   ```bash
   workstation$ kubectl create namespace lab-02-06
   workstation$ kubectl apply -f - <<'EOF'
   apiVersion: apps/v1
   kind: Deployment
   metadata:
     name: web
     namespace: lab-02-06
   spec:
     replicas: 2
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
           image: nginxinc/nginx-unprivileged:1.31-alpine
           ports:
           - name: http
             containerPort: 8080
   ---
   apiVersion: v1
   kind: Service
   metadata:
     name: web
     namespace: lab-02-06
   spec:
     selector:
       app: web
     ports:
     - name: http
       port: 80
       targetPort: http
   ---
   apiVersion: v1
   kind: Pod
   metadata:
     name: client
     namespace: lab-02-06
     labels:
       app: client
   spec:
     containers:
     - name: shell
       image: nicolaka/netshoot:v0.16
       command: ["sleep", "infinity"]
   EOF
   workstation$ kubectl -n lab-02-06 wait --for=condition=Ready pod/client
   workstation$ kubectl -n lab-02-06 exec client -- curl -s -m3 -o /dev/null -w '%{http_code}\n' http://web/
   ```

   Expected:
   ```
   200
   ```

2. Lock the namespace down. An empty `podSelector` selects every Pod in the namespace; listing both policy types
   with no rules means "nothing is allowed".

   ```bash
   workstation$ kubectl apply -f - <<'EOF'
   apiVersion: networking.k8s.io/v1
   kind: NetworkPolicy
   metadata:
     name: default-deny-all
     namespace: lab-02-06
   spec:
     podSelector: {}
     policyTypes:
     - Ingress
     - Egress
   EOF
   workstation$ kubectl -n lab-02-06 exec client -- curl -sS -m3 http://web/
   workstation$ kubectl -n lab-02-06 exec client -- nslookup -timeout=2 web
   ```

   Expected:
   ```
   curl: (28) Resolving timed out after 3002 milliseconds
   command terminated with exit code 28

   ;; communications error to 10.96.0.10#53: timed out
   ;; no servers could be reached
   ```

   Why: egress is denied for every Pod, including packets to CoreDNS. Calico drops them silently, so you see
   timeouts, not "connection refused". A timeout is the typical symptom of a NetworkPolicy.

3. Allow client → web. A colleague writes the egress rule with port 80 "because the Service listens on 80". To skip
   DNS for now, test with the ClusterIP.

   ```bash
   workstation$ kubectl apply -f - <<'EOF'
   apiVersion: networking.k8s.io/v1
   kind: NetworkPolicy
   metadata:
     name: client-to-web
     namespace: lab-02-06
   spec:
     podSelector:
       matchLabels:
         app: client
     policyTypes:
     - Egress
     egress:
     - to:
       - podSelector:
           matchLabels:
             app: web
       ports:
       - protocol: TCP
         port: 80          # WRONG: this is the Service port
   ---
   apiVersion: networking.k8s.io/v1
   kind: NetworkPolicy
   metadata:
     name: web-from-client
     namespace: lab-02-06
   spec:
     podSelector:
       matchLabels:
         app: web
     policyTypes:
     - Ingress
     ingress:
     - from:
       - podSelector:
           matchLabels:
             app: client
       ports:
       - protocol: TCP
         port: 8080
   EOF
   workstation$ WEB_IP=$(kubectl -n lab-02-06 get svc web -o jsonpath='{.spec.clusterIP}')
   workstation$ kubectl -n lab-02-06 exec client -- curl -sS -m3 -o /dev/null -w '%{http_code}\n' http://$WEB_IP/
   ```

   Expected:
   ```
   curl: (28) Connection timed out after 3002 milliseconds
   ```

   Why: kube-proxy rewrites `10.102.113.56:80` to `<pod-ip>:8080` **before** Calico evaluates the policy. A
   NetworkPolicy never sees Service IPs or Service ports, only Pod IPs and container ports. Fix the port (a named
   port such as `http` works too, it is resolved against the destination Pod):

   ```bash
   workstation$ kubectl -n lab-02-06 patch netpol client-to-web --type=json -p '[{"op":"replace","path":"/spec/egress/0/ports/0/port","value":8080}]'
   workstation$ kubectl -n lab-02-06 exec client -- curl -sS -m3 -o /dev/null -w '%{http_code}\n' http://$WEB_IP/
   workstation$ kubectl -n lab-02-06 exec client -- curl -sS -m3 -o /dev/null -w '%{http_code}\n' http://web/
   ```

   Expected:
   ```
   200
   curl: (28) Resolving timed out after 3004 milliseconds
   ```

   The IP works, the name does not: DNS is still blocked.

4. Allow DNS for all Pods in the namespace, but (mistake number three) only over UDP.

   ```bash
   workstation$ kubectl apply -f - <<'EOF'
   apiVersion: networking.k8s.io/v1
   kind: NetworkPolicy
   metadata:
     name: allow-dns
     namespace: lab-02-06
   spec:
     podSelector: {}
     policyTypes:
     - Egress
     egress:
     - to:
       - namespaceSelector:
           matchLabels:
             kubernetes.io/metadata.name: kube-system
         podSelector:
           matchLabels:
             k8s-app: kube-dns
       ports:
       - protocol: UDP
         port: 53
   EOF
   workstation$ kubectl -n lab-02-06 exec client -- curl -sS -m3 -o /dev/null -w '%{http_code}\n' http://web/
   workstation$ kubectl -n lab-02-06 exec client -- dig +tcp +short +timeout=2 +tries=1 web.lab-02-06.svc.cluster.local
   ```

   Expected:
   ```
   200
   ;; Connection to 10.96.0.10#53(10.96.0.10) for web.lab-02-06.svc.cluster.local failed: timed out.
   ;; no servers could be reached
   ```

   Why: most lookups use UDP, but DNS falls back to TCP for large answers (many A records, DNSSEC, long TXT
   records). UDP-only rules cause rare, "random" resolution failures that are very hard to debug. Always allow both:

   ```bash
   workstation$ kubectl -n lab-02-06 patch netpol allow-dns --type=json -p '[{"op":"add","path":"/spec/egress/0/ports/-","value":{"protocol":"TCP","port":53}}]'
   workstation$ kubectl -n lab-02-06 exec client -- dig +tcp +short +timeout=2 +tries=1 web.lab-02-06.svc.cluster.local
   ```

   Expected:
   ```
   10.102.113.56
   ```

   The rule targets the CoreDNS **Pods** (`k8s-app: kube-dns`) on their container port 53, not the `kube-dns`
   Service IP `10.96.0.10`, for the same DNAT reason as in step 3.

5. Verify that everything else is still denied: the Internet, and an unlabelled Pod in the same namespace.

   ```bash
   workstation$ kubectl -n lab-02-06 exec client -- curl -sS -m3 http://1.1.1.1/
   workstation$ kubectl -n lab-02-06 run intruder --image=curlimages/curl:8.23.0 --restart=Never --rm -it -- curl -sS -m3 http://web/
   workstation$ kubectl -n lab-02-06 get netpol
   ```

   Expected:
   ```
   curl: (28) Connection timed out after 3002 milliseconds
   curl: (28) Connection timed out after 3002 milliseconds

   NAME               POD-SELECTOR   AGE
   allow-dns          <none>         24s
   client-to-web      app=client     49s
   default-deny-all   <none>         71s
   web-from-client    app=web        49s
   ```

   Why: policies are additive allow-lists, there is no order and no "deny" rule. The intruder may resolve `web`
   (`allow-dns` selects all Pods), but neither its egress nor the web Pods' ingress allows the connection. Note that
   the reply packets of allowed connections need no rule: policies are stateful.

### Clean up

```bash
workstation$ kubectl delete namespace lab-02-06
```

### Your turn

The namespace also runs an `ops` Pod (`alpine/k8s:1.37.1`, ServiceAccount `deployer` allowed to list Pods in
`lab-02-06`) that must talk to the Kubernetes API. Under default deny, `kubectl get pods` inside it hangs. Write a
policy that lets **only** the ops Pod reach the API server, and nothing else. Hint: the obvious rule "egress to
`10.96.0.1/32` port 443" (the `kubernetes` Service) does not work. Find out why and what the right destination is.
Does the ops Pod need the DNS rule for this?

<details>
<summary>Solution</summary>

Redo steps 1, 2 and 4 if you cleaned up. Create the ServiceAccount, RBAC, the Pod and the "obvious" policy:

```bash
workstation$ kubectl apply -f - <<'EOF'
apiVersion: v1
kind: ServiceAccount
metadata:
  name: deployer
  namespace: lab-02-06
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: pod-reader
  namespace: lab-02-06
rules:
- apiGroups: [""]
  resources: ["pods"]
  verbs: ["get", "list"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: deployer-pod-reader
  namespace: lab-02-06
subjects:
- kind: ServiceAccount
  name: deployer
  namespace: lab-02-06
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: pod-reader
---
apiVersion: v1
kind: Pod
metadata:
  name: ops
  namespace: lab-02-06
  labels:
    app: ops
spec:
  serviceAccountName: deployer
  containers:
  - name: kubectl
    image: alpine/k8s:1.37.1
    command: ["sleep", "infinity"]
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: ops-to-apiserver
  namespace: lab-02-06
spec:
  podSelector:
    matchLabels:
      app: ops
  policyTypes:
  - Egress
  egress:
  - to:
    - ipBlock:
        cidr: 10.96.0.1/32
    ports:
    - protocol: TCP
      port: 443
EOF
workstation$ kubectl -n lab-02-06 wait --for=condition=Ready pod/ops
workstation$ kubectl -n lab-02-06 exec ops -- sh -c 'timeout 8 kubectl get pods; echo exit=$?'
```

Expected:
```
exit=143
Terminated
```

(Use `timeout` rather than `kubectl --request-timeout`: any extra client flag makes kubectl skip the in-cluster
config and fall back to `localhost:8080`.)

The ClusterIP is DNATed to the real API server endpoint before the policy is evaluated. Look it up:

```bash
workstation$ kubectl get endpointslice -n default -l kubernetes.io/service-name=kubernetes
```

Expected:
```
NAME         ADDRESSTYPE   PORTS   ENDPOINTS      AGE
kubernetes   IPv4          6443    192.168.1.10   15d
```

Allow that address and port instead (with several control-plane nodes, list all of them):

```bash
workstation$ kubectl -n lab-02-06 patch netpol ops-to-apiserver --type=json -p '[{"op":"replace","path":"/spec/egress/0","value":{"to":[{"ipBlock":{"cidr":"192.168.1.10/32"}}],"ports":[{"protocol":"TCP","port":6443}]}}]'
workstation$ kubectl -n lab-02-06 exec ops -- sh -c 'timeout 8 kubectl get pods; echo exit=$?'
workstation$ kubectl -n lab-02-06 exec ops -- kubectl get pods -n kube-system
```

Expected:
```
NAME                   READY   STATUS    RESTARTS   AGE
client                 1/1     Running   0          2m54s
ops                    1/1     Running   0          85s
web-664bdc94fd-4npnj   1/1     Running   0          2m54s
web-664bdc94fd-ds279   1/1     Running   0          2m54s
exit=0
Error from server (Forbidden): pods is forbidden: User "system:serviceaccount:lab-02-06:deployer" cannot list resource "pods" in API group "" in the namespace "kube-system"
```

The network now allows the API, RBAC still limits what the Pod may do: two independent layers. DNS is not needed
because in-cluster clients use the `KUBERNETES_SERVICE_HOST=10.96.0.1` environment variable, not a name (the
`allow-dns` policy would allow it anyway). Clean up with `kubectl delete namespace lab-02-06`.
</details>

---

## Lab 2.7: Zero-trust networking for a three-tier app

**Scenario** – A pentest report says: "an attacker who compromises the web frontend can talk directly to the Redis
cache and to the Internet". The app is a classic three-tier stack: `frontend` (nginx reverse proxy) → `api`
(podinfo) → `cache` (Redis). You will apply a zero-trust model: deny everything, then allow exactly the arrows of the
architecture diagram, and prove both the happy path and the blocked paths.

**What you'll learn**
- Translating an architecture diagram into NetworkPolicies (one policy per tier, ingress and egress)
- An ingress rule without `from` (any source, any namespace) vs. a rule with `podSelector`
- That kubelet probes keep working under default deny (Calico allows traffic from the local node)
- The limits of L3/L4 policies

```
 any namespace ──8080──▶ frontend ──9898──▶ api ──6379──▶ cache
                          (nginx)        (podinfo)      (redis)
```

### Steps

1. Deploy the application and an "external" client in another namespace.

   ```bash
   workstation$ kubectl create namespace lab-02-07
   workstation$ kubectl create namespace lab-02-07-ext
   workstation$ kubectl -n lab-02-07-ext run shell --image=nicolaka/netshoot:v0.16 --command -- sleep infinity
   workstation$ kubectl apply -f - <<'EOF'
   apiVersion: v1
   kind: ConfigMap
   metadata:
     name: frontend-conf
     namespace: lab-02-07
   data:
     default.conf: |
       server {
         listen 8080;
         location / {
           proxy_pass http://api.lab-02-07.svc.cluster.local:9898;
         }
       }
   ---
   apiVersion: apps/v1
   kind: Deployment
   metadata:
     name: frontend
     namespace: lab-02-07
   spec:
     replicas: 2
     selector:
       matchLabels:
         tier: frontend
     template:
       metadata:
         labels:
           tier: frontend
       spec:
         containers:
         - name: nginx
           image: nginxinc/nginx-unprivileged:1.31-alpine
           ports:
           - name: http
             containerPort: 8080
           volumeMounts:
           - name: conf
             mountPath: /etc/nginx/conf.d
         volumes:
         - name: conf
           configMap:
             name: frontend-conf
   ---
   apiVersion: v1
   kind: Service
   metadata:
     name: frontend
     namespace: lab-02-07
   spec:
     selector:
       tier: frontend
     ports:
     - name: http
       port: 80
       targetPort: http
   ---
   apiVersion: apps/v1
   kind: Deployment
   metadata:
     name: api
     namespace: lab-02-07
   spec:
     replicas: 2
     selector:
       matchLabels:
         tier: api
     template:
       metadata:
         labels:
           tier: api
       spec:
         containers:
         - name: podinfo
           image: ghcr.io/stefanprodan/podinfo:6.17.0
           command: ["./podinfo", "--port=9898", "--cache-server=tcp://redis:6379"]
           ports:
           - name: http
             containerPort: 9898
           readinessProbe:
             httpGet:
               path: /readyz
               port: http
   ---
   apiVersion: v1
   kind: Service
   metadata:
     name: api
     namespace: lab-02-07
   spec:
     selector:
       tier: api
     ports:
     - name: http
       port: 9898
       targetPort: http
   ---
   apiVersion: apps/v1
   kind: Deployment
   metadata:
     name: redis
     namespace: lab-02-07
   spec:
     replicas: 1
     selector:
       matchLabels:
         tier: cache
     template:
       metadata:
         labels:
           tier: cache
       spec:
         containers:
         - name: redis
           image: redis:8.8
           ports:
           - name: redis
             containerPort: 6379
   ---
   apiVersion: v1
   kind: Service
   metadata:
     name: redis
     namespace: lab-02-07
   spec:
     selector:
       tier: cache
     ports:
     - name: redis
       port: 6379
       targetPort: redis
   EOF
   workstation$ kubectl -n lab-02-07 get pods -L tier
   ```

   Expected:
   ```
   NAME                        READY   STATUS    RESTARTS   AGE   TIER
   api-7b6b465d7-mprqz         1/1     Running   0          3s    api
   api-7b6b465d7-rn6gx         1/1     Running   0          3s    api
   frontend-7b85d47947-kqjhr   1/1     Running   0          3s    frontend
   frontend-7b85d47947-ksf2m   1/1     Running   0          3s    frontend
   redis-5b58f96868-8kfbt      1/1     Running   0          3s    cache
   ```

2. Test the happy path (write and read a value through all three tiers) and confirm the pentest findings.

   ```bash
   workstation$ X="kubectl -n lab-02-07-ext exec shell --"
   workstation$ $X curl -s http://frontend.lab-02-07/ | grep -E 'hostname|version'
   workstation$ $X curl -s -X POST -d blue -w '%{http_code}\n' http://frontend.lab-02-07/cache/color
   workstation$ $X curl -s http://frontend.lab-02-07/cache/color; echo
   workstation$ $X curl -s -m3 -o /dev/null -w 'direct api %{http_code}\n' http://api.lab-02-07:9898/
   workstation$ $X sh -c 'echo PING | nc -w2 redis.lab-02-07 6379'
   ```

   Expected:
   ```
     "hostname": "api-7b6b465d7-mprqz",
     "version": "6.17.0",
   202
   blue
   direct api 200
   +PONG
   ```

   Everything can talk to everything, across namespaces: that is the Kubernetes default.

3. Apply the zero-trust policy set: a default deny, DNS for everyone, and one policy per tier.

   ```bash
   workstation$ kubectl apply -f - <<'EOF'
   apiVersion: networking.k8s.io/v1
   kind: NetworkPolicy
   metadata:
     name: default-deny-all
     namespace: lab-02-07
   spec:
     podSelector: {}
     policyTypes: ["Ingress", "Egress"]
   ---
   apiVersion: networking.k8s.io/v1
   kind: NetworkPolicy
   metadata:
     name: allow-dns
     namespace: lab-02-07
   spec:
     podSelector: {}
     policyTypes: ["Egress"]
     egress:
     - to:
       - namespaceSelector:
           matchLabels:
             kubernetes.io/metadata.name: kube-system
         podSelector:
           matchLabels:
             k8s-app: kube-dns
       ports:
       - protocol: UDP
         port: 53
       - protocol: TCP
         port: 53
   ---
   apiVersion: networking.k8s.io/v1
   kind: NetworkPolicy
   metadata:
     name: frontend
     namespace: lab-02-07
   spec:
     podSelector:
       matchLabels:
         tier: frontend
     policyTypes: ["Ingress", "Egress"]
     ingress:
     - ports:                       # no "from": any source, in any namespace
       - protocol: TCP
         port: 8080
     egress:
     - to:
       - podSelector:
           matchLabels:
             tier: api
       ports:
       - protocol: TCP
         port: 9898
   ---
   apiVersion: networking.k8s.io/v1
   kind: NetworkPolicy
   metadata:
     name: api
     namespace: lab-02-07
   spec:
     podSelector:
       matchLabels:
         tier: api
     policyTypes: ["Ingress", "Egress"]
     ingress:
     - from:
       - podSelector:
           matchLabels:
             tier: frontend
       ports:
       - protocol: TCP
         port: 9898
     egress:
     - to:
       - podSelector:
           matchLabels:
             tier: cache
       ports:
       - protocol: TCP
         port: 6379
   ---
   apiVersion: networking.k8s.io/v1
   kind: NetworkPolicy
   metadata:
     name: cache
     namespace: lab-02-07
   spec:
     podSelector:
       matchLabels:
         tier: cache
     policyTypes: ["Ingress", "Egress"]
     ingress:
     - from:
       - podSelector:
           matchLabels:
             tier: api
       ports:
       - protocol: TCP
         port: 6379
   EOF
   workstation$ kubectl -n lab-02-07 get netpol
   ```

   Expected:
   ```
   NAME               POD-SELECTOR    AGE
   allow-dns          <none>          3s
   api                tier=api        3s
   cache              tier=cache      3s
   default-deny-all   <none>          3s
   frontend           tier=frontend   3s
   ```

   Why: a `podSelector` inside `from`/`to` without a `namespaceSelector` only matches Pods in the **policy's own
   namespace**. The cache has no egress rules at all: Redis never initiates connections.

4. Re-run the tests. The happy path must still work, the direct paths must not.

   ```bash
   workstation$ $X curl -s -m3 -X POST -d green -w '%{http_code}\n' http://frontend.lab-02-07/cache/color
   workstation$ $X curl -s -m3 http://frontend.lab-02-07/cache/color; echo
   workstation$ $X curl -sS -m3 -o /dev/null http://api.lab-02-07:9898/
   workstation$ $X sh -c 'echo PING | nc -w2 redis.lab-02-07 6379; echo nc-exit=$?'
   ```

   Expected:
   ```
   202
   green
   curl: (28) Connection timed out after 3001 milliseconds
   nc-exit=1
   ```

5. Now play the attacker who owns a frontend Pod: try Redis and the Internet from inside it.

   ```bash
   workstation$ F=$(kubectl -n lab-02-07 get pod -l tier=frontend -o name | head -1)
   workstation$ kubectl -n lab-02-07 exec $F -- sh -c 'nc -w2 redis 6379 </dev/null; echo frontend-to-redis-exit=$?'
   workstation$ kubectl -n lab-02-07 exec $F -- sh -c 'wget -q -T3 -O- http://example.com >/dev/null; echo frontend-to-internet-exit=$?'
   workstation$ kubectl -n lab-02-07 get pods
   ```

   Expected:
   ```
   frontend-to-redis-exit=1
   wget: download timed out
   frontend-to-internet-exit=1

   NAME                        READY   STATUS    RESTARTS   AGE
   api-7b6b465d7-mprqz         1/1     Running   0          33s
   api-7b6b465d7-rn6gx         1/1     Running   0          33s
   ...
   ```

   Why: both pentest findings are fixed. The `api` Pods are still `Ready`: readiness probes come from the kubelet on
   the same node, and Calico always allows host-to-local-Pod traffic. (Other CNIs behave the same way, but this is
   CNI-specific; with some CNIs you must allow the node CIDR explicitly.)

### Clean up

```bash
workstation$ kubectl delete namespace lab-02-07 lab-02-07-ext
```

### Your turn

The BI team adds a `reporter` Pod (label `role: reporter`, image `curlimages/curl:8.23.0`) in `lab-02-07` that must
read values **directly from the API** (`GET /cache/<key>` on port 9898), not through the frontend. It must not reach
Redis or the frontend. Do it **without editing** the existing policies. Then try a `POST` from the reporter: what does
this tell you about NetworkPolicies?

<details>
<summary>Solution</summary>

First confirm that the default deny blocks a new Pod:

```bash
workstation$ kubectl -n lab-02-07 run reporter --image=curlimages/curl:8.23.0 --labels=role=reporter --command -- sleep infinity
workstation$ kubectl -n lab-02-07 exec reporter -- curl -sS -m3 http://api:9898/cache/color
```

Expected:
```
curl: (28) Connection timed out after 3001 milliseconds
```

Policies are additive, so two new objects are enough: egress for the reporter and an extra ingress for the API.

```bash
workstation$ kubectl apply -f - <<'EOF'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: reporter
  namespace: lab-02-07
spec:
  podSelector:
    matchLabels:
      role: reporter
  policyTypes: ["Egress"]
  egress:
  - to:
    - podSelector:
        matchLabels:
          tier: api
    ports:
    - protocol: TCP
      port: 9898
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: api-from-reporter
  namespace: lab-02-07
spec:
  podSelector:
    matchLabels:
      tier: api
  policyTypes: ["Ingress"]
  ingress:
  - from:
    - podSelector:
        matchLabels:
          role: reporter
    ports:
    - protocol: TCP
      port: 9898
EOF
workstation$ R="kubectl -n lab-02-07 exec reporter --"
workstation$ $R curl -sS -m3 http://api:9898/cache/color; echo
workstation$ $R curl -sS -m3 telnet://redis:6379 </dev/null
workstation$ $R curl -sS -m3 -o /dev/null http://frontend/
workstation$ $R curl -s -m3 -X POST -d hacked -w 'POST %{http_code}\n' http://api:9898/cache/color
workstation$ kubectl -n lab-02-07-ext exec shell -- curl -s -m3 http://frontend.lab-02-07/cache/color
```

Expected:
```
green
curl: (28) Connection timed out after 3002 milliseconds
curl: (28) Connection timed out after 3006 milliseconds
POST 202
hacked
```

Reads work and Redis and the frontend stay closed, but the "read-only" reporter could also **overwrite** data.
NetworkPolicies work on L3/L4 (IPs, ports, protocols). They cannot tell `GET` from `POST` or check paths. For that
you need L7 authorization: in the app itself, an API gateway, or a service mesh. Clean up with
`kubectl delete namespace lab-02-07 lab-02-07-ext`.
</details>

---

## Lab 2.8: Letting monitoring in: namespaceSelector and podSelector, AND vs OR

**Scenario** – The `shop` team isolates its namespace, and Prometheus (running in the `monitoring` namespace) must
still scrape the metrics port 9797. The first attempt looks right in review but lets Grafana in, the second lets a
developer's private Prometheus in from another namespace, and both quietly break the shop for its own users. You will
learn to read the YAML structure that makes the difference between AND and OR, one of the most common
NetworkPolicy bugs.

**What you'll learn**
- `from: [ {namespaceSelector}, {podSelector} ]` (two peers, **OR**) vs `from: [ {namespaceSelector, podSelector} ]` (one peer, **AND**)
- What an empty `namespaceSelector: {}` means
- That the first policy selecting a Pod isolates it for **all** other ingress, too
- Selecting namespaces with the immutable `kubernetes.io/metadata.name` label

### Steps

1. Create the app namespace, the monitoring namespace (with `prometheus` and `grafana`) and a developer namespace
   with its own `prometheus`.

   ```bash
   workstation$ for n in lab-02-08 lab-02-08-monitoring lab-02-08-dev; do kubectl create namespace $n; done
   workstation$ kubectl -n lab-02-08-monitoring run prometheus --image=curlimages/curl:8.23.0 --labels=app=prometheus --command -- sleep infinity
   workstation$ kubectl -n lab-02-08-monitoring run grafana --image=curlimages/curl:8.23.0 --labels=app=grafana --command -- sleep infinity
   workstation$ kubectl -n lab-02-08-dev run prometheus --image=curlimages/curl:8.23.0 --labels=app=prometheus --command -- sleep infinity
   workstation$ kubectl apply -f - <<'EOF'
   apiVersion: apps/v1
   kind: Deployment
   metadata:
     name: shop
     namespace: lab-02-08
   spec:
     replicas: 1
     selector:
       matchLabels:
         app: shop
     template:
       metadata:
         labels:
           app: shop
       spec:
         containers:
         - name: podinfo
           image: ghcr.io/stefanprodan/podinfo:6.17.0
           command: ["./podinfo", "--port=9898", "--port-metrics=9797"]
           ports:
           - name: http
             containerPort: 9898
           - name: metrics
             containerPort: 9797
   ---
   apiVersion: v1
   kind: Service
   metadata:
     name: shop
     namespace: lab-02-08
   spec:
     selector:
       app: shop
     ports:
     - name: http
       port: 80
       targetPort: http
     - name: metrics
       port: 9797
       targetPort: metrics
   EOF
   workstation$ kubectl -n lab-02-08 rollout status deploy/shop
   ```

   Define a small helper that scrapes from all three Pods:

   ```bash
   workstation$ scrape() { for p in lab-02-08-monitoring/prometheus lab-02-08-monitoring/grafana lab-02-08-dev/prometheus; do
       printf '%-32s' $p; kubectl -n ${p%/*} exec ${p#*/} -- curl -s -m2 -o /dev/null -w '%{http_code}\n' http://shop.lab-02-08:9797/metrics; done 2>&1 | grep -v 'command terminated'; }
   workstation$ scrape
   ```

   Expected (`000` = timeout):
   ```
   lab-02-08-monitoring/prometheus 200
   lab-02-08-monitoring/grafana    200
   lab-02-08-dev/prometheus        200
   ```

2. Attempt 1: "from the monitoring namespace and from Prometheus". Note the **two dashes** under `from`.

   ```bash
   workstation$ kubectl apply -f - <<'EOF'
   apiVersion: networking.k8s.io/v1
   kind: NetworkPolicy
   metadata:
     name: allow-metrics-scrape
     namespace: lab-02-08
   spec:
     podSelector:
       matchLabels:
         app: shop
     policyTypes: ["Ingress"]
     ingress:
     - from:
       - namespaceSelector:
           matchLabels:
             kubernetes.io/metadata.name: lab-02-08-monitoring
       - podSelector:
           matchLabels:
             app: prometheus
       ports:
       - protocol: TCP
         port: 9797
   EOF
   workstation$ kubectl -n lab-02-08 describe netpol allow-metrics-scrape | sed -n '/Allowing ingress/,/Not affecting/p'
   workstation$ scrape
   ```

   Expected:
   ```
     Allowing ingress traffic:
       To Port: 9797/TCP
       From:
         NamespaceSelector: kubernetes.io/metadata.name=lab-02-08-monitoring
       From:
         PodSelector: app=prometheus
     Not affecting egress traffic
   lab-02-08-monitoring/prometheus 200
   lab-02-08-monitoring/grafana    200
   lab-02-08-dev/prometheus        000
   ```

   Why: two list items are two peers, ORed: "any Pod in `lab-02-08-monitoring`" **or** "Pods labelled
   `app=prometheus` in the policy's own namespace `lab-02-08`". Grafana gets in. `describe` shows it clearly: two
   separate `From:` blocks.

3. Attempt 2: one peer with both selectors, but "any namespace" written as `namespaceSelector: {}`.

   ```bash
   workstation$ kubectl apply -f - <<'EOF'
   apiVersion: networking.k8s.io/v1
   kind: NetworkPolicy
   metadata:
     name: allow-metrics-scrape
     namespace: lab-02-08
   spec:
     podSelector:
       matchLabels:
         app: shop
     policyTypes: ["Ingress"]
     ingress:
     - from:
       - namespaceSelector: {}
         podSelector:
           matchLabels:
             app: prometheus
       ports:
       - protocol: TCP
         port: 9797
   EOF
   workstation$ kubectl -n lab-02-08 describe netpol allow-metrics-scrape | sed -n '/From:/,/Not affecting/p'
   workstation$ scrape
   ```

   Expected:
   ```
       From:
         NamespaceSelector: <none>
         PodSelector: app=prometheus
     Not affecting egress traffic
   lab-02-08-monitoring/prometheus 200
   lab-02-08-monitoring/grafana    000
   lab-02-08-dev/prometheus        200
   ```

   Why: one item = AND, but `{}` selects **every** namespace. Anyone who can create a Pod labelled
   `app=prometheus` anywhere in the cluster can scrape (and the same trick works for any port you open this way).

4. The correct version: one peer, **both** selectors, with a specific namespace.

   ```bash
   workstation$ kubectl apply -f - <<'EOF'
   apiVersion: networking.k8s.io/v1
   kind: NetworkPolicy
   metadata:
     name: allow-metrics-scrape
     namespace: lab-02-08
   spec:
     podSelector:
       matchLabels:
         app: shop
     policyTypes: ["Ingress"]
     ingress:
     - from:
       - namespaceSelector:
           matchLabels:
             kubernetes.io/metadata.name: lab-02-08-monitoring
         podSelector:
           matchLabels:
             app: prometheus
       ports:
       - protocol: TCP
         port: 9797
   EOF
   workstation$ kubectl -n lab-02-08 describe netpol allow-metrics-scrape | sed -n '/From:/,/Not affecting/p'
   workstation$ scrape
   ```

   Expected:
   ```
       From:
         NamespaceSelector: kubernetes.io/metadata.name=lab-02-08-monitoring
         PodSelector: app=prometheus
     Not affecting egress traffic
   lab-02-08-monitoring/prometheus 200
   lab-02-08-monitoring/grafana    000
   lab-02-08-dev/prometheus        000
   ```

5. The hidden casualty: the shop's own users. Check the application port from inside `lab-02-08`.

   ```bash
   workstation$ kubectl -n lab-02-08 run self --image=curlimages/curl:8.23.0 --command -- sleep 600
   workstation$ kubectl -n lab-02-08 wait --for=condition=Ready pod/self
   workstation$ kubectl -n lab-02-08 exec self -- curl -sS -m2 -o /dev/null -w '%{http_code}\n' http://shop/
   ```

   Expected:
   ```
   curl: (28) Connection timed out after 2001 milliseconds
   ```

   Why: we never wrote a default deny, but as soon as **any** ingress policy selects a Pod, that Pod is isolated
   for ingress and only what some policy allows gets through. The "monitoring" policy silently took the shop
   offline. Allow the app port explicitly (here: from Pods in the same namespace):

   ```bash
   workstation$ kubectl apply -f - <<'EOF'
   apiVersion: networking.k8s.io/v1
   kind: NetworkPolicy
   metadata:
     name: allow-app-traffic
     namespace: lab-02-08
   spec:
     podSelector:
       matchLabels:
         app: shop
     policyTypes: ["Ingress"]
     ingress:
     - from:
       - podSelector: {}
       ports:
       - protocol: TCP
         port: 9898
   EOF
   workstation$ kubectl -n lab-02-08 exec self -- curl -sS -m2 -o /dev/null -w '%{http_code}\n' http://shop/
   workstation$ kubectl -n lab-02-08 exec self -- curl -sS -m2 -o /dev/null -w '%{http_code}\n' http://shop:9797/metrics
   ```

   Expected:
   ```
   200
   curl: (28) Connection timed out after 2002 milliseconds
   ```

   The two policies add up per port: same-namespace Pods get 9898, only the monitoring Prometheus gets 9797.

### Clean up

```bash
workstation$ kubectl delete namespace lab-02-08 lab-02-08-monitoring lab-02-08-dev
```

### Your turn

The monitoring team adds a second, disaster-recovery Prometheus in a new namespace `lab-02-08-monitoring-dr`.
1. Allow both monitoring Prometheus instances to scrape, using a namespace label `monitoring: "true"` that you put on
   both monitoring namespaces.
2. Then play the developer: label `lab-02-08-dev` with `monitoring=true`. What happens, and what does that mean for
   who may edit namespace labels?
3. Rewrite the policy so that relabelling cannot be abused, and try to fake the label you used.

<details>
<summary>Solution</summary>

Redo step 1 if you cleaned up. Create the DR namespace and label the monitoring namespaces:

```bash
workstation$ kubectl create namespace lab-02-08-monitoring-dr
workstation$ kubectl -n lab-02-08-monitoring-dr run prometheus --image=curlimages/curl:8.23.0 --labels=app=prometheus --command -- sleep infinity
workstation$ kubectl label namespace lab-02-08-monitoring lab-02-08-monitoring-dr monitoring=true
workstation$ kubectl apply -f - <<'EOF'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-metrics-scrape
  namespace: lab-02-08
spec:
  podSelector:
    matchLabels:
      app: shop
  policyTypes: ["Ingress"]
  ingress:
  - from:
    - namespaceSelector:
        matchLabels:
          monitoring: "true"
      podSelector:
        matchLabels:
          app: prometheus
    ports:
    - protocol: TCP
      port: 9797
EOF
workstation$ scrape() { for p in lab-02-08-monitoring/prometheus lab-02-08-monitoring-dr/prometheus lab-02-08-monitoring/grafana lab-02-08-dev/prometheus; do
    printf '%-36s' $p; kubectl -n ${p%/*} exec ${p#*/} -- curl -s -m2 -o /dev/null -w '%{http_code}\n' http://shop.lab-02-08:9797/metrics; done 2>&1 | grep -v 'command terminated'; }
workstation$ scrape
```

Expected:
```
lab-02-08-monitoring/prometheus     200
lab-02-08-monitoring-dr/prometheus  200
lab-02-08-monitoring/grafana        000
lab-02-08-dev/prometheus            000
```

Now the developer labels their namespace:

```bash
workstation$ kubectl label namespace lab-02-08-dev monitoring=true
workstation$ scrape
```

Expected:
```
lab-02-08-dev/prometheus            200
```

Anyone allowed to `patch` Namespaces can join the "monitoring" group. Namespace objects are cluster-scoped, so
namespace admins normally cannot edit them, but this must be part of your RBAC review. The robust alternative is the
`kubernetes.io/metadata.name` label, which the API server sets on every namespace and always resets to its name:

```bash
workstation$ kubectl apply -f - <<'EOF'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-metrics-scrape
  namespace: lab-02-08
spec:
  podSelector:
    matchLabels:
      app: shop
  policyTypes: ["Ingress"]
  ingress:
  - from:
    - namespaceSelector:
        matchExpressions:
        - key: kubernetes.io/metadata.name
          operator: In
          values: ["lab-02-08-monitoring", "lab-02-08-monitoring-dr"]
      podSelector:
        matchLabels:
          app: prometheus
    ports:
    - protocol: TCP
      port: 9797
EOF
workstation$ scrape
workstation$ kubectl label namespace lab-02-08-dev kubernetes.io/metadata.name=lab-02-08-monitoring --overwrite
workstation$ kubectl get namespace lab-02-08-dev --show-labels
```

Expected:
```
lab-02-08-monitoring/prometheus     200
lab-02-08-monitoring-dr/prometheus  200
lab-02-08-monitoring/grafana        000
lab-02-08-dev/prometheus            000
namespace/lab-02-08-dev labeled
NAME            STATUS   AGE   LABELS
lab-02-08-dev   Active   3m    kubernetes.io/metadata.name=lab-02-08-dev,monitoring=true
```

The command "succeeds", but the API server immediately puts the real name back. Clean up with
`kubectl delete namespace lab-02-08 lab-02-08-monitoring lab-02-08-monitoring-dr lab-02-08-dev`.
</details>

---

## Lab 2.9: Egress lockdown: the backup job may only talk to S3

**Scenario** – The nightly backup Pod holds database dumps and S3 credentials. After a supply-chain incident in the
news ("compromised image exfiltrates data to the Internet"), the CISO demands that backup Pods may talk to exactly
one destination: the S3 endpoint `192.168.1.100:9000`, nothing else, not even the MinIO console on the same host.
You will write an egress allow-list with `ipBlock`, prove what is blocked with an attacker's toolkit that carries
the same labels, and see what the S3 server sees as the source address.

**What you'll learn**
- Egress policies with `ipBlock` for destinations outside the cluster, restricted by port
- That egress rules are per **IP and port** (same host, other port = blocked)
- How Calico's `natOutgoing` SNATs Pod traffic to the node IP, and why that matters for external firewalls
- `ipBlock` with `except` for "Internet yes, private networks no"

### Steps

1. Create the namespace, a backup Pod (MinIO client, credentials via `MC_HOST_s3`), a "probe" Pod with the **same
   label** (`app=backup`, standing in for a compromised backup image), and an internal web service.

   ```bash
   workstation$ kubectl create namespace lab-02-09
   workstation$ kubectl -n lab-02-09 run backup --image=pgsty/mc:RELEASE.2026-10-26T00-00-00Z --labels=app=backup \
       --env=MC_HOST_s3=http://minioadmin:minioadmin123@192.168.1.100:9000 --command -- sleep infinity
   workstation$ kubectl -n lab-02-09 run probe --image=nicolaka/netshoot:v0.16 --labels=app=backup --command -- sleep infinity
   workstation$ kubectl -n lab-02-09 run web --image=nginx:1.31-alpine --labels=app=web --port=80 --expose
   workstation$ kubectl -n lab-02-09 wait --for=condition=Ready pod --all
   workstation$ kubectl -n lab-02-09 exec backup -- mc ls s3
   ```

   Expected:
   ```
   [2026-11-04 02:18:28 UTC]     0B training-bucket/
   ```

2. Check what a backup Pod can reach today. Define a probe helper:

   ```bash
   workstation$ probe() { for u in http://192.168.1.100:9000/minio/health/live http://192.168.1.100:9001/ https://example.com/ http://web/ https://192.168.1.10:6443/version; do
       printf '%-45s' $u; kubectl -n lab-02-09 exec probe -- curl -sk -m3 -o /dev/null -w '%{http_code}\n' $u 2>/dev/null; done; }
   workstation$ probe
   ```

   Expected:
   ```
   http://192.168.1.100:9000/minio/health/live  200
   http://192.168.1.100:9001/                   200
   https://example.com/                         200
   http://web/                                  200
   https://192.168.1.10:6443/version            200
   ```

   S3 API, MinIO admin console, the Internet, other Pods and the Kubernetes API: all open.

3. Apply the egress allow-list: DNS (so that names still resolve) plus TCP 9000 on one IP.

   ```bash
   workstation$ kubectl apply -f - <<'EOF'
   apiVersion: networking.k8s.io/v1
   kind: NetworkPolicy
   metadata:
     name: backup-egress
     namespace: lab-02-09
   spec:
     podSelector:
       matchLabels:
         app: backup
     policyTypes: ["Egress"]
     egress:
     - to:
       - namespaceSelector:
           matchLabels:
             kubernetes.io/metadata.name: kube-system
         podSelector:
           matchLabels:
             k8s-app: kube-dns
       ports:
       - protocol: UDP
         port: 53
       - protocol: TCP
         port: 53
     - to:
       - ipBlock:
           cidr: 192.168.1.100/32
       ports:
       - protocol: TCP
         port: 9000
   EOF
   workstation$ probe
   ```

   Expected:
   ```
   http://192.168.1.100:9000/minio/health/live  200
   http://192.168.1.100:9001/                   000
   https://example.com/                         000
   http://web/                                  000
   https://192.168.1.10:6443/version            000
   ```

   Why: the two `egress` items are ORed, inside each item `to` and `ports` are ANDed. Only "CoreDNS on 53" or
   "192.168.1.100 on 9000" is allowed. Only Pods with `app=backup` are affected: `web` still has full egress.

4. Run the real backup: create a bucket and upload a "dump". Then try to exfiltrate it to a public S3 service.

   ```bash
   workstation$ kubectl -n lab-02-09 exec backup -- sh -c 'mc mb s3/lab-02-09-backups &&
       echo "-- pg_dump output --" > /tmp/db.sql &&
       mc cp -q /tmp/db.sql s3/lab-02-09-backups/db-$(date +%F).sql && mc ls s3/lab-02-09-backups'
   workstation$ kubectl -n lab-02-09 exec backup -- sh -c 'MC_HOST_play=https://Q3AM3UQ867SPQQA43P2F:x@play.min.io timeout 8 mc ls play; echo exit=$?'
   ```

   Expected:
   ```
   Bucket created successfully `s3/lab-02-09-backups`.
   `/tmp/db.sql` -> `s3/lab-02-09-backups/db-2026-11-04.sql`
   [2026-11-04 02:59:26 UTC]    21B STANDARD db-2026-11-04.sql
   exit=124
   ```

   The upload works, the connection to the public `play.min.io` hangs until `timeout` kills it (exit 124).

5. Look at the connection from the S3 server's side. Hold a connection open from the probe and list the connection
   tracking table on the client VM (MinIO runs there in Docker).

   ```bash
   workstation$ kubectl -n lab-02-09 get pod probe -o wide          # note the node, here node2
   workstation$ kubectl -n lab-02-09 exec probe -- sh -c 'sleep 15 | nc 192.168.1.100 9000'
   client-vm$   sudo grep -h 'dport=9000' /proc/net/nf_conntrack | head -3       # within 15 s
   ```

   Expected:
   ```
   ipv4     2 tcp      6 431991 ESTABLISHED src=192.168.1.12 dst=192.168.1.100 sport=42874 dport=9000 src=172.17.0.2 dst=192.168.1.12 ...
   ```

   Why: the Calico IP pool has `natOutgoing: true`, so traffic leaving the Pod network is SNATed to the **node IP**
   (`192.168.1.12` = node2). The NetworkPolicy is evaluated *before* SNAT on the real Pod, so it is precise, but an
   external firewall in front of the S3 server only sees node IPs and cannot tell a backup Pod from any other Pod on
   that node. That is why egress control belongs in the cluster.

### Clean up

```bash
workstation$ kubectl -n lab-02-09 exec backup -- mc rb --force s3/lab-02-09-backups
workstation$ kubectl delete namespace lab-02-09
```

### Your turn

The backup tool gets an "update check" feature that calls a vendor API over HTTPS on the Internet (IPs change all
the time, so you cannot list them). Allow **HTTPS (443) to the public Internet** for the backup Pods, but keep every
private range (`10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`, which includes the Pod, Service and node networks)
closed, except the S3 rule you already have. Do not edit the existing policy. Verify with the probe Pod, including
`http://example.com` (port 80) and the Kubernetes API via its ClusterIP `https://10.96.0.1`.

<details>
<summary>Solution</summary>

Redo steps 1 and 3 if you cleaned up. Add a second policy, which is ORed with the first one:

```bash
workstation$ kubectl apply -f - <<'EOF'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: backup-egress-internet
  namespace: lab-02-09
spec:
  podSelector:
    matchLabels:
      app: backup
  policyTypes: ["Egress"]
  egress:
  - to:
    - ipBlock:
        cidr: 0.0.0.0/0
        except:
        - 10.0.0.0/8
        - 172.16.0.0/12
        - 192.168.0.0/16
    ports:
    - protocol: TCP
      port: 443
EOF
workstation$ for u in http://192.168.1.100:9000/minio/health/live http://192.168.1.100:9001/ https://example.com/ http://example.com/ http://web/ https://192.168.1.10:6443/version https://10.96.0.1/version; do
    printf '%-45s' $u; kubectl -n lab-02-09 exec probe -- curl -sk -m3 -o /dev/null -w '%{http_code}\n' $u 2>/dev/null; done
```

Expected:
```
http://192.168.1.100:9000/minio/health/live  200
http://192.168.1.100:9001/                   000
https://example.com/                         200
http://example.com/                          000
http://web/                                  000
https://192.168.1.10:6443/version            000
https://10.96.0.1/version                    000
```

Public HTTPS works, plain HTTP does not (port), and everything private stays closed: the Kubernetes API is blocked
both by IP and via its ClusterIP, because `10.96.0.1:443` is DNATed to `192.168.1.10:6443` before the policy is
checked. S3 on 9000 still works thanks to the first policy. Note that `except` must lie inside `cidr`. Clean up as
above.
</details>

---

## Lab 2.10: Admin panel reachable only from the office network

**Scenario** – An internal admin panel is exposed through a MetalLB LoadBalancer. Compliance requires that it is
reachable **only** from the office admin workstation (the client VM `192.168.1.100`) and not from other Pods, other
teams' namespaces or anywhere else. The first attempt, a NetworkPolicy with an `ipBlock`, works "sometimes",
which is the worst kind of bug. You will find out why, fix it with `externalTrafficPolicy: Local`, and verify
denied sources too.

**What you'll learn**
- Why `ipBlock` policies for external clients need the client IP to survive (no SNAT)
- How `externalTrafficPolicy: Cluster` causes *intermittent* failures with source-IP policies
- How to verify allowed **and** denied sources (client VM, Pods, nodes)
- That the node itself can always reach its local Pods with Calico (a property you should know about)

### Steps

1. Deploy the admin panel with one replica per worker and a LoadBalancer Service (default
   `externalTrafficPolicy: Cluster`), plus a Pod in another namespace that will act as "another team".

   ```bash
   workstation$ kubectl create namespace lab-02-10
   workstation$ kubectl create namespace lab-02-10-other
   workstation$ kubectl -n lab-02-10-other run shell --image=nicolaka/netshoot:v0.16 --command -- sleep infinity
   workstation$ kubectl apply -f - <<'EOF'
   apiVersion: apps/v1
   kind: Deployment
   metadata:
     name: admin
     namespace: lab-02-10
   spec:
     replicas: 2
     selector:
       matchLabels:
         app: admin
     template:
       metadata:
         labels:
           app: admin
       spec:
         topologySpreadConstraints:
         - maxSkew: 1
           topologyKey: kubernetes.io/hostname
           whenUnsatisfiable: DoNotSchedule
           nodeTaintsPolicy: Honor
           labelSelector:
             matchLabels:
               app: admin
         containers:
         - name: whoami
           image: traefik/whoami:v1.12.0
           args: ["--name=admin-panel"]
           ports:
           - name: http
             containerPort: 80
   ---
   apiVersion: v1
   kind: Service
   metadata:
     name: admin
     namespace: lab-02-10
   spec:
     type: LoadBalancer
     selector:
       app: admin
     ports:
     - name: http
       port: 80
       targetPort: http
   EOF
   workstation$ kubectl -n lab-02-10 get svc admin
   workstation$ kubectl -n lab-02-10 get pods -o wide
   ```

   Expected:
   ```
   NAME    TYPE           CLUSTER-IP    EXTERNAL-IP     PORT(S)        AGE
   admin   LoadBalancer   10.99.47.96   192.168.1.242   80:32595/TCP   5s

   NAME                     READY   STATUS    RESTARTS   AGE   IP               NODE
   admin-84dd7df756-kcv59   1/1     Running   0          5s    172.16.104.16    node2
   admin-84dd7df756-phjrj   1/1     Running   0          5s    172.16.166.142   node1
   ```

2. Check access from the office (client VM) before any policy.

   ```bash
   client-vm$ LB=192.168.1.242     # your EXTERNAL-IP
   client-vm$ for i in 1 2 3 4; do curl -sS -m3 http://$LB/ 2>&1 | grep -E '^Name|RemoteAddr|curl' | tr '\n' ' '; echo; done
   ```

   Expected:
   ```
   Name: admin-panel RemoteAddr: 192.168.1.11:60174
   Name: admin-panel RemoteAddr: 172.16.166.128:15801
   Name: admin-panel RemoteAddr: 192.168.1.11:42153
   Name: admin-panel RemoteAddr: 172.16.166.128:2703
   ```

   As in Lab 2.2, the client IP is replaced by node1's address (the node MetalLB announces from) or its tunnel
   address.

3. Apply the "office only" policy.

   ```bash
   workstation$ kubectl apply -f - <<'EOF'
   apiVersion: networking.k8s.io/v1
   kind: NetworkPolicy
   metadata:
     name: admin-from-office
     namespace: lab-02-10
   spec:
     podSelector:
       matchLabels:
         app: admin
     policyTypes: ["Ingress"]
     ingress:
     - from:
       - ipBlock:
           cidr: 192.168.1.100/32
       ports:
       - protocol: TCP
         port: 80
   EOF
   client-vm$ for i in 1 2 3 4; do curl -sS -m3 http://$LB/ 2>&1 | grep -E '^Name|RemoteAddr|curl' | tr '\n' ' '; echo; done
   ```

   Expected:
   ```
   Name: admin-panel RemoteAddr: 192.168.1.11:19603
   curl: (28) Connection timed out after 3002 milliseconds
   curl: (28) Connection timed out after 3016 milliseconds
   Name: admin-panel RemoteAddr: 192.168.1.11:15398
   ```

   Why does it work *sometimes*? node1 receives every request. When kube-proxy picks the Pod on node1, Calico
   checks the policy in node1's forwarding path while the source is still `192.168.1.100` (the SNAT happens later,
   on the way out), so it passes. When it picks the Pod on node2, the packet arrives at node2 already SNATed to
   node1's tunnel IP `172.16.166.128`, which is not in the allow-list, so it is dropped. A policy based on client IPs
   needs the client IP to reach the node that runs the Pod.

4. Preserve the client IP with `externalTrafficPolicy: Local`.

   ```bash
   workstation$ kubectl -n lab-02-10 patch svc admin -p '{"spec":{"externalTrafficPolicy":"Local"}}'
   client-vm$   for i in 1 2 3 4 5 6; do curl -sS -m3 http://$LB/ 2>&1 | grep -E '^Hostname|RemoteAddr|curl' | tr '\n' ' '; echo; done
   ```

   Expected:
   ```
   Hostname: admin-84dd7df756-phjrj RemoteAddr: 192.168.1.100:34906
   Hostname: admin-84dd7df756-phjrj RemoteAddr: 192.168.1.100:34922
   Hostname: admin-84dd7df756-phjrj RemoteAddr: 192.168.1.100:34934
   Hostname: admin-84dd7df756-phjrj RemoteAddr: 192.168.1.100:34938
   Hostname: admin-84dd7df756-phjrj RemoteAddr: 192.168.1.100:34946
   Hostname: admin-84dd7df756-phjrj RemoteAddr: 192.168.1.100:34960
   ```

   Every request works and shows the real client. Note that in MetalLB L2 mode one node owns the IP, so only the
   Pod on that node (node1) receives external traffic; the second replica is a hot standby for failover.

5. A rule is only verified when you have also seen it **deny**. Try from another team's Pod (via the LB IP and via
   the ClusterIP) and from a node.

   ```bash
   workstation$ X="kubectl -n lab-02-10-other exec shell --"
   workstation$ for u in http://192.168.1.242/ http://admin.lab-02-10/; do printf '%-28s' $u; $X curl -s -m3 -o /dev/null -w '%{http_code}\n' $u; done
   node2$ for i in 1 2 3 4; do curl -sS -m3 http://192.168.1.242/ 2>&1 | grep -E 'RemoteAddr|curl'; done
   ```

   Expected:
   ```
   http://192.168.1.242/       000
   http://admin.lab-02-10/     000

   RemoteAddr: 192.168.1.12:44103
   RemoteAddr: 192.168.1.12:23001
   RemoteAddr: 192.168.1.12:3249
   curl: (28) Connection timed out after 3139 milliseconds
   ```

   Why: Pods are denied on every path, because the policy protects the Pod, not one particular address. The node
   result is mixed: kube-proxy sends node-originated traffic to any endpoint. Connections to the **remote** Pod are
   dropped, but node2 always reaches its **local** Pod. Calico allows traffic from a host to its own Pods
   unconditionally, otherwise kubelet probes would break. NetworkPolicy does not protect Pods from their own node.
   Anyone with root on a node is inside the trust boundary anyway.

### Clean up

```bash
workstation$ kubectl delete namespace lab-02-10 lab-02-10-other      # releases the MetalLB IP
```

### Your turn

A colleague proposes a "simpler" solution: drop the NetworkPolicy and set `loadBalancerSourceRanges:
["192.168.1.100/32"]` on the Service, "that's what it's for". Test that proposal from the client VM and from the
other team's Pod: via the LB IP, the ClusterIP and the node port. Is it equivalent? What would you recommend?

<details>
<summary>Solution</summary>

Redo steps 1 and 4 if you cleaned up (`externalTrafficPolicy: Local`, no NetworkPolicy yet). Then:

```bash
workstation$ kubectl -n lab-02-10 delete netpol admin-from-office --ignore-not-found
workstation$ kubectl -n lab-02-10 patch svc admin -p '{"spec":{"loadBalancerSourceRanges":["192.168.1.100/32"]}}'
workstation$ NP=$(kubectl -n lab-02-10 get svc admin -o jsonpath='{.spec.ports[0].nodePort}')
workstation$ X="kubectl -n lab-02-10-other exec shell --"
workstation$ for u in http://192.168.1.242/ http://admin.lab-02-10/ http://192.168.1.11:$NP/; do printf '%-28s' $u; $X curl -s -m3 -o /dev/null -w '%{http_code}\n' $u; done
client-vm$   curl -s -m3 -o /dev/null -w '%{http_code}\n' http://$LB/
```

Expected:
```
http://192.168.1.242/       000
http://admin.lab-02-10/     200
http://192.168.1.11:32595/  200

200
```

`loadBalancerSourceRanges` is enforced by kube-proxy (or a cloud load balancer) **only for the LoadBalancer IP**.
The ClusterIP and the node port bypass it, so any Pod in the cluster can still open the admin panel. Not equivalent.

Recommendation: defense in depth. Keep `loadBalancerSourceRanges` (on a cloud provider, it filters traffic before it
even reaches your nodes) **and** the NetworkPolicy, which protects the Pod on every path:

```bash
workstation$ kubectl apply -f - <<'EOF'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: admin-from-office
  namespace: lab-02-10
spec:
  podSelector:
    matchLabels:
      app: admin
  policyTypes: ["Ingress"]
  ingress:
  - from:
    - ipBlock:
        cidr: 192.168.1.100/32
    ports:
    - protocol: TCP
      port: 80
EOF
workstation$ for u in http://192.168.1.242/ http://admin.lab-02-10/ http://192.168.1.11:$NP/; do printf '%-28s' $u; $X curl -s -m3 -o /dev/null -w '%{http_code}\n' $u; done
client-vm$   curl -s -m3 -o /dev/null -w '%{http_code}\n' http://$LB/
```

Expected:
```
http://192.168.1.242/       000
http://admin.lab-02-10/     000
http://192.168.1.11:32595/  000

200
```

Clean up with `kubectl delete namespace lab-02-10 lab-02-10-other`.
</details>
