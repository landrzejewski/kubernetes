**Wprowadzenie**

Współczesne aplikacje konteneryzowane często wymagają przechowywania danych wrażliwych, takich jak hasła, tokeny dostępu czy certyfikaty. Kubernetes udostępnia mechanizm **Secrets**, który pozwala na bezpieczne zarządzanie tego typu informacjami w klastrze. Celem tego artykułu jest przedstawienie podstawowych koncepcji związanych z Kubernetes Secrets, omówienie metod tworzenia i wykorzystania ich w zasobach klastra oraz wskazanie najlepszych praktyk, które ułatwią zachowanie bezpieczeństwa i elastyczności w zarządzaniu danymi wrażliwymi.

---

## 1. Czym są Secrets w Kubernetes?

**Secret** w Kubernetes to obiekt, którego celem jest przechowywanie i udostępnianie danych wrażliwych (takich jak hasła, klucze szyfrujące, tokeny API, pliki certyfikatów) w sposób odizolowany od reszty konfiguracji aplikacji. W odróżnieniu od obiektów ConfigMap, które są optymalizowane pod kątem przechowywania niepoufnych ustawień (np. parametrów konfiguracyjnych), Secrets są zaprojektowane z myślą o ograniczeniu dostępu i możliwości odszyfrowania zawartości tylko tym podom lub użytkownikom, którzy faktycznie ich potrzebują.

#### Kluczowe cechy Secrets:

1. **Kodowanie Base64**
   Dane przechowywane w obiekcie Secret są domyślnie kodowane w Base64 (nie szyfrowane!). Oznacza to, że trzon bezpieczeństwa opiera się na kontroli dostępu (RBAC, RoleBindings) i (opcjonalnie) szyfrowaniu w lokacji (Encryption at Rest), a nie na prostym zakodowaniu wartości.

2. **Integracja z Podami**
   Secrets można montować w postaci wolumenów (jako pliki) lub wstrzykiwać jako zmienne środowiskowe do kontenerów.

3. **Różne typy**

    * `Opaque` (ogólny typ, dowolne pary klucz–wartość zakodowane w Base64)
    * `docker-registry` (przechowywanie poświadczeń do prywatnych rejestrów obrazów)
    * `tls` (przechowuje certyfikat TLS i klucz prywatny)
    * inne, np. `bootstrap.kubernetes.io/token`

---

## 2. Dlaczego warto korzystać z Secrets?

1. **Segragacja dostępu**
   Wartości przechowywane w Secret są odseparowane od kodu aplikacji i manifestów. Dzięki temu można ograniczyć dostęp do wrażliwych danych tylko do wybranych użytkowników lub serwisów (RBAC).

2. **Łatwiejsza rotacja poświadczeń**
   Zamiast hardkodować hasła w plikach YAML, łatwiej jest zaktualizować wartość Secret i odtworzyć połączenia, nie zmieniając manifestów Deployment.

3. **Zautomatyzowane szyfrowanie w etcd (Encryption at Rest)**
   W przypadku włączenia szyfrowania danych at rest w etcd (klucz `EncryptionConfiguration`), wartości Secret są dodatkowo szyfrowane w bazie danych klastra.

4. **Integracja z narzędziami zewnętrznymi**
   – Możliwość synchronizacji z HashiCorp Vault, AWS Secrets Manager, Azure Key Vault itp., dzięki czemu Kubernetes Secrets mogą być automatycznie odświeżane.

---

## 3. Tworzenie Secret: podstawowe metody

### 3.1. Tworzenie za pomocą `kubectl create secret`

Najprostszą metodą jest użycie komendy `kubectl create secret`. Przykład: chcemy przechować hasło do bazy danych:

```bash
# 1. Zakładamy, że nasz użytkownik DB to "admin", a hasło to "S3kretn3H@sło"
kubectl create secret generic db-credentials \
  --from-literal=username=admin \
  --from-literal=password=S3kretn3H@sło \
  --namespace=prod
```

Wyjaśnienie:

