# Troubleshooting #3 — Container Insights: costes inesperados en factura

## Síntoma

Aparece un cargo inesperado en AWS Cost Explorer bajo **CloudWatch → Custom Metrics** o **CloudWatch → Vended Metrics** que no estaba en el presupuesto.

---

## Por qué Container Insights tiene coste

Container Insights publica métricas **custom** en CloudWatch (no son las métricas gratuitas estándar de AWS). El modelo de precios es por **métrica-mes**:

```
CloudWatch Metrics pricing (eu-west-1):
  Primeras 10,000 métricas: $0.30/métrica/mes
  Siguientes 240,000:        $0.10/métrica/mes
```

### Métricas que genera Container Insights por recurso

| Dimensión | Métricas por defecto | Notas |
|-----------|---------------------|-------|
| Cluster | ~10 métricas | ContainerCount, TaskCount, etc. |
| Service | ~10 métricas × N services | Por cada service en el cluster |
| Task | ~10 métricas × N tasks | Por cada task definida |
| Container | ~5 métricas × N containers | Por cada container en tasks |

**Ejemplo de coste real con la arquitectura de este lab**:
```
Cluster:  1 cluster × 10 métricas = 10
Services: 2 services × 10 métricas = 20
Tasks:    2 task defs × 10 métricas = 20
Containers: 2 containers × 5 métricas = 10

Total: ~60 métricas × $0.30/mes = $18/mes adicionales
```

> Para arquitecturas grandes (20+ services, 100+ tasks): puede superar $200-500/mes solo en métricas de Container Insights.

---

## Diagnóstico

### Ver el estado actual de Container Insights

```bash
# Verificar si está habilitado en el cluster
aws ecs describe-clusters \
  --clusters shopapi-cluster \
  --include SETTINGS \
  --query 'clusters[0].settings'

# Resultado si habilitado:
# [{"name": "containerInsights", "value": "enabled"}]
# Resultado si deshabilitado:
# [{"name": "containerInsights", "value": "disabled"}]
```

### Ver el gasto en Cost Explorer via CLI

```bash
# Coste de Container Insights en el último mes
aws ce get-cost-and-usage \
  --time-period Start=$(date -d 'first day of last month' +%Y-%m-%d),End=$(date +%Y-%m-%d) \
  --granularity MONTHLY \
  --filter '{"Dimensions": {"Key": "SERVICE", "Values": ["AmazonCloudWatch"]}}' \
  --group-by '[{"Type": "DIMENSION", "Key": "USAGE_TYPE"}]' \
  --metrics BlendedCost
```

---

## Solución: deshabilitar en entornos no productivos

```bash
# Deshabilitar Container Insights en el cluster de dev/staging
aws ecs update-cluster-settings \
  --cluster shopapi-cluster-dev \
  --settings name=containerInsights,value=disabled

echo "✅ Container Insights deshabilitado en dev"
```

---

## Estrategia recomendada por entorno

| Entorno | Container Insights | Justificación |
|---------|------------------|---------------|
| **dev** | ❌ Deshabilitado | No necesita métricas detalladas; CloudWatch básico suficiente |
| **staging** | ⚠️ Opcional | Habilitar solo si estás investigando un problema específico |
| **prod** | ✅ Habilitado | El coste se justifica con la visibilidad operacional |

---

## Alternativas más económicas

### Opción 1: Métricas básicas de ECS (gratuitas)

Sin Container Insights, ECS publica automáticamente en CloudWatch:
- `CPUUtilization` y `MemoryUtilization` a nivel Service (no Task)
- Sin coste adicional

```bash
# Ver métricas básicas disponibles sin Container Insights
aws cloudwatch list-metrics \
  --namespace AWS/ECS \
  --dimensions Name=ClusterName,Value=shopapi-cluster \
  --query 'Metrics[].MetricName' \
  --output table
```

### Opción 2: Prometheus + Grafana (coste variable)

Para grandes instalaciones, exportar métricas ECS a Prometheus/Grafana puede ser más económico que Container Insights, pero añade complejidad operacional.

### Opción 3: CloudWatch embedded metrics format (EMF)

Publicar métricas custom directamente desde la aplicación usando el formato EMF (estructurado en logs). Paga solo las métricas que realmente necesitas.

---

## Conceptos clave para el examen

| Pregunta | Respuesta |
|---------|-----------|
| ¿Container Insights está habilitado por defecto? | **No**, hay que habilitarlo explícitamente |
| ¿Qué tipo de métricas publica? | Métricas **custom** de CloudWatch ($0.30/métrica/mes) |
| ¿Cómo habilitarlo? | `aws ecs update-cluster-settings --settings name=containerInsights,value=enabled` |
| ¿Qué métricas son gratuitas en ECS? | `CPUUtilization` y `MemoryUtilization` del namespace `AWS/ECS` |
| ¿Se puede habilitar por servicio? | No — es a nivel de **cluster** |
