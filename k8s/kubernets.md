 ## Podstawy administracji
Wyświetlenie informacji dotyczących elementu konfiguracyjnego
```
kubectl explain pod.spec
```
Zastosowanie konfiguracji
```
kubectl create -f echo-server-pod.yaml
```
Pobranie konfiguracji w formacie json/yaml
```
kubectl get po echo-server-pod -o yaml
```
```
kubectl describe echo-server-pod
```
Wyświetlenie logów
```
kubectl logs echo-server-pod [-c $CONTAINER_NAME]
```
Forward portów
```
kubectl port-forward echo-server-pod 8888:8080 
```
Wykonanie polecenia na kontenerze / pod
```
kubectl exec echo-server-pod -- env
```
## Labels
Pokazanie etykiet
```
kubectl get pods --show-labels
```
Filtrowanie po etykietach
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
Dodanie etykiety
```
kubectl label pod echo-server-pod type=forntend
```
```
kubectl label node node1.k8s type=primary
```
Zmiana etykiety
```
kubectl label pod echo-server-pod type=backend --overwrite
```
Usunięcie etykiety
```
kubectl label pod echo-server-pod type-
```
## Annotations
Dodanie adnotacji
```
kubectl annotate pod echo-server-pod training=true
```
Wyświetlenie adnotacji
```
kubectl get pod echo-server-pod -o yaml
```
## Namespaces
Pobranie przestrzeni nazw
```
kubectl get namespaces
```
Pobranie podów z danej przestrzeni nazw
```
kubectl get pods --namespace=kube-system
```
Utworzenie przestrzeni nazw
```
kubectl create namespace training
```
Usunięcie przestrzeni nazw
```
kubectl delete namespace training
```
Ustawienie kontekstu/przestrzeni
```
kubectl config set-context --current --namespace=training
```
Usuwanie zasobów
```
kubectl delete pod echo-server-pod
```
```
kubectl delete pod -l version=v1
```
```
kubectl delete namesapces training
```
```
kubectl delete pods --all
```
```
kubectl delete all --all
```
## Deployment
```
kubectl apply -f echo-server-deployment.yml --record
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
Polisy sieciowe [https://github.com/ahmetb/kubernetes-network-policy-recipes](https://github.com/ahmetb/kubernetes-network-policy-recipes)

Uruchomienie testowego poda w klastrze
```
kubectl run -it --rm test --image=busybox /bin/sh
```
Instalacja metallb [https://metallb.universe.tf/installation](https://metallb.universe.tf/installation)
```
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.15.3/config/manifests/metallb-native.yaml
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
Instalacja Ingress [https://kubernetes.github.io/ingress-nginx/deploy/#bare-metal-clusters](https://kubernetes.github.io/ingress-nginx/deploy/#bare-metal-clusters)
```
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.14.1/deploy/static/provider/baremetal/deploy.yaml
kubectl get pods -n ingress-nginx -l app.kubernetes.io/name=ingress-nginx --watch
```
Instalacja Gateway
```
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.4.1/standard-install.yaml
helm install ngf oci://ghcr.io/nginx/charts/nginx-gateway-fabric --create-namespace -n nginx-gateway
kubectl get pods,svc -n nginx-gateway
kubectl get gc
```
Instalacja UI  [https://kubernetes.io/docs/tasks/access-application-cluster/web-ui-dashboard](https://kubernetes.io/docs/tasks/access-application-cluster/web-ui-dashboard)
```
helm repo add kubernetes-dashboard https://kubernetes.github.io/dashboard/

helm upgrade --install kubernetes-dashboard kubernetes-dashboard/kubernetes-dashboard --create-namespace --namespace kubernetes-dashboard'

### Alternatywnie (repo cache)
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
Instalacja Helm [https://helm.sh/docs/intro/install](https://helm.sh/docs/intro/install)
```
curl https://baltocdn.com/helm/signing.asc | gpg --dearmor | sudo tee /usr/share/keyrings/helm.gpg > /dev/null
sudo apt-get install apt-transport-https --yes
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/helm.gpg] https://baltocdn.com/helm/stable/debian/ all main" | sudo tee /etc/apt/sources.list.d/helm-stable-debian.list
sudo apt-get update
sudo apt-get install helm
```
