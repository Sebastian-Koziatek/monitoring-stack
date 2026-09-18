# Stack monitoringowy w kontenerach (Docker / Podman)

Jeden `docker-compose.yml` z całym środowiskiem szkoleniowym — kontenerowy
odpowiednik sześciu skryptów instalacyjnych z Modułu 9 materiałów
[Monitoring](https://github.com/Sebastian-Koziatek/Monitoring), tylko że
wszystko wstaje jedną komendą i komunikuje się ze sobą po nazwach usług.

Działa tak samo na **Dockerze** i na **Podmanie** (również rootless).

| Komponent | Kontenery | Odpowiednik skryptu |
|---|---|---|
| ELK Stack | `elasticsearch`, `kibana`, `elk-setup`, `filebeat`, `elasticsearch-exporter` | Instalacja ELK Stack.md |
| Grafana | `grafana` | Instalacja Grafany.md |
| InfluxDB + Telegraf | `influxdb`, `telegraf` | Instalacja InfluxDB i Telegraf.md |
| Loki | `loki`, `promtail` | Instalacja Lokiego.md |
| Prometheus | `prometheus`, `node-exporter` | Instalacja Prometheus i Node Exporter.md |
| Zabbix 7.0 LTS | `zabbix-db`, `zabbix-server`, `zabbix-web`, `zabbix-agent` | Instalacja Zabbix.md |
| Spinacz integracji | `stack-init` | — (dodatek) |

---

## Porty i dostępy

| Usługa | URL | Login | Hasło |
|---|---|---|---|
| Grafana | http://HOST:3000 | `admin` | `admin` |
| Kibana | http://HOST:5601 | `szkolenie` | `szkolenie` |
| Elasticsearch | http://HOST:9200 | `szkolenie` | `szkolenie` |
| Prometheus | http://HOST:9090 | — | — |
| Node Exporter | http://HOST:9100/metrics | — | — |
| Elasticsearch Exporter | http://HOST:9114/metrics | — | — |
| Telegraf (Prometheus) | http://HOST:9273/metrics | — | — |
| Loki | http://HOST:3100/ready | — | — |
| Promtail | http://HOST:9080 | — | — |
| InfluxDB | http://HOST:8086 | `admin` | `Influx123!` |
| Zabbix frontend | http://HOST:8081 | `Admin` | `zabbix` |
| Zabbix server (trapper) | HOST:10051 | — | — |
| Zabbix agent | HOST:10050 | — | — |

Wszystkie hasła siedzą w pliku `.env`, który jest w repozytorium celowo — stack
ma wstawać od razu po `git clone`. To hasła **szkoleniowe**, jawne także w tabeli
wyżej. W produkcji zmień je przed pierwszym startem (po starcie zmiana wymaga
skasowania wolumenów) i trzymaj poza repo.

---

## Uruchomienie

### Docker

```bash
cd monitoring-stack
docker compose up -d
docker compose ps
```

### Podman (rootless)

```bash
cd monitoring-stack

# wariant 1 — podman-compose
podman-compose up -d
podman-compose ps

# wariant 2 — wbudowany provider (deleguje do docker-compose)
podman compose up -d
```

### Przed pierwszym startem (Linux)

Elasticsearch lubi wyższy `vm.max_map_count` — na hoście:

```bash
sudo sysctl -w vm.max_map_count=262144
echo "vm.max_map_count=262144" | sudo tee -a /etc/sysctl.conf
```

Jeśli host ma mniej niż 8 GB RAM, zmniejsz stertę Elasticsearcha w `.env`
(`ES_HEAP_SIZE=512m`). Cały stack potrzebuje realnie ~6 GB RAM.

---

## Co jest z czym spięte

Wszystko poniżej działa **od razu po `up -d`**, bez klikania w GUI.

```
node-exporter ─────┐
telegraf ──────────┤
loki ──────────────┼──► prometheus ──┐
promtail ──────────┤                 │
influxdb ──────────┤                 │
es-exporter ───────┘                 │
                                     ├──► GRAFANA
telegraf ──────────► influxdb ───────┤    (5 datasource'ów + 5 dashboardów
                                     │     z provisioningu)
promtail ──────────► loki ───────────┤
filebeat ──────────► elasticsearch ──┤
                          ▲          │
                       kibana        │
                                     │
zabbix-agent ─► zabbix-server ───────┘
                     │   └──► zabbix-db (MariaDB)
                     └──────► zabbix-web (frontend :8081)
```

| Połączenie | Jak jest zrobione |
|---|---|
| Grafana → Prometheus, Loki, InfluxDB, Elasticsearch | provisioning, `datasources.yaml` |
| Grafana → Zabbix | `stack-init` przez API Grafany (plugin + datasource) |
| Prometheus → node_exporter, telegraf, loki, promtail, grafana, influxdb, es-exporter | `prometheus.yml`, 8 jobów |
| Telegraf → InfluxDB | token/org/bucket z `.env` — bez wklejania tokenu ręcznie |
| Telegraf → Elasticsearch | `inputs.elasticsearch` — statystyki klastra |
| Telegraf → wszystkie usługi | `inputs.http_response` — syntetyczne testy dostępności |
| Promtail → Loki | push na `loki:3100` |
| Filebeat → Elasticsearch | index `filebeat-*`, te same logi co w Lokim |
| Elasticsearch → Prometheus | `elasticsearch-exporter` na porcie 9114 |
| Kibana → Elasticsearch | hasło `kibana_system` ustawia `elk-setup` |
| Zabbix: agent → server → MariaDB, frontend → server | zmienne środowiskowe w compose |
| Zabbix: host „Zabbix server" → kontener agenta | `stack-init` przez API Zabbixa |

Dwa kontenery jednorazowe domykają to, czego nie da się wstrzyknąć plikiem
konfiguracyjnym:

- **`elk-setup`** — czeka na Elasticsearch, ustawia hasło `kibana_system`
  i zakłada użytkownika `szkolenie` (rola superuser).
- **`stack-init`** — przestawia interfejs hosta „Zabbix server" z `127.0.0.1`
  na kontener `zabbix-agent`, włącza plugin Zabbixa w Grafanie i zakłada
  datasource `Zabbix`. Jest **idempotentny** — można go puszczać ponownie:

  ```bash
  docker compose up -d --force-recreate stack-init
  docker compose logs stack-init
  ```

  Jeśli Grafana nie zdążyła zainstalować pluginu Zabbixa (dociąga go z
  internetu przy pierwszym starcie), `stack-init` zgłasza to i kończy się
  sukcesem — reszta stacku działa. Wystarczy potem puścić go jeszcze raz.

### Gotowe dashboardy

Wgrywają się same do folderu **Szkolenie**:

| Dashboard | Źródło danych | Skąd |
|---|---|---|
| Stack szkoleniowy — przegląd | Prometheus | własny — stan wszystkich komponentów, CPU/RAM, czasy odpowiedzi, zdrowie ES |
| Node Exporter Full | Prometheus | grafana.com ID 1860 |
| InfluxDB / Telegraf (Flux) | InfluxDB | własny — te same metryki drugą ścieżką, zapytania w Flux |
| Loki — logi hosta | Loki | grafana.com ID 13639 |
| Elasticsearch — logi z Filebeata | Elasticsearch | własny — wolumen logów + podgląd wpisów |

Dashboardy dla Influxa i ES są własne, bo gotowce z grafana.com pod Telegrafa
(ID 928) używają InfluxQL, a nasz datasource pracuje w trybie **Flux** — nie
pokazałyby żadnych danych. Własne pliki `.json` dorzucaj do
`config/grafana/provisioning/dashboards/` i restartuj Grafanę.

---

## Pierwsze kroki po starcie

### 1. Weryfikacja

```bash
curl -u szkolenie:szkolenie http://localhost:9200                 # Elasticsearch
curl -s http://localhost:5601/api/status | head -c 200            # Kibana
curl http://localhost:9090/api/v1/targets | head -c 400           # cele Prometheusa
curl http://localhost:3100/ready                                  # Loki
curl http://localhost:8086/health                                 # InfluxDB
curl -s http://localhost:9273/metrics | head -5                   # Telegraf
docker compose logs elk-setup                                     # dane logowania ELK
```

Kibana potrzebuje 1–2 minut na pełny start — to normalne.

### 2. Dashboardy Filebeata w Kibanie (opcjonalnie)

Filebeat wysyła logi od razu, ale gotowe dashboardy dla Kibany trzeba wgrać
jedną komendą (wymaga wstałej Kibany):

```bash
docker compose exec filebeat filebeat setup --dashboards
```

### 3. Logi kontenerów (opcjonalnie)

Promtail i Filebeat zbierają `/var/log` hosta. Logi samych kontenerów leżą
w innym miejscu na Dockerze (`/var/lib/docker/containers`) niż na Podmanie
(`~/.local/share/containers/storage/overlay-containers`), dlatego nie są
montowane domyślnie — dopisz wolumen pasujący do swojego silnika.

---

## Trwałość danych (wolumeny)

Każdy komponent, który cokolwiek przechowuje, ma **nazwany wolumen** — restart,
`docker compose down`, aktualizacja obrazu czy reboot hosta nie kasują danych.

| Wolumen | Kontener | Ścieżka | Co w nim jest |
|---|---|---|---|
| `es-data` | elasticsearch | `/usr/share/elasticsearch/data` | indeksy, dokumenty, konfiguracja security |
| `kibana-data` | kibana | `/usr/share/kibana/data` | UUID instancji, cache |
| `filebeat-data` | filebeat | `/usr/share/filebeat/data` | rejestr offsetów — po restarcie nie czyta logów od nowa |
| `grafana-data` | grafana | `/var/lib/grafana` | baza SQLite: userzy, dashboardy, alerty, pluginy |
| `prometheus-data` | prometheus | `/prometheus` | baza TSDB z metrykami (retencja 15 dni) |
| `loki-data` | loki | `/loki` | chunki logów, indeksy TSDB, WAL |
| `promtail-positions` | promtail | `/promtail` | pozycje w plikach — bez duplikatów po restarcie |
| `influxdb-data` | influxdb | `/var/lib/influxdb2` | dane serii czasowych |
| `influxdb-config` | influxdb | `/etc/influxdb2` | organizacja, bucket, tokeny |
| `zabbix-db-data` | zabbix-db | `/var/lib/mysql` | cała baza Zabbixa (hosty, historia, konfiguracja) |
| `zabbix-server-data` | zabbix-server | `/var/lib/zabbix` | skrypty alertów, moduły, snmptraps |

Co **nie** jest na wolumenie i nie musi być: `node-exporter`, `telegraf`,
`elasticsearch-exporter`, `zabbix-agent` i `zabbix-web` nie trzymają stanu —
wszystko, co produkują, ląduje w bazach powyżej.

Podgląd i backup:

```bash
docker compose config --volumes            # lista wolumenów stacku
docker volume ls | grep monitoring-lab     # jak nazywa je silnik
docker system df -v | grep monitoring-lab  # ile miejsca zajmują

# backup pojedynczego wolumenu do tar.gz
docker run --rm -v monitoring-lab_grafana-data:/data -v "$PWD:/backup" \
  alpine:3.21 tar czf /backup/grafana-$(date +%F).tar.gz -C /data .
```

Pod Podmanem te same komendy działają po podmianie `docker` na `podman`.
Wolumeny są tworzone przy pierwszym starcie i **przeżywają `down`** — kasuje je
dopiero `down -v`.

Przy pierwszym montowaniu oba silniki kopiują do wolumenu zawartość katalogu
z obrazu wraz z właścicielem, więc Elasticsearch (uid 1000), Grafana (472) czy
Loki (10001) mają prawo pisać także w trybie rootless.

---

## Zatrzymanie i sprzątanie

```bash
docker compose stop            # zatrzymanie, dane zostają
docker compose down            # usunięcie kontenerów, wolumeny zostają
docker compose down -v         # usunięcie WSZYSTKIEGO łącznie z danymi
```

`down -v` to odpowiednik `--remove` ze skryptów — kasuje indeksy Elasticsearcha,
bazę Zabbixa, dashboardy Grafany i metryki. Nieodwracalne.

---

## Uwagi dla Podmana

Plik jest pisany tak, żeby działał na obu silnikach bez zmian:

- brak klucza `version:` (przestarzały w Compose v2, ignorowany przez podman-compose),
- brak `privileged:` i montowania `/var/run/docker.sock`,
- żaden port nie schodzi poniżej 1024 (frontend Zabbixa jest na **8081**, nie na 80) —
  rootless Podman nie umie bindować portów uprzywilejowanych,
- brak `ulimits: memlock` (rootless nie podniesie twardego limitu),
- bind-mounty konfiguracji mają etykietę `:z` dla SELinuksa na RHEL/Fedorze,
- katalogi hosta (`/proc`, `/sys`, `/`, `/var/log`) są montowane **bez** `:z` —
  relabelowanie katalogów systemowych zepsułoby hosta.

Jeśli na RHEL-u z SELinuksem Promtail nie może czytać `/var/log`, odkomentuj
w usłudze `promtail`:

```yaml
    security_opt:
      - label=disable
```

Autostart po reboocie pod Podmanem (rootless, systemd usera):

```bash
podman generate systemd --new --files --name monitoring-lab   # starsze wersje
# albo (Podman 4.4+): quadlet, ~/.config/containers/systemd/
loginctl enable-linger $USER
```

---

## Struktura katalogów

```
monitoring-stack/
├── docker-compose.yml
├── .env                                  # hasła i parametry
├── README.md
└── config/
    ├── elk/init-users.sh                 # kibana_system + user szkolenie
    ├── prometheus/prometheus.yml         # scrape wszystkich komponentów
    ├── loki/loki-config.yaml             # TSDB + filesystem, retencja 7 dni
    ├── promtail/promtail-config.yaml     # zbiera /var/log hosta
    ├── telegraf/telegraf.conf            # InfluxDB v2 + prometheus_client
    ├── filebeat/filebeat.yml             # logi hosta -> Elasticsearch
    ├── init/stack-init.sh                # API Zabbixa + API Grafany
    └── grafana/provisioning/
        ├── datasources/datasources.yaml  # Prometheus, Loki, InfluxDB, ES
        └── dashboards/                   # provider + 5 gotowych dashboardów
```

---

## Różnice względem skryptów bare-metal

| Skrypt (systemd) | Stack (kontenery) |
|---|---|
| Loki 2.9.3, boltdb-shipper, schema v11 | Loki 3.5, TSDB, schema v13 (2.9 nie jest już wspierane) |
| `elasticsearch-reset-password` + `curl` | kontener `elk-setup` robi to samo przez API |
| ręczne `influx setup` + wklejanie tokenu | `DOCKER_INFLUXDB_INIT_*` + token z `.env` |
| Zabbix na Apache, port 80 | Zabbix na nginx, port 8081 (rootless Podman) |
| brak agenta logów | dołożony Promtail (Loki) i Filebeat (Elasticsearch) |
| datasource'y klikane ręcznie w GUI | provisioning z pliku przy starcie Grafany |
| Zabbix i Grafana nie wiedzą o sobie | `stack-init` spina je przez API |
| brak metryk ES w Prometheusie | dołożony elasticsearch-exporter |
| pusta Grafana po instalacji | 5 dashboardów wgranych z provisioningu |
