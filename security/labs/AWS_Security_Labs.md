# AWS Security Services — Labs Prácticos

> **Módulo:** `security/labs/` — Prompts para Claude Code  
> **Repo:** github.com/systtekcloud/aws-cloud-services  
> **Región:** eu-west-1 | **Stack:** AWS CLI v2 + Terraform ≥ 1.7

---

## Estado del módulo

| Lab | Servicio | Estado | Free Trial | Carpeta |
|-----|----------|--------|------------|---------|
| lab01 | Security Governance (Organizations + SCPs + Identity Center + Logging + Config + Secrets) | ✅ **COMPLETADO** | — | `lab01-security-governance/` |
| lab02 | IAM Access Analyzer | ⏳ Pendiente | GRATIS siempre | `lab02-access-analyzer/` |
| lab03 | AWS Config + Remediation | ⏳ Pendiente | Primeras reglas gratis | `lab03-config/` |
| lab04 | Amazon GuardDuty | ⏳ Pendiente | 30 días | `lab04-guardduty/` |
| lab05 | AWS Security Hub | ⏳ Pendiente | 30 días | `lab05-security-hub/` |
| lab06 | Amazon Inspector | ⏳ Pendiente | 30 días | `lab06-inspector/` |
| lab07 | Amazon Macie | ⏳ Pendiente | 30 días | `lab07-macie/` |
| lab08 | Amazon Detective | ⏳ Pendiente | 30 días | `lab08-detective/` |

> ⚠️ **Estrategia de free trials:** Activar GuardDuty primero (lab04) — es prerequisito para Security Hub (lab05) y Detective (lab08). Activar los tres el mismo día para maximizar los 30 días de trial. Inspector y Macie pueden activarse en sesiones separadas.

> ℹ️ **Sobre lab03-config:** lab01 ya cubre Config básico en fase-05. Lab03 es intencionadamente completo y profundo — cubre Config Rules avanzadas, Remediation automática via SSM y Config Aggregator, que no están en lab01.

---

## Lab 02 — IAM Access Analyzer

**Por qué:** GRATIS, sin prerequisitos, concepto débil identificado en simulacros SAA-C03.  
**Coste:** GRATIS siempre  
**Tiempo estimado:** 45-60 minutos

### Prompt para Claude Code

```
Contexto: Repo aws-cloud-services en github.com/systtekcloud/aws-cloud-services
Mismo estilo que lab01-security-governance ya existente en security/labs/.
Región: eu-west-1. Herramientas: AWS CLI v2 + Terraform >= 1.7

Crea el módulo security/labs/lab02-access-analyzer/ con esta estructura:

1. concept-map/README.md:
   - Qué es IAM Access Analyzer y qué detecta
   - Zona de confianza: cuenta vs organización
   - Tipos de recursos analizados (S3, IAM roles, KMS, Lambda, SQS)
   - Estados de findings: Active, Archived, Resolved
   - Cuándo usar Archive vs Resolved
   - Analogía DevOps: Access Analyzer ≈ auditoría de accesos en un firewall

2. labs/01-setup/README.md:
   - Crear Access Analyzer a nivel de cuenta (zona de confianza: cuenta)
   - Comandos AWS CLI paso a paso con output esperado
   - Verificar que el analyzer está activo
   - Script de validación: validate.sh

3. labs/02-findings/README.md:
   - Crear un S3 bucket con bucket policy que permite acceso a otra cuenta
   - Verificar que Access Analyzer genera finding
   - Gestionar el finding: Archive con razón documentada
   - Simular remediación: eliminar el acceso externo → finding Resolved automático
   - Comandos CLI para listar, filtrar y gestionar findings

4. labs/03-bucket-exposed/README.md:
   - Crear bucket con s3:GetObject a Principal: *
   - Block Public Access: OFF
   - Verificar finding generado por Access Analyzer
   - Comparar con finding de Macie (Policy:) — misma detección, distinto servicio
   - Remediar: habilitar BPA + eliminar Principal: *

5. labs/04-cross-account/README.md:
   - Crear IAM Role con trust policy que permite AssumeRole desde otra cuenta
   - Verificar finding de Access Analyzer en el rol
   - Documentar cuándo es intencionado (Archive) vs problema real

6. terraform/main.tf:
   - aws_accessanalyzer_analyzer resource
   - S3 bucket de prueba con bucket policy parametrizable
   - IAM Role de prueba con trust policy configurable
   - Outputs: analyzer ARN, bucket ARN, role ARN

7. scenarios/README.md:
   - 3 escenarios típicos del SAA-C03 relacionados con Access Analyzer
   - Para cada uno: situación, servicio correcto y por qué

8. cleanup.md:
   - Comandos para eliminar todos los recursos creados en el lab
   - Mismo formato que cleanup.md de lab01

Coste estimado: GRATIS (Access Analyzer no tiene coste)
Tiempo estimado: 45-60 minutos
```

