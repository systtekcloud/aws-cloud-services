# Compute EC2 — Respuestas SAA-C03

> Respuestas a: [compute-scenarios-sa-associate.md](./compute-scenarios-sa-associate.md)
> **No abrir hasta haber respondido cada escenario.**

---

## Escenario 1 — Plataforma de pagos: TLS pass-through y IP fuente

**Respuesta correcta: B**

Este escenario pivota sobre dos limitaciones técnicas del ALB que el examen prueba con frecuencia:

**ALB no puede hacer TLS pass-through.** El ALB opera en capa 7 (HTTP/HTTPS) y **siempre termina TLS** en el listener. No existe modo "pass-through" en ALB — cuando el listener es HTTPS, el ALB descifra el tráfico, inspecciona los headers HTTP y luego abre una nueva conexión (cifrada o no) hacia el backend. El requisito de PCI-DSS de que el dato de tarjeta no viaje en claro en ningún segmento de la red hace que el ALB sea **incompatible con este requisito** independientemente de la configuración del target group.

**NLB con listener TCP en puerto 443** actúa como pass-through puro: recibe bytes TCP en el puerto 443 y los reenvía al backend sin inspeccionar ni modificar el contenido. El backend establece el TLS directamente con el cliente. El NLB nunca ve el contenido del certificado ni los datos cifrados.

**Proxy Protocol v2** es el mecanismo estándar para que un load balancer de capa 4 comunique al backend los metadatos de la conexión original (IP fuente, puerto fuente, familia de protocolo) sin modificar el payload TCP. El backend recibe un pequeño header prepended al inicio de la conexión TCP con esta información — sin Proxy Protocol, el backend solo vería la IP del NLB.

**Por qué cada incorrecta falla en producción**

**A — ALB con target HTTPS:** Esta opción mejora parcialmente la situación: el tramo ALB→Backend es ahora cifrado con una segunda sesión TLS. Pero **el ALB sigue terminando el TLS del cliente** — descifra el tráfico en el ALB, lo reinspecta, y abre una nueva sesión TLS hacia el backend. Hay un punto donde los datos están descifrados dentro del proceso del ALB. Además, `X-Forwarded-For` funciona bien para pasar la IP del cliente, pero el auditor PCI puede objetar que el dato de tarjeta "pasa por" el proceso del ALB en texto claro en memoria. No es TLS extremo a extremo criptográficamente — son dos sesiones TLS distintas.

**C — ALB + WAF:** WAF opera sobre el tráfico HTTP que el ALB ya ha descifrado. Si el problema es que el ALB no debe ver el contenido descifrado, añadir WAF (que también ve el contenido) no resuelve nada. Esta opción confunde "seguridad adicional" con "cumplir el requisito específico". El hallazgo del auditor es sobre el tramo ALB→EC2 en texto plano, no sobre la falta de WAF.

**D — Classic Load Balancer TCP:** El CLB en modo TCP también puede hacer pass-through (como el NLB), pero hay un problema fundamental: **el CLB está deprecated** — AWS no recomienda nuevas implementaciones y tiene limitaciones de rendimiento, AZ, y soporte de protocolos vs NLB. Específicamente para este caso, el CLB en modo TCP **no soporta Proxy Protocol v2** (solo v1, con limitaciones). Además, la opción menciona `X-Forwarded-For` que es un header HTTP — no existe en modo TCP puro del CLB.

**Exam tip**

> **NLB = capa 4, TCP pass-through, preserva IP fuente con Proxy Protocol.** **ALB = capa 7, siempre termina TLS.** Cuando el escenario menciona "TLS extremo a extremo", "compliance requiere cifrado hasta el backend", o "TLS pass-through", la respuesta es NLB. Si el escenario menciona "IP real del cliente en load balancer capa 4", la solución es Proxy Protocol (no `X-Forwarded-For`, que es HTTP).

---

## Escenario 2 — Route 53 weighted vs failover: TTL y DNS caching

**Respuesta correcta: A**

El problema tiene dos partes que deben resolverse independientemente:

**El problema del DNS caching durante el switch:** Route 53 sirve el DNS record con el TTL configurado. Cuando los resolvers tienen el record en caché, ignoran cualquier cambio en Route 53 hasta que el TTL expira. Con TTL = 300 s, los resolvers pueden servir el record antiguo durante hasta 5 minutos. Los clientes con DNS corporativo (que suelen hacer caching más agresivo) pueden retener el record hasta 30+ minutos.

