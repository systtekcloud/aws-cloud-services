# Troubleshooting 02 — Security Group: tráfico bloqueado

## Síntoma
`curl http://<alb-dns>/health` → timeout o `Connection refused`. Las instancias están `healthy` pero no hay respuesta.

## Diagnóstico

```bash
source ~/.ec2-lab-env

# 1. Revisar SG del ALB (debe aceptar 80/443 desde 0.0.0.0/0)
aws ec2 describe-security-groups \
  --group-ids "$SG_ALB_ID" \
  --query 'SecurityGroups[0].IpPermissions[*].[FromPort,ToPort,IpRanges[0].CidrIp]' \
  --output table

# 2. Revisar SG de EC2 (debe aceptar app-port desde SG del ALB)
aws ec2 describe-security-groups \
  --group-ids "$SG_EC2_ID" \
  --query 'SecurityGroups[0].IpPermissions[*].[FromPort,ToPort,UserIdGroupPairs[0].GroupId]' \
  --output table

# 3. Verificar que el SG del ALB tiene salida (egress) al SG de EC2
aws ec2 describe-security-groups \
  --group-ids "$SG_ALB_ID" \
  --query 'SecurityGroups[0].IpPermissionsEgress' \
  --output table

# 4. VPC Flow Logs (si están activos)
# Buscar REJECT en los logs de la instancia o del ENI del ALB
```

## Causas comunes

| Causa | Solución |
|---|---|
| Regla de ingreso 80/443 falta en SG del ALB | `aws ec2 authorize-security-group-ingress --group-id $SG_ALB_ID --protocol tcp --port 80 --cidr 0.0.0.0/0` |
| SG de EC2 referencia CIDR en lugar de SG source | Cambiar a: `--source-group $SG_ALB_ID` (más seguro) |
| Puerto incorrecto en la regla del SG de EC2 | La regla debe ser exactamente el puerto de la app (8080, no 80) |
| SG del ALB sin egress abierto | El default egress `0.0.0.0/0` permite todo — no modificar a menos que sea necesario |
| NACL bloquea tráfico de retorno | NACLs son stateless — revisar reglas de salida (respuesta a puertos efímeros 1024-65535) |

## Corrección típica

```bash
# Caso más común: SG de EC2 con CIDR en lugar de SG source
# 1. Ver la regla incorrecta
aws ec2 describe-security-groups --group-ids "$SG_EC2_ID"

# 2. Revocar regla con CIDR
aws ec2 revoke-security-group-ingress \
  --group-id "$SG_EC2_ID" \
  --protocol tcp \
  --port 8080 \
  --cidr "10.0.0.0/16"   # la regla incorrecta

# 3. Añadir regla correcta con SG source
aws ec2 authorize-security-group-ingress \
  --group-id "$SG_EC2_ID" \
  --protocol tcp \
  --port 8080 \
  --source-group "$SG_ALB_ID"
```

## Exam Trap
Los **NACLs son stateless** — si una petición entra por el puerto 80, la respuesta sale por un puerto efímero (1024-65535). Si el NACL de la subnet del cliente bloquea esos puertos de salida, la conexión falla aunque el SG esté bien. Los **Security Groups son stateful** — si permites la entrada, la respuesta se permite automáticamente.
