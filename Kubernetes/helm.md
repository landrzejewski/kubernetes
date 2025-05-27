## 1. Kluczowe pojęcia

* **Chart** – pakiet zawierający wszystkie zasoby Kubernetes (manifesty), jak szablony i pliki konfiguracyjne.
* **Release** – pojedyncza instalacja chartu (może ich być wiele dla jednego chartu, w różnych namespace’ach).
* **Repository** – miejsce przechowywania spakowanych chartów, skąd można je pobrać (`helm repo add`).

---

## 2. Tworzenie nowego chartu

```bash
# 1) Utwórz katalog roboczy
mkdir myapp-chart && cd myapp-chart

# 2) Wygeneruj szkielet chartu
helm create myapp
cd myapp
```

Po wywołaniu `helm create myapp` zobaczysz strukturę:

```
myapp/
├── Chart.yaml
├── values.yaml
├── charts/
└── templates/
    ├── deployment.yaml
    ├── service.yaml
    ├── _helpers.tpl
    └── ingress.yaml
```

---

## 3. Omówienie struktury

* **Chart.yaml** – metadane chartu (nazwa, wersja, opis, dependencies).
* **values.yaml** – wartości domyślne, które można nadpisać.
* **templates/** – katalog z plikami szablonów, używającymi Go templating.
* **charts/** – pod-folder na zależne subchart’y.

---

## 4. Templating – przykłady

### 4.1. Deployment

W `templates/deployment.yaml` znajdziesz fragment:

```yaml
spec:
  replicas: {{ .Values.replicaCount }}
  template:
    spec:
      containers:
      - name: {{ .Chart.Name }}
        image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"
        ports:
        - containerPort: {{ .Values.service.port }}
```

* `{{ .Values.replicaCount }}` – odczytuje z `values.yaml`.
* `{{ .Chart.Name }}` – nazwa chartu.

### 4.2. Helpers

W `_helpers.tpl` możesz zdefiniować funkcję:

```gotmpl
{{- define "myapp.fullname" -}}
{{ printf "%s-%s" .Release.Name .Chart.Name }}
{{- end -}}
```

Następnie w szablonach:

```yaml
metadata:
  name: {{ include "myapp.fullname" . }}
```

---

## 5. Konfigurowanie wartości (`values.yaml`)

Otwórz `values.yaml` i zmodyfikuj:

```yaml
replicaCount: 2

image:
  repository: nginx
  tag: stable

service:
  type: ClusterIP
  port: 80

ingress:
  enabled: false
```

Jeśli chcesz nadpisać przy instalacji:

```bash
helm install prod-release . \
  --namespace production \
  --set replicaCount=4,image.tag=1.19
```

Możesz także przekazać osobny plik:

```bash
helm install prod-release . \
  -f custom-values.yaml
```

---

## 6. Instalacja i upgrade

### 6.1. Instalacja

```bash
helm install myapp-release ./myapp \
  --namespace staging \
  --create-namespace
```

### 6.2. Sprawdzanie statusu

```bash
helm status myapp-release -n staging
kubectl get all -n staging
```

### 6.3. Upgrade po zmianie wartości lub szablonów

```bash
# Zmiana liczby replik
helm upgrade myapp-release ./myapp \
  --namespace staging \
  --set replicaCount=5
```

### 6.4. Rollback

```bash
helm rollback myapp-release 1     # do revision 1
```

---

## 7. Pakowanie i publikacja chartu

### 7.1. Pakowanie

```bash
helm package myapp
# → myapp-0.1.0.tgz
```

### 7.2. Tworzenie własnego repozytorium (GitHub Pages, ChartMuseum)

* **ChartMuseum**: uruchom ChartMuseum jako pod/usługę i `helm repo add myrepo http://chartmuseum:8080`.
* **GitHub Pages**:

    1. Umieść `.tgz` w katalogu `gh-pages` + index.yaml.
    2. `helm repo index . --url https://youruser.github.io/yourrepo/`
    3. `helm repo add yourrepo https://youruser.github.io/yourrepo/`

### 7.3. Aktualizacja indeksu

Za każdym razem, gdy dodasz nowy pakiet do repo:

```bash
helm repo index . --merge index.yaml --url https://your.repo.url/
```

---

## 8. Zależności (Dependencies)

W `Chart.yaml` możesz zadeklarować inne charty:

```yaml
dependencies:
  - name: redis
    version: 14.8.8
    repository: https://charts.bitnami.com/bitnami
```

Następnie:

```bash
helm dependency update ./myapp
# Tworzy charts/redis-14.8.8.tgz
```

Poniżej krok-po-kroku przykład, jak zainstalować gotowy chart PostgreSQL 
(np. z repozytorium Bitnami) i skonfigurować go pod konkretne potrzeby przy pomocy 
własnego pliku `values.yaml` lub flagi `--set`.

---

## 1. Dodanie repozytorium i sprawdzenie dostępnych wersji

```bash
# 1.1 Dodaj repo Bitnami i zaktualizuj indeks
helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo update

# 1.2 Podejrzyj dostępne wersje PostgreSQL
helm search repo bitnami/postgresql
```

## 2. Zobaczenie domyślnych wartości

Zanim coś nadpiszemy, warto „prześwietlić” co chart udostępnia do konfiguracji:

```bash
helm show values bitnami/postgresql > postgresql-default-values.yaml
```

Plik `postgresql-default-values.yaml` zawiera pełen zestaw opcji (persistence, resources, użytkownicy, hasła, service, metrics itp.).

---

## 3. Przygotowanie własnego `values.yaml`

Stwórz plik `custom-postgresql-values.yaml` z fragmentami, które chcesz zmienić. Na przykład:

```yaml
## custom-postgresql-values.yaml

# 1) Bezpieczne hasła (lub możesz pominąć i chart wygeneruje losowe)
auth:
  username: myuser
  password: myS3cretP@ss
  database: mydatabase

# 2) Ustawienia storage
primary:
  persistence:
    enabled: true
    size: 20Gi
    storageClass: fast-ssd

# 3) Zasoby (limity i rezerwacje)
resources:
  requests:
    cpu: 500m
    memory: 512Mi
  limits:
    cpu: 1
    memory: 1Gi

# 4) Typ usługi i port (ClusterIP/LoadBalancer)
service:
  type: ClusterIP
  port: 5432

# 5) (Opcjonalnie) metryki Prometheusa
metrics:
  enabled: true
  service:
    monitor:
      enabled: true
      additionalLabels:
        release: prometheus
```

---

## 4. Instalacja z użyciem `-f`

```bash
helm install pg-release bitnami/postgresql --namespace database --create-namespace -f postgresql-default-values.yaml
```

* `pg-release` – nazwa Twojego „release”.
* `-f ...` – przekazuje Twój plik z nadpisanymi wartościami.
* `--namespace database --create-namespace` – tworzy (jeśli trzeba) i używa namespace’u `database`.

---

## 5. Alternatywa: nadpisanie pojedynczych wartości flagą `--set`

Jeśli chcesz szybko zmienić kilkanaście prostych ustawień bez pliku:

```bash
helm install pg-demo bitnami/postgresql \
  --namespace database \
  --create-namespace \
  --set auth.username=demoUser \
  --set auth.password=DemoP@ss123 \
  --set primary.persistence.size=10Gi \
  --set resources.requests.memory=256Mi \
  --set metrics.enabled=true
```

Flagi `--set` łączą się kropkami z hierarchią w `values.yaml`.

---

## 6. Weryfikacja i aktualizacje

* Sprawdź status i adres usługi:

  ```bash
  helm status pg-release -n database
  kubectl get svc -n database
  ```
* Zmiana konfiguracji po instalacji:

    1. Edytuj `custom-postgresql-values.yaml` lub przygotuj kolejny plik.
    2. Uruchom:

       ```bash
       helm upgrade pg-release bitnami/postgresql \
         -n database \
         -f custom-postgresql-values.yaml
       ```
* Rollback do poprzedniej wersji:

  ```bash
  helm rollback pg-release 1
  ```
