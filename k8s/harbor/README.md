# Guía de Despliegue y Uso de Harbor con Kubernetes y GitOps

Esta carpeta contiene la configuración para desplegar **Harbor** dentro de Kubernetes y gestionarlo mediante GitOps (ArgoCD) o Helm.

---

## 1. Despliegue con ArgoCD

Si ya tienes ArgoCD instalado en tu clúster:
```bash
kubectl apply -f argocd/application-harbor.yaml
```
ArgoCD creará el namespace `harbor` y desplegará todos los componentes (Core, Portal, Database, Redis, Trivy, Registry).

---

## 2. Despliegue alternativo manual con Helm

Si prefieres desplegarlo manualmente con Helm:
```bash
# 1. Agregar el repositorio oficial de Harbor
helm repo add harbor https://helm.goharbor.io
helm repo update

# 2. Instalar el chart con nuestros values
helm install harbor harbor/harbor \
  --namespace harbor \
  --create-namespace \
  -f k8s/harbor/values.yaml
```

---

## 3. Acceso a Harbor

Con los valores definidos en `k8s/harbor/values.yaml`:
- **URL**: `http://harbor.local:30002` (o `http://<IP_DEL_NODO_K8S>:30002`)
- **Usuario**: `admin`
- **Contraseña**: `HarborAdmin123!`

> [!TIP]
> Si estás en un clúster local (Minikube / Kind), agrega la siguiente línea a tu archivo `/etc/hosts` en tu máquina:
> ```
> 127.0.0.1 harbor.local
> ```
> (En Minikube también puedes ejecutar `minikube service harbor -n harbor` o usar un port-forward).

---

## 4. Pasos iniciales en la interfaz de Harbor

1. Inicia sesión como `admin`.
2. Crea un nuevo proyecto llamado **`gitops`** (hazlo público o privado según tu preferencia).
3. Si es privado, ve a **Projects > gitops > Robot Accounts** y genera una cuenta robot con permisos de lectura/escritura (Pull / Push).

---

## 5. Configuración de Insecure Registry en Docker local (si usas HTTP)

Dado que Harbor está configurado en HTTP (`:30002`) para desarrollo local, debes indicarle a tu Docker local que permita registros HTTP no seguros:
Edita `/etc/docker/daemon.json`:
```json
{
  "insecure-registries": ["harbor.local:30002", "localhost:30002"]
}
```
Y reinicia Docker:
```bash
sudo systemctl restart docker
```

---

## 6. Autenticación de Kubernetes (`imagePullSecrets`)

Para que los pods de `frontend` y `backend` descarguen imágenes de Harbor en Kubernetes:
```bash
kubectl apply -f k8s/common/harbor-secret.yaml
```
O créalo directamente con el CLI:
```bash
kubectl create secret docker-registry harbor-registry-secret \
  --docker-server=harbor.local:30002 \
  --docker-username=admin \
  --docker-password='HarborAdmin123!' \
  --namespace=default
```

