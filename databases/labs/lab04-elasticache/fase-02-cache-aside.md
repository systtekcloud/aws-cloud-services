# Fase 02 — ElastiCache: Cache-Aside y Session Store

## Objetivo

Implementar los dos patrones de caché más frecuentes en el examen SAA-C03: **Cache-Aside** (leer de caché antes que de DB) y **Session Store** (almacenar sesiones de usuario en Redis).

**Tiempo estimado:** 30-35 minutos

---

## Los patrones de caché para SAA-C03

```
┌─────────────────────────────────────────────────────────────────────┐
│  PATRONES DE CACHÉ                                                   │
│                                                                      │
│  1. CACHE-ASIDE (Lazy Loading)                                       │
│     App → Redis → HIT → devolver datos                              │
│     App → Redis → MISS → App → DB → guardar en Redis → devolver     │
│                                                                      │
│  2. SESSION STORE                                                    │
│     Request → Redis (session data) → respuesta sin tocar la DB      │
│     Ventaja: si el servidor de app cae, la sesión no se pierde      │
│                                                                      │
│  3. WRITE-THROUGH (menos frecuente en SAA)                          │
│     App escribe en DB → App escribe en Redis → lectura siempre HIT  │
│     Desventaja: escribe siempre en caché aunque el dato no se lea   │
└─────────────────────────────────────────────────────────────────────┘
```

---

## Parte A — Cache-Aside Pattern

### Arquitectura

```
Cliente → App Server → ¿Está en Redis?
                       ├─ SÍ (HIT): devolver desde Redis (baja latencia <1ms)
                       └─ NO (MISS): consultar RDS/Aurora → guardar en Redis con TTL → devolver
```

### Configuración de la app en la EC2

```bash
# En la EC2 (via SSM), instalar dependencias
sudo apt-get install -y python3-pip redis-tools
pip3 install redis pymysql boto3

# Verificar conexión a Redis
PRIMARY="redis-lab-cluster.xxxxxx.ng.0001.euw1.cache.amazonaws.com"
redis-cli -h $PRIMARY -p 6379 --tls PING
# PONG
```

### Script cache-aside demo

```python
#!/usr/bin/env python3
# cache_aside_demo.py
# Simula el patrón cache-aside con ElastiCache + datos ficticios

import redis
import json
import time
import random

# --- Configuración ---
REDIS_HOST = "redis-lab-cluster.xxxxxx.ng.0001.euw1.cache.amazonaws.com"
REDIS_PORT = 6379
CACHE_TTL = 300  # 5 minutos

# Inicializar cliente Redis con TLS
r = redis.Redis(
    host=REDIS_HOST,
    port=REDIS_PORT,
    ssl=True,
    decode_responses=True
)

# --- Base de datos simulada (en prod sería RDS/Aurora) ---
FAKE_DB = {
    "1001": {"nombre": "Ana García", "ciudad": "Madrid", "pedidos": 5},
    "1002": {"nombre": "Carlos López", "ciudad": "Barcelona", "pedidos": 3},
    "1003": {"nombre": "María Ruiz", "ciudad": "Valencia", "pedidos": 8},
}

def get_from_db(customer_id: str) -> dict:
    """Simula una consulta lenta a la base de datos (RDS/Aurora)."""
    time.sleep(0.1)  # latencia simulada de 100ms
    return FAKE_DB.get(customer_id)

def get_customer(customer_id: str) -> dict:
    """
    Cache-Aside Pattern:
    1. Buscar en Redis
    2. Si no está (MISS), consultar DB y guardar en Redis
    3. Si está (HIT), devolver desde Redis
    """
    cache_key = f"customer:{customer_id}"

    # Intento 1: caché
    start = time.time()
    cached = r.get(cache_key)
    if cached:
        elapsed = (time.time() - start) * 1000
        print(f"  [HIT]  customer:{customer_id} → {elapsed:.1f}ms (desde Redis)")
        return json.loads(cached)

    # MISS: ir a la DB
    start = time.time()
    data = get_from_db(customer_id)
    elapsed = (time.time() - start) * 1000
    print(f"  [MISS] customer:{customer_id} → {elapsed:.1f}ms (desde DB)")

    if data:
        # Guardar en caché con TTL
        r.setex(cache_key, CACHE_TTL, json.dumps(data))
        print(f"  → Guardado en caché con TTL={CACHE_TTL}s")

    return data

def update_customer(customer_id: str, new_data: dict):
    """
    Al actualizar en DB, invalidar la caché (Cache Invalidation).
    Sin esto, los lectores verían datos obsoletos.
    """
    # 1. Actualizar en DB (simulado)
    FAKE_DB[customer_id] = new_data
    print(f"  [DB]   customer:{customer_id} actualizado en DB")

    # 2. Invalidar caché
    cache_key = f"customer:{customer_id}"
    r.delete(cache_key)
    print(f"  [DEL]  cache key {cache_key} invalidada")

# --- Demo ---
print("\n=== DEMO CACHE-ASIDE ===\n")

print("Primera lectura (siempre MISS — caché vacía):")
get_customer("1001")
get_customer("1001")  # Segunda lectura: HIT

print("\nSegunda secuencia — tres clientes diferentes:")
for cid in ["1001", "1002", "1003", "1001", "1002"]:
    get_customer(cid)

print("\n=== Cache stats ===")
info = r.info("stats")
print(f"  Hits:   {info.get('keyspace_hits', 0)}")
print(f"  Misses: {info.get('keyspace_misses', 0)}")

print("\n=== Invalidación de caché ===")
get_customer("1001")  # HIT
update_customer("1001", {"nombre": "Ana García-López", "ciudad": "Madrid", "pedidos": 6})
get_customer("1001")  # MISS después de invalidación
get_customer("1001")  # HIT de nuevo
```