---

## Lab 03 — AWS Config + Remediation

**Por qué:** Config Remediation automática fue fallo en simulacro. Config Aggregator es concepto débil. Lab01 cubre Config básico — este lab es completo y profundo.  
**Coste:** ~$2-3 por lab completo  
**Tiempo estimado:** 90-120 minutos

### Prompt para Claude Code

```
Contexto: Repo aws-cloud-services en github.com/systtekcloud/aws-cloud-services
Mismo estilo que lab01-security-governance ya existente en security/labs/.
Región: eu-west-1. Herramientas: AWS CLI v2 + Terraform >= 1.7

NOTA: lab01 cubre Config básico en fase-05. Este lab es intencionadamente
completo y profundo — cubre Config Rules avanzadas, Remediation automática
via SSM y Config Aggregator, que no están en lab01.

Crea el módulo security/labs/lab03-config/ con esta estructura:

1. concept-map/README.md:
   - Qué es AWS Config y qué registra
   - Triggers: Configuration change vs Periodic
   - Config Rules: managed vs custom (Lambda)
   - Config Remediation: SSM Automation Documents vs Lambda
   - Diferencia clave: Config = compliance configuración (no amenazas)
   - Config Aggregator: solo lectura cross-account — NO puede remediar
   - Analogía DevOps: Config ≈ auditoría continua de infraestructura como código

2. labs/01-setup/README.md:
   - Habilitar AWS Config con delivery channel a S3
   - Configurar IAM Role para Config
   - Verificar que Config empieza a registrar recursos
   - Explorar el historial de configuración de un recurso existente
   - Script validate.sh

3. labs/02-rules/README.md:
   - Añadir managed rule: restricted-ssh (puerto 22 no abierto a internet)
   - Crear Security Group que viole la regla
   - Verificar que Config marca el SG como NON_COMPLIANT
   - Añadir managed rule: s3-bucket-public-read-prohibited
   - Crear bucket público y verificar NON_COMPLIANT
   - Explorar el timeline de compliance de un recurso

4. labs/03-remediation/README.md:
   - Configurar Automatic Remediation en la regla restricted-ssh
   - Remediation Action: SSM Automation Document AWS-DisablePublicAccessForSecurityGroup
   - Verificar que al crear un SG con puerto 22 abierto:
     1. Config detecta NON_COMPLIANT
     2. Remediation se ejecuta automáticamente
     3. SG queda COMPLIANT sin intervención manual
   - IMPORTANTE: documentar diferencia entre:
     Automatic Remediation (nativo en Config) vs EventBridge + Lambda (patrón genérico)

5. labs/04-custom-rule/README.md:
   - Crear Lambda custom rule que verifica que EC2 tiene tag 'Environment'
   - Si no tiene el tag: NON_COMPLIANT
   - Configurar remediation via Lambda que añade el tag automáticamente
   - Probar con EC2 sin tag y verificar el flujo completo

6. labs/05-aggregator/README.md:
   - Crear Config Aggregator en la cuenta actual
   - Entender qué puede y qué NO puede hacer el Aggregator:
     PUEDE: ver estado de compliance de múltiples cuentas/regiones
     NO PUEDE: ejecutar remediación cross-account directamente
   - Para remediar cross-account: SSM Automation + AssumeRole
   - Documentar el patrón completo de remediación centralizada

7. terraform/main.tf:
   - aws_config_configuration_recorder
   - aws_config_delivery_channel
   - aws_config_config_rule para restricted-ssh y s3-bucket-public-read-prohibited
   - aws_config_remediation_configuration
   - S3 bucket para delivery channel
   - IAM roles necesarios

8. scenarios/README.md:
   - 4 escenarios SAA-C03 sobre Config
   - Incluir: Config vs GuardDuty vs Inspector — cuándo usar cada uno
   - Incluir: Config Aggregator — qué puede y qué no puede hacer
   - Incluir: Automatic Remediation vs EventBridge + Lambda

9. cleanup.md:
   - Comandos para eliminar todos los recursos creados
   - Mismo formato que cleanup.md de lab01

Coste estimado: ~$2-3 por lab completo
Tiempo estimado: 90-120 minutos
```

