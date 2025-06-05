**Wprowadzenie**

W przypadku Kubernetes „backup” oznacza nie tylko zabezpieczenie danych aplikacji (Persistent Volumes), ale przede wszystkim zachowanie spójnego stanu konfiguracji klastra: zasobów API (Deploymenty, Services, ConfigMapy, Secrets itp.), stanu etcd oraz definicji CRD/Custom Resources. Skuteczne tworzenie kopii zapasowych pozwala na szybkie odtworzenie środowiska po awarii, migrację między klastrami lub odtworzenie skutków nieumyślnych zmian w konfiguracji. Poniżej przedstawiamy przegląd kluczowych elementów, które warto chronić, oraz opisujemy najpopularniejsze metody backupu i przywracania konfiguracji Kubernetes.

---

## 1. Co należy backupować?

1. **Stan etcd**
   Etcd to rozproszony klucz-wartość pełniący rolę głównego repozytorium stanu klastra. Zawiera definicje wszystkich obiektów Kubernetes (w tym Secrets). Jeśli etcd ulegnie uszkodzeniu lub dane zostaną przypadkowo zmienione lub usunięte, bez backupu etct nie da się przywrócić faktycznego stanu klastra.

2. **Definicje Custom Resource Definitions (CRD)**
   Jeżeli w klastrze zainstalowano rozszerzenia typu CRD (np. PrometheusOperator, cert-manager, Ingress custom resources), warto wykonać osobne backupy ich manifestów lub użyć narzędzi, które uwzględniają te zasoby.

3. **Zasoby Namespacowane i Nienamespacowane**

    * **Zasoby Namespacowane**: Deployment, StatefulSet, DaemonSet, Service, ConfigMap, Secret, Role/RoleBinding, Ingress, ServiceAccount itp.
    * **Zasoby Nienamespacowane**: Namespace (definicja i ewentualne adnotacje), Node, PersistentVolume (PV), StorageClass, ClusterRole/ClusterRoleBinding, PodSecurityPolicy (jeśli używane), CustomResourceDefinition, itp.

4. **Persistent Volumes i dane aplikacji**
   Backup samej konfiguracji (zasobów) nie zastąpi backupu danych aplikacji przechowywanych w PV. Warto skorzystać z dedykowanych narzędzi (Velero, Stash, kasten) lub z funkcji natywnego storage (snapshoty dysków w chmurze) do zabezpieczenia wolumenów.

5. **Certyfikaty TLS i klucze szyfrowania**
   – Klucze używane przez kube-apiserver (TLS, EncryptionConfiguration)
   – Certyfikaty Ingress, CertManager lub inne, które nie są przechowywane w etcd (jeśli użyto dedykowanego sekretu lub zewnętrznego magazynu).

---

## 2. Backup etcd: rozsądne podejście do źródła prawdy

### 2.1. Etcd w środowisku kontrolowanym przez kubeadm

Jeżeli klaster został utworzony przy pomocy **kubeadm**, domyślnie etcd działa jako stateless pod na węźle master. Aplikacja etcd przechowuje pliki bazy danych pod ścieżką `/var/lib/etcd`. Kubernetes oferuje wbudowane polecenie do snapshotu:

```bash
# 1. Uzyskanie dostępu do węzła master
SSH user@master-node

# 2. Utworzenie katalogu na snapshot
sudo mkdir -p /var/backups/etcd

# 3. Wykonanie snapshotu etcd
sudo ETCDCTL_API=3 etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  snapshot save /var/backups/etcd/snapshot-$(date +%Y%m%d%H%M%S).db
```

**Wyjaśnienie parametrów**:

* `--endpoints` – adresy API etcd (zwykle localhost:2379).
* `--cacert`, `--cert`, `--key` – ścieżki do plików TLS, które umożliwiają `etcdctl` autoryzację w etcd.
* `snapshot save` – zapisuje bazę etcd w pliku `.db`. Zalecane jest dodanie daty/godziny do nazwy pliku, by łatwiej zarządzać wieloma snapshotami.

