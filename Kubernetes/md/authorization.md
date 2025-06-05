## Wprowadzenie

W środowisku Kubernetes (k8s) zarządzanie dostępem do zasobów klastra jest kluczowym aspektem bezpieczeństwa i stabilności. W artykule omówimy podstawowe mechanizmy uwierzytelniania i autoryzacji wykorzystywane w Kubernetes, zwłaszcza:

1. **Users** – użytkownicy zewnętrzni i ich uwierzytelnianie do API Serwera.
2. **Service Accounts** – konta serwisowe wykorzystywane przez komponenty działające wewnątrz klastra, np. pod’y.
3. **RBAC Admission Controller** – mechanizm autoryzacji oparty na rolach (Role-Based Access Control), który decyduje, czy dany podmiot (user lub ServiceAccount) ma prawo wykonać określoną akcję.

Każda z tych warstw pełni odrębną rolę w łańcuchu bezpieczeństwa Kubernetes. W dalszej części artykułu omówimy szczegółowo ich funkcjonowanie, przedstawimy przykłady konfiguracji oraz pokażemy, jak używać RBAC Admission Controller, aby nadawać uprawnienia w sposób precyzyjny i bezpieczny.

---

## 1. Uwierzytelnianie w Kubernetes – rola „Users”

### 1.1. Czym są „Users” w Kubernetes?

Kubernetes nie posiada wbudowanego systemu zarządzania kontami użytkowników. Zamiast tego korzysta z zewnętrznych mechanizmów uwierzytelniania, takich jak:

* **Klucze certyfikatów TLS/SSL** (certificate authentication).
* **Tokeny** (bearer tokens) – często JWT generowane przez OpenID Connect.
* **Basic Auth** (login i hasło) – **niezalecane** w produkcji.
* **Service Account Tokens** – autentykacja kont serwisowych.
* **Webhook token authentication** – oddelegowanie uwierzytelniania do zewnętrznego serwisu.

**User** to podmiot (osoba lub zewnętrzna aplikacja), która uzyskuje dostęp do API Servera i stara się wywołać operacje CRUD na zasobach (np. węzły, pod’y, ConfigMapy, itp.). W dokumentacji Kubernetes “user” jest bytem logicznym reprezentującym tożsamość podmiotu próbującego uwierzytelnić się do API.

#### 1.1.1. Rozróżnienie „Userów” i „ServiceAccountów”

* **Users** (w sensie Kubernetes) to podmioty uwierzytelniane na zewnątrz, np. administratorzy, deweloperzy bądź zewnętrzne procesy (CI/CD). Kubernetes nie przechowuje obiektów „User” w etcd.
* **ServiceAccounts** (obiekty typu ServiceAccount) tworzone są wewnątrz klastra i służą autoryzacji aplikacji wykonywanych w podach. Wykorzystują one wbudowane tokeny JWT przypisane do konta w namespace. Obiekty ServiceAccount są przechowywane w etcd jako natywne zasoby Kubernetes.

### 1.2. Uwierzytelnianie z wykorzystaniem certyfikatów TLS

Jednym z najczęściej stosowanych w produkcji sposobów uwierzytelniania „Userów” jest generowanie certyfikatów TLS. Proces wygląda następująco:

1. **Generacja klucza prywatnego (private key)** dla użytkownika.
2. **Stworzenie wniosku o podpisanie certyfikatu (CSR)**, w którym określa się nazwę podmiotu (`CN` – Common Name).
3. **Podpisanie CSR** za pomocą Certyfikatu CA (Certificate Authority) wykorzystywanego przez API Server k8s.
4. **Konfiguracja kubeconfig** – w pliku kubeconfig użytkownika umieszczony jest certyfikat klienta i klucz prywatny oraz informacje o serwerze API.

#### 1.2.1. Przykład generacji certyfikatu dla użytkownika

```bash
# 1. Generacja klucza prywatnego
openssl genrsa -out alice.key 2048

# 2. Generacja CSR z CN=alice i opcjonalnym flagiem dla grup
openssl req -new -key alice.key -out alice.csr -subj "/CN=alice/O=developers"

# 3. Podpisanie CSR przez CA (zakładamy, że dysponujemy plikami ca.crt i ca.key)
openssl x509 -req -in alice.csr -CA ca.crt -CAkey ca.key -CAcreateserial -out alice.crt -days 365

# 4. Utworzenie wpisu dla użytkownika 'alice' w kubeconfig
kubectl config set-credentials alice \
  --client-certificate=alice.crt \
  --client-key=alice.key

# 5. Dodanie kontekstu (opcjonalnie):
kubectl config set-context alice-context \
  --cluster=my-cluster \
  --user=alice

# 6. Przełączenie na kontekst (aby testować uwierzytelnianie):
kubectl config use-context alice-context
```

W powyższym przykładzie:

* `CN=alice` (Common Name) to nazwa podmiotu, którą Kubernetes będzie rozpoznawał jako nazwę użytkownika.
* `O=developers` (Organization) definiuje grupę, do której użytkownik należy; można definiować wiele grup przez powtarzanie flagi `-subj "/CN=.../O=group1/O=group2"`.

Po wgraniu certyfikatu i przełączeniu kontekstu użytkownik `alice` jest uwierzytelniany na podstawie certyfikatu. W dalszym kroku należy przyznać mu odpowiednie uprawnienia za pomocą RBAC (opis w rozdziale 3).

---

## 2. Service Accounts

### 2.1. Co to jest ServiceAccount?

**ServiceAccount** to wbudowany zasób Kubernetes, którego zadaniem jest reprezentowanie tożsamości używanej przez procesy (kontenery/pody) działające wewnątrz klastra. W przeciwieństwie do „Users”, ServiceAccount’y są obiektami natywnymi, które można tworzyć, usuwać i modyfikować jak każdy inny zasób Kubernetes (np. Deployment, ConfigMap).

Cechy ServiceAccount:

* Każdy namespace domyślnie otrzymuje konto serwisowe o nazwie `default`. Kontenery uruchamiane w danym namespace, jeśli nie wskazano inaczej, automatycznie otrzymują token, który łączy się z `ServiceAccount default`.
* Tokeny ServiceAccount są montowane automatycznie do podów (przez wolumen typu `Projected` lub `Secret`), chyba że jawnie wyłączono tę funkcjonalność.
* Token przypisany do ServiceAccount to JWT (JSON Web Token), który zawiera informacje o:

    * nazwie ServiceAccount (pole `sub` – subject i `kubernetes.io/serviceaccount/service-account.name`),
    * namespace,
    * ewentualnych grupach (`kubernetes.io/serviceaccount/service-account.group`).
* Token ten można wykorzystać do komunikacji z API Serverem, co pozwala aplikacjom wewnątrz klastra na autoryzację działań w imieniu konta serwisowego.

### 2.2. Tworzenie i wykorzystywanie ServiceAccount w podach

#### 2.2.1. Przykład tworzenia ServiceAccount

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: worker-sa
  namespace: dev-environment
```

Powyższy YAML należy zastosować poleceniem:

```bash
kubectl apply -f worker-serviceaccount.yaml
```

Spowoduje to utworzenie w namespace `dev-environment` konta serwisowego `worker-sa`.

#### 2.2.2. Montowanie tokenu do poda

Gdy tworzymy Pod lub Deployment, możemy jawnie wskazać, które ServiceAccount chcemy użyć. Przykład:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: worker-deployment
  namespace: dev-environment
spec:
  replicas: 2
  selector:
    matchLabels:
      app: worker-app
  template:
    metadata:
      labels:
        app: worker-app
    spec:
      serviceAccountName: worker-sa   # <-- wskazanie ServiceAccount
      containers:
      - name: worker-container
        image: myregistry/myworkerapp:latest
        # Opcjonalnie, możemy pobrać token w kontenerze:
        volumeMounts:
        - name: token-volume
          mountPath: /var/run/secrets/kubernetes.io/serviceaccount
          readOnly: true
      volumes:
      - name: token-volume
        projected:
          sources:
          - serviceAccountToken:
              path: token
              # TTL tokenu w sekundach
              expirationSeconds: 3600
```

W powyższym przykładzie:

* `serviceAccountName: worker-sa` – kontener będzie używał ServiceAccount `worker-sa`. Jeżeli nie zostanie podany żaden ServiceAccount, to wykorzystane zostanie konto `default` w danym namespace.
* Sekcja `projected` w `volumes` pokazuje, jak odczytać token i pliki CA (np. `ca.crt`) w kontenerze. Dzięki temu aplikacja działająca w kontenerze może uwierzytelniać się w API Serwerze, odwołując się do ścieżki `/var/run/secrets/kubernetes.io/serviceaccount/token`.

### 2.3. Tokeny i automatyczne rotowanie