La solución estándar es **reducir el TTL con antelación**: reducir a 10–30 s **antes** del switch, esperar un tiempo equivalente al TTL antiguo (300 s) para que todos los resolvers refresquen, y luego hacer el switch. Con TTL = 10 s, el cambio efectivo ocurre en < 10 s después del switch. Esta es la práctica recomendada para migraciones DNS de baja interrupción.

**El problema del failover automático con Weighted Routing:** Route 53 Weighted Routing **no tiene failover automático por sí solo** — si el endpoint v2 está caído pero el peso es 100, Route 53 sigue enviando tráfico allí. La solución es asociar **health checks de Route 53** a los records weighted. Cuando un record weighted tiene un health check asociado y el check falla, Route 53 excluye ese record del pool de respuestas y redistribuye el peso entre los records healthy restantes.

La opción A es la única que combina correctamente ambas soluciones.

**Por qué cada incorrecta falla en producción**

**B — Migrar a Failover Routing:** Route 53 Failover solo tiene dos estados: Primary o Secondary. No permite distribución gradual de tráfico (10%/90%, 50%/50%). Si la empresa quiere gradualidad, necesita Weighted. Además, "usar las listener rules del ALB para gradualidad" implica que el 100% del tráfico DNS va al mismo ALB, y las listener rules dentro del ALB dividen — pero eso solo funciona si los dos ALBs (v1 y v2) están detrás del mismo DNS, lo cual no es la arquitectura descrita. Esta opción resuelve el failover pero sacrifica la migración gradual.

**C — Mantener TTL de 300 s y documentarlo:** Esta opción acepta el comportamiento observado como correcto, pero ignora que la empresa tiene un objetivo de failover < 60 s para el próximo punto. Un TTL de 300 s hace imposible ese objetivo. Además, los "30+ minutos de clientes corporativos" son indicativos de DNS resolvers con caching agresivo — un TTL corto los obliga a refrescar más frecuentemente. La documentación no resuelve el problema técnico.

**D — Route 53 Latency Routing:** Latency Routing elige el endpoint con menor latencia de red observada desde el resolver al endpoint — **no es una forma de hacer A/B testing o distribución gradual de tráfico**. Si ambos endpoints están en la misma región (mismo ALB o misma AZ), Latency Routing no tiene criterio de diferenciación real y el resultado es impredecible. Esta opción demuestra confundir "latency" (latencia de red al endpoint) con "rendimiento de la aplicación".

**Exam tip**

> **TTL del DNS record ≠ TTL de expiración de la caché del resolver.** El record se propaga en Route 53 en segundos, pero los resolvers sirven el valor cacheado hasta que el TTL expira. Para switches limpios: bajar el TTL con antelación, esperar TTL_antiguo segundos, hacer el switch. Para failover automático con Weighted: añadir health checks al record. Sin health check, Weighted no elimina endpoints caídos.

---

## Escenario 3 — E-commerce global: CloudFront vs Global Accelerator

**Respuesta correcta: C**

Este es el escenario más importante del examen para distinguir cuándo usar cada servicio:

**CloudFront** es un CDN (Content Delivery Network). Su valor principal es el **caché de contenido en edge locations**. Para contenido no cacheable (cache hit rate < 5%), CloudFront no proporciona ventaja de latencia significativa porque cada request tiene que hacer el viaje completo hasta el origen de todas formas. La red backbone de AWS entre edge y origin es la misma que usa Global Accelerator — la diferencia es que CloudFront introduce overhead de HTTP adicional para el "miscarriage" del caché.

**AWS Global Accelerator** no cachea nada. Su función es enrutar el tráfico desde el edge location más cercano al usuario hasta el endpoint de destino **a través de la red privada backbone de AWS** (en lugar del internet público). Esto elimina múltiples hops de internet público, reduce la latencia en 30–60% para tráfico transcontinental, y proporciona **BGP anycast** — los clientes se conectan siempre a la misma IP estática independientemente de su ubicación. Los health checks de Global Accelerator pueden monitorizar la latencia (no solo disponibilidad), disparando failover cuando la latencia supera un umbral.

Para tráfico dinámico no cacheable (API de búsqueda personalizada), **Global Accelerator es la elección correcta**. La latencia de 380–520 ms se reduce a ~150–200 ms simplemente al evitar los hops de internet público transcontinental. El coste es ~$0.010/GB de datos transferidos + $0.025/hora por acelerador — dentro del presupuesto indicado.

**Por qué cada incorrecta falla en producción**

