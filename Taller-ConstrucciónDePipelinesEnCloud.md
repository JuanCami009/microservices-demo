**Integrantes**  
Juan Camilo Molina Mussen  
Sharik Camila Rueda Lucero

**Taller**

1. Metodología ágil a utilizar  
     
   **Marco ágil seleccionado: Scrum**  
     
   El equipo trabaja en sprints de tres-cuatro semanas. Cada sprint tiene sus ceremonias (planning, daily, review, retrospectiva) y produce un incremento potencialmente entregable. La estrategia de branching debe reflejar ese ritmo y garantizar que el pipeline CI/CD pueda ejecutarse de forma continua y segura.  
     
2. Estrategia de branching para desarrolladores  
     
   **Filosofía base**  
     
   Se adopta **Git Flow**, que se describe como una estrategia multi-rama diseñada para gestionar el código fuente de forma estructurada con ciclos de release bien definidos. Aunque Scrum trabaja con sprints cortos, Git Flow encaja bien aquí porque cada sprint tiene un incremento entregable concreto, lo que equivale a un ciclo de release planificado. En microservices-demo esto es especialmente útil porque los tres microservicios (vote, result, worker) se desarrollan en paralelo por diferentes miembros del equipo y comparten puntos de integración críticos (Kafka y PostgreSQL), por lo que se necesita una estrategia que regule con claridad qué código está listo para release y qué está aún en desarrollo.  
     
   **Ramas permanentes**  
     
   **master** contiene exclusivamente el código de producción etiquetado. Todo lo que llega aquí ha pasado por el ciclo completo de integración y pruebas. Está protegida: solo reciben merge las ramas **release/** y **hotfix/**. Cada merge a master lleva un tag de versión (**v1.0.0, v1.1.0, etc.**) que el equipo de operaciones usa para actualizar el tag de imagen en los charts de Helm.  
     
   **develop** es la rama de integración continua del equipo de desarrollo. Aquí convergen todas las features terminadas del sprint. Es la fuente de verdad del estado actual del desarrollo y el punto desde donde se crean las ramas de release al cierre de cada sprint.

   **Ramas de trabajo (efímeras)**

   

   **Ramas de feature \- una por historia de usuario:**

   

   feature/SPRINT-\<número\>-\<id-historia\>-\<descripción-corta\>

   

   **Ejemplos reales para microservices-demo:**

   

* feature/SPRINT-01-US-04-vote-kafka-error-handling  
* feature/SPRINT-02-US-11-worker-upsert-retry  
* feature/SPRINT-02-US-15-result-websocket-reconnect  
    
  Estas ramas nacen siempre desde **develop**, corresponden a una sola historia de usuario del sprint backlog, y se mergean de vuelta a **develop** mediante Pull Request con aprobación de al menos un compañero del equipo. Una vez mergeadas, se eliminan. Es importante no dejar estas ramas abiertas más de lo necesario dado que vote, result y worker comparten Kafka y PostgreSQL como puntos de integración; cambios sin integrar rápidamente generan conflictos en esos puntos de encuentro.  
    
  **Ramas de release \- una por sprint:**  
    
  release/SPRINT-\<número\>-v\<versión\>

  **Ejemplo:** release/SPRINT-02-v1.2.0


  Se crea desde **develop** al final del sprint, una vez que todas las historias del sprint están mergeadas. En esta rama solo se permiten correcciones de bugs detectados en la sprint review o en las pruebas finales, no features nuevas. Una vez estabilizada, se mergea tanto a **master** (con su tag de versión) como de vuelta a **develop** para mantener consistencia. Esto mapea directamente con la sprint review de Scrum: la rama **release/** es el incremento del sprint que se demuestra al Product Owner.


  **Ramas de hotfix \- para bugs críticos en producción:**


  hotfix/v\<versión\>-\<descripción\>


  **Ejemplo:** hotfix/v1.2.1-worker-restart-clears-votes


  Nacen desde **master**, corrigen el problema mínimo necesario y se mergean tanto a **master** (con nuevo tag) como a **develop** para que el fix quede incorporado en el flujo normal de desarrollo.

  **Flujo del desarrollador dentro del sprint**


1. En el sprint planning se asigna la historia al desarrollador.  
2. El desarrollador crea la rama **feature/** desde **develop** actualizado.  
3. Hace commits frecuentes y descriptivos: **feat(vote): add retry on Kafka publish failure.**  
4. Al terminar, abre un Pull Request hacia **develop** con descripción y referencia a la historia de usuario.  
5. El pipeline CI se ejecuta automáticamente: build, tests unitarios, análisis estático de código.  
6. Un compañero del equipo aprueba el PR mediante peer review.  
7. Se hace merge a **develop** y se elimina la rama de feature.  
8. Al cierre del sprint, el Scrum Master o Tech Lead crea la rama **release/** desde **develop**.  
9. Se estabiliza, se mergea a **master** con tag y de vuelta a **develop**.  
     
     
3. Estrategia de branching para operaciones  
     
   **Filosofía base**  
     
   Se adopta Trunk-based Development para operaciones. Se define como la estrategia donde todos los cambios se integran directamente en un tronco compartido (**main**) que se mantiene siempre en estado desplegable. Para operaciones esto tiene una ventaja concreta: cualquier cambio de infraestructura que entre al trunk está inmediatamente disponible para ser desplegado, lo que elimina la latencia que generarían ramas de larga vida. En microservices-demo, donde la infraestructura es relativamente estable (Kafka en KRaft, PostgreSQL con un solo schema, cuatro charts de Helm bien definidos), los cambios de operaciones son puntuales y frecuentes pero pequeños, exactamente el perfil para el que Trunk-based Development está optimizado.  
     
   **Ramas permanentes**  
     
   **main** es la única rama permanente y representa en todo momento el estado actual de la infraestructura integrada y validada. Está protegida: todo cambio entra por Pull Request con al menos una aprobación. El pipeline de infraestructura se ejecuta automáticamente sobre cada PR antes del merge. Lo que está en **main** es lo que el pipeline despliega: no hay ambigüedad sobre qué versión de la infraestructura está activa.  
     
   **Ramas de trabajo (efímeras)**  
     
   Se describe la variante Scaled Trunk Development para equipos que necesitan un nivel adicional de control: se permiten ramas cortas de feature y bugfix, pero con la condición de que vivan máximo 1-2 días antes de integrarse al trunk. **Para operaciones en este proyecto se aplica esa variante:**  
     
   infra/SPRINT-\<número\>-\<descripción-corta\>  
     
   **Ejemplos reales para microservices-demo:**  
     
* infra/SPRINT-01-kafka-kraft-persistentvolumeclaim  
* infra/SPRINT-02-postgresql-resource-limits  
* infra/SPRINT-02-helm-result-ingress-tls  
* infra/SPRINT-03-worker-deployment-image-update  
    
  Estas ramas nacen desde **main**, se trabajan rápido (máximo un par de días), se validan con **helm lint** y **helm template**, pasan por el pipeline de infraestructura y se mergean de vuelta a **main**. Se eliminan inmediatamente después del merge. No se acumulan cambios grandes en una sola rama: si un cambio de infraestructura es complejo, se parte en incrementos pequeños que se integran progresivamente al trunk.  
    
  **Para emergencias en producción:**  
    
  hotfix/infra-\<fecha\>-\<descripción\>  
    
  **Ejemplo:** hotfix/infra-20260413-kafka-broker-oom-limit  
    
  Sale desde **main**, aplica el fix mínimo necesario, PR con aprobación acelerada del Tech Lead de operaciones y merge inmediato a **main**. El pipeline despliega automáticamente.  
  Flujo  
    
  **Flujo del equipo de operaciones dentro del sprint**  
    
1. En el sprint planning se identifican los cambios de infraestructura necesarios para soportar las historias del equipo de desarrollo.  
2. El equipo de operaciones crea la rama **infra/** desde **main** actualizado.  
3. Modifica los manifiestos o charts, valida localmente con **helm lint** y **helm template**.  
4. El pipeline de infraestructura se ejecuta automáticamente: validación de Helm charts, escaneo de seguridad de imágenes Docker.  
5. PR hacia **main** con aprobación de un par del equipo de operaciones.  
6. Merge a **main** y despliegue automático al ambiente correspondiente.  
7. La rama **infra/** se elimina.

   

   

4. Patrones de diseño de nube (mínimo dos)  
     
   **Patrón 1 \- Retry**

   **Definición**

   

   El patrón Retry establece que cuando una operación falla por una causa que se considera transitoria (timeout de red, spike de latencia, sobrecarga momentánea), el sistema no debe rendirse inmediatamente sino reintentar la operación un número controlado de veces, con una espera entre intentos, antes de declarar el fallo definitivamente. La clave está en la palabra transitoria: el Retry solo tiene sentido cuando existe una probabilidad razonable de que el problema se resuelva solo en cuestión de segundos.

   

   **Problema que resuelve en microservices-demo**

   

   En el flujo de votación, vote publica un mensaje en Kafka cada vez que un usuario emite su voto. Kafka, como cualquier sistema distribuido, puede experimentar picos de latencia momentáneos, reconexiones de líder de partición, o retrasos de red que hacen que el send() al broker falle con un timeout. Sin Retry, ese fallo se propaga directamente al usuario como un error 500, y el voto se pierde. En un sistema de votación, perder un voto por un fallo de red de 200ms es inaceptable.

   

   **Qué fallos atiende y qué fallos no**

   

   El patrón Retry está configurado para actuar únicamente sobre excepciones de naturaleza transitoria: KafkaException por timeouts de red y TimeoutException por esperas superadas. Errores de serialización (SerializationException) están explícitamente excluidos porque indican un problema en el mensaje mismo, no en la infraestructura, y reintentarlo no lo va a resolver.

   

   **Limitación que motiva el siguiente patrón**

   

   El Retry resuelve fallos transitorios, pero falla ante caídas sostenidas. Si Kafka lleva 30 segundos caído, cada solicitud de voto agotará sus 3 intentos (con sus esperas) antes de fallar. Con 100 usuarios votando simultáneamente, el sistema acumula 300 llamadas bloqueadas esperando timeouts, los threads del servidor se agotan y el servicio vote colapsa por completo, aunque el problema original sea solo Kafka. Esto motiva directamente el Circuit Breaker.

   

   **Patrón 2 \- Circuit Breaker**

   

   **Definición**

   

   El patrón Circuit Breaker modela el comportamiento de un disyuntor eléctrico: cuando detecta que un sistema dependiente está fallando de forma sostenida, "abre el circuito" y bloquea inmediatamente todas las llamadas subsiguientes hacia ese sistema, retornando un fallback sin siquiera intentar la comunicación. Después de un tiempo configurable, pasa a un estado "semiabierto" donde permite pasar algunas solicitudes de prueba para verificar si el sistema dependiente se ha recuperado. Si esas pruebas tienen éxito, el circuito se cierra y la operación normal se reanuda.

   

   **Problema que resuelve en microservices-demo**

   

   Como se describió en la limitación del Retry: si Kafka cae durante un período prolongado, el Retry por sí solo convierte cada solicitud de voto en una secuencia de intentos bloqueados que consumen threads del servidor. El Circuit Breaker corta ese ciclo: después de detectar un umbral de fallos consecutivos, abre el circuito y responde a todos los votos subsiguientes con un fallback instantáneo, preservando los recursos del servicio vote y manteniendo la experiencia del usuario controlada.

   

   

5. Diagrama de arquitectura  
6. Pipelines de desarrollo (incluidos los scripts para las tareas que lo necesiten)

   Los pipelines de desarrollo se implementan como GitHub Actions en `.github/workflows/`. Están diseñados en correspondencia directa con la estrategia Git Flow del punto 2.

   **Resumen de los cuatro pipelines**

   | Archivo | Disparador | Propósito |
   |---|---|---|
   | `ci.yml` | Push a `feature/**`, `hotfix/**`; PR hacia `develop` o `master` | Validación de rama: build + tests + análisis estático |
   | `cd-develop.yml` | Push a `develop` | Build Docker + publicación en ACR + deploy a VM de desarrollo vía SSH con Docker Compose |
   | `cd-release.yml` | Push a `release/**` o `hotfix/**` | Build RC + publicación con tag `rc-X.Y.Z` + deploy a VM de staging vía SSH con Docker Compose |
   | `cd-production.yml` | Push de tag `vX.Y.Z` a `master` | Build producción + publicación en ACR + deploy a VM de producción vía SSH con Docker Compose |

   **Pipeline 1 — CI (`.github/workflows/ci.yml`)**

   Corresponde al paso 5 del flujo del desarrollador dentro del sprint: *"el pipeline CI se ejecuta automáticamente: build, tests unitarios, análisis estático de código"*. Se activa en cualquier rama de feature y en todas las PRs antes de que puedan mergearse a `develop` o `master`.

   *Trabajos paralelos:*

   **test-vote** (Java): compila con `mvn compile`, ejecuta tests con `mvn test` y corre el análisis estático con `mvn spotbugs:check` (plugin SpotBugs configurado en `pom.xml` con threshold `High`). Los reportes de Surefire se guardan como artefactos de la ejecución.

   **test-worker** (Go): descarga dependencias con `go mod download`, verifica integridad del módulo con `go mod verify`, ejecuta `go vet ./...` (análisis estático), compila con `go build` y corre los tests con `go test -race ./...`.

   **build-result** (Node.js): instala dependencias con `npm install` y ejecuta `npm audit --audit-level=critical` para detectar vulnerabilidades conocidas de severidad crítica en las dependencias.

   **Pipeline 2 — CD Develop (`.github/workflows/cd-develop.yml`)**

   Se ejecuta automáticamente en cada merge a `develop`. Reutiliza los mismos tres trabajos de CI y, una vez que los tres pasan, ejecuta dos trabajos adicionales secuencialmente:

   **build-and-push**: autentica en Azure mediante OIDC (sin secretos de larga vida), hace login al Azure Container Registry con `az acr login`, configura Docker Buildx y construye las tres imágenes en paralelo. Publica cada imagen con dos tags: `dev-latest` y `dev-<sha>`, donde `<sha>` es el SHA del commit para trazabilidad. Usa caché de capas de Docker (`type=gha`) para acelerar builds sucesivos.

   **deploy-dev**: copia el `docker-compose.yml` a la VM de desarrollo usando `appleboy/scp-action`, luego conecta por SSH con `appleboy/ssh-action` y ejecuta: autentica Docker con ACR usando la Managed Identity de la VM (`az acr login`), escribe un archivo `.env` con los tags de imagen del deploy actual y ejecuta `docker compose pull && docker compose up -d --remove-orphans`.

   **`docker-compose.yml`**: define los cinco servicios del stack. Los tres servicios de aplicación (`vote`, `result`, `worker`) leen sus imágenes desde variables de entorno (`${VOTE_IMAGE}`, `${RESULT_IMAGE}`, `${WORKER_IMAGE}`) que el pipeline escribe en el `.env` antes de cada deploy. Los dos servicios de infraestructura usan imágenes fijas: `apache/kafka:3.9.0` en modo KRaft (sin Zookeeper) y `postgres:17`. Ambos tienen `healthcheck` configurado para que los servicios de aplicación esperen a que estén listos antes de iniciar (`depends_on: condition: service_healthy`). Los nombres de servicio `kafka` y `postgresql` coinciden exactamente con los que el código tiene hardcodeados.

   **Pipeline 3 — CD Release (`.github/workflows/cd-release.yml`)**

   Se activa en push a `release/**` y `hotfix/**`. Incluye un trabajo adicional al inicio:

   **extract-version**: parsea el nombre de la rama con expresión regular `v\d+\.\d+\.\d+` para extraer la versión. Por ejemplo `release/SPRINT-02-v1.2.0` produce el tag de imagen `rc-1.2.0`. Si no se encuentra el patrón, el pipeline falla con error descriptivo.

   Los trabajos de CI se repiten para garantizar que el código estabilizado de la rama release sigue pasando todas las validaciones. El trabajo **build-and-push** publica en ACR con el tag `rc-X.Y.Z`. El trabajo **deploy-staging** conecta a la VM de staging (`AZURE_VM_HOST_STAGING`) por SSH y ejecuta el mismo script de Docker Compose con las imágenes RC. El ambiente `staging` puede configurarse en GitHub Environments para requerir aprobación antes del deploy.

   **Pipeline 4 — CD Producción (`.github/workflows/cd-production.yml`)**

   Se activa únicamente cuando se hace push de un tag con formato `vX.Y.Z`. Esto ocurre cuando el Tech Lead mergea la rama `release/**` a `master` y crea el tag de versión:

   ```bash
   git checkout master
   git merge --no-ff release/SPRINT-02-v1.2.0
   git tag -a v1.2.0 -m "Release v1.2.0 — Sprint 02"
   git push origin master --tags
   ```

   **build-and-push**: extrae la versión quitando el prefijo `v` del nombre del tag (e.g. `v1.2.0` → `1.2.0`) y publica cada imagen en ACR con dos tags: el número de versión exacto y `latest`.

   **deploy-production**: está asociado al ambiente `production` de GitHub Environments, lo que permite configurar una aprobación manual obligatoria antes de que se ejecute. Conecta a la VM de producción por SSH, ejecuta el mismo script de Docker Compose con las imágenes versionadas y crea un Release en GitHub con las referencias exactas a las imágenes desplegadas.

   **Infraestructura de Azure necesaria**

   Los pipelines de deploy asumen que los siguientes recursos de Azure ya existen (se provisiona en el punto 8):

   | Recurso | Propósito |
   |---|---|
   | Azure Container Registry (ACR) | Almacén de imágenes Docker de los tres servicios |
   | Azure VM (una por ambiente: dev, staging, prod) | Máquinas donde corre Docker Compose con el stack completo |
   | Managed Identity en cada VM | Permite que la VM haga `az acr login` sin credenciales explícitas (rol `AcrPull` sobre el ACR) |
   | Service Principal con OIDC | Identidad que usan los pipelines de GitHub Actions para hacer push al ACR (rol `AcrPush`) |

   Nota: si el presupuesto es limitado, las tres VMs pueden ser la misma máquina usando `docker compose --project-name dev/staging/prod` para mantener los stacks aislados, ajustando los puertos para evitar conflictos.

   **Autenticación OIDC con Azure (sin secretos de larga vida)**

   Los tres pipelines de deploy usan la acción `azure/login@v2` con federación de identidad (OIDC) en lugar de almacenar credenciales como secreto. El flujo es: GitHub genera un token JWT firmado → Azure AD lo valida contra el federated credential configurado → se emite un token de acceso de corta duración. Esto elimina la rotación manual de contraseñas de service principal.

   Para configurar la federación se ejecuta una vez:

   ```bash
   # 1. Crear el service principal
   az ad sp create-for-rbac --name "github-microservices-demo" --sdk-auth

   # 2. Obtener el Object ID de la aplicación
   APP_ID=$(az ad app list --display-name "github-microservices-demo" --query "[0].appId" -o tsv)

   # 3. Agregar federated credential para la rama develop
   az ad app federated-credential create --id $APP_ID --parameters '{
     "name": "github-develop",
     "issuer": "https://token.actions.githubusercontent.com",
     "subject": "repo:<owner>/microservices-demo:ref:refs/heads/develop",
     "audiences": ["api://AzureADTokenExchange"]
   }'

   # 4. Asignar roles (AcrPush en el ACR, AKS RBAC Writer en el clúster)
   az role assignment create --assignee $APP_ID --role AcrPush --scope <acr-resource-id>
   az role assignment create --assignee $APP_ID --role "Azure Kubernetes Service RBAC Writer" --scope <aks-resource-id>
   ```

   Repetir el paso 3 para cada rama/tag que necesite deploy (`release/**`, tags `v*`).

   **Secretos y variables necesarios en el repositorio de GitHub**

   | Nombre | Tipo | Uso |
   |---|---|---|
   | `AZURE_CLIENT_ID` | Secreto | App ID del service principal para autenticación OIDC |
   | `AZURE_TENANT_ID` | Secreto | Tenant ID de Azure AD |
   | `AZURE_SUBSCRIPTION_ID` | Secreto | ID de la suscripción de Azure |
   | `ACR_LOGIN_SERVER` | Variable | URL del ACR, ej. `microdemo.azurecr.io` |
   | `ACR_NAME` | Variable | Nombre corto del ACR, ej. `microdemo` |
   | `AZURE_VM_HOST_DEV` | Secreto | IP o hostname de la VM de desarrollo |
   | `AZURE_VM_HOST_STAGING` | Secreto | IP o hostname de la VM de staging |
   | `AZURE_VM_HOST_PROD` | Secreto | IP o hostname de la VM de producción |
   | `AZURE_VM_USERNAME` | Secreto | Usuario SSH de las VMs (ej. `azureuser`) |
   | `AZURE_VM_SSH_KEY` | Secreto | Clave SSH privada para acceder a las VMs |
   | `ACR_LOGIN_SERVER` | Variable | URL del ACR, ej. `microdemo.azurecr.io` |
   | `ACR_NAME` | Variable | Nombre corto del ACR, ej. `microdemo` |
   | `GITHUB_TOKEN` | Automático | Creación de GitHub Releases (lo provee GitHub Actions) |

   **Análisis estático — configuración en `vote/pom.xml`**

   Se agrega el plugin `spotbugs-maven-plugin` versión `4.8.3.1` en la sección `<build><plugins>`. La configuración usa `threshold=High` para reportar únicamente bugs de severidad alta o superior, evitando falsos positivos en código que usa frameworks como Spring Boot. El análisis se invoca con `mvn spotbugs:check` y detiene el pipeline si encuentra algún bug bajo el umbral configurado.

7. Pipelines de infraestructura (incluidos los scripts para las tareas que lo necesiten)  
8. Implementación de la infraestructura  
9. Demostración en vivo de cambios en el pipeline  
   

**Nota:** Entrega de los resultados: debe incluir la documentación necesaria para todos  
los elementos desarrollados.  
