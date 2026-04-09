# Lab 08 — Scenarios SAA-C03

Escenarios de examen sobre Amazon Detective, investigación forense y respuesta a incidentes.

---

## Escenario 1 — Detective vs CloudTrail para investigación de incidentes

**Contexto:** El equipo de seguridad de una empresa recibe un GuardDuty finding:
`UnauthorizedAccess:IAMUser/ConsoleLoginSuccess.NoMFA` con severidad MEDIUM para el usuario `carlos.dev`.

El CISO quiere saber:
- ¿Desde qué IP se autenticó?
- ¿Qué recursos accedió después del login?
- ¿Asumió algún otro rol?
- ¿Descargó datos de S3?

**Pregunta:** ¿Qué servicio responde estas preguntas de forma más eficiente?

**Opciones:**
- A) CloudTrail — buscar manualmente eventos de `carlos.dev` en el rango de tiempo
- B) Amazon Detective — investigar la entidad `carlos.dev` en el behavior graph
- C) AWS Config — revisar el historial de configuración de recursos
- D) VPC Flow Logs con consultas Athena

**Respuesta correcta: B**

**Explicación:**
- **Amazon Detective** es específicamente el servicio diseñado para este escenario. Proporciona:
  - El grafo de la entidad `carlos.dev` con todas sus relaciones (IPs, buckets, roles, instancias)
  - Timeline automático de API calls comparado con el baseline histórico
  - Anotaciones de comportamiento anómalo (ej: "esta IP no se había visto antes")
  - Todo correlacionado en una sola vista visual

- **CloudTrail** (opción A) contiene la misma información, pero requiere correlación manual entre CloudTrail, VPC Flow Logs y GuardDuty — proceso que tarda horas vs minutos con Detective.

- **Config** (opción C) responde sobre el estado de configuración de recursos, no sobre el comportamiento de un usuario.

- **VPC Flow Logs + Athena** (opción D) muestra tráfico de red pero no API calls ni relaciones IAM.

**Pista SAA-C03:** "investigar qué hizo un usuario/recurso durante un incidente" → **Amazon Detective**. "auditar todos los API calls de una cuenta" → CloudTrail.

---

## Escenario 2 — Orden correcto de respuesta a incidente

**Contexto:** GuardDuty genera el finding `CryptoCurrency:EC2/BitcoinTool.B` — una instancia EC2 está minando criptomonedas. El equipo de seguridad necesita:
1. Entender el alcance del ataque (¿qué más comprometió?)
2. Contener el incidente (aislar la instancia)
3. Preservar evidencia forense (snapshot)
4. Notificar al equipo

**Pregunta:** ¿Cuál es el orden correcto de las acciones?

**Opciones:**
- A) Terminar instancia → investigar con Detective → notificar
- B) Snapshot → aislar instancia (cambiar SG) → investigar con Detective → notificar
- C) Investigar con Detective → snapshot → aislar instancia → notificar
- D) Notificar → esperar aprobación → snapshot → terminar instancia

**Respuesta correcta: B**

**Explicación:**
El orden correcto en respuesta a incidente es:

```
1. PRESERVAR EVIDENCIA (snapshot)
   → Antes de cualquier acción, capturar el estado del disco
   → aws ec2 create-snapshot --volume-id <vol-id>
   → Si terminas la instancia sin snapshot, pierdes la evidencia

2. CONTENER (aislar, no terminar)
   → Cambiar el Security Group a uno de "cuarentena" (sin inbound/outbound)
   → NO terminar — la instancia en memoria puede tener datos forenses
   → aws ec2 modify-instance-attribute --groups <quarantine-sg>

3. INVESTIGAR (Detective)
   → Con la instancia aislada, usar Detective para entender el alcance
   → ¿Cómo entró el atacante? ¿Qué más accedió? ¿Exfiltró datos?

4. NOTIFICAR
   → Con el scope documentado, notificar con información completa
```

La opción A (terminar primero) destruye evidencia forense.
La opción C (investigar sin aislar primero) permite que el ataque continúe.
La opción D (esperar aprobación) es demasiado lenta para contención.

**Pista SAA-C03:** Orden de respuesta a incidente:
**Snapshot → Aislar → Investigar (Detective) → Notificar**

---

## Escenario 3 — Detective vs Security Hub

**Contexto:** Un analista de seguridad tiene dos tareas:

**Tarea A:** Revisar el estado de seguridad general de la empresa: cuántos controles del CIS Benchmark están fallando, qué servicios tienen findings sin resolver, y el Security Score general.

**Tarea B:** Investigar un incidente específico: un GuardDuty finding indica que credenciales IAM han sido exfiltradas. Necesita saber qué hizo el atacante con esas credenciales, desde qué IPs se conectó, y qué datos accedió.

**Pregunta:** ¿Qué servicio usar para cada tarea?

**Respuesta:**

| Tarea | Servicio | Razón |
|-------|---------|-------|
| **Tarea A** — postura global | **Security Hub** | Dashboard de compliance, Security Score, findings agregados de múltiples servicios |
| **Tarea B** — investigación específica | **Amazon Detective** | Grafo de entidades, timeline correlacionado, comportamiento anómalo vs baseline |

```
Security Hub responde a:
  "¿Cuántos problemas tengo?"
  "¿Qué % de controles CIS estoy pasando?"
  "¿Qué servicios generan más findings HIGH?"

Amazon Detective responde a:
  "¿Qué hizo exactamente el atacante?"
  "¿Qué recursos tocó?"
  "¿Fue la primera vez que esta IP accedió?"
  "¿Hay movimiento lateral a otras entidades?"

Los dos son complementarios:
  Security Hub → detectar y priorizar → "tenemos un CRITICAL en prod"
  Detective → investigar → "aquí está el timeline completo del ataque"
```

---

## Tabla resumen SAA-C03 — Detective

| Dimensión | Respuesta |
|-----------|---------|
| **¿Qué hace Detective?** | Investigación forense — correlaciona eventos para entender incidentes |
| **Fuentes de datos** | CloudTrail + VPC Flow Logs + GuardDuty (automático) |
| **Retención** | 1 año de datos históricos |
| **¿Detecta amenazas?** | **No** — necesita GuardDuty para la detección |
| **¿Puede contener ataques?** | **No** — solo investiga. Lambda + EventBridge contienen |
| **Maduración del grafo** | 24-48h para el baseline inicial |
| **Detective vs CloudTrail** | Detective = correlación visual (minutos). CloudTrail = logs en bruto (horas) |
| **Detective vs Security Hub** | Detective = investigar UN incidente. Security Hub = postura GLOBAL |
| **Prerrequisito** | GuardDuty activo con findings |

**Para recordar Detective en el examen:**
- "investigar" / "forense" / "qué pasó" / "alcance del ataque" → **Detective**
- "detectar" / "amenazas activas" → GuardDuty
- "postura global" / "compliance" → Security Hub
- "auditoría de API calls en bruto" → CloudTrail
