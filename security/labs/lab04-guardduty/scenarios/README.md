# Lab 04 — Scenarios SAA-C03

Escenarios de examen sobre Amazon GuardDuty, detección de amenazas y respuesta a incidentes.

---

## Escenario 1 — Credenciales IAM comprometidas

**Contexto:** Un equipo de seguridad recibe un finding de GuardDuty: `UnauthorizedAccess:IAMUser/ConsoleLoginSuccess.B` con severidad HIGH. El finding indica que alguien se logó en la consola desde una IP en un país donde la empresa no opera.

**Pregunta:** ¿Cuál es el orden correcto de respuesta a este incidente?

**Opciones:**
- A) Ignorar — GuardDuty genera falsos positivos frecuentemente
- B) Deshabilitar el usuario IAM → revocar sesiones activas → investigar en CloudTrail → rotar credenciales
- C) Cambiar la contraseña del usuario y esperar
- D) Activar GuardDuty enhanced monitoring y esperar más datos

**Respuesta correcta: B**

**Explicación:**
El orden de respuesta ante credenciales comprometidas (IAM Incident Response):
1. **Deshabilitar el usuario IAM** (`aws iam update-login-profile --password-reset-required` o attach `DenyAll` policy) — detiene el daño inmediato
2. **Revocar sesiones activas** (`aws iam delete-login-profile`, `aws iam update-access-key --status Inactive`) — invalida tokens existentes
3. **Investigar en CloudTrail** — ver qué hizo el atacante, qué recursos tocó
4. **Rotar credenciales** — emitir nuevas credenciales para el usuario legítimo
5. Opcionalmente: usar **Detective** para visualizar el grafo completo del incidente

GuardDuty detecta, pero la respuesta es manual o via Lambda. La opción A es incorrecta porque GuardDuty tiene muy baja tasa de falsos positivos (machine learning + threat intelligence).

**Pista SAA-C03:** finding de credenciales comprometidas → acción inmediata: deshabilitar + revocar + investigar.

---

## Escenario 2 — Equipo de pentest genera ruido

**Contexto:** Una empresa contrata a un equipo externo de pentest que opera desde IPs variables (no fijas) usando herramientas que incluyen Kali Linux. GuardDuty genera decenas de findings `PenTest:IAMUser/KaliLinux` diariamente. El equipo de seguridad quiere que estos findings no aparezcan en el dashboard pero SÍ quiere mantener la visibilidad sobre el pentest.

**Pregunta:** ¿Cuál es la solución más adecuada?

**Opciones:**
- A) Deshabilitar GuardDuty durante el periodo de pentest
- B) Crear una Trusted IP List con las IPs del equipo de pentest
- C) Crear una Suppression Rule con criterio: type=PenTest:IAMUser/KaliLinux
- D) Archivar manualmente cada finding durante el pentest

**Respuesta correcta: C**

**Explicación:**
- **Suppression Rule** archiva automáticamente los findings futuros que cumplan el criterio. GuardDuty sigue detectando y registrando (útil para auditoría), pero los findings no contaminan el dashboard. Los findings NO se envían a Security Hub.
- La opción B (Trusted IP List) sería correcta si las IPs fueran fijas y conocidas de antemano. Como las IPs varían, Trusted IP List no aplica.
- La opción A es incorrecta — deshabilitar GuardDuty deja la cuenta sin detección de amenazas reales durante el pentest, que es exactamente cuando hay más actividad.
- La opción D es incorrecta — el archive manual no es escalable con decenas de findings diarios.

**Pista SAA-C03:** "IPs variables" + "archivar automáticamente" = Suppression Rule. "IPs fijas conocidas" = Trusted IP List.

---

## Escenario 3 — Respuesta automática a instancia comprometida

**Contexto:** GuardDuty detecta `CryptoCurrency:EC2/BitcoinTool.B` (severidad HIGH) en una instancia EC2 de producción. La empresa requiere aislamiento automático de la instancia en menos de 5 minutos sin intervención manual.

**Pregunta:** ¿Cuál es la arquitectura correcta?

**Opciones:**
- A) GuardDuty → SNS → email al equipo → aislar manualmente
- B) GuardDuty → EventBridge Rule (severity HIGH) → Lambda (cambiar SG a quarantine) + SNS (notificar)
- C) GuardDuty → AWS Systems Manager → Run Command → aislar instancia
- D) Activar GuardDuty Malware Protection → remediación automática integrada

**Respuesta correcta: B**

**Explicación:**
- **EventBridge + Lambda** es el patrón estándar de respuesta automática para GuardDuty. La Lambda cambia el Security Group de la EC2 afectada a uno de "cuarentena" (sin ingress ni egress), aislándola de la red en segundos.
- La opción A requiere intervención manual — viola el requisito de < 5 minutos automático.
- La opción C (SSM Run Command) podría funcionar pero no es el patrón más directo; modificar el SG via Lambda es más rápido y no requiere SSM Agent en la instancia.
- La opción D es incorrecta — GuardDuty Malware Protection escanea archivos pero no aísla instancias automáticamente.

**Pista SAA-C03:** GuardDuty no tiene acción directa → **siempre** necesita EventBridge como intermediario.

---

## Escenario 4 — GuardDuty vs Macie vs Inspector vs Config

**Contexto:** Una empresa evalúa qué servicio de seguridad usar para cada escenario. Elige el servicio correcto.

**Situación A:** "Detectar que alguien está haciendo port scanning desde una de nuestras EC2"
**Situación B:** "Verificar que todos los buckets S3 tienen cifrado habilitado"
**Situación C:** "Encontrar archivos que contengan números de tarjeta de crédito en S3"
**Situación D:** "Detectar que una imagen Docker en ECR tiene CVE-2024-XXXXX crítico"

**Respuestas:**
- **A → GuardDuty** (`Recon:EC2/Portscan`) — detecta comportamiento anómalo en la red vía VPC Flow Logs
- **B → AWS Config** (`s3-bucket-server-side-encryption-enabled`) — verifica configuración de recursos
- **C → Amazon Macie** (`SensitiveData:S3Object/Financial`) — analiza contenido de objetos S3
- **D → Amazon Inspector** (Enhanced Scanning en ECR) — detecta CVEs en imágenes de contenedores

**Tabla resumen:**

| Servicio | Pregunta que responde |
|---------|----------------------|
| **GuardDuty** | ¿Alguien está **haciendo** algo malicioso ahora mismo? |
| **Config** | ¿Algún recurso está **mal configurado**? |
| **Macie** | ¿Hay **datos sensibles** expuestos en S3? |
| **Inspector** | ¿Hay **vulnerabilidades conocidas** (CVEs) en mis workloads? |
| **Access Analyzer** | ¿Quién tiene **acceso externo no intencionado** a mis recursos? |
| **Security Hub** | ¿Cuál es mi **postura de seguridad global** (vista agregada)? |
| **Detective** | ¿Qué **pasó exactamente** durante un incidente? (investigación forense) |

**Pista SAA-C03:** Memorizar la "pregunta que responde" cada servicio elimina el 90% de confusiones en el examen.
