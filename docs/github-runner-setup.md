# Guía de Configuración de GitHub Actions Self-Hosted Runner

Esta guía detalla el proceso completo para configurar y registrar un **Self-Hosted Runner** de GitHub Actions en tu máquina local. Este componente permite cerrar el ciclo de **Integración Continua (CI)** de la PoC, compilando y subiendo imágenes a tu registro privado **Harbor** sin exponer tu red local a internet.

---

## 1. ¿Por qué se requiere un Self-Hosted Runner?

En este proyecto, Harbor se ejecuta de forma privada en tu máquina local (`http://harbor.local:30002`). 

* **Los runners estándar de GitHub (en la nube)** no pueden acceder a tu red privada ni resolver `harbor.local`.
* **Un Self-Hosted Runner** se ejecuta en tu propio sistema operativo, estableciendo una conexión saliente segura hacia GitHub (vía HTTPS) para consultar trabajos pendientes. Cuando detecta un nuevo push o PR, ejecuta el pipeline localmente con acceso directo a tu Docker daemon y al registro Harbor.

```text
+-----------------------+                         +-----------------------------------+
|     GitHub Cloud      |                         |      Tu Máquina Local (Host)      |
|                       |                         |                                   |
|   Repositorio Git     |   Consulta saliente     |   +---------------------------+   |
|   (Push / Pull Request) <-------------------------  | GitHub Actions Runner     |   |
|           |           |      (Long Polling)     |   | (linux, x64, self-hosted) |   |
|           v           |                         |   +-------------+-------------+   |
|   Dispara Workflow    |                         |                 |                 |
|   (.github/ci.yaml)   |                         |                 v                 |
+-----------------------+                         |       +-------------------+       |
                                                  |       |   Docker Engine   |       |
                                                  |       |  (Build & Push)   |       |
                                                  |       +---------+---------+       |
                                                  |                 |                 |
                                                  |                 v                 |
                                                  |       +-------------------+       |
                                                  |       |   Harbor Local    |       |
                                                  |       |  (:30002/gitops)  |       |
                                                  |       +---------+---------+       |
                                                  |                 |                 |
                                                  |                 v                 |
                                                  |       +-------------------+       |
                                                  |       |   Argo CD / K8s   |       |
                                                  |       +-------------------+       |
                                                  +-----------------------------------+
```

---

## 2. Prerrequisitos en la Máquina Local

Antes de registrar el runner, asegúrate de cumplir con lo siguiente:

1. **Docker en ejecución**:
   ```bash
   docker ps
   ```
2. **Permisos de Docker para tu usuario sin `sudo`**:
   El runner se ejecuta bajo tu usuario regular. Para que pueda construir y publicar imágenes sin requerir contraseñas de administrador:
   ```bash
   sudo usermod -aG docker $USER
   newgrp docker
   ```
   *(Valida ejecutando `docker info` sin `sudo`)*.

3. **Resolución de nombres a Harbor**:
   Verifica que la entrada `harbor.local` responda en tu terminal:
   ```bash
   curl -I http://harbor.local:30002
   ```

---

## 3. Paso a Paso: Descarga y Registro del Runner

### Paso 3.1: Obtener el Token de Registro en GitHub

1. Ingresa a tu repositorio en GitHub.
2. Dirígete a **Settings** (Configuración) > pestaña lateral **Actions** > **Runners**.
3. Haz clic en el botón verde **New self-hosted runner**.
4. En **Runner image**, selecciona **Linux**.
5. En **Architecture**, selecciona **x64**.
6. Deja abierta esta pestaña para copiar los comandos que GitHub genera con tu **token temporal**.

---

### Paso 3.2: Descargar el Binario del Runner

Abre una terminal en tu máquina y crea una carpeta dedicada para el runner (por ejemplo en tu directorio home):

```bash
# Crear directorio dedicado
mkdir -p ~/actions-runner && cd ~/actions-runner

# Descargar el paquete más reciente (reemplaza la versión por la mostrada en tu GitHub)
curl -o actions-runner-linux-x64.tar.gz -L https://github.com/actions/runner/releases/download/v2.322.0/actions-runner-linux-x64-2.322.0.tar.gz

# Extraer el instalador
tar xzf ./actions-runner-linux-x64.tar.gz
```

---

### Paso 3.3: Configurar y Conectar el Runner

Ejecuta el script de configuración con el token proporcionado por la interfaz de GitHub:

```bash
./config.sh --url https://github.com/<TU-USUARIO-O-ORGANIZACION>/<TU-REPOSITORIO> --token <TOKEN_PROPORCIONADO_POR_GITHUB>
```

