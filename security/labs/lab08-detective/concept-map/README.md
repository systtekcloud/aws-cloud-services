# Lab 08 — Amazon Detective: Mapa Conceptual

---

## Qué es Amazon Detective

Amazon Detective es un servicio de **investigación forense de incidentes de seguridad**. Ingiere automáticamente datos de CloudTrail, VPC Flow Logs y GuardDuty, construye un **grafo de comportamiento** de tu cuenta, y permite investigar visualmente qué pasó durante un incidente.

**Principio clave:** Detective responde a "¿qué pasó exactamente?" — no detecta amenazas, no agrega findings.

---

## Fuentes de datos que ingiere Detective

```
Detective ingiere automáticamente (sin configuración):
┌────────────────────────────────────────────────────────────────────────┐
│  AWS CloudTrail    → API calls: quién llamó a qué, cuándo, desde dónde│
│  VPC Flow Logs     → Tráfico de red: IPs, puertos, bytes transferidos  │
│  GuardDuty findings → Findings de amenazas activas como contexto       │
│                                                                         │
│  Retención: 1 año de datos históricos                                  │
│  Espera inicial: 24-48h para que el behavior graph madure              │
└────────────────────────────────────────────────────────────────────────┘
```

---

## Qué proporciona Detective

```
Behaviour Graph (grafo de relaciones):

    IAM Role ─────────────────────────────── EC2 Instance
       │              AssumeRole               │
       │                                       │ VPC Flow Log
       ▼                                       ▼
  API Call Timeline                     Conexiones de red
  ─────────────────                     ─────────────────
  • sts:AssumeRole (14:23)              • IP 198.51.100.1:443 → i-abc (14:25)
  • s3:ListBuckets (14:24)              • i-abc → 198.51.100.99:22 (14:26)
  • s3:GetObject x47 (14:24-14:31)      • bytes_out = 2.3 GB (14:26-15:00)
  • ec2:DescribeInstances (14:32)
  • iam:ListUsers (14:33)

→ Detective correlaciona automáticamente estos eventos para mostrar:
  "El rol fue asumido → se hicieron 47 GetObject en S3 → se inició conexión
   SSH saliente → se exfiltraron 2.3 GB en 34 minutos"
```

---

## Diferencia CRÍTICA: Detective vs CloudTrail

Esta comparación es una de las más frecuentes en SAA-C03:

```
┌──────────────────────────────────────────────────────────────────────────┐
│  CloudTrail                          Amazon Detective                      │
│  ──────────────────────────          ──────────────────────────────────   │
│  "¿Qué ocurrió?" (log en bruto)      "¿Qué pasó exactamente?" (correlado) │
│                                                                            │
│  Proporciona:                        Proporciona:                         │
│  - Eventos de API en JSON            - Grafo de relaciones entre          │
│  - Búsqueda por campo                  entidades (IPs, roles, instancias) │
│  - Athena para queries SQL           - Línea temporal automática          │
│  - 90 días en Event History          - Contexto histórico (1 año)         │
│                                      - Patrón de comportamiento normal    │
│                                        vs comportamiento anómalo          │
│                                                                            │
│  Investigar un incidente con         Investigar un incidente con          │
│  CloudTrail:                         Detective:                           │
│  1. Abrir CloudTrail console         1. Ir al GuardDuty finding           │
│  2. Filtrar por recurso              2. Click "Investigate in Detective"  │
│  3. Filtrar por rango de tiempo      3. Ver el grafo ya construido        │
│  4. Revisar evento por evento        4. Línea temporal visual             │
│  5. Correlacionar manualmente        5. Contexto automático               │
│  6. Ir a VPC Flow Logs separados     6. IPs, roles, instancias            │
│     y correlacionar                     ya correlacionadas                │
│                                                                            │
│  Tiempo: horas                       Tiempo: minutos                      │
│                                                                            │
│  Cuándo usar CloudTrail:             Cuándo usar Detective:               │
│  - Auditoría de compliance           - Investigación de incidente activo  │
│  - "¿Quién borró este recurso?"      - "¿Qué alcance tuvo el ataque?"     │
│  - Integración con SIEMs             - "¿Qué más tocó el atacante?"       │
└──────────────────────────────────────────────────────────────────────────┘

Regla SAA-C03:
  "investigación forense" / "qué hizo el atacante" / "alcance del ataque" → Detective
  "auditoría de API calls" / "log en bruto" / "compliance" → CloudTrail
```

