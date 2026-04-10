#!/bin/bash
# provision-azure.sh
# Aprovisiona los recursos de Azure necesarios para el pipeline de CD.
# Es IDEMPOTENTE: puede ejecutarse múltiples veces sin efectos secundarios.
#
# Variables de entorno requeridas:
#   RESOURCE_GROUP   → nombre del grupo de recursos (ej. microservices-demo-rg)
#   LOCATION         → región de Azure              (ej. eastus)
#   ACR_NAME         → nombre del Azure Container Registry (ej. microdemo)
#
# Variables de entorno opcionales:
#   VM_SIZE          → tamaño de las VMs            (default: Standard_B2s)
#   VM_ADMIN_USER    → usuario SSH de las VMs       (default: azureuser)
#
# Uso:
#   export RESOURCE_GROUP=microservices-demo-rg
#   export LOCATION=eastus
#   export ACR_NAME=microdemo
#   bash scripts/provision-azure.sh

set -euo pipefail

# ── Configuración ──────────────────────────────────────────────────────────────
RESOURCE_GROUP="${RESOURCE_GROUP:?Variable RESOURCE_GROUP no definida}"
LOCATION="${LOCATION:?Variable LOCATION no definida}"
ACR_NAME="${ACR_NAME:?Variable ACR_NAME no definida}"
VM_SIZE="${VM_SIZE:-Standard_B2s}"
VM_ADMIN_USER="${VM_ADMIN_USER:-azureuser}"

ENVIRONMENTS=(dev staging prod)

# Puertos expuestos en cada VM
PORT_VOTE=8080
PORT_RESULT=4000

echo "==========================================="
echo " Aprovisionando infraestructura de Azure"
echo " Grupo de recursos : $RESOURCE_GROUP"
echo " Región            : $LOCATION"
echo " ACR               : $ACR_NAME"
echo "==========================================="

# ── 1. Grupo de recursos ───────────────────────────────────────────────────────
echo ""
echo "[1/4] Grupo de recursos..."
az group create \
  --name "$RESOURCE_GROUP" \
  --location "$LOCATION" \
  --output none
echo "  ✓ $RESOURCE_GROUP listo"

# ── 2. Azure Container Registry ────────────────────────────────────────────────
echo ""
echo "[2/4] Azure Container Registry..."
if ! az acr show --name "$ACR_NAME" --resource-group "$RESOURCE_GROUP" &>/dev/null; then
  az acr create \
    --resource-group "$RESOURCE_GROUP" \
    --name "$ACR_NAME" \
    --sku Basic \
    --admin-enabled false \
    --output none
  echo "  ✓ ACR $ACR_NAME creado"
else
  echo "  ✓ ACR $ACR_NAME ya existe, sin cambios"
fi

ACR_ID=$(az acr show \
  --name "$ACR_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --query id -o tsv)

# ── 3. VMs de Azure (una por ambiente) ─────────────────────────────────────────
echo ""
echo "[3/4] Máquinas virtuales..."

for ENV in "${ENVIRONMENTS[@]}"; do
  VM_NAME="microservices-demo-$ENV"
  echo "  Procesando VM: $VM_NAME ($ENV)..."

  # Crear VM si no existe
  if ! az vm show --resource-group "$RESOURCE_GROUP" --name "$VM_NAME" &>/dev/null; then
    az vm create \
      --resource-group "$RESOURCE_GROUP" \
      --name "$VM_NAME" \
      --image Ubuntu2404 \
      --size "$VM_SIZE" \
      --admin-username "$VM_ADMIN_USER" \
      --generate-ssh-keys \
      --assign-identity '[system]' \
      --output none
    echo "    ✓ VM $VM_NAME creada"
  else
    echo "    ✓ VM $VM_NAME ya existe"
  fi

  # Abrir puertos (idempotente: falla silenciosamente si ya existen)
  az vm open-port \
    --resource-group "$RESOURCE_GROUP" \
    --name "$VM_NAME" \
    --port "$PORT_VOTE" \
    --priority 100 \
    --output none 2>/dev/null || true

  az vm open-port \
    --resource-group "$RESOURCE_GROUP" \
    --name "$VM_NAME" \
    --port "$PORT_RESULT" \
    --priority 110 \
    --output none 2>/dev/null || true

  # Obtener el Principal ID de la Managed Identity de la VM
  PRINCIPAL_ID=$(az vm show \
    --resource-group "$RESOURCE_GROUP" \
    --name "$VM_NAME" \
    --query "identity.principalId" -o tsv)

  # Asignar rol AcrPull si no está asignado
  EXISTING_ROLE=$(az role assignment list \
    --assignee "$PRINCIPAL_ID" \
    --role AcrPull \
    --scope "$ACR_ID" \
    --query "length(@)" -o tsv)

  if [ "$EXISTING_ROLE" -eq 0 ]; then
    az role assignment create \
      --assignee "$PRINCIPAL_ID" \
      --role AcrPull \
      --scope "$ACR_ID" \
      --output none
    echo "    ✓ Rol AcrPull asignado a $VM_NAME"
  else
    echo "    ✓ Rol AcrPull ya asignado a $VM_NAME"
  fi

  # Instalar Docker, Docker Compose y Azure CLI en la VM
  echo "    Instalando Docker y Azure CLI en $VM_NAME..."
  az vm run-command invoke \
    --resource-group "$RESOURCE_GROUP" \
    --name "$VM_NAME" \
    --command-id RunShellScript \
    --scripts '
      set -e
      # Docker
      if ! command -v docker &>/dev/null; then
        apt-get update -qq
        apt-get install -y -qq ca-certificates curl
        curl -fsSL https://get.docker.com | sh
        usermod -aG docker '"$VM_ADMIN_USER"'
        echo "Docker instalado"
      else
        echo "Docker ya instalado"
      fi

      # Docker Compose plugin (incluido en Docker Desktop, verificar)
      docker compose version &>/dev/null || (
        apt-get install -y -qq docker-compose-plugin
        echo "Docker Compose plugin instalado"
      )

      # Azure CLI
      if ! command -v az &>/dev/null; then
        curl -sL https://aka.ms/InstallAzureCLIDeb | bash
        echo "Azure CLI instalado"
      else
        echo "Azure CLI ya instalado"
      fi

      # Directorio de trabajo
      mkdir -p /opt/microservices-demo
      chown '"$VM_ADMIN_USER"':'"$VM_ADMIN_USER"' /opt/microservices-demo
    ' \
    --output none
  echo "    ✓ Dependencias listas en $VM_NAME"
done

# ── 4. Resumen de IPs públicas ─────────────────────────────────────────────────
echo ""
echo "[4/4] IPs públicas de las VMs:"
for ENV in "${ENVIRONMENTS[@]}"; do
  VM_NAME="microservices-demo-$ENV"
  IP=$(az vm show \
    --resource-group "$RESOURCE_GROUP" \
    --name "$VM_NAME" \
    --show-details \
    --query publicIps -o tsv)
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
echo "  1. Agrega las IPs como secretos en GitHub:"
echo "       AZURE_VM_HOST_DEV, AZURE_VM_HOST_STAGING, AZURE_VM_HOST_PROD"
echo "  2. Agrega la clave SSH generada como secreto AZURE_VM_SSH_KEY"
echo "       Ubicación: ~/.ssh/id_rsa (generada por --generate-ssh-keys)"