---

## Lab 04 — Amazon GuardDuty

**Por qué:** Servicio de detección más frecuente en SAA-C03. Trusted IP Lists y Suppression Rules son conceptos testados. Prerequisito para lab05 y lab08.  
**Coste:** GRATIS durante 30 días de free trial  
**Tiempo estimado:** 90 minutos

### Prompt para Claude Code

```
Contexto: Repo aws-cloud-services en github.com/systtekcloud/aws-cloud-services
Mismo estilo que lab01-security-governance ya existente en security/labs/.
Región: eu-west-1. Herramientas: AWS CLI v2 + Terraform >= 1.7

⚠️ IMPORTANTE: GuardDuty tiene 30 días de free trial.
Activar solo cuando se vaya a ejecutar el lab.
Este lab es prerequisito para lab05-security-hub y lab08-detective.

Crea el módulo security/labs/lab04-guardduty/ con esta estructura:

1. concept-map/README.md:
   - Qué es GuardDuty y qué detecta (no configura, no bloquea)
   - Fuentes de datos: VPC Flow Logs, CloudTrail, DNS Logs, S3 Logs, EKS
   - Tipos de findings: UnauthorizedAccess, Recon, Trojan, CryptoCurrency...
   - Trusted IP List vs Threat IP List — diferencia clave
   - Suppression Rules vs Archive manual
   - Patrón de respuesta: GuardDuty → EventBridge → Lambda + SNS
   - Analogía DevOps: GuardDuty ≈ IDS/IPS en la capa de red

2. labs/01-setup/README.md:
   - Habilitar GuardDuty via CLI
   - Generar finding de prueba: aws guardduty create-sample-findings
   - Explorar la estructura de un finding: tipo, severidad, recurso afectado
   - Script validate.sh

3. labs/02-trusted-ips/README.md:
   - Crear archivo de Trusted IP List en S3
   - Activar Trusted IP List en GuardDuty
   - Verificar que GuardDuty no genera findings para esas IPs
   - Crear Threat IP List con IPs de prueba
   - Documentar: cuándo usar Trusted IP List vs Suppression Rules

4. labs/03-suppression/README.md:
   - Crear Suppression Rule para un tipo de finding específico
   - Filtrar por: finding type + resource type
   - Verificar que los findings se crean pero aparecen como Archived
   - Caso de uso: equipo de pentest genera findings → Suppression vs Trusted IP

5. labs/04-remediation/README.md:
   - Crear EventBridge Rule que reacciona a finding GuardDuty severity HIGH
   - Target 1: Lambda que aísla la EC2 (cambia SG a quarantine)
   - Target 2: SNS que notifica al equipo
   - Probar con sample finding de severidad HIGH
   - Verificar el flujo completo: finding → EventBridge → Lambda + SNS
   - IMPORTANTE: documentar por qué GuardDuty no puede invocar SNS directamente

6. terraform/main.tf:
   - aws_guardduty_detector
   - aws_guardduty_ipset (Trusted IP List)
   - aws_guardduty_threatintelset
   - aws_guardduty_filter (Suppression Rule)
   - aws_cloudwatch_event_rule + aws_cloudwatch_event_target (EventBridge)
   - aws_lambda_function para remediación
   - aws_sns_topic para notificaciones
   - IAM roles necesarios

7. scenarios/README.md:
   - 4 escenarios SAA-C03 sobre GuardDuty
   - Incluir: GuardDuty vs Macie vs Inspector — cuándo usar cada uno
   - Incluir: respuesta a incidente con credenciales IAM comprometidas

8. cleanup.md:
   - Comandos para eliminar todos los recursos creados
   - Mismo formato que cleanup.md de lab01

Coste: GRATIS durante 30 días de free trial
Tiempo estimado: 90 minutos
```

