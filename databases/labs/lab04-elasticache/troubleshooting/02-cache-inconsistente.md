# Troubleshooting 02 — ElastiCache: Datos obsoletos en caché

## Escenario

Los usuarios ven datos desactualizados después de una actualización en la base de datos. Por ejemplo:
- El usuario actualiza su dirección en RDS
- La respuesta de la API sigue mostrando la dirección antigua durante varios minutos

---

## Diagnóstico

### Paso 1: Verificar si el dato está siendo servido desde caché

```bash
redis-cli -h $PRIMARY -p 6379 --tls GET "customer:1001"
# Si devuelve datos → están en caché
# Si devuelve (nil) → no están en caché (se sirven de DB)

# Ver el TTL restante
redis-cli -h $PRIMARY -p 6379 --tls TTL "customer:1001"
# Número positivo → tiempo en segundos hasta que expire
# -1 → sin TTL (nunca expira → problema potencial)
# -2 → ya no existe
```

### Paso 2: Comprobar si hay TTL en las claves

```bash
# Ver todas las claves de clientes y sus TTLs
redis-cli -h $PRIMARY -p 6379 --tls KEYS "customer:*" | while read key; do
  ttl=$(redis-cli -h $PRIMARY -p 6379 --tls TTL "$key")
  echo "$key → TTL: $ttl"
done
```

Si aparece `-1` (sin TTL) en claves que deberían expirar → datos que nunca se actualizan.

---

## Causas y soluciones

### Causa 1 — Se usa SET sin TTL (las claves nunca expiran)

```python
# ❌ MAL: SET sin expiración → dato queda en caché para siempre
r.set(f"customer:{customer_id}", json.dumps(data))

# ✅ BIEN: SETEX con TTL razonable
CACHE_TTL = 300  # 5 minutos
r.setex(f"customer:{customer_id}", CACHE_TTL, json.dumps(data))
```

**Fix para claves existentes sin TTL:**

```bash
# Añadir TTL a una clave que no lo tiene
redis-cli -h $PRIMARY -p 6379 --tls EXPIRE "customer:1001" 300

# O actualizar todas las claves de clientes con TTL
for key in $(redis-cli -h $PRIMARY -p 6379 --tls KEYS "customer:*"); do
  redis-cli -h $PRIMARY -p 6379 --tls EXPIRE "$key" 300
done
```

### Causa 2 — No se invalida la caché al actualizar en DB (cache stale)

El patrón Cache-Aside require **invalidar o actualizar la clave en Redis cuando se modifica la DB**.

```python
# ❌ MAL: actualiza en DB pero no en caché
def update_customer_bad(customer_id, new_data):
    db.execute("UPDATE customers SET ... WHERE id = ?", (customer_id,))
    # ← caché sigue teniendo el dato antiguo hasta que expire

# ✅ BIEN: invalidar caché tras actualizar DB
def update_customer_good(customer_id, new_data):
    # 1. Actualizar en DB (fuente de verdad)
    db.execute("UPDATE customers SET ... WHERE id = ?", (customer_id,))
    # 2. Invalidar caché
    cache_key = f"customer:{customer_id}"
    r.delete(cache_key)
    # En el siguiente GET, habrá un MISS y se leerá el dato fresco de DB
```

**Estrategia alternativa — Write-Through:**
```python
def update_customer_write_through(customer_id, new_data):
    # 1. Actualizar en DB
    db.execute("UPDATE customers SET ... WHERE id = ?", (customer_id,))
    # 2. Actualizar en caché directamente (sin invalidar)
    r.setex(f"customer:{customer_id}", CACHE_TTL, json.dumps(new_data))
    # Ventaja: no hay MISS después del update
    # Desventaja: dos escrituras (DB + caché) en cada update
```

### Causa 3 — TTL demasiado largo para datos que cambian frecuentemente

```python
# Para datos que cambian mucho (precio de stock, inventario):
CACHE_TTL = 30   # 30 segundos

# Para datos relativamente estables (perfil de usuario, descripción de producto):
CACHE_TTL = 3600  # 1 hora

# Para datos que casi nunca cambian (catálogo de productos):
CACHE_TTL = 86400  # 24 horas
```

### Causa 4 — Race condition al invalidar (concurrent updates)

En entornos con alta concurrencia, puede darse que:
1. Thread A lee de DB → MISS en caché
2. Thread B actualiza en DB + invalida caché
3. Thread A guarda en caché el valor antiguo (antes del update de B)

**Fix — Usar transacciones Redis (WATCH/MULTI/EXEC) o simplemente TTL corto:**

```python
import redis

def get_customer_safe(customer_id):
    cache_key = f"customer:{customer_id}"
    pipe = r.pipeline()

    # Usar WATCH para detectar cambios concurrentes
    try:
        pipe.watch(cache_key)
        cached = pipe.get(cache_key)

        if cached:
            return json.loads(cached)

        # MISS: leer de DB
        data = get_from_db(customer_id)

        pipe.multi()
        pipe.setex(cache_key, CACHE_TTL, json.dumps(data))
        pipe.execute()
        return data

    except redis.WatchError:
        # Otro proceso modificó la clave — reintentar o ir directo a DB
        return get_from_db(customer_id)
    finally:
        pipe.reset()
```

---

## Estrategias de invalidación de caché (para el examen)

| Estrategia | Descripción | Cuándo usar |
|------------|-------------|-------------|
| **TTL-based** | Cada clave expira automáticamente | Datos con tolerancia a estar desactualizados |
| **Invalidación explícita** | `DEL key` al actualizar en DB | Datos críticos que deben estar frescos |
| **Write-Through** | Actualizar caché y DB en el mismo paso | Writes frecuentes, lecturas muy frecuentes |
| **Write-Behind** | Actualizar caché primero, DB después (async) | Latencia de escritura crítica (riesgo de pérdida de datos) |

---

## Resumen SAA-C03

| Pregunta | Respuesta |
|----------|-----------|
| ¿Cómo evitar datos obsoletos en caché? | TTL + invalidación explícita al actualizar |
| ¿Cuál es el patrón más común con ElastiCache? | **Cache-Aside (Lazy Loading)** |
| ¿Qué hace Write-Through? | Actualiza caché y DB simultáneamente |
| ¿Desventaja del Write-Through? | Cache pollution (guarda datos que nunca se leen) |
