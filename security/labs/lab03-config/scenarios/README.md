# Lab 03 — Scenarios SAA-C03

Escenarios de examen sobre AWS Config, remediación automática y compliance.

---

## Escenario 1 — Detectar cambios de configuración

**Contexto:** Una empresa necesita saber cuándo alguien modifica un Security Group y registrar el estado anterior y posterior del cambio.

**Pregunta:** ¿Qué servicio AWS proporciona un historial continuo de cambios de configuración en recursos, incluyendo quién lo cambió y cuándo?

**Opciones:**
- A) AWS CloudTrail
- B) AWS Config
- C) Amazon CloudWatch
- D) AWS Trusted Advisor

**Respuesta correcta: B**

**Explicación:**
- **Config** graba el estado de configuración de cada recurso a lo largo del tiempo. Permite ver el historial completo: quién creó/modificó el recurso, el estado antes y después, y cuándo ocurrió el cambio.
- **CloudTrail** registra llamadas a la API (quién hizo qué), pero no almacena el estado completo de configuración del recurso.
- **CloudWatch** monitoriza métricas y logs, no el estado de configuración de recursos.
- **Trusted Advisor** da recomendaciones de best practices, no historial de cambios.

**Pista SAA-C03:** "historial de configuración" + "estado anterior/posterior" = AWS Config.

---

## Escenario 2 — Remediación automática de Security Groups

**Contexto:** Una empresa tiene cientos de cuentas AWS. El equipo de seguridad necesita que cualquier Security Group con el puerto 22 abierto a 0.0.0.0/0 sea corregido automáticamente en menos de 5 minutos, sin intervención manual.

**Pregunta:** ¿Cuál es la arquitectura más adecuada?

**Opciones:**
- A) CloudWatch Events → SNS → email al equipo de seguridad → remediar manualmente
- B) AWS Config Rule `restricted-ssh` con Automatic Remediation usando SSM Automation Document `AWS-DisablePublicAccessForSecurityGroup`
- C) AWS Trusted Advisor con notificaciones por email
- D) AWS Inspector con Lambda de remediación

**Respuesta correcta: B**

**Explicación:**
- **Config + Automatic Remediation** es el patrón nativo para "Config Rule falla → acción automática". El SSM Automation Document `AWS-DisablePublicAccessForSecurityGroup` elimina la regla de ingress del puerto 22 sin código custom.
- La opción A requiere intervención manual, viola el requisito "sin intervención manual".
- **Trusted Advisor** hace recomendaciones pero no tiene remediation automática.
- **Inspector** evalúa vulnerabilidades en EC2/containers, no monitoriza configuración de SGs en tiempo real.

**Pista SAA-C03:** "Config Rule" + "automáticamente" = Config Automatic Remediation con SSM Document.

---

## Escenario 3 — Compliance multi-cuenta

**Contexto:** Una empresa con 50 cuentas AWS necesita un dashboard centralizado que muestre el estado de compliance de todas las cuentas desde una cuenta de seguridad central.

**Pregunta:** ¿Qué componente de AWS Config permite agregar datos de compliance de múltiples cuentas y regiones en un único punto de consulta?

**Opciones:**
- A) Config Aggregator con Organizations
- B) AWS Security Hub
- C) AWS Organizations Service Control Policies
- D) AWS Config con cross-account IAM Roles

**Respuesta correcta: A**

**Explicación:**
- **Config Aggregator** con Organizations agrega automáticamente los datos de compliance de todas las cuentas miembro. Permite consultas del tipo "¿cuántos recursos NON_COMPLIANT hay en total en mis 50 cuentas?"
- **Security Hub** también agrega findings de múltiples cuentas, pero Config Aggregator es específico para Config Rules compliance.
- **SCPs** controlan permisos en Organizations, no muestran compliance.
- La opción D requiere configuración manual por cuenta — Organizations automatiza el proceso.

**Importante:** El Aggregator es **solo lectura**. Ver el estado de compliance desde una cuenta central NO significa que esa cuenta pueda remediar recursos en las demás cuentas. Para remediación cross-account se necesita el patrón: EventBridge → Lambda → sts:AssumeRole → remediar.

**Pista SAA-C03:** "compliance de múltiples cuentas" + "dashboard centralizado" = Config Aggregator.

---

## Escenario 4 — Custom rule vs Managed rule

**Contexto:** Una empresa requiere que todas las instancias EC2 tengan el tag `CostCenter` con un valor del formato `CC-XXXX`. Los managed rules de AWS Config no cubren este requisito específico.

**Pregunta:** ¿Cómo implementar esta validación en AWS Config?

**Opciones:**
- A) Usar el managed rule `required-tags` con configuración avanzada
- B) Crear una Custom Config Rule con una Lambda que evalúe el tag y llame a `config:PutEvaluations`
- C) Usar AWS Service Catalog para forzar el tag en el aprovisionamiento
- D) Configurar una SCP que bloquee la creación de EC2 sin el tag

**Respuesta correcta: B**

**Explicación:**
- **Custom Lambda Rule** es la forma de extender Config cuando los managed rules no cubren la lógica necesaria. La Lambda recibe el `configurationItem`, evalúa la condición y reporta `COMPLIANT`/`NON_COMPLIANT` via `config:PutEvaluations`.
- El managed rule `required-tags` verifica que el tag exista, pero no puede validar el formato del valor (regex `CC-XXXX`).
- **Service Catalog** controla el aprovisionamiento pero no monitoriza recursos existentes.
- **SCPs** previenen la creación pero no evalúan recursos ya existentes ni permiten un historial de compliance.

**Pista SAA-C03:** "lógica de evaluación custom" + "Config" = Custom Config Rule con Lambda (`CUSTOM_LAMBDA`, `put_evaluations`).

---

## Tabla resumen SAA-C03

| Servicio | Para qué sirve | No sirve para |
|---------|---------------|--------------|
| **AWS Config** | Historial de configuración, compliance de recursos, remediation | Monitorizar métricas, logs de aplicación |
| **Config Rule (managed)** | Validar best practices predefinidas | Lógica custom compleja |
| **Config Rule (custom)** | Validar cualquier condición de configuración | Acciones en tiempo real (no es trigger inmediato) |
| **Config Automatic Remediation** | Corregir automáticamente recursos NON_COMPLIANT | Reaccionar a eventos que no sean Config Rules |
| **Config Aggregator** | Vista centralizada de compliance multi-cuenta | Remediar en cuentas miembro (solo lectura) |
| **EventBridge + Lambda** | Reaccionar a cualquier evento AWS + lógica custom | Historial de configuración |