* `generic` – typ Secret (`Opaque`).
* `db-credentials` – nazwa Secret.
* `--from-literal` – tworzy parę klucz=wartość, która zostanie zakodowana w Base64.
* `--namespace=prod` – (opcjonalnie) namespace, w którym tworzymy Secret.

Po wykonaniu komendy:

```shell
$ kubectl get secrets -n prod
NAME             TYPE     DATA   AGE
db-credentials   Opaque   2      5s
```

Możemy podejrzeć szczegóły (wartości zakodowane w Base64):

```bash
kubectl get secret db-credentials -n prod -o yaml
```

Przykładowa odpowiedź:

```yaml
apiVersion: v1
data:
  password: UzNrcmV0bjJIYXNsw7N3  # Base64("S3kretn3H@sło")
  username: YWRtaW4=              # Base64("admin")
kind: Secret
metadata:
  name: db-credentials
  namespace: prod
type: Opaque
```

Aby odszyfrować wartość, można użyć:

```bash
$ echo "UzNrcmV0bjJIYXNsw7N3" | base64 --decode
S3kretn3H@sło
```

---

### 3.2. Tworzenie z plików lokalnych

Często chcemy wczytać certyfikat lub plik z hasłem spoza wiersza poleceń:

```bash
# Zakładamy, że mamy plik `ca.crt`, `tls.crt` i `tls.key` w katalogu lokalnym
kubectl create secret tls my-tls-secret \
  --cert=./tls.crt \
  --key=./tls.key \
  --namespace=prod
```

Komenda tworzy Secret typu `kubernetes.io/tls`, który zawiera:

* `tls.crt` (certyfikat publiczny)
* `tls.key` (klucz prywatny)

Alternatywnie, aby wgrać dowolne pliki do Secret Opaque:

```bash
kubectl create secret generic app-files-secret \
  --from-file=config.json=./config.json \
  --from-file=credentials.txt=./credentials.txt \
  --namespace=prod
```

Każdy plik zostanie zakodowany w Base64 i umieszczony jako wartość odpowiadającego mu klucza (`config.json`, `credentials.txt`).

---

### 3.3. Definicja YAML

Przykład definicji Secret w czystym YAML (bez użycia `kubectl create`):

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: db-credentials
  namespace: prod
type: Opaque
data:
  username: YWRtaW4=                # Base64("admin")
  password: UzNrcmV0bjJIYXNsw7N3      # Base64("S3kretn3H@sło")
```

1. Zakoduj wartości w Base64:

   ```bash
   echo -n "admin" | base64      # zwróci: YWRtaW4=
   echo -n "S3kretn3H@sło" | base64  # zwróci: UzNrcmV0bjJIYXNsw7N3
   ```
2. Wstaw je do pola `data:` w manifeście.

Następnie:

```bash
kubectl apply -f secret-db-credentials.yaml
```

---

## 4. Wykorzystanie Secret w Podach i Deploymentach

### 4.1. Wstrzykiwanie jako zmienne środowiskowe

Najłatwiej jest odczytać wartości Secret jako zmienne środowiskowe w kontenerze:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: my-app
  namespace: prod
spec:
  replicas: 2
  selector:
    matchLabels:
      app: my-app
  template:
    metadata:
      labels:
        app: my-app
    spec:
      containers:
        - name: my-app-container
          image: example/my-app:1.0
          env:
            - name: DB_USER
              valueFrom:
                secretKeyRef:
                  name: db-credentials
                  key: username
            - name: DB_PASS
              valueFrom:
                secretKeyRef:
                  name: db-credentials
                  key: password
```

**Wyjaśnienie:**

* `valueFrom.secretKeyRef.name` – nazwa Secret (`db-credentials`).
* `key` – nazwa konkretnego klucza w obiekcie Secret (`username` lub `password`).
* W kontenerze będą dostępne zmienne środowiskowe:

    * `DB_USER=admin`
    * `DB_PASS=S3kretn3H@sło`

### 4.2. Montowanie jako wolumen (pliki)

Często certyfikaty TLS czy pliki konfiguracyjne chcemy mieć dostępnymi jako pliki w systemie plików kontenera:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: pod-with-secret-vol
  namespace: prod
