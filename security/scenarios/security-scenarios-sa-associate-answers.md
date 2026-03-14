# Security & Governance — Respuestas SAA-C03

> Respuestas a: [security-scenarios-sa-associate.md](./security-scenarios-sa-associate.md)
> **No abrir hasta haber respondido cada escenario.**

---

## Escenario 1 — Fintech: SCP/OU restricción de regiones

**Respuesta correcta: A**

Las Service Control Policies (SCPs) son controles preventivos a nivel de organización. Cuando una SCP se aplica a una OU, afecta a **todos los principals** en todas las cuentas miembro de esa OU — sin excepciones. Esto incluye roles de servicio, pipelines de CI/CD, roles con `AdministratorAccess` e incluso el usuario root de la cuenta miembro (el root de las cuentas miembro, no el Management Account root). Ningún actor dentro de la cuenta puede sobreescribir una SCP porque las SCPs se aplican por encima de los permisos IAM: la evaluación de políticas en AWS requiere que tanto la SCP **como** la política IAM permitan la acción.

La estrategia correcta para restricción de regiones es un `Deny` con `StringNotEquals` en `aws:RequestedRegion` combinado con un `NotAction` que excluye los servicios globales. Los servicios globales como IAM, CloudFront, Route 53, STS, ACM (cuando se usa con CloudFront) y WAF no están vinculados a una región — sus API calls van siempre a `us-east-1` independientemente de dónde opere el recurso. Sin excluirlos, la SCP rompe funcionalidades fundamentales de la organización.

El patrón de la SCP correcta es:
```json
{
  "Effect": "Deny",
  "NotAction": ["iam:*", "cloudfront:*", "route53:*", "sts:*", "acm:*", "waf:*", "support:*"],
  "Resource": "*",
  "Condition": {
    "StringNotEquals": {"aws:RequestedRegion": "eu-west-1"}
  }
}
```

**Por qué cada incorrecta falla en producción**

- **B — IAM Permission Boundary:** Los boundaries solo se aplican a los IAM principals (roles y usuarios) a los que están adjuntos. Un rol de servicio sin el boundary no está restringido. Además, si un developer con `iam:CreateRole` crea un nuevo rol, ese rol no hereda automáticamente el boundary — necesitaría una Lambda adicional (que también podría tener un rol sin boundary). Es una defensa en profundidad válida pero no un control preventivo universal. No puede bloquear todos los principals como lo hace una SCP.

- **C — AWS Config auto-remediation:** Config es un control **detectivo**, no **preventivo**. Entre el momento en que se crea el recurso y el momento en que Config lo detecta y la remediación lo elimina, el recurso ha existido (y potencialmente ha procesado datos). Para PCI-DSS, un RDS con datos de tarjeta creado en la región incorrecta es un hallazgo crítico incluso si se elimina en 5 minutos. Además, no todos los recursos pueden eliminarse automáticamente sin impacto en servicios existentes.

- **D — Tag Policy:** Las Tag Policies controlan el formato y valores de tags, pero **no deniegan la creación de recursos sin el tag**. Son controles de gobernanza de etiquetado, no de seguridad. Un developer puede crear un recurso en cualquier región con o sin el tag.

> **Exam tip:** Cuando el enunciado dice "imposible de eludir desde dentro de una cuenta miembro" o "incluso con AdministratorAccess", la respuesta siempre involucra SCPs. Las SCPs son el único mecanismo de AWS que opera por encima de los permisos IAM de una cuenta.

---

## Escenario 2 — Retail: protección de CloudTrail

**Respuesta correcta: C**

Las SCPs aplicadas a nivel **Root** de la organización se aplican automáticamente a **todas las cuentas miembro** actuales y futuras. La clave está en el comportamiento de las SCPs con la Management Account: las SCPs nunca se aplican a la Management Account, lo que significa que el equipo de gobernanza que administra el org trail (desde Management) no se ve afectado. Para las cuentas miembro, la SCP hace que `cloudtrail:StopLogging`, `cloudtrail:DeleteTrail` y `cloudtrail:UpdateTrail` sean denegadas a **todo principal** sin excepción — incluyendo roles con `AdministratorAccess`.

