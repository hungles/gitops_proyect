# GitOps Local con Argo CD, Harbor y Microservicios

Proyecto demostrativo para implementar y practicar un flujo GitOps completo en un clúster local de Kubernetes:

```text
Código / Push → Docker Build & Push → Harbor (Registry Local :30002)
                                              ↓
Git (Kustomize: dev / prod) → Argo CD (ApplicationSet) → Kubernetes
```

Incluye una aplicación Frontend en **React**, una API Backend en **Node.js**, persistencia con **PostgreSQL**, **Harbor** como registro privado de contenedores y **Argo CD** como orquestador GitOps dinámico multi-entorno.

---

## Arquitectura del Repositorio

| Componente / Ruta | Descripción |
| :--- | :--- |
| **`apps/frontend`** | Código React (Vite) empaquetado en Nginx (proxy inverso a la API). |
| **`apps/backend`** | API REST en Node.js (Express) con conexión a PostgreSQL. |
| **`k8s/base`** | Manifiestos base comunes de Frontend, Backend y Database. |
| **`k8s/environments/dev`** | Overlay de Kustomize para Desarrollo (1 réplica, configs dev, tags `:dev`). |
| **`k8s/environments/prod`** | Overlay de Kustomize para Producción (3 réplicas, límites de CPU/RAM, tags `:prod`). |
| **`k8s/harbor`** | Configuración personalizada (`values.yaml`) para el chart oficial de Harbor. |
| **`argocd/applicationset.yaml`** | Generador dinámico que crea aplicaciones en Argo CD según entorno (`dev` o `prod`). |
| **`argocd/application-harbor.yaml`**| Aplicación de Argo CD que despliega Harbor desde su Helm Chart y la rama `harbor`. |
| **`.github/workflows/ci.yaml`** | Pipeline de CI para construir y publicar imágenes automáticamente. |

---

## Guía Paso a Paso para Desplegar el Proyecto

Sigue estos pasos manuales para poner en marcha todo el entorno en tu máquina y clúster local.

---

### Paso 1: Configuración del Host Local (Docker y DNS)

Dado que Harbor se ejecuta en local sobre HTTP (puerto `30002`) sin certificados SSL firmados, debes configurar la resolución de nombres y permitir que Docker se comunique con registros no seguros.

1. **Agregar entrada DNS en `/etc/hosts`**:
   ```bash
   echo "127.0.0.1 harbor.local" | sudo tee -a /etc/hosts
   ```
   *(Si utilizas Minikube con driver VM, reemplaza `127.0.0.1` por la IP arrojada por `minikube ip`)*.

2. **Habilitar Insecure Registry en Docker**:
   Edita o crea el archivo `/etc/docker/daemon.json` en tu sistema:
   ```json
   {
     "insecure-registries": ["harbor.local:30002", "localhost:30002", "127.0.0.1:30002"]
   }
   ```

3. **Reiniciar el servicio de Docker**:
   ```bash
   sudo systemctl restart docker
   ```

---

### Paso 2: Instalación de Argo CD en el Clúster

1. **Crear el namespace de Argo CD**:
   ```bash
   kubectl create namespace argocd
   ```

2. **Instalar Argo CD**:
   ```bash
   kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
   ```

3. **Instalar los CRDs con Server-Side Apply**:
   > [!IMPORTANT]
   > El CRD de `ApplicationSet` supera el límite de anotaciones de Kubernetes (256 KB). Por ello, es necesario aplicar los CRDs utilizando `--server-side`:
   ```bash
   kubectl apply --server-side -k https://github.com/argoproj/argo-cd/manifests/crds?ref=stable
   ```

4. **Obtener la contraseña inicial del usuario `admin`**:
   ```bash
   kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d; echo
   ```

---

### Paso 3: Despliegue de Harbor mediante Argo CD

Harbor está desacoplado del ciclo de las aplicaciones y rastrea su propia rama (`harbor`) en el repositorio.

1. **Asegurar la existencia de la rama `harbor` en Git**:
   ```bash
   git checkout -b harbor
   git push origin harbor
   git checkout dev
   ```

2. **Aplicar el manifiesto de Harbor en Argo CD**:
   ```bash
   kubectl apply -f argocd/application-harbor.yaml
   ```

3. **Verificar que los pods de Harbor estén listos**:
   ```bash
   kubectl get pods -n harbor -w
   ```
   *(Este proceso puede tardar un par de minutos mientras se descargan e inicializan Registry, Database, Redis, Core y Portal)*.

---

### Paso 4: Acceso Local mediante Port-Forwarding (Recomendado)

El método más robusto y universal para acceder tanto a Harbor como a Argo CD en entornos locales es mediante `kubectl port-forward`:

```bash
# Terminal 1: Port-forward para Harbor (expone en el puerto 30002)
kubectl port-forward svc/harbor -n harbor 30002:80

# Terminal 2: Port-forward para Argo CD (expone en el puerto 8080)
kubectl port-forward svc/argocd-server -n argocd 8080:443
```

