# Sub-lab 02: Fluent Bit — Logs estructurados a CloudWatch

## Objetivo

Configurar Fluent Bit para enviar logs de pods a CloudWatch Logs con metadata de Kubernetes (namespace, pod, container), y filtrar logs por severidad.

---

## Paso 1: Fluent Bit vía add-on (si no está instalado)

```bash
# Si instalaste amazon-cloudwatch-observability en sub-lab 01, Fluent Bit ya está instalado

# Verificar
kubectl get pods -n amazon-cloudwatch | grep fluent-bit
# fluent-bit-xxxxx   1/1   Running   0   5m   (uno por nodo)

# Ver la configuración actual
kubectl get configmap fluent-bit-config -n amazon-cloudwatch -o yaml
```

## Paso 2: Instalar Fluent Bit standalone (más control)

```bash
# Si quieres configuración personalizada, instala via Helm
helm repo add fluent https://fluent.github.io/helm-charts
helm install fluent-bit fluent/fluent-bit \
  --namespace amazon-cloudwatch \
  --create-namespace \
  --values - <<'EOF'
config:
  service: |
    [SERVICE]
        Flush         5
        Daemon        Off
        Log_Level     info
        HTTP_Server   On
        HTTP_Listen   0.0.0.0
        HTTP_Port     2020

  inputs: |
    [INPUT]
        Name              tail
        Tag               kube.*
        Path              /var/log/containers/*.log
        Parser            docker
        DB                /var/log/flb_kube.db
        Mem_Buf_Limit     5MB
        Skip_Long_Lines   On
        Refresh_Interval  10

  filters: |
    [FILTER]
        Name                kubernetes
        Match               kube.*
        Kube_URL            https://kubernetes.default.svc:443
        Kube_CA_File        /var/run/secrets/kubernetes.io/serviceaccount/ca.crt
        Kube_Token_File     /var/run/secrets/kubernetes.io/serviceaccount/token
        Merge_Log           On
        Keep_Log            Off
        K8S-Logging.Parser  On
        K8S-Logging.Exclude On

    # Excluir logs de kube-system y fluent-bit mismo (reduce costes)
    [FILTER]
        Name    grep
        Match   kube.*
        Exclude $kubernetes['namespace_name'] kube-system
        Exclude $kubernetes['namespace_name'] amazon-cloudwatch

  outputs: |
    [OUTPUT]
        Name                cloudwatch_logs
        Match               kube.*
        region              eu-west-1
        log_group_name      /aws/eks/eks-dev/containers
        log_stream_prefix   ${NAMESPACE}/
        auto_create_group   On
        log_retention_days  30
EOF
```

## Paso 3: Log groups en CloudWatch

```bash
# Ver los log groups creados por Fluent Bit
aws logs describe-log-groups \
  --log-group-name-prefix "/aws/eks/eks-dev/containers"

# Log streams: uno por pod
aws logs describe-log-streams \
  --log-group-name "/aws/eks/eks-dev/containers" \
  --log-stream-name-prefix "workloads/"

# Ver logs de un pod específico
kubectl get pods -n workloads -o jsonpath='{.items[0].metadata.name}'

POD_NAME=$(kubectl get pods -n workloads -l app=demo -o name | head -1 | cut -d'/' -f2)
aws logs filter-log-events \
  --log-group-name "/aws/eks/eks-dev/containers" \
  --log-stream-names "workloads/${POD_NAME}_demo" \
  --start-time $(date -d '10 minutes ago' +%s)000 \
  --query 'events[].message' \
  --output text
```

## Paso 4: Filtros y parseo JSON

```bash
# Si la app escribe JSON en stdout, Fluent Bit lo parsea automáticamente
# y los campos JSON se convierten en campos de CloudWatch Logs

# Ejemplo de log JSON que parsea Fluent Bit:
# {"level":"INFO","message":"Request processed","duration_ms":45,"path":"/api/users"}

# Buscar solo errores con Logs Insights
aws logs start-query \
  --log-group-name "/aws/eks/eks-dev/containers" \
  --start-time $(date -d '1 hour ago' +%s) \
  --end-time $(date +%s) \
  --query-string '
    fields @timestamp, kubernetes.namespace_name, kubernetes.pod_name, message
    | filter level = "ERROR"
    | sort @timestamp desc
    | limit 50
  '
```

## Paso 5: Dashboard de logs con CloudWatch Logs Insights

```
CloudWatch Console → Logs Insights

Query útil para detectar errores frecuentes:
fields @timestamp, kubernetes.namespace_name, kubernetes.pod_name, message
| filter level in ["ERROR", "WARN"]
| stats count(*) as error_count by kubernetes.namespace_name, kubernetes.pod_name
| sort error_count desc
| limit 20

Interpretar:
- Pod con muchos errores → puede estar en crashloop o con un bug
- Namespace con muchos warnings → revisar recursos (CPU throttle, OOM)
```