El mecanismo de defensa es preciso: no hay condición que permita excepciones, no hay `Principal` que limite el alcance, y no hay forma de que un administrador de cuenta miembro modifique o elimine la SCP (solo el Management Account puede modificar SCPs). Las nuevas cuentas añadidas a la organización heredan automáticamente las SCPs del Root.

**Por qué cada incorrecta falla en producción**

- **A — IAM policy centralizada con StackSets:** El problema fundamental es que un IAM user o role con `AdministratorAccess` puede modificar las políticas IAM adjuntas a sus propios roles o puede crear un nuevo rol sin esa política y usarlo para ejecutar las acciones prohibidas. Si el admin puede modificar políticas IAM, puede remover la restricción. Las StackSets tampoco son instantáneas — hay un delay entre la creación de un rol nuevo y la aplicación de la política de denegación por la Lambda.

- **B — AWS Config con auto-remediation:** Mismo problema que en el Escenario 1: Config es **detectivo**. Si CloudTrail se detiene durante 5 minutos mientras Config detecta la desviación y ejecuta la remediación, esos 5 minutos quedan sin auditoría — exactamente el hallazgo SOC2 que el equipo quiere evitar. Para SOC2 Type II, los gaps en el audit trail son hallazgos críticos.

- **D — CloudTrail log file validation + S3 Object Lock:** Estas medidas protegen la **integridad de los logs ya generados** — si alguien intenta modificar o eliminar un archivo de log en S3, Object Lock lo bloquea. Pero no impiden que CloudTrail sea detenido. Si el trail se detiene, no se generan nuevos logs. Object Lock no aplica a logs que nunca existieron. Es una capa de defensa válida y complementaria, pero no reemplaza el control preventivo que impide detener el trail en primer lugar.

> **Exam tip:** CloudTrail log file validation + S3 Object Lock protege los logs **ya guardados**. Una SCP protege el **trail activo**. Son capas complementarias, no sustitutos. En el examen, distingue entre "proteger la configuración" (SCP) y "proteger los datos generados" (Object Lock).

---

## Escenario 3 — Healthcare: IAM Identity Center vs IAM Users

**Respuesta correcta: B**

AWS IAM Identity Center (antes AWS SSO) es el servicio diseñado específicamente para este caso de uso: gestión centralizada de acceso humano a múltiples cuentas AWS. El flujo es: (1) crear usuarios en el **Identity Store** nativo de Identity Center (no se necesita IdP externo), (2) crear **Permission Sets** que encapsulan los permisos (equivalentes a los roles IAM que los usuarios asumirán), (3) crear **Account Assignments** que mapean `usuario + Permission Set → cuenta`. El portal de acceso de Identity Center genera **credenciales temporales** (STS tokens) por sesión — no hay access keys estáticas de larga duración. Cuando un usuario es deshabilitado en Identity Center, sus credenciales activas expiran y no puede obtener nuevas — el acceso a todas las cuentas se revoca en minutos.

HIPAA se beneficia de este modelo porque: (a) el audit trail en CloudTrail muestra la identidad del usuario de Identity Center (no un role genérico), (b) no hay credenciales estáticas que puedan filtrarse, y (c) el proceso de offboarding es atómico — una sola acción cubre todas las cuentas.

**Por qué cada incorrecta falla en producción**

- **A — IAM users en Management + cross-account roles:** Simplifica el offboarding (desactivar en un lugar) pero no elimina las credenciales estáticas — los usuarios siguen teniendo access keys del IAM user en Management. El acceso CLI requeriría keys de larga duración o procesos adicionales. Además, la auditabilidad es limitada: CloudTrail en las cuentas destino muestra el role asumido, no el IAM user de Management, dificultando la atribución individual en los logs de la cuenta workload.

- **C — AWS Directory Service Managed Microsoft AD + SAML federation por cuenta:** Requiere configurar SAML federation individualmente en cada una de las 8 cuentas — hay que crear el Identity Provider IAM en cada cuenta y mantener los metadatos SAML sincronizados. Es operacionalmente costoso y propenso a errores. Managed Microsoft AD tiene un costo de ~$288/mes solo por la infraestructura del directorio. El problema señalado de "empresa sin IdP existente" se resuelve con Directory Service, pero agrega una capa de infraestructura que gestionar.

