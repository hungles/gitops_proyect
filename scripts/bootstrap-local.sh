#!/usr/bin/env bash

# Bootstrap de demostración local: Argo CD -> Harbor -> imágenes -> ApplicationSet.
# No modifica /etc/hosts ni la configuración del daemon de Docker.

set -euo pipefail

readonly ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly ARGOCD_NAMESPACE="argocd"
readonly HARBOR_NAMESPACE="harbor"
readonly HARBOR_APPLICATION="gitops-harbor"
readonly TEMP_DIR="$(mktemp -d)"

HARBOR_URL="${HARBOR_URL:-harbor.local:30002}"
HARBOR_PROJECT="${HARBOR_PROJECT:-gitops}"
HARBOR_USERNAME="${HARBOR_USERNAME:-admin}"
HARBOR_PASSWORD="${HARBOR_PASSWORD:-}"
IMAGE_TAGS="${IMAGE_TAGS:-dev,prod}"
INSTALL_ARGOCD="${INSTALL_ARGOCD:-true}"

log() {
  printf '\n==> %s\n' "$*"
}

fail() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "Se requiere el comando '$1'."
}

wait_for_deployment() {
  local namespace="$1"
  local deployment="$2"
  wait_for_resource "$namespace" "deployment/${deployment}"
  kubectl -n "$namespace" rollout status "deployment/${deployment}" --timeout=10m
}

wait_for_statefulset() {
  local namespace="$1"
  local statefulset="$2"
  wait_for_resource "$namespace" "statefulset/${statefulset}"
  kubectl -n "$namespace" rollout status "statefulset/${statefulset}" --timeout=10m
}

wait_for_resource() {
  local namespace="$1"
  local resource="$2"
  local attempt

  for attempt in {1..60}; do
    kubectl -n "$namespace" get "$resource" >/dev/null 2>&1 && return 0
    sleep 5
  done
  fail "El recurso ${resource} no apareció en el namespace ${namespace}."
}

create_registry_secret() {
  local namespace="$1"

  kubectl create namespace "$namespace" --dry-run=client -o yaml | kubectl apply -f -
  kubectl -n "$namespace" create secret generic harbor-registry-secret \
    --from-file=.dockerconfigjson="${DOCKER_CONFIG}/config.json" \
    --type=kubernetes.io/dockerconfigjson \
    --dry-run=client -o yaml | kubectl apply -f -
}

push_images() {
  local tags="$1"
  local tag

  log "Autenticando Docker en Harbor"
  printf '%s' "$HARBOR_PASSWORD" | docker login "$HARBOR_URL" \
    --username "$HARBOR_USERNAME" --password-stdin

  log "Construyendo imágenes"
  docker build -t "${HARBOR_URL}/${HARBOR_PROJECT}/frontend:bootstrap" \
    "${ROOT_DIR}/apps/frontend"
  docker build -t "${HARBOR_URL}/${HARBOR_PROJECT}/backend:bootstrap" \
    "${ROOT_DIR}/apps/backend"

  IFS=',' read -r -a tag_list <<< "$tags"
  for tag in "${tag_list[@]}"; do
    tag="${tag//[[:space:]]/}"
    [[ -n "$tag" ]] || continue

    log "Publicando frontend y backend con la etiqueta ${tag}"
    docker tag "${HARBOR_URL}/${HARBOR_PROJECT}/frontend:bootstrap" \
      "${HARBOR_URL}/${HARBOR_PROJECT}/frontend:${tag}"
    docker tag "${HARBOR_URL}/${HARBOR_PROJECT}/backend:bootstrap" \
      "${HARBOR_URL}/${HARBOR_PROJECT}/backend:${tag}"
    docker push "${HARBOR_URL}/${HARBOR_PROJECT}/frontend:${tag}"
    docker push "${HARBOR_URL}/${HARBOR_PROJECT}/backend:${tag}"
  done
}

require_command kubectl
require_command docker
require_command curl

cleanup() {
  rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

export DOCKER_CONFIG="${TEMP_DIR}/docker-config"
mkdir -p "$DOCKER_CONFIG"

kubectl cluster-info >/dev/null || fail "kubectl no puede conectarse al clúster actual."

if [[ "$INSTALL_ARGOCD" == "true" ]]; then
  log "Instalando o actualizando Argo CD"
  kubectl create namespace "$ARGOCD_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
  kubectl apply -n "$ARGOCD_NAMESPACE" \
    -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
  wait_for_deployment "$ARGOCD_NAMESPACE" argocd-server
fi

if [[ -z "$HARBOR_PASSWORD" ]]; then
  read -r -s -p "Contraseña de Harbor para ${HARBOR_USERNAME}: " HARBOR_PASSWORD
  printf '\n'
fi
[[ -n "$HARBOR_PASSWORD" ]] || fail "HARBOR_PASSWORD no puede estar vacía."

log "Creando la Application de Harbor"
kubectl apply -f "${ROOT_DIR}/argocd/application-harbor.yaml"
wait_for_deployment "$HARBOR_NAMESPACE" gitops-harbor-core
wait_for_deployment "$HARBOR_NAMESPACE" gitops-harbor-portal
wait_for_statefulset "$HARBOR_NAMESPACE" gitops-harbor-database

log "Esperando la API de Harbor"
for attempt in {1..30}; do
  if curl --silent --fail "http://${HARBOR_URL}/api/v2.0/health" >/dev/null; then
    break
  fi
  [[ "$attempt" -eq 30 ]] && fail "Harbor no respondió en http://${HARBOR_URL}."
  sleep 5
done

log "Creando el proyecto ${HARBOR_PROJECT} si todavía no existe"
auth_file="${TEMP_DIR}/harbor.netrc"
umask 077
printf 'machine %s\nlogin %s\npassword %s\n' "${HARBOR_URL%%:*}" "$HARBOR_USERNAME" "$HARBOR_PASSWORD" > "$auth_file"
project_status="$(curl --silent --output /dev/null --write-out '%{http_code}' \
  --netrc-file "$auth_file" \
  -H 'Content-Type: application/json' \
  --request POST "http://${HARBOR_URL}/api/v2.0/projects" \
  --data "{\"project_name\":\"${HARBOR_PROJECT}\",\"metadata\":{\"public\":\"true\"}}")"
[[ "$project_status" == "201" || "$project_status" == "409" ]] || \
  fail "No se pudo crear el proyecto Harbor (HTTP ${project_status})."

push_images "$IMAGE_TAGS"

log "Creando imagePullSecrets para dev y prod"
create_registry_secret dev
create_registry_secret prod

log "Aplicando el ApplicationSet de microservicios"
kubectl apply -f "${ROOT_DIR}/argocd/applicationset.yaml"

log "Esperando los componentes del entorno dev"
wait_for_statefulset dev postgres
wait_for_deployment dev backend
wait_for_deployment dev frontend

cat <<EOF

Bootstrap completado.

Harbor:   http://${HARBOR_URL}
Argo CD:  kubectl port-forward svc/argocd-server -n argocd 8080:443
Frontend: kubectl get svc frontend-service -n dev

Las imágenes publicadas usan las etiquetas: ${IMAGE_TAGS}
EOF
