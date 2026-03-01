# VPC Networking — Escenarios SAA-C03

> 11 escenarios de arquitectura estilo examen real.
> Las respuestas están en: [vpc-scenarios-sa-associate-answers.md](./vpc-scenarios-sa-associate-answers.md)

---

## Índice

| # | Industria | Patrón principal | Compliance |
|---|-----------|-----------------|------------|
| [1](#escenario-1) | Fintech | Sin salida a internet — Endpoints vs NAT | PCI-DSS |
| [2](#escenario-2) | E-Commerce | Multi-VPC a escala — Peering vs TGW | — |
| [3](#escenario-3) | Healthcare | Conectividad híbrida — VPN vs Direct Connect | HIPAA |
| [4](#escenario-4) | SaaS | Multi-AZ HA con egress — NAT GW por AZ | — |
| [5](#escenario-5) | Retail | Troubleshooting — SG vs NACL (puertos efímeros) | — |
| [6](#escenario-6) | Fintech | Endpoint Policy — control de exfiltración S3 | PCI-DSS |
| [7](#escenario-7) | Media/SaaS | IPv6 con instancias privadas — Egress-only IGW | — |
| [8](#escenario-8) | DevOps/SaaS | Interface Endpoint sin DNS privado — troubleshooting | — |
| [9](#escenario-9) | Fintech M&A | CIDRs solapados — PrivateLink entre cuentas | — |
| [10](#escenario-10) | Fintech | Detección de amenazas de red en tiempo real | — |
| [11](#escenario-11) | Enterprise | Egress centralizado con inspección — TGW + Security VPC | — |

---

## Escenario 1

### Procesamiento de pagos sin exposición a internet

Una fintech procesa transacciones de tarjeta de crédito en su entorno de producción. Tras una auditoría PCI-DSS Level 1, el auditor ha marcado como hallazgo crítico que los servidores de procesamiento en subnets privadas utilizan un NAT Gateway para comunicarse con Amazon S3 (almacenamiento de registros de auditoría) y AWS Secrets Manager (credenciales de base de datos). El auditor exige que el entorno de datos de titulares de tarjeta (CDE — Cardholder Data Environment) no tenga ninguna ruta hacia internet, directa o indirecta.

Los servidores también necesitan acceso a AWS Systems Manager Parameter Store para recibir configuración dinámica, y el equipo de operaciones conecta a ellos via AWS Session Manager (SSM) para evitar gestionar claves SSH. El sistema debe estar operativo 24/7 sin ventanas de mantenimiento para el cambio de arquitectura.

El Director de Seguridad ha indicado explícitamente: *"Si el tráfico sale por internet en algún punto del camino, aunque esté cifrado, incumple la norma."*

**Requisitos técnicos**
- Los servidores de procesamiento deben residir en subnets **sin ruta hacia internet** (ni directa via IGW ni indirecta via NAT GW)
- Acceso a S3 (logs), Secrets Manager (credenciales), SSM Parameter Store y Session Manager
- Conectividad operativa via SSM Session Manager (sin SSH, sin bastions)
- Sin ventana de mantenimiento — cambio con mínimo impacto
- Minimizar incremento de coste mensual

**Opciones**

**A)** Mantener las subnets privadas con NAT Gateway. Añadir una regla outbound en los Security Groups que restrinja el tráfico saliente únicamente a los rangos IP conocidos de AWS (prefix lists de S3, Secrets Manager y SSM). Esto garantiza que el tráfico solo va a servicios AWS.

**B)** Mover los servidores a subnets públicas pero sin asignarles IP pública (solo IP privada). Configurar Security Groups estrictos que bloqueen todo el tráfico entrante no autorizado. El IGW solo enruta tráfico con destino a IPs públicas.

**C)** Crear un Gateway Endpoint para S3 (sin coste adicional) e Interface Endpoints para Secrets Manager, SSM, SSMMessages y EC2Messages. Mover los servidores a subnets aisladas sin route table de salida a internet. Los Interface Endpoints resuelven via DNS privado desde dentro de la VPC.

**D)** Desactivar el NAT Gateway y usar AWS PrivateLink para crear un endpoint de servicio propio que enrute las peticiones a S3 y Secrets Manager a través de una cuenta intermediaria que sí tiene conectividad a internet, manteniendo los servidores sin acceso directo.

---

## Escenario 2

### Crecimiento multi-VPC: conectividad y aislamiento a escala

Una empresa de e-commerce ha crecido hasta tener 8 VPCs en eu-west-1: tres VPCs de producción (tienda web, pagos, logística), tres de desarrollo/staging (una por dominio), una VPC de Servicios Compartidos (DNS privado, repositorio de artefactos, monitorización) y una VPC de Seguridad (GuardDuty, Security Hub, logs de auditoría).

Actualmente usan VPC Peering entre todos los VPCs que necesitan comunicarse. El equipo de red tarda tres días en incorporar una nueva VPC porque hay que actualizar manualmente las route tables en cada VPC ya existente. Cuando se añadió la quinta VPC hace tres meses, se olvidó actualizar dos route tables y la aplicación estuvo 6 horas sin acceso al repositorio de artefactos.

Para el próximo trimestre, el equipo de plataforma prevé añadir 4 VPCs más. El equipo de seguridad ha impuesto un nuevo requisito: **las VPCs de producción no deben poder comunicarse con las VPCs de desarrollo directamente**, aunque ambas puedan acceder a Servicios Compartidos.

**Requisitos técnicos**
- Todas las VPCs deben poder acceder a Servicios Compartidos y a Seguridad
- Producción y Desarrollo deben estar **completamente aisladas entre sí**
- Incorporar nuevas VPCs debe tomar horas, no días
- La solución debe escalar a 20+ VPCs en 12 meses

**Opciones**

**A)** Mantener VPC Peering pero reorganizarlo en modelo hub-and-spoke: crear peering entre cada VPC y la VPC de Servicios Compartidos. Esta VPC actúa como hub y enruta tráfico entre VPCs spoke a través de ella.

**B)** Reemplazar todos los VPC Peerings por conexiones AWS PrivateLink (NLB-backed) para exponer cada servicio de Servicios Compartidos como endpoint privado en cada VPC consumidora.

**C)** Migrar a AWS Transit Gateway con dos route tables: una para VPCs de producción (solo acepta rutas de Servicios Compartidos y Seguridad) y otra para VPCs de desarrollo (solo acepta rutas de Servicios Compartidos y Seguridad). Ninguna VPC de producción tiene ruta hacia VPCs de desarrollo y viceversa.

**D)** Usar VPC Peering completo (full-mesh) automatizado con AWS CloudFormation StackSets que crean y actualizan automáticamente los peerinigs y route tables al detectar nuevas VPCs via AWS Config.

---

## Escenario 3

### Migración de EHR hospitalario: conectividad híbrida

Un hospital regional gestiona su sistema de historia clínica electrónica (EHR) con Epic en un datacenter on-premises. El equipo de IT ha planificado una migración en fases a AWS (eu-west-1). Las estaciones de trabajo clínicas en planta —usadas por médicos y enfermería durante la atención al paciente— consultan el EHR en tiempo real; cualquier latencia superior a 200ms en las consultas de pacientes impacta directamente en la seguridad clínica.

El hospital tiene una conexión a internet de 500 Mbps actualmente al 60% de utilización. HIPAA exige cifrado en tránsito y controles de acceso auditables. El proveedor Epic indica que la solución de conectividad debe garantizar un ancho de banda mínimo de 200 Mbps **dedicados** para el tráfico de replicación. El piloto técnico comienza en 6 semanas. La migración completa está planificada para el mes 7.

**Requisitos técnicos**
- Latencia < 200ms entre on-premises y AWS para consultas EHR en producción
- 200 Mbps dedicados y garantizados para replicación de datos
- Cifrado en tránsito (HIPAA)
- El piloto en 6 semanas no puede esperar a nueva infraestructura de red
- Alta disponibilidad para producción (backup si el enlace principal falla)

**Opciones**

**A)** Configurar Site-to-Site VPN IPSec sobre la conexión a internet existente para todas las fases (piloto y producción). El tráfico VPN va cifrado, cumple HIPAA. Añadir una segunda VPN sobre un enlace 4G/LTE de backup.

**B)** Solicitar Direct Connect de 1 Gbps inmediatamente. Esperar a que esté provisionado (normalmente 4-12 semanas) antes de comenzar el piloto. Una vez operativo, usar DX para todo el tráfico.

**C)** Usar Site-to-Site VPN para el piloto de 6 semanas (disponible en horas). Solicitar Direct Connect de 1 Gbps en paralelo para producción. Una vez operativo, configurar el VPN como backup de DX con ruta menos preferida via BGP (MED más alto). Mantener ambos activos.

