# Ćwiczenia praktyczne: Docker

## Ćwiczenie 1 - Uruchamianie kontenerów

**Cel:** Rozróżnić uruchomienie jednorazowe, interaktywne i w tle oraz podstawowe operacje na działającym kontenerze.

**Zadanie:**
1. Uruchom jednorazowo kontener `busybox`, który wypisze aktualną datę i sam się usunie po zakończeniu.
2. Wejdź interaktywnie do kontenera `debian:12` i sprawdź wewnątrz: wersję systemu (`cat /etc/os-release`), listę procesów oraz identyfikator bieżącego procesu (`echo $$`). Opuść kontener.
3. Uruchom w tle serwer `httpd:alpine` (Apache) pod nazwą `apache-lab`, mapując port `9090` hosta na `80` kontenera. Potwierdź odpowiedź przez `curl`.
4. Wyświetl listę działających kontenerów, a następnie listę wszystkich (również zakończonych), i obejrzyj logi serwera Apache.

---

## Ćwiczenie 2 - Praca z obrazami

**Cel:** Pobierać, przeglądać, tagować i porównywać obrazy oraz rozumieć ich warstwową budowę.

**Zadanie:**
1. Pobierz obrazy `python:3.12-alpine`, `python:3.12-slim` oraz `redis:7-alpine`. Wyświetl lokalne obrazy i porównaj rozmiary wariantów `alpine` i `slim`.
2. Obejrzyj historię warstw obrazu `redis:7-alpine` i wskaż polecenia, które utworzyły poszczególne warstwy.
3. Z `docker inspect` obrazu `python:3.12-slim` odczytaj: domyślne polecenie (`Cmd`), zmienne środowiskowe oraz architekturę.
4. Nadaj obrazowi `redis:7-alpine` dwa tagi: `cache/redis:prod` i `cache/redis:rc`. Potwierdź, że oba wskazują ten sam `IMAGE ID`, a następnie usuń tag `cache/redis:rc`.

---

## Ćwiczenie 3 - Cykl życia i interakcja z kontenerem

**Cel:** Zarządzać stanami kontenera oraz diagnozować i modyfikować działającą instancję.

**Zadanie:**
1. Uruchom w tle długo żyjący kontener `busybox` (`sleep 7200`) pod nazwą `serwis`.
2. Przejdź przez stany: `pause` -> `unpause` -> `restart` -> `stop` -> `start`, sprawdzając status po każdym kroku.
3. Bez wchodzenia do kontenera wypisz zawartość katalogu głównego (`docker exec ...`).
4. Wejdź interaktywnie, utwórz katalog `/dane` i plik w nim z dowolną treścią, wyjdź i potwierdź spoza kontenera, że plik istnieje.
5. Utwórz na hoście plik `raport.txt`, skopiuj go do kontenera, a następnie skopiuj go z powrotem pod inną nazwą.
6. Odczytaj przez szablon (`--format`) status kontenera oraz datę jego uruchomienia.

---

## Ćwiczenie 4 - Limity zasobów

**Cel:** Ograniczać pamięć i CPU oraz zaobserwować działanie mechanizmu OOM-killer.

**Zadanie:**
1. Uruchom kontener `redis:7-alpine` z limitem pamięci `128m` oraz drugi kontener z limitem CPU `0.25`. Zweryfikuj limity migawkowym `docker stats`.
2. Uruchom w tle kontener `python:3.12-alpine` z limitem pamięci `32m`, który po krótkim opóźnieniu próbuje zaalokować dużą listę w pamięci (np. `python -c "a=[0]*50_000_000; import time; time.sleep(60)"`).
3. Po kilku sekundach sprawdź flagę `OOMKilled` w `docker inspect` oraz kod wyjścia kontenera.
4. Uruchom ten sam scenariusz dwukrotnie: raz z limitem `--cpus="0.25"`, raz z `--cpu-shares=256`, i opisz różnicę w znaczeniu obu parametrów.

---

## Ćwiczenie 5 - Trwałość danych

**Cel:** Zapewnić przetrwanie danych poza cyklem życia kontenera i dobrać właściwy mechanizm składowania.

**Zadanie:**
1. Utwórz wolumen nazwany `mariadb-data` i podłącz go do kontenera `mariadb:11` (katalog `/var/lib/mysql`, hasło roota przez zmienną środowiskową). Utwórz bazę `sklep`. Usuń kontener, uruchom nowy z tym samym wolumenem i potwierdź, że baza `sklep` nadal istnieje.
2. Przygotuj na hoście katalog z plikiem statycznym i podłącz go w trybie tylko do odczytu do serwera `caddy:alpine`. Zmień plik na hoście i potwierdź widoczność zmiany w kontenerze.
3. Uruchom kontener z montażem `tmpfs` o rozmiarze `16m`, zapisz w nim plik, zrestartuj kontener i potwierdź, że plik zniknął.
4. Wykonaj kopię zapasową wolumenu `mariadb-data` do archiwum `.tar.gz`, korzystając z pomocniczego kontenera.

---

## Ćwiczenie 6 - Sieci kontenerów

**Cel:** Zbudować komunikację między kontenerami z rozwiązywaniem nazw oraz świadomie publikować porty i izolować segmenty.

