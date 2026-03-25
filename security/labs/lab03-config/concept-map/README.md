# AWS Config — Concept Map

> **Coste:** ~$2-3 por lab completo | **Región:** eu-west-1

---

## Qué es AWS Config

AWS Config es un servicio de **auditoría continua de configuración** de recursos AWS. Registra el historial de configuración de cada recurso y evalúa ese estado contra **Config Rules** para determinar si es compliant o no.

Responde a la pregunta: *¿mis recursos tienen la configuración que deberían tener?*

No es un detector de amenazas (eso es GuardDuty) — es un auditor de **estado de configuración** que además puede **remediar automáticamente** las desviaciones.

---

## Los tres componentes principales de AWS Config

### 1. Config Recorder (Configuration Recorder)

Registra los cambios de configuración de los recursos AWS en tu cuenta. Cuando un recurso cambia, Config captura el nuevo estado y lo almacena.

```
EC2 cambia de tipo → Config registra: antes t3.micro, ahora t3.large, timestamp, quién
S3 cambia policy  → Config registra: policy anterior, nueva policy, timestamp
```

### 2. Config Rules

Reglas que evalúan si los recursos cumplen con la configuración deseada.

| Tipo | Descripción | Ejemplo |
|------|-------------|---------|
| **Managed Rules** | Reglas predefinidas por AWS | `restricted-ssh`, `s3-bucket-public-read-prohibited` |
| **Custom Rules (Lambda)** | Lógica personalizada en Lambda | "todos los EC2 deben tener tag `Environment`" |
| **Proactive Rules** | Evalúan antes de crear el recurso | Integración con CloudFormation Guard |

**Triggers de evaluación:**
- `Configuration change` → se evalúa cada vez que el recurso cambia
- `Periodic` → se evalúa cada hora, 3h, 6h, 12h o 24h

### 3. Config Remediation

Cuando una regla detecta un recurso `NON_COMPLIANT`, puede ejecutar una acción de remediación:

- **SSM Automation Documents** → documentos predefinidos de AWS (ej: `AWS-DisablePublicAccessForSecurityGroup`)
- **Lambda functions** → lógica personalizada

---

## Flujo completo

```
Recurso crea/modifica
        ↓
Config Recorder captura el cambio
        ↓
Config Rule evalúa: COMPLIANT / NON_COMPLIANT
        ↓ (si NON_COMPLIANT)
Remediation Action se ejecuta (manual o automática)
        ↓
Recurso vuelve a COMPLIANT
        ↓
Config registra el nuevo estado
```

---

## Config Aggregator

Permite ver el estado de compliance de **múltiples cuentas y regiones** desde una única vista centralizada.

**Lo que PUEDE hacer:**
- Ver findings de compliance de todas las cuentas
- Ver el historial de cambios de recursos en todas las cuentas
- Generar informes de compliance agregados

**Lo que NO PUEDE hacer:**
- Ejecutar remediaciones cross-account directamente
- Modificar recursos en cuentas miembro

**Para remediar cross-account:** necesitas un SSM Automation Document que use `AssumeRole` en cada cuenta destino.

---

## Diferencia con otros servicios

| Pregunta | Servicio |
|---------|---------|
| ¿El puerto 22 está abierto en mis SGs? | **Config** (regla `restricted-ssh`) |
| ¿Hay actividad sospechosa de SSH? | **GuardDuty** |
| ¿Mis EC2 tienen vulnerabilidades? | **Inspector** |
| ¿Hay datos PII en mis buckets? | **Macie** |
| ¿Cuántos findings de seguridad tengo? | **Security Hub** |

---

## Diferencia crítica: Remediation automática vs EventBridge + Lambda

Ambos patrones pueden "remediar automáticamente" un problema, pero son conceptualmente distintos:

| Aspecto | Config Automatic Remediation | EventBridge + Lambda |
|---------|------------------------------|----------------------|
| **Cuándo** | Integrado en Config, se activa al detectar NON_COMPLIANT | Reacciona a cualquier evento AWS |
| **Cómo** | SSM Automation Document (nativo) | Lambda con lógica custom |
| **Retries** | Configurable (máx. intentos, cooldown) | Configurable en EventBridge |
| **Alcance** | Solo recursos evaluados por Config | Cualquier evento de cualquier servicio |
| **Cuándo usarlo** | Remediación de compliance de configuración | Automatización general de eventos |

**Ejemplo SAA-C03:** "Cuando un Security Group abra el puerto 22 a internet, cerrarlo automáticamente" → Config Automatic Remediation con `AWS-DisablePublicAccessForSecurityGroup`.

---

## Analogía DevOps

Config ≈ **auditoría continua de infraestructura como código**

Es como tener un linter que ejecuta continuamente sobre tu infraestructura real (no el código) y te avisa cuando el estado actual difiere del estado deseado. Y si configuras remediation, es como un auto-fix que corrige las desviaciones automáticamente.

---

## Coste

| Componente | Precio |
|-----------|--------|
| Config items registrados | $0.003 por item de configuración |
| Config Rules evaluaciones | $0.001 por evaluación de regla |
| Primeras reglas gestionadas | Gratis (tier inicial) |
| SSM Automation Remediation | $0.00025 por step de automatización |

Para un lab de 1-2 horas: **~$2-3 total**.
