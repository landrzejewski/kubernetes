# Rozwiązania: Docker (materiał dla prowadzącego)

## Ćwiczenie 1 - Uruchamianie kontenerów

```bash
# 1. Jednorazowy kontener, sam się usuwa
docker run --rm busybox date

# 2. Sesja interaktywna
docker run -it --rm debian:12 /bin/bash
#   wewnątrz:
#   cat /etc/os-release
#   ps aux
#   echo $$            # PID procesu powłoki (zwykle 1)
#   exit

# 3. Serwer Apache w tle + test
docker run -d --name apache-lab -p 9090:80 httpd:alpine
curl http://localhost:9090         # "It works!"

# 4. Listy kontenerów i logi
docker ps
docker ps -a
docker logs apache-lab

# Sprzątanie
docker rm -f apache-lab
```

Komentarz: `echo $$` w kontenerze zwraca zwykle `1`, bo proowłoka jest pierwszym procesem w izolowanej przestrzeni nazw PID.

## Ćwiczenie 2 - Praca z obrazami

```bash
# 1. Pobranie i porównanie rozmiarów
docker pull python:3.12-alpine
docker pull python:3.12-slim
docker pull redis:7-alpine
docker images
#   alpine jest wyraźnie mniejszy od slim

# 2. Warstwy obrazu
docker history --human redis:7-alpine

# 3. Wybrane pola z inspect
docker inspect --format='{{.Config.Cmd}}'          python:3.12-slim
docker inspect --format='{{json .Config.Env}}'     python:3.12-slim
docker inspect --format='{{.Architecture}}'        python:3.12-slim

# 4. Tagowanie (alias) i usunięcie jednego tagu
docker tag redis:7-alpine cache/redis:prod
docker tag redis:7-alpine cache/redis:rc
docker images | grep -E 'redis|cache'   # te same IMAGE ID
docker rmi cache/redis:rc                # usuwa tylko tag, obraz zostaje

# Sprzątanie
docker rmi cache/redis:prod
```

Komentarz: `docker rmi` na tagu, do którego prowadzi kilka tagów, usuwa wyłącznie etykietę (`Untagged`). Dopiero usunięcie ostatniego tagu kasuje warstwy (`Deleted`).

## Ćwiczenie 3 - Cykl życia i interakcja z kontenerem

```bash
# 1. Długo żyjący kontener
docker run -d --name serwis busybox sleep 7200

# 2. Przejścia między stanami
docker pause serwis   && docker ps        # status (Paused)
docker unpause serwis && docker ps
docker restart serwis
docker stop serwis    && docker ps -a     # Exited
docker start serwis   && docker ps        # Up

# 3. Polecenie bez wchodzenia do kontenera
docker exec serwis ls -la /

# 4. Sesja interaktywna i utworzenie pliku (busybox -> sh)
docker exec -it serwis sh
#   mkdir /dane
#   echo "zawartosc testowa" > /dane/plik.txt
#   exit
docker exec serwis cat /dane/plik.txt     # potwierdzenie spoza kontenera

# 5. Kopiowanie host <-> kontener
echo "raport z hosta" > raport.txt
docker cp raport.txt serwis:/dane/
docker cp serwis:/dane/raport.txt raport-kopia.txt
cat raport-kopia.txt

# 6. Odczyt pól przez szablon
docker inspect --format='{{.State.Status}}'    serwis
docker inspect --format='{{.State.StartedAt}}' serwis

# Sprzątanie
docker rm -f serwis
rm -f raport.txt raport-kopia.txt
```

## Ćwiczenie 4 - Limity zasobów

```bash
# 1. Limity pamięci i CPU + weryfikacja
docker run -d --memory="128m" --name redis-lim redis:7-alpine
docker run -d --cpus="0.25"   --name cpu-lim   redis:7-alpine
docker stats --no-stream redis-lim cpu-lim

# 2. Kontener przekraczający limit pamięci
docker run -d --name oom-test --memory="32m" python:3.12-alpine \
  python -c "import time; time.sleep(3); a=[0]*50_000_000; time.sleep(60)"

# 3. Sprawdzenie OOM i kodu wyjścia (po ~10 s)
sleep 10
docker inspect oom-test --format='{{.State.OOMKilled}}'   # true
docker inspect oom-test --format='{{.State.ExitCode}}'    # 137 (128+9, SIGKILL)

# 4. Limit twardy vs waga względna
docker run -d --cpus="0.25"     --name twardy   redis:7-alpine
docker run -d --cpu-shares=256  --name wzgledny redis:7-alpine

# Sprzątanie
docker rm -f redis-lim cpu-lim oom-test twardy wzgledny
```