**D)** Solicitar Direct Connect de 1 Gbps y configurar Direct Connect Gateway para tener conectividad con múltiples regiones AWS desde el inicio. Usar VPN como backup en cada región.

---

## Escenario 4

### Alta disponibilidad de egress en multi-AZ

Una empresa SaaS tiene su aplicación backend en instancias EC2 en subnets privadas distribuidas entre eu-west-1a y eu-west-1b. La aplicación llama a APIs externas (Stripe, SendGrid) con ~3.000 llamadas por minuto en hora punta y necesita salida a internet para ello.

El equipo actualmente tiene un único NAT Gateway en eu-west-1a. Tanto las instancias de eu-west-1a como las de eu-west-1b usan ese mismo NAT GW. Durante un simulacro de fallo de AZ, desactivaron eu-west-1a y descubrieron que **todas** las instancias de eu-west-1b perdieron conectividad saliente. Se generaron 4 horas de alertas y pérdida de transacciones antes de desplegar una solución de emergencia.

El SLO de la aplicación es 99.95% de disponibilidad. Un nuevo requisito del cliente enterprise establece que la arquitectura debe tolerar el fallo completo de una AZ sin impacto en el servicio. Stripe y SendGrid tienen whitelisted las IPs de salida actuales.

**Requisitos técnicos**
- Tolerancia al fallo de cualquier AZ sin pérdida de conectividad saliente
- Las APIs de terceros no deben interrumpirse sin intervención manual
- El coste adicional debe ser justificable ante el CFO
- No modificar las IPs de los servidores de aplicación (IPs whitelisted por terceros)