---

## Lab 05 — AWS Security Hub

**Por qué:** Gestión de findings y Suppression Rules fue fallo en simulacro. Vista centralizada multi-cuenta es frecuente en SAA-C03.  
**Coste:** GRATIS durante 30 días de free trial  
**Tiempo estimado:** 60 minutos  
**Prerequisito:** lab04-guardduty activo

### Prompt para Claude Code

```
Contexto: Repo aws-cloud-services en github.com/systtekcloud/aws-cloud-services
Mismo estilo que lab01-security-governance ya existente en security/labs/.
Región: eu-west-1. Herramientas: AWS CLI v2 + Terraform >= 1.7

⚠️ IMPORTANTE: Security Hub tiene 30 días de free trial.
⚠️ PREREQUISITO: GuardDuty habilitado (lab04). Sin GuardDuty Security Hub
   tendrá muy pocos findings para trabajar.

Crea el módulo security/labs/lab05-security-hub/ con esta estructura:

1. concept-map/README.md:
   - Qué es Security Hub — agregador de findings, NO detector
   - Fuentes: GuardDuty, Macie, Inspector, Config, Access Analyzer + terceros
   - Security Score: cómo se calcula
   - Estándares: AWS FSBP, CIS Benchmark, PCI-DSS
   - Estados de findings: Active, Suppressed, Resolved
   - Suppression Rules: automáticas para casos conocidos
   - Diferencia clave: Security Hub (vista agregada) vs Detective (investigación)

2. labs/01-setup/README.md:
   - Habilitar Security Hub
   - Activar estándar: AWS Foundational Security Best Practices
   - Activar estándar: CIS AWS Foundations Benchmark
   - Verificar que findings de GuardDuty aparecen en Security Hub
   - Explorar el Security Score inicial
   - Script validate.sh

3. labs/02-findings/README.md:
   - Explorar findings agregados de múltiples servicios
   - Filtrar findings por: severidad, servicio, tipo de recurso
   - Gestionar un finding: cambiar estado a Suppressed con razón documentada
   - Gestionar un finding: cambiar estado a Resolved tras remediación
   - Crear Suppression Rule automática para un tipo de finding recurrente
   - Documentar diferencia: Suppressed (conocido) vs Resolved (remediado)

4. labs/03-standards/README.md:
   - Explorar controles fallidos del CIS Benchmark
   - Remediar un control fallido (ej: MFA en root, CloudTrail habilitado)
   - Verificar que el Security Score mejora tras la remediación
   - Deshabilitar un control específico con justificación documentada
   - Documentar: deshabilitar control vs Suppression Rule — diferencia

5. terraform/main.tf:
   - aws_securityhub_account
   - aws_securityhub_standards_subscription (FSBP + CIS)
   - aws_securityhub_insight para findings personalizados
   - Outputs: hub ARN, standards ARNs

6. scenarios/README.md:
   - 4 escenarios SAA-C03 sobre Security Hub
   - Incluir: Security Hub vs Detective — cuándo usar cada uno
   - Incluir: gestión de finding conocido (partner autorizado) — Suppression vs Disable

7. cleanup.md:
   - Comandos para eliminar todos los recursos creados
   - Mismo formato que cleanup.md de lab01

Coste: GRATIS durante 30 días de free trial
Tiempo estimado: 60 minutos
```