**Weryfikacja poprawności snapshotu**:

```bash
sudo ETCDCTL_API=3 etcdctl \
  v3snapshot status /var/backups/etcd/snapshot-20250605120000.db

# Przykład odpowiedzi:
#   Revision: 123456
#   Total key-value pairs: 150
#   Total size: 1024 kB
```

Jeśli zwróci poprawne statystyki, snapshot został wykonany pomyślnie.

### 2.2. Automatyzacja backupu etcd

1. **Chronjob na węźle master**
   Wykorzystanie crona lub systemd-timer do cyklicznego wywoływania powyższej komendy. Przykład prostego skryptu w `/usr/local/bin/backup-etcd.sh`:

   ```bash
   #!/bin/bash
   BACKUP_DIR="/var/backups/etcd"
   TIMESTAMP=$(date +%Y%m%d%H%M%S)
   FILENAME="${BACKUP_DIR}/snapshot-${TIMESTAMP}.db"
   # Tworzenie katalogu, jeśli nie istnieje
   mkdir -p "${BACKUP_DIR}"

   ETCDCTL_API=3 etcdctl \
     --endpoints=https://127.0.0.1:2379 \
     --cacert=/etc/kubernetes/pki/etcd/ca.crt \
     --cert=/etc/kubernetes/pki/etcd/server.crt \
     --key=/etc/kubernetes/pki/etcd/server.key \
     snapshot save "${FILENAME}"

   # Opcjonalnie: usuń snapshoty starsze niż 7 dni
   find "${BACKUP_DIR}" -type f -name "snapshot-*.db" -mtime +7 -exec rm {} \;
   ```

   W `crontab -e` (jako root) wpis:

   ```
   0 */6 * * * /usr/local/bin/backup-etcd.sh >> /var/log/etcd-backup.log 2>&1
   ```

   Powyższa reguła uruchomi backup co 6 godzin i zachowa log w `/var/log/etcd-backup.log`. Pliki starsze niż 7 dni zostaną usunięte.

2. **Przechowywanie snapshotów poza maszyną**
   Po utworzeniu lokalnego pliku warto przenieść go do zewnętrznego repozytorium (S3, NFS, SSH, Dropbox itp.). Przykładowe dodanie wysłania do S3 w skrypcie:

   ```bash
   # Po utworzeniu snapshot:
   aws s3 cp "${FILENAME}" s3://my-k8s-backups/etcd/
   ```

   Dzięki temu, w razie awarii węzłów master, snapshot będzie dostępny w zewnętrznym miejscu.

### 2.3. Przywracanie etcd ze snapshotu

W środowisku kubeadm należy wykonać przywracanie etcd w trybie offline (gdy etcd nie działa) i następnie zresetować konfigurację kube-apiserver. Przykładowe kroki:

1. **Zatrzymaj kube-apiserver i etcd** (jeśli działają jako stateless pods w kubeadm, można usunąć DV-API lub uruchomić je w innym trybie).

2. **Przywróć DB**:

   ```bash
   ETCDCTL_API=3 etcdctl snapshot restore /var/backups/etcd/snapshot-20250605120000.db \
     --name etcd-restore \
     --initial-cluster "etcd-restore=https://127.0.0.1:2380" \
     --initial-cluster-token restore-token \
     --initial-advertise-peer-urls https://127.0.0.1:2380 \
     --data-dir /var/lib/etcd-restore
   ```

   – `--name` – nazwa instancji etcd.
   – `--initial-cluster` – definicja węzła.
   – `--initial-advertise-peer-urls` – adres, na którym inne węzły będą się łączyć (jeśli to klastra jednouwęzłowy).
   – `--data-dir` – katalog docelowy, w którym etcd odczyta przywróconą bazę.

