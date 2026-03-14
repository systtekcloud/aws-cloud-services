# Security & Governance — Escenarios SAA-C03

> 10 escenarios de arquitectura estilo examen real. Multi-cuenta, Organizations, SCP, Identity Center y más.
> Las respuestas están en: [security-scenarios-sa-associate-answers.md](./security-scenarios-sa-associate-answers.md)

---

## Índice

| # | Industria | Patrón principal | Compliance |
|---|-----------|-----------------|------------|
| [1](#escenario-1) | Fintech | SCP/OU — restricción de regiones por OU vs IAM policy | PCI-DSS |
| [2](#escenario-2) | Retail | SCP/OU — protección de CloudTrail org-level vs IAM | — |
| [3](#escenario-3) | Healthcare | IAM Identity Center vs IAM Users — acceso federado multi-cuenta | HIPAA |
| [4](#escenario-4) | Media | CloudTrail org vs Config — auditoría de eventos vs compliance de estado | — |
| [5](#escenario-5) | SaaS Enterprise | Control Tower guardrails vs Organizations manual — baseline governance | — |
| [6](#escenario-6) | Banking | KMS + Secrets Manager — AccessDenied cross-account decrypt | PCI-DSS |
| [7](#escenario-7) | E-Commerce | SSM Session Manager vs bastion — acceso operativo sin claves estáticas | — |
| [8](#escenario-8) | Pharma | RAM — compartir recursos entre cuentas sin duplicarlos | GxP |
| [9](#escenario-9) | Insurance | Access Analyzer — findings de acceso externo no intencionado | SOC2 |
| [10](#escenario-10) | Government | Permission boundaries — delegación sin escalada de privilegios | FedRAMP |

---

## Escenario 1

### Fintech: restricción de regiones aprobadas por OU — SCP vs IAM Permission Boundary

Una fintech europea opera bajo PCI-DSS Level 1 con una organización AWS de 12 cuentas. El equipo de arquitectura ha definido que todos los workloads de producción deben desplegarse exclusivamente en `eu-west-1` (Irlanda) por requisitos de residencia de datos. La organización tiene una OU llamada `Workloads` que contiene 9 cuentas de aplicación y una cuenta de Management separada fuera de esa OU.

Durante una revisión de accesos, el equipo de seguridad descubrió que un desarrollador en la cuenta `payments-dev` había creado accidentalmente una instancia RDS en `ap-southeast-1` (Singapur). El desarrollador tenía un IAM Permission Boundary aplicado a su rol con una condición `aws:RequestedRegion` restringida a `eu-west-1`. Sin embargo, la instancia RDS sí se creó. Al investigar, se confirmó que el Permission Boundary estaba correctamente configurado en su rol de IAM, pero la creación del recurso ocurrió a través de una automation pipeline con un **rol de servicio diferente** que no tenía ese boundary.

El equipo de seguridad necesita un control preventivo que sea **imposible de eludir desde dentro de cualquier cuenta miembro**, sin importar qué rol o usuario ejecuta la acción, incluyendo roles de servicio, pipelines de CI/CD, y usuarios con `AdministratorAccess`. Los servicios globales (IAM, CloudFront, Route 53, STS, ACM, WAF global) deben continuar funcionando desde cualquier región.

**Requisitos técnicos**
- Ninguna cuenta en la OU `Workloads` puede crear recursos fuera de `eu-west-1`
- Servicios globales (IAM, CloudFront, Route 53, STS, ACM, WAF) deben seguir funcionando
- La restricción debe aplicarse a TODOS los principals en las cuentas miembro (roles de servicio, roles de CI/CD, usuarios admin)
- La cuenta de Management no debe verse afectada
- No se permiten excepciones a nivel de cuenta individual (no puede ser overrideado por el admin de la cuenta)

**Opciones**

**A)** Crear una SCP en la OU `Workloads` con un `Deny` sobre todas las acciones (`"Action": "*"`), con una condición `StringNotEquals` en `aws:RequestedRegion` con valor `eu-west-1`. Usar `NotAction` para excluir explícitamente los servicios globales (IAM, CloudFront, Route 53, STS, ACM, WAF, Support). La SCP se aplica automáticamente a todas las cuentas miembro de la OU y no puede ser sobreescrita desde dentro de una cuenta.

**B)** Aplicar un IAM Permission Boundary a todos los roles y usuarios en cada cuenta de la OU `Workloads`. El boundary incluye una condición `StringEquals` en `aws:RequestedRegion` restringida a `eu-west-1`. Automatizar la aplicación del boundary con una Lambda que escucha eventos de CloudTrail y aplica el boundary a cualquier rol nuevo creado en esas cuentas.

**C)** Crear una regla de AWS Config llamada `approved-regions` en todas las cuentas de la OU con auto-remediación. Si se detecta un recurso fuera de `eu-west-1`, una SSM Automation lo elimina automáticamente. Configurar Config Aggregator a nivel de organización para visibilidad centralizada.

**D)** Crear una Tag Policy en la OU `Workloads` que requiera el tag `Region=eu-west-1` en todos los recursos. Configurar AWS Config para detectar recursos sin ese tag y notificar al equipo de seguridad. Documentar en el runbook que los desarrolladores deben aplicar el tag correcto.

---

## Escenario 2

### Retail: protección del CloudTrail organizacional contra modificación — SCP vs IAM policy

Una empresa de retail con presencia en 8 países opera 15 cuentas AWS bajo AWS Organizations. Como parte de su programa SOC2 Type II, el equipo de auditoría requiere una **pista de auditoría inmutable**: todos los API calls de todas las cuentas deben estar registrados y esa configuración no puede ser modificada por ningún operador. La empresa tiene un trail organizacional configurado en la cuenta de Management que replica logs a un bucket S3 con Object Lock habilitado.

Durante una revisión de acceso trimestral, se descubrió que un administrador en la cuenta `retail-ops` (que tiene `AdministratorAccess`) ejecutó `aws cloudtrail stop-logging` por error mientras probaba un script de automatización. El trail estuvo inactivo durante 47 minutos, período que quedó sin auditoría. Este evento fue catalogado como un hallazgo crítico de SOC2. El equipo de seguridad propone aplicar una política IAM en cada cuenta que deniegue las acciones de CloudTrail, pero el equipo de gobernanza señala un problema fundamental: si el administrador de la cuenta puede modificar políticas IAM, también puede remover esa política de denegación.

El equipo de arquitectura necesita un control que sea **imposible de remover o circumventer desde dentro de una cuenta miembro**, incluso si el usuario tiene `AdministratorAccess` o acceso root a esa cuenta (excluido el Management Account root).

**Requisitos técnicos**
- Ningún principal en cuentas miembro puede ejecutar `cloudtrail:StopLogging`, `cloudtrail:DeleteTrail`, ni `cloudtrail:UpdateTrail`
- El control se aplica automáticamente a cuentas nuevas que se añadan a la organización
- La cuenta de Management (que administra el org trail) debe quedar excluida
- El control no puede ser removido desde dentro de la cuenta miembro
- Cobertura: todas las cuentas actuales y futuras de la organización

**Opciones**

**A)** Crear una política IAM centralizada con `Deny` explícito en `cloudtrail:StopLogging`, `cloudtrail:DeleteTrail`, `cloudtrail:UpdateTrail`. Adjuntar esta política a todos los roles y grupos IAM en cada cuenta miembro usando CloudFormation StackSets. Crear una Lambda con CloudWatch Events que detecte cuando se crea un rol nuevo y adjunte la política automáticamente.

**B)** Habilitar AWS Config con la regla `cloud-trail-enabled` en todas las cuentas. Configurar una acción de remediación automática que re-habilite el CloudTrail si la regla detecta que está desactivado. El SLA de remediación es de < 5 minutos.

**C)** Crear una SCP a nivel Root de la organización con `Deny` en `cloudtrail:StopLogging`, `cloudtrail:DeleteTrail`, `cloudtrail:UpdateTrail`. No incluir ningún `Condition` ni `Principal` que limite el alcance — el Deny afecta a todos los principals en todas las cuentas miembro. La cuenta de Management no está afectada por SCPs aplicadas a la organización (las SCPs no se aplican a la Management Account).

**D)** Habilitar CloudTrail log file validation en el trail organizacional y configurar S3 Object Lock con modo COMPLIANCE en el bucket de destino. Si alguien intenta eliminar o modificar un log file, Object Lock lo bloquea. Habilitar MFA Delete en el bucket para una capa adicional de protección.

---

## Escenario 3

### Healthcare: centralización de acceso multi-cuenta — Identity Center vs IAM Users

Una red hospitalaria opera bajo HIPAA con 8 cuentas AWS: 1 cuenta de Management y 7 cuentas de workload (producción, staging, desarrollo, analytics, seguridad, backup, shared-services). El equipo de ingeniería tiene 45 personas con diferentes niveles de acceso según su rol: los DevOps engineers necesitan acceso de `PowerUser` a dev y read-only a producción, los arquitectos necesitan acceso amplio en múltiples cuentas, y los analistas solo necesitan acceso a la cuenta de analytics.

La situación actual: se crearon IAM users individuales en cada cuenta necesaria — en total, el equipo gestiona **360 IAM users** (45 engineers × 8 cuentas). Un hallazgo de auditoría HIPAA identificó que **12 ex-empleados** aún tienen IAM users activos en entre 2 y 5 cuentas cada uno — uno de ellos con acceso a la cuenta de producción. El proceso de offboarding requería revocar manualmente el acceso en cada cuenta, y en estos casos el proceso no se completó.

El CISO exige una solución donde **dar de baja a un usuario bloquee su acceso a TODAS las cuentas simultáneamente**. La empresa no tiene un proveedor de identidad corporativo (no hay Active Directory, no hay Okta). Quiere una solución nativa de AWS que no requiera infraestructura adicional. La solución debe eliminar las access keys estáticas y usar credenciales temporales para todo acceso, tanto a consola como a CLI.

**Requisitos técnicos**
- Un único punto de gestión de usuarios: eliminar un usuario bloquea acceso a todas las cuentas
- Diferentes niveles de permisos por cuenta y por rol (no todos ven lo mismo en todas las cuentas)
- Sin credenciales estáticas de larga duración (no access keys permanentes)
- MFA obligatorio para acceso a consola
- Audit log de cada sesión: quién accedió a qué cuenta, cuándo, desde dónde
- Sin necesidad de IdP externo (solución 100% AWS-native)

**Opciones**

**A)** Crear IAM users en la cuenta de Management con `AdministratorAccess`. Crear IAM roles en cada cuenta workload con trust policy que permita `sts:AssumeRole` desde la cuenta de Management. Los engineers hacen switch-role desde su IAM user de Management a los roles en las cuentas de destino. El proceso de offboarding solo requiere desactivar el IAM user en Management.

**B)** Habilitar IAM Identity Center en la organización. Crear usuarios en el Identity Store nativo de IAM Identity Center (sin IdP externo). Crear Permission Sets que representan los niveles de acceso (PowerUser, ReadOnly, AnalyticsAccess). Crear Account Assignments que mapean usuario → Permission Set → cuenta. Los engineers acceden vía el portal de acceso de Identity Center con credenciales temporales. Deshabilitar un usuario en Identity Center revoca acceso a todas las cuentas.

