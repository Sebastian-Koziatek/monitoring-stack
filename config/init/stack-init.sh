#!/bin/sh
# =============================================================================
#  stack-init — domyka integracje, których nie da się wstrzyknąć plikiem
#
#  1. Zabbix API  — przestawia interfejs hosta "Zabbix server" z 127.0.0.1
#                   na kontener zabbix-agent (inaczej host jest niedostępny)
#  2. Grafana API — włącza plugin Zabbixa i zakłada datasource "Zabbix"
#
#  Skrypt jest IDEMPOTENTNY — można go puszczać wielokrotnie.
#  Brak pluginu Zabbixa w Grafanie nie jest błędem: skrypt to zgłasza i kończy
#  się sukcesem, żeby nie blokować reszty stacku.
# =============================================================================
set -u

ZBX_HOST_NAME="Zabbix server"
GRAFANA_AUTH="${GRAFANA_ADMIN_USER}:${GRAFANA_ADMIN_PASSWORD}"
ZBX_PLUGIN="alexanderzobnin-zabbix-app"

# --- pomocnicze --------------------------------------------------------------

zbx_api() {
  # $1 = metoda, $2 = params (JSON), $3 = token (opcjonalnie)
  if [ -n "${3:-}" ]; then
    curl -s -X POST "${ZBX_URL}" \
      -H 'Content-Type: application/json-rpc' \
      -H "Authorization: Bearer $3" \
      -d "{\"jsonrpc\":\"2.0\",\"method\":\"$1\",\"params\":$2,\"id\":1}"
  else
    curl -s -X POST "${ZBX_URL}" \
      -H 'Content-Type: application/json-rpc' \
      -d "{\"jsonrpc\":\"2.0\",\"method\":\"$1\",\"params\":$2,\"id\":1}"
  fi
}

wait_for() {
  # $1 = URL, $2 = opis, $3 = maks. liczba prób
  echo "  czekam na $2 ..."
  i=0
  until curl -sf -o /dev/null "$1"; do
    i=$((i + 1))
    if [ "$i" -ge "$3" ]; then
      echo "  ✗ $2 nie odpowiada — pomijam ten krok"
      return 1
    fi
    sleep 5
  done
  echo "  ✓ $2 odpowiada"
  return 0
}

# =============================================================================
#  KROK 1: Zabbix — interfejs agenta
# =============================================================================
echo "==== KROK 1: Zabbix — interfejs hosta '${ZBX_HOST_NAME}' ===="

if wait_for "http://zabbix-web:8080/" "frontend Zabbixa" 60; then

  # Frontend odpowiada zanim Zabbix server skończy import schematu bazy,
  # więc logowanie ponawiamy aż API zacznie działać (do ~5 minut).
  TOKEN=""
  i=0
  while [ -z "${TOKEN}" ] && [ "${i}" -lt 30 ]; do
    TOKEN=$(zbx_api user.login \
      "{\"username\":\"${ZBX_USER}\",\"password\":\"${ZBX_PASSWORD}\"}" \
      | jq -r '.result // empty')
    if [ -z "${TOKEN}" ]; then
      [ "${i}" -eq 0 ] && echo "  czekam na API Zabbixa (import schematu bazy) ..."
      i=$((i + 1))
      sleep 10
    fi
  done

  if [ -z "${TOKEN}" ]; then
    echo "  ✗ Nie udało się zalogować do API Zabbixa (user ${ZBX_USER})"
    echo "    Sprawdź:  docker compose logs zabbix-server | tail -30"
    echo "    Jeśli zmieniałeś hasło Admina, przestaw ZBX_PASSWORD w compose."
  else
    echo "  ✓ Zalogowany do API Zabbixa"

    # Interfejs typu 1 = Zabbix agent
    IFACE=$(zbx_api host.get \
      "{\"filter\":{\"host\":[\"${ZBX_HOST_NAME}\"]},\"selectInterfaces\":[\"interfaceid\",\"type\",\"ip\",\"dns\",\"useip\",\"port\"]}" \
      "${TOKEN}" \
      | jq -r '.result[0].interfaces[]? | select((.type|tostring)=="1") | .interfaceid' | head -1)

    if [ -z "${IFACE}" ]; then
      echo "  ✗ Nie znalazłem interfejsu agenta na hoście '${ZBX_HOST_NAME}'"
    else
      CURRENT=$(zbx_api hostinterface.get \
        "{\"interfaceids\":\"${IFACE}\",\"output\":[\"dns\",\"useip\"]}" "${TOKEN}" \
        | jq -r '.result[0] | "\(.useip):\(.dns)"')

      if [ "${CURRENT}" = "0:${ZBX_AGENT_DNS}" ]; then
        echo "  ✓ Interfejs już wskazuje na ${ZBX_AGENT_DNS} (nic nie zmieniam)"
      else
        RESULT=$(zbx_api hostinterface.update \
          "{\"interfaceid\":\"${IFACE}\",\"useip\":0,\"dns\":\"${ZBX_AGENT_DNS}\",\"port\":\"10050\"}" \
          "${TOKEN}")
        if echo "${RESULT}" | jq -e '.result.interfaceids' >/dev/null 2>&1; then
          echo "  ✓ Interfejs agenta przestawiony na ${ZBX_AGENT_DNS}:10050"
        else
          echo "  ✗ hostinterface.update nie przeszło: ${RESULT}"
        fi
      fi
    fi

    zbx_api user.logout '{}' "${TOKEN}" >/dev/null 2>&1
  fi