3. **Zamontuj przywrócony katalog jako źródło etcd**. W pliku manifestu kube-apiserver (zwykle `/etc/kubernetes/manifests/etcd.yaml`) zmodyfikuj pole `dataDir` lub w przypadku kubeadm:

    * Przenieś `/var/lib/etcd` na `/var/lib/etcd-old`.
    * Skopiuj zawartość `/var/lib/etcd-restore/global` do `/var/lib/etcd`.

4. **Uruchom ponownie kube-apiserver/etcd** – systemd lub kubelet automatycznie wznowi kontroler.

5. **Sprawdź stan**:

   ```bash
   ETCDCTL_API=3 etcdctl \
     --endpoints=https://127.0.0.1:2379 \
     --cacert=/etc/kubernetes/pki/etcd/ca.crt \
     --cert=/etc/kubernetes/pki/etcd/server.crt \
     --key=/etc/kubernetes/pki/etcd/server.key \
     member list
   ```

   Jeśli komenda zwraca listę członków, etcd działa poprawnie.

---

## 3. Backup definicji zasobów Kubernetes

Oprócz etcd można również przechowywać w postaci statycznych manifestów lub eksportów YAML definicje obiektów. Dzięki temu w przypadku awarii lub błędnego usunięcia można szybko odtworzyć konfigurację.

### 3.1. Eksport wszystkich zasobów z danego namespace

Jeżeli chcemy uzyskać kompletną kopię konfiguracji (Deploymentów, Services, ConfigMap, Secret itp.) w postaci YAML:

```bash
kubectl get all,configmaps,secrets,ingress,networkpolicies,pvc -n prod -o yaml > backup-prod-all.yaml
```

Kroki:

1. `all` – obejmuje Deployment, StatefulSet, DaemonSet, ReplicaSet, Pod, Service, ReplicaController (wszystkie główne typy „workload” i „service”).
2. Dodatkowo warto ręcznie dodać zasoby takie jak:

    * `configmaps`
    * `secrets` (uwaga: YAML będzie zawierał wartości zakodowane w Base64; jeśli chodzi o poufność, lepiej exportować pojedyncze Secret ręcznie i przesyłać zaszyfrowane w zewnętrzny magazyn)
    * `ingress`
    * `networkpolicies`, `persistentvolumeclaims` itp.

Taki jeden plik YAML można umieścić w repozytorium Git (repo przyjazny do wersjonowania). Dzięki temu historia zmian zawierać będzie snapshoty konfiguracji z różnych momentów.

### 3.2. Eksport wszystkich zasobów z całego klastra

Jeżeli chcemy wyeksportować zasoby spoza namespace (ClusterRole, ClusterRoleBinding, StorageClass, CRD, Namespace definitions itp.), można użyć:

```bash
# Zbiorczy eksport zasobów nienamespacowanych:
kubectl get crd,clusterrole,clusterrolebinding,storageclass,pv,namespace -o yaml > backup-cluster-resources.yaml

# Zasobów namespacowanych (dla wszystkich namespace):
for ns in $(kubectl get ns -o name | cut -d/ -f2); do
  kubectl get all,configmaps,secrets,ingress,pvc -n $ns -o yaml >> backup-all-namespaces.yaml
done
```

Pliki wynikowe można połączyć w jedno repozytorium. Warto zwrócić uwagę na:

* **Kolejność**: przy przywracaniu ClusterRole/CRD należy je utworzyć przed zasobami, które ich używają (np. Custom Resources).
* **Separacja**: lepiej mieć osobne pliki dla zasobów globalnych i dla poszczególnych namespace’ów.

### 3.3. Automatyzacja eksportu konfiguracji