**C)** Desplegar AWS Directory Service Managed Microsoft AD en la cuenta de Management. Configurar SAML federation entre el Managed AD y cada una de las 8 cuentas individualmente. Los engineers se autentican con sus credenciales de AD y son redirigidos al rol IAM correspondiente via SAML. La gestión central de AD permite revocar acceso desde un único punto.

**D)** Contratar AWS SSO (el servicio legacy anterior a IAM Identity Center). Crear los 45 usuarios en SSO y asignarlos a las cuentas. AWS SSO gestiona la federación automáticamente. Al deshabilitar un usuario en SSO se revoca el acceso inmediatamente a todas las cuentas.

---

## Escenario 4

### Media: CloudTrail vs Config — auditoría de eventos vs compliance de estado

Una empresa de medios digitales opera bajo SOC2 Type II con 6 cuentas AWS. El equipo de seguridad gestiona varios tipos de alertas relacionadas con S3 y necesita entender qué herramienta responde a cada tipo de pregunta. En la última semana recibieron tres alertas distintas que generaron confusión sobre qué servicio debían consultar para investigar cada una:

**Alerta 1:** A las 14:32 UTC del martes, un bucket S3 llamado `media-assets-prod` fue configurado como público. El equipo necesita saber: ¿qué usuario o rol ejecutó la acción?, ¿desde qué IP?, ¿en qué momento exacto?