- **D — AWS SSO (legacy):** IAM Identity Center **es** AWS SSO — fue renombrado en 2022. No existe como servicio separado. Esta opción es un distractor que intenta confundir al candidato con terminología obsoleta.

> **Exam tip:** En escenarios con "acceso multi-cuenta + equipo de personas + credenciales temporales + un solo lugar de gestión", la respuesta es siempre **IAM Identity Center**. Recuerda: Identity Center = SSO renombrado. Permission Sets → temporary credentials via STS. Un usuario deshabilitado pierde acceso a todas las cuentas.

---

## Escenario 4 — Media: CloudTrail vs Config

**Respuesta correcta: D**

CloudTrail y AWS Config son servicios complementarios que responden preguntas fundamentalmente distintas y no se puede prescindir de ninguno:

**CloudTrail** registra **llamadas a la API** — eventos: quién (identidad), qué acción, cuándo, desde dónde (IP). Es un log de actividad. Puede responder "¿qué API call modificó este bucket a las 14:32?" pero **no puede** responder "¿qué buckets están actualmente configurados como públicos?" porque CloudTrail no tiene un modelo del estado actual de los recursos — solo tiene el historial de eventos.

**AWS Config** mantiene un **inventario continuo del estado de configuración** de cada recurso. Puede responder "¿qué buckets tienen `BlockPublicAccess` deshabilitado ahora mismo?" (Alerta 2) y "¿cuántas veces cambió esta configuración en 90 días?" (Alerta 3 — a través del configuration history). Config no registra la identidad del ejecutor de forma directa, pero correlaciona con CloudTrail para reconstruir el "quién".

El Config Aggregator a nivel de organización cubre automáticamente todas las cuentas sin configuración manual por cuenta — un Config Aggregator en la cuenta de Management o de Security recibe datos de las 6 cuentas workload.

**Por qué cada incorrecta falla en producción**

- **A — Solo CloudTrail para las 3 alertas:** CloudTrail puede responder quién hizo el cambio (Alerta 1), pero no puede responder qué recursos están actualmente en un estado específico (Alerta 2). Buscar en CloudTrail eventos de modificación de ACL y filtrar los que pusieron acceso público sería una consulta enormemente compleja que requeriría Athena, y aun así no daría el estado actual porque podría haberse revertido el cambio después.

- **B — Solo Config para las 3 alertas:** Config correlaciona cambios de configuración con los API calls de CloudTrail, pero la información de "quién" y la IP de origen vive en CloudTrail, no en Config. Config sabe que hubo un cambio y a qué hora, pero para el detalle completo de la Alerta 1 (IP, user agent, parámetros exactos del API call) se necesita CloudTrail.

- **C — GuardDuty para Alerta 1:** GuardDuty detecta **comportamiento anómalo y amenazas** (como acceso inusual desde una IP sospechosa o exfiltración de datos). No genera alertas de "este bucket fue hecho público a las 14:32 por este usuario". GuardDuty podría generar una alerta si el acceso a un bucket público fuera anómalo en términos de volumen, pero no es la herramienta para auditoría de cambios de configuración.

> **Exam tip:** Memoriza la distinción: **CloudTrail = quién/cuándo/qué-acción** (log de eventos de API). **Config = estado-actual + historial-de-configuración** (inventario de recursos). Pregunta en el examen: "¿está el recurso en compliance AHORA?" → Config. "¿quién hizo el cambio?" → CloudTrail.

---

## Escenario 5 — SaaS Enterprise: Control Tower vs Organizations manual

**Respuesta correcta: D**

AWS Control Tower es el servicio de AWS diseñado específicamente para este problema: establecer y mantener un baseline de seguridad en una organización multi-cuenta de forma automatizada y escalable. Cuando se activa, Control Tower:

1. Crea automáticamente dos cuentas especiales: **Log Archive** (centraliza logs de CloudTrail y Config) y **Audit** (acceso de seguridad centralizado). Estas cuentas no deben crearse manualmente — Control Tower las gestiona.
2. Aplica **guardrails preventivos** (SCPs que bloquean comportamientos inseguros, como deshabilitar CloudTrail o crear buckets públicos) a las OUs.
3. Aplica **guardrails detectivos** (Config Rules que alertan sobre desviaciones del baseline).
4. Ofrece **Account Factory**: un portal self-service donde cualquier persona autorizada (product managers) puede crear una nueva cuenta AWS con toda la baseline aplicada en minutos, sin intervención del equipo de plataforma.
5. Escala automáticamente: cada nueva cuenta creada via Account Factory recibe el mismo baseline sin trabajo manual adicional.

