# Compute EC2 — Escenarios SAA-C03

> 10 escenarios de arquitectura estilo examen real.
> Las respuestas están en: [compute-scenarios-sa-associate-answers.md](./compute-scenarios-sa-associate-answers.md)

---

## Índice

| # | Industria | Patrón principal | Compliance |
|---|-----------|-----------------|------------|
| [1](#escenario-1) | Fintech | ALB vs NLB — TLS pass-through y preservación de IP fuente | PCI-DSS |
| [2](#escenario-2) | SaaS | Route 53 weighted vs failover — TTL y DNS caching en blue/green | — |
| [3](#escenario-3) | E-Commerce Global | CloudFront vs Global Accelerator — contenido dinámico vs estático | — |
| [4](#escenario-4) | Media | Auto Scaling troubleshooting — instancias unhealthy desde el inicio | — |
| [5](#escenario-5) | Healthcare | 2-tier vs 3-tier — seguridad de subnets y SG cascade | HIPAA |
| [6](#escenario-6) | Data Analytics | Cost optimization — Spot, On-Demand y Savings Plans | — |
| [7](#escenario-7) | SaaS B2B | Deregistration delay — requests en vuelo y 502 durante scaling | — |
| [8](#escenario-8) | Trading | Global Accelerator multi-región — RTO < 30 s sin DNS propagation | — |
| [9](#escenario-9) | Retail | Cross-AZ traffic costs — factura inesperada en arquitectura Multi-AZ | — |
| [10](#escenario-10) | Enterprise | ASG + ElastiCache + stateless — sesiones y acceso seguro sin bastion | — |

---

## Escenario 1

### Plataforma de pagos: cifrado extremo a extremo sin terminación en el load balancer

Una fintech europea procesa pagos con tarjeta bajo PCI-DSS Level 1. Su arquitectura actual usa un **Application Load Balancer** que termina TLS en el listener (certificado ACM) y reenvía el tráfico en HTTP plano a instancias EC2 en subnets privadas. El equipo de seguridad acaba de recibir el informe de la auditoría QSA (Qualified Security Assessor): el dato de tarjeta viaja cifrado desde el navegador hasta el ALB, pero **en texto plano desde el ALB hasta el servidor de aplicación** dentro de la VPC. El auditor lo clasifica como hallazgo crítico: el tráfico HTTP interno podría ser capturado por cualquier proceso con acceso a la red de la VPC (e.g., un contenedor comprometido en la misma subnet).

Adicionalmente, el equipo de operaciones necesita que los servidores de backend puedan ver la **IP real del cliente** (no la del ALB) en los logs de auditoría PCI, porque el requisito 10.3 de PCI-DSS exige registrar la IP de origen de cada transacción. El sistema procesa 4.000 transacciones por minuto con una latencia p95 de 120 ms end-to-end. Cualquier cambio debe hacerse **sin modificar el código de la aplicación** que procesa el pago.

El volumen de conexiones es de ~500 TPS en hora punta. Los servidores backend tienen sus propios certificados TLS instalados con una CA privada interna. No hay WebSockets ni conexiones long-lived — son peticiones HTTP POST de corta duración (< 2 s).

**Requisitos técnicos**
- TLS cifrado extremo a extremo: desde el cliente hasta el backend (sin terminación en LB)
- IP real del cliente visible en los logs del backend (requisito PCI-DSS 10.3)
- Sin cambios en el código de la aplicación de pagos
- Latencia p95 < 150 ms, 500 TPS en pico
- Alta disponibilidad Multi-AZ

**Opciones**

**A)** Mantener el ALB actual pero cambiar el target group a HTTPS (puerto 443). El ALB termina TLS en el listener y abre una nueva conexión TLS cifrada hacia el backend. Añadir `X-Forwarded-For` header en el ALB para que el backend lea la IP real del cliente desde ese header.

**B)** Reemplazar el ALB por un **Network Load Balancer** con listener TCP en el puerto 443. Configurar TLS pass-through: el NLB no termina TLS sino que reenvía los bytes TCP tal cual al backend. Activar **Proxy Protocol v2** en el target group para que el backend reciba la IP real del cliente en el header del protocolo.

**C)** Mantener el ALB con listener HTTPS y añadir un **AWS WAF** delante. WAF inspeccionará el tráfico cifrado y bloqueará ataques. Configurar un Security Group que permita solo al ALB comunicarse con el backend. Esto satisface el requisito de seguridad sin cambiar el flujo TLS.

**D)** Reemplazar el ALB por un **Classic Load Balancer** en modo TCP. El CLB en modo TCP actúa como pass-through sin terminar TLS. Añadir `X-Forwarded-For` en la configuración del CLB para pasar la IP del cliente.

---

## Escenario 2

### Plataforma SaaS: migración blue/green con Route 53 y usuarios atrapados en versión antigua

Una empresa de SaaS ha desplegado una nueva versión (v2) de su API en un nuevo conjunto de instancias EC2 detrás de un nuevo ALB. Mantienen la versión anterior (v1) activa. Para hacer una migración gradual, configuraron **Route 53 Weighted Routing** con dos records apuntando a `api.empresa.com`:

- Record v1: peso 90, TTL 300 s → ALB v1
- Record v2: peso 10, TTL 300 s → ALB v2

Tras 48 horas de observación sin incidentes, el equipo decide hacer el switch completo: cambian el peso de v1 a **0** y el de v2 a **100** desde la consola de Route 53. Sin embargo, el equipo de soporte empieza a recibir llamadas de clientes que siguen llegando a v1 durante los siguientes **8–12 minutos**. Algunos clientes empresariales con DNS corporativo siguen en v1 durante más de 30 minutos.

El equipo de QA necesita además implementar una política que automáticamente deje de enviar tráfico a una región si el health check falla — algo que el routing weighted actual no hace aunque el endpoint v2 esté caído. En la siguiente iteración, el equipo también quiere ser capaz de hacer un **failover inmediato** (< 60 s) si v2 presenta errores 5xx, volviendo a v1 como destino de todo el tráfico.

**Requisitos técnicos**
- Migración gradual controlable (porcentaje de tráfico ajustable)
- Failover automático si un endpoint está unhealthy (sin intervención manual)
- Tiempo de propagación del cambio al 100% < 60 segundos
- Sin interrupción de servicio durante la migración
- Los health checks deben validar respuestas HTTP 200 en `/health`

**Opciones**

**A)** Mantener Weighted Routing pero reducir el TTL de los records a **10 segundos** antes del cambio final. Cuando todos los resolvers hayan expirado el caché, el switch es efectivo en 10 s. Para failover automático, añadir health checks de Route 53 a cada record weighted — si el health check falla, Route 53 excluye ese record automáticamente.

**B)** Migrar la política de Weighted a **Failover Routing** con v2 como Primary y v1 como Secondary. Route 53 Failover con health check cambia automáticamente al Secondary si Primary está unhealthy. Para la migración gradual, usar el peso del ALB (listener rules) en lugar de Route 53.

**C)** Mantener el TTL actual de 300 s. El problema de los 8–12 minutos es esperado y correcto — es el tiempo necesario para que los resolvers refresquen el caché. Reducir el TTL aumenta el coste de Route 53 y la carga en los name servers. Documentar en el runbook que los cambios tardan hasta 5 minutos en propagarse.

**D)** Usar **Route 53 Latency Routing** en lugar de Weighted, con ambas versiones desplegadas en la misma región. Latency Routing elige el endpoint con menor latencia observada, distribuyendo el tráfico gradualmente hacia v2 si tiene mejor rendimiento. Añadir health checks para failover automático.

---

## Escenario 3

### E-commerce global: latencia alta en API de búsqueda para usuarios de Asia y LATAM

Una plataforma de e-commerce con sede en eu-west-1 (Irlanda) tiene usuarios en Europa, Asia-Pacífico (Tokio, Singapur) y Latinoamérica (São Paulo). El contenido estático del frontend (imágenes, CSS, JS) ya está servido mediante **Amazon CloudFront** con excelente rendimiento (< 50 ms p95 globalmente). Sin embargo, las llamadas a la **API de búsqueda de productos** (`/api/search`) siguen haciendo round-trip hasta eu-west-1, con latencia de **380–520 ms p95** para usuarios en Asia y de **290–340 ms p95** para LATAM. El 70% de los abandono de sesión ocurren en usuarios que esperan más de 300 ms para los resultados de búsqueda.

El equipo propone expandir CloudFront para también cachear las respuestas de la API de búsqueda. Sin embargo, el arquitecto señala que las búsquedas son personalizadas (incluyen el historial de búsqueda del usuario, su tier de precios y su localización exacta), por lo que **el cache hit rate sería inferior al 5%**: casi todas las respuestas de búsqueda son únicas. El coste de CloudFront por request `GET` es de $0.0085/10.000 requests — con 50 millones de requests/día y < 5% de cache hit, el coste sería similar al de otras alternativas.

El equipo de plataforma también menciona que en el pasado tuvieron un incidente de 45 minutos donde eu-west-1 era accesible pero la latencia desde Asia subía a 4+ segundos por congestión en tránsito de internet — sin que ningún health check lo detectara.

**Requisitos técnicos**
- Reducir latencia de API de búsqueda a < 150 ms p95 para Asia y LATAM
- La API no es cacheable (< 5% cache hit rate esperado)
- Detección y failover automático ante degradación de rendimiento, no solo fallos completos
- Sin redeploy de la aplicación en múltiples regiones (seguir con eu-west-1 como único backend)
- Presupuesto de optimización de red: máximo $2.000/mes adicionales

**Opciones**

**A)** Extender CloudFront para incluir `/api/search` como behavior adicional. Aunque el cache hit rate sea bajo, CloudFront usa la red de AWS entre los edge locations y el origen (eu-west-1), acelerando el tráfico dinámico. Configurar TTL = 0 en ese behavior para que CloudFront no cachee pero sí use la ruta de red optimizada.

**B)** Desplegar instancias EC2 de la API de búsqueda en ap-northeast-1 (Tokio) y sa-east-1 (São Paulo) con Route 53 Latency Routing. Cada región tiene su propia base de datos sincronizada. Esto reduce la latencia a < 50 ms en esas regiones.

