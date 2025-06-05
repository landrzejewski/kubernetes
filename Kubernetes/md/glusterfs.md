## Wprowadzenie

GlusterFS to skalowalny, rozproszony system plików oparty o architekturę typu *user-space*, rozwijany przez Red Hat. Umożliwia łączenie zasobów dyskowych wielu serwerów w jeden, spójny, sieciowy system plików, oferując wysoką dostępność i odporność na awarie (replikacja). W kontekście Kubernetes, GlusterFS może być wykorzystane jako backend dla wolumenów „Persistent Volumes” (**PV**) za pośrednictwem **CSI** (Container Storage Interface). Dzięki CSI możliwa jest zarówno statyczna, jak i dynamiczna alokacja wolumenów GlusterFS w klastrze Kubernetes.

Ten tutorial opisuje:

1. **Instalację oraz konfigurację** klastra GlusterFS na dystrybucji Debian (w oparciu o Debian 11/12).
2. **Instalację klienta GlusterFS** na węzłach Kubernetes (aby węzły mogły montować wolumeny).
3. **Instalację i konfigurację sterownika CSI** dla GlusterFS w Kubernetes.
4. **Tworzenie obiektów StorageClass, PersistentVolume (PV) i PersistentVolumeClaim (PVC)**, służących do przydzielania i używania zasobów GlusterFS przez aplikacje w Kubernetes.
5. **Przykładowe testy**, dowodzące poprawności działania.

---

## Założenia i środowisko

* **Debian 11 lub Debian 12** jako system bazowy dla węzłów GlusterFS.
* Co najmniej **3 serwery Debian** (nazwijmy je `node1`, `node2`, `node3`) w tej samej sieci, z dostępem mutalnym po nazwach/DNS.
* Każdy węzeł GlusterFS posiada przynajmniej **po jeden dysk** dedykowany pod brakery (np. `/dev/sdb`).
* **Użytkownik z uprawnieniami `sudo`** na wszystkich maszynach.
* Węzły Kubernetes już istnieją lub zostaną utworzone osobno (np. przy użyciu kubeadm). Tutorial nie obejmuje samej instalacji Kubernetesa.
* Zakładamy, że **czas i strefa czasowa** na węzłach jest poprawnie zsynchronizowana (NTP).
* W praktyce, by umożliwić dynamiczne tworzenie wolumenów (provisioning), używa się **Heketi** lub innego brokera – w tym tutorialu pokażemy zarówno wariant statyczny (ręczne tworzenie PV), jak i wzmiankowo wskażemy, jak włączyć możliwość dynamicznego provisioningu poprzez Heketi + CSI.

---

## Część I: Instalacja i konfiguracja klastra GlusterFS na Debianie

### 1. Przygotowanie hostów

1. **Ustaw nazwy hostów i /etc/hosts**
   Na każdym z węzłów GlusterFS należy w pliku `/etc/hosts` zdefiniować wpisy odpowiadające adresom IP i nazwom wszystkich węzłów. Przykład (na każdym nodeX, jako root lub z `sudo`):

   ```bash
   sudo bash -c 'cat >> /etc/hosts <<EOF
   192.168.5.50   node1.home.lan   node1
   192.168.5.56   node2.home.lan   node2
   192.168.5.57   node3.home.lan   node3
   EOF'
   ```

   Następnie ustaw hostname na każdym serwerze:

   ```bash
   # Na node1:
   sudo hostnamectl set-hostname node1.home.lan

   # Na node2:
   sudo hostnamectl set-hostname node2.home.lan

   # Na node3:
   sudo hostnamectl set-hostname node3.home.lan
   ```

   ([shape.host][1], [shape.host][1])

2. **Sprawdź, czy hosty się widzą**
   Z każdego nodeX powinno być możliwe wywołanie `ping nodeY.home.lan` i odwrotnie.

   ```bash
   ping -c 3 node2.home.lan
   ```

