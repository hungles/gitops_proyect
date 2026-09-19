#!/usr/bin/env bash
# ==============================================================================
# Script de Automatización para el Primer Despliegue Local (GitOps Stack)
# Basado estrictamente en la guía oficial de README.md
# ==============================================================================
set -euo pipefail

# Asegurar que el script se ejecute siempre desde la raíz del repositorio
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_ROOT}"

# Colores para salida de consola
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_step() {
    echo -e "\n${CYAN}====================================================================${NC}"
    echo -e "${CYAN} $1 ${NC}"
    echo -e "${CYAN}====================================================================${NC}"
}

# Comprobar herramientas requeridas
check_prerequisites() {
    log_info "Verificando dependencias necesarias (docker, kubectl, git, curl)..."
    for tool in docker kubectl git curl; do
        if ! command -v "$tool" &> /dev/null; then
            log_error "Herramienta requerida no encontrada: $tool. Por favor instálala antes de continuar."
            exit 1
        fi
    done
    log_success "Todas las herramientas necesarias están disponibles."
}

# ==============================================================================
# Paso 1: Configuración del Host Local (Docker y DNS)
# ==============================================================================
step1_host_setup() {
    log_step "Paso 1: Configuración del Host Local (Docker y DNS)"

    # 1.1 DNS en /etc/hosts
    log_info "1. Verificando entrada 'harbor.local' en /etc/hosts..."
    if grep -q "harbor.local" /etc/hosts; then
        log_success "'harbor.local' ya existe en /etc/hosts."
    else
        log_info "Agregando '127.0.0.1 harbor.local' a /etc/hosts (requiere sudo)..."
        echo "127.0.0.1 harbor.local" | sudo tee -a /etc/hosts > /dev/null
        log_success "Entrada añadida a /etc/hosts."
    fi

    # 1.2 Insecure Registries en /etc/docker/daemon.json
    log_info "2. Configurando 'insecure-registries' en /etc/docker/daemon.json..."
    REGISTRIES='["harbor.local:30002", "localhost:30002", "127.0.0.1:30002"]'
    
    python3 - <<EOF
import json, os, subprocess

daemon_path = "/etc/docker/daemon.json"
data = {}
modified = False

if os.path.exists(daemon_path):
    try:
        with open(daemon_path, "r") as f:
            data = json.load(f)
    except Exception:
        data = {}

current_insecure = data.get("insecure-registries", [])
targets = ["harbor.local:30002", "localhost:30002", "127.0.0.1:30002"]

for reg in targets:
    if reg not in current_insecure:
        current_insecure.append(reg)
        modified = True

if modified or "insecure-registries" not in data:
    data["insecure-registries"] = current_insecure
    # Guardar en archivo temporal y mover con sudo
    with open("/tmp/daemon.json.tmp", "w") as f:
        json.dump(data, f, indent=2)
    subprocess.run(["sudo", "mv", "/tmp/daemon.json.tmp", daemon_path], check=True)
    subprocess.run(["sudo", "chmod", "644", daemon_path], check=True)
    print("RESTART_DOCKER")
else:
    print("ALREADY_CONFIGURED")
EOF

    # Si se modificó la configuración, reiniciar docker
    if python3 -c '
import json, os
p = "/etc/docker/daemon.json"
if os.path.exists(p):
    with open(p) as f:
        d = json.load(f)
    regs = d.get("insecure-registries", [])
    if all(x in regs for x in ["harbor.local:30002", "localhost:30002", "127.0.0.1:30002"]):
        print("OK")
' | grep -q "OK"; then
        log_success "daemon.json configurado correctamente con insecure-registries."
    else
        log_warn "Asegúrate de reiniciar Docker si se realizaron cambios: sudo systemctl restart docker"
    fi
}

# ==============================================================================
# Paso 2: Instalación de Argo CD en el Clúster
# ==============================================================================
step2_install_argocd() {
    log_step "Paso 2: Instalación de Argo CD en el Clúster"

    log_info "1. Creando namespace 'argocd'..."
    kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -

    log_info "2. Aplicando manifiestos oficiales de Argo CD con Server-Side Apply..."
    kubectl apply -n argocd --server-side --force-conflicts -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

    log_info "3. Aplicando CRDs de Argo CD con Server-Side Apply..."
    kubectl apply --server-side --force-conflicts -k https://github.com/argoproj/argo-cd/manifests/crds?ref=stable

    log_info "Esperando que el despliegue de argocd-server esté listo..."
    kubectl rollout status deployment/argocd-server -n argocd --timeout=300s || true

    log_info "4. Obteniendo la contraseña inicial de 'admin' de Argo CD..."
    if kubectl -n argocd get secret argocd-initial-admin-secret &>/dev/null; then
        ARGOCD_PASS=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)
        echo -e "${GREEN}Contraseña inicial de Argo CD (admin):${NC} $ARGOCD_PASS"
    else
        log_info "El secreto argocd-initial-admin-secret ya no existe (probablemente la contraseña ya fue modificada)."
    fi
}

# ==============================================================================
# Paso 3: Despliegue de Harbor mediante Argo CD
# ==============================================================================
step3_deploy_harbor() {
    log_step "Paso 3: Despliegue de Harbor mediante Argo CD"

    log_info "1. Verificando rama 'harbor' en Git..."
    CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
    if git show-ref --verify --quiet refs/heads/harbor; then
        log_info "La rama 'harbor' existe localmente."
    else
        log_info "Creando rama 'harbor'..."
        git branch harbor
    fi

    log_info "Intentando publicar la rama 'harbor' en remoto (si hay acceso)..."
    git push origin harbor 2>/dev/null || log_warn "No se pudo hacer push de 'harbor' a origin. Si estás en local sin remoto configurado, puedes ignorar esta advertencia."

    log_info "2. Aplicando Application de Harbor en Argo CD..."
    kubectl apply -f argocd/application-harbor.yaml

    log_info "3. Esperando que los pods de Harbor se inicialicen (esto puede tomar 2-3 minutos)..."
    log_info "Comprobando namespace 'harbor'..."
    for i in {1..30}; do
        if kubectl get namespace harbor &>/dev/null; then
            break
        fi
        sleep 5
    done

    log_info "Esperando despliegue de componentes clave de Harbor (core, portal, registry)..."
    kubectl rollout status deployment/gitops-harbor-core -n harbor --timeout=300s 2>/dev/null || true
    kubectl rollout status deployment/gitops-harbor-portal -n harbor --timeout=300s 2>/dev/null || true
    kubectl rollout status deployment/gitops-harbor-registry -n harbor --timeout=300s 2>/dev/null || true

    log_success "Manifiesto de Harbor aplicado en Argo CD."
}

# ==============================================================================
# Paso 4: Verificación / Inicio de Port-Forwarding para Harbor
# ==============================================================================
step4_port_forward_check() {
    log_step "Paso 4: Verificación de acceso a Harbor (puerto 30002)"

    log_info "Verificando si el puerto 30002 responde en harbor.local..."
    if curl -sI http://harbor.local:30002 >/dev/null 2>&1 || nc -z 127.0.0.1 30002 2>/dev/null; then
        log_success "El puerto 30002 ya está activo y respondiendo."
    else
        log_warn "Puerto 30002 no está accesible directamente. Iniciando port-forward de Harbor en segundo plano..."
        nohup kubectl port-forward svc/harbor -n harbor 30002:80 > /tmp/harbor-portforward.log 2>&1 &
        sleep 5
        if curl -sI http://harbor.local:30002 >/dev/null 2>&1; then
            log_success "Port-forward iniciado en segundo plano (PID: $!)."
        else
            log_warn "Asegúrate de ejecutar en otra terminal: kubectl port-forward svc/harbor -n harbor 30002:80"
        fi
    fi
}

# ==============================================================================
# Paso 5: Configurar Proyecto en Harbor y Subir Imágenes Locales
# ==============================================================================
step5_build_and_push_images() {
    log_step "Paso 5: Configuración del Proyecto en Harbor y Subida de Imágenes Locales"

    HARBOR_URL="harbor.local:30002"
    HARBOR_USER="admin"
    HARBOR_PASS="HarborAdmin123!"
    PROJECT="gitops"

    log_info "1. Creando proyecto '$PROJECT' en Harbor vía API REST..."
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -u "${HARBOR_USER}:${HARBOR_PASS}" \
        -X POST "http://${HARBOR_URL}/api/v2.0/projects" \
        -H "Content-Type: application/json" \
        -d "{\"project_name\": \"${PROJECT}\", \"public\": true}" || echo "000")

    if [ "$HTTP_CODE" = "201" ]; then
        log_success "Proyecto '$PROJECT' creado exitosamente en Harbor."
    elif [ "$HTTP_CODE" = "409" ]; then
        log_info "El proyecto '$PROJECT' ya existe en Harbor."
    else
        log_warn "Respuesta API al crear proyecto: HTTP $HTTP_CODE (verifica credenciales o interfaz web)."
    fi

    log_info "2. Iniciando sesión en Docker local contra Harbor ($HARBOR_URL)..."
    echo "$HARBOR_PASS" | docker login "$HARBOR_URL" -u "$HARBOR_USER" --password-stdin

    log_info "3. Construyendo y subiendo imagen de Backend (tag :dev)..."
    docker build -t "${HARBOR_URL}/${PROJECT}/backend:dev" ./apps/backend
    docker push "${HARBOR_URL}/${PROJECT}/backend:dev"

    log_info "4. Construyendo y subiendo imagen de Frontend (tag :dev)..."
    docker build -t "${HARBOR_URL}/${PROJECT}/frontend:dev" ./apps/frontend
    docker push "${HARBOR_URL}/${PROJECT}/frontend:dev"

    log_success "Imágenes :dev construidas y publicadas en Harbor."
}