Komentarz: `--cpus="0.25"` to **limit twardy** - kontener nigdy nie dostanie więcej niż 25% jednego rdzenia. `--cpu-shares=256` to **waga względna** (domyślnie 1024); działa tylko przy rywalizacji o CPU - przy wolnym procesorze kontener może wykorzystać znacznie więcej.

## Ćwiczenie 5 - Trwałość danych

```bash
# 1. Wolumen nazwany - dane przeżywają usunięcie kontenera
docker volume create mariadb-data
docker run -d --name mdb \
  -v mariadb-data:/var/lib/mysql \
  -e MARIADB_ROOT_PASSWORD=tajne mariadb:11
sleep 20                                   # czas na inicjalizację bazy
docker exec mdb mariadb -uroot -ptajne -e "CREATE DATABASE sklep;"
docker rm -f mdb
docker run -d --name mdb2 \
  -v mariadb-data:/var/lib/mysql \
  -e MARIADB_ROOT_PASSWORD=tajne mariadb:11
sleep 15
docker exec mdb2 mariadb -uroot -ptajne -e "SHOW DATABASES;" | grep sklep

# 2. Bind mount (tylko do odczytu) - zmiana na hoście widoczna od razu
mkdir -p strona && echo '<h1>Wersja 1</h1>' > strona/index.html
docker run -d --name web -p 8080:80 \
  -v $(pwd)/strona:/usr/share/caddy:ro caddy:alpine
curl -s localhost:8080
echo '<h1>Wersja 2</h1>' > strona/index.html
curl -s localhost:8080                     # już Wersja 2

# 3. tmpfs - dane tylko w pamięci, znikają po restarcie
docker run -d --name tmp-test --tmpfs /cache:size=16m alpine sleep 3600
docker exec tmp-test sh -c "echo dane > /cache/plik.txt"
docker exec tmp-test cat /cache/plik.txt
docker restart tmp-test
docker exec tmp-test ls /cache             # pusto

# 4. Kopia zapasowa wolumenu
docker run --rm \
  -v mariadb-data:/data \
  -v $(pwd):/backup \
  alpine tar czf /backup/mariadb-backup.tar.gz -C /data .
ls -lh mariadb-backup.tar.gz

# Sprzątanie
docker rm -f mdb2 web tmp-test
docker volume rm mariadb-data
rm -rf strona mariadb-backup.tar.gz
```

Komentarz: w obrazie `caddy:alpine` domyślny Caddyfile serwuje pliki z katalogu `/usr/share/caddy` na porcie 80.

## Ćwiczenie 6 - Sieci kontenerów

```bash
# 1. Domyślny mostek - komunikacja tylko po IP
docker run -d --name a1 alpine sleep 3600
docker run -d --name a2 alpine sleep 3600
A1_IP=$(docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' a1)
docker exec a2 ping -c 2 $A1_IP            # działa
docker exec a2 ping -c 2 a1 || echo "brak DNS na domyślnym mostku"

# 2. Sieć własna - automatyczny DNS po nazwie
docker network create lab-net --driver bridge --subnet 172.30.0.0/16
docker run -d --name api    --network lab-net alpine sleep 3600
docker run -d --name worker --network lab-net alpine sleep 3600
docker exec worker ping -c 2 api           # działa po nazwie

# 3. Izolacja trójwarstwowa
docker network create strefa-pub
docker network create strefa-priv
docker run -d --name proxy     --network strefa-pub  alpine sleep 3600
docker run -d --name baza      --network strefa-priv alpine sleep 3600
docker run -d --name aplikacja --network strefa-pub  alpine sleep 3600
docker network connect strefa-priv aplikacja          # aplikacja w obu sieciach
docker exec proxy     ping -c1 aplikacja               # OK
docker exec aplikacja ping -c1 baza                    # OK
docker exec proxy     ping -c1 baza || echo "proxy nie widzi bazy (dobra izolacja)"

# 4. Publikacja portów
docker run -d --name web-loc -p 127.0.0.1:8081:80 caddy:alpine   # tylko localhost
docker run -d --name web-rnd -P caddy:alpine                     # port losowy
docker port web-rnd                                              # odczyt mapowania

# Sprzątanie
docker rm -f a1 a2 api worker proxy baza aplikacja web-loc web-rnd
docker network rm lab-net strefa-pub strefa-priv
```

