# Troubleshooting 02 — RDS con "Publicly Accessible = Yes" accidental

## Escenario

Revisando tu instancia RDS notas que al crearla marcaste `Publicly accessible = Yes` por error (o usaste un template que lo tenía activo). La DB tiene una IP pública potencialmente expuesta.

---

## Síntomas observables

```bash
aws rds describe-db-instances \
  --db-instance-identifier db-lab-rds-instance \
  --query 'DBInstances[0].{PubliclyAccessible:PubliclyAccessible,Endpoint:Endpoint.Address}' \
  --output json --region eu-west-1
```

Resultado problemático:
```json
{
  "PubliclyAccessible": true,
  "Endpoint": "db-lab-rds-instance.xxxx.eu-west-1.rds.amazonaws.com"
}
```

---

## Riesgo real

Aunque `PubliclyAccessible = True` no garantiza que la DB sea accesible desde internet (también necesita Security Group permisivo), **es un riesgo de configuración** y una mala práctica.

El riesgo aumenta si:
1. El Security Group tiene `0.0.0.0/0` en el puerto 3306
2. La instancia está en una subnet con ruta a IGW

AWS Security Hub y AWS Config reportarán esto como finding crítico.

---

## Fix

```bash
# Corregir Publicly Accessible
aws rds modify-db-instance \
  --db-instance-identifier db-lab-rds-instance \
  --no-publicly-accessible \
  --apply-immediately \
  --region eu-west-1

# Esperar
aws rds wait db-instance-available \
  --db-instance-identifier db-lab-rds-instance \
  --region eu-west-1

# Verificar
aws rds describe-db-instances \
  --db-instance-identifier db-lab-rds-instance \
  --query 'DBInstances[0].PubliclyAccessible' \
  --output text --region eu-west-1
# Debe devolver: False
```

### También verificar el DB Subnet Group

Si el DB Subnet Group incluye subnets públicas, hay que recrearlo con solo subnets privadas:

```bash
# Ver qué subnets tiene el subnet group actual
aws rds describe-db-subnet-groups \
  --db-subnet-group-name db-lab-rds-subnetgroup \
  --query 'DBSubnetGroups[0].Subnets[*].{SubnetId:SubnetIdentifier,AZ:SubnetAvailabilityZone.Name}' \
  --output table --region eu-west-1
```

Verifica que TODAS las subnets listadas son privadas (sin ruta a IGW directo).

---

## Prevención

1. **Nunca usar el template "Production"** en RDS para labs (fuerza Multi-AZ pero no garantiza sin IP pública).
2. **Crear siempre el DB Subnet Group primero** con solo subnets privadas.
3. **AWS Config Rule:** habilitar `rds-instance-public-access-check` para detectar esto automáticamente.
4. **SCPs (Organizations):** en cuentas de producción, usar SCP que prohíba `rds:ModifyDBInstance` con `PubliclyAccessible=true`.
