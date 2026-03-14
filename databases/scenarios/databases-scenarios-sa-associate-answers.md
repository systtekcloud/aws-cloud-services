# Databases — Respuestas SAA-C03

> Respuestas a: [databases-scenarios-sa-associate.md](./databases-scenarios-sa-associate.md)
> **No abrir hasta haber respondido cada escenario.**

---

## Escenario 1 — Sistema de historiales médicos: rendimiento y alta disponibilidad

**Respuesta correcta: B**

Este escenario explota la confusión más frecuente del examen: **Multi-AZ ≠ escalado de lecturas**.

RDS Multi-AZ mantiene una instancia **standby** sincronizada en otra AZ mediante replicación síncrona. El standby existe exclusivamente para failover automático — **no sirve tráfico de lectura en ningún momento**. Es invisible para la aplicación hasta que el primary falla. Aumentar la capacidad del standby o intentar enrutarle lecturas es imposible: AWS no expone un endpoint separado para él.

La solución correcta es **Read Replicas** porque son instancias RDS reales con su propio endpoint, que sirven consultas SELECT sin competir con las escrituras del writer. La arquitectura resultante:

- **Writer endpoint** → escrituras de enfermería (actualizaciones de signos vitales)
- **Read Replica endpoint(s)** → lecturas de médicos (historial, laboratorio)
- **Multi-AZ** → continúa proporcionando failover automático sin cambios

El cambio en la aplicación es mínimo: configurar el ORM/driver para usar el endpoint de réplica en las queries de solo lectura. Se puede hacer en caliente sin interrupciones. El coste de una réplica `db.t3.medium` o equivalente está dentro del presupuesto de $800/mes.

**Por qué cada incorrecta falla en producción**

**A — Usar el standby de Multi-AZ para lecturas:** AWS **no permite** conectarse directamente a la instancia standby de Multi-AZ. No tiene endpoint propio ni acepta conexiones de cliente. Esta opción es técnicamente imposible, no solo mala práctica. Si el director de TI intenta implementarla, no encontrará ningún endpoint para configurar.

**C — Migrar a Aurora sin réplicas:** Aurora tiene mejor rendimiento de almacenamiento (6 copias en 3 AZs), pero si hay un solo nodo Aurora sin réplicas, **todas las lecturas siguen compitiendo con las escrituras** en la misma instancia. El almacenamiento distribuido de Aurora no reduce la carga de CPU del nodo de cómputo. Además, la migración a Aurora requiere planificación y una ventana de mantenimiento que el enunciado prohíbe. No resuelve el problema de fondo.

**D — RDS Proxy:** El Proxy es un pool de conexiones que reduce el número de conexiones simultáneas y acelera el failover. **No distribuye carga de lecturas entre primary y standby** — eso es físicamente imposible porque el standby no acepta conexiones. El Proxy enruta todo el tráfico al primary hasta que ocurre un failover. No resuelve el 85% de CPU por lecturas.

**Exam tip**

> **Multi-AZ = HA (failover automático). Read Replicas = rendimiento de lecturas.** Son ortogonales y complementarios. Cuando el escenario describe **alta CPU o latencia alta en lecturas** con Multi-AZ ya activo, la respuesta siempre implica añadir **Read Replicas**. La frase "¿no debería Multi-AZ distribuir la carga?" es el distractor clásico — la respuesta es siempre NO.

---

## Escenario 2 — Plataforma de e-commerce: lecciones de un incidente en Black Friday

**Respuesta correcta: B**

El post-mortem reveló dos problemas distintos que la solución debe resolver juntos:

**Problema 1 — Failover automático en < 60 s:** Las Read Replicas de RDS PostgreSQL **no hacen failover automático**. Son instancias de solo lectura que requieren promoción manual, actualización de DNS y reinicio de aplicación — exactamente los 23 minutos del incidente. Ni siquiera activar Multi-AZ en RDS resuelve el segundo problema.

**Problema 2 — Creación de réplicas en < 15 min:** RDS crea réplicas desde snapshot: clona el volumen EBS (o de storage), lo que tarda 30–60 minutos dependiendo del tamaño. Con 2 TB de datos, 45 minutos es normal.

**Aurora PostgreSQL resuelve ambos problemas:**

