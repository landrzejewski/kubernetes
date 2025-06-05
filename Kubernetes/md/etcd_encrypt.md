**Wprowadzenie**

W środowisku Kubernetes kluczowe jest nie tylko zabezpieczenie komunikacji sieciowej (np. TLS między komponentami), ale również ochrona danych przechowywanych w głównej bazie etcd. **Etcd** stanowi „serce” klastra – to tam zapisywane są wszystkie obiekty Kubernetes (Deploymenty, ConfigMapy, Secrets, Role, itp.). Bez odpowiednich zabezpieczeń, dostęp do plików etcd lub jego kopii zapasowych może prowadzić do wycieku poufnych informacji. W tym artykule omówimy mechanizm **Encryption at Rest** (szyfrowanie danych w spoczynku) dla etcd w Kubernetes. Przedstawimy, dlaczego jest to istotne, jak działa oraz jak skonfigurować i zweryfikować szyfrowanie etcd w klastrze.

---

## 1. Dlaczego szyfrowanie etcd jest istotne?

1. **Ochrona poufnych danych**
   Etcd przechowuje nie tylko metadane zasobów, ale także wartości wrażliwe (w szczególności zasoby typu Secret). Bez szyfrowania w spoczynku (at rest) wartości Secret w etcd będą zakodowane jedynie w Base64 – co stanowi poziom jedynie kosmetycznego zaciemnienia, a nie prawdziwe zabezpieczenie. W razie dostępu do plików etcd (np. w wyniku nieautoryzowanego dostępu do węzła master lub kopii zapasowej) można dość łatwo odszyfrować Base64.

2. **Zgodność z regulacjami i dobrymi praktykami**
   W wielu organizacjach i branżach (np. finanse, opieka zdrowotna) obowiązują wymogi, by dane wrażliwe były szyfrowane w spoczynku. Włączenie Encryption at Rest dla etcd pomaga spełnić te wymogi i unikać audytowych niezgodności.

3. **Pełna obrona wielowarstwowa**
   Nawet jeżeli kontrola dostępu (RBAC) czy mechanizmy sieciowe zostały poprawnie skonfigurowane, szyfrowanie danych w etcd stanowi kolejny poziom zabezpieczeń – w razie wycieku kopii zapasowej bazy etcd, poufne dane w formie zaszyfrowanej są trudniejsze do ujawnienia.

---

## 2. Sposób działania Encryption at Rest w Kubernetes

### 2.1. Przechowywanie danych w etcd

* Kubernetes API Server (apiserver) komunikuje się z etcd, zapisując i odczytując obiekty klastra.
* Domyślnie apiserver zapisuje obiekty w etcd w formacie JSON (dla zasobów takich jak Deployment) lub YAML (przy eksporcie), a wartości typu Secret są w polu `data` zakodowane w Base64, ale nie zaszyfrowane.
* Pliki etcd są zwykle przechowywane na dysku kontrolera węzła master (lub w dedykowanym etapie, jeśli korzystamy z zewnętrznego oddzielnego analizatora etcd).

### 2.2. Co robi Encryption at Rest?

* **Encryption at Rest** oznacza, że przed zapisaniem wartości wrażliwych do etcd API Server szyfruje je przy użyciu wybranej metody szyfrowania symetrycznego (AES, pierwszy wpis w kluczu itp.).
* Etcd zapisuje już zaszyfrowaną (ciphertext) wartość – nawet jeśli ktoś uzyska dostęp do pliku bazy etcd, nie odczyta wrażliwych danych bez znajomości klucza szyfrującego.
* Gdy inny komponent (np. kubelet, kubectl) odpyta API o dany obiekt, apiserver odszyfruje go w locie, zwracając klientowi oryginalną wartość.

### 2.3. Poziomy szyfrowania

W Kubernetes można skonfigurować szyfrowanie tych zasobów, które chcemy chronić. Typowe konfiguracje:

* **Całościowe szyfrowanie „secrets”** – szyfrujemy wyłącznie zasoby typu Secret.
* **Rozszerzone szyfrowanie** – można również wybrać szyfrowanie ConfigMap, Endpoints czy innych wrażliwych obiektów.
* **Tryb „identity”** – oznacza brak szyfrowania (tylko Base64), stosowany np. jako ostatni element w liście providerów, by zachować wsteczną zgodność.

---

## 3. Konfiguracja EncryptionConfiguration

Kluczowym plikiem, który definiuje sposób szyfrowania, jest **EncryptionConfiguration**. To plik JSON lub YAML, który wskazujemy API Serverowi przy uruchamianiu (argument linii poleceń `--encryption-provider-config=/ścieżka/do/pliku.yaml`).
Ustaw w `sudo nano /etc/kubernetes/manifests/kube-apiserver.yaml`

### 3.1. Struktura pliku EncryptionConfiguration