**A — CloudFront con TTL=0:** Con TTL=0, CloudFront nunca cachea — cada request va al origen. CloudFront con TTL=0 para tráfico dinámico es simplemente un proxy HTTP con overhead adicional. La red backbone de AWS entre edge y origin existe, pero CloudFront no está optimizado para TCP acelerado de la misma forma que Global Accelerator. El resultado práctico es similar o ligeramente peor que sin CloudFront (overhead de headers adicionales, procesamiento en edge). Esta opción es el "distractor perfecto" del examen — parece inteligente pero ignora la diferencia fundamental entre un CDN y un acelerador de red.

**B — Desplegar en múltiples regiones:** Resuelve el problema de latencia correctamente (instancias en Tokio → < 50 ms para Asia), pero incumple explícitamente el requisito "sin redeploy de la aplicación en múltiples regiones" y "seguir con eu-west-1 como único backend". Además, implica sincronización de bases de datos entre regiones, lo cual es un proyecto de meses, no semanas.

**D — API Gateway Edge-Optimized con caché:** API Gateway Edge-Optimized también usa CloudFront como distribución. Con < 5% de cache hit rate y TTL de 60 s, el caché de API Gateway apenas ayuda. El caching de API Gateway por `user_id` implica millones de claves de caché distintas con baja reutilización. El coste de API Gateway por millones de requests/día es también significativamente mayor que Global Accelerator.

**Exam tip**

> **CloudFront = caché + CDN** (contenido estático, HTML, assets, respuestas repetibles). **Global Accelerator = TCP/UDP acceleration + anycast IP** (API dinámicas, conexiones TCP persistentes, failover sin DNS). Si el escenario dice "API no cacheable", "contenido dinámico y personalizado", o "cache hit rate bajo", Global Accelerator gana siempre. Si dice "distribución global de imágenes/vídeo/JS", CloudFront.

---

## Escenario 4 — Plataforma de streaming: instancias unhealthy desde el inicio

**Respuesta correcta: B**

El diagnóstico en este escenario es una cadena de causa-efecto que el equipo no ha trazado correctamente. Los datos del enunciado son suficientes para identificar la causa raíz sin ambigüedad:

**Evidencia clave:** El cambio de ayer modificó el SG de las EC2 para aceptar inbound del ALB en el **puerto 80**. La aplicación escucha en el **puerto 8080**. El health check usa `traffic-port`, que resuelve al puerto configurado en el target group registration — que es **8080**.

**Flujo de fallo:**
1. ALB intenta conectar al puerto 8080 de la EC2 (para el health check)
2. El SG de la EC2 solo permite inbound en el puerto 80 desde el SG del ALB
3. La conexión TCP al puerto 8080 es rechazada por el SG → timeout
4. ALB marca la instancia como unhealthy tras 2 checks fallidos (30 s)
5. ASG recibe la notificación de unhealthy → termina la instancia → lanza nueva → ciclo

El fix es añadir una regla inbound en el SG de las EC2 que permita el tráfico del SG del ALB en el **puerto 8080** (o cambiar el puerto de la regla existente de 80 a 8080). El cambio es instantáneo — no requiere reemplazar instancias ni modificar el ASG.

**Por qué cada incorrecta falla en producción**

**A — Cambiar el health check path a `/`:** El path del health check (`/healthz`) puede ser correcto o incorrecto — el enunciado no dice que la ruta haya cambiado. Incluso si `/healthz` no existiera y devolviera 404, **el ALB nunca llegaría a recibir respuesta** porque la conexión TCP al puerto 8080 ya está siendo bloqueada por el SG. Cambiar el path no resuelve el bloqueo de SG. En producción, si se implementa esta opción, el comportamiento será idéntico al actual.

**C — Grace Period del ASG a 120 s:** El Grace Period es el tiempo que el ASG espera **después del EC2 health check** (no del ALB health check) antes de evaluar el health check del ASG. Aumentar el Grace Period daría más tiempo antes de que el ASG termine instancias, pero **el ALB seguiría marcando las instancias como unhealthy** porque el SG sigue bloqueando el puerto 8080. Con Grace Period de 120 s, el ciclo simplemente sería más lento (instancias sobreviven 2 minutos en lugar de 30 s antes de ser terminadas), pero el resultado es el mismo.

**D — Subnets sin NAT Gateway:** El enunciado confirma que `user_data` se ejecuta correctamente (el log `cloud-init-output.log` lo muestra) y que el proceso arranca en el puerto 8080 (`ss -tlnp` lo confirma). La aplicación está funcionando. El problema no es de conectividad de salida (que necesitaría NAT) sino de conectividad de entrada desde el ALB. Mover a subnets públicas sería un cambio de arquitectura innecesario y peligroso.