**Alerta 2:** El equipo de compliance necesita un inventario actualizado: ¿cuáles son los buckets S3 en este momento que tienen acceso público habilitado, en las 6 cuentas?

**Alerta 3:** Para el reporte SOC2, el auditor solicita: ¿cuántas veces cambió la configuración de acceso público de cualquier bucket S3 en los últimos 90 días, y cuál era el estado antes y después de cada cambio?

El equipo tiene un CloudTrail org-level trail activo (configurado en la cuenta de Management) que ya cubre las 6 cuentas. No tienen AWS Config habilitado actualmente. El equipo debate si Config es necesario o si CloudTrail puede responder todas las preguntas.

**Requisitos técnicos**
- Cobertura multi-cuenta: las 6 cuentas deben estar cubiertas
- Mínimo overhead operacional: no quieren gestionar configuraciones per-account
- Necesitan responder los tres tipos de preguntas: quién hizo qué, estado actual, historial de cambios

**Opciones**

**A)** CloudTrail responde las tres alertas. Para la Alerta 1: buscar el evento `PutBucketAcl` o `PutBucketPublicAccessBlock` en CloudTrail. Para la Alerta 2: buscar todos los eventos de modificación de ACL de S3 en el último período y filtrar los que pusieron acceso público. Para la Alerta 3: CloudTrail mantiene historial de 90 días de todos los API calls, incluyendo los cambios de configuración de S3.

