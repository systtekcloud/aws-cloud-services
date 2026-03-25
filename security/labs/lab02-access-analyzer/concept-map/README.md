# IAM Access Analyzer — Concept Map

> **Coste:** GRATIS siempre | **Región:** eu-west-1

---

## Qué es IAM Access Analyzer

IAM Access Analyzer analiza automáticamente las **resource-based policies** de tu cuenta para detectar accesos externos no intencionados. Cuando una política permite acceso desde fuera de tu **zona de confianza** (trust zone), genera un **finding**.

No es un servicio de detección de amenazas (eso es GuardDuty) — es un auditor de **configuración de acceso**. Responde a la pregunta: *¿quién puede acceder a mis recursos desde fuera de mi cuenta/organización?*

---

## Zona de confianza (Trust Zone)

La zona de confianza define qué se considera "interno" vs "externo":

| Tipo de Analyzer | Zona de confianza | Cuándo usar |
|-----------------|-------------------|-------------|
| **Account** | Tu cuenta AWS | Cuenta standalone o sin Organizations |
| **Organization** | Toda la organización AWS | Multi-cuenta con AWS Organizations |

Si configuras un analyzer a nivel de **Account**, un rol que permite `AssumeRole` desde otra cuenta de tu organización generará un finding. Si lo configuras a nivel de **Organization**, ese mismo rol no genera finding porque está dentro de la zona de confianza.

---

## Recursos analizados

Access Analyzer analiza resource-based policies de estos servicios:

| Recurso | Qué detecta |
|---------|------------|
| **S3 Buckets** | Bucket policies y ACLs que permiten acceso externo |
| **IAM Roles** | Trust policies que permiten AssumeRole desde cuentas/servicios externos |
| **KMS Keys** | Key policies que permiten uso desde entidades externas |
| **Lambda Functions** | Resource-based policies que permiten invocación externa |
| **SQS Queues** | Queue policies con acceso cross-account |
| **Secrets Manager** | Resource policies en secretos |
| **SNS Topics** | Topic policies con acceso externo |

---

## Estados de los findings

| Estado | Qué significa | Cuándo usarlo |
|--------|--------------|---------------|
| **Active** | Acceso externo detectado, sin revisar | Estado inicial de todo finding |
| **Archived** | Revisado y marcado como intencionado | Acceso cross-account legítimo y documentado |
| **Resolved** | El acceso externo fue eliminado | Cuando remedias la configuración |

**Regla práctica:**
- `Archive` → el acceso es intencionado (ej: rol de auditoría cross-account autorizado)
- `Resolved` → el acceso era un error y lo corregiste

---

## Cuándo usar Archive vs Resolved

```
Situación: Bucket S3 con acceso a cuenta-partner-123456789

¿Es intencionado?
  Sí → Archive con nota: "Bucket compartido con Partner X, autorizado por ticket #456"
  No → Corregir la bucket policy → finding pasa automáticamente a Resolved
```

Access Analyzer **actualiza automáticamente** el estado:
- Si corriges una política → finding pasa a `Resolved` automáticamente
- Si el acceso sigue ahí y lo archivas → permanece en `Archived`

---

## Cómo funciona internamente

Access Analyzer usa **Zelkova**, un motor de razonamiento automático basado en SMT (Satisfiability Modulo Theories). Analiza las políticas matemáticamente para determinar si permiten acceso externo — no necesita tráfico real para detectar el problema.

Esto lo diferencia de GuardDuty (que analiza tráfico real) y de Config (que comprueba configuración contra reglas predefinidas).

---

## Analogía DevOps

Access Analyzer ≈ **auditoría de ACLs en un firewall**

Como hacer un `iptables -L` o revisar las reglas de un Security Group, pero para todas las resource-based policies de tu cuenta. En lugar de revisar manualmente cada bucket policy y trust policy, Access Analyzer lo hace automáticamente y te alerta cuando algo permite acceso desde fuera.

---

## Diferencia con otros servicios de seguridad

| Servicio | Qué detecta | Cuándo usarlo |
|---------|------------|---------------|
| **Access Analyzer** | Configuración de acceso (quién PUEDE acceder) | Auditoría preventiva de políticas |
| **GuardDuty** | Amenazas activas (quién ESTÁ accediendo de forma sospechosa) | Detección de intrusiones en runtime |
| **Macie** | Datos sensibles en S3 + configuración insegura de buckets | Cumplimiento GDPR/PII en S3 |
| **Config** | Compliance de configuración de recursos contra reglas | Auditoría continua de infraestructura |
| **Security Hub** | Agregador de findings de todos los servicios anteriores | Vista centralizada de seguridad |

---

## Tabla de decisión rápida (SAA-C03)

| Pregunta | Servicio |
|---------|---------|
| "¿Quién puede acceder a mis recursos desde fuera?" | Access Analyzer |
| "¿Hay actividad sospechosa en mi cuenta?" | GuardDuty |
| "¿Tengo datos PII expuestos en S3?" | Macie |
| "¿Mis recursos cumplen las políticas de seguridad?" | Config |
| "¿Cuántos findings críticos tengo en total?" | Security Hub |