**Opciones**

**A)** Crear un NAT Instance (EC2 t3.small con script de NAT) en eu-west-1b como backup del NAT Gateway en eu-west-1a. Configurar la route table de eu-west-1b para apuntar al NAT Instance cuando el NAT Gateway principal falle.

**B)** Mover todos los servidores de aplicación a subnets públicas con Elastic IPs. Eliminar la dependencia del NAT Gateway. Los Security Groups controlarán el acceso entrante.

**C)** Desplegar un NAT Gateway en cada AZ (eu-west-1a y eu-west-1b). Actualizar la route table de eu-west-1a para que su `0.0.0.0/0` apunte al NAT GW de eu-west-1a, y la de eu-west-1b para que apunte al NAT GW de eu-west-1b. Cada AZ es autónoma para el egress.

**D)** Configurar una única route table privada compartida con dos rutas de igual coste (ECMP) hacia los NAT Gateways de ambas AZs para distribuir el tráfico y proporcionar redundancia automática.

---

## Escenario 5

### La aplicación no conecta a la base de datos

Una empresa retail tiene una arquitectura 3-tier: servidores web en subnets públicas, servidores de aplicación en subnets privadas (`10.10.11.0/24`) y bases de datos PostgreSQL en subnets aisladas (`10.10.21.0/24`). Recientemente desplegaron una nueva NACL personalizada (`nacl-isolated`) en las subnets de base de datos para reforzar la seguridad tras una auditoría interna.

Desde el despliegue de la NACL, las aplicaciones reportan `connection timeout` al intentar conectar a PostgreSQL (puerto 5432). El Security Group de la instancia DB (`sg-db`) tiene configurada la regla: **Inbound TCP 5432 desde sg-app**. El Security Group tiene outbound `All traffic Allowed`.

Un analista ha revisado los VPC Flow Logs del ENI de la instancia DB y ha encontrado lo siguiente:

```
# Registro 1 — ENI instancia DB
srcaddr=10.10.11.20  dstaddr=10.10.21.35  dstport=5432  protocol=6  action=ACCEPT

# Registro 2 — ENI instancia DB
srcaddr=10.10.21.35  dstaddr=10.10.11.20  srcport=5432  dstport=49821  protocol=6  action=REJECT
```

Los Security Groups no han sido modificados. Solo se desplegó la nueva NACL.

**Requisitos técnicos**
- Identificar la causa raíz basándose en los Flow Logs
- La solución debe restaurar la conectividad sin comprometer el aislamiento de la subnet

**Opciones**

**A)** Añadir una regla inbound en el Security Group `sg-db` que permita TCP en puertos 1024-65535 desde `10.10.11.0/24`. Los Security Groups necesitan reglas explícitas para el tráfico de respuesta TCP.

