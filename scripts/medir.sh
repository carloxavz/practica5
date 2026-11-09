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
URL="https://firestore.googleapis.com/v1/projects/$PROYECTO/databases/$BASE/documents/pedidos?pageSize=1000"

curl -s -X POST "$B/inventario/reiniciar" >/dev/null
sleep 2

T0=$(date +%s.%N)
CODIGOS=$(seq "$N" | xargs -P "$P" -I{} curl -s -o /dev/null -w "%{http_code}\n" -X POST "$B/pedidos" \
  -H 'Content-Type: application/json' \
  -d "{\"cliente\": \"M-$ETQ {}\", \"items\": [{\"producto\": \"tinto\", \"cantidad\": 1}]}" | sort | uniq -c | tr '\n' ' ')
T1=$(date +%s.%N)

# Sondea Firestore hasta que los N pedidos estén terminados (máximo 10 minutos).
TOKEN=$(gcloud auth print-access-token)
for _ in $(seq 300); do
  DOCS=$(curl -s -H "Authorization: Bearer $TOKEN" "$URL")
  HECHOS=$(echo "$DOCS" | jq --arg e "M-$ETQ " '[.documents[] | select(.fields.cliente.stringValue | startswith($e))
           | select(.fields.estado.stringValue == "listo" or .fields.estado.stringValue == "rechazado")] | length')
  [ "$HECHOS" -ge "$N" ] && break
  sleep 2
done

ULTIMO=$(echo "$DOCS" | jq -r --arg e "M-$ETQ " '[.documents[] | select(.fields.cliente.stringValue | startswith($e))
         | .fields.actualizado.timestampValue] | max')
LISTOS=$(echo "$DOCS" | jq --arg e "M-$ETQ " '[.documents[] | select(.fields.cliente.stringValue | startswith($e))
         | select(.fields.estado.stringValue == "listo")] | length')
T_ULT=$(date -d "$ULTIMO" +%s.%N)

LINEA=$(awk -v e="$ETQ" -v n="$N" -v p="$P" -v t0="$T0" -v t1="$T1" -v tu="$T_ULT" -v l="$LISTOS" -v c="$CODIGOS" \
  'BEGIN { printf "%s | N=%s P=%s | publicar=%.1fs | ultimo_terminado=%.1fs | listos=%s/%s | codigos: %s", e, n, p, t1-t0, tu-t0, l, n, c }')
mkdir -p ~/ev
echo "$LINEA" | tee -a ~/ev/mediciones.txt