**C)** Colocar **AWS Global Accelerator** delante del ALB en eu-west-1. Global Accelerator enruta el tráfico desde el edge location más cercano al usuario hacia eu-west-1 a través de la red backbone privada de AWS, evitando el internet público. Configurar health checks con umbrales de latencia para detectar degradación, no solo fallos.

**D)** Implementar **Amazon API Gateway** con caché de respuestas habilitado para `/api/search`. API Gateway Edge-Optimized distribuye el punto de entrada globalmente via CloudFront. Configurar TTL de caché de 60 segundos con invalidación basada en `user_id` para personalización.

---

## Escenario 4

### Plataforma de streaming: instancias del Auto Scaling Group nunca pasan a healthy

Un equipo de DevOps gestiona una plataforma de streaming de vídeo bajo demanda. Tienen un Auto Scaling Group con Launch Template (Amazon Linux 2, `t3.large`) detrás de un Application Load Balancer. Tras un cambio de configuración desplegado ayer, el ASG lanza nuevas instancias correctamente pero el ALB las marca como **unhealthy** a los 30 segundos. El ASG termina las instancias unhealthy y lanza nuevas inmediatamente, creando un ciclo continuo. CloudWatch muestra que el ASG ha lanzado y terminado 47 instancias en las últimas 2 horas. La aplicación en eu-west-1 está completamente caída.

