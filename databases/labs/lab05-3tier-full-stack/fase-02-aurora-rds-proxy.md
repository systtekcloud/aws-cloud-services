# Fase 02 — Aurora MySQL + RDS Proxy

## Objetivo

Desplegar el Aurora MySQL cluster en las subnets de DB tier, crear el esquema SQL del e-commerce, y configurar RDS Proxy para que Lambda y múltiples instancias de app no saturen las conexiones de Aurora.

**Tiempo estimado:** 35-40 minutos

---

## ¿Por qué RDS Proxy?

```
SIN RDS Proxy:
  Lambda (1000 invocaciones simultáneas)
  ├── conexión 1 → Aurora
  ├── conexión 2 → Aurora
  ├── ...
  └── conexión 1000 → Aurora  ← OVERFLOW "too many connections"
  Aurora max_connections ≈ 90 en db.t3.medium

CON RDS Proxy:
  Lambda (1000 invocaciones simultáneas)
  └── → RDS Proxy (pool de 90 conexiones multiplexadas)
            └── 90 conexiones reales → Aurora
  Lambda ve 1000 conexiones exitosas, Aurora ve solo 90
```

**Casos de uso en el examen:**
- Lambda → Aurora (Lambda escala rápido, Aurora tiene límite de conexiones)
- ECS Fargate con autoscaling → Aurora
- Múltiples microservicios → misma Aurora

---

## Paso 1 — Aurora Cluster en subnets DB tier

Sigue los pasos de la **Fase 01 del lab02**, pero usando:
- Subnet Group: subnets `10.20.20.0/24` y `10.20.21.0/24` (DB tier)
- SG: `sg-aurora-lab05`
- Cluster identifier: `aurora-lab05`
- Writer: `aurora-lab05-writer`
- Reader: `aurora-lab05-reader`
- DB name: `ecommerce`

> Si el lab02 está activo con la VPC del lab01, puedes reutilizarlo. Para este lab, lo recreamos con la nueva VPC 3-tier.

### DB Subnet Group para el DB tier

```bash
SUBNET_DB_A=$(aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=cidrBlock,Values=10.20.20.0/24" \
  --query 'Subnets[0].SubnetId' --output text --region eu-west-1)

SUBNET_DB_B=$(aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=cidrBlock,Values=10.20.21.0/24" \
  --query 'Subnets[0].SubnetId' --output text --region eu-west-1)

aws rds create-db-subnet-group \
  --db-subnet-group-name aurora-lab05-subnetgroup \
  --db-subnet-group-description "Aurora DB tier subnets - lab05" \
  --subnet-ids $SUBNET_DB_A $SUBNET_DB_B \
  --region eu-west-1
```

---

## Paso 2 — Esquema SQL del e-commerce

Una vez que el cluster esté `available`, conecta y crea las tablas:

```bash
# Obtener endpoint y password
WRITER=$(aws rds describe-db-clusters \
  --db-cluster-identifier aurora-lab05 \
  --query 'DBClusters[0].Endpoint' --output text --region eu-west-1)

PASS=$(aws secretsmanager get-secret-value \
  --secret-id lab05/aurora/admin \
  --query 'SecretString' --output text --region eu-west-1 | jq -r '.password')

mysql -h $WRITER -u admin -p"$PASS" ecommerce
```

### DDL del esquema