---

### 2. Instalacja pakietów GlusterFS

Na wszystkich węzłach (node1, node2, node3) wykonaj:

```bash
sudo apt update
sudo apt install -y glusterfs-server glusterfs-common
```

* `glusterfs-server` – usługi potrzebne do działania demona `glusterd`.
* `glusterfs-common` – klient oraz narzędzia pomocnicze.
* Zaraz po instalacji włącz i uruchom usługę glusterd:

  ```bash
  sudo systemctl enable --now glusterd.service
  ```

([shape.host][1], [docs.gluster.org][2])

---

### 3. Konfiguracja dysków (“bricków”)

1. **Podłącz dyski do każdej maszyny** (np. `/dev/sdb`). W przykładzie użyjemy XFS jako systemu plików na brickach:

   ```bash
   # a) Sprawdź dostępność dysku, np.:
   lsblk

   # b) Sformatuj partycję /dev/sdb1:
   sudo mkfs.xfs -i size=512 /dev/sdb1

   # c) Utwórz katalog na brick:
   sudo mkdir -p /data/brick1

   # d) Dodaj wpis do /etc/fstab, by montować automatycznie:
   echo '/dev/sdb1  /data/brick1  xfs  defaults  1 2' | sudo tee -a /etc/fstab

   # e) Zamontuj:
   sudo mount -a
   ```

   **Uwaga**: jeśli dysk ma niewykrojoną partycję, należy utworzyć partycję przed formatowaniem.
   ([docs.gluster.org][2], [docs.gluster.org][3])

2. W efekcie, na każdym węźle powinno istnieć `/data/brick1` zamontowane na sdb1.

---

### 4. Tworzenie puli zaufanych węzłów (trusted pool)

Aby węzły GlusterFS współpracowały, muszą utworzyć tzw. „trusted pool”. Na **node1** (lub dowolnym węźle inicjującym) wykonaj:

```bash
# Na node1:
sudo gluster peer probe node2.home.lan
sudo gluster peer probe node3.home.lan

# Sprawdź status puli:
sudo gluster peer status
```

Powinny się pojawić wpisy wskazujące, że peerzy są „Peer in Cluster (Connected)”.
([kubedemy.io][4], [docs.gluster.org][2])

---

### 5. Utworzenie i uruchomienie Wolumenu GlusterFS

1. **Na node1** (gdzie już jesteś zalogowany jako root lub z sudo) utwórz wolumen o nazwie `k8s-volume`, replikowany pomiędzy wszystkimi trzema węzłami:

   ```bash
   sudo gluster volume create k8s-volume replica 3 transport tcp \
     node1.home.lan:/data/brick1 \
     node2.home.lan:/data/brick1 \
     node3.home.lan:/data/brick1
   ```

    * `replica 3` – oznacza, że każdy plik będzie replikowany na 3 kopie (po jednym bricku na każdym węźle).
    * `transport tcp` – rzadko modyfikuje się w standardowej sieci, zostawiamy TCP.

2. **Uruchom wolumen**:

   ```bash
   sudo gluster volume start k8s-volume
   ```

3. **Zweryfikuj informacje o wolumenie**:

   ```bash
   sudo gluster volume info k8s-volume
   ```

   Powinieneś zobaczyć informacje o bricked nodes, liczbie replik itd.
   ([kubedemy.io][4], [docs.gluster.org][2])

**Wynik**: teraz masz działający trzywęzłowy klaster GlusterFS, z wolumenem `k8s-volume`, w pełni replikowanym.

---

## Część II: Instalacja klienta GlusterFS na węzłach Kubernetes

Aby węzły (worker nodes) Kubernetes mogły montować wolumeny z klastra GlusterFS, musisz zainstalować na nich pakiet `glusterfs-client`.

Na każdym węźle K8s (worker) wykonaj:

```bash
sudo apt update
sudo apt install -y glusterfs-client
```

