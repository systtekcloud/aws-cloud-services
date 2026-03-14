# Troubleshooting 01 — RDS Proxy: Errores de conexión y configuración

## Escenario

La aplicación intenta conectarse a través del RDS Proxy y obtiene:

```
ERROR 2003 (HY000): Can't connect to MySQL server on 'aurora-lab05-proxy.proxy-xxx.eu-west-1.rds.amazonaws.com'
```

O bien, el Proxy se crea pero sus targets permanecen en estado `UNAVAILABLE`.

---

## Diagnóstico

### Paso 1: Verificar estado del Proxy

```bash
aws rds describe-db-proxies \
  --db-proxy-name aurora-lab05-proxy \
  --query 'DBProxies[0].{Status:Status,Endpoint:Endpoint}' \
  --output table --region eu-west-1
```

Estados posibles:
- `available` — Proxy operativo
- `creating` — Creándose (~5 min)
- `modifying` — Actualizándose
- `incompatible-network` — **Problema de red/SG**

### Paso 2: Verificar estado de los targets

```bash
aws rds describe-db-proxy-targets \
  --db-proxy-name aurora-lab05-proxy \
  --query 'Targets[*].{Endpoint:Endpoint,State:TargetHealth.State,Reason:TargetHealth.Reason}' \
  --output table --region eu-west-1
```

Si `State = UNAVAILABLE`, el campo `Reason` indica la causa exacta.

### Paso 3: Verificar conectividad del SG

```bash
# El SG del Proxy debe permitir inbound 3306 desde el SG de la app
SG_PROXY=$(aws rds describe-db-proxies \
  --db-proxy-name aurora-lab05-proxy \
  --query 'DBProxies[0].VpcSecurityGroupIds[0]' --output text --region eu-west-1)

aws ec2 describe-security-groups \
  --group-ids $SG_PROXY \
  --query 'SecurityGroups[0].IpPermissions' \
  --output json --region eu-west-1
```

---

## Causas y soluciones

### Causa 1 — El Proxy no puede acceder al Secret en Secrets Manager

**Síntoma:** Targets en `UNAVAILABLE` con reason `"SECRETS_MANAGER_ACCESS_DENIED"` o `"PENDING_PROXY_CAPACITY"`.

```bash
# Verificar que el rol IAM tiene permisos sobre el secret
PROXY_ROLE="rds-proxy-lab05-role"

# Ver políticas del rol
aws iam list-role-policies --role-name $PROXY_ROLE --output table
aws iam get-role-policy --role-name $PROXY_ROLE --policy-name AllowSecretsManager

# El Resource del policy debe coincidir con el ARN exacto del secret
SECRET_ARN=$(aws secretsmanager describe-secret \
  --secret-id "lab05/aurora/admin" \
  --query 'ARN' --output text --region eu-west-1)
echo "Secret ARN: $SECRET_ARN"
```

**Fix:**

```bash
aws iam put-role-policy --role-name $PROXY_ROLE --policy-name AllowSecretsManager \
  --policy-document "{
    \"Version\":\"2012-10-17\",
    \"Statement\":[{
      \"Effect\":\"Allow\",
      \"Action\":[\"secretsmanager:GetSecretValue\",\"secretsmanager:DescribeSecret\"],
      \"Resource\":\"${SECRET_ARN}\"
    }]
  }"
```

> **Importante:** Después de cambiar el IAM rol, puede tardar hasta 10 minutos en que el Proxy lo detecte.

### Causa 2 — El formato del secret es incorrecto

El Proxy espera un JSON con campos exactos. El formato requerido:

```json
{
  "username": "admin",
  "password": "tu-password",
  "host": "aurora-lab05.cluster-xxx.eu-west-1.rds.amazonaws.com",
  "port": 3306,
  "dbname": "ecommerce"
}
```

**Verificar:**

```bash
aws secretsmanager get-secret-value \
  --secret-id "lab05/aurora/admin" \
  --query 'SecretString' --output text --region eu-west-1 | python3 -m json.tool
```

**Fix si el formato es incorrecto:**