## Ćwiczenie 7 - Budowanie własnego obrazu (Dockerfile)

`app.js`:
```js
const express = require("express");
const app = express();
const VERSION = process.env.APP_VERSION || "dev";

app.get("/api/status", (req, res) => res.json({ status: "ok", version: VERSION }));
app.get("/healthz", (req, res) => res.status(200).send("OK"));

app.listen(3000, () => console.log("API na porcie 3000, wersja " + VERSION));
```

`package.json`:
```json
{
  "name": "status-api",
  "version": "1.0.0",
  "main": "app.js",
  "dependencies": { "express": "^4.19.2" }
}
```

`Dockerfile`:
```dockerfile
FROM node:20-alpine
WORKDIR /app

# najpierw zależności - warstwa cache'owana przy zmianach kodu
COPY package.json .
RUN npm install --omit=dev

# dopiero potem kod aplikacji
COPY app.js .

ENV APP_VERSION=1.0.0
EXPOSE 3000

HEALTHCHECK --interval=15s --timeout=3s --start-period=10s --retries=3 \
  CMD wget -q -O /dev/null http://localhost:3000/healthz || exit 1

CMD ["node", "app.js"]
```

```bash
# 3. Budowa, uruchomienie, test
docker build -t status-api:1.0 .
docker run -d -p 3000:3000 --name api status-api:1.0
sleep 12
curl -s localhost:3000/api/status
docker inspect --format='{{.State.Health.Status}}' api   # healthy

# 4. Zmiana tylko kodu -> warstwa npm install z cache
sed -i 's/"ok"/"ready"/' app.js
docker build -t status-api:1.1 .          # w logu: krok npm install -> CACHED

# Sprzątanie
docker rm -f api
docker rmi status-api:1.0 status-api:1.1
```

## Ćwiczenie 8 - Optymalizacja i multi-stage build

`Dockerfile` (multi-stage, produkcyjny):
```dockerfile
# Etap 1: budowanie statycznych plików
FROM node:20-alpine AS build
WORKDIR /app
COPY package.json package-lock.json* ./
RUN npm install
COPY . .
RUN npm run build           # generuje katalog dist/

# Etap 2: lekki serwer statyczny - kopiujemy tylko wynik buildu
FROM nginx:alpine
COPY --from=build /app/dist /usr/share/nginx/html
EXPOSE 80
```

`Dockerfile.dev` (jednoetapowy, do porównania rozmiaru):
```dockerfile
FROM node:20-alpine
WORKDIR /app
COPY package.json package-lock.json* ./
RUN npm install
COPY . .
EXPOSE 5173
CMD ["npm", "run", "dev", "--", "--host"]
```

`.dockerignore`:
```
node_modules
dist
.env
.env.*
.git
*.md
```

```bash
# Przykładowy projekt do testów
npm create vite@latest frontend -- --template react
cd frontend

docker build -t frontend:prod .
docker build -f Dockerfile.dev -t frontend:dev .
docker images | grep frontend
#   frontend:prod (nginx + statyka) jest rzędy wielkości mniejszy
#   niż frontend:dev (cały toolchain Node + node_modules)

# Wpływ .dockerignore na rozmiar kontekstu
tar -czh -f - . 2>/dev/null | wc -c                          # bez wykluczeń
tar -czh -f - --exclude-from=.dockerignore . 2>/dev/null | wc -c   # z .dockerignore

# Sprzątanie
docker rmi frontend:prod frontend:dev
cd .. && rm -rf frontend
```