El equipo verifica:
- Las instancias se lanzan correctamente (EC2 `running`)
- El `user_data` instala la aplicación (visible en `/var/log/cloud-init-output.log`)
- El proceso de la app arranca en el puerto 8080 (confirmado con `ss -tlnp | grep 8080`)
- Los logs de la aplicación no muestran errores

El health check del ALB está configurado con: **path `/healthz`**, puerto `traffic-port` (8080), protocolo HTTP, intervalo 15 s, threshold 2 checks, timeout 5 s.

El Security Group del ALB tiene outbound `0.0.0.0/0`. El Security Group de las EC2 tiene inbound del SG del ALB en el puerto **80** (modificado ayer como parte del cambio).

**Requisitos técnicos**
- Diagnóstico y resolución sin terminar las instancias manualmente
- Restaurar el servicio en < 15 minutos
- Evitar que el ASG siga en ciclo de lanzamiento/terminación (instance flapping)

**Opciones**

**A)** El problema es que el health check path `/healthz` no existe en la nueva versión de la aplicación. Cambiar el path del health check a `/` (root) en la configuración del ALB target group. Si `/` devuelve 200, el ALB marcará las instancias como healthy.

**B)** El Security Group de las EC2 permite inbound del ALB solo en el puerto 80, pero la aplicación escucha en el 8080 y el health check usa `traffic-port` (8080). El ALB no puede alcanzar el puerto 8080 de las EC2 → health check falla. Añadir una regla inbound en el SG de las EC2 que permita al SG del ALB en el puerto 8080 (o cambiar la regla de puerto 80 a 8080).