El argumento de "demasiada magia" es válido culturalmente, pero los componentes de Control Tower (SCPs, Config Rules, CloudTrail, roles IAM) son completamente visibles y auditables. Control Tower no oculta la infraestructura — la crea de forma estándar y predecible.

**Por qué cada incorrecta falla en producción**

- **A — Organizations manual + SCPs + StackSets:** Técnicamente viable pero operacionalmente costoso y propenso a inconsistencias. El escenario ya describe que el proceso actual (manual) ha producido cuentas con baseline incompleta. La solución manual no resuelve el self-service — cada cuenta nueva requiere intervención del equipo de plataforma. Escalar a 25 cuentas multiply esto por 25.

- **B — StackSets con EventBridge:** Más automatizado que A, pero hay un delay entre la creación de la cuenta y el despliegue del Stack (10 minutos o más). Durante ese período, la cuenta nueva existe sin baseline. Además, no crea automáticamente las cuentas de Log Archive y Audit — esas deben existir previamente. StackSets también pueden fallar silenciosamente si hay errores de permisos.

- **C — Service Catalog:** Añade una capa de self-service pero con alta complejidad operacional. El producto de Service Catalog debe ser mantenido por el equipo de plataforma (que sigue siendo un cuello de botella). El Step Functions workflow necesita permisos especiales para crear cuentas, lo que añade complejidad de IAM. No es el patrón estándar de AWS para este caso de uso.

> **Exam tip:** Cuando el escenario menciona "cuentas de Log Archive y Audit", "guardrails automáticos", y "self-service account vending", la respuesta es **Control Tower**. Control Tower = Organizations + SCPs + Config Rules + CloudTrail + Account Factory, todo preconfigurado y mantenido por AWS.

---

## Escenario 6 — Banking: KMS cross-account AccessDenied

**Respuesta correcta: D**

El acceso cross-account a KMS Customer Managed Keys tiene un mecanismo de doble autorización que es uno de los puntos más frecuentemente malentendidos y más examinados en el SAA-C03. A diferencia de los recursos dentro de la misma cuenta (donde el IAM policy es suficiente), en cross-account KMS **ambas condiciones deben cumplirse simultáneamente**:

**Condición 1 — Key Policy en la cuenta de Security:** La Key Policy del CMK debe incluir un `Allow` explícito para el principal de la otra cuenta. Puede ser el ARN específico del IAM Role (`arn:aws:iam::APP_ACCOUNT_ID:role/EC2AppRole`) o el root de la cuenta de App (`arn:aws:iam::APP_ACCOUNT_ID:root`). Sin esto, KMS rechaza la solicitud independientemente de lo que diga el IAM policy del caller.

**Condición 2 — IAM Role Policy en la cuenta de App:** El IAM Role del EC2 debe tener `kms:Decrypt` sobre el ARN del CMK en Security. Sin esto, la evaluación de políticas IAM de AWS rechaza la acción antes de que llegue a KMS.

El error específico del escenario: la Key Policy de la CMK en Security no incluye al principal de App. Cuando Secrets Manager intenta descifrar el secret usando esa CMK, KMS verifica su Key Policy, no encuentra autorización para el principal de App, y devuelve `AccessDenied`. La opción A (solo añadir el IAM policy) es insuficiente precisamente porque falta la Key Policy.

**Por qué cada incorrecta falla en producción**

- **A — Solo añadir kms:Decrypt al IAM Role:** En cross-account KMS, el IAM policy es necesario pero no suficiente. La Key Policy también debe autorizar. Con solo el IAM policy, KMS sigue devolviendo `AccessDenied` porque verifica su Key Policy y no encuentra el principal de App autorizado.

- **B — Mover la CMK a la cuenta de App:** Viola el requisito explícito del enunciado ("KMS key stays in Security account") y destruye el modelo de separación de responsabilidades del banco. El equipo de Security perdería el control centralizado de las claves de cifrado. En un entorno PCI-DSS, la centralización de key management es un control crítico.

