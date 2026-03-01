#!/usr/bin/env bash
# =============================================================================
# Lab v1 — ShopAPI en ECS Fargate
# Script 01: ECR — Crear repositorio, build y push de imagen Docker
#
# Uso:
#   export APP_DIR="/ruta/a/shopapi"
#   bash cli/01-ecr.sh
#
# Requiere: aws-cli >= 2.0, docker >= 20.0
# =============================================================================
set -euo pipefail

# -----------------------------------------------------------------------------
# Colores para output legible en terminal
# -----------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # Sin color

info()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
ok()      { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }
section() { echo -e "\n${YELLOW}========================================${NC}"; \
            echo -e "${YELLOW}  $*${NC}"; \
            echo -e "${YELLOW}========================================${NC}\n"; }

# =============================================================================
# SECCION 1: Verificacion de prerrequisitos
# =============================================================================
section "Verificando prerrequisitos"

# Verificar AWS CLI
if ! command -v aws &>/dev/null; then
  error "aws-cli no encontrado. Instalar desde: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html"
fi
AWS_VERSION=$(aws --version 2>&1 | awk '{print $1}' | cut -d'/' -f2)
ok "aws-cli version: ${AWS_VERSION}"

# Verificar Docker
if ! command -v docker &>/dev/null; then
  error "Docker no encontrado. Instalar desde: https://docs.docker.com/engine/install/"
fi
DOCKER_VERSION=$(docker --version | awk '{print $3}' | tr -d ',')
ok "Docker version: ${DOCKER_VERSION}"

# Verificar que Docker daemon esta corriendo
if ! docker info &>/dev/null; then
  error "Docker daemon no esta corriendo. Ejecutar: sudo systemctl start docker"
fi
ok "Docker daemon: corriendo"

# Verificar credenciales AWS
if ! aws sts get-caller-identity &>/dev/null; then
  error "Credenciales AWS no configuradas. Ejecutar: aws configure"
fi

# =============================================================================
# SECCION 2: Configuracion de variables de entorno
# =============================================================================
section "Configurando variables de entorno"

# Obtener Account ID automaticamente si no esta definido
export AWS_ACCOUNT_ID="${AWS_ACCOUNT_ID:-$(aws sts get-caller-identity --query Account --output text)}"
export AWS_REGION="${AWS_REGION:-eu-west-1}"
export PROJECT_PREFIX="${PROJECT_PREFIX:-shopapi}"
export ECR_REPO_NAME="${ECR_REPO_NAME:-shopapi/api}"
export IMAGE_TAG="${IMAGE_TAG:-0.1.0}"
export APP_DIR="${APP_DIR:-$(pwd)}"

# Construir variables derivadas
export ECR_REGISTRY="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
export ECR_REPO_URI="${ECR_REGISTRY}/${ECR_REPO_NAME}"
export LOCAL_IMAGE_NAME="${PROJECT_PREFIX}-api"

# Mostrar la configuracion activa
echo ""
info "Configuracion activa:"
echo "  AWS Account ID : ${AWS_ACCOUNT_ID}"
echo "  AWS Region     : ${AWS_REGION}"
echo "  ECR Registry   : ${ECR_REGISTRY}"
echo "  ECR Repo URI   : ${ECR_REPO_URI}"
echo "  Image Tag      : ${IMAGE_TAG}"
echo "  App Directory  : ${APP_DIR}"
echo ""

# Verificar que el directorio de la app existe
if [[ ! -d "${APP_DIR}" ]]; then
  error "Directorio de la app no existe: ${APP_DIR}. Exportar APP_DIR correctamente."
fi

# Verificar que existe un Dockerfile
if [[ ! -f "${APP_DIR}/Dockerfile" ]]; then
  error "Dockerfile no encontrado en: ${APP_DIR}. Asegurate de estar en el directorio correcto."
fi

ok "Directorio de la app encontrado con Dockerfile"

# =============================================================================
# SECCION 3: Crear repositorio ECR
# =============================================================================
section "Creando repositorio ECR"

# Comprobar si el repositorio ya existe para no fallar si se re-ejecuta el script
REPO_EXISTS=$(aws ecr describe-repositories \
  --repository-names "${ECR_REPO_NAME}" \
  --region "${AWS_REGION}" \
  --query 'repositories[0].repositoryUri' \
  --output text 2>/dev/null || echo "NO_EXISTE")

if [[ "${REPO_EXISTS}" == "NO_EXISTE" ]]; then
  info "Creando repositorio ECR: ${ECR_REPO_NAME} ..."

  aws ecr create-repository \
    --repository-name "${ECR_REPO_NAME}" \
    --region "${AWS_REGION}" \
    --image-scanning-configuration scanOnPush=true \
    --image-tag-mutability MUTABLE \
    --tags Key=Project,Value="${PROJECT_PREFIX}" Key=Lab,Value=v1

  ok "Repositorio ECR creado: ${ECR_REPO_URI}"
else
  warn "El repositorio ECR ya existe: ${REPO_EXISTS}"
  ok "Reutilizando repositorio existente"
fi