W nowszych wersjach Kubernetes (>= 1.20) domyślnie włączone jest automatyczne rotowanie tokenów ServiceAccount. Oznacza to, że token przypisany do ServiceAccount w podzie ma ograniczony czas ważności (np. 1 godzina), a kubelet automatycznie pobiera od API nowe tokeny i uaktualnia je w podzie, zanim wygaśnie. Dzięki temu zmniejsza się ryzyko długotrwałego narażenia w przypadku wycieku tokenu.

* Token standardowo dostępny jest w ścieżce:

  ```
  /var/run/secrets/kubernetes.io/serviceaccount/token
  ```
* Plik `ca.crt` umożliwia aplikacji zweryfikowanie tożsamości API Servera, co zabezpiecza przed atakami typu man-in-the-middle.

### 2.4. Różnice między ServiceAccount a użytkownikiem „normalnym”

| Cecha                            | User (Kubernetes)                                           | ServiceAccount                                             |
| -------------------------------- | ----------------------------------------------------------- | ---------------------------------------------------------- |
| Przechowywany w etcd             | **Nie** (brak obiektów typu User)                           | **Tak** (zapisane jako obiekt `ServiceAccount`)            |
| Mechanizm uwierzytelniania       | Zewnętrzne (certyfikaty TLS, tokeny OIDC, Basic Auth, itp.) | Automatyczne tokeny JWT montowane do poda                  |
| Zakres obowiązywania             | Podmiot zewnętrzny (developer, CI/CD, itp.)                 | Podmiot wewnątrz klastra (pod, operator, kontroler)        |
| Automatyczne rotowanie tokena    | Nie (tokeny muszą być ręcznie odnawiane, jeśli wygasną)     | Tak (jeśli włączone rotowanie tokenów w Kubernetes >=1.20) |
| Przykładowa ścieżka w kubeconfig | `users[ ].user.client-certificate`                          | `/var/run/secrets/kubernetes.io/serviceaccount/token`      |

---

## 3. RBAC (Role-Based Access Control)

### 3.1. Zarys mechanizmu RBAC

RBAC to główny mechanizm autoryzacji w Kubernetes od wersji 1.6. Umożliwia zdefiniowanie:

* **Role** (poziom namespace) oraz **ClusterRole** (poziom całego klastra),
* **RoleBinding** (przypisanie Role do Userów lub ServiceAccounts w określonym namespace) oraz **ClusterRoleBinding** (przypisanie ClusterRole w skali klastra).

W RBAC definiujemy *cztery* główne typy zasobów:

1. **Role** – zdefiniowane w konkretnym namespace. Określają, jakie zasoby i jakie operacje (akcje) można wykonywać w tym namespace.
2. **ClusterRole** – zdefiniowane w całym klastrze. Mogą być wykorzystywane w RoleBindingach w każdym namespace lub bezpośrednio w ClusterRoleBinding. Stosuje się je do uprawnień ogólnoklastrowych (np. dostęp do węzłów, PersistentVolumes itp.).
3. **RoleBinding** – przypisuje Role do podmiotu (User lub ServiceAccount) w określonym namespace.
4. **ClusterRoleBinding** – przypisuje ClusterRole w skali całego klastra do podmiotu (User lub ServiceAccount).

Dzięki temu administratorzy mogą precyzyjnie określać, kto i jakie ma uprawnienia w klastrze.

### 3.2. Składnia i przykłady definiowania RBAC

#### 3.2.1. Tworzenie Role (namespace-level)

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: pod-reader
  namespace: dev-environment
rules:
- apiGroups: [""]                         # "" oznacza główną grupę API (pods, services, configmaps itp.)
  resources: ["pods"]                    # zasoby, do których uprawnienia się odnoszą
  verbs: ["get", "watch", "list"]         # dozwolone operacje: odczyt danych (GET), LIST, WATCH
```

Opis:

* **apiGroups** – lista grup API (główna pusta grupa to `""`).
* **resources** – lista zasobów (np. `pods`, `services`, `configmaps`).
* **verbs** – lista akcji (`get`, `list`, `watch`, `create`, `update`, `delete`, `patch`, `deletecollection`).

Role `pod-reader` pozwoli na odczytywanie listy i szczegółów Podów w namespace `dev-environment`.

#### 3.2.2. Tworzenie RoleBinding

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: read-pods-binding
  namespace: dev-environment
subjects:
- kind: User                              # podmiotem jest użytkownik typu 'User'
  name: alice                             # taki sam CN jak w certyfikacie TLS
  apiGroup: rbac.authorization.k8s.io
- kind: ServiceAccount                    # można dodać więcej niż jeden podmiot
  name: worker-sa
  namespace: dev-environment
roleRef:
  kind: Role
  name: pod-reader
  apiGroup: rbac.authorization.k8s.io
```

Wyjaśnienie:

* **subjects** – lista podmiotów, którym przyznajemy uprawnienia. Każdy podmiot ma:

    * `kind` – `User` lub `ServiceAccount` lub `Group`.
    * `name` – nazwa podmiotu (dla użytkownika – CN w certyfikacie, dla ServiceAccount – nazwa konta w danym namespace).
    * `namespace` – wymagane tylko, gdy podmiot jest `ServiceAccount`.
* **roleRef** – referencja do Role lub ClusterRole, które chcemy przypisać. W przypadku Role musimy wskazać namespace Role (domyślnie taki sam jak w RoleBinding).

Po zastosowaniu powyższych zasobów użytkownik `alice` i ServiceAccount `worker-sa` w namespace `dev-environment` będą mogli wykonywać akcje GET, LIST, WATCH na zasobie `pods` tylko w tym namespace.

#### 3.2.3. ClusterRole i ClusterRoleBinding

##### Tworzenie ClusterRole

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: namespace-admin
rules:
- apiGroups: [""]                         # podstawowa grupa API
  resources: ["namespaces", "pods", "services", "secrets"]
  verbs: ["*"]                            # wszystkie możliwe operacje
```

**ClusterRole** `namespace-admin` umożliwia wykonywanie wszystkich akcji na zasobach `namespaces`, `pods`, `services` i `secrets` w całym klastrze.

##### Tworzenie ClusterRoleBinding

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: jenkins-admin-binding
subjects:
- kind: ServiceAccount
  name: jenkins-sa
  namespace: ci-namespace
roleRef:
  kind: ClusterRole
  name: namespace-admin
  apiGroup: rbac.authorization.k8s.io
```

W powyższym przykładzie ServiceAccount `jenkins-sa` w namespace `ci-namespace` otrzymuje uprawnienia do zarządzania namespace’ami i zasobami (pods, services, secrets) w całym klastrze. Dzięki temu np. potok CI/CD może dynamicznie tworzyć namespace’y, deployować do nich zasoby i usuwać je po wykonaniu zadań.

---

## 4. Admission Controllers – szczególna rola RBAC Admission

### 4.1. Czym są Admission Controllers?

Admission Controllers to wbudowane (lub ładowane jako pluginy) mechanizmy w API Serverze Kubernetes, które mogą przechwycić żądanie (np. stworzenie nowego obiektu) i je zmodyfikować lub odrzucić na podstawie określonych zasad. Można je podzielić na:

* **Mutating Admission Controllers** – mogą modyfikować (zmieniać) obiekty przed zapisaniem ich w etcd (np. np. uzupełnianie domyślnych wartości, dodawanie adnotacji).
* **Validating Admission Controllers** – tylko walidują, czy żądanie spełnia określone kryteria; w razie niezgodności odrzucają żądanie.

W Kubernetes można włączyć lub wyłączyć poszczególne Admission Controllers poprzez konfigurację flagi `--enable-admission-plugins` w API Serverze. Domyślnie wiele z nich jest włączonych, m.in. `NamespaceLifecycle`, `LimitRanger`, `ServiceAccount` (odpowiadający za weryfikację ServiceAccount i tokenów), a także `RBAC` (właściwy „RBAC Admission Controller” realizujący autoryzację RBAC).

### 4.2. RBAC Admission Controller – zasada działania

**RBAC Admission Controller** to mechanizm weryfikujący, czy uwierzytelniony podmiot (User lub ServiceAccount) ma prawo wykonać daną akcję na wskazanym zasobie. Proces przebiega następująco:

1. **Authentication** – API Server najpierw weryfikuje tożsamość (certyfikaty, tokeny, itp.).
2. **Authorization** – na etapie Admission Controller `RBAC` sprawdzane jest, czy dany podmiot ma przypisane odpowiednie Role/ClusterRole, które pozwalają na wykonanie żądanej operacji (np. `create` na `pods` w namespace `dev-environment`).
3. **Admission** – jeśli podmiot nie ma odpowiednich uprawnień, żądanie jest odrzucane z kodem HTTP 403 Forbidden. W przeciwnym wypadku przyzwala się na modyfikację lub utworzenie zasobu.

