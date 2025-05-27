## Czym są NetworkPolicy?

* **NetworkPolicy** to obiekt API w Kubernetes (extensible via `networking.k8s.io/v1`), pozwalający kontrolować ruch sieciowy **do** (ingress) i **z** (egress) grupy podów.
* Domyślnie, jeśli w danym namespace nie ma żadnej NetworkPolicy, ruch między wszystkimi podami jest **otwarty** (allow-all).
* Gdy utworzysz choć jedną politykę w namespace, zaczyna działać zasada „pod bez dopasowanej polityki jest izolowany” – tzn. ruch, który nie pasuje do żadnej polityki, jest **odrzucany**.

### Kluczowe elementy

* **`podSelector`** – dobiera pody, do których polityka będzie się odnosić.
* **`policyTypes`** – listuje, czy polityka dotyczy `Ingress` i/lub `Egress`.
* **`ingress`** / **`egress`** – zestaw reguł definiujących, jaki ruch jest dozwolony:

    * `from` (dla Ingress): z jakich źródeł (podów / namespace’ów / IP bloków)
    * `to`   (dla Egress): do jakich destynacji (podów / namespace’ów / IP bloków)
    * `ports`: na jakich portach/protokole

---

## 1. Domyślne odrzucenie ruchu (deny-all) dla nowych podów

Często stosowany wzorzec „najpierw odrzucamy wszystko, potem dodajemy wyjątki”.

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: app-namespace
spec:
  podSelector: {}          # dotyczy wszystkich podów w namespace
  policyTypes:
    - Ingress
    - Egress
  # brak sekcji ingress i egress = deny all
```

* Po zastosowaniu żadien pod nie będzie mógł:

    * otrzymywać ruchu (Ingress)
    * wysyłać ruchu (Egress)
      dopóki nie dodasz innych polityk.

---

## 2. Pozwolenie tylko na ruch wewnątrz namespace

Chcemy, żeby pody mogły się komunikować **tylko** z innymi podami w tym samym namespace.

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-same-namespace
  namespace: app-namespace
spec:
  podSelector: {}           # dotyczy wszystkich podów
  policyTypes:
    - Ingress
    - Egress

  ingress:
  - from:
    - podSelector: {}       # dowolny pod w tym samym ns

  egress:
  - to:
    - podSelector: {}       # dowolny pod w tym samym ns
```

* **Ingress**: ruch przychodzący tylko z pods w `app-namespace`.
* **Egress**: ruch wychodzący tylko do pods w `app-namespace`.

---

## 3. Ograniczenie dostępu do bazy danych (Ingress)

Scenariusz: mamy pody aplikacji (`app=frontend`) i bazy (`app=postgresql`). Chcemy, żeby tylko frontendy mogły się łączyć do bazy na porcie 5432.

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-db-access
  namespace: data-namespace
spec:
  podSelector:
    matchLabels:
      app: postgresql

  policyTypes:
    - Ingress

  ingress:
  - from:
    - namespaceSelector:
        matchLabels:
          name: app-namespace   # albo matchLabels: { team: frontend }
      podSelector:
        matchLabels:
          app: frontend
    ports:
    - protocol: TCP
      port: 5432
```

* **`podSelector`** wskazuje pody Postgresa.
* **`from`** określa, że tylko pody oznaczone `app=frontend` w namespace’u o labelu `name=app-namespace` mogą nawiązać połączenie TCP na 5432.

---

## 4. Kontrola egress do zewnętrznego API (Egress)

Scenariusz: kontener w namespace’u `payments` może wysyłać ruch HTTP tylko do zewnętrznego API pod IP `203.0.113.5`, port 443.

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-external-api
  namespace: payments
spec:
  podSelector: {}             # wszystkie pody w payments
  policyTypes:
    - Egress

  egress:
  - to:
    - ipBlock:
        cidr: 203.0.113.5/32
    ports:
    - protocol: TCP
      port: 443
```

* Tylko ruch HTTPS do podanego IP będzie przepuszczony.
* Inny egress (np. DNS czy inne IP) zostanie zablokowany, jeśli nie ma innych polityk.

---

## 5. Przykład mieszany: aplikacja mikroserwisowa

Mamy namespace `microservices` z trzema serwisami:

* **frontend** (label `app=frontend`)
* **backend**  (label `app=backend`)
* **db**       (label `app=db`)

Chcemy:

1. **Domyślnie** zablokować cały ruch (Ingress + Egress).
2. **Frontend**:

    * może wysyłać HTTP (80) do backend
    * może odbierać ruch od dowolnego klienta z zewnątrz
3. **Backend**:

    * może odbierać ruch tylko z frontendu (port 8080)
    * może wysyłać ruch do bazy (port 5432)
4. **DB**:

    * może przyjmować ruch tylko od backend (5432)

### 5.1. Default deny

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: microservices
spec:
  podSelector: {}
  policyTypes:
  - Ingress
  - Egress
```

### 5.2. Frontend policy

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: frontend-policy
  namespace: microservices
spec:
  podSelector:
    matchLabels:
      app: frontend
  policyTypes:
  - Ingress
  - Egress

  # Ingress: allow from anywhere on port 80
  ingress:
  - from:
    - ipBlock:
        cidr: 0.0.0.0/0
    ports:
    - protocol: TCP
      port: 80

  # Egress: allow to backend:8080
  egress:
  - to:
    - podSelector:
        matchLabels:
          app: backend
    ports:
    - protocol: TCP
      port: 8080
```

### 5.3. Backend policy

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: backend-policy
  namespace: microservices
spec:
  podSelector:
    matchLabels:
      app: backend
  policyTypes:
  - Ingress
  - Egress

  # Ingress: only from frontend:80
  ingress:
  - from:
    - podSelector:
        matchLabels:
          app: frontend
    ports:
    - protocol: TCP
      port: 80

  # Egress: only to db:5432
  egress:
  - to:
    - podSelector:
        matchLabels:
          app: db
    ports:
    - protocol: TCP
      port: 5432
```

### 5.4. DB policy

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: db-policy
  namespace: microservices
spec:
  podSelector:
    matchLabels:
      app: db
  policyTypes:
  - Ingress

  # Ingress: only from backend
  ingress:
  - from:
    - podSelector:
        matchLabels:
          app: backend
    ports:
    - protocol: TCP
      port: 5432
```