spec:
  containers:
    - name: nginx
      image: nginx:1.21
      volumeMounts:
        - name: tls-volume
          mountPath: "/etc/nginx/tls"
          readOnly: true
  volumes:
    - name: tls-volume
      secret:
        secretName: my-tls-secret
```

Efekt:

* W ścieżce `/etc/nginx/tls/tls.crt` znajdzie się certyfikat
* W `/etc/nginx/tls/tls.key` – klucz prywatny

### 4.3. Użycie w plikach konfiguracyjnych (ConfigMap + Secret)

Czasami konfiguracja wymaga połączenia danych z ConfigMap i Secret. Przykład: plik `database.properties` w ConfigMap odwołuje się do zmiennych środowiskowych, które pochodzą z Secret:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: app-config
  namespace: prod
data:
  application.properties: |
    db.url=jdbc:postgresql://db-service:5432/mydb
    db.user=${DB_USER}
    db.password=${DB_PASS}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: my-app
  namespace: prod
spec:
  replicas: 1
  selector:
    matchLabels:
      app: my-app
  template:
    metadata:
      labels:
        app: my-app
    spec:
      containers:
        - name: my-app
          image: example/my-app:1.0
          env:
            - name: DB_USER
              valueFrom:
                secretKeyRef:
                  name: db-credentials
                  key: username
            - name: DB_PASS
              valueFrom:
                secretKeyRef:
                  name: db-credentials
                  key: password
          volumeMounts:
            - name: config-volume
              mountPath: /app/config
              readOnly: true
      volumes:
        - name: config-volume
          configMap:
            name: app-config
```

W ten sposób w kontenerze będzie dostępny plik `application.properties`, w którym zmienne `${DB_USER}` i `${DB_PASS}` zostaną rozwinięte przez logikę aplikacji. (Uwaga: niektóre frameworki pobierają zmienne środowiskowe bezpośrednio; w takim przypadku wystarczy użyć env).

---

## 5. Dodatkowe typy Secret

### 5.1. Secret typu `docker-registry`

Jeżeli aplikacja potrzebuje pobrać obraz z prywatnego rejestru, możemy utworzyć typ Secret `kubernetes.io/dockerconfigjson`, np.:

```bash
kubectl create secret docker-registry regcred \
  --docker-server=registry.example.com \
  --docker-username=jan.kowalski \
  --docker-password=S3kretn3Haslo \
  --docker-email=jan.kowalski@example.com \
  --namespace=prod
```

Następnie w Deployment:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: private-app
  namespace: prod
spec:
  replicas: 1
  template:
    spec:
      imagePullSecrets:
        - name: regcred
      containers:
        - name: private-app-container
          image: registry.example.com/private-app:latest
```

Dzięki temu kubelet wie, gdzie i jak się uwierzytelnić, aby pobrać obraz.

### 5.2. Secret typu `tls`

Tworzenie Secret z certyfikatem TLS:

```bash
# Załóżmy, że mamy `tls.crt` i `tls.key`
kubectl create secret tls frontend-tls --cert=./tls.crt --key=./tls.key --namespace=prod
```

Użycie w Ingress:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: frontend-ingress
  namespace: prod
spec:
  tls:
    - hosts:
        - www.example.com
      secretName: frontend-tls
  rules:
    - host: www.example.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: frontend-svc
                port:
                  number: 80
```

Ingress Controller odczyta certyfikat z Secret i skonfiguruje TLS dla domeny `www.example.com`.

---

## 6. Najlepsze praktyki (Best Practices)

### 6.1. Włącz szyfrowanie danych at rest w etcd

Domyślnie wartości Secret są zapisywane w etcd w postaci zakodowanej Base64, ale nie są szyfrowane. Zalecane jest włączenie szyfrowania **EncryptionConfiguration**, aby chronić dane wrażliwe również w momencie przechowywania:

