# v2 — 3-Tier con Aurora + ElastiCache + Secrets Manager

Extiende v1 añadiendo la capa de datos: Aurora MySQL Multi-AZ, ElastiCache Redis y Secrets Manager para gestión segura de credenciales.

```
Internet
   │
  ALB (público, subnets public-a/b/c)
   │
  EC2 ASG (subnets private-app-a/b/c)
   │              │
Aurora MySQL    ElastiCache
Multi-AZ        Redis
(subnets db)    (subnets db)
   └── Secrets Manager (credentials)
```

**Coste estimado:** ~8-12€/día (Aurora + ElastiCache + NAT). Detener el cluster Aurora al terminar.

---

## Fase A — CLI

### Prerequisitos
Tener v1 desplegado y el fichero `~/.ec2-lab-env` cargado:
```bash
source ~/.ec2-lab-env
```

### Paso 1 — Subnets de base de datos (capa DB)
```bash
bash cli/01-db-subnets.sh
```

### Paso 2 — Aurora MySQL Multi-AZ
```bash
bash cli/02-aurora.sh
```

### Paso 3 — ElastiCache Redis
```bash
bash cli/03-elasticache.sh
```

### Paso 4 — Secrets Manager + actualizar app
```bash
bash cli/04-secrets-app.sh
```

### Paso 5 — Validación 3-tier
```bash
bash cli/05-validacion.sh
```

### Cleanup
```bash
bash cli/99-cleanup.sh
```

---

## Fase B — Terraform

```bash
cd terraform/
terraform init
terraform plan -var="vpc_id=$VPC_ID" \
               -var="private_app_subnet_ids=[\"$SUBNET_APP_A\",\"$SUBNET_APP_B\",\"$SUBNET_APP_C\"]" \
               -var="ec2_sg_id=$SG_EC2_ID"
terraform apply
```

Variables principales:

| Variable | Default | Descripción |
|---|---|---|
| `aws_region` | eu-west-1 | Región |
| `db_instance_class` | db.t3.medium | Tipo instancia Aurora |
| `redis_node_type` | cache.t3.micro | Tipo nodo ElastiCache |
| `db_name` | shopdb | Nombre de la base de datos |

---

## Resultados esperados

- `curl http://$ALB_DNS/health` → `{"status":"healthy","db":"ok","cache":"ok"}`
- `curl http://$ALB_DNS/db-check` → lista de registros de Aurora
- Aurora: 1 writer + 1 reader en AZs distintas
- Secrets Manager: credencial rotada automáticamente cada 30 días

---

## Exam Traps

| Trampa | Realidad |
|---|---|
| Usar `db.t3.micro` en Aurora Multi-AZ | Mínimo `db.t3.medium`; t3.micro no soporta Multi-AZ en Aurora |
| Conectar EC2→Aurora con CIDR abierto | Usar SG source chaining: el SG de Aurora solo acepta desde el SG de EC2 |
| Guardar credenciales en user_data | Siempre Secrets Manager / SSM Parameter Store |
| Reader endpoint para writes | Writer endpoint para escritura, reader endpoint para lecturas |
| Olvidar `authToken` en ElastiCache | Transit encryption + auth token obligatorios para Redis en producción |
| Aurora stop indefinido | Stop máx. 7 días; AWS lo reinicia automáticamente si se olvida |
