# Stack monitoringowy w kontenerach (Docker / Podman)

Jeden `docker-compose.yml` z całym środowiskiem szkoleniowym — kontenerowy
odpowiednik sześciu skryptów instalacyjnych z Modułu 9 materiałów
[Monitoring](https://github.com/Sebastian-Koziatek/Monitoring), tylko że
wszystko wstaje jedną komendą i komunikuje się ze sobą po nazwach usług.

Działa tak samo na **Dockerze** i na **Podmanie** (również rootless).

| Komponent | Kontenery | Odpowiednik skryptu |
|---|---|---|
| ELK Stack | `elasticsearch`, `kibana`, `elk-setup` | Instalacja ELK Stack.md |
| Grafana | `grafana` | Instalacja Grafany.md |
| InfluxDB + Telegraf | `influxdb`, `telegraf` | Instalacja InfluxDB i Telegraf.md |
| Loki | `loki`, `promtail` | Instalacja Lokiego.md |
| Prometheus | `prometheus`, `node-exporter` | Instalacja Prometheus i Node Exporter.md |
| Zabbix 7.0 LTS | `zabbix-db`, `zabbix-server`, `zabbix-web`, `zabbix-agent` | Instalacja Zabbix.md |

---

## Porty i dostępy

| Usługa | URL | Login | Hasło |
|---|---|---|---|
| Grafana | http://HOST:3000 | `admin` | `admin` |
| Kibana | http://HOST:5601 | `szkolenie` | `szkolenie` |
| Elasticsearch | http://HOST:9200 | `szkolenie` | `szkolenie` |
| Prometheus | http://HOST:9090 | — | — |
| Node Exporter | http://HOST:9100/metrics | — | — |
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

```
node-exporter ─┐
telegraf ──────┼──► prometheus ──┐
loki ──────────┤                 │
influxdb ──────┘                 │
                                 ├──► GRAFANA (datasource'y wstrzyknięte
promtail ──► loki ───────────────┤      automatycznie przez provisioning)
                                 │
telegraf ──► influxdb ───────────┤
                                 │
kibana ──► elasticsearch ────────┘  (ES też jako datasource Grafany)

zabbix-agent ──► zabbix-server ──► zabbix-db (MariaDB)
                       └──────────► zabbix-web (frontend :8081)
```

Konkretne powiązania:

- **Prometheus** scrape'uje: siebie, `node-exporter`, `telegraf` (port 9273),
  `loki`, `promtail`, `grafana`, `influxdb` — plik `config/prometheus/prometheus.yml`.
- **Telegraf** pisze do InfluxDB v2 **i równolegle** wystawia te same metryki
  w formacie Prometheusa, dodatkowo sprawdza dostępność wszystkich usług
  (`inputs.http_response`) i czyta statystyki klastra Elasticsearch
  (`inputs.elasticsearch`).
- **Promtail** zbiera logi z `/var/log` hosta i wysyła do Lokiego.
- **Grafana** ma gotowe źródła: Prometheus (domyślne), Loki, InfluxDB (Flux),
  Elasticsearch. Zabbix — opcjonalnie, patrz niżej.
- **elk-setup** to kontener jednorazowy: czeka na Elasticsearch, ustawia hasło
  `kibana_system` i zakłada użytkownika `szkolenie` (rola superuser) — dokładnie
  to, co w skrypcie robiły `elasticsearch-reset-password` i `curl`.

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

### 2. Zabbix — wskaż agenta

Domyślny host „Zabbix server" w Zabbixie ma interfejs `127.0.0.1`, a agent
siedzi w osobnym kontenerze. W GUI: **Data collection → Hosts → Zabbix server →
Interfaces** i zmień adres na `zabbix-agent` (DNS name), port `10050`.

### 3. Zabbix w Grafanie (opcjonalnie)

```bash
docker compose exec grafana grafana cli plugins ls     # czy plugin jest
mv config/grafana/provisioning/datasources/zabbix.yaml.example \
   config/grafana/provisioning/datasources/zabbix.yaml
docker compose restart grafana
```

Plugin `alexanderzobnin-zabbix-app` instaluje się przy pierwszym starcie
Grafany i wymaga internetu. Dopóki go nie ma, **nie** zmieniaj nazwy pliku na
`.yaml` — provisioning wywali błąd przy starcie.

### 4. Dashboardy

Pliki `.json` wrzuć do `config/grafana/provisioning/dashboards/` i zrestartuj
Grafanę. Sprawdzone ID z grafana.com: **1860** (Node Exporter Full),
**928** (Telegraf system metrics), **13639** (Loki logs).

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
    └── grafana/provisioning/
        ├── datasources/datasources.yaml  # Prometheus, Loki, InfluxDB, ES
        ├── datasources/zabbix.yaml.example
        └── dashboards/dashboards.yaml
```

---

## Różnice względem skryptów bare-metal

| Skrypt (systemd) | Stack (kontenery) |
|---|---|
| Loki 2.9.3, boltdb-shipper, schema v11 | Loki 3.5, TSDB, schema v13 (2.9 nie jest już wspierane) |
| `elasticsearch-reset-password` + `curl` | kontener `elk-setup` robi to samo przez API |
| ręczne `influx setup` + wklejanie tokenu | `DOCKER_INFLUXDB_INIT_*` + token z `.env` |
| Zabbix na Apache, port 80 | Zabbix na nginx, port 8081 (rootless Podman) |
| brak agenta logów | dołożony Promtail — bez niego Loki stoi pusty |
| datasource'y klikane ręcznie w GUI | provisioning z pliku przy starcie Grafany |
