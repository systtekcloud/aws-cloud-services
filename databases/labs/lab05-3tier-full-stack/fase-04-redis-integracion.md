# Fase 04 — Redis: Cache-Aside + Session Store integrados

## Objetivo

Conectar ElastiCache Redis con los dos servicios de DB anteriores: cachear productos de DynamoDB (cache-aside) y cachear resultados de Aurora (reducir carga), además de gestionar sesiones de usuario entre "instancias de app".

**Tiempo estimado:** 25-30 minutos

---

## Arquitectura de caché en 3 capas

```
Request: GET /producto/LIBRO-AWS
         │
         ▼
┌────────────────────────────────┐
│  Redis (cache)                 │
│  KEY: product:PROD#LIBRO-AWS   │
│  HIT → devuelve en <1ms        │
│  MISS → continúa abajo         │
└──────────────┬─────────────────┘
               │ MISS
               ▼
┌────────────────────────────────┐
│  DynamoDB (catálogo)           │
│  PK=PROD#LIBRO-AWS SK=METADATA │
│  Latencia ~5-10ms              │
│  → guarda en Redis con TTL 5min│
└────────────────────────────────┘

Request: GET /pedidos?usuario=1001
         │
         ▼
┌────────────────────────────────┐
│  Redis (cache)                 │
│  KEY: user_orders:1001         │
│  HIT → devuelve en <1ms        │
│  MISS → continúa abajo         │
└──────────────┬─────────────────┘
               │ MISS
               ▼
┌────────────────────────────────┐
│  Aurora via RDS Proxy          │
│  SELECT ... JOIN ... WHERE     │
│  Latencia ~20-50ms             │
│  → guarda en Redis con TTL 2min│
└────────────────────────────────┘
```

---

## Paso 1 — Desplegar Redis en DB tier

Si tienes el lab04 activo (VPC distinta), o si usas la nueva VPC 3-tier:

```bash
# Subnet Group en subnets DB tier
aws elasticache create-cache-subnet-group \
  --cache-subnet-group-name redis-lab05-subnetgroup \
  --cache-subnet-group-description "Redis subnets for lab05 3-tier" \
  --subnet-ids $SUBNET_DB_A $SUBNET_DB_B \
  --region eu-west-1

# Replication Group
aws elasticache create-replication-group \
  --replication-group-id redis-lab05 \
  --replication-group-description "Redis lab05 - cache + sessions" \
  --engine redis --engine-version 7.1 \
  --cache-node-type cache.t3.micro \
  --num-cache-clusters 2 \
  --cache-subnet-group-name redis-lab05-subnetgroup \
  --security-group-ids $SG_REDIS \
  --automatic-failover-enabled --multi-az-enabled \
  --at-rest-encryption-enabled --transit-encryption-enabled \
  --tags Key=Project,Value=db-labs Key=Lab,Value=lab05 \
  --region eu-west-1

aws elasticache wait replication-group-available \
  --replication-group-id redis-lab05 --region eu-west-1
```

---

## Paso 2 — Script de integración desde la EC2

Instala las dependencias en la EC2 y ejecuta el script de demo:

```bash
# En la EC2 via SSM
sudo dnf install -y redis
pip3 install redis pymysql boto3
```

### Script de integración completo