Warto zaznaczyć, że Admission Controller RBAC działa zarówno dla jednostkowych zasobów (np. pojedyncze wywołanie `kubectl create pod`), jak i w ramach większych operacji (np. Deployment, StatefulSet, itp.).

### 4.3. Konfiguracja i diagnostyka RBAC Admission Controller

#### 4.3.1. Flagi API Servera

W pliku konfiguracyjnym systemd lub w specyfikacji manifold Kubernetes (np. kubeadm) może pojawić się fragment konfiguracji API Servera podobny do poniższego:

```yaml
apiVersion: kubeadm.k8s.io/v1beta3
kind: ClusterConfiguration
apiServer:
  extraArgs:
    authorization-mode: Node,RBAC
    enable-admission-plugins: NamespaceLifecycle,LimitRanger,ServiceAccount,DefaultStorageClass,ResourceQuota,RBAC
```

Główne flagi:

* `--authorization-mode` – lista mechanizmów autoryzacji, np. `Node` (uprawnienia węzłów), `RBAC`. Kolejność ma znaczenie: jeśli `Node` odrzuci żądanie przed `RBAC`, nie nastąpi dalsze sprawdzenie RBAC.
* `--enable-admission-plugins` – lista aktywnych Admission Controllerów. `RBAC` powinien się znaleźć na liście, by reguły RBAC były faktycznie egzekwowane.

#### 4.3.2. Sprawdzanie działania RBAC

1. **Próba wykonania akcji bez odpowiednich uprawnień**
   Załóżmy, że w namespace `dev-environment` nie przyznaliśmy użytkownikowi `bob` żadnych uprawnień. Jeśli spróbuje utworzyć Pod, otrzyma błąd 403:

   ```bash
   kubectl --user=bob -n dev-environment run test-pod --image=nginx
   ```

   Otrzymamy:

   ```
   Error from server (Forbidden): pods "test-pod" is forbidden: User "bob" cannot create resource "pods" in API group "" in the namespace "dev-environment"
   ```

2. **Nadanie uprawnień i weryfikacja**
   Przykładowo, chcemy, aby `bob` mógł odczytać configmapy w namespace `dev-environment`. Tworzymy Role i RoleBinding:

   ```yaml
   apiVersion: rbac.authorization.k8s.io/v1
   kind: Role
   metadata:
     name: configmap-reader
     namespace: dev-environment
   rules:
   - apiGroups: [""]
     resources: ["configmaps"]
     verbs: ["get", "list", "watch"]
   ---
   apiVersion: rbac.authorization.k8s.io/v1
   kind: RoleBinding
   metadata:
     name: bind-configmap-reader
     namespace: dev-environment
   subjects:
   - kind: User
     name: bob
     apiGroup: rbac.authorization.k8s.io
   roleRef:
     kind: Role
     name: configmap-reader
     apiGroup: rbac.authorization.k8s.io
   ```

   Po zastosowaniu powyższych zasobów `bob` może wykonać:

   ```bash
   kubectl --user=bob -n dev-environment get configmap
   ```

   Natomiast próba utworzenia configmapy nadal zwróci błąd 403.

#### 4.3.3. Diagnostyka – `SubjectAccessReview`

Aby sprawdzić, czy dany podmiot ma uprawnienie do wykonania określonej operacji, można wykorzystać zasób `SelfSubjectAccessReview` lub `SubjectAccessReview`. Najczęściej stosowany jest `SelfSubjectAccessReview`, bo sprawdza uprawnienia aktualnie uwierzytelnionego użytkownika.

Przykład definiowania `SelfSubjectAccessReview`:

```yaml
apiVersion: authorization.k8s.io/v1
kind: SelfSubjectAccessReview
spec:
  resourceAttributes:
    namespace: dev-environment
    verb: create
    group: ""
    resource: configmaps
```

Wysyłamy zapytanie:

```bash
kubectl apply -f selfsubjectaccessreview.yaml
```

Jeśli jesteśmy uwierzytelnieni jako `bob` (np. kontekst kubeconfig), otrzymamy w odpowiedzi:

```yaml
status:
  allowed: false
  denied: true
  evaluationError: ""
  reason: "RBAC: rbac.authorization.k8s.io:subjectaccessreviews ..."
```

Po przyznaniu odpowiednich ról (opisanych w 4.3.2) oraz powtórzeniu `SelfSubjectAccessReview` wynik zmieni się na:

```yaml
status:
  allowed: true
  denied: false
  evaluationError: ""
  reason: "Allowed by rolebinding dev-environment/bind-configmap-reader: Role dev-environment/configmap-reader"
```

---

## 5. Przykładowe scenariusze użycia

Poniżej przedstawiamy kilka typowych scenariuszy, w których wykorzystywane są Users, ServiceAccounts oraz RBAC Admission Controller.

### 5.1. Scenariusz 1: Deweloperzy mają prawo tworzyć i zarządzać tylko swoimi zasobami w dedykowanym namespace

Załóżmy, że mamy zespół deweloperów pracujących w namespace `dev-environment`. Chcemy, aby:

* Deweloper `alice` miał uprawnienia do zarządzania (CRUD) zasobami: `pods`, `deployments`, `services`, `configmaps` w `dev-environment`.
* Deweloper `bob` miał tylko uprawnienia do odczytu zasobów w `dev-environment`.
* Żaden z deweloperów nie miał dostępu do namespace’ów innych zespołów.

#### 5.1.1. Definicja ról

```yaml
# Role: pełne zarządzanie zasobami dla alice
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: dev-editor
  namespace: dev-environment
rules:
- apiGroups: ["", "apps", "extensions"]  # pods, services, deployments, itp.
  resources: ["pods", "deployments", "services", "configmaps", "secrets"]
  verbs: ["*"]

---
# Role: tylko odczyt zasobów dla bob
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: dev-viewer
  namespace: dev-environment
rules:
- apiGroups: ["", "apps", "extensions"]
  resources: ["pods", "deployments", "services", "configmaps", "secrets"]
  verbs: ["get", "list", "watch"]
```

#### 5.1.2. Przypisanie ról (RoleBinding)

```yaml
# RoleBinding dla alice
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: alice-dev-editor-binding
  namespace: dev-environment
subjects:
- kind: User
  name: alice
  apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: Role
  name: dev-editor
  apiGroup: rbac.authorization.k8s.io

---
# RoleBinding dla bob
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: bob-dev-viewer-binding
  namespace: dev-environment
subjects:
- kind: User
  name: bob
  apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: Role
  name: dev-viewer
  apiGroup: rbac.authorization.k8s.io
```

#### 5.1.3. Konfiguracja kubeconfig

**alice kubeconfig**:

```yaml
apiVersion: v1
kind: Config
clusters:
- cluster:
    certificate-authority: /etc/kubernetes/pki/ca.crt
    server: https://api.my-k8s-cluster.example.com:6443
  name: my-cluster
contexts:
- context:
    cluster: my-cluster
    user: alice
    namespace: dev-environment
  name: alice@dev-environment
current-context: alice@dev-environment
users:
- name: alice
  user:
    client-certificate: /home/alice/.kube/alice.crt
    client-key: /home/alice/.kube/alice.key
```

**bob kubeconfig** – analogicznie, ale z certyfikatami boba:

```yaml
apiVersion: v1
kind: Config
clusters:
- cluster:
    certificate-authority: /etc/kubernetes/pki/ca.crt
    server: https://api.my-k8s-cluster.example.com:6443
  name: my-cluster
contexts:
- context:
    cluster: my-cluster
    user: bob
    namespace: dev-environment
  name: bob@dev-environment
current-context: bob@dev-environment
users:
- name: bob
  user:
    client-certificate: /home/bob/.kube/bob.crt
    client-key: /home/bob/.kube/bob.key
```

Po takiej konfiguracji:

* `alice` może wykonywać operacje: `kubectl get pods`, `kubectl create deployment`, `kubectl delete service`, itp.
* `bob` może tylko: `kubectl get pods`, `kubectl describe pod`, `kubectl get configmap`, itp. Próba `kubectl create` lub `delete` zwróci błąd 403.

### 5.2. Scenariusz 2: Aplikacja wewnątrz klastra korzysta z ServiceAccount

Załóżmy, że wdrażamy aplikację typu **operator**, która ma tworzyć i usuwać Custom Resource Definition (CRD) w klastrze, a także odczytywać stan obiektów typu `Deployment` i `StatefulSet` we wszystkich namespace’ach. Dla bezpieczeństwa chcemy, aby operator działał w imieniu osobnego ServiceAccount, a nie w imieniu konta `default`.

#### 5.2.1. Tworzenie ServiceAccount

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: my-operator-sa
  namespace: operator-namespace