---

## Lab 06 — Amazon Inspector

**Por qué:** Inspector Enhanced Scanning en ECR es concepto débil identificado. Patrón Inspector → EventBridge → pipeline es frecuente en SAA-C03.  
**Coste:** GRATIS durante 30 días de free trial  
**Tiempo estimado:** 75 minutos  
**Prerequisito:** ECR disponible (módulo ecs/ ya existente)

### Prompt para Claude Code

```
Contexto: Repo aws-cloud-services en github.com/systtekcloud/aws-cloud-services
Mismo estilo que lab01-security-governance ya existente en security/labs/.
Región: eu-west-1. Herramientas: AWS CLI v2 + Terraform >= 1.7

⚠️ IMPORTANTE: Inspector tiene 30 días de free trial.
⚠️ PREREQUISITO: ECR disponible (del módulo ecs/ ya existente en el repo).

Crea el módulo security/labs/lab06-inspector/ con esta estructura:

1. concept-map/README.md:
   - Qué es Inspector y qué escanea: EC2, ECR, Lambda
   - Enhanced Scanning vs Basic Scanning en ECR — diferencia crítica
   - Estructura de un finding: CVE, paquete, versión afectada, severidad
   - Patrón DevSecOps: Inspector → EventBridge → parar pipeline
   - Diferencia: Inspector (vulnerabilidades) vs GuardDuty (amenazas activas)
   - Analogía DevOps: Inspector ≈ vulnerability scanning en CI/CD pipeline

2. labs/01-ec2-scanning/README.md:
   - Habilitar Inspector
   - Lanzar EC2 con SSM Agent (prerequisito para Inspector en EC2)
   - Verificar que Inspector escanea la instancia automáticamente
   - Explorar findings: CVEs en paquetes instalados
   - Filtrar findings por severidad CRITICAL y HIGH
   - Script validate.sh

3. labs/02-ecr-scanning/README.md:
   - Habilitar Enhanced Scanning en ECR (no Basic Scanning)
   - Push de imagen con vulnerabilidades conocidas (usar imagen antigua)
   - Verificar que Inspector genera findings en el push
   - Explorar findings: CVE ID, paquete afectado, versión con fix
   - Documentar diferencia: Enhanced (Inspector) vs Basic (ECR nativo)

4. labs/03-pipeline-integration/README.md:
   - Crear EventBridge Rule: Inspector finding severity=CRITICAL en ECR
   - Target 1: Lambda que simula detener el pipeline
     (en producción llamaría API de GitHub Actions/GitLab CI)
   - Target 2: SNS notificación al equipo con detalle del CVE
   - Probar el flujo completo: push imagen vulnerable → finding → Lambda + SNS
   - Documentar: por qué Inspector no puede invocar SNS directamente

5. terraform/main.tf:
   - aws_inspector2_enabler
   - aws_ecr_repository con image_scanning_configuration
   - aws_cloudwatch_event_rule para Inspector findings
   - aws_lambda_function para notificación/remediación
   - aws_sns_topic
   - IAM roles necesarios

6. scenarios/README.md:
   - 3 escenarios SAA-C03 sobre Inspector
   - Incluir: Inspector + pipeline CI/CD — arquitectura completa
   - Incluir: Inspector vs GuardDuty vs Config — tabla comparativa

7. cleanup.md:
   - Comandos para eliminar todos los recursos creados
   - Mismo formato que cleanup.md de lab01

Coste: GRATIS durante 30 días de free trial
Tiempo estimado: 75 minutos
```

