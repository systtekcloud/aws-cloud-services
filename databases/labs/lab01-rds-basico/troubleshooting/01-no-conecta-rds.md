# Troubleshooting 01 — "Can't connect to MySQL server"

## Escenario

Acabas de crear la instancia RDS y la EC2 de aplicación. Intentas conectar desde la EC2 vía SSM Session Manager:

```bash
mysql -h db-lab-rds-instance.xxxxx.eu-west-1.rds.amazonaws.com -u admin -p
```

Y obtienes:

```
ERROR 2003 (HY000): Can't connect to MySQL server on 'db-lab-rds-instance.xxxxx.eu-west-1.rds.amazonaws.com' (110)
```

O directamente timeout sin mensaje.

---

## Síntomas observables

### En la consola AWS

- La instancia RDS está en estado `Available`
- La EC2 está en estado `Running`
- La conexión desde SSM llega a la EC2 sin problemas
- Solo falla el `mysql -h ...` o el `nc -zv ... 3306`

### En la CLI desde la EC2 (SSM)

```bash
# Probar conectividad TCP al puerto 3306
nc -zv db-lab-rds-instance.xxxxx.eu-west-1.rds.amazonaws.com 3306
# Resultado si hay problema: Connection timed out
# Resultado si funciona: succeeded!
```

---

## Comandos de diagnóstico

### Paso 1: Verificar que RDS está en estado Available y no tiene IP pública

```bash
aws rds describe-db-instances \
  --db-instance-identifier db-lab-rds-instance \
  --query 'DBInstances[0].{Status:DBInstanceStatus,PubliclyAccessible:PubliclyAccessible,Endpoint:Endpoint.Address,AZ:AvailabilityZone}' \
  --output table --region eu-west-1
```

Salida esperada:
```
------------------------------------------------------------------
| Status: available | PubliclyAccessible: False | Endpoint: db-lab...
```

### Paso 2: Verificar el Security Group de RDS

```bash
# Obtener el SG ID de la instancia RDS
SG_RDS=$(aws rds describe-db-instances \
  --db-instance-identifier db-lab-rds-instance \
  --query 'DBInstances[0].VpcSecurityGroups[0].VpcSecurityGroupId' \
  --output text --region eu-west-1)

# Ver las reglas del SG
aws ec2 describe-security-groups \
  --group-ids $SG_RDS \
  --query 'SecurityGroups[0].IpPermissions' \
  --output json --region eu-west-1
```

**Regla correcta esperada:**
```json
[
  {
    "FromPort": 3306,
    "ToPort": 3306,
    "IpProtocol": "tcp",
    "UserIdGroupPairs": [{"GroupId": "sg-XXXX"}]  ← sg-app, NO un CIDR
  }
]
```

**Regla INCORRECTA (causa del problema):**
```json
[
  {
    "FromPort": 3306,
    "ToPort": 3306,
    "IpProtocol": "tcp",
    "IpRanges": []  ← Lista vacía = nadie puede conectar
  }
]
```

### Paso 3: Verificar que la EC2 usa el SG correcto

```bash
EC2_ID="i-XXXXXXX"  # tu EC2 ID

aws ec2 describe-instances \
  --instance-ids $EC2_ID \
  --query 'Reservations[0].Instances[0].{SG:SecurityGroups,Subnet:SubnetId,VPC:VpcId}' \
  --output json --region eu-west-1
```

Confirmar que:
- El SG de la EC2 es `sg-app-db-labs` (el que está en la regla inbound de RDS)
- La subnet de la EC2 está en la misma VPC que RDS

### Paso 4: Verificar que VPC tiene DNS habilitado

```bash
VPC_ID="vpc-XXXXXX"

aws ec2 describe-vpc-attribute --vpc-id $VPC_ID --attribute enableDnsHostnames --region eu-west-1
aws ec2 describe-vpc-attribute --vpc-id $VPC_ID --attribute enableDnsSupport --region eu-west-1
```

Ambos deben mostrar `{"Value": true}`.

---

## Causas y soluciones

### Causa 1 (Probabilidad: Alta) — Security Group de RDS no permite la fuente correcta

**Síntoma específico:** `nc` timeout pero RDS está `Available`.

**Por qué ocurre:** Al crear el SG de RDS, se configuró `0.0.0.0/0` o nada en el inbound, en lugar de usar `sg-app-db-labs` como fuente.

**Fix:**

```bash
SG_RDS="sg-XXXXXX"  # ID de sg-rds-db-labs
SG_APP="sg-YYYYYY"  # ID de sg-app-db-labs

# Primero eliminar reglas incorrectas (si las hay)
aws ec2 revoke-security-group-ingress \
  --group-id $SG_RDS \
  --protocol tcp --port 3306 \
  --cidr 0.0.0.0/0 \
  --region eu-west-1 2>/dev/null || true

# Añadir la regla correcta: solo desde sg-app
aws ec2 authorize-security-group-ingress \
  --group-id $SG_RDS \
  --protocol tcp --port 3306 \
  --source-group $SG_APP \
  --region eu-west-1
```

### Causa 2 (Probabilidad: Media) — EC2 no está asociada al SG correcto

**Fix:**

```bash
EC2_ID="i-XXXXXXX"
SG_APP="sg-YYYYYY"

aws ec2 modify-instance-attribute \
  --instance-id $EC2_ID \
  --groups $SG_APP \
  --region eu-west-1
```

### Causa 3 (Probabilidad: Media) — DNS hostnames deshabilitado en VPC

**Síntoma:** El endpoint de RDS no resuelve (`nslookup db-lab... → server can't find`).

**Fix:**

```bash
VPC_ID="vpc-XXXXXX"
aws ec2 modify-vpc-attribute --vpc-id $VPC_ID --enable-dns-hostnames
aws ec2 modify-vpc-attribute --vpc-id $VPC_ID --enable-dns-support
```

### Causa 4 (Probabilidad: Baja) — EC2 y RDS en VPCs distintas

**Fix:** Asegúrate de que la EC2 y el DB Subnet Group usan la misma VPC (`vpc-db-labs`).

---

## Cómo prevenirlo

1. **Al crear el SG de RDS:** siempre usa Source = Security Group (no CIDR), referenciando `sg-app`.
2. **Verificar antes de conectar:** `aws rds describe-db-instances --query ...PubliclyAccessible...` debe ser `False`.
3. **Test rápido de red:** `nc -zv <endpoint> 3306` antes de instalar el cliente MySQL.