**C)** El problema es el **Grace Period** del Auto Scaling Group, que está configurado en 0 segundos. Las instancias tardan ~45 s en arrancar completamente, pero el ASG las evalúa como unhealthy inmediatamente. Aumentar el Health Check Grace Period a 120 segundos.

**D)** Las instancias están siendo lanzadas en subnets privadas sin ruta de salida a internet, por lo que `user_data` no puede descargar los paquetes de la aplicación. Cambiar las subnets del ASG a subnets públicas o añadir un NAT Gateway para que el user_data tenga conectividad.

---

## Escenario 5

### Sistema de historiales clínicos: arquitectura 2-tier expuesta a auditoría HIPAA

Un hospital regional tiene su sistema de gestión de historiales clínicos (EHR) desplegado en AWS con la siguiente arquitectura actual: las instancias EC2 (servidor de aplicación + servidor web en el mismo proceso) están en **subnets públicas** con IPs públicas asignadas. El Security Group de las EC2 permite inbound en los puertos 443 (HTTPS desde internet) y 22 (SSH desde la IP de la oficina del administrador). La base de datos RDS PostgreSQL está en una subnet privada, con su Security Group aceptando conexiones desde el SG de las EC2.

La auditoría HIPAA ha marcado tres hallazgos críticos: (1) los servidores de aplicación tienen IP pública directamente expuesta a internet, innecesaria ya que hay un ALB delante; (2) el acceso SSH con clave privada en el ordenador del administrador es un vector de riesgo si el portátil es robado; (3) no hay separación entre la capa de presentación web y la capa de lógica de negocio. El auditor exige una arquitectura de **mínima exposición** antes de la siguiente auditoría en 90 días.

El sistema tiene ~200 usuarios internos (médicos, enfermeras, administración). No hay usuarios externos — el sistema solo es accesible desde la intranet del hospital y desde VPN corporativa. No hay requisito de baja latencia pública; la prioridad es la seguridad y el cumplimiento.

**Requisitos técnicos**
- Servidores de aplicación en subnets privadas (sin IP pública)
- Acceso administrativo sin SSH keys ni puertos abiertos hacia internet
- Separación de tiers: presentación / aplicación / datos
- Acceso solo desde VPN corporativa o intranet del hospital
- Sin ventana de mantenimiento extendida (cambio incremental)

**Opciones**

**A)** Mover las instancias EC2 a subnets privadas. Eliminar las IPs públicas. Añadir un **Application Load Balancer** en subnets públicas como punto de entrada HTTPS. El ALB tiene un Security Group que acepta HTTPS (443) solo desde el rango CIDR de la VPN corporativa. Eliminar la regla SSH del SG de las EC2. Instalar el agente **SSM** en las instancias y usar **AWS Systems Manager Session Manager** para acceso administrativo via consola AWS o CLI.

**B)** Mantener las instancias en subnets públicas pero eliminar las IPs públicas. Sin IP pública, las instancias no son accesibles desde internet aunque estén en subnet pública. Añadir un ALB y restringir el SG de las EC2 para aceptar solo tráfico del SG del ALB. El SSH se reemplaza por EC2 Instance Connect (no requiere clave pre-instalada).

**C)** Mover las instancias a subnets privadas y crear un **bastion host** en una subnet pública con IP pública. El bastion tiene SSH habilitado desde la IP de la VPN corporativa. Los administradores hacen SSH al bastion y desde ahí SSH a las instancias privadas. Eliminar SSH directo a las instancias de aplicación.

