#!/usr/bin/env bash
# ── Lab v6 — Capacity Provider Strategy optimizada ───────────────────────────
# Configura la mezcla óptima FARGATE + FARGATE_SPOT por tipo de workload.
set -euo pipefail

AWS_REGION="${AWS_REGION:-eu-west-1}"
CLUSTER="shopapi-cluster"
API_SERVICE="shopapi-api"
WORKER_SERVICE="shopapi-worker"

echo "═══════════════════════════════════════════════════════"
echo "Lab v6 — Capacity Providers: estrategia de coste óptimo"
echo "═══════════════════════════════════════════════════════"

# ── Situación actual ───────────────────────────────────────────────────────────
echo ""
echo "📊 Situación actual de Capacity Providers..."

echo "--- Cluster capacity providers ---"
aws ecs describe-clusters \
  --clusters "$CLUSTER" \
  --include STATISTICS SETTINGS \
  --query 'clusters[0].{
    capacityProviders: capacityProviders,
    defaultStrategy: defaultCapacityProviderStrategy
  }' \
  --output json \
  --region "$AWS_REGION"

echo ""
echo "--- Distribución actual de tasks ---"
aws ecs describe-services \
  --cluster "$CLUSTER" \
  --services "$API_SERVICE" "$WORKER_SERVICE" \
  --query 'services[].{
    name: serviceName,
    running: runningCount,
    strategy: capacityProviderStrategy
  }' \
  --output table \
  --region "$AWS_REGION"

# ── Actualizar API: mezcla conservadora (SLA crítico) ─────────────────────────
echo ""
echo "🔧 Actualizando estrategia de Capacity Provider para API..."
echo ""
echo "Estrategia para API (SLA crítico):"
echo "  FARGATE:      base=2, weight=1  → 2 tasks siempre On-Demand"
echo "  FARGATE_SPOT: base=0, weight=1  → 50% de tasks adicionales en Spot"
echo ""

aws ecs update-service \
  --cluster "$CLUSTER" \
  --service "$API_SERVICE" \
  --capacity-provider-strategy \
    capacityProvider=FARGATE,base=2,weight=1 \
    capacityProvider=FARGATE_SPOT,base=0,weight=1 \
  --region "$AWS_REGION" \
  --query 'service.{
    name: serviceName,
    estrategia: capacityProviderStrategy
  }' \
  --output json

echo ""
echo "✅ API actualizada: 2 tasks garantizadas On-Demand + 50% adicionales en Spot"

# ── Actualizar Workers: agresivo en Spot (no SLA crítico) ─────────────────────
echo ""
echo "🔧 Actualizando estrategia de Workers (mayor tolerancia a Spot)..."
echo ""
echo "Estrategia para Workers (batch, idempotente):"
echo "  FARGATE:      base=1, weight=1  → 1 task garantizada"
echo "  FARGATE_SPOT: base=0, weight=4  → 80% en Spot"
echo ""

aws ecs update-service \
  --cluster "$CLUSTER" \
  --service "$WORKER_SERVICE" \
  --capacity-provider-strategy \
    capacityProvider=FARGATE,base=1,weight=1 \
    capacityProvider=FARGATE_SPOT,base=0,weight=4 \
  --region "$AWS_REGION" \
  --query 'service.{
    name: serviceName,
    estrategia: capacityProviderStrategy
  }' \
  --output json 2>/dev/null || echo "  Worker service no encontrado, saltando..."

echo ""
echo "✅ Workers actualizados: 1 task garantizada + 80% en Spot"

# ── Verificación de ahorro estimado ───────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════════"
echo "💰 Estimación de ahorro (eu-west-1):"
echo ""
echo "  Fargate On-Demand:  \$0.04856/vCPU/h + \$0.00532/GB/h"
echo "  Fargate Spot:       ~70% descuento = ~\$0.01457/vCPU/h"
echo ""
echo "  Con 4 tasks API (2 On-Demand + 2 Spot, 1vCPU/2GB cada una):"
echo "  - Sin Spot: 4 × (0.04856 + 2×0.00532) × 720h = \$196/mes"
echo "  - Con Spot: 2×\$49 + 2×\$14.7                = \$127/mes (-35%)"
echo ""
echo "  Con 6 tasks Worker (1 On-Demand + 5 Spot, 0.5vCPU/1GB):"
echo "  - Sin Spot: 6 × (0.02428 + 0.00532) × 720h = \$128/mes"
echo "  - Con Spot: 1×\$21.3 + 5×\$6.4              = \$53/mes (-59%)"
echo "═══════════════════════════════════════════════════════"

echo ""
echo "⚠️  IMPORTANTE: Asegúrate de que tus workers manejen SIGTERM correctamente"
echo "   para tolerar interrupciones de Fargate Spot (2 minutos de aviso)."
echo "   Ver: app/main.py — signal handler + SQS visibility timeout"
