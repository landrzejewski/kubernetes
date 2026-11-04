# Module 03: Gateway API

Gateway API is the successor of Ingress: infrastructure teams own `Gateway`s (listeners, IPs, certificates) and
application teams own `HTTPRoute`s (hosts, paths, filters, backends). In this module you drive NGINX Gateway Fabric
(NGF) through realistic scenarios—multi-app hosting, microservice paths, TLS, header manipulation, multi-tenancy—and
learn to read the status conditions that tell you *why* a route does not work.

## Prerequisites check

```bash
workstation$ kubectl get gatewayclass nginx                 # ACCEPTED=True
workstation$ kubectl get crd httproutes.gateway.networking.k8s.io referencegrants.gateway.networking.k8s.io
workstation$ kubectl get ipaddresspool -n metallb-system    # 192.168.1.240-192.168.1.250
client-vm$   curl --version | head -1                       # curl is available on the client VM
```

Every `Gateway` you create gets its own NGINX data-plane Deployment and a `LoadBalancer` Service from the MetalLB pool
(only 11 addresses). **Delete each lab's namespace when you are done**, so the address returns to the pool.

## Table of contents

- [Lab 3.1: Anatomy of a Gateway – from 404 to first response](#lab-31-anatomy-of-a-gateway--from-404-to-first-response)
- [Lab 3.2: One IP, many websites – host-based routing](#lab-32-one-ip-many-websites--host-based-routing)
- [Lab 3.3: Microservices behind one domain – path routing and URL rewrite](#lab-33-microservices-behind-one-domain--path-routing-and-url-rewrite)
- [Lab 3.4: Beta users, API versions and read-only traffic – header, query and method matching](#lab-34-beta-users-api-versions-and-read-only-traffic--header-query-and-method-matching)
- [Lab 3.5: HTTPS for the shop – TLS termination and HTTP→HTTPS redirect](#lab-35-https-for-the-shop--tls-termination-and-httphttps-redirect)
- [Lab 3.6: Security headers and request tagging – header modifiers](#lab-36-security-headers-and-request-tagging--header-modifiers)
- [Lab 3.7: A shared company Gateway – allowedRoutes and ReferenceGrant](#lab-37-a-shared-company-gateway--allowedroutes-and-referencegrant)
- [Lab 3.8: Why is my route not working? – troubleshooting from status](#lab-38-why-is-my-route-not-working--troubleshooting-from-status)

---

## Lab 3.1: Anatomy of a Gateway – from 404 to first response

**Scenario** – Your team is moving the `podinfo` web app from a `NodePort` Service to Gateway API. Before the
migration you want to understand exactly what NGINX Gateway Fabric creates when you apply a `Gateway`, which status
conditions prove that the configuration has been *accepted* and *programmed*, and what a client sees at each stage.

**What you'll learn**
- The three roles: `GatewayClass` (controller), `Gateway` (listeners + address), `HTTPRoute` (routing rules)
- How NGF provisions a per-Gateway `<gateway>-nginx` Deployment and `LoadBalancer` Service
- Reading `Accepted`, `Programmed`, `ResolvedRefs` conditions and `attachedRoutes`
- What a typo in `gatewayClassName` looks like

### Steps

1. Create the namespace and the application.

```bash
workstation$ kubectl create namespace lab-03-01
workstation$ kubectl apply -n lab-03-01 -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: podinfo
spec:
  replicas: 2
  selector:
    matchLabels: {app: podinfo}
  template:
    metadata:
      labels: {app: podinfo}
    spec:
      containers:
      - name: podinfo
        image: ghcr.io/stefanprodan/podinfo:6.17.0
        ports:
        - containerPort: 9898
---
apiVersion: v1
kind: Service
metadata:
  name: podinfo
spec:
  selector: {app: podinfo}
  ports:
  - port: 80
    targetPort: 9898
EOF
workstation$ kubectl -n lab-03-01 rollout status deploy/podinfo
```

2. Look at the `GatewayClass`. It is cluster-scoped and points to the controller that will implement your Gateways.

```bash
workstation$ kubectl get gatewayclass nginx
```

Expected:
```
NAME    CONTROLLER                                   ACCEPTED   AGE
nginx   gateway.nginx.org/nginx-gateway-controller   True       5m16s
```

3. Create a `Gateway` with a single HTTP listener on port 80.

```bash
workstation$ kubectl apply -n lab-03-01 -f - <<'EOF'
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: web
spec:
  gatewayClassName: nginx
  listeners:
  - name: http
    protocol: HTTP
    port: 80
EOF
workstation$ kubectl -n lab-03-01 get gateway
workstation$ kubectl -n lab-03-01 get deploy,svc
```

Expected:
```
NAME   CLASS   ADDRESS         PROGRAMMED   AGE
web    nginx   192.168.1.240   True         15s

NAME                        READY   UP-TO-DATE   AVAILABLE   AGE
deployment.apps/podinfo     2/2     2            2           17s
deployment.apps/web-nginx   1/1     1            1           15s

NAME                TYPE           CLUSTER-IP       EXTERNAL-IP     PORT(S)        AGE
service/podinfo     ClusterIP      10.101.171.205   <none>          80/TCP         17s
service/web-nginx   LoadBalancer   10.103.67.150    192.168.1.240   80:32214/TCP   15s
```

**Why:** NGF's control plane (namespace `nginx-gateway`) only *configures* NGINX. For every Gateway it provisions a
dedicated data plane, `web-nginx` (image `ghcr.io/nginx/nginx-gateway-fabric/nginx`), in the Gateway's namespace, and
exposes it with a `LoadBalancer` Service. MetalLB assigns the external IP, which is copied to the Gateway's
`status.addresses`. You never edit `web-nginx` directly; it is owned by the Gateway.

4. Read the Gateway's conditions—at Gateway level and per listener.

```bash
workstation$ kubectl -n lab-03-01 get gateway web \
  -o jsonpath='{range .status.conditions[*]}{.type}={.status} ({.reason}){"\n"}{end}'
workstation$ kubectl -n lab-03-01 get gateway web \
  -o jsonpath='{range .status.listeners[*]}{.name}: attachedRoutes={.attachedRoutes}{"\n"}{range .conditions[*]}  {.type}={.status} ({.reason}){"\n"}{end}{end}'
```

Expected:
```
Accepted=True (Accepted)
Programmed=True (Programmed)
http: attachedRoutes=0
  Programmed=True (Programmed)
  Accepted=True (Accepted)
  ResolvedRefs=True (ResolvedRefs)
  Conflicted=False (NoConflicts)
```

**Why:** `Accepted` means the configuration is valid; `Programmed` means it has been pushed to the data plane and an
address exists. `attachedRoutes=0` tells you that nobody routes through this listener yet.

5. Send a request from the client VM. Use the address from `kubectl get gateway`.

```bash
client-vm$ GW=192.168.1.240
client-vm$ curl -si http://$GW/ | head -1
```

Expected:
```
HTTP/1.1 404 Not Found
```

**Why:** the listener is up, but without a route NGINX has nowhere to send the request. A `404` with `Server: nginx`
is the typical "Gateway OK, route missing" symptom.

6. Attach an `HTTPRoute`. `parentRefs` says *which Gateway*, `backendRefs` says *which Service and port*.

```bash
workstation$ kubectl apply -n lab-03-01 -f - <<'EOF'
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: podinfo
spec:
  parentRefs:
  - name: web
  rules:
  - backendRefs:
    - name: podinfo
      port: 80
EOF
workstation$ kubectl -n lab-03-01 get httproute podinfo \
  -o jsonpath='{range .status.parents[*]}{.parentRef.name} by {.controllerName}{"\n"}{range .conditions[*]}  {.type}={.status} ({.reason}){"\n"}{end}{end}'
workstation$ kubectl -n lab-03-01 get gateway web -o jsonpath='{.status.listeners[0].attachedRoutes}{"\n"}'
```

Expected:
```
web by gateway.nginx.org/nginx-gateway-controller
  Accepted=True (Accepted)
  ResolvedRefs=True (ResolvedRefs)
1
```

**Why:** a route's status is reported **per parent** (one entry per Gateway it attaches to). `Accepted` = the Gateway
let the route attach; `ResolvedRefs` = all backends exist and are usable. Those two conditions are the first thing to
check when traffic does not flow (see Lab 3.8).

7. Test again—requests are load-balanced across both podinfo Pods.

```bash
client-vm$ curl -s http://$GW/ | head -4
client-vm$ for i in 1 2 3 4; do curl -s http://$GW/ | grep hostname; done
```

Expected:
```
{
  "hostname": "podinfo-57fdc6f4d7-9bw2n",
  "version": "6.17.0",
  "revision": "fd3a834ed8d14b80ea334cf8a2fddd4597924da6",
  "hostname": "podinfo-57fdc6f4d7-9bw2n",
  "hostname": "podinfo-57fdc6f4d7-9bw2n",
  "hostname": "podinfo-57fdc6f4d7-9bw2n",
  "hostname": "podinfo-57fdc6f4d7-fj7l6",
```

8. Pitfall: a typo in `gatewayClassName`. Nothing fails at `apply` time; the Gateway simply waits forever.

```bash
workstation$ kubectl apply -n lab-03-01 -f - <<'EOF'
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: typo
spec:
  gatewayClassName: ngnix
  listeners:
  - name: http
    protocol: HTTP
    port: 80
EOF
workstation$ kubectl -n lab-03-01 get gateway
workstation$ kubectl -n lab-03-01 get gateway typo \
  -o jsonpath='{range .status.conditions[*]}{.type}={.status} ({.reason}): {.message}{"\n"}{end}'
workstation$ kubectl -n lab-03-01 delete gateway typo
```

Expected:
```
NAME   CLASS   ADDRESS         PROGRAMMED   AGE
typo   ngnix                   Unknown      5s
web    nginx   192.168.1.240   True         44s
Accepted=Unknown (Pending): Waiting for controller
Programmed=Unknown (Pending): Waiting for controller
```

**Why:** no controller claims the class `ngnix`, so nobody writes status. `Unknown`/`Waiting for controller` always
means "check the class name".

9. Ownership: delete the Gateway and watch NGF remove its data plane (and release the IP). The route remains, but
it has no parents anymore.

```bash
workstation$ kubectl -n lab-03-01 delete gateway web
workstation$ kubectl -n lab-03-01 get deploy,svc
workstation$ kubectl -n lab-03-01 get httproute podinfo -o jsonpath='{.status}{"\n"}'
```

Expected:
```
NAME                      READY   UP-TO-DATE   AVAILABLE   AGE
deployment.apps/podinfo   2/2     2            2           103s

NAME              TYPE        CLUSTER-IP       EXTERNAL-IP   PORT(S)   AGE
service/podinfo   ClusterIP   10.101.171.205   <none>        80/TCP    103s
{"parents":[]}
```

### Clean up

```bash
workstation$ kubectl delete namespace lab-03-01
```

### Your turn

The SRE team wants to scrape podinfo's Prometheus endpoint `/metrics` through the Gateway, but **only on a separate
port 9090**, never on the public port 80. Recreate the namespace, app and Gateway (steps 1–6), then:
1. add a second listener `ops` (HTTP, port 9090) to the Gateway,
2. create a route `podinfo-ops` that attaches *only* to `ops` and forwards only `/metrics`,
3. make sure the public route attaches only to `http` and that `http://$GW/metrics` no longer returns metrics.

<details><summary>Solution</summary>

`sectionName` in `parentRefs` binds a route to one listener. A route *without* `sectionName` attaches to **every**
listener of the Gateway—a common way to leak internal endpoints. Rules are matched most-specific-first, so a
`/metrics` rule without `backendRefs` "swallows" the path on the public listener (NGF answers `500`, as the
Gateway API spec requires for a rule with no backends).

```bash
workstation$ kubectl apply -n lab-03-01 -f - <<'EOF'
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: web
spec:
  gatewayClassName: nginx
  listeners:
  - name: http
    protocol: HTTP
    port: 80
  - name: ops
    protocol: HTTP
    port: 9090
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: podinfo
spec:
  parentRefs:
  - name: web
    sectionName: http
  rules:
  - backendRefs:
    - name: podinfo
      port: 80
  - matches:                # block /metrics on the public listener
    - path:
        type: PathPrefix
        value: /metrics
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: podinfo-ops
spec:
  parentRefs:
  - name: web
    sectionName: ops
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /metrics
    backendRefs:
    - name: podinfo
      port: 80
EOF
workstation$ kubectl -n lab-03-01 get svc web-nginx
workstation$ kubectl -n lab-03-01 get gateway web \
  -o jsonpath='{range .status.listeners[*]}{.name}: attachedRoutes={.attachedRoutes}{"\n"}{end}'
```

Expected (NGF adds the new port to the existing LoadBalancer Service):
```
NAME        TYPE           CLUSTER-IP      EXTERNAL-IP     PORT(S)                       AGE
web-nginx   LoadBalancer   10.103.67.150   192.168.1.240   80:32214/TCP,9090:31371/TCP   74s
http: attachedRoutes=1
ops: attachedRoutes=1
```

Verify:
```bash
client-vm$ curl -s http://$GW:9090/metrics | grep -m2 http_request
client-vm$ curl -s -o /dev/null -w '%{http_code}\n' http://$GW:9090/          # 404: only /metrics on ops
client-vm$ curl -s -o /dev/null -w '%{http_code}\n' http://$GW/metrics        # 500: blocked on public port
client-vm$ curl -s -o /dev/null -w '%{http_code}\n' http://$GW/env            # 200: app still works
```

Expected:
```
# HELP http_request_duration_seconds Seconds spent serving HTTP requests.
# TYPE http_request_duration_seconds histogram
404
500
200
```

Clean up: `kubectl delete namespace lab-03-01`.
</details>

---

## Lab 3.2: One IP, many websites – host-based routing

**Scenario** – ACME runs its shop and its blog on separate teams' Deployments, but marketing owns only one public IP
and wants every new `*.acme.lab` subdomain to show a "Coming soon" page until the site is ready. You will serve all
of them from a single Gateway listener and let the HTTP `Host` header decide where each request goes.

**What you'll learn**
- Listener `hostname` (wildcard) vs. route `hostnames`
- Testing virtual hosts without DNS: `curl -H 'Host: …'` and `curl --resolve`
- Precedence: an exact hostname beats a wildcard
- Why a hostname in a route can be silently ignored

### Steps

1. Create the namespace and three apps: the shop (podinfo with a custom message), the blog (`whoami`) and a
   "Coming soon" page.

```bash
workstation$ kubectl create namespace lab-03-02
workstation$ kubectl apply -n lab-03-02 -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: shop
spec:
  selector:
    matchLabels: {app: shop}
  template:
    metadata:
      labels: {app: shop}
    spec:
      containers:
      - name: podinfo
        image: ghcr.io/stefanprodan/podinfo:6.17.0
        env:
        - name: PODINFO_UI_MESSAGE
          value: "Welcome to the ACME shop"
        ports:
        - containerPort: 9898
---
apiVersion: v1
kind: Service
metadata:
  name: shop
spec:
  selector: {app: shop}
  ports:
  - port: 80
    targetPort: 9898
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: blog
spec:
  selector:
    matchLabels: {app: blog}
  template:
    metadata:
      labels: {app: blog}
    spec:
      containers:
      - name: whoami
        image: traefik/whoami:v1.12.0
        args: ["--name=acme-blog"]
        ports:
        - containerPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: blog
spec:
  selector: {app: blog}
  ports:
  - port: 80
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: coming-soon
spec:
  selector:
    matchLabels: {app: coming-soon}
  template:
    metadata:
      labels: {app: coming-soon}
    spec:
      containers:
      - name: podinfo
        image: ghcr.io/stefanprodan/podinfo:6.17.0
        env:
        - name: PODINFO_UI_MESSAGE
          value: "Coming soon!"
        ports:
        - containerPort: 9898
---
apiVersion: v1
kind: Service
metadata:
  name: coming-soon
spec:
  selector: {app: coming-soon}
  ports:
  - port: 80
    targetPort: 9898
EOF
```

2. Create a Gateway whose listener accepts only `*.acme.lab`, and one route per website.

```bash
workstation$ kubectl apply -n lab-03-02 -f - <<'EOF'
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: acme
spec:
  gatewayClassName: nginx
  listeners:
  - name: acme-lab
    protocol: HTTP
    port: 80
    hostname: "*.acme.lab"
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: shop
spec:
  parentRefs:
  - name: acme
  hostnames:
  - shop.acme.lab
  rules:
  - backendRefs:
    - name: shop
      port: 80
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: blog
spec:
  parentRefs:
  - name: acme
  hostnames:
  - blog.acme.lab
  rules:
  - backendRefs:
    - name: blog
      port: 80
EOF
workstation$ kubectl -n lab-03-02 get gateway,httproute
```

Expected:
```
NAME                                     CLASS   ADDRESS         PROGRAMMED   AGE
gateway.gateway.networking.k8s.io/acme   nginx   192.168.1.240   True         6s

NAME                                       HOSTNAMES           AGE
httproute.gateway.networking.k8s.io/blog   ["blog.acme.lab"]   6s
httproute.gateway.networking.k8s.io/shop   ["shop.acme.lab"]   6s
```

3. There is no DNS for `acme.lab`. Two ways to test from the client VM: set the `Host` header, or make curl resolve
   the name to the Gateway IP with `--resolve` (closer to a real browser, and required for TLS/SNI later).

```bash
client-vm$ GW=192.168.1.240        # ADDRESS of the Gateway
client-vm$ curl -s -H 'Host: shop.acme.lab' http://$GW/ | grep message
client-vm$ curl -s --resolve blog.acme.lab:80:$GW http://blog.acme.lab/ | grep -E 'Name|Host:'
client-vm$ curl -si http://$GW/ | head -1                                   # no Host match (IP only)
client-vm$ curl -si -H 'Host: news.acme.lab' http://$GW/ | head -1          # no route for news yet
```

Expected:
```
  "message": "Welcome to the ACME shop",
Name: acme-blog
Host: blog.acme.lab
X-Forwarded-Host: blog.acme.lab
HTTP/1.1 404 Not Found
HTTP/1.1 404 Not Found
```

**Why:** NGINX builds one `server` block per hostname. Requests whose `Host` does not match any route hostname end
in a default server that returns `404`.

4. Add the "Coming soon" catch-all for every other subdomain.

```bash
workstation$ kubectl apply -n lab-03-02 -f - <<'EOF'
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: coming-soon
spec:
  parentRefs:
  - name: acme
  hostnames:
  - "*.acme.lab"
  rules:
  - backendRefs:
    - name: coming-soon
      port: 80
EOF
client-vm$ for h in shop blog news careers; do printf '%-18s ' $h.acme.lab; \
             curl -s -H "Host: $h.acme.lab" http://$GW/ | grep -E '"message|^Name'; done
client-vm$ curl -si -H 'Host: acme.lab' http://$GW/ | head -1
```

Expected:
```
shop.acme.lab        "message": "Welcome to the ACME shop",
blog.acme.lab      Name: acme-blog
news.acme.lab        "message": "Coming soon!",
careers.acme.lab     "message": "Coming soon!",
HTTP/1.1 404 Not Found
```

**Why:** exact hostnames take precedence over wildcards, no matter in which order the routes were created. Note that
`*.acme.lab` does **not** match the apex domain `acme.lab`—the wildcard requires at least one extra label.

5. The listener has `attachedRoutes=3` now—each route counts once per listener it attaches to.

```bash
workstation$ kubectl -n lab-03-02 get gateway acme -o jsonpath='{.status.listeners[0].attachedRoutes}{"\n"}'
```

Expected:
```
3
```

### Clean up

```bash
workstation$ kubectl delete namespace lab-03-02
```

### Your turn

Marketing bought a second domain, `acme-shop.lab`, and wants the shop available there too. Add the hostname to the
`shop` route first and test it—explain the result—and then make it work **without** creating a second Gateway
(one IP only!).

<details><summary>Solution</summary>

Adding the hostname to the route alone does not help:

```bash
workstation$ kubectl -n lab-03-02 patch httproute shop --type=json \
  -p '[{"op":"add","path":"/spec/hostnames/-","value":"acme-shop.lab"}]'
client-vm$ curl -si -H 'Host: acme-shop.lab' http://$GW/ | head -1
```

Expected:
```
HTTP/1.1 404 Not Found
```

**Why:** the effective hostnames of a route are the *intersection* of route `hostnames` and listener `hostname`.
`acme-shop.lab` does not match `*.acme.lab`, so it is dropped silently (the route is still `Accepted`, because
`shop.acme.lab` still intersects). The Gateway owner must open the domain with another listener—listeners on the same
port are allowed as long as their hostnames differ:

```bash
workstation$ kubectl apply -n lab-03-02 -f - <<'EOF'
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: acme
spec:
  gatewayClassName: nginx
  listeners:
  - name: acme-lab
    protocol: HTTP
    port: 80
    hostname: "*.acme.lab"
  - name: acme-shop
    protocol: HTTP
    port: 80
    hostname: "acme-shop.lab"
EOF
workstation$ kubectl -n lab-03-02 get gateway acme \
  -o jsonpath='{range .status.listeners[*]}{.name}: attachedRoutes={.attachedRoutes}{"\n"}{end}'
client-vm$ curl -s -H 'Host: acme-shop.lab' http://$GW/ | grep message
```

Expected:
```
acme-lab: attachedRoutes=3
acme-shop: attachedRoutes=1
  "message": "Welcome to the ACME shop",
```

Only the `shop` route attaches to the new listener, because it is the only one whose hostnames intersect with
`acme-shop.lab`.
</details>

---

## Lab 3.3: Microservices behind one domain – path routing and URL rewrite

**Scenario** – The ACME monolith has been split: the storefront stays at `/`, while `catalog` and `cart` are now
separate services. The browser must keep calling one origin (`/api/catalog/...`, `/api/cart/...`) to avoid CORS,
but the catalog team's service serves its endpoints at `/` and the cart service expects `/v1/cart/...`. On top of
that, the old load balancer health check calls `/status`, which the new app no longer has.

**What you'll learn**
- `PathPrefix` vs `Exact` matching, and why `/api/cart` does not match `/api/cartoons`
- Rule precedence (longest/most specific match wins, not YAML order)
- `URLRewrite` with `ReplacePrefixMatch` and `ReplaceFullPath`
- Using `whoami` to see exactly what path the backend receives

### Steps

1. Create the namespace, the three services and a Gateway.

```bash
workstation$ kubectl create namespace lab-03-03
workstation$ kubectl apply -n lab-03-03 -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: frontend
spec:
  selector:
    matchLabels: {app: frontend}
  template:
    metadata:
      labels: {app: frontend}
    spec:
      containers:
      - name: podinfo
        image: ghcr.io/stefanprodan/podinfo:6.17.0
        env:
        - name: PODINFO_UI_MESSAGE
          value: "ACME storefront"
        ports:
        - containerPort: 9898
---
apiVersion: v1
kind: Service
metadata:
  name: frontend
spec:
  selector: {app: frontend}
  ports:
  - port: 80
    targetPort: 9898
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: catalog
spec:
  selector:
    matchLabels: {app: catalog}
  template:
    metadata:
      labels: {app: catalog}
    spec:
      containers:
      - name: whoami
        image: traefik/whoami:v1.12.0
        args: ["--name=catalog"]
---
apiVersion: v1
kind: Service
metadata:
  name: catalog
spec:
  selector: {app: catalog}
  ports:
  - port: 80
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: cart
spec:
  selector:
    matchLabels: {app: cart}
  template:
    metadata:
      labels: {app: cart}
    spec:
      containers:
      - name: whoami
        image: traefik/whoami:v1.12.0
        args: ["--name=cart"]
---
apiVersion: v1
kind: Service
metadata:
  name: cart
spec:
  selector: {app: cart}
  ports:
  - port: 80
---
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: shop
spec:
  gatewayClassName: nginx
  listeners:
  - name: http
    protocol: HTTP
    port: 80
EOF
workstation$ kubectl -n lab-03-03 wait --for=condition=Available deploy --all
workstation$ kubectl -n lab-03-03 get gateway shop        # note the ADDRESS
```

2. Route by path prefix. The catch-all rule (no `matches` = `PathPrefix /`) is listed first on purpose.

```bash
workstation$ kubectl apply -n lab-03-03 -f - <<'EOF'
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: shop
spec:
  parentRefs:
  - name: shop
  rules:
  - backendRefs:
    - name: frontend
      port: 80
  - matches:
    - path:
        type: PathPrefix
        value: /api/catalog
    backendRefs:
    - name: catalog
      port: 80
  - matches:
    - path:
        type: PathPrefix
        value: /api/cart
    backendRefs:
    - name: cart
      port: 80
EOF
```

3. Test. `whoami` prints the request line it received, so you can see the path the backend gets.

```bash
client-vm$ GW=192.168.1.240
client-vm$ curl -s http://$GW/ | grep message
client-vm$ curl -s "http://$GW/api/catalog/items?page=2" | grep -E '^Name|^GET'
client-vm$ curl -s http://$GW/api/cart | grep -E '^Name|^GET'
client-vm$ curl -si http://$GW/api/cartoons | tail -1
```

Expected:
```
  "message": "ACME storefront",
Name: catalog
GET /api/catalog/items?page=2 HTTP/1.1
Name: cart
GET /api/cart HTTP/1.1
404 page not found
```

**Why:**
- Although the catch-all rule comes first, `/api/catalog/...` goes to catalog: the Gateway API mandates that the
  **longest matching prefix wins**, independent of rule order.
- `PathPrefix` matches whole path *segments*: `/api/cartoons` is **not** under `/api/cart`, so it falls through to
  the frontend (the `404 page not found` body comes from podinfo, not NGINX).
- Without a rewrite, backends see the full public path (`/api/catalog/items`). That breaks services that serve
  their API at `/`.

4. Add rewrites: strip `/api/catalog`, translate `/api/cart` to `/v1/cart`, and map the old health check
   `/status` (exact) to podinfo's `/healthz`.

```bash
workstation$ kubectl apply -n lab-03-03 -f - <<'EOF'
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: shop
spec:
  parentRefs:
  - name: shop
  rules:
  - backendRefs:
    - name: frontend
      port: 80
  - matches:
    - path:
        type: PathPrefix
        value: /api/catalog
    filters:
    - type: URLRewrite
      urlRewrite:
        path:
          type: ReplacePrefixMatch
          replacePrefixMatch: /
    backendRefs:
    - name: catalog
      port: 80
  - matches:
    - path:
        type: PathPrefix
        value: /api/cart
    filters:
    - type: URLRewrite
      urlRewrite:
        path:
          type: ReplacePrefixMatch
          replacePrefixMatch: /v1/cart
    backendRefs:
    - name: cart
      port: 80
  - matches:
    - path:
        type: Exact
        value: /status
    filters:
    - type: URLRewrite
      urlRewrite:
        path:
          type: ReplaceFullPath
          replaceFullPath: /healthz
    backendRefs:
    - name: frontend
      port: 80
EOF
client-vm$ for p in /api/catalog '/api/catalog/items?page=2' /api/catalog/items/42 /api/cart/checkout; do \
             printf '%-28s -> ' "$p"; curl -s "http://$GW$p" | grep '^GET'; done
client-vm$ curl -s http://$GW/status
```

Expected:
```
/api/catalog                 -> GET / HTTP/1.1
/api/catalog/items?page=2    -> GET /items?page=2 HTTP/1.1
/api/catalog/items/42        -> GET /items/42 HTTP/1.1
/api/cart/checkout           -> GET /v1/cart/checkout HTTP/1.1
{
  "status": "OK"
}
```

**Why:** `ReplacePrefixMatch` replaces only the matched prefix and keeps the rest of the path and the query string.
`ReplaceFullPath` replaces the entire path—use it with `Exact` matches, otherwise every sub-path collapses to the
same target. Rewrites happen inside the proxy; the client never sees the new path (compare with a redirect below).

### Clean up

```bash
workstation$ kubectl delete namespace lab-03-03
```

### Your turn

Thousands of old newsletter links point to `http://<shop>/catalog/items/<id>?ref=newsletter`. Instead of serving
the catalog on two paths, the SEO team wants a **permanent redirect** to the new `/api/catalog/...` URL, keeping
the item path and the query string. Implement it in a **separate** HTTPRoute called `legacy-redirects` attached to
the same Gateway (the shop route stays untouched).

<details><summary>Solution</summary>

```bash
workstation$ kubectl apply -n lab-03-03 -f - <<'EOF'
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: legacy-redirects
spec:
  parentRefs:
  - name: shop
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /catalog
    filters:
    - type: RequestRedirect
      requestRedirect:
        path:
          type: ReplacePrefixMatch
          replacePrefixMatch: /api/catalog
        statusCode: 301
EOF
client-vm$ curl -si "http://$GW/catalog/items/42?ref=newsletter" | grep -iE '^HTTP|^Location'
client-vm$ curl -sL "http://$GW/catalog/items/42?ref=newsletter" | grep '^GET'      # follow the redirect
```

Expected:
```
HTTP/1.1 301 Moved Permanently
Location: http://192.168.1.240:80/api/catalog/items/42?ref=newsletter
GET /items/42?ref=newsletter HTTP/1.1
```

Notes:
- A `RequestRedirect` rule has no `backendRefs`: the Gateway answers by itself.
- Several HTTPRoutes can attach to one Gateway; NGF merges their rules per hostname. That lets different teams own
  different paths of the same site.
- Unlike `URLRewrite`, a redirect is visible to the client and cached by browsers (`301`). Use `302` while testing.
</details>

---

## Lab 3.4: Beta users, API versions and read-only traffic – header, query and method matching

**Scenario** – The orders API is being migrated to a new database. During the migration, read requests (`GET`) must
be served by a read replica (`orders-replica`), while writes still go to `orders-primary`. In parallel, product
wants beta testers—identified by the `X-Beta-User: true` header or a `?beta=1` link—to use the new
`orders-beta` service for *all* requests. Simple, until the rules start to overlap.

**What you'll learn**
- Matching on `method`, `headers` and `queryParams`
- AND inside one match vs. OR between `matches` entries
- The Gateway API precedence rules (path > method > headers > query params) and how they surprise you
- Case sensitivity of header names vs. values

### Steps

1. Create the namespace, three `whoami` services (each prints its name) and a Gateway.

```bash
workstation$ kubectl create namespace lab-03-04
workstation$ for svc in orders-primary orders-replica orders-beta; do
  kubectl -n lab-03-04 create deployment $svc --image=traefik/whoami:v1.12.0 -- /whoami --name=$svc
  kubectl -n lab-03-04 expose deployment $svc --port=80
done
workstation$ kubectl apply -n lab-03-04 -f - <<'EOF'
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: api
spec:
  gatewayClassName: nginx
  listeners:
  - name: http
    protocol: HTTP
    port: 80
EOF
workstation$ kubectl -n lab-03-04 wait --for=condition=Available deploy --all
workstation$ kubectl -n lab-03-04 get gateway api
```

2. Route reads to the replica and everything else to the primary.

```bash
workstation$ kubectl apply -n lab-03-04 -f - <<'EOF'
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: orders
spec:
  parentRefs:
  - name: api
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /orders
    backendRefs:
    - name: orders-primary
      port: 80
  - matches:
    - path:
        type: PathPrefix
        value: /orders
      method: GET
    backendRefs:
    - name: orders-replica
      port: 80
EOF
```

Define a small test helper on the client VM—it prints the curl arguments and the backend name:

```bash
client-vm$ GW=192.168.1.240
client-vm$ t(){ printf '%-48s -> ' "$*"; curl -s "$@" | grep ^Name; }
client-vm$ t http://$GW/orders
client-vm$ t -X POST http://$GW/orders
client-vm$ t -X DELETE http://$GW/orders/7
```

Expected:
```
http://192.168.1.240/orders                      -> Name: orders-replica
-X POST http://192.168.1.240/orders              -> Name: orders-primary
-X DELETE http://192.168.1.240/orders/7          -> Name: orders-primary
```

3. Add the beta rule. The two entries under `matches` are ORed; conditions *inside* one entry are ANDed.

```bash
workstation$ kubectl apply -n lab-03-04 -f - <<'EOF'
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: orders
spec:
  parentRefs:
  - name: api
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /orders
    backendRefs:
    - name: orders-primary
      port: 80
  - matches:
    - path:
        type: PathPrefix
        value: /orders
      method: GET
    backendRefs:
    - name: orders-replica
      port: 80
  - matches:
    - path:                 # header AND path
        type: PathPrefix
        value: /orders
      headers:
      - name: X-Beta-User
        value: "true"
    - path:                 # OR query param AND path
        type: PathPrefix
        value: /orders
      queryParams:
      - name: beta
        value: "1"
    backendRefs:
    - name: orders-beta
      port: 80
EOF
client-vm$ t -X POST -H 'X-Beta-User: true' http://$GW/orders
client-vm$ t -H 'X-Beta-User: true' http://$GW/orders
client-vm$ t "http://$GW/orders?beta=1"
```

Expected:
```
-X POST -H X-Beta-User: true http://192.168.1.240/orders -> Name: orders-beta
-H X-Beta-User: true http://192.168.1.240/orders -> Name: orders-replica
http://192.168.1.240/orders?beta=1               -> Name: orders-replica
```

**Why:** beta `GET`s land on the replica! When several matches fit a request, Gateway API picks the winner by
fixed precedence, **not** by rule order: exact path > longest prefix > **method** > number of header matches >
number of query-param matches. A `GET` matches both `method: GET` (replica) and the header match (beta), and the
method match ranks higher.

4. Fix it: give the beta rule matches that combine `method: GET` *with* the header/query param. They now have a
   method **and** a header, which beats method alone.

```bash
workstation$ kubectl apply -n lab-03-04 -f - <<'EOF'
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: orders
spec:
  parentRefs:
  - name: api
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /orders
    backendRefs:
    - name: orders-primary
      port: 80
  - matches:
    - path:
        type: PathPrefix
        value: /orders
      method: GET
    backendRefs:
    - name: orders-replica
      port: 80
  - matches:
    - path:
        type: PathPrefix
        value: /orders
      headers:
      - name: X-Beta-User
        value: "true"
    - path:
        type: PathPrefix
        value: /orders
      method: GET
      headers:
      - name: X-Beta-User
        value: "true"
    - path:
        type: PathPrefix
        value: /orders
      method: GET
      queryParams:
      - name: beta
        value: "1"
    backendRefs:
    - name: orders-beta
      port: 80
EOF
client-vm$ t http://$GW/orders
client-vm$ t -X POST http://$GW/orders
client-vm$ t -H 'X-Beta-User: true' http://$GW/orders
client-vm$ t -X POST -H 'X-Beta-User: true' http://$GW/orders
client-vm$ t "http://$GW/orders?beta=1"
client-vm$ t "http://$GW/orders?beta=yes"
client-vm$ t -H 'X-Beta-User: TRUE' http://$GW/orders
client-vm$ t -H 'x-beta-user: true' http://$GW/orders
```

Expected:
```
http://192.168.1.240/orders                      -> Name: orders-replica
-X POST http://192.168.1.240/orders              -> Name: orders-primary
-H X-Beta-User: true http://192.168.1.240/orders -> Name: orders-beta
-X POST -H X-Beta-User: true http://192.168.1.240/orders -> Name: orders-beta
http://192.168.1.240/orders?beta=1               -> Name: orders-beta
http://192.168.1.240/orders?beta=yes             -> Name: orders-replica
-H X-Beta-User: TRUE http://192.168.1.240/orders -> Name: orders-replica
-H x-beta-user: true http://192.168.1.240/orders -> Name: orders-beta
```

**Why:** header **names** are case-insensitive (HTTP semantics), header **values** and query values are matched
exactly (`Exact` is the default `type`). Keep a table of test requests like the one above whenever you write
overlapping rules—it is the only reliable way to know which rule wins.

### Clean up

```bash
workstation$ kubectl delete namespace lab-03-04
```

### Your turn

The mobile team shipped app version 4 that only works with the new API. Every request whose `X-App-Version` header
starts with `4.` (e.g. `4.0.1`, `4.12`, but **not** `40.1` or `3.9`) must go to `orders-beta`, for every HTTP method.
Do it in a **separate** HTTPRoute named `orders-mobile-v4`, without touching `orders`.

<details><summary>Solution</summary>

Use a `RegularExpression` header match (supported by NGF). As in step 4, you need a variant with `method: GET`,
otherwise the replica rule wins for reads. Precedence is evaluated across **all** routes attached to the same
hostname, not just inside one HTTPRoute.

```bash
workstation$ kubectl apply -n lab-03-04 -f - <<'EOF'
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: orders-mobile-v4
spec:
  parentRefs:
  - name: api
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /orders
      headers:
      - name: X-App-Version
        type: RegularExpression
        value: '^4\.[0-9]+'
    - path:
        type: PathPrefix
        value: /orders
      method: GET
      headers:
      - name: X-App-Version
        type: RegularExpression
        value: '^4\.[0-9]+'
    backendRefs:
    - name: orders-beta
      port: 80
EOF
client-vm$ for v in 4.0.1 4.12 3.9 40.1; do
  printf '%-6s GET -> ' $v; curl -s -H "X-App-Version: $v" http://$GW/orders | grep ^Name
  printf '%-6s POST-> ' $v; curl -s -X POST -H "X-App-Version: $v" http://$GW/orders | grep ^Name
done
```

Expected:
```
4.0.1  GET -> Name: orders-beta
4.0.1  POST-> Name: orders-beta
4.12   GET -> Name: orders-beta
4.12   POST-> Name: orders-beta
3.9    GET -> Name: orders-replica
3.9    POST-> Name: orders-primary
40.1   GET -> Name: orders-replica
40.1   POST-> Name: orders-primary
```

Anchor your regular expressions (`^…`); an unanchored `4\.` would also match `14.0`.
</details>

---

## Lab 3.5: HTTPS for the shop – TLS termination and HTTP→HTTPS redirect

**Scenario** – The payment provider refuses to integrate with a shop that serves its checkout over plain HTTP. You
will terminate TLS at the Gateway with a certificate stored in a Kubernetes Secret, keep the backend on plain HTTP
inside the cluster, and permanently redirect every `http://` request to `https://`, preserving path and query string.

**What you'll learn**
- Creating a self-signed certificate with a proper SAN and a `kubernetes.io/tls` Secret
- An `HTTPS` listener with `tls.mode: Terminate` and `certificateRefs`
- SNI: why the hostname matters during the TLS handshake
- Binding routes to listeners with `sectionName` and redirecting with `RequestRedirect`

### Steps

1. Create the namespace, a certificate for `shop.acme.lab` and the Secret. Modern clients ignore the CN and only
   check the **subjectAltName**, so always set it.

```bash
workstation$ kubectl create namespace lab-03-05
workstation$ mkdir -p ~/lab-03-05 && cd ~/lab-03-05
workstation$ openssl req -x509 -newkey rsa:2048 -nodes -days 365 \
  -keyout shop.key -out shop.crt \
  -subj "/CN=shop.acme.lab/O=ACME" -addext "subjectAltName=DNS:shop.acme.lab"
workstation$ openssl x509 -in shop.crt -noout -subject -ext subjectAltName -enddate
workstation$ kubectl -n lab-03-05 create secret tls shop-tls --cert=shop.crt --key=shop.key
workstation$ kubectl -n lab-03-05 get secret shop-tls
```

Expected:
```
subject=CN=shop.acme.lab, O=ACME
X509v3 Subject Alternative Name:
    DNS:shop.acme.lab
notAfter=Nov  4 02:39:08 2027 GMT
NAME       TYPE                DATA   AGE
shop-tls   kubernetes.io/tls   2      1s
```

2. Deploy the shop (`whoami`, so we can see the forwarded headers), a Gateway with an HTTP and an HTTPS listener,
   and a route.

```bash
workstation$ kubectl apply -n lab-03-05 -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: shop
spec:
  selector:
    matchLabels: {app: shop}
  template:
    metadata:
      labels: {app: shop}
    spec:
      containers:
      - name: whoami
        image: traefik/whoami:v1.12.0
        args: ["--name=shop"]
---
apiVersion: v1
kind: Service
metadata:
  name: shop
spec:
  selector: {app: shop}
  ports:
  - port: 80
---
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: shop
spec:
  gatewayClassName: nginx
  listeners:
  - name: http
    protocol: HTTP
    port: 80
    hostname: shop.acme.lab
  - name: https
    protocol: HTTPS
    port: 443
    hostname: shop.acme.lab
    tls:
      mode: Terminate
      certificateRefs:
      - kind: Secret
        name: shop-tls
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: shop
spec:
  parentRefs:
  - name: shop
  hostnames:
  - shop.acme.lab
  rules:
  - backendRefs:
    - name: shop
      port: 80
EOF
workstation$ kubectl -n lab-03-05 get gateway,svc
workstation$ kubectl -n lab-03-05 get gateway shop \
  -o jsonpath='{range .status.listeners[*]}{.name}: attachedRoutes={.attachedRoutes}{"\n"}{end}'
```

Expected:
```
NAME                                     CLASS   ADDRESS         PROGRAMMED   AGE
gateway.gateway.networking.k8s.io/shop   nginx   192.168.1.242   True         7s

NAME                 TYPE           CLUSTER-IP      EXTERNAL-IP     PORT(S)                      AGE
service/shop         ClusterIP      10.105.73.152   <none>          80/TCP                       7s
service/shop-nginx   LoadBalancer   10.99.165.4     192.168.1.242   80:30251/TCP,443:31957/TCP   6s
http: attachedRoutes=1
https: attachedRoutes=1
```

**Why:** the certificate Secret must live in the Gateway's namespace (a different namespace needs a
`ReferenceGrant`, see Lab 3.7). The route has no `sectionName`, so it attaches to both listeners.

3. Test HTTPS from the client VM. `--resolve` makes curl send the right SNI and `Host`.

```bash
client-vm$ GW=192.168.1.242
client-vm$ mkdir -p ~/lab-03-05 && cd ~/lab-03-05
client-vm$ curl -sS --resolve shop.acme.lab:443:$GW https://shop.acme.lab/
```

Expected:
```
curl: (60) SSL certificate problem: self-signed certificate
```

The client does not trust our certificate. Copy `shop.crt` from the workstation (e.g. with `scp`), or—for the lab—
fetch it from the Gateway and inspect it (trust on first use):

```bash
client-vm$ openssl s_client -connect $GW:443 -servername shop.acme.lab </dev/null 2>/dev/null | openssl x509 -out shop.crt
client-vm$ openssl x509 -in shop.crt -noout -subject -issuer -enddate
client-vm$ curl -s --cacert shop.crt --resolve shop.acme.lab:443:$GW https://shop.acme.lab/ | grep -E '^Name|^X-Forwarded-Proto'
```

Expected:
```
subject=CN=shop.acme.lab, O=ACME
issuer=CN=shop.acme.lab, O=ACME
notAfter=Nov  4 02:39:08 2027 GMT
Name: shop
X-Forwarded-Proto: https
```

**Why:** TLS ends at NGINX; the backend receives plain HTTP plus `X-Forwarded-Proto: https`, which apps use to build
correct absolute URLs and to set `Secure` cookies.

4. What happens without SNI (e.g. by IP)? The listener only serves `shop.acme.lab`, so the handshake is rejected.

```bash
client-vm$ curl -skv https://$GW/ 2>&1 | grep -iE 'alert|error'
```

Expected:
```
* TLSv1.3 (IN), TLS alert, unrecognized name (624):
* TLS connect error: error:0A000458:SSL routines::tlsv1 unrecognized name
```

5. Plain HTTP still serves the shop—which is exactly what we must stop.

```bash
client-vm$ curl -s -o /dev/null -w '%{http_code}\n' --resolve shop.acme.lab:80:$GW http://shop.acme.lab/
```

Expected:
```
200
```

6. Bind the application route only to the `https` listener and add a redirect-only route on `http`.

```bash
workstation$ kubectl apply -n lab-03-05 -f - <<'EOF'
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: shop
spec:
  parentRefs:
  - name: shop
    sectionName: https
  hostnames:
  - shop.acme.lab
  rules:
  - backendRefs:
    - name: shop
      port: 80
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: http-to-https
spec:
  parentRefs:
  - name: shop
    sectionName: http
  hostnames:
  - shop.acme.lab
  rules:
  - filters:
    - type: RequestRedirect
      requestRedirect:
        scheme: https
        statusCode: 301
EOF
client-vm$ curl -si --resolve shop.acme.lab:80:$GW "http://shop.acme.lab/cart?id=7" | grep -iE '^HTTP|^Location'
client-vm$ curl -sL --cacert shop.crt --resolve shop.acme.lab:80:$GW --resolve shop.acme.lab:443:$GW \
             "http://shop.acme.lab/cart?id=7" | grep -E '^Name|^GET'
```

Expected:
```
HTTP/1.1 301 Moved Permanently
Location: https://shop.acme.lab/cart?id=7
Name: shop
GET /cart?id=7 HTTP/1.1
```

**Why:** if the application route stayed attached to `http` as well, NGF would have two candidate rules for the
same host and path on port 80; splitting by `sectionName` makes the intent explicit. When `scheme` changes to
`https` and no port is given, the redirect uses the well-known port 443 (so no `:443` appears in `Location`).

### Clean up

```bash
workstation$ kubectl delete namespace lab-03-05
workstation$ rm -rf ~/lab-03-05
client-vm$ rm -rf ~/lab-03-05
```

### Your turn

The security audit demands an **ECDSA P-256** certificate valid for **90 days** instead of the 1-year RSA one.
Rotate the certificate in place (same Secret name, no change to the Gateway, no Pod restarts), then prove from the
client VM that the new certificate is served. What happens to a client that pinned the *old* self-signed `shop.crt`?

<details><summary>Solution</summary>

```bash
workstation$ cd ~/lab-03-05
workstation$ openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 90 \
  -keyout shop-ec.key -out shop-ec.crt \
  -subj "/CN=shop.acme.lab/O=ACME" -addext "subjectAltName=DNS:shop.acme.lab"
workstation$ kubectl -n lab-03-05 create secret tls shop-tls --cert=shop-ec.crt --key=shop-ec.key \
  --dry-run=client -o yaml | kubectl apply -f -
```

(`create --dry-run -o yaml | apply` is the idiomatic way to update a Secret from files; the warning about the
missing `last-applied-configuration` annotation is harmless.)

Verify:
```bash
client-vm$ openssl s_client -connect $GW:443 -servername shop.acme.lab </dev/null 2>/dev/null \
             | openssl x509 -noout -enddate -text | grep -E 'notAfter|Public Key Algorithm|ASN1 OID'
client-vm$ curl -sS --cacert shop.crt --resolve shop.acme.lab:443:$GW https://shop.acme.lab/ | head -1
workstation$ kubectl -n lab-03-05 get pods -l gateway.networking.k8s.io/gateway-name=shop
```

Expected:
```
notAfter=Feb  2 02:42:09 2027 GMT
            Public Key Algorithm: id-ecPublicKey
                ASN1 OID: prime256v1
curl: (60) SSL certificate problem: self-signed certificate
NAME                          READY   STATUS    RESTARTS   AGE
shop-nginx-594b6964dc-rrkt5   1/1     Running   0          3m6s
```

NGF watches the Secret and reloads NGINX within seconds—no restart. The client that trusted the old self-signed
certificate breaks, because a self-signed certificate is its own CA. That is why real deployments issue leaf
certificates from a CA (e.g. cert-manager with an internal CA or Let's Encrypt): clients trust the CA, and leaf
rotations become invisible. Re-fetch `shop.crt` as in step 3 to make curl work again.
</details>

---

## Lab 3.6: Security headers and request tagging – header modifiers

**Scenario** – A penetration test of the legacy ACME shop found two issues: responses leak the technology stack and
internal host names (`X-Powered-By`, `X-Backend-Server`), and the site can be framed by other origins
(clickjacking). The app cannot be changed before the next release, so the Gateway must fix the headers. At the same
time, the API team wants to stop clients from forcing debug mode with `X-Debug` and from pretending to be
another environment with `X-Env`.

**What you'll learn**
- `ResponseHeaderModifier` and `RequestHeaderModifier` with `set`, `add`, `remove`
- The difference between `set` (overwrite) and `add` (append)
- Filters are per **rule**, not per route
- `PartiallyInvalid`: how NGF reports a rule it had to drop

### Steps

1. Create the namespace, a "legacy" NGINX app that leaks headers, a `whoami` service that prints request headers,
   and a Gateway named `edge`.

```bash
workstation$ kubectl create namespace lab-03-06
workstation$ kubectl apply -n lab-03-06 -f - <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: legacy-web
data:
  default.conf: |
    server {
      listen 80;
      location / {
        add_header X-Powered-By "PHP/7.4.3" always;
        add_header X-Backend-Server "web-01.corp.internal" always;
        default_type text/html;
        return 200 "<h1>ACME legacy shop</h1>\n";
      }
    }
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
spec:
  selector:
    matchLabels: {app: web}
  template:
    metadata:
      labels: {app: web}
    spec:
      containers:
      - name: nginx
        image: nginx:1.31-alpine
        ports:
        - containerPort: 80
        volumeMounts:
        - name: conf
          mountPath: /etc/nginx/conf.d
      volumes:
      - name: conf
        configMap:
          name: legacy-web
---
apiVersion: v1
kind: Service
metadata:
  name: web
spec:
  selector: {app: web}
  ports:
  - port: 80
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: echo
spec:
  selector:
    matchLabels: {app: echo}
  template:
    metadata:
      labels: {app: echo}
    spec:
      containers:
      - name: whoami
        image: traefik/whoami:v1.12.0
        args: ["--name=echo"]
---
apiVersion: v1
kind: Service
metadata:
  name: echo
spec:
  selector: {app: echo}
  ports:
  - port: 80
---
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: edge
spec:
  gatewayClassName: nginx
  listeners:
  - name: http
    protocol: HTTP
    port: 80
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: shop
spec:
  parentRefs:
  - name: edge
  rules:
  - backendRefs:
    - name: web
      port: 80
  - matches:
    - path:
        type: PathPrefix
        value: /inspect
    backendRefs:
    - name: echo
      port: 80
EOF
workstation$ kubectl -n lab-03-06 wait --for=condition=Available deploy --all
workstation$ kubectl -n lab-03-06 get gateway edge
```

2. Look at what the outside world sees today. (`/inspect` is routed to `whoami`, which echoes the request headers it
   received—our window into what the backend gets.)

```bash
client-vm$ GW=192.168.1.240
client-vm$ curl -si http://$GW/
client-vm$ curl -s -H 'X-Debug: true' -H 'X-Env: dev' http://$GW/inspect | grep -E '^X-|^GET'
```

Expected:
```
HTTP/1.1 200 OK
Server: nginx
Date: Wed, 04 Nov 2026 02:44:37 GMT
Content-Type: text/html
Content-Length: 26
Connection: keep-alive
X-Powered-By: PHP/7.4.3
X-Backend-Server: web-01.corp.internal

<h1>ACME legacy shop</h1>
GET /inspect HTTP/1.1
X-Debug: true
X-Env: dev
X-Forwarded-For: 192.168.1.100
X-Forwarded-Host: 192.168.1.240
X-Forwarded-Port: 80
X-Forwarded-Proto: http
X-Real-Ip: 192.168.1.100
```

Note the `X-Forwarded-*` and `X-Real-Ip` headers that NGF adds for you: the backend still knows the real client IP.

3. First attempt: add security headers and remove all revealing headers, including `Server`.

```bash
workstation$ kubectl apply -n lab-03-06 -f - <<'EOF'
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: shop
spec:
  parentRefs:
  - name: edge
  rules:
  - filters:
    - type: ResponseHeaderModifier
      responseHeaderModifier:
        set:
        - name: X-Frame-Options
          value: DENY
        - name: Referrer-Policy
          value: strict-origin-when-cross-origin
        remove:
        - X-Powered-By
        - X-Backend-Server
        - Server
    backendRefs:
    - name: web
      port: 80
  - matches:
    - path:
        type: PathPrefix
        value: /inspect
    backendRefs:
    - name: echo
      port: 80
EOF
workstation$ kubectl -n lab-03-06 get httproute shop \
  -o jsonpath='{range .status.parents[*].conditions[*]}{.type}={.status} ({.reason}): {.message}{"\n"}{end}'
client-vm$ curl -si http://$GW/ | head -1
client-vm$ curl -s -o /dev/null -w '%{http_code}\n' http://$GW/inspect
```

Expected:
```
Accepted=True (Accepted): The Route is accepted
ResolvedRefs=True (ResolvedRefs): All references are resolved
PartiallyInvalid=True (UnsupportedValue): Dropped Rule(s): spec.rules[0].filters[0].ResponseHeaderModifier.remove: Invalid value: {"name":"Server","value":""}: header name is not allowed
HTTP/1.1 500 Internal Server Error
200
```

**Why:** NGF does not allow modifying some headers that NGINX itself controls (`Server`, `Date`, `Content-Type`,
…). Instead of rejecting the whole route, it **drops the invalid rule** and reports `PartiallyInvalid=True`. The
dropped rule was the catch-all, so `/` now returns `500`, while `/inspect` still works. Always check the route
conditions after `apply`—`kubectl apply` succeeded and the route is `Accepted`, yet the site is down.

4. Fix the response rule and add a request filter for the API: overwrite `X-Env`, remove `X-Debug`, and tag
   requests with `X-Request-Source`.

```bash
workstation$ kubectl apply -n lab-03-06 -f - <<'EOF'
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: shop
spec:
  parentRefs:
  - name: edge
  rules:
  - filters:
    - type: ResponseHeaderModifier
      responseHeaderModifier:
        set:
        - name: X-Frame-Options
          value: DENY
        - name: Referrer-Policy
          value: strict-origin-when-cross-origin
        remove:
        - X-Powered-By
        - X-Backend-Server
    backendRefs:
    - name: web
      port: 80
  - matches:
    - path:
        type: PathPrefix
        value: /inspect
    filters:
    - type: RequestHeaderModifier
      requestHeaderModifier:
        set:
        - name: X-Env
          value: prod
        add:
        - name: X-Request-Source
          value: acme-edge
        remove:
        - X-Debug
    backendRefs:
    - name: echo
      port: 80
EOF
workstation$ kubectl -n lab-03-06 get httproute shop \
  -o jsonpath='{range .status.parents[*].conditions[*]}{.type}={.status} ({.reason}){"\n"}{end}'
client-vm$ curl -si http://$GW/
client-vm$ curl -s -H 'X-Debug: true' -H 'X-Env: dev' -H 'X-Request-Source: mobile' http://$GW/inspect | grep -E '^X-|^GET'
```

Expected:
```
Accepted=True (Accepted)
ResolvedRefs=True (ResolvedRefs)
HTTP/1.1 200 OK
Server: nginx
Date: Wed, 04 Nov 2026 02:45:00 GMT
Content-Type: text/html
Content-Length: 26
Connection: keep-alive
X-Frame-Options: DENY
Referrer-Policy: strict-origin-when-cross-origin

<h1>ACME legacy shop</h1>
GET /inspect HTTP/1.1
X-Env: prod
X-Forwarded-For: 192.168.1.100
X-Forwarded-Host: 192.168.1.240
X-Forwarded-Port: 80
X-Forwarded-Proto: http
X-Real-Ip: 192.168.1.100
X-Request-Source: mobile,acme-edge
```

**Why:**
- `set` replaced the client's `X-Env: dev`—use it for anything the backend trusts.
- `add` **appends** to an existing header (`mobile,acme-edge`), so a client can still inject a value. `add` is for
  headers that may legitimately carry several values.
- `remove` takes header names only; `X-Debug` never reaches the backend.

### Clean up

```bash
workstation$ kubectl delete namespace lab-03-06
```

### Your turn

A new single-page app on `https://app.acme.lab` calls the API under `/inspect`. Change the route so that:
1. API responses carry CORS headers `Access-Control-Allow-Origin: https://app.acme.lab` and
   `Access-Control-Allow-Methods: GET, POST, OPTIONS`, plus `Cache-Control: no-store`—but the shop pages do **not**;
2. clients can no longer inject their own `X-Request-Source` value;
3. API responses get the same `X-Frame-Options`/`Referrer-Policy` headers as the shop. (Check the response headers of
   `/inspect` after step 4 first—are they there?)

<details><summary>Solution</summary>

Filters belong to a rule, so the `/inspect` rule did **not** inherit the security headers of the catch-all rule. You
have to repeat them (NGF does not support per-`backendRef` filters; it reports
`ResolvedRefs=False … backendRefs[0].filters: must have at most 0 items`). Switching `add` to `set` makes the
gateway the single source of truth for `X-Request-Source`.

```bash
workstation$ kubectl apply -n lab-03-06 -f - <<'EOF'
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: shop
spec:
  parentRefs:
  - name: edge
  rules:
  - filters:
    - type: ResponseHeaderModifier
      responseHeaderModifier:
        set:
        - name: X-Frame-Options
          value: DENY
        - name: Referrer-Policy
          value: strict-origin-when-cross-origin
        remove:
        - X-Powered-By
        - X-Backend-Server
    backendRefs:
    - name: web
      port: 80
  - matches:
    - path:
        type: PathPrefix
        value: /inspect
    filters:
    - type: RequestHeaderModifier
      requestHeaderModifier:
        set:
        - name: X-Env
          value: prod
        - name: X-Request-Source
          value: acme-edge
        remove:
        - X-Debug
    - type: ResponseHeaderModifier
      responseHeaderModifier:
        set:
        - name: X-Frame-Options
          value: DENY
        - name: Referrer-Policy
          value: strict-origin-when-cross-origin
        - name: Access-Control-Allow-Origin
          value: https://app.acme.lab
        - name: Access-Control-Allow-Methods
          value: GET, POST, OPTIONS
        - name: Cache-Control
          value: no-store
    backendRefs:
    - name: echo
      port: 80
EOF
client-vm$ curl -s -D - -o /dev/null http://$GW/ | grep -iE '^x-|^access|^cache|^referrer'
client-vm$ curl -s -D - -H 'X-Request-Source: mobile' -H 'Origin: https://app.acme.lab' http://$GW/inspect \
             | grep -iE '^x-(frame|request|env)|^access|^cache|^referrer'
```

Expected:
```
X-Frame-Options: DENY
Referrer-Policy: strict-origin-when-cross-origin
X-Frame-Options: DENY
Referrer-Policy: strict-origin-when-cross-origin
Access-Control-Allow-Origin: https://app.acme.lab
Access-Control-Allow-Methods: GET, POST, OPTIONS
Cache-Control: no-store
X-Env: prod
X-Request-Source: acme-edge
```

The first five lines of the second command are response headers; the last two are request headers echoed by `whoami`.
</details>

---

## Lab 3.7: A shared company Gateway – allowedRoutes and ReferenceGrant

**Scenario** – ACME's platform team runs **one** Gateway (one IP, one set of certificates) in an `infra` namespace
for all product teams. Only namespaces that completed onboarding may publish routes on it. Team A's shop also needs
to forward `/search` to a Service owned by the search team in another namespace—and the search team wants to decide
explicitly who may do that.

**What you'll learn**
- Splitting ownership: Gateway in one namespace, HTTPRoutes in others (`parentRefs.namespace`)
- `allowedRoutes.namespaces.from: Selector` with a namespace label
- How a rejected route looks (`Accepted=False`, `NotAllowedByListeners`)
- Cross-namespace `backendRefs` and `ReferenceGrant` (`RefNotPermitted`)

### Steps

1. Create the namespaces (only team A is onboarded) and the shared Gateway, which accepts routes only from
   namespaces labelled `shared-gateway-access=true`.

```bash
workstation$ kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Namespace
metadata:
  name: lab-03-07-infra
---
apiVersion: v1
kind: Namespace
metadata:
  name: lab-03-07-team-a
  labels:
    shared-gateway-access: "true"
---
apiVersion: v1
kind: Namespace
metadata:
  name: lab-03-07-team-b
---
apiVersion: v1
kind: Namespace
metadata:
  name: lab-03-07-search
---
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: shared
  namespace: lab-03-07-infra
spec:
  gatewayClassName: nginx
  listeners:
  - name: apps
    protocol: HTTP
    port: 80
    hostname: "*.apps.acme.lab"
    allowedRoutes:
      namespaces:
        from: Selector
        selector:
          matchLabels:
            shared-gateway-access: "true"
EOF
workstation$ kubectl -n lab-03-07-infra get gateway shared
```

Expected:
```
NAME     CLASS   ADDRESS         PROGRAMMED   AGE
shared   nginx   192.168.1.240   True         5s
```

**Why:** the default is `from: Same` (only routes from the Gateway's own namespace). `All` would let *any*
namespace grab any hostname on the company IP. `Selector` turns a namespace label into an onboarding switch—restrict
who may set that label with RBAC or an admission policy.

2. Each team deploys an app called `app` (whoami printing the team name).

```bash
workstation$ for ns in team-a team-b search; do
  kubectl -n lab-03-07-$ns create deployment app --image=traefik/whoami:v1.12.0 -- /whoami --name=$ns
  kubectl -n lab-03-07-$ns expose deployment app --port=80
done
```

3. Team A and team B both publish a route on the shared Gateway. Note `parentRefs[].namespace`.

```bash
workstation$ kubectl apply -f - <<'EOF'
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: shop
  namespace: lab-03-07-team-a
spec:
  parentRefs:
  - name: shared
    namespace: lab-03-07-infra
  hostnames:
  - shop.apps.acme.lab
  rules:
  - backendRefs:
    - name: app
      port: 80
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: blog
  namespace: lab-03-07-team-b
spec:
  parentRefs:
  - name: shared
    namespace: lab-03-07-infra
  hostnames:
  - blog.apps.acme.lab
  rules:
  - backendRefs:
    - name: app
      port: 80
EOF
workstation$ for r in lab-03-07-team-a/shop lab-03-07-team-b/blog; do echo "== $r"
  kubectl -n ${r%/*} get httproute ${r#*/} \
    -o jsonpath='{range .status.parents[*].conditions[*]}{.type}={.status} ({.reason}): {.message}{"\n"}{end}'
done
workstation$ kubectl -n lab-03-07-infra get gateway shared -o jsonpath='{.status.listeners[0].attachedRoutes}{"\n"}'
```

Expected:
```
== lab-03-07-team-a/shop
Accepted=True (Accepted): The Route is accepted
ResolvedRefs=True (ResolvedRefs): All references are resolved
== lab-03-07-team-b/blog
ResolvedRefs=True (ResolvedRefs): All references are resolved
Accepted=False (NotAllowedByListeners): The Route is not allowed by any listener
1
```

```bash
client-vm$ GW=192.168.1.240
client-vm$ curl -s -H 'Host: shop.apps.acme.lab' http://$GW/ | grep ^Name
client-vm$ curl -s -o /dev/null -w '%{http_code}\n' -H 'Host: blog.apps.acme.lab' http://$GW/
```

Expected:
```
Name: team-a
404
```

**Why:** team B can *create* the route (it has RBAC in its own namespace), but the Gateway refuses it. The
rejection is visible only in the route's status—team B will not see anything on the Gateway object, which it
probably cannot even read. Teach teams to check `Accepted` on their routes.

4. Onboard team B by labelling its namespace. The route is accepted without being re-applied.

```bash
workstation$ kubectl label namespace lab-03-07-team-b shared-gateway-access=true
workstation$ kubectl -n lab-03-07-team-b get httproute blog \
  -o jsonpath='{range .status.parents[*].conditions[*]}{.type}={.status} ({.reason}){"\n"}{end}'
client-vm$ curl -s -H 'Host: blog.apps.acme.lab' http://$GW/ | grep ^Name
```

Expected:
```
Accepted=True (Accepted)
ResolvedRefs=True (ResolvedRefs)
Name: team-b
```

5. Team A adds `/search`, forwarding to the search team's Service in `lab-03-07-search`.

```bash
workstation$ kubectl apply -f - <<'EOF'
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: shop
  namespace: lab-03-07-team-a
spec:
  parentRefs:
  - name: shared
    namespace: lab-03-07-infra
  hostnames:
  - shop.apps.acme.lab
  rules:
  - backendRefs:
    - name: app
      port: 80
  - matches:
    - path:
        type: PathPrefix
        value: /search
    backendRefs:
    - name: app
      namespace: lab-03-07-search
      port: 80
EOF
workstation$ kubectl -n lab-03-07-team-a get httproute shop \
  -o jsonpath='{range .status.parents[*].conditions[*]}{.type}={.status} ({.reason}): {.message}{"\n"}{end}'
client-vm$ curl -s -o /dev/null -w '%{http_code}\n' -H 'Host: shop.apps.acme.lab' "http://$GW/search?q=shoes"
client-vm$ curl -s -H 'Host: shop.apps.acme.lab' http://$GW/ | grep ^Name
```

Expected:
```
Accepted=True (Accepted): The Route is accepted
ResolvedRefs=False (RefNotPermitted): spec.rules[1].backendRefs[0].namespace: Forbidden: Backend ref to Service lab-03-07-search/app not permitted by any ReferenceGrant
500
Name: team-a
```

**Why:** a cross-namespace reference is a privilege of the **target** namespace. Without it, any team could expose
any internal Service to the internet just by referencing it. The rest of the route keeps working; only the rule with
the forbidden backend answers `500`.

6. The search team grants access—only to HTTPRoutes from team A, and only to the Service `app`.

```bash
workstation$ kubectl apply -f - <<'EOF'
apiVersion: gateway.networking.k8s.io/v1
kind: ReferenceGrant
metadata:
  name: allow-team-a-routes
  namespace: lab-03-07-search      # lives in the namespace being referenced
spec:
  from:
  - group: gateway.networking.k8s.io
    kind: HTTPRoute
    namespace: lab-03-07-team-a
  to:
  - group: ""
    kind: Service
    name: app
EOF
workstation$ kubectl -n lab-03-07-team-a get httproute shop \
  -o jsonpath='{range .status.parents[*].conditions[*]}{.type}={.status} ({.reason}){"\n"}{end}'
client-vm$ curl -s -H 'Host: shop.apps.acme.lab' "http://$GW/search?q=shoes" | grep -E '^Name|^GET'
```

Expected:
```
Accepted=True (Accepted)
ResolvedRefs=True (ResolvedRefs)
Name: search
GET /search?q=shoes HTTP/1.1
```

### Clean up

```bash
workstation$ kubectl delete namespace lab-03-07-infra lab-03-07-team-a lab-03-07-team-b lab-03-07-search
```

### Your turn

Team B now runs **payments** and falls under PCI rules: its hostname `pay.acme.lab` must be served by a dedicated
listener on the shared Gateway that **only** `lab-03-07-team-b` may use, regardless of labels other namespaces
set on themselves. Team B publishes route `payments`. Then play the attacker: from team A, create a route
`fake-payments` with hostname `pay.acme.lab` and show that it is rejected.

<details><summary>Solution</summary>

Select the namespace by the immutable label `kubernetes.io/metadata.name` that Kubernetes sets on every namespace—
nobody can fake it.

```bash
workstation$ kubectl apply -f - <<'EOF'
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: shared
  namespace: lab-03-07-infra
spec:
  gatewayClassName: nginx
  listeners:
  - name: apps
    protocol: HTTP
    port: 80
    hostname: "*.apps.acme.lab"
    allowedRoutes:
      namespaces:
        from: Selector
        selector:
          matchLabels:
            shared-gateway-access: "true"
  - name: pay
    protocol: HTTP
    port: 80
    hostname: pay.acme.lab
    allowedRoutes:
      namespaces:
        from: Selector
        selector:
          matchLabels:
            kubernetes.io/metadata.name: lab-03-07-team-b
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: payments
  namespace: lab-03-07-team-b
spec:
  parentRefs:
  - name: shared
    namespace: lab-03-07-infra
    sectionName: pay
  hostnames:
  - pay.acme.lab
  rules:
  - backendRefs:
    - name: app
      port: 80
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: fake-payments
  namespace: lab-03-07-team-a
spec:
  parentRefs:
  - name: shared
    namespace: lab-03-07-infra
  hostnames:
  - pay.acme.lab
  rules:
  - backendRefs:
    - name: app
      port: 80
EOF
workstation$ for r in lab-03-07-team-b/payments lab-03-07-team-a/fake-payments; do echo "== $r"
  kubectl -n ${r%/*} get httproute ${r#*/} \
    -o jsonpath='{range .status.parents[*].conditions[*]}{.type}={.status} ({.reason}): {.message}{"\n"}{end}'
done
workstation$ kubectl -n lab-03-07-infra get gateway shared \
  -o jsonpath='{range .status.listeners[*]}{.name}: attachedRoutes={.attachedRoutes}{"\n"}{end}'
client-vm$ curl -s -H 'Host: pay.acme.lab' http://$GW/ | grep ^Name
```

Expected:
```
== lab-03-07-team-b/payments
Accepted=True (Accepted): The Route is accepted
ResolvedRefs=True (ResolvedRefs): All references are resolved
== lab-03-07-team-a/fake-payments
ResolvedRefs=True (ResolvedRefs): All references are resolved
Accepted=False (NoMatchingListenerHostname): The Listener hostname does not match the Route hostnames
apps: attachedRoutes=2
pay: attachedRoutes=1
Name: team-b
```

The fake route is not allowed on `pay` (wrong namespace) and its hostname does not fit `*.apps.acme.lab`, so it has
no listener at all. The reason reported is the hostname mismatch from the listener it *was* allowed to use.
</details>

---

## Lab 3.8: Why is my route not working? – troubleshooting from status

**Scenario** – Monday morning, five teams opened tickets: "my site returns 404/500 since Friday's deployment". All of
them use the same Gateway, `kubectl apply` succeeded for everyone, and the Gateway is `Programmed`. You will
diagnose every ticket from the HTTPRoute status alone, fix it, and then hunt down a sneakier failure where the status
is all green.

**What you'll learn**
- A one-liner that prints the conditions of all routes in a namespace
- Mapping reasons to root causes: `BackendNotFound`, `NoMatchingParent`, `NoMatchingListenerHostname`, no status
- Which errors produce `404`, `500`, `502` and `503`
- Going below the route: EndpointSlices and the NGINX data-plane logs

### Steps

1. Create the namespace and the (broken) setup. podinfo's Service listens on port **9898**.

```bash
workstation$ kubectl create namespace lab-03-08
workstation$ kubectl apply -n lab-03-08 -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: podinfo
spec:
  selector:
    matchLabels: {app: podinfo}
  template:
    metadata:
      labels: {app: podinfo}
    spec:
      containers:
      - name: podinfo
        image: ghcr.io/stefanprodan/podinfo:6.17.0
        ports:
        - containerPort: 9898
---
apiVersion: v1
kind: Service
metadata:
  name: podinfo
spec:
  selector: {app: podinfo}
  ports:
  - name: http
    port: 9898
---
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: web
spec:
  gatewayClassName: nginx
  listeners:
  - name: http
    protocol: HTTP
    port: 80
    hostname: "*.acme.lab"
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: orders
spec:
  parentRefs:
  - name: web
  hostnames: [orders.acme.lab]
  rules:
  - backendRefs:
    - name: podinfo
      port: 80
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: catalog
spec:
  parentRefs:
  - name: web
  hostnames: [catalog.acme.lab]
  rules:
  - backendRefs:
    - name: catalog
      port: 9898
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: cart
spec:
  parentRefs:
  - name: web
    sectionName: https
  hostnames: [cart.acme.lab]
  rules:
  - backendRefs:
    - name: podinfo
      port: 9898
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: admin
spec:
  parentRefs:
  - name: web
  hostnames: [admin.acme.internal]
  rules:
  - backendRefs:
    - name: podinfo
      port: 9898
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: search
spec:
  parentRefs:
  - name: web-gateway
  hostnames: [search.acme.lab]
  rules:
  - backendRefs:
    - name: podinfo
      port: 9898
EOF
workstation$ kubectl -n lab-03-08 rollout status deploy/podinfo
```

2. Reproduce the tickets from the client VM.

```bash
client-vm$ GW=192.168.1.240
client-vm$ for h in orders.acme.lab catalog.acme.lab cart.acme.lab admin.acme.internal search.acme.lab; do
  printf '%-22s %s\n' $h $(curl -s -o /dev/null -w '%{http_code}' -H "Host: $h" http://$GW/); done
```

Expected:
```
orders.acme.lab        500
catalog.acme.lab       500
cart.acme.lab          404
admin.acme.internal    404
search.acme.lab        404
```

**Why:** `500` = the route is attached, but its backend is unusable. `404` = no attached route matches that host at
all. The HTTP code already tells you which half of the status to look at.

3. Print all route conditions at once. Keep this one-liner—it is the fastest Gateway API debugging tool.

```bash
workstation$ kubectl -n lab-03-08 get httproute -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{range .status.parents[*].conditions[*]}  {.type}={.status} ({.reason}): {.message}{"\n"}{end}{end}'
workstation$ kubectl -n lab-03-08 get gateway web -o jsonpath='{.status.listeners[0].attachedRoutes}{"\n"}'
```

Expected:
```
admin
  ResolvedRefs=True (ResolvedRefs): All references are resolved
  Accepted=False (NoMatchingListenerHostname): The Listener hostname does not match the Route hostnames
cart
  ResolvedRefs=True (ResolvedRefs): All references are resolved
  Accepted=False (NoMatchingParent): The Listener is not found for this parent ref
catalog
  Accepted=True (Accepted): The Route is accepted
  ResolvedRefs=False (BackendNotFound): spec.rules[0].backendRefs[0].name: Not found: "catalog"
orders
  Accepted=True (Accepted): The Route is accepted
  ResolvedRefs=False (BackendNotFound): No matching port for Service podinfo and port 80
search
2
```

Read it as a diagnosis table:

| Route | Symptom | Reason | Root cause |
|-------|---------|--------|------------|
| `orders` | 500 | `BackendNotFound` – no matching port | `backendRefs.port` must be the **Service** port (9898), not the container port or "80 by habit" |
| `catalog` | 500 | `BackendNotFound` – not found | Service name typo / Service not deployed yet |
| `cart` | 404 | `NoMatchingParent` | `sectionName: https` – the Gateway has no listener with that name |
| `admin` | 404 | `NoMatchingListenerHostname` | `admin.acme.internal` does not intersect with listener `*.acme.lab` |
| `search` | 404 | *no status at all* | `parentRefs` points to `web-gateway`, which does not exist—no controller ever looks at the route |

Only 2 routes are attached to the listener (`orders` and `catalog`): they are accepted but have broken backends.

4. Fix all five routes.

```bash
workstation$ kubectl apply -n lab-03-08 -f - <<'EOF'
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: orders
spec:
  parentRefs:
  - name: web
  hostnames: [orders.acme.lab]
  rules:
  - backendRefs:
    - name: podinfo
      port: 9898
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: catalog
spec:
  parentRefs:
  - name: web
  hostnames: [catalog.acme.lab]
  rules:
  - backendRefs:
    - name: podinfo
      port: 9898
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: cart
spec:
  parentRefs:
  - name: web
    sectionName: http
  hostnames: [cart.acme.lab]
  rules:
  - backendRefs:
    - name: podinfo
      port: 9898
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: admin
spec:
  parentRefs:
  - name: web
  hostnames: [admin.acme.lab]
  rules:
  - backendRefs:
    - name: podinfo
      port: 9898
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: search
spec:
  parentRefs:
  - name: web
  hostnames: [search.acme.lab]
  rules:
  - backendRefs:
    - name: podinfo
      port: 9898
EOF
workstation$ kubectl -n lab-03-08 get httproute -o jsonpath='{range .items[*]}{.metadata.name}{": "}{range .status.parents[*].conditions[*]}{.type}={.status} {end}{"\n"}{end}'
client-vm$ for h in orders catalog cart admin search; do
  printf '%-22s %s\n' $h.acme.lab $(curl -s -o /dev/null -w '%{http_code}' -H "Host: $h.acme.lab" http://$GW/); done
```

Expected:
```
admin: Accepted=True ResolvedRefs=True
cart: Accepted=True ResolvedRefs=True
catalog: Accepted=True ResolvedRefs=True
orders: Accepted=True ResolvedRefs=True
search: Accepted=True ResolvedRefs=True
orders.acme.lab        200
catalog.acme.lab       200
cart.acme.lab          200
admin.acme.lab         200
search.acme.lab        200
```

### Clean up

```bash
workstation$ kubectl delete namespace lab-03-08
```

### Your turn

A sixth ticket: "reviews.acme.lab returns 503, but `Accepted` and `ResolvedRefs` are both `True`!" Deploy the
broken app below (before the clean up), reproduce the error and find **two** bugs—without staring at the YAML. Use
`kubectl get endpointslice` and the data-plane logs (`kubectl logs deploy/web-nginx -c nginx`).

```bash
workstation$ kubectl apply -n lab-03-08 -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: reviews
spec:
  replicas: 2
  selector:
    matchLabels: {app: reviews}
  template:
    metadata:
      labels: {app: reviews}
    spec:
      containers:
      - name: podinfo
        image: ghcr.io/stefanprodan/podinfo:6.17.0
        ports:
        - containerPort: 9898
---
apiVersion: v1
kind: Service
metadata:
  name: reviews
spec:
  selector: {app: review}
  ports:
  - port: 80
    targetPort: 8080
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: reviews
spec:
  parentRefs:
  - name: web
  hostnames: [reviews.acme.lab]
  rules:
  - backendRefs:
    - name: reviews
      port: 80
EOF
```

<details><summary>Solution</summary>

The route only validates that the Service and port **exist**. Whether the Service selects any Pods and whether the
`targetPort` is right is outside the Gateway API's view.

```bash
client-vm$ curl -si -H 'Host: reviews.acme.lab' http://$GW/ | head -1
workstation$ kubectl -n lab-03-08 get endpointslice -l kubernetes.io/service-name=reviews
```

Expected:
```
HTTP/1.1 503 Service Temporarily Unavailable
NAME            ADDRESSTYPE   PORTS     ENDPOINTS   AGE
reviews-8qfrm   IPv4          <unset>   <unset>     7s
```

Bug 1: no endpoints → the selector `app: review` does not match the Pods (`app: reviews`). NGINX has an empty upstream
and returns `503`. Fix it:

```bash
workstation$ kubectl -n lab-03-08 patch service reviews -p '{"spec":{"selector":{"app":"reviews"}}}'
workstation$ kubectl -n lab-03-08 get endpointslice -l kubernetes.io/service-name=reviews
client-vm$ curl -si -H 'Host: reviews.acme.lab' http://$GW/ | head -1
workstation$ kubectl -n lab-03-08 logs deploy/web-nginx -c nginx --tail=20 | grep -E 'connect\(\)|502'
```

Expected:
```
NAME            ADDRESSTYPE   PORTS   ENDPOINTS                      AGE
reviews-8qfrm   IPv4          8080    172.16.166.185,172.16.104.50   17s
HTTP/1.1 502 Bad Gateway
... connect() failed (111: Connection refused) while connecting to upstream, client: 192.168.1.100, server: reviews.acme.lab, request: "GET / HTTP/1.1", upstream: "http://172.16.166.185:8080/", host: "reviews.acme.lab"
192.168.1.100 - - [04/Nov/2026:02:49:38 +0000] "GET / HTTP/1.1" 502 150 "-" "curl/8.14.1"
```

Bug 2: `502` + "Connection refused" on `:8080` → the Pods listen on 9898. NGF sends traffic **directly to the Pod
IPs and the targetPort** from the EndpointSlice (it does not go through the ClusterIP), so the log shows exactly
which Pod and port failed. Fix the `targetPort`:

```bash
workstation$ kubectl -n lab-03-08 patch service reviews --type=json \
  -p '[{"op":"replace","path":"/spec/ports/0/targetPort","value":9898}]'
client-vm$ curl -si -H 'Host: reviews.acme.lab' http://$GW/ | head -1
```

Expected:
```
HTTP/1.1 200 OK
```

Summary of HTTP codes: `404` route not attached / host or path not matched · `500` route attached but backend
reference invalid (or a rule without backends) · `503` backend Service has no ready endpoints · `502` endpoints exist
but refuse the connection (wrong targetPort, app crashed).

Clean up: `kubectl delete namespace lab-03-08`.
</details>
