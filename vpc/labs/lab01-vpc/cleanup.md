# Cleanup — Borrar todos los recursos del lab

> **Tiempo:** ~15 min | **Importancia:** CRÍTICO — cada recurso olvidado genera coste

---

## Por qué el orden importa

AWS impide borrar recursos que tienen dependencias activas. El orden correcto es siempre de "hoja" a "raíz":

```
EC2 → ENIs/Endpoints → NAT GW → EIP → Security Groups → NACLs →
Subnets → Route Tables → IGW → Flow Logs → VPC
```

---

## Verificación inicial — ¿Qué tienes creado?

```bash
# Ver todos los recursos del proyecto de un vistazo
aws resourcegroupstaggingapi get-resources \
  --tag-filters Key=Project,Values=vpc-lab \
  --query 'ResourceTagMappingList[*].[ResourceARN]' \
  --output text

# Ver VPCs del lab
aws ec2 describe-vpcs \
  --filters "Name=tag:Project,Values=vpc-lab" \
  --query 'Vpcs[*].[VpcId,CidrBlock,State]' \
  --output table
```

---

## Paso 1 — Terminar instancias EC2

**Consola:** EC2 > Instances > seleccionar `bastion-public-a`, `app-private-a`, `db-isolated-a` > Instance state > **Terminate instance**

```bash
# Obtener IDs de todas las instancias del lab
INSTANCE_IDS=$(aws ec2 describe-instances \
  --filters "Name=tag:Project,Values=vpc-lab" \
            "Name=instance-state-name,Values=running,stopped" \
  --query 'Reservations[*].Instances[*].InstanceId' \
  --output text)

echo "Instancias a terminar: $INSTANCE_IDS"

# Terminar
aws ec2 terminate-instances --instance-ids $INSTANCE_IDS

# Esperar a que estén terminated
aws ec2 wait instance-terminated --instance-ids $INSTANCE_IDS
echo "Instancias terminadas."
```

---

## Paso 2 — Borrar VPC Endpoints

**Consola:** VPC > Endpoints > filtrar por VPC `vpc-lab-dev` > seleccionar todos > Actions > **Delete VPC endpoints**

```bash
# Listar todos los endpoints del lab
EP_IDS=$(aws ec2 describe-vpc-endpoints \
  --filters "Name=tag:Project,Values=vpc-lab" \
            "Name=vpc-endpoint-state,Values=available,pending" \
  --query 'VpcEndpoints[*].VpcEndpointId' \
  --output text)

if [ -n "$EP_IDS" ]; then
  echo "Borrando endpoints: $EP_IDS"
  aws ec2 delete-vpc-endpoints --vpc-endpoint-ids $EP_IDS
  echo "Endpoints borrados."
else
  echo "No hay endpoints que borrar."
fi
```

> Los Gateway Endpoints (S3) también se borran con este comando.

---

## Paso 3 — Borrar Flow Logs

**Consola:** VPC > Your VPCs > `vpc-lab-dev` > pestaña Flow logs > seleccionar > **Delete**

```bash
# Obtener flow log IDs
FLOW_LOG_IDS=$(aws ec2 describe-flow-logs \
  --filter "Name=resource-id,Values=$VPC_ID" \
  --query 'FlowLogs[*].FlowLogId' \
  --output text)

if [ -n "$FLOW_LOG_IDS" ]; then
  aws ec2 delete-flow-logs --flow-log-ids $FLOW_LOG_IDS
  echo "Flow logs borrados."
fi

# Borrar CloudWatch Log Group
aws logs delete-log-group \
  --log-group-name /vpc/flow-logs/vpc-lab-dev 2>/dev/null && \
  echo "Log Group borrado." || echo "Log Group no existía."
```

---

## Paso 4 — Borrar NAT Gateway y liberar Elastic IP

> Si ya borraste el NAT GW en Fase 2, salta este paso.

**Consola:** VPC > NAT Gateways > seleccionar `nat-gw-public-a` > Actions > **Delete NAT gateway**

```bash
NAT_IDS=$(aws ec2 describe-nat-gateways \
  --filter "Name=tag:Project,Values=vpc-lab" \
           "Name=state,Values=available,pending" \
  --query 'NatGateways[*].NatGatewayId' \
  --output text)

if [ -n "$NAT_IDS" ]; then
  aws ec2 delete-nat-gateway --nat-gateway-id $NAT_IDS
  echo "Esperando que el NAT GW esté deleted..."
  aws ec2 wait nat-gateway-deleted --nat-gateway-ids $NAT_IDS
  echo "NAT GW borrado."
fi

# Liberar Elastic IPs
EIP_IDS=$(aws ec2 describe-addresses \
  --filters "Name=tag:Project,Values=vpc-lab" \
  --query 'Addresses[*].AllocationId' \
  --output text)

for EIP_ID in $EIP_IDS; do
  aws ec2 release-address --allocation-id $EIP_ID
  echo "EIP $EIP_ID liberada."
done
```

