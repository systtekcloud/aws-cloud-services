# Fase 5 — Flow Logs y Troubleshooting

> **Tiempo:** ~50 min | 💡 **COSTE:** CloudWatch Logs ~0.57€/GB ingestado + 0.03€/GB almacenado | **Coste práctico: < 0.05€**

---

## Objetivo

Activar VPC Flow Logs, generar tráfico de prueba y aprender a leer los logs para diagnosticar 8 escenarios reales de conectividad. Al final entenderás por qué un paquete llega o no llega.

---

## Qué son los Flow Logs (y qué NO son)

```
Flow Logs capturan:                    Flow Logs NO capturan:
✓ IP origen y destino                  ✗ Contenido del paquete (payload)
✓ Puerto origen y destino              ✗ DNS queries internas (Route53 Resolver)
✓ Protocolo (TCP/UDP/ICMP)             ✗ Tráfico DHCP
✓ Bytes y paquetes transferidos        ✗ Metadata del instance store
✓ ACCEPT o REJECT                      ✗ Tráfico al 169.254.169.254 (IMDSv2)
✓ Timestamp inicio/fin de flujo        ✗ Tráfico entre ECS tasks en mismo host
```

---

## Paso 1 — Crear IAM Role para Flow Logs

**Consola:** IAM > Roles > **Create role**

- Service: **EC2** (temporalmente, lo cambiaremos)
- Policy: No añadir ninguna todavía
- Name: `vpc-flow-logs-role`

Tras crear el rol, editar la **Trust Policy**:

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {
      "Service": "vpc-flow-logs.amazonaws.com"
    },
    "Action": "sts:AssumeRole"
  }]
}
```

Añadir Inline Policy:
```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:DescribeLogGroups",
      "logs:DescribeLogStreams"
    ],
    "Resource": "*"
  }]
}
```

<details>
<summary>🔧 CLI equivalente</summary>

```bash
# Trust policy
cat > /tmp/flow-logs-trust.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"Service": "vpc-flow-logs.amazonaws.com"},
    "Action": "sts:AssumeRole"
  }]
}
EOF

aws iam create-role \
  --role-name vpc-flow-logs-role \
  --assume-role-policy-document file://policy/flow-logs-trust.json

# Inline policy
cat > /tmp/flow-logs-policy.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": [
      "logs:CreateLogGroup","logs:CreateLogStream",
      "logs:PutLogEvents","logs:DescribeLogGroups","logs:DescribeLogStreams"
    ],
    "Resource": "*"
  }]
}
EOF

aws iam put-role-policy \
  --role-name vpc-flow-logs-role \
  --policy-name flow-logs-cw \
  --policy-document file://policy/flow-logs-policy.json

FLOW_LOGS_ROLE_ARN=$(aws iam get-role \
  --role-name vpc-flow-logs-role \
  --query 'Role.Arn' --output text)
echo "FLOW_LOGS_ROLE_ARN=$FLOW_LOGS_ROLE_ARN"
```
</details>

---

## Paso 2 — Crear CloudWatch Log Group

**Consola:** CloudWatch > Log groups > **Create log group**
- Name: `/vpc/flow-logs/vpc-lab-dev`
- Retention: **7 days** (para el lab, no acumular datos)

<details>
<summary>🔧 CLI equivalente</summary>

```bash
aws logs create-log-group \
  --log-group-name /vpc/flow-logs/vpc-lab-dev \
  --region $AWS_REGION

aws logs put-retention-policy \
  --log-group-name /vpc/flow-logs/vpc-lab-dev \
  --retention-in-days 7
```
</details>

---

## Paso 3 — Activar VPC Flow Logs

**Consola:** VPC > Your VPCs > seleccionar `vpc-lab-dev` > pestaña **Flow logs** > **Create flow log**

| Campo | Valor |
|-------|-------|
| Filter | **All** (captura ACCEPT y REJECT) |
| Maximum aggregation interval | 1 minute |
| Destination | **Send to CloudWatch Logs** |
| Destination log group | `/vpc/flow-logs/vpc-lab-dev` |
| IAM role | `vpc-flow-logs-role` |
| Log record format | **AWS default format** |

<details>
<summary>🔧 CLI equivalente</summary>

```bash
aws ec2 create-flow-logs \
  --resource-type VPC \
  --resource-ids $VPC_ID \
  --traffic-type ALL \
  --log-destination-type cloud-watch-logs \
  --log-group-name /vpc/flow-logs/vpc-lab-dev \
  --deliver-logs-permission-arn $FLOW_LOGS_ROLE_ARN \
  --max-aggregation-interval 60