- **C — AWS managed key (aws/secretsmanager):** Las AWS managed keys (`aws/secretsmanager`) **no funcionan cross-account**. Son gestionadas por AWS dentro de la cuenta donde existe el servicio — no pueden ser usadas por recursos en otras cuentas. Esta opción es un distractor que confunde "managed by AWS" con "accesible desde cualquier cuenta".

> **Exam tip:** KMS cross-account = **doble llave**: Key Policy en la cuenta de la clave + IAM Policy en la cuenta del caller. Recuerda la regla: "para usar una CMK en otra cuenta, el dueño de la clave debe abrir la puerta (Key Policy), y el usuario debe tener la llave (IAM Policy)."

---

## Escenario 7 — E-Commerce: SSM Session Manager

**Respuesta correcta: C**

AWS Systems Manager Session Manager con VPC Endpoints es la solución que cumple todos los requisitos: elimina SSH, el bastion host, el puerto 22, las credenciales estáticas, y funciona sin internet desde instancias en subnets privadas.

El mecanismo técnico: el **SSM Agent** en cada instancia EC2 establece una conexión HTTPS saliente hacia los endpoints de SSM. Con VPC Endpoints (tipo Interface), esa comunicación se hace completamente dentro de la red privada de AWS sin salir a internet. Los tres endpoints necesarios son:
- `com.amazonaws.REGION.ssm` — comunicación principal con el servicio SSM
- `com.amazonaws.REGION.ssmmessages` — protocolo de Session Manager
- `com.amazonaws.REGION.ec2messages` — mensajería de Run Command

Cada sesión se autentica con IAM — el usuario que inicia la sesión puede ser un usuario de IAM Identity Center, y su identidad aparece en CloudTrail con el evento `StartSession`. Los security groups de las instancias no necesitan reglas de inbound — el agente inicia conexiones salientes al endpoint. La grabación de sesiones (keystrokes y output completo) se configura en el documento de preferencias de Session Manager y se envía a S3 y/o CloudWatch Logs.

**Por qué cada incorrecta falla en producción**

- **A — EC2 Instance Connect:** Instance Connect genera SSH keys temporales, pero sigue siendo SSH. El Security Group debe tener el puerto 22 abierto (hacia el IP range del servicio EC2 Instance Connect, pero abierto). Se necesita acceso de red directo a la instancia — en subnets privadas sin internet, Instance Connect no puede alcanzar la instancia. No elimina SSH del todo.

- **B — SSM Session Manager con NAT Gateway:** La opción es técnicamente correcta (SSM funciona vía internet) pero viola el requisito "sin internet en la subnet privada". Añadir un NAT Gateway tiene un costo (~$0.045/hora + datos procesados) y abre una ruta de salida a internet que no existía. Los VPC Endpoints son más seguros (tráfico nunca sale de AWS) y frecuentemente más económicos para workloads que principalmente consumen SSM.

- **D — AWS CloudShell:** CloudShell es una shell en el navegador de la consola de AWS con credenciales IAM preconfiguradas. Permite ejecutar AWS CLI pero **no puede acceder directamente a instancias EC2 privadas** — CloudShell vive en la infraestructura de AWS, no en la VPC del cliente. No hay conectividad de red entre CloudShell y subnets privadas de los clientes.

> **Exam tip:** SSM Session Manager sin internet = **VPC Endpoints obligatorios** (ssm + ssmmessages + ec2messages). Con internet disponible, funciona sin endpoints pero abre tráfico a internet. El examen frecuentemente presenta ambas variantes para ver si el candidato conoce los endpoints.

---

## Escenario 8 — Pharma: AWS Resource Access Manager

**Respuesta correcta: D**

AWS Resource Access Manager (RAM) es el servicio diseñado para compartir recursos AWS entre cuentas dentro de una organización sin crear copias del recurso. Los recursos se comparten desde la cuenta propietaria y las cuentas receptoras los ven y usan como propios, pero el recurso físico (y su facturación) permanece en la cuenta propietaria.