```

#### 5.2.2. Definicja ClusterRole z uprawnieniami

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: operator-crd-manager
rules:
  # Zarządzanie CRD (CRD są w grupie apiextensions.k8s.io)
- apiGroups: ["apiextensions.k8s.io"]
  resources: ["customresourcedefinitions"]
  verbs: ["get", "list", "watch", "create", "update", "delete", "patch"]
  # Zarządzanie obiektami typu Deployment i StatefulSet (grupa apps)
- apiGroups: ["apps"]
  resources: ["deployments", "statefulsets"]
  verbs: ["get", "list", "watch", "update", "patch"]
```

#### 5.2.3. Przypisanie ClusterRole do ServiceAccount (ClusterRoleBinding)

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: bind-operator-sa
subjects:
- kind: ServiceAccount
  name: my-operator-sa
  namespace: operator-namespace
roleRef:
  kind: ClusterRole
  name: operator-crd-manager
  apiGroup: rbac.authorization.k8s.io
```

#### 5.2.4. Wdrożenie operatora jako Deployment z ServiceAccount

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: my-operator
  namespace: operator-namespace
spec:
  replicas: 1
  selector:
    matchLabels:
      app: my-operator
  template:
    metadata:
      labels:
        app: my-operator
    spec:
      serviceAccountName: my-operator-sa
      containers:
      - name: operator
        image: registry.example.com/my-operator:latest
        # Katalog, w którym domyślnie montowany jest token ServiceAccount:
        volumeMounts:
        - mountPath: /var/run/secrets/kubernetes.io/serviceaccount
          name: sa-token
          readOnly: true
      volumes:
      - name: sa-token
        secret:
          secretName: my-operator-sa-token  # nazwa sekretu utworzonego automatycznie
          optional: true
```

W efekcie nasz operator działa w kontekście „usera” określonego przez JWT wygenerowany dla `ServiceAccount my-operator-sa`. RBAC Admission Controller weryfikuje każdą próbę modyfikacji CRD lub obiektów typu Deployment w klastrze, sprawdzając, czy token ServiceAccount ma odpowiednie uprawnienia (zgodne z ClusterRole).

### 5.3. Scenariusz 3: Testowanie uprawnień za pomocą `SubjectAccessReview`

Czasami warto przed wdrożeniem zmian w RBAC przetestować, czy użytkownik będzie miał odpowiednie uprawnienia do danej operacji. W tym celu można użyć zasobu `SelfSubjectAccessReview`, jak opisano wcześniej.

#### 5.3.1. Sprawdzenie uprawnień użytkownika „charlie”

```yaml
apiVersion: authorization.k8s.io/v1
kind: SelfSubjectAccessReview
spec:
  resourceAttributes:
    namespace: prod-environment
    verb: delete
    group: ""
    resource: pods
```

Zakładamy, że użytkownik `charlie` ma wykonać powyższy `kubectl apply -f` przy pomocy swojego kontekstu kubeconfig (`--user=charlie`). Jeśli ma odpowiednie uprawnienia (Role/ClusterRoleBinding), otrzyma w odpowiedzi:

```yaml
status:
  allowed: true
  denied: false
  evaluationError: ""
  reason: "Allowed by rolebinding prod-environment/charlie-pod-admin"
```

W przeciwnym razie zobaczy:

```yaml
status:
  allowed: false
  denied: true
  evaluationError: ""
  reason: "RBAC: rbac.authorization.k8s.io:rolebindings ... not found"
```

---

## 6. Wewnętrzne mechanizmy Admission Controller związane z RBAC

### 6.1. Kolejność działania Admission Controllers

Podczas przetwarzania żądania API Server wykonuje kolejno:

1. **Authentication** – weryfikacja tożsamości (certyfikaty, tokeny).
2. **Authorization** – weryfikacja uprawnień. Do elementów autoryzacyjnych zaliczają się m.in. `Node`, `RBAC`, `Webhook`, `ABAC` (jeśli włączony).
3. **Mutating Admission Controllers** – ewentualne modyfikacje zasobu (np. wstrzyknięcie defaultów, adnotacji).
4. **Validating Admission Controllers** – weryfikacja, czy obiekt spełnia polityki (np. `PodSecurityPolicy`, `ResourceQuota`, `ValidatingAdmissionWebhook`).

W ramach punktu 2 (Authorization) RBAC Admission Controller odmawia lub przyznaje dostęp. Jeśli żądanie zostanie odrzucone, kolejne kroki (modyfikacje, walidacje) nie są wywoływane.

### 6.2. Główne komponenty RBAC Admission Controller

RBAC Admission Controller korzysta z wewnętrznych API Kubernetes:

* **RoleBindings** i **ClusterRoleBindings** – określają, kto i jakie Role/ClusterRole posiada.
* Podczas zapytania RBAC wykonuje algorytm dopasowania:

    1. Sprawdza RoleBinding’i w namespace (jeśli operacja jest namespaced).
    2. Sprawdza ClusterRoleBinding’i (operacje globalne lub także w namespace, jeśli RoleBinding odwołuje się do ClusterRole).
* Porównuje `verb` (np. `get`, `list`, `delete`) i `resource` (np. `pods`, `deployments`) z regułami zdefiniowanymi w Role/ClusterRole.

Przykładowo, gdy użytkownik próbuje `kubectl delete pod foo` w namespace `dev-environment`, RBAC:

1. Odczytuje Subjects (User’y, ServiceAccount’y, Group’y) z RoleBinding w `dev-environment` odnoszące się do Role z regułą `resources: ["pods"]; verbs: ["delete"]`.
2. Odczytuje ClusterRoleBinding, jeżeli użytkownik lub ServiceAccount występuje w Subjectach i RoleRef odnosi się do ClusterRole pozwalającej na usuwanie `pods` w tym namespace (lub globalnie).

Jeśli co najmniej jedna rola na to pozwala, operacja jest dozwolona.

---

## 7. Zasady dobrego projektowania RBAC w Kubernetes

### 7.1. Zasada najmniejszych uprawnień (Least Privilege)

Najważniejszą regułą projektowania polityk RBAC jest przyznawanie jedynie tych uprawnień, które są absolutnie niezbędne. Przykłady dobrych praktyk:

* Zamiast dawać `verbs: ["*"]` i `resources: ["*"]`, wskazujemy precyzyjnie, czego dany podmiot może dotykać.
* Dla deweloperów w namespace deweloperskim przyznajemy uprawnienia w danym namespace, a nie globalnie (unikamy ClusterRole `/ *` Bindings).
* Dla aplikacji (ServiceAccount) definiujemy specjalne cluster-role z minimalnym zakresem dostępu (np. tylko do jednego CRD lub jednej grupy zasobów).

### 7.2. Unikanie nadmiernego korzystania z ClusterRoleBinding

Jeśli nie jest to wymagane, lepiej korzystać z **Role** i **RoleBinding** (poziom namespace). Zbyt szerokie ClusterRoleBinding może dać dostęp do niezamierzonych namespace’ów lub zasobów. Warto:

* Stosować ClusterRole tylko wtedy, gdy uprawnienia są globalne (np. zarządzanie węzłami, CRD, PersistentVolumes).
* Dla zwykłych aplikacji bazodanowych, monitoringowych, operatorów – definiować ClusterRole, a następnie przypisać je poprzez RoleBinding w wybranych namespace’ach (wymaga to jednak, by ClusterRoleBinding odwoływał się do ClusterRole, co z grubsza daje globalny dostęp, ale ograniczony przynajmniej do namespace, który RoleBinding wskazuje; można też zrobić RoleBinding do ClusterRole, co jest wspieraną konstrukcją).

Przykład przypisania ClusterRole w namespace (RoleBinding do ClusterRole):

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: bind-clusterrole-to-sa
  namespace: my-namespace
subjects:
- kind: ServiceAccount
  name: sa-example
  namespace: my-namespace
roleRef:
  kind: ClusterRole
  name: view   # wbudowana ClusterRole 'view'
  apiGroup: rbac.authorization.k8s.io