**Exam tip**

> Para troubleshooting de instancias unhealthy, trazar la cadena: **¿EC2 está Running? → ¿User data completó? → ¿Proceso escucha en el puerto correcto? → ¿SG permite al ALB llegar a ese puerto?** En el examen, cuando un "cambio reciente" precede al problema, el cambio es siempre la causa. El dato de que el SG fue modificado "ayer" y solo permite puerto 80 mientras la app usa 8080 es la señal.

---

## Escenario 5 — Sistema de historiales clínicos: arquitectura 3-tier HIPAA

**Respuesta correcta: A**

La opción A es la única que cumple **todos** los requisitos simultáneamente:

**Subnets privadas para EC2:** Las instancias de aplicación pasan a subnets privadas sin IP pública ni ruta directa a internet. El único punto de entrada pública es el ALB, que filtra el tráfico antes de llegar a las instancias.

**ALB con SG restrictivo:** El ALB tiene un Security Group que acepta HTTPS solo desde el rango CIDR de la VPN corporativa. Esto implementa el requisito de "solo acceso desde VPN o intranet" a nivel de SG (no NACL), que es la forma recomendada y con estado.

**SSM Session Manager en lugar de SSH:** SSM Session Manager es la solución correcta para acceso administrativo en entornos de alta seguridad:
- No requiere abrir ningún puerto (ni 22 ni ningún otro) en los SGs de las EC2
- No requiere gestión de claves SSH (ni distribución, ni rotación, ni revocación)
- Toda sesión queda registrada en AWS CloudTrail y opcionalmente en S3/CloudWatch Logs
- Se controla mediante políticas IAM — acceso granular por usuario, rol o tag de instancia
- Funciona completamente a través de la red privada de AWS via el endpoint SSM (que puede ser un Interface Endpoint para máxima seguridad)

**Por qué cada incorrecta falla en producción**

**B — Subnets públicas sin IP pública + EC2 Instance Connect:** La definición de subnet pública es que su Route Table tiene una ruta a un Internet Gateway — independientemente de si las instancias tienen IP pública o no. Una instancia sin IP pública en subnet pública sigue siendo un hallazgo de compliance (el auditor considera el riesgo de que accidentalmente se le asigne una IP pública). Además, EC2 Instance Connect genera credenciales SSH temporales, pero **sigue usando SSH** — requiere que el puerto 22 esté abierto en el SG de la EC2, que es exactamente uno de los hallazgos de la auditoría.

**C — Bastion host en subnet pública:** El bastion host es una mejora respecto al SSH directo, pero sigue introduciendo un servidor SSH expuesto a internet (aunque solo desde VPN). El auditor HIPAA identificó la gestión de SSH keys como riesgo — un bastion host sigue requiriendo gestión de keys para el administrador. Además, el acceso en dos saltos (VPN → bastion → instancia privada) añade complejidad operativa. SSM Session Manager elimina toda esta superficie de ataque.

**D — AWS Network Firewall como capa perimetral:** Network Firewall es una herramienta de inspección de tráfico de red (IPS/IDS). Puede bloquear escaneos de puertos y tráfico malicioso, pero **no resuelve los hallazgos fundamentales**: las instancias siguen en subnets públicas con IPs públicas, y el SSH sigue existiendo. El auditor marcará "las instancias tienen IP pública" y "SSH con keys gestionadas manualmente" como hallazgos, independientemente de cuántas capas de firewall haya delante.

**Exam tip**

> Para **HIPAA/PCI-DSS** + "sin SSH keys" + "sin bastion" → la respuesta es siempre **SSM Session Manager** (agente SSM + IAM + sin puertos abiertos). Para "sin acceso directo desde internet" → instancias en **subnets privadas** (no públicas sin IP — eso no es suficiente). La clave de la opción incorrecta B es "subnet pública sin IP pública" — parece lo mismo que privada, pero no lo es.

---

## Escenario 6 — Optimización de costes: Spot, On-Demand y Savings Plans

**Respuesta correcta: B**

La solución óptima combina tres mecanismos de pricing para tres perfiles de carga distintos:

**Compute Savings Plan para la baseline continua:** Los Compute Savings Plans (1 o 3 años) ofrecen hasta 66% de descuento sobre On-Demand y son **más flexibles que las Reserved Instances**: aplican automáticamente a cualquier familia de instancia, tamaño, región, OS y tenancy. No hay necesidad de especificar el tipo de instancia al comprar. Para las 6 instancias web (`m5.xlarge`) que corren 24/7, un Savings Plan de 1 año cubre el 100% de ese gasto con ~30–40% de descuento. Para las 10 instancias base de procesamiento (`r5.4xlarge` x 12h/día), el Savings Plan también aplica durante las horas que corren.

