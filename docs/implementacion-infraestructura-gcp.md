# Implementación de Infraestructura en Google Cloud Platform

Este documento describe paso a paso la implementación de la infraestructura de nube para el proyecto **microservices-demo** (votación Tacos vs. Burritos), usando Google Cloud Platform como plataforma de despliegue y GitHub Actions como motor de CI/CD.

---

## Tabla de contenido

1. [Arquitectura general](#1-arquitectura-general)
2. [Prerequisitos](#2-prerequisitos)
3. [Configuración de autenticación OIDC (Workload Identity Federation)](#3-configuración-de-autenticación-oidc-workload-identity-federation)
4. [Aprovisionamiento de recursos en GCP](#4-aprovisionamiento-de-recursos-en-gcp)
5. [Instalación de dependencias en las VMs](#5-instalación-de-dependencias-en-las-vms)
6. [Configuración de GitHub](#6-configuración-de-github)
7. [Configuración de ramas Git](#7-configuración-de-ramas-git)
8. [Verificación del pipeline CI](#8-verificación-del-pipeline-ci)

---

## 1. Arquitectura general

```
GitHub Actions
     │
     │  Workload Identity Federation (OIDC)
     ▼
Google Cloud Platform
     ├── Artifact Registry (us-central1)
     │     └── Repositorio Docker: microservices
     │
     └── Compute Engine
           ├── microservices-demo-dev      (35.222.97.106)
           ├── microservices-demo-staging  (34.42.246.65)
           └── microservices-demo-prod     (34.57.190.1)
```

Cada VM tiene adjunta una **Service Account** (`vm-gar-reader`) con el rol `roles/artifactregistry.reader`, lo que le permite hacer pull de imágenes del Artifact Registry sin credenciales explícitas.

Los pipelines de GitHub Actions usan **Workload Identity Federation** para autenticarse en GCP sin secretos de larga vida.

---

## 2. Prerequisitos

- Cuenta de Google con acceso al portal de GCP ([console.cloud.google.com](https://console.cloud.google.com))
- Repositorio en GitHub con los workflows en `.github/workflows/`
- Acceso a Google Cloud Shell (no se requiere instalar nada localmente)

---

## 3. Configuración de autenticación OIDC (Workload Identity Federation)

Workload Identity Federation permite que GitHub Actions obtenga tokens de acceso temporales de GCP sin guardar credenciales estáticas. GitHub genera un JWT firmado que GCP valida contra el proveedor configurado.

### 3.1 Habilitar API de credenciales

Desde **Google Cloud Shell** (`>_` en el portal de GCP):

```bash
# Definir variables del proyecto
PROJECT_ID="microservices-demo-492923"
GITHUB_USER="JuanCami009"
REPO_NAME="microservices-demo"

gcloud services enable iamcredentials.googleapis.com --project="$PROJECT_ID"
```

### 3.2 Crear el Workload Identity Pool

```bash
gcloud iam workload-identity-pools create "github-pool" --project="$PROJECT_ID" --location="global" --display-name="GitHub Actions Pool"
```

### 3.3 Crear el proveedor OIDC

El proveedor conecta el pool con el issuer de tokens de GitHub Actions. El parámetro `--attribute-condition` restringe el acceso exclusivamente al repositorio especificado.

```bash
gcloud iam workload-identity-pools providers create-oidc "github-provider" --project="$PROJECT_ID" --location="global" --workload-identity-pool="github-pool" --display-name="GitHub Provider" --attribute-mapping="google.subject=assertion.sub,attribute.repository=assertion.repository" --issuer-uri="https://token.actions.githubusercontent.com" --attribute-condition="attribute.repository=='$GITHUB_USER/$REPO_NAME'"
```

### 3.4 Crear la Service Account para GitHub Actions

Esta SA es la identidad con la que GitHub Actions actúa dentro de GCP (hace push de imágenes al Artifact Registry).

```bash
gcloud iam service-accounts create "github-actions-sa" --project="$PROJECT_ID" --display-name="GitHub Actions Service Account"
```

### 3.5 Asignar permisos de escritura en Artifact Registry

```bash
gcloud projects add-iam-policy-binding "$PROJECT_ID" --member="serviceAccount:github-actions-sa@$PROJECT_ID.iam.gserviceaccount.com" --role="roles/artifactregistry.writer"
```

### 3.6 Vincular el pool WIF con la Service Account

Solo los workflows del repositorio especificado pueden asumir esta identidad.

```bash
PROJECT_NUMBER=$(gcloud projects describe $PROJECT_ID --format='get(projectNumber)') && gcloud iam service-accounts add-iam-policy-binding "github-actions-sa@$PROJECT_ID.iam.gserviceaccount.com" --project="$PROJECT_ID" --role="roles/iam.workloadIdentityUser" --member="principalSet://iam.googleapis.com/projects/$PROJECT_NUMBER/locations/global/workloadIdentityPools/github-pool/attribute.repository/$GITHUB_USER/$REPO_NAME"
```

### 3.7 Obtener los valores para GitHub Secrets

```bash
echo "GCP_SERVICE_ACCOUNT: github-actions-sa@$PROJECT_ID.iam.gserviceaccount.com"
echo "GCP_WORKLOAD_IDENTITY_PROVIDER:"
gcloud iam workload-identity-pools providers describe "github-provider" --project="$PROJECT_ID" --location="global" --workload-identity-pool="github-pool" --format="get(name)"
```

**Valores obtenidos:**
- `GCP_SERVICE_ACCOUNT`: `github-actions-sa@microservices-demo-492923.iam.gserviceaccount.com`
- `GCP_WORKLOAD_IDENTITY_PROVIDER`: `projects/664112216219/locations/global/workloadIdentityPools/github-pool/providers/github-provider`

---

## 4. Aprovisionamiento de recursos en GCP

### 4.1 Google Artifact Registry

Creado desde la consola de GCP (**Artifact Registry** → **Create Repository**):

| Campo | Valor |
|-------|-------|
| Name | `microservices` |
| Format | `Docker` |
| Mode | `Standard` |
| Location type | `Region` → `us-central1` |
| Encryption | Google-managed |
| Immutable image tags | Disabled |
| Cleanup policies | Dry run |

Las imágenes se almacenan con el formato:
```
us-central1-docker.pkg.dev/microservices-demo-492923/microservices/SERVICE:TAG
```

### 4.2 Service Account para las VMs

Creada desde **IAM & Admin** → **Service Accounts** → **Create Service Account**:

| Campo | Valor |
|-------|-------|
| Name | `vm-gar-reader` |
| Display name | `VM Artifact Registry Reader` |
| Role | `Artifact Registry Reader` |

Esta SA permite que cada VM haga pull de imágenes del Artifact Registry usando Application Default Credentials, sin necesidad de credenciales explícitas en los scripts de despliegue.

### 4.3 Reglas de firewall

Creadas desde **VPC Network** → **Firewall** → **Create Firewall Rule**:

| Regla | Puerto | Propósito |
|-------|--------|-----------|
| `allow-microservices-8080` | TCP 8080 | Servicio vote |
| `allow-microservices-4000` | TCP 4000 | Servicio result |
| `allow-ssh-microservices` | TCP 22 | SSH desde GitHub Actions |

Todas usan:
- **Target tags:** `microservices-demo`
- **Source:** `0.0.0.0/0`

### 4.4 Máquinas Virtuales de Compute Engine

Creadas desde **Compute Engine** → **VM Instances** → **Create Instance**.

Configuración idéntica para las 3 VMs:

| Campo | Valor |
|-------|-------|
| Region | `us-central1` |
| Zone | `us-central1-a` |
| Machine type | `e2-medium` |
| Boot disk OS | Ubuntu 24.04 LTS |
| Boot disk size | 20 GB |
| Service account | `vm-gar-reader` |
| Access scopes | Allow full access to all Cloud APIs |
| Network tags | `microservices-demo` |

| VM | IP Pública |
|----|-----------|
| `microservices-demo-dev` | `35.222.97.106` |
| `microservices-demo-staging` | `34.42.246.65` |
| `microservices-demo-prod` | `34.57.190.1` |

---

## 5. Instalación de dependencias en las VMs

### 5.1 Generar clave SSH para GitHub Actions

Desde Cloud Shell:

```bash
ssh-keygen -t ed25519 -f ~/.ssh/gcp_deploy -N "" -C "github-actions-deploy"
```

### 5.2 Agregar la clave pública a cada VM

```bash
gcloud config set project microservices-demo-492923

gcloud compute instances add-metadata microservices-demo-dev --zone=us-central1-a --metadata="ssh-keys=ubuntu:$(cat ~/.ssh/gcp_deploy.pub)"

gcloud compute instances add-metadata microservices-demo-staging --zone=us-central1-a --metadata="ssh-keys=ubuntu:$(cat ~/.ssh/gcp_deploy.pub)"

gcloud compute instances add-metadata microservices-demo-prod --zone=us-central1-a --metadata="ssh-keys=ubuntu:$(cat ~/.ssh/gcp_deploy.pub)"
```

### 5.3 Instalar Docker en las VMs

```bash
ssh -i ~/.ssh/gcp_deploy -o StrictHostKeyChecking=no ubuntu@35.222.97.106 "curl -fsSL https://get.docker.com | sudo sh && sudo usermod -aG docker ubuntu"

ssh -i ~/.ssh/gcp_deploy -o StrictHostKeyChecking=no ubuntu@34.42.246.65 "curl -fsSL https://get.docker.com | sudo sh && sudo usermod -aG docker ubuntu"

ssh -i ~/.ssh/gcp_deploy -o StrictHostKeyChecking=no ubuntu@34.57.190.1 "curl -fsSL https://get.docker.com | sudo sh && sudo usermod -aG docker ubuntu"
```

Docker versión instalada: **29.4.0**

### 5.4 Crear directorio de trabajo en las VMs

```bash
ssh -i ~/.ssh/gcp_deploy -o StrictHostKeyChecking=no ubuntu@35.222.97.106 "sudo mkdir -p /opt/microservices-demo && sudo chown ubuntu:ubuntu /opt/microservices-demo"

ssh -i ~/.ssh/gcp_deploy -o StrictHostKeyChecking=no ubuntu@34.42.246.65 "sudo mkdir -p /opt/microservices-demo && sudo chown ubuntu:ubuntu /opt/microservices-demo"

ssh -i ~/.ssh/gcp_deploy -o StrictHostKeyChecking=no ubuntu@34.57.190.1 "sudo mkdir -p /opt/microservices-demo && sudo chown ubuntu:ubuntu /opt/microservices-demo"
```

### 5.5 Instalar gcloud CLI en las VMs

Las VMs necesitan `gcloud` para autenticarse con el Artifact Registry al momento del despliegue.

```bash
ssh -i ~/.ssh/gcp_deploy -o StrictHostKeyChecking=no ubuntu@35.222.97.106 "sudo snap install google-cloud-cli --classic"

ssh -i ~/.ssh/gcp_deploy -o StrictHostKeyChecking=no ubuntu@34.42.246.65 "sudo snap install google-cloud-cli --classic"

ssh -i ~/.ssh/gcp_deploy -o StrictHostKeyChecking=no ubuntu@34.57.190.1 "sudo snap install google-cloud-cli --classic"
```

---

## 6. Configuración de GitHub

### 6.1 Secrets

Ruta: **Settings** → **Secrets and variables** → **Actions** → pestaña **Secrets**

| Secret | Valor |
|--------|-------|
| `GCP_WORKLOAD_IDENTITY_PROVIDER` | `projects/664112216219/locations/global/workloadIdentityPools/github-pool/providers/github-provider` |
| `GCP_SERVICE_ACCOUNT` | `github-actions-sa@microservices-demo-492923.iam.gserviceaccount.com` |
| `GCP_VM_HOST_DEV` | `35.222.97.106` |
| `GCP_VM_HOST_STAGING` | `34.42.246.65` |
| `GCP_VM_HOST_PROD` | `34.57.190.1` |
| `GCP_VM_USERNAME` | `ubuntu` |
| `GCP_VM_SSH_KEY` | Contenido de `~/.ssh/gcp_deploy` (clave privada completa) |

### 6.2 Variables

Ruta: **Settings** → **Secrets and variables** → **Actions** → pestaña **Variables**

| Variable | Valor |
|----------|-------|
| `GCP_PROJECT_ID` | `microservices-demo-492923` |
| `GAR_LOCATION` | `us-central1` |
| `GAR_REPO` | `microservices` |
| `GCE_ZONE` | `us-central1-a` |

### 6.3 Environments

Ruta: **Settings** → **Environments** → **New environment**

| Environment | Propósito | Protección |
|-------------|-----------|------------|
| `infrastructure` | Aprueba cambios de infra a `main` | Opcional: reviewer manual |
| `staging` | Deploy de release candidates | Opcional: reviewer manual |
| `production` | Deploy a producción | Required reviewers activado |

---

## 7. Configuración de ramas Git

```bash
# Crear rama develop (integración continua del equipo de desarrollo)
git checkout main
git checkout -b develop
git push origin develop

# Regresar a main
git checkout main
```

La rama `main` actúa también como `master` en el flujo de Git Flow para los pipelines de producción (los tags `vX.Y.Z` se disparan independientemente del nombre de la rama base).

---

## 8. Verificación del pipeline CI

### 8.1 Problema encontrado: `go.sum` faltante

El repositorio no incluía el archivo `worker/go.sum`, necesario para que `go vet` y `go test` puedan verificar la integridad de las dependencias del módulo Go.

**Error original:**
```
Error: missing go.sum entry for module providing package github.com/IBM/sarama
go: updates to go.mod needed; to update it: go mod tidy
```

### 8.2 Solución: workflow temporal para generar go.sum

Se creó un workflow temporal (`.github/workflows/generate-gosum.yml`) con trigger `workflow_dispatch` que ejecuta `go mod tidy` en la rama feature y hace commit automático de los archivos generados:

```yaml
- name: Generate go.sum and update go.mod
  working-directory: worker
  run: go mod tidy

- name: Commit go.mod and go.sum
  run: |
    git config user.name "github-actions[bot]"
    git config user.email "github-actions[bot]@users.noreply.github.com"
    git add worker/go.mod worker/go.sum
    git diff --staged --quiet || git commit -m "fix: update go.mod and go.sum for worker module"
    git push
```

El workflow se eliminó una vez cumplido su propósito.

### 8.3 Resultado final del pipeline CI

Pipeline `ci.yml` ejecutado en la rama `feature/SPRINT-01-test-pipeline`:

| Job | Estado | Tiempo |
|-----|--------|--------|
| `test-vote` — Java/Spring Boot | ✅ Passed | ~1 min |
| `test-worker` — Go | ✅ Passed | ~30s |
| `build-result` — Node.js | ✅ Passed | ~20s |

El pipeline valida correctamente:
- Compilación y tests unitarios de vote (Maven + SpotBugs)
- Análisis estático, compilación y tests con race detector de worker (go vet + go test -race)
- Instalación de dependencias y auditoría de seguridad de result (npm audit)