([kubedemy.io][4], [kubedemy.io][4])

Dzięki temu węzły będą posiadać narzędzia umożliwiające montowanie wolumenów GlusterFS.

---

## Część III: Instalacja i konfiguracja sterownika CSI dla GlusterFS w Kubernetes

### 1. Pobranie i wdrożenie manifestów sterownika CSI

Oficjalny kod sterownika **GlusterFS CSI** znajduje się w repozytorium GitHub:

> [https://github.com/gluster/gluster-csi-driver](https://github.com/gluster/gluster-csi-driver) ([github.com][5])

Aby wdrożyć sterownik w klastrze K8s:

1. **Zainstaluj `git` (jeśli nie jest dostępny)**:

   ```bash
   sudo apt update
   sudo apt install -y git
   ```

2. **Sklonuj repozytorium gluster-csi-driver** (na którymkolwiek węźle, np. master lub na laptopie, by potem zastosować manifesty):

   ```bash
   git clone https://github.com/gluster/gluster-csi-driver.git
   cd gluster-csi-driver
   ```

3. W katalogu repozytorium znajdują się gotowe manifesty Kubernetes w folderze `deploy/kubernetes` (jeśli masz konkretną ścieżkę, zweryfikuj w repo, np. `deploy/kubernetes-1.20/glusterfs/`).
   Dla uproszczenia wersji w pełni kompatybilnej z K8s (wersja API), użyj katalogu odpowiadającego twojej wersji Kubernetes. Załóżmy, że korzystasz z **v1.24+** – manifesty prawdopodobnie w `deploy/kubernetes-1.24/glusterfs/`. Upewnij się, że ścieżka istnieje:

   ```bash
   ls deploy/kubernetes-1.24/glusterfs/
   # powinny być pliki takie jak: csi-attacher.yaml, csi-provisioner.yaml, csi-nodeplugin.yaml, driver.yaml itd.
   ```

4. **Zastosuj manifesty** (jako administrator klastra, np. `kubectl` na konfigurowanym kube-apiserver):

   ```bash
   # Przykład ścieżki – dostosuj do swojej wersji Kubernetes
   kubectl apply -f deploy/kubernetes-1.24/glusterfs
   ```

   Operacja ta utworzy następujące zasoby:

    * **Namespace** (zwykle `gluster-csi-driver` lub `default`, w zależności od manifestu).
    * Rolę RBAC (Role / ClusterRole + RoleBinding / ClusterRoleBinding) dla serwisów CSI.
    * **Deployment/DaemonSet**:

        * `csi-attacher` (prowizje/usuwanie wolumenów),
        * `csi-provisioner` (jeśli dynamiczne provisioningi),
        * `csi-nodeplugin` (komponent montowania: kontener uruchamiany na każdym węźle).
    * **DriverSet** / `CSIDriver` Object (rejestruje sterownik w API serverze K8s).
    * Sekrety / ConfigMap (jeśli potrzebne; np. do Heketi).

   ([github.com][5], [kubernetes-csi.github.io][6])

**Uwaga**: jeśli korzystasz z dynamicznego provisioningu, manifesty mogą zawierać odwołania do Heketi (usługa REST API do zarządzania bricked volumes). Jeśli nie chcesz konfiguracji Heketi, a jedynie montowanie już istniejących volume, powyższe manifesty i tak pozwolą na statyczne tworzenie PV (opisane dalej). Jeśli planujesz dynamiczne provisioningi, konieczne będzie:

* Wdrożenie **Heketi** (np. w kontenerze lub jako osobna usługa),
* Utworzenie sekretnych danych (login/hasło do Heketi) i ConfigMap z parametrami (np. `resturl`, `restuser`, `secretName`).

W celach demonstracyjnych w dalszej części skoncentrujemy się na **statycznych** PV, bez Heketi.

---

### 2. Weryfikacja działania sterownika CSI

Po zastosowaniu manifestów skontroluj, czy wszystkie pod’y i inne zasoby zostały uruchomione:

```bash
# Lista podów w przestrzeni nazw, w której wdrożyłeś driver:
kubectl get pods -n gluster-csi-driver

# Powinieneś zobaczyć:
# csi-attacher-..., csi-provisioner-..., csi-nodeplugin-... (na każdym węźle) w stanie Running

# Sprawdź obiekty CSIDriver:
kubectl get csidrivers
# Powinna pojawić się pozycja np. "gluster.org.glusterfs" lub podobna

# Sprawdź, czy nie ma błędów:
kubectl describe pod <nazwa-poda> -n gluster-csi-driver
```

Jeżeli wszystkie pod’y są w stanie `Running` oraz obiekt `CSIDriver` istnieje, sterownik jest gotowy do pracy.
([github.com][5], [kubernetes-csi.github.io][6])

---

## Część IV: Tworzenie StorageClass, PersistentVolume i PersistentVolumeClaim

### 1. Przykładowy StorageClass dla GlusterFS CSI (Statyczny provisioning)

Ponieważ w tym tutorialu nie zakładamy Heketi, **StorageClass** wykorzystamy de facto jedynie do deklaracji sterownika CSI. Dzięki StorageClass będzie można wykonywać statyczne alokacje PV (ręcznie tworzone PV i PVC) albo – jeśli będzie skonfigurowany Heketi – dynamiczne provisioningi.

Utwórz plik `glusterfs-sc.yaml`:

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: glusterfs-csi
provisioner: org.gluster.glusterfs    # nazwa powinna odpowiadać polowi .name w obiekcie CSIDriver
reclaimPolicy: Retain                  # lub Delete, w zależności od strategii usuwania PV po PVC
volumeBindingMode: Immediate           # lub WaitForFirstConsumer
```

Zastosuj:

```bash
kubectl apply -f glusterfs-sc.yaml
```

**Wyjaśnienie pól**:

* `provisioner: org.gluster.glusterfs` – nazwa sterownika CSI, zarejestrowana w Kubernetes po wdrożeniu manifestów CSI (może być nieco inna; sprawdź `kubectl get csidrivers`).
* `reclaimPolicy: Retain` – po usunięciu PVC wolumen PV pozostaje (można go później manualnie usunąć). Wybierz `Delete` jeśli chcesz, by przy dynamicznym provisioningu wolumen był usuwany razem z PVC.
* `volumeBindingMode: Immediate` – PV zostanie przypisany od razu, niezależnie od schedulingu Podów. Dla zaawansowanych scenariuszy, gdy wolumeny są dostępne dopiero na węzłach, można ustawić `WaitForFirstConsumer`.
  ([docs.gluster.org][7], [cloud.google.com][8])

---

### 2. Przykładowy PersistentVolume (statyczny)

Poniższy manifest tworzy PV, który bezpośrednio wskazuje na istniejący wolumen GlusterFS (`k8s-volume`) z klastra:

```yaml
apiVersion: v1
kind: PersistentVolume
metadata:
  name: pv-glusterfs-static
spec:
  capacity:
    storage: 10Gi
  accessModes:
    - ReadWriteMany       # GlusterFS wspiera RWX
  persistentVolumeReclaimPolicy: Retain
  storageClassName: glusterfs-csi
  csi:
    driver: org.gluster.glusterfs   # nazwa sterownika CSI
    volumeHandle: k8s-volume        # identyfikator wolumenu GlusterFS
    readOnly: false
    # Parametry potrzebne do montowania:
    volumeAttributes:
      # Tutaj umieszczamy adres(y) i nazwy wolumenu (do montowania)
      endpoints: glusterfs-cluster  # nazwa Endpoints (opisane niżej)
      path: k8s-volume              # nazwa utworzonego wcześniej gluster volume
```

W powyższym przykładzie:

* `volumeHandle: k8s-volume` – identyfikator, pod którym sterownik CSI „rozpozna” istniejący wolumen GlusterFS.
* `volumeAttributes.endpoints` – nazwa zasobu typu `Endpoints`, który wskazuje na listę IP/hostname serwerów GlusterFS.
* `volumeAttributes.path` – nazwa wolumenu utworzonego w klastrze GlusterFS.

#### 2.1 Definicja Endpoints dla GlusterFS

Aby k8s mógł odnaleźć węzły GlusterFS, tworzymy obiekt **Endpoints**, wskazujący na IP hostów klastra GlusterFS. Utwórz plik `glusterfs-endpoints.yaml`:

```yaml
apiVersion: v1
kind: Endpoints
metadata:
  name: glusterfs-cluster
subsets:
  - addresses:
      - ip: 192.168.5.50   # node1
      - ip: 192.168.5.56   # node2
      - ip: 192.168.5.57   # node3
    ports:
      - port: 1           # port – w przypadku GlusterFS nie wykorzystujemy typowego portu 1, ale pole musi istnieć
```

Zastosuj:

```bash
kubectl apply -f glusterfs-endpoints.yaml
```

([kubedemy.io][4], [kubedemy.io][4])

#### 2.2 Utworzenie PV

Po utworzeniu Endpoints, utwórz PV:

```bash
kubectl apply -f pv-glusterfs-static.yaml
```

Zwróć uwagę, że:

* Pole `volumeHandle` musi dokładnie odpowiadać nazwie utworzonego wcześniej wolumenu `k8s-volume`.
* `storageClassName` musi zgadzać się z nazwą StorageClass (`glusterfs-csi`).

Sprawdź status PV:

```bash
kubectl get pv pv-glusterfs-static
```

---

### 3. Przykładowy PersistentVolumeClaim

Podlinkujmy utworzony PV do PVC. Utwórz plik `glusterfs-pvc.yaml`:

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: pvc-glusterfs-static
spec:
  accessModes:
    - ReadWriteMany
  resources:
    requests:
      storage: 10Gi
  storageClassName: glusterfs-csi
```

Zastosuj:

```bash
kubectl apply -f glusterfs-pvc.yaml
```

Sprawdź status PVC:

```bash
kubectl get pvc pvc-glusterfs-static
```

Po krótkiej chwili PVC powinien mieć status `Bound`, a pole `VOLUME` wskazywać na `pv-glusterfs-static`.

([kubedemy.io][4], [kubedemy.io][4])

---

## Część V: Testowanie działania – przykładowy Pod korzystający z PVC

Aby upewnić się, że montowanie działa poprawnie, uruchommy prosty Pod:

Utwórz plik `glusterfs-demo-pod.yaml`:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: glusterfs-test-pod
spec:
  containers:
    - name: alpine
      image: alpine:latest
      command: ["sh", "-c", "echo 'Test GlusterFS' > /data/congratulations.txt && sleep 3600"]
      volumeMounts:
        - name: gluster-volume
          mountPath: /data
  volumes:
    - name: gluster-volume
      persistentVolumeClaim:
        claimName: pvc-glusterfs-static
```

Zastosuj manifest:

```bash
kubectl apply -f glusterfs-demo-pod.yaml
```

Po chwili sprawdź, czy Pod działa:

```bash
kubectl get pods glusterfs-test-pod
```

Jeśli jest w stanie `Running`, wejdź do środka, aby zweryfikować zawartość:

```bash
kubectl exec -it glusterfs-test-pod -- sh -c "ls -l /data && cat /data/congratulations.txt"
```

Powinieneś zobaczyć plik `congratulations.txt` z treścią `Test GlusterFS`. Jeśli tak, oznacza to, że **PV** został poprawnie zmontowany i zapis do GlusterFS działa.
([kubedemy.io][4], [kubedemy.io][4])