**D)** Mantener la arquitectura actual pero implementar **AWS Network Firewall** en las subnets públicas para inspeccionar el tráfico y bloquear accesos no autorizados. El Network Firewall actúa como capa de seguridad perimetral sin necesidad de mover las instancias. Añadir reglas para bloquear el escaneo de puertos y los intentos de SSH desde IPs no autorizadas.

---

## Escenario 6

### Empresa de data analytics: optimizar costes de compute para cargas mixtas

Una empresa de analytics tiene dos tipos de carga diferenciada en AWS. El **tier web** (API y dashboards) corre en 6 instancias `m5.xlarge` 24/7 que siempre deben estar disponibles — es la cara del negocio hacia los clientes. El **tier de procesamiento** ejecuta jobs de transformación de datos que leen de S3, procesan en memoria y escriben resultados en S3; estos jobs corren típicamente entre las 18:00 y las 06:00 (12 horas/día) y son tolerantes a interrupciones (están diseñados para reiniciar desde checkpoints). El procesamiento usa instancias `r5.4xlarge` con una flota de entre 10 y 40 instancias según la carga. La factura de EC2 del mes pasado fue de $28.000.

El equipo de finanzas ha solicitado reducir el coste de EC2 en al menos un 40% sin degradar el SLA de disponibilidad del tier web (99,9%). El arquitecto identifica que actualmente todas las instancias (web y procesamiento) son **On-Demand**, y ninguna tiene Savings Plan ni Reserved Instance. El tier de procesamiento tiene un consumo base predecible de 10 instancias `r5.4xlarge` durante las 12 horas de ventana, con picos de hasta 40 instancias.

**Requisitos técnicos**
- SLA 99,9% para el tier web (6 instancias `m5.xlarge` siempre disponibles)
- El tier de procesamiento puede tolerar interrupciones con reinicio desde checkpoint
- Reducción de coste ≥ 40% sobre la factura actual
- Máxima flexibilidad para cambiar tipos de instancia en el futuro
- Implementar en < 30 días (sin migración compleja)

**Opciones**

**A)** Comprar **Reserved Instances** de 1 año, sin pago inicial, para las 6 instancias web (`m5.xlarge`) y para las 10 instancias base de procesamiento (`r5.4xlarge`). Para los picos de procesamiento (hasta 40 instancias), usar On-Demand. Las Reserved Instances dan hasta 40% de descuento y el compromiso de 1 año es aceptable dado que ambas cargas son estables.

**B)** Aplicar un **Compute Savings Plan** de 1 año para cubrir el gasto base continuo (las 6 instancias web + las 10 de procesamiento base). Los Compute Savings Plans son más flexibles que las RIs (aplican a cualquier familia, región y OS). Para los picos de procesamiento, usar instancias **Spot** en un ASG con múltiples tipos de instancia y AZs, aprovechando la tolerancia a interrupciones del diseño.

**C)** Mantener todo On-Demand pero implementar **Auto Scaling agresivo** que apague las instancias web durante horas de baja demanda (02:00–08:00) y las del tier de procesamiento cuando no hay jobs. El ahorro de las horas apagadas compensará la falta de descuentos por compromiso.

**D)** Convertir el tier web a instancias **Spot** con una estrategia de múltiples tipos de instancia (`m5.xlarge`, `m4.xlarge`, `m5a.xlarge`) para minimizar interrupciones. Las interrupciones de Spot se producen con 2 minutos de aviso — tiempo suficiente para drenar conexiones del ALB. Para el procesamiento, usar Spot directamente sin cambios.

---

## Escenario 7

### Plataforma SaaS B2B: errores 502 durante deployments en horas punta

Una empresa de SaaS tiene una API REST de gestión de facturas que atiende a 3.000 empresas clientes. La arquitectura usa un ALB con un Auto Scaling Group de instancias `c5.large`. El equipo de desarrollo despliega nuevas versiones cada martes a las 14:00 usando un script que: (1) pone la nueva versión en S3, (2) lanza nuevas instancias con el nuevo código via `user_data`, (3) espera a que estén healthy en el ALB, (4) termina las instancias antiguas.