Poniżej znajduje się przykładowy plik `encryption-config.yaml`, który szyfruje wszystkie zasoby Secret algorytmem AES-CBC z kluczem 32-bajtowym:

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
              # Klucz musi być zakodowany w Base64 i mieć 32 bajty (256 bitów) długości.
              secret: "wK5j3Fo3YvQyLSfKT9pI9E4tUEphtfNoZvX8jJdF50="
      - identity: {}
```

**Opis kluczowych pól:**

* `resources` – lista zasobów (w tej kolejności), których dotyczy szyfrowanie.
* `- secrets` – oznacza, że szyfrujemy wszystkie obiekty typu Secret.
* `providers` – lista providerów szyfrowania w kolejności, w jakiej mają być stosowani.

    * `aescbc` – pierwszy provider, który oznacza szyfrowanie AES-CBC.

        * `keys` – tablica kluczy szyfrujących, z których pierwszy będzie domyślnie używany do szyfrowania nowych wartości.

            * `name: key1` – etykieta (nazwa) klucza.
            * `secret: "<Base64-encoded-32-bytes>"` – klucz szyfrujący.
    * `identity` – ostatni provider, który zwraca wartość w postaci niezmienionej, przydatny do wczytywania obiektów zapisanych wcześniej bez szyfrowania.

### 3.2. Generowanie klucza szyfrującego

Aby wygenerować klucz 32-bajtowy i zakodować go w Base64 (np. w Linuxie):

```bash
head -c 32 /dev/urandom | base64
# Przykładowy wynik: wK5j3Fo3YvQyLSfKT9pI9E4tUEphtfNoZvX8jJdF50=
```

Skopiowaną wartość wstawiamy w pole `secret:`.

### 3.3. Montowanie konfiguracji w API Serverze

Na każdym węźle kontrolera (master) plik `encryption-config.yaml` należy umieścić w bezpiecznej lokalizacji (np. `/etc/kubernetes/encryption-config.yaml`) i dodać parametr przy uruchomieniu API Servera:

```shell
# Parametry systemd (przykład dla kube-apiserver.service)
KUBE_API_SERVER_OPTS="--encryption-provider-config=/etc/kubernetes/encryption-config.yaml \
  --other-params..."
```

Po restarcie API Servera nowe odczyty i zapisy Secret będą przebiegały zgodnie z definicją w pliku konfiguracyjnym.

---

## 4. Weryfikacja działania szyfrowania

Aby upewnić się, że szyfrowanie działa prawidłowo, można przeprowadzić kilka kroków weryfikacyjnych.

### 4.1. Utworzenie testowego Secret

Najpierw utwórzmy prosty Secret w klastrze (w namespace np. `prod`):

```bash
kubectl create secret generic test-secret \
  --from-literal=username=test \
  --from-literal=password=Test123! \
  --namespace=prod
```

### 4.2. Eksport danych z etcd

Trzeba wyeksportować bazę etcd (lub przynajmniej interesujące nas klucze). Najprostszym sposobem jest użycie komendy:

```bash
kubectl get secrets test-secret -n prod -o yaml > /tmp/secret-before-decode.yaml
```

**Uwagi**:

* Jeżeli API Server jest poprawnie skonfigurowany, w zaszyfrowanej postaci (ciphertext) zobaczymy klucz `data`, ale rzeczywiste wartości będą różnić się od zwykłego Base64, gdyż zostaną wcześniej zaszyfrowane.
* Aby zobaczyć surowe dane w etcd, można użyć narzędzia `etcdctl`. Przykład (jeżeli mamy dostęp do etcdctl na maszynie master):

```bash
# Zaloguj się na węzeł master, zakładając, że etcdctl jest skonfigurowany (kolizja TLS i endpointów):
ETCDCTL_API=3 etcdctl get \
  /registry/secrets/prod/test-secret \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/peer.crt \
  --key=/etc/kubernetes/pki/etcd/peer.key
```

W odpowiedzi powinien pojawić się zaszyfrowany ciąg bajtów (Base64 ciphertext). Jeśli odczytujemy to, co jest w polu `data` (np. `username` i `password`), wartości nie będą bezpośrednimi ciągami Base64 „admin” czy „Test123!”. Będą dodatkowo zaszyfrowane przy użyciu AES-CBC.

### 4.3. Próba odszyfrowania ręcznie

Ponieważ w etcd przechowywana jest już zaszyfrowana wartość, ręczne odszyfrowywanie wymagałoby znajomości klucza AES-CBC i sposobu kodowania. W praktyce weryfikację wykonuje się zamiast ręcznego odszyfrowania, poprzez próby odczytu Secret przez API Server:

```bash
kubectl get secret test-secret -n prod -o jsonpath="{.data.username}" | base64 --decode
# Powinno zwrócić: test
```

Jeśli powyższa komenda zwraca oryginalną wartość (np. `test`), oznacza, że apiserver poprawnie odszyfrowuje Secret w locie. Natomiast surowe wartości w etcd są zaszyfrowane.

---

## 5. Rotacja kluczy szyfrowania

W miarę upływu czasu należy przeprowadzać rotację kluczy szyfrujących, aby minimalizować ryzyko przejęcia długoterminowego. Poniższe kroki przedstawiają przykładowy proces rotacji:

### 5.1. Dodanie drugiego klucza do pliku EncryptionConfiguration

Aktualny plik `encryption-config.yaml` (przed rotacją) mógł wyglądać tak:

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
              secret: "wK5j3Fo3YvQyLSfKT9pI9E4tUEphtfNoZvX8jJdF50="
      - identity: {}
```

