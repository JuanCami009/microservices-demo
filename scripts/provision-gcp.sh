#!/bin/bash
# provision-gcp.sh
# Aprovisiona los recursos de GCP necesarios para el pipeline de CD.
# Es IDEMPOTENTE: puede ejecutarse múltiples veces sin efectos secundarios.
#
# Variables de entorno requeridas:
#   GCP_PROJECT_ID  → ID del proyecto de GCP (ej. my-project-123)
#   GAR_LOCATION    → región del Artifact Registry  (ej. us-central1)
#   GAR_REPO        → nombre del repositorio en GAR (ej. microservices)
#
# Variables de entorno opcionales:
#   GCE_ZONE        → zona de las VMs              (default: us-central1-a)
#   VM_MACHINE_TYPE → tipo de máquina               (default: e2-medium)
#   VM_ADMIN_USER   → usuario SSH de las VMs        (default: ubuntu)
#   SSH_KEY_FILE    → ruta de la clave SSH para CI  (default: ~/.ssh/gcp_microservices_deploy)
#
# Uso (desde Google Cloud Shell):
#   export GCP_PROJECT_ID=my-project-123
#   export GAR_LOCATION=us-central1
#   export GAR_REPO=microservices
#   bash scripts/provision-gcp.sh

set -euo pipefail

# ── Configuración ──────────────────────────────────────────────────────────────
GCP_PROJECT_ID="${GCP_PROJECT_ID:?Variable GCP_PROJECT_ID no definida}"
GAR_LOCATION="${GAR_LOCATION:?Variable GAR_LOCATION no definida}"
GAR_REPO="${GAR_REPO:?Variable GAR_REPO no definida}"
GCE_ZONE="${GCE_ZONE:-us-central1-a}"
VM_MACHINE_TYPE="${VM_MACHINE_TYPE:-e2-medium}"
VM_ADMIN_USER="${VM_ADMIN_USER:-ubuntu}"
SSH_KEY_FILE="${SSH_KEY_FILE:-$HOME/.ssh/gcp_microservices_deploy}"

ENVIRONMENTS=(dev staging prod)
PORT_VOTE=8080
PORT_RESULT=4000

echo "==========================================="
echo " Aprovisionando infraestructura de GCP"
echo " Proyecto       : $GCP_PROJECT_ID"
echo " Región GAR     : $GAR_LOCATION"
echo " Repositorio GAR: $GAR_REPO"
echo " Zona VMs       : $GCE_ZONE"
echo "==========================================="

# Establecer el proyecto activo
gcloud config set project "$GCP_PROJECT_ID" --quiet

# ── 1. Habilitar APIs necesarias ───────────────────────────────────────────────
echo ""
echo "[1/6] Habilitando APIs de GCP..."
gcloud services enable \
  compute.googleapis.com \
  artifactregistry.googleapis.com \
  iam.googleapis.com \
  --project="$GCP_PROJECT_ID" \
  --quiet
echo "  ✓ APIs habilitadas"

# ── 2. Google Artifact Registry ────────────────────────────────────────────────
echo ""
echo "[2/6] Google Artifact Registry..."
if ! gcloud artifacts repositories describe "$GAR_REPO" \
    --location="$GAR_LOCATION" \
    --project="$GCP_PROJECT_ID" &>/dev/null; then
  gcloud artifacts repositories create "$GAR_REPO" \
    --repository-format=docker \
    --location="$GAR_LOCATION" \
    --project="$GCP_PROJECT_ID" \
    --quiet
  echo "  ✓ Repositorio $GAR_REPO creado en $GAR_LOCATION"
else
  echo "  ✓ Repositorio $GAR_REPO ya existe"
fi

# ── 3. Service Account para que las VMs lean del Artifact Registry ─────────────
echo ""
echo "[3/6] Service Account para VMs..."
VM_SA_NAME="vm-gar-reader"
VM_SA_EMAIL="$VM_SA_NAME@$GCP_PROJECT_ID.iam.gserviceaccount.com"