**B)** Añadir una ruta en la route table de la subnet aislada que permita el tráfico de vuelta hacia `10.10.11.0/24`. El `REJECT` en logs indica que no hay ruta de retorno en la route table.

**C)** Reiniciar el agente de VPC Flow Logs. Los registros muestran un falso REJECT debido a un problema de captura — el tráfico TCP real está fluyendo correctamente pero los logs están desincronizados.

**D)** Añadir una regla outbound en la NACL `nacl-isolated` que permita TCP 1024-65535 con destino `10.10.11.0/24`. La NACL es stateless y necesita una regla explícita para el tráfico de respuesta.

---

## Escenario 6

### Control de exfiltración via VPC Endpoint Policy

Una fintech ha implementado la arquitectura PCI-DSS: sus servidores de procesamiento residen en subnets aisladas sin acceso a internet, y utilizan un **Gateway Endpoint de S3** para almacenar logs de transacciones en `s3://fintech-audit-logs-prod`.

Durante un red team exercise, el equipo descubrió que cualquier instancia dentro de la VPC puede ejecutar `aws s3 cp archivo.txt s3://cualquier-bucket-externo/` y los datos **llegan al destino**. Aunque el tráfico va por el Gateway Endpoint (sin pasar por internet), el endpoint permite acceso a **cualquier bucket de S3**, incluyendo buckets en cuentas AWS de terceros. Un atacante con acceso a una instancia comprometida podría exfiltrar datos de tarjetas de crédito hacia un bucket en su propia cuenta AWS.

El CISO ha pedido un control que garantice que las instancias solo puedan acceder al bucket corporativo, **sin modificar los IAM roles de las instancias**.

**Requisitos técnicos**
- Restringir el acceso via Gateway Endpoint únicamente al bucket `fintech-audit-logs-prod`
- No modificar los IAM roles de las instancias
- La solución debe ser auditable y demostrable al equipo de compliance
- Coste mínimo

**Opciones**

**A)** Añadir una Bucket Policy al bucket `fintech-audit-logs-prod` que requiera que las peticiones provengan de la VPC (`aws:SourceVpc`). Esto asegura que solo las instancias dentro de la VPC puedan acceder al bucket corporativo.

**B)** Crear una NACL en las subnets aisladas que bloquee el tráfico saliente hacia los rangos IP de S3 (usando el prefix list del Gateway Endpoint) excepto para el rango IP específico del bucket corporativo.

**C)** Modificar los IAM roles de las instancias para incluir una condición `aws:RequestedRegion` que restrinja el acceso S3 solo a eu-west-1, reduciendo los buckets accesibles a los de la región corporativa.

**D)** Adjuntar un Endpoint Policy al Gateway Endpoint de S3 que restrinja las acciones permitidas únicamente al ARN del bucket corporativo. Cualquier petición hacia otro bucket o cuenta será denegada en el nivel del endpoint.

---

## Escenario 7

### IPv6 en instancias privadas — Egress-only Internet Gateway

Una empresa de media streaming está desplegando un nuevo servicio de distribución de contenido. Necesita conectarse a APIs de terceros que solo exponen endpoints IPv6 (redes móviles en algunos mercados europeos). Sus servidores de procesamiento también deben poder iniciar conexiones IPv6 hacia internet, pero el CISO ha establecido que **ningún cliente externo debe poder iniciar conexiones hacia los servidores de procesamiento por IPv6**.

El arquitecto ha asignado un bloque `/56` IPv6 al VPC. Los servidores de procesamiento están en subnets privadas (sin IP pública IPv4). La solución debe ser completamente managed por AWS (sin instancias proxy adicionales).

**Requisitos técnicos**
- Los servidores en subnets privadas pueden iniciar conexiones IPv6 salientes
- Nadie en internet puede iniciar conexiones IPv6 hacia los servidores
- IPv4 sigue funcionando (arquitectura dual-stack)
- Sin instancias intermediarias (proxy, bastion) para el flujo IPv6

**Opciones**

**A)** Añadir el bloque `/56` IPv6 al VPC. Asignar un bloque `/64` a las subnets de procesamiento. Añadir una ruta `::/0 → IGW` en la route table privada. Configurar Security Groups para bloquear todo el tráfico IPv6 entrante. El IGW gestiona tanto IPv4 como IPv6.

**B)** Añadir el bloque `/56` IPv6 al VPC. Configurar el NAT Gateway existente para gestionar también el tráfico IPv6. El NAT GW ya maneja el egress IPv4 y puede extenderse a IPv6 sin infraestructura adicional.