```python
#!/usr/bin/env python3
# integracion_demo.py — Ejecutar en la EC2 via SSM
"""
Demo de integración de los 3 servicios:
  Redis: caché de productos (DynamoDB) + caché de pedidos (Aurora) + sesiones
  DynamoDB: catálogo de productos
  Aurora (via RDS Proxy): pedidos y pagos
"""

import json, time, uuid, boto3, pymysql, redis
from decimal import Decimal

# =========== CONFIGURACIÓN ===========
REDIS_HOST   = "redis-lab05.xxxxx.ng.0001.euw1.cache.amazonaws.com"
PROXY_HOST   = "aurora-lab05-proxy.proxy-xxxx.eu-west-1.rds.amazonaws.com"
DB_NAME      = "ecommerce"
SECRET_ID    = "lab05/aurora/admin"
DYNAMO_TABLE = "ecommerce-catalog"
REGION       = "eu-west-1"

# TTLs
TTL_PRODUCT  = 300   # 5 min para datos de producto
TTL_ORDERS   = 120   # 2 min para lista de pedidos (cambia frecuente)
TTL_SESSION  = 3600  # 1h para sesión de usuario
TTL_CART     = 3600  # 1h para carrito

# =========== INICIALIZACIÓN ===========
r = redis.Redis(host=REDIS_HOST, port=6379, ssl=True, decode_responses=True)

sm = boto3.client('secretsmanager', region_name=REGION)
ddb = boto3.resource('dynamodb', region_name=REGION)
catalog_table = ddb.Table(DYNAMO_TABLE)

def get_aurora_conn():
    """Obtiene conexión a Aurora via RDS Proxy usando Secrets Manager."""
    secret = json.loads(sm.get_secret_value(SecretId=SECRET_ID)['SecretString'])
    return pymysql.connect(
        host=PROXY_HOST, user=secret['username'], password=secret['password'],
        database=DB_NAME, connect_timeout=5, cursorclass=pymysql.cursors.DictCursor
    )

# =========== CAPA DE CACHÉ ===========

def get_product(sku: str) -> dict:
    """Cache-Aside: Redis → DynamoDB."""
    key = f"product:{sku}"
    cached = r.get(key)
    if cached:
        print(f"  [REDIS HIT]  {key}")
        return json.loads(cached)

    print(f"  [REDIS MISS] {key} → consultando DynamoDB...")
    t0 = time.time()
    resp = catalog_table.get_item(Key={'PK': sku, 'SK': 'METADATA'})
    ms = (time.time() - t0) * 1000
    item = resp.get('Item')

    if item:
        # Convertir Decimal a float para JSON
        item_json = json.dumps(item, default=lambda x: float(x) if isinstance(x, Decimal) else str(x))
        r.setex(key, TTL_PRODUCT, item_json)
        print(f"  [DDB]        {key} → {ms:.1f}ms → cacheado {TTL_PRODUCT}s")
    return item

def get_user_orders(user_id: int) -> list:
    """Cache-Aside: Redis → Aurora (via RDS Proxy)."""
    key = f"user_orders:{user_id}"
    cached = r.get(key)
    if cached:
        print(f"  [REDIS HIT]  {key}")
        return json.loads(cached)

    print(f"  [REDIS MISS] {key} → consultando Aurora via RDS Proxy...")
    t0 = time.time()
    conn = get_aurora_conn()
    with conn.cursor() as cur:
        cur.execute("""
            SELECT p.id, p.estado, p.total, p.creado_en,
                   GROUP_CONCAT(lp.nombre_producto) AS productos
            FROM pedidos p
            JOIN lineas_pedido lp ON lp.pedido_id = p.id
            WHERE p.usuario_id = %s
            GROUP BY p.id
            ORDER BY p.creado_en DESC
        """, (user_id,))
        orders = [dict(row, creado_en=str(row['creado_en'])) for row in cur.fetchall()]
    conn.close()
    ms = (time.time() - t0) * 1000

    r.setex(key, TTL_ORDERS, json.dumps(orders))
    print(f"  [AURORA]     {key} → {len(orders)} pedidos en {ms:.1f}ms → cacheado {TTL_ORDERS}s")
    return orders

# =========== SESSION STORE ===========

def login(user_id: int, email: str) -> str:
    """Crea una sesión en Redis. Devuelve session_id."""
    session_id = str(uuid.uuid4())
    r.setex(f"session:{session_id}", TTL_SESSION, json.dumps({
        "user_id": user_id,
        "email": email,
        "cart": {}
    }))
    print(f"  [SESSION]    Creada para user={user_id}: {session_id[:8]}...")
    return session_id

def add_to_cart(session_id: str, sku: str, qty: int):
    """Añade un producto al carrito (en la sesión Redis)."""
    key = f"session:{session_id}"
    data = json.loads(r.get(key) or '{}')
    data.setdefault('cart', {})[sku] = qty
    r.setex(key, TTL_SESSION, json.dumps(data))
    print(f"  [CART]       {sku} × {qty} añadido al carrito de {session_id[:8]}...")

def get_session(session_id: str) -> dict:
    """Lee la sesión activa."""
    data = r.get(f"session:{session_id}")
    return json.loads(data) if data else None

# =========== DEMO COMPLETO ===========

print("\n" + "="*60)
print("DEMO INTEGRACIÓN: DynamoDB + Aurora + Redis")
print("="*60 + "\n")

# 1. Caché de productos (Redis → DynamoDB)
print("─── 1. Caché de productos ───")
p = get_product("PROD#LIBRO-AWS")
print(f"  Producto: {p.get('nombre')} — {p.get('precio')}€" if p else "  No encontrado")
get_product("PROD#LIBRO-AWS")   # Segunda vez: HIT
get_product("PROD#TECLADO-MECH")  # Otro producto: MISS

# 2. Caché de pedidos (Redis → Aurora via RDS Proxy)
print("\n─── 2. Caché de pedidos ───")
orders = get_user_orders(1)
print(f"  {len(orders)} pedidos del usuario 1")
get_user_orders(1)  # Segunda vez: HIT

# 3. Session store
print("\n─── 3. Session Store ───")
sid = login(1, "ana@example.com")
add_to_cart(sid, "PROD#LIBRO-AWS", 1)
add_to_cart(sid, "PROD#TECLADO-MECH", 2)
session = get_session(sid)
print(f"  Sesión activa: user={session['user_id']}, carrito={session['cart']}")

# 4. Redis stats
print("\n─── 4. Stats Redis ───")
info = r.info('stats')
print(f"  Hits:   {info.get('keyspace_hits', 0)}")
print(f"  Misses: {info.get('keyspace_misses', 0)}")
total = info.get('keyspace_hits', 0) + info.get('keyspace_misses', 0)
if total:
    print(f"  Hit Rate: {info.get('keyspace_hits', 0) / total * 100:.1f}%")

print("\n" + "="*60)
print("✓ Integración completada")
print("="*60)
```