if ! gcloud iam service-accounts describe "$VM_SA_EMAIL" \
    --project="$GCP_PROJECT_ID" &>/dev/null; then
  gcloud iam service-accounts create "$VM_SA_NAME" \
    --display-name="VM Artifact Registry Reader" \
    --project="$GCP_PROJECT_ID" \
    --quiet
  echo "  ✓ Service Account $VM_SA_EMAIL creada"
else
  echo "  ✓ Service Account $VM_SA_EMAIL ya existe"
fi

# Asignar rol de lectura en el repositorio (idempotente: falla silenciosamente si ya existe)
gcloud artifacts repositories add-iam-policy-binding "$GAR_REPO" \
  --location="$GAR_LOCATION" \
  --member="serviceAccount:$VM_SA_EMAIL" \
  --role="roles/artifactregistry.reader" \
  --project="$GCP_PROJECT_ID" \
  --quiet 2>/dev/null || true
echo "  ✓ Rol artifactregistry.reader asignado"

# ── 4. Clave SSH para GitHub Actions ──────────────────────────────────────────
# Solo se genera si no estamos en GitHub Actions (en CI la clave la provee el secreto)
echo ""
echo "[4/6] Clave SSH para GitHub Actions..."
if [ "${GITHUB_ACTIONS:-false}" != "true" ]; then
  if [ ! -f "$SSH_KEY_FILE" ]; then
    ssh-keygen -t ed25519 -f "$SSH_KEY_FILE" -N "" -C "github-actions-deploy"
    echo "  ✓ Clave SSH generada: $SSH_KEY_FILE"
  else
    echo "  ✓ Clave SSH ya existe: $SSH_KEY_FILE"
  fi
  SSH_PUBLIC_KEY=$(cat "${SSH_KEY_FILE}.pub")
else
  echo "  ✓ (Ejecutando en GitHub Actions — clave SSH provista por secreto)"
  SSH_PUBLIC_KEY=""
fi

# ── 5. Reglas de firewall ──────────────────────────────────────────────────────
echo ""
echo "[5/6] Reglas de firewall..."

# Puertos de la aplicación
for PORT in "$PORT_VOTE" "$PORT_RESULT"; do
  RULE="allow-microservices-$PORT"
  if ! gcloud compute firewall-rules describe "$RULE" \
      --project="$GCP_PROJECT_ID" &>/dev/null; then
    gcloud compute firewall-rules create "$RULE" \
      --allow="tcp:$PORT" \
      --target-tags="microservices-demo" \
      --description="Microservices demo — puerto $PORT" \
      --project="$GCP_PROJECT_ID" \
      --quiet
    echo "  ✓ Regla $RULE creada"
  else
    echo "  ✓ Regla $RULE ya existe"
  fi
done

# Puerto SSH para GitHub Actions
if ! gcloud compute firewall-rules describe "allow-ssh-microservices" \
    --project="$GCP_PROJECT_ID" &>/dev/null; then
  gcloud compute firewall-rules create "allow-ssh-microservices" \
    --allow="tcp:22" \
    --target-tags="microservices-demo" \
    --description="SSH para despliegue desde GitHub Actions" \
    --project="$GCP_PROJECT_ID" \
    --quiet
  echo "  ✓ Regla SSH creada"
else
  echo "  ✓ Regla SSH ya existe"
fi

# ── 6. VMs de Compute Engine (una por ambiente) ────────────────────────────────
echo ""
echo "[6/6] Máquinas virtuales..."

# Script de inicio que se ejecuta automáticamente cuando la VM arranca por primera vez.
# Instala Docker, Docker Compose y gcloud CLI, y crea el directorio de trabajo.
STARTUP_SCRIPT=$(cat << SCRIPT
#!/bin/bash
set -e
export DEBIAN_FRONTEND=noninteractive

# Docker
if ! command -v docker &>/dev/null; then
  apt-get update -qq
  apt-get install -y -qq ca-certificates curl
  curl -fsSL https://get.docker.com | sh
  usermod -aG docker $VM_ADMIN_USER
  echo "Docker instalado"
else
  echo "Docker ya instalado"
fi

# Docker Compose plugin
if ! docker compose version &>/dev/null; then
  apt-get install -y -qq docker-compose-plugin
  echo "Docker Compose instalado"
else
  echo "Docker Compose ya instalado"
fi

# gcloud CLI
if ! command -v gcloud &>/dev/null; then
  curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg \
    | gpg --dearmor -o /usr/share/keyrings/cloud.google.gpg
  echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" \
    | tee /etc/apt/sources.list.d/google-cloud-sdk.list
  apt-get update -qq
  apt-get install -y -qq google-cloud-cli
  echo "gcloud CLI instalado"
else
  echo "gcloud CLI ya instalado"
fi

# Directorio de trabajo
mkdir -p /opt/microservices-demo
chown $VM_ADMIN_USER:$VM_ADMIN_USER /opt/microservices-demo
SCRIPT
)