**B)** AWS Config responde las tres alertas. Config registra quién hizo los cambios de configuración (tiene integración con CloudTrail para capturar el initiator), el estado actual de compliance de cada bucket (Alerta 2), y el historial completo de cambios de configuración en 90 días (Alerta 3). CloudTrail es redundante si se tiene Config.

**C)** Amazon GuardDuty responde la Alerta 1 porque detecta comportamiento anómalo incluyendo accesos no autorizados a S3. AWS Config responde las Alertas 2 y 3. CloudTrail no es necesario si GuardDuty y Config están habilitados porque juntos cubren todos los casos de uso de seguridad.

**D)** CloudTrail responde la Alerta 1 (quién/cuándo/IP = auditoría de llamadas a la API). AWS Config responde la Alerta 2 (estado actual = snapshot de compliance) y la Alerta 3 (historial de configuración = configuration history de cada recurso). Ambos servicios son necesarios y complementarios. Habilitar Config con un Config Aggregator a nivel de organización para cubrir las 6 cuentas sin configuración manual por cuenta.

---

## Escenario 5

### SaaS Enterprise: Control Tower vs Organizations manual — baseline governance

Una startup de SaaS B2B ha crecido de 2 a 12 cuentas AWS en 6 meses. El CTO proyecta llegar a 25 cuentas en los próximos 12 meses a medida que el equipo de producto crea nuevos entornos aislados por cliente enterprise. El equipo de plataforma (3 personas) actualmente provisiona cuentas nuevas manualmente: crean la cuenta, configuran CloudTrail, aplican SCPs de seguridad básica, habilitan GuardDuty, y crean los roles de acceso. Este proceso toma entre 4 y 6 horas por cuenta y ha producido inconsistencias — no todas las cuentas tienen el mismo baseline.

El CISO ha definido que **cada cuenta nueva debe tener obligatoriamente** desde el momento de su creación: CloudTrail org-level habilitado, S3 Block Public Access activado por defecto, GuardDuty habilitado, MFA requerida para root, una cuenta de Log Archive dedicada para centralizar logs, y una cuenta de Audit dedicada para acceso de seguridad. Los product managers quieren poder crear cuentas nuevas por su cuenta (self-service) sin depender del equipo de plataforma.

El equipo de ingeniería debate dos opciones: implementar AWS Control Tower vs construir la solución manualmente con Organizations + SCPs + Config + StackSets. El argumento en contra de Control Tower es que "hace demasiada magia" y el equipo quiere control total sobre cada componente.

**Requisitos técnicos**
- Baseline de seguridad aplicado automáticamente a cada cuenta nueva
- Cuentas de Log Archive y Audit creadas automáticamente (no manualmente)
- Self-service account vending: los product managers pueden crear cuentas sin intervención del equipo de plataforma
- Guardrails preventivos (que bloqueen) y detectivos (que alerten) sobre las cuentas
- Escalable a 25+ cuentas sin aumento proporcional de overhead operacional

**Opciones**

**A)** Implementar la solución manualmente con AWS Organizations + SCPs + CloudFormation StackSets + AWS Config. El equipo tiene control total sobre cada componente. Crear un runbook detallado para el provisioning de cuentas. Las SCPs se gestionan manualmente en el Root de la organización. StackSets despliegan la baseline a cada cuenta nueva. Requiere que el equipo de plataforma intervenga en cada provisioning.

**B)** Usar CloudFormation StackSets con un Stack de baseline que se despliegue automáticamente mediante EventBridge cuando se detecta una nueva cuenta. El Stack crea CloudTrail, habilita GuardDuty, configura los roles de acceso, y aplica las políticas necesarias. Los product managers pueden iniciar el proceso creando la cuenta, y el Stack se despliega automáticamente 10 minutos después.