RAM soporta exactamente los recursos del escenario:
- **Transit Gateway**: las cuentas de Dev, Staging y Prod se unen al TGW existente en Shared Services como si fuera suyo propio. Hay un solo TGW, una sola factura de TGW en Shared Services.
- **AMI**: la AMI compartida puede ser lanzada desde las cuentas receptoras sin copiarla. La licencia de AMI del Marketplace se gestiona desde Shared Services y las otras cuentas pagan solo las horas de EC2, no la licencia adicional.
- **Route 53 Resolver Rules**: las reglas de forwarding se comparten y las cuentas receptoras las asocian a sus VPCs sin crear endpoints propios.

Para GxP, la auditabilidad es clara: `GetResourceShares` y las llamadas de uso en CloudTrail muestran quién usa qué recurso compartido. El propietario es inequívocamente Shared Services.

**Por qué cada incorrecta falla en producción**

- **A — Duplicar recursos:** Exactamente el problema que el escenario pide resolver. Un TGW por cuenta, una licencia de AMI por cuenta. Mantiene los costos actuales y el overhead operacional.

- **B — VPC Peering + ModifyImageAttribute:** VPC Peering no sirve para compartir un TGW — el TGW es el reemplazo de VPC Peering en arquitecturas multi-cuenta, no algo que se comparta vía Peering. `ModifyImageAttribute --launch-permission` copia el snapshot de la AMI a cada cuenta, lo que puede generar cargos de licencia adicionales y crea copias que deben actualizarse manualmente cuando la AMI fuente se actualiza. No es el patrón recomendado para compartir AMIs de Marketplace.

- **C — CloudFormation StackSets:** StackSets despliegan recursos idénticos en múltiples cuentas — es decir, crean copias en cada cuenta, exactamente lo que se quiere evitar. Un StackSet que despliega un TGW crea un TGW por cuenta. Útil para configuración (security groups, IAM roles, Config Rules), no para compartir recursos únicos.

> **Exam tip:** Cuando el escenario pide "compartir recursos SIN copiarlos" entre cuentas, la respuesta es **AWS RAM**. Recursos compartibles clave: VPC Subnets, Transit Gateway, Route 53 Resolver rules, AMIs, License Manager configurations, Aurora clusters.

---

## Escenario 9 — Insurance: AWS IAM Access Analyzer

**Respuesta correcta: D**

AWS IAM Access Analyzer resuelve exactamente el problema del escenario: detectar políticas de recursos que conceden acceso a entidades fuera de la **zona de confianza definida** (la organización de AWS). Es el servicio más preciso para este caso de uso porque no busca patrones genéricos de seguridad — analiza la lógica efectiva de cada política y determina si **cualquier principal externo** puede acceder al recurso.

Un **Organization Analyzer** (configurado en la Management Account o en una cuenta delegada de seguridad) analiza automáticamente todos los recursos de todas las cuentas de la organización. Genera **findings** para cada recurso accesible externamente. Los findings pueden ser **archivados** cuando el acceso externo es intencional y aprobado — esto crea una lista blanca de accesos conocidos, de modo que cuando aparece un nuevo finding no archivado, es por definición no intencionado (o nuevo). La integración con EventBridge permite alertas en tiempo real al crear un nuevo finding.

Los recursos que Access Analyzer analiza incluyen exactamente los del escenario: S3 buckets, IAM roles (trust policies), KMS keys, SQS queues, Lambda functions, y Secrets Manager secrets.

**Por qué cada incorrecta falla en producción**

- **A — AWS Config rules específicas:** Las reglas de Config que menciona la opción (`s3-bucket-public-read-prohibited`, `iam-no-inline-policy-check`) no detectan accesos cross-account externos. `s3-bucket-public-read-prohibited` detecta si el bucket es completamente público (accesible por cualquiera), pero no detecta una resource policy que da acceso a una cuenta externa específica. Para los IAM roles con trust policies externas o KMS keys con cross-account access, no hay reglas de Config nativas equivalentes.

- **B — Amazon Macie:** Macie analiza los datos dentro de los buckets S3 en busca de información sensible (PII, datos financieros) y patrones de acceso anómalos a los datos. No analiza las resource-based policies de otros servicios (IAM roles, KMS keys, SQS). No está diseñado para el análisis de políticas de acceso.

