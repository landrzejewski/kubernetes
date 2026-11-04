# Module 07: Release Strategies, Autoscaling & Scheduling

Shipping a new version, surviving a traffic peak and putting Pods on the right machines are the three daily jobs of
running production workloads. In **Part A** you release new versions of a shop with Gateway API traffic management
(blue/green, canary, mirroring, automated progressive delivery). In **Part B** you let Kubernetes size the
application horizontally and vertically. In **Part C** you control *where* Pods run, and keep them running when
nodes fail or go into maintenance.

## Prerequisites check

```bash
workstation$ kubectl get nodes                                   # master, node1, node2 Ready
workstation$ kubectl get gatewayclass nginx                      # ACCEPTED=True
workstation$ kubectl top nodes                                   # metrics-server works (Part B)
workstation$ kubectl describe node master | grep Taints          # node-role.kubernetes.io/control-plane:NoSchedule
client-vm$   curl --version | head -1                            # Part A traffic tests run on the client VM
```

Part A uses two versions of podinfo: `ghcr.io/stefanprodan/podinfo:6.16.0` ("blue", the current release) and
`6.17.0` ("green", the new release). Each Gateway takes one IP from the small MetalLB pool—delete the lab namespace
when you are done.

## Table of contents

**Part A – Release strategies with Gateway API**
- [Lab 7.1: Blue/green release of the shop – preview hostname and instant rollback](#lab-71-bluegreen-release-of-the-shop--preview-hostname-and-instant-rollback)
- [Lab 7.2: Let QA test green in production – header-based routing](#lab-72-let-qa-test-green-in-production--header-based-routing)
- [Lab 7.3: Release v2 to 10% of users – weighted canary](#lab-73-release-v2-to-10-of-users--weighted-canary)
- [Lab 7.4: Employees first – canary by header and cookie, then by weight](#lab-74-employees-first--canary-by-header-and-cookie-then-by-weight)
- [Lab 7.5: Dark launch – shadow traffic with RequestMirror](#lab-75-dark-launch--shadow-traffic-with-requestmirror)
- [Lab 7.6: Progressive delivery with a health gate and automatic rollback](#lab-76-progressive-delivery-with-a-health-gate-and-automatic-rollback)

**Part B – Autoscaling**
- [Lab 7.7: Black Friday traffic – HPA on CPU](#lab-77-black-friday-traffic--hpa-on-cpu)
- [Lab 7.8: Scale up fast, scale down slowly – multi-metric HPA and behavior](#lab-78-scale-up-fast-scale-down-slowly--multi-metric-hpa-and-behavior)
- [Lab 7.9: Why doesn't my HPA scale? – troubleshooting](#lab-79-why-doesnt-my-hpa-scale--troubleshooting)
- [Lab 7.10: More CPU without a restart – in-place Pod resize](#lab-710-more-cpu-without-a-restart--in-place-pod-resize)
- [Lab 7.11: Right-sizing with the Vertical Pod Autoscaler](#lab-711-right-sizing-with-the-vertical-pod-autoscaler) ⚠ cluster-wide
- [Lab 7.12: Business-hours scaling with a CronJob and RBAC](#lab-712-business-hours-scaling-with-a-cronjob-and-rbac)

**Part C – Node selection and scheduling**
- [Lab 7.13: Pinning workloads to zones – node labels, nodeSelector and required affinity](#lab-713-pinning-workloads-to-zones--node-labels-nodeselector-and-required-affinity) ⚠ cluster-wide
- [Lab 7.14: Prefer, don't require – weighted node affinity with fallback](#lab-714-prefer-dont-require--weighted-node-affinity-with-fallback) ⚠ cluster-wide
- [Lab 7.15: A dedicated node for the data team – taints and tolerations](#lab-715-a-dedicated-node-for-the-data-team--taints-and-tolerations) ⚠ cluster-wide
- [Lab 7.16: When a node dies – NoExecute taints and tolerationSeconds](#lab-716-when-a-node-dies--noexecute-taints-and-tolerationseconds) ⚠ cluster-wide
- [Lab 7.17: Surviving a node failure – pod anti-affinity and co-locating a cache](#lab-717-surviving-a-node-failure--pod-anti-affinity-and-co-locating-a-cache)
- [Lab 7.18: Even spreading across zones – topology spread constraints](#lab-718-even-spreading-across-zones--topology-spread-constraints) ⚠ cluster-wide
- [Lab 7.19: Node maintenance without downtime – cordon, drain and PodDisruptionBudget](#lab-719-node-maintenance-without-downtime--cordon-drain-and-poddisruptionbudget) ⚠ cluster-wide

---

# Part A – Release strategies with Gateway API

## Lab 7.1: Blue/green release of the shop – preview hostname and instant rollback

**Scenario** – The shop runs version 6.16.0 ("blue"). Version 6.17.0 ("green") must go live tonight, and the
business demands two things: the product owner wants to click through green on the real infrastructure *before* the
switch, and if anything goes wrong, going back must take seconds, not a redeploy. You will run both versions side by
side, expose green on a preview hostname, and switch production traffic by editing one field of an HTTPRoute.

**What you'll learn**
- Blue/green with two Deployments + two Services and Gateway API routes
- A preview hostname for the idle color
- Switching and rolling back by changing a `backendRef`—and measuring that no request fails
- Why blue/green needs double capacity and readiness probes

### Steps

1. Create the namespace, both colors, the Gateway and two routes: `www.shop.lab` → blue (live),
   `preview.shop.lab` → green.

```bash
workstation$ kubectl create namespace lab-07-01
workstation$ kubectl apply -n lab-07-01 -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: shop-blue
spec:
  replicas: 2
  selector:
    matchLabels: {app: shop, color: blue}
  template:
    metadata:
      labels: {app: shop, color: blue}
    spec:
      containers:
      - name: podinfo
        image: ghcr.io/stefanprodan/podinfo:6.16.0
        env:
        - {name: PODINFO_UI_COLOR, value: "#1e40af"}
        - {name: PODINFO_UI_MESSAGE, value: "blue"}
        ports:
        - containerPort: 9898
        readinessProbe:
          httpGet: {path: /readyz, port: 9898}
---
apiVersion: v1
kind: Service
metadata:
  name: shop-blue
spec:
  selector: {app: shop, color: blue}
  ports:
  - port: 80
    targetPort: 9898
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: shop-green
spec:
  replicas: 2
  selector:
    matchLabels: {app: shop, color: green}
  template:
    metadata:
      labels: {app: shop, color: green}
    spec:
      containers:
      - name: podinfo
        image: ghcr.io/stefanprodan/podinfo:6.17.0
        env:
        - {name: PODINFO_UI_COLOR, value: "#15803d"}
        - {name: PODINFO_UI_MESSAGE, value: "green"}
        ports:
        - containerPort: 9898
        readinessProbe:
          httpGet: {path: /readyz, port: 9898}
---
apiVersion: v1
kind: Service
metadata:
  name: shop-green
spec:
  selector: {app: shop, color: green}
  ports:
  - port: 80
    targetPort: 9898
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
    hostname: "*.shop.lab"
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: live
spec:
  parentRefs:
  - name: shop
  hostnames: [www.shop.lab]
  rules:
  - backendRefs:
    - name: shop-blue
      port: 80
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: preview
spec:
  parentRefs:
  - name: shop
  hostnames: [preview.shop.lab]
  rules:
  - backendRefs:
    - name: shop-green
      port: 80
EOF
workstation$ kubectl -n lab-07-01 wait --for=condition=Available deploy --all
workstation$ kubectl -n lab-07-01 get gateway,httproute
```

Expected:
```
NAME                                     CLASS   ADDRESS         PROGRAMMED   AGE
gateway.gateway.networking.k8s.io/shop   nginx   192.168.1.240   True         17s

NAME                                          HOSTNAMES              AGE
httproute.gateway.networking.k8s.io/live      ["www.shop.lab"]       17s
httproute.gateway.networking.k8s.io/preview   ["preview.shop.lab"]   17s
```

**Why:** the two colors differ only in the `color` label, so each Service selects exactly one color. Blue/green is
*infrastructure-level* versioning: both versions are fully deployed and warm. That is also its cost—you run double
capacity during the release.

2. The product owner checks both hostnames.

```bash
client-vm$ GW=192.168.1.240
client-vm$ curl -s -H 'Host: www.shop.lab' http://$GW/ | grep -E 'version|message'
client-vm$ curl -s -H 'Host: preview.shop.lab' http://$GW/ | grep -E 'version|message'
```

Expected:
```
  "version": "6.16.0",
  "message": "blue",
  "version": "6.17.0",
  "message": "green",
```

(With `--resolve preview.shop.lab:80:$GW` or an `/etc/hosts` entry you can open the colorful podinfo UI in a
browser on the client VM.)

3. Start a "customer" in a second client VM terminal: it requests the live site 5 times per second and prints how
   many consecutive answers came from each color. Leave it running.

```bash
client-vm$ while true; do
  curl -s -m 2 -H 'Host: www.shop.lab' http://$GW/ | grep -o '"message": "[a-z]*"' || echo ERROR
  sleep 0.1
done | uniq -c
```

4. Go live: point the live route at green. It is a single-field change.

```bash
workstation$ kubectl -n lab-07-01 patch httproute live --type=json \
  -p '[{"op":"replace","path":"/spec/rules/0/backendRefs/0/name","value":"shop-green"}]'
```

5. Green has a problem—roll back immediately with the same command, pointing back to `shop-blue`.

```bash
workstation$ kubectl -n lab-07-01 patch httproute live --type=json \
  -p '[{"op":"replace","path":"/spec/rules/0/backendRefs/0/name","value":"shop-blue"}]'
```

Stop the loop with `Ctrl+C`. Expected (counts depend on your timing):
```
     24 "message": "blue"
     47 "message": "green"
     68 "message": "blue"
```

**Why:** not a single `ERROR`. NGF regenerates the NGINX configuration and reloads it gracefully: existing
connections finish on the old configuration, new ones use the new one. Both colors stayed deployed, so rollback is
as fast as the switch. Compare this with a rolling update, where rollback means rolling Pods back one by one.

6. Pitfalls worth knowing:
   - Switching to a color whose Pods are not ready gives every user a `503` (the Service has no endpoints). Always
     check readiness *before* switching—this is what the readiness probe and the script in *Your turn* are for.
   - Blue/green switches *all* users at once. Sessions stored in Pod memory, or database schema changes that the
     old version cannot read, make rollback impossible—keep releases backward compatible.
   - After a successful release, keep blue for a while (fast rollback), then scale it to 0 and reuse it as the next
     release's "green".

### Clean up

```bash
workstation$ kubectl delete namespace lab-07-01
```

### Your turn

Manual JSON patches at 2 a.m. are error-prone. Write a script `bg-switch.sh <blue|green>` for the workstation that:
1. refuses to switch if the target color has no ready Pods,
2. makes the target color live **and** points `preview.shop.lab` at the other color (so preview always shows the
   idle version, ready for the next release),
3. prints which backend each route uses.

Test it: switch to green, scale blue to 0 and try to switch back (must be refused), scale blue to 2 and switch back.

<details><summary>Solution</summary>

```bash
workstation$ mkdir -p ~/lab-07-01 && cd ~/lab-07-01
workstation$ cat > bg-switch.sh <<'EOF'
#!/bin/sh
# usage: ./bg-switch.sh blue|green   -> <color> becomes live, the other color becomes preview
set -e
NS=lab-07-01
case "$1" in
  blue)  NEW=blue;  OLD=green ;;
  green) NEW=green; OLD=blue ;;
  *) echo "usage: $0 blue|green"; exit 1 ;;
esac
READY=$(kubectl -n $NS get deploy shop-$NEW -o jsonpath='{.status.readyReplicas}')
if [ "${READY:-0}" -lt 1 ]; then echo "shop-$NEW has no ready Pods - refusing to switch"; exit 1; fi
patch() { kubectl -n $NS patch httproute "$1" --type=json \
  -p "[{\"op\":\"replace\",\"path\":\"/spec/rules/0/backendRefs/0/name\",\"value\":\"shop-$2\"}]"; }
patch live "$NEW"
patch preview "$OLD"
kubectl -n $NS get httproute live preview \
  -o custom-columns='ROUTE:.metadata.name,HOST:.spec.hostnames[0],BACKEND:.spec.rules[0].backendRefs[0].name'
EOF
workstation$ chmod +x bg-switch.sh
workstation$ ./bg-switch.sh green
workstation$ kubectl -n lab-07-01 scale deploy shop-blue --replicas=0
workstation$ ./bg-switch.sh blue; echo "rc=$?"
workstation$ kubectl -n lab-07-01 scale deploy shop-blue --replicas=2
workstation$ kubectl -n lab-07-01 rollout status deploy/shop-blue
workstation$ ./bg-switch.sh blue
```

Expected:
```
httproute.gateway.networking.k8s.io/live patched
httproute.gateway.networking.k8s.io/preview patched
ROUTE     HOST               BACKEND
live      www.shop.lab       shop-green
preview   preview.shop.lab   shop-blue
deployment.apps/shop-blue scaled
shop-blue has no ready Pods - refusing to switch
rc=1
deployment.apps/shop-blue scaled
deployment "shop-blue" successfully rolled out
httproute.gateway.networking.k8s.io/live patched
httproute.gateway.networking.k8s.io/preview patched
ROUTE     HOST               BACKEND
live      www.shop.lab       shop-blue
preview   preview.shop.lab   shop-green
```

Verify from the client VM:
```bash
client-vm$ curl -s -H 'Host: www.shop.lab' http://$GW/ | grep message        # "blue"
client-vm$ curl -s -H 'Host: preview.shop.lab' http://$GW/ | grep message    # "green"
```

Clean up: `kubectl delete namespace lab-07-01; rm -rf ~/lab-07-01`.
</details>

---

## Lab 7.2: Let QA test green in production – header-based routing

**Scenario** – A preview hostname (Lab 7.1) is not always possible: cookies, CORS rules and OAuth redirect URLs are
bound to the real domain `www.shop.lab`. The QA team wants to run its smoke tests against green **on the production
hostname** while customers keep getting blue. After go-live, QA must still be able to reach blue for comparison.

**What you'll learn**
- Header-based routing to an unreleased version on the live hostname
- Running a smoke test through the production Gateway
- Swapping the default and the "opt-in" backend at go-live
- Why header routing is a test tool, not a security boundary

### Steps

1. Create the namespace and both versions. The loop creates a Deployment + Service per color (same as Lab 7.1,
   just shorter). Note the **unquoted** `EOF`, so the shell substitutes `$color` and `$tag`.

```bash
workstation$ kubectl create namespace lab-07-02
workstation$ for v in blue:6.16.0 green:6.17.0; do color=${v%%:*} tag=${v##*:}
kubectl apply -n lab-07-02 -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: shop-$color
spec:
  replicas: 2
  selector:
    matchLabels: {app: shop, color: $color}
  template:
    metadata:
      labels: {app: shop, color: $color}
    spec:
      containers:
      - name: podinfo
        image: ghcr.io/stefanprodan/podinfo:$tag
        env:
        - {name: PODINFO_UI_MESSAGE, value: "$color"}
        ports:
        - containerPort: 9898
        readinessProbe:
          httpGet: {path: /readyz, port: 9898}
---
apiVersion: v1
kind: Service
metadata:
  name: shop-$color
spec:
  selector: {app: shop, color: $color}
  ports:
  - port: 80
    targetPort: 9898
EOF
done
```

2. Create the Gateway and one live route: by default blue, but requests carrying `X-QA-Preview: green` go to green.

```bash
workstation$ kubectl apply -n lab-07-02 -f - <<'EOF'
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
    hostname: "*.shop.lab"
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: live
spec:
  parentRefs:
  - name: shop
  hostnames: [www.shop.lab]
  rules:
  - backendRefs:
    - name: shop-blue
      port: 80
  - matches:
    - headers:
      - name: X-QA-Preview
        value: green
    backendRefs:
    - name: shop-green
      port: 80
EOF
workstation$ kubectl -n lab-07-02 wait --for=condition=Available deploy --all
workstation$ kubectl -n lab-07-02 get gateway shop
```

3. Customers vs. QA:

```bash
client-vm$ GW=192.168.1.240
client-vm$ for i in 1 2 3 4 5 6; do curl -s -H 'Host: www.shop.lab' http://$GW/ | grep -o '"message": "[a-z]*"'; done | sort | uniq -c
client-vm$ curl -s -H 'Host: www.shop.lab' -H 'X-QA-Preview: green' http://$GW/ | grep -E 'version|message'
client-vm$ curl -s -H 'Host: www.shop.lab' -H 'X-QA-Preview: purple' http://$GW/ | grep message
```

Expected:
```
      6 "message": "blue"
  "version": "6.17.0",
  "message": "green",
  "message": "blue",
```

**Why:** the header match (rule 2) is more specific than the catch-all (rule 1), so it wins regardless of order.
An unknown value falls back to blue—customers can never land on green by accident.

4. QA runs its smoke test against green, through the real Gateway and hostname.

```bash
client-vm$ for p in / /healthz /readyz /version /api/info /status/418; do
  printf '%-12s %s\n' $p $(curl -s -o /dev/null -w '%{http_code}' -H 'Host: www.shop.lab' -H 'X-QA-Preview: green' http://$GW$p)
done
client-vm$ curl -s -H 'Host: www.shop.lab' -H 'X-QA-Preview: green' http://$GW/version
```

Expected:
```
/            200
/healthz     200
/readyz      200
/version     200
/api/info    200
/status/418  418
{
  "commit": "fd3a834ed8d14b80ea334cf8a2fddd4597924da6",
  "version": "6.17.0"
}
```

(`/status/<code>` is a podinfo test endpoint that answers with the requested status code. We will use it to
simulate failures in Lab 7.6.)

5. QA approved. Go live by swapping the roles: green becomes the default, `X-QA-Preview: blue` reaches the old
   version for comparisons and bug reproduction.

```bash
workstation$ kubectl apply -n lab-07-02 -f - <<'EOF'
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: live
spec:
  parentRefs:
  - name: shop
  hostnames: [www.shop.lab]
  rules:
  - backendRefs:
    - name: shop-green
      port: 80
  - matches:
    - headers:
      - name: X-QA-Preview
        value: blue
    backendRefs:
    - name: shop-blue
      port: 80
EOF
client-vm$ curl -s -H 'Host: www.shop.lab' http://$GW/ | grep message
client-vm$ curl -s -H 'Host: www.shop.lab' -H 'X-QA-Preview: blue' http://$GW/ | grep message
```

Expected:
```
  "message": "green",
  "message": "blue",
```

**Why (pitfall):** anyone who knows the header can reach the unreleased version—headers are trivially set by
clients. Header routing is fine for "not advertised" features, but **not** for confidential ones. For those, add
authentication in the app or use a separate, access-restricted listener (Lab 3.7).

### Clean up

```bash
workstation$ kubectl delete namespace lab-07-02
```

### Your turn

Go back to the pre-release state (blue default, green via `X-QA-Preview: green`). The analytics team complains that
QA smoke tests pollute their conversion statistics, and the CDN cached a green page for customers. Change the QA rule
so that:
1. every QA request reaching green carries `X-Synthetic-Test: true` (the app's analytics skip such requests),
2. QA responses carry `X-Served-By: shop-green` and `Cache-Control: no-store`,
3. customer traffic is not affected.

Use podinfo's `/headers` endpoint (it echoes the request headers) to verify point 1.

<details><summary>Solution</summary>

```bash
workstation$ kubectl apply -n lab-07-02 -f - <<'EOF'
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: live
spec:
  parentRefs:
  - name: shop
  hostnames: [www.shop.lab]
  rules:
  - backendRefs:
    - name: shop-blue
      port: 80
  - matches:
    - headers:
      - name: X-QA-Preview
        value: green
    filters:
    - type: RequestHeaderModifier
      requestHeaderModifier:
        set:
        - name: X-Synthetic-Test
          value: "true"
    - type: ResponseHeaderModifier
      responseHeaderModifier:
        set:
        - name: X-Served-By
          value: shop-green
        - name: Cache-Control
          value: no-store
    backendRefs:
    - name: shop-green
      port: 80
EOF
client-vm$ curl -s -D - -H 'Host: www.shop.lab' -H 'X-QA-Preview: green' http://$GW/headers \
             | grep -iE '^x-served|^cache-control'
client-vm$ curl -s -H 'Host: www.shop.lab' -H 'X-QA-Preview: green' http://$GW/headers | grep -A1 Synthetic
client-vm$ curl -s -D - -H 'Host: www.shop.lab' http://$GW/headers | grep -ciE '^x-served|synthetic'
```

Expected:
```
X-Served-By: shop-green
Cache-Control: no-store
  "X-Synthetic-Test": [
    "true"
0
```

The last command prints `0`: customer requests and responses are untouched, because filters apply only to the rule
they are defined in.
</details>

---

## Lab 7.3: Release v2 to 10% of users – weighted canary

**Scenario** – Marketing wants the new shop version 6.17.0 live this week, the SRE team wants proof it behaves under
real traffic before everyone gets it. The agreement: start with **10%** of requests, watch, go to **50%**, then
**100%**. You will split traffic with HTTPRoute weights, measure the actual split from the client side, survive a
crashing canary, and finish the release cleanly.

**What you'll learn**
- `backendRefs[].weight` for traffic splitting (a "canary" independent of replica counts)
- Measuring the split with a small client-side script
- What happens when a weighted backend has no endpoints—and how weight `0` saves you
- Promoting a canary without a single failed request

### Steps

1. Create the namespace and two tracks: `stable` (6.16.0) and `canary` (6.17.0), 2 replicas each.

```bash
workstation$ kubectl create namespace lab-07-03
workstation$ for v in stable:6.16.0 canary:6.17.0; do track=${v%%:*} tag=${v##*:}
kubectl apply -n lab-07-03 -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: shop-$track
spec:
  replicas: 2
  selector:
    matchLabels: {app: shop, track: $track}
  template:
    metadata:
      labels: {app: shop, track: $track}
    spec:
      containers:
      - name: podinfo
        image: ghcr.io/stefanprodan/podinfo:$tag
        env:
        - {name: PODINFO_UI_MESSAGE, value: "$track"}
        ports:
        - containerPort: 9898
        readinessProbe:
          httpGet: {path: /readyz, port: 9898}
---
apiVersion: v1
kind: Service
metadata:
  name: shop-$track
spec:
  selector: {app: shop, track: $track}
  ports:
  - port: 80
    targetPort: 9898
EOF
done
```

2. Gateway and the live route with a 90/10 split.

```bash
workstation$ kubectl apply -n lab-07-03 -f - <<'EOF'
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
    hostname: "*.shop.lab"
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: live
spec:
  parentRefs:
  - name: shop
  hostnames: [www.shop.lab]
  rules:
  - backendRefs:
    - name: shop-stable
      port: 80
      weight: 90
    - name: shop-canary
      port: 80
      weight: 10
EOF
workstation$ kubectl -n lab-07-03 wait --for=condition=Available deploy --all
workstation$ kubectl -n lab-07-03 get gateway shop
```

**Why:** with plain Services, a 10% canary needs a 9:1 *replica* ratio (see the replica-based canary in chapter 11). With Gateway
API the proxy does the split, so 2 canary Pods can receive 10%, 50% or 100%—traffic share and capacity are
independent.

3. On the client VM, create a script that sends N requests and counts the versions.

```bash
client-vm$ mkdir -p ~/lab-07 && cd ~/lab-07
client-vm$ cat > count.sh <<'EOF'
#!/bin/sh
# usage: ./count.sh <gateway-ip> [requests] [extra curl args...]
GW=$1; N=${2:-200}; shift 2 2>/dev/null
for i in $(seq "$N"); do
  curl -s -m 2 -H 'Host: www.shop.lab' "$@" "http://$GW/" | grep -o '"version": "[0-9.]*"' || echo ERROR
done | sort | uniq -c | awk -v n="$N" '{ printf "%5d  %5.1f%%  %s %s\n", $1, 100*$1/n, $2, $3 }'
EOF
client-vm$ chmod +x count.sh
client-vm$ GW=192.168.1.240
client-vm$ ./count.sh $GW 200
```

Expected (the split is statistical; ±3% is normal for 200 requests):
```
  177   88.5%  "version": "6.16.0"
   23   11.5%  "version": "6.17.0"
```

4. Metrics look good. Define a helper on the workstation and move to 50/50, then to 0/100.

```bash
workstation$ setw() { kubectl -n lab-07-03 patch httproute live --type=json -p "[
  {\"op\":\"replace\",\"path\":\"/spec/rules/0/backendRefs/0/weight\",\"value\":$1},
  {\"op\":\"replace\",\"path\":\"/spec/rules/0/backendRefs/1/weight\",\"value\":$2}]"; }
workstation$ setw 50 50
client-vm$ ./count.sh $GW 200
workstation$ setw 0 100
workstation$ kubectl -n lab-07-03 get httproute live -o jsonpath='{range .spec.rules[0].backendRefs[*]}{.name}={.weight} {end}{"\n"}'
client-vm$ ./count.sh $GW 200
```

Expected:
```
   85   42.5%  "version": "6.16.0"
  115   57.5%  "version": "6.17.0"
shop-stable=0 shop-canary=100
  200  100.0%  "version": "6.17.0"
```

**Why:** weights are **relative**, not percentages: `9`/`1`, `90`/`10` and `900`/`100` are the same split. A
backend with weight `0` receives no traffic but stays in the route—ready for an instant rollback.

5. Failure drill: go back to 90/10 and let the canary "crash" (scale it to 0).

```bash
workstation$ setw 90 10
workstation$ kubectl -n lab-07-03 scale deploy shop-canary --replicas=0
client-vm$ ./count.sh $GW 200
```

Expected:
```
  177   88.5%  "version": "6.16.0"
   23   11.5%  ERROR
```

**Why:** NGF keeps sending the canary's share to an upstream with no endpoints, and those users get `503`. The
Gateway does not "fail over" between weighted backends. Roll back by setting the canary weight to 0:

```bash
workstation$ setw 100 0
client-vm$ ./count.sh $GW 100
```

Expected:
```
  100  100.0%  "version": "6.16.0"
```

### Clean up

```bash
workstation$ kubectl delete namespace lab-07-03
```

Keep `~/lab-07/count.sh` on the client VM; Labs 7.4–7.6 use it.

### Your turn

Finish the release properly. Bring the canary back (2 replicas) and route 100% to it. Then make `shop-stable` run
6.17.0, move all traffic back to `shop-stable` and scale the canary to 0—so the next release starts from the
same layout. Run a loop of 250 requests on the client VM *during* the whole promotion and prove that no request
failed.

<details><summary>Solution</summary>

The trick is the order: update `shop-stable` **while it has weight 0**, and only shift traffic back when its new
Pods are ready.

```bash
workstation$ kubectl -n lab-07-03 scale deploy shop-canary --replicas=2
workstation$ kubectl -n lab-07-03 rollout status deploy/shop-canary
workstation$ setw 0 100
```

Start the traffic loop (it prints the result after ~30 s):
```bash
client-vm$ for i in $(seq 1 250); do
  curl -s -m 2 -H 'Host: www.shop.lab' http://$GW/ | grep -o '"version": "[0-9.]*"' || echo ERROR; sleep 0.1
done | uniq -c
```

Meanwhile, on the workstation:
```bash
workstation$ kubectl -n lab-07-03 set image deploy/shop-stable podinfo=ghcr.io/stefanprodan/podinfo:6.17.0
workstation$ kubectl -n lab-07-03 rollout status deploy/shop-stable
workstation$ setw 100 0
workstation$ kubectl -n lab-07-03 scale deploy shop-canary --replicas=0
```

Expected on the client VM:
```
    250 "version": "6.17.0"
```

Verify the final state:
```bash
client-vm$ ./count.sh $GW 50
workstation$ kubectl -n lab-07-03 get deploy -o wide
```

Expected: `50  100.0%  "version": "6.17.0"`, `shop-stable` 2/2 with image `podinfo:6.17.0`, `shop-canary` 0/0.
In a GitOps setup you would make the same changes in Git: image tag of stable first, weights second.
</details>

---

## Lab 7.4: Employees first – canary by header and cookie, then by weight

**Scenario** – Before a single customer sees version 6.17.0, ACME wants its own employees to use it for a day
("dogfooding"). Employees come through the corporate proxy, which adds `X-Employee: true`; beta testers who
work from home get a `canary=always` cookie from the beta sign-up page. Only after that phase does a weighted
rollout to customers start—while employees and beta testers stay on the new version the whole time.

**What you'll learn**
- Combining match-based (deterministic) and weight-based (statistical) canaries in one route
- Matching a cookie with a `RegularExpression` on the `Cookie` header
- Weight `0` as "deployed but dark"
- Why weighted canaries are not sticky, and how cookies fix it

### Steps

1. Create the namespace and the two tracks (same loop as in Lab 7.3).

```bash
workstation$ kubectl create namespace lab-07-04
workstation$ for v in stable:6.16.0 canary:6.17.0; do track=${v%%:*} tag=${v##*:}
kubectl apply -n lab-07-04 -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: shop-$track
spec:
  replicas: 2
  selector:
    matchLabels: {app: shop, track: $track}
  template:
    metadata:
      labels: {app: shop, track: $track}
    spec:
      containers:
      - name: podinfo
        image: ghcr.io/stefanprodan/podinfo:$tag
        env:
        - {name: PODINFO_UI_MESSAGE, value: "$track"}
        ports:
        - containerPort: 9898
        readinessProbe:
          httpGet: {path: /readyz, port: 9898}
---
apiVersion: v1
kind: Service
metadata:
  name: shop-$track
spec:
  selector: {app: shop, track: $track}
  ports:
  - port: 80
    targetPort: 9898
EOF
done
```

2. Phase 1 (dogfooding): customers get stable (canary weight 0), employees and beta testers get the canary.

```bash
workstation$ kubectl apply -n lab-07-04 -f - <<'EOF'
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
    hostname: "*.shop.lab"
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: live
spec:
  parentRefs:
  - name: shop
  hostnames: [www.shop.lab]
  rules:
  - backendRefs:                     # customers: weighted
    - name: shop-stable
      port: 80
      weight: 100
    - name: shop-canary
      port: 80
      weight: 0
  - matches:                         # employees OR beta testers: always canary
    - headers:
      - name: X-Employee
        value: "true"
    - headers:
      - name: Cookie
        type: RegularExpression
        value: '(^|.*; )canary=always(;.*|$)'
    backendRefs:
    - name: shop-canary
      port: 80
EOF
workstation$ kubectl -n lab-07-04 wait --for=condition=Available deploy --all
workstation$ kubectl -n lab-07-04 get httproute live \
  -o jsonpath='{range .status.parents[*].conditions[*]}{.type}={.status} {.message}{"\n"}{end}'
```

Expected:
```
Accepted=True The Route is accepted
ResolvedRefs=True All references are resolved
```

**Why the regex:** browsers send *all* cookies in one `Cookie` header (`a=1; b=2; c=3`). An `Exact` match would only
work if `canary=always` were the only cookie. The anchors `(^|.*; )` and `(;.*|$)` make sure we match the cookie
**name** exactly—`xcanary=always` or `canary=alwaysnot` must not match.

3. Test all user groups with `count.sh` from Lab 7.3 (it passes extra arguments to curl). Create it first if you
   skipped that lab.

```bash
client-vm$ cd ~/lab-07 && GW=192.168.1.240
client-vm$ ./count.sh $GW 300                                                         # customers
client-vm$ ./count.sh $GW 50 -H 'X-Employee: true'                                    # employees
client-vm$ ./count.sh $GW 20 -H 'Cookie: session=abc123; canary=always; theme=dark'  # beta tester
client-vm$ ./count.sh $GW 20 -b 'canary=always'                                       # curl's cookie option
client-vm$ ./count.sh $GW 20 -b 'canary=alwaysnot; xcanary=always'                    # look-alikes
```

Expected:
```
  300  100.0%  "version": "6.16.0"
   50  100.0%  "version": "6.17.0"
   20  100.0%  "version": "6.17.0"
   20  100.0%  "version": "6.17.0"
   20  100.0%  "version": "6.16.0"
```

4. Phase 2: employees are happy, start the customer rollout with 20%.

```bash
workstation$ setw() { kubectl -n lab-07-04 patch httproute live --type=json -p "[
  {\"op\":\"replace\",\"path\":\"/spec/rules/0/backendRefs/0/weight\",\"value\":$1},
  {\"op\":\"replace\",\"path\":\"/spec/rules/0/backendRefs/1/weight\",\"value\":$2}]"; }
workstation$ setw 80 20
client-vm$ ./count.sh $GW 200
client-vm$ ./count.sh $GW 50 -H 'X-Employee: true'
```

Expected:
```
  159   79.5%  "version": "6.16.0"
   41   20.5%  "version": "6.17.0"
   50  100.0%  "version": "6.17.0"
```

**Why:** the match rules are evaluated first and are deterministic; only requests that match none of them fall into
the weighted catch-all. You can keep raising the customer percentage while the internal groups stay pinned.

5. Pitfall: weights are applied **per request**. A customer at 20% does not get "the canary"; every page load is a new
   coin toss, so one user can see 6.16.0, 6.17.0, 6.16.0… That is fine for stateless APIs, but confusing for UIs
   and dangerous if the versions store data differently. Common fix: the application (or a tiny edge function)
   sets `canary=always` or `canary=never` on the first response, and the Gateway honours the cookie—see *Your turn*.

### Clean up

```bash
workstation$ kubectl delete namespace lab-07-04
```

### Your turn

Support says some customers hit a bug in 6.17.0 and must be kept off the canary while it is being fixed. Add an
**opt-out**: requests with the cookie `canary=never` must always go to stable, even during the weighted phase. Keep
the 80/20 split for everyone else, and keep employees/beta testers on the canary. Prove all four groups behave.

<details><summary>Solution</summary>

```bash
workstation$ kubectl apply -n lab-07-04 -f - <<'EOF'
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: live
spec:
  parentRefs:
  - name: shop
  hostnames: [www.shop.lab]
  rules:
  - backendRefs:
    - name: shop-stable
      port: 80
      weight: 80
    - name: shop-canary
      port: 80
      weight: 20
  - matches:
    - headers:
      - name: X-Employee
        value: "true"
    - headers:
      - name: Cookie
        type: RegularExpression
        value: '(^|.*; )canary=always(;.*|$)'
    backendRefs:
    - name: shop-canary
      port: 80
  - matches:
    - headers:
      - name: Cookie
        type: RegularExpression
        value: '(^|.*; )canary=never(;.*|$)'
    backendRefs:
    - name: shop-stable
      port: 80
EOF
client-vm$ ./count.sh $GW 200                                  # customers
client-vm$ ./count.sh $GW 100 -b 'session=abc; canary=never'   # opted out
client-vm$ ./count.sh $GW 50 -b 'canary=always'                # beta tester
client-vm$ ./count.sh $GW 50 -H 'X-Employee: true'             # employee
```

Expected:
```
  156   78.0%  "version": "6.16.0"
   44   22.0%  "version": "6.17.0"
  100  100.0%  "version": "6.16.0"
   50  100.0%  "version": "6.17.0"
   50  100.0%  "version": "6.17.0"
```

With an "assign on first visit" cookie (`always` for 20% of new visitors, `never` for the rest) these two rules turn
the per-request split into a **sticky** per-user canary.
</details>

---

## Lab 7.5: Dark launch – shadow traffic with RequestMirror

**Scenario** – The search team rewrote the search API (v2). Synthetic tests pass, but nobody knows how v2 behaves
with *real* production queries—odd parameters, real request rates, real payloads. Instead of exposing customers to
v2, you will **mirror** production traffic to it: users keep getting answers from v1, while v2 receives a copy of
every request and its responses are thrown away.

**What you'll learn**
- The `RequestMirror` filter and what "fire and forget" means
- Verifying shadow traffic in the mirror's logs
- Why the mirror cannot break users—and why it can still break your data
- Mirroring only safe requests and only a percentage of them

### Steps

1. Create the namespace, search v1 (podinfo 6.16.0, 2 replicas) and search v2 (6.17.0, 1 replica, with debug
   logging so that every request is logged), plus a Gateway.

```bash
workstation$ kubectl create namespace lab-07-05
workstation$ kubectl apply -n lab-07-05 -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: search-v1
spec:
  replicas: 2
  selector:
    matchLabels: {app: search, version: v1}
  template:
    metadata:
      labels: {app: search, version: v1}
    spec:
      containers:
      - name: podinfo
        image: ghcr.io/stefanprodan/podinfo:6.16.0
        ports:
        - containerPort: 9898
---
apiVersion: v1
kind: Service
metadata:
  name: search-v1
spec:
  selector: {app: search, version: v1}
  ports:
  - port: 80
    targetPort: 9898
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: search-v2
spec:
  replicas: 1
  selector:
    matchLabels: {app: search, version: v2}
  template:
    metadata:
      labels: {app: search, version: v2}
    spec:
      containers:
      - name: podinfo
        image: ghcr.io/stefanprodan/podinfo:6.17.0
        command: ["./podinfo", "--port=9898", "--level=debug"]
        ports:
        - containerPort: 9898
---
apiVersion: v1
kind: Service
metadata:
  name: search-v2
spec:
  selector: {app: search, version: v2}
  ports:
  - port: 80
    targetPort: 9898
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
    hostname: "*.shop.lab"
EOF
workstation$ kubectl -n lab-07-05 wait --for=condition=Available deploy --all
```

2. Route `/api` to v1 and mirror every request to v2.

```bash
workstation$ kubectl apply -n lab-07-05 -f - <<'EOF'
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: search
spec:
  parentRefs:
  - name: shop
  hostnames: [www.shop.lab]
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /api
    filters:
    - type: RequestMirror
      requestMirror:
        backendRef:
          name: search-v2
          port: 80
    backendRefs:
    - name: search-v1
      port: 80
EOF
workstation$ kubectl -n lab-07-05 get httproute search \
  -o jsonpath='{range .status.parents[*].conditions[*]}{.type}={.status} {.message}{"\n"}{end}'
```

Expected:
```
Accepted=True The Route is accepted
ResolvedRefs=True All references are resolved
```

3. Send 20 searches and one POST (podinfo's `/api/echo` returns the body it receives).

```bash
client-vm$ GW=192.168.1.240
client-vm$ for i in $(seq 20); do
  curl -s -H 'Host: www.shop.lab' "http://$GW/api/info?q=shoes-$i" | grep -o '"version": "[0-9.]*"'
done | sort | uniq -c
client-vm$ curl -s -X POST -d '{"order":42}' -H 'Host: www.shop.lab' http://$GW/api/echo; echo
```

Expected—every answer came from v1:
```
     20 "version": "6.16.0"
{"order":42}
```

4. Now look at v2's logs: it received a copy of everything, including the POST body.

```bash
workstation$ kubectl -n lab-07-05 logs deploy/search-v2 | grep -c 'request started'
workstation$ kubectl -n lab-07-05 logs deploy/search-v2 | grep -E 'request started|payload' | tail -2
```

Expected:
```
21
{"level":"debug","ts":"2026-11-04T03:02:10.661Z","caller":"http/logging.go:39","msg":"request started","proto":"HTTP/1.1","uri":"/api/echo","method":"POST","remote":"172.16.166.173:44464","user-agent":"curl/8.14.1"}
{"level":"debug","ts":"2026-11-04T03:02:10.661Z","caller":"http/echo.go:125","msg":"payload received","size":12,"payload":{"order":42}}
```

**Why:** NGINX sends the mirrored request as a background subrequest (the `remote` address is the Gateway Pod) and
ignores its response. You can now compare v2's error rate, latency and logs with v1—under real load—without any
customer seeing v2.

5. The mirror cannot hurt users: take v2 down completely and measure.

```bash
workstation$ kubectl -n lab-07-05 scale deploy search-v2 --replicas=0
client-vm$ for i in $(seq 20); do curl -s -o /dev/null -w '%{http_code} %{time_total}\n' -H 'Host: www.shop.lab' "http://$GW/api/info"; done \
  | awk '{c[$1]++; t+=$2} END {for (k in c) print k, c[k]; printf "avg %.3fs\n", t/NR}'
workstation$ kubectl -n lab-07-05 scale deploy search-v2 --replicas=1
```

Expected:
```
200 20
avg 0.007s
```

6. But it **can** hurt your data. The `{"order":42}` POST was executed twice—once by v1 and once by v2. If v2 writes
   to the same database, sends e-mails or charges credit cards, a dark launch creates duplicate side effects.
   Rules of thumb: mirror only idempotent/read-only requests, or point the shadow at a copy of the data with
   outgoing integrations stubbed. A mirror also doubles the load on everything v2 depends on.

### Clean up

```bash
workstation$ kubectl delete namespace lab-07-05
```

### Your turn

Make the dark launch safe and cheap: mirror **only `GET`** requests under `/api` (all methods must still be served by
v1), and only **25%** of them, because v2 runs with a single replica. Send 200 GETs and 10 POSTs and show from v2's
logs that roughly 50 GETs and no POSTs arrived.

<details><summary>Solution</summary>

Split the rule by method. The `GET` match is more specific, so GETs take the mirroring rule. The `percent` field of
`RequestMirror` (Gateway API v1.3+) is supported by NGF.

```bash
workstation$ kubectl apply -n lab-07-05 -f - <<'EOF'
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: search
spec:
  parentRefs:
  - name: shop
  hostnames: [www.shop.lab]
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /api
    backendRefs:
    - name: search-v1
      port: 80
  - matches:
    - path:
        type: PathPrefix
        value: /api
      method: GET
    filters:
    - type: RequestMirror
      requestMirror:
        backendRef:
          name: search-v2
          port: 80
        percent: 25
    backendRefs:
    - name: search-v1
      port: 80
EOF
client-vm$ for i in $(seq 200); do curl -s -o /dev/null -H 'Host: www.shop.lab' "http://$GW/api/info?i=$i"; done
client-vm$ for i in $(seq 10); do curl -s -o /dev/null -X POST -d "{\"order\":$i}" -H 'Host: www.shop.lab' "http://$GW/api/echo"; done
workstation$ kubectl -n lab-07-05 logs deploy/search-v2 --since=2m | grep 'request started' \
  | grep -o '"method":"[A-Z]*"' | sort | uniq -c
```

Expected (25% of 200 GETs, no POST):
```
     51 "method":"GET"
```
</details>

---

## Lab 7.6: Progressive delivery with a health gate and automatic rollback

**Scenario** – Manual canaries (Lab 7.3) depend on someone watching dashboards at the right moment. ACME wants the
release pipeline to do it: shift traffic 10% → 25% → 50% → 100%, check the error rate after every step, and roll
back **automatically** if the new version misbehaves. This is what tools like Argo Rollouts or Flagger do; you will
build the core loop yourself in 40 lines of shell, and test it with a deliberately broken build.

**What you'll learn**
- Automating weight changes with `kubectl patch`
- A health gate measured *through the Gateway* from a probe Pod
- Simulating a bad release with podinfo's `PODINFO_RANDOM_ERROR`
- Automatic rollback by setting the canary weight to 0

### Steps

1. Create the namespace, stable (6.16.0), a **buggy** canary (6.17.0 with `PODINFO_RANDOM_ERROR=true`: about 1/3 of
   its responses are 4xx/5xx), the Gateway, the route (100/0) and a probe Pod with curl.

```bash
workstation$ kubectl create namespace lab-07-06
workstation$ kubectl apply -n lab-07-06 -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: shop-stable
spec:
  replicas: 2
  selector:
    matchLabels: {app: shop, track: stable}
  template:
    metadata:
      labels: {app: shop, track: stable}
    spec:
      containers:
      - name: podinfo
        image: ghcr.io/stefanprodan/podinfo:6.16.0
        ports:
        - containerPort: 9898
        readinessProbe:
          httpGet: {path: /readyz, port: 9898}
---
apiVersion: v1
kind: Service
metadata:
  name: shop-stable
spec:
  selector: {app: shop, track: stable}
  ports:
  - port: 80
    targetPort: 9898
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: shop-canary
spec:
  replicas: 2
  selector:
    matchLabels: {app: shop, track: canary}
  template:
    metadata:
      labels: {app: shop, track: canary}
    spec:
      containers:
      - name: podinfo
        image: ghcr.io/stefanprodan/podinfo:6.17.0
        env:
        - name: PODINFO_RANDOM_ERROR      # simulate a buggy build: 1/3 of requests fail
          value: "true"
        ports:
        - containerPort: 9898
        readinessProbe:
          httpGet: {path: /readyz, port: 9898}
---
apiVersion: v1
kind: Service
metadata:
  name: shop-canary
spec:
  selector: {app: shop, track: canary}
  ports:
  - port: 80
    targetPort: 9898
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
    hostname: "*.shop.lab"
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: live
spec:
  parentRefs:
  - name: shop
  hostnames: [www.shop.lab]
  rules:
  - backendRefs:
    - name: shop-stable
      port: 80
      weight: 100
    - name: shop-canary
      port: 80
      weight: 0
---
apiVersion: v1
kind: Pod
metadata:
  name: probe
spec:
  containers:
  - name: curl
    image: curlimages/curl:8.23.0
    command: ["sleep", "infinity"]
EOF
workstation$ kubectl -n lab-07-06 wait --for=condition=Available deploy --all
workstation$ kubectl -n lab-07-06 wait --for=condition=Ready pod/probe
workstation$ kubectl -n lab-07-06 get svc shop-nginx
```

**Why the probe Pod:** the script needs `kubectl` (to change weights) *and* access to the Gateway. Your workstation
may not reach the MetalLB address, but every Pod can reach the Gateway's Service `shop-nginx`—so traffic still
passes through NGINX and the weights, exactly like customer traffic.

2. Note that the canary's readiness probe is green, although it is broken—readiness checks only `/readyz`:

```bash
workstation$ kubectl -n lab-07-06 get deploy shop-canary
workstation$ kubectl -n lab-07-06 exec probe -- sh -c \
  'for i in $(seq 30); do curl -s -o /dev/null -w "%{http_code}\n" http://shop-canary/; done | sort | uniq -c'
```

Expected (random):
```
NAME          READY   UP-TO-DATE   AVAILABLE   AGE
shop-canary   2/2     2            2           24s
     18 200
      3 400
      5 409
      4 500
```

3. Write the progressive delivery script.

```bash
workstation$ mkdir -p ~/lab-07-06 && cd ~/lab-07-06
workstation$ cat > progressive.sh <<'EOF'
#!/bin/sh
# Progressive delivery: shift traffic to the canary step by step, roll back automatically on errors.
NS=lab-07-06
STEPS="10 25 50 100"      # canary weight in percent
REQUESTS=200              # requests per health check
MAX_ERROR_PCT=1           # health gate: max. share of non-2xx answers

setw() {
  kubectl -n $NS patch httproute live --type=json -p "[
    {\"op\":\"replace\",\"path\":\"/spec/rules/0/backendRefs/0/weight\",\"value\":$1},
    {\"op\":\"replace\",\"path\":\"/spec/rules/0/backendRefs/1/weight\",\"value\":$2}]" >/dev/null
}

# send traffic THROUGH the Gateway (its Service), from a probe Pod inside the cluster
check() {
  kubectl -n $NS exec probe -- sh -c "for i in \$(seq $REQUESTS); do
      curl -s -o /dev/null -m 2 -w '%{http_code}\n' -H 'Host: www.shop.lab' http://shop-nginx/; done" \
    | awk '!/^2/ {e++} END {print e+0}'
}

for w in $STEPS; do
  setw $((100 - w)) $w
  sleep 5                                   # let NGINX reload and traffic settle
  errors=$(check)
  pct=$((errors * 100 / REQUESTS))
  echo "$(date +%T) canary=${w}%  errors=${errors}/${REQUESTS} (${pct}%)"
  if [ "$errors" -gt $((REQUESTS * MAX_ERROR_PCT / 100)) ]; then
    setw 100 0
    echo "$(date +%T) health gate FAILED -> rolled back to stable (canary weight 0)"
    exit 1
  fi
done
echo "$(date +%T) canary healthy at 100% -> ready to promote"
EOF
workstation$ chmod +x progressive.sh
```

4. Release the buggy build.

```bash
workstation$ ./progressive.sh; echo "rc=$?"
workstation$ kubectl -n lab-07-06 get httproute live -o jsonpath='{range .spec.rules[0].backendRefs[*]}{.name}={.weight} {end}{"\n"}'
```

Expected:
```
04:04:06 canary=10%  errors=7/200 (3%)
04:04:06 health gate FAILED -> rolled back to stable (canary weight 0)
rc=1
shop-stable=100 shop-canary=0
```

**Why:** with 10% of traffic on a build that fails 1/3 of the time, about 3% of all requests failed—above the 1%
budget. Only a tenth of the users were exposed, for a few seconds, and nobody had to wake up. The non-zero exit code
lets a CI/CD pipeline stop here.

5. The developers fix the bug (we just remove the error simulation). Release again.

```bash
workstation$ kubectl -n lab-07-06 set env deploy/shop-canary PODINFO_RANDOM_ERROR-
workstation$ kubectl -n lab-07-06 rollout status deploy/shop-canary
workstation$ ./progressive.sh; echo "rc=$?"
```

Expected:
```
04:04:24 canary=10%  errors=0/200 (0%)
04:04:33 canary=25%  errors=0/200 (0%)
04:04:42 canary=50%  errors=0/200 (0%)
04:04:52 canary=100%  errors=0/200 (0%)
04:04:52 canary healthy at 100% -> ready to promote
rc=0
```

Promotion (stable gets the new image, weights back to 100/0) works as in the *Your turn* of Lab 7.3.

6. Limits of this design, and what real tools add: the gate measures *all* traffic, so a small canary needs a strict
   threshold (the canary's own error rate was 33%!). Argo Rollouts / Flagger query per-version metrics from
   Prometheus, wait longer per step, and require several successful checks in a row. They also store the rollout
   state in a CRD, so a crashed pipeline does not leave the route at, say, 25%.

### Clean up

```bash
workstation$ kubectl delete namespace lab-07-06
workstation$ rm -rf ~/lab-07-06
client-vm$   rm -rf ~/lab-07          # count.sh from Labs 7.3-7.5
```

### Your turn

Version 6.17.1 fixes the errors but has a performance regression. Reset the route to 100/0, simulate the slow build
with podinfo's random delay (`PODINFO_RANDOM_DELAY=true`, `PODINFO_RANDOM_DELAY_UNIT=ms`,
`PODINFO_RANDOM_DELAY_MIN=300`, `PODINFO_RANDOM_DELAY_MAX=800`) and extend the script with a **latency gate**: at
most 2% of the requests may take longer than 0.5 s. Show that the slow build is rolled back and that a build without
the delay is promoted.

<details><summary>Solution</summary>

Let curl print the status code **and** `time_total`, and let awk count both conditions.

```bash
workstation$ cat > progressive.sh <<'EOF'
#!/bin/sh
# Progressive delivery with two health gates: errors and latency.
NS=lab-07-06
STEPS="10 25 50 100"
REQUESTS=200
MAX_ERROR_PCT=1           # gate 1: max. share of non-2xx answers
SLOW_SECONDS=0.5          # gate 2: a request slower than this is "slow" ...
MAX_SLOW_PCT=2            # ... and at most this share may be slow

setw() {
  kubectl -n $NS patch httproute live --type=json -p "[
    {\"op\":\"replace\",\"path\":\"/spec/rules/0/backendRefs/0/weight\",\"value\":$1},
    {\"op\":\"replace\",\"path\":\"/spec/rules/0/backendRefs/1/weight\",\"value\":$2}]" >/dev/null
}

# prints "<errors> <slow>"
check() {
  kubectl -n $NS exec probe -- sh -c "for i in \$(seq $REQUESTS); do
      curl -s -o /dev/null -m 5 -w '%{http_code} %{time_total}\n' -H 'Host: www.shop.lab' http://shop-nginx/; done" \
    | awk -v slow=$SLOW_SECONDS '$1 !~ /^2/ {e++} $2 > slow {s++} END {print e+0, s+0}'
}

for w in $STEPS; do
  setw $((100 - w)) $w
  sleep 5
  set -- $(check); errors=$1; slow=$2
  echo "$(date +%T) canary=${w}%  errors=${errors}/${REQUESTS}  slow(>${SLOW_SECONDS}s)=${slow}/${REQUESTS}"
  if [ "$errors" -gt $((REQUESTS * MAX_ERROR_PCT / 100)) ] || [ "$slow" -gt $((REQUESTS * MAX_SLOW_PCT / 100)) ]; then
    setw 100 0
    echo "$(date +%T) health gate FAILED -> rolled back to stable (canary weight 0)"
    exit 1
  fi
done
echo "$(date +%T) canary healthy at 100% -> ready to promote"
EOF
workstation$ kubectl -n lab-07-06 patch httproute live --type=json -p '[
  {"op":"replace","path":"/spec/rules/0/backendRefs/0/weight","value":100},
  {"op":"replace","path":"/spec/rules/0/backendRefs/1/weight","value":0}]'
workstation$ kubectl -n lab-07-06 set env deploy/shop-canary PODINFO_RANDOM_DELAY=true \
  PODINFO_RANDOM_DELAY_UNIT=ms PODINFO_RANDOM_DELAY_MIN=300 PODINFO_RANDOM_DELAY_MAX=800
workstation$ kubectl -n lab-07-06 rollout status deploy/shop-canary
workstation$ ./progressive.sh; echo "rc=$?"
```

Expected:
```
04:05:38 canary=10%  errors=0/200  slow(>0.5s)=20/200
04:05:39 health gate FAILED -> rolled back to stable (canary weight 0)
rc=1
```

Remove the delay and release again:
```bash
workstation$ kubectl -n lab-07-06 set env deploy/shop-canary PODINFO_RANDOM_DELAY- \
  PODINFO_RANDOM_DELAY_UNIT- PODINFO_RANDOM_DELAY_MIN- PODINFO_RANDOM_DELAY_MAX-
workstation$ kubectl -n lab-07-06 rollout status deploy/shop-canary
workstation$ ./progressive.sh; echo "rc=$?"
```

Expected:
```
04:05:58 canary=10%  errors=0/200  slow(>0.5s)=0/200
04:06:08 canary=25%  errors=0/200  slow(>0.5s)=0/200
04:06:18 canary=50%  errors=0/200  slow(>0.5s)=0/200
04:06:27 canary=100%  errors=0/200  slow(>0.5s)=0/200
04:06:27 canary healthy at 100% -> ready to promote
rc=0
```
</details>

---

# Part B – Autoscaling

## Lab 7.7: Black Friday traffic – HPA on CPU

**Scenario** – On a normal day one shop Pod is plenty. On Black Friday the traffic goes up tenfold within minutes,
and nobody wants to sit at the keyboard scaling Deployments. You will put a HorizontalPodAutoscaler (HPA) on the
shop, hit it with a realistic load test **through the Gateway**, and watch it scale out—and later back in.

**What you'll learn**
- `autoscaling/v2` HPA with a CPU `Utilization` target (percentage of *requests*)
- Generating load with `fortio` in a Job
- Reading HPA status: `TARGETS`, events, `ScalingLimited`
- The default behaviour: fast scale-up, 5-minute scale-down stabilization

### Steps

1. Create the namespace, the shop with CPU **requests** (the HPA needs them), a Gateway and a route.

```bash
workstation$ kubectl create namespace lab-07-07
workstation$ kubectl apply -n lab-07-07 -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: shop
spec:
  replicas: 1
  selector:
    matchLabels: {app: shop}
  template:
    metadata:
      labels: {app: shop}
    spec:
      containers:
      - name: podinfo
        image: ghcr.io/stefanprodan/podinfo:6.17.0
        ports:
        - containerPort: 9898
        readinessProbe:
          httpGet: {path: /readyz, port: 9898}
        resources:
          requests:
            cpu: 100m
            memory: 64Mi
          limits:
            cpu: 500m
            memory: 128Mi
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
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: shop
spec:
  parentRefs:
  - name: shop
  rules:
  - backendRefs:
    - name: shop
      port: 80
EOF
workstation$ kubectl -n lab-07-07 wait --for=condition=Available deploy --all
```

2. Create the HPA: keep average CPU usage at 50% of the request (50m per Pod), between 1 and 8 replicas.

```bash
workstation$ kubectl apply -n lab-07-07 -f - <<'EOF'
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: shop
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: shop
  minReplicas: 1
  maxReplicas: 8
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: 50
EOF
workstation$ kubectl -n lab-07-07 get hpa shop
```

Expected—`<unknown>` for the first ~30–60 s until metrics-server has a sample, then a real value:
```
NAME   REFERENCE         TARGETS              MINPODS   MAXPODS   REPLICAS   AGE
shop   Deployment/shop   cpu: <unknown>/50%   1         8         1          30s
...
shop   Deployment/shop   cpu: 1%/50%          1         8         1          65s
```

**Why:** the HPA controller polls the metrics API every 15 s and computes
`desired = ceil(current replicas × current utilization / target utilization)`.
Utilization is relative to the **request**, so without a CPU request there is nothing to compute (Lab 7.9).

3. Open a second terminal and watch the HPA.

```bash
workstation$ kubectl -n lab-07-07 get hpa shop -w
```

4. Start the Black Friday rush: a fortio Job sends 800 requests/s over 16 connections for 150 s to the Gateway's
   Service `shop-nginx`, so the traffic passes through NGINX exactly like customer traffic.

```bash
workstation$ kubectl apply -n lab-07-07 -f - <<'EOF'
apiVersion: batch/v1
kind: Job
metadata:
  name: black-friday
spec:
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      containers:
      - name: fortio
        image: fortio/fortio:1.76.0
        args: ["load", "-qps", "800", "-c", "16", "-t", "150s", "-timeout", "3s", "http://shop-nginx/"]
EOF
```

Expected in the watch terminal (sampled every ~15 s):
```
shop   Deployment/shop   cpu: 1%/50%     1     8     1     87s
shop   Deployment/shop   cpu: 204%/50%   1     8     1     117s
shop   Deployment/shop   cpu: 253%/50%   1     8     4     2m12s
shop   Deployment/shop   cpu: 184%/50%   1     8     6     2m27s
shop   Deployment/shop   cpu: 109%/50%   1     8     6     2m42s
shop   Deployment/shop   cpu: 94%/50%    1     8     8     2m57s
shop   Deployment/shop   cpu: 81%/50%    1     8     8     3m12s
shop   Deployment/shop   cpu: 78%/50%    1     8     8     3m58s
```

**Why:** 1 → 4 → 6 → 8. The default scale-up policy allows doubling (or +4 Pods) every 15 s, so it takes a few
rounds to catch up. New Pods must also pass their readiness probe before they get traffic and before their CPU
counts.

5. The HPA is maxed out. Its conditions say so:

```bash
workstation$ kubectl -n lab-07-07 get hpa shop \
  -o jsonpath='{range .status.conditions[*]}{.type}={.status} ({.reason}): {.message}{"\n"}{end}'
workstation$ kubectl -n lab-07-07 describe hpa shop | grep SuccessfulRescale
```

Expected:
```
AbleToScale=True (ScaleDownStabilized): recent recommendations were higher than current one, applying the highest recent recommendation
ScalingActive=True (ValidMetricFound): the HPA was able to successfully calculate a replica count from cpu resource utilization (percentage of request)
ScalingLimited=True (TooManyReplicas): the desired replica count is more than the maximum replica count
ScaledToZero=False (NotScaledToZero): the HPA controller did not scale the workload to zero
  Normal   SuccessfulRescale             2m45s               horizontal-pod-autoscaler  New size: 4; reason: cpu resource utilization (percentage of request) above target
  Normal   SuccessfulRescale             2m30s               horizontal-pod-autoscaler  New size: 6; reason: cpu resource utilization (percentage of request) above target
  Normal   SuccessfulRescale             2m                  horizontal-pod-autoscaler  New size: 8; reason: cpu resource utilization (percentage of request) above target
```

6. How did the customers do? Read the fortio summary.

```bash
workstation$ kubectl -n lab-07-07 wait --for=condition=Complete job/black-friday --timeout=180s
workstation$ kubectl -n lab-07-07 logs job/black-friday | grep -E '^Code|All done|target 99%' | tail -3
```

Expected:
```
# target 99% 0.00846
Code 200 : 120000 (100.0 %)
All done 120000 calls (plus 16 warmup) 5.850 ms avg, 799.9 qps
```

7. Traffic is over, yet the HPA keeps 8 replicas for **5 minutes**, then drops to 1 in one step.

```bash
workstation$ kubectl -n lab-07-07 describe hpa shop | grep SuccessfulRescale | tail -1
```

Expected (about 5 minutes after the load stopped):
```
  Normal   SuccessfulRescale             16s                    horizontal-pod-autoscaler  New size: 1; reason: All metrics below target
```

**Why:** the default `scaleDown.stabilizationWindowSeconds` is 300: the HPA uses the *highest* recommendation of
the last 5 minutes, so a short dip in traffic does not cause flapping. Lab 7.8 tunes this.

### Clean up

```bash
workstation$ kubectl delete namespace lab-07-07
```

### Your turn

At 8 replicas the HPA was limited and CPU stayed at ~78% instead of 50%. Use the numbers you observed to estimate
how many replicas this load really needs, raise `maxReplicas` accordingly, re-run the load test (delete the old Job
first) and show that the HPA reaches its target without `ScalingLimited=True`.

<details><summary>Solution</summary>

Total demand ≈ 8 Pods × 78m ≈ 625m CPU. At a target of 50m per Pod: 625 / 50 ≈ 13 Pods. Leave head-room (and note
that every extra Pod adds a bit of overhead): `maxReplicas: 16`.

```bash
workstation$ kubectl -n lab-07-07 delete job black-friday
workstation$ kubectl -n lab-07-07 patch hpa shop -p '{"spec":{"maxReplicas":16}}'
workstation$ kubectl apply -n lab-07-07 -f - <<'EOF'
apiVersion: batch/v1
kind: Job
metadata:
  name: black-friday
spec:
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      containers:
      - name: fortio
        image: fortio/fortio:1.76.0
        args: ["load", "-qps", "800", "-c", "16", "-t", "150s", "-timeout", "3s", "http://shop-nginx/"]
EOF
workstation$ kubectl -n lab-07-07 get hpa shop -w          # Ctrl+C after ~2 minutes
workstation$ kubectl -n lab-07-07 get hpa shop \
  -o jsonpath='{range .status.conditions[*]}{.type}={.status} ({.reason}){"\n"}{end}'
```

Expected (the start value depends on how many replicas are left from the previous run):
```
shop   Deployment/shop   cpu: 46%/50%   1     16    14    12m
shop   Deployment/shop   cpu: 57%/50%   1     16    14    13m
shop   Deployment/shop   cpu: 59%/50%   1     16    16    13m
shop   Deployment/shop   cpu: 53%/50%   1     16    16    14m
AbleToScale=True (ReadyForNewScale)
ScalingActive=True (ValidMetricFound)
ScalingLimited=False (DesiredWithinRange)
ScaledToZero=False (NotScaledToZero)
```

`53%` is accepted as "on target": the HPA ignores deviations within its 10% tolerance to avoid constant small
corrections. In real capacity planning you would also check that the nodes have room for `maxReplicas × requests`
(16 × 100m = 1.6 CPU here) and that downstream systems (database connections!) can handle that many Pods.
</details>

---

## Lab 7.8: Scale up fast, scale down slowly – multi-metric HPA and behavior

**Scenario** – After Lab 7.7 the shop team has two complaints: scaling up from 1 to 8 Pods took almost two minutes
(customers saw slow pages), and after the rush the HPA waited five minutes and then dropped all Pods at once. They
also want memory as a second signal "to be safe". You will tune the HPA's `behavior` and see what multiple metrics
do—including a memory metric that scales the shop to the maximum for no reason.

**What you'll learn**
- Several metrics in one HPA: the **largest** proposal wins
- `behavior.scaleUp` / `behavior.scaleDown`: `stabilizationWindowSeconds`, `policies`, `selectPolicy`
- Reading the scaling timeline from events
- Why memory is a poor scaling metric for most apps

### Steps

1. Create the namespace and the same shop, Gateway and route as in Lab 7.7.

```bash
workstation$ kubectl create namespace lab-07-08
workstation$ kubectl apply -n lab-07-08 -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: shop
spec:
  replicas: 1
  selector:
    matchLabels: {app: shop}
  template:
    metadata:
      labels: {app: shop}
    spec:
      containers:
      - name: podinfo
        image: ghcr.io/stefanprodan/podinfo:6.17.0
        ports:
        - containerPort: 9898
        readinessProbe:
          httpGet: {path: /readyz, port: 9898}
        resources:
          requests:
            cpu: 100m
            memory: 64Mi
          limits:
            cpu: 500m
            memory: 128Mi
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
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: shop
spec:
  parentRefs:
  - name: shop
  rules:
  - backendRefs:
    - name: shop
      port: 80
EOF
workstation$ kubectl -n lab-07-08 wait --for=condition=Available deploy --all
```

2. Create an HPA with two metrics and explicit behavior:
   - **scale up**: no stabilization; per 15 s add up to +200% *or* +4 Pods, whichever is more (`selectPolicy: Max`),
   - **scale down**: consider the last 60 s of recommendations, then remove at most 2 Pods per 30 s.

```bash
workstation$ kubectl apply -n lab-07-08 -f - <<'EOF'
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: shop
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: shop
  minReplicas: 2
  maxReplicas: 16
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: 50
  - type: Resource
    resource:
      name: memory
      target:
        type: Utilization
        averageUtilization: 80
  behavior:
    scaleUp:
      stabilizationWindowSeconds: 0
      selectPolicy: Max
      policies:
      - type: Percent
        value: 200
        periodSeconds: 15
      - type: Pods
        value: 4
        periodSeconds: 15
    scaleDown:
      stabilizationWindowSeconds: 60
      selectPolicy: Min
      policies:
      - type: Pods
        value: 2
        periodSeconds: 30
EOF
workstation$ sleep 60; kubectl -n lab-07-08 get hpa shop
```

Expected:
```
NAME   REFERENCE         TARGETS                        MINPODS   MAXPODS   REPLICAS   AGE
shop   Deployment/shop   cpu: 1%/50%, memory: 26%/80%   2         16        2          60s
```

**Why:** `minReplicas: 2`—never run a customer-facing service on a single Pod. With several metrics the HPA computes
a replica count for each and takes the **maximum**, so adding a metric can only make it scale *more*, never less.

3. Run 2 minutes of load (same fortio Job as in Lab 7.7, 120 s) and keep `kubectl -n lab-07-08 get hpa shop -w`
   open in a second terminal.

```bash
workstation$ kubectl apply -n lab-07-08 -f - <<'EOF'
apiVersion: batch/v1
kind: Job
metadata:
  name: black-friday
spec:
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      containers:
      - name: fortio
        image: fortio/fortio:1.76.0
        args: ["load", "-qps", "800", "-c", "16", "-t", "120s", "-timeout", "3s", "http://shop-nginx/"]
EOF
```

4. About 5 minutes after the start, print the scaling timeline from the events:

```bash
workstation$ kubectl -n lab-07-08 get events --field-selector reason=SuccessfulRescale \
  -o custom-columns=TIME:.lastTimestamp,MSG:.message --sort-by=.lastTimestamp
```

Expected (load from 03:27:10 to 03:29:10):
```
TIME                   MSG
2026-11-04T03:25:38Z   New size: 2; reason: Current number of replicas below Spec.MinReplicas
2026-11-04T03:27:23Z   New size: 6; reason: cpu resource utilization (percentage of request) above target
2026-11-04T03:28:08Z   New size: 12; reason: cpu resource utilization (percentage of request) above target
2026-11-04T03:30:09Z   New size: 10; reason: All metrics below target
2026-11-04T03:30:39Z   New size: 8; reason: All metrics below target
2026-11-04T03:31:09Z   New size: 6; reason: All metrics below target
2026-11-04T03:31:39Z   New size: 5; reason: All metrics below target
2026-11-04T03:32:09Z   New size: 4; reason: All metrics below target
2026-11-04T03:32:39Z   New size: 3; reason: All metrics below target
2026-11-04T03:33:40Z   (combined from similar events): New size: 2; reason: All metrics below target
```

**Why:**
- Scale-up: 2 → 6 in one step (+200%), compared to 1 → 4 → 6 → 8 with the defaults in Lab 7.7.
- Scale-down started ~60 s after the load ended (not 300 s), then went down by at most 2 Pods every 30 s. The
  2-Pod policy is a *limit*; towards the end the steps are smaller because the 60 s window keeps the highest
  recent recommendation. If traffic comes back during scale-down, plenty of Pods are still there.

5. Now the memory "safety" metric bites. A new release preloads a 60 MB product catalog into memory at startup
   (simulated with podinfo's `PODINFO_STRESS_MEMORY`). There is no traffic at all.

```bash
workstation$ kubectl -n lab-07-08 set env deploy/shop PODINFO_STRESS_MEMORY=60
workstation$ kubectl -n lab-07-08 rollout status deploy/shop
workstation$ sleep 120; kubectl -n lab-07-08 get hpa shop
workstation$ kubectl top pod -n lab-07-08 -l app=shop | head -4
workstation$ kubectl -n lab-07-08 describe hpa shop | grep -A3 '^Metrics'
```

Expected (and still growing):
```
NAME   REFERENCE         TARGETS                         MINPODS   MAXPODS   REPLICAS   AGE
shop   Deployment/shop   cpu: 1%/50%, memory: 118%/80%   2         16        8          11m
NAME                    CPU(cores)   MEMORY(bytes)
shop-55554f86fc-8bhh4   1m           78Mi
shop-55554f86fc-lzc2h   1m           76Mi
shop-55554f86fc-r4ht2   10m          73Mi
Metrics:                                                  ( current / target )
  resource cpu on pods  (as a percentage of request):     1% (1m) / 50%
  resource memory on pods  (as a percentage of request):  118% (79266474666m) / 80%
```

**Why:** every new Pod loads the same 60 MB, so the *average* memory never drops—adding Pods does not reduce the
metric, and the HPA keeps scaling towards `maxReplicas`. Memory works as an HPA metric only if memory grows with
load *and* is released when load moves to other Pods (rare for caches, JVMs and Go apps). Here the right fix is a
higher memory **request** (78Mi used vs. 64Mi requested), and removing the memory metric:

```bash
workstation$ kubectl -n lab-07-08 patch hpa shop --type=json -p '[{"op":"remove","path":"/spec/metrics/1"}]'
```

### Clean up

```bash
workstation$ kubectl delete namespace lab-07-08
```

### Your turn

It's Black Friday morning. The SRE team wants a **scale-down freeze** for the day: the HPA may add Pods but must never
remove them, even when CPU is at 1%. In the evening the freeze is lifted. Implement both changes on the HPA (without
touching `minReplicas`) and show the HPA status while frozen.
Apply the freeze right after step 5, while the HPA still holds many replicas (or re-run the load Job first).

<details><summary>Solution</summary>

`selectPolicy: Disabled` turns off one direction completely.

```bash
workstation$ kubectl -n lab-07-08 patch hpa shop --type=merge \
  -p '{"spec":{"behavior":{"scaleDown":{"selectPolicy":"Disabled"}}}}'
workstation$ sleep 100; kubectl -n lab-07-08 get hpa shop
workstation$ kubectl -n lab-07-08 get hpa shop \
  -o jsonpath='{range .status.conditions[?(@.type=="ScalingLimited")]}{.reason}: {.message}{"\n"}{end}'
```

Expected—1% CPU, still 8 replicas:
```
NAME   REFERENCE         TARGETS       MINPODS   MAXPODS   REPLICAS   AGE
shop   Deployment/shop   cpu: 1%/50%   2         16        8          13m
ScaleDownLimit: the desired replica count is decreasing faster than the maximum scale rate
```

Lift the freeze in the evening:
```bash
workstation$ kubectl -n lab-07-08 patch hpa shop --type=merge \
  -p '{"spec":{"behavior":{"scaleDown":{"selectPolicy":"Min"}}}}'
workstation$ sleep 75; kubectl -n lab-07-08 get events --field-selector reason=SuccessfulRescale \
  -o custom-columns=TIME:.lastTimestamp,MSG:.message --sort-by=.lastTimestamp | tail -2
```

Expected:
```
2026-11-04T03:39:56Z   New size: 4; reason: All metrics below target
2026-11-04T03:40:26Z   (combined from similar events): New size: 2; reason: All metrics below target
```

Compared to raising `minReplicas`, `Disabled` keeps the HPA free to scale *up* and does not force an immediate
scale-out; it just holds what the traffic already required. Lab 7.12 automates such schedule-based changes.
</details>

---

## Lab 7.9: Why doesn't my HPA scale? – troubleshooting

**Scenario** – Three tickets from the platform channel: "the HPA shows `<unknown>`", "the checkout HPA does
nothing", and the nastiest one: "every time CI deploys, half of our Pods disappear for a few seconds". You will
reproduce each problem, read the HPA conditions and events that explain it, and fix it—including the GitOps pitfall
where re-applying a manifest fights with the HPA.

**What you'll learn**
- The three HPA conditions: `AbleToScale`, `ScalingActive`, `ScalingLimited`
- `missing request for cpu` and `FailedGetScale`
- Why `spec.replicas` in a manifest and an HPA do not mix
- Removing `replicas` from a manifest **safely** (`kubectl apply set-last-applied`)

### Steps

1. Create the namespace, an `api` Deployment **without resource requests**, an HPA for it, and an HPA for a
   Deployment called `checkout-api`.

```bash
workstation$ kubectl create namespace lab-07-09
workstation$ kubectl apply -n lab-07-09 -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: api
spec:
  replicas: 1
  selector:
    matchLabels: {app: api}
  template:
    metadata:
      labels: {app: api}
    spec:
      containers:
      - name: podinfo
        image: ghcr.io/stefanprodan/podinfo:6.17.0
        ports:
        - containerPort: 9898
---
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: api
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: api
  minReplicas: 2
  maxReplicas: 6
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: 60
---
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: checkout
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: checkout-api
  minReplicas: 2
  maxReplicas: 6
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: 60
EOF
```

2. Wait a minute, then look at both HPAs and their conditions.

```bash
workstation$ kubectl -n lab-07-09 get hpa
workstation$ for h in api checkout; do echo "== $h"
  kubectl -n lab-07-09 get hpa $h -o jsonpath='{range .status.conditions[*]}{.type}={.status} ({.reason}): {.message}{"\n"}{end}'
done
```

Expected:
```
NAME       REFERENCE                 TARGETS              MINPODS   MAXPODS   REPLICAS   AGE
api        Deployment/api            cpu: <unknown>/60%   2         6         2          60s
checkout   Deployment/checkout-api   cpu: <unknown>/60%   2         6         0          60s
== api
AbleToScale=True (SucceededGetScale): the HPA controller was able to get the target's current scale
ScaledToZero=False (NotScaledToZero): the HPA controller did not scale the workload to zero
ScalingActive=False (FailedGetResourceMetric): the HPA was unable to compute the replica count: failed to get cpu utilization: missing request for cpu in container podinfo of Pod api-789b4d784d-s486q
== checkout
AbleToScale=False (FailedGetScale): the HPA controller was unable to get the target's current scale: deployments.apps "checkout-api" not found
```

Both show `<unknown>`, for different reasons—**always read the conditions**:

| Condition | Meaning | Typical causes |
|-----------|---------|----------------|
| `AbleToScale=False` | the HPA cannot read/modify the target's `/scale` | wrong `scaleTargetRef` name/kind/apiVersion, RBAC |
| `ScalingActive=False` | no usable metric | missing requests, metrics-server down (`no metrics returned from resource metrics API`), Pods not ready yet |
| `ScalingLimited=True` | desired count clipped | `minReplicas`/`maxReplicas` reached (Lab 7.7) |

Note that `api` still runs **2** replicas: `minReplicas` is enforced even without metrics.

3. Fix both: the checkout team has not deployed yet (delete the HPA), and `api` gets requests. This time the team
   manages the Deployment as a file in Git, *with* `replicas: 1` as it always has, and the HPA minimum is raised to 3.

```bash
workstation$ kubectl -n lab-07-09 delete hpa checkout
workstation$ mkdir -p ~/lab-07-09 && cd ~/lab-07-09
workstation$ cat > api.yaml <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: api
spec:
  replicas: 1
  selector:
    matchLabels: {app: api}
  template:
    metadata:
      labels: {app: api}
    spec:
      containers:
      - name: podinfo
        image: ghcr.io/stefanprodan/podinfo:6.17.0
        ports:
        - containerPort: 9898
        resources:
          requests:
            cpu: 100m
            memory: 64Mi
---
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: api
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: api
  minReplicas: 3
  maxReplicas: 6
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: 60
EOF
workstation$ kubectl apply -n lab-07-09 -f api.yaml
workstation$ sleep 45; kubectl -n lab-07-09 get hpa api
```

Expected:
```
NAME   REFERENCE        TARGETS       MINPODS   MAXPODS   REPLICAS   AGE
api    Deployment/api   cpu: 5%/60%   3         6         3          116s
```

4. The CI pipeline re-applies the same file (as it does on every commit). Watch `spec.replicas`:

```bash
workstation$ kubectl apply -n lab-07-09 -f api.yaml
workstation$ for i in $(seq 1 8); do
  echo "$(date +%T) spec.replicas=$(kubectl -n lab-07-09 get deploy api -o jsonpath='{.spec.replicas}')"; sleep 3; done
workstation$ kubectl -n lab-07-09 get events --field-selector involvedObject.kind=Deployment --sort-by=.lastTimestamp | tail -2
```

Expected:
```
04:14:58 spec.replicas=1
04:15:01 spec.replicas=1
04:15:05 spec.replicas=1
04:15:08 spec.replicas=1
04:15:11 spec.replicas=1
04:15:14 spec.replicas=3
04:15:17 spec.replicas=3
04:15:20 spec.replicas=3
38s         Normal   ScalingReplicaSet   deployment/api   Scaled down replica set api-6d6b9b5dc7 from 3 to 1
25s         Normal   ScalingReplicaSet   deployment/api   Scaled up replica set api-6d6b9b5dc7 from 1 to 3
```

**Why:** `kubectl apply` (and Argo CD / Flux) writes `replicas: 1` back into the Deployment, two Pods are killed
immediately, and ~15 s later the HPA scales back up. With an HPA at 12 replicas under Black Friday load, this
"deploy" drops capacity by 90%. **Rule: if an HPA manages a Deployment, the manifest must not contain
`spec.replicas`.**

5. Remove the field from the file and apply. Surprise:

```bash
workstation$ sed -i.bak '/^  replicas: 1$/d' api.yaml     # GNU and BSD sed
workstation$ grep -c replicas api.yaml
workstation$ kubectl apply -n lab-07-09 -f api.yaml
workstation$ for i in 1 2 3; do echo "$(date +%T) spec.replicas=$(kubectl -n lab-07-09 get deploy api -o jsonpath='{.spec.replicas}')"; sleep 2; done
```

Expected:
```
0
04:15:43 spec.replicas=1
04:15:45 spec.replicas=1
04:15:47 spec.replicas=1
```

**Why:** client-side `kubectl apply` remembers the last applied file in the
`kubectl.kubernetes.io/last-applied-configuration` annotation. A field that *was* in the last applied file and is
missing now is **deleted** from the object—and a deleted `replicas` defaults to 1. It happens only once (after that
the annotation no longer contains `replicas`), but once is enough to hurt. Wait for the HPA to restore 3 replicas
before the next step.

6. The safe way: first rewrite the annotation to the new file, then apply. To reproduce the starting situation, put
   `replicas: 1` back with the backup file first.

```bash
workstation$ kubectl apply -n lab-07-09 -f api.yaml.bak; sleep 25     # back to the old state, HPA restores 3
workstation$ kubectl -n lab-07-09 get deploy api -o jsonpath='{.spec.replicas}{"\n"}'
workstation$ kubectl -n lab-07-09 apply set-last-applied -f api.yaml
workstation$ kubectl apply -n lab-07-09 -f api.yaml
workstation$ for i in 1 2 3; do echo "$(date +%T) spec.replicas=$(kubectl -n lab-07-09 get deploy api -o jsonpath='{.spec.replicas}')"; sleep 2; done
```

Expected:
```
3
deployment.apps/api configured
horizontalpodautoscaler.autoscaling/api configured
deployment.apps/api configured
horizontalpodautoscaler.autoscaling/api configured
04:16:51 spec.replicas=3
04:16:53 spec.replicas=3
04:16:55 spec.replicas=3
```

With server-side apply (`kubectl apply --server-side`, Argo CD's `ServerSideApply=true`) the HPA owns the
`replicas` field via managed fields, and the problem largely disappears.

### Clean up

```bash
workstation$ kubectl delete namespace lab-07-09
workstation$ rm -rf ~/lab-07-09
```

### Your turn

The `api` team adds a `log-shipper` sidecar (busybox, no resource requests—"it's just a sidecar"). Apply the new
Deployment below, observe what happens to the HPA, and fix the HPA **without** adding requests to the sidecar.

```bash
workstation$ kubectl apply -n lab-07-09 -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: api
spec:
  selector:
    matchLabels: {app: api}
  template:
    metadata:
      labels: {app: api}
    spec:
      containers:
      - name: podinfo
        image: ghcr.io/stefanprodan/podinfo:6.17.0
        ports:
        - containerPort: 9898
        resources:
          requests:
            cpu: 100m
            memory: 64Mi
      - name: log-shipper
        image: busybox:1.38
        command: ["sh", "-c", "while true; do sleep 3600; done"]
EOF
```

<details><summary>Solution</summary>

A `Resource` metric averages over **all** containers of the Pod, so every container needs a request:

```bash
workstation$ sleep 50; kubectl -n lab-07-09 get hpa api
workstation$ kubectl -n lab-07-09 get hpa api \
  -o jsonpath='{range .status.conditions[?(@.type=="ScalingActive")]}{.reason}: {.message}{"\n"}{end}'
```

Expected:
```
NAME   REFERENCE        TARGETS              MINPODS   MAXPODS   REPLICAS   AGE
api    Deployment/api   cpu: <unknown>/60%   3         6         3          10m
FailedGetResourceMetric: the HPA was unable to compute the replica count: failed to get cpu utilization: missing request for cpu in container log-shipper of Pod api-6b68b89c4c-t5zdc
```

Scale on the CPU of the application container only, with a `ContainerResource` metric (GA since Kubernetes 1.30).
This is also more accurate: a busy sidecar should not trigger scaling of the app.

```bash
workstation$ kubectl apply -n lab-07-09 -f - <<'EOF'
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: api
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: api
  minReplicas: 3
  maxReplicas: 6
  metrics:
  - type: ContainerResource
    containerResource:
      name: cpu
      container: podinfo
      target:
        type: Utilization
        averageUtilization: 60
EOF
workstation$ sleep 30; kubectl -n lab-07-09 get hpa api
workstation$ kubectl -n lab-07-09 get hpa api \
  -o jsonpath='{range .status.conditions[?(@.type=="ScalingActive")]}{.reason}: {.message}{"\n"}{end}'
```

Expected:
```
NAME   REFERENCE        TARGETS       MINPODS   MAXPODS   REPLICAS   AGE
api    Deployment/api   cpu: 0%/60%   3         6         3          11m
ValidMetricFound: the HPA was able to successfully calculate a replica count from cpu container resource utilization (percentage of request)
```
</details>

---

## Lab 7.10: More CPU without a restart – in-place Pod resize

**Scenario** – The monthly report generator runs as a long-lived Pod that keeps a large in-memory cache. At month-end
it needs five times more CPU for a few hours, but restarting it means rebuilding the cache for 20 minutes. Since
Kubernetes 1.35 (GA), Pod CPU and memory can be changed **in place**. You will give the Pod more CPU without a
restart, see why a memory change is configured to restart the container, and what happens when the node is full.

**What you'll learn**
- The `resize` subresource: `kubectl patch pod … --subresource resize`
- `resizePolicy` per resource: `NotRequired` vs `RestartContainer`
- Reading desired (`spec`) vs. actual (`status.containerStatuses[].resources`) resources and the cgroup values
- `PodResizeInProgress` / `PodResizePending` (`Deferred`) and admission-time rejection

### Steps

1. Create the namespace and the Pod. CPU can change without a restart; memory changes restart the container (many
   runtimes—JVM `-Xmx`, Node.js heap—only read their memory limit at startup).

```bash
workstation$ kubectl create namespace lab-07-10
workstation$ kubectl apply -n lab-07-10 -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: report
spec:
  containers:
  - name: podinfo
    image: ghcr.io/stefanprodan/podinfo:6.17.0
    resizePolicy:
    - resourceName: cpu
      restartPolicy: NotRequired
    - resourceName: memory
      restartPolicy: RestartContainer
    resources:
      requests:
        cpu: 100m
        memory: 64Mi
      limits:
        cpu: 200m
        memory: 128Mi
EOF
workstation$ kubectl -n lab-07-10 wait --for=condition=Ready pod/report
workstation$ kubectl -n lab-07-10 get pod report \
  -o jsonpath='{.status.qosClass} restarts={.status.containerStatuses[0].restartCount} {.status.containerStatuses[0].resources}{"\n"}'
workstation$ kubectl -n lab-07-10 exec report -- cat /sys/fs/cgroup/cpu.max /sys/fs/cgroup/memory.max
```

Expected:
```
Burstable restarts=0 {"limits":{"cpu":"200m","memory":"128Mi"},"requests":{"cpu":"100m","memory":"64Mi"}}
20000 100000
134217728
```

**Why:** `cpu.max` = `20000 100000` means 20 ms of CPU time per 100 ms period = 200m. `memory.max` is 128 MiB.
These cgroup files are what the kernel actually enforces.

2. Month-end: raise CPU to request 500m / limit 1 CPU, in place.

```bash
workstation$ kubectl -n lab-07-10 patch pod report --subresource resize --patch \
  '{"spec":{"containers":[{"name":"podinfo","resources":{"requests":{"cpu":"500m"},"limits":{"cpu":"1"}}}]}}'
workstation$ sleep 5
workstation$ kubectl -n lab-07-10 get pod report \
  -o jsonpath='restarts={.status.containerStatuses[0].restartCount} status={.status.containerStatuses[0].resources}{"\n"}'
workstation$ kubectl -n lab-07-10 exec report -- cat /sys/fs/cgroup/cpu.max
workstation$ kubectl -n lab-07-10 get events --field-selector involvedObject.name=report | grep Resize
```

Expected:
```
pod/report patched
restarts=0 status={"limits":{"cpu":"1","memory":"128Mi"},"requests":{"cpu":"500m","memory":"64Mi"}}
100000 100000
5s          Normal   ResizeStarted     pod/report   Pod resize started: {"containers":[{"name":"podinfo","resources":{"limits":{"cpu":"1","memory":"128Mi"},"requests":{"cpu":"500m","memory":"64Mi"}}}],"generation":2}
5s          Normal   ResizeCompleted   pod/report   Pod resize completed: {"containers":[{"name":"podinfo","resources":{"limits":{"cpu":"1","memory":"128Mi"},"requests":{"cpu":"500m","memory":"64Mi"}}}],"generation":2}
```

**Why:** the kubelet changed the cgroup (`100000 100000` = 1 CPU) while the process kept running—`restarts=0`, the
cache survives. A plain `kubectl edit pod` would be rejected: resources can only be changed through the `resize`
subresource (which also has its own RBAC permission, `pods/resize`).

3. The cache grows: give it more memory. This container's policy says `RestartContainer`.

```bash
workstation$ kubectl -n lab-07-10 patch pod report --subresource resize --patch \
  '{"spec":{"containers":[{"name":"podinfo","resources":{"requests":{"memory":"256Mi"},"limits":{"memory":"512Mi"}}}]}}'
workstation$ sleep 8
workstation$ kubectl -n lab-07-10 get pod report \
  -o jsonpath='restarts={.status.containerStatuses[0].restartCount} status={.status.containerStatuses[0].resources}{"\n"}'
workstation$ kubectl -n lab-07-10 exec report -- cat /sys/fs/cgroup/memory.max
workstation$ kubectl -n lab-07-10 get pod report
```

Expected:
```
restarts=1 status={"limits":{"cpu":"1","memory":"512Mi"},"requests":{"cpu":"500m","memory":"256Mi"}}
536870912
NAME     READY   STATUS    RESTARTS     AGE
report   1/1     Running   1 (6s ago)   29s
```

**Why:** the **container** restarted, the **Pod** did not: same name, same IP, same node, no rescheduling. Choose
`NotRequired` for memory only if the application adapts to a changed limit at runtime.

4. Ask for more than the node has in total—the API server rejects it at once:

```bash
workstation$ kubectl -n lab-07-10 patch pod report --subresource resize --patch \
  '{"spec":{"containers":[{"name":"podinfo","resources":{"requests":{"cpu":"20"},"limits":{"cpu":"20"}}}]}}'
```

Expected:
```
Error from server (Forbidden): pods "report" is forbidden: node didn't have enough allocatable resources: cpu, requested: 20000, allocatable: 4000
```

5. Ask for something that fits the node's capacity but not its *free* capacity (other Pods hold requests):

```bash
workstation$ kubectl -n lab-07-10 patch pod report --subresource resize --patch \
  '{"spec":{"containers":[{"name":"podinfo","resources":{"requests":{"cpu":"3900m"},"limits":{"cpu":"4"}}}]}}'
workstation$ sleep 5
workstation$ kubectl -n lab-07-10 get pod report \
  -o jsonpath='{range .status.conditions[*]}{.type}={.status} ({.reason}) {.message}{"\n"}{end}' | grep -i resize
workstation$ kubectl -n lab-07-10 get pod report \
  -o jsonpath='spec={.spec.containers[0].resources.requests} status={.status.containerStatuses[0].resources.requests}{"\n"}'
```

Expected:
```
PodResizePending=True (Deferred) Node didn't have enough resource: cpu, requested: 3900, used: 650, capacity: 4000
spec={"cpu":"3900m","memory":"256Mi"} status={"cpu":"500m","memory":"256Mi"}
```

**Why:** `Deferred` means "maybe later": the kubelet retries when other Pods on the node free resources. The Pod is
**not** moved to another node—in-place resize never reschedules. Desired (`spec`) and actual (`status`) now differ,
which is exactly what you must monitor. Go back to a feasible size:

```bash
workstation$ kubectl -n lab-07-10 patch pod report --subresource resize --patch \
  '{"spec":{"containers":[{"name":"podinfo","resources":{"requests":{"cpu":"500m"},"limits":{"cpu":"1"}}}]}}'
```

### Clean up

```bash
workstation$ kubectl delete namespace lab-07-10
```

### Your turn

The report service is actually a Deployment `reports` (2 replicas, CPU 100m/200m, CPU `NotRequired`). Resize both
Pods in place to 400m/800m. Then somebody runs `kubectl rollout restart deploy/reports`. Predict and verify the CPU
of the new Pods. What is the right way to make the bigger size permanent, and what does it cost?

<details><summary>Solution</summary>

```bash
workstation$ kubectl apply -n lab-07-10 -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: reports
spec:
  replicas: 2
  selector:
    matchLabels: {app: reports}
  template:
    metadata:
      labels: {app: reports}
    spec:
      containers:
      - name: podinfo
        image: ghcr.io/stefanprodan/podinfo:6.17.0
        resizePolicy:
        - resourceName: cpu
          restartPolicy: NotRequired
        resources:
          requests:
            cpu: 100m
            memory: 64Mi
          limits:
            cpu: 200m
            memory: 128Mi
EOF
workstation$ kubectl -n lab-07-10 rollout status deploy/reports
workstation$ for p in $(kubectl -n lab-07-10 get pod -l app=reports -o name); do
  kubectl -n lab-07-10 patch $p --subresource resize --patch \
    '{"spec":{"containers":[{"name":"podinfo","resources":{"requests":{"cpu":"400m"},"limits":{"cpu":"800m"}}}]}}'
done
workstation$ cols='POD:.metadata.name,CPU_REQ:.status.containerStatuses[0].resources.requests.cpu,CPU_LIM:.status.containerStatuses[0].resources.limits.cpu,RESTARTS:.status.containerStatuses[0].restartCount'
workstation$ kubectl -n lab-07-10 get pod -l app=reports -o custom-columns=$cols
workstation$ kubectl -n lab-07-10 rollout restart deploy/reports
workstation$ kubectl -n lab-07-10 rollout status deploy/reports
workstation$ kubectl -n lab-07-10 get pod -l app=reports -o custom-columns=$cols
```

Expected:
```
POD                       CPU_REQ   CPU_LIM   RESTARTS
reports-96fd485c8-8z5cf   400m      800m      0
reports-96fd485c8-cs4zg   400m      800m      0
...
POD                        CPU_REQ   CPU_LIM   RESTARTS
reports-79447f9799-hjdbz   100m      200m      0
reports-79447f9799-nsl5z   100m      200m      0
```

(Old Pods may still be listed for a few seconds while they terminate.) The resize changed **Pods**, not the
Deployment's template—so any new Pod (restart, rollout, node failure, HPA scale-out) gets the template size again.
To make it permanent, change the template (`kubectl set resources deploy/reports --requests=cpu=400m
--limits=cpu=800m`, or in Git). That creates a new ReplicaSet and replaces the Pods—a restart after all. In-place
resize is for *temporary* or *automated* adjustments, which is exactly how the VPA uses it in the next lab.
</details>

---

## Lab 7.11: Right-sizing with the Vertical Pod Autoscaler

**Scenario** – The FinOps report shows the cluster is 80% "reserved" but only 10% used. The `catalog` team copied
`1 CPU / 1Gi` requests from a template "to be safe", while the `search` team set `10m / 32Mi` and gets CPU-throttled.
Nobody knows the right numbers. The Vertical Pod Autoscaler (VPA) watches actual usage and recommends—or
applies—requests. You will install it, read recommendations, and let it resize Pods **in place**.

**⚠ cluster-wide:** this lab installs the VPA (CRDs, three controllers in `kube-system`, a mutating webhook). The
*Clean up* section uninstalls it.

**What you'll learn**
- Installing VPA 1.8.1 from `kubernetes/autoscaler`
- `updateMode: Off` (recommendation only) and reading `lowerBound` / `target` / `upperBound`
- `updateMode: InPlaceOrRecreate`: the updater resizes running Pods without restarting them
- The admission controller sets requests on new Pods; `resourcePolicy` puts guard rails around it

### Steps

1. Install the VPA (needs `git` and `openssl` on the workstation; the script generates the webhook certificate).

```bash
workstation$ mkdir -p ~/lab-07-11 && cd ~/lab-07-11
workstation$ git clone -q --depth 1 --branch vertical-pod-autoscaler-1.8.1 https://github.com/kubernetes/autoscaler.git
workstation$ cd autoscaler/vertical-pod-autoscaler && ./hack/vpa-up.sh
workstation$ kubectl -n kube-system get deploy vpa-admission-controller vpa-recommender vpa-updater \
  -o custom-columns=NAME:.metadata.name,READY:.status.readyReplicas,IMAGE:.spec.template.spec.containers[0].image
```

Expected:
```
NAME                       READY   IMAGE
vpa-admission-controller   1       registry.k8s.io/autoscaling/vpa-admission-controller:1.8.1
vpa-recommender            1       registry.k8s.io/autoscaling/vpa-recommender:1.8.1
vpa-updater                1       registry.k8s.io/autoscaling/vpa-updater:1.8.1
```

**Why three parts:** the *recommender* reads metrics and computes recommendations, the *updater* applies them to
running Pods (in place or by eviction), the *admission controller* (a mutating webhook) sets requests on every new
Pod.

2. Create the namespace, the over-provisioned `catalog` (1 CPU / 1Gi request), a constant 150 req/s of traffic, and a
   VPA in recommendation-only mode.

```bash
workstation$ kubectl create namespace lab-07-11
workstation$ kubectl apply -n lab-07-11 -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: catalog
spec:
  replicas: 2
  selector:
    matchLabels: {app: catalog}
  template:
    metadata:
      labels: {app: catalog}
    spec:
      containers:
      - name: podinfo
        image: ghcr.io/stefanprodan/podinfo:6.17.0
        ports:
        - containerPort: 9898
        resources:
          requests:
            cpu: "1"
            memory: 1Gi
          limits:
            cpu: "2"
            memory: 2Gi
---
apiVersion: v1
kind: Service
metadata:
  name: catalog
spec:
  selector: {app: catalog}
  ports:
  - port: 80
    targetPort: 9898
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: traffic
spec:
  replicas: 1
  selector:
    matchLabels: {app: traffic}
  template:
    metadata:
      labels: {app: traffic}
    spec:
      containers:
      - name: fortio
        image: fortio/fortio:1.76.0
        args: ["load", "-qps", "150", "-c", "4", "-t", "0", "http://catalog/"]   # -t 0 = run forever
        resources:
          requests: {cpu: 50m, memory: 32Mi}
---
apiVersion: autoscaling.k8s.io/v1
kind: VerticalPodAutoscaler
metadata:
  name: catalog
spec:
  targetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: catalog
  updatePolicy:
    updateMode: "Off"
EOF
workstation$ kubectl -n lab-07-11 wait --for=condition=Available deploy --all
```

3. After about 90 seconds the recommender has enough samples for a first recommendation.

```bash
workstation$ kubectl -n lab-07-11 get vpa
workstation$ kubectl top pod -n lab-07-11 -l app=catalog
workstation$ kubectl -n lab-07-11 get vpa catalog -o jsonpath='{.status.recommendation.containerRecommendations[0]}' | jq .
```

Expected:
```
NAME      MODE   CPU   MEM     PROVIDED   AGE
catalog   Off    78m   250Mi   True       92s
NAME                       CPU(cores)   MEMORY(bytes)
catalog-649ccff46-9q8pz    71m          25Mi
catalog-649ccff46-fv826    53m          27Mi
{
  "containerName": "podinfo",
  "lowerBound": {
    "cpu": "25m",
    "memory": "250Mi"
  },
  "target": {
    "cpu": "78m",
    "memory": "250Mi"
  },
  "uncappedTarget": {
    "cpu": "78m",
    "memory": "250Mi"
  },
  "upperBound": {
    "cpu": "962820m",
    "memory": "447511086205"
  }
}
```

How to read it:
- **target** is what VPA would set: 78m CPU instead of 1 CPU—the team reserved 13× too much.
- Memory shows **250Mi** although Pods use ~26Mi: that is the recommender's default *minimum* per Pod
  (`--pod-recommendation-min-memory-mb=250`).
- **lowerBound/upperBound** describe the confidence range. With only minutes of history the upper bound is absurd;
  it narrows over hours and days. The updater only acts on running Pods whose requests are **outside** this range,
  so `catalog` (1 CPU is "within" 25m–962 CPU) would not be touched yet.

`Off` mode is the safe way to start: collect recommendations for a week, compare them with your requests, then
decide. Real VPA recommendations need representative traffic (including peaks).

4. The `search` team is the opposite case: 10m / 32Mi, below what it needs. Give it a VPA in `InPlaceOrRecreate`
   mode and watch the Pods.

```bash
workstation$ kubectl apply -n lab-07-11 -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: search
spec:
  replicas: 2
  selector:
    matchLabels: {app: search}
  template:
    metadata:
      labels: {app: search}
    spec:
      containers:
      - name: podinfo
        image: ghcr.io/stefanprodan/podinfo:6.17.0
        ports:
        - containerPort: 9898
        resources:
          requests:
            cpu: 10m
            memory: 32Mi
          limits:
            cpu: 20m
            memory: 64Mi
---
apiVersion: v1
kind: Service
metadata:
  name: search
spec:
  selector: {app: search}
  ports:
  - port: 80
    targetPort: 9898
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: search-traffic
spec:
  replicas: 1
  selector:
    matchLabels: {app: search-traffic}
  template:
    metadata:
      labels: {app: search-traffic}
    spec:
      containers:
      - name: fortio
        image: fortio/fortio:1.76.0
        args: ["load", "-qps", "150", "-c", "4", "-t", "0", "http://search/"]
        resources:
          requests: {cpu: 50m, memory: 32Mi}
---
apiVersion: autoscaling.k8s.io/v1
kind: VerticalPodAutoscaler
metadata:
  name: search
spec:
  targetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: search
  updatePolicy:
    updateMode: InPlaceOrRecreate
EOF
workstation$ cols='POD:.metadata.name,CPU:.status.containerStatuses[0].resources.requests.cpu,MEM:.status.containerStatuses[0].resources.requests.memory,CPU_LIM:.status.containerStatuses[0].resources.limits.cpu,RESTARTS:.status.containerStatuses[0].restartCount'
workstation$ for i in $(seq 1 9); do sleep 20; echo "--- $(date +%T)"
  kubectl -n lab-07-11 get vpa search --no-headers
  kubectl -n lab-07-11 get pod -l app=search -o custom-columns=$cols --no-headers
done
```

Expected over ~3 minutes (trimmed):
```
--- 04:44:42
search   InPlaceOrRecreate                     21s
search-79bbcf7f89-fmgqj   10m   32Mi   20m   0
search-79bbcf7f89-nmxwd   10m   32Mi   20m   0
--- 04:45:02
search   InPlaceOrRecreate   25m   250Mi   True   41s
search-79bbcf7f89-fmgqj   10m   32Mi   20m   0
search-79bbcf7f89-nmxwd   10m   32Mi   20m   0
--- 04:46:03
search   InPlaceOrRecreate   35m   250Mi   True   102s
search-79bbcf7f89-fmgqj   25m   250Mi   50m   0
search-79bbcf7f89-nmxwd   10m   32Mi    20m   0
--- 04:47:03
search   InPlaceOrRecreate   63m   250Mi   True   2m42s
search-79bbcf7f89-fmgqj   25m   250Mi   50m   0
search-79bbcf7f89-nmxwd   35m   250Mi   70m   0
```

```bash
workstation$ kubectl -n lab-07-11 get events --sort-by=.lastTimestamp | grep -E 'InPlaceResizedByVPA|ResizeCompleted'
```

Expected:
```
2m39s   Normal   InPlaceResizedByVPA   pod/search-79bbcf7f89-fmgqj   Pod was resized in place by VPA Updater.
2m39s   Normal   ResizeCompleted       pod/search-79bbcf7f89-fmgqj   Pod resize completed: {"containers":[{"name":"podinfo","resources":{"limits":{"cpu":"50m","memory":"500Mi"},"requests":{"cpu":"25m","memory":"250Mi"}}}],"generation":2}
99s     Normal   InPlaceResizedByVPA   pod/search-79bbcf7f89-nmxwd   Pod was resized in place by VPA Updater.
99s     Normal   ResizeCompleted       pod/search-79bbcf7f89-nmxwd   Pod resize completed: {"containers":[{"name":"podinfo","resources":{"limits":{"cpu":"70m","memory":"500Mi"},"requests":{"cpu":"35m","memory":"250Mi"}}}],"generation":2}
```

**Why:**
- The requests (10m/32Mi) were **below** the lower bound, so the updater acted—using the in-place resize from Lab
  7.10. `RESTARTS` stays 0: same Pods, no eviction.
- One Pod at a time, about a minute apart (the updater loop), to limit disruption.
- **Limits are scaled proportionally**: 10m/20m became 25m/50m (ratio 1:2), 32Mi/64Mi became 250Mi/500Mi.
- The target kept rising (63m) but the Pods were not resized again: their requests are now within the bounds.
  VPA deliberately avoids constant small changes.

5. The `catalog` Pods keep their 1 CPU (within the bounds). New Pods, however, always get the target from the
   admission controller. Switch `catalog` to `InPlaceOrRecreate` and restart it.

```bash
workstation$ kubectl -n lab-07-11 patch vpa catalog --type=merge -p '{"spec":{"updatePolicy":{"updateMode":"InPlaceOrRecreate"}}}'
workstation$ kubectl -n lab-07-11 rollout restart deploy/catalog
workstation$ kubectl -n lab-07-11 rollout status deploy/catalog
workstation$ kubectl -n lab-07-11 get pod -l app=catalog -o custom-columns='POD:.metadata.name,CPU:.spec.containers[0].resources.requests.cpu,MEM:.spec.containers[0].resources.requests.memory,CPU_LIM:.spec.containers[0].resources.limits.cpu,MEM_LIM:.spec.containers[0].resources.limits.memory'
workstation$ kubectl -n lab-07-11 get pod -l app=catalog -o jsonpath='{.items[0].metadata.annotations.vpaUpdates}{"\n"}'
workstation$ kubectl -n lab-07-11 get deploy catalog -o jsonpath='{.spec.template.spec.containers[0].resources}{"\n"}'
```

Expected:
```
POD                        CPU   MEM     CPU_LIM   MEM_LIM
catalog-5f86c4744c-ks4nd   78m   250Mi   156m      500Mi
catalog-5f86c4744c-tkfnz   78m   250Mi   156m      500Mi
Pod resources updated by catalog: container 0: cpu request, memory request, cpu limit, memory limit
{"limits":{"cpu":"2","memory":"2Gi"},"requests":{"cpu":"1","memory":"1Gi"}}
```

**Why:** the Deployment template still says 1 CPU / 1Gi—VPA changes **Pods**, not the template (GitOps tools see no
drift). The `vpaUpdates` annotation tells you who changed the Pod. Two important rules:
- Do **not** combine VPA and an HPA on the same CPU/memory metric: VPA changes the requests that the HPA's
  utilization is computed against, and they chase each other. (HPA on custom metrics + VPA is fine.)
- VPA recommendations follow observed usage. A memory leak becomes a "recommendation" too—cap it (*Your turn*).

### Clean up

```bash
workstation$ kubectl delete namespace lab-07-11
workstation$ cd ~/lab-07-11/autoscaler/vertical-pod-autoscaler && ./hack/vpa-down.sh
workstation$ kubectl get crd | grep -c autoscaling.k8s.io                  # 0
workstation$ kubectl get mutatingwebhookconfiguration | grep vpa             # nothing
workstation$ cd ~ && rm -rf ~/lab-07-11
```

### Your turn

FinOps and SRE agree on guard rails for `catalog` (do it before the clean up):
- VPA may never set less than **100m / 300Mi** (startup spikes) or more than **500m / 512Mi** (budget),
- VPA may change **requests only**; limits stay as the team defined them (2 CPU / 2Gi).

Configure it, compare `target` with `uncappedTarget`, restart the Deployment and verify the new Pods.

<details><summary>Solution</summary>

```bash
workstation$ kubectl apply -n lab-07-11 -f - <<'EOF'
apiVersion: autoscaling.k8s.io/v1
kind: VerticalPodAutoscaler
metadata:
  name: catalog
spec:
  targetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: catalog
  updatePolicy:
    updateMode: InPlaceOrRecreate
  resourcePolicy:
    containerPolicies:
    - containerName: podinfo
      controlledValues: RequestsOnly
      minAllowed:
        cpu: 100m
        memory: 300Mi
      maxAllowed:
        cpu: 500m
        memory: 512Mi
EOF
workstation$ sleep 70
workstation$ kubectl -n lab-07-11 get vpa catalog -o jsonpath='{.status.recommendation.containerRecommendations[0]}' \
  | jq -c '{target, uncappedTarget}'
workstation$ kubectl -n lab-07-11 rollout restart deploy/catalog
workstation$ kubectl -n lab-07-11 rollout status deploy/catalog
workstation$ kubectl -n lab-07-11 get pod -l app=catalog -o custom-columns='POD:.metadata.name,CPU:.spec.containers[0].resources.requests.cpu,MEM:.spec.containers[0].resources.requests.memory,CPU_LIM:.spec.containers[0].resources.limits.cpu,MEM_LIM:.spec.containers[0].resources.limits.memory'
```

Expected:
```
{"target":{"cpu":"100m","memory":"300Mi"},"uncappedTarget":{"cpu":"78m","memory":"250Mi"}}
POD                        CPU    MEM     CPU_LIM   MEM_LIM
catalog-688b987c9f-grtf6   100m   300Mi   2         2Gi
catalog-688b987c9f-qxqft   100m   300Mi   2         2Gi
```

`uncappedTarget` is what the data says, `target` is what VPA will apply after the policy. With `RequestsOnly` the
limits are untouched—useful when limits encode a deliberate decision (e.g. a JVM heap sized to the memory limit).
</details>

---

## Lab 7.12: Business-hours scaling with a CronJob and RBAC

**Scenario** – The B2B order portal is used from 8:00 to 18:00 (Warsaw time) on weekdays; at night and at weekends
it is idle. Running 4 replicas 24/7 wastes money, and the morning rush starts too fast for the HPA to catch. The
plan: a CronJob scales the portal up at 7:55 and down at 18:00—with a ServiceAccount that may scale **exactly this
one Deployment** and nothing else.

**What you'll learn**
- CronJobs with `timeZone`, `concurrencyPolicy` and history limits
- Least-privilege RBAC for the `deployments/scale` subresource and `resourceNames`
- Testing RBAC with `kubectl auth can-i --as=system:serviceaccount:…`
- Running a CronJob immediately with `kubectl create job --from=cronjob/…`

### Steps

1. Create the namespace, the portal, the ServiceAccount, Role and RoleBinding.

```bash
workstation$ kubectl create namespace lab-07-12
workstation$ kubectl apply -n lab-07-12 -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: shop
spec:
  replicas: 1
  selector:
    matchLabels: {app: shop}
  template:
    metadata:
      labels: {app: shop}
    spec:
      containers:
      - name: podinfo
        image: ghcr.io/stefanprodan/podinfo:6.17.0
        resources:
          requests: {cpu: 50m, memory: 64Mi}
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: scaler
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: scale-shop
rules:
- apiGroups: ["apps"]
  resources: ["deployments"]
  resourceNames: ["shop"]
  verbs: ["get"]
- apiGroups: ["apps"]
  resources: ["deployments/scale"]
  resourceNames: ["shop"]
  verbs: ["get", "patch", "update"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: scaler-scale-shop
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: scale-shop
subjects:
- kind: ServiceAccount
  name: scaler
EOF
```

**Why:** `kubectl scale` reads the Deployment and patches its **`/scale` subresource**. Granting `patch` on
`deployments` would also allow changing the image, the command, the ServiceAccount… `deployments/scale` allows only
the replica count. `resourceNames` narrows it to one object.

2. Verify the permissions before you rely on them.

```bash
workstation$ SA=system:serviceaccount:lab-07-12:scaler
workstation$ for a in "patch deployments/shop --subresource=scale" "patch deployments/catalog --subresource=scale" \
             "delete deployments/shop" "patch deployments/shop --subresource=scale -n default"; do
  printf '%-55s %s\n' "$a" "$(kubectl -n lab-07-12 auth can-i $a --as=$SA)"; done
```

Expected:
```
patch deployments/shop --subresource=scale              yes
patch deployments/catalog --subresource=scale           no
delete deployments/shop                                 no
patch deployments/shop --subresource=scale -n default   no
```

3. Create the two CronJobs. `alpine/k8s` contains `kubectl`; inside a Pod it authenticates with the ServiceAccount
   token automatically and uses the Pod's namespace.

```bash
workstation$ kubectl apply -n lab-07-12 -f - <<'EOF'
apiVersion: batch/v1
kind: CronJob
metadata:
  name: business-hours-start
spec:
  schedule: "55 7 * * 1-5"
  timeZone: Europe/Warsaw
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 2
  failedJobsHistoryLimit: 2
  jobTemplate:
    spec:
      backoffLimit: 2
      template:
        spec:
          serviceAccountName: scaler
          restartPolicy: OnFailure
          containers:
          - name: kubectl
            image: alpine/k8s:1.37.1
            command: ["kubectl", "scale", "deployment/shop", "--replicas=4"]
---
apiVersion: batch/v1
kind: CronJob
metadata:
  name: business-hours-end
spec:
  schedule: "0 18 * * 1-5"
  timeZone: Europe/Warsaw
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 2
  failedJobsHistoryLimit: 2
  jobTemplate:
    spec:
      backoffLimit: 2
      template:
        spec:
          serviceAccountName: scaler
          restartPolicy: OnFailure
          containers:
          - name: kubectl
            image: alpine/k8s:1.37.1
            command: ["kubectl", "scale", "deployment/shop", "--replicas=1"]
EOF
workstation$ kubectl -n lab-07-12 get cronjob
```

Expected:
```
NAME                   SCHEDULE       TIMEZONE        SUSPEND   ACTIVE   LAST SCHEDULE   AGE
business-hours-end     0 18 * * 1-5   Europe/Warsaw   False     0        <none>          0s
business-hours-start   55 7 * * 1-5   Europe/Warsaw   False     0        <none>          0s
```

**Why `timeZone`:** without it, the schedule is interpreted in the kube-controller-manager's time zone (usually
UTC), and daylight-saving changes shift your business hours twice a year.

4. You do not want to wait until tomorrow morning. Run each CronJob once, now:

```bash
workstation$ kubectl -n lab-07-12 create job --from=cronjob/business-hours-start test-start
workstation$ kubectl -n lab-07-12 wait --for=condition=Complete job/test-start
workstation$ kubectl -n lab-07-12 logs job/test-start
workstation$ kubectl -n lab-07-12 get deploy shop
workstation$ kubectl -n lab-07-12 create job --from=cronjob/business-hours-end test-end
workstation$ kubectl -n lab-07-12 wait --for=condition=Complete job/test-end
workstation$ kubectl -n lab-07-12 logs job/test-end
workstation$ kubectl -n lab-07-12 get deploy shop
```

Expected:
```
job.batch/test-start created
job.batch/test-start condition met
deployment.apps/shop scaled
NAME   READY   UP-TO-DATE   AVAILABLE   AGE
shop   4/4     4            4           14s
job.batch/test-end created
job.batch/test-end condition met
deployment.apps/shop scaled
NAME   READY   UP-TO-DATE   AVAILABLE   AGE
shop   1/1     1            1           17s
```

5. Pitfalls to remember:
   - `concurrencyPolicy: Forbid` + `backoffLimit` prevents piles of hanging Jobs if the API server is unreachable.
   - If the CronJob controller is down at 7:55 (e.g. control-plane maintenance), the run is caught up only within
     `startingDeadlineSeconds`; otherwise it is skipped. Consider setting it (e.g. `3600`).
   - Dedicated tools (KEDA's cron scaler, cluster autoscaler schedules) do the same declaratively; the CronJob
     approach needs nothing but built-in objects.

### Clean up

```bash
workstation$ kubectl delete namespace lab-07-12
```

### Your turn

The portal gets an HPA (CPU 60%, 1–10 replicas). Now the CronJobs above are useless: the HPA overwrites
`spec.replicas` with its own calculation on its next sync, so the "morning boost" is undone. Change the design: during
business hours the HPA's **`minReplicas`** must be 4, outside business hours 1. Update the Role (least privilege
again) and both CronJobs, then test both jobs.

<details><summary>Solution</summary>

```bash
workstation$ kubectl -n lab-07-12 delete job test-start test-end
workstation$ kubectl apply -n lab-07-12 -f - <<'EOF'
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: shop
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: shop
  minReplicas: 1
  maxReplicas: 10
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: 60
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: scale-shop
rules:
- apiGroups: ["autoscaling"]
  resources: ["horizontalpodautoscalers"]
  resourceNames: ["shop"]
  verbs: ["get", "patch"]
---
apiVersion: batch/v1
kind: CronJob
metadata:
  name: business-hours-start
spec:
  schedule: "55 7 * * 1-5"
  timeZone: Europe/Warsaw
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 2
  failedJobsHistoryLimit: 2
  jobTemplate:
    spec:
      backoffLimit: 2
      template:
        spec:
          serviceAccountName: scaler
          restartPolicy: OnFailure
          containers:
          - name: kubectl
            image: alpine/k8s:1.37.1
            command: ["kubectl", "patch", "hpa", "shop", "--type=merge", "-p", '{"spec":{"minReplicas":4}}']
---
apiVersion: batch/v1
kind: CronJob
metadata:
  name: business-hours-end
spec:
  schedule: "0 18 * * 1-5"
  timeZone: Europe/Warsaw
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 2
  failedJobsHistoryLimit: 2
  jobTemplate:
    spec:
      backoffLimit: 2
      template:
        spec:
          serviceAccountName: scaler
          restartPolicy: OnFailure
          containers:
          - name: kubectl
            image: alpine/k8s:1.37.1
            command: ["kubectl", "patch", "hpa", "shop", "--type=merge", "-p", '{"spec":{"minReplicas":1}}']
EOF
workstation$ kubectl -n lab-07-12 create job --from=cronjob/business-hours-start test-start
workstation$ kubectl -n lab-07-12 wait --for=condition=Complete job/test-start
workstation$ kubectl -n lab-07-12 logs job/test-start
workstation$ sleep 25; kubectl -n lab-07-12 get hpa shop
workstation$ kubectl -n lab-07-12 create job --from=cronjob/business-hours-end test-end
workstation$ kubectl -n lab-07-12 wait --for=condition=Complete job/test-end
workstation$ kubectl -n lab-07-12 logs job/test-end
workstation$ kubectl -n lab-07-12 get hpa shop
```

Expected:
```
horizontalpodautoscaler.autoscaling/shop patched
NAME   REFERENCE         TARGETS       MINPODS   MAXPODS   REPLICAS   AGE
shop   Deployment/shop   cpu: 0%/60%   4         10        4          29s
horizontalpodautoscaler.autoscaling/shop patched
NAME   REFERENCE         TARGETS       MINPODS   MAXPODS   REPLICAS   AGE
shop   Deployment/shop   cpu: 8%/60%   1         10        4          34s
```

After the evening job the HPA keeps 4 replicas for its 5-minute scale-down window and then goes down to what the
load requires. During business hours the HPA can still scale *above* 4 when needed—schedule and load work together
instead of against each other. The scale permissions on the Deployment are no longer needed and were removed from
the Role.
</details>

---

# Part C – Node selection and scheduling

## Lab 7.13: Pinning workloads to zones – node labels, nodeSelector and required affinity

**Scenario** – ACME's two workers sit in two server rooms ("zones"). The payments service must run in `zone-a`, where
the PCI-audited network lives; batch reports must stay *out* of `zone-a`; ML training needs a GPU node, which the
cluster does not have yet. You will simulate the zones with node labels and express these rules with `nodeSelector`
and required node affinity—and see what the scheduler says when a rule cannot be met.

**⚠ cluster-wide:** this lab labels nodes. Always run *Clean up*.

**What you'll learn**
- Labelling nodes with the well-known `topology.kubernetes.io/zone` key
- `nodeSelector` (exact match) vs `nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution`
- Operators `In`, `NotIn`, `Exists`; reading `FailedScheduling` messages
- "IgnoredDuringExecution": what happens when a label disappears from a node

### Steps

1. Create the namespace and simulate two zones. (Cloud providers set this label automatically.)

```bash
workstation$ kubectl create namespace lab-07-13
workstation$ kubectl label node node1 topology.kubernetes.io/zone=zone-a
workstation$ kubectl label node node2 topology.kubernetes.io/zone=zone-b
workstation$ kubectl get nodes -L topology.kubernetes.io/zone
```

Expected:
```
NAME     STATUS   ROLES           AGE   VERSION   ZONE
master   Ready    control-plane   15d   v1.37.1
node1    Ready    <none>          15d   v1.37.1   zone-a
node2    Ready    <none>          15d   v1.37.1   zone-b
```

2. Pin payments to `zone-a` with a `nodeSelector`.

```bash
workstation$ kubectl apply -n lab-07-13 -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: payments
spec:
  replicas: 4
  selector:
    matchLabels: {app: payments}
  template:
    metadata:
      labels: {app: payments}
    spec:
      nodeSelector:
        topology.kubernetes.io/zone: zone-a
      containers:
      - name: podinfo
        image: ghcr.io/stefanprodan/podinfo:6.17.0
        resources:
          requests: {cpu: 20m, memory: 32Mi}
EOF
workstation$ kubectl -n lab-07-13 rollout status deploy/payments
workstation$ kubectl -n lab-07-13 get pod -l app=payments -o custom-columns=POD:.metadata.name,STATUS:.status.phase,NODE:.spec.nodeName
```

Expected—all four on node1:
```
POD                        STATUS    NODE
payments-8757d9d4f-bbhvs   Running   node1
payments-8757d9d4f-cnbcn   Running   node1
payments-8757d9d4f-sd2qd   Running   node1
payments-8757d9d4f-xnqvb   Running   node1
```

3. A typo (`zone-c`) in another team's manifest:

```bash
workstation$ kubectl apply -n lab-07-13 -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: reports
spec:
  replicas: 2
  selector:
    matchLabels: {app: reports}
  template:
    metadata:
      labels: {app: reports}
    spec:
      nodeSelector:
        topology.kubernetes.io/zone: zone-c
      containers:
      - name: podinfo
        image: ghcr.io/stefanprodan/podinfo:6.17.0
        resources:
          requests: {cpu: 20m, memory: 32Mi}
EOF
workstation$ kubectl -n lab-07-13 get pod -l app=reports
workstation$ kubectl -n lab-07-13 get events --field-selector reason=FailedScheduling | tail -1
```

Expected:
```
NAME                      READY   STATUS    RESTARTS   AGE
reports-d55cfdc7f-fwp8z   0/1     Pending   0          5s
reports-d55cfdc7f-l4hcb   0/1     Pending   0          5s
6s   Warning   FailedScheduling   pod/reports-d55cfdc7f-l4hcb   0/3 nodes are available: 1 node(s) had untolerated taint(s), 2 node(s) didn't match Pod's node affinity/selector. preemption: 0/3 nodes are available: 3 Preemption is not helpful for scheduling.
```

**Why:** the message accounts for every node: the master is excluded by its taint (Lab 7.15), the workers by the
selector. Nothing is wrong with the cluster—the Pod asks for something that does not exist. Pending Pods never
"fix themselves" unless a matching node appears.

4. Reports must avoid `zone-a` but run in *some* zone. `nodeSelector` cannot express "not"; node affinity can.
   Expressions inside one term are **ANDed**.

```bash
workstation$ kubectl apply -n lab-07-13 -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: reports
spec:
  replicas: 2
  selector:
    matchLabels: {app: reports}
  template:
    metadata:
      labels: {app: reports}
    spec:
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
            - matchExpressions:
              - key: topology.kubernetes.io/zone
                operator: NotIn
                values: [zone-a]
              - key: topology.kubernetes.io/zone     # NotIn alone also matches nodes WITHOUT the label
                operator: Exists
      containers:
      - name: podinfo
        image: ghcr.io/stefanprodan/podinfo:6.17.0
        resources:
          requests: {cpu: 20m, memory: 32Mi}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ml-training
spec:
  replicas: 1
  selector:
    matchLabels: {app: ml-training}
  template:
    metadata:
      labels: {app: ml-training}
    spec:
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
            - matchExpressions:
              - key: accelerator
                operator: Exists
      containers:
      - name: podinfo
        image: ghcr.io/stefanprodan/podinfo:6.17.0
        resources:
          requests: {cpu: 20m, memory: 32Mi}
EOF
workstation$ kubectl -n lab-07-13 rollout status deploy/reports
workstation$ kubectl -n lab-07-13 get pod -l 'app in (reports,ml-training)' -o custom-columns=POD:.metadata.name,STATUS:.status.phase,NODE:.spec.nodeName
```

Expected:
```
POD                            STATUS    NODE
ml-training-79789f79bc-s6rv6   Pending   <none>
reports-7457bc7759-kd5c9       Running   node2
reports-7457bc7759-l6x2v       Running   node2
```

**Why the `Exists`:** `NotIn [zone-a]` is also true for nodes that have *no* zone label at all—a new, unlabelled
node (or the master, if it had no taint) would qualify. Combining `NotIn` with `Exists` means "has a zone, and it is
not zone-a".

5. A GPU node "arrives" (we label node2), the ML Pod is scheduled. Then the label is removed again.

```bash
workstation$ kubectl label node node2 accelerator=nvidia-l4
workstation$ kubectl -n lab-07-13 rollout status deploy/ml-training
workstation$ kubectl -n lab-07-13 get pod -l app=ml-training -o custom-columns=POD:.metadata.name,STATUS:.status.phase,NODE:.spec.nodeName
workstation$ kubectl label node node2 accelerator-
workstation$ sleep 5; kubectl -n lab-07-13 get pod -l app=ml-training -o custom-columns=POD:.metadata.name,STATUS:.status.phase,NODE:.spec.nodeName
```

Expected:
```
POD                            STATUS    NODE
ml-training-79789f79bc-s6rv6   Running   node2
POD                            STATUS    NODE
ml-training-79789f79bc-s6rv6   Running   node2
```

**Why:** *IgnoredDuringExecution*—affinity is checked only at scheduling time. Removing a label does not evict
running Pods; they keep running on a node that no longer matches until they are recreated. To force Pods off a
node, use a `NoExecute` taint (Lab 7.16) or a drain (Lab 7.19).

### Clean up

```bash
workstation$ kubectl delete namespace lab-07-13
workstation$ kubectl label node node1 node2 topology.kubernetes.io/zone-
workstation$ kubectl label node node2 pci-certified- 2>/dev/null    # from Your turn
workstation$ kubectl get nodes -L topology.kubernetes.io/zone,pci-certified
```

### Your turn

The auditors certified node2 for PCI as well. New rule for payments: run in **zone-a OR on any node labelled
`pci-certified=true`**. Label node2, rewrite the payments Deployment with node affinity (6 replicas) and show where the
Pods land. Then answer: what happens if somebody re-adds the old `nodeSelector: {topology.kubernetes.io/zone: zone-a}`
next to the new affinity? Try it.

<details><summary>Solution</summary>

Separate `nodeSelectorTerms` are **ORed**. (Expressions inside a term are ANDed.)

```bash
workstation$ kubectl label node node2 pci-certified=true
workstation$ kubectl apply -n lab-07-13 -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: payments
spec:
  replicas: 6
  selector:
    matchLabels: {app: payments}
  template:
    metadata:
      labels: {app: payments}
    spec:
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
            - matchExpressions:                       # term 1: zone-a
              - key: topology.kubernetes.io/zone
                operator: In
                values: [zone-a]
            - matchExpressions:                       # OR term 2: PCI-certified node
              - key: pci-certified
                operator: In
                values: ["true"]
      containers:
      - name: podinfo
        image: ghcr.io/stefanprodan/podinfo:6.17.0
        resources:
          requests: {cpu: 20m, memory: 32Mi}
EOF
workstation$ kubectl -n lab-07-13 rollout status deploy/payments
workstation$ sleep 20; kubectl -n lab-07-13 get pod -l app=payments -o wide --no-headers | awk '{print $7}' | sort | uniq -c
```

Expected (`kubectl apply` removed the old `nodeSelector`, because it is no longer in the applied manifest):
```
      3 node1
      3 node2
```

Now add the old `nodeSelector` back:
```bash
workstation$ kubectl -n lab-07-13 patch deploy payments \
  -p '{"spec":{"template":{"spec":{"nodeSelector":{"topology.kubernetes.io/zone":"zone-a"}}}}}'
workstation$ kubectl -n lab-07-13 rollout status deploy/payments
workstation$ sleep 20; kubectl -n lab-07-13 get pod -l app=payments -o wide --no-headers | awk '{print $7}' | sort | uniq -c
```

Expected:
```
      6 node1
```

`nodeSelector` and `nodeAffinity` are **ANDed**: a node must satisfy both. The selector silently undoes the new
rule—check for leftovers when migrating from `nodeSelector` to affinity.
</details>

---

## Lab 7.14: Prefer, don't require – weighted node affinity with fallback

**Scenario** – The catalog service answers faster on the SSD node, so it *should* run there—but a catalog outage
because "the SSD node is full" would be far worse than slightly slower answers. You will express placement wishes
with weighted **preferred** affinity, watch the scheduler fall back to other nodes when the preferred one is full,
and compare it with a **required** rule that leaves Pods `Pending`.

**⚠ cluster-wide:** this lab labels nodes. Always run *Clean up*.

**What you'll learn**
- `preferredDuringSchedulingIgnoredDuringExecution` with `weight` (1–100)
- How several preferences add up in the node score
- Fallback behaviour when the preferred node lacks resources
- Required vs preferred: availability vs placement guarantees

### Steps

1. Create the namespace and label the nodes: node1 = zone-a + SSD, node2 = zone-b + HDD.

```bash
workstation$ kubectl create namespace lab-07-14
workstation$ kubectl label node node1 topology.kubernetes.io/zone=zone-a disktype=ssd
workstation$ kubectl label node node2 topology.kubernetes.io/zone=zone-b disktype=hdd
workstation$ kubectl get nodes -L topology.kubernetes.io/zone,disktype
```

Expected:
```
NAME     STATUS   ROLES           AGE   VERSION   ZONE     DISKTYPE
master   Ready    control-plane   15d   v1.37.1
node1    Ready    <none>          15d   v1.37.1   zone-a   ssd
node2    Ready    <none>          15d   v1.37.1   zone-b   hdd
```

2. Deploy the catalog with two preferences: SSD (weight 80) and zone-b (weight 20—the cheaper server room).

```bash
workstation$ kubectl apply -n lab-07-14 -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: catalog
spec:
  replicas: 6
  selector:
    matchLabels: {app: catalog}
  template:
    metadata:
      labels: {app: catalog}
    spec:
      affinity:
        nodeAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
          - weight: 80
            preference:
              matchExpressions:
              - key: disktype
                operator: In
                values: [ssd]
          - weight: 20
            preference:
              matchExpressions:
              - key: topology.kubernetes.io/zone
                operator: In
                values: [zone-b]
      containers:
      - name: podinfo
        image: ghcr.io/stefanprodan/podinfo:6.17.0
        resources:
          requests: {cpu: 20m, memory: 32Mi}
EOF
workstation$ kubectl -n lab-07-14 rollout status deploy/catalog
workstation$ kubectl -n lab-07-14 get pod -l app=catalog -o wide --no-headers | awk '{print $7}' | sort | uniq -c
```

Expected:
```
      6 node1
```

**Why:** for each node the scheduler sums the weights of the matching preferences: node1 = 80, node2 = 20. That
sum is one input of the node score (next to resource balance, spreading, image locality…). 80 vs 20 is a clear
win, so all Pods go to node1.

3. Black Friday: each catalog Pod now needs 1.5 CPU, and we want 4 of them. A worker has 4 CPUs.

```bash
workstation$ kubectl -n lab-07-14 set resources deploy/catalog --requests=cpu=1500m,memory=64Mi
workstation$ kubectl -n lab-07-14 scale deploy/catalog --replicas=4
workstation$ kubectl -n lab-07-14 rollout status deploy/catalog
workstation$ kubectl -n lab-07-14 get pod -l app=catalog -o wide --no-headers | awk '{print $3, $7}' | sort | uniq -c
```

Expected:
```
      2 Running node1
      2 Running node2
```

**Why:** node1 fits only two 1.5-CPU Pods. Preferences are evaluated only among nodes that pass the *filters*
(resources, taints, required affinity). node2 is less preferred but feasible, so the remaining Pods land there—the
service has full capacity.

4. Compare with the strict version (required SSD).

```bash
workstation$ kubectl -n lab-07-14 delete deploy catalog
workstation$ kubectl apply -n lab-07-14 -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: catalog-strict
spec:
  replicas: 4
  selector:
    matchLabels: {app: catalog-strict}
  template:
    metadata:
      labels: {app: catalog-strict}
    spec:
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
            - matchExpressions:
              - key: disktype
                operator: In
                values: [ssd]
      containers:
      - name: podinfo
        image: ghcr.io/stefanprodan/podinfo:6.17.0
        resources:
          requests: {cpu: 1500m, memory: 64Mi}
EOF
workstation$ sleep 15
workstation$ kubectl -n lab-07-14 get pod -l app=catalog-strict -o wide --no-headers | awk '{print $3, $7}' | sort | uniq -c
workstation$ kubectl -n lab-07-14 get events --field-selector reason=FailedScheduling | tail -1
```

Expected:
```
      2 Pending <none>
      2 Running node1
15s   Warning   FailedScheduling   pod/catalog-strict-6db7db666f-q49sg   0/3 nodes are available: 1 Insufficient cpu, 1 node(s) didn't match Pod's node affinity/selector, 1 node(s) had untolerated taint(s). preemption: 0/3 nodes are available: 1 No preemption victims found for incoming pod, 2 Preemption is not helpful for scheduling.
```

**Why:** half of the capacity is missing although node2 has 3.7 idle CPUs. Use *required* only for hard
constraints (licences, hardware, compliance); use *preferred* for performance and cost wishes.

### Clean up

```bash
workstation$ kubectl delete namespace lab-07-14
workstation$ kubectl label node node1 node2 disktype- topology.kubernetes.io/zone-
workstation$ kubectl get nodes -L topology.kubernetes.io/zone,disktype
```

### Your turn

The SSD node will be decommissioned next quarter, and finance wants to use the cheap zone-b room as much as possible.
Change the catalog (back to 6 replicas, 20m CPU) so that **zone-b is the strong preference** and SSD only a
tie-breaker. Predict the placement before you apply. Why is a preferred placement still not a *guarantee*, even with
weight 100?

<details><summary>Solution</summary>

Swap the weights: zone-b 80, SSD 20 → node1 scores 20, node2 scores 80.

```bash
workstation$ kubectl -n lab-07-14 delete deploy catalog-strict
workstation$ kubectl apply -n lab-07-14 -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: catalog
spec:
  replicas: 6
  selector:
    matchLabels: {app: catalog}
  template:
    metadata:
      labels: {app: catalog}
    spec:
      affinity:
        nodeAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
          - weight: 20
            preference:
              matchExpressions:
              - key: disktype
                operator: In
                values: [ssd]
          - weight: 80
            preference:
              matchExpressions:
              - key: topology.kubernetes.io/zone
                operator: In
                values: [zone-b]
      containers:
      - name: podinfo
        image: ghcr.io/stefanprodan/podinfo:6.17.0
        resources:
          requests: {cpu: 20m, memory: 32Mi}
EOF
workstation$ kubectl -n lab-07-14 rollout status deploy/catalog
workstation$ kubectl -n lab-07-14 get pod -l app=catalog -o wide --no-headers | awk '{print $7}' | sort | uniq -c
```

Expected:
```
      6 node2
```

Not a guarantee because: (1) the affinity score is only one of several scoring plugins—with very unequal node load,
`NodeResourcesBalancedAllocation` or default topology spreading can outweigh it; (2) a full or tainted node is
filtered out before scoring; (3) it is evaluated only at scheduling time—Pods do not move back when the preferred node
gets free capacity (that is what the *descheduler* project is for).
</details>

---

## Lab 7.15: A dedicated node for the data team – taints and tolerations

**Scenario** – The data team bought node2's capacity for nightly ETL jobs and does not want other teams' Pods there
(noisy neighbours). At the same time, the control-plane node must stay free of application Pods—except for a few
system agents. You will keep Pods *away* from nodes with taints, let selected Pods in with tolerations, and learn
why a toleration alone does not put a Pod on the dedicated node.

**⚠ cluster-wide:** this lab taints and labels node2. While the taint is active, *no new Pods of other workloads* can
start on node2. Run it when nobody else uses the cluster, and always run *Clean up*.

**What you'll learn**
- Taints (`key=value:Effect`) on nodes vs. tolerations on Pods
- Why a toleration *allows* but does not *attract*—and the taint + label + affinity pattern
- `NoSchedule` does not evict Pods that are already running
- The control-plane taint and how system agents tolerate it

### Steps

1. Create the namespace and look at the taint that already exists in every kubeadm cluster.

```bash
workstation$ kubectl create namespace lab-07-15
workstation$ kubectl get nodes -o custom-columns=NODE:.metadata.name,TAINTS:.spec.taints
```

Expected:
```
NODE     TAINTS
master   [map[effect:NoSchedule key:node-role.kubernetes.io/control-plane]]
node1    <none>
node2    <none>
```

2. Dedicate node2: a **taint** repels everyone without a toleration, a **label** lets the data team target it.

```bash
workstation$ kubectl taint node node2 dedicated=data-team:NoSchedule
workstation$ kubectl label node node2 dedicated=data-team
workstation$ kubectl describe node node2 | grep Taints
```

Expected:
```
Taints:             dedicated=data-team:NoSchedule
```

3. Another team deploys the shop (no toleration).

```bash
workstation$ kubectl apply -n lab-07-15 -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: shop
spec:
  replicas: 4
  selector:
    matchLabels: {app: shop}
  template:
    metadata:
      labels: {app: shop}
    spec:
      containers:
      - name: podinfo
        image: ghcr.io/stefanprodan/podinfo:6.17.0
        resources:
          requests: {cpu: 20m, memory: 32Mi}
EOF
workstation$ kubectl -n lab-07-15 rollout status deploy/shop
workstation$ kubectl -n lab-07-15 get pod -l app=shop -o wide --no-headers | awk '{print $7}' | sort | uniq -c
```

Expected:
```
      4 node1
```

**Why:** node2 is filtered out by its taint, the master by its own. Pods that were already running on node2
before the taint was added stay there—`NoSchedule` only affects *new* scheduling decisions.

4. The data team's first attempt: an ETL Deployment with a **toleration** only.

```bash
workstation$ kubectl apply -n lab-07-15 -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: etl
spec:
  replicas: 4
  selector:
    matchLabels: {app: etl}
  template:
    metadata:
      labels: {app: etl}
    spec:
      tolerations:
      - key: dedicated
        operator: Equal
        value: data-team
        effect: NoSchedule
      containers:
      - name: podinfo
        image: ghcr.io/stefanprodan/podinfo:6.17.0
        resources:
          requests: {cpu: 20m, memory: 32Mi}
EOF
workstation$ kubectl -n lab-07-15 rollout status deploy/etl
workstation$ kubectl -n lab-07-15 get pod -l app=etl -o wide --no-headers | awk '{print $7}' | sort | uniq -c
```

Expected (the exact split may vary):
```
      2 node1
      2 node2
```

**Why:** a toleration only says "I *may* run on a node with this taint". The scheduler still considers all other
nodes, and its spreading score happily puts ETL Pods on node1—the data team's Pods now compete with the shop.

5. Add required node affinity to the label. Taint (keeps others out) + label/affinity (pulls the team in) is the
   standard pattern for dedicated nodes.

```bash
workstation$ kubectl -n lab-07-15 patch deploy etl --type=merge -p '{"spec":{"template":{"spec":{"affinity":{"nodeAffinity":{"requiredDuringSchedulingIgnoredDuringExecution":{"nodeSelectorTerms":[{"matchExpressions":[{"key":"dedicated","operator":"In","values":["data-team"]}]}]}}}}}}}'
workstation$ kubectl -n lab-07-15 rollout status deploy/etl
workstation$ kubectl -n lab-07-15 wait --for=delete pod -l app=etl --field-selector=spec.nodeName=node1 --timeout=90s
workstation$ kubectl -n lab-07-15 get pod -l app=etl -o wide --no-headers | awk '{print $7}' | sort | uniq -c
```

Expected:
```
pod/etl-7c4895984-2w6gc condition met
pod/etl-7c4895984-fz48v condition met
      4 node2
```

**Why the `wait`?** `rollout status` returns as soon as the new Pods are available, while the old Pods may still be
*Terminating* (podinfo drains for a few seconds). Without the wait you'd count them too and see `2 node1 / 6 node2`.

6. The control plane: a Pod pinned to the master is rejected unless it tolerates the control-plane taint.

```bash
workstation$ kubectl apply -n lab-07-15 -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: cp-agent
spec:
  nodeSelector:
    kubernetes.io/hostname: master
  tolerations:
  - key: node-role.kubernetes.io/control-plane
    operator: Exists
    effect: NoSchedule
  containers:
  - name: agent
    image: busybox:1.38
    command: ["sh", "-c", "echo collecting metrics on $(hostname); sleep 3600"]
    resources:
      requests: {cpu: 10m, memory: 16Mi}
EOF
workstation$ kubectl -n lab-07-15 get pod cp-agent -o wide
```

Expected: `cp-agent` is `Running` on `master`, and `kubectl -n lab-07-15 logs cp-agent` prints
`collecting metrics on cp-agent`. Remove the `tolerations` block and re-create the Pod to see it stay
`Pending` with `1 node(s) had untolerated taint(s)`.

**Why:** `operator: Exists` matches the taint key with any value—that is how kube-proxy, Calico and other system
DaemonSets run on the master. Be careful with a bare `- operator: Exists` (no key): it tolerates **every** taint.

### Clean up

```bash
workstation$ kubectl delete namespace lab-07-15
workstation$ kubectl taint node node2 dedicated=data-team:NoSchedule-
workstation$ kubectl label node node2 dedicated-
workstation$ kubectl get nodes -o custom-columns=NODE:.metadata.name,TAINTS:.spec.taints     # only master tainted
```

### Your turn

*(Do this before the Clean up, while node2 is still tainted.)* The security team rolls out a log collector that must run
on **every** node: node1, the data team's node2 and the master. Write a DaemonSet `log-agent` (busybox, `sleep 3600`) that achieves this, and verify that it has exactly one
Pod per node. Which tolerations does the DaemonSet controller add automatically, and why are they not enough here?

<details><summary>Solution</summary>

```bash
workstation$ kubectl apply -n lab-07-15 -f - <<'EOF'
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: log-agent
spec:
  selector:
    matchLabels: {app: log-agent}
  template:
    metadata:
      labels: {app: log-agent}
    spec:
      tolerations:
      - key: node-role.kubernetes.io/control-plane
        operator: Exists
        effect: NoSchedule
      - key: dedicated
        operator: Exists
        effect: NoSchedule
      containers:
      - name: agent
        image: busybox:1.38
        command: ["sh", "-c", "sleep 3600"]
        resources:
          requests: {cpu: 10m, memory: 16Mi}
EOF
workstation$ kubectl -n lab-07-15 rollout status ds/log-agent
workstation$ kubectl -n lab-07-15 get pod -l app=log-agent -o wide --no-headers | awk '{print $7}' | sort
workstation$ kubectl -n lab-07-15 get pod -l app=log-agent -o jsonpath='{.items[0].spec.tolerations}' | jq -r '.[].key'
```

Expected:
```
master
node1
node2
node-role.kubernetes.io/control-plane
dedicated
node.kubernetes.io/not-ready
node.kubernetes.io/unreachable
node.kubernetes.io/disk-pressure
node.kubernetes.io/memory-pressure
node.kubernetes.io/pid-pressure
node.kubernetes.io/unschedulable
```

The DaemonSet controller adds tolerations for the *node condition* taints (not-ready, unreachable, pressure,
unschedulable), so agents keep running on sick or cordoned nodes. It cannot guess your custom taints or the
control-plane taint—you must add those yourself.
</details>

---

## Lab 7.16: When a node dies – NoExecute taints and tolerationSeconds

**Scenario** – Last month node2 lost power and the checkout service was degraded for five minutes, although node1
had plenty of free capacity. Why did Kubernetes wait so long before starting replacement Pods? You will simulate the
outage by stopping the kubelet on node2, watch the node lifecycle controller taint the node, and tune how long Pods
wait with `tolerationSeconds`.

**⚠ cluster-wide:** this lab stops the kubelet on node2 for a few minutes. Every workload on node2 is affected
(including other labs and the NGINX Gateway Fabric controller). Keep the outage under 4 minutes, and always run
*Clean up*.

**What you'll learn**
- The automatic `NoExecute` tolerations every Pod gets (`not-ready`, `unreachable`, 300 s)
- What happens, and when, after a node stops reporting
- Faster failover with a shorter `tolerationSeconds`
- Why the Pods on the "dead" node are still running

### Steps

1. Create the namespace and two versions of checkout. Both *prefer* node2 (so they start there), but may run
   anywhere. `checkout-fast` tolerates an unreachable/not-ready node for only 30 s.

```bash
workstation$ kubectl create namespace lab-07-16
workstation$ for v in checkout:300 checkout-fast:30; do name=${v%%:*} secs=${v##*:}
kubectl apply -n lab-07-16 -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: $name
spec:
  replicas: 2
  selector:
    matchLabels: {app: $name}
  template:
    metadata:
      labels: {app: $name}
    spec:
      affinity:
        nodeAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
          - weight: 100
            preference:
              matchExpressions:
              - {key: kubernetes.io/hostname, operator: In, values: [node2]}
      tolerations:
      - {key: node.kubernetes.io/unreachable, operator: Exists, effect: NoExecute, tolerationSeconds: $secs}
      - {key: node.kubernetes.io/not-ready, operator: Exists, effect: NoExecute, tolerationSeconds: $secs}
      containers:
      - name: podinfo
        image: ghcr.io/stefanprodan/podinfo:6.17.0
        resources:
          requests: {cpu: 20m, memory: 32Mi}
EOF
done
workstation$ kubectl -n lab-07-16 wait --for=condition=Available deploy --all
workstation$ kubectl -n lab-07-16 get pod -o wide --no-headers | awk '{print $1, $7}'
```

Expected:
```
checkout-799b967747-vmv6c node2
checkout-799b967747-wtdfb node2
checkout-fast-6989796b96-qbcgj node2
checkout-fast-6989796b96-vbpbs node2
```

2. For `checkout` we wrote the same values Kubernetes adds by default. Check a Pod that has no tolerations at all:

```bash
workstation$ kubectl -n lab-07-16 run plain --image=ghcr.io/stefanprodan/podinfo:6.17.0
workstation$ kubectl -n lab-07-16 get pod plain -o jsonpath='{.spec.tolerations}' | jq -c '.[]'
```

Expected:
```
{"effect":"NoExecute","key":"node.kubernetes.io/not-ready","operator":"Exists","tolerationSeconds":300}
{"effect":"NoExecute","key":"node.kubernetes.io/unreachable","operator":"Exists","tolerationSeconds":300}
```

**Why:** the `DefaultTolerationSeconds` admission plugin adds them. They mean: "if my node becomes unreachable,
keep me bound to it for 5 minutes"—to survive short network blips without mass rescheduling. That is the
five-minute outage from the scenario.

3. Open a watch in a second terminal:

```bash
workstation$ kubectl -n lab-07-16 get pod -o wide -w
```

4. "Pull the plug": stop the kubelet on node2 and note the time.

```bash
node2$ date +%T; sudo systemctl stop kubelet
```

5. Watch the node and its taints. After the node-monitor grace period (about 50 s) the node becomes `NotReady`/
   `Unknown` and the node lifecycle controller taints it:

```bash
workstation$ kubectl get node node2
workstation$ kubectl get node node2 -o jsonpath='{.spec.taints}' | jq -c '.[]'
```

Expected (kubelet stopped at 04:52:53, taints added 47 s later):
```
NAME    STATUS     ROLES    AGE   VERSION
node2   NotReady   <none>   15d   v1.37.1
{"effect":"NoSchedule","key":"node.kubernetes.io/unreachable","timeAdded":"2026-11-04T04:53:40Z"}
{"effect":"NoExecute","key":"node.kubernetes.io/unreachable","timeAdded":"2026-11-04T04:53:40Z"}
```

6. About 30 s after the `NoExecute` taint appeared, the `checkout-fast` Pods on node2 are marked for deletion
   (`Terminating`) and replacements start on node1. The `checkout` Pods stay "Running" on node2 for 5 minutes.

```bash
workstation$ kubectl -n lab-07-16 get pod -o wide --no-headers | awk '{print $1, $2, $3, $7}'
workstation$ kubectl -n lab-07-16 get pod -l app=checkout -o jsonpath='{range .items[*]}{.metadata.name} Ready={.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}'
```

Expected (~90 s after stopping the kubelet):
```
checkout-799b967747-82q2r 1/1 Running node2
checkout-799b967747-rnd5w 1/1 Running node2
checkout-fast-6989796b96-7b77c 1/1 Terminating node2
checkout-fast-6989796b96-7dwbp 1/1 Terminating node2
checkout-fast-6989796b96-p62vf 1/1 Running node1
checkout-fast-6989796b96-w7tsv 1/1 Running node1
plain 1/1 Running node1
checkout-799b967747-82q2r Ready=False
checkout-799b967747-rnd5w Ready=False
```
(`plain` behaves like `checkout` if it was scheduled on node2.)

**Why:**
- The replacement is created as soon as the old Pod gets a deletion timestamp; the old Pod stays `Terminating`
  because no kubelet can confirm that it stopped.
- The containers on node2 are actually **still running**—CRI-O does not depend on the kubelet. The control plane
  just cannot know. That is why Kubernetes waits: a real outage and a network partition look the same.
- `checkout` still shows `Running` and even `READY 1/1`: those columns come from container statuses that only the (dead)
  kubelet could update. The node lifecycle controller, however, sets the Pod's **`Ready` condition to `False`**, so the
  EndpointSlice controller stops sending it Service traffic as soon as the node is `NotReady`.

7. Restore the node before the 5 minutes are over.

```bash
node2$ sudo systemctl start kubelet
workstation$ kubectl wait --for=condition=Ready node/node2 --timeout=120s
workstation$ kubectl get node node2 -o jsonpath='{.spec.taints}{"\n"}'
workstation$ kubectl -n lab-07-16 get pod -o wide --no-headers | awk '{print $1, $3, $7}'
```

Expected:
```
node/node2 condition met
checkout-799b967747-82q2r Running node2
checkout-799b967747-rnd5w Running node2
checkout-fast-6989796b96-p62vf Running node1
checkout-fast-6989796b96-w7tsv Running node1
plain Running node1
```
The `Terminating` Pods disappear, `checkout` is still on node2 and `checkout-fast` now runs on node1 (Pods never move
back by themselves). The `unreachable:NoExecute` taint can linger for a few seconds after the node is `Ready`. Run the
taints command again until it prints an empty line.

**Trade-off:** a short `tolerationSeconds` gives fast failover for stateless services, but causes needless churn on
every network hiccup. Keep the default for stateful workloads (a StatefulSet Pod is **not** replaced while the old
one might still be running—it waits until the node returns or someone deletes the Pod/node).

### Clean up

```bash
node2$ sudo systemctl is-active kubelet       # must be "active"
workstation$ kubectl delete namespace lab-07-16
workstation$ kubectl get node node2 -o jsonpath='{.spec.taints}{"\n"}'    # empty
```

### Your turn

Planned maintenance of node2's network card: you want all application Pods off node2 **immediately**, except a
`net-monitor` Pod that must keep running there for the whole maintenance (it records the outage). Use a custom
`NoExecute` taint `maintenance=nic:NoExecute`. Create `net-monitor` (pinned to node2) so that it survives, apply the
taint, and verify. Remove the taint afterwards.

<details><summary>Solution</summary>

A `NoExecute` taint evicts running Pods that do not tolerate it, immediately. A toleration **without**
`tolerationSeconds` tolerates it forever.

```bash
workstation$ kubectl apply -n lab-07-16 -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: net-monitor
spec:
  nodeSelector:
    kubernetes.io/hostname: node2
  tolerations:
  - key: maintenance
    operator: Equal
    value: nic
    effect: NoExecute
  containers:
  - name: monitor
    image: busybox:1.38
    command: ["sh", "-c", "while true; do date; sleep 10; done"]
EOF
workstation$ kubectl -n lab-07-16 wait --for=condition=Ready pod/net-monitor
workstation$ kubectl taint node node2 maintenance=nic:NoExecute
workstation$ sleep 20; kubectl -n lab-07-16 get pod -o wide --no-headers | awk '{print $1, $3, $7}'
```

Expected:
```
checkout-799b967747-q29g4 Running node1
checkout-799b967747-xwnkq Running node1
checkout-fast-6989796b96-p62vf Running node1
checkout-fast-6989796b96-w7tsv Running node1
net-monitor Running node2
plain Running node1
```
`net-monitor` still runs on node2, and the `checkout` Pods were evicted and replaced on node1. Other namespaces were hit too:
`kubectl get pods -A -o wide --field-selector spec.nodeName=node2` now shows only calico-node, kube-proxy, csi-s3 (which
tolerate everything) and `net-monitor`. The NGF controller, the csi-s3 provisioner and the MetalLB speaker were evicted. A
`NoExecute` taint is a cluster-wide hammer. After removing the taint, check that they are back:
`kubectl -n metallb-system rollout status ds/speaker`.

```bash
workstation$ kubectl taint node node2 maintenance=nic:NoExecute-
workstation$ kubectl delete namespace lab-07-16
```
</details>

---

## Lab 7.17: Surviving a node failure – pod anti-affinity and co-locating a cache

**Scenario** – An incident review found that all three replicas of the web frontend were running on the same node—
when it rebooted, the site was down although "we had three replicas". At the same time, the checkout service makes
dozens of calls per request to its session cache and suffers from cross-node latency. You will spread replicas with
pod **anti**-affinity and pull checkout next to the cache with pod affinity.

**What you'll learn**
- `podAntiAffinity` with `topologyKey: kubernetes.io/hostname`
- Required anti-affinity: one replica per node, and `Pending` when you run out of nodes
- Preferred anti-affinity as the flexible alternative
- `podAffinity` for co-location, and the rolling-update deadlock (*Your turn*)

### Steps

1. Create the namespace and the frontend with **required** anti-affinity: no two `app=web` Pods on the same host.

```bash
workstation$ kubectl create namespace lab-07-17
workstation$ kubectl apply -n lab-07-17 -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
spec:
  replicas: 3
  selector:
    matchLabels: {app: web}
  template:
    metadata:
      labels: {app: web}
    spec:
      affinity:
        podAntiAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
          - labelSelector:
              matchLabels: {app: web}
            topologyKey: kubernetes.io/hostname
      containers:
      - name: podinfo
        image: ghcr.io/stefanprodan/podinfo:6.17.0
        resources:
          requests: {cpu: 20m, memory: 32Mi}
EOF
workstation$ sleep 20
workstation$ kubectl -n lab-07-17 get pod -l app=web -o custom-columns=POD:.metadata.name,STATUS:.status.phase,NODE:.spec.nodeName
workstation$ kubectl -n lab-07-17 get events --field-selector reason=FailedScheduling | tail -1
```

Expected:
```
POD                    STATUS    NODE
web-7fbc5cd9c5-5gxq5   Running   node1
web-7fbc5cd9c5-6v7cp   Running   node2
web-7fbc5cd9c5-lrs5p   Pending   <none>
20s   Warning   FailedScheduling   pod/web-7fbc5cd9c5-lrs5p   0/3 nodes are available: 1 node(s) had untolerated taint(s), 2 node(s) didn't match pod anti-affinity rules. preemption: 0/3 nodes are available: 1 Preemption is not helpful for scheduling, 2 No preemption victims found for incoming pod.
```

**Why:** `topologyKey` defines the "domain" in which the rule applies; `kubernetes.io/hostname` = per node. Two
workers = at most two replicas. Required anti-affinity is a hard guarantee for HA, and it blocks scaling beyond the
number of domains (and an HPA scaling out would create Pending Pods).

2. Switch to **preferred** anti-affinity. Delete and re-create the Deployment (why not `apply`? see *Your turn*).

```bash
workstation$ kubectl -n lab-07-17 delete deploy web
workstation$ kubectl apply -n lab-07-17 -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
spec:
  replicas: 3
  selector:
    matchLabels: {app: web}
  template:
    metadata:
      labels: {app: web}
    spec:
      affinity:
        podAntiAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
          - weight: 100
            podAffinityTerm:
              labelSelector:
                matchLabels: {app: web}
              topologyKey: kubernetes.io/hostname
      containers:
      - name: podinfo
        image: ghcr.io/stefanprodan/podinfo:6.17.0
        resources:
          requests: {cpu: 20m, memory: 32Mi}
EOF
workstation$ kubectl -n lab-07-17 rollout status deploy/web
workstation$ kubectl -n lab-07-17 get pod -l app=web -o custom-columns=POD:.metadata.name,STATUS:.status.phase,NODE:.spec.nodeName
```

Expected:
```
POD                    STATUS    NODE
web-7b68f55d8f-j8rt7   Running   node2
web-7b68f55d8f-nkjls   Running   node1
web-7b68f55d8f-r57rd   Running   node2
```

**Why:** every node gets one replica first; the third goes where the penalty is smallest. If one node fails, at
least one replica survives. For "spread as evenly as possible" with more control, see topology spread constraints
in Lab 7.18.

3. Co-locate checkout with its session cache (Redis) using **pod affinity**.

```bash
workstation$ kubectl apply -n lab-07-17 -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: session-cache
spec:
  replicas: 1
  selector:
    matchLabels: {app: session-cache}
  template:
    metadata:
      labels: {app: session-cache}
    spec:
      containers:
      - name: redis
        image: redis:8.8
        resources:
          requests: {cpu: 20m, memory: 32Mi}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: checkout
spec:
  replicas: 3
  selector:
    matchLabels: {app: checkout}
  template:
    metadata:
      labels: {app: checkout}
    spec:
      affinity:
        podAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
          - labelSelector:
              matchLabels: {app: session-cache}
            topologyKey: kubernetes.io/hostname
      containers:
      - name: podinfo
        image: ghcr.io/stefanprodan/podinfo:6.17.0
        resources:
          requests: {cpu: 20m, memory: 32Mi}
EOF
workstation$ kubectl -n lab-07-17 rollout status deploy/checkout
workstation$ kubectl -n lab-07-17 get pod -l 'app in (session-cache,checkout)' -o custom-columns=POD:.metadata.name,STATUS:.status.phase,NODE:.spec.nodeName
```

Expected (node1 or node2—but all on the same node):
```
POD                              STATUS    NODE
checkout-56954b8566-bdf5c        Running   node1
checkout-56954b8566-ddtb6        Running   node1
checkout-56954b8566-m6s2c        Running   node1
session-cache-86d76bd9c7-z4sp9   Running   node1
```

**Why and pitfalls:** checkout Pods stay `Pending` until a cache Pod exists (it is fine here because both were
created together and the scheduler retries). Affinity is checked only at scheduling time: if the cache Pod is later
rescheduled to node2, the checkout Pods stay on node1. And you have just put all checkout replicas on one node—
combine co-location with anti-affinity or spreading if you need HA as well.

### Clean up

```bash
workstation$ kubectl delete namespace lab-07-17
```

### Your turn

The HA team insists on **required** anti-affinity, so they run `web-ha` with **2** replicas (one per worker).
Deploy it (same as step 1, name `web-ha`, 2 replicas), then release a new version with
`kubectl -n lab-07-17 set image deploy/web-ha podinfo=ghcr.io/stefanprodan/podinfo:6.16.0`. The rollout never
finishes. Explain why, and fix it without giving up the required rule.

<details><summary>Solution</summary>

```bash
workstation$ kubectl apply -n lab-07-17 -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web-ha
spec:
  replicas: 2
  selector:
    matchLabels: {app: web-ha}
  template:
    metadata:
      labels: {app: web-ha}
    spec:
      affinity:
        podAntiAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
          - labelSelector:
              matchLabels: {app: web-ha}
            topologyKey: kubernetes.io/hostname
      containers:
      - name: podinfo
        image: ghcr.io/stefanprodan/podinfo:6.17.0
        resources:
          requests: {cpu: 20m, memory: 32Mi}
EOF
workstation$ kubectl -n lab-07-17 rollout status deploy/web-ha
workstation$ kubectl -n lab-07-17 set image deploy/web-ha podinfo=ghcr.io/stefanprodan/podinfo:6.16.0
workstation$ kubectl -n lab-07-17 rollout status deploy/web-ha --timeout=45s
workstation$ kubectl -n lab-07-17 get pod -l app=web-ha -o custom-columns=POD:.metadata.name,STATUS:.status.phase,NODE:.spec.nodeName,IMAGE:.spec.containers[0].image
```

Expected:
```
error: timed out waiting for the condition
POD                       STATUS    NODE     IMAGE
web-ha-6bfc58fc84-dbnxb   Pending   <none>   ghcr.io/stefanprodan/podinfo:6.16.0
web-ha-868cdc6697-kbhs7   Running   node2    ghcr.io/stefanprodan/podinfo:6.17.0
web-ha-868cdc6697-skq6w   Running   node1    ghcr.io/stefanprodan/podinfo:6.17.0
```

The default strategy is `maxSurge: 25%` (rounded **up** to 1) and `maxUnavailable: 25%` (rounded **down** to 0): the
Deployment first creates an extra new Pod and only then removes an old one. The surge Pod has the label `app=web-ha`,
and both nodes already host an `app=web-ha` Pod, so it can never be scheduled—and no old Pod is removed while it is
Pending. (The same deadlock happened in step 2 if you `apply` the preferred version over the required one: the old
Pods' *required* rule also repels the new Pods.)

Fix: replace instead of surge—take one old Pod down first.

```bash
workstation$ kubectl -n lab-07-17 patch deploy web-ha -p '{"spec":{"strategy":{"rollingUpdate":{"maxSurge":0,"maxUnavailable":1}}}}'
workstation$ kubectl -n lab-07-17 rollout status deploy/web-ha
workstation$ kubectl -n lab-07-17 get pod -l app=web-ha -o custom-columns=POD:.metadata.name,STATUS:.status.phase,NODE:.spec.nodeName,IMAGE:.spec.containers[0].image
```

Expected:
```
deployment "web-ha" successfully rolled out
POD                       STATUS    NODE    IMAGE
web-ha-6bfc58fc84-dbnxb   Running   node2   ghcr.io/stefanprodan/podinfo:6.16.0
web-ha-6bfc58fc84-wxbxm   Running   node1   ghcr.io/stefanprodan/podinfo:6.16.0
```

The price: during the update only one replica serves traffic. With required anti-affinity you need **one more node
than replicas** for zero-capacity-loss rollouts.
</details>

---

## Lab 7.18: Even spreading across zones – topology spread constraints

**Scenario** – The frontend must survive the loss of a whole server room. Anti-affinity (Lab 7.17) can say "not
together", but not "evenly". With 9 replicas in 2 zones you want 5/4, not 8/1. Topology spread constraints express
exactly that—and they have a surprising interaction with the tainted control-plane node.

**⚠ cluster-wide:** this lab labels nodes (including the master). Always run *Clean up*.

**What you'll learn**
- `topologySpreadConstraints`: `maxSkew`, `topologyKey`, `whenUnsatisfiable`, `labelSelector`
- How skew is computed per domain
- Why a tainted node in its own zone blocks scheduling, and `nodeTaintsPolicy: Honor`
- `minDomains` (*Your turn*)

### Steps

1. Create the namespace and the two zones.

```bash
workstation$ kubectl create namespace lab-07-18
workstation$ kubectl label node node1 topology.kubernetes.io/zone=zone-a
workstation$ kubectl label node node2 topology.kubernetes.io/zone=zone-b
```

2. Deploy the frontend with a hard spread rule: the number of `app=frontend` Pods per zone may differ by at most 1.

```bash
workstation$ kubectl apply -n lab-07-18 -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: frontend
spec:
  replicas: 5
  selector:
    matchLabels: {app: frontend}
  template:
    metadata:
      labels: {app: frontend}
    spec:
      topologySpreadConstraints:
      - maxSkew: 1
        topologyKey: topology.kubernetes.io/zone
        whenUnsatisfiable: DoNotSchedule
        labelSelector:
          matchLabels: {app: frontend}
      containers:
      - name: podinfo
        image: ghcr.io/stefanprodan/podinfo:6.17.0
        resources:
          requests: {cpu: 20m, memory: 32Mi}
EOF
workstation$ kubectl -n lab-07-18 rollout status deploy/frontend
workstation$ kubectl -n lab-07-18 get pod -l app=frontend -o wide --no-headers | awk '{print $7}' | sort | uniq -c
workstation$ kubectl -n lab-07-18 scale deploy/frontend --replicas=9
workstation$ kubectl -n lab-07-18 rollout status deploy/frontend
workstation$ kubectl -n lab-07-18 get pod -l app=frontend -o wide --no-headers | awk '{print $7}' | sort | uniq -c
```

Expected:
```
      3 node1
      2 node2
      5 node1
      4 node2
```

**Why:** *skew* = Pods in a domain − Pods in the emptiest eligible domain. Placing a Pod is allowed only if the
resulting skew is ≤ `maxSkew`. `DoNotSchedule` makes it a filter (hard); `ScheduleAnyway` makes it a score (soft).
Unlike anti-affinity, this works for any number of replicas.

3. The infrastructure team labels the master as well—it sits in a third room, `zone-c`. Scale to 11.

```bash
workstation$ kubectl label node master topology.kubernetes.io/zone=zone-c
workstation$ kubectl -n lab-07-18 scale deploy/frontend --replicas=11
workstation$ sleep 15
workstation$ kubectl -n lab-07-18 get pod -l app=frontend -o wide --no-headers | awk '{print $3, $7}' | sort | uniq -c
workstation$ kubectl -n lab-07-18 get events --field-selector reason=FailedScheduling | tail -1
```

Expected:
```
      2 Pending <none>
      5 Running node1
      4 Running node2
15s   Warning   FailedScheduling   pod/frontend-9c7f44dcc-x5cz5   0/3 nodes are available: 1 node(s) had untolerated taint(s), 2 node(s) didn't match pod topology spread constraints. preemption: 0/3 nodes are available: 1 Preemption is not helpful for scheduling, 2 No preemption victims found for incoming pod.
```

**Why:** `zone-c` now counts as a domain with **0** frontend Pods, so the minimum is 0 and zone-a (5) / zone-b (4)
already exceed the skew—but no Pod can go to zone-c, because the master is tainted. By default
(`nodeTaintsPolicy: Ignore`) the skew calculation ignores taints. The same happens in clouds when a node pool in
some zone is tainted for a special team.

4. Tell the constraint to honour taints: nodes whose taints the Pod does not tolerate are no longer domains.

```bash
workstation$ kubectl -n lab-07-18 patch deploy frontend --type=json \
  -p '[{"op":"add","path":"/spec/template/spec/topologySpreadConstraints/0/nodeTaintsPolicy","value":"Honor"}]'
workstation$ kubectl -n lab-07-18 rollout status deploy/frontend
workstation$ kubectl -n lab-07-18 get pod -l app=frontend -o wide --no-headers | awk '{print $3, $7}' | sort | uniq -c
```

Expected:
```
      6 Running node1
      5 Running node2
```

(There is a matching `nodeAffinityPolicy`, default `Honor`: nodes excluded by the Pod's node affinity/selector are
not counted as domains.)

### Clean up

```bash
workstation$ kubectl delete namespace lab-07-18
workstation$ kubectl label node master node1 node2 topology.kubernetes.io/zone-
workstation$ kubectl get nodes -L topology.kubernetes.io/zone
```

### Your turn

The architecture board decides: the `api` (4 replicas) must be spread over **at least 3 zones**; if fewer zones are
available, the missing capacity must be *visible* as Pending Pods rather than silently piling up in two zones. Keep
the master labelled `zone-c` (do this before the clean up). Implement it with `minDomains`, observe the result on our
cluster, then make the third zone usable for the `api` and observe again.

<details><summary>Solution</summary>

`minDomains: 3` (only valid with `DoNotSchedule`): while fewer than 3 eligible domains exist, the global minimum is
treated as 0, so each zone can hold at most `maxSkew` Pods.

```bash
workstation$ kubectl apply -n lab-07-18 -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: api
spec:
  replicas: 4
  selector:
    matchLabels: {app: api}
  template:
    metadata:
      labels: {app: api}
    spec:
      topologySpreadConstraints:
      - maxSkew: 1
        minDomains: 3
        topologyKey: topology.kubernetes.io/zone
        whenUnsatisfiable: DoNotSchedule
        nodeTaintsPolicy: Honor
        labelSelector:
          matchLabels: {app: api}
      containers:
      - name: podinfo
        image: ghcr.io/stefanprodan/podinfo:6.17.0
        resources:
          requests: {cpu: 20m, memory: 32Mi}
EOF
workstation$ sleep 20
workstation$ kubectl -n lab-07-18 get pod -l app=api -o wide --no-headers | awk '{print $3, $7}' | sort | uniq -c
```

Expected—only two eligible zones (the tainted master is not a domain with `Honor`), one Pod each:
```
      2 Pending <none>
      1 Running node1
      1 Running node2
```

Make zone-c eligible by tolerating the control-plane taint (in a real cluster: add a worker in a third zone):
```bash
workstation$ kubectl -n lab-07-18 patch deploy api --type=json -p '[{"op":"add","path":"/spec/template/spec/tolerations","value":[{"key":"node-role.kubernetes.io/control-plane","operator":"Exists","effect":"NoSchedule"}]}]'
workstation$ kubectl -n lab-07-18 rollout status deploy/api
workstation$ kubectl -n lab-07-18 get pod -l app=api -o wide --no-headers | awk '{print $3, $7}' | sort | uniq -c
```

Expected:
```
      1 Running master
      2 Running node1
      1 Running node2
```

Three domains, skew 1 (2/1/1). Running application Pods on the control plane is fine for a lab, not for production.
</details>

---

## Lab 7.19: Node maintenance without downtime – cordon, drain and PodDisruptionBudget

**Scenario** – node2 needs a kernel update and a reboot during business hours. The checkout service (3 replicas)
must keep **at least 2 replicas** serving at all times. You will cordon the node, drain it while a
PodDisruptionBudget (PDB) protects checkout, see how a too-strict PDB blocks the drain, and bring the node back.

**⚠ cluster-wide:** this lab cordons and drains node2. **All** Pods on node2 (other namespaces, the NGF controller)
are evicted and rescheduled on node1. Run it when nobody else uses the cluster, and always run *Clean up*
(`uncordon`).

**What you'll learn**
- `kubectl cordon` / `uncordon` (`spec.unschedulable`, the `node.kubernetes.io/unschedulable` taint)
- `kubectl drain`: eviction API, `--ignore-daemonsets`, `--delete-emptydir-data`, `--timeout`
- PodDisruptionBudgets with `minAvailable` / `maxUnavailable`
- Why a PDB that allows zero disruptions blocks maintenance

### Steps

1. Create the namespace, checkout (3 replicas spread over both workers) and a PDB.

```bash
workstation$ kubectl create namespace lab-07-19
workstation$ kubectl apply -n lab-07-19 -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: checkout
spec:
  replicas: 3
  selector:
    matchLabels: {app: checkout}
  template:
    metadata:
      labels: {app: checkout}
    spec:
      topologySpreadConstraints:
      - maxSkew: 1
        topologyKey: kubernetes.io/hostname
        whenUnsatisfiable: ScheduleAnyway
        labelSelector:
          matchLabels: {app: checkout}
      containers:
      - name: podinfo
        image: ghcr.io/stefanprodan/podinfo:6.17.0
        readinessProbe:
          httpGet: {path: /readyz, port: 9898}
        resources:
          requests: {cpu: 20m, memory: 32Mi}
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: checkout
spec:
  minAvailable: 2
  selector:
    matchLabels: {app: checkout}
EOF
workstation$ kubectl -n lab-07-19 rollout status deploy/checkout
workstation$ kubectl -n lab-07-19 get pod -o wide --no-headers | awk '{print $1, $7}'
workstation$ kubectl -n lab-07-19 get pdb checkout
```

Expected:
```
checkout-766b7997cd-cksjb node1
checkout-766b7997cd-l2z9f node2
checkout-766b7997cd-wrc9t node2
NAME       MIN AVAILABLE   MAX UNAVAILABLE   ALLOWED DISRUPTIONS   AGE
checkout   2               N/A               1                     5s
```

**Why:** `ALLOWED DISRUPTIONS` = ready Pods − `minAvailable` = 1. A PDB only limits *voluntary* disruptions that go
through the **eviction API** (drain, cluster autoscaler, VPA in Recreate mode). It cannot prevent a node crash.

2. Cordon node2: no new Pods are scheduled there; running Pods are untouched.

```bash
workstation$ kubectl cordon node2
workstation$ kubectl get node node2
workstation$ kubectl get node node2 -o jsonpath='{.spec.taints}{"\n"}'
workstation$ kubectl -n lab-07-19 scale deploy/checkout --replicas=4
workstation$ kubectl -n lab-07-19 get pod -o wide --no-headers | awk '{print $1, $7}'
workstation$ kubectl -n lab-07-19 scale deploy/checkout --replicas=3
```

Expected:
```
NAME    STATUS                     ROLES    AGE   VERSION
node2   Ready,SchedulingDisabled   <none>   15d   v1.37.1
[{"effect":"NoSchedule","key":"node.kubernetes.io/unschedulable","timeAdded":"..."}]
```
The fourth Pod lands on node1.

3. Drain node2. In a second terminal watch the Pods: `kubectl -n lab-07-19 get pod -o wide -w`.

```bash
workstation$ kubectl drain node2 --ignore-daemonsets --delete-emptydir-data --timeout=180s
```

Expected:
```
node/node2 already cordoned
Warning: ignoring DaemonSet-managed Pods: kube-system/calico-node-r5srn, kube-system/csi-s3-ckz6g, kube-system/kube-proxy-jpvmr, metallb-system/speaker-rs7gh
evicting pod lab-07-19/checkout-766b7997cd-zw45s
evicting pod lab-07-19/checkout-766b7997cd-9qnmk
error when evicting pods/"checkout-766b7997cd-9qnmk" -n "lab-07-19" (will retry after 5s): Cannot evict pod as it would violate the pod's disruption budget.
evicting pod lab-07-19/checkout-766b7997cd-9qnmk
pod/checkout-766b7997cd-zw45s evicted
pod/checkout-766b7997cd-9qnmk evicted
node/node2 drained
```

With two checkout Pods on node2, the second eviction is refused by the PDB at first: drain evicts one, waits until the replacement on node1 is **ready** (thanks to the readiness probe), and only then
evicts the next.

```bash
workstation$ kubectl -n lab-07-19 get pod -o wide --no-headers | awk '{print $1, $3, $7}'
workstation$ kubectl -n lab-07-19 get pdb checkout
```

Expected:
```
checkout-766b7997cd-gzj4c Running node1
checkout-766b7997cd-hqh4g Running node1
checkout-766b7997cd-ldzmz Running node1
NAME       MIN AVAILABLE   MAX UNAVAILABLE   ALLOWED DISRUPTIONS   AGE
checkout   2               N/A               1                     13s
```

**Why the flags:** DaemonSet Pods would be recreated on the node immediately, so drain skips them. `emptyDir` data is
lost on eviction, so drain asks for explicit consent. `--timeout` makes drain fail instead of hanging forever.

4. Do the maintenance (e.g. `node2$ sudo reboot`), then return the node to service.

```bash
workstation$ kubectl uncordon node2
workstation$ kubectl get node node2
workstation$ kubectl -n lab-07-19 get pod -o wide --no-headers | awk '{print $1, $7}'
```

Expected: node2 `Ready` (no `SchedulingDisabled`), but all checkout Pods are **still on node1**—Kubernetes does
not rebalance. A `kubectl -n lab-07-19 rollout restart deploy/checkout` spreads them again (thanks to the spread
constraint).

### Clean up

```bash
workstation$ kubectl uncordon node2                      # safe to repeat
workstation$ kubectl delete namespace lab-07-19
workstation$ kubectl get nodes                           # no SchedulingDisabled
```

### Your turn

A colleague "hardened" the PDB to `minAvailable: 3` (= all replicas), and someone left a bare debugging Pod
(`kubectl run debug --image=busybox:1.38 -- sleep 3600`, pinned to node2 with `--overrides`) in the namespace.
Reproduce both and find the problems **without** disturbing the node: a server-side dry run
(`kubectl drain … --dry-run=server`) sends real eviction requests that are validated (PDBs included) but not
executed. Then fix the situation so that the real drain succeeds while checkout keeps at least 2 ready replicas.

<details><summary>Solution</summary>

```bash
workstation$ kubectl -n lab-07-19 rollout restart deploy/checkout && kubectl -n lab-07-19 rollout status deploy/checkout
workstation$ kubectl -n lab-07-19 patch pdb checkout --type=merge -p '{"spec":{"minAvailable":3}}'
workstation$ kubectl -n lab-07-19 run debug --image=busybox:1.38 \
  --overrides='{"spec":{"nodeSelector":{"kubernetes.io/hostname":"node2"}}}' -- sleep 3600
workstation$ kubectl -n lab-07-19 get pdb checkout
workstation$ kubectl drain node2 --ignore-daemonsets --delete-emptydir-data --dry-run=client 2>&1 | grep -E 'error|cannot'
workstation$ kubectl drain node2 --ignore-daemonsets --pod-selector=app=checkout --timeout=20s --dry-run=server 2>&1 | tail -3
workstation$ kubectl get node node2          # still Ready, not cordoned: it was a dry run
```

Expected:
```
NAME       MIN AVAILABLE   MAX UNAVAILABLE   ALLOWED DISRUPTIONS   AGE
checkout   3               N/A               0                     14s
error: unable to drain node "node2" due to error: cannot delete Pods that declare no controller (use --force to override): lab-07-19/debug, continuing command...
cannot delete Pods that declare no controller (use --force to override): lab-07-19/debug
 node2
error when evicting pods/"checkout-766b7997cd-l2z9f" -n "lab-07-19": global timeout reached: 20s
error when evicting pods/"checkout-766b7997cd-wrc9t" -n "lab-07-19": global timeout reached: 20s
NAME    STATUS   ROLES    AGE   VERSION
node2   Ready    <none>   15d   v1.37.1
```

Two problems:
1. **Bare Pods** have no controller to recreate them, so drain refuses to delete them unless you pass `--force`
   (the Pod is gone for good). Decide consciously—here: delete the debug Pod.
2. **`ALLOWED DISRUPTIONS 0`**: drain would retry `Cannot evict pod as it would violate the pod's disruption budget`
   until the timeout. A PDB must always allow at least one disruption. Prefer `maxUnavailable: 1`, which keeps
   working when you scale the Deployment.

```bash
workstation$ kubectl -n lab-07-19 delete pod debug
workstation$ kubectl -n lab-07-19 patch pdb checkout --type=merge -p '{"spec":{"minAvailable":null,"maxUnavailable":1}}'
workstation$ kubectl -n lab-07-19 get pdb checkout
workstation$ kubectl drain node2 --ignore-daemonsets --pod-selector=app=checkout --dry-run=server
```

Expected:
```
NAME       MIN AVAILABLE   MAX UNAVAILABLE   ALLOWED DISRUPTIONS   AGE
checkout   N/A             1                 1                     43s
node/node2 cordoned (server dry run)
evicting pod lab-07-19/checkout-766b7997cd-wrc9t (server dry run)
evicting pod lab-07-19/checkout-766b7997cd-l2z9f (server dry run)
node/node2 drained (server dry run)
```

Now the real drain succeeds (one checkout Pod at a time) and you return the node:
```bash
workstation$ kubectl drain node2 --ignore-daemonsets --delete-emptydir-data --timeout=180s
workstation$ kubectl uncordon node2
```

Expected:
```
node/node2 cordoned
evicting pod lab-07-19/checkout-6f6fcf84bd-qprtk
evicting pod lab-07-19/checkout-6f6fcf84bd-5c8qn
error when evicting pods/"checkout-6f6fcf84bd-5c8qn" -n "lab-07-19" (will retry after 5s): Cannot evict pod as it would violate the pod's disruption budget.
pod/checkout-6f6fcf84bd-qprtk evicted
evicting pod lab-07-19/checkout-6f6fcf84bd-5c8qn
pod/checkout-6f6fcf84bd-5c8qn evicted
node/node2 drained
node/node2 uncordoned
```

Note that a server dry run validates every eviction *individually*: it reveals a PDB that allows **zero**
disruptions, but not the "one at a time" waiting of a real drain.
</details>
