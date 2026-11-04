## Basic administration
Display documentation for a configuration field
```
kubectl explain pod.spec
```
Apply a configuration
```
kubectl create -f echo-server-pod.yaml
```
Get the configuration in JSON/YAML format
```
kubectl get po echo-server-pod -o yaml
```
```
kubectl describe pod echo-server-pod
```
Display logs
```
kubectl logs echo-server-pod [-c $CONTAINER_NAME]
```
Port forwarding
```
kubectl port-forward echo-server-pod 8888:8080 
```
Execute a command in a container / pod
```
kubectl exec echo-server-pod -- env
```
## Labels
Show labels
```
kubectl get pods --show-labels
```
Filter by labels
```
kubectl get pods -l version
```
```
kubectl get pods -l version=1
```
```
kubectl get pods -l version!=1
```
```
kubectl get pods -l '!version'
```
```
kubectl get pods -l 'env in (production,development)'
```
```
kubectl get pods -l 'env notin (production,development)'
```
```
kubectl get pods -l 'env=production,version=2'
```
Add a label
```
kubectl label pod echo-server-pod type=frontend
```
```
kubectl label node node1.k8s type=primary
```
Change a label
```
kubectl label pod echo-server-pod type=backend --overwrite
```
Remove a label
```
kubectl label pod echo-server-pod type-
```
## Annotations
Add an annotation
```
kubectl annotate pod echo-server-pod training=true
```
Display annotations
```
kubectl get pod echo-server-pod -o yaml
```
## Namespaces
List namespaces
```
kubectl get namespaces
```
List pods in a given namespace
```
kubectl get pods --namespace=kube-system
```
Create a namespace
```
kubectl create namespace training
```
Delete a namespace
```
kubectl delete namespace training
```
Set the namespace for the current context
```
kubectl config set-context --current --namespace=training
```
Delete resources
```
kubectl delete pod echo-server-pod
```
```
kubectl delete pod -l version=v1
```
```
kubectl delete namespaces training
```
```
kubectl delete pods --all
```
```
kubectl delete all --all
```
## Deployment
```
kubectl apply -f echo-server-deployment.yml
```
```
kubectl rollout history deployment echo-server-deployment
```
```
kubectl rollout status deployment echo-server-deployment
```
```
while true;do curl -s http://192.168.1.241;sleep 1;done;
```
```
kubectl set image deployment echo-server-deployment echo-server-app=landrzejewski/echo-server:v2
```
```
kubectl rollout undo deployment echo-server-deployment --to-revision=1
```
Run a test pod in the cluster
```
kubectl run -it --rm test --image=busybox /bin/sh
```
Installing MetalLB [https://metallb.universe.tf/installation](https://metallb.universe.tf/installation)
```
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.16.1/config/manifests/metallb-native.yaml
```
```
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: first-pool
  namespace: metallb-system
spec:
  addresses:
  - 192.168.1.240-192.168.1.250
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: example
  namespace: metallb-system
```
Installing Ingress (ingress-nginx) [https://kubernetes.github.io/ingress-nginx/deploy/#bare-metal-clusters](https://kubernetes.github.io/ingress-nginx/deploy/#bare-metal-clusters)

Note: the ingress-nginx project was retired (maintenance ended in March 2026) - prefer the Gateway API below for new setups.
```
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.15.1/deploy/static/provider/baremetal/deploy.yaml
kubectl get pods -n ingress-nginx -l app.kubernetes.io/name=ingress-nginx --watch
```
Installing Gateway API (NGINX Gateway Fabric)
```
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.7.0/standard-install.yaml
helm install ngf oci://ghcr.io/nginx/charts/nginx-gateway-fabric --create-namespace -n nginx-gateway
kubectl get pods,svc -n nginx-gateway
kubectl get gc
```
Installing the UI (Kubernetes Dashboard) [https://kubernetes.io/docs/tasks/access-application-cluster/web-ui-dashboard](https://kubernetes.io/docs/tasks/access-application-cluster/web-ui-dashboard)

Note: Kubernetes Dashboard was archived in January 2026 (no more fixes or releases; the recommended successor is Headlamp). Its Helm repository moved to kubernetes-retired.github.io.
```
helm repo add kubernetes-dashboard https://kubernetes-retired.github.io/dashboard/

helm upgrade --install kubernetes-dashboard kubernetes-dashboard/kubernetes-dashboard --create-namespace --namespace kubernetes-dashboard
```

### Alternatively (using the registry cache)
```
helm upgrade --install kubernetes-dashboard kubernetes-dashboard/kubernetes-dashboard \
  --create-namespace \
  --namespace kubernetes-dashboard \
  --set auth.image.repository=klasawchmurze.pl:5000/docker.io/kubernetesui/dashboard-auth \
  --set api.image.repository=klasawchmurze.pl:5000/docker.io/kubernetesui/dashboard-api \
  --set web.image.repository=klasawchmurze.pl:5000/docker.io/kubernetesui/dashboard-web \
  --set metricsScraper.image.repository=klasawchmurze.pl:5000/docker.io/kubernetesui/dashboard-metrics-scraper \
  --set kong.image.repository=klasawchmurze.pl:5000/docker.io/kong


kubectl apply -f admin-user.yml
kubectl apply -f admin-roles.yml

kubectl -n kubernetes-dashboard create token admin-user

kubectl -n kubernetes-dashboard port-forward svc/kubernetes-dashboard-kong-proxy 8001:443 --address 0.0.0.0
```
