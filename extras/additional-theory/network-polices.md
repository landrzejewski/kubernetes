# Tutorial: Kubernetes NetworkPolicies

## Spis treści
1. [Wprowadzenie](#wprowadzenie)
2. [Przygotowanie środowiska](#przygotowanie-środowiska)
3. [Przykład 1: Domyślna izolacja](#przykład-1-domyślna-izolacja)
4. [Przykład 2: Zezwolenie na ruch przychodzący](#przykład-2-zezwolenie-na-ruch-przychodzący)
5. [Przykład 3: Izolacja między namespace'ami](#przykład-3-izolacja-między-namespaceami)
6. [Przykład 4: Ograniczenie ruchu wychodzącego](#przykład-4-ograniczenie-ruchu-wychodzącego)
7. [Przykład 5: Zaawansowane polityki](#przykład-5-zaawansowane-polityki)
8. [Czyszczenie środowiska](#czyszczenie-środowiska)

---

## Wprowadzenie

**NetworkPolicy** to zasób Kubernetes, który kontroluje ruch sieciowy między podami. Działa podobnie jak firewall na poziomie aplikacji.

### Kluczowe koncepty:
- **Domyślnie**: wszystkie pody mogą komunikować się ze sobą bez ograniczeń
- **Po zastosowaniu NetworkPolicy**: ruch jest ograniczony zgodnie z zdefiniowanymi regułami
- **Ingress**: ruch przychodzący DO poda
- **Egress**: ruch wychodzący Z poda
- **Selektory**: określają, których podów dotyczy polityka

### Wymagania:
- Network plugin obsługujący NetworkPolicy (Calico - masz zainstalowany ✓)
- Działający klaster Kubernetes

---

## Przygotowanie środowiska

### 1. Utwórz namespace do testów

```bash
kubectl create namespace network-demo
kubectl config set-context --current --namespace=network-demo
```

### 2. Wdróż trzy proste aplikacje testowe

Zapisz jako `test-apps.yaml`:

```yaml
---
# Frontend application
apiVersion: v1
kind: Pod
metadata:
  name: frontend
  namespace: network-demo
  labels:
    app: frontend
    tier: frontend
spec:
  containers:
  - name: nginx
    image: nginx:alpine
    ports:
    - containerPort: 80

---
# Backend application
apiVersion: v1
kind: Pod
metadata:
  name: backend
  namespace: network-demo
  labels:
    app: backend
    tier: backend
spec:
  containers:
  - name: nginx
    image: nginx:alpine
    ports:
    - containerPort: 80

---
# Database
apiVersion: v1
kind: Pod
metadata:
  name: database
  namespace: network-demo
  labels:
    app: database
    tier: database
spec:
  containers:
  - name: nginx
    image: nginx:alpine
    ports:
    - containerPort: 80

---
# Test pod (do wysyłania requestów)
apiVersion: v1
kind: Pod
metadata:
  name: test-client
  namespace: network-demo
  labels:
    app: test-client
spec:
  containers:
  - name: alpine
    image: alpine
    command: ['sh', '-c', 'apk add curl && sleep 3600']
```

Zastosuj:
```bash
kubectl apply -f test-apps.yaml
```

Poczekaj aż wszystkie pody będą gotowe:
```bash
kubectl get pods -w
```

### 3. Pobierz adresy IP podów

```bash
kubectl get pods -o wide
```

### 4. Test bazowej łączności (przed NetworkPolicies)

```bash
# Z test-client do frontend
kubectl exec -it test-client -- curl -m 3 http://<FRONTEND_IP>

# Z test-client do backend
kubectl exec -it test-client -- curl -m 3 http://<BACKEND_IP>

# Z test-client do database
kubectl exec -it test-client -- curl -m 3 http://<DATABASE_IP>
```

**Wynik**: Wszystkie połączenia powinny działać ✓

---

## Przykład 1: Domyślna izolacja

### Cel: Zablokuj CAŁY ruch przychodzący do bazy danych

Zapisz jako `deny-all-database.yaml`:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: deny-all-to-database
  namespace: network-demo
spec:
  podSelector:
    matchLabels:
      app: database
  policyTypes:
  - Ingress
  # Brak reguł ingress = blokada wszystkiego
```

Zastosuj:
```bash
kubectl apply -f deny-all-database.yaml
```

### Test:

```bash
# To POWINNO się NIE UDAĆ (timeout)
kubectl exec -it test-client -- curl -m 3 http://<DATABASE_IP>

# To nadal działa (frontend i backend nie mają NetworkPolicy)
kubectl exec -it test-client -- curl -m 3 http://<FRONTEND_IP>
kubectl exec -it test-client -- curl -m 3 http://<BACKEND_IP>
```

### Wyjaśnienie:
- `podSelector` określa, których podów dotyczy polityka (database)
- `policyTypes: [Ingress]` oznacza, że kontrolujemy ruch przychodzący
- Pusta lista reguł ingress = **DENY ALL**

---

## Przykład 2: Zezwolenie na ruch przychodzący

### Cel: Pozwól TYLKO backendowi łączyć się z bazą danych

Zapisz jako `allow-backend-to-db.yaml`:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-backend-to-database
  namespace: network-demo
spec:
  podSelector:
    matchLabels:
      app: database
  policyTypes:
  - Ingress
  ingress:
  - from:
    - podSelector:
        matchLabels:
          app: backend
    ports:
    - protocol: TCP
      port: 80
```

Zastosuj:
```bash
kubectl apply -f allow-backend-to-db.yaml
```

### Test:

```bash
# To POWINNO się NIE UDAĆ (test-client nie ma dostępu)
kubectl exec -it test-client -- curl -m 3 http://<DATABASE_IP>

# To POWINNO DZIAŁAĆ (backend ma dostęp)
kubectl exec -it backend -- sh -c "apk add curl && curl -m 3 http://<DATABASE_IP>"
```

### Wyjaśnienie:
- Polityka zastępuje poprzednią (deny-all)
- Teraz pody z labelką `app: backend` mogą łączyć się z bazą na porcie 80
- Wszystkie inne pody nadal są zablokowane

---

## Przykład 3: Izolacja między namespace'ami

### Cel: Backend może przyjmować ruch TYLKO z tego samego namespace

### 1. Utwórz drugi namespace z aplikacją

```bash
kubectl create namespace other-namespace

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: external-client
  namespace: other-namespace
  labels:
    app: external
spec:
  containers:
  - name: alpine
    image: alpine
    command: ['sh', '-c', 'apk add curl && sleep 3600']
EOF
```

### 2. Zastosuj politykę do backendu

Zapisz jako `backend-same-namespace-only.yaml`:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: backend-same-namespace-only
  namespace: network-demo
spec:
  podSelector:
    matchLabels:
      app: backend
  policyTypes:
  - Ingress
  ingress:
  - from:
    - podSelector:
        matchLabels:
          app: frontend
      namespaceSelector:
        matchLabels:
          name: network-demo
    ports:
    - protocol: TCP
      port: 80
```

### 3. Dodaj label do namespace

```bash
kubectl label namespace network-demo name=network-demo
```

Zastosuj:
```bash
kubectl apply -f backend-same-namespace-only.yaml
```

### Test:

```bash
# Z tego samego namespace - POWINNO DZIAŁAĆ
kubectl exec -it -n network-demo test-client -- curl -m 3 http://<BACKEND_IP>

# Z innego namespace - POWINNO się NIE UDAĆ
kubectl exec -it -n other-namespace external-client -- curl -m 3 http://<BACKEND_IP>
```

### Wyjaśnienie:
- `namespaceSelector` ogranicza ruch do konkretnych namespace'ów
- Można go łączyć z `podSelector` dla precyzyjnej kontroli

---

## Przykład 4: Ograniczenie ruchu wychodzącego

### Cel: Frontend może łączyć się TYLKO z backendem (nie z Internetem)

Zapisz jako `frontend-egress.yaml`:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: frontend-egress-restricted
  namespace: network-demo
spec:
  podSelector:
    matchLabels:
      app: frontend
  policyTypes:
  - Egress
  egress:
  # Zezwól na DNS
  - to:
    - namespaceSelector:
        matchLabels:
          name: kube-system
      podSelector:
        matchLabels:
          k8s-app: kube-dns
    ports:
    - protocol: UDP
      port: 53
  # Zezwól TYLKO na backend
  - to:
    - podSelector:
        matchLabels:
          app: backend
    ports:
    - protocol: TCP
      port: 80
```

Zastosuj:
```bash
kubectl label namespace kube-system name=kube-system
kubectl apply -f frontend-egress.yaml
```

### Test:

```bash
# Do backendu - POWINNO DZIAŁAĆ
kubectl exec -it frontend -- sh -c "apk add curl && curl -m 3 http://<BACKEND_IP>"

# Do database - POWINNO się NIE UDAĆ
kubectl exec -it frontend -- curl -m 3 http://<DATABASE_IP>

# Do Internetu - POWINNO się NIE UDAĆ
kubectl exec -it frontend -- curl -m 3 http://google.com
```

### Wyjaśnienie:
- `policyTypes: [Egress]` kontroluje ruch wychodzący
- Musimy jawnie zezwolić na DNS (inaczej nic nie działa)
- Frontend może wychodzić TYLKO do backendu

---

## Przykład 5: Zaawansowane polityki

### Cel: Realistyczny scenariusz 3-warstwowej aplikacji

```yaml
# 1. Frontend - przyjmuje ruch z zewnątrz, łączy się z backendem
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: frontend-policy
  namespace: network-demo
spec:
  podSelector:
    matchLabels:
      tier: frontend
  policyTypes:
  - Ingress
  - Egress
  ingress:
  # Przyjmuj ruch z wszędzie (np. LoadBalancer)
  - {}
  egress:
  # DNS
  - to:
    - namespaceSelector: {}
      podSelector:
        matchLabels:
          k8s-app: kube-dns
    ports:
    - protocol: UDP
      port: 53
  # Backend na porcie 8080
  - to:
    - podSelector:
        matchLabels:
          tier: backend
    ports:
    - protocol: TCP
      port: 8080

---
# 2. Backend - przyjmuje tylko od frontend, łączy się z DB
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: backend-policy
  namespace: network-demo
spec:
  podSelector:
    matchLabels:
      tier: backend
  policyTypes:
  - Ingress
  - Egress
  ingress:
  - from:
    - podSelector:
        matchLabels:
          tier: frontend
    ports:
    - protocol: TCP
      port: 8080
  egress:
  # DNS
  - to:
    - namespaceSelector: {}
      podSelector:
        matchLabels:
          k8s-app: kube-dns
    ports:
    - protocol: UDP
      port: 53
  # Database
  - to:
    - podSelector:
        matchLabels:
          tier: database
    ports:
    - protocol: TCP
      port: 5432

---
# 3. Database - przyjmuje tylko od backend, zero egress
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: database-policy
  namespace: network-demo
spec:
  podSelector:
    matchLabels:
      tier: database
  policyTypes:
  - Ingress
  - Egress
  ingress:
  - from:
    - podSelector:
        matchLabels:
          tier: backend
    ports:
    - protocol: TCP
      port: 5432
  # Egress pusty = brak połączeń wychodzących
  egress: []
```

### Diagram przepływu:
```
Internet → Frontend (port 80) → Backend (port 8080) → Database (port 5432)
            ✓ wszędzie          ✓ tylko frontend      ✓ tylko backend
```

---

## Weryfikacja i debugging

### Sprawdź zastosowane polityki:

```bash
kubectl get networkpolicies
kubectl describe networkpolicy <nazwa-polityki>
```

### Sprawdź, które pody są objęte polityką:

```bash
kubectl get pods --show-labels
```

### Testowanie łączności:

```bash
# Z poda do poda (po IP)
kubectl exec -it <pod-source> -- curl -m 3 http://<pod-target-ip>

# Z poda do serwisu (po nazwie DNS)
kubectl exec -it <pod-source> -- curl -m 3 http://<service-name>
```

### Częste problemy:

1. **Zapomnienie o DNS** - zawsze dodaj regułę egress dla kube-dns
2. **Kolejność polityk** - wszystkie polityki są addytywne (OR logic)
3. **Selektory** - upewnij się, że labele są prawidłowe
4. **Network plugin** - upewnij się, że Calico działa:
   ```bash
   kubectl get pods -n kube-system | grep calico
   ```

---

## Czyszczenie środowiska

### Usuń wszystkie zasoby testowe:

```bash
kubectl delete namespace network-demo
kubectl delete namespace other-namespace
```

Lub selektywnie:

```bash
# Usuń wszystkie NetworkPolicies
kubectl delete networkpolicies --all -n network-demo

# Usuń pody testowe
kubectl delete pods --all -n network-demo
```

---

## Podsumowanie i najlepsze praktyki

### ✅ Dobre praktyki:

1. **Deny by default**: Zacznij od zablokowania wszystkiego, potem otwieraj
   ```yaml
   ingress: []  # deny all ingress
   egress: []   # deny all egress
   ```

2. **Dokładne selektory**: Używaj wielu labeli dla precyzji
   ```yaml
   podSelector:
     matchLabels:
       app: backend
       version: v2
       environment: production
   ```

3. **Dokumentuj**: Dodawaj annotations wyjaśniające politykę
   ```yaml
   metadata:
     annotations:
       description: "Blocks all access to PII database except from auth service"
   ```

4. **Testuj stopniowo**: Nie wdrażaj wszystkich polityk naraz

5. **Monitoring**: Monitoruj logi Calico/sieciowe dla zablokowanych połączeń

### ❌ Czego unikać:

1. Zbyt szerokich selectorów (`podSelector: {}`  = wszystkie pody)
2. Zapominania o regułach DNS dla egress
3. Mylenia AND vs OR w selektorach
4. Wdrażania polityk bez testowania

### 📚 Dodatkowe zasoby:

- [Oficjalna dokumentacja K8s](https://kubernetes.io/docs/concepts/services-networking/network-policies/)
- [Network Policy Editor](https://editor.networkpolicy.io/) - wizualizacja polityk
- [Calico documentation](https://docs.projectcalico.org/)

---

## Zadania do samodzielnego wykonania

1. **Zadanie 1**: Stwórz politykę, która pozwala frontenowi przyjmować ruch TYLKO z podów z labelką `role: loadbalancer`

2. **Zadanie 2**: Ograicz bazę danych tak, aby mogła łączyć się wychodzące TYLKO do serwisu backupowego (port 9000)

3. **Zadanie 3**: Stwórz politykę namespace-wide, która blokuje cały ruch między namespace'ami (tylko ruch wewnątrz namespace dozwolony)

4. **Zadanie 4**: Pozwól podowi monitoring łączyć się ze wszystkimi podami, ale tylko na porcie 9090 (metrics)

Powodzenia! 🚀