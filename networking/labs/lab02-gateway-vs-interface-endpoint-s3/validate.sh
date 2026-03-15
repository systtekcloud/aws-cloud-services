#!/usr/bin/env bash
# =============================================================================
# validate.sh — Lab 02: Gateway Endpoint vs NAT Gateway para S3
#
# Qué hace este script:
#   1. Lee outputs de Terraform para obtener IDs/IPs necesarios
#   2. Desde EC2-A (subnet-gw): sube un objeto de 5MB a S3
#   3. Desde EC2-B (subnet-nat): sube un objeto de 5MB a S3
#   4. Espera 90s para que los Flow Logs lleguen a CloudWatch
#   5. Consulta CloudWatch Insights para ver qué tráfico pasó por NAT GW
#   6. Muestra resultado: EC2-A → 0 bytes via NAT, EC2-B → ~5MB via NAT
#
# Pre-requisitos:
#   - terragrunt apply completado
#   - aws CLI configurada con perfil de lab
#   - jq instalado (apt-get install jq / brew install jq)
# =============================================================================

set -euo pipefail

REGION="eu-west-1"
TERRAGRUNT_DIR="$(dirname "$0")/terragrunt"

echo "============================================================"
echo "Lab 02 — Validación: Gateway Endpoint vs NAT Gateway S3"
echo "============================================================"

# Leer outputs de Terraform
echo ""
echo "[1/6] Leyendo outputs de Terraform..."
cd "$TERRAGRUNT_DIR"

EC2_GW_ID=$(terragrunt output -raw ec2_gw_instance_id 2>/dev/null)
EC2_NAT_ID=$(terragrunt output -raw ec2_nat_instance_id 2>/dev/null)
EC2_GW_IP=$(terragrunt output -raw ec2_gw_private_ip 2>/dev/null)
EC2_NAT_IP=$(terragrunt output -raw ec2_nat_private_ip 2>/dev/null)
NAT_GW_IP=$(terragrunt output -raw nat_gateway_public_ip 2>/dev/null)
BUCKET=$(terragrunt output -raw s3_bucket_name 2>/dev/null)
LOG_GROUP=$(terragrunt output -raw cloudwatch_log_group 2>/dev/null)

echo "  EC2-A (Gateway Endpoint): $EC2_GW_ID  IP: $EC2_GW_IP"
echo "  EC2-B (NAT only):         $EC2_NAT_ID  IP: $EC2_NAT_IP"
echo "  NAT Gateway IP:           $NAT_GW_IP"
echo "  S3 Bucket:                $BUCKET"
echo "  Flow Logs:                $LOG_GROUP"

# Esperar a que SSM esté disponible en ambas instancias
echo ""
echo "[2/6] Esperando disponibilidad SSM (hasta 120s)..."
for INSTANCE_ID in "$EC2_GW_ID" "$EC2_NAT_ID"; do
  for i in $(seq 1 24); do
    STATUS=$(aws ssm describe-instance-information \
      --filters "Key=InstanceIds,Values=$INSTANCE_ID" \
      --region "$REGION" \
      --query "InstanceInformationList[0].PingStatus" \
      --output text 2>/dev/null || echo "None")
    if [ "$STATUS" = "Online" ]; then
      echo "  ✓ $INSTANCE_ID: Online"
      break
    fi
    echo "  ... $INSTANCE_ID: $STATUS (intento $i/24)"
    sleep 5
  done
done

# Generar tráfico S3 desde EC2-A (Gateway Endpoint)
echo ""
echo "[3/6] EC2-A → S3 via Gateway Endpoint (generando 5MB de tráfico)..."
aws ssm send-command \
  --instance-ids "$EC2_GW_ID" \
  --document-name "AWS-RunShellScript" \
  --parameters "commands=[
    'dd if=/dev/urandom bs=1M count=5 2>/dev/null | aws s3 cp - s3://$BUCKET/test-from-ec2-gw.bin --region $REGION',
    'echo EXIT_CODE:\$?'
  ]" \
  --region "$REGION" \
  --output text \
  --query "Command.CommandId" > /tmp/cmd_gw_id.txt

CMD_GW_ID=$(cat /tmp/cmd_gw_id.txt)
echo "  Command ID: $CMD_GW_ID"