**Spot para los picos de procesamiento:** El tier de procesamiento está explícitamente diseñado para reiniciar desde checkpoints, lo que lo hace ideal para Spot. Las instancias Spot ofrecen hasta 90% de descuento sobre On-Demand. Un ASG con `MixedInstancesPolicy` configurado con múltiples familias de instancias (`r5.4xlarge`, `r5a.4xlarge`, `r4.4xlarge`) y múltiples AZs minimiza la probabilidad de interrupción simultánea de toda la flota.

**Por qué cada incorrecta falla en producción**

**A — Reserved Instances de 1 año:** Las RIs son válidas pero **menos flexibles que los Savings Plans**. Con RIs, el descuento solo aplica al tipo de instancia específico comprado (e.g., `m5.xlarge` en eu-west-1). Si el equipo decide migrar a `m6i.xlarge` o `m5.2xlarge` (con ASG) o cambiar de región, las RIs del tipo antiguo no cubren el nuevo tipo — se pagan sin uso. Los Savings Plans cubren automáticamente cualquier cambio de tipo. Para el requisito de "máxima flexibilidad para cambiar tipos en el futuro", Savings Plans son superiores. El coste de descuento es similar (30–40%).

**C — Auto Scaling agresivo para las horas de baja demanda:** Apagar instancias web de 02:00 a 08:00 (6 horas, 25% del día) ahorra un 25% — muy lejos del objetivo de 40%. Además, el SLA de 99,9% del tier web no permite apagarlas durante horas de baja actividad (siempre habrá usuarios en distintas zonas horarias o procesos automáticos). El Auto Scaling agresivo introduce riesgo de capacidad insuficiente al escalar hacia arriba.

**D — Spot para el tier web:** El SLA de 99,9% es incompatible con Spot en el tier web. Spot puede interrumpirse con 2 minutos de aviso — incluso con múltiples tipos de instancia, es posible que múltiples instancias sean interrumpidas simultáneamente durante escasez de capacidad. Un evento de escasez regional de Spot puede comprometer el SLA. Para cargas que "siempre deben estar disponibles", Spot no es apropiado como componente único.

**Exam tip**

> **Savings Plans > Reserved Instances en flexibilidad.** Compute Savings Plans aplican a cualquier familia, región y OS — son el mecanismo de commitment más flexible. Usar para baseline predecible de larga duración. **Spot** = hasta 90% de descuento, solo para cargas tolerantes a interrupción con mecanismo de checkpointing. **On-Demand** = sin compromiso, para picos impredecibles que no tolera Spot.

---

## Escenario 7 — Deregistration delay: 502 durante deployments

**Respuesta correcta: C**

Este escenario requiere entender el ciclo completo de terminación de una instancia en un ASG con ALB:

**El ciclo de terminación:**
1. ASG decide terminar una instancia (deployment o scale-in)
2. ASG pone la instancia en estado `Terminating:Wait` (si hay Lifecycle Hook) o directamente en `Terminating`
3. ALB recibe notificación → pone el target en `draining` (deregistering)
4. ALB deja de enviar **nuevas** conexiones a ese target
5. ALB espera el `Deregistration Delay` (300 s por defecto) o hasta que todas las conexiones activas cierren
6. ALB marca el target como `deregistered`
7. ASG recibe notificación de deregistration completo → envía SIGTERM al proceso de EC2 → espera 30 s → envía SIGKILL → termina la instancia

**El problema real:** La aplicación no implementa graceful shutdown. Cuando el proceso recibe SIGTERM (paso 7), termina inmediatamente matando las peticiones en curso — incluso si el Deregistration Delay de 300 s aún no ha expirado. El delay del ALB protege contra **nuevas conexiones entrantes**, pero no puede proteger contra la terminación abrupta del proceso backend.

**La solución de la opción C:** El Lifecycle Hook intercepta entre el paso 1 y el inicio de la terminación real, añadiendo 120 s adicionales de `wait` donde la instancia está en `Terminating:Wait`. Durante este tiempo, la instancia sigue corriendo el proceso. El ALB ya ha completado su draining (Deregistration Delay de 110 s), así que no llegan nuevas peticiones. Las peticiones en curso (máximo 90 s) tienen tiempo de finalizar antes de que el Lifecycle Hook libere la instancia para terminación.

**Por qué cada incorrecta falla en producción**