for ENV in "${ENVIRONMENTS[@]}"; do
  VM_NAME="microservices-demo-$ENV"
  echo "  Procesando VM: $VM_NAME ($ENV)..."

  # Crear VM si no existe
  if ! gcloud compute instances describe "$VM_NAME" \
      --zone="$GCE_ZONE" \
      --project="$GCP_PROJECT_ID" &>/dev/null; then

    # Preparar metadata: startup-script + clave SSH (si está disponible)
    METADATA_ARGS="startup-script=$STARTUP_SCRIPT"
    if [ -n "$SSH_PUBLIC_KEY" ]; then
      METADATA_ARGS="$METADATA_ARGS,ssh-keys=$VM_ADMIN_USER:$SSH_PUBLIC_KEY"
    fi

    gcloud compute instances create "$VM_NAME" \
      --zone="$GCE_ZONE" \
      --machine-type="$VM_MACHINE_TYPE" \
      --image-family=ubuntu-2404-lts-amd64 \
      --image-project=ubuntu-os-cloud \
      --service-account="$VM_SA_EMAIL" \
      --scopes=cloud-platform \
      --tags=microservices-demo \
      --metadata="$METADATA_ARGS" \
      --project="$GCP_PROJECT_ID" \
      --quiet
    echo "    ✓ VM $VM_NAME creada (Docker se instalará en el primer arranque)"
  else
    echo "    ✓ VM $VM_NAME ya existe"

    # Actualizar clave SSH si está disponible (para VMs existentes)
    if [ -n "$SSH_PUBLIC_KEY" ]; then
      gcloud compute instances add-metadata "$VM_NAME" \
        --zone="$GCE_ZONE" \
        --project="$GCP_PROJECT_ID" \
        --metadata="ssh-keys=$VM_ADMIN_USER:$SSH_PUBLIC_KEY" \
        --quiet
      echo "    ✓ Clave SSH actualizada en $VM_NAME"
    fi
  fi
done

# ── Resumen de IPs externas ────────────────────────────────────────────────────
echo ""
echo "IPs externas de las VMs:"
for ENV in "${ENVIRONMENTS[@]}"; do
  VM_NAME="microservices-demo-$ENV"
  IP=$(gcloud compute instances describe "$VM_NAME" \
    --zone="$GCE_ZONE" \
    --project="$GCP_PROJECT_ID" \
    --format="get(networkInterfaces[0].accessConfigs[0].natIP)")
  echo "  $ENV → $IP"
  echo "         vote:   http://$IP:$PORT_VOTE"
  echo "         result: http://$IP:$PORT_RESULT"
done

echo ""
echo "==========================================="
echo " Aprovisionamiento completado exitosamente"
echo "==========================================="
echo ""
echo "Próximos pasos:"
echo "  1. Espera ~2 min para que el startup-script instale Docker en las VMs"
echo "  2. Agrega las IPs como secretos en GitHub:"
echo "       GCP_VM_HOST_DEV, GCP_VM_HOST_STAGING, GCP_VM_HOST_PROD"
if [ "${GITHUB_ACTIONS:-false}" != "true" ]; then
  echo "  3. Agrega la clave SSH privada como secreto GCP_VM_SSH_KEY:"
  echo "       cat $SSH_KEY_FILE"
  echo "  4. Agrega el usuario SSH como secreto GCP_VM_USERNAME: $VM_ADMIN_USER"
fi