**C)** Usar AWS Service Catalog con un producto de "Nueva Cuenta AWS". Los product managers navegan al Service Catalog, lanzan el producto "Cuenta AWS Baseline", ingresan el nombre y propósito de la cuenta, y Service Catalog ejecuta un Step Functions workflow que crea la cuenta y aplica la baseline. Requiere que el equipo de plataforma mantenga el producto de Service Catalog.

**D)** Implementar AWS Control Tower. Control Tower crea automáticamente las cuentas de Log Archive y Audit. Aplica guardrails preventivos (SCPs) y detectivos (Config Rules) automáticamente a cada OU. Account Factory permite que los product managers creen cuentas nuevas via un formulario self-service. El baseline completo se aplica automáticamente a cada cuenta nueva sin intervención del equipo de plataforma. Los componentes individuales (SCPs, Config Rules, CloudTrail) son visibles y auditables aunque gestionados por Control Tower.

---

## Escenario 6

### Banking: KMS cross-account AccessDenied — doble autorización requerida

Un banco opera bajo PCI-DSS con una arquitectura multi-cuenta: una cuenta de Security (donde el equipo de criptografía gestiona todas las claves KMS) y múltiples cuentas de Aplicación. Esta separación garantiza que los equipos de aplicación no pueden modificar ni eliminar las claves de cifrado. El equipo de Security creó una **Customer Managed Key (CMK)** en la cuenta de Security para cifrar credenciales de bases de datos.

El equipo de App almacenó las credenciales de conexión a la base de datos en **AWS Secrets Manager** en la cuenta de App, usando la CMK cross-account de Security como clave de cifrado (especificando el ARN completo de la CMK al crear el secret). La instancia EC2 en la cuenta de App tiene un **IAM Role** con la siguiente política:

```json
{
  "Effect": "Allow",
  "Action": ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"],
  "Resource": "arn:aws:secretsmanager:eu-west-1:APP_ACCOUNT_ID:secret:db-credentials-*"
}
```

Cuando la aplicación llama a `GetSecretValue`, Secrets Manager devuelve el secret pero para descifrarlo llama a KMS. El resultado es un error: `AccessDenied` en la operación `kms:Decrypt`. El equipo de App confirma que el IAM Role tiene los permisos de Secrets Manager correctos. El equipo de Security confirma que la CMK existe y está activa. Nadie entiende por qué falla.

**Requisitos técnicos**
- La instancia EC2 en App account debe poder leer el secret
- La CMK debe permanecer en la cuenta de Security (no moverla)
- Principio de mínimo privilegio: no usar wildcards como `kms:*`
- Sin cambios en la estructura base de la Key Policy de KMS (no eliminar la sección de administración de claves)

**Opciones**

**A)** Añadir `kms:Decrypt` al IAM Role policy del EC2 en la cuenta de App, apuntando al ARN completo de la CMK en la cuenta de Security:
```json
{"Effect": "Allow", "Action": "kms:Decrypt", "Resource": "arn:aws:kms:eu-west-1:SECURITY_ACCOUNT_ID:key/KEY_ID"}
```
Esto es suficiente — una vez que el IAM Role tiene permiso explícito para `kms:Decrypt`, KMS lo autoriza.

**B)** Mover la CMK de la cuenta de Security a la cuenta de App. Recrear el secret en Secrets Manager apuntando a la nueva CMK local. Aunque pierde la separación de cuentas, elimina la complejidad del acceso cross-account y resuelve el `AccessDenied` inmediatamente.

**C)** Reemplazar la CMK por la **AWS managed key** de Secrets Manager (`aws/secretsmanager`). Las AWS managed keys son gestionadas por AWS y automáticamente permiten acceso cross-account cuando Secrets Manager las usa. No requiere configuración adicional de Key Policy.

**D)** El acceso cross-account a KMS requiere autorización en **ambos lados**: (1) El **IAM Role en la cuenta de App** debe tener `kms:Decrypt` sobre el ARN de la CMK en Security, Y (2) la **Key Policy de la CMK en la cuenta de Security** debe incluir el principal de la cuenta de App (el ARN del IAM Role o `arn:aws:iam::APP_ACCOUNT_ID:root`) con permiso para `kms:Decrypt`. Sin ambas condiciones, KMS rechaza la solicitud. Solo con la opción A (IAM policy en App) no es suficiente porque KMS también requiere que la Key Policy lo autorice explícitamente.