- **Failover:** Aurora mantiene el cluster endpoint invariable. Cuando el writer falla, Aurora promueve automáticamente una réplica a writer en **< 30 segundos** (típicamente 15–20 s). La aplicación no necesita cambiar de endpoint — el cluster endpoint resuelve siempre al writer actual.
- **Creación de réplicas:** Las Aurora Replicas comparten el mismo volumen de almacenamiento del cluster (no clonan datos). Crear una nueva Aurora Replica toma **5–10 minutos** independientemente del tamaño de los datos, porque no hay copia de datos — solo se provisiona el nodo de cómputo.

La migración puede hacerse con `aws dms` o usando el endpoint de réplica para minimizar el downtime.

**Por qué cada incorrecta falla en producción**

**A — RDS Multi-AZ + mantener Read Replicas:** Esto resuelve el problema 1 (failover automático en ~60-120 s con RDS Multi-AZ), pero **no resuelve el problema 2**. Las Read Replicas de RDS PostgreSQL seguirían tardando 45 minutos en crearse, incumpliendo el objetivo de < 15 minutos. Además, el RTO con RDS Multi-AZ es de 60–120 segundos — en el límite del objetivo de 60 s — frente a los < 30 s de Aurora.

**C — Script Lambda para promover réplica:** Reproducir manualmente el proceso de failover con Lambda introduce latencia adicional (detección por CloudWatch → invocación Lambda → promoción → actualización Route 53). El SLA de Route 53 TTL añade más latencia. En la práctica, este proceso tardará entre 5 y 15 minutos — muy por encima del objetivo de 60 s. Además, es frágil: si el Lambda falla, no hay fallback.

**D — Multi-AZ + ElastiCache, eliminar Read Replicas:** ElastiCache Redis es excelente para absorber lecturas repetitivas (catálogo de productos es un candidato ideal), pero **no puede absorber queries dinámicas o personalizadas** que no estén en caché. Eliminar las Read Replicas significa que cualquier cache miss impacta directamente al writer. Con 90% de lecturas, un cache hit rate del 70% aún deja el 27% de lecturas totales en el writer — potencialmente más que antes si el catálogo es muy dinámico.

**Exam tip**

> **Read Replicas RDS = escalar lecturas, NO HA.** Si el escenario menciona "promover réplica manualmente" como su mecanismo de recuperación, es la señal de que necesitan **Multi-AZ o Aurora**. Para RTO < 60 s y creación de réplicas rápida, la respuesta es **Aurora**. La clave diferencial es el almacenamiento compartido de Aurora: sin copia de datos al crear réplicas.

---

## Escenario 3 — Plataforma de gaming: throttling en tabla DynamoDB de partidas

**Respuesta correcta: B**

El problema tiene **dos dimensiones independientes** que una solución completa debe abordar:

**Dimensión 1 — Hot partition en escrituras:** DynamoDB distribuye los datos en particiones basándose en el hash de la PK. Con `PK = "GAME#<game_id>"` único por partida, las escrituras están bien distribuidas. El problema está en que **todas las partidas activas comparten el mismo SK prefix `STATUS#active`**. Aunque DynamoDB no hace sharding por SK (el SK es solo orden dentro de la partición), las lecturas/escrituras que buscan por este valor compiten por las mismas particiones internas. El sharding del SK con un sufijo aleatorio (`STATUS#active#<0-9>`) distribuye las claves en más particiones lógicas, reduciendo la contención.

**Dimensión 2 — Query ineficiente de partidas activas por jugador:** Un `Scan` con `FilterExpression` lee **todos los items de la tabla** y descarta los que no coinciden — es O(n) en RCU independientemente del resultado. Con 50.000 partidas activas entre millones de items totales, esto es extremadamente ineficiente. La solución correcta es un **GSI** con `PK = "PLAYER#<player_id>"` que permita hacer `Query` en O(resultado) — solo lee los items que coinciden.

La opción B aborda ambas dimensiones correctamente y mantiene On-Demand.

**Por qué cada incorrecta falla en producción**

**A — Cambiar a Provisioned + Auto Scaling:** Auto Scaling de DynamoDB tiene una latencia de reacción de **varias decenas de segundos a minutos** — el throttling ocurre en los primeros minutos de un lanzamiento, exactamente cuando el auto scaling aún no ha reaccionado. Además, un hot partition con muchas escrituras al mismo prefijo de clave puede causar throttling **incluso con capacidad reservada abundante**, porque DynamoDB limita el throughput por partición física. Cambiar a Provisioned no elimina la causa raíz del hot partition.

