# Module 06: Security

Kubernetes security has two halves: **who may do what** through the API (authentication, RBAC, admission) and **what
a container may do** on the node (Pod Security, `securityContext`, resource limits). In this module you give apps,
people and pipelines exactly the access they need, audit and break RBAC on purpose, and lock down workloads and
tenant namespaces up to your own admission policy.

## Prerequisites check

```bash
workstation$ kubectl auth whoami                     # you are cluster-admin (kubernetes-admin, group kubeadm:cluster-admins or system:masters)
workstation$ kubectl auth can-i '*' '*' -A           # yes
workstation$ openssl version; jq --version           # for user certificates and token decoding
workstation$ kubectl api-resources | grep -E 'certificatesigningrequests|validatingadmissionpolicies'
```

Several labs create **cluster-scoped** objects (ClusterRoles, ClusterRoleBindings, CertificateSigningRequests,
ValidatingAdmissionPolicies). They carry the `lab-06-` prefix and are removed in each lab's *Clean up*. Files for
users and kubeconfigs go to `~/lab-06-*` on your workstation.

## Table of contents

- [Lab 6.1: A least-privilege ServiceAccount for an app that reads its own config](#lab-61-a-least-privilege-serviceaccount-for-an-app-that-reads-its-own-config)
- [Lab 6.2: A contractor gets read-only access with a client certificate](#lab-62-a-contractor-gets-read-only-access-with-a-client-certificate)
- [Lab 6.3: Team access through groups, across several namespaces](#lab-63-team-access-through-groups-across-several-namespaces)
- [Lab 6.4: An on-call role with aggregated ClusterRoles](#lab-64-an-on-call-role-with-aggregated-clusterroles)
- [Lab 6.5: A CI/CD deployer with short-lived tokens](#lab-65-a-cicd-deployer-with-short-lived-tokens)
- [Lab 6.6: Auditing RBAC and privilege-escalation pitfalls](#lab-66-auditing-rbac-and-privilege-escalation-pitfalls)
- [Lab 6.7: Pod Security Admission for a namespace migration](#lab-67-pod-security-admission-for-a-namespace-migration)
- [Lab 6.8: Hardening a web server with securityContext](#lab-68-hardening-a-web-server-with-securitycontext)
- [Lab 6.9: Tenant namespaces with ResourceQuota and LimitRange](#lab-69-tenant-namespaces-with-resourcequota-and-limitrange)
- [Lab 6.10: Your own admission rules with ValidatingAdmissionPolicy](#lab-610-your-own-admission-rules-with-validatingadmissionpolicy)

---

## Lab 6.1: A least-privilege ServiceAccount for an app that reads its own config

**Scenario** – A settings service reads its configuration from a ConfigMap through the Kubernetes API, so it can pick
up changes without a restart. The first draft ran with the namespace's `default` ServiceAccount and a broad Role. A
security review asks for two things: Pods that do not talk to the API must not get a token at all, and this app may
read **its own** ConfigMap and nothing else.

**What you'll learn**
- the automatically mounted ServiceAccount token and `automountServiceAccountToken: false`
- a Role restricted with `resourceNames`, bound to a dedicated ServiceAccount
- calling the API from a Pod with `kubectl` and with plain `curl` + token
- checking permissions with `kubectl auth whoami` and `kubectl auth can-i` (also with `--as`)

### Steps

1. Create the namespace, the data, a ServiceAccount without automatic token mount, a narrow Role and a Pod that opts
   in to the token.

```bash
workstation$ kubectl create namespace lab-06-01
workstation$ kubectl -n lab-06-01 apply -f - <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: app-settings
data:
  log-level: info
  max-connections: "100"
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: other-team-settings
data:
  internal-endpoint: http://billing.internal:8080
---
apiVersion: v1
kind: Secret
metadata:
  name: db-password
stringData:
  password: s3cr3t
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: settings-reader
automountServiceAccountToken: false        # no token unless a Pod explicitly asks for one
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: read-app-settings
rules:
- apiGroups: [""]
  resources: ["configmaps"]
  resourceNames: ["app-settings"]          # this one object only
  verbs: ["get", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: settings-reader
subjects:
- kind: ServiceAccount
  name: settings-reader
  namespace: lab-06-01
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: read-app-settings
---
apiVersion: v1
kind: Pod
metadata:
  name: settings-app
spec:
  serviceAccountName: settings-reader
  automountServiceAccountToken: true        # this Pod needs the API, so it opts in
  containers:
  - name: app
    image: alpine/k8s:1.37.1
    command: ["sleep", "infinity"]
EOF
```

2. For comparison, start a Pod with the `default` ServiceAccount. It gets a token although it never needs one.

```bash
workstation$ kubectl -n lab-06-01 run default-sa --image=alpine/k8s:1.37.1 --command -- sleep infinity
workstation$ kubectl -n lab-06-01 wait --for=condition=Ready pod/settings-app pod/default-sa
workstation$ kubectl -n lab-06-01 exec default-sa -- ls /var/run/secrets/kubernetes.io/serviceaccount
workstation$ kubectl -n lab-06-01 exec default-sa -- kubectl get configmaps
```

Expected:
```
ca.crt
namespace
token
Error from server (Forbidden): configmaps is forbidden: User "system:serviceaccount:lab-06-01:default" cannot list resource "configmaps" in API group "" in the namespace "lab-06-01"
```

The `default` ServiceAccount has no permissions, but the token still authenticates: an attacker who breaks into the
container can talk to the API server, probe it, and use whatever someone binds to `default` later. Set
`automountServiceAccountToken: false` on ServiceAccounts (or Pods) that do not need the API.

3. Check who the app is. The token is bound to the Pod and the node, which shows up as extra attributes.

```bash
workstation$ kubectl -n lab-06-01 exec settings-app -- kubectl auth whoami
```

Expected:
```
ATTRIBUTE                                           VALUE
Username                                            system:serviceaccount:lab-06-01:settings-reader
Groups                                              [system:serviceaccounts system:serviceaccounts:lab-06-01 system:authenticated]
Extra: authentication.kubernetes.io/node-name       [node1]
Extra: authentication.kubernetes.io/pod-name        [settings-app]
...
```

4. Exercise the permissions from inside the Pod (`kubectl` there uses the mounted token automatically).

```bash
workstation$ kubectl -n lab-06-01 exec settings-app -- kubectl get configmap app-settings -o jsonpath='{.data}'; echo
workstation$ kubectl -n lab-06-01 exec settings-app -- kubectl get configmap other-team-settings
workstation$ kubectl -n lab-06-01 exec settings-app -- kubectl get configmaps
workstation$ kubectl -n lab-06-01 exec settings-app -- kubectl get secret db-password
```

Expected:
```
{"log-level":"info","max-connections":"100"}
Error from server (Forbidden): configmaps "other-team-settings" is forbidden: User "system:serviceaccount:lab-06-01:settings-reader" cannot get resource "configmaps" in API group "" in the namespace "lab-06-01"
Error from server (Forbidden): configmaps is forbidden: User "system:serviceaccount:lab-06-01:settings-reader" cannot list resource "configmaps" in API group "" in the namespace "lab-06-01"
Error from server (Forbidden): secrets "db-password" is forbidden: User "system:serviceaccount:lab-06-01:settings-reader" cannot get resource "secrets" in API group "" in the namespace "lab-06-01"
```

`list` is denied because a list request has no single object name to match against `resourceNames`. Watching the one
object works, though: `kubectl get configmap app-settings -w` sends a watch with `fieldSelector=metadata.name=...`,
which RBAC matches against `resourceNames`.

5. Most apps do not ship `kubectl`; they use an HTTP client and the same three mounted files.

```bash
workstation$ kubectl -n lab-06-01 exec settings-app -- sh -c '
  SA=/var/run/secrets/kubernetes.io/serviceaccount
  curl -s --cacert $SA/ca.crt -H "Authorization: Bearer $(cat $SA/token)" \
    https://kubernetes.default.svc/api/v1/namespaces/$(cat $SA/namespace)/configmaps/app-settings | jq -c .data'
```

Expected:
```
{"log-level":"info","max-connections":"100"}
```

6. As an admin you can check the same thing from outside, by impersonating the ServiceAccount, and list everything
   it may do.

```bash
workstation$ kubectl auth can-i get configmap/app-settings -n lab-06-01 --as=system:serviceaccount:lab-06-01:settings-reader
workstation$ kubectl auth can-i list configmaps -n lab-06-01 --as=system:serviceaccount:lab-06-01:settings-reader
workstation$ kubectl -n lab-06-01 exec settings-app -- kubectl auth can-i --list | grep -E 'Resources|configmaps'
```

Expected:
```
yes
no
Resources                                       Non-Resource URLs                      Resource Names   Verbs
configmaps                                      []                                     [app-settings]   [get watch]
```

### Clean up

```bash
workstation$ kubectl delete namespace lab-06-01
```

### Your turn

The settings service should also publish a heartbeat into a ConfigMap `settings-app-status` (key `heartbeat`, value
= current time), and it must not be able to modify `app-settings`. Grant the minimum needed with a second Role, and
try to let the app create the status ConfigMap itself. What happens, and how do you solve it?

<details><summary>Solution</summary>

```bash
workstation$ kubectl -n lab-06-01 apply -f - <<'EOF'
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: write-app-status
rules:
- apiGroups: [""]
  resources: ["configmaps"]
  resourceNames: ["settings-app-status"]
  verbs: ["create", "get", "patch", "update"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: settings-reader-status
subjects:
- kind: ServiceAccount
  name: settings-reader
  namespace: lab-06-01
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: write-app-status
EOF
workstation$ kubectl -n lab-06-01 exec settings-app -- kubectl create configmap settings-app-status --from-literal=heartbeat=now
```

Expected:
```
error: failed to create configmap: configmaps is forbidden: User "system:serviceaccount:lab-06-01:settings-reader" cannot create resource "configmaps" in API group "" in the namespace "lab-06-01"
```

`create` cannot be limited with `resourceNames`: the authorizer sees a create request for "configmaps" without a
name (the name is in the request body), so the rule never matches. Either grant `create` on all ConfigMaps (too
much here) or let the deployment pre-create the object, and keep `get`/`patch`/`update` restricted by name:

```bash
workstation$ kubectl -n lab-06-01 create configmap settings-app-status --from-literal=heartbeat=never
workstation$ kubectl -n lab-06-01 exec settings-app -- sh -c \
  'kubectl patch configmap settings-app-status -p "{\"data\":{\"heartbeat\":\"$(date -u +%FT%TZ)\"}}"'
workstation$ kubectl -n lab-06-01 exec settings-app -- kubectl patch configmap app-settings -p '{"data":{"log-level":"debug"}}'
workstation$ kubectl -n lab-06-01 get configmap settings-app-status -o jsonpath='{.data.heartbeat}{"\n"}'
```

Expected:
```
configmap/settings-app-status created
configmap/settings-app-status patched
Error from server (Forbidden): configmaps "app-settings" is forbidden: User "system:serviceaccount:lab-06-01:settings-reader" cannot patch resource "configmaps" in API group "" in the namespace "lab-06-01"
2026-11-04T03:38:38Z
```

You can now remove `create` from the Role; it never had an effect.

</details>

---

## Lab 6.2: A contractor gets read-only access with a client certificate

**Scenario** – Anna, an external contractor, has to troubleshoot the staging environment for a week. She needs to
read workloads and logs in **staging only**, never production, and must not see Secrets. Kubernetes has no user
database; a user is whoever presents a certificate signed by the cluster CA. We let Anna create her own key, sign her
request through the CertificateSigningRequest API, build her a kubeconfig, and bind the built-in `view` role in one
namespace.

**What you'll learn**
- the CSR API: `signerName: kubernetes.io/kube-apiserver-client`, `expirationSeconds`, approval
- how `CN` becomes the user name and `O` the groups
- building a kubeconfig with `kubectl config set-cluster/set-credentials/set-context`
- namespace-scoped access with a RoleBinding to the built-in `view` ClusterRole
- what you can and cannot do when access must be revoked

### Steps

1. Create two environments.

```bash
workstation$ kubectl create namespace lab-06-02-staging
workstation$ kubectl create namespace lab-06-02-prod
workstation$ kubectl -n lab-06-02-staging create deployment web --image=nginx:1.31-alpine
```

2. Anna creates her private key and a certificate signing request. The key never leaves her laptop; you only see the
   CSR.

```bash
workstation$ mkdir -p ~/lab-06-02 && cd ~/lab-06-02
workstation$ openssl genrsa -out anna.key 2048
workstation$ openssl req -new -key anna.key -out anna.csr -subj "/CN=anna/O=contractors"
```

3. Submit the CSR to the cluster with a lifetime of one day, and approve it as an admin.

```bash
workstation$ kubectl apply -f - <<EOF
apiVersion: certificates.k8s.io/v1
kind: CertificateSigningRequest
metadata:
  name: lab-06-02-anna
spec:
  request: $(base64 < anna.csr | tr -d '\n')
  signerName: kubernetes.io/kube-apiserver-client
  expirationSeconds: 86400
  usages: ["client auth"]
EOF
workstation$ kubectl get csr lab-06-02-anna
workstation$ kubectl certificate approve lab-06-02-anna
workstation$ kubectl get csr lab-06-02-anna
```

Expected:
```
NAME             AGE   SIGNERNAME                            REQUESTOR          REQUESTEDDURATION   CONDITION
lab-06-02-anna   0s    kubernetes.io/kube-apiserver-client   kubernetes-admin   24h                 Pending
certificatesigningrequest.certificates.k8s.io/lab-06-02-anna approved
NAME             AGE   SIGNERNAME                            REQUESTOR          REQUESTEDDURATION   CONDITION
lab-06-02-anna   0s    kubernetes.io/kube-apiserver-client   kubernetes-admin   24h                 Approved,Issued
```

> Before approving, always decode and check the request (`openssl req -in anna.csr -noout -subject`). Approving a
> CSR with `O=system:masters` would create a permanent cluster-admin that RBAC cannot restrict.

4. Download the signed certificate.

```bash
workstation$ kubectl get csr lab-06-02-anna -o jsonpath='{.status.certificate}' | base64 -d > anna.crt
workstation$ openssl x509 -in anna.crt -noout -subject -issuer -dates
```

Expected:
```
subject=O=contractors, CN=anna
issuer=CN=kubernetes
notBefore=Nov  4 03:34:35 2026 GMT
notAfter=Nov  5 03:34:35 2026 GMT
```

5. Build a kubeconfig for Anna. It contains the API server address and the cluster CA (both taken from your own
   kubeconfig), her certificate and key, and a context with `lab-06-02-staging` as the default namespace.

```bash
workstation$ SERVER=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
workstation$ kubectl config view --minify --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' | base64 -d > ca.crt
workstation$ kubectl config --kubeconfig=anna.kubeconfig set-cluster training --server=$SERVER --certificate-authority=ca.crt --embed-certs=true
workstation$ kubectl config --kubeconfig=anna.kubeconfig set-credentials anna --client-certificate=anna.crt --client-key=anna.key --embed-certs=true
workstation$ kubectl config --kubeconfig=anna.kubeconfig set-context anna@training --cluster=training --user=anna --namespace=lab-06-02-staging
workstation$ kubectl config --kubeconfig=anna.kubeconfig use-context anna@training
workstation$ kubectl --kubeconfig=anna.kubeconfig auth whoami
```

Expected:
```
ATTRIBUTE                                           VALUE
Username                                            anna
Groups                                              [contractors system:authenticated]
```

6. Anna is authenticated, but not authorised for anything yet.

```bash
workstation$ kubectl --kubeconfig=anna.kubeconfig get pods
```

Expected:
```
Error from server (Forbidden): pods is forbidden: User "anna" cannot list resource "pods" in API group "" in the namespace "lab-06-02-staging"
```

7. Bind the built-in `view` ClusterRole to Anna with a **RoleBinding** in staging. A RoleBinding grants the
   ClusterRole's permissions only inside its own namespace.

```bash
workstation$ kubectl -n lab-06-02-staging create rolebinding anna-view --clusterrole=view --user=anna
workstation$ kubectl --kubeconfig=anna.kubeconfig get pods
workstation$ kubectl --kubeconfig=anna.kubeconfig delete deployment web
workstation$ kubectl --kubeconfig=anna.kubeconfig get secrets
workstation$ kubectl --kubeconfig=anna.kubeconfig -n lab-06-02-prod get pods
```

Expected:
```
NAME                   READY   STATUS    RESTARTS   AGE
web-6d669fbd59-dvh6l   0/1     ContainerCreating   0          1s
Error from server (Forbidden): deployments.apps "web" is forbidden: User "anna" cannot delete resource "deployments" in API group "apps" in the namespace "lab-06-02-staging"
Error from server (Forbidden): secrets is forbidden: User "anna" cannot list resource "secrets" in API group "" in the namespace "lab-06-02-staging"
Error from server (Forbidden): pods is forbidden: User "anna" cannot list resource "pods" in API group "" in the namespace "lab-06-02-prod"
```

`view` deliberately excludes Secrets (and `pods/exec`), because reading a ServiceAccount token Secret would let a
viewer act as that ServiceAccount.

### Clean up

```bash
workstation$ kubectl delete namespace lab-06-02-staging lab-06-02-prod
workstation$ kubectl delete csr lab-06-02-anna
workstation$ rm -rf ~/lab-06-02
```

### Your turn

Anna's contract ends early, today. Remove her access immediately. Then check: is her certificate still valid? Can
she still authenticate? Does deleting the CSR object change anything? What would you do differently next time to make
off-boarding safer?

<details><summary>Solution</summary>

```bash
workstation$ kubectl -n lab-06-02-staging delete rolebinding anna-view
workstation$ kubectl --kubeconfig=anna.kubeconfig get pods
workstation$ openssl x509 -in anna.crt -noout -checkend 3600 && echo "certificate still valid for at least 1h"
workstation$ kubectl delete csr lab-06-02-anna
workstation$ kubectl --kubeconfig=anna.kubeconfig auth whoami | head -2
```

Expected:
```
rolebinding.rbac.authorization.k8s.io "anna-view" deleted from lab-06-02-staging namespace
Error from server (Forbidden): pods is forbidden: User "anna" cannot list resource "pods" in API group "" in the namespace "lab-06-02-staging"
Certificate will not expire
certificate still valid for at least 1h
certificatesigningrequest.certificates.k8s.io "lab-06-02-anna" deleted
ATTRIBUTE                                           VALUE
Username                                            anna
```

Kubernetes cannot revoke client certificates (there is no CRL/OCSP check). Removing the RoleBinding takes away the
authorisation instantly, but the certificate keeps **authenticating** until `notAfter`, and any permission granted
later to `anna`, to `contractors` or to `system:authenticated` would apply to her again. The CSR object is just a
record; deleting it changes nothing. Safer practice: short `expirationSeconds` and re-issue as needed, bind groups
instead of individual users only when group membership is controlled, never reuse user names, and for humans prefer
an OIDC identity provider, where disabling the account ends access everywhere.

</details>

---

## Lab 6.3: Team access through groups, across several namespaces

**Scenario** – The payments team operates its service in `dev` and `staging` (scale, restart, read logs), while
production changes go through the release process only. People join and leave the team every month, and nobody wants
to edit RoleBindings each time. We define the team's permissions **once** in a ClusterRole, bind it to the **group**
`team-payments` in the two namespaces, and let group membership come from the `O=` field of each member's
certificate.

**What you'll learn**
- one ClusterRole reused by RoleBindings in several namespaces
- binding a group instead of users; `O=` in the certificate subject becomes the group
- scripting user on-boarding (CSR → certificate → clean kubeconfig)
- `kubectl auth can-i` from the user's point of view

### Steps

1. Create the three environments, each with the payments Deployment.

```bash
workstation$ for env in dev staging prod; do
  kubectl create namespace lab-06-03-payments-$env
  kubectl -n lab-06-03-payments-$env create deployment payments --image=traefik/whoami:v1.12.0
done
```

2. Define what an "app operator" may do. It is a ClusterRole, but it grants nothing until it is bound.

```bash
workstation$ kubectl apply -f - <<'EOF'
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: lab-06-03-app-operator
rules:
- apiGroups: ["apps"]
  resources: ["deployments", "replicasets"]
  verbs: ["get", "list", "watch", "update", "patch"]
- apiGroups: ["apps"]
  resources: ["deployments/scale"]
  verbs: ["get", "update", "patch"]
- apiGroups: [""]
  resources: ["pods", "services", "configmaps", "events"]
  verbs: ["get", "list", "watch"]
- apiGroups: [""]
  resources: ["pods"]
  verbs: ["delete"]                 # "turn it off and on again"
- apiGroups: [""]
  resources: ["pods/log"]
  verbs: ["get"]
EOF
```

3. Bind it to the group in dev and staging only.

```bash
workstation$ for env in dev staging; do
  kubectl -n lab-06-03-payments-$env create rolebinding team-payments --clusterrole=lab-06-03-app-operator --group=team-payments
done
workstation$ kubectl get rolebindings -A | grep -E 'NAMESPACE|team-payments'
```

Expected:
```
NAMESPACE                    NAME            ROLE                                 AGE
lab-06-03-payments-dev       team-payments   ClusterRole/lab-06-03-app-operator   3s
lab-06-03-payments-staging   team-payments   ClusterRole/lab-06-03-app-operator   2s
```

4. On-boarding is the same every time, so put it into a shell function. It creates a key and a CSR, gets the CSR
   signed, and writes a kubeconfig that contains **only** the new user's credentials.

```bash
workstation$ mkdir -p ~/lab-06-03 && cd ~/lab-06-03
workstation$ SERVER=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
workstation$ kubectl config view --minify --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' | base64 -d > ca.crt
workstation$ new_user() {   # new_user <name> <subject>
  openssl genrsa -out $1.key 2048 2>/dev/null
  openssl req -new -key $1.key -out $1.csr -subj "$2"
  kubectl apply -f - >/dev/null <<EOF
apiVersion: certificates.k8s.io/v1
kind: CertificateSigningRequest
metadata:
  name: lab-06-03-$1
spec:
  request: $(base64 < $1.csr | tr -d '\n')
  signerName: kubernetes.io/kube-apiserver-client
  expirationSeconds: 86400
  usages: ["client auth"]
EOF
  kubectl certificate approve lab-06-03-$1 >/dev/null
  kubectl wait --for=jsonpath='{.status.certificate}' csr/lab-06-03-$1 >/dev/null
  kubectl get csr lab-06-03-$1 -o jsonpath='{.status.certificate}' | base64 -d > $1.crt
  rm -f $1.kubeconfig
  kubectl config --kubeconfig=$1.kubeconfig set-cluster training --server=$SERVER --certificate-authority=ca.crt --embed-certs=true >/dev/null
  kubectl config --kubeconfig=$1.kubeconfig set-credentials $1 --client-certificate=$1.crt --client-key=$1.key --embed-certs=true >/dev/null
  kubectl config --kubeconfig=$1.kubeconfig set-context $1@training --cluster=training --user=$1 >/dev/null
  kubectl config --kubeconfig=$1.kubeconfig use-context $1@training >/dev/null
  echo "kubeconfig for $1 written to $1.kubeconfig"
}
workstation$ new_user bob "/CN=bob/O=team-payments"
workstation$ kubectl --kubeconfig=bob.kubeconfig auth whoami | grep -E 'Username|Groups'
```

Expected:
```
kubeconfig for bob written to bob.kubeconfig
Username                                            bob
Groups                                              [team-payments system:authenticated]
```

> **Pitfall:** a shortcut like `kubectl config view --minify --raw > bob.kubeconfig` followed by
> `set-credentials bob` leaves **your admin key** in Bob's file under the old user entry. Always build user
> kubeconfigs from scratch, as above.

5. Bob operates dev and staging, but not prod, and cannot do more than the role allows.

```bash
workstation$ for env in dev staging prod; do
  echo "== $env: $(kubectl --kubeconfig=bob.kubeconfig -n lab-06-03-payments-$env scale deploy payments --replicas=2 2>&1)"
done
workstation$ kubectl --kubeconfig=bob.kubeconfig -n lab-06-03-payments-dev auth can-i delete deployments
workstation$ kubectl --kubeconfig=bob.kubeconfig -n lab-06-03-payments-dev auth can-i get secrets
```

Expected:
```
== dev: deployment.apps/payments scaled
== staging: deployment.apps/payments scaled
== prod: Error from server (Forbidden): deployments.apps "payments" is forbidden: User "bob" cannot get resource "deployments" in API group "apps" in the namespace "lab-06-03-payments-prod"
no
no
```

6. Carol joins the team. On-board her; no RBAC object changes.

```bash
workstation$ new_user carol "/CN=carol/O=team-payments"
workstation$ kubectl --kubeconfig=carol.kubeconfig -n lab-06-03-payments-staging get deploy
```

Expected:
```
kubeconfig for carol written to carol.kubeconfig
NAME       READY   UP-TO-DATE   AVAILABLE   AGE
payments   1/2     2            1           2s
```

The flip side: the group is whatever the certificate says. Whoever approves CSRs controls team membership, and
leaving the team means waiting for the certificate to expire (Lab 6.2). Keep `expirationSeconds` short.

### Clean up

```bash
workstation$ kubectl delete namespace lab-06-03-payments-dev lab-06-03-payments-staging lab-06-03-payments-prod
workstation$ kubectl delete clusterrole lab-06-03-app-operator
workstation$ kubectl delete csr lab-06-03-bob lab-06-03-carol
workstation$ rm -rf ~/lab-06-03
```

### Your turn

Carol also joins the on-call rotation. Members of the group `team-oncall` may **read** everything in
`lab-06-03-payments-prod`, including Pod logs, but still not change anything. Give Carol a new certificate that puts
her in both groups, grant the on-call access with a single binding, and show that Carol can read prod logs but not
scale prod, while Bob still cannot see prod at all.

<details><summary>Solution</summary>

A subject can contain several `O=` entries; each one becomes a group. Group membership is fixed in the certificate,
so Carol needs a new one (delete the old CSR first, because the function reuses its name).

```bash
workstation$ kubectl delete csr lab-06-03-carol
workstation$ new_user carol "/CN=carol/O=team-payments/O=team-oncall"
workstation$ kubectl --kubeconfig=carol.kubeconfig auth whoami | grep Groups
workstation$ kubectl -n lab-06-03-payments-prod create rolebinding team-oncall-view --clusterrole=view --group=team-oncall
workstation$ POD=$(kubectl -n lab-06-03-payments-prod get pod -l app=payments -o name)
workstation$ kubectl --kubeconfig=carol.kubeconfig -n lab-06-03-payments-prod logs $POD | head -1
workstation$ kubectl --kubeconfig=carol.kubeconfig -n lab-06-03-payments-prod scale deploy payments --replicas=2
workstation$ kubectl --kubeconfig=bob.kubeconfig -n lab-06-03-payments-prod logs $POD
```

Expected:
```
Groups                                              [team-oncall team-payments system:authenticated]
rolebinding.rbac.authorization.k8s.io/team-oncall-view created
2026/11/04 03:40:37 Starting up on port 80
Error from server (Forbidden): deployments.apps "payments" is forbidden: User "carol" cannot patch resource "deployments/scale" in API group "apps" in the namespace "lab-06-03-payments-prod"
Error from server (Forbidden): pods "payments-65f4cc9488-bz465" is forbidden: User "bob" cannot get resource "pods" in API group "" in the namespace "lab-06-03-payments-prod"
```

The built-in `view` ClusterRole includes `pods/log`, so no custom role is needed. RBAC is purely additive: Carol's
permissions are the union of everything bound to `carol`, `team-payments`, `team-oncall` and `system:authenticated`.
Remove the extra binding in *Clean up* together with the namespaces.

</details>

---

## Lab 6.4: An on-call role with aggregated ClusterRoles

**Scenario** – At 3 a.m. the on-call engineer must be able to look at **everything** (all namespaces, nodes, events,
metrics) but change nothing, except in production, where they may open a shell in a Pod and read logs during an
incident. Secrets stay off-limits everywhere. The read-only part should also grow automatically when new resource
types (CRDs, storage) are added, without anybody editing one giant role. Aggregated ClusterRoles do exactly that.

**What you'll learn**
- `aggregationRule`: a ClusterRole assembled by the controller from labelled ClusterRoles
- reusing the built-in `view` building blocks via `rbac.authorization.k8s.io/aggregate-to-view`
- combining a ClusterRoleBinding (read everywhere) with a namespaced Role (act in prod only)
- testing as somebody else with `--as` / `--as-group` (impersonation)

### Steps

1. Create a production and a staging namespace with a workload, and a Secret in prod.

```bash
workstation$ kubectl create namespace lab-06-04-prod
workstation$ kubectl create namespace lab-06-04-staging
workstation$ for ns in lab-06-04-prod lab-06-04-staging; do kubectl -n $ns create deployment shop --image=nginx:1.31-alpine; done
workstation$ kubectl -n lab-06-04-prod create secret generic stripe --from-literal=key=sk_live_x
```

2. Create the aggregated on-call ClusterRole, a first building block for nodes (which `view` does not cover, because
   nodes are cluster-scoped), and bind it cluster-wide to the group `lab-06-04-oncall`.

```bash
workstation$ kubectl apply -f - <<'EOF'
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: lab-06-04-oncall
aggregationRule:
  clusterRoleSelectors:
  - matchLabels:
      rbac.authorization.k8s.io/aggregate-to-view: "true"   # everything the built-in "view" role contains
  - matchLabels:
      lab-06-04/aggregate-to-oncall: "true"                 # plus our own building blocks
rules: []                                                   # filled in by the controller
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: lab-06-04-oncall-nodes
  labels:
    lab-06-04/aggregate-to-oncall: "true"
rules:
- apiGroups: [""]
  resources: ["nodes"]
  verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: lab-06-04-oncall
subjects:
- kind: Group
  name: lab-06-04-oncall
  apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: ClusterRole
  name: lab-06-04-oncall
  apiGroup: rbac.authorization.k8s.io
EOF
workstation$ kubectl get clusterrole lab-06-04-oncall -o json | jq '.rules | length'
workstation$ kubectl get clusterrole lab-06-04-oncall -o json | jq -c '.rules[] | select(.resources | index("nodes"))'
```

Expected (the controller copied 14 rules into our empty role, among them metrics from metrics-server, which labels
its own role for `view`, and our nodes rule):
```
14
{"apiGroups":["metrics.k8s.io"],"resources":["pods","nodes"],"verbs":["get","list","watch"]}
{"apiGroups":[""],"resources":["nodes"],"verbs":["get","list","watch"]}
```

> **Do not** put the label `rbac.authorization.k8s.io/aggregate-to-view: "true"` on your *own* ClusterRoles unless
> you mean it: that would add your rules to the built-in `view` role of every user in the cluster.

3. Add the incident-response rights in prod only.

```bash
workstation$ kubectl -n lab-06-04-prod apply -f - <<'EOF'
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: incident-response
rules:
- apiGroups: [""]
  resources: ["pods/exec"]
  verbs: ["create", "get"]
- apiGroups: [""]
  resources: ["pods/log"]
  verbs: ["get"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: oncall-incident-response
subjects:
- kind: Group
  name: lab-06-04-oncall
  apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: Role
  name: incident-response
  apiGroup: rbac.authorization.k8s.io
EOF
```

4. Act as Dave from the on-call group. As cluster-admin you may impersonate any user and group; the API server then
   authorises the request as if Dave had sent it.

```bash
workstation$ ONC="--as=dave --as-group=lab-06-04-oncall"
workstation$ kubectl $ONC get nodes
workstation$ kubectl $ONC get pods -A | grep lab-06-04
workstation$ kubectl $ONC -n lab-06-04-prod get secrets
workstation$ kubectl $ONC -n lab-06-04-prod exec deploy/shop -- nginx -v
workstation$ kubectl $ONC -n lab-06-04-staging exec deploy/shop -- nginx -v
workstation$ kubectl $ONC -n lab-06-04-prod delete pod -l app=shop
```

Expected:
```
NAME     STATUS   ROLES           AGE   VERSION
master   Ready    control-plane   15d   v1.37.1
node1    Ready    <none>          15d   v1.37.1
node2    Ready    <none>          15d   v1.37.1
lab-06-04-prod      shop-7ffcc9fcd5-f9b4s                       1/1     Running   0             4s
lab-06-04-staging   shop-7ffcc9fcd5-df2p5                       1/1     Running   0             4s
Error from server (Forbidden): secrets is forbidden: User "dave" cannot list resource "secrets" in API group "" in the namespace "lab-06-04-prod"
nginx version: nginx/1.31.8
error: unable to upgrade connection: pods "shop-7ffcc9fcd5-df2p5" is forbidden: User "dave" cannot create resource "pods/exec" in API group "" in the namespace "lab-06-04-staging"
Error from server (Forbidden): pods "shop-7ffcc9fcd5-f9b4s" is forbidden: User "dave" cannot delete resource "pods" in API group "" in the namespace "lab-06-04-prod"
```

> Note the trade-off: `pods/exec` in prod means Dave can read every Secret that a prod Pod mounts or has in its
> environment. Exec is a powerful right; audit who has it (Lab 6.6).

5. Storage is added to the on-call scope later. Create one more building block; nobody touches the on-call role
   itself or its binding.

```bash
workstation$ kubectl $ONC get storageclass
workstation$ kubectl apply -f - <<'EOF'
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: lab-06-04-oncall-storage
  labels:
    lab-06-04/aggregate-to-oncall: "true"
rules:
- apiGroups: [""]
  resources: ["persistentvolumes"]
  verbs: ["get", "list", "watch"]
- apiGroups: ["storage.k8s.io"]
  resources: ["storageclasses"]
  verbs: ["get", "list", "watch"]
EOF
workstation$ kubectl $ONC get storageclass
workstation$ kubectl get clusterrole lab-06-04-oncall -o json | jq '.rules | length'
```

Expected:
```
Error from server (Forbidden): storageclasses.storage.k8s.io is forbidden: User "dave" cannot list resource "storageclasses" in API group "storage.k8s.io" at the cluster scope
clusterrole.rbac.authorization.k8s.io/lab-06-04-oncall-storage created
NAME       PROVISIONER        RECLAIMPOLICY   VOLUMEBINDINGMODE   ALLOWVOLUMEEXPANSION   AGE
minio-sc   ru.yandex.s3.csi   Delete          Immediate           false                  83m
16
```

### Clean up

```bash
workstation$ kubectl delete namespace lab-06-04-prod lab-06-04-staging
workstation$ kubectl delete clusterrolebinding lab-06-04-oncall
workstation$ kubectl delete clusterrole lab-06-04-oncall lab-06-04-oncall-nodes lab-06-04-oncall-storage
```

### Your turn

After the last incident, on-call engineers want two more tools **in prod only**: `kubectl rollout restart` for a
Deployment, and `kubectl debug` to attach an ephemeral `busybox` container to a running Pod (the nginx image has no
debugging tools). Extend their prod permissions with the minimum verbs, and verify as Dave that both work in prod,
that `rollout restart` is still denied in staging, and that scaling prod is still denied.

<details><summary>Solution</summary>

`rollout restart` is a `patch` of the Deployment (it sets an annotation in the Pod template). `kubectl debug`
patches the Pod's `ephemeralcontainers` subresource.

```bash
workstation$ kubectl -n lab-06-04-prod apply -f - <<'EOF'
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: incident-response
rules:
- apiGroups: [""]
  resources: ["pods/exec"]
  verbs: ["create", "get"]
- apiGroups: [""]
  resources: ["pods/log"]
  verbs: ["get"]
- apiGroups: ["apps"]
  resources: ["deployments"]
  verbs: ["patch"]                       # kubectl rollout restart
- apiGroups: [""]
  resources: ["pods/ephemeralcontainers"]
  verbs: ["patch"]                       # kubectl debug
EOF
workstation$ kubectl $ONC -n lab-06-04-prod rollout restart deploy/shop
workstation$ kubectl $ONC -n lab-06-04-prod rollout status deploy/shop
workstation$ POD=$(kubectl -n lab-06-04-prod get pod -l app=shop -o name | head -1)
workstation$ kubectl $ONC -n lab-06-04-prod debug $POD --image=busybox:1.38 --target=nginx -- sh -c 'ps | head -3'
workstation$ E=$(kubectl -n lab-06-04-prod get $POD -o jsonpath='{.spec.ephemeralContainers[0].name}')
workstation$ kubectl $ONC -n lab-06-04-prod logs $POD -c $E
workstation$ kubectl $ONC -n lab-06-04-staging rollout restart deploy/shop
workstation$ kubectl $ONC -n lab-06-04-prod scale deploy/shop --replicas=3
```

Expected:
```
deployment.apps/shop restarted
deployment "shop" successfully rolled out
Targeting container "nginx". If you don't see processes from this container it may be because the container runtime doesn't support this feature.
Defaulting debug container name to debugger-8z4rs.
PID   USER     TIME  COMMAND
    1 root      0:00 nginx: master process nginx -g daemon off;
   25 101       0:00 nginx: worker process
error: failed to patch: deployments.apps "shop" is forbidden: User "dave" cannot patch resource "deployments" in API group "apps" in the namespace "lab-06-04-staging"
Error from server (Forbidden): deployments.apps "shop" is forbidden: User "dave" cannot patch resource "deployments/scale" in API group "apps" in the namespace "lab-06-04-prod"
```

`--target=nginx` shares the process namespace of the `nginx` container (named after the image by
`kubectl create deployment`), so the debug container sees nginx's processes. Be aware that `patch` on Deployments
also allows changing the image or the replica field in the spec; RBAC cannot restrict *which* fields are patched.
If that matters, add a ValidatingAdmissionPolicy (Lab 6.10).

</details>

---

## Lab 6.5: A CI/CD deployer with short-lived tokens

**Scenario** – The CI pipeline deploys new image versions of the `web` app. Today it uses a copy of an admin
kubeconfig stored in the CI system, which never expires and can do anything. We replace it with a dedicated
ServiceAccount that can only update Deployments in one namespace, and a token that is minted per pipeline run and
expires after 15 minutes. Leaked tokens should be worthless by the time anyone finds them.

**What you'll learn**
- `kubectl create token` (TokenRequest API) with `--duration`; no Secret is created
- a minimal Role for `kubectl set image` + `kubectl rollout status`
- building a token-based kubeconfig for a CI job
- revoking tokens: deleting the ServiceAccount, the authentication cache, and why the RoleBinding still matters

### Steps

1. Create the namespace, the app, the ServiceAccount and the deployer Role. `set image` sends a `patch`, and
   `rollout status` watches the Deployment.

```bash
workstation$ kubectl create namespace lab-06-05
workstation$ kubectl -n lab-06-05 create deployment web --image=nginx:1.31-alpine
workstation$ kubectl -n lab-06-05 create serviceaccount ci-deployer
workstation$ kubectl -n lab-06-05 apply -f - <<'EOF'
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: deployer
rules:
- apiGroups: ["apps"]
  resources: ["deployments"]
  verbs: ["get", "list", "watch", "patch"]
- apiGroups: ["apps"]
  resources: ["replicasets"]
  verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: ci-deployer
subjects:
- kind: ServiceAccount
  name: ci-deployer
  namespace: lab-06-05
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: deployer
EOF
```

2. Mint a token for one pipeline run and look inside. It is signed by the API server's ServiceAccount key and is
   not stored anywhere in the cluster.

```bash
workstation$ TOKEN=$(kubectl -n lab-06-05 create token ci-deployer --duration=15m)
workstation$ echo "$TOKEN" | jq -R 'split(".")[1] | @base64d | fromjson | {aud, sub, valid_minutes: ((.exp - .iat) / 60)}'
workstation$ kubectl -n lab-06-05 get secrets
```

Expected:
```
{
  "aud": [
    "https://kubernetes.default.svc.cluster.local"
  ],
  "sub": "system:serviceaccount:lab-06-05:ci-deployer",
  "valid_minutes": 15
}
No resources found in lab-06-05 namespace.
```

3. Build the kubeconfig the CI job will use: cluster address, cluster CA and the token, nothing else.

```bash
workstation$ mkdir -p ~/lab-06-05 && cd ~/lab-06-05
workstation$ SERVER=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
workstation$ kubectl config view --minify --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' | base64 -d > ca.crt
workstation$ kubectl config --kubeconfig=ci.kubeconfig set-cluster training --server=$SERVER --certificate-authority=ca.crt --embed-certs=true
workstation$ kubectl config --kubeconfig=ci.kubeconfig set-credentials ci-deployer --token="$TOKEN"
workstation$ kubectl config --kubeconfig=ci.kubeconfig set-context ci --cluster=training --user=ci-deployer --namespace=lab-06-05
workstation$ kubectl config --kubeconfig=ci.kubeconfig use-context ci
workstation$ kubectl --kubeconfig=ci.kubeconfig auth whoami | head -2
```

Expected:
```
ATTRIBUTE                                           VALUE
Username                                            system:serviceaccount:lab-06-05:ci-deployer
```

In a real pipeline the CI system obtains the token itself, for example with its own short-lived identity
(OIDC federation) or from a vault, and writes the kubeconfig into the job's temporary workspace.

4. Run the deployment step of the pipeline.

```bash
workstation$ kubectl --kubeconfig=ci.kubeconfig set image deploy/web nginx=nginx:1.31.8-alpine
workstation$ kubectl --kubeconfig=ci.kubeconfig rollout status deploy/web --timeout=90s
workstation$ kubectl --kubeconfig=ci.kubeconfig get deploy web -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
```

Expected:
```
deployment.apps/web image updated
deployment "web" successfully rolled out
nginx:1.31.8-alpine
```

5. And everything else is denied.

```bash
workstation$ kubectl --kubeconfig=ci.kubeconfig delete deploy web
workstation$ kubectl --kubeconfig=ci.kubeconfig get secrets
workstation$ kubectl --kubeconfig=ci.kubeconfig -n default get deploy
```

Expected:
```
Error from server (Forbidden): deployments.apps "web" is forbidden: User "system:serviceaccount:lab-06-05:ci-deployer" cannot delete resource "deployments" in API group "apps" in the namespace "lab-06-05"
Error from server (Forbidden): secrets is forbidden: User "system:serviceaccount:lab-06-05:ci-deployer" cannot list resource "secrets" in API group "" in the namespace "lab-06-05"
Error from server (Forbidden): deployments.apps is forbidden: User "system:serviceaccount:lab-06-05:ci-deployer" cannot list resource "deployments" in API group "apps" in the namespace "default"
```

6. The token leaked into a build log. There is no "revoke this token" API; the emergency brake is to delete the
   ServiceAccount, which invalidates **all** its tokens (they carry the ServiceAccount's UID).

```bash
workstation$ kubectl -n lab-06-05 delete serviceaccount ci-deployer
workstation$ kubectl -n lab-06-05 create serviceaccount ci-deployer
workstation$ sleep 15; kubectl --kubeconfig=ci.kubeconfig get deploy
```

Expected:
```
serviceaccount "ci-deployer" deleted from lab-06-05 namespace
serviceaccount/ci-deployer created
error: You must be logged in to the server (Unauthorized)
```

> **Two details:** (1) Directly after the deletion the old token may work for a few more seconds, because the API
> server caches successful token authentications (about 10 s) and its view of ServiceAccounts. (2) The recreated
> ServiceAccount has the same **name**, and RoleBindings refer to names, so new tokens for it immediately have the
> deployer rights again. Deleting a compromised identity means deleting (or reviewing) its bindings, too.

### Clean up

```bash
workstation$ kubectl delete namespace lab-06-05
workstation$ rm -rf ~/lab-06-05
```

### Your turn

Deleting the ServiceAccount kills the tokens of **every** pipeline. Make tokens revocable per pipeline run: create
a Secret `ci-run-4711` that represents the run, mint a one-hour token **bound** to that Secret, put it into
`ci.kubeconfig`, and show that the token stops working when (and only when) the Secret is deleted.

<details><summary>Solution</summary>

```bash
workstation$ kubectl -n lab-06-05 create secret generic ci-run-4711 --from-literal=pipeline=shop/main#4711
workstation$ TOKEN=$(kubectl -n lab-06-05 create token ci-deployer --duration=1h \
  --bound-object-kind=Secret --bound-object-name=ci-run-4711)
workstation$ echo "$TOKEN" | jq -R 'split(".")[1] | @base64d | fromjson | .["kubernetes.io"]'
workstation$ kubectl config --kubeconfig=ci.kubeconfig set-credentials ci-deployer --token="$TOKEN"
workstation$ kubectl --kubeconfig=ci.kubeconfig get deploy web
workstation$ kubectl -n lab-06-05 delete secret ci-run-4711
workstation$ for i in 1 2 3 4 5; do echo "$(date -u +%T) $(kubectl --kubeconfig=ci.kubeconfig get deploy web -o name 2>&1)"; sleep 5; done
```

Expected (the binding is recorded in the token, and the token dies with the Secret after the ~10 s cache):
```
{
  "namespace": "lab-06-05",
  "secret": {
    "name": "ci-run-4711",
    "uid": "bd51c002-76f3-4419-afaf-7d2ffe2c6756"
  },
  "serviceaccount": {
    "name": "ci-deployer",
    "uid": "b4e151a6-f1c4-47ed-b228-8262211d7092"
  }
}
NAME   READY   UP-TO-DATE   AVAILABLE   AGE
web    1/1     1            1           26s
secret "ci-run-4711" deleted from lab-06-05 namespace
03:45:16 deployment.apps/web
03:45:21 deployment.apps/web
03:45:26 error: You must be logged in to the server (Unauthorized)
03:45:31 error: You must be logged in to the server (Unauthorized)
03:45:36 error: You must be logged in to the server (Unauthorized)
```

Bound tokens can reference a Secret, a Pod or a Node. Pods get Pod-bound tokens automatically (Lab 5.8); for
external systems a Secret per run (deleted by the pipeline's last step, or by a TTL controller) gives you a revocation
handle without long-lived credentials.

</details>

---

## Lab 6.6: Auditing RBAC and privilege-escalation pitfalls

**Scenario** – Before an external penetration test, you review the RBAC setup of the payments namespace. On paper
the CI bot "cannot read Secrets" and the team lead "only manages RoleBindings". We check what these identities can
really do, from the API's point of view and through side doors: Pods that mount Secrets, Pods that run as a more
privileged ServiceAccount, and RoleBindings that hand out more than their creator has.

**What you'll learn**
- `kubectl auth can-i --list`, `kubectl auth whoami` and impersonation (`--as`) for audits
- why `create pods` implies reading every Secret and using every ServiceAccount of the namespace
- RBAC's built-in escalation prevention, and the `bind` / `escalate` verbs that switch it off
- a pitfall in `kubectl auth can-i` with subresources

### Steps

1. Create the namespace, a Secret, a CI bot that may run Pods and a sync job's ServiceAccount that may read Secrets.

```bash
workstation$ kubectl create namespace lab-06-06
workstation$ kubectl -n lab-06-06 create secret generic payment-api-key --from-literal=key=sk_live_51HxTOPSECRET
workstation$ kubectl -n lab-06-06 apply -f - <<'EOF'
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ci-bot
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: secret-sync
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: pod-runner
rules:
- apiGroups: [""]
  resources: ["pods"]
  verbs: ["create", "get", "list", "delete"]
- apiGroups: [""]
  resources: ["pods/log"]
  verbs: ["get"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: ci-bot-pod-runner
subjects:
- {kind: ServiceAccount, name: ci-bot, namespace: lab-06-06}
roleRef: {apiGroup: rbac.authorization.k8s.io, kind: Role, name: pod-runner}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: secret-reader
rules:
- apiGroups: [""]
  resources: ["secrets"]
  verbs: ["get", "list"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: secret-sync-reader
subjects:
- {kind: ServiceAccount, name: secret-sync, namespace: lab-06-06}
roleRef: {apiGroup: rbac.authorization.k8s.io, kind: Role, name: secret-reader}
EOF
```

2. Audit the CI bot the official way.

```bash
workstation$ BOT="--as=system:serviceaccount:lab-06-06:ci-bot"
workstation$ kubectl -n lab-06-06 auth can-i --list $BOT | grep -E 'Resources|^pods'
workstation$ kubectl -n lab-06-06 auth can-i get secrets $BOT
workstation$ kubectl -n lab-06-06 get secret payment-api-key $BOT
```

Expected:
```
Resources                                       Non-Resource URLs                      Resource Names   Verbs
pods                                            []                                     []               [create get list delete]
pods/log                                        []                                     []               [get]
no
Error from server (Forbidden): secrets "payment-api-key" is forbidden: User "system:serviceaccount:lab-06-06:ci-bot" cannot get resource "secrets" in API group "" in the namespace "lab-06-06"
```

3. Side door 1: the bot creates a Pod that mounts the Secret and prints it. The kubelet, not the bot, reads the
   Secret, and RBAC never asks whether the Pod's creator may see it.

```bash
workstation$ kubectl -n lab-06-06 run leak $BOT --image=busybox:1.38 --restart=Never \
  --overrides='{"spec":{"containers":[{"name":"leak","image":"busybox:1.38","command":["cat","/s/key"],"volumeMounts":[{"name":"s","mountPath":"/s"}]}],"volumes":[{"name":"s","secret":{"secretName":"payment-api-key"}}]}}'
workstation$ sleep 8; kubectl -n lab-06-06 logs leak $BOT; echo
```

Expected:
```
pod/leak created
sk_live_51HxTOPSECRET
```

4. Side door 2: the bot runs a Pod **as** `secret-sync` and uses that ServiceAccount's token from inside.

```bash
workstation$ kubectl -n lab-06-06 run borrow $BOT --image=alpine/k8s:1.37.1 --restart=Never \
  --overrides='{"spec":{"serviceAccountName":"secret-sync","containers":[{"name":"borrow","image":"alpine/k8s:1.37.1","command":["kubectl","get","secrets","-o","name"]}]}}'
workstation$ sleep 10; kubectl -n lab-06-06 logs borrow $BOT
```

Expected:
```
pod/borrow created
secret/payment-api-key
```

> **Rule:** `create` on Pods (or on anything that creates Pods: Deployments, Jobs, CronJobs, ...) in a namespace is
> equivalent to reading every Secret, ConfigMap and ServiceAccount token in that namespace. Keep high-value Secrets in
> namespaces where untrusted identities cannot create workloads. Admission policies (Pod Security, Lab 6.7; VAP,
> Lab 6.10) can restrict *which* Pods they create.

5. Now the team lead, Frank. He may view the namespace and manage RoleBindings.

```bash
workstation$ kubectl -n lab-06-06 apply -f - <<'EOF'
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: team-lead
rules:
- apiGroups: ["rbac.authorization.k8s.io"]
  resources: ["rolebindings"]
  verbs: ["create", "get", "list", "delete"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: frank-team-lead
subjects:
- {kind: User, name: frank, apiGroup: rbac.authorization.k8s.io}
roleRef: {apiGroup: rbac.authorization.k8s.io, kind: Role, name: team-lead}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: frank-view
subjects:
- {kind: User, name: frank, apiGroup: rbac.authorization.k8s.io}
roleRef: {apiGroup: rbac.authorization.k8s.io, kind: ClusterRole, name: view}
EOF
workstation$ kubectl -n lab-06-06 auth whoami --as=frank
workstation$ kubectl -n lab-06-06 create rolebinding newbie-view --clusterrole=view --user=newbie --as=frank
workstation$ kubectl -n lab-06-06 create rolebinding frank-admin --clusterrole=admin --user=frank --as=frank
```

Expected (Frank may hand out `view`, which he holds himself, but not `admin`):
```
ATTRIBUTE   VALUE
Username    frank
Groups      [system:authenticated]
rolebinding.rbac.authorization.k8s.io/newbie-view created
error: failed to create rolebinding: rolebindings.rbac.authorization.k8s.io "frank-admin" is forbidden: user "frank" (groups=["system:authenticated"]) is attempting to grant RBAC permissions not currently held:
{APIGroups:[""], Resources:["configmaps"], Verbs:["create" "delete" "deletecollection" "patch" "update"]}
...
{APIGroups:[""], Resources:["secrets"], Verbs:["get" "list" "watch" "create" "delete" "deletecollection" "patch" "update"]}
...
```

This is RBAC's escalation prevention: you can only create a binding (or a Role) if you already hold every
permission in it.

6. Someone wants Frank to on-board developers with `edit`, and gives him the `bind` verb for that one ClusterRole.

```bash
workstation$ kubectl -n lab-06-06 apply -f - <<'EOF'
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: may-bind-edit
rules:
- apiGroups: ["rbac.authorization.k8s.io"]
  resources: ["clusterroles"]
  resourceNames: ["edit"]
  verbs: ["bind"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: frank-may-bind-edit
subjects:
- {kind: User, name: frank, apiGroup: rbac.authorization.k8s.io}
roleRef: {apiGroup: rbac.authorization.k8s.io, kind: Role, name: may-bind-edit}
EOF
workstation$ kubectl -n lab-06-06 create rolebinding newbie-edit --clusterrole=edit --user=newbie --as=frank
workstation$ kubectl -n lab-06-06 auth can-i get secrets --as=newbie
workstation$ kubectl -n lab-06-06 auth can-i get secrets --as=frank
```

Expected:
```
rolebinding.rbac.authorization.k8s.io/newbie-edit created
yes
no
```

Frank cannot read Secrets, but he can now make *anyone*, including a second account of his own, able to read them.
`bind` (for bindings) and `escalate` (for editing Roles) are exactly as powerful as the roles they name; grant them
with `resourceNames` and treat them like the permissions themselves.

### Clean up

```bash
workstation$ kubectl delete namespace lab-06-06
```

### Your turn

The pen-testers will ask "who can get at the payment Secret in `lab-06-06`?". Write a small audit that prints one
line per ServiceAccount of the namespace and per user that appears in its RoleBindings, with four answers: may get
Secrets directly, may create Pods (side door), may exec into Pods (reads mounted Secrets and env), may create
RoleBindings. Hint: check your exec column against the bot's Role; `kubectl auth can-i create pods/exec` is not what
it looks like.

<details><summary>Solution</summary>

`kubectl auth can-i VERB TYPE/NAME` treats `pods/exec` as "the Pod named exec". Subresources need `--subresource`:

```bash
workstation$ kubectl -n lab-06-06 auth can-i create pods/exec --as=system:serviceaccount:lab-06-06:ci-bot
workstation$ kubectl -n lab-06-06 auth can-i create pods --subresource=exec --as=system:serviceaccount:lab-06-06:ci-bot
```

Expected (the first answer is about creating a Pod named `exec`):
```
yes
no
```

The audit:

```bash
workstation$ audit() {   # audit <subject for --as>
  printf '%-45s secrets=%-3s pods=%-3s exec=%-3s rolebindings=%s\n' "$1" \
    "$(kubectl -n lab-06-06 auth can-i get secrets --as=$1)" \
    "$(kubectl -n lab-06-06 auth can-i create pods --as=$1)" \
    "$(kubectl -n lab-06-06 auth can-i create pods --subresource=exec --as=$1)" \
    "$(kubectl -n lab-06-06 auth can-i create rolebindings --as=$1)"
}
workstation$ for sa in $(kubectl -n lab-06-06 get sa -o jsonpath='{.items[*].metadata.name}'); do
  audit system:serviceaccount:lab-06-06:$sa
done
workstation$ for u in $(kubectl -n lab-06-06 get rolebindings -o json | jq -r '[.items[].subjects[]? | select(.kind=="User") | .name] | unique | .[]'); do
  audit $u
done
```

Expected:
```
system:serviceaccount:lab-06-06:ci-bot        secrets=no  pods=yes exec=no  rolebindings=no
system:serviceaccount:lab-06-06:default       secrets=no  pods=no  exec=no  rolebindings=no
system:serviceaccount:lab-06-06:secret-sync   secrets=yes pods=no  exec=no  rolebindings=no
frank                                         secrets=no  pods=no  exec=no  rolebindings=yes
newbie                                        secrets=yes pods=yes exec=yes rolebindings=no
```

Reading it: `secret-sync` and `newbie` read the Secret directly, `ci-bot` indirectly through Pods, and `frank`
indirectly through bindings. Only `default` is clean. The audit only covers subjects you know about; users and
groups bound by ClusterRoleBindings (and the members of groups) need the same check, and tools such as
`kubectl-who-can` or `rakkess` automate it.

</details>

---

## Lab 6.7: Pod Security Admission for a namespace migration

**Scenario** – The shop namespace must eventually meet the Pod Security **restricted** standard, but today it runs
legacy workloads that would break if you switched it on overnight. We use Pod Security Admission's three modes the way
they are meant to be used in a migration: **enforce** the `baseline` level now (no privileged containers, no host
access), **warn** and **audit** against `restricted` to see what still has to change, test the switch with a
server-side dry run, and only then enforce `restricted`.

**What you'll learn**
- the namespace labels `pod-security.kubernetes.io/<mode>[-version]` for `enforce`, `warn` and `audit`
- what `baseline` blocks (privileged, host namespaces, hostPath, ...) and what `restricted` additionally requires
- why a Deployment can be "created" although none of its Pods can be
- `kubectl label --dry-run=server` to check existing Pods against a new level

### Steps

1. Create the namespace with the migration labels. Pin the enforced version, so that a cluster upgrade does not
   suddenly tighten the rules.

```bash
workstation$ kubectl create namespace lab-06-07
workstation$ kubectl label namespace lab-06-07 \
  pod-security.kubernetes.io/enforce=baseline pod-security.kubernetes.io/enforce-version=v1.37 \
  pod-security.kubernetes.io/warn=restricted pod-security.kubernetes.io/audit=restricted
workstation$ kubectl get namespace lab-06-07 --show-labels
```

Expected:
```
NAME        STATUS   AGE   LABELS
lab-06-07   Active   0s    kubernetes.io/metadata.name=lab-06-07,pod-security.kubernetes.io/audit=restricted,pod-security.kubernetes.io/enforce-version=v1.37,pod-security.kubernetes.io/enforce=baseline,pod-security.kubernetes.io/warn=restricted
```

2. Deploy the legacy app (stock nginx, runs as root). `baseline` allows it, `restricted` would not, so you get a
   warning and the Deployment runs.

```bash
workstation$ kubectl -n lab-06-07 create deployment legacy --image=nginx:1.31-alpine
workstation$ kubectl -n lab-06-07 rollout status deploy/legacy
```

Expected:
```
deployment.apps/legacy created
Warning: would violate PodSecurity "restricted:latest": allowPrivilegeEscalation != false (container "nginx" must set securityContext.allowPrivilegeEscalation=false), unrestricted capabilities (container "nginx" must set securityContext.capabilities.drop=["ALL"]), runAsNonRoot != true (pod or container "nginx" must set securityContext.runAsNonRoot=true), seccompProfile (pod or container "nginx" must set securityContext.seccompProfile.type to "RuntimeDefault" or "Localhost")
deployment "legacy" successfully rolled out
```

The warning is a to-do list. The `audit` mode writes the same findings into the API server audit log (if auditing
is configured), which is how you find violations from CI systems that nobody watches.

3. Things that `baseline` blocks: a privileged container, and a Pod that uses the host network and mounts the node's
   root filesystem.

```bash
workstation$ kubectl -n lab-06-07 run root-shell --image=busybox:1.38 \
  --overrides='{"spec":{"containers":[{"name":"root-shell","image":"busybox:1.38","command":["sleep","infinity"],"securityContext":{"privileged":true}}]}}'
workstation$ kubectl -n lab-06-07 run node-disk --image=busybox:1.38 \
  --overrides='{"spec":{"hostNetwork":true,"containers":[{"name":"node-disk","image":"busybox:1.38","command":["sleep","infinity"],"volumeMounts":[{"name":"root","mountPath":"/host"}]}],"volumes":[{"name":"root","hostPath":{"path":"/"}}]}}'
```

Expected:
```
Error from server (Forbidden): pods "root-shell" is forbidden: violates PodSecurity "baseline:v1.37": privileged (container "root-shell" must not set securityContext.privileged=true)
Error from server (Forbidden): pods "node-disk" is forbidden: violates PodSecurity "baseline:v1.37": host namespaces (hostNetwork=true), hostPath volumes (volume "root")
```

4. A trap for the unwary: Pod Security checks **Pods**. A Deployment with a forbidden Pod template is accepted (with a
   warning only), and the failure shows up later in the ReplicaSet's events.

```bash
workstation$ kubectl -n lab-06-07 apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: node-exporter-ish
spec:
  selector:
    matchLabels: {app: nx}
  template:
    metadata:
      labels: {app: nx}
    spec:
      hostPID: true
      containers:
      - name: c
        image: busybox:1.38
        command: ["sleep", "infinity"]
EOF
workstation$ kubectl -n lab-06-07 get deploy node-exporter-ish
workstation$ kubectl -n lab-06-07 get events --field-selector reason=FailedCreate | tail -1
```

Expected:
```
Warning: would violate PodSecurity "restricted:latest": host namespaces (hostPID=true), ...
deployment.apps/node-exporter-ish created
NAME                READY   UP-TO-DATE   AVAILABLE   AGE
node-exporter-ish   0/1     0            0           3s
Warning   FailedCreate   replicaset/node-exporter-ish-868cb78fcd   (combined from similar events): Error creating: pods "node-exporter-ish-868cb78fcd-gf8xn" is forbidden: violates PodSecurity "baseline:v1.37": host namespaces (hostPID=true)
```

If a Deployment shows `0/1` and no Pods at all, check `kubectl get events` for `FailedCreate` before anything else.

```bash
workstation$ kubectl -n lab-06-07 delete deployment node-exporter-ish
```

5. Would switching `enforce` to `restricted` today break something? Ask the API server without changing anything:

```bash
workstation$ kubectl label --dry-run=server --overwrite namespace lab-06-07 pod-security.kubernetes.io/enforce=restricted
```

Expected:
```
namespace/lab-06-07 labeled (server dry run)
Warning: existing pods in namespace "lab-06-07" violate the new PodSecurity enforce level "restricted:v1.37"
Warning: legacy-cf8557d9d-tnqcn: allowPrivilegeEscalation != false, unrestricted capabilities, runAsNonRoot != true, seccompProfile
```

Existing Pods are never evicted by a label change, but after the switch their replacements (a rollout, a node
drain) would be rejected.

### Clean up

```bash
workstation$ kubectl delete namespace lab-06-07
```

### Your turn

Finish the migration: change the `legacy` Deployment so that it complies with `restricted` (hint: there is an
unprivileged variant of the nginx image that listens on port 8080), confirm with a server-side dry run that nothing
violates `restricted` any more, switch `enforce` to `restricted`, check that the app still serves its start page,
and see what happens to a quick `kubectl run` test Pod afterwards.

<details><summary>Solution</summary>

```bash
workstation$ kubectl -n lab-06-07 apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: legacy
spec:
  selector:
    matchLabels: {app: legacy}
  template:
    metadata:
      labels: {app: legacy}
    spec:
      securityContext:
        runAsNonRoot: true
        seccompProfile: {type: RuntimeDefault}
      containers:
      - name: nginx
        image: nginxinc/nginx-unprivileged:1.31-alpine    # runs as UID 101, listens on 8080
        ports:
        - containerPort: 8080
        securityContext:
          allowPrivilegeEscalation: false
          capabilities: {drop: ["ALL"]}
EOF
workstation$ kubectl -n lab-06-07 rollout status deploy/legacy
workstation$ kubectl -n lab-06-07 get pods                # wait until the old Pod is gone
workstation$ kubectl label --dry-run=server --overwrite namespace lab-06-07 pod-security.kubernetes.io/enforce=restricted
workstation$ kubectl label --overwrite namespace lab-06-07 pod-security.kubernetes.io/enforce=restricted
workstation$ kubectl -n lab-06-07 exec deploy/legacy -- sh -c 'id; wget -qO- 127.0.0.1:8080 | grep -o "<title>.*</title>"'
workstation$ kubectl -n lab-06-07 run quick-test --image=busybox:1.38 -- sleep 1
```

Expected (no warnings from the dry run once only the new Pod exists):
```
deployment "legacy" successfully rolled out
namespace/lab-06-07 labeled (server dry run)
namespace/lab-06-07 labeled
uid=101(nginx) gid=101(nginx) groups=101(nginx)
<title>Welcome to nginx!</title>
Error from server (Forbidden): pods "quick-test" is forbidden: violates PodSecurity "restricted:v1.37": allowPrivilegeEscalation != false (container "quick-test" must set securityContext.allowPrivilegeEscalation=false), unrestricted capabilities (container "quick-test" must set securityContext.capabilities.drop=["ALL"]), runAsNonRoot != true (pod or container "quick-test" must set securityContext.runAsNonRoot=true), seccompProfile (pod or container "quick-test" must set securityContext.seccompProfile.type to "RuntimeDefault" or "Localhost")
```

If you run the dry run while the old root Pod is still terminating, it is still listed as a violation. Use
`127.0.0.1`, not `localhost`: busybox `wget` tries IPv6 `::1` first, and this nginx only listens on IPv4. Under
`restricted`, ad-hoc debugging Pods need a compliant `securityContext` too; that friction is intended.

</details>

---

## Lab 6.8: Hardening a web server with securityContext

**Scenario** – A pen test found a remote-code-execution bug in a plugin of the shop's web frontend. Inside the
container the attacker was root, could rewrite the web pages and had a ServiceAccount token. The bug will be fixed,
but the next one is coming, so we make the container a poor place for an attacker: no root, no capabilities, no
privilege escalation, a read-only filesystem, the default seccomp profile, and no API token.

**What you'll learn**
- inspecting what a container may do: `id`, `CapEff`, `NoNewPrivs`, `Seccomp` in `/proc/1/status`
- `runAsNonRoot`/`runAsUser`, `allowPrivilegeEscalation: false`, `capabilities.drop: ["ALL"]`,
  `seccompProfile: RuntimeDefault`, `readOnlyRootFilesystem: true`
- giving a read-only container exactly the writable paths it needs (`emptyDir` on `/tmp`)
- how these settings map to the Pod Security `restricted` level

### Steps

1. Run the frontend the way most tutorials do, and look at it through an attacker's eyes.

```bash
workstation$ kubectl create namespace lab-06-08
workstation$ kubectl label namespace lab-06-08 pod-security.kubernetes.io/warn=restricted
workstation$ kubectl -n lab-06-08 create deployment web-default --image=nginx:1.31-alpine
workstation$ kubectl -n lab-06-08 rollout status deploy/web-default
workstation$ kubectl -n lab-06-08 exec deploy/web-default -- sh -c '
  id
  grep -E "^(CapEff|NoNewPrivs|Seccomp):" /proc/1/status
  echo "<h1>hacked</h1>" > /usr/share/nginx/html/index.html && echo defaced
  ls /var/run/secrets/kubernetes.io/serviceaccount'
```

Expected:
```
uid=0(root) gid=0(root) groups=0(root),1(bin),2(daemon),3(sys),4(adm),6(disk),10(wheel),11(floppy),20(dialout),26(tape),27(video)
CapEff:	00000000000005fb
NoNewPrivs:	0
Seccomp:	0
defaced
ca.crt
namespace
token
```

Root, nine Linux capabilities (`0x5fb`: `CHOWN`, `DAC_OVERRIDE`, `FOWNER`, `SETUID`, `SETGID`, `KILL`, ...), no
seccomp filter (`0` = unconfined, the kubelet default), setuid binaries would work (`NoNewPrivs: 0`), the site can be
defaced, and there is an API token to steal.

2. Harden it. The unprivileged nginx image runs as UID 101 and listens on 8080, so it needs no capabilities.

```bash
workstation$ kubectl -n lab-06-08 apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web-hardened
spec:
  selector:
    matchLabels: {app: web-hardened}
  template:
    metadata:
      labels: {app: web-hardened}
    spec:
      automountServiceAccountToken: false
      securityContext:
        runAsNonRoot: true
        runAsUser: 101
        runAsGroup: 101
        seccompProfile: {type: RuntimeDefault}
      containers:
      - name: nginx
        image: nginxinc/nginx-unprivileged:1.31-alpine
        ports:
        - containerPort: 8080
        securityContext:
          readOnlyRootFilesystem: true
          allowPrivilegeEscalation: false
          capabilities: {drop: ["ALL"]}
EOF
workstation$ kubectl -n lab-06-08 get pods -l app=web-hardened        # after ~15 s
workstation$ kubectl -n lab-06-08 logs deploy/web-hardened | grep emerg
```

Expected:
```
NAME                           READY   STATUS   RESTARTS      AGE
web-hardened-bbc86cd76-dgbk2   0/1     Error    2 (14s ago)   15s
nginx: [emerg] mkdir() "/tmp/proxy_temp" failed (30: Read-only file system)
```

> **Why:** a read-only root filesystem breaks every program that writes somewhere "harmless": PID files, caches,
> temp files, `/var/run`. Read the error, then give the app exactly those paths as `emptyDir` volumes.

3. Add a writable `/tmp` and nothing else.

```bash
workstation$ kubectl -n lab-06-08 patch deployment web-hardened --type=strategic -p '
spec:
  template:
    spec:
      containers:
      - name: nginx
        volumeMounts:
        - {name: tmp, mountPath: /tmp}          # pid file and temp dirs; the only writable path
      volumes:
      - name: tmp
        emptyDir: {sizeLimit: 64Mi}'
workstation$ kubectl -n lab-06-08 rollout status deploy/web-hardened
```

4. Repeat the attacker's checks.

```bash
workstation$ kubectl -n lab-06-08 exec deploy/web-hardened -- sh -c '
  id
  grep -E "^(CapEff|NoNewPrivs|Seccomp):" /proc/1/status
  echo "<h1>hacked</h1>" > /usr/share/nginx/html/index.html
  touch /etc/x
  ls /tmp
  wget -qO- 127.0.0.1:8080 | grep -o "<title>.*</title>"
  ls /var/run/secrets/kubernetes.io/serviceaccount'
```

Expected:
```
uid=101(nginx) gid=101(nginx) groups=101(nginx)
CapEff:	0000000000000000
NoNewPrivs:	1
Seccomp:	2
sh: can't create /usr/share/nginx/html/index.html: Read-only file system
touch: /etc/x: Read-only file system
client_temp
fastcgi_temp
nginx.pid
proxy_temp
scgi_temp
uwsgi_temp
<title>Welcome to nginx!</title>
ls: /var/run/secrets/kubernetes.io/serviceaccount: No such file or directory
```

No capabilities, `NoNewPrivs` set, seccomp in filter mode (`2`), nothing writable except `/tmp`, no token, and the
site still works. An attacker can still run code as UID 101 inside the container, but has far fewer ways to persist,
escalate or move on. (`127.0.0.1` instead of `localhost`: busybox `wget` tries IPv6 first, and this nginx listens on
IPv4 only.)

5. These settings are exactly what the `restricted` Pod Security level demands (plus `readOnlyRootFilesystem`, which
   it does not require). Check with a dry run: only the default Deployment is reported.

```bash
workstation$ kubectl label --dry-run=server --overwrite namespace lab-06-08 pod-security.kubernetes.io/enforce=restricted
```

Expected:
```
namespace/lab-06-08 labeled (server dry run)
Warning: existing pods in namespace "lab-06-08" violate the new PodSecurity enforce level "restricted:latest"
Warning: web-default-64489b947f-btds5: allowPrivilegeEscalation != false, unrestricted capabilities, runAsNonRoot != true, seccompProfile
```

### Clean up

```bash
workstation$ kubectl delete namespace lab-06-08
```

### Your turn

The shop also runs a Redis cache (`redis:8.8`, with `--appendonly yes`). Delete `web-default`, switch the namespace
to **enforce** `restricted`, and deploy Redis as `cache` with the same hardening: non-root (the image's `redis` user
is UID 999), read-only root filesystem, no capabilities, `RuntimeDefault` seccomp, no token. Find out which path it
must be able to write to, and prove that `SET`/`GET` work and that the root filesystem is read-only.

<details><summary>Solution</summary>

Redis writes its append-only file to its working directory `/data`. With `fsGroup` the `emptyDir` is group-owned
by 999 (Lab 4.9).

```bash
workstation$ kubectl -n lab-06-08 delete deployment web-default
workstation$ kubectl label --overwrite namespace lab-06-08 pod-security.kubernetes.io/enforce=restricted
workstation$ kubectl -n lab-06-08 apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: cache
spec:
  selector:
    matchLabels: {app: cache}
  template:
    metadata:
      labels: {app: cache}
    spec:
      automountServiceAccountToken: false
      securityContext:
        runAsNonRoot: true
        runAsUser: 999                  # the "redis" user of the official image
        runAsGroup: 999
        fsGroup: 999
        seccompProfile: {type: RuntimeDefault}
      containers:
      - name: redis
        image: redis:8.8
        args: ["--appendonly", "yes"]
        securityContext:
          readOnlyRootFilesystem: true
          allowPrivilegeEscalation: false
          capabilities: {drop: ["ALL"]}
        volumeMounts:
        - {name: data, mountPath: /data}
      volumes:
      - name: data
        emptyDir: {}
EOF
workstation$ kubectl -n lab-06-08 rollout status deploy/cache
workstation$ kubectl -n lab-06-08 exec deploy/cache -- sh -c 'id; redis-cli SET basket:42 "3 items"; redis-cli GET basket:42; ls -ln /data; touch /etc/x'
```

Expected (admitted under `restricted` without warnings):
```
deployment.apps/cache created
deployment "cache" successfully rolled out
uid=999(redis) gid=999(redis) groups=999(redis)
OK
3 items
drwx--S--- 2 999 999 4096 Nov  4 03:50 appendonlydir
touch: cannot touch '/etc/x': Read-only file system
```

Setting `runAsUser` explicitly matters for images whose entrypoint normally starts as root and drops privileges
itself (the official Redis and Postgres images do that with `gosu`): with `runAsNonRoot` alone, the kubelet would
refuse to start the container, because the image's default user is root.

</details>

---

## Lab 6.9: Tenant namespaces with ResourceQuota and LimitRange

**Scenario** – The platform team hosts small customer shops, one namespace per tenant, on a shared cluster. A
runaway tenant must not starve the others, nobody may grab one of the few MetalLB addresses, and tenants who forget to
set resource requests should still get sensible values. We give tenant `acme` a budget (ResourceQuota) and
defaults plus per-container bounds (LimitRange), then watch both say "no".

**What you'll learn**
- ResourceQuota for compute (`requests.*`, `limits.*`), object counts (`pods`) and Service types
- LimitRange `defaultRequest`/`default` (injected) and `min`/`max` (enforced) per container
- how quota failures surface in Deployments (`FailedCreate` on the ReplicaSet)
- why a quota on CPU/memory without a LimitRange breaks naive deployments

### Steps

1. Create the tenant namespace with its budget and defaults.

```bash
workstation$ kubectl create namespace lab-06-09-acme
workstation$ kubectl -n lab-06-09-acme apply -f - <<'EOF'
apiVersion: v1
kind: ResourceQuota
metadata:
  name: tenant-budget
spec:
  hard:
    requests.cpu: "1"
    requests.memory: 1Gi
    limits.cpu: "2"
    limits.memory: 2Gi
    pods: "6"
    services.loadbalancers: "0"         # no external IPs for this tenant
    services.nodeports: "0"
    persistentvolumeclaims: "2"
---
apiVersion: v1
kind: LimitRange
metadata:
  name: tenant-defaults
spec:
  limits:
  - type: Container
    defaultRequest: {cpu: 100m, memory: 128Mi}   # used when a container sets no requests
    default:        {cpu: 250m, memory: 256Mi}   # used when a container sets no limits
    max:            {cpu: "1", memory: 1Gi}
    min:            {cpu: 10m, memory: 16Mi}
EOF
workstation$ kubectl -n lab-06-09-acme describe quota tenant-budget
```

Expected:
```
Name:                   tenant-budget
Namespace:              lab-06-09-acme
Resource                Used  Hard
--------                ----  ----
limits.cpu              0     2
limits.memory           0     2Gi
persistentvolumeclaims  0     2
pods                    0     6
requests.cpu            0     1
requests.memory         0     1Gi
services.loadbalancers  0     0
services.nodeports      0     0
```

2. The tenant deploys without thinking about resources. The LimitRange admission plugin fills in the defaults.

```bash
workstation$ kubectl -n lab-06-09-acme create deployment shop --image=traefik/whoami:v1.12.0
workstation$ kubectl -n lab-06-09-acme rollout status deploy/shop
workstation$ kubectl -n lab-06-09-acme get pod -l app=shop -o jsonpath='{.items[0].spec.containers[0].resources}{"\n"}'
```

Expected:
```
{"limits":{"cpu":"250m","memory":"256Mi"},"requests":{"cpu":"100m","memory":"128Mi"}}
```

3. A single container may not exceed `max`, regardless of the remaining budget.

```bash
workstation$ kubectl -n lab-06-09-acme run greedy --image=busybox:1.38 --restart=Never \
  --overrides='{"spec":{"containers":[{"name":"greedy","image":"busybox:1.38","command":["sleep","3600"],"resources":{"limits":{"cpu":"2","memory":"4Gi"}}}]}}'
```

Expected:
```
Error from server (Forbidden): pods "greedy" is forbidden: [maximum cpu usage per Container is 1, but limit is 2, maximum memory usage per Container is 1Gi, but limit is 4Gi]
```

4. Black Friday: the tenant scales to 8 replicas. The quota allows 6 Pods.

```bash
workstation$ kubectl -n lab-06-09-acme scale deploy shop --replicas=8
workstation$ kubectl -n lab-06-09-acme get deploy shop
workstation$ kubectl -n lab-06-09-acme get events --field-selector reason=FailedCreate | tail -1
workstation$ kubectl -n lab-06-09-acme describe quota tenant-budget | sed -n '/Resource/,$p'
```

Expected:
```
deployment.apps/shop scaled
NAME   READY   UP-TO-DATE   AVAILABLE   AGE
shop   6/8     6            6           9s
Warning   FailedCreate   replicaset/shop-55975d5855   (combined from similar events): Error creating: pods "shop-55975d5855-cfpq4" is forbidden: exceeded quota: tenant-budget, requested: pods=1, used: pods=6, limited: pods=6
Resource                Used    Hard
--------                ----    ----
limits.cpu              1500m   2
limits.memory           1536Mi  2Gi
persistentvolumeclaims  0       2
pods                    6       6
requests.cpu            600m    1
requests.memory         768Mi   1Gi
services.loadbalancers  0       0
services.nodeports      0       0
```

The `scale` command succeeds; the API server rejects the *Pods*, and only the ReplicaSet's events tell you why. The
same applies to HPA scale-ups: a quota silently caps autoscaling.

5. Services are counted, too. The tenant cannot take a MetalLB address or open a NodePort, but a ClusterIP is fine.

```bash
workstation$ kubectl -n lab-06-09-acme expose deploy shop --type=LoadBalancer --port=80
workstation$ kubectl -n lab-06-09-acme expose deploy shop --type=NodePort --port=80
workstation$ kubectl -n lab-06-09-acme expose deploy shop --port=80
```

Expected:
```
Error from server (Forbidden): services "shop" is forbidden: exceeded quota: tenant-budget, requested: services.loadbalancers=1,services.nodeports=1, used: services.loadbalancers=0,services.nodeports=0, limited: services.loadbalancers=0,services.nodeports=0
Error from server (Forbidden): services "shop" is forbidden: exceeded quota: tenant-budget, requested: services.nodeports=1, used: services.nodeports=0, limited: services.nodeports=0
service/shop exposed
```

A LoadBalancer Service also allocates a NodePort, which is why it counts against both.

### Clean up

```bash
workstation$ kubectl delete namespace lab-06-09-acme
```

### Your turn

On-board a second tenant, `lab-06-09-globex`, with the same compute budget but **only the ResourceQuota** (someone
forgot the LimitRange). Additionally, globex may use at most 2Gi of storage in total and at most 2 claims of the S3
StorageClass `minio-sc`. Deploy `shop` as before and explain what you see; fix it without changing the Deployment.
Then create two `minio-sc` claims of 1Gi and 2Gi.

<details><summary>Solution</summary>

Storage quotas can be global (`requests.storage`) and per StorageClass
(`<class>.storageclass.storage.k8s.io/...`).

```bash
workstation$ kubectl create namespace lab-06-09-globex
workstation$ kubectl -n lab-06-09-globex apply -f - <<'EOF'
apiVersion: v1
kind: ResourceQuota
metadata:
  name: tenant-budget
spec:
  hard:
    requests.cpu: "1"
    requests.memory: 1Gi
    limits.cpu: "2"
    limits.memory: 2Gi
    pods: "6"
    services.loadbalancers: "0"
    services.nodeports: "0"
    requests.storage: 2Gi                                        # all classes together
    minio-sc.storageclass.storage.k8s.io/requests.storage: 2Gi   # S3 volumes
    minio-sc.storageclass.storage.k8s.io/persistentvolumeclaims: "2"
EOF
workstation$ kubectl -n lab-06-09-globex create deployment shop --image=traefik/whoami:v1.12.0
workstation$ kubectl -n lab-06-09-globex get deploy shop
workstation$ kubectl -n lab-06-09-globex get events --field-selector reason=FailedCreate | tail -1
```

Expected:
```
NAME   READY   UP-TO-DATE   AVAILABLE   AGE
shop   0/1     0            0           5s
Warning   FailedCreate   replicaset/shop-55975d5855   (combined from similar events): Error creating: pods "shop-55975d5855-t2qbj" is forbidden: failed quota: tenant-budget: must specify limits.cpu for: whoami; limits.memory for: whoami; requests.cpu for: whoami; requests.memory for: whoami
```

Once a quota tracks `requests.cpu` (or `limits.*`), every Pod must declare those values, otherwise the quota could not
account for it. Apply the `tenant-defaults` LimitRange from step 1 to this namespace, and the Pods get defaults:

```bash
workstation$ kubectl -n lab-06-09-globex apply -f - <<'EOF'
apiVersion: v1
kind: LimitRange
metadata:
  name: tenant-defaults
spec:
  limits:
  - type: Container
    defaultRequest: {cpu: 100m, memory: 128Mi}
    default:        {cpu: 250m, memory: 256Mi}
    max:            {cpu: "1", memory: 1Gi}
    min:            {cpu: 10m, memory: 16Mi}
EOF
workstation$ kubectl -n lab-06-09-globex rollout restart deploy shop
workstation$ kubectl -n lab-06-09-globex get deploy shop
```

Expected:
```
NAME   READY   UP-TO-DATE   AVAILABLE   AGE
shop   1/1     1            1           20s
```

Now the storage:

```bash
workstation$ kubectl -n lab-06-09-globex apply -f - <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: uploads
spec:
  storageClassName: minio-sc
  accessModes: [ReadWriteMany]
  resources:
    requests: {storage: 1Gi}
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: archive
spec:
  storageClassName: minio-sc
  accessModes: [ReadWriteMany]
  resources:
    requests: {storage: 2Gi}
EOF
workstation$ kubectl -n lab-06-09-globex describe quota tenant-budget | grep -E 'storage|claims'
```

Expected:
```
persistentvolumeclaim/uploads created
Error from server (Forbidden): error when creating "STDIN": persistentvolumeclaims "archive" is forbidden: exceeded quota: tenant-budget, requested: minio-sc.storageclass.storage.k8s.io/requests.storage=2Gi,requests.storage=2Gi, used: minio-sc.storageclass.storage.k8s.io/requests.storage=1Gi,requests.storage=1Gi, limited: minio-sc.storageclass.storage.k8s.io/requests.storage=2Gi,requests.storage=2Gi
minio-sc.storageclass.storage.k8s.io/persistentvolumeclaims  1      2
minio-sc.storageclass.storage.k8s.io/requests.storage        1Gi    2Gi
requests.storage                                             1Gi    2Gi
```

The quota counts what is *requested*; Lab 4.6 showed that an S3 volume does not enforce its size, so the real usage
must be limited on the S3 side as well. Clean up with `kubectl delete namespace lab-06-09-globex`; the `uploads`
volume and its bucket prefix are deleted with it.

</details>

---

## Lab 6.10: Your own admission rules with ValidatingAdmissionPolicy

**Scenario** – Two incidents in one month: a Deployment with `image: nginx:latest` silently picked up a new major
version during a node replacement, and an alert fired for a Deployment nobody claimed. The platform team decides:
every image must have a pinned tag or digest, and every Deployment must carry a `team` label. Instead of running a
webhook server, we write the rules in CEL as a ValidatingAdmissionPolicy, roll it out in *warn* mode first, then
enforce it, scoped to our own namespace.

**What you'll learn**
- `ValidatingAdmissionPolicy` (CEL rules) and `ValidatingAdmissionPolicyBinding` (where and how they apply)
- `variables`, `messageExpression`, optional fields (`?initContainers.orValue([])`)
- rolling out with `validationActions: [Warn, Audit]`, then `[Deny]`
- scoping with `namespaceSelector`, and the gaps a policy leaves (bare Pods)

> **Scope:** the binding below matches only the namespace `lab-06-10` via its `kubernetes.io/metadata.name` label.
> A policy without a selector would apply to every namespace in the cluster, including `kube-system`.

### Steps

1. Create the namespaces, the policy and a binding in warn mode.

```bash
workstation$ kubectl create namespace lab-06-10
workstation$ kubectl create namespace lab-06-10-other
workstation$ kubectl apply -f - <<'EOF'
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicy
metadata:
  name: lab-06-10-deployment-rules
spec:
  failurePolicy: Fail
  matchConstraints:
    resourceRules:
    - apiGroups: ["apps"]
      apiVersions: ["v1"]
      operations: ["CREATE", "UPDATE"]
      resources: ["deployments"]
  variables:
  - name: containers
    expression: >-
      object.spec.template.spec.containers +
      object.spec.template.spec.?initContainers.orValue([])
  validations:
  - expression: >-
      variables.containers.all(c,
        c.image.matches('^.+(:[^:/]+|@sha256:[a-f0-9]{64})$') && !c.image.endsWith(':latest'))
    messageExpression: >-
      'every image needs a pinned tag or digest (not :latest), offending: ' +
      variables.containers.filter(c, !c.image.matches('^.+(:[^:/]+|@sha256:[a-f0-9]{64})$') || c.image.endsWith(':latest')).map(c, c.name + '=' + c.image).join(', ')
    reason: Invalid
  - expression: "has(object.metadata.labels) && 'team' in object.metadata.labels"
    message: "Deployments must have a 'team' label (who gets paged?)"
    reason: Invalid
---
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicyBinding
metadata:
  name: lab-06-10-deployment-rules
spec:
  policyName: lab-06-10-deployment-rules
  validationActions: [Warn, Audit]          # dry-run phase: report, do not block
  matchResources:
    namespaceSelector:
      matchExpressions:
      - key: kubernetes.io/metadata.name
        operator: In
        values: ["lab-06-10"]
EOF
workstation$ kubectl get validatingadmissionpolicy lab-06-10-deployment-rules -o jsonpath='{.status}{"\n"}'
```

Expected (an empty `typeChecking` means the CEL expressions compiled and type-checked against the Deployment schema):
```
{"observedGeneration":1,"typeChecking":{}}
```

The regular expression accepts `name:tag` and `name@sha256:<digest>`; the `[^:/]` part makes sure that the colon of
a registry port (`registry:5000/app`) is not mistaken for a tag.

2. Warn phase: violations are reported to the client (and the audit log), but the objects would be created.
   Admission policies also run for server-side dry runs, so we can test without actually pulling `:latest` images.

```bash
workstation$ kubectl -n lab-06-10 create deployment quick --image=nginx:latest --dry-run=server
workstation$ kubectl -n lab-06-10 create deployment quick2 --image=redis --dry-run=server
```

Expected:
```
deployment.apps/quick created (server dry run)
Warning: Validation failed for ValidatingAdmissionPolicy 'lab-06-10-deployment-rules' with binding 'lab-06-10-deployment-rules': every image needs a pinned tag or digest (not :latest), offending: nginx=nginx:latest
Warning: Validation failed for ValidatingAdmissionPolicy 'lab-06-10-deployment-rules' with binding 'lab-06-10-deployment-rules': Deployments must have a 'team' label (who gets paged?)
deployment.apps/quick2 created (server dry run)
Warning: Validation failed for ValidatingAdmissionPolicy 'lab-06-10-deployment-rules' with binding 'lab-06-10-deployment-rules': every image needs a pinned tag or digest (not :latest), offending: redis=redis
Warning: Validation failed for ValidatingAdmissionPolicy 'lab-06-10-deployment-rules' with binding 'lab-06-10-deployment-rules': Deployments must have a 'team' label (who gets paged?)
```

3. The teams have had time to fix their manifests. Enforce.

```bash
workstation$ kubectl patch validatingadmissionpolicybinding lab-06-10-deployment-rules --type=merge -p '{"spec":{"validationActions":["Deny"]}}'
workstation$ kubectl -n lab-06-10 create deployment quick --image=nginx:latest
```

Expected:
```
validatingadmissionpolicybinding.admissionregistration.k8s.io/lab-06-10-deployment-rules patched
error: failed to create deployment: deployments.apps "quick" is forbidden: ValidatingAdmissionPolicy 'lab-06-10-deployment-rules' with binding 'lab-06-10-deployment-rules' denied request: every image needs a pinned tag or digest (not :latest), offending: nginx=nginx:latest
```

4. A labelled Deployment whose **init container** has no tag is caught, too. Fix the tag and it is admitted.

```bash
workstation$ cat > shop.yaml <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: shop
  labels: {team: payments}
spec:
  selector:
    matchLabels: {app: shop}
  template:
    metadata:
      labels: {app: shop}
    spec:
      initContainers:
      - name: migrate
        image: busybox
        command: ["true"]
      containers:
      - name: web
        image: nginx:1.31-alpine
EOF
workstation$ kubectl -n lab-06-10 apply -f shop.yaml
workstation$ sed -i 's/image: busybox$/image: busybox:1.38/' shop.yaml && kubectl -n lab-06-10 apply -f shop.yaml
workstation$ kubectl -n lab-06-10 label deployment shop team-
```

Expected (the policy also runs on UPDATE, so removing the label later is refused):
```
The deployments "shop" is invalid: : ValidatingAdmissionPolicy 'lab-06-10-deployment-rules' with binding 'lab-06-10-deployment-rules' denied request: every image needs a pinned tag or digest (not :latest), offending: migrate=busybox
deployment.apps/shop created
The deployments "shop" is invalid: : ValidatingAdmissionPolicy 'lab-06-10-deployment-rules' with binding 'lab-06-10-deployment-rules' denied request: Deployments must have a 'team' label (who gets paged?)
```

5. Check the scope and the gaps.

```bash
workstation$ kubectl -n lab-06-10-other create deployment quick --image=nginx:latest --dry-run=server
workstation$ kubectl -n lab-06-10 run bare --image=nginx:latest --dry-run=server
```

Expected (no warnings, no denial):
```
deployment.apps/quick created (server dry run)
pod/bare created (server dry run)
```

The other namespace is not selected by the binding. And the policy only matches Deployments, so a bare Pod (or a
StatefulSet, Job, CronJob ...) with `:latest` walks right past it. Image rules belong on **Pods**, or on all
workload kinds.

### Clean up

```bash
workstation$ kubectl delete validatingadmissionpolicybinding lab-06-10-deployment-rules
workstation$ kubectl delete validatingadmissionpolicy lab-06-10-deployment-rules
workstation$ kubectl delete namespace lab-06-10 lab-06-10-other
workstation$ rm -f shop.yaml
```

### Your turn

Security wants images only from approved registries, and **they** maintain the list, not the platform team: a
ConfigMap `allowed-registries` in `lab-06-10` with a key `prefixes` (comma-separated, e.g.
`docker.io/library/,ghcr.io/stefanprodan/,registry.k8s.io/`). Write a second policy `lab-06-10-allowed-registries`
that reads this ConfigMap as its parameter, covers **Pods and Deployments**, understands short names (`nginx:1.31`
means `docker.io/library/nginx:1.31`, `traefik/whoami` means `docker.io/traefik/whoami`), and blocks everything if the
ConfigMap is missing. Test with busybox, podinfo, `traefik/whoami:v1.12.0` and `evil.example.com/miner:1.0`, then add
`docker.io/traefik/` to the list.

<details><summary>Solution</summary>

```bash
workstation$ kubectl apply -f - <<'EOF'
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicy
metadata:
  name: lab-06-10-allowed-registries
spec:
  failurePolicy: Fail
  paramKind:
    apiVersion: v1
    kind: ConfigMap
  matchConstraints:
    resourceRules:
    - apiGroups: [""]
      apiVersions: ["v1"]
      operations: ["CREATE", "UPDATE"]
      resources: ["pods"]
    - apiGroups: ["apps"]
      apiVersions: ["v1"]
      operations: ["CREATE", "UPDATE"]
      resources: ["deployments"]
  variables:
  - name: podSpec                                  # Pods and Deployments keep the spec in different places
    expression: "has(object.spec.template) ? object.spec.template.spec : object.spec"
  - name: images                                   # normalise "nginx:1" to "docker.io/library/nginx:1"
    expression: >-
      (variables.podSpec.containers + variables.podSpec.?initContainers.orValue([])).map(c,
        c.image.split('/').size() > 1 && c.image.split('/')[0].contains('.') ? c.image :
        c.image.split('/').size() > 1 ? 'docker.io/' + c.image : 'docker.io/library/' + c.image)
  - name: allowed
    expression: "params.data.prefixes.split(',').map(p, p.trim())"
  validations:
  - expression: "variables.images.all(i, variables.allowed.exists(p, i.startsWith(p)))"
    messageExpression: >-
      'images must come from an approved registry (' + params.data.prefixes + '), rejected: ' +
      variables.images.filter(i, !variables.allowed.exists(p, i.startsWith(p))).join(', ')
---
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicyBinding
metadata:
  name: lab-06-10-allowed-registries
spec:
  policyName: lab-06-10-allowed-registries
  validationActions: [Deny]
  paramRef:
    name: allowed-registries
    namespace: lab-06-10
    parameterNotFoundAction: Deny                  # no list, no deployments
  matchResources:
    namespaceSelector:
      matchExpressions:
      - key: kubernetes.io/metadata.name
        operator: In
        values: ["lab-06-10"]
EOF
workstation$ kubectl -n lab-06-10 run probe --image=busybox:1.38 --restart=Never -- sleep 1
```

Expected (fail closed, the parameter does not exist yet):
```
The pods "probe" is invalid: : ValidatingAdmissionPolicy 'lab-06-10-allowed-registries' with binding 'lab-06-10-allowed-registries' denied request: failed to configure binding: no params found for policy binding with `Deny` parameterNotFoundAction
```

```bash
workstation$ kubectl -n lab-06-10 create configmap allowed-registries \
  --from-literal=prefixes='docker.io/library/,ghcr.io/stefanprodan/,registry.k8s.io/'
workstation$ kubectl -n lab-06-10 run probe --image=busybox:1.38 --restart=Never -- sleep 1
workstation$ kubectl -n lab-06-10 run podinfo --image=ghcr.io/stefanprodan/podinfo:6.17.0
workstation$ kubectl -n lab-06-10 run whoami --image=traefik/whoami:v1.12.0
workstation$ kubectl -n lab-06-10 run evil --image=evil.example.com/miner:1.0
workstation$ kubectl -n lab-06-10 create deployment whoami --image=traefik/whoami:v1.12.0
```

Expected:
```
configmap/allowed-registries created
pod/probe created
pod/podinfo created
The pods "whoami" is invalid: : ValidatingAdmissionPolicy 'lab-06-10-allowed-registries' with binding 'lab-06-10-allowed-registries' denied request: images must come from an approved registry (docker.io/library/,ghcr.io/stefanprodan/,registry.k8s.io/), rejected: docker.io/traefik/whoami:v1.12.0
The pods "evil" is invalid: : ValidatingAdmissionPolicy 'lab-06-10-allowed-registries' with binding 'lab-06-10-allowed-registries' denied request: images must come from an approved registry (docker.io/library/,ghcr.io/stefanprodan/,registry.k8s.io/), rejected: evil.example.com/miner:1.0
error: failed to create deployment: deployments.apps "whoami" is forbidden: ValidatingAdmissionPolicy 'lab-06-10-allowed-registries' with binding 'lab-06-10-allowed-registries' denied request: images must come from an approved registry (docker.io/library/,ghcr.io/stefanprodan/,registry.k8s.io/), rejected: docker.io/traefik/whoami:v1.12.0
```

Security approves Traefik's images; no policy change is needed:

```bash
workstation$ kubectl -n lab-06-10 patch configmap allowed-registries --type=merge \
  -p '{"data":{"prefixes":"docker.io/library/,ghcr.io/stefanprodan/,registry.k8s.io/,docker.io/traefik/"}}'
workstation$ kubectl -n lab-06-10 run whoami --image=traefik/whoami:v1.12.0
```

Expected:
```
configmap/allowed-registries patched
pod/whoami created
```

Give the security team RBAC rights on this one ConfigMap (`resourceNames: [allowed-registries]`, Lab 6.1) and they
own the list. Clean up both policies and bindings:

```bash
workstation$ kubectl delete validatingadmissionpolicybinding lab-06-10-allowed-registries
workstation$ kubectl delete validatingadmissionpolicy lab-06-10-allowed-registries
```

</details>