---

## Diferencia: Detective vs Security Hub

```
Security Hub                          Amazon Detective
────────────────────────────          ────────────────────────────────
"¿Cuál es mi postura global?"         "¿Qué pasó exactamente en este finding?"

→ Dashboard de compliance             → Investigación de un incidente específico
→ Security Score                      → Grafo de entidades afectadas
→ Agrega findings de múltiples        → Línea temporal del comportamiento
  servicios                           → Contexto: ¿es esto normal?
→ Responde "¿cuántos problemas tengo?"→ Responde "¿qué recursos tocó el atacante?"

Flujo típico de respuesta a incidente:
1. GuardDuty detecta → finding CRITICAL
2. Security Hub lo muestra en dashboard centralizado
3. Analista hace click en "Investigate in Detective"
4. Detective muestra el grafo completo del incidente
```

---

## Flujo de investigación con Detective

```
Paso 1: GuardDuty finding
  "UnauthorizedAccess:IAMUser/ConsoleLoginSuccess.NoMFA"
  Resource: IAM User arn:aws:iam::123456789012:user/alice
  Severity: MEDIUM
  Time: 2026-04-09T14:23:45Z
                    │
                    │ Click "Investigate in Detective"
                    ▼
Paso 2: Detective abre el perfil de la entidad (IAM User: alice)
  - API calls en el último día/semana/mes
  - Desde qué IPs se autenticó (comparado con comportamiento normal)
  - Recursos que accedió (S3, EC2, IAM...)
  - Roles que asumió
                    │
                    │ ¿Qué recursos accedió?
                    ▼
Paso 3: Correlación automática
  S3 bucket: data-lake-prod
  - alice accedió 47 veces en 8 minutos (vs. media histórica: 2/hora)
  - Datos descargados: 2.3 GB (anomalía estadística: 3 sigma)
  - Desde IP: 198.51.100.1 (never seen before para alice)
                    │
                    │ Conclusión
                    ▼
Paso 4: Scope del ataque
  "Credenciales de alice comprometidas desde 14:23.
   Se exfiltraron 2.3 GB de data-lake-prod en 8 minutos.
   No se detectó movimiento lateral a otras cuentas."
```

---

## Analogía DevOps

```
Detective ≈ Distributed Tracing para incidentes de seguridad

Distributed Tracing (Jaeger/Zipkin):     Amazon Detective:
────────────────────────────────────     ─────────────────────────────────
Problema: "el checkout tardó 3 seg"      Problema: "GuardDuty finding crítico"

Sin tracing:                             Sin Detective:
  - Ver logs de cada microservicio         - Ver CloudTrail por servicio
  - Correlacionar manualmente              - Correlacionar manualmente
  - Encontrar el cuello de botella         - Encontrar el alcance del ataque
  - Tiempo: horas                          - Tiempo: horas

Con tracing:                             Con Detective:
  - Una vista con la traza completa        - Una vista con el grafo completo
  - Latencia por span automática           - Línea temporal automática
  - Relaciones entre servicios             - Relaciones entre entidades AWS
  - Tiempo: minutos                        - Tiempo: minutos

Del mismo modo que el tracing correlaciona spans de múltiples servicios
en una sola traza visual, Detective correlaciona eventos de CloudTrail,
VPC Flow Logs y GuardDuty en un solo grafo de incidente.
```
