# Lab 07 — Amazon Macie: Mapa Conceptual

---

## Qué es Amazon Macie

Amazon Macie es un servicio de seguridad que usa machine learning para **descubrir, clasificar y proteger datos sensibles en Amazon S3**. Tiene dos dimensiones de análisis: el **contenido** de los objetos y la **configuración** de los buckets.

**Principio clave:** Macie analiza **S3 exclusivamente** — no escanea RDS, EFS, DynamoDB ni otros almacenes.

---

## Las dos categorías de findings — distinción crítica para SAA-C03

Esta es la distinción más testada en el examen sobre Macie:

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  CATEGORÍA 1: SensitiveData:                                                 │
│  ─────────────────────────────────────────────────────────────────          │
│  Inspecciona el CONTENIDO del objeto S3                                      │
│                                                                              │
│  Subtipos:                                                                   │
│  SensitiveData:S3Object/Personal          → PII (nombre, email, teléfono,  │
│                                              DNI, pasaporte)                 │
│  SensitiveData:S3Object/Financial         → Números de tarjeta, cuentas     │
│                                              bancarias, IBAN                 │
│  SensitiveData:S3Object/Credentials      → Passwords, API keys,             │
│                                              tokens de acceso                │
│  SensitiveData:S3Object/CustomIdentifier → Patrones definidos por ti        │
│                                              (ej: números de empleado)       │
│                                                                              │
│  Cuándo Macie lo detecta:                                                    │
│  → Cuando el OBJETO CONTIENE datos sensibles                                 │
│                                                                              │
│  Remediación correcta:                                                       │
│  → Proteger, cifrar o eliminar el CONTENIDO                                  │
│  → Mover el objeto a un bucket cifrado                                       │
│  → Restringir el acceso al objeto                                            │
├─────────────────────────────────────────────────────────────────────────────┤
│  CATEGORÍA 2: Policy:                                                        │
│  ─────────────────────────────────────────────────────────────────          │
│  Inspecciona la CONFIGURACIÓN del bucket                                     │
│                                                                              │
│  Subtipos:                                                                   │
│  Policy:IAMUser/S3BucketPubliclyAccessible → Bucket público (BPA off)       │
│  Policy:IAMUser/S3BucketEncryptionDisabled → Sin cifrado por defecto         │
│  Policy:IAMUser/S3BucketSharedExternally   → Acceso cross-account           │
│  Policy:IAMUser/S3BucketReplicatedExternally → Replicación a otra cuenta    │
│                                                                              │
│  Cuándo Macie lo detecta:                                                    │
│  → Cuando la CONFIGURACIÓN del bucket es insegura                            │
│                                                                              │
│  Remediación correcta:                                                       │
│  → Corregir la CONFIGURACIÓN del bucket                                      │
│  → Habilitar Block Public Access                                             │
│  → Habilitar cifrado por defecto (SSE-S3 o SSE-KMS)                         │
└─────────────────────────────────────────────────────────────────────────────┘

Regla mnemotécnica:
  El prefijo del finding te dice QUÉ remediar:
  SensitiveData: → el CONTENIDO es el problema → proteger/eliminar datos
  Policy:        → la CONFIGURACIÓN es el problema → corregir el bucket
```

---

## Automated Discovery vs Discovery Jobs

```
Automated Discovery                   Discovery Jobs
────────────────────────────          ────────────────────────────
Automático, continuo                  Manual, bajo demanda

- Macie elige qué objetos             - Tú defines el scope:
  muestrear                             buckets, prefijos, rangos
- Sampling inteligente                - Escaneo completo (sin sampling)
- Actualiza el inventory              - Para auditorías específicas
  de datos sensibles                  - Para compliance (GDPR, PCI)
- Siempre activo si está              - Se programa o lanza manualmente
  habilitado

Cuándo usar cada uno:
→ Automated: visión continua del        → Discovery Job: auditoría puntual
  landscape de datos sensibles            o escaneo exhaustivo de un bucket
```

---

## Cómo leer el prefijo del finding para elegir la remediación

```
Finding recibido: "Policy:IAMUser/S3BucketPubliclyAccessible"
                    ──────                ─────────────────────
                    Categoría             Subtipo
                    = CONFIGURACIÓN       = Bucket público

→ Acción: habilitar Block Public Access (no es problema del contenido)

Finding recibido: "SensitiveData:S3Object/Personal"
                    ─────────────                ────────
                    Categoría                    Subtipo
                    = CONTENIDO                  = PII

→ Acción: cifrar el objeto, restringir acceso, revisar quién subió el archivo
```

---

## Diferencia: Macie vs Access Analyzer para buckets públicos

Ambos pueden detectar buckets con acceso externo, pero con enfoque diferente:

```
┌─────────────────────────────────────────────────────────────────────────────┐
│              Macie                              Access Analyzer             │
│  ─────────────────────────────────     ─────────────────────────────────   │
│  "¿Hay datos sensibles expuestos?"      "¿La bucket policy permite acceso   │
│                                          externo?"                          │
│                                                                             │
│  Analiza:                               Analiza:                            │
│  - Configuración del bucket             - Resource-based policies           │
│  - CONTENIDO de los objetos             - Permisos IAM efectivos            │
│                                                                             │
│  Finding tipo:                          Finding tipo:                       │
│  Policy:IAMUser/S3BucketPubliclyAcc.    External access finding            │
│  SensitiveData:S3Object/Personal                                            │
│                                                                             │
│  Cuándo usar Macie:                     Cuándo usar Access Analyzer:        │
│  "¿Qué datos sensibles tengo en S3?"    "¿Qué recursos permiten acceso      │
│  "¿Hay PII expuesto?"                    a cuentas externas?"               │
└─────────────────────────────────────────────────────────────────────────────┘

Para SAA-C03:
  Pregunta sobre PII, datos financieros, credenciales en S3 → Macie
  Pregunta sobre acceso cross-account o políticas externas → Access Analyzer
  Las dos preguntas a la vez → ambos servicios complementarios
```

---

## Analogía DevOps

```
Macie ≈ DLP (Data Loss Prevention) en la nube

DLP tradicional (ej: Symantec DLP):       Amazon Macie:
─────────────────────────────────────     ─────────────────────────────────
- Escanea emails/documentos               - Escanea objetos S3
  buscando PII antes de salir              buscando PII
- Patrones: números tarjeta,              - Patrones: mismos tipos
  DNIs, contraseñas                         + Custom Identifiers
- Bloquea la transmisión                  - Genera findings (no bloquea)
  si detecta datos sensibles                → EventBridge → Lambda bloquea
- Configurado por el CISO                 - Automated Discovery continuo

En ambos casos: encuentras los datos ANTES de que salgan del perímetro
En Macie: el "perímetro" es S3 — si los datos llegan ahí ya están en S3,
pero Macie los encuentra para que puedas actuar antes de que sean accesibles
```
