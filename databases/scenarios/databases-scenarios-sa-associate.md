# Databases — Escenarios SAA-C03

> 6 escenarios de arquitectura estilo examen real.
> Las respuestas están en: [databases-scenarios-sa-associate-answers.md](./databases-scenarios-sa-associate-answers.md)

---

## Índice

| # | Industria | Patrón principal | Compliance |
|---|-----------|-----------------|------------|
| [1](#escenario-1) | Healthcare | RDS Multi-AZ vs Read Replicas — HA vs escalado de lecturas | HIPAA |
| [2](#escenario-2) | Retail | RDS vs Aurora — failover RTO y crecimiento | — |
| [3](#escenario-3) | Gaming | DynamoDB — hot partition y key design | — |
| [4](#escenario-4) | E-Commerce | DynamoDB — GSI y nuevos patrones de acceso | — |
| [5](#escenario-5) | SaaS | ElastiCache Redis — session store y escalado horizontal | — |
| [6](#escenario-6) | Banking | DR multi-región — Aurora Global Database vs Read Replicas | PCI-DSS |

---

## Escenario 1

### Sistema de historiales médicos: rendimiento y alta disponibilidad

Un hospital universitario ejecuta su sistema de historiales clínicos electrónicos (EHR) sobre Amazon RDS MySQL en configuración **Multi-AZ** en eu-west-1. El sistema tiene dos tipos de carga claramente diferenciados: escrituras de enfermería (actualizaciones de signos vitales, medicación) y lecturas de médicos (consulta de historial completo antes de visita, resultados de laboratorio). En los últimos tres meses, los médicos reportan que las páginas de historial tardan entre 4 y 8 segundos en cargar, impactando negativamente la atención al paciente. Las métricas de CloudWatch muestran que la instancia RDS alcanza un 85% de CPU durante las rondas de visita (08:00–11:00 y 15:00–17:00), con `ReadIOPS` saturando consistentemente.

El equipo de infraestructura propone varias soluciones. El Director de TI señala que ya tienen Multi-AZ activo y pregunta "¿no debería eso resolver el problema de rendimiento distribuyendo la carga entre las dos instancias?". El equipo de cumplimiento exige que cualquier cambio mantenga un **RTO < 2 minutos** y **RPO ≈ 0** en caso de fallo de la instancia primaria, que es el requisito actual de HIPAA del hospital.

El presupuesto aprobado es de +$800/mes adicionales. La base de datos tiene 2 TB de datos históricos y el volumen crece 50 GB/mes. El equipo no puede permitirse una interrupción de servicio para realizar el cambio.

**Requisitos técnicos**
- Reducir la latencia de lecturas de 4–8 s a menos de 1 s
- Mantener RTO < 2 min y RPO ≈ 0 ante fallo del writer
- Sin ventana de mantenimiento — cambio en caliente
- Presupuesto adicional: máximo $800/mes
- Compliance HIPAA: datos siempre cifrados en tránsito y en reposo

**Opciones**

**A)** La configuración Multi-AZ actual ya tiene una instancia standby sincronizada en otra AZ. Cambiar el endpoint de la aplicación para que apunte directamente a la instancia standby para las consultas de lectura. Esto distribuye la carga entre primary y standby sin coste adicional.

**B)** Crear una o dos Read Replicas de RDS MySQL en la misma región. Modificar la aplicación para enrutar las consultas de solo lectura al endpoint de la Read Replica y mantener las escrituras en el endpoint del writer. Conservar Multi-AZ para HA. Asegurarse de que la réplica también usa cifrado KMS.

**C)** Migrar de RDS Multi-AZ a Aurora MySQL con Multi-AZ desactivado. Aurora tiene almacenamiento distribuido en 6 copias sobre 3 AZs internamente, lo que proporciona mejor rendimiento de lectura que RDS estándar incluso sin réplicas.

**D)** Activar RDS Proxy delante de la instancia Multi-AZ. El Proxy agrupa las conexiones de la aplicación y distribuye las consultas entre la instancia primaria y standby, reduciendo la carga de CPU en el writer.

---

## Escenario 2

### Plataforma de e-commerce: lecciones de un incidente en Black Friday

Una plataforma de retail online sufrió un incidente crítico durante el Black Friday. A las 10:47 AM, la instancia RDS PostgreSQL primaria perdió conectividad por un fallo de hardware en la zona de disponibilidad eu-west-1b. El equipo tardó **23 minutos** en restablecer el servicio: primero detectaron el problema (8 min), luego promovieron manualmente una Read Replica a instancia principal (11 min), y finalmente actualizaron el DNS de conexión en la aplicación (4 min). Durante esos 23 minutos, el carrito de compras y el checkout estuvieron completamente inoperativos, con una pérdida estimada de €180.000.

El post-mortem reveló que la arquitectura tenía **dos Read Replicas** para escalar las consultas del catálogo de productos, pero ninguna configuración de Multi-AZ. El equipo asumía incorrectamente que las Read Replicas proporcionaban alta disponibilidad automática ante fallos del writer. Adicionalmente, el equipo quiere reducir el tiempo de creación de Read Replicas: actualmente crear una nueva réplica desde el snapshot tarda 45 minutos, lo cual es inadecuado para escalar durante picos de tráfico imprevistos.

Para el próximo Black Friday, el CTO ha establecido un objetivo de **RTO < 60 segundos** ante cualquier fallo de instancia y mantener la capacidad de escalar réplicas de lectura en menos de 15 minutos. El equipo también menciona que el catálogo de productos recibe 90% lecturas vs 10% escrituras, y quieren mantener esa escalabilidad de lecturas.

**Requisitos técnicos**
- RTO < 60 segundos ante fallo de la instancia writer (failover automático)
- RPO ≈ 0 (sin pérdida de transacciones)
- Crear nuevas réplicas de lectura en < 15 minutos ante picos
- Ratio 90% lecturas / 10% escrituras — escalar lecturas eficientemente
- Sin cambios en el esquema de datos

**Opciones**

**A)** Activar Multi-AZ en la instancia RDS PostgreSQL existente y mantener las dos Read Replicas actuales. Multi-AZ proveerá failover automático en < 60 segundos al standby, y las Read Replicas seguirán sirviendo lecturas. Para crear réplicas más rápido, activar Auto Scaling de réplicas.

**B)** Migrar de RDS PostgreSQL a Amazon Aurora PostgreSQL. Aurora proporciona failover automático a una réplica en < 30 segundos (sin cambio de endpoint si se usa el cluster endpoint), y las Aurora Replicas comparten el volumen de almacenamiento del cluster por lo que se crean en 5–10 minutos en lugar de 45.