El problema: los clientes reportan errores **HTTP 502 Bad Gateway** y **504 Gateway Timeout** durante aproximadamente 3–4 minutos cada vez que se hace un deployment en horas de negocio. El análisis de los logs del ALB muestra que los 502 ocurren exactamente cuando las instancias antiguas pasan al estado `draining` (deregistering). Las instancias procesan peticiones de generación de facturas PDF que pueden tardar hasta **90 segundos** en completarse. El **Deregistration Delay** del target group está configurado en el valor por defecto de **300 segundos**.

El equipo revisa el código y confirma que la aplicación no implementa graceful shutdown — cuando el proceso recibe SIGTERM, termina inmediatamente sin esperar a que las peticiones en curso finalicen.

**Requisitos técnicos**
- Cero errores 502/504 durante deployments
- Las peticiones de generación de factura (hasta 90 s) no deben interrumpirse
- Sin cambios en el código de la aplicación (limitación del equipo)
- El deployment completo no debe tardar más de 15 minutos
- Coste de implementación: mínimo

**Opciones**

**A)** El Deregistration Delay de 300 s debería ser suficiente para las peticiones de 90 s. El problema real es que las instancias están en subnets distintas y el ALB tiene **cross-zone load balancing deshabilitado** — las instancias de una AZ drenan antes de que las de otra AZ estén healthy, creando un gap de capacidad. Habilitar cross-zone load balancing.

**B)** El Deregistration Delay de 300 s es mayor que la duración máxima de las peticiones (90 s), por lo que debería funcionar. El problema son los health checks: están configurados con un **intervalo de 30 s y threshold de 3 checks** (90 s en total). Las nuevas instancias tardan 90 s en pasar a healthy, durante los cuales el ALB tiene menos capacidad y sobrecarga las instancias existentes antes de que estas inicien el draining. Reducir el intervalo de health check a 10 s con threshold 2 (20 s para pasar a healthy).

**C)** La aplicación no hace graceful shutdown — al recibir SIGTERM (cuando EC2 es terminada), el proceso muere inmediatamente aunque haya peticiones en curso. El Deregistration Delay protege durante el periodo de draining del ALB, pero **el ASG termina la instancia EC2 cuando el draining completa** (o cuando expira el delay). Si una petición lleva 85 s y el delay expira antes de que finalice, el proceso muere. Reducir el Deregistration Delay a **110 segundos** (90 s de petición máxima + 20 s de margen) y añadir un **Lifecycle Hook** de tipo `autoscaling:EC2_INSTANCE_TERMINATING` que añada 120 s adicionales antes de la terminación definitiva, permitiendo que las peticiones en curso finalicen.

**D)** Cambiar la estrategia de deployment a **Blue/Green** con dos ASGs separados: ASG-blue (versión actual) y ASG-green (nueva versión). El ALB tiene dos target groups. Cuando green está healthy, cambiar las listener rules para enviar el 100% del tráfico a green y poner blue en draining. Blue puede estar en draining durante 10 minutos sin coste adicional.

---

## Escenario 8

### Plataforma de trading: failover multi-región en menos de 30 segundos

Una empresa de trading algorítmico tiene su plataforma en AWS con servidores en **eu-west-1 (Irlanda)** como región primaria y **eu-central-1 (Frankfurt)** como región secundaria (warm standby). Los algoritmos de trading ejecutan órdenes en bolsas europeas — cada segundo de inoperatividad puede costar entre €50.000 y €200.000. El SLA contractual exige **RTO < 30 segundos** ante un fallo completo de la región primaria.

La arquitectura actual usa **Route 53 Failover Routing** con un record primario (eu-west-1) y un record secundario (eu-central-1). Los health checks de Route 53 comprueban el endpoint HTTP cada 30 segundos con TTL de 60 segundos en los DNS records. En un simulacro de DR reciente, el equipo midió el tiempo real de failover: los health checks de Route 53 tardaron 30 s en detectar el fallo, y los DNS resolvers tardaron hasta 90 s adicionales en refrescar el caché (TTL era 60 s + tiempo de propagación). El failover real fue de **2–3 minutos** — muy por encima del SLA de 30 s.

El equipo quiere mantener la región secundaria como warm standby (activa, lista para recibir tráfico, pero sin procesar órdenes hasta que sea promovida). El sistema de órdenes requiere conexión TCP persistente desde los algoritmos clientes.