# Generar tráfico S3 desde EC2-B (solo NAT)
echo ""
echo "[4/6] EC2-B → S3 via NAT Gateway (generando 5MB de tráfico)..."
aws ssm send-command \
  --instance-ids "$EC2_NAT_ID" \
  --document-name "AWS-RunShellScript" \
  --parameters "commands=[
    'dd if=/dev/urandom bs=1M count=5 2>/dev/null | aws s3 cp - s3://$BUCKET/test-from-ec2-nat.bin --region $REGION',
    'echo EXIT_CODE:\$?'
  ]" \
  --region "$REGION" \
  --output text \
  --query "Command.CommandId" > /tmp/cmd_nat_id.txt

CMD_NAT_ID=$(cat /tmp/cmd_nat_id.txt)
echo "  Command ID: $CMD_NAT_ID"

# Esperar resultados de los comandos
echo ""
echo "[5/6] Esperando resultado de los comandos SSM..."
sleep 30
for CMD_ID in "$CMD_GW_ID" "$CMD_NAT_ID"; do
  STATUS=$(aws ssm get-command-invocation \
    --command-id "$CMD_ID" \
    --instance-id $([ "$CMD_ID" = "$CMD_GW_ID" ] && echo "$EC2_GW_ID" || echo "$EC2_NAT_ID") \
    --region "$REGION" \
    --query "Status" --output text 2>/dev/null || echo "Unknown")
  echo "  Comando $CMD_ID: $STATUS"
done

# Esperar a que los Flow Logs lleguen a CloudWatch
echo ""
echo "[6/6] Esperando Flow Logs en CloudWatch (90s)..."
sleep 90

# Consultar CloudWatch Logs Insights
# Buscamos flujos donde el destino es la IP pública del NAT Gateway
# (tráfico que pasó DESDE la VPC HACIA el NAT GW hacia internet)
echo ""
echo "============================================================"
echo "RESULTADOS — Tráfico S3 via NAT Gateway"
echo "============================================================"
echo ""
echo "Consultando CloudWatch Logs Insights..."
echo "(Buscando flujos con destino $NAT_GW_IP — IP del NAT Gateway)"
echo ""

QUERY_ID=$(aws logs start-query \
  --log-group-name "$LOG_GROUP" \
  --start-time $(date -d '10 minutes ago' +%s 2>/dev/null || date -v-10M +%s) \
  --end-time $(date +%s) \
  --query-string "
    fields @timestamp, srcaddr, dstaddr, bytes, action
    | filter dstaddr = \"$NAT_GW_IP\"
    | filter srcaddr = \"$EC2_GW_IP\" or srcaddr = \"$EC2_NAT_IP\"
    | stats sum(bytes) as total_bytes by srcaddr
  " \
  --region "$REGION" \
  --query "queryId" \
  --output text)

echo "Query ID: $QUERY_ID"
sleep 10

RESULTS=$(aws logs get-query-results \
  --query-id "$QUERY_ID" \
  --region "$REGION" \
  --output json)

echo ""
echo "Bytes de tráfico que pasaron por NAT Gateway:"
echo "$RESULTS" | python3 -c "
import json, sys
data = json.load(sys.stdin)
results = data.get('results', [])
if not results:
    print('  (Sin datos aún — espera más tiempo o verifica que los comandos SSM completaron)')
for row in results:
    row_dict = {f['field']: f['value'] for f in row}
    src = row_dict.get('srcaddr', '?')
    bytes_val = int(row_dict.get('total_bytes', 0))
    label = 'EC2-A (Gateway Endpoint)' if src == '$EC2_GW_IP' else 'EC2-B (NAT only)'
    print(f'  {label} ({src}): {bytes_val:,} bytes via NAT')
"

echo ""
echo "CONCLUSIÓN:"
echo "  EC2-A (Gateway Endpoint) → tráfico S3 NO debería aparecer via NAT"
echo "  EC2-B (NAT only)         → tráfico S3 SÍ aparece via NAT (~5MB)"
echo ""
echo "Verifica también en la consola AWS:"
echo "  CloudWatch → Log Insights → $LOG_GROUP"
echo ""
echo "Cleanup:"
echo "  cd terragrunt && terragrunt destroy"
echo "============================================================"