---

## Paso 5 — Borrar Network ACLs

> La NACL default de la VPC no se puede borrar, solo las custom.

```bash
NACL_IDS=$(aws ec2 describe-network-acls \
  --filters "Name=tag:Project,Values=vpc-lab" \
            "Name=default,Values=false" \
  --query 'NetworkAcls[*].NetworkAclId' \
  --output text)

for NACL_ID in $NACL_IDS; do
  aws ec2 delete-network-acl --network-acl-id $NACL_ID
  echo "NACL $NACL_ID borrada."
done
```

---

## Paso 6 — Borrar Security Groups

> El SG `default` de la VPC no se puede borrar.

**Consola:** EC2 > Security Groups > filtrar por VPC `vpc-lab-dev` > seleccionar custom SGs > **Delete security groups**

```bash
SG_IDS=$(aws ec2 describe-security-groups \
  --filters "Name=tag:Project,Values=vpc-lab" \
  --query 'SecurityGroups[?GroupName!=`default`].GroupId' \
  --output text)

# Hay que borrar en orden correcto (SGs que referencian a otros primero)
# Primero revocar referencias cruzadas, luego borrar
for SG_ID in $SG_IDS; do
  # Revocar reglas que referencian otros SGs del lab
  aws ec2 revoke-security-group-ingress \
    --group-id $SG_ID \
    --ip-permissions "$(aws ec2 describe-security-groups \
      --group-ids $SG_ID \
      --query 'SecurityGroups[0].IpPermissions' \
      --output json)" 2>/dev/null || true
done

# Ahora borrar
for SG_ID in $SG_IDS; do
  aws ec2 delete-security-group --group-id $SG_ID && \
    echo "SG $SG_ID borrado." || echo "SG $SG_ID: no se pudo borrar (puede tener dependencias)"
done
```

---

## Paso 7 — Borrar Subnets

```bash
SUBNET_IDS=$(aws ec2 describe-subnets \
  --filters "Name=tag:Project,Values=vpc-lab" \
  --query 'Subnets[*].SubnetId' \
  --output text)

for SUBNET_ID in $SUBNET_IDS; do
  aws ec2 delete-subnet --subnet-id $SUBNET_ID && \
    echo "Subnet $SUBNET_ID borrada."
done
```

---

## Paso 8 — Borrar Route Tables

> La route table `main` (asociada por defecto a la VPC) no se puede borrar.

```bash
RT_IDS=$(aws ec2 describe-route-tables \
  --filters "Name=tag:Project,Values=vpc-lab" \
            "Name=association.main,Values=false" \
  --query 'RouteTables[*].RouteTableId' \
  --output text)

for RT_ID in $RT_IDS; do
  aws ec2 delete-route-table --route-table-id $RT_ID && \
    echo "Route Table $RT_ID borrada."
done
```

---

## Paso 9 — Desadjuntar y borrar Internet Gateway

```bash
IGW_ID=$(aws ec2 describe-internet-gateways \
  --filters "Name=tag:Project,Values=vpc-lab" \
  --query 'InternetGateways[0].InternetGatewayId' \
  --output text)

if [ "$IGW_ID" != "None" ] && [ -n "$IGW_ID" ]; then
  # Primero desadjuntar
  aws ec2 detach-internet-gateway \
    --internet-gateway-id $IGW_ID \
    --vpc-id $VPC_ID
  # Luego borrar
  aws ec2 delete-internet-gateway --internet-gateway-id $IGW_ID
  echo "IGW $IGW_ID borrado."
fi
```

---

## Paso 10 — Borrar la VPC

```bash
if [ -n "$VPC_ID" ]; then
  aws ec2 delete-vpc --vpc-id $VPC_ID && \
    echo "VPC $VPC_ID borrada. ✓" || \
    echo "Error borrando VPC — puede quedar algún recurso asociado."
fi
```

---

## Paso 11 — Borrar recursos IAM del lab