```
</details>

✅ **Validación:** En la pestaña Flow logs de la VPC aparece el flow log con estado `Active`.

---

## Paso 4 — Generar tráfico de prueba

Antes de ver los escenarios, genera tráfico variado para tener logs con qué trabajar:

```bash
# TRÁFICO LEGÍTIMO (debe aparecer como ACCEPT)
# 1. SSH al bastion (desde tu máquina)
ssh -i ~/.ssh/vpc-lab-key.pem ec2-user@$BASTION_IP "echo ok"

# 2. Desde bastion al privado
ssh -i ~/.ssh/vpc-lab-key.pem \
    -J ec2-user@$BASTION_IP ec2-user@$APP_PRIV_IP \
    "curl -s https://checkip.amazonaws.com"

# TRÁFICO RECHAZADO (debe aparecer como REJECT)
# 3. Intentar SSH desde bastion directamente a isolated (bloqueado por SG-DB)
ssh -i ~/.ssh/vpc-lab-key.pem \
    -J ec2-user@$BASTION_IP \
    ec2-user@$DB_PRIV_IP -o ConnectTimeout=5 || true

# 4. Intentar HTTP (80) al bastion — SG solo permite 22
curl --connect-timeout 3 http://$BASTION_IP || true

# Esperar 1-2 minutos para que los logs aparezcan en CloudWatch
echo "Esperando 90 segundos para que los logs se propaguen..."
sleep 90
```

---

## Paso 5 — Leer los Flow Logs en CloudWatch

**Consola:** CloudWatch > Log groups > `/vpc/flow-logs/vpc-lab-dev` > seleccionar un log stream

### Formato de un registro de Flow Log

```
version account-id interface-id srcaddr dstaddr srcport dstport protocol packets bytes start end action log-status

Ejemplo ACCEPT:
2 123456789012 eni-0a1b2c3d4e 10.10.1.5 10.10.11.20 54321 22 6 10 1340 1700000000 1700000060 ACCEPT OK

Ejemplo REJECT:
2 123456789012 eni-0a1b2c3d4e 10.10.1.5 10.10.21.30 54322 22 6 1 40 1700000000 1700000060 REJECT OK
```

| Campo | Ejemplo | Significa |
|-------|---------|-----------|
| `interface-id` | `eni-0a1b2c3d4e` | ENI de la instancia destino |
| `srcaddr` | `10.10.1.5` | IP origen del paquete |
| `dstaddr` | `10.10.11.20` | IP destino |
| `srcport` | `54321` | Puerto efímero del cliente |
| `dstport` | `22` | Puerto del servicio |
| `protocol` | `6` | TCP (6=TCP, 17=UDP, 1=ICMP) |
| `action` | `ACCEPT` | SG o NACL permitió/rechazó |

---

## 8 Escenarios de Troubleshooting

---

### Escenario 1 — REJECT por Security Group (regla faltante)

**Síntoma:** No puedo hacer SSH a `app-private-a` desde internet.

**Log esperado:**
```
srcaddr=<tu_IP_publica>  dstaddr=10.10.11.20  dstport=22  action=REJECT
```

**Query CloudWatch Logs Insights:**
```sql
fields @timestamp, srcAddr, dstAddr, dstPort, action
| filter action="REJECT" and dstPort=22
| sort @timestamp desc
| limit 20
```

**Diagnóstico:** El SG `sg-app` solo permite SSH desde `sg-bastion`, no desde IPs públicas externas. Correcto por diseño — no es un error.

**Solución si fuera un bug:** Añadir regla inbound en SG-App para el puerto y origen correcto.

---

### Escenario 2 — REJECT por NACL (puertos efímeros bloqueados)

**Síntoma:** La conexión SSH se establece pero los comandos se quedan colgados / sin respuesta.

**Log esperado:**
```
# Inbound ACCEPT (el SYN llegó)
srcaddr=10.10.11.20  dstaddr=10.10.21.30  dstport=22  action=ACCEPT