**C)** Mantener la arquitectura actual (solo Read Replicas, sin Multi-AZ) pero implementar un script de Lambda que monitorice el writer vía CloudWatch y promueva automáticamente una Read Replica cuando detecte un fallo. El script actualiza el registro DNS en Route 53 con el nuevo endpoint.

**D)** Añadir Multi-AZ a RDS PostgreSQL y eliminar las Read Replicas. Para el catálogo de productos (lecturas intensivas), añadir una capa de ElastiCache Redis en modo cache-aside que absorba el 90% de lecturas sin llegar a la base de datos.

---

## Escenario 3

### Plataforma de gaming: throttling en tabla DynamoDB de partidas

Una startup de gaming móvil tiene una plataforma de juego de estrategia en tiempo real con 800.000 jugadores activos. Utilizan DynamoDB con capacidad **On-Demand** para almacenar el estado de las partidas activas. La tabla tiene la siguiente estructura:

```
PK: "GAME#<game_id>"
SK: "STATUS#<estado>"   (valores: "active", "waiting", "finished")
Atributos: player_ids, start_time, turn_count, last_updated
```

El equipo observa que cada vez que lanzan un nuevo modo de juego, miles de partidas se crean simultáneamente con `SK = "STATUS#active"`. CloudWatch muestra `ThrottledRequests` en `PutItem` y `UpdateItem` durante los primeros 15 minutos del lanzamiento. El soporte de AWS les ha informado que están experimentando un **hot partition**: todas las escrituras de nuevas partidas activas van a la misma partición lógica porque comparten el mismo prefijo de SK.

El equipo también necesita una operación frecuente: "lista de todas las partidas activas de un jugador" (`query by player_id where STATUS = active`). Actualmente hacen `Scan` con `FilterExpression`, lo cual consume muchas RCU y tiene latencia de 2–4 segundos.

El volumen es de ~50.000 partidas activas simultáneas. El equipo no quiere volver a capacidad Provisioned porque los picos son muy impredecibles.

**Requisitos técnicos**
- Eliminar el throttling en escrituras durante lanzamientos de nuevos modos
- Query "partidas activas de un jugador" en < 100 ms
- Mantener On-Demand (no quieren gestionar RCU/WCU)
- Sin rediseño completo de la aplicación
- Coste mensual no debe incrementarse más del 30%

**Opciones**

**A)** Mantener el diseño actual de claves pero cambiar a capacidad **Provisioned** con Application Auto Scaling configurado al 70% de utilización. Establecer WCU mínimas en 10.000 y máximas en 50.000. El auto scaling absorberá los picos del lanzamiento sin throttling.

**B)** Rediseñar la clave de sort para incluir un sufijo de shard aleatorio: `SK = "STATUS#active#<shard>"` donde `<shard>` es un número del 0 al 9 calculado como `random.randint(0,9)`. Para listar todas las partidas activas de un jugador, añadir un GSI con `PK = "PLAYER#<player_id>"` y `SK = "GAME#<game_id>"`. Mantener On-Demand.