* **Cron lub CI/CD**:
  – Skrypt wykonujący powyższe komendy i wysyłający wygenerowane pliki do systemu kontroli wersji (Git, SVN) lub do zdalnego storage (S3, artifactory).
  – Przykład (Bash + Git):

  ```bash
  #!/bin/bash
  DATE=$(date +%Y%m%d%H%M%S)
  BACKUP_DIR="/var/backups/k8s-configs/${DATE}"
  mkdir -p "${BACKUP_DIR}"

  # Backup Cluster-scoped resources
  kubectl get crd,clusterrole,clusterrolebinding,storageclass,pv,namespace -o yaml > "${BACKUP_DIR}/cluster-${DATE}.yaml"

  # Backup Namespaced resources
  for ns in $(kubectl get ns -o jsonpath='{.items[*].metadata.name}'); do
    mkdir -p "${BACKUP_DIR}/${ns}"
    kubectl get all,configmaps,secrets,ingress,pvc -n "${ns}" -o yaml > "${BACKUP_DIR}/${ns}/resources-${ns}.yaml"
  done

  # Skopiowanie do repozytorium Git
  cd /opt/k8s-backups-repo
  git pull
  cp -r "${BACKUP_DIR}" .
  git add "${DATE}"
  git commit -m "Backup Kubernetes configs ${DATE}"
  git push origin main
  ```

  – Skrypt można uruchamiać codziennie lub co kilka godzin, w zależności od częstotliwości zmian w klastrze.

* **Narzędzia specjalizowane**:
  – **kubectl-backup** (skrypt/szeroko stosowane narzędzie Open Source) – potrafi zautomatyzować pobieranie i przechowywanie w ustalonym magazynie.
  – **ark/Velero** – rozbudowane narzędzie do backupu i przywracania klastra (opisane w punkcie 4).

---

## 4. Velero: kompleksowy backup i restore klastra

Velero (dawniej Heptio Ark) to jedno z najpopularniejszych narzędzi open source przeznaczonych do backupu, migracji i disaster recovery w Kubernetes. Oferuje:

* Backup i przywracanie zasobów (Deploymenty, ConfigMapy, Secrets itp.).
* Backup i przywracanie Persistent Volumes (snapshoty zależne od dostawcy).
* Możliwość przechowywania kopii zapasowych w zewnętrznych storage (S3, Azure Blob, GCS).
* Planowanie okresowych backupów (Schedule) i definiowanie retencji (TTL).
* Migrację między klastrami (klucz „restore-as-new-namespace” itp.).

### 4.1. Instalacja Velero

Przed przystąpieniem do instalacji upewnij się, że masz skonfigurowany dostęp do zewnętrznego magazynu (np. bucket S3) oraz że posiadasz klucz IAM z odpowiednimi uprawnieniami.

1. **Pobranie binarki Velero**
   Pobierz i rozpakuj odpowiednią wersję dla systemu operacyjnego (np. Linux/macOS) ze strony GitHub:

   ```bash
   wget https://github.com/vmware-tanzu/velero/releases/download/v1.11.0/velero-v1.11.0-linux-amd64.tar.gz
   tar -xzf velero-v1.11.0-linux-amd64.tar.gz
   sudo mv velero-v1.11.0-linux-amd64/velero /usr/local/bin/
   ```

2. **Utworzenie Credentials dla dostawcy storage**
   – Dla AWS S3: plik `credentials-velero` zawierający:

   ```
   [default]
   aws_access_key_id = <YOUR_AWS_KEY_ID>
   aws_secret_access_key = <YOUR_AWS_SECRET_KEY>
   ```

   – Dla Google Cloud Storage lub Azure: analogiczne pliki JSON lub pliki z kluczem.