**Requisitos técnicos**
- RTO < 30 segundos ante fallo de eu-west-1 (medido desde el fallo hasta que eu-central-1 procesa órdenes)
- Conexiones TCP persistentes desde clientes (algoritmos de trading)
- Warm standby en eu-central-1 (instancias corriendo, sin tráfico de producción)
- Sin cambios en los clientes (algoritmos de trading no pueden modificarse)
- El failover debe ser automático (sin intervención manual)

**Opciones**

**A)** Reducir el TTL de Route 53 a **10 segundos** antes del horario de mercado y aumentar la frecuencia de los health checks de Route 53 a cada 10 segundos. Con TTL de 10 s, los resolvers refrescan más frecuentemente. El failover efectivo debería completarse en 20–30 s (10 s de health check + 10 s de TTL).

**B)** Reemplazar Route 53 Failover por **AWS Global Accelerator**. Global Accelerator usa una IP anycast estática que no cambia — los clientes se conectan siempre a la misma IP. El tráfico entra por el edge location más cercano y se enruta por la red backbone de AWS. Los health checks de Global Accelerator detectan fallos en **< 30 segundos** y redirigen el tráfico al endpoint secundario **sin necesidad de propagación DNS** — el cambio es inmediato a nivel de red.

**C)** Implementar un **Application Load Balancer cross-region** usando **AWS Global Accelerator** con dos endpoint groups (eu-west-1 y eu-central-1). Configurar pesos: eu-west-1 con peso 100 y eu-central-1 con peso 0. En caso de fallo, cambiar los pesos via API en < 5 s.

**D)** Mantener Route 53 pero añadir un **Lambda@Edge** que intercepte las queries DNS y devuelva el endpoint secundario cuando detecte que el primario está caído. Lambda@Edge ejecuta en < 5 ms en los edge locations de CloudFront, permitiendo failover casi instantáneo.

---

## Escenario 9

### Retailer online: factura de AWS inesperadamente alta en arquitectura Multi-AZ

Un retailer online desplegó hace 3 meses una arquitectura Multi-AZ "de libro": ALB en dos subnets públicas, ASG con instancias EC2 en dos subnets privadas (eu-west-1a y eu-west-1b), RDS Aurora MySQL Multi-AZ con writer en eu-west-1a y reader en eu-west-1b, ElastiCache Redis Multi-AZ, y NAT Gateway en eu-west-1a para que las instancias privadas salgan a internet. La arquitectura funciona perfectamente — pero la factura de AWS del primer mes completo fue **€4.800 más alta** de lo presupuestado.

El análisis de Cost Explorer muestra que los tres conceptos más caros son: (1) **EC2 - Other** (€1.200) — que incluye transferencia de datos entre AZs, (2) **NAT Gateway** (€1.800) — procesamiento de datos, y (3) el NAT Gateway tiene el 80% del tráfico generado por descargas de paquetes de actualización de sistema operativo y dependencias en las instancias EC2. El equipo tiene un pipeline CI/CD que actualiza las instancias diariamente descargando ~15 GB de paquetes desde los repositorios de Amazon Linux y pip.

**Requisitos técnicos**
- Mantener la arquitectura Multi-AZ (no se puede degradar a single-AZ)
- Reducir la factura en al menos €3.000/mes
- Sin impacto en la funcionalidad de la aplicación
- Las actualizaciones de sistema operativo y dependencias deben seguir funcionando

**Opciones**

**A)** Añadir un segundo NAT Gateway en eu-west-1b para que las instancias de esa AZ no tengan que cruzar AZ para salir a internet. Esto reduce el cross-AZ traffic charge (€1.200). El tráfico NAT se distribuye entre los dos NAT Gateways, reduciendo el coste unitario.

**B)** Para el cross-AZ traffic entre EC2 y RDS: modificar la aplicación para que siempre conecte al endpoint del writer (que está en eu-west-1a) desde instancias en eu-west-1a, y al endpoint del reader desde instancias en eu-west-1b. Para el tráfico NAT Gateway: crear un **repositorio de paquetes interno** usando AWS CodeArtifact o S3 + VPC Gateway Endpoint, y configurar las instancias para que descarguen paquetes desde ahí en lugar de desde internet.