---

## Lab 07 — Amazon Macie

**Por qué:** Confusión entre `Policy:` vs `SensitiveData:` identificada en simulacros. Clasificación de datos en S3 es frecuente en SAA-C03.  
**Coste:** GRATIS durante 30 días de free trial  
**Tiempo estimado:** 60 minutos

### Prompt para Claude Code

```
Contexto: Repo aws-cloud-services en github.com/systtekcloud/aws-cloud-services
Mismo estilo que lab01-security-governance ya existente en security/labs/.
Región: eu-west-1. Herramientas: AWS CLI v2 + Terraform >= 1.7

⚠️ IMPORTANTE: Macie tiene 30 días de free trial.

Crea el módulo security/labs/lab07-macie/ con esta estructura:

1. concept-map/README.md:
   - Qué es Macie: clasifica CONTENIDO y detecta CONFIGURACIÓN insegura en S3
   - DOS categorías de findings — distinción crítica para el examen:
     SensitiveData:  → inspecciona CONTENIDO del objeto
                       PII, financiero, credenciales, PHI
     Policy:         → inspecciona CONFIGURACIÓN del bucket
                       bucket público, cross-account, cifrado deshabilitado
   - Automated Discovery vs Discovery Jobs
   - Cómo leer el prefijo del finding para elegir la remediación correcta
   - Diferencia: Macie (S3 content+config) vs Access Analyzer (resource policies)

2. labs/01-setup/README.md:
   - Habilitar Macie
   - Explorar Automated Discovery
   - Crear S3 bucket con datos de prueba (no datos reales)
   - Script validate.sh

3. labs/02-sensitive-data/README.md:
   - Crear archivo CSV con datos FICTICIOS que simulen PII
     (nombres, emails, teléfonos inventados — nunca datos reales)
   - Subir al bucket de prueba
   - Crear Discovery Job sobre el bucket
   - Verificar finding: SensitiveData:S3Object/Personal
   - Explorar el finding: qué tipo de dato detectó, en qué objeto

4. labs/03-policy-findings/README.md:
   - Crear bucket con Block Public Access OFF + bucket policy Allow Principal: *
   - Verificar finding: Policy:IAMUser/S3BucketPubliclyAccessible
   - DOCUMENTAR la diferencia clave:
     Policy: finding      → remediación = corregir CONFIGURACIÓN
     SensitiveData: finding → remediación = proteger/eliminar CONTENIDO
   - Remediar: habilitar BPA + eliminar Allow Principal: *
   - Verificar que el finding pasa a Resolved

5. terraform/main.tf:
   - aws_macie2_account
   - aws_macie2_classification_job
   - S3 buckets de prueba con configuraciones diferentes
   - IAM roles necesarios

6. scenarios/README.md:
   - 3 escenarios SAA-C03 sobre Macie
   - Incluir: leer tipo de finding (prefijo) para elegir remediación
   - Incluir: Macie vs Access Analyzer para detectar buckets públicos

7. cleanup.md:
   - Comandos para eliminar todos los recursos creados
   - Mismo formato que cleanup.md de lab01

Coste: GRATIS durante 30 días de free trial
Tiempo estimado: 60 minutos
```

---

## Lab 08 — Amazon Detective

**Por qué:** Detective vs CloudTrail es confusión frecuente en SAA-C03. Investigación forense post-incidente es patrón clave.  
**Coste:** GRATIS durante 30 días de free trial  
**Tiempo estimado:** 45 minutos (+ 24-48h para que el grafo madure)  
**Prerequisito:** lab04-guardduty activo y con findings