3. **Zainstalowanie Velero w klastrze**
   Przykład dla AWS S3:

   ```bash
   velero install \
     --provider aws \
     --plugins velero/velero-plugin-for-aws:v1.11.0 \
     --bucket my-velero-backups \
     --backup-location-config region=eu-central-1 \
     --secret-file ./credentials-velero
   ```

   – `--bucket` – nazwa bucketa S3, w którym Velero będzie przechowywać backupy.
   – `--backup-location-config` – konfiguracja regionu i inne opcje.
   – `--secret-file` – ścieżka do pliku z poświadczeniami.

   W wyniku pojawi się namespace `velero`, a w nim:

    * Pod `velero` (kontener backup/restic, velero-server).
    * Deployment i ServiceAccount w namespace `velero`.
    * Dodatkowe ConfigMapy i Secret.

### 4.2. Utworzenie pierwszego backupu

Po zainstalowaniu można wykonać backup całego klastra lub wybranych namespace’ów:

```bash
velero backup create backup-prod-20250605 \
  --include-namespaces prod,staging \
  --snapshot-volumes \
  --wait
```

**Wyjaśnienie**:

* `backup create` – tworzy backup.
* `--include-namespaces prod,staging` – ogranicza backup do podanych namespace’ów (opcjonalnie).
* `--snapshot-volumes` – wykonuje snapshoty Persistent Volumes (o ile istnieje dla danego rodzaju storage).
* `--wait` – poczeka, aż backup się zakończy, zanim zwróci kontrolę do użytkownika.

Status backupu można sprawdzić:

```bash
velero backup get
```

Przykładowa odpowiedź:

| NAME                 | STATUS    | CREATED                       | EXPIRES | SELECTOR |
| -------------------- | --------- | ----------------------------- | ------- | -------- |
| backup-prod-20250605 | Completed | 2025-06-05 14:30:00 +0000 UTC | 29d     |          |

### 4.3. Przywracanie z backupu

Aby przywrócić backup w tym samym lub innym klastrze:

```bash
velero restore create --from-backup backup-prod-20250605
```

Opcjonalnie można przywrócić tylko wybrane namespace’y lub zasoby:

```bash
velero restore create \
  --from-backup backup-prod-20250605 \
  --include-namespaces prod \
  --restore-volumes
```

W przypadku migracji między klastrami, zaleca się:

1. Zainstalowanie Velero w klastrze docelowym z tą samą konfiguracją dostępu do S3.
2. Skopiowanie danych z S3 w odpowiednie miejsce (bucket).
3. Uruchomienie polecenia `velero restore create` – Velero pobierze manifesty i snapshoty PV, a następnie przywróci zasoby.

#### Uwaga: restauracja PB (PersistentVolume)

* Jeżeli PV bazuje na storage zewnętrznym (np. EBS, EFS, Azure Disk), Velero utworzy nowy wolumen na podstawie snapshotu (współpraca z restic lub natywnymi snapshotami).
* Jeżeli PV korzysta z lokalnego dysku na węźle, PV nie zostanie odtworzony (zależnie od typu `volumeMode`). Wtedy konieczne może być ręczne przygotowanie zasobu (np. Dynamic Provisioning).

---

## 5. Alternatywne podejścia i narzędzia

### 5.1. Kasten K10 (by Veeam)

Kasten K10 to komercyjne (ze wspieranym darmowym tier-em dla małych klastrów) rozwiązanie oferujące:

* Backup i restore zasobów Kubernetes
* Snapshoty PV (różne backendy storage)
* Polityki retencji, szyfrowanie backupów, integrację z wieloma providerami chmurowymi
* Prosty interfejs webowy do zarządzania backupami i przywracania
* Możliwość migracji klastra między on-prem a chmurą

Instalacja zwykle odbywa się przez Helm chart:

```bash
helm repo add kasten https://charts.kasten.io/
helm install k10 kasten/k10 --namespace=kasten-io --create-namespace
```

### 5.2. Stash (by AppsCode)

Stash to kolejny projekt open source, który umożliwia backup zasobów i wolumenów:

* Oferuje CRD typu `BackupConfiguration`, `BackupSession`, `RestoreSession`.
* Umożliwia backup PVC przy użyciu różnych snapshotterów (GCP, AWS, CSI).
* Elastyczna definicja reguł (filtry etykiet).
* Integracja z zewnętrznymi magazynami (S3, GCS, Azure Blob, NFS).