```sql
-- ============================================================
-- E-COMMERCE Schema — Aurora MySQL
-- Almacena: usuarios, pedidos, pagos (datos transaccionales)
-- ============================================================

USE ecommerce;

-- Usuarios (datos de cuenta, NO el catálogo de productos → DynamoDB)
CREATE TABLE usuarios (
  id         BIGINT AUTO_INCREMENT PRIMARY KEY,
  email      VARCHAR(255) UNIQUE NOT NULL,
  nombre     VARCHAR(255) NOT NULL,
  ciudad     VARCHAR(100),
  creado_en  DATETIME DEFAULT NOW(),
  INDEX idx_email (email)
);

-- Pedidos
CREATE TABLE pedidos (
  id           BIGINT AUTO_INCREMENT PRIMARY KEY,
  usuario_id   BIGINT NOT NULL,
  estado       ENUM('pendiente','procesando','enviado','entregado','cancelado') DEFAULT 'pendiente',
  total        DECIMAL(10,2) NOT NULL,
  creado_en    DATETIME DEFAULT NOW(),
  actualizado  DATETIME DEFAULT NOW() ON UPDATE NOW(),
  FOREIGN KEY (usuario_id) REFERENCES usuarios(id),
  INDEX idx_usuario_estado (usuario_id, estado),
  INDEX idx_estado_fecha (estado, creado_en)
);

-- Líneas de pedido (vincula pedido → producto de DynamoDB)
CREATE TABLE lineas_pedido (
  id             BIGINT AUTO_INCREMENT PRIMARY KEY,
  pedido_id      BIGINT NOT NULL,
  dynamo_sku     VARCHAR(100) NOT NULL,  -- PK de DynamoDB
  nombre_producto VARCHAR(255) NOT NULL, -- snapshot del nombre en el momento
  cantidad       INT NOT NULL DEFAULT 1,
  precio_unit    DECIMAL(10,2) NOT NULL,
  FOREIGN KEY (pedido_id) REFERENCES pedidos(id),
  INDEX idx_pedido (pedido_id),
  INDEX idx_sku (dynamo_sku)
);

-- Pagos
CREATE TABLE pagos (
  id              BIGINT AUTO_INCREMENT PRIMARY KEY,
  pedido_id       BIGINT NOT NULL,
  metodo          ENUM('tarjeta','transferencia','paypal') NOT NULL,
  importe         DECIMAL(10,2) NOT NULL,
  estado          ENUM('pendiente','completado','fallido','reembolsado') DEFAULT 'pendiente',
  referencia_ext  VARCHAR(255),
  procesado_en    DATETIME DEFAULT NOW(),
  FOREIGN KEY (pedido_id) REFERENCES pedidos(id),
  INDEX idx_pedido (pedido_id)
);

-- Datos de ejemplo
INSERT INTO usuarios (email, nombre, ciudad) VALUES
  ('ana@example.com',    'Ana García',    'Madrid'),
  ('carlos@example.com', 'Carlos López',  'Barcelona'),
  ('maria@example.com',  'María Ruiz',    'Valencia');

INSERT INTO pedidos (usuario_id, estado, total) VALUES
  (1, 'entregado', 89.99),
  (1, 'pendiente', 149.00),
  (2, 'procesando', 259.99);

INSERT INTO lineas_pedido (pedido_id, dynamo_sku, nombre_producto, cantidad, precio_unit) VALUES
  (1, 'PROD#LIBRO-AWS',      'Libro AWS SAA-C03',   1, 89.99),
  (2, 'PROD#TECLADO-MECH',   'Teclado mecánico',    1, 149.00),
  (3, 'PROD#MONITOR-27',     'Monitor 27"',         1, 259.99);

INSERT INTO pagos (pedido_id, metodo, importe, estado) VALUES
  (1, 'tarjeta', 89.99, 'completado'),
  (2, 'tarjeta', 149.00, 'pendiente'),
  (3, 'paypal',  259.99, 'completado');

-- Verificar
SELECT p.id, u.nombre, p.total, p.estado, COUNT(lp.id) as items
FROM pedidos p
JOIN usuarios u ON u.id = p.usuario_id
JOIN lineas_pedido lp ON lp.pedido_id = p.id
GROUP BY p.id;
```

---

## Paso 3 — Crear RDS Proxy

### Prerrequisito: secret en Secrets Manager

RDS Proxy usa Secrets Manager para gestionar las credenciales. El secret del cluster Aurora ya existe (`lab05/aurora/admin`).

El secret debe tener el formato que RDS Proxy espera:
```json
{
  "username": "admin",
  "password": "XXXX"
}
```

### Consola

1. **RDS → Proxies → Create proxy**
2. Proxy identifier: `aurora-lab05-proxy`
3. Engine compatibility: **MySQL**

### Target group

4. Database: **aurora-lab05** (selecciona el cluster)
5. Connection pool max: **100%** (del max_connections de Aurora)

### Connectivity

| Campo | Valor |
|-------|-------|
| VPC | `vpc-lab05-3tier` |
| VPC security group | `sg-aurora-lab05` |
| Subnets | `subnet-private-db-a`, `subnet-private-db-b` |

### Authentication

6. IAM authentication: **Required** (más seguro) o **Allowed** (más fácil para el lab)
7. Secrets Manager secret: `lab05/aurora/admin`

8. **Create proxy** — tardará ~5-10 minutos

<details>
<summary>CLI equivalente</summary>