**Zadanie:**
1. Uruchom dwa kontenery `alpine` na domyślnym mostku i pokaż, że komunikują się po adresie IP, lecz nie po nazwie.
2. Utwórz własną sieć `lab-net` z podaną podsiecią (`172.30.0.0/16`), uruchom w niej kontenery `api` i `worker` i potwierdź, że pingują się po nazwie.
3. Zbuduj topologię trójwarstwową: sieci `strefa-pub` i `strefa-priv`; `proxy` w `strefa-pub`, `baza` w `strefa-priv`, a `aplikacja` podłączona do obu sieci. Wykaż, że `proxy` dosięga `aplikacja`, `aplikacja` dosięga `baza`, ale `proxy` nie dosięga `baza`.
4. Opublikuj usługę `caddy:alpine` raz tylko na pętli lokalnej hosta (`127.0.0.1`), a raz na porcie losowym, i odczytaj przydzielony port.

---

## Ćwiczenie 7 - Budowanie własnego obrazu (Dockerfile)

**Cel:** Napisać poprawny Dockerfile z kontrolą zdrowia i wykorzystaniem cache warstw.

**Zadanie:**
1. Przygotuj minimalną usługę REST w Node.js z Express, udostępniającą endpoint `/api/status` (zwraca JSON) oraz `/healthz` (zwraca 200).
2. Napisz Dockerfile na bazie `node:20-alpine`, który: ustawia katalog roboczy, najpierw kopiuje `package.json` i instaluje zależności, dopiero potem kopiuje kod, ustawia zmienną środowiskową z numerem wersji, deklaruje port i definiuje `HEALTHCHECK` odpytujący `/healthz`.
3. Zbuduj obraz z tagiem, uruchom kontener, sprawdź odpowiedź endpointu oraz status zdrowia odczytany z `docker inspect`.
4. Zmień wyłącznie treść odpowiedzi `/api/status`, przebuduj obraz i wskaż w logu budowania, że warstwa instalacji zależności została pobrana z cache.

---

## Ćwiczenie 8 - Optymalizacja i multi-stage build

**Cel:** Znacząco zmniejszyć obraz produkcyjny dzięki budowaniu wieloetapowemu i dobrym praktykom warstw.

**Zadanie:**
1. Przygotuj aplikację frontendową budowaną przez Node (np. prosty projekt Vite/React generujący katalog `dist`).
2. Napisz Dockerfile multi-stage: etap `build` na `node:20-alpine` instaluje zależności i buduje statyczne pliki, a etap finalny na `nginx:alpine` kopiuje wyłącznie wynik budowania (`COPY --from=build .../dist /usr/share/nginx/html`).
3. Dla porównania napisz wariant jednoetapowy oparty wprost na obrazie Node z serwerem deweloperskim i porównaj rozmiary obu obrazów.
4. Dodaj `.dockerignore` wykluczający `node_modules`, katalog buildu, pliki `.env` oraz dokumentację. Porównaj rozmiar kontekstu budowania z plikiem i bez niego.

---

## Ćwiczenie 9 - Docker Compose: aplikacja wielokontenerowa

**Cel:** Zdefiniować i uruchomić wielousługowy stos jednym plikiem `docker-compose.yml`.

**Zadanie:**
1. Zbuduj stos złożony z usług: `api` (aplikacja w Node.js lub Pythonie budowana z lokalnego Dockerfile, zapisująca i odczytująca rekordy) oraz `db` (`postgres:16-alpine`).
2. W pliku Compose skonfiguruj: budowanie usługi `api`, mapowanie portu, zmienne środowiskowe z danymi połączenia do bazy (host = nazwa usługi `db`), `depends_on`, wolumen nazwany na dane Postgresa, wspólną sieć oraz `healthcheck` dla obu usług. Ustaw politykę restartu.
3. Uruchom stos w tle, sprawdź status usług i kilkukrotnie wywołaj endpoint `api` zapisujący rekord, aby potwierdzić komunikację z bazą po nazwie usługi.
4. Przeskaluj usługę `api` do 3 instancji, podejrzyj listę kontenerów, a następnie zatrzymaj i usuń stos - najpierw bez, a potem wraz z wolumenami.

---

## Ćwiczenie 10 - Bezpieczeństwo obrazu i ochrona sekretów

**Cel:** Zbudować obraz zgodny z dobrymi praktykami bezpieczeństwa i nie dopuścić do wycieku poufnych danych do warstw.

**Zadanie:**
1. Przygotuj dwa warianty obrazu prostej usługi HTTP: pierwszy działający domyślnie jako `root`, drugi z utworzonym użytkownikiem nieuprzywilejowanym (`USER` oraz `COPY --chown`). Uruchom oba i porównaj wynik polecenia `id` wewnątrz każdego z nich.
2. Wykaż różnicę w uprawnieniach: w obu kontenerach spróbuj zapisać plik do katalogu systemowego (np. `/etc`) i pokaż, że wariant nieuprzywilejowany nie ma takiej możliwości.
3. Dodaj plik `.dockerignore` wykluczający katalog `.git`, zależności, pliki `.env` z sekretami oraz dokumentację. Zbuduj obraz i potwierdź, że wykluczone pliki nie trafiły do środka. Porównaj rozmiar kontekstu budowania z plikiem `.dockerignore` i bez niego.
4. Zademonstruj wyciek sekretu przekazanego przez `ARG` (odszukaj go w `docker history`) oraz przez `COPY` z późniejszym `rm` (odzyskaj wartość po wyeksportowaniu obrazu poleceniem `docker save`).
5. Wprowadź sekret poprawnie - przy użyciu montażu BuildKit (`RUN --mount=type=secret,id=...`), tak aby był dostępny wyłącznie podczas jednej instrukcji `RUN`. Potwierdź, że nie pozostawia śladu w historii obrazu.