#!/usr/bin/env bash
# ==============================================================================
# Helper para Port-Forwarding Local (Paso 4 de la documentación)
# Mantiene accesibles Harbor y Argo CD en localhost
# ==============================================================================
set -euo pipefail

# Colores
CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${CYAN}====================================================================${NC}"
echo -e "${CYAN} Iniciando Port-Forwards para Harbor y Argo CD                       ${NC}"
echo -e "${CYAN}====================================================================${NC}"
echo -e "Harbor:  ${GREEN}http://harbor.local:30002${NC} (admin / HarborAdmin123!)"
echo -e "Argo CD: ${GREEN}https://localhost:8080${NC}   (admin)"
echo -e "\nPresiona Ctrl+C para detener ambos reenvíos de puertos.\n"

trap 'kill $(jobs -p) 2>/dev/null || true; echo -e "\n${YELLOW}Port-forwards detenidos.${NC}"; exit 0' SIGINT SIGTERM EXIT

# Port-forward Harbor (svc/harbor puerto 80 -> host 30002)
kubectl port-forward svc/harbor -n harbor 30002:80 >/dev/null 2>&1 &

# Port-forward Argo CD (svc/argocd-server puerto 443 -> host 8080)
kubectl port-forward svc/argocd-server -n argocd 8080:443 >/dev/null 2>&1 &

# Esperar a que los procesos en segundo plano finalicen
wait