Przykład definiowania `BackupConfiguration`:

```yaml
apiVersion: stash.appscode.com/v1beta1
kind: BackupConfiguration
metadata:
  name: backup-my-app
  namespace: prod
spec:
  repository:
    name: s3-repo
  schedule: "0 2 * * *"
  target:
    ref:
      apiVersion: apps/v1
      kind: Deployment
      name: my-app
    paths:
      - /data # ścieżka wewnątrz kontenera
  retentionPolicy:
    keepLast: 7
```

### 5.3. Ręczna strategia GitOps + kube-apiserver-aggregator

**GitOps** zakłada, że cała konfiguracja klastra (manifesty YAML) trzymana jest w repozytorium Git i wdrażana przy pomocy narzędzi takich jak ArgoCD lub Flux. W takim modelu:

1. Każda zmiana manifestów (Deployment, Service, ConfigMap itp.) trafia do Git z recenzją pull request.
2. Git praktycznie staje się historycznym backupem (możliwość checkout starego commita i odtworzenie konfiguracji).
3. Przywrócenie stanu klastra sprowadza się do odtworzenia stanu Git i wymuszenia synchronizacji w ArgoCD/Flux.
4. Należy nadal pamiętać o etcd i backupie danych, gdyż GitOps nie chroni danych aplikacji (PV).

---

## 6. Przywracanie konfiguracji po awarii

### 6.1. Etap 1: Odtworzenie etcd lub infrastruktury K8s

1. **Nowe węzły master lub reinstalacja K8s** (np. `kubeadm init`).
2. **Przywrócenie etct** z ostatniego sprawdzonego snapshotu (opis w sekcji 2.3).
3. **Zweryfikowanie**, że `kubectl get nodes` i `kubectl get pods -n kube-system` zwracają oczekiwany stan.

### 6.2. Etap 2: Przywrócenie zasobów Namespacowanych i Nienamespacowanych

1. **Kluczowe zasoby nienamespacowane (CRD, StorageClass, RBAC, Namespace)**

   ```bash
   kubectl apply -f backup-cluster-resources.yaml
   ```

   Kolejność:

    * Namespace
    * StorageClass/SC
    * CRD (by zasoby Custom Resources mogły być odtworzone)
    * ClusterRole/ClusterRoleBinding
    * Reszta (np. PV, itp.)

2. **Zasoby namespacowane**

   ```bash
   # Dla każdego namespace:
   kubectl apply -f backup-prod-all.yaml
   kubectl apply -f backup-staging-all.yaml
   ```

   – Rezultat: Deploymenty, Services, ConfigMapy, Secrets, itp.

3. **Persistent Volumes i PVC**
   – Jeśli PV bazuje na dynamicznie provisioningowanym storage (np. EBS), PVC zostaną odtworzone automatycznie, a PV przypisze nowy wolumen.
   – W przypadku snapshots EBS/GCP, użycie Velero/restic (punkt 4) lub ręczna rekreacja PV.

4. **Ponowne wdrożenie Ingress/CertManager**
   – Po przywróceniu CRD CertManager, przywróć Custom Resources typu Certificate, CertificateRequest.
   – Ingress ponownie pobierze certyfikaty z odpowiednich Secret.

### 6.3. Weryfikacja

1. `kubectl get nodes,namespace,deployments,services,pods` – sprawdź, czy struktura jest poprawna.
2. `kubectl logs` dla krytycznych podów w `kube-system` (core-DNS, kube-proxy, kube-apiserver).
3. Testy aplikacji: sprawdź, czy usługi front-endowe łączą się z bazą danych, czy configmaps/secret są prawidłowo odczytywane.
4. Sprawdź, czy PV są podłączone i zawartość danych (jeżeli backupowałeś wolumeny).