Aby dodać nowy klucz (key2), modyfikujemy plik:

```yaml
apiVersion: apiserver.config.k8s.io/v1
kind: EncryptionConfiguration
resources:
  - resources:
      - secrets
    providers:
      - aescbc:
          keys:
            - name: key2
              secret: "D9aK3jL2hYtVXzqPCiU7BrF0RmEwqdNzpT5SaZ3sYxQ="  # nowy klucz
            - name: key1
              secret: "wK5j3Fo3YvQyLSfKT9pI9E4tUEphtfNoZvX8jJdF50="
      - identity: {}
```

**Kolejność kluczy ma znaczenie**:

* Pierwszy element w tablicy (`key2`) będzie kluczem domyślnym do szyfrowania nowo tworzonych lub aktualizowanych wartości.
* `key1` pozostaje wciąż jako poprzedni klucz, pozwalający apiserverowi odczytywać (odszyfrowywać) wartości zaszyfrowane dotychczas.

### 5.2. Zastosowanie nowej konfiguracji

* Wgraj zmodyfikowany plik na wszystkie węzły kontrolera:

  ```bash
  scp encryption-config.yaml master-node-1:/etc/kubernetes/encryption-config.yaml
  scp encryption-config.yaml master-node-2:/etc/kubernetes/encryption-config.yaml
  scp encryption-config.yaml master-node-3:/etc/kubernetes/encryption-config.yaml
  ```
* Zrestartuj API Server (lub cały kube-apiserver) na każdym węźle:

  ```bash
  systemctl restart kube-apiserver
  ```
* Po restarcie nowe Secret będą szyfrowane przy użyciu `key2`, ale odczyt ich nadal będzie możliwy, ponieważ znajdują się również `key1`.

### 5.3. Rekompresja istniejących Secret (re-encrypt)

Po dodaniu nowego klucza, dotychczasowe obiekty w etcd nadal pozostaną zaszyfrowane starym kluczem `key1`. Aby zaktualizować wszystkie istniejące Secret tak, by zostały ponownie zaszyfrowane przy użyciu nowego klucza (`key2`), należy przeprowadzić proces **rekryptryzacji** (re-encrypt). Kubernetes nie wykonuje tego automatycznie – trzeba ręcznie wymusić zmianę:

1. **Przy użyciu narzędzia `kubectl` i skryptu**
   Poniższy fragment w Bashu demonstruje iterację przez wszystkie Secret w namespace i wymuszenie odświeżenia:

   ```bash
   #!/bin/bash
   NS=prod
   for secret in $(kubectl get secrets -n $NS -o name); do
     # Pobierz pełny obiekt Secret jako JSON
     kubectl get $secret -n $NS -o json | \
       # Usuń adnotację (metadata.resourceVersion), by wymusić utworzenie nowej wersji
       jq 'del(.metadata.resourceVersion)' | \
       # Zastosuj obiekt ponownie – zapis spowoduje zaszyfrowanie nowym kluczem
       kubectl apply -f -
   done
   ```

   **Wyjaśnienia techniczne**:

    * Usuwamy pole `.metadata.resourceVersion` (oraz ewentualne `.metadata.uid` i `.metadata.managedFields`), by Kubernetes uznał, że to „nowa” wersja obiektu.
    * W efekcie API Server zapisze ten Secret od nowa, szyfrując go `key2`.

2. **Sprawdzenie, czy rekord jest zaszyfrowany nowym kluczem**
   Podobnie jak wcześniej, można użyć `etcdctl get` i przeanalizować ciphertext. Klucz pierwszego bajtu ciphertext często wskazuje, który klucz szyfrujący był użyty (w zależności od implementacji). Dokumentacja Kubernetes podaje, że ciphertext dla AES-CBC rozpoczyna się od nagłówka zawierającego identyfikator klucza (np. `k8s:enc:aescbc:v1:key2:<IV><ciphertext>`). W praktyce, przy oglądaniu surowych bajtów, można odróżnić, że nie jest to już ciphertext wygenerowany przez `key1`.
