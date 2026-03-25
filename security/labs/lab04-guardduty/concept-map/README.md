# Lab 04 — Amazon GuardDuty: Mapa Conceptual

---

## Qué es GuardDuty

GuardDuty es un servicio de **detección de amenazas** que analiza continuamente las fuentes de datos de tu cuenta AWS para identificar actividad maliciosa o no autorizada.

**Principio clave:** GuardDuty **detecta** — no configura, no bloquea, no remedia por sí solo.

```
Sin GuardDuty:          Con GuardDuty:
                         ┌─────────────────────────────────┐
Actividad sospechosa     │ Fuentes de datos analizadas:     │
→ nadie lo sabe          │  VPC Flow Logs                   │
                         │  CloudTrail                       │
                         │  DNS Logs                         │
                         │  S3 Data Events                   │
                         │  EKS Audit Logs                   │
                         └──────────────┬──────────────────┘
                                        │ Machine Learning
                                        │ + threat intelligence
                                        ▼
                               Finding generado
                         (tipo, severidad, recurso afectado)
```

---

## Fuentes de datos

| Fuente | Qué detecta | Habilitación |
|--------|-------------|-------------|
| **VPC Flow Logs** | Comunicaciones sospechosas, port scans, crypto mining | Automática (GuardDuty los lee sin activar Flow Logs en tu cuenta) |
| **CloudTrail Management Events** | Uso inusual de API, credenciales comprometidas | Automática |
| **CloudTrail S3 Data Events** | Exfiltración de datos en S3 | Opcional (Protection Plan) |
| **DNS Logs** | Conexiones a dominios maliciosos, C2 callbacks | Automática |
| **EKS Audit Logs** | Actividad sospechosa en Kubernetes | Opcional (EKS Protection) |
| **Lambda Network Activity** | Funciones Lambda contactando IPs maliciosas | Opcional |

> **Importante:** GuardDuty no requiere que tengas VPC Flow Logs habilitados en tu cuenta. Analiza los logs directamente desde la infraestructura de AWS.

---

## Tipos de findings

Los findings se nombran con el patrón: `ThreatPurpose:ResourceType/ThreatFamilyName`

| Categoría | Ejemplo | Qué significa |
|-----------|---------|--------------|
| **UnauthorizedAccess** | `UnauthorizedAccess:IAMUser/ConsoleLoginSuccess.B` | Login desde IP inusual o país sospechoso |
| **Recon** | `Recon:EC2/Portscan` | Escaneo de puertos desde tu EC2 |
| **CryptoCurrency** | `CryptoCurrency:EC2/BitcoinTool.B` | Tu EC2 está minando criptomonedas |
| **Trojan** | `Trojan:EC2/DNSDataExfiltration` | Exfiltración de datos via DNS |
| **Backdoor** | `Backdoor:EC2/C&CActivity.B` | Tu EC2 se comunica con servidor de C2 |
| **PenTest** | `PenTest:IAMUser/KaliLinux` | API calls desde herramienta de pentest |
| **Policy** | `Policy:S3/BucketBlockPublicAccessDisabled` | Alguien deshabilitó Block Public Access |

**Severidad:** LOW (1-3.9), MEDIUM (4-6.9), HIGH (7-8.9), CRITICAL (9-10)

---

## Trusted IP List vs Threat IP List

Esta distinción es **crítica para el examen SAA-C03**:

### Trusted IP List
```
┌─────────────────────────────────────────────────────────┐
│ TRUSTED IP LIST                                          │
│                                                          │
│ IPs de las que GuardDuty NO generará findings           │
│                                                          │
│ Casos de uso:                                            │
│  - Oficinas corporativas                                 │
│  - Herramientas de monitorización legítimas              │
│  - Redes VPN propias                                     │
│  - Entornos de pentest autorizados                       │
│                                                          │
│ Formato: archivo .txt con una IP/CIDR por línea         │
│ Ubicación: bucket S3                                     │
│ Solo UNA Trusted IP List por región por detector        │
└─────────────────────────────────────────────────────────┘
```

### Threat IP List
```
┌─────────────────────────────────────────────────────────┐
│ THREAT IP LIST                                           │
│                                                          │
│ IPs de las que GuardDuty SÍ generará findings           │
│ (además de las amenazas que ya detecta por defecto)     │
│                                                          │
│ Casos de uso:                                            │
│  - IOCs (Indicators of Compromise) propios              │
│  - IPs de atacantes conocidos en tu sector              │
│  - Feeds de threat intelligence internos                 │
│                                                          │
│ Formato: archivo .txt con una IP/CIDR por línea         │
│ Hasta 6 Threat IP Lists por región por detector        │
└─────────────────────────────────────────────────────────┘
```

