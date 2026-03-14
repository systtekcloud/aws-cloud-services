# Troubleshooting 03 — ElastiCache: Elegir entre Redis y Memcached

## Escenario

Este es un "troubleshooting" de diseño, no de operaciones. El escenario típico en el examen SAA-C03:

> "Una empresa necesita una capa de caché para reducir la carga en su RDS. Los requisitos son: alta disponibilidad, persistencia de datos en caso de reinicio, y capacidad para almacenar estructuras de datos complejas. ¿Qué servicio AWS debería usar?"

La respuesta correcta depende de los requisitos específicos. Esta guía te ayuda a elegir sin dudas.

---

## Árbol de decisión Redis vs Memcached

```
¿Necesitas alguna de estas características?
├── Persistencia (datos sobreviven al reinicio)         → REDIS
├── Replicación / Failover automático                   → REDIS
├── Multi-AZ                                            → REDIS
├── Estructuras de datos complejas (sorted sets, lists) → REDIS
├── Pub/Sub messaging                                   → REDIS
├── Lua scripting                                       → REDIS
├── Streams (Redis Streams)                             → REDIS
├── Geo commands (GEOADD, GEORADIUS)                    → REDIS
└── Solo caché simple K/V con máximo throughput
    ├── Necesito escalar horizontalmente de forma sencilla → MEMCACHED
    └── Quiero multi-threading para máximo CPU utilization  → MEMCACHED
```

---

## Tabla comparativa completa

| Característica | Redis | Memcached |
|----------------|-------|-----------|
| **Persistencia** | ✅ RDB + AOF | ❌ |
| **Replicación** | ✅ Primary + Replicas | ❌ |
| **Failover automático** | ✅ | ❌ |
| **Multi-AZ** | ✅ | ❌ (multi-node, same AZ shard) |
| **Cluster Mode** | ✅ hasta 500 shards | ✅ hasta 20 nodos |
| **Tipos de datos** | String, Hash, List, Set, Sorted Set, Stream, HyperLogLog | String solamente |
| **Sorted Sets (leaderboards)** | ✅ | ❌ |
| **Pub/Sub** | ✅ | ❌ |
| **Multi-thread** | ❌ (single-threaded) | ✅ |
| **Backup/Restore** | ✅ | ❌ |
| **Encryption at rest** | ✅ | ❌ |
| **Encryption in transit (TLS)** | ✅ | ❌ |
| **AUTH / ACL** | ✅ | ❌ (no autenticación nativa) |
| **Tamaño máx. objeto** | 512 MB | 1 MB |

---

## Casos de uso en el examen SAA-C03

### Cuando la respuesta es Redis

| Caso de uso | Por qué Redis |
|-------------|---------------|
| Session Store | Necesita TTL por clave + alta disponibilidad |
| Leaderboard / Ranking | Sorted Sets (ZADD/ZREVRANGE) |
| Rate Limiting | Atomic INCR + TTL |
| Pub/Sub (chat, notificaciones) | Redis Pub/Sub |
| Gaming leaderboards | Sorted Sets |
| Queues simples | Lists (LPUSH/RPOP) |
| Cache con HA y failover | Replication + Multi-AZ |
| Cache que sobrevive reinicios | Persistencia RDB |

### Cuando la respuesta podría ser Memcached

| Caso de uso | Por qué Memcached |
|-------------|-------------------|
| Cache de objetos simples a muy alta velocidad | Multi-threaded, menor overhead |
| Necesito sharding horizontal muy sencillo | Arquitectura simpler |
| No necesito HA ni persistencia | Sin replica overhead |

> **Realidad en el examen:** Casi siempre la respuesta es Redis. Memcached solo aparece cuando el escenario explícitamente dice "no necesita HA" o "máximo throughput con multi-threading".

---

## Casos de distractor frecuentes en el examen

### Distractor 1: "La aplicación necesita caché de objetos para reducir latencia"
→ Podría ser Redis o Memcached. Busca pistas adicionales como "HA", "failover", "persistencia".

### Distractor 2: "Necesita almacenar sesiones de usuario entre múltiples instancias EC2"
→ **Redis** — necesita TTL, HA, y persistencia opcional.

### Distractor 3: "Necesita un leaderboard en tiempo real"
→ **Redis** — Sorted Sets son perfectos para esto (Memcached no tiene Sorted Sets).

### Distractor 4: "Base de datos en memoria de baja latencia para millones de requests"
→ Podría ser Redis o DAX (si es DynamoDB). Leer bien si menciona DynamoDB.

---

## DAX vs ElastiCache: otro par frecuente

| | DAX | ElastiCache Redis |
|--|-----|-------------------|
| Para qué DB | DynamoDB only | RDS, Aurora, cualquier DB |
| Protocolo | API DynamoDB | Redis protocol |
| Latencia | microsegundos | microsegundos |
| Cache invalidation | Automática (con write-through) | Manual o TTL |
| Instalación | Sin cambios en app (compatible API DDB) | Requiere cambios en app |
| Cuándo usar | Tienes DynamoDB y quieres caché sin cambiar código | Tienes RDS/Aurora o necesitas patrones Redis |

---

## Resumen SAA-C03 — La Cheatsheet final

```
Redis = HA + Persistencia + Tipos complejos + Pub/Sub + Multi-AZ
Memcached = Simple K/V + Multi-thread + Sin HA + Sin persistencia

ElastiCache Redis = cache para RDS/Aurora/cualquier DB
DAX = cache para DynamoDB (API compatible, no requiere cambios en app)
```

**Tip del examen:** Si ves "session store", "leaderboard", "pub/sub", "persistencia en caché", "failover en caché" → siempre Redis.
