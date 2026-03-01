# VPC Networking — Respuestas SAA-C03

> Respuestas a: [vpc-scenarios-sa-associate.md](./vpc-scenarios-sa-associate.md)
> **No abrir hasta haber respondido cada escenario.**

---

## Escenario 1 — Procesamiento de pagos sin exposición a internet

**Respuesta correcta: C**

La única solución que elimina completamente cualquier ruta hacia internet es colocar los servidores en subnets aisladas (sin `0.0.0.0/0` en su route table) y usar VPC Endpoints para acceder a los servicios AWS directamente dentro de la red de Amazon:

- **Gateway Endpoint para S3**: enruta el tráfico via prefix list en la route table. Completamente gratuito. El tráfico nunca sale de la infraestructura de AWS.
- **Interface Endpoint para Secrets Manager**: crea una ENI privada dentro de la subnet. El DNS `secretsmanager.eu-west-1.amazonaws.com` resuelve a la IP privada de esa ENI.
- **Interface Endpoints para SSM** — los tres son necesarios para Session Manager: `ssm`, `ssmmessages`, `ec2messages`. Sin ellos, el agente SSM no puede contactar con la API.

El resultado: los servidores tienen IPs privadas, sus route tables solo contienen la ruta `local`, y todo el tráfico hacia AWS va por ENIs privadas dentro de la VPC. El auditor puede verificar con Flow Logs que no existe ningún flujo hacia IPs externas.

**Por qué cada incorrecta falla en producción**

**A:** Restringir el tráfico saliente a prefix lists de AWS en los Security Groups **no elimina la ruta a internet**. La route table sigue teniendo `0.0.0.0/0 → NAT GW → IGW`. El camino existe aunque no se use habitualmente. Un auditor de red puede demostrar que la ruta existe. Además, si el prefix list de AWS cambia (añaden IPs nuevas), el tráfico legítimo se bloquearía antes de actualizar el SG.

**B:** Las subnets públicas están definidas como subnets cuya route table tiene una ruta hacia un Internet Gateway. Aunque una instancia no tenga IP pública asignada, **la subnet en sí es pública** — es un hallazgo automático en cualquier escáner de compliance PCI-DSS. El IGW no "filtra" por presencia de IP pública; la ruta en la route table es lo que define la categoría.

**D:** Introducir una cuenta intermediaria no elimina la exposición — la desplaza un nivel. Los datos sensibles pasan por una cuenta adicional, aumentando la superficie de ataque y el coste de auditoría. AWS PrivateLink está diseñado para exponer servicios propios, no para crear proxies de servicios AWS gestionados.

**Exam tip**

> Cuando el enunciado dice **"sin ruta a internet"**, **"PCI-DSS"** o **"CDE"**: la respuesta implica siempre **subnets aisladas + VPC Endpoints**. Gateway Endpoint para S3/DynamoDB (gratuito), Interface Endpoint para el resto. Si hay SSM Session Manager, necesitas los tres endpoints: `ssm`, `ssmmessages`, `ec2messages`. La frase que descarta el NAT GW es *"aunque esté cifrado"* — el auditor rechaza la ruta, no solo el cifrado.

---

## Escenario 2 — Crecimiento multi-VPC: conectividad y aislamiento a escala

**Respuesta correcta: C**

Transit Gateway es el servicio diseñado para este problema. En lugar de O(n²) conexiones de peering, cada VPC se conecta **una sola vez** al TGW. Añadir una nueva VPC: (1) crear attachment, (2) asociar a la route table correcta, (3) actualizar la route table de la VPC.

El aislamiento Prod/Dev se implementa con TGW Route Tables:
```
TGW-RT-Prod:    rutas a Servicios-Compartidos, Seguridad (sin rutas a Dev)
TGW-RT-Dev:     rutas a Servicios-Compartidos, Seguridad (sin rutas a Prod)
TGW-RT-Shared:  rutas a todos (responde a peticiones de cualquier VPC)
```

El aislamiento es estructural — no requiere SGs ni NACLs adicionales entre tiers.

