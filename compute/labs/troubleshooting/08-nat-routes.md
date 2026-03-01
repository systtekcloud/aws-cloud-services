# Troubleshooting 08 — NAT Gateway y tablas de rutas

## Síntoma
Las instancias EC2 en subnets privadas no tienen acceso a internet (no pueden hacer `pip install`, `aws s3 cp`, o llamadas a APIs externas). O solo algunas AZs tienen acceso.

## Diagnóstico

```bash
source ~/.ec2-lab-env

# 1. Verificar route tables de las subnets privadas
for SUBNET in "$SUBNET_APP_A" "$SUBNET_APP_B" "$SUBNET_APP_C"; do
  echo "Subnet: $SUBNET"
  RT_ID=$(aws ec2 describe-route-tables \
    --filters "Name=association.subnet-id,Values=$SUBNET" \
    --query 'RouteTables[0].RouteTableId' --output text)
  aws ec2 describe-route-tables \
    --route-table-ids "$RT_ID" \
    --query 'RouteTables[0].Routes[*].[DestinationCidrBlock,NatGatewayId,GatewayId,State]' \
    --output table
  echo "---"
done

# 2. Estado de los NAT Gateways
aws ec2 describe-nat-gateways \
  --filter "Name=vpc-id,Values=$VPC_ID" \
  --query 'NatGateways[*].[NatGatewayId,SubnetId,State,NatGatewayAddresses[0].PublicIp]' \
  --output table

# 3. Verificar desde la instancia (vía SSM)
INSTANCE_ID=$(aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names "$ASG_NAME" \
  --query 'AutoScalingGroups[0].Instances[0].InstanceId' --output text)

aws ssm send-command \
  --targets "[{\"Key\":\"instanceids\",\"Values\":[\"$INSTANCE_ID\"]}]" \
  --document-name "AWS-RunShellScript" \
  --parameters 'commands=["curl -sf https://checkip.amazonaws.com || echo NO_INTERNET","ip route show"]' \
  --query 'Command.CommandId' --output text
```

## Causas comunes

| Causa | Indicador | Solución |
|---|---|---|
| Ruta `0.0.0.0/0` falta en RT privada | `Routes` no tiene entrada NAT | Añadir ruta: `aws ec2 create-route --route-table-id $RT_ID --destination-cidr-block 0.0.0.0/0 --nat-gateway-id $NAT_ID` |
| Subnet privada asociada a RT pública | RT tiene `GatewayId=igw-xxx` en lugar de `NatGatewayId` | Reasociar a la RT privada correcta |
| NAT Gateway en estado `failed` | `State=failed` | Eliminar y recrear: los NAT GW no se pueden reiniciar |
| NAT Gateway en subnet privada en lugar de pública | NAT GW debe estar en subnet pública | Recrear el NAT en una subnet pública con IGW |
| AZ-B usa NAT de AZ-A (cross-AZ) | Funciona pero añade coste de transferencia entre AZs | Desplegar 1 NAT por AZ para HA y cost-optimization |
| EIP no asociada al NAT | `NatGatewayAddresses[].PublicIp` vacío | Asociar EIP o recrear el NAT |

## S3 Gateway Endpoint — tráfico S3 sin NAT

```bash
# El tráfico a S3 desde subnets privadas NO necesita NAT si hay un Gateway Endpoint
# Verificar que el endpoint existe y tiene las RTs añadidas
aws ec2 describe-vpc-endpoints \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=service-name,Values=com.amazonaws.${REGION}.s3" \
  --query 'VpcEndpoints[0].{State:State,RouteTables:RouteTableIds}' \
  --output table

# Si el Gateway Endpoint no está en la RT privada → añadirlo
aws ec2 modify-vpc-endpoint \
  --vpc-endpoint-id "$S3_ENDPOINT_ID" \
  --add-route-table-ids "$RT_PRIVATE_ID"
```

## Exam Trap
**NAT Gateway debe estar en una subnet pública** (con ruta al IGW). Si se crea en una subnet privada, el NAT GW no tiene acceso a internet y no funciona. Además, el NAT GW tiene coste de procesamiento de datos (~0.045$/GB) **además** del coste por hora — el tráfico cross-AZ a través del NAT GW se cobra doble (transferencia entre AZs + procesamiento del NAT).