# Outbound REJECT (la respuesta no sale — NACL bloquea efímeros)
srcaddr=10.10.21.30  dstaddr=10.10.11.20  srcport=22  dstport=54321  action=REJECT
```

**Query:**
```sql
fields @timestamp, srcAddr, dstAddr, srcPort, dstPort, action
| filter action="REJECT" and srcPort=22
| sort @timestamp desc
```

**Diagnóstico:** NACL con regla DENY en outbound que bloquea puertos 1024-65535. El SG es stateful (permite la respuesta), pero la NACL es stateless y necesita la regla explícita.

**Solución:** Añadir regla NACL outbound `ALLOW TCP 1024-65535` hacia el CIDR origen.

---

### Escenario 3 — ACCEPT pero sin conectividad (problema de routing)

**Síntoma:** Los logs muestran ACCEPT, pero la aplicación no conecta.

**Log esperado:**
```
# Entrada ACCEPT en instancia destino
srcaddr=10.10.11.20  dstaddr=10.10.21.30  dstport=5432  action=ACCEPT

# Pero la respuesta va por otro camino (o no hay ruta de vuelta)
```

**Query:**
```sql
fields @timestamp, srcAddr, dstAddr, dstPort, action, interfaceId
| filter (srcAddr="10.10.11.20" or dstAddr="10.10.11.20")
| sort @timestamp desc
```

**Diagnóstico:** El tráfico llega a la instancia destino (ACCEPT en su ENI), pero la respuesta no tiene ruta de vuelta al origen. Típico cuando faltan rutas en alguna RT o hay rutas asimétricas en escenarios de Peering/TGW.

---

### Escenario 4 — Sin logs (problema de IAM o configuración)

**Síntoma:** Hay actividad en la VPC pero no aparece nada en CloudWatch.

**Posibles causas y diagnóstico:**

```bash
# 1. Verificar que el flow log está activo
aws ec2 describe-flow-logs \
  --filter "Name=resource-id,Values=$VPC_ID" \
  --query 'FlowLogs[*].[FlowLogId,FlowLogStatus,DeliverLogsStatus]' \
  --output table
# DeliverLogsStatus debe ser SUCCESS (no FAILED)

# 2. Si DeliverLogsStatus=FAILED, revisar el IAM role
aws iam simulate-principal-policy \
  --policy-source-arn $FLOW_LOGS_ROLE_ARN \
  --action-names logs:PutLogEvents logs:CreateLogStream \
  --resource-arns "arn:aws:logs:eu-west-1:$AWS_ACCOUNT:log-group:/vpc/flow-logs/*"

# 3. Verificar que el Log Group existe
aws logs describe-log-groups \
  --log-group-name-prefix /vpc/flow-logs