- **C — AWS Security Hub:** Security Hub agrega hallazgos de múltiples servicios y proporciona una visión consolidada de seguridad. Pero Security Hub por sí solo no genera los hallazgos de acceso externo — depende de que otros servicios (como Access Analyzer) los generen. Security Hub consume los hallazgos de Access Analyzer, no los reemplaza. Habilitar Security Hub sin Access Analyzer no detecta los escenarios del enunciado.

> **Exam tip:** **Access Analyzer** = "¿quién fuera de mi zona de confianza puede acceder a mis recursos basados en políticas de recursos?". La zona de confianza puede ser una cuenta o una organización. El Organization Analyzer es la configuración clave para multi-cuenta. Archive findings = "este acceso externo es intencional y aprobado".

---

## Escenario 10 — Government: Permission Boundaries

**Respuesta correcta: C**

Los **Permission Boundaries** son el mecanismo de IAM para implementar delegación de privilegios con restricción de escalada. Un boundary es una política IAM que actúa como **guardrail máximo** sobre lo que un rol o usuario puede hacer — los permisos efectivos son la intersección de las políticas de identidad (las políticas adjuntas al rol) Y el boundary. El boundary no otorga permisos por sí mismo; solo limita el máximo que las políticas de identidad pueden conceder.

La implementación correcta usa la condición `iam:PermissionsBoundary` en la política de los developers:
```json
{
  "Effect": "Allow",
  "Action": ["iam:CreateRole", "iam:PutRolePolicy", "iam:AttachRolePolicy"],
  "Resource": "*",
  "Condition": {
    "StringEquals": {
      "iam:PermissionsBoundary": "arn:aws:iam::ACCOUNT_ID:policy/AppTeamBoundary"
    }
  }
}
```

Esta condición hace que `iam:CreateRole` sea **denegado automáticamente** si la llamada no incluye el boundary `AppTeamBoundary`. El rol creado tendrá el boundary aplicado, lo que limita sus permisos efectivos al contenido del boundary (excluye `iam:*`, `organizations:*`, `billing:*`).

El paso crítico adicional que hace C correcto: aplicar el mismo `AppTeamBoundary` como boundary a los propios developers. Sin esto, un developer con permisos amplios podría modificar el boundary policy (si tiene `iam:CreatePolicy` o `iam:PutRolePolicy` sobre la policy del boundary) y expandir los límites. Con el boundary en los developers, sus permisos efectivos también están limitados por `AppTeamBoundary`, cerrando el vector de escalada.

**Por qué cada incorrecta falla en producción**

- **A — SCP que deniegue AdministratorAccess:** Las SCPs operan a nivel de **cuenta**, no a nivel de usuario individual dentro de la cuenta. Una SCP puede denegar que cualquier principal de la cuenta adjunte `AdministratorAccess` a un rol, pero no puede hacer restricciones granulares basadas en qué equipo crea el rol. Además, un developer podría crear un rol con `PowerUserAccess` (que no está en la SCP) y aún escalar privilegios significativamente. Las SCPs no pueden verificar "qué policies están siendo adjuntadas a un rol siendo creado" de forma granular.

- **B — Revocar permisos IAM y mantener Plataforma como intermediario:** Mejora el SLA pero no resuelve el cuello de botella estructural. El equipo de Plataforma sigue siendo el bloqueante. Escalar a 25 cuentas y 3 equipos de aplicación multiply el problema. No es una solución técnica — es un proceso manual que no escala.

- **D — Permission Boundary sin aplicarlo a los developers:** Esta opción es un distractor sutil. Si los developers tienen el boundary solo en los roles que crean, pero ellos mismos no tienen boundary, podrían usar sus permisos IAM directos para modificar la policy `AppTeamBoundary` (expandiéndola para incluir `iam:*`) y luego crear roles con esos permisos expandidos. La diferencia entre C y D es precisamente si el boundary también aplica a los developers mismos — C es correcto, D no lo es.

> **Exam tip:** Permission Boundary = **límite de lo que un rol puede recibir**, no lo que puede hacer directamente. Condición `iam:PermissionsBoundary` en el IAM policy del developer = "solo puedo crear roles si adjunto este boundary". Recuerda: para que el sistema sea hermético, el boundary debe aplicarse tanto a los roles creados COMO a los developers que los crean.
