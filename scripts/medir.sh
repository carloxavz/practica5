#!/usr/bin/env bash
# Mide cuánto tarda el último de N pedidos en quedar terminado (listo o rechazado).
# Uso (desde Cloud Shell, en la raíz del repo):  bash scripts/medir.sh <etiqueta> [N=60] [paralelo=20]
# Escribe una línea de resultado en ~/ev/mediciones.txt
set -euo pipefail
cd "$(dirname "$0")/../infra"

ETQ=${1:?etiqueta, p. ej. max3-r1}
N=${2:-60}
P=${3:-20}
B=$(terraform output -raw url_backend)
PROYECTO=$(gcloud config get-value project 2>/dev/null)
BASE=${BASE:-marci-cafeteria}
URL="https://firestore.googleapis.com/v1/projects/$PROYECTO/databases/$BASE/documents:runQuery"
PREF="M-$ETQ "

# Consulta solo los pedidos de esta medición (cliente empieza por "M-<etiqueta> ").
# Un filtro de rango sobre un solo campo no necesita índice compuesto.
CONSULTA=$(jq -cn --arg a "$PREF" --arg b "$PREF~" '{structuredQuery: {from: [{collectionId: "pedidos"}],
  where: {compositeFilter: {op: "AND", filters: [
    {fieldFilter: {field: {fieldPath: "cliente"}, op: "GREATER_THAN_OR_EQUAL", value: {stringValue: $a}}},
    {fieldFilter: {field: {fieldPath: "cliente"}, op: "LESS_THAN", value: {stringValue: $b}}}]}}}}')

curl -s -X POST "$B/inventario/reiniciar" >/dev/null
sleep 2

T0=$(date +%s.%N)
RESP=$(seq "$N" | xargs -P "$P" -I{} curl -s -m 30 -o /dev/null -w "%{http_code}\n" -X POST "$B/pedidos" \
  -H 'Content-Type: application/json' \
  -d "{\"cliente\": \"$PREF{}\", \"items\": [{\"producto\": \"tinto\", \"cantidad\": 1}]}")
T1=$(date +%s.%N)
CODIGOS=$(echo "$RESP" | sort | uniq -c | tr '\n' ' ')
OK=$(echo "$RESP" | grep -c '^201$' || true)

# Sondea Firestore hasta que los pedidos aceptados (201) estén terminados (máximo 4 minutos).
TOKEN=$(gcloud auth print-access-token)
DOCS='[]'
for _ in $(seq 120); do
  DOCS=$(curl -s -m 20 -X POST -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
         "$URL" -d "$CONSULTA" | jq -c '[.[] | select(.document) | .document.fields]' 2>/dev/null || echo '[]')
  HECHOS=$(echo "$DOCS" | jq '[.[] | select(.estado.stringValue == "listo" or .estado.stringValue == "rechazado")] | length')
  [ "$HECHOS" -ge "$OK" ] && break
  sleep 2
done

ULTIMO=$(echo "$DOCS" | jq -r '[.[] | .actualizado.timestampValue] | max')
LISTOS=$(echo "$DOCS" | jq '[.[] | select(.estado.stringValue == "listo")] | length')
T_ULT=$(date -d "$ULTIMO" +%s.%N)

LINEA=$(awk -v e="$ETQ" -v n="$N" -v p="$P" -v t0="$T0" -v t1="$T1" -v tu="$T_ULT" -v l="$LISTOS" -v c="$CODIGOS" \
  -v ok="$OK" -v h="$HECHOS" 'BEGIN { printf "%s | N=%s P=%s | publicar=%.1fs | ultimo_terminado=%.1fs | terminados=%s/%s | listos=%s | codigos: %s", e, n, p, t1-t0, tu-t0, h, ok, l, c }')
mkdir -p ~/ev
echo "$LINEA" | tee -a ~/ev/mediciones.txt