**C)** Mover todas las instancias del ASG a una sola AZ (eu-west-1a) para eliminar el cross-AZ traffic. Usar solo eu-west-1a también para ElastiCache y conectar siempre al writer de Aurora (eu-west-1a). Esto elimina el cruce de AZ pero mantiene Multi-AZ en los servicios gestionados.

**D)** Desactivar el NAT Gateway y usar **VPC Interface Endpoints** para todos los servicios AWS que usan las EC2 (S3, ECR, CloudWatch, SSM). Los Interface Endpoints eliminan la necesidad de NAT para servicios AWS, y para el acceso a repositorios externos (pip, yum), configurar las actualizaciones para que se ejecuten durante la construcción de la AMI (bake into AMI) en lugar de en tiempo de ejecución.

---

## Escenario 10

### Empresa enterprise: arquitectura stateless con acceso seguro y sin bastion

Una empresa enterprise con 500 desarrolladores gestiona una aplicación web crítica en AWS: un ASG con 20 instancias `m5.2xlarge` en subnets privadas detrás de un ALB. Las sesiones de usuario se almacenan actualmente en la memoria local de cada EC2. Hay un bastion host en una subnet pública al que los desarrolladores acceden vía SSH para depurar problemas en producción. El equipo de seguridad ha emitido dos hallazgos: (1) el almacenamiento de sesión en memoria local rompe la escalabilidad horizontal y produce sesiones perdidas durante scale-in; (2) el bastion host con SSH abierto a `0.0.0.0/0` es el vector de ataque más común en el sector.

El CTO quiere que la arquitectura sea completamente **stateless** (cualquier instancia puede atender cualquier request) y que el acceso administrativo sea **sin SSH keys y completamente auditado** en AWS CloudTrail. Adicionalmente, el equipo de operaciones necesita poder ejecutar comandos en múltiples instancias simultáneamente (e.g., "reiniciar el proceso de aplicación en todas las instancias").

**Requisitos técnicos**
- Sesiones de usuario no deben perderse durante scale-in del ASG
- Acceso administrativo auditado, sin gestión de SSH keys, sin bastion host
- Capacidad de ejecutar comandos en múltiples instancias simultáneamente
- TTL de sesión de 4 horas con sliding expiration
- Las instancias no deben tener puertos de administración abiertos hacia internet (ni SSH ni RDP)
- Las sesiones deben sobrevivir el fallo/reinicio de una instancia EC2

**Opciones**

**A)** Implementar **sticky sessions persistentes** en el ALB (cookie `AWSALB` con duración de 4 horas). Esto garantiza que cada usuario siempre va a la misma instancia, por lo que la sesión en memoria local siempre está disponible. Para el acceso administrativo, sustituir el bastion por **EC2 Instance Connect** que genera credenciales SSH temporales sin gestión de keys permanentes.

**B)** Externalizar las sesiones a **ElastiCache Redis** (Replication Group Multi-AZ): `SETEX session:<id> 14400 <data>` con renovación del TTL en cada request (sliding expiration). Eliminar las sticky sessions del ALB. Reemplazar el bastion host por **AWS Systems Manager Session Manager** (agente SSM en cada EC2, acceso via consola o `aws ssm start-session`, auditoría completa en CloudTrail). Para comandos en múltiples instancias, usar **SSM Run Command** con target por tag.

**C)** Migrar las sesiones a **Amazon DynamoDB** con TTL habilitado (atributo `expire_at`). Crear una tabla `sessions` con `session_id` como PK. Para el acceso administrativo, crear una VPN Site-to-Site entre la red corporativa y la VPC — los desarrolladores aceden via VPN y luego SSH a las IPs privadas de las instancias. El SG de EC2 permite SSH solo desde el rango CIDR de la VPN.

**D)** Reemplazar el ASG con un cluster **Amazon ECS** en instancias EC2. Los contenedores son inherentemente stateless por diseño. Para las sesiones, ECS puede usar volúmenes EFS compartidos entre contenedores. Para el acceso administrativo, usar **ECS Exec** que permite ejecutar comandos en contenedores sin SSH.

---