**A — Habilitar cross-zone load balancing:** Cross-zone load balancing distribuye las peticiones uniformemente entre instancias de todas las AZs (en lugar de solo la AZ local). Es útil cuando las AZs tienen distinto número de instancias. Pero el problema descrito es de peticiones en vuelo siendo cortadas durante la terminación de instancias — cross-zone no tiene ningún efecto sobre el comportamiento de draining ni sobre el graceful shutdown de la aplicación.

**B — Reducir intervalo de health check:** Reducir el intervalo mejora el tiempo de detección de instancias healthy nuevas (de 90 s a 20 s), lo cual acelera el deployment. Pero no resuelve el problema de las peticiones cortadas durante la terminación. Las instancias antiguas siguen siendo terminadas abruptamente cuando el proceso recibe SIGTERM — las peticiones en curso de 85 s siguen siendo cortadas.

**D — Blue/Green con dos ASGs:** Blue/Green es una estrategia válida y elimina el problema de forma diferente (el ASG-blue completa su draining antes de ser terminado). Sin embargo, el enunciado especifica "sin cambios en el código de la aplicación" y pide "coste de implementación mínimo". Mantener dos ASGs paralelos duplica la infraestructura durante el deployment. La opción C (Deregistration Delay + Lifecycle Hook) resuelve el problema con cero cambios de infraestructura adicionales.

**Exam tip**

> **Deregistration Delay** = tiempo que el ALB espera para drenar conexiones antes de desregistrar el target. **No** protege contra la terminación del proceso EC2. Para peticiones de larga duración, combinar: (1) Deregistration Delay ≥ duración máxima de petición, (2) Lifecycle Hook para retrasar el SIGTERM hasta que el draining complete. El orden: ALB drains → delay expira → ASG envía SIGTERM → proceso muere.

---

## Escenario 8 — Trading: failover multi-región < 30 segundos

**Respuesta correcta: B**

El análisis del simulacro de DR revela el problema fundamental con Route 53 Failover para RTO < 30 s: **la propagación DNS introduce una latencia mínima de TTL + tiempo de detección** que en la práctica nunca es inferior a 60–90 s en condiciones reales.

**Por qué Route 53 Failover no puede cumplir 30 s:**
- Health check interval: 30 s (mínimo con Route 53 Standard)
- Fast health check: 10 s (disponible, pero con coste adicional)
- El resolver del cliente puede tener el record en caché hasta TTL segundos adicionales
- Incluso con TTL = 1 s, la propagación entre todos los resolvers tarda de 30 a 120 s en la práctica

**AWS Global Accelerator resuelve este problema a nivel de red, no a nivel de DNS:**

Las IPs de Global Accelerator son **static anycast IPs** — los clientes se conectan siempre a la misma IP (e.g., `1.2.3.4`). No hay resolución DNS involucrada en el failover. Cuando Global Accelerator detecta que eu-west-1 está caído (health check cada 30 s), redirige el tráfico a eu-central-1 **cambiando el routing en la red de AWS** — sin cambiar ningún registro DNS, sin propagación, sin TTL. Los clientes que ya tienen conexiones establecidas son redirigidos en el siguiente intento de conexión TCP (que ocurre en segundos si la conexión cae). El failover completo ocurre en **< 30 segundos**.

Para conexiones TCP persistentes (algoritmos de trading): Global Accelerator con listener TCP mantiene las conexiones en la red backbone de AWS. Si el endpoint primario falla, las conexiones existentes caen (como caerían con cualquier fallo de región), pero los clientes que reintentan son enrutados al endpoint secundario en < 30 s.

**Por qué cada incorrecta falla en producción**

**A — Route 53 TTL = 10 s + health check cada 10 s:** Con health check de 10 s y TTL de 10 s, el tiempo mínimo teórico es 20 s. En la práctica: algunos resolvers corporativos ignorarán el TTL corto (muchos firewalls DNS cachean con un TTL mínimo de 60 s por política interna). El simulacro ya demostró 2–3 minutos con TTL de 60 s y checks cada 30 s — reducir a 10 s mejora el tiempo teórico pero no garantiza < 30 s en entornos DNS corporativos reales, que es exactamente el entorno del cliente (algoritmos en infraestructura del banco).

**C — "ALB cross-region" con Global Accelerator y pesos 100/0:** Un ALB no es un servicio cross-region — un ALB existe en una región específica. Global Accelerator con endpoint groups sí puede tener endpoints en múltiples regiones. Pero la descripción de "cambiar pesos via API en < 5 s" implica una operación manual o automatizada — no es failover automático. Además, cambiar pesos en Global Accelerator requiere una llamada API que puede tardar 30–60 s en propagarse globalmente. Esta opción confunde el mecanismo de pesos de Global Accelerator con el failover automático por health check.