---

## Escenario 7

### E-Commerce: acceso operativo sin bastion ni claves estáticas — SSM Session Manager

Una plataforma de e-commerce procesa 50.000 pedidos diarios en una flota de 80 instancias EC2 en subnets privadas (sin Internet Gateway en la tabla de rutas de esa subnet). Actualmente el equipo de operaciones accede a las instancias vía un **bastion host** en una subnet pública con SSH en el puerto 22. Hay 5 ingenieros que comparten los mismos SSH keypairs, lo que significa que los logs de las instancias muestran el usuario `ec2-user` para todas las sesiones sin indicar qué ingeniero accedió.

Un ingeniero dejó la empresa hace 3 semanas. El equipo no está seguro si revocó el acceso correctamente — los keypairs eran compartidos y almacenados en un repositorio interno. Más allá de este caso puntual, el equipo de seguridad identificó en la auditoría de PCI-DSS varios hallazgos: (1) el puerto 22 está abierto desde `0.0.0.0/0` en el security group del bastion, (2) no existe trazabilidad individual de las sesiones, (3) las SSH keys son credenciales estáticas de larga duración, (4) no hay grabación de sesiones. PCI-DSS Requirement 8 exige identificación individual de cada usuario que accede a sistemas con datos de tarjeta.

**Requisitos técnicos**
- Eliminación completa del bastion host y del puerto SSH
- Cada sesión debe ser atribuible a un usuario individual (identidad IAM)
- Grabación completa de sesiones en S3 y/o CloudWatch Logs
- Sin inbound rules necesarias en el Security Group de las instancias EC2
- Funciona para instancias en subnets privadas sin acceso a internet
- Sin credenciales estáticas (sin SSH keys, sin passwords)

**Opciones**

**A)** Mantener el bastion host pero reemplazar SSH keypairs por **EC2 Instance Connect**. Instance Connect permite acceso SSH sin keypairs permanentes — genera un par de claves temporal por sesión y lo invalida después de 60 segundos. La identidad IAM del usuario queda en CloudTrail cuando llama a `ec2-instance-connect:SendSSHPublicKey`. Eliminar el acceso desde `0.0.0.0/0` y restringir el security group solo a la IP del bastion.

**B)** Usar **SSM Session Manager** habilitando acceso a internet desde las instancias EC2 (añadir una NAT Gateway a la subnet privada). El agente SSM en la instancia se conecta a los endpoints regionales de SSM vía HTTPS. No se necesita abrir el puerto 22, pero sí se necesita que las instancias tengan salida a internet para llegar a `ssm.eu-west-1.amazonaws.com`.

**C)** Usar **SSM Session Manager** con **VPC Endpoints** para los servicios `com.amazonaws.eu-west-1.ssm`, `com.amazonaws.eu-west-1.ssmmessages`, y `com.amazonaws.eu-west-1.ec2messages`. Con estos endpoints, el agente SSM en la instancia se comunica con SSM a través de la red privada de AWS sin salir a internet. No se necesita puerto 22 ni inbound rules. Las sesiones se autentican con IAM Identity Center. Los logs de sesión se envían a S3 y CloudWatch Logs. Se puede configurar grabación completa de la sesión (keystrokes + output).

**D)** Usar **AWS CloudShell** para conectarse a las instancias privadas. CloudShell es una shell gestionada por AWS con credenciales de IAM preconfiguradas. Desde CloudShell se puede ejecutar AWS CLI y acceder a recursos dentro de la VPC sin necesidad de un bastion host externo.

---

## Escenario 8

### Pharma: compartir recursos entre cuentas — RAM vs duplicación

Una empresa farmacéutica opera bajo regulación GxP (Good Practice) con 4 cuentas AWS organizadas en una jerarquía: Shared Services, Dev, Staging y Prod. La cuenta de Shared Services contiene tres recursos críticos que actualmente se duplican en cada cuenta:

1. **Transit Gateway**: cada cuenta (Dev, Staging, Prod) tiene su propio TGW con su propio conjunto de attachments. Costo mensual: $0.05/hora por TGW × 3 cuentas + $0.05/hora por attachment × (4 attachments × 3 cuentas) = $108/mes solo en TGW overhead.

2. **AMI de security scanner licenciada**: un escáner de vulnerabilidades de un vendor tercero con licencia por instancia-hora. Actualmente hay 3 copias de la AMI (una por cuenta de workload) y cada copia genera cargos de licencia independientes. Una sola AMI compartida reduciría los cargos de licencia en un 66%.