**Por qué cada incorrecta falla en producción**

**A:** VPC Peering es **no transitivo**. Si VPC-Prod-A tiene peering con Servicios Compartidos, y VPC-Prod-B también, VPC-Prod-A **no puede** alcanzar VPC-Prod-B a través de Servicios Compartidos. La VPC hub no puede reenviar tráfico entre sus spokes. Para que funcione el modelo hub-and-spoke con Peering, necesitarías peering directo entre cada par — volvemos a O(n²).

**B:** PrivateLink es correcto para exponer **servicios específicos** (una API, una base de datos) de forma privada. No resuelve el routing general entre VPCs. Requeriría un NLB y un endpoint por cada servicio que quieras exponer — con 20 VPCs y múltiples servicios, la complejidad operativa sería mayor que el problema actual.

**D:** La automatización con CloudFormation/Config puede reducir el tiempo operativo del peering, pero no resuelve el problema técnico de fondo: peering sigue siendo no transitivo y la restricción Prod/Dev requeriría NACLs o SGs específicas por subnet (frágil y difícil de auditar). El número de conexiones para 20 VPCs en full-mesh es 190 — inmanejable incluso con automatización.

**Exam tip**

> Palabras clave para Transit Gateway: **"múltiples VPCs"** (≥ 3-4), **"aislamiento entre grupos de VPCs"**, **"escala"**, **"hub-and-spoke"**. La trampa clásica es la opción con VPC Peering como hub — recuerda: **peering no es transitivo**. Si el enunciado dice "VPC-A no puede llegar a VPC-C a través de VPC-B", confirma la limitación del peering.

---

## Escenario 3 — Migración de EHR hospitalario: conectividad híbrida

**Respuesta correcta: C**

Es la solución que respeta los dos constraints críticos que entran en conflicto: el piloto en 6 semanas y los requisitos de producción.

**VPN para el piloto:** Una Site-to-Site VPN IPSec se provisiona en horas. El cifrado AES-256 cumple HIPAA. El piloto tiene menor volumen de datos y la latencia variable de internet es aceptable para validación técnica.

**Direct Connect para producción:** DX ofrece latencia predecible (SLA garantizado), ancho de banda dedicado no compartido, y la posibilidad de contratar 200 Mbps reservados. El proceso de contratación tarda 4-12 semanas — iniciarlo en paralelo con el piloto permite tenerlo listo para el mes 7.

**VPN como backup vía BGP:** Configurar la VPN con un AS path más largo o MED más alto hace que el tráfico prefiera DX automáticamente. Si DX falla, el tráfico cae sobre VPN sin intervención manual. Satisface el requisito HIPAA de continuidad de negocio.

**Por qué cada incorrecta falla en producción**

**A:** VPN IPSec sobre internet tiene latencia **variable e impredecible**. La conexión ya está al 60% de utilización — añadir 200 Mbps de replicación la llevaría al 100%, provocando congestión. El proveedor Epic requiere 200 Mbps **dedicados**, que una VPN sobre internet compartida no puede garantizar. Válida como puente temporal, inviable para producción.

**B:** Esperar a que DX esté provisionado antes de iniciar el piloto incumple el plazo de 6 semanas. El lead time de Direct Connect incluye negociación con ISP local, instalación física en el datacenter, y configuración en AWS — puede superar las 6 semanas. El piloto es necesario para validar la arquitectura de migración.

**D:** Direct Connect Gateway es la solución correcta cuando necesitas conectar un datacenter a **múltiples regiones AWS** desde un único enlace DX. Para un hospital que migra a una sola región, DX Gateway añade complejidad innecesaria. También ignora el problema del timing del piloto. Trampa para quienes recuerdan DX Gateway como "la mejor forma de DX" sin analizar si el caso multi-región aplica.

**Exam tip**