**C)** Añadir el bloque `/56` IPv6 al VPC. Asignar `/64` a las subnets de procesamiento. Crear un **Egress-Only Internet Gateway**. Añadir una ruta `::/0 → EIGW` en la route table privada. No añadir `::/0 → IGW` en esa route table.

**D)** IPv6 requiere que todas las subnets sean públicas (los bloques IPv6 son globalmente enrutables). Mover los servidores de procesamiento a subnets públicas y usar Security Groups para bloquear el acceso entrante de internet. El CIDR privado RFC1918 solo aplica a IPv4.

---

## Escenario 8

### Interface Endpoint de Secrets Manager con DNS privado — troubleshooting

Un equipo de plataforma ha desplegado un Interface Endpoint para AWS Secrets Manager con la opción "Enable private DNS names" activada. El endpoint figura como `Available` en la consola. El Security Group asociado permite HTTPS (TCP 443) inbound desde el CIDR de la VPC (`10.10.0.0/16`). Los IAM roles de las instancias tienen permisos `secretsmanager:GetSecretValue`.

Sin embargo, las instancias obtienen `connection timeout` al llamar a `secretsmanager.eu-west-1.amazonaws.com`. Un análisis con `nslookup` desde una instancia revela que el hostname resuelve a una IP **pública** de AWS (`52.95.x.x`) en lugar de a la IP privada de la ENI del endpoint (`10.10.21.100`).

El equipo ha verificado:
- Estado del endpoint: `Available` ✓
- SG permite TCP 443 desde VPC CIDR ✓
- IAM role tiene permisos ✓
- Private DNS name habilitado en el endpoint ✓

**Requisitos técnicos**
- Identificar por qué el DNS no resuelve a la IP privada del endpoint
- Solucionar sin reemplazar el endpoint

**Opciones**

**A)** El Security Group del endpoint necesita una regla outbound que permita TCP 443 hacia el CIDR de la VPC. Sin ella, la ENI del endpoint no puede enviar respuestas a los clientes.

**B)** Las instancias deben usar el hostname específico del endpoint (`vpce-xxx-yyy.secretsmanager.eu-west-1.vpce.amazonaws.com`) en lugar del hostname regional estándar. El DNS privado no funciona con el hostname genérico del servicio.

**C)** La VPC tiene `enableDnsSupport` o `enableDnsHostnames` configurado como `false`. La resolución DNS privada de los Interface Endpoints requiere que ambos atributos DNS de la VPC estén activados.

**D)** El Interface Endpoint debe desplegarse en la misma subnet que las instancias. Cuando están en subnets distintas, el DNS privado no propaga la resolución correcta.

---

## Escenario 9

### Adquisición con CIDRs solapados — acceso a servicio específico entre cuentas

FinCorp (Cuenta A, VPC: `10.10.0.0/16`) ha adquirido PayStart (Cuenta B, VPC: `10.10.0.0/16` — mismo CIDR). FinCorp necesita consumir una API de reconciliación de pagos específica de PayStart (TCP 8443). Los requisitos del equipo de seguridad son:

- FinCorp puede acceder **únicamente** al endpoint de la API (TCP 8443), sin ningún otro acceso a la red de PayStart
- PayStart **no debe tener ningún acceso** a la red de FinCorp
- Los CIDRs (`10.10.0.0/16`) **no pueden cambiarse** en ninguna de las dos cuentas (200+ servicios con IPs hardcodeadas)
- Deadline para cumplir el requisito: **5 días hábiles** (contrato firmado)

**Requisitos técnicos**
- Acceso unidireccional: FinCorp → API de PayStart
- Sin acceso amplio de red entre las VPCs
- Los CIDRs superpuestos son un constraint fijo
- Solución desplegable en días

**Opciones**

**A)** Crear VPC Peering entre Cuenta A y Cuenta B. Usar Security Groups en la EC2 de la API de reconciliación para restringir acceso al puerto 8443, y NACLs para evitar que PayStart acceda a FinCorp.

**B)** Desplegar AWS Transit Gateway en Cuenta A con attachments en ambas VPCs. Configurar TGW Route Tables para que PayStart solo pueda enrutar hacia la subnet de la API de reconciliación.

**C)** En Cuenta B (PayStart), desplegar un NLB delante de la API de reconciliación. Crear un VPC Endpoint Service desde ese NLB. En Cuenta A (FinCorp), crear un Interface Endpoint apuntando al Endpoint Service de PayStart. Las instancias de FinCorp se conectan via la IP privada del endpoint.