# Verificar que el repositorio esta disponible
REPO_URI=$(aws ecr describe-repositories \
  --repository-names "${ECR_REPO_NAME}" \
  --region "${AWS_REGION}" \
  --query 'repositories[0].repositoryUri' \
  --output text)

ok "URI del repositorio: ${REPO_URI}"

# =============================================================================
# SECCION 4: Autenticar Docker con ECR
# =============================================================================
section "Autenticando Docker con ECR"

# El token de autenticacion de ECR dura 12 horas
# El comando get-login-password obtiene el token y lo pasa a docker login
info "Obteniendo token de autenticacion de ECR ..."
aws ecr get-login-password \
  --region "${AWS_REGION}" \
  | docker login \
    --username AWS \
    --password-stdin \
    "${ECR_REGISTRY}"

ok "Docker autenticado con ECR exitosamente"

# =============================================================================
# SECCION 5: Build de la imagen Docker
# =============================================================================
section "Construyendo imagen Docker"

info "Iniciando build de ${LOCAL_IMAGE_NAME}:${IMAGE_TAG} ..."
info "Contexto de build: ${APP_DIR}"
echo ""

# Build con multiples tags: version especifica y latest
docker build \
  --tag "${LOCAL_IMAGE_NAME}:${IMAGE_TAG}" \
  --tag "${LOCAL_IMAGE_NAME}:latest" \
  --file "${APP_DIR}/Dockerfile" \
  --build-arg APP_VERSION="${IMAGE_TAG}" \
  "${APP_DIR}"

echo ""
ok "Imagen construida exitosamente"

# Mostrar el tamano de la imagen
IMAGE_SIZE=$(docker images "${LOCAL_IMAGE_NAME}:${IMAGE_TAG}" \
  --format "{{.Size}}")
info "Tamano de la imagen: ${IMAGE_SIZE}"

# Verificar rapidamente que la imagen arranca correctamente (smoke test local)
info "Ejecutando smoke test local del contenedor ..."
CONTAINER_ID=$(docker run \
  --detach \
  --rm \
  --publish 8080:8080 \
  --name shopapi-smoke-test \
  --env APP_ENV=production \
  --env APP_VERSION="${IMAGE_TAG}" \
  "${LOCAL_IMAGE_NAME}:${IMAGE_TAG}")

# Esperar a que el contenedor arranque (max 10 segundos)
MAX_WAIT=10
WAIT=0
until curl -sf http://localhost:8080/health &>/dev/null || [[ ${WAIT} -ge ${MAX_WAIT} ]]; do
  sleep 1
  WAIT=$((WAIT + 1))
done

if curl -sf http://localhost:8080/health &>/dev/null; then
  HEALTH_RESPONSE=$(curl -s http://localhost:8080/health)
  ok "Smoke test exitoso. Respuesta: ${HEALTH_RESPONSE}"
else
  warn "Smoke test: el endpoint /health no respondio en ${MAX_WAIT}s. Continuando de todas formas."
fi

# Detener el contenedor de prueba
docker stop shopapi-smoke-test &>/dev/null || true
ok "Contenedor de prueba eliminado"

# =============================================================================
# SECCION 6: Tag y push a ECR
# =============================================================================
section "Subiendo imagen a ECR (tag y push)"

# Tag: asociar la imagen local con la URI completa de ECR
info "Tagging imagen con URI de ECR ..."

docker tag \
  "${LOCAL_IMAGE_NAME}:${IMAGE_TAG}" \
  "${ECR_REPO_URI}:${IMAGE_TAG}"

docker tag \
  "${LOCAL_IMAGE_NAME}:latest" \
  "${ECR_REPO_URI}:latest"

ok "Tags aplicados:"
echo "  ${ECR_REPO_URI}:${IMAGE_TAG}"
echo "  ${ECR_REPO_URI}:latest"

# Push del tag de version especifica
info "Subiendo ${ECR_REPO_URI}:${IMAGE_TAG} ..."
docker push "${ECR_REPO_URI}:${IMAGE_TAG}"
ok "Push de version ${IMAGE_TAG} completado"

# Push del tag latest
info "Subiendo ${ECR_REPO_URI}:latest ..."
docker push "${ECR_REPO_URI}:latest"
ok "Push de 'latest' completado"

# =============================================================================
# SECCION 7: Verificacion final
# =============================================================================
section "Verificacion final"

info "Imagenes en ECR para ${ECR_REPO_NAME}:"
aws ecr list-images \
  --repository-name "${ECR_REPO_NAME}" \
  --region "${AWS_REGION}" \
  --query 'imageIds[*].[imageTag, imageDigest]' \
  --output table

echo ""
ok "Script 01 completado exitosamente"
echo ""
info "Proximos pasos:"
echo "  Ejecutar: bash cli/02-cluster-y-task.sh"
echo ""
info "Variables exportadas para el siguiente script:"
echo "  export AWS_ACCOUNT_ID=${AWS_ACCOUNT_ID}"
echo "  export AWS_REGION=${AWS_REGION}"
echo "  export ECR_REPO_URI=${ECR_REPO_URI}"
echo "  export IMAGE_TAG=${IMAGE_TAG}"