3. **Route 53 Resolver rules**: reglas de resolución DNS privadas para el dominio corporativo `corp.pharma.internal`. Actualmente cada cuenta tiene sus propios Resolver endpoints y rules duplicadas, añadiendo latencia y costo.

El equipo de arquitectura propone centralizar estos recursos en Shared Services y compartirlos con las cuentas workload. GxP requiere que cada recurso tenga un único propietario identificable y un audit trail de uso.

**Requisitos técnicos**
- Los recursos permanecen en la cuenta de Shared Services (propietario único)
- Las cuentas Dev, Staging y Prod pueden usar los recursos como si fueran propios
- El sharing debe ocurrir dentro de la misma AWS Organization (no sharing externo)
- Reducción de costos sin sacrificar aislamiento entre entornos

**Opciones**

**A)** Desplegar el TGW y una copia de la AMI en cada cuenta. Comprar una licencia de AMI por cuenta en AWS Marketplace. Configurar Route 53 Resolver outbound endpoints independientes por cuenta. Mantiene el aislamiento completo entre entornos a costa de duplicar recursos y costos.

**B)** Usar **VPC Peering** entre la cuenta de Shared Services y cada cuenta workload para el acceso al TGW. Compartir la AMI manualmente con `ec2:ModifyImageAttribute --launch-permission` para dar acceso a las otras cuentas. Configurar Resolver forwarding rules en cada cuenta apuntando a los endpoints de Shared Services.

**C)** Usar **CloudFormation StackSets** para desplegar resources idénticos en cada cuenta desde una plantilla central. Los recursos se crean en cada cuenta pero se gestionan centralmente desde Shared Services. Si hay un cambio en la configuración, StackSets lo propaga a todas las cuentas automáticamente.

**D)** Usar **AWS Resource Access Manager (RAM)** para compartir el Transit Gateway, la AMI, y las Route 53 Resolver rules desde la cuenta de Shared Services con las cuentas Dev, Staging y Prod (o con la AWS Organization completa). RAM permite que los recursos permanezcan en la cuenta propietaria mientras otras cuentas los usan directamente. No se crea una copia del recurso — es el mismo recurso. Las cuentas workload ven los recursos compartidos como si fueran de su propia cuenta. El propietario (Shared Services) mantiene el control total y el audit trail de uso está en CloudTrail.

---

## Escenario 9

### Insurance: detección continua de acceso externo no intencionado — Access Analyzer

Una aseguradora opera bajo SOC2 Type II con una política de seguridad clara: todos los recursos AWS deben ser privados excepto aquellos explícitamente aprobados por el comité de seguridad. La última auditoría trimestral (realizada manualmente por el equipo de seguridad con scripts de AWS CLI) encontró los siguientes hallazgos en sus 5 cuentas:

- 3 buckets S3 con resource-based policies que otorgan acceso a cuentas AWS externas (fuera de la organización)
- 1 IAM role con una trust policy que permite `sts:AssumeRole` desde una cuenta AWS desconocida (probablemente un PoC olvidado de hace 8 meses)
- 1 KMS Customer Managed Key con una key policy que permite `kms:Decrypt` a una cuenta de un proveedor tercero que ya no tiene contrato

Ninguno de estos accesos externos estaba documentado como aprobado. El equipo de seguridad tardó 3 semanas en completar la revisión manual. Necesitan una solución que detecte este tipo de acceso en tiempo real (o near-real-time), no solo trimestralmente.

**Requisitos técnicos**
- Monitoreo continuo de resource-based policies en S3, IAM roles, KMS keys, SQS, Lambda, Secrets Manager
- Capacidad de marcar accesos externos como "aprobados" (expected) para distinguirlos de hallazgos no intencionados
- Cobertura de todas las cuentas de la organización desde un único punto de gestión
- Alertas automáticas cuando aparece un nuevo hallazgo de acceso externo

**Opciones**

**A)** Crear reglas de AWS Config: `s3-bucket-public-read-prohibited`, `iam-no-inline-policy-check`, y `kms-cmk-not-scheduled-for-deletion` en todas las cuentas. Configurar Config Aggregator a nivel de organización para visibilidad central. Las reglas evalúan compliance periódicamente y alertan via SNS.

**B)** Usar **Amazon Macie** para escanear continuamente los buckets S3 en busca de datos sensibles y políticas de acceso incorrectas. Macie identifica buckets con acceso público y genera hallazgos de seguridad. Integrar con EventBridge para alertas automáticas.

