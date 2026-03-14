# Troubleshooting 03 — Timeout al resolver el DNS endpoint de RDS

## Escenario

Desde la EC2 en subnet privada intentas resolver el endpoint de RDS:

```bash
nslookup db-lab-rds-instance.xxxx.eu-west-1.rds.amazonaws.com
```

Y obtienes:

```
;; connection timed out; no servers could be reached
```

O al intentar conectar con mysql:

```
ERROR 2005 (HY000): Unknown MySQL server host 'db-lab-rds-instance.xxxx' (0)
```

---

## Diagnóstico

### Paso 1: Verificar atributos DNS de la VPC

```bash
VPC_ID="vpc-XXXXXX"

# Debe ser true
aws ec2 describe-vpc-attribute \
  --vpc-id $VPC_ID \
  --attribute enableDnsHostnames \
  --query 'EnableDnsHostnames.Value' \
  --output text --region eu-west-1

# Debe ser true
aws ec2 describe-vpc-attribute \
  --vpc-id $VPC_ID \
  --attribute enableDnsSupport \
  --query 'EnableDnsSupport.Value' \
  --output text --region eu-west-1
```

### Paso 2: Verificar resolución DNS desde la EC2

```bash
# Desde SSM Session Manager en la EC2:
cat /etc/resolv.conf
# Debe mostrar nameserver 10.20.0.2 (o el .2 de tu VPC CIDR = VPC DNS resolver)
```

### Paso 3: Verificar VPC Endpoints SSM (si usas Session Manager sin NAT)

```bash
aws ec2 describe-vpc-endpoints \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --query 'VpcEndpoints[*].{Service:ServiceName,State:State}' \
  --output table --region eu-west-1
```

---

## Causas y soluciones

### Causa 1 (Probabilidad: Alta) — `enableDnsHostnames = false`

**Fix:**

```bash
aws ec2 modify-vpc-attribute --vpc-id $VPC_ID --enable-dns-hostnames
```

### Causa 2 (Probabilidad: Media) — `enableDnsSupport = false`

**Fix:**

```bash
aws ec2 modify-vpc-attribute --vpc-id $VPC_ID --enable-dns-support
```

### Causa 3 (Probabilidad: Baja) — VPC Endpoints SSM con `privateDnsEnabled = false`

Si los VPC Endpoints de SSM no tienen DNS privado, SSM Session Manager puede no funcionar y la resolución de nombres del VPC DNS resolver puede fallar.

**Fix:** Recrear los endpoints con `--private-dns-enabled`.

---

## Cómo prevenirlo

Al crear cualquier VPC que vaya a hospedar RDS o SSM, habilitar SIEMPRE al principio:

```bash
aws ec2 modify-vpc-attribute --vpc-id $VPC_ID --enable-dns-hostnames
aws ec2 modify-vpc-attribute --vpc-id $VPC_ID --enable-dns-support
```

Esto es equivalente a las checkboxes "DNS hostnames" y "DNS resolution" en la consola VPC.