> La señal para **Direct Connect**: latencia garantizada (SLAs), ancho de banda dedicado, altos volúmenes de datos, conexiones de larga duración. La señal para **VPN**: disponibilidad rápida, coste bajo, backup de DX. La señal para **VPN + DX combinados**: enunciado que menciona *"necesitamos empezar ya"* Y *"producción necesita garantías"*. HIPAA **no exige** DX — VPN IPSec satisface el requisito de cifrado.

---

## Escenario 4 — Alta disponibilidad de egress en multi-AZ

**Respuesta correcta: C**

NAT Gateway por AZ es el patrón de alta disponibilidad que AWS recomienda explícitamente. Hay dos razones convergentes:

**Razón 1 — Resiliencia:** Cuando eu-west-1a falla, el NAT GW de eu-west-1a también falla. Las instancias en eu-west-1b tienen su propia route table que apunta al NAT GW de eu-west-1b —que sigue funcionando. Sin dependencia cross-AZ.

**Razón 2 — Coste de transferencia:** Cuando eu-west-1b usa el NAT GW de eu-west-1a, cada byte genera **0.02€/GB** de coste inter-AZ. Con NAT GW por AZ, el tráfico no cruza fronteras de AZ y se elimina ese coste.

La clave operativa: route tables separadas por AZ (`rt-private-euw1a` → `nat-gw-euw1a`, `rt-private-euw1b` → `nat-gw-euw1b`). Respecto a las IPs whitelisted: las Elastic IPs de los NAT Gateways son estáticas — Stripe y SendGrid pueden whitelist ambas desde el inicio.

**Por qué cada incorrecta falla en producción**

**A:** Un NAT Instance es una EC2 — un único punto de fallo dentro de eu-west-1b. Requiere deshabilitar source/destination check, gestionar parches, escalar manualmente, y configurar failover propio. El incidente fue precisamente porque el equipo tardó 4 horas en reaccionar — un NAT Instance replica exactamente ese problema. Su fiabilidad no puede compararse con un servicio managed.

**B:** Mover servidores a subnets públicas viola el principio de menor privilegio. Los servidores de aplicación SaaS no deben ser directamente alcanzables desde internet. Cualquier error de configuración en SGs expone los servidores. Además, las IPs de instancias cambian al terminarlas y relanzarlas.

**D:** Las VPC Route Tables de AWS **no soportan ECMP** para NAT Gateways. Las rutas con el mismo destino se resuelven por "última ruta gana" — no se distribuye el tráfico. ECMP es posible con appliances de red de terceros usando GWLB, pero no es el comportamiento nativo de las route tables para NAT Gateways.

**Exam tip**

> Cuando el enunciado menciona **"fallo de AZ"** y hay **NAT Gateway involucrado**: la respuesta es siempre **NAT GW por AZ** + route tables separadas por AZ. La segunda razón (coste inter-AZ) refuerza la decisión pero no es la principal. La trampa es el NAT Instance — parece backup válido pero introduce más problemas de los que resuelve.

---

## Escenario 5 — La aplicación no conecta a la base de datos

**Respuesta correcta: D**

Los Flow Logs son el diagnóstico definitivo:

**Registro 1 (ACCEPT):** La petición TCP de la app (10.10.11.20) al puerto 5432 de la DB (10.10.21.35) fue aceptada. La NACL inbound permite TCP 5432 desde `10.10.11.0/24` y el SG permite esa conexión. Hasta aquí correcto.

**Registro 2 (REJECT):** La **respuesta** de la DB hacia la app en el puerto efímero **49821** (elegido aleatoriamente por el kernel del cliente) fue rechazada. `action=REJECT` indica que una NACL o SG bloqueó el paquete.

¿Por qué no el SG? Los Security Groups son **stateful**: cuando aceptan una conexión TCP entrante, automáticamente permiten el tráfico de respuesta saliente sin regla explícita. El SG con "All outbound Allowed" confirma esto.

¿Por qué sí la NACL? Las NACLs son **stateless**: no recuerdan las conexiones. El paquete de respuesta (srcport=5432, dstport=49821) es evaluado independientemente por las reglas outbound de `nacl-isolated`. Si esa NACL no tiene regla outbound para TCP 1024-65535 hacia `10.10.11.0/24`, el paquete es rechazado.

