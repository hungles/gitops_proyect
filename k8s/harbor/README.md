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
> (En Minikube también puedes ejecutar `minikube service harbor -n harbor`.)

### Acceso mediante port-forward

Para acceder desde tu máquina sin exponer el `NodePort`, reenvía el servicio
externo de Harbor (`harbor`). No uses el servicio interno `gitops-harbor-portal`:

```bash
kubectl port-forward svc/harbor -n harbor 30002:80
```

Mantén el comando en ejecución y abre `http://harbor.local:30002`. La entrada
`127.0.0.1 harbor.local` en `/etc/hosts` es necesaria porque coincide con el
valor `externalURL` configurado en `values.yaml`.

> [!NOTE]
> `harborAdminPassword` define la contraseña inicial de `admin`. Si el usuario
> cambia la contraseña en la interfaz, el valor del archivo no se actualiza y
> no puede utilizarse para consultar la contraseña actual.

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

> [!IMPORTANT]
> Esta configuración solo afecta al Docker del host. Si Kubernetes usa
> `containerd` (por ejemplo, Kind), el runtime del nodo también debe tener un
> `certs.d` configurado para `harbor.local:30002`. El script
> `scripts/bootstrap-local.sh` lo configura automáticamente para nodos Kind.

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