**D — Lambda@Edge con CloudFront para DNS:** Lambda@Edge ejecuta durante la resolución de peticiones HTTP de CloudFront — no interviene en la resolución DNS. Esta opción demuestra confusión entre el plano DNS y el plano HTTP. Además, CloudFront es un CDN diseñado para HTTP/HTTPS — no es adecuado para conexiones TCP arbitrarias de algoritmos de trading. La solución propuesta es técnicamente imposible.

**Exam tip**

> **Route 53 Failover ≠ RTO < 30 s.** Route 53 introduce siempre el TTL de propagación DNS. Para **RTO < 30 s sin cambio DNS**, la respuesta es **Global Accelerator**: IPs anycast estáticas, failover en red backbone sin DNS. Palabras clave del examen: "conexiones TCP persistentes", "RTO < 60 s multi-región", "sin cambio de IP en clientes", "failover sin DNS" → Global Accelerator.

---

## Escenario 9 — Cross-AZ traffic costs: factura inesperada en Multi-AZ

**Respuesta correcta: D**

La factura tiene dos problemas independientes que deben resolverse de forma diferente:

**Problema 1 — Cross-AZ traffic (€1.200):** Cada vez que una instancia EC2 en eu-west-1a lee de RDS Aurora en eu-west-1b (o viceversa), AWS cobra **$0.01/GB** en ambas direcciones. Con una aplicación de alto volumen de datos, esto suma rápidamente. La solución: modificar la lógica de conexión para que instancias en eu-west-1a lean del writer (también en eu-west-1a) y lecturas en eu-west-1b usen el reader endpoint de Aurora en eu-west-1b. Sin embargo, esto es una optimización de aplicación compleja — no siempre es factible.

**Problema 2 — NAT Gateway (€1.800):** El 80% del tráfico NAT son descargas de paquetes desde repositorios de Amazon Linux y pip. NAT Gateway cobra **$0.045/GB de datos procesados** — a este precio, 15 GB/día × 30 días × 20 instancias = 9.000 GB × $0.045 = $405/mes solo en datos, más la tarifa horaria. La solución más eficiente es eliminar la necesidad de NAT para estos accesos:
- **Gateway Endpoint para S3** (gratuito): Los repositorios de Amazon Linux se sirven desde S3 — con el Gateway Endpoint, el tráfico va directo a S3 sin pasar por NAT Gateway, sin coste de transferencia.
- **VPC Endpoint para dependencias internas**: Si pip usa CodeArtifact o un repositorio interno en S3, el Gateway Endpoint también ayuda.
- **Bake into AMI**: Incluir todos los paquetes en la AMI base durante la construcción (CI/CD pipeline) elimina la descarga en tiempo de ejecución. Las instancias arrancan con todo instalado.

La opción D es la única que aborda el problema de NAT Gateway de forma estructural (€1.800/mes) y no crea nuevos problemas de disponibilidad.

**Por qué cada incorrecta falla en producción**

**A — Segundo NAT Gateway en eu-west-1b:** Añadir un NAT Gateway en la segunda AZ reduce el cross-AZ traffic de las instancias en eu-west-1b (que ahora no cruzan a eu-west-1a para salir). Esto salva €200–400/mes en cross-AZ. Pero **el coste principal es el NAT Gateway en sí** (€1.800 por procesamiento de datos de actualizaciones). Un segundo NAT Gateway no reduce el coste de datos procesados — lo divide entre dos NAT Gateways, manteniendo el coste total igual o incluso añadiendo el coste fijo de un segundo NAT Gateway ($32/mes + datos).

**B — Optimización de routing de DB + repositorio interno:** Esta opción aborda ambos problemas correctamente, pero la primera parte ("modificar la aplicación para conectar al writer desde eu-west-1a") requiere cambios de código de aplicación potencialmente complejos (awareness de AZ en la lógica de conexión). La opción D (bake AMI) resuelve el problema mayor (€1.800 de NAT) de forma más limpia y sin código de aplicación. En el contexto del examen, D es más directamente correcto para el impacto principal.

**C — Mover todo a una sola AZ:** Esto elimina el cross-AZ traffic (ahorrando €1.200/mes), pero viola el requisito explícito de "mantener la arquitectura Multi-AZ". Además, los servicios gestionados (Aurora, ElastiCache) siguen estando en múltiples AZs — el requisito de Multi-AZ es para la disponibilidad de la aplicación, no solo de los datos. Concentrar el tier de aplicación en una sola AZ elimina la HA ante fallos de AZ.