```yaml
apiVersion: apiserver.config.k8s.io/v1
kind: EncryptionConfiguration
resources:
  - resources:
      - secrets
    providers:
      - aescbc:
          keys:
            - name: key1
              secret: YOUR_BASE64_ENCODED_32BYTE_KEY
      - identity: {}
```

Po zaktualizowaniu konfiguracji controller-managera (argument `--encryption-provider-config`), nowe Secret będą szyfrowane. Pamiętaj o rotacji kluczy i bezpiecznym przechowywaniu ich poza klastrem.

### 6.2. Ogranicz dostęp za pomocą RBAC

Nie wszyscy użytkownicy lub usługi muszą mieć dostęp do każdego Secret. Skonfiguruj **Role** i **RoleBinding** (lub **ClusterRole** / **ClusterRoleBinding**), by przydzielić uprawnienia tylko tym podmiotom, które faktycznie ich potrzebują. Przykład:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: secret-reader
  namespace: prod
rules:
  - apiGroups: [""]
    resources: ["secrets"]
    resourceNames: ["db-credentials"]
    verbs: ["get"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: bind-secret-reader
  namespace: prod
subjects:
  - kind: ServiceAccount
    name: my-app-sa
    namespace: prod
roleRef:
  kind: Role
  name: secret-reader
  apiGroup: rbac.authorization.k8s.io
```

Dzięki temu serwisowa konta `my-app-sa` (używana przez Deployment) będzie mogła jedynie odczytać Secret `db-credentials`, ale nie zarządzać innymi Secret.

### 6.3. Nie przechowuj wrażliwych danych w repozytorium kodu

Unikaj commitowania plików z zakodowanymi na stałe secretami (np. Base64). Zamiast tego, stosuj:

* Narzędzia do szablonów (Helm, Kustomize), które mogą wstrzykiwać wartości w sposób bezpieczny z systemów zarządzania kluczami.
* Zewnętrzne menedżery sekretów (HashiCorp Vault, AWS Secrets Manager). Wówczas kontenery mogą odpytywać zaufane źródło w czasie uruchomienia.

### 6.4. Rotacja haseł i kluczy

Z czasem hasła i klucze powinny być rotowane. Można to zautomatyzować:

1. Aktualizacja wartości w Secret (`kubectl apply -f ...` lub `kubectl create secret --dry-run` + `-o yaml | kubectl apply`).
2. Wymuszenie restartu Deploymentów, by kontenery odczytały nowe wartości (np. `kubectl rollout restart deployment my-app`).

### 6.5. Monitorowanie i audyt

* Włącz audyt w Kubernetes API, by śledzić operacje na obiektach Secret.
* Regularnie przeglądaj logi Kubernetes Audit Log, by zidentyfikować nietypowe próby dostępu.

---

## 7. Przykładowy scenariusz: Od A do Z

Poniżej znajduje się przykładowy workflow wdrożenia aplikacji webowej, która korzysta z bazy danych PostgreSQL. Aplikacja potrzebuje poświadczeń w postaci loginu i hasła (traktowanych jako Secret).

1. **Tworzenie Secret**

   ```bash
   # Kodujemy login i hasło do Base64
   echo -n "appuser" | base64    # YXBwdXNlcg==
   echo -n "TopS3kr3t!" | base64  # VG9wUzNrcjN0IQ==

   cat <<EOF > secret-postgres.yaml
   apiVersion: v1
   kind: Secret
   metadata:
     name: postgres-credentials
     namespace: prod
   type: Opaque
   data:
     username: YXBwdXNlcg==
     password: VG9wUzNrcjN0IQ==
   EOF

   kubectl apply -f secret-postgres.yaml
   ```

2. **Deployment bazy danych (z wykorzystaniem Secret)**
   Deployment manifest (`postgres-deployment.yaml`):

   ```yaml
   apiVersion: apps/v1
   kind: Deployment
   metadata:
     name: postgres
     namespace: prod
   spec:
     replicas: 1
     selector:
       matchLabels:
         app: postgres
     template:
       metadata:
         labels:
           app: postgres
       spec:
         containers:
           - name: postgres
             image: postgres:14
             env:
               - name: POSTGRES_USER
                 valueFrom:
                   secretKeyRef:
                     name: postgres-credentials
                     key: username
               - name: POSTGRES_PASSWORD
                 valueFrom:
                   secretKeyRef:
                     name: postgres-credentials
                     key: password
             ports:
               - containerPort: 5432
         # wolumen do przechowywania danych
         volumes:
           - name: pgdata
             emptyDir: {}
   ```

   W ten sposób kontener Postgresa uruchomi się z właściwymi poświadczeniami.

3. **Deployment aplikacji (konsumpcja Secret)**
   Aplikacja w Spring Boot (przykładowo) potrzebuje połączenia do bazy, więc definiujemy:

   ```yaml
   apiVersion: apps/v1
   kind: Deployment
   metadata:
     name: web-app
     namespace: prod
   spec:
     replicas: 2
     selector:
       matchLabels:
         app: web-app
     template:
       metadata:
         labels:
           app: web-app
       spec:
         containers:
           - name: web-app-container
             image: example/web-app:2.1
             env:
               - name: SPRING_DATASOURCE_URL
                 value: jdbc:postgresql://postgres:5432/mydb
               - name: SPRING_DATASOURCE_USERNAME
                 valueFrom:
                   secretKeyRef:
                     name: postgres-credentials
                     key: username
               - name: SPRING_DATASOURCE_PASSWORD
                 valueFrom:
                   secretKeyRef:
                     name: postgres-credentials
                     key: password
             ports:
               - containerPort: 8080
   ```

4. **Weryfikacja działania**

   ```bash
   # Sprawdź, czy Secret istnieje
   kubectl get secret postgres-credentials -n prod -o yaml

   # Sprawdź status Deployment
   kubectl get deployments -n prod
   kubectl get pods -n prod

   # Zaloguj się do jednego z podów web-app i spróbuj połączyć się do Postgresa
   kubectl exec -it <web-app-pod-name> -n prod -- /bin/sh

   # W środku kontenera:
   env | grep SPRING_DATASOURCE_    # powinna wyświetlić wartości zmiennych środowiskowych
   ```

---

## 8. Dodatkowe narzędzia i rozszerzenia

### 8.1. SealedSecrets (Bitnami/External Secrets)

**SealedSecrets** to projekt, który umożliwia szyfrowanie Secret offline i przechowywanie ich w repozytorium Git w postaci bezpiecznego, zaszyfrowanego obiektu (SealedSecret). Proces:

1. `kubeseal` (klient) pobiera publiczny klucz z klastra.
2. Użytkownik szyfruje lokalne pliki (np. `secret.yaml`) do `sealedsecret.yaml`.
3. Zaszyfrowany obiekt (SealedSecret) trafia w repozytorium.
4. Kontroler SealedSecrets w klastrze odszyfrowuje i tworzy standardowy Secret.

**Przykład:**

```bash
# 1. Instalacja SealedSecrets controller w klastrze:
kubectl apply -f https://github.com/bitnami-labs/sealed-secrets/releases/download/v0.23.0/controller.yaml

# 2. Utworzenie lokalnego Secret (unencrypted):
cat <<EOF > db-secret.yaml
apiVersion: v1
kind: Secret
metadata:
  name: db-secret
  namespace: prod
type: Opaque
data:
  username: YXBkbWlu
  password: U2VjdXJlUGFzc3dvcmQ=
EOF

# 3. Pobranie klucza publicznego i zaszyfrowanie:
kubeseal --format yaml < db-secret.yaml > sealed-db-secret.yaml

# 4. sealed-db-secret.yaml przechowujemy w repozytorium. Kontroler automatycznie utworzy Secret w klastrze.
kubectl apply -f sealed-db-secret.yaml
```

### 8.2. External Secrets

Kolejna metoda polega na integracji z zewnętrznym systemem zarządzania sekretami (Vault, AWS Secrets Manager) za pomocą CRD `ExternalSecret`. Wówczas klaster ściąga wartości bezpośrednio z zewnętrznego dostawcy i tworzy standardowy Secret.