```

Powyższe pozwoli naszemu `ServiceAccount` z `my-namespace` tylko czytać wszystkie zasoby w tym właśnie namespace, bez dawania globalnych uprawnień.

### 7.3. Organizacja i dokumentacja polityk RBAC

#### 7.3.1. Modularność manifestów

* **Rozdzielanie manifestów** – lepiej mieć osobne pliki YAML na Role, RoleBinding, ClusterRole, ClusterRoleBinding, „Userów” (kubeconfig) i ServiceAccount’y.
* **Nazewnictwo** – stosować spójne prefiksy, np. `dev-editor`, `dev-viewer`, `prod-admin`, `ci-operator-sa-cr`, aby łatwo identyfikować, do czego służą poszczególne zasoby.

#### 7.3.2. Dokumentacja

* **README.md** w repozytorium z manifestami RBAC, opisujący cel, kontekst i powiązane instrukcje (np. który plik applyować, w jakiej kolejności, jakie zmienne należy podmienić \[namespace, nazwa użytkownika]).
* **Opis uprawnień** – dobrze umieścić komentarze w samych plikach YAML, dostarczając krótkich notatek, dlaczego np. Role ma dostęp do `deployments` i `pods`, ale nie ma dostępu do `secrets`.

### 7.4. Regularne audyty i przeglądy polityk RBAC

* Wdrażanie nowych aplikacji niesie ryzyko nadania zbyt szerokich uprawnień.
* Istnieją narzędzia typu **kube-bench** i **kube-hunter**, które pozwalają skanować klaster pod kątem błędów konfiguracyjnych, w tym nadmiernych uprawnień RBAC.
* **Regularne przeglądy** – zespoły DevOps lub administratorzy powinni okresowo weryfikować RoleBinding i ClusterRoleBinding pod kątem zgodności z aktualnymi potrzebami.
* **Dzienniki audytu (Audit Logs)** – Kubernetes może być skonfigurowany do logowania operacji API. Dzięki temu w razie incydentu łatwiej zidentyfikować, który użytkownik lub ServiceAccount wykonywał krytyczne operacje.

---

## 8. Podsumowanie

W artykule przedstawiliśmy:

1. **Users** – mechanizmy uwierzytelniania z użyciem certyfikatów TLS, tokenów, OIDC; brak natywnych obiektów `User` w etcd; przykładowa konfiguracja kubeconfig.
2. **Service Accounts** – wbudowane konta serwisowe, które służą do uwierzytelniania aplikacji działających wewnątrz klastra; automatyczne montowanie tokenów i rotowanie JWT.
3. **RBAC Admission Controller** – mechanizm autoryzacji, który na podstawie Role, RoleBinding, ClusterRole, ClusterRoleBinding decyduje, czy dany podmiot (User lub ServiceAccount) może wykonać operację na zasobie.
4. **Przykładowe scenariusze** – przydzielanie deweloperom uprawnień editors/viewers w namespace; wdrożenie operatora z dedykowanym ServiceAccount i ClusterRole; testowanie uprawnień za pomocą `SelfSubjectAccessReview`.
5. **Dobre praktyki** – zasada najmniejszych uprawnień, unikanie nadmiernego dotowania globalnych uprawnień, modularne manifesty, dokumentacja i regularne audyty polityk RBAC.

Dobrze skonfigurowane mechanizmy Users, ServiceAccounts i RBAC Admission Controller stanowią solidne fundamenty bezpieczeństwa w klastrze Kubernetes. Dzięki nim administratorzy mogą precyzyjnie kontrolować dostęp, a aplikacje wewnątrz klastra działają zgodnie z najmniejszymi niezbędnymi uprawnieniami, co minimalizuje ryzyko eskalacji uprawnień oraz naruszenia bezpieczeństwa.

---

## Załącznik: Szybkie przypomnienie głównych zasobów RBAC

| Zasób                  | Poziom          | Przeznaczenie                                                                                                                                     |
| ---------------------- | --------------- | ------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Role**               | Namespace-level | Zestaw reguł (resources + verbs) ograniczony do konkretnego namespace.                                                                            |
| **ClusterRole**        | Cluster-level   | Zestaw reguł (resources + verbs) działający globalnie w klastrze; może dotyczyć zasobów namespaced lub węzłowych.                                 |
| **RoleBinding**        | Namespace-level | Przypisanie Role do User/ServiceAccount/Group w konkretnym namespace.                                                                             |
| **ClusterRoleBinding** | Cluster-level   | Przypisanie ClusterRole do User/ServiceAccount/Group globalnie lub w wybranych namespace’ach (poprzez RoleBinding odwołujący się do ClusterRole). |

---

### Przykładowe komendy weryfikacyjne

1. **Wylistowanie RoleBinding w namespace**:

   ```bash
   kubectl get rolebindings -n dev-environment
   ```
2. **Wylistowanie ClusterRoleBinding**:

   ```bash
   kubectl get clusterrolebindings
   ```
3. **Sprawdzenie, czy ServiceAccount istnieje i jaki token ma w namespace**:

   ```bash
   kubectl get serviceaccount worker-sa -n dev-environment -o yaml
   # lub
   kubectl describe serviceaccount worker-sa -n dev-environment
   ```
4. **Odczyt tokenu w działającym podzie**:

   ```bash
   kubectl exec -n dev-environment worker-pod -- cat /var/run/secrets/kubernetes.io/serviceaccount/token
   ```
5. **Testowanie uprawnień (SelfSubjectAccessReview)**:

   ```bash
   cat <<EOF | kubectl apply -f -
   apiVersion: authorization.k8s.io/v1
   kind: SelfSubjectAccessReview
   spec:
     resourceAttributes:
       namespace: dev-environment
       verb: create
       group: ""
       resource: pods
   EOF
   ```


## Przykład 1: ServiceAccount do odczytu ConfigMap wewnątrz poda

Założenia:

* Stworzymy namespace `demo-sa1`.
* Utworzymy ServiceAccount `cfg-reader-sa`.
* Utworzymy ConfigMap `app-config` w tym namespace.
* Nadajemy Role, która pozwoli `cfg-reader-sa` na odczyt ConfigMap w namespace `demo-sa1`.
* Wdrożymy Pod, który wykorzystuje ten ServiceAccount i spróbujemy odczytać ConfigMap poprzez API (przykład z wykorzystaniem prostego obrazu BusyBox i `curl`).

### 1.1. Utworzenie namespace’u

```bash
kubectl create namespace demo-sa1
```

### 1.2. Utworzenie ServiceAccount

```yaml
# plik: sa-cfg-reader.yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: cfg-reader-sa
  namespace: demo-sa1
```

```bash
kubectl apply -f sa-cfg-reader.yaml
```

Sprawdź, czy ServiceAccount powstał:

```bash
kubectl get serviceaccount cfg-reader-sa -n demo-sa1
```

### 1.3. Utworzenie ConfigMap, którą odczyta nasz pod

```yaml
# plik: demo-configmap.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: app-config
  namespace: demo-sa1
data:
  message: "Hello from ConfigMap!"
  timeout: "30"
```

```bash
kubectl apply -f demo-configmap.yaml
```

Zweryfikuj zawartość:

```bash
kubectl get configmap app-config -n demo-sa1 -o yaml
```

### 1.4. Utworzenie Role pozwalającej na czytanie ConfigMap

```yaml
# plik: role-cfg-read.yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: configmap-reader
  namespace: demo-sa1
rules:
- apiGroups: [""]             # pusta grupa API (core/v1)
  resources: ["configmaps"]   # zasób ConfigMap
  verbs: ["get", "list"]      # pozwalamy na GET oraz LIST
```

```bash
kubectl apply -f role-cfg-read.yaml
```

Sprawdzenie, czy Role istnieje:

```bash
kubectl get role configmap-reader -n demo-sa1
```

### 1.5. Utworzenie RoleBinding wiążącego Role i ServiceAccount

```yaml
# plik: rb-cfg-read-binding.yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: cfg-reader-binding
  namespace: demo-sa1
subjects:
- kind: ServiceAccount
  name: cfg-reader-sa
  namespace: demo-sa1
roleRef:
  kind: Role
  name: configmap-reader
  apiGroup: rbac.authorization.k8s.io
```

```bash
kubectl apply -f rb-cfg-read-binding.yaml
```

Sprawdź RoleBinding:

```bash
kubectl get rolebinding cfg-reader-binding -n demo-sa1
```

### 1.6. Wdrożenie poda z ServiceAccount i próba odczytu ConfigMap

Stworzymy Pod, który korzysta z obrazu `busybox`, montuje ServiceAccountToken i wykonuje polecenie `sleep`, by pod pozostawał w running, a my mogliśmy się do niego zalogować.

```yaml
# plik: pod-cfg-reader.yaml
apiVersion: v1
kind: Pod
metadata:
  name: cfg-reader-pod
  namespace: demo-sa1
spec:
  serviceAccountName: cfg-reader-sa
  containers:
  - name: busybox
    image: busybox:1.35
    command:
      - "/bin/sh"
      - "-c"
      - "sleep 3600"
    volumeMounts:
    - name: sa-token
      mountPath: /var/run/secrets/kubernetes.io/serviceaccount
      readOnly: true
  volumes:
  - name: sa-token
    projected:
      sources:
      - serviceAccountToken:
          path: token
          expirationSeconds: 3600
      - configMap:
          name: kube-root-ca.crt # niezbędne do weryfikacji certyfikatu API Servera
          items:
            - key: ca.crt
              path: ca.crt
