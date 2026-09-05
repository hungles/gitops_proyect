# Guía Completa de ArgoCD: Instalación, Componentes y Despliegues GitOps

Este documento proporciona una guía paso a paso para instalar **ArgoCD** en tu clúster de Kubernetes, una explicación detallada de cada uno de sus componentes internos y la documentación de las aplicaciones configuradas en este repositorio.

---

## Tabla de Contenidos
1. [Guía de Instalación en el Clúster](#1-guía-de-instalación-en-el-clúster)
   - [Paso 1: Crear Namespace](#paso-1-crear-el-namespace)
   - [Paso 2: Aplicar Manifiestos Oficiales](#paso-2-aplicar-los-manifiestos-oficiales)
   - [Paso 3: Verificar la Instalación](#paso-3-verificar-la-instalación)
   - [Paso 4: Acceder a la Interfaz Web (UI)](#paso-4-acceder-a-la-interfaz-web-ui)
   - [Paso 5: Obtener la Contraseña de Administrador](#paso-5-obtener-la-contraseña-de-administrador)
   - [Paso 6: (Opcional) Instalar y usar el CLI de ArgoCD](#paso-6-opcional-instalar-el-cli-de-argocd)
2. [Arquitectura y Componentes Internos de ArgoCD](#2-arquitectura-y-componentes-internos-de-argocd)
   - [argocd-server](#argocd-server)
   - [argocd-repo-server](#argocd-repo-server)
   - [argocd-application-controller](#argocd-application-controller)
   - [argocd-dex-server](#argocd-dex-server)
   - [argocd-redis](#argocd-redis)
   - [argocd-notifications-controller](#argocd-notifications-controller)
3. [Conceptos Fundamentales y CRDs](#3-conceptos-fundamentales-y-crds)
   - [Application](#application)
   - [AppProject](#appproject)
   - [ApplicationSet](#applicationset)
4. [Componentes del Proyecto GitOps (Nuestras Aplicaciones)](#4-componentes-del-proyecto-gitops-nuestras-aplicaciones)
   - [gitops-database](#1-gitops-database)
   - [gitops-backend](#2-gitops-backend)
   - [gitops-frontend](#3-gitops-frontend)
   - [gitops-harbor](#4-gitops-harbor)
5. [Comandos Frecuentes y Troubleshooting](#5-comandos-frecuentes-y-troubleshooting)

---

## 1. Guía de Instalación en el Clúster

### Prerrequisitos
- Un clúster de Kubernetes activo (Minikube, Kind, k3s, EKS, GKE, AKS o Bare-metal).
- Herramienta `kubectl` configurada con permisos de administrador (`cluster-admin`).

### Paso 1: Crear el Namespace
ArgoCD se ejecuta habitualmente en un namespace dedicado llamado `argocd`:
```bash
kubectl create namespace argocd
```

### Paso 2: Aplicar los Manifiestos Oficiales
Aplica la versión estable oficial más reciente de ArgoCD:
```bash
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
```

> [!NOTE]
> Para entornos con alta disponibilidad (HA) en producción, se recomienda usar el manifiesto `ha/install.yaml`. Para entornos locales o de desarrollo, `install.yaml` es ideal.

### Paso 3: Verificar la Instalación
Espera a que todos los pods alcancen el estado `Running`:
```bash
kubectl get pods -n argocd -w
```
Deberías ver componentes como `argocd-server`, `argocd-repo-server`, `argocd-application-controller`, `argocd-redis`, etc.

### Paso 4: Acceder a la Interfaz Web (UI)

#### Método A: Port-Forward (Recomendado para pruebas locales / desarrollo)
```bash
kubectl port-forward svc/argocd-server -n argocd 8080:443
```
Luego abre tu navegador en: [https://localhost:8080](https://localhost:8080).
*(Acepta la advertencia de certificado autofirmado SSL).*

#### Método B: Cambiar el servicio a NodePort
```bash
kubectl patch svc argocd-server -n argocd -p '{"spec": {"type": "NodePort"}}'
```
Y consulta el puerto asignado con:
```bash
kubectl get svc argocd-server -n argocd
```

### Paso 5: Obtener la Contraseña de Administrador
El usuario por defecto es `admin`. La contraseña inicial se genera automáticamente en un Secret:
```bash
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d; echo
```
Copia esa contraseña e inicia sesión en la interfaz web.

> [!TIP]
> Una vez que inicies sesión, se recomienda cambiar la contraseña desde la interfaz en **User Info > Update Password** o mediante el CLI. Tras cambiarla, puedes eliminar el Secret inicial:
> ```bash
> kubectl -n argocd delete secret argocd-initial-admin-secret
> ```

### Paso 6: (Opcional) Instalar el CLI de ArgoCD
En Linux:
```bash
curl -sSL -o argocd-linux-amd64 https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-amd64
sudo install -m 555 argocd-linux-amd64 /usr/local/bin/argocd
rm argocd-linux-amd64
```
Iniciar sesión mediante CLI:
```bash
argocd login localhost:8080 --username admin --insecure
```

---

## 2. Arquitectura y Componentes Internos de ArgoCD

ArgoCD sigue el patrón de controlador de Kubernetes para implementar **GitOps**, manteniendo sincronizado el estado real del clúster con el estado deseado declarado en Git.

```
       +------------------------------------------------------------+
       |                        Usuario / UI                        |
       +------------------------------------------------------------+
                                     |
                                     v
       +------------------------------------------------------------+
       |                       argocd-server                        |
       |             (API gRPC/REST, UI, Autenticación)             |
       +------------------------------------------------------------+
                               |            ^
                               v            |
    +------------------------------+    +---------------------------+
    | argocd-application-controller|    |     argocd-repo-server    |
    |  (Reconciliación GitOps)     |<-->|  (Clonación Git, Helm,    |
    +------------------------------+    |   Kustomize, Manifiestos) |
                   |                    +---------------------------+
                   v                                  ^
       +-----------------------+                      |
       |  Kubernetes API Server|                      v
       |   (Estado en Vivo)    |             +------------------+
       +-----------------------+             |   argocd-redis   |
                                             |  (Caché de datos)|
                                             +------------------+
```

### `argocd-server`
- **Función**: Es el servidor de API central. Expone tanto una API gRPC como una API REST utilizada por la UI web, el CLI de ArgoCD y sistemas externos de CI/CD.
- **Responsabilidades**:
  - Autenticación y autorización de usuarios (RBAC).
  - Gestión de credenciales de repositorios y clústeres.
  - Recepción de webhooks de Git (GitHub, GitLab, Bitbucket) para forzar sincronizaciones instantáneas sin esperar el ciclo de sondeo periódico.
  - Invocación de operaciones manuales como `Sync`, `Rollback` y visualización de logs de pods.

### `argocd-repo-server`
- **Función**: Servicio interno dedicado a interactuar con los repositorios Git y Helm.
- **Responsabilidades**:
  - Clona y mantiene copias locales en caché de los repositorios Git declarados.
  - Interpreta y renderiza plantillas de herramientas como **Helm**, **Kustomize**, **Ksonnet** o manifiestos YAML estándar.
  - Devuelve los manifiestos de Kubernetes en formato puro a los demás componentes para su comparación y aplicación.

### `argocd-application-controller`
- **Función**: Es el cerebro y motor de reconciliación de ArgoCD. Es un operador de Kubernetes que ejecuta un ciclo de control continuo (Control Loop).
- **Responsabilidades**:
  - Monitorea continuamente las aplicaciones (`Application` CRDs).
  - Compara el **estado vivo** (lo que realmente está corriendo en el clúster) contra el **estado deseado** (obtenido del `repo-server` desde Git).
  - Detecta desviaciones (*Out of Sync* o *Drift*).
  - Si la política `automated.selfHeal` está activa, corrige automáticamente cualquier cambio manual en el clúster restaurando lo definido en Git.
  - Aplica políticas de poda (`automated.prune`), eliminando recursos en el clúster que hayan sido borrados de Git.

### `argocd-dex-server`
- **Función**: Servidor de identidad y autenticación OpenID Connect (OIDC).
- **Responsabilidades**:
  - Facilita la integración con proveedores de identidad externos como GitHub, Google, GitLab, Keycloak, SAML o LDAP para inicio de sesión único (SSO).

### `argocd-redis`
- **Función**: Servicio de almacenamiento en memoria de alta velocidad.
- **Responsabilidades**:
  - Almacena en caché el estado de los repositorios Git, tokens de sesión y resultados de renderizado de manifiestos, evitando sobrecargar los repositorios externos y acelerando la reconciliación.

### `argocd-notifications-controller`
- **Función**: Módulo opcional pero muy utilizado para el envío de alertas y notificaciones.
- **Responsabilidades**:
  - Envía notificaciones ante eventos del ciclo de vida de las aplicaciones (éxito en la sincronización, fallos, cambio de estado de salud) hacia canales como Slack, Discord, Microsoft Teams, correo electrónico o Webhooks personalizados.

---

## 3. Conceptos Fundamentales y CRDs

ArgoCD introduce Custom Resource Definitions (CRDs) en Kubernetes:

### `Application`
Representa un grupo de recursos de Kubernetes administrados como una unidad lógica. Define:
- **`source`**: De dónde provienen los manifiestos (URL del repositorio Git/Helm, rama/revisión y ruta en el repositorio).
- **`destination`**: A qué clúster y namespace deben desplegarse los recursos.
- **`syncPolicy`**: Cómo debe comportarse la sincronización (`automated`, `selfHeal`, `prune`, `syncOptions`).

### `AppProject`
Proporciona un mecanismo de aislamiento y gobernanza (*multi-tenancy*). Permite delimitar:
- Qué repositorios Git pueden ser consumidos.
- A qué clústeres y namespaces se puede desplegar.
- Qué tipos de recursos de Kubernetes (`Kind`) están permitidos o denegados.
- Roles de usuario y permisos RBAC específicos para el proyecto.

### `ApplicationSet`
Controlador que automatiza la creación masiva y dinámica de recursos `Application`. Es ideal para patrones como:
- Desplegar una aplicación en múltiples clústeres simultáneamente.
- Monitorear múltiples ramas o carpetas de un monorepo para crear entornos dinámicos por cada *Pull Request*.

---

## 4. Componentes del Proyecto GitOps (Nuestras Aplicaciones)

En este repositorio, la gestión de despliegues se realiza de forma **dinámica y automatizada**:

```
argocd/
├── applicationset.yaml     # Generador dinámico para Microservicios (Dev / Prod)
├── application-harbor.yaml # Registro de Contenedores Harbor (Helm Multi-source)
└── README.md               # Esta documentación
```

### 1. `gitops-microservices` (ApplicationSet)
* **Archivo**: [`argocd/applicationset.yaml`](file:///home/scarmona/git/gitops_proyect/argocd/applicationset.yaml)
* **Tipo**: Generador Dinámico de Aplicaciones (`ApplicationSet`).
* **Responsabilidad**: Genera dinámicamente dos aplicaciones independientes en ArgoCD:
  1. **`gitops-stack-dev`**:
     - Rastrea la rama **`dev`**.
     - Despliega el overlay Kustomize **`k8s/environments/dev`**.
     - Namespace de destino: **`dev`** (1 réplica, variables de desarrollo).
  2. **`gitops-stack-prod`**:
     - Rastrea la rama **`main`**.
     - Despliega el overlay Kustomize **`k8s/environments/prod`**.
     - Namespace de destino: **`prod`** (3 réplicas, límites de CPU/RAM, alta disponibilidad).
* **Componentes que despliega en cada entorno**:
  - **Base de Datos**: StatefulSet de PostgreSQL, PVC persistente, Service y Secret.
  - **Backend**: Deployment de Node.js/Express, ConfigMap, Service e `imagePullSecrets`.
  - **Frontend**: Deployment de React + Nginx y Service NodePort.

### 2. `gitops-harbor`
* **Archivo**: [`argocd/application-harbor.yaml`](file:///home/scarmona/git/gitops_proyect/argocd/application-harbor.yaml)
* **Tipo**: Aplicación Multi-source (Helm Chart oficial de Harbor + valores personalizados en Git).
* **Namespace de destino**: `harbor`
* **Componentes que despliega**:
  - Registro de imágenes privado Harbor (Portal, Core, Jobservice, Registry, Database, Redis, Trivy).
  - Expuesto vía `NodePort` en los puertos `30002` (HTTP) y `30003` (HTTPS).

---

## 5. Comandos Frecuentes y Troubleshooting

### Desplegar todas las aplicaciones en ArgoCD
```bash
# Aplicar todos los manifiestos de aplicaciones a la vez
kubectl apply -f argocd/
```

### Listar aplicaciones y su estado con el CLI
```bash
argocd app list
```

### Forzar la sincronización manual de una aplicación
```bash
argocd app sync gitops-backend
```

### Ver el árbol de recursos y salud de una aplicación
```bash
argocd app get gitops-database
```

### Solución a problemas comunes:
* **Estado `OutOfSync` persistente**: Revisa si algún recurso en Kubernetes tiene campos mutados por un controlador de admisión (admission webhook) o si faltan permisos de RBAC.
* **Error de conexión con Git**: Verifica que la URL del repositorio en `repoURL` sea accesible y pública, o agrega las credenciales SSH/Token en ArgoCD bajo **Settings > Repositories**.
* **Auto-sync no detecta cambios inmediatos**: ArgoCD sondea Git cada 3 minutos por defecto. Puedes hacer clic en **Refresh** en la UI, ejecutar `argocd app get <nombre> --refresh`, o configurar un Webhook en tu repositorio de GitHub apuntando a `/api/webhook` de ArgoCD.