#### Enlaces de Acceso y Credenciales:
* **Harbor**: [http://harbor.local:30002](http://harbor.local:30002)
  * **Usuario**: `admin`
  * **Contraseña**: `HarborAdmin123!` *(definida en `k8s/harbor/values.yaml`)*
* **Argo CD**: [https://localhost:8080](https://localhost:8080)
  * **Usuario**: `admin`
  * **Contraseña**: La obtenida en el Paso 2.

---

### Paso 5: Configurar el Proyecto en Harbor y Subir Imágenes Locales

1. Ingresa a la interfaz de Harbor ([http://harbor.local:30002](http://harbor.local:30002)).
2. Crea un nuevo proyecto llamado **`gitops`** (puedes marcarlo como público o privado).
3. **Inicia sesión en Harbor desde tu terminal**:
   ```bash
   docker login harbor.local:30002 -u admin -p 'HarborAdmin123!'
   ```
4. **Construir y subir las imágenes para el entorno `dev`**:
   ```bash
   # Backend
   docker build -t harbor.local:30002/gitops/backend:dev ./apps/backend
   docker push harbor.local:30002/gitops/backend:dev

   # Frontend
   docker build -t harbor.local:30002/gitops/frontend:dev ./apps/frontend
   docker push harbor.local:30002/gitops/frontend:dev
   ```
   *(Opcional: Si deseas probar el entorno de producción, puedes etiquetar y subir también como `:prod`)*.

---

### Paso 6: Configuración del Runtime de Kubernetes (containerd)

Si tu clúster es **Kind**, **Minikube** o **k3s**, el runtime interno del nodo (`containerd`) intentará descargar las imágenes por HTTPS por defecto. Si los pods arrojan el error `server gave HTTP response to HTTPS client`:

* **En Kind**:
  ```bash
  docker exec -it kind-control-plane bash
  mkdir -p /etc/containerd/certs.d/harbor.local:30002
  cat > /etc/containerd/certs.d/harbor.local:30002/hosts.toml <<EOF
  server = "http://harbor.local:30002"
  [host."http://harbor.local:30002"]
    capabilities = ["pull", "resolve", "push"]
    skip_verify = true
  EOF
  systemctl restart containerd
  exit
  ```
* **En Minikube**:
  ```bash
  minikube ssh
  sudo mkdir -p /etc/containerd/certs.d/harbor.local:30002
  sudo tee /etc/containerd/certs.d/harbor.local:30002/hosts.toml <<EOF
  server = "http://harbor.local:30002"
  [host."http://harbor.local:30002"]
    capabilities = ["pull", "resolve", "push"]
    skip_verify = true
  EOF
  sudo systemctl restart containerd
  exit
  ```

---

### Paso 7: Crear el Secreto de Autenticación (`imagePullSecrets`)

Para que Kubernetes descargue las imágenes desde Harbor en el namespace `dev`:

```bash
# Crear namespace dev si no existe
kubectl create namespace dev --dry-run=client -o yaml | kubectl apply -f -

# Crear el Secret para descargar imágenes
kubectl create secret docker-registry harbor-registry-secret \
  --docker-server=harbor.local:30002 \
  --docker-username=admin \
  --docker-password='HarborAdmin123!' \
  --namespace=dev
```
*(Para el entorno `prod`, repite el comando cambiando `--namespace=prod`)*.

---

### Paso 8: Desplegar Microservicios con el ApplicationSet

El archivo [`argocd/applicationset.yaml`](argocd/applicationset.yaml) generará dinámicamente dos aplicaciones:
* `gitops-stack-dev`: escucha la rama `dev` y despliega `k8s/environments/dev` en el namespace `dev`.
* `gitops-stack-prod`: escucha la rama `main` y despliega `k8s/environments/prod` en el namespace `prod`.

Asegúrate de haber subido los cambios a tu rama `dev`:
```bash
git add .
git commit -m "feat: setup dynamic multi-environment gitops"
git push origin dev
```

Y aplica el generador:
```bash
kubectl apply -f argocd/applicationset.yaml
```

Verifica en la UI de Argo CD ([https://localhost:8080](https://localhost:8080)) o por CLI:
```bash
kubectl get applications -n argocd
kubectl get pods -n dev -w
```

---

## Flujo de Trabajo y CI/CD

Cuando decidas automatizar la compilación mediante GitHub Actions:
1. Configura un **self-hosted runner** (ya que los runners públicos de GitHub no pueden acceder a tu `harbor.local:30002` privado).
2. Configura los siguientes secretos en tu repositorio de GitHub:
   * `HARBOR_URL`: `harbor.local:30002`
   * `HARBOR_USERNAME`: `admin`
   * `HARBOR_PASSWORD`: `HarborAdmin123!`
   * `HARBOR_PROJECT`: `gitops`
3. Cada push a `dev` compilará y subirá la imagen con el tag `:dev`, y cada push a `main` publicará con `:prod` y `:latest`. Argo CD detectará los cambios y actualizará el clúster automáticamente.