```

> **Uwaga:** W Kubernetes w wersjach ≥1.20 token automatycznie montowany jest do `/var/run/secrets/kubernetes.io/serviceaccount/token` i `ca.crt` jest dostępny w `/var/run/secrets/kubernetes.io/serviceaccount/ca.crt`. W powyższym przykładzie używamy mechanizmu `projected`, aby jawnie określić token i CA, co pozwala skupić się na samym działaniu. Jeśli Twój klaster automatycznie montuje token, wystarczy pominąć sekcję `volumes` i `volumeMounts`; w kontenerze i tak będzie dostępny `token` i `ca.crt`.

```bash
kubectl apply -f pod-cfg-reader.yaml
```

Zweryfikuj, czy Pod działa:

```bash
kubectl get pods -n demo-sa1
```

#### 1.6.1. Zalogowanie do poda i próba odczytu ConfigMap przez kube-apiserver

1. **Zaloguj się do poda**:

   ```bash
   kubectl exec -it cfg-reader-pod -n demo-sa1 -- /bin/sh
   ```

2. **Sprawdź token i CA**:

   ```sh
   # Token
   cat /var/run/secrets/kubernetes.io/serviceaccount/token
   # Zapisz wygenerowany token (np. do zmiennej środowiskowej)
   TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)

   # Ścieżka do certyfikatu CA
   ls /var/run/secrets/kubernetes.io/serviceaccount/ca.crt
   ```

3. **Odczytaj ConfigMap za pomocą curl**:

   ```sh
   # Ustawiamy zmienną środowiskową API_SERVER
   # (może być namespace m.in. pobrane z /var/run/secrets/kubernetes.io/serviceaccount/namespace, ale domyślnie chcemy korzystać z 'demo-sa1')
   API_SERVER="https://kubernetes.default.svc"

   # Wykonujemy żądanie GET do SCIEZKI REST API 
   curl -sSk \
     --cacert /var/run/secrets/kubernetes.io/serviceaccount/ca.crt \
     -H "Authorization: Bearer $TOKEN" \
     "$API_SERVER/api/v1/namespaces/demo-sa1/configmaps/app-config" | jq .
   ```

   **Oczekiwany wynik** (odpowiedź JSON z danymi ConfigMap, np.):

   ```json
   {
     "apiVersion": "v1",
     "data": {
       "message": "Hello from ConfigMap!",
       "timeout": "30"
     },
     "kind": "ConfigMap",
     "metadata": {
       "name": "app-config",
       "namespace": "demo-sa1",
       ...
     }
   }
   ```

   Jeśli zobaczysz powyższe dane – to znaczy, że ServiceAccount `cfg-reader-sa` ma właściwe uprawnienia.

4. **Sprawdzenie braku uprawnień do utworzenia ConfigMap**:

   Spróbujmy teraz wykonać POST, żeby utworzyć nową ConfigMap. Oczywiście w Role pozwoliliśmy tylko na `get` i `list`, więc operacja powinna zostać odrzucona:

   ```sh
   # przykład prostego JSON-a:
   curl -sSk \
     --cacert /var/run/secrets/kubernetes.io/serviceaccount/ca.crt \
     -H "Authorization: Bearer $TOKEN" \
     -H "Content-Type: application/json" \
     -X POST \
     -d '{"apiVersion":"v1","kind":"ConfigMap","metadata":{"name":"should-fail"},"data":{"k":"v"}}' \
     "$API_SERVER/api/v1/namespaces/demo-sa1/configmaps"
   ```

   **Oczekiwany wynik**: Błąd 403 Forbidden:

   ```json
   {"kind":"Status","apiVersion":"v1","metadata":{},"status":"Failure","message":"configmaps is forbidden: User \"system:serviceaccount:demo-sa1:cfg-reader-sa\" cannot create resource \"configmaps\" in API group \"\" in the namespace \"demo-sa1\"","reason":"Forbidden","details":{"group":"","kind":"configmaps"},"code":403}
   ```

   W ten sposób pokazaliśmy, jak ServiceAccount w połączeniu z odpowiednią Role i RoleBinding daje dostęp tylko do odczytu ConfigMap, a próba zapisu zostaje zablokowana.

---

## Przykład 2: ServiceAccount do odczytu i tworzenia Secret w jednym namespace

W tym przykładzie:

* Stworzymy namespace `demo-sa2`.
* Utworzymy ServiceAccount `secret-editor-sa`.
* Nadajemy Role, która pozwoli na tworzenie, odczyt i usuwanie Secret (ressource: `secrets`) w namespace `demo-sa2`.
* Wdrożymy pod, który będzie próbował utworzyć Secret, a następnie odczytać go.

### 2.1. Utworzenie namespace’u

```bash
kubectl create namespace demo-sa2
```

### 2.2. Utworzenie ServiceAccount

```yaml
# plik: sa-secret-editor.yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: secret-editor-sa
  namespace: demo-sa2
```

```bash
kubectl apply -f sa-secret-editor.yaml
```

### 2.3. Definicja Role pozwalającej na CRUD na secretach

```yaml
# plik: role-secret-editor.yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: secret-editor
  namespace: demo-sa2
rules:
- apiGroups: [""]
  resources: ["secrets"]
  verbs: ["get", "list", "create", "update", "delete"]
```

```bash
kubectl apply -f role-secret-editor.yaml
```

### 2.4. Utworzenie RoleBinding wiążącego Role i ServiceAccount

```yaml
# plik: rb-secret-editor-binding.yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: secret-editor-binding
  namespace: demo-sa2
subjects:
- kind: ServiceAccount
  name: secret-editor-sa
  namespace: demo-sa2
roleRef:
  kind: Role
  name: secret-editor
  apiGroup: rbac.authorization.k8s.io
```

```bash
kubectl apply -f rb-secret-editor-binding.yaml
```

### 2.5. Wdrożenie poda, który próbuje CRUD na Secret

Pod wykonujący kilka kroków:

1. Sprawdzenie, że obecnie nie ma Secret o nazwie `my-secret`.
2. Utworzenie Secret o nazwie `my-secret` z przykładowymi danymi.
3. Odczytanie go (dekodowanie z base64).
4. Naniesienie w nim zmiany (np. aktualizacja wartości).
5. Usunięcie Secret.

```yaml
# plik: pod-secret-editor.yaml
apiVersion: v1
kind: Pod
metadata:
  name: secret-editor-pod
  namespace: demo-sa2
spec:
  serviceAccountName: secret-editor-sa
  restartPolicy: Never
  containers:
  - name: tester
    image: bitnami/kubectl:1.27
    command:
      - "/bin/sh"
      - "-c"
      - |
        set -e

        # Zmienna środowiskowa z tokenem i CA
        TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
        CA=/var/run/secrets/kubernetes.io/serviceaccount/ca.crt
        API="https://kubernetes.default.svc"

        echo "1. Sprawdzanie, czy Secret my-secret istnieje (powinno być puste)"
        curl -sSk --cacert $CA -H "Authorization: Bearer $TOKEN" \
          "$API/api/v1/namespaces/demo-sa2/secrets/my-secret" || echo "Nie znaleziono Secret"

        echo "2. Tworzenie Secret 'my-secret'"
        curl -sSk --cacert $CA -H "Authorization: Bearer $TOKEN" \
          -H "Content-Type: application/json" \
          -X POST \
          -d '{
            "apiVersion":"v1",
            "kind":"Secret",
            "metadata":{"name":"my-secret"},
            "data": {"username":"YWRtaW4=", "password":"cGFzc3dvcmQ="}
          }' \
          "$API/api/v1/namespaces/demo-sa2/secrets"

        echo "3. Odczytywanie Secret 'my-secret' i dekodowanie w bashu"
        SECRET_JSON=$(curl -sSk --cacert $CA -H "Authorization: Bearer $TOKEN" \
          "$API/api/v1/namespaces/demo-sa2/secrets/my-secret")
        echo "$SECRET_JSON" | jq -r '.data.username' | base64 -d
        echo "$SECRET_JSON" | jq -r '.data.password' | base64 -d

        echo "4. Aktualizacja Secret: zmiana hasła"
        curl -sSk --cacert $CA -H "Authorization: Bearer $TOKEN" \
          -H "Content-Type: application/json" \
          -X PUT \
          -d '{
            "apiVersion":"v1",
            "kind":"Secret",
            "metadata":{"name":"my-secret"},
            "data": {"username":"YWRtaW4=", "password":"bmV3IHBhc3M="}
          }' \
          "$API/api/v1/namespaces/demo-sa2/secrets/my-secret"

        echo "5. Usuwanie Secret 'my-secret'"
        curl -sSk --cacert $CA -H "Authorization: Bearer $TOKEN" \
          -X DELETE "$API/api/v1/namespaces/demo-sa2/secrets/my-secret"

        echo "6. Koniec testu. Puszczamy 'sleep' by pod się nie zamknął natychmiast"
        sleep 3600
    volumeMounts:
    - name: sa-token
      mountPath: /var/run/secrets/kubernetes.io/serviceaccount
      readOnly: true
  volumes:
  - name: sa-token
    projected:
      sources:
      - serviceAccountToken:
          path: token
          expirationSeconds: 3600
      - configMap:
          name: kube-root-ca.crt
          items:
            - key: ca.crt
              path: ca.crt