**C — DAX para lecturas:** DAX es un caché de lectura para DynamoDB. El problema descrito son **throttles en escrituras** (`PutItem`, `UpdateItem`), no en lecturas. DAX no puede absorber escrituras — solo hace write-through. Añadir DAX no reduce la presión de escritura en el hot partition ni mejora el `Scan` ineficiente de forma sostenible (el Scan sigue consumiendo RCU de la tabla subyacente en el primer MISS de caché).

**D — Tabla separada para partidas activas:** Separar por estado resuelve parcialmente el problema de concentración, pero introduce complejidad operativa significativa: hay que garantizar la consistencia entre tablas al cambiar el estado de una partida (transacción o lógica de aplicación compleja). Si la operación de "mover partida terminada" falla a mitad, los datos quedan inconsistentes. El GSI de la opción B es más elegante y no requiere sincronización entre tablas.

**Exam tip**

> **Hot partition = mal diseño de PK/SK.** Cuando el escenario describe throttling concentrado en un subconjunto de items (misma categoría, mismo estado, mismo prefijo), la solución siempre implica **write sharding** (sufijo aleatorio) o rediseño de claves. `Scan` con `FilterExpression` = señal de alerta — siempre reemplazar por `Query` con **GSI**. On-Demand no elimina el throttling de hot partitions — el límite es por partición, no por tabla.

---

## Escenario 4 — Catálogo de e-commerce: nuevos patrones de acceso sin rediseño

**Respuesta correcta: B**

La premisa crítica del escenario es que **la tabla ya existe en producción con millones de items**. Esto hace que la opción A sea imposible por definición:

- **LSI (Local Secondary Index):** Solo puede crearse **en el momento de crear la tabla**. Una vez que la tabla existe, no es posible añadir ni eliminar LSIs. Esta es una limitación absoluta de DynamoDB, no configurable ni con actualizaciones de la tabla.
- **GSI (Global Secondary Index):** Se puede **crear y eliminar en cualquier momento** en una tabla existente, en caliente, sin interrumpir el servicio. DynamoDB rellena el GSI de forma asíncrona leyendo la tabla existente.

Para los tres casos de uso descritos, los GSIs son la herramienta correcta:

1. **GSI-category** (`PK = category`, `SK = price`) → permite `Query` por categoría ordenada por precio. La proyección debe incluir `name`, `image`, `product_id`.
2. **GSI-rating** (`PK = "ALL_PRODUCTS"`, `SK = rating`) → permite `Query` sobre todos los productos ordenados por rating. El valor fijo de PK es un hot partition menor aceptable para lecturas de homepage (pocos items, caché fácil).
3. **GSI-brand** (`PK = brand`, `SK = product_id`) con `stock_count` proyectado → permite `Query` por marca y filtrar en aplicación por `stock_count > 0`.

**Por qué cada incorrecta falla en producción**

**A — Crear LSIs:** **Técnicamente imposible** en una tabla existente. Esta opción es la trampa central del escenario. En el examen, si ves LSI propuesto para una tabla "existente" o con datos actuales, es siempre incorrecta. El arquitecto del escenario tiene razón al objetarla. El impacto en producción: el intento de `update-table` con nuevos LSIs devuelve un error inmediato de la API.

**C — Scan paralelo con TotalSegments:** Un `Scan` con `FilterExpression` consume **RCU proporcional a los datos leídos, no a los datos devueltos**. Con 4 millones de items y lecturas de 1KB cada uno, un Scan completo consume ~4 millones de RCU — aproximadamente €4–6 por scan en modo On-Demand. Con el catálogo consultándose cientos de veces por hora, el coste sería prohibitivo y la latencia de 2–4 segundos persistiría. El paralelismo reduce el tiempo de pared, no el consumo total de RCU.

**D — Query con FilterExpression sobre tabla principal:** `FilterExpression` en una `Query` solo filtra después de leer los items. Si `category` no es parte de la clave de la tabla principal (`PK = "PRODUCT#<id>"`), DynamoDB **no puede hacer Query** por ese atributo sin un GSI — solo puede hacer Scan. La opción propone usar `FilterExpression` en `Query`, lo cual requiere que `category` sea parte de la PK o SK de la tabla o un índice. Es una mezcla de conceptos que no funciona como se describe.