**D)** Configurar Site-to-Site VPN entre las dos VPCs sobre internet, y usar BGP para anunciar únicamente la ruta `/32` del servidor de la API de reconciliación desde PayStart hacia FinCorp.

---

## Escenario 10

### Detección de amenazas de red en tiempo real

Una empresa de servicios financieros acaba de sufrir un incidente de seguridad: una instancia EC2 comprometida estuvo escaneando puertos de otras instancias de la VPC y exfiltrando datos durante 6 días antes de ser descubierta. VPC Flow Logs estaban habilitados y enviando a S3, pero nadie había configurado alertas.

El CISO ha pedido implementar detección de amenazas en **tiempo real** (alertas en menos de 10 minutos) para los siguientes patrones:
- Escaneo de puertos (muchos REJECT desde una misma IP origen)
- Volúmenes inusuales de datos salientes (posible exfiltración)
- Conexiones hacia IPs maliciosas conocidas

El equipo de seguridad tiene 2 ingenieros y no tiene presupuesto para herramientas SIEM externas. Quieren **mínimo overhead operativo**.

**Requisitos técnicos**
- Detección en < 10 minutos
- Cobertura de los 3 patrones indicados (port scan, exfiltración, IPs maliciosas)
- Equipo de 2 ingenieros — mínimo overhead de mantenimiento
- Sin SIEM de terceros

**Opciones**

**A)** Crear una tabla Athena sobre el bucket S3 de Flow Logs. Escribir queries SQL para cada patrón de amenaza y programarlas cada 5 minutos con EventBridge + Lambda. Enviar alertas via SNS.

**B)** Habilitar Amazon GuardDuty. Analizará automáticamente VPC Flow Logs, CloudTrail y DNS logs para detectar las amenazas indicadas. Configurar GuardDuty findings para disparar reglas de EventBridge → SNS para alertas.

**C)** Transmitir VPC Flow Logs a Amazon Kinesis Data Firehose, procesar con Lambda (lógica de detección de amenazas custom), almacenar resultados en DynamoDB y alertar con SNS cuando se superen umbrales.

**D)** Instalar un agente de SIEM de terceros en cada instancia EC2 para recopilar y reenviar logs a un servidor SIEM centralizado en una VPC de seguridad dedicada, para análisis en tiempo real.

---

## Escenario 11

### Egress centralizado con inspección — TGW + Security VPC

Una empresa enterprise tiene 5 VPCs de producción en eu-west-1. Actualmente cada VPC tiene su propio NAT Gateway para salida a internet. El CISO ha mandatado: **todo el tráfico saliente a internet debe pasar por un punto centralizado de inspección** donde se aplique un firewall de red de terceros (capaz de hacer deep packet inspection) antes de salir. Esto aplica a todas las VPCs existentes y a las nuevas que se añadan en el futuro.

El equipo de seguridad gestiona una "Security VPC" con el appliance de firewall de terceros. El diseño debe ser escalable: añadir una nueva VPC al patrón no debe requerir más de 1 hora de trabajo.

**Requisitos técnicos**
- **Todo** el tráfico saliente de producción debe pasar por el firewall de la Security VPC
- El tráfico no puede bypassear la inspección por ningún camino
- Escalable: añadir nueva VPC ≤ 1 hora de configuración
- Alta disponibilidad del punto de inspección

**Opciones**

**A)** Crear VPC Peering entre cada VPC de producción y la Security VPC. Configurar rutas por defecto en las subnets privadas de producción apuntando a la IP del appliance de firewall en la Security VPC.

**B)** Desplegar un Transit Gateway. Adjuntar todas las VPCs de producción y la Security VPC al TGW. Configurar las TGW Route Tables para que `0.0.0.0/0` desde las VPCs de producción enrute hacia la Security VPC. El appliance de firewall inspecciona y reenvía hacia el NAT Gateway e IGW en la Security VPC.

**C)** Desplegar AWS Network Firewall en cada VPC de producción con las mismas reglas de política de seguridad. Centralizar el logging de todos los Network Firewalls hacia un bucket S3 en la Security VPC para auditoría.

**D)** Usar VPC Flow Logs y Amazon GuardDuty para detectar tráfico no inspeccionado y bloquearlo de forma reactiva mediante funciones Lambda que actualicen los Security Groups cuando se detecte tráfico sospechoso.