```

**Uwaga:** Pod używa obrazu `bitnami/kubectl:1.27`, żeby mieć wbudowane `jq` oraz `curl`.

```bash
kubectl apply -f pod-secret-editor.yaml
```

Sprawdź stan poda:

```bash
kubectl get pod secret-editor-pod -n demo-sa2
```

Po kilku chwilach zaloguj się do poda i ręcznie zweryfikuj, co się wydarzyło, albo obserwuj jego logi:

```bash
kubectl logs secret-editor-pod -n demo-sa2
```

Powinieneś zobaczyć kroki:

1. Informację, że Secret nie istniał.
2. Utworzenie Secret.
3. Wydrukowane odszyfrowane wartości `admin` oraz `password`.
4. Aktualizację na `new pass`.
5. Usunięcie Secret.
6. Potwierdzenie zakończenia testu.

Jeśli wszystko się udało, to znaczy, że ServiceAccount `secret-editor-sa` ma prawidłowo przydzielone uprawnienia CRUD na zasób `secrets` w namespace `demo-sa2`.

---

## Przykład 3: Ograniczenie ServiceAccount tylko do odczytu podów w wielu namespace’ach (ClusterRole + RoleBinding)

Czasem chcemy dać ServiceAccount możliwość odczytu obiektów (np. pods) w kilku namespace’ach, ale nie w całym klastrze. Zamiast tworzyć Role w każdym namespace, możemy utworzyć jedną ClusterRole, a następnie w każdym z wybranych namespace’ przypisać ją przez RoleBinding. W tym przykładzie:

* Namespace’y: `team-a`, `team-b`.
* ServiceAccount: `viewer-sa` (będzie istniało w obu namespace’ach).
* ClusterRole: `pod-viewer` (tylko `get`, `list`, `watch` dla pods).
* RoleBinding: w każdym namespace `team-a` i `team-b` wiążący `pod-viewer` z `ServiceAccount viewer-sa`.

### 3.1. Utworzenie namespace’ów

```bash
kubectl create namespace team-a
kubectl create namespace team-b
```

### 3.2. Utworzenie dwóch ServiceAccount (w każdym namespace o tej samej nazwie)

```yaml
# plik: sa-viewer-team-a.yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: viewer-sa
  namespace: team-a
```

```yaml
# plik: sa-viewer-team-b.yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: viewer-sa
  namespace: team-b
```

```bash
kubectl apply -f sa-viewer-team-a.yaml
kubectl apply -f sa-viewer-team-b.yaml
```

### 3.3. Utworzenie ClusterRole pozwalającej na odczyt podów

```yaml
# plik: clusterrole-pod-viewer.yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: pod-viewer
rules:
- apiGroups: [""]
  resources: ["pods"]
  verbs: ["get", "list", "watch"]
```

```bash
kubectl apply -f clusterrole-pod-viewer.yaml
```

Sprawdź, czy ClusterRole powstała:

```bash
kubectl get clusterrole pod-viewer
```

### 3.4. Utworzenie RoleBindingów w każdym namespace

#### 3.4.1. RoleBinding w namespace `team-a`

```yaml
# plik: rb-pod-viewer-team-a.yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: bind-pod-viewer
  namespace: team-a
subjects:
- kind: ServiceAccount
  name: viewer-sa
  namespace: team-a
roleRef:
  kind: ClusterRole
  name: pod-viewer
  apiGroup: rbac.authorization.k8s.io
```

```bash
kubectl apply -f rb-pod-viewer-team-a.yaml
```

#### 3.4.2. RoleBinding w namespace `team-b`

```yaml
# plik: rb-pod-viewer-team-b.yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: bind-pod-viewer
  namespace: team-b
subjects:
- kind: ServiceAccount
  name: viewer-sa
  namespace: team-b
roleRef:
  kind: ClusterRole
  name: pod-viewer
  apiGroup: rbac.authorization.k8s.io
```

```bash
kubectl apply -f rb-pod-viewer-team-b.yaml
```

W obu przypadkach `viewer-sa` w danym namespace uzyskuje prawo do `get`, `list` i `watch` zasobów `pods`, ale tylko w odpowiednim namespace (z uwagi na to, że RoleBinding jest namespaced).

### 3.5. Weryfikacja przez wdrożenie prostych podów i próba odczytu z innego namespace

1. **Stwórz Pod w namespace `team-a` oraz `team-b`**
   Dla uproszczenia każdy z podów może być po prostu `busybox` w trybie `sleep`, by dać sobie czas na testowanie:

   ```yaml
   # plik: pod-test-team-a.yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: test-a
     namespace: team-a
   spec:
     containers:
     - name: busybox
       image: busybox:1.35
       command: ["sh", "-c", "sleep 3600"]
   ```

   ```yaml
   # plik: pod-test-team-b.yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: test-b
     namespace: team-b
   spec:
     containers:
     - name: busybox
       image: busybox:1.35
       command: ["sh", "-c", "sleep 3600"]
   ```

   ```bash
   kubectl apply -f pod-test-team-a.yaml
   kubectl apply -f pod-test-team-b.yaml
   ```

2. **Wdrożenie Podu wykorzystującego `viewer-sa` i test odczytu**

   Utworzymy Pod w namespace `team-a`, który korzysta z `viewer-sa` i próbuje odczytać listę Podów z obu namespace’ów (`team-a` oraz `team-b`). Ostatecznie dostęp do `team-a` powinien się udać, a do `team-b` – zostać zabroniony.

   ```yaml
   # plik: pod-try-viewer.yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: try-viewer-pod
     namespace: team-a
   spec:
     serviceAccountName: viewer-sa
     restartPolicy: Never
     containers:
     - name: tester
       image: bitnami/kubectl:1.27
       command:
         - "/bin/sh"
         - "-c"
         - |
           set -e
           TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
           CA=/var/run/secrets/kubernetes.io/serviceaccount/ca.crt
           API="https://kubernetes.default.svc"

           echo "Lista podów w namespace team-a (powinno zadziałać):"
           curl -sSk --cacert $CA -H "Authorization: Bearer $TOKEN" \
             "$API/api/v1/namespaces/team-a/pods" | jq .

           echo "Lista podów w namespace team-b (powinno być 403 Forbidden):"
           curl -sSk --cacert $CA -H "Authorization: Bearer $TOKEN" \
             "$API/api/v1/namespaces/team-b/pods" || echo "Dostęp zabroniony"
           sleep 3600
       volumeMounts:
       - name: sa-token
         mountPath: /var/run/secrets/kubernetes.io/serviceaccount
         readOnly: true
     volumes:
     - name: sa-token
       projected:
         sources:
         - serviceAccountToken:
             path: token
             expirationSeconds: 3600
         - configMap:
             name: kube-root-ca.crt
             items:
               - key: ca.crt
                 path: ca.crt
   ```

   ```bash
   kubectl apply -f pod-try-viewer.yaml
   ```

   Sprawdź logi:

   ```bash
   kubectl logs try-viewer-pod -n team-a
   ```

   **Oczekiwane rezultaty**:

    * Pierwsze zapytanie (listowanie pods w `team-a`) powinno zwrócić obiekt JSON z danymi poda `test-a` oraz `try-viewer-pod`.
    * Drugie zapytanie (listowanie pods w `team-b`) powinno zwrócić błąd 403 lub po prostu komunikat “Dostęp zabroniony”.

---

## Przykład 4: Utworzenie kubeconfig dla ServiceAccount i użycie go poza klastrem

Czasem chcemy, by jakiś zewnętrzny proces (np. skrypt mogący działać poza klasrem) mógł uwierzytelniać się w API Serwerze przy użyciu ServiceAccount. Poniższy przykład pokazuje, jak wygenerować kubeconfig dla ServiceAccount, by z poziomu komputera lokalnego wykorzystywać token i komunikować się z klastrem.

### 4.1. Tworzenie ServiceAccount w namespace `demo-sa3`

```bash
kubectl create namespace demo-sa3
kubectl create serviceaccount ext-sa -n demo-sa3
```

### 4.2. Przydzielenie minimalnej roli (odczyt podów) ServiceAccount

Najpierw utwórzmy Role i RoleBinding (jak w poprzednich przykładach). Załóżmy, że chcemy, by `ext-sa` mógł czytać Pods w namespace `demo-sa3`.

```yaml
# plik: role-ext-pod-reader.yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: ext-pod-reader
  namespace: demo-sa3
rules:
- apiGroups: [""]
  resources: ["pods"]
  verbs: ["get", "list"]
```

```yaml
# plik: rb-ext-pod-reader.yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: ext-pod-reader-binding
  namespace: demo-sa3
subjects:
- kind: ServiceAccount
  name: ext-sa
  namespace: demo-sa3