**Exam tip**

> **LSI = solo al crear la tabla, misma PK, distinto SK. GSI = en cualquier momento, cualquier clave.** Cuando el enunciado dice "tabla existente" + "nuevo patrón de acceso", la respuesta es siempre **GSI**. Memorizar: `Scan + FilterExpression` siempre es sospechoso en el examen — buscar la opción con `Query + GSI` como sustituto.

---

## Escenario 5 — SaaS multi-tenant: sesiones rotas al escalar horizontalmente

**Respuesta correcta: C**

El problema raíz es que las sesiones residen **en la memoria local de cada EC2** — son estado local en un sistema que necesita ser stateless. La solución arquitectónica correcta es externalizar las sesiones a un almacén centralizado, compartido y de alta disponibilidad.

**ElastiCache Redis** es la elección óptima por varias razones:

- **Latencia:** Redis tiene latencia de submilisegundo (< 1 ms) para operaciones de `GET`/`SET`. DynamoDB tiene latencia de 1–10 ms en condiciones normales — 10x mayor. Para sesiones que se consultan en cada request HTTP, la diferencia es perceptible.
- **TTL nativo:** `SETEX session:<id> 28800 <data>` establece automáticamente la expiración. El TTL se puede renovar en cada request con `EXPIRE`, implementando sliding expiration. DynamoDB TTL tiene una latencia de eliminación de **hasta 48 horas** — no es garantía de expiración puntual.
- **Multi-AZ con failover automático:** El Replication Group de Redis (Primary + Replica en AZs distintas) proporciona HA. Si el Primary falla, la Replica se promueve automáticamente en ~30 segundos.
- **Expansión multi-región en 6 meses:** Redis es un protocolo estándar — la aplicación puede conectarse a clusters Redis en cualquier región. Para multi-región real, existe ElastiCache Global Datastore (Redis).
- **TLS en tránsito:** `transit_encryption_enabled = true` cifra la comunicación entre la app y Redis — requisito implícito para datos de sesión de usuarios.

Con esta arquitectura, el ALB ya no necesita sticky sessions: cualquier instancia EC2 puede atender cualquier request porque todas acceden al mismo Redis.

**Por qué cada incorrecta falla en producción**

**A — Sticky sessions + scale-in protection:** Esta opción trata el síntoma, no la causa. Scale-in protection bloquea la terminación de instancias con usuarios activos, pero ¿cuánto tiempo? Si una sesión dura 8 horas, la instancia no puede terminarse en 8 horas — destruye el ahorro de coste del Auto Scaling. Además, no resuelve el caso de fallo de instancia (hardware failure): si la EC2 falla, las sesiones se pierden igualmente. La función Lambda que "revisa usuarios activos" introduce latencia y complejidad sin resolver el problema de fondo.

**B — DynamoDB para sesiones:** DynamoDB es una solución válida, pero **subóptima para sesiones** por dos razones: (1) latencia de 1–10 ms es 10x mayor que Redis — con un servicio SaaS con decenas de miles de requests/segundo, esto suma latencia perceptible; (2) el TTL de DynamoDB no es preciso — la eliminación puede retrasarse hasta 48 horas, lo que significa que sesiones "expiradas" podrían ser reutilizadas si la aplicación no verifica el timestamp manualmente. Para el requisito de expiración en exactamente 8 horas, Redis es más fiable.

**D — ElastiCache Memcached:** Memcached no tiene **replicación ni failover automático**. Si un nodo de Memcached falla, todas las sesiones almacenadas en ese nodo se pierden — exactamente el mismo problema que con la memoria local de EC2, simplemente externalizado. Memcached tampoco tiene persistencia: un restart del cluster elimina todos los datos. Para sesiones de usuario en producción, la pérdida de datos ante fallos de nodo es inaceptable.

**Exam tip**

> Para **session store**, la respuesta es siempre **ElastiCache Redis** (nunca Memcached). Las palabras clave que lo confirman: "sesiones se pierden al escalar", "sticky sessions como workaround", "stateless app tier", "Auto Scaling rompe sesiones". Redis = TTL exacto + replicación + HA. Memcached = sin HA, sin persistencia, sin replicación → nunca para sesiones críticas.