**C)** Activar DynamoDB Accelerator (DAX) delante de la tabla. DAX cachea los resultados de `GetItem` y `Query`, reduciendo el número de lecturas que llegan a DynamoDB. Esto libera capacidad de la tabla para absorber más escrituras durante los lanzamientos.

**D)** Separar las partidas activas en una tabla DynamoDB independiente llamada `active-games`, con `PK = "PLAYER#<player_id>"` y `SK = "GAME#<game_id>"`. Cuando una partida termina, se mueve a la tabla principal. Esto aísla el hot partition al no mezclar estados.

---

## Escenario 4

### Catálogo de e-commerce: nuevos patrones de acceso sin rediseño

Una empresa de e-commerce tiene su catálogo de productos en DynamoDB con el siguiente esquema de Single-Table Design:

```
PK: "PRODUCT#<product_id>"
SK: "METADATA" | "STOCK#<warehouse_id>" | "REVIEW#<review_id>"
Atributos: category, brand, price, stock_count, rating
```

La tabla fue diseñada hace 18 meses para dos casos de uso: obtener un producto por ID (`GetItem`) y listar reviews de un producto (`Query by PK`). Ahora el equipo de producto necesita tres nuevos casos de uso que **no estaban en el diseño original**:

1. "Listar todos los productos de una categoría ordenados por precio" (para la página de categoría)
2. "Listar los 20 productos con mayor rating" (para la home page)
3. "Buscar productos de una marca específica con stock > 0" (para campañas de marca)

El lead de datos propone crear un **LSI** (Local Secondary Index) por categoría. El arquitecto de sistemas objeta que eso es imposible en una tabla existente y propone alternativas. La tabla tiene 4 millones de items y recibe 2.000 lecturas/segundo en hora punta. El equipo quiere mantener consistencia eventual en las nuevas consultas (no necesitan consistencia fuerte para el catálogo).

**Requisitos técnicos**
- Soportar los 3 nuevos patrones de acceso sin hacer `Scan` sobre la tabla completa
- La tabla ya existe — no se puede recrear (millones de items en producción)
- Consistencia eventual aceptable para lecturas del catálogo
- Latencia < 50 ms para las nuevas consultas
- Coste adicional aceptable: los GSIs se cobran por almacenamiento + throughput

**Opciones**

**A)** Crear un LSI con `PK = "PRODUCT#<product_id>"` y clave de sort por `category` para el caso de uso 1. Crear otro LSI para `rating` para el caso de uso 2. Los LSIs no tienen coste adicional de almacenamiento significativo.

**B)** Crear tres GSIs independientes: `GSI-category` con `PK = category` y `SK = price`, `GSI-rating` con `PK = "ALL_PRODUCTS"` y `SK = rating`, y `GSI-brand` con `PK = brand` y `SK = product_id` con atributo proyectado `stock_count`. Mantener consistencia eventual en todas las queries.

**C)** Para los tres nuevos casos de uso, usar `Scan` con `FilterExpression` y paralelizar el scan en 4 segmentos (`TotalSegments=4`). Esto es más barato que crear GSIs porque no duplica el almacenamiento.

**D)** Usar `Query` con `FilterExpression` sobre la tabla principal, filtrando por `category` o `brand` en los atributos no clave. Añadir índices solo si la latencia sigue siendo inaceptable después de 30 días de observación.

---

## Escenario 5

### SaaS multi-tenant: sesiones rotas al escalar horizontalmente

Una empresa de SaaS ofrece una plataforma de gestión de proyectos B2B con 3.000 empresas clientes. La aplicación corre en instancias EC2 (Auto Scaling Group) detrás de un Application Load Balancer. Las sesiones de usuario se almacenan **en memoria local de cada instancia EC2** usando el módulo de sesiones del framework web. Cuando hay poca carga (2 instancias EC2), el equipo usa **sticky sessions en el ALB** para asegurarse de que cada usuario siempre va a la misma instancia.

El problema: durante picos de carga (fin de sprint, lunes por la mañana), el Auto Scaling escala de 2 a 8 instancias. Los usuarios cuya instancia anterior fue reemplazada pierden su sesión y son forzados a hacer login de nuevo. Esto ocurre varias veces por semana y genera tickets de soporte. Además, cuando el ASG escala hacia abajo, si la instancia eliminada tenía usuarios activos con sticky session, esos usuarios también pierden sesión.

El equipo considera varias soluciones. Tienen además un requisito de seguridad: las sesiones deben expirar automáticamente tras 8 horas de inactividad. La empresa tiene planes de expandir a dos regiones adicionales en 6 meses para dar servicio a clientes en LATAM y Asia-Pacífico.