roleRef:
  kind: Role
  name: ext-pod-reader
  apiGroup: rbac.authorization.k8s.io
```

```bash
kubectl apply -f role-ext-pod-reader.yaml
kubectl apply -f rb-ext-pod-reader.yaml
```

### 4.3. Pobranie tokenu ServiceAccount i CA

Kubernetes automatycznie tworzy `Secret`, w którym znajduje się token dla ServiceAccount. Nazwa sekretu zwykle zaczyna się od `<nazwa-sa>-token-XXXXX`. Zidentyfikujmy ją:

```bash
kubectl get secret -n demo-sa3 | grep ext-sa-token
```

Przykładowo wyświetli:

```
ext-sa-token-abcde   kubernetes.io/service-account-token   3      2m
```

Pobieramy wartości do lokalnych plików:

```bash
# Token
kubectl get secret ext-sa-token-abcde -n demo-sa3 -o go-template='{{ .data.token }}' | base64 -d > ext-sa.token

# CA.crt
kubectl get secret ext-sa-token-abcde -n demo-sa3 -o go-template='{{ .data.ca\.crt }}' | base64 -d > ca.crt
```

### 4.4. Zbudowanie kubeconfig z wykorzystaniem tokenu

Załóżmy, że adres API Servera to `https://api.k8s.example.com:6443`. Aby stworzyć własny kubeconfig:

```bash
# 1. Utwórz kubeconfig z minimalnymi sekcjami:
kubectl config set-cluster demo-sa3-cluster \
  --server=https://api.k8s.example.com:6443 \
  --certificate-authority=ca.crt \
  --embed-certs=true \
  --kubeconfig=ext-sa.kubeconfig

# 2. Dodaj użytkownika, korzystając z tokenu:
kubectl config set-credentials ext-sa-user \
  --token="$(cat ext-sa.token)" \
  --kubeconfig=ext-sa.kubeconfig

# 3. Dodaj kontekst (namespace domyślny = demo-sa3):
kubectl config set-context ext-sa-context \
  --cluster=demo-sa3-cluster \
  --user=ext-sa-user \
  --namespace=demo-sa3 \
  --kubeconfig=ext-sa.kubeconfig

# 4. Przełącz się na ten kontekst:
kubectl config use-context ext-sa-context --kubeconfig=ext-sa.kubeconfig
```

### 4.5. Weryfikacja z lokalnej maszyny

Na lokalnej maszynie, używając `ext-sa.kubeconfig`, spróbujmy wczytać listę podów w namespace `demo-sa3`:

```bash
KUBECONFIG=./ext-sa.kubeconfig kubectl get pods
```

Jeżeli nie masz żadnych podów w `demo-sa3`, wynik będzie pusty, ale nie powinien zwrócić błędu 403. Jeżeli spróbujesz odczytać pods w innym namespace, np. `kube-system`, to powinna pojawić się odmowa:

```bash
KUBECONFIG=./ext-sa.kubeconfig kubectl get pods -n kube-system
```

Spodziewany błąd:

```
Error from server (Forbidden): pods is forbidden: User "system:serviceaccount:demo-sa3:ext-sa" cannot list resource "pods" in API group "" in the namespace "kube-system"
```

---

## Przykład 5: Użycie `SelfSubjectAccessReview` wewnątrz poda, by sprawdzić uprawnienia ServiceAccount

W poprzednich przykładach weryfikowaliśmy uprawnienia poprzez żądania HTTP do API Servera i obserwowaliśmy błędy 403. Kubernetes pozwala jednak także na programatyczne sprawdzenie, czy dany token ma prawo do wykonania wskazanej operacji, za pomocą obiektu `SelfSubjectAccessReview`. Ten zasób wysyłamy w imieniu bieżącego podmiotu – w naszym przypadku ServiceAccount.

### 5.1. Tworzymy Role i RoleBinding, które przyznają ServiceAccount `ssar-sa` dostęp do sprawdzania podów

Załóżmy namespace `demo-sa4`. Postępujemy tak:

```bash
kubectl create namespace demo-sa4
kubectl create serviceaccount ssar-sa -n demo-sa4
```

#### 5.1.1. Przydzielamy `ssar-sa` Role `pods-reader` (czytanie pods)

```yaml
# plik: role-pods-reader.yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: pods-reader
  namespace: demo-sa4
rules:
- apiGroups: [""]
  resources: ["pods"]
  verbs: ["get", "list"]
```

```bash
kubectl apply -f role-pods-reader.yaml
```

#### 5.1.2. RoleBinding

```yaml
# plik: rb-pods-reader-binding.yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: pods-reader-binding
  namespace: demo-sa4
subjects:
- kind: ServiceAccount
  name: ssar-sa
  namespace: demo-sa4
roleRef:
  kind: Role
  name: pods-reader
  apiGroup: rbac.authorization.k8s.io
```

```bash
kubectl apply -f rb-pods-reader-binding.yaml
```

### 5.2. Wdrożenie poda z narzędziem do wysyłania `SelfSubjectAccessReview`

Użyjemy obrazu `bitnami/kubectl:1.27`, który zawiera `kubectl` oraz `jq`. Pod wykona dwa zapytania do `SelfSubjectAccessReview`:

1. Czy możemy listować pods w namespace `demo-sa4`?
2. Czy możemy usuwać pods w namespace `demo-sa4`? (powinno zostać zabronione)

```yaml
# plik: pod-ssar-test.yaml
apiVersion: v1
kind: Pod
metadata:
  name: ssar-test-pod
  namespace: demo-sa4
spec:
  serviceAccountName: ssar-sa
  restartPolicy: Never
  containers:
  - name: tester
    image: bitnami/kubectl:1.27
    command:
      - "/bin/sh"
      - "-c"
      - |
        set -e
        TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
        CA=/var/run/secrets/kubernetes.io/serviceaccount/ca.crt
        API="https://kubernetes.default.svc"

        echo "1. Sprawdzam, czy mogę listować pods (apiVersion: authorization.k8s.io/v1 / SelfSubjectAccessReview):"
        curl -sSk --cacert $CA -H "Authorization: Bearer $TOKEN" \
          -H "Content-Type: application/json" \
          -X POST \
          -d '{
            "apiVersion":"authorization.k8s.io/v1",
            "kind":"SelfSubjectAccessReview",
            "spec":{
              "resourceAttributes":{
                "namespace":"demo-sa4",
                "verb":"list",
                "group":"",
                "resource":"pods"
              }
            }
          }' \
          "$API/apis/authorization.k8s.io/v1/selfsubjectaccessreviews" | jq .

        echo "2. Sprawdzam, czy mogę usunąć pods (DELETE) w demo-sa4:"
        curl -sSk --cacert $CA -H "Authorization: Bearer $TOKEN" \
          -H "Content-Type: application/json" \
          -X POST \
          -d '{
            "apiVersion":"authorization.k8s.io/v1",
            "kind":"SelfSubjectAccessReview",
            "spec":{
              "resourceAttributes":{
                "namespace":"demo-sa4",
                "verb":"delete",
                "group":"",
                "resource":"pods"
              }
            }
          }' \
          "$API/apis/authorization.k8s.io/v1/selfsubjectaccessreviews" | jq .

        sleep 3600
    volumeMounts:
    - name: sa-token
      mountPath: /var/run/secrets/kubernetes.io/serviceaccount
      readOnly: true
  volumes:
  - name: sa-token
    projected:
      sources:
      - serviceAccountToken:
          path: token
          expirationSeconds: 3600
      - configMap:
          name: kube-root-ca.crt
          items:
            - key: ca.crt
              path: ca.crt
```

```bash
kubectl apply -f pod-ssar-test.yaml
```

Sprawdzenie logów poda:

```bash
kubectl logs ssar-test-pod -n demo-sa4
```

**Oczekiwany wynik**:

1. Pierwsza część odpowiada, że `allowed: true`, bo `ssar-sa` ma Role, która pozwala na `list pods` w `demo-sa4`.
2. Druga część odpowiada, że `allowed: false`, ponieważ nikt nie przyznał uprawnienia `delete pods` w tej roli.

Przykładowa struktura odpowiedzi:

```json
{
  "apiVersion": "authorization.k8s.io/v1",
  "kind": "SelfSubjectAccessReview",
  "status": {
    "allowed": true,
    "denied": false,
    "evaluationError": "",
    "reason": "Allowed by rolebinding demo-sa4/pods-reader-binding: Role demo-sa4/pods-reader"
  }
}
{
  "apiVersion": "authorization.k8s.io/v1",
  "kind": "SelfSubjectAccessReview",
  "status": {
    "allowed": false,
    "denied": true,
    "evaluationError": "",
    "reason": "RBAC: rbac.authorization.k8s.io:rolebindings ... no matching rule to allow delete pods"
  }
}
```