Komentarz: w obrazie produkcyjnym nie ma kompilatora ani `node_modules` - trafia tam wyłącznie zbudowana statyka serwowana przez nginx. Stąd dramatyczna różnica rozmiaru względem wariantu jednoetapowego.

## Ćwiczenie 9 - Docker Compose: aplikacja wielokontenerowa

`app.js`:
```js
const express = require("express");
const { Pool } = require("pg");
const app = express();

const pool = new Pool({
  host: process.env.DB_HOST || "db",
  user: process.env.DB_USER || "app",
  password: process.env.DB_PASSWORD || "app",
  database: process.env.DB_NAME || "app",
  port: 5432,
});

app.get("/health", async (req, res) => {
  try { await pool.query("SELECT 1"); res.send("ok"); }
  catch { res.status(503).send("db down"); }
});

app.get("/dodaj", async (req, res) => {
  await pool.query("CREATE TABLE IF NOT EXISTS wizyty (id SERIAL PRIMARY KEY, ts TIMESTAMP DEFAULT now())");
  await pool.query("INSERT INTO wizyty DEFAULT VALUES");
  const r = await pool.query("SELECT COUNT(*) AS liczba FROM wizyty");
  res.json({ liczba: r.rows[0].liczba });
});

app.listen(3000, () => console.log("API na porcie 3000"));
```

`package.json`:
```json
{
  "name": "compose-api",
  "version": "1.0.0",
  "main": "app.js",
  "dependencies": { "express": "^4.19.2", "pg": "^8.11.5" }
}
```

`Dockerfile`:
```dockerfile
FROM node:20-alpine
WORKDIR /app
COPY package.json .
RUN npm install --omit=dev
COPY app.js .
EXPOSE 3000
CMD ["node", "app.js"]
```

`docker-compose.yml`:
```yaml
services:
  api:
    build: .
    ports:
      - "3000:3000"          # do skalowania zmień na "3000-3002:3000" lub usuń host port
    environment:
      DB_HOST: db
      DB_USER: app
      DB_PASSWORD: app
      DB_NAME: app
    depends_on:
      - db
    networks: [appnet]
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "wget", "-qO-", "http://localhost:3000/health"]
      interval: 15s
      timeout: 5s
      retries: 5

  db:
    image: postgres:16-alpine
    environment:
      POSTGRES_USER: app
      POSTGRES_PASSWORD: app
      POSTGRES_DB: app
    volumes:
      - pgdata:/var/lib/postgresql/data
    networks: [appnet]
    restart: unless-stopped
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U app"]
      interval: 10s
      timeout: 5s
      retries: 5

volumes:
  pgdata:

networks:
  appnet:
    driver: bridge
```

```bash
# 3. Uruchomienie i test komunikacji api <-> db po nazwie usługi
docker compose up -d
docker compose ps
sleep 10
curl -s localhost:3000/dodaj      # {"liczba":"1"}
curl -s localhost:3000/dodaj      # {"liczba":"2"}

# 4. Skalowanie (wymaga zniesienia stałego host portu - patrz komentarz w pliku)
docker compose up -d --scale api=3
docker compose ps

# Zatrzymanie: bez wolumenów dane zostają, z -v - znikają
docker compose down
docker compose down -v
```

Komentarz: `depends_on` gwarantuje tylko **kolejność startu**, nie gotowość bazy - dlatego aplikacja i tak musi obsłużyć chwilowy brak połączenia (tu robi to `healthcheck` + ponawiane zapytania). Przy `--scale api=3` stałe mapowanie `"3000:3000"` powoduje konflikt portu; należy użyć zakresu `"3000-3002:3000"` albo opublikować port bez stałej wartości hosta.

## Ćwiczenie 10 - Bezpieczeństwo obrazu i ochrona sekretów

`app.py` (wspólna, minimalna usługa HTTP):
```python
from http.server import BaseHTTPRequestHandler, HTTPServer

class H(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200); self.end_headers()
        self.wfile.write(b"ok\n")

HTTPServer(("0.0.0.0", 8000), H).serve_forever()
```

`Dockerfile.root`:
```dockerfile
FROM python:3.12-alpine
WORKDIR /app
COPY app.py .
EXPOSE 8000
CMD ["python", "app.py"]
```