**La solución:** Añadir en `nacl-isolated` una regla outbound `ALLOW TCP 1024-65535 → 10.10.11.0/24`.

**Por qué cada incorrecta falla en producción**

**A:** Los Security Groups son **stateful**. Cuando `sg-db` acepta una conexión TCP entrante en 5432, la respuesta saliente está automáticamente permitida. Añadir una regla inbound TCP 1024-65535 en `sg-db` no tendría ningún efecto sobre el tráfico de respuesta outbound, y además abriría un rango de puertos innecesario para tráfico entrante.

**B:** Un `REJECT` en Flow Logs indica explícitamente que un **Security Group o NACL** rechazó el paquete. Si el problema fuera una ruta faltante, el paquete sería descartado silenciosamente (sin `REJECT` — aparecería como `NODATA` o no habría registro). La ruta `local` ya incluye la comunicación dentro de la misma VPC.

**C:** VPC Flow Logs no tienen "falsos positivos" en el campo `action`. Los valores `ACCEPT` y `REJECT` reflejan decisiones reales en el momento de captura. Reiniciar el servicio de logs no cambia la conectividad de red.

**Exam tip**

> Tabla de diagnóstico para connection timeout con Flow Logs:
>
> | Log muestra | Causa probable |
> |-------------|----------------|
> | Inbound ACCEPT + Outbound REJECT | **NACL falta regla outbound efímeros 1024-65535** |
> | Inbound REJECT | SG o NACL inbound bloquea |
> | Sin logs en absoluto | IAM role mal configurado, o tráfico excluido (DHCP, IMDSv2) |
> | ACCEPT en ambos sentidos pero no conecta | Routing asimétrico |
>
> Clave: **NACL stateless → necesita regla para ida Y vuelta**. **SG stateful → la respuesta es automática**.

---

## Escenario 6 — Control de exfiltración via VPC Endpoint Policy

**Respuesta correcta: D**

