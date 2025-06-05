## 1. NodeSelector

### Opis i działanie

* **Najprostszy** mechanizm – wybiera węzły posiadające dokładnie zadeklarowane etykiety.
* Scheduler **ignoruje** węzły, które nie mają wszystkich wymaganych par `klucz=wartość`.

### Składnia

```yaml
spec:
  nodeSelector:
    <key1>: <value1>
    <key2>: <value2>
```

### Przykłady

1. **Dyski NVMe vs HDD**

   ```bash
   kubectl label node nodeA storage=nvme
   kubectl label node nodeB storage=hdd
   ```

   ```yaml
   kind: Pod
   metadata:
     name: pod-nvme-only
   spec:
     containers:
     - name: app
       image: alpine
     nodeSelector:
       storage: nvme
   ```
2. **Środowisko (env)**

   ```yaml
   nodeSelector:
     env: production
   ```

---

## 2. Node Affinity

### Opis i zalety

* Daje **więcej elastyczności** niż NodeSelector – obsługuje operatory `In/NotIn/Exists/DoesNotExist/Gt/Lt`.
* Możliwość definiowania:

    * **requiredDuringSchedulingIgnoredDuringExecution** – twarde warunki (hard)
    * **preferredDuringSchedulingIgnoredDuringExecution** – miękkie preferencje (soft)

### Składnia

```yaml
spec:
  affinity:
    nodeAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        nodeSelectorTerms:
        - matchExpressions:
          - key: "<klucz>"
            operator: In|NotIn|Exists|DoesNotExist|Gt|Lt
            values: [ "<wartość1>", ... ]
      preferredDuringSchedulingIgnoredDuringExecution:
      - weight: <1–100>
        preference:
          matchExpressions:
          - key: "<klucz>"
            operator: In
            values: [ "<wartość>" ]
```

### Przykłady

1. **Twarda afinity – GPU**

   ```yaml
   kind: Pod
   metadata:
     name: gpu-pod
   spec:
     containers:
     - name: compute
       image: tensorflow:latest
     affinity:
       nodeAffinity:
         requiredDuringSchedulingIgnoredDuringExecution:
           nodeSelectorTerms:
           - matchExpressions:
             - key: gpu.present
               operator: Exists
   ```
2. **Miękka afinity – region**

   ```yaml
   kind: Pod
   metadata:
     name: eu-pref-pod
   spec:
     containers:
     - name: web
       image: nginx
     affinity:
       nodeAffinity:
         preferredDuringSchedulingIgnoredDuringExecution:
         - weight: 50
           preference:
             matchExpressions:
             - key: region
               operator: In
               values: ["eu-central","eu-west"]
   ```

---

## 3. Taints & Tolerations

### Koncepcja

* **Taint** na węźle odrzuca pady bez odpowiedniej **toleration**.
* **Toleration** w manifeście poda pozwala mu “zignorować” dany taint i zostać zaplanowanym.

### Efekty taintów

| Efekt                | Zachowanie                                          |
| -------------------- | --------------------------------------------------- |
| **NoSchedule**       | Nowe pady bez toleracji **nie** są planowane.       |
| **PreferNoSchedule** | Scheduler **stara się** unikać, ale nie gwarantuje. |
| **NoExecute**        | Usuwa istniejące pady bez toleracji i blokuje nowe. |

### Dodawanie taintu

```bash
kubectl taint nodes <node> <key>=<value>:<efekt>
# np.
kubectl taint nodes nodeC maintenance=true:NoSchedule
```

### Składnia toleracji

```yaml
spec:
  tolerations:
  - key: "<klucz>"
    operator: Equal|Exists
    value: "<wartość>"      # przy Equal
    effect: NoSchedule|PreferNoSchedule|NoExecute
    # opcjonalnie:
    # tolerationSeconds: <sekundy>  # tylko dla NoExecute
```

### Przykład end-to-end

1. ```bash
   kubectl taint nodes nodeC maintenance=true:NoSchedule
   ```
2. Pod bez toleration → **Pending**
3. Pod z toleration:

   ```yaml
   kind: Pod
   metadata:
     name: maintenance-pod
   spec:
     containers:
     - name: test
       image: busybox
       command: ["sleep","3600"]
     tolerations:
     - key: "maintenance"
       operator: "Equal"
       value: "true"
       effect: "NoSchedule"
   ```

   – zostanie zaplanowany na `nodeC`.

---

## 4. Przykład mieszany

Scenariusz: mamy klaster z węzłami CPU i GPU, w regionie `eu-west`, część węzłów oznaczona jest do konserwacji. Chcemy uruchomić batch job, który:

* **twardo** wymaga GPU,
* **preferuje** region `eu-west`,
* **ignoruje** taint konserwacyjny,
* dodatkowo **środowiskowo** ma tylko produkcyjną etykietę.

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: gpu-batch-job
spec:
  template:
    metadata:
      name: gpu-batch-pod
    spec:
      containers:
      - name: worker
        image: myorg/batch-worker:latest
      restartPolicy: Never

      # 1) proste file-level: tylko produkcyjne węzły
      nodeSelector:
        env: production

      # 2) określamy wymóg GPU i preferencję regionu
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
            - matchExpressions:
              - key: gpu.present
                operator: Exists
          preferredDuringSchedulingIgnoredDuringExecution:
          - weight: 80
            preference:
              matchExpressions:
              - key: region
                operator: In
                values:
                - eu-west

      # 3) tolerujemy taint konserwacyjny
      tolerations:
      - key: "maintenance"
        operator: "Equal"
        value: "true"
        effect: "NoSchedule"
```

* **nodeSelector** ensures only `env=production` nodes are considered.
* **requiredDuringScheduling…** forces placement on GPU-equipped nodes.
* **preferredDuringScheduling…** gives priority to węzły w `eu-west`.
* **tolerations** pozwalają na scheduling na węzłach z taintem `maintenance=true:NoSchedule`.
