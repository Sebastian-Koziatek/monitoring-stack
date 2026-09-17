#!/bin/sh
# =============================================================================
#  Konfiguracja użytkowników Elasticsearch — kontenerowy odpowiednik kroku 7
#  ze skryptu "Instalacja ELK Stack.md" (elasticsearch-reset-password + curl).
#
#  1. czeka aż Elasticsearch wstanie
#  2. ustawia hasło użytkownika technicznego kibana_system (Kibana -> ES)
#  3. tworzy użytkownika szkoleniowego z rolą superuser
# =============================================================================
set -e

ES="http://elasticsearch:9200"
AUTH="elastic:${ELASTIC_PASSWORD}"

echo "=== Czekam na Elasticsearch (${ES}) ==="
i=0
until curl -sf -u "${AUTH}" "${ES}/_cluster/health" >/dev/null 2>&1; do
  i=$((i + 1))
  if [ "$i" -gt 60 ]; then
    echo "✗ Elasticsearch nie odpowiedział w ciągu 5 minut"
    exit 1
  fi
  sleep 5
done
echo "✓ Elasticsearch odpowiada"

echo "=== Ustawiam hasło użytkownika kibana_system ==="
curl -sf -X POST "${ES}/_security/user/kibana_system/_password" \
  -u "${AUTH}" \
  -H 'Content-Type: application/json' \
  -d "{\"password\":\"${KIBANA_SYSTEM_PASSWORD}\"}" >/dev/null
echo "✓ Hasło kibana_system ustawione"

echo "=== Tworzę użytkownika szkoleniowego: ${TRAINING_USER} ==="
curl -sf -X POST "${ES}/_security/user/${TRAINING_USER}" \
  -u "${AUTH}" \
  -H 'Content-Type: application/json' \
  -d "{\"password\":\"${TRAINING_PASSWORD}\",\"roles\":[\"superuser\"],\"full_name\":\"Uzytkownik Szkoleniowy\"}" >/dev/null
echo "✓ Użytkownik ${TRAINING_USER} gotowy"

echo ""
echo "=========================================="
echo "DANE LOGOWANIA DLA UCZESTNIKÓW (Kibana):"
echo "  Login: ${TRAINING_USER}"
echo "  Hasło: ${TRAINING_PASSWORD}"
echo "=========================================="