**Exam tip**

> **NAT Gateway** cobra por GB de datos procesados ($0.045/GB). Grandes descargadores (actualizaciones, pulls de Docker, backups) que van a través de NAT son los principales culpables de facturas altas. **Gateway Endpoint para S3** es gratuito y elimina el NAT para acceso a S3 y repositorios de Amazon Linux. Para actualizaciones frecuentes de SO: **bake into AMI** (instalar en CI/CD, no en runtime). **Cross-AZ traffic** = $0.01/GB por dirección — pensar en la topología de qué habla con qué en cada AZ.

---

## Escenario 10 — ASG + ElastiCache + stateless: arquitectura sin bastion

**Respuesta correcta: B**

La opción B resuelve todos los requisitos con las herramientas más directas y mejor integradas de AWS:

**ElastiCache Redis para sesiones:** `SETEX session:<id> 14400 <serialized_data>` almacena la sesión con TTL de 4 horas (14400 s). En cada request autenticado, `EXPIRE session:<id> 14400` renueva el TTL (sliding expiration). Con Replication Group Multi-AZ (Primary en eu-west-1a, Replica en eu-west-1b), si el Primary falla, la Replica se promueve en ~30 s — las sesiones persisten. Las instancias EC2 pueden ser escaladas, reemplazadas o terminadas sin perder ninguna sesión.

**SSM Session Manager para acceso administrativo:**
- **Sin puertos abiertos:** El agente SSM establece una conexión saliente HTTPS hacia el endpoint regional de SSM (o via Interface Endpoint). No requiere inbound en ningún SG.
- **Sin SSH keys:** La autenticación es IAM — permisos por `ssm:StartSession` en el rol del desarrollador.
- **Auditoría completa:** Cada sesión queda en CloudTrail con usuario IAM, hora de inicio/fin, y opcionalmente el contenido de los comandos en CloudWatch Logs / S3.
- **Run Command masivo:** `aws ssm send-command --targets Key=tag:Environment,Values=prod --document-name AWS-RunShellScript --parameters commands="systemctl restart app"` ejecuta en paralelo en todas las instancias con ese tag.

**Por qué cada incorrecta falla en producción**

**A — Sticky sessions + EC2 Instance Connect:** Sticky sessions restablecen la dependencia entre usuario e instancia — si la instancia es terminada por el ASG (scale-in), el usuario pierde su sesión. No resuelve el problema de statelessness. EC2 Instance Connect genera credenciales SSH temporales (15 minutos) pero sigue requiriendo que el **puerto 22 esté abierto** en el SG de la EC2 — exactamente el hallazgo de seguridad que se quiere eliminar. Además, EC2 Instance Connect no soporta "Run Command en múltiples instancias".

**C — DynamoDB + VPN + SSH:** DynamoDB es válido para sesiones pero con latencia 5–10x mayor que Redis (ms vs sub-ms). El TTL de DynamoDB no garantiza expiración puntual (puede retrasarse hasta 48 h). La VPN Site-to-Site resuelve el acceso seguro pero requiere gestión de SSH keys en los portátiles de los desarrolladores — mismo vector de riesgo que el bastion. Además, con 500 desarrolladores, la gestión de keys SSH es una pesadilla operativa. No existe "Run Command en múltiples instancias" vía SSH.

**D — Migrar a ECS con EFS para sesiones:** Migrar a ECS es un proyecto mayor que probablemente requiere semanas — incompatible con resolver un problema de seguridad urgente. Los volúmenes EFS para sesiones son latentes para accesos aleatorios (NFS sobre red) y mucho más caros que Redis para este patrón de acceso. ECS Exec resuelve el acceso administrativo correctamente, pero requiere la migración completa a ECS como prerrequisito. La opción introduce una solución global donde solo se necesita resolver dos problemas específicos.

**Exam tip**

> **SSM Session Manager** = sin SSH, sin bastion, sin keys, sin puertos abiertos. Requiere: (1) agente SSM instalado y corriendo, (2) IAM role en la EC2 con `AmazonSSMManagedInstanceCore`, (3) permisos IAM del usuario con `ssm:StartSession`. **SSM Run Command** = ejecución masiva por tag/grupo. Para sesiones stateless: siempre **ElastiCache Redis** (TTL exacto, sub-ms, Multi-AZ). La combinación SSM + Redis aparece frecuentemente en el examen para arquitecturas "de libro" de stateless + secure access.