---

## Escenario 6 — Banco digital: recuperación ante desastres multi-región

**Respuesta correcta: B**

Este escenario expone las **limitaciones ocultas de las Read Replicas cross-region** que el CISO del banco desconoce, y por qué Aurora Global Database es cualitativamente diferente.

**Limitaciones de la Read Replica cross-region (situación actual):**

1. **RPO no garantizado:** La replicación de Read Replicas cross-region es **asíncrona**. El `ReplicaLag` puede estar en segundos o minutos dependiendo del volumen de escrituras. Con 120.000 transacciones/hora, el lag puede crecer significativamente durante picos. No hay SLA de RPO.
2. **RTO de 30–60+ minutos:** Promover una Read Replica cross-region a cluster standalone requiere: detener la réplica, esperar a que aplique todos los cambios pendientes del binlog, iniciar el nuevo cluster, actualizar la configuración de la aplicación. El proceso no es automatizado — requiere intervención manual paso a paso. En un banco con carga alta, puede tardar 30–60 minutos fácilmente.
3. **Sin failover drill real:** Promover una Read Replica cross-region es **destructivo** — el cluster resultante es independiente, no puede "volver" al rol de réplica automáticamente. Para hacer un drill trimestral, el banco tendría que recrear la réplica desde cero cada vez.

**Aurora Global Database resuelve todos estos problemas:**

- **RPO < 1 s:** La replicación es a nivel de storage (no de binlog), con latencia típica de **< 1 segundo**. Es un SLA documentado por AWS.
- **RTO < 1 min:** El `failover-global-cluster` (managed failover) promueve la región secundaria en **< 1 minuto** de forma automatizada. La aplicación cambia el endpoint.
- **Failover drill no destructivo:** Aurora Global Database soporta **"planned failover"** que intercambia roles primario/secundario de forma bidireccional — el drill puede ejecutarse y revertirse sin recrear nada.
- **KMS CMK cross-region:** Aurora Global Database soporta CMKs replicadas entre regiones con AWS KMS.

**Por qué cada incorrecta falla en producción**

**A — Mantener Read Replica cross-region con runbook manual:** El RTO real de este proceso con 2 TB de datos y lag en hora punta supera los 15 minutos incluso con el mejor runbook. Más crítico: el regulador exige **demostrarlo** trimestralmente. Cada drill destruye la réplica, que luego hay que recrear (45+ minutos de recreación más sincronización). El coste operativo y el riesgo de error humano son inaceptables para un banco.

**C — RDS MySQL Multi-AZ + Read Replica cross-region:** Esta opción mezcla dos servicios distintos y hereda las limitaciones de la Read Replica cross-region descrita en A. Además, RDS Multi-AZ solo protege **dentro de la misma región** — no contribuye al RPO/RTO cross-region. Migrar de Aurora a RDS representa un retroceso técnico significativo (pierde las ventajas de Aurora: almacenamiento distribuido, failover rápido, creación rápida de réplicas) sin ningún beneficio DR adicional.

**D — Activo-activo con DMS:** La replicación bidireccional con DMS introduce el problema de **conflictos de escritura**. En un sistema bancario, dos regiones aceptando escrituras simultáneas sobre las mismas cuentas/transacciones puede generar inconsistencias irrecuperables (e.g., la misma cuenta se debita dos veces en distintas regiones). DMS no tiene resolución de conflictos para datos transaccionales — ese problema pertenece a la lógica de negocio. Además, DMS tiene latencia variable y no garantiza ordenación de transacciones. Para datos financieros, activo-activo real requiere un diseño de datos mucho más sofisticado (e.g., CRDTs, particionado estricto por región) que DMS no proporciona.

**Exam tip**

> **Read Replica cross-region ≠ DR con RTO/RPO garantizados.** Para cumplir RPO < 1 min y RTO < 15 min cross-region, la respuesta es **Aurora Global Database**. Los distractores intentan que confundas "tengo datos en otra región" con "puedo hacer failover en < 15 min". La clave del examen: si el enunciado menciona RPO en segundos o RTO en minutos cross-region, busca **Aurora Global Database**. Si solo menciona HA dentro de una región, Multi-AZ es suficiente.