fi

# =============================================================================
#  KROK 2: Grafana — plugin i datasource Zabbixa
# =============================================================================
echo ""
echo "==== KROK 2: Grafana — datasource Zabbix ===="

if wait_for "${GRAFANA_URL}/api/health" "Grafana" 60; then

  # Grafana dociąga plugin w tle już po otwarciu portu — dajmy jej ~2 minuty
  i=0
  while ! curl -sf -u "${GRAFANA_AUTH}" "${GRAFANA_URL}/api/plugins/${ZBX_PLUGIN}/settings" >/dev/null 2>&1 \
        && [ "${i}" -lt 12 ]; do
    [ "${i}" -eq 0 ] && echo "  czekam na instalację pluginu ${ZBX_PLUGIN} ..."
    i=$((i + 1))
    sleep 10
  done

  if ! curl -sf -u "${GRAFANA_AUTH}" "${GRAFANA_URL}/api/plugins/${ZBX_PLUGIN}/settings" >/dev/null 2>&1; then
    echo "  ○ Plugin ${ZBX_PLUGIN} nie jest zainstalowany"
    echo "    Grafana dociąga go z internetu przy pierwszym starcie."
    echo "    Sprawdź:  docker compose logs grafana | grep -i plugin"
    echo "    Potem:    docker compose up -d --force-recreate stack-init"
  else
    echo "  ✓ Plugin ${ZBX_PLUGIN} obecny"

    curl -s -X POST -u "${GRAFANA_AUTH}" \
      -H 'Content-Type: application/json' \
      -d '{"enabled":true,"pinned":true}' \
      "${GRAFANA_URL}/api/plugins/${ZBX_PLUGIN}/settings" >/dev/null
    echo "  ✓ Plugin włączony w organizacji"

    if curl -sf -u "${GRAFANA_AUTH}" "${GRAFANA_URL}/api/datasources/name/Zabbix" >/dev/null 2>&1; then
      echo "  ✓ Datasource 'Zabbix' już istnieje (nic nie zmieniam)"
    else
      RESULT=$(curl -s -X POST -u "${GRAFANA_AUTH}" \
        -H 'Content-Type: application/json' \
        -d "{
              \"name\":\"Zabbix\",
              \"uid\":\"zabbix\",
              \"type\":\"alexanderzobnin-zabbix-datasource\",
              \"access\":\"proxy\",
              \"url\":\"http://zabbix-web:8080/api_jsonrpc.php\",
              \"jsonData\":{
                \"username\":\"${ZBX_USER}\",
                \"trends\":true,
                \"trendsFrom\":\"7d\",
                \"trendsRange\":\"4d\",
                \"cacheTTL\":\"1h\"
              },
              \"secureJsonData\":{\"password\":\"${ZBX_PASSWORD}\"}
            }" \
        "${GRAFANA_URL}/api/datasources")
      if echo "${RESULT}" | jq -e '.datasource.uid' >/dev/null 2>&1; then
        echo "  ✓ Datasource 'Zabbix' utworzony"
      else
        echo "  ✗ Nie udało się utworzyć datasource'a: ${RESULT}"
      fi
    fi
  fi
fi

echo ""
echo "==== stack-init zakończony ===="
exit 0
