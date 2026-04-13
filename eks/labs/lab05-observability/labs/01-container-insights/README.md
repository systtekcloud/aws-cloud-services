# Sub-lab 01: Container Insights

## Objetivo

Habilitar Container Insights en EKS, navegar los dashboards de CloudWatch, y crear alarmas para CPU y memoria.

---

## Paso 1: Habilitar Container Insights como add-on

```bash
# Opción A: Al crear el cluster (recomendado)
aws eks create-cluster \
  --name eks-dev \
  --logging '{"clusterLogging":[{"types":["api","audit","authenticator"],"enabled":true}]}'

# Opción B: En un cluster existente
aws eks update-cluster-config \
  --name eks-dev \
  --logging '{"clusterLogging":[{"types":["api","audit","authenticator","controllerManager","scheduler"],"enabled":true}]}'

# Instalar el add-on de Container Insights (CloudWatch Observability)
aws eks create-addon \
  --cluster-name eks-dev \
  --addon-name amazon-cloudwatch-observability

# El add-on instala:
# - CloudWatch Agent (métricas de pods, nodos)
# - Fluent Bit (logs → CloudWatch)
# Tardará 2-3 minutos

# Verificar
aws eks describe-addon --cluster-name eks-dev --addon-name amazon-cloudwatch-observability
```

## Paso 2: Ver métricas en CloudWatch

```bash
# Las métricas aparecen bajo el namespace: ContainerInsights
# Dimensiones disponibles: ClusterName, Namespace, PodName, NodeName

# Ver métricas de un namespace específico desde CLI
aws cloudwatch get-metric-statistics \
  --namespace ContainerInsights \
  --metric-name pod_cpu_utilization \
  --dimensions Name=ClusterName,Value=eks-dev Name=Namespace,Value=workloads \
  --statistics Average \
  --start-time $(date -u -d '30 minutes ago' +%Y-%m-%dT%H:%M:%SZ) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%SZ) \
  --period 60
```

## Paso 3: Dashboard automático de Container Insights

```
AWS Console → CloudWatch → Container Insights → Performance Monitoring

Seleccionar:
- EKS Clusters → eks-dev
- Ver: Cluster, Nodes, Namespaces, Services, Pods

Métricas disponibles:
  CPU utilization     → por cluster / namespace / pod
  Memory utilization  → por cluster / namespace / pod
  Network received/transmitted bytes
  Disk I/O (para Managed Nodes)
  Pod restarts         → señal de OOMKilled o crashloops
```

## Paso 4: Crear alarma de CloudWatch para CPU alta

```bash
# Alarma: si algún pod en namespace "workloads" supera 80% CPU por 5 minutos
aws cloudwatch put-metric-alarm \
  --alarm-name "eks-high-cpu-workloads" \
  --alarm-description "CPU alta en namespace workloads" \
  --namespace ContainerInsights \
  --metric-name pod_cpu_utilization \
  --dimensions Name=ClusterName,Value=eks-dev Name=Namespace,Value=workloads \
  --statistic Average \
  --period 60 \
  --evaluation-periods 5 \
  --threshold 80 \
  --comparison-operator GreaterThanThreshold \
  --alarm-actions "arn:aws:sns:eu-west-1:123456789:alertas-eks"

# Alarma para pod restarts (señal de crashloop)
aws cloudwatch put-metric-alarm \
  --alarm-name "eks-pod-restarts-workloads" \
  --alarm-description "Pods reiniciando frecuentemente" \
  --namespace ContainerInsights \
  --metric-name pod_number_of_container_restarts \
  --dimensions Name=ClusterName,Value=eks-dev Name=Namespace,Value=workloads \
  --statistic Sum \
  --period 300 \
  --evaluation-periods 1 \
  --threshold 5 \
  --comparison-operator GreaterThanThreshold \
  --alarm-actions "arn:aws:sns:eu-west-1:123456789:alertas-eks"
```

## Paso 5: Logs de Control Plane en CloudWatch

```bash
# Los logs del control plane van a /aws/eks/{cluster}/cluster
aws logs describe-log-groups --log-group-name-prefix "/aws/eks/eks-dev"
# /aws/eks/eks-dev/cluster → api server, authenticator, scheduler, controller-manager

# Ver logs del API server (audit trail de kubectl)
aws logs filter-log-events \
  --log-group-name "/aws/eks/eks-dev/cluster" \
  --log-stream-names "kube-apiserver-audit-*" \
  --filter-pattern '{ $.user.username = "admin" }' \
  --start-time $(date -d '1 hour ago' +%s)000

# Buscar errores en el authenticator (fallos de IRSA)
aws logs filter-log-events \
  --log-group-name "/aws/eks/eks-dev/cluster" \
  --log-stream-names "authenticator-*" \
  --filter-pattern "ERROR"
```