### Ejecutar el demo

```bash
python3 cache_aside_demo.py
```

Salida esperada:
```
=== DEMO CACHE-ASIDE ===

Primera lectura (siempre MISS — caché vacía):
  [MISS] customer:1001 → 100.3ms (desde DB)
  → Guardado en caché con TTL=300s
  [HIT]  customer:1001 → 0.3ms (desde Redis)

=== Cache stats ===
  Hits:   4
  Misses: 3

=== Invalidación de caché ===
  [HIT]  customer:1001 → 0.2ms (desde Redis)
  [DB]   customer:1001 actualizado en DB
  [DEL]  cache key customer:1001 invalidada
  [MISS] customer:1001 → 100.1ms (desde DB)
  [HIT]  customer:1001 → 0.3ms (desde Redis)
```

---

## Parte B — Session Store Pattern

Redis es ideal para almacenar sesiones HTTP gracias a:
- TTL automático por clave (la sesión expira sola)
- Acceso O(1) por session_id
- Compartido entre múltiples servidores de app → el usuario puede ir a cualquier instancia

### Por qué Redis > instancia local para sesiones

```
Sin Redis (sesiones locales):
  ┌─────────────────────────────────────────────────────────┐
  │  Load Balancer                                           │
  │      ↓              ↓              ↓                     │
  │  App Server 1   App Server 2   App Server 3             │
  │  [sesión usuario A]                                      │
  │                                                          │
  │  Si el usuario A va al Server 2 → "no iniciaste sesión" │
  │  Requiere sticky sessions en el LB (single point of failure)│
  └─────────────────────────────────────────────────────────┘

Con Redis (sesiones centralizadas):
  ┌─────────────────────────────────────────────────────────┐
  │  Load Balancer (round-robin)                             │
  │      ↓              ↓              ↓                     │
  │  App Server 1   App Server 2   App Server 3             │
  │                    ↓                                     │
  │              ElastiCache Redis                           │
  │              [sesión:abc123 → {user_id, cart, ...}]     │
  │                                                          │
  │  Cualquier server lee la sesión → no hay sticky sessions │
  └─────────────────────────────────────────────────────────┘
```

### Demo Session Store