El **Endpoint Policy** es el mecanismo nativo diseñado exactamente para este caso de uso: controlar **qué recursos** son accesibles a través de un VPC Endpoint, independientemente de los permisos IAM del llamante.

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": "*",
    "Action": ["s3:PutObject", "s3:GetObject", "s3:ListBucket"],
    "Resource": [
      "arn:aws:s3:::fintech-audit-logs-prod",
      "arn:aws:s3:::fintech-audit-logs-prod/*"
    ]
  }]
}
```

Con esta política, cualquier petición hacia un bucket diferente de `fintech-audit-logs-prod` a través del Gateway Endpoint recibe **Access Denied** — aunque el IAM role lo permitiera. El control se aplica en la capa del endpoint, no en la instancia. Auditable: el equipo de compliance revisa la Endpoint Policy en la consola sin revisar decenas de IAM roles.

**Por qué cada incorrecta falla en producción**

**A:** Una Bucket Policy en el bucket corporativo protege **ese bucket**, pero no impide que las instancias accedan a **otros buckets**. El atacante no necesita el bucket `fintech-audit-logs-prod` para exfiltrar — puede crear su propio bucket (`attacker-bucket`) y enviar datos allí. La Bucket Policy de un bucket no controla el acceso a otros buckets.

**B:** S3 usa las mismas IPs (el prefix list del Gateway Endpoint) para **todos** los buckets de S3, independientemente de la cuenta propietaria. No es posible distinguir "tráfico hacia bucket-A" de "tráfico hacia bucket-B" por dirección IP. Las NACLs operan en capa de red (IP/puerto) y no tienen visibilidad del ARN del bucket en la petición HTTP.

**C:** Restringir `aws:RequestedRegion` a eu-west-1 reduce el scope pero **no resuelve el problema**: un atacante puede crear su bucket exfiltrador en eu-west-1 también. La condición de región no discrimina entre la cuenta corporativa y una cuenta de un atacante. Además, el enunciado especifica explícitamente "sin modificar los IAM roles".

**Exam tip**

> **Endpoint Policy** = controla qué **recursos AWS** son accesibles a través del endpoint (independiente de IAM). **Bucket Policy** = controla quién puede acceder a **ese bucket concreto**. Son capas complementarias, no alternativas. Señal para Endpoint Policy: *"prevenir acceso a buckets externos"*, *"exfiltración via endpoint"*, *"sin modificar IAM"*. Funciona igual para Gateway Endpoints (S3, DynamoDB) e Interface Endpoints.

---

## Escenario 7 — IPv6 con instancias privadas — Egress-only Internet Gateway

**Respuesta correcta: C**

El **Egress-Only Internet Gateway** (EIGW) es el mecanismo diseñado específicamente para este caso: permite tráfico IPv6 **saliente** desde instancias en subnets privadas, pero **bloquea cualquier conexión entrante iniciada desde internet**. Es el equivalente IPv6 del NAT Gateway, con una diferencia fundamental: no hace traducción de direcciones (IPv6 no necesita NAT porque cada dirección es globalmente única).

Configuración correcta:
- VPC: asignar bloque `/56` IPv6
- Subnets privadas: asignar `/64` (sin ruta `::/0 → IGW`)
- Crear EIGW adjunto a la VPC
- Route table privada: añadir `::/0 → EIGW`

El EIGW actúa como puerta de salida con estado: permite respuestas a conexiones iniciadas desde dentro, pero descarta paquetes iniciados desde internet.

**Por qué cada incorrecta falla en producción**

**A:** Añadir una ruta `::/0 → IGW` en la subnet privada hace que esa subnet sea **pública por IPv6** — cualquier instancia con una dirección IPv6 global unicast (que todas las tendrán si la subnet tiene un bloque IPv6 asignado) puede recibir tráfico desde internet si el SG lo permite. Los Security Groups son la segunda línea de defensa, no el límite arquitectónico. Un error de configuración del SG expondría los servidores directamente. El EIGW existe precisamente para evitar depender de los SGs como única protección.

**B:** El NAT Gateway de AWS **no soporta IPv6**. NAT es fundamentalmente un mecanismo para traducir direcciones IPv4 privadas a públicas. IPv6 fue diseñado para eliminar NAT (cada dispositivo tiene dirección global única). Intentar configurar el NAT GW para IPv6 fallará — AWS no lo permite.

**D:** Es incorrecto afirmar que IPv6 requiere subnets públicas. Las subnets pueden ser privadas en IPv6 simplemente omitiendo la ruta `::/0 → IGW` en su route table. Los bloques IPv6 son globalmente enrutables, pero eso no significa que deban tener una ruta de internet si no se configura. Además, usar un proxy EC2 introduce un single point of failure y overhead operativo que el EIGW elimina.

**Exam tip**

> **"IPv6 egress sin ser alcanzable desde internet"** = **Egress-Only Internet Gateway**. EIGW es para IPv6 lo que NAT GW es para IPv4 — pero sin traducción de direcciones. Hecho clave: **NAT Gateway NO soporta IPv6**. Si el enunciado menciona IPv6 + instancias privadas + salida a internet, EIGW es la respuesta. Si solo menciona IPv6 en subnets públicas (recursos accesibles desde internet), usa el IGW directamente.

---

## Escenario 8 — Interface Endpoint de Secrets Manager con DNS privado — troubleshooting

**Respuesta correcta: C**

Para que un Interface Endpoint con Private DNS enabled funcione, la VPC necesita que **ambos** atributos DNS estén activados:
- `enableDnsSupport = true`: permite que las instancias usen el servidor DNS de la VPC (en la dirección VPC+2, p.ej. `10.10.0.2`)
- `enableDnsHostnames = true`: permite que AWS asigne nombres DNS a las instancias y habilita que los Private Hosted Zones de Route 53 funcionen dentro de la VPC

Cuando Private DNS está habilitado en un Interface Endpoint, AWS crea una Private Hosted Zone que **sobreescribe** la resolución del hostname estándar del servicio (`secretsmanager.eu-west-1.amazonaws.com`) para devolver la IP privada de la ENI del endpoint (`10.10.21.100`). Si `enableDnsSupport` está desactivado, las instancias no pueden contactar el servidor DNS de la VPC y la sobreescritura no tiene efecto — el nombre resuelve a la IP pública de AWS.

**Por qué cada incorrecta falla en producción**

**A:** Los Security Groups son **stateful**. Cuando una instancia inicia una conexión HTTPS al endpoint (que es una petición iniciada por el cliente), el SG del endpoint solo necesita permitir el **inbound** TCP 443 desde el origen. La respuesta del endpoint al cliente está automáticamente permitida por la naturaleza stateful del SG. Una regla outbound en el SG del endpoint no es necesaria ni relevante para el problema descrito.

**B:** El propósito de "Enable private DNS names" es exactamente que el código existente que usa el hostname estándar (`secretsmanager.eu-west-1.amazonaws.com`) no necesite modificarse — el DNS se encarga de resolverlo a la IP privada. Forzar el uso del hostname específico del endpoint (`vpce-xxx.secretsmanager...vpce.amazonaws.com`) funciona como workaround pero requiere cambiar la configuración de todas las aplicaciones, lo que contradice el objetivo del private DNS y no resuelve la causa raíz.

**D:** Interface Endpoints funcionan a nivel de VPC via DNS, no a nivel de subnet. Cuando el private DNS está bien configurado, cualquier instancia en cualquier subnet de la VPC resolverá el hostname del servicio a la IP privada del endpoint ENI. No existe requisito de colocalización en la misma subnet.

**Exam tip**

> **Interface Endpoint + Private DNS + timeout + DNS resuelve a IP pública** → **verificar `enableDnsSupport` y `enableDnsHostnames` en la VPC** (ambos deben ser `true`). Este es el diagnóstico correcto cuando el endpoint está `Available`, el SG es correcto, IAM es correcto, pero el tráfico sigue yendo a la IP pública. Es el error más común al desplegar Interface Endpoints en VPCs con configuración DNS no estándar.

---

## Escenario 9 — Adquisición con CIDRs solapados — acceso a servicio específico entre cuentas

**Respuesta correcta: C**

**AWS PrivateLink (Endpoint Services)** es el único mecanismo de conectividad VPC que funciona con CIDRs solapados porque no usa enrutamiento basado en CIDRs para la comunicación. Resuelve los cuatro requisitos simultáneamente:

1. **CIDRs solapados no son problema**: El consumidor crea un Interface Endpoint que obtiene una IP dentro de su propio espacio de direcciones (del CIDR del consumidor). La conexión usa esa IP, sin routing entre CIDRs superpuestos.
2. **Acceso unidireccional por diseño**: El consumidor (FinCorp) puede alcanzar el NLB de PayStart, pero PayStart no tiene ninguna ruta hacia FinCorp.
3. **Restricción de puerto**: El NLB solo tiene listener en TCP 8443 — el único puerto accesible.
4. **Desplegable en días**: Crear un NLB, un Endpoint Service y un Interface Endpoint no requiere más de pocas horas.

**Por qué cada incorrecta falla en producción**

**A:** VPC Peering **requiere CIDRs no superpuestos** — es una restricción técnica fundamental, no de configuración. Con ambas VPCs en `10.10.0.0/16`, el peering es imposible. AWS rechazará la solicitud de peering. Esta opción no es viable bajo ninguna configuración adicional de SGs o NACLs.

**B:** Transit Gateway también **requiere CIDRs no superpuestos** para enrutar. El TGW necesita saber qué prefijo CIDR pertenece a qué attachment. Con dos attachments anunciando el mismo `10.10.0.0/16`, el routing es ambiguo y TGW no puede distinguir el tráfico. AWS no permite crear la tabla de rutas necesaria.

**D:** Site-to-Site VPN entre VPCs también requiere CIDRs no superpuestos para que BGP pueda anunciar rutas. Si ambos lados anuncian `10.10.0.0/16`, el anuncio de la ruta `/32` del servidor no resuelve el conflicto en la tabla de rutas base — los paquetes de respuesta no sabrían por qué camino volver.

**Exam tip**

> **CIDRs solapados + necesidad de compartir servicio específico** = **AWS PrivateLink (Endpoint Service)**. Es el **único** mecanismo de conectividad VPC que no requiere CIDRs no solapados. También es la respuesta cuando el enunciado dice "solo exponer un servicio, no acceso completo a la red". VPC Peering, TGW y VPN **siempre** requieren CIDRs no superpuestos.

---

## Escenario 10 — Detección de amenazas de red en tiempo real

**Respuesta correcta: B**

**Amazon GuardDuty** es el servicio purpose-built para exactamente estos patrones de amenaza. Tiene detectores basados en ML pre-construidos para:
- **Escaneo de puertos**: `Recon:EC2/PortProbeUnprotectedPort`, `Recon:EC2/Portscan`
- **Exfiltración de datos**: `Exfiltration:EC2/StrangeBehavior`, `Exfiltration:EC2/AnomalousBehavior`
- **Conexiones a IPs maliciosas**: threat intelligence feeds gestionados automáticamente (`Trojan:EC2/DNSDataExfiltration`, `Backdoor:EC2/C&CActivity`)

GuardDuty consume VPC Flow Logs **directamente** (no necesita el bucket S3 del equipo — accede a los logs por su propio canal). El tiempo de detección es típicamente < 5 minutos. El equipo no gestiona ningún pipeline. El coste es predecible por GB analizado.

**Por qué cada incorrecta falla en producción**

**A:** Las queries de Athena son **batch** — incluso programándolas cada 5 minutos, la latencia real puede ser de 10-15 minutos sumando el intervalo de agregación de Flow Logs (10 min por defecto), el tiempo de ejecución de la query y el tiempo de procesamiento de la alerta. Además, escribir y mantener queries SQL para patrones de amenaza es trabajo de investigación de seguridad especializado que un equipo de 2 personas no puede sostener y actualizar ante amenazas nuevas.

**C:** Kinesis Data Firehose + Lambda es técnicamente capaz pero requiere semanas de desarrollo para implementar correctamente los algoritmos de detección de los 3 patrones, plus infraestructura de pipeline que debe monitorizarse, escalarse y mantenerse. Para un equipo de 2 ingenieros, esto se convierte en el proyecto principal, desplazando la operativa de seguridad real.

**D:** Agentes SIEM en cada EC2 introducen overhead máximo: hay que instalar y actualizar agentes en cada instancia (incluyendo nuevas instancias de ASGs), gestionar la infraestructura del servidor SIEM central, y escribir reglas de detección custom. Un agente que falle silenciosamente en una instancia crea puntos ciegos de seguridad difíciles de detectar.

**Exam tip**

> **"Detección de amenazas"**, **"escaneo de puertos"**, **"exfiltración"**, **"IPs maliciosas"**, **"mínimo overhead operativo"** → **Amazon GuardDuty**. GuardDuty es el servicio managed de threat detection que consume automáticamente Flow Logs, CloudTrail y DNS logs sin ninguna configuración de pipeline. El distractor clásico es Kinesis + Lambda que es técnicamente correcto pero viola el requisito de mínimo overhead.

---

## Escenario 11 — Egress centralizado con inspección — TGW + Security VPC

**Respuesta correcta: B**

Transit Gateway con el patrón de **Security VPC / Egress VPC** es la arquitectura estándar para inspección centralizada de tráfico. El flujo completo:

```
VPC-Prod-N → TGW → Security VPC → Appliance Firewall → NAT GW → IGW → Internet
Respuesta: Internet → IGW → NAT GW → Firewall → TGW → VPC-Prod-N
```

Las TGW Route Tables garantizan que `0.0.0.0/0` desde cualquier VPC de producción enruta exclusivamente hacia la Security VPC. El appliance no puede ser bypasseado — es el único camino. Para añadir una nueva VPC: (1) crear attachment TGW + (2) asociar a la RT de producción = < 1 hora. Alta disponibilidad: el appliance en la Security VPC puede desplegarse en múltiples AZs con un NLB o AWS GWLB.

**Por qué cada incorrecta falla en producción**

**A:** VPC Peering es **no transitivo**. Si VPC-Prod-A hace peering con la Security VPC, la ruta `0.0.0.0/0 → peering connection` en la route table de Prod-A no funciona para tráfico de internet. El VPC Peering no admite rutas por defecto (`0.0.0.0/0`) a través del peering — solo permite tráfico hacia el CIDR exacto de la VPC peerada. El tráfico de internet no puede ser enrutado a través de una conexión de peering.

**C:** Desplegar Network Firewall en **cada VPC** no es "centralizado" — es distribuido. No crea un único punto de inspección obligatorio (un atacante que comprometiera una VPC y desactivara su Network Firewall local bypassearía la inspección). Además, el coste de Network Firewall por VPC escala linealmente. El logging centralizado en S3 no equivale a inspección centralizada.

**D:** GuardDuty + Flow Logs es **detección reactiva**, no inspección preventiva. El tráfico ya ha salido cuando GuardDuty lo detecta. Un Lambda que actualice Security Groups tiene latencia (segundos-minutos). El CISO pidió inspección **antes** de que el tráfico salga, no alertas después.

**Exam tip**

> **"Egress centralizado"**, **"todo el tráfico debe pasar por inspection VPC"**, **"escalable a nuevas VPCs"** → **Transit Gateway + Security/Egress VPC**. Clave: VPC Peering no soporta rutas `0.0.0.0/0` (no hay tráfico de internet por peering). TGW es imprescindible para el routing centralizado. Si el enunciado menciona un "appliance de firewall" de terceros, puede aparecer AWS Gateway Load Balancer (GWLB) como mecanismo de inserción del appliance en el flujo de tráfico — eso es correcto y compatible con esta arquitectura.

---

## Tabla resumen — Patrones y palabras clave

| Patrón | Servicio/Mecanismo | Señal clave en el enunciado |
|--------|-------------------|----------------------------|
| Sin internet / PCI-DSS | Subnets aisladas + VPC Endpoints | "sin ruta a internet", "CDE", "PCI-DSS", "aunque esté cifrado" |
| SSM sin bastion | Interface Endpoints ssm + ssmmessages + ec2messages | "sin SSH", "sin bastion", "Session Manager" |
| Multi-VPC a escala | Transit Gateway + RT segregadas | "N VPCs", "aislamiento entre grupos", "hub-and-spoke", "escala" |
| Peering no transitivo | — (trampa) | "enrutar a través de VPC hub", "peering como hub" |
| Híbrido producción | Direct Connect + VPN backup | "latencia garantizada", "banda dedicada", "EHR/ERP" |
| HA egress multi-AZ | NAT GW por AZ + RT por AZ | "fallo de AZ", "NAT Gateway único", "egress" |
| Troubleshooting NACL | Regla outbound puertos efímeros 1024-65535 | ACCEPT inbound + REJECT outbound en Flow Logs |
| Exfiltración via Endpoint | Endpoint Policy | "exfiltración", "acceso a buckets externos", "sin modificar IAM" |
| IPv6 egress privado | Egress-Only Internet Gateway | "IPv6 privado", "sin acceso entrante IPv6", "NAT para IPv6" |
| Interface Endpoint sin DNS | enableDnsSupport + enableDnsHostnames | Endpoint Available + DNS resuelve a IP pública |
| CIDRs solapados | AWS PrivateLink (Endpoint Service) | "CIDRs solapados", "no se puede cambiar CIDR", "acceso solo a un servicio" |
| Detección de amenazas | Amazon GuardDuty | "port scan", "exfiltración", "IPs maliciosas", "mínimo overhead" |
| Egress centralizado / inspección | Transit Gateway + Security VPC | "todo el tráfico por firewall central", "inspection VPC", "appliance" |