Durante el asistente interactivo se te solicitarán los siguientes datos:
1. **Runner group**: Presiona `Enter` para usar el grupo `Default`.
2. **Runner name**: Ingresa un nombre descriptivo (ej: `local-devops-runner`) o presiona `Enter` para usar el hostname de tu máquina.
3. **Labels adicionales**: Presiona `Enter` (por defecto incluirá `self-hosted`, `linux` y `x64`, que son exactamente las requeridas en `.github/workflows/ci.yaml`).
4. **Work folder**: Presiona `Enter` para usar el valor por defecto (`_work`).

Al finalizar verás el mensaje:
```text
√ Runner successfully added
√ Runner connection test completed and succeeded.
```

---

## 4. Ejecutar el Runner

Tienes dos formas de ejecutar el runner:

### Opción A: Modo Interactivo (Solo para pruebas rápidas)
```bash
./run.sh
```
> [!NOTE]
> Este modo es útil para depurar el primer workflow, pero se detendrá si cierras la terminal.

### Opción B: Como Servicio en Segundo Plano con Systemd (Recomendado)
Para mantener el runner activo incluso tras reiniciar tu equipo:

```bash
# Instalar como servicio del sistema (requiere sudo una única vez)
sudo ./svc.sh install

# Iniciar el servicio
sudo ./svc.sh start

# Verificar que esté activo
sudo ./svc.sh status
```

Para consultar los logs del runner en cualquier momento:
```bash
journalctl -u actions.runner.* -f
```

---

## 5. Configuración de Secretos en el Repositorio de GitHub

El workflow [`.github/workflows/ci.yaml`](file:///home/scarmona/git/gitops_proyect/.github/workflows/ci.yaml) consume variables de entorno protegidas para iniciar sesión en Harbor y etiquetar las imágenes.

1. En GitHub, ve a **Settings** > **Secrets and variables** > **Actions**.
2. Haz clic en **New repository secret** y crea los siguientes 4 secretos:

| Nombre del Secreto | Valor de Ejemplo | Descripción |
| :--- | :--- | :--- |
| **`HARBOR_URL`** | `harbor.local:30002` | Dirección del registro local. |
| **`HARBOR_USERNAME`** | `admin` | Usuario con permisos de push en Harbor. |
| **`HARBOR_PASSWORD`** | `HarborAdmin123!` | Contraseña del usuario de Harbor. |
| **`HARBOR_PROJECT`** | `gitops` | Nombre del proyecto creado en Harbor. |

---

## 6. Validación de la PoC End-to-End

Una vez que el runner y los secretos estén configurados, valida el flujo completo:

1. **Hacer un cambio y push**:
   ```bash
   git checkout dev
   # Realiza cualquier cambio menor o commit vacío de prueba:
   git commit --allow-empty -m "ci: test self-hosted runner workflow"
   git push origin dev
   ```

2. **Monitorear en GitHub Actions**:
   * Dirígete a la pestaña **Actions** en tu repositorio de GitHub.
   * Verás el pipeline `CI/CD Pipeline (Harbor)` en ejecución.
   * Observa cómo los jobs `build-and-push-frontend` y `build-and-push-backend` se asignan a tu runner local.

3. **Verificar en Harbor**:
   * Ingresa a [http://harbor.local:30002](http://harbor.local:30002).
   * Navega a **Projects** > **gitops** > **Repositories**.
   * Deberás ver los artefactos `frontend` y `backend` actualizados recientemente con la etiqueta `dev` y `sha-<hash>`.

4. **Verificar en Argo CD**:
   * Ingresa a [https://localhost:8080](https://localhost:8080).
   * La aplicación `gitops-stack-dev` detectará y mantendrá sincronizado el estado del clúster.

---

## 7. Comandos de Administración del Runner

| Acción | Comando (dentro de `~/actions-runner`) |
| :--- | :--- |
| **Ver estado del servicio** | `sudo ./svc.sh status` |
| **Detener servicio** | `sudo ./svc.sh stop` |
| **Reiniciar servicio** | `sudo ./svc.sh restart` |
| **Desinstalar servicio** | `sudo ./svc.sh uninstall` |
| **Desvincular runner de GitHub** | `./config.sh remove --token <TOKEN_DE_ELIMINACION>` |

---

## 8. Solución de Problemas Comunes (Troubleshooting)

* **Error: `Got permission denied while trying to connect to the Docker daemon socket`**:
  * Tu usuario no pertenece al grupo `docker`. Ejecuta `sudo usermod -aG docker $USER`, reinicia la sesión con `su - $USER` y reinicia el servicio del runner con `sudo ./svc.sh restart`.

* **Error: `server gave HTTP response to HTTPS client` en Docker push**:
  * Verifica que `/etc/docker/daemon.json` contenga `"insecure-registries": ["harbor.local:30002"]` y reinicia Docker con `sudo systemctl restart docker`.

* **El runner figura como `Offline` en GitHub**:
  * Comprueba si el proceso o servicio está activo con `sudo ./svc.sh status`. Si lo ejecutaste interactivamente con `./run.sh`, asegúrate de que la terminal no se haya cerrado.