### Ejecutar el demo

```bash
# En la EC2 via SSM:
# 1. Edita el script para poner tus endpoints reales
# 2. Ejecuta:
python3 integracion_demo.py
```

Salida esperada:
```
─── 1. Caché de productos ───
  [REDIS MISS] product:PROD#LIBRO-AWS → consultando DynamoDB...
  [DDB]        product:PROD#LIBRO-AWS → 8.3ms → cacheado 300s
  Producto: Guía AWS Solutions Architect Associate — 89.99€
  [REDIS HIT]  product:PROD#LIBRO-AWS
  [REDIS MISS] product:PROD#TECLADO-MECH → consultando DynamoDB...

─── 2. Caché de pedidos ───
  [REDIS MISS] user_orders:1 → consultando Aurora via RDS Proxy...
  [AURORA]     user_orders:1 → 3 pedidos en 28.4ms → cacheado 120s
  3 pedidos del usuario 1
  [REDIS HIT]  user_orders:1

─── 3. Session Store ───
  [SESSION]    Creada para user=1: a3b7c9d2...
  [CART]       PROD#LIBRO-AWS × 1 añadido al carrito...
  [CART]       PROD#TECLADO-MECH × 2 añadido al carrito...

─── 4. Stats Redis ───
  Hits:   3
  Misses: 3
  Hit Rate: 50.0%
```

---

## Paso 3 — Invalidación coordinada

Cuando se actualiza un producto en DynamoDB, hay que invalidar la caché Redis:

```python
def update_product_price(sku: str, new_price: float):
    """Actualiza precio en DynamoDB e invalida la caché Redis."""
    # 1. Actualizar en DynamoDB (fuente de verdad)
    catalog_table.update_item(
        Key={'PK': sku, 'SK': 'METADATA'},
        UpdateExpression='SET precio = :p',
        ExpressionAttributeValues={':p': Decimal(str(new_price))}
    )
    print(f"  [DDB UPDATE] {sku} precio → {new_price}€")

    # 2. Invalidar caché (el próximo GET leerá el dato fresco)
    r.delete(f"product:{sku}")
    print(f"  [REDIS DEL]  product:{sku} invalidado")
```

---

## ✅ Validaciones

```bash
# Claves en Redis
redis-cli -h $REDIS_PRIMARY -p 6379 --tls KEYS "*"
# product:PROD#LIBRO-AWS
# product:PROD#TECLADO-MECH
# user_orders:1
# session:xxxxxxxx-...

# Hit rate global
redis-cli -h $REDIS_PRIMARY -p 6379 --tls INFO stats | grep -E "keyspace_hits|keyspace_misses"
```