**C)** Habilitar **AWS Security Hub** con el estándar AWS Foundational Security Best Practices (FSBP) en todas las cuentas. Security Hub agrega hallazgos de múltiples servicios (GuardDuty, Inspector, Macie) y proporciona una puntuación de seguridad. Configurar un Security Hub delegated administrator en la cuenta de Management para visibilidad multi-cuenta.

**D)** Habilitar **AWS IAM Access Analyzer** con un **Organization Analyzer** (configurado en la cuenta de Management o en la cuenta de Security delegada). Access Analyzer analiza continuamente las resource-based policies de S3 buckets, IAM roles, KMS keys, SQS queues, Lambda functions, y Secrets Manager secrets. Genera **findings** para cualquier recurso accesible desde fuera de la zona de confianza (la organización). Los findings aprobados se archivan para distinguirlos de nuevos hallazgos no intencionados. Integrar con EventBridge para alertas automáticas cuando se crea un nuevo finding.

---

## Escenario 10

### Government: delegación de privilegios sin escalada — Permission Boundaries

Una agencia gubernamental opera bajo FedRAMP Moderate con un equipo de Plataforma central que controla las cuentas AWS. Los equipos de Aplicación (3 equipos de 8 personas cada uno) necesitan crear sus propios IAM roles para sus Lambda functions, EC2 instances y ECS tasks. Sin embargo, el equipo de Plataforma tiene una preocupación de seguridad crítica: si un desarrollador de Aplicación puede crear IAM roles, podría crear un rol con `AdministratorAccess` o `iam:*` y usarlo para escalar sus propios privilegios.

La solución actual: el equipo de Plataforma crea manualmente todos los IAM roles a petición de los equipos de Aplicación. Esto crea un cuello de botella — el equipo de Plataforma recibe 15-20 solicitudes de nuevos roles por semana y el SLA de respuesta es de 2-3 días hábiles. Los equipos de Aplicación están bloqueados mientras esperan sus roles.

El equipo de Plataforma quiere delegar la creación de roles IAM a los equipos de Aplicación con una **restricción técnica aplicada** que les impida crear roles con más permisos de los que ellos mismos tienen. Las SCPs no son la solución correcta aquí porque el problema es granular a nivel de equipo/desarrollador dentro de la misma cuenta, no a nivel de cuenta.

**Requisitos técnicos**
- Los developers de Aplicación pueden crear IAM roles para sus workloads
- Los roles creados no pueden tener permisos superiores a un límite predefinido (no IAM admin, no billing, no Organizations)
- Si un developer intenta crear un rol SIN adjuntar el boundary requerido, la acción debe ser denegada
- La restricción debe ser técnicamente aplicable (no depender de procesos manuales o revisiones)
- El equipo de Plataforma controla qué permisos puede otorgar un developer (definiendo el boundary)

**Opciones**

**A)** Crear una SCP en la organización que deniegue la creación de IAM roles con `AdministratorAccess` o `PowerUserAccess` como managed policies. La SCP previene que ninguna cuenta pueda crear roles con esas políticas específicas adjuntas.

**B)** Revocar todos los permisos IAM de los equipos de Aplicación. El equipo de Plataforma mantiene un formulario de solicitud de roles con un SLA de 1 día hábil (mejorando el actual de 2-3 días). Los equipos de Aplicación documentan sus necesidades y Plataforma las implementa.

**C)** Crear una **Permission Boundary policy** (`AppTeamBoundary`) que define el máximo de permisos que un rol creado por un developer puede tener (excluye `iam:*`, `organizations:*`, `billing:*`). En la IAM policy de los developers, añadir una condición `iam:PermissionsBoundary` que requiere que cualquier llamada a `iam:CreateRole` o `iam:PutRolePolicy` incluya `PermissionsBoundary=arn:aws:iam::ACCOUNT_ID:policy/AppTeamBoundary`. También aplicar `AppTeamBoundary` como boundary a los propios developers para que no puedan escalar sus privilegios. Si intentan crear un rol sin boundary, la acción se deniega.

**D)** Igual que la opción C, pero sin aplicar el boundary a los propios developers — solo a los roles que crean. Sin el boundary en los developers mismos, ellos podrían crear un rol con el boundary requerido pero luego modificar el boundary policy para expandir los permisos. La ausencia del boundary en los developers es la diferencia clave que hace ineficaz esta opción.