```bash
# Role SSM + S3 para instancias (ec2-ssm-s3-role)
aws iam remove-role-from-instance-profile \
  --instance-profile-name ec2-ssm-s3-profile \
  --role-name ec2-ssm-s3-role 2>/dev/null || true
aws iam delete-instance-profile \
  --instance-profile-name ec2-ssm-s3-profile 2>/dev/null || true
aws iam detach-role-policy \
  --role-name ec2-ssm-s3-role \
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore 2>/dev/null || true
aws iam detach-role-policy \
  --role-name ec2-ssm-s3-role \
  --policy-arn arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess 2>/dev/null || true
aws iam delete-role --role-name ec2-ssm-s3-role 2>/dev/null || true

# Role Flow Logs
aws iam delete-role-policy \
  --role-name vpc-flow-logs-role \
  --policy-name flow-logs-cw 2>/dev/null || true
aws iam delete-role --role-name vpc-flow-logs-role 2>/dev/null || true

echo "Roles IAM del lab borrados."
```

---

## Paso 12 — Borrar recursos IaC (Fase 6)

> Solo si completaste la Fase 6 (Terraform + Atmos + GitHub Actions).

```bash
# GitHub Actions OIDC role
aws iam delete-role-policy \
  --role-name github-actions-vpc-lab \
  --policy-name vpc-lab-permissions 2>/dev/null || true
aws iam delete-role --role-name github-actions-vpc-lab 2>/dev/null || true

# OIDC provider de GitHub Actions
OIDC_ARN=$(aws iam list-open-id-connect-providers \
  --query "OpenIDConnectProviderList[?ends_with(Arn,'token.actions.githubusercontent.com')].Arn" \
  --output text)
[ -n "$OIDC_ARN" ] && aws iam delete-open-id-connect-provider \
  --open-id-connect-provider-arn "$OIDC_ARN" && echo "OIDC provider borrado."

# Estado Terraform en S3 (vaciar bucket antes de borrarlo)
BUCKET="tf-state-vpc-lab-$(aws sts get-caller-identity --query Account --output text)"
aws s3 rm s3://$BUCKET --recursive 2>/dev/null || true
aws s3api delete-bucket --bucket $BUCKET 2>/dev/null && echo "Bucket de estado $BUCKET borrado."

echo "Recursos IaC borrados."
```

---

## Paso 13 — Borrar Key Pair

```bash
aws ec2 delete-key-pair --key-name vpc-lab-key 2>/dev/null && \
  echo "Key pair borrado."
rm -f ~/.ssh/vpc-lab-key.pem
```

---

## Verificación final

```bash
# Verificar que no quedan recursos del lab
echo "=== VPCs del lab ==="
aws ec2 describe-vpcs \
  --filters "Name=tag:Project,Values=vpc-lab" \
  --query 'Vpcs[*].[VpcId,State]' --output table

echo "=== EC2 del lab ==="
aws ec2 describe-instances \
  --filters "Name=tag:Project,Values=vpc-lab" \
            "Name=instance-state-name,Values=running,stopped,pending" \
  --query 'Reservations[*].Instances[*].[InstanceId,State.Name]' --output table

echo "=== Elastic IPs sin asociar ==="
aws ec2 describe-addresses \
  --filters "Name=tag:Project,Values=vpc-lab" \
  --query 'Addresses[*].[AllocationId,PublicIp,AssociationId]' --output table

echo "=== NAT Gateways activos ==="
aws ec2 describe-nat-gateways \
  --filter "Name=tag:Project,Values=vpc-lab" \
           "Name=state,Values=available,pending" \
  --query 'NatGateways[*].[NatGatewayId,State]' --output table

echo "=== Interface Endpoints activos ==="
aws ec2 describe-vpc-endpoints \
  --filters "Name=tag:Project,Values=vpc-lab" \
            "Name=vpc-endpoint-type,Values=Interface" \
            "Name=vpc-endpoint-state,Values=available" \
  --query 'VpcEndpoints[*].[VpcEndpointId,ServiceName]' --output table
```

✅ **Limpieza completa cuando:** Todos los comandos anteriores devuelven listas vacías o tablas sin filas.

---

## Checklist final

- [ ] Todas las EC2 terminadas
- [ ] Interface Endpoints borrados
- [ ] Flow Logs borrados + CloudWatch Log Group eliminado
- [ ] NAT Gateway borrado
- [ ] Elastic IP liberada
- [ ] NACLs custom borradas
- [ ] Security Groups custom borrados
- [ ] Subnets borradas
- [ ] Route Tables custom borradas
- [ ] IGW desadjuntado y borrado
- [ ] VPC borrada
- [ ] IAM Roles del lab borrados
- [ ] Key Pair borrado

**Coste después de la limpieza: 0€/mes** ✓
