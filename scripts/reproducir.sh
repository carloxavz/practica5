#!/usr/bin/env bash
# Reconstruye la cafetería desde cero, sin pasos en la consola.
# Requisitos: infra/terraform.tfvars con proyecto, prefijo e imágenes (backend:v1, frontend:v1, cocina:v2).
# Uso (Cloud Shell, raíz del repo):  bash scripts/reproducir.sh
set -euo pipefail
cd "$(dirname "$0")/.."
RAIZ=$(pwd)
cd infra

# En Cloud Shell la red rechaza a veces muchas conexiones simultáneas: una subida y un recurso a la vez.
if [ ! -f /etc/docker/daemon.json ]; then
  echo '{"max-concurrent-uploads": 1}' | sudo tee /etc/docker/daemon.json >/dev/null
  sudo service docker restart >/dev/null && sleep 5
fi

terraform init -input=false >/dev/null

# 1. El registro (y las APIs).
terraform apply -input=false -auto-approve -parallelism=1 -target=google_artifact_registry_repository.registro

# 2. Las imágenes, con las mismas etiquetas que pide terraform.tfvars.
REGISTRO=$(terraform output -raw registro)
REGION=${REGISTRO%%-docker.pkg.dev*}
gcloud auth configure-docker "$REGION-docker.pkg.dev" --quiet
for img in $(grep -E '^imagen_' terraform.tfvars | sed -E 's/.*"(.*)".*/\1/'); do
  nombre=$(basename "${img%%:*}")
  docker build -q -t "$img" "$RAIZ/$nombre"
  docker push -q "$img"
done

# 3. Todo lo demás.
terraform apply -input=false -auto-approve -parallelism=1
terraform output
