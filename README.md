# GitOps local con Argo CD, Harbor y GitHub Actions

Proyecto demostrativo para practicar un flujo GitOps completo en un clúster local:

```text
Git push → GitHub Actions (self-hosted runner) → Harbor
                                           ↓
Git (manifiestos Kustomize) → Argo CD → Kubernetes
```

Incluye una aplicación React, una API Node.js, PostgreSQL, Harbor como registro
privado y Argo CD como reconciliador GitOps. Está pensado para aprendizaje y
portafolio; no es una configuración de producción.

## Arquitectura

| Componente | Responsabilidad |
| --- | --- |
| `apps/frontend` | Aplicación React servida con Nginx. |
| `apps/backend` | API Node.js conectada a PostgreSQL. |
| `k8s/base` | Manifiestos comunes de base de datos, backend y frontend. |
| `k8s/environments` | Overlays Kustomize para `dev` y `prod`. |
| Harbor | Almacena `gitops/frontend` y `gitops/backend`. |
| Argo CD | Sincroniza Git con el clúster y corrige drift. |
| GitHub Actions | Construye y publica imágenes desde un self-hosted runner local. |

El `ApplicationSet` genera dos aplicaciones: `gitops-stack-dev` desde la rama
`dev` y `gitops-stack-prod` desde `main`. Harbor obtiene su chart oficial desde
Helm y sus valores desde la rama `harbor`.

## Inicio rápido

### Prerrequisitos

- Un clúster Kubernetes local activo y seleccionado en `kubectl`.
- Docker instalado; debe permitir HTTP para `harbor.local:30002` como insecure
  registry.
- `kubectl`, `docker` y `curl` disponibles en el `PATH`.
- La entrada `127.0.0.1 harbor.local` en `/etc/hosts`.

El script solicita la contraseña de Harbor de forma interactiva. También se
puede proporcionar por variable de entorno:

```bash
export HARBOR_PASSWORD='cambia-esta-contraseña'
./scripts/bootstrap-local.sh
```

El bootstrap instala Argo CD si es necesario, crea Harbor, crea el proyecto
`gitops`, publica las dos aplicaciones con las etiquetas `dev` y `prod`, crea
los `imagePullSecrets` de ambos entornos y aplica el `ApplicationSet`.

Para reutilizar una instalación existente de Argo CD:

```bash
INSTALL_ARGOCD=false ./scripts/bootstrap-local.sh
```

Para publicar etiquetas diferentes:

```bash
IMAGE_TAGS=dev ./scripts/bootstrap-local.sh
```

> Si se publica solo `dev`, el entorno `prod` no tendrá una imagen `prod` para
> descargar. El valor predeterminado publica ambos tags para que la demo quede
> operativa de extremo a extremo.

## Accesos locales

```bash
# Argo CD
kubectl port-forward svc/argocd-server -n argocd 8080:443

# Harbor (usar el servicio público, no gitops-harbor-portal)
kubectl port-forward svc/harbor -n harbor 30002:80
```

- Argo CD: <https://localhost:8080>
- Harbor: <http://harbor.local:30002>

Consulta [argocd/README.md](argocd/README.md) y
[k8s/harbor/README.md](k8s/harbor/README.md) para las credenciales iniciales y
comandos de diagnóstico.

## CI/CD con runner local

El workflow [`.github/workflows/ci.yaml`](.github/workflows/ci.yaml) utiliza un
runner con las etiquetas `self-hosted`, `linux` y `x64`. Esto es imprescindible:
los runners alojados por GitHub no pueden acceder a tu registro Harbor local.

Configura estos secretos en GitHub:

- `HARBOR_USERNAME`
- `HARBOR_PASSWORD`
- `HARBOR_URL` (`harbor.local:30002`)
- `HARBOR_PROJECT` (`gitops`)

Los pushes a `dev` publican imágenes `:dev`; los pushes a `main` publican
`:prod`, una etiqueta por SHA y `:latest`.

## Flujo GitOps que demuestra el proyecto

1. Un cambio en código activa GitHub Actions en el runner local.
2. El runner construye y publica las imágenes en Harbor.
3. Un cambio de manifiestos en `dev` o `main` es detectado por Argo CD.
4. Argo CD renderiza Kustomize y aplica el estado deseado en `dev` o `prod`.
5. Si alguien modifica recursos manualmente, `selfHeal` restaura lo declarado
   en Git; `prune` elimina recursos retirados del repositorio.

## Notas de seguridad

Las contraseñas de ejemplo de este repositorio son únicamente para una demo
local. Antes de usarlo fuera de ese contexto, reemplázalas por secretos
gestionados (por ejemplo, External Secrets, Sealed Secrets o SOPS), usa TLS en
Harbor y limita qué workflows pueden ejecutarse en el self-hosted runner.