**Diferencia clave:**
- Trusted IP List → **suprime** findings de esas IPs (equipo de pentest propio)
- Threat IP List → **añade** fuentes de amenazas (IOCs de tu threat intel)

---

## Suppression Rules vs Archive manual

| | Suppression Rules | Archive manual |
|-|-------------------|----------------|
| **Automático** | Sí — aplica a findings futuros | No — hay que hacer clic por finding |
| **Criterios** | Tipo de finding + filtros | Finding individual |
| **Estado del finding** | Se archiva automáticamente | Se archiva manualmente |
| **Visible en Security Hub** | NO se envía | Sí se envía pero como Archived |
| **Cuándo usar** | Ruido recurrente y conocido | Caso puntual analizado |

**Ejemplo de Suppression Rule:**
```
Finding type = PenTest:IAMUser/KaliLinux
AND Resource.AccessKeyDetails.UserName = "pentest-user"
→ Archivar automáticamente
```

---

## Patrón de respuesta: GuardDuty → EventBridge → Lambda + SNS

GuardDuty genera findings pero **no puede actuar directamente**. El patrón estándar de respuesta automática es:

```
┌─────────────┐    Finding      ┌──────────────┐
│  GuardDuty  │ ─────────────> │  EventBridge  │
│  (detecta)  │                │  Rule         │
└─────────────┘                └──────┬────────┘
                                       │
                          ┌────────────┴────────────┐
                          │                          │
                          ▼                          ▼
                   ┌─────────────┐          ┌─────────────┐
                   │   Lambda    │          │     SNS     │
                   │ (Remediar)  │          │ (Notificar) │
                   │             │          │             │
                   │ - Cambiar SG│          │ - Email     │
                   │ - Revocar   │          │ - Slack     │
                   │   credencial│          │ - PagerDuty │
                   │ - Aislar EC2│          └─────────────┘
                   └─────────────┘
```

**¿Por qué EventBridge en el medio?**
- GuardDuty no tiene integración directa con Lambda o SNS
- EventBridge actúa como bus de eventos entre GuardDuty y los targets de remediación
- Permite múltiples targets por finding y filtrado por severidad, tipo, etc.

---

## Analogía DevOps

```
GuardDuty ≈ IDS/IPS en la capa de red

Sistema tradicional:          AWS con GuardDuty:
┌──────────────────┐          ┌──────────────────────────────────┐
│  Firewall + IDS  │          │  GuardDuty                        │
│                  │          │                                    │
│  - Analiza       │    ≈     │  - Analiza VPC Flow Logs          │
│    tráfico       │          │    CloudTrail, DNS, S3            │
│  - Genera alertas│          │  - Genera findings                 │
│  - No bloquea    │          │  - No bloquea (solo detecta)      │
│    directamente  │          │  → EventBridge+Lambda para actuar │
└──────────────────┘          └──────────────────────────────────┘

Respuesta a incidente tradicional:    Con GuardDuty:
Alert → equipo SOC → investigar       Finding → EventBridge → Lambda (automático)
→ aislar máquina manualmente         → EC2 aislada en segundos
```

---

## Tabla comparativa para el examen SAA-C03

| Servicio | Detecta | Fuente de datos | Respuesta |
|---------|---------|----------------|-----------|
| **GuardDuty** | Amenazas activas y comportamiento anómalo | VPC Flow Logs, CloudTrail, DNS | EventBridge → Lambda/SNS |
| **Config** | Configuración incorrecta de recursos | Estado de recursos | SSM Automation o Lambda |
| **Inspector** | Vulnerabilidades en EC2/ECR/Lambda | Paquetes instalados, CVEs | EventBridge → Lambda |
| **Macie** | Datos sensibles en S3 + config insegura | Contenido y configuración de S3 | EventBridge → Lambda |
| **Access Analyzer** | Accesos externos no intencionados | Resource policies | Alertas → acción manual |

**Regla mnemotécnica:**
- GuardDuty → ¿alguien está **haciendo** algo malo?
- Config → ¿algo está **configurado** incorrectamente?
- Inspector → ¿hay **vulnerabilidades** en mis workloads?
- Macie → ¿hay **datos sensibles** expuestos en S3?
- Access Analyzer → ¿quién tiene **acceso** a mis recursos?