### Prompt para Claude Code

```
Contexto: Repo aws-cloud-services en github.com/systtekcloud/aws-cloud-services
Mismo estilo que lab01-security-governance ya existente en security/labs/.
Región: eu-west-1. Herramientas: AWS CLI v2 + Terraform >= 1.7

⚠️ IMPORTANTE: Detective tiene 30 días de free trial.
⚠️ PREREQUISITO OBLIGATORIO: GuardDuty habilitado (lab04) con findings generados.
   Sin GuardDuty, Detective no tiene datos útiles para investigar.
⚠️ NOTA: Detective necesita 24-48h para construir el behavior graph inicial.
   Planificar el lab con ese margen.

Crea el módulo security/labs/lab08-detective/ con esta estructura:

1. concept-map/README.md:
   - Qué es Detective: correlación automática para investigación forense
   - Fuentes que ingiere: CloudTrail + VPC Flow Logs + GuardDuty findings
   - Qué proporciona: grafo de relaciones, línea temporal, contexto
   - Diferencia CRÍTICA para el examen:
     CloudTrail → logs en bruto, búsqueda manual
     Detective  → correlación automática, investigación visual
   - Diferencia: Detective (investigar) vs Security Hub (agregar findings)
   - Cuándo usar Detective: 'qué pasó exactamente', 'alcance del ataque'
   - Analogía DevOps: Detective ≈ distributed tracing para incidentes de seguridad

2. labs/01-setup/README.md:
   - Habilitar Detective
   - Verificar que ingiere datos de GuardDuty
   - Explorar el behavior graph — qué entidades ve
   - Nota: esperar 24-48h antes de continuar con el lab 02
   - Script validate.sh

3. labs/02-investigation/README.md:
   - Generar sample findings en GuardDuty
   - Desde un finding de GuardDuty → 'Investigate in Detective'
   - Explorar el grafo de la entidad afectada (EC2 o IAM principal)
   - Identificar: qué IPs se comunicaron, qué API calls se hicieron, cuándo
   - Documentar el flujo de investigación: finding → Detective → timeline → conclusión
   - Comparar con buscar lo mismo en CloudTrail manualmente

4. terraform/main.tf:
   - aws_detective_graph
   - Outputs: graph ARN

5. scenarios/README.md:
   - 3 escenarios SAA-C03 sobre Detective
   - Incluir: Detective vs CloudTrail — cuándo usar cada uno
   - Incluir: orden correcto de respuesta a incidente (snapshot → aislar → Detective)

6. cleanup.md:
   - Comandos para eliminar todos los recursos creados
   - Mismo formato que cleanup.md de lab01

Coste: GRATIS durante 30 días de free trial
Tiempo estimado: 45 minutos (+ 24-48h para que el grafo madure)
```

---

## Estructura final del módulo

```
security/labs/
├── lab01-security-governance/    ✅ COMPLETADO
│   ├── fase-00-diseno-objetivo.md
│   ├── fase-01-organizations-cuentas.md
│   ├── fase-02-identity-center.md
│   ├── fase-03-scps-validacion.md
│   ├── fase-04-logging-central.md
│   ├── fase-05-compliance-config.md
│   ├── fase-06-secretos-operacion.md
│   └── cleanup.md
├── lab02-access-analyzer/        ⏳ Pendiente (GRATIS — empezar aquí)
├── lab03-config/                 ⏳ Pendiente
├── lab04-guardduty/              ⏳ Pendiente (prerequisito para lab05 y lab08)
├── lab05-security-hub/           ⏳ Pendiente (prerequisito: lab04)
├── lab06-inspector/              ⏳ Pendiente
├── lab07-macie/                  ⏳ Pendiente
└── lab08-detective/              ⏳ Pendiente (prerequisito: lab04)
```

---

*Repo: github.com/systtekcloud/aws-cloud-services | Módulo: security/labs/*