```

**Solución más común:** El IAM role no tiene permiso `logs:CreateLogGroup` o `logs:PutLogEvents`. Revisar la Inline Policy del role.

---

### Escenario 5 — Tráfico ACCEPT esperado no aparece en logs

**Síntoma:** Hay tráfico de un tipo concreto que debería salir en logs pero no aparece.

**Posibles causas:**

1. **Filtro incorrecto:** Si activaste Flow Logs con `Traffic type = REJECT`, no verás los ACCEPT.
2. **Aggregation interval:** Con intervalo de 10 minutos, los logs aparecen tarde. Cambiar a 1 minuto para debugging.
3. **Tráfico excluido:** Algunos tipos de tráfico nunca aparecen en Flow Logs (DHCP, IMDSv2 a 169.254.169.254, DNS resolver interno de VPC).

**Query para verificar qué tráfico se está capturando:**
```sql
fields @timestamp, srcAddr, dstAddr, dstPort, action
| stats count(*) by action
| sort count desc
```

---

### Escenario 6 — EC2 a S3 via Gateway Endpoint (verificar que no va por internet)

**Síntoma (en este caso, éxito):** Quieres confirmar que `aws s3 cp` desde la subnet isolated usa el endpoint y no el NAT GW.

**Lo que NO verás en Flow Logs:**
- El prefijo de S3 (`52.x.x.x`) como destino desde la subnet isolated si el Gateway Endpoint está bien configurado — el tráfico va directamente sin pasar por el IGW ni el NAT GW.

**Lo que SÍ verás:**
```
# Tráfico desde isolated hacia IP de S3 (endpoint routing)
srcaddr=10.10.21.5  dstaddr=52.218.x.x  dstport=443  action=ACCEPT
# La IP 52.218.x.x pertenece a S3 y el tráfico fue enrutado via endpoint
```

**Query:**
```sql
fields @timestamp, srcAddr, dstAddr, dstPort, action
| filter srcAddr like "10.10.21." and dstPort=443
| sort @timestamp desc
```

**Verificación alternativa:** Comprueba que no hay entradas `srcaddr=<EIP del NAT GW>` para el mismo flujo — si el NAT GW estuviera en medio, la IP origen sería la EIP.

---

### Escenario 7 — Interface Endpoint SSM (ENI privada en logs)

**Síntoma:** Quieres ver cómo aparece el tráfico SSM en los logs cuando usas Interface Endpoint.

**Lo que verás:**
```
# Desde EC2 isolated hacia la ENI del Interface Endpoint
srcaddr=10.10.21.5   dstaddr=10.10.21.100  dstport=443  action=ACCEPT
# 10.10.21.100 es la IP privada de la ENI del Interface Endpoint
```

El tráfico nunca sale de la VPC. La ENI del endpoint está en la misma subnet.

**Query:**
```sql
fields @timestamp, srcAddr, dstAddr, dstPort, action
| filter srcAddr like "10.10.21." and dstAddr like "10.10.21." and dstPort=443
| sort @timestamp desc
```

---

### Escenario 8 — NAT GW y SNAT (source IP translation)

**Síntoma:** Quieres entender cómo el NAT GW aparece en los logs.

**Flujo completo al hacer `curl https://google.com` desde EC2 privada:**

```
# En ENI de EC2 privada (private-a):
srcaddr=10.10.11.20  dstaddr=142.250.x.x  dstport=443  action=ACCEPT

# En ENI del NAT GW (public-a):
srcaddr=10.10.11.20  dstaddr=142.250.x.x  dstport=443  action=ACCEPT
# ↑ Mismo flujo, capturado en otra ENI

# En internet (no capturado por Flow Logs) el origen es la EIP del NAT GW
```

**Observación clave:** Los Flow Logs capturan tráfico en ENIs individuales. El mismo flujo puede aparecer dos veces (una en la ENI de la EC2 y otra en la ENI del NAT GW). Para evitar confusión, filtra siempre por `interface-id`.

**Query por ENI específica:**
```sql
fields @timestamp, interfaceId, srcAddr, dstAddr, action
| filter interfaceId="eni-xxxxxxxxx"
| sort @timestamp desc
```

---

## Resumen de queries útiles

```sql
-- Ver todos los REJECT en los últimos 15 min
fields @timestamp, srcAddr, dstAddr, dstPort, action
| filter action="REJECT"
| sort @timestamp desc
| limit 50

-- Top 10 IPs que más tráfico generan
fields srcAddr
| stats count(*) as flows by srcAddr
| sort flows desc
| limit 10

-- Tráfico hacia un puerto específico
fields @timestamp, srcAddr, dstAddr, action
| filter dstPort=22 or dstPort=443 or dstPort=5432
| sort @timestamp desc

-- Flujos rechazados agrupados por destino
fields dstAddr, dstPort, action
| filter action="REJECT"
| stats count(*) as rejected_count by dstAddr, dstPort
| sort rejected_count desc
```

---

## 🗑️ Borrar Flow Logs y Log Group (opcional)

```bash
# Obtener flow log ID
FLOW_LOG_ID=$(aws ec2 describe-flow-logs \
  --filter "Name=resource-id,Values=$VPC_ID" \
  --query 'FlowLogs[0].FlowLogId' --output text)

# Borrar flow log
aws ec2 delete-flow-logs --flow-log-ids $FLOW_LOG_ID

# Borrar Log Group (borra todos los logs)
aws logs delete-log-group \
  --log-group-name /vpc/flow-logs/vpc-lab-dev
```

> El coste de CloudWatch Logs para este lab es mínimo (~0.05€), pero es buena práctica limpiar recursos temporales.

---

**Siguiente fase:** [fase-06-iac.md](./fase-06-iac.md) | O si ya terminaste: [cleanup.md](./cleanup.md)
