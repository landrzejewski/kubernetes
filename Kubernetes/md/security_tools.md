## 1. Skanowanie obrazów kontenerów przy użyciu Trivy

Trivy ([https://github.com/aquasecurity/trivy](https://github.com/aquasecurity/trivy)) to popularne narzędzie typu open source, stworzone przez Aqua Security, które umożliwia:

* Wykrywanie **CVE** (Common Vulnerabilities and Exposures) w warstwach obrazu (system operacyjny, biblioteki języka, komponenty aplikacyjne).
* Generowanie **SBOM** (Software Bill of Materials) w standardowych formatach takich jak CycloneDX czy SPDX.

### 1.1. Wykrywanie CVE

1. **Instalacja Trivy**
   Trivy można zainstalować na wiele sposobów:

   ```bash
   # Przykład instalacji przez skrypt:
   curl -sfL https://raw.githubusercontent.com/aquasecurity/trivy/main/contrib/install.sh | sh -
   ```

   lub przez pakiet menedżera systemu:

   ```bash
   sudo apt-get install -y trivy       # Debian/Ubuntu
   sudo yum install -y trivy           # CentOS/RHEL
   ```

2. **Podstawowe skanowanie obrazu**
   Aby przeskanować obraz kontenera pod kątem podatności, wystarczy:

   ```bash
   trivy image moja-aplikacja:latest
   ```

   W wyniku narzędzie:

    * Pobrać bazę podatności (domyślnie z ✔ GitHub Advisory Database, ✔ NVD, ✔ Red Hat CVE, itp.).
    * Przeanalizować warstwy obrazu: system operacyjny (np. Alpine, Debian, Ubuntu), język (np. Python, Node.js) oraz zależności (np. Gemfile.lock, package-lock.json).
    * Wypisać listę znalezionych podatności z informacją o:

        * **ID CVE** (np. CVE-2022-12345),
        * **Krytyczności** (LOW, MEDIUM, HIGH, CRITICAL),
        * **Pakiecie/komponencie**,
        * **Wersji, w której podatność została poprawiona**,
        * **Źródłach**.

3. **Zaawansowane opcje**

    * **Ignorowanie niektórych CVE**:
      Można wskazać plik `.trivyignore`, zawierający CVE, które są w danej organizacji uznane za “riski zaakceptowane” i nie będą blokować procesu CI/CD.
    * **Wymuszanie minimalnego poziomu krytyczności**:

      ```bash
      trivy image --severity HIGH,CRITICAL moja-aplikacja:latest
      ```
    * **Eksport wyników**:
      Trivy pozwala wyeksportować raport w formacie JSON, SARIF czy CSV:

      ```bash
      trivy image --format json --output raport.json moja-aplikacja:latest
      ```

### 1.2. Generowanie SBOM

SBOM (Software Bill of Materials) to metadane opisujące komponenty składowe danej aplikacji czy obrazu kontenera. W praktyce ułatwia to śledzenie licencji, odpowiedzialności oraz szybką identyfikację, które konkretnie pakiety i wersje są używane.

1. **SBOM w formacie CycloneDX**
   Aby utworzyć SBOM dla obrazu w formacie CycloneDX, używamy parametru `--format cyclonedx`:

   ```bash
   trivy image --format cyclonedx --output sbom-cyclonedx.xml moja-aplikacja:latest
   ```

   Po chwili w katalogu projektu powstanie plik `sbom-cyclonedx.xml`, zawierający hierarchię komponentów, wersje, licencje oraz (opcjonalnie) powiązane CVE.

2. **SBOM w formacie SPDX**
   Analogicznie można wygenerować plik SPDY:

   ```bash
   trivy image --format spdx-json --output sbom-spdx.json moja-aplikacja:latest
   ```

3. **Integracja z pipeline CI/CD**

    * Raport SBOM może zostać wysłany do narzędzia zewnętrznego (np. Snyk, GitLab Dependency Scanning, GitHub Advanced Security), które w oparciu o te dane pomaga w zarządzaniu podatnościami i licencjami.
    * W przypadku wykrycia nieakceptowalnych licencji bądź krytycznych CVE, proces CI może zostać przerwany.

### 1.3. Przykładowa konfiguracja w GitLab CI

```yaml
stages:
  - scan

trivy_scan:
  stage: scan
  image: aquasec/trivy:latest
  script:
    - trivy image --format json --output trivy-report.json moja-aplikacja:latest
    - trivy image --format cyclonedx --output sbom-cyclonedx.xml moja-aplikacja:latest
  artifacts:
    paths:
      - trivy-report.json
      - sbom-cyclonedx.xml
    expire_in: 1 week
```

Taka konfiguracja zapewnia, że przed wypchnięciem obrazu do rejestru wykonujemy pełne skanowanie CVE i generujemy SBOM, zapisując oba artefakty jako pliki do wglądu.

---

## 2. Sprawdzanie zgodności konfiguracji klastra Kubernetes z CIS Kubernetes Benchmark

### 2.1. Czym jest CIS Kubernetes Benchmark?

CIS (Center for Internet Security) publikowało wytyczne bezpieczeństwa (Benchmark) dotyczące najlepszych praktyk konfiguracji klastrów Kubernetes. Benchmark obejmuje trzy główne profile:

1. **Master Node Configuration** – bezpieczeństwo API server, kontrolerów, etcd, scheduler-a.
2. **Worker Node Configuration** – kubelet, kube-proxy, kontenery itp.
3. **Policy as Code / Uwierzytelnianie i Autoryzacja** – role RBAC, sieć, limit zasobów.

Każdy z tych rozdziałów zawiera zdefiniowane kontrole (np. “1.1.1 Ensure that the API server pod specification file permissions are set to 644 or more restrictive”).

### 2.2. Narzędzie „kube-bench”

Jednym z najbardziej popularnych sposobów automatyzacji audytu zgodnie z CIS Benchmark jest użycie **kube-bench** ([https://github.com/aquasecurity/kube-bench](https://github.com/aquasecurity/kube-bench)). Działa ono w następujący sposób:

1. **Pobranie i uruchomienie**

   ```bash
   wget https://github.com/aquasecurity/kube-bench/releases/download/v0.6.7/kube-bench_0.6.7_linux_amd64.deb
   sudo dpkg -i kube-bench_0.6.7_linux_amd64.deb
   ```

   lub poprzez kontener:

   ```bash
   docker run --rm -v /var/run/docker.sock:/var/run/docker.sock -v /etc:/etc \
     -v /usr/lib/systemd:/usr/lib/systemd -v /var/lib:/var/lib \
     aquasec/kube-bench:latest
   ```

2. **Wybór poziomu auditu**
   Domyślnie `kube-bench` próbuje wykryć, czy jest uruchomiony na węźle master czy worker, a następnie przystępuje do sprawdzania 200+ reguł. Można też wymusić profil:

   ```bash
   kube-bench master
   kube-bench node
   ```

3. **Raporty**
   Wynikiem działania jest raport w standardowym formacie wyjściowym (np. JSON lub czytelny dla konsoli). Każda kontrola jest oznaczona jako:

    * **PASS** – zgodne z wytycznymi
    * **WARN** – zgodne, ale odradzane
    * **FAIL** – niezgodne
    * **INFO** – ogólna informacja

   Przykładowy fragment outputu:

   ```
   [1.1] Master Node Security Configuration
   [1.1.1]  Ensure that the API server pod specification file permissions are set to 644 or more restrictive (Manual)
         * File: /etc/kubernetes/manifests/kube-apiserver.yaml
         * Permissions: 600
         * FAIL: Permissions are 600
   ```

4. **Integracja w pipeline**
   Podobnie jak w przypadku Trivy, `kube-bench` można zintegrować w proces CI/CD (np. GitLab CI, Jenkins), aby przy każdym wdrożeniu od razu sprawdzić, czy zmiany w konfiguracji klastra nie łamią zasad CIS.

   ```yaml
   stages:
     - audit

   kube_bench_audit:
     stage: audit
     image: aquasec/kube-bench:latest
     script:
       - kube-bench master --json > kube-bench-report.json
     artifacts:
       paths:
         - kube-bench-report.json
       expire_in: 1 week
   ```

### 2.3. Alternatywy: kubeaudit, Kubescape, Trivy (Infrastructure as Code)

* **kubeaudit** ([https://github.com/Shopify/kubeaudit](https://github.com/Shopify/kubeaudit)) – narzędzie napisane w Go, skupione na szybkim sprawdzaniu polityk RBAC, sieci (NetworkPolicy), dostępów do itp.
* **Kubescape** ([https://github.com/armosec/kubescape](https://github.com/armosec/kubescape)) – narzędzie od ARMO, które również implementuje kontrole CIS, a dodatkowo dostarcza własne reguły i integrację z platformami chmurowymi.
* **Trivy Infrastructure as Code** – Trivy potrafi także sprawdzać pliki Helm, YAML (Kubernetes manifests) pod kątem niezgodności z najlepszymi praktykami (np. brak `readOnlyRootFilesystem`, nieużywanie `latest` w tagach, brak limitów zasobów, itp.).

  Przykład uruchomienia:

  ```bash
  trivy config ./k8s-manifests/
  ```

  Wynikiem będzie lista znajdowanych problemów (np. `FAIL Ungrouped.Must specify resources.limits.cpu`).

---

## 3. Ograniczenie uprawnień i kontrola dostępu przy użyciu SecurityContext

Zaawansowane zasady bezpieczeństwa w Kubernetes zakładają, że aplikacje (kontenery) powinny działać z najmniejszym zbiorem uprawnień, niezbędnym do funkcjonowania. Odpowiedzialne za to są obiekty:

* **Pod SecurityContext** – dotyczy wszystkich kontenerów w Podzie,
* **Container SecurityContext** – specyficzne ustawienia dla pojedynczego kontenera.

### 3.1. Przykładowe pola SecurityContext

1. **runAsUser / runAsGroup**
   Pozwala wskazać, z jaką tożsamością użytkownika (UID) lub grupy (GID) będzie uruchomiony kontener.

   ```yaml
   securityContext:
     runAsUser: 1001
     runAsGroup: 1001
   ```

2. **readOnlyRootFilesystem**
   Ustawienie `true` powoduje, że system plików root wewnątrz kontenera jest tylko do odczytu (np. w przypadku aplikacji webowych, które nie muszą zapisywać na dysk).

   ```yaml
   securityContext:
     readOnlyRootFilesystem: true
   ```

3. **allowPrivilegeEscalation**
   Jeżeli ustawimy tę wartość na `false`, zapobiegamy eskalacji przywilejów w ramach procesu (np. próbie podniesienia uprawnień).

   ```yaml
   securityContext:
     allowPrivilegeEscalation: false
   ```

4. **privileged**
   Flaga `true` pozwala uruchomić kontener z pełnymi uprawnieniami root (dostęp do urządzeń, hosta). Zdecydowanie odradzana w środowiskach produkcyjnych, jeżeli nie jest absolutnie konieczna.

   ```yaml
   securityContext:
     privileged: false
   ```

5. **capabilities**
   Pozwala dodać lub usunąć konkretne capabilities (np. `NET_ADMIN`, `SYS_PTRACE`). Najbezpieczniej jawnie usuwać wszelkie niepotrzebne zdolności:

   ```yaml
   securityContext:
     capabilities:
       drop:
         - ALL
   ```

6. **seccompProfile**
   Umożliwia wskazanie profilu Seccomp, który odfiltrowuje zbiór systemowych wywołań (syscalls). Najczęściej używa się domyślnego profilu `runtime/default` albo profilu `disa`/`docker/default`.

   ```yaml
   securityContext:
     seccompProfile:
       type: RuntimeDefault
   ```

### 3.2. Przykładowy manifest z SecurityContext

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: secure-app
spec:
  securityContext:
    runAsUser: 1001
    runAsGroup: 1001
    fsGroup: 1001
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: app-container
      image: moja-aplikacja:latest
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop:
            - ALL
```

> **Uwaga:**
>
> * W dużych zespołach często definiuje się globalne polityki (PodSecurityPolicies lub w nowoczesnych wersjach Kubernetes – Gatekeeper / OPA, Kyverno) na poziomie klastra, wymuszające, aby każdy Pod spełniał określone wymagania bezpieczeństwa (np. brak `privileged`, minimalne wersje syscalli, nieużywanie `latest`, itp.).

### 3.3. Integracja z narzędziami analizy manifestów

* **Trivy IaC** (omówione wyżej) – automatycznie wykrywa, gdy w YAML-u nie zdefiniowano wymaganych opcji SecurityContext.
* **KubeLinter** ([https://github.com/stackrox/kube-linter](https://github.com/stackrox/kube-linter)) – skanuje manifesty i wykrywa antywzorce (np. brak `drop: ALL`, brak limitów zasobów, użycie `privileged`).
* **Kubebench** nie tylko sprawdza konfigurację węzłów, ale i weryfikuje, czy nie ma niebezpiecznych ustawień w etcd, kubelet itp.

---

## 4. Narzędzia dodatkowe: Falco, Tracee, audyty

### 4.1. Falco – Runtime Security

**Falco** ([https://github.com/falcosecurity/falco](https://github.com/falcosecurity/falco)) to narzędzie typu eBPF / kernel module, które w czasie rzeczywistym monitoruje wywołania syscalów w kontenerach i na hoście, aby wykrywać podejrzane zachowania (nieautoryzowane modyfikacje plików, próby ładowania modułów jądra, wykonania powłoki w podwyższonych przywilejach itp.).

1. **Instalacja i konfiguracja**

    * Falco instaluje się jako DaemonSet w klastrze Kubernetes:

      ```bash
      kubectl apply -f https://raw.githubusercontent.com/falcosecurity/charts/main/falco/crds/crd.yaml
      helm repo add falcosecurity https://falcosecurity.github.io/charts
      helm install falco falcosecurity/falco
      ```
    * Falco wykorzystuje wbudowane reguły, które można dostosować (np. wyciszyć niektóre alerty, dodać własne).
    * Po instalacji Falco automatycznie monitoruje wszystkie namespace’y i wyświetla wydarzenia w logach (stdout lub zintegrowane z Elasticsearch, Splunk, Slack itp.).

2. **Przykładowe reguły**

    * Wykrywanie uruchomienia powłoki w kontenerze z najmniej uprzywilejowanym użytkownikiem:

      ```yaml
      - rule: Terminal shell in container
        desc: Detect a shell being spawned in a container (TTY or STDIN)
        condition: spawned_process and proc.pname in (bash, sh, csh, tcsh, zsh, ksh) and container.id != host
        output: "Shell spawned by user=%user.name %container.info (command=%proc.cmdline)"
        priority: WARNING
        tags: [container, shell]
      ```
    * Próba zapisu do katalogu (`/etc`) w kontenerze, którego system plików jest tylko do odczytu:

      ```yaml
      - rule: Write to readOnly filesystem
        condition: write_access and evt.dir = < and fd.root = / and fd.name startswith /etc and not fd.readonly
        output: "Attempt to write to /etc in container (readonly) user=%user.name container=%container.id"
        priority: CRITICAL
        tags: [filesystem, container]
      ```

3. **Integracja z SIEM i SOAR**
   Alerty z Falco można kierować do:

    * Systemów typu **Elasticsearch + Kibana** (ELK Stack),
    * **Splunk**,
    * **Syslog**,
    * bezpośrednio do **Slack** czy **Microsoft Teams**,
    * specjalistycznych platform typu **Sumo Logic**, **Datadog**.

Dzięki temu w czasie rzeczywistym otrzymujemy powiadomienia o potencjalnych incydentach bezpieczeństwa.

### 4.2. Tracee (Trace Call Auditing)

**Tracee** (komponent od Aqua Security, [https://github.com/aquasecurity/tracee](https://github.com/aquasecurity/tracee)) to narzędzie, które zbiera szczegółowe informacje o wywołaniach syscalli (Trace syscall) w kontenerach i na hoście, pozwalając na:

* **Audyty systemowe** – śledzenie np. otwierania plików, tworzenia nowych procesów, otwierania gniazd sieciowych.
* **Wykrywanie rootkitu** – analiza nietypowych wywołań systemowych, wskazujących na złośliwe działania na poziomie jądra.
* **Deep forensic** – możliwość zapisywania pełnych sekwencji wywołań, które później można odtworzyć i przeanalizować (np. w przypadku incydentu).

1. **Instalacja**
   Tracee uruchamiamy jako DaemonSet w Kubernetes:

   ```bash
   kubectl apply -f https://raw.githubusercontent.com/aquasecurity/tracee/main/installation/k8s/tracee-ebpf.yaml
   ```

   Domyślnie zbiera on wszystkie syscalli dla wszystkich kontenerów. Jeżeli chcemy ograniczyć zakres, stosujemy filtry w konfiguracji.

2. **Przykładowa polisa śledzenia**
   W pliku `tracee-rules.toml` definiujemy np.:

   ```toml
   [[rules]]
   name = "Detect write in /etc/shadow"
   condition = "evt.type = open and evt.dir = < and fd.name contains \"/etc/shadow\""
   output = "Process (pid=%proc.pid, tid=%thread.tid) próbował otworzyć /etc/shadow"
   priority = "HIGH"
   ```

3. **Audyty Tracee vs. Falco**

    * Falco opiera się na gotowych regułach i skupia się na prostszych, wysokopoziomowych anomaliach.
    * Tracee jest bardziej “surowy” i daje pełne śledzenie wywołań jądra. Sprawdza się, gdy potrzebujemy audytu pod niskim poziomem (forensics, hunting rootkitów), ale wymaga większej wiedzy analitycznej.

### 4.3. Audyty Kubernetes (Audit Logs)

Kubernetes sam w sobie dostarcza mechanizm logowania audytu (Audit Logging), dzięki któremu każda próba wywołania API (np. `kubectl exec`, `api-server` request) jest zapisywana w dedykowanym pliku (lub wysyłana do sysloga / ElasticSearch).

1. **Konfiguracja audit policy**
   W pliku `audit-policy.yaml` definiujemy, jakie zdarzenia i z jakim poziomem szczegółowości mają być logowane:

   ```yaml
   apiVersion: audit.k8s.io/v1
   kind: Policy
   rules:
     - level: Metadata
       verbs: ["create", "update", "patch", "delete"]
       resources:
         - group: ""
           resources: ["pods", "deployments"]
       namespaces: ["production"]
     - level: RequestResponse
       users: ["system:admin"]
   ```

2. **Włączenie audytu w kube-apiserver**
   W manifeście (lub w konfiguracji kube-apiserver) podajemy:

   ```
   --audit-log-path=/var/log/kubernetes/audit.log
   --audit-policy-file=/etc/kubernetes/audit-policy.yaml
   ```

3. **Analiza logów**
   Po wygenerowaniu plików ze zdarzeniami, używamy narzędzi takich jak **Elasticsearch + Kibana**, **Splunk**, czy **Fluentd** do agregacji i wizualizacji. Dzięki temu mamy pełny przegląd, kto i kiedy zmieniał zasoby w klastrze, jakie operacje zostały odrzucone, itp.