`Dockerfile.nonroot`:
```dockerfile
FROM python:3.12-alpine
RUN addgroup -g 1001 app && adduser -D -u 1001 -G app app
WORKDIR /app
COPY --chown=app:app app.py .
USER app
EXPOSE 8000
CMD ["python", "app.py"]
```

```bash
# 1. Porównanie tożsamości procesu
docker build -f Dockerfile.root    -t sec:root    .
docker build -f Dockerfile.nonroot -t sec:nonroot .
docker run --rm sec:root    id      # uid=0(root)
docker run --rm sec:nonroot id      # uid=1001(app)

# 2. Test uprawnień zapisu do katalogu systemowego
docker run --rm sec:root    sh -c "touch /etc/x && echo zapis_OK || echo brak"   # zapis_OK
docker run --rm sec:nonroot sh -c "touch /etc/x && echo zapis_OK || echo brak"   # brak
```

`.dockerignore` (do punktu 3):
```
.git
node_modules
.env
.env.*
*.md
```

```bash
# 3. Wpływ .dockerignore na kontekst budowania
mkdir -p .git && echo "SECRET=poufne" > .env && echo "# dok" > README.md
tar -czh -f - . 2>/dev/null | wc -c                                   # bez wykluczeń
tar -czh -f - --exclude-from=.dockerignore . 2>/dev/null | wc -c      # mniejszy
```

```bash
# Sekret testowy
echo "API_TOKEN=super-tajne-12345" > token.txt
```

`Dockerfile.arg` (WYCIEK przez ARG):
```dockerfile
FROM alpine:latest
ARG API_TOKEN
RUN echo "uzyto tokenu: ${API_TOKEN}" > /tmp/log
CMD ["true"]
```

`Dockerfile.copy` (WYCIEK przez COPY + rm):
```dockerfile
FROM alpine:latest
COPY token.txt /tmp/token.txt
RUN cat /tmp/token.txt > /tmp/log && rm /tmp/token.txt
CMD ["true"]
```

`Dockerfile.secret` (POPRAWNIE - montaż BuildKit):
```dockerfile
# syntax=docker/dockerfile:1
FROM alpine:latest
RUN --mount=type=secret,id=token \
    cat /run/secrets/token > /tmp/log && \
    echo "sekret uzyty bez zapisu do warstwy"
CMD ["true"]
```

```bash
# 4a. Wyciek przez ARG - wartość widoczna w historii obrazu
docker build -f Dockerfile.arg --build-arg API_TOKEN=super-tajne-12345 -t leak:arg .
docker history --no-trunc leak:arg | grep -i token      # token widoczny!

# 4b. Wyciek przez COPY+rm - plik zniknął z finalnej warstwy, ale został we wcześniejszej
docker build -f Dockerfile.copy -t leak:copy .
docker run --rm leak:copy ls /tmp/token.txt 2>&1 || echo "brak w finalnej warstwie..."
docker save leak:copy -o leak.tar
mkdir -p extracted && tar -xf leak.tar -C extracted
find extracted -name "*.tar" -exec tar -xOf {} \; 2>/dev/null | grep -a "super-tajne" \
  && echo "ODZYSKANO sekret z warstw (zle!)"

# 5. Poprawnie - BuildKit secret mount, brak sladu w historii
DOCKER_BUILDKIT=1 docker build -f Dockerfile.secret \
  --secret id=token,src=./token.txt -t safe:secret .
docker history --no-trunc safe:secret | grep -i token || echo "brak tokenu w historii (dobrze)"

# Sprzątanie
docker rmi sec:root sec:nonroot leak:arg leak:copy safe:secret
rm -rf .git extracted leak.tar token.txt .env README.md
```

Zasady kluczowe: nigdy nie przekazuj sekretów przez `ARG`/`ENV` (lądują w historii obrazu) ani przez `COPY` z późniejszym `rm` (wartość zostaje w niższej warstwie i jest odzyskiwalna po `docker save`). Sekret potrzebny tylko podczas budowania montuj przez BuildKit (`RUN --mount=type=secret`); sekret potrzebny w działaniu wstrzykuj w runtime (`-e`, `--env-file`, montowane pliki).