```bash
CLUSTER_ENDPOINT=$(aws rds describe-db-clusters \
  --db-cluster-identifier aurora-lab05 \
  --query 'DBClusters[0].Endpoint' --output text --region eu-west-1)

aws secretsmanager update-secret \
  --secret-id "lab05/aurora/admin" \
  --secret-string "{\"username\":\"admin\",\"password\":\"TU_PASSWORD\",\"host\":\"${CLUSTER_ENDPOINT}\",\"port\":3306,\"dbname\":\"ecommerce\"}" \
  --region eu-west-1
```

### Causa 3 — Security Group: Proxy sin acceso a Aurora

El flujo correcto de SGs es: **App SG → Proxy SG → Aurora SG**

```bash
# Verificar que Aurora acepta conexiones del SG del Proxy
SG_AURORA=$(aws rds describe-db-clusters \
  --db-cluster-identifier aurora-lab05 \
  --query 'DBClusters[0].VpcSecurityGroups[0].VpcSecurityGroupId' \
  --output text --region eu-west-1)

aws ec2 describe-security-groups \
  --group-ids $SG_AURORA \
  --query 'SecurityGroups[0].IpPermissions[?FromPort==`3306`]' \
  --output json --region eu-west-1
```

El SG de Aurora debe tener inbound TCP 3306 desde el SG del Proxy.

**Fix:**

```bash
SG_PROXY=$(aws rds describe-db-proxies \
  --db-proxy-name aurora-lab05-proxy \
  --query 'DBProxies[0].VpcSecurityGroupIds[0]' --output text --region eu-west-1)

aws ec2 authorize-security-group-ingress \
  --group-id $SG_AURORA \
  --protocol tcp --port 3306 \
  --source-group $SG_PROXY \
  --region eu-west-1
```

### Causa 4 — El Proxy y Aurora están en subnets distintas o diferentes VPCs

```bash
# Subnets del Proxy
aws rds describe-db-proxies \
  --db-proxy-name aurora-lab05-proxy \
  --query 'DBProxies[0].VpcSubnetIds' --output json --region eu-west-1

# Subnets de Aurora
aws rds describe-db-clusters \
  --db-cluster-identifier aurora-lab05 \
  --query 'DBClusters[0].DBSubnetGroup' --output text --region eu-west-1
```

Ambos deben estar en la **misma VPC**. Las subnets no necesitan ser idénticas, pero deben estar en la misma VPC y tener routing entre ellas.

### Causa 5 — Error "too many connections" todavía después de implementar el Proxy

Si el mensaje es `ERROR 1040: Too many connections` incluso con el Proxy, la aplicación se está conectando **directamente a Aurora** en vez de al Proxy.

**Diagnóstico:**

```bash
# Verificar cuál endpoint usa la app
# El endpoint del Proxy tiene formato: .proxy-xxx.
# El endpoint de Aurora tiene formato:  .cluster-xxx.

# En la app, buscar la variable de conexión
grep -r "endpoint\|aurora\|mysql\|DATABASE_URL" /path/to/app/config/
```

**Fix:** Actualizar la variable de entorno/config de la app para apuntar al Proxy:

```bash
# Proxy endpoint (usar este)
PROXY_ENDPOINT=$(aws rds describe-db-proxies \
  --db-proxy-name aurora-lab05-proxy \
  --query 'DBProxies[0].Endpoint' --output text --region eu-west-1)
echo $PROXY_ENDPOINT
# Ejemplo: aurora-lab05-proxy.proxy-c0abc123.eu-west-1.rds.amazonaws.com
```

---

## Resumen SAA-C03

| Pregunta | Respuesta |
|----------|-----------|
| ¿Para qué sirve RDS Proxy? | Pool de conexiones: N conexiones de clientes → M conexiones reales a Aurora |
| ¿Cuándo es obligatorio? | Lambda → Aurora (Lambda abre/cierra conexión en cada invocación) |
| ¿Cómo autentica al backend? | Usa un secret de Secrets Manager (no pide credenciales a la app) |
| ¿Afecta al endpoint de la app? | Sí: cambiar `aurora.cluster-xxx` por `aurora-proxy.proxy-xxx` |
| ¿Soporta Multi-AZ? | El Proxy sobrevive el failover de Aurora sin cambio de endpoint |
| ¿RDS Proxy tiene IP pública? | No — solo accesible dentro de la VPC |