**Requisitos técnicos**
- Las sesiones deben sobrevivir el escalado/reducción del ASG
- Expiración automática de sesión por inactividad (8 horas TTL)
- Latencia de acceso a sesión < 5 ms
- Alta disponibilidad del almacén de sesiones (Multi-AZ)
- Preparado para expansión multi-región en 6 meses
- Las sesiones deben sobrevivir el reinicio/fallo de una instancia EC2

**Opciones**

**A)** Configurar **sticky sessions persistentes** en el ALB con duración de cookie de 8 horas. Modificar el Auto Scaling para usar `scale-in protection` en instancias con sesiones activas. Una función Lambda revisa periódicamente si hay usuarios activos antes de permitir que el ASG termine una instancia.

**B)** Almacenar las sesiones en **Amazon DynamoDB** con TTL habilitado (8 horas). La aplicación serializa la sesión como un item de DynamoDB con `session_id` como PK y un atributo `ttl` con el timestamp de expiración. Multi-AZ está incluido en DynamoDB por diseño.

**C)** Desplegar **Amazon ElastiCache for Redis** con Replication Group (Primary + Replica en diferentes AZs) y `transit_encryption_enabled = true`. Almacenar las sesiones con `SETEX session:<session_id> 28800 <serialized_data>`. La aplicación se conecta siempre al Primary endpoint para escribir y leer sesiones. Eliminar las sticky sessions del ALB.

**D)** Desplegar **Amazon ElastiCache for Memcached** en modo cluster con 4 nodos. Distribuir las sesiones usando consistent hashing entre los nodos para minimizar los cache misses. Configurar el TTL de cada entrada a 28800 segundos (8 horas).

---

## Escenario 6

### Banco digital: recuperación ante desastres multi-región

Un banco digital procesa 120.000 transacciones por hora usando Amazon Aurora MySQL como base de datos transaccional principal en eu-west-1 (Irlanda). El regulador bancario europeo (BCE) exige demostrar que el banco puede recuperarse ante la pérdida completa de una región AWS con **RPO < 1 minuto** y **RTO < 15 minutos**. El banco debe poder ejecutar un "failover drill" cada trimestre para demostrar la capacidad de recuperación al regulador.

Actualmente tienen una **Aurora Read Replica en eu-central-1** (Frankfurt) que replica desde el cluster primario de eu-west-1. El CISO asume que esto cumple los requisitos de DR: "tenemos los datos en dos regiones". Sin embargo, el equipo de arquitectura ha identificado que la solución actual tiene limitaciones críticas que no son evidentes hasta que se necesita el failover real.

El banco también tiene un requisito de compliance PCI-DSS: todos los datos deben estar cifrados con claves KMS gestionadas por el banco, y el acceso a las credenciales de base de datos debe auditarse completamente. Cada minuto de inoperatividad en producción tiene un impacto regulatorio y financiero de aproximadamente €15.000.

**Requisitos técnicos**
- RPO < 1 minuto ante pérdida completa de eu-west-1
- RTO < 15 minutos con failover ejecutable por el equipo de operaciones (sin intervención de AWS)
- Cifrado KMS con Customer Managed Keys (CMK) en ambas regiones
- Credenciales de DB gestionadas en Secrets Manager con rotación automática
- Failover drill ejecutable trimestralmente sin impacto en producción
- Coste de la solución DR debe ser inferior al €15.000/h de impacto regulatorio

**Opciones**

**A)** Mantener la Aurora Read Replica cross-region actual. Documentar el runbook de failover manual: (1) detener réplica, (2) promover Read Replica a cluster standalone, (3) actualizar DNS en Route 53, (4) reiniciar aplicaciones apuntando al nuevo endpoint. Estimar el tiempo real del runbook mediante simulacros en entorno de staging.

**B)** Convertir el cluster actual a **Aurora Global Database** con eu-west-1 como región primaria y eu-central-1 como región secundaria. La replicación es a nivel de storage con latencia típica de < 1 segundo. En caso de desastre, el equipo ejecuta un "managed planned failover" (o "unplanned failover") desde la consola o CLI, que promueve automáticamente la región secundaria en < 1 minuto de RTO.

**C)** Reemplazar Aurora por **Amazon RDS for MySQL Multi-AZ** en eu-west-1 y añadir una Read Replica en eu-central-1. Multi-AZ proporciona HA dentro de la región (RTO ~1-2 min), y la Read Replica sirve como DR cross-region. Esto es más económico que Aurora Global Database.

**D)** Implementar una arquitectura activo-activo con dos clusters Aurora independientes en eu-west-1 y eu-central-1, usando AWS DMS (Database Migration Service) para replicación bidireccional continua. Ambas regiones aceptan escrituras simultáneamente, eliminando el concepto de "failover" — si una región falla, la otra ya está activa.

---
