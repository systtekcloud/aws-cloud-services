# Lab 05 — Scenarios SAA-C03

Escenarios de examen sobre AWS Security Hub, gestión de findings y compliance.

---

## Escenario 1 — Partner de seguridad autorizado genera findings

**Contexto:** Una empresa usa un producto de seguridad de tercero (CrowdStrike) que está integrado con Security Hub. Este producto genera findings del tipo `Software and Configuration Checks/Vulnerabilities/CVE` en todos los servidores de desarrollo. El equipo sabe que los servidores de dev tienen vulnerabilidades aceptadas intencionalmente (ciclos de parcheo más lentos). Quieren que estos findings no contaminen el dashboard principal.

**Pregunta:** ¿Cuál es la solución más adecuada?

**Opciones:**
- A) Deshabilitar la integración de CrowdStrike con Security Hub para el entorno de dev
- B) Crear una Automation Rule (Suppression Rule) con criterio: ProductName=CrowdStrike AND Tags.Environment=dev → estado SUPPRESSED
- C) Deshabilitar el control de vulnerabilidades en el estándar CIS
- D) Crear un filtro de búsqueda y revisar manualmente cada semana

**Respuesta correcta: B**

**Explicación:**
- **Automation Rule con SUPPRESSED** es el patrón correcto para findings que son conocidos y aceptados condicionalmente. Los findings se siguen creando (auditoría completa), pero no aparecen en el dashboard principal ni afectan el Security Score.
- La opción A deshabilitaría la visibilidad de CrowdStrike también para producción — exceso de supresión.
- La opción C deshabilita el control para TODOS los recursos, no solo para dev.
- La opción D requiere intervención manual — no escala.

**Pista SAA-C03:** finding conocido y recurrente + criterio basado en atributos = **Automation Rule con SUPPRESSED**.

---

## Escenario 2 — Security Hub vs Amazon Detective

**Contexto:** El CISO de una empresa necesita dos cosas:
1. Un dashboard que muestre el estado de seguridad global de la cuenta y cuántos controles están fallando vs el benchmark CIS.
2. Después de detectar un acceso sospechoso, entender exactamente qué hizo el atacante: qué APIs llamó, desde qué IPs y en qué orden temporal.

**Pregunta:** ¿Qué servicio corresponde a cada necesidad?

**Opciones:**
- A) Security Hub para ambas
- B) Detective para ambas
- C) Security Hub para la necesidad 1, Detective para la necesidad 2
- D) CloudTrail para ambas, con consultas Athena

**Respuesta correcta: C**

**Explicación:**
- **Security Hub** responde a "¿cuál es mi postura de seguridad?". Proporciona el Security Score, controles fallidos vs CIS/FSBP, y vista agregada de findings de múltiples servicios.
- **Detective** responde a "¿qué pasó exactamente?". Correlaciona CloudTrail + VPC Flow Logs + GuardDuty para generar un grafo de relaciones y línea temporal del incidente.
- CloudTrail (opción D) tiene los logs en bruto pero requiere consultas manuales — no escala para investigación forense rápida.

**Pista SAA-C03:** "postura de seguridad / compliance / score" = Security Hub. "investigar incidente / qué pasó / forense" = Detective.

---

## Escenario 3 — Deshabilitar control vs Suppression Rule

**Contexto:** Una empresa tiene dos situaciones:

**Situación A:** Usa AWS KMS con CMKs propias para todas las instancias EC2. El control `EC2.7 - EBS default encryption should be enabled` está fallando porque tienen un proceso alternativo de cifrado. El control no aplica a su arquitectura.

**Situación B:** Un bucket S3 específico (`access-logs-bucket`) está correctamente configurado como público (aloja logs de acceso web que deben ser públicos). El control `S3.2 - S3 buckets should prohibit public read access` falla solo para ese bucket.

**Pregunta:** ¿Qué acción tomar en cada situación?

**Respuesta:**

- **Situación A → Deshabilitar el control** con `DisabledReason: "Compensating control: CMKs en KMS para todo EBS"`. El control no aplica en absoluto a esta arquitectura, por lo que no debe evaluarse.

- **Situación B → Automation Rule con SUPPRESSED** filtrando por `Resources.Id = arn:aws:s3:::access-logs-bucket`. El control sigue siendo válido para el resto de buckets — solo se suprime el finding de ese bucket específico.

```
Regla de decisión:
¿El control aplica a algún recurso de tu cuenta?
  NO → Deshabilitar control
  SÍ, pero hay una excepción específica → Automation Rule (SUPPRESSED)
```

---

## Escenario 4 — Arquitectura multi-cuenta con Security Hub

**Contexto:** Una empresa con 20 cuentas AWS necesita:
- Vista centralizada de todos los findings de seguridad desde una cuenta de Security central
- El Security Score agregado de todas las cuentas
- Capacidad de gestionar findings de cuentas miembro desde la cuenta central

**Pregunta:** ¿Cómo configurar Security Hub para este escenario?

**Opciones:**
- A) Usar Config Aggregator en la cuenta central
- B) Configurar Security Hub en modo delegated administrator via AWS Organizations, designando la cuenta Security como administrador
- C) Instalar un agente en cada cuenta que envíe findings a la cuenta central
- D) Usar CloudWatch Cross-Account Observability

**Respuesta correcta: B**

**Explicación:**
- **Security Hub con delegated administrator** (via Organizations) permite designar una cuenta como administrador que recibe automáticamente los findings de todas las cuentas miembro. Desde la cuenta administradora se pueden gestionar findings, crear Automation Rules y ver el Security Score agregado.
- Config Aggregator (opción A) solo agrega datos de Config, no de GuardDuty/Inspector/Macie/etc.
- Las opciones C y D no son los mecanismos correctos para Security Hub.

**Configuración CLI (referencia):**
```bash
# En la cuenta de Organizations management:
aws securityhub enable-organization-admin-account \
  --admin-account-id "SECURITY_ACCOUNT_ID" \
  --region eu-west-1

# En la cuenta Security (ahora administradora):
aws securityhub update-organization-configuration \
  --auto-enable \
  --region eu-west-1
```

**Pista SAA-C03:** "Security Hub + múltiples cuentas + centralizado" = delegated administrator via Organizations.

---

## Tabla resumen SAA-C03

| Servicio | Pregunta que responde | Multi-cuenta |
|---------|----------------------|-------------|
| **Security Hub** | ¿Cuál es mi postura de seguridad global? | Sí — delegated admin via Organizations |
| **Config Aggregator** | ¿Compliance de Config Rules en múltiples cuentas? | Sí — pero solo Config Rules |
| **Detective** | ¿Qué pasó exactamente en este incidente? | Sí — con behavior graph |
| **GuardDuty** | ¿Hay amenazas activas ahora? | Sí — Organizations admin |

**Para recordar:**
- Security Hub = **agregador de findings** (no detecta)
- Detective = **investigación forense** (no agrega)
- Ambos necesitan GuardDuty activo para ser útiles