```bash
# IAM Role para RDS Proxy
PROXY_ROLE_ARN=$(aws iam create-role \
  --role-name rds-proxy-lab05-role \
  --assume-role-policy-document '{
    "Version":"2012-10-17",
    "Statement":[{"Effect":"Allow","Principal":{"Service":"rds.amazonaws.com"},"Action":"sts:AssumeRole"}]
  }' --query 'Role.Arn' --output text)

# Política para que el proxy lea el secret
aws iam put-role-policy \
  --role-name rds-proxy-lab05-role \
  --policy-name AllowSecretsManager \
  --policy-document "{
    \"Version\":\"2012-10-17\",
    \"Statement\":[{
      \"Effect\":\"Allow\",
      \"Action\":[\"secretsmanager:GetSecretValue\"],
      \"Resource\":\"${SECRET_ARN}\"
    }]
  }"

# Crear el proxy
aws rds create-db-proxy \
  --db-proxy-name aurora-lab05-proxy \
  --engine-family MYSQL \
  --auth "[{\"AuthScheme\":\"SECRETS\",\"SecretArn\":\"${SECRET_ARN}\",\"IAMAuth\":\"DISABLED\"}]" \
  --role-arn $PROXY_ROLE_ARN \
  --vpc-subnet-ids $SUBNET_DB_A $SUBNET_DB_B \
  --vpc-security-group-ids $SG_AURORA \
  --require-tls \
  --region eu-west-1

# Registrar el cluster Aurora como target
aws rds register-db-proxy-targets \
  --db-proxy-name aurora-lab05-proxy \
  --db-cluster-identifiers aurora-lab05 \
  --region eu-west-1

aws rds wait db-proxy-available \
  --db-proxy-name aurora-lab05-proxy \
  --region eu-west-1
echo "RDS Proxy disponible"
```

</details>

---

## Paso 4 — Verificar RDS Proxy desde la EC2

```bash
# Obtener endpoint del Proxy
PROXY_ENDPOINT=$(aws rds describe-db-proxies \
  --db-proxy-name aurora-lab05-proxy \
  --query 'DBProxies[0].Endpoint' \
  --output text --region eu-west-1)

echo "Proxy endpoint: $PROXY_ENDPOINT"

# Conectar a través del Proxy (misma sintaxis que Aurora directo)
mysql -h $PROXY_ENDPOINT -u admin -p"$PASS" ecommerce \
  -e "SELECT @@aurora_server_id; SELECT COUNT(*) FROM pedidos;"
```

### Diferencia entre conexión directa y via Proxy

```bash
# Conexión directa → Aurora Writer
mysql -h aurora-lab05.cluster-xxxx.eu-west-1.rds.amazonaws.com ...
# @@aurora_server_id = aurora-lab05-writer

# Conexión via RDS Proxy → Pool → Aurora Writer
mysql -h aurora-lab05-proxy.proxy-xxxx.eu-west-1.rds.amazonaws.com ...
# @@aurora_server_id = aurora-lab05-writer (misma instancia, pero via proxy)
```

El RDS Proxy **transparentemente** reutiliza conexiones existentes → Aurora solo ve N conexiones del pool, no una por cada cliente.

---

## ✅ Validaciones de la fase

```bash
# 1. Cluster Aurora available
aws rds describe-db-clusters \
  --db-cluster-identifier aurora-lab05 \
  --query 'DBClusters[0].{Status:Status,Endpoint:Endpoint}' \
  --output table --region eu-west-1

# 2. RDS Proxy available
aws rds describe-db-proxies \
  --db-proxy-name aurora-lab05-proxy \
  --query 'DBProxies[0].{Status:Status,Endpoint:Endpoint}' \
  --output table --region eu-west-1
# Status=available

# 3. Proxy target health
aws rds describe-db-proxy-targets \
  --db-proxy-name aurora-lab05-proxy \
  --query 'Targets[*].{Target:TargetArn,Health:TargetHealth.State}' \
  --output table --region eu-west-1
# Health=AVAILABLE

# 4. Tablas creadas
mysql -h $PROXY_ENDPOINT -u admin -p"$PASS" ecommerce \
  -e "SHOW TABLES; SELECT COUNT(*) FROM pedidos;"
```

---

## Conceptos SAA-C03 cubiertos

| Concepto | Evidencia |
|----------|-----------|
| RDS Proxy para Lambda | Explicación y demo de connection pooling |
| Aurora cluster en subnet privada DB tier | Separación App/DB |
| Secrets Manager como fuente de credenciales del Proxy | Paso 3 |
| `too many connections` → solución RDS Proxy | Diagrama inicial |