# ==============================================================================
# Paso 6: Configuración del Runtime de Kubernetes (containerd)
# ==============================================================================
step6_configure_runtime() {
    log_step "Paso 6: Configuración del Runtime de Kubernetes (containerd)"

    # Comprobación de Kind
    if docker ps --format '{{.Names}}' | grep -q "kind-control-plane"; then
        log_info "Detectado clúster KinD (kind-control-plane). Configurando containerd certs.d..."
        docker exec kind-control-plane mkdir -p /etc/containerd/certs.d/harbor.local:30002
        docker exec kind-control-plane sh -c 'cat > /etc/containerd/certs.d/harbor.local:30002/hosts.toml <<EOF
server = "http://harbor.local:30002"
[host."http://harbor.local:30002"]
  capabilities = ["pull", "resolve", "push"]
  skip_verify = true
EOF'
        docker exec kind-control-plane systemctl restart containerd
        log_success "containerd configurado y reiniciado en kind-control-plane."
    elif command -v minikube &>/dev/null && minikube status &>/dev/null; then
        log_info "Detectado clúster Minikube. Configurando containerd en Minikube..."
        minikube ssh "sudo mkdir -p /etc/containerd/certs.d/harbor.local:30002 && sudo tee /etc/containerd/certs.d/harbor.local:30002/hosts.toml <<EOF
server = \"http://harbor.local:30002\"
[host.\"http://harbor.local:30002\"]
  capabilities = [\"pull\", \"resolve\", \"push\"]
  skip_verify = true
EOF
sudo systemctl restart containerd"
        log_success "containerd configurado y reiniciado en Minikube."
    else
        log_warn "No se detectó Kind ni Minikube automáticamente. Consulta el Paso 6 del README.md si los pods fallan con error HTTPS."
    fi
}

# ==============================================================================
# Paso 7: Crear Secreto de Autenticación (imagePullSecrets)
# ==============================================================================
step7_create_pull_secrets() {
    log_step "Paso 7: Crear el Secreto de Autenticación (imagePullSecrets)"

    for ENV in dev prod; do
        log_info "Creando namespace y secreto para entorno: '$ENV'..."
        kubectl create namespace "$ENV" --dry-run=client -o yaml | kubectl apply -f -
        
        kubectl create secret docker-registry harbor-registry-secret \
            --docker-server=harbor.local:30002 \
            --docker-username=admin \
            --docker-password='HarborAdmin123!' \
            --namespace="$ENV" \
            --dry-run=client -o yaml | kubectl apply -f -
    done
    log_success "Secretos 'harbor-registry-secret' creados en namespaces 'dev' y 'prod'."
}

# ==============================================================================
# Paso 8: Desplegar Microservicios con el ApplicationSet
# ==============================================================================
step8_deploy_applicationset() {
    log_step "Paso 8: Desplegar Microservicios con el ApplicationSet"

    log_info "Aplicando generador ApplicationSet..."
    kubectl apply -f argocd/applicationset.yaml

    log_success "ApplicationSet aplicado exitosamente."
    
    echo -e "\n${GREEN}====================================================================${NC}"
    echo -e "${GREEN} ¡Despliegue inicial completado con éxito! ${NC}"
    echo -e "${GREEN}====================================================================${NC}"
    echo -e "Puedes verificar el estado con:"
    echo -e "  kubectl get applications -n argocd"
    echo -e "  kubectl get pods -n dev -w"
    echo -e ""
    echo -e "Accesos a las interfaces locales:"
    echo -e "  * Harbor:  http://harbor.local:30002 (admin / HarborAdmin123!)"
    echo -e "  * Argo CD: https://localhost:8080 (admin / <ver contraseña arriba>)"
    echo -e ""
    echo -e "Para mantener activos los accesos locales si no los tienes en segundo plano:"
    echo -e "  ./scripts/port-forward.sh"
    echo -e "===================================================================="
}

# ==============================================================================
# Flujo Principal
# ==============================================================================
main() {
    check_prerequisites
    step1_host_setup
    step2_install_argocd
    step3_deploy_harbor
    step4_port_forward_check
    step5_build_and_push_images
    step6_configure_runtime
    step7_create_pull_secrets
    step8_deploy_applicationset
}

main "$@"