```python
#!/usr/bin/env python3
# session_store_demo.py

import redis
import json
import uuid
import time

REDIS_HOST = "redis-lab-cluster.xxxxxx.ng.0001.euw1.cache.amazonaws.com"
SESSION_TTL = 3600  # 1 hora

r = redis.Redis(host=REDIS_HOST, port=6379, ssl=True, decode_responses=True)

def create_session(user_id: str, user_data: dict) -> str:
    """Crea una sesión en Redis y devuelve el session_id."""
    session_id = str(uuid.uuid4())
    session_data = {
        "user_id": user_id,
        "created_at": time.time(),
        **user_data
    }
    r.setex(f"session:{session_id}", SESSION_TTL, json.dumps(session_data))
    return session_id

def get_session(session_id: str) -> dict:
    """Obtiene los datos de una sesión (o None si expiró)."""
    data = r.get(f"session:{session_id}")
    if data:
        # Refrescar TTL con cada acceso (sliding expiration)
        r.expire(f"session:{session_id}", SESSION_TTL)
        return json.loads(data)
    return None

def destroy_session(session_id: str):
    """Invalida una sesión (logout)."""
    r.delete(f"session:{session_id}")

def update_cart(session_id: str, item: str, quantity: int):
    """Actualiza el carrito en la sesión."""
    session = get_session(session_id)
    if not session:
        return False
    cart = session.get("cart", {})
    cart[item] = quantity
    session["cart"] = cart
    r.setex(f"session:{session_id}", SESSION_TTL, json.dumps(session))
    return True

# --- Demo ---
print("\n=== DEMO SESSION STORE ===\n")

# Login: crear sesión
session_id = create_session("1001", {"nombre": "Ana García", "cart": {}})
print(f"Sesión creada: {session_id[:8]}...")

# Añadir items al carrito
update_cart(session_id, "libro-aws", 1)
update_cart(session_id, "teclado", 2)

# Leer sesión desde cualquier servidor de app
session = get_session(session_id)
print(f"Sesión recuperada: user={session['user_id']}, carrito={session['cart']}")

# TTL restante
ttl = r.ttl(f"session:{session_id}")
print(f"TTL restante: {ttl}s ({ttl//60} minutos)")

# Logout
destroy_session(session_id)
print(f"Sesión destruida")
assert get_session(session_id) is None, "La sesión debería haber expirado"
print("✓ Sesión correctamente eliminada\n")
```

---

## Parte C — Leaderboard con Sorted Sets (bonus SAA)

Redis Sorted Sets son perfectos para leaderboards en tiempo real:

```bash
# En redis-cli
PRIMARY="redis-lab-cluster.xxxxxx.ng.0001.euw1.cache.amazonaws.com"
redis-cli -h $PRIMARY -p 6379 --tls

# Añadir usuarios con puntuación
ZADD leaderboard 1500 "ana"
ZADD leaderboard 2300 "carlos"
ZADD leaderboard 1800 "maria"
ZADD leaderboard 3100 "pedro"

# Top 3 (orden descendente)
ZREVRANGE leaderboard 0 2 WITHSCORES
# 1) "pedro" 2) "3100"
# 3) "carlos" 4) "2300"
# 5) "maria" 6) "1800"

# Actualizar puntuación
ZINCRBY leaderboard 500 "ana"

# Posición de un usuario
ZREVRANK leaderboard "ana"
# 3 (posición 4, 0-indexed)
```

---

## ✅ Validaciones de la fase

```bash
PRIMARY="redis-lab-cluster.xxxxxx.ng.0001.euw1.cache.amazonaws.com"

# 1. Cache-Aside: claves en Redis
redis-cli -h $PRIMARY -p 6379 --tls KEYS "customer:*"
# customer:1001, customer:1002, customer:1003

# 2. TTL activo
redis-cli -h $PRIMARY -p 6379 --tls TTL customer:1001
# 280 (o similar, menor que 300)

# 3. Memoria usada
redis-cli -h $PRIMARY -p 6379 --tls INFO memory | grep used_memory_human

# 4. Keyspace
redis-cli -h $PRIMARY -p 6379 --tls INFO keyspace
# db0:keys=X,expires=Y,avg_ttl=Z
```

---

## Conceptos SAA-C03 cubiertos

| Patrón | Caso de uso | Ventaja |
|--------|-------------|---------|
| Cache-Aside | Datos de producto/cliente leídos frecuentemente | Reduce carga en RDS ~90% |
| Session Store | Sesiones HTTP entre múltiples instancias | Elimina sticky sessions en el LB |
| Sorted Sets (ZADD/ZREVRANGE) | Leaderboards, top-N queries | O(log N) insertions + reads |
| TTL por clave (SETEX) | Datos temporales, sesiones, cache | Expiración automática sin código extra |
