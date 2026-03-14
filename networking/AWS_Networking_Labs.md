# AWS Networking Labs
### Prompt + Escenarios para Claude Code
**DATP-2028 · Post SAA-C03 · eu-west-1**

---

## 1. Cómo usar este documento

Este documento contiene el prompt base y 7 escenarios de lab de networking AWS listos para usar con Claude Code. Está pensado para el período post-examen SAA-C03, una vez completadas las certificaciones prioritarias.

### Flujo de trabajo

1. Copia el **Prompt Base** (Sección 2) en Claude Code (IDE)
2. Elige un escenario de la Sección 3 según el concepto que quieras practicar
3. Rellena los tres campos entre corchetes `[ ]` del prompt con los datos del escenario
4. Claude Code genera el código Terraform/Terragrunt completo
5. Ejecuta, valida el comportamiento y destruye (`terraform destroy`)

| Claude.ai (este entorno) | Claude Code (IDE) |
|--------------------------|-------------------|
| Diseño, teoría, decisiones de arquitectura | Implementación, código, ejecución de labs |

---

## 2. Prompt Base para Claude Code

Copia el bloque completo y rellena los campos entre corchetes `[ ]` antes de enviarlo.

```
# Lab de Networking AWS — Claude Code

## Contexto
Soy un DevOps Engineer preparando AWS SAA-C03 siguiendo el path
DATP-2028. Necesito un lab práctico de networking AWS para
consolidar conceptos vistos en estudio teórico.

## Escenario a implementar
[DESCRIBE AQUÍ el escenario — copia el campo 'Escenario'
 del documento de labs que corresponda]

## Concepto a demostrar
[ESPECIFICA el comportamiento exacto que quieres ver —
 copia el campo 'Demuestra' del escenario elegido]

## Stack obligatorio
- IaC: Terraform/Terragrunt (estructura modular)
- Cloud: AWS (cuenta personal de laboratorio)
- Region: eu-west-1 (salvo que el escenario requiera multi-region)
- Estado remoto: S3 backend (sin DynamoDB, usar S3 native locking)

## Requisitos del lab
1. Infraestructura mínima necesaria para demostrar el concepto
   (no over-engineer — foco en el concepto de red)
2. Outputs claros que permitan verificar que el lab funciona
3. Script de validación bash que compruebe conectividad
4. Comentarios en el código explicando el POR QUÉ de cada decisión
5. README con:
   - Diagrama de red en ASCII o Mermaid
   - Pasos de despliegue
   - Comandos de validación
   - Coste estimado y cómo destruir el lab

## Restricciones de coste
- Destruible en < 5 minutos (terraform destroy)
- Coste máximo estimado: < $2 si se destruye en < 2 horas
- Evitar recursos con coste fijo alto (NAT GW si no es necesario)
- Indicar explícitamente qué recursos tienen coste por hora

## Contexto adicional
- Sigo estructura multirepo con Terragrunt
- Certificaciones en curso: SAA-C03 (examen 1 abril 2026)

## [CAMPO OPCIONAL — contexto adicional del escenario]
[Añade aquí cualquier restricción o variante específica
 que quieras aplicar a este lab concreto]
```

---

## 3. Escenarios de Lab

7 escenarios ordenados por prioridad. Los de prioridad ALTA tienen mayor peso en el examen SAA-C03 y mayor valor para el portfolio.

---

### 🔴 Lab 1 — PrivateLink con CIDRs solapados `ALTA`

| Campo | Detalle |
|-------|---------|
| **Escenario** | Dos VPCs con CIDR `10.0.0.0/16` necesitan comunicarse entre sí sin modificar sus rangos de red |
| **Concepto** | EC2 en VPC-A conecta a servicio HTTP en VPC-B via NLB + PrivateLink Interface Endpoint, sin VPC Peering, sin modificar CIDRs |
| **Demuestra** | Que el tráfico fluye correctamente aunque los CIDRs sean idénticos. Que VPC Peering falla con CIDRs solapados y PrivateLink lo resuelve |
| **Coste est.** | < $0.50 en 1h (Interface Endpoint ~$0.01/h + EC2 t3.micro free tier) |

---

### 🔴 Lab 2 — Gateway Endpoint vs Interface Endpoint para S3 `ALTA`

| Campo | Detalle |
|-------|---------|
| **Escenario** | EC2 en subnet privada accede a S3. Dos configuraciones: con Gateway Endpoint y sin él (solo NAT Gateway) |
| **Concepto** | VPC Flow Logs habilitados. Una EC2 usa Gateway Endpoint, otra solo NAT Gateway. Se mide el tráfico en ambos casos |
| **Demuestra** | Con Gateway Endpoint el tráfico NO pasa por NAT Gateway (visible en Flow Logs). Sin él, todo el tráfico S3 consume NAT y genera coste adicional |
| **Coste est.** | < $0.30 en 1h (Gateway Endpoint gratuito. NAT GW $0.045/h solo si se incluye) |

---

### 🔴 Lab 3 — NAT Gateway multi-AZ y alta disponibilidad `ALTA`

| Campo | Detalle |
|-------|---------|
| **Escenario** | VPC con subnets privadas en `us-east-1a` y `us-east-1b`. Config A: NAT GW solo en `us-east-1a`. Config B: NAT GW en cada AZ |
| **Concepto** | Simular fallo de AZ (parar NAT GW de `us-east-1a`). Comparar comportamiento de subnet privada B en ambas configuraciones |
| **Demuestra** | Config A: `us-east-1b` pierde acceso a internet cuando `us-east-1a` falla. Config B: cada subnet es independiente. Cross-AZ genera coste adicional |
| **Coste est.** | < $0.20 en 1h (2x NAT GW $0.045/h cada uno — destruir rápido) |

---

### 🟡 Lab 4 — VPC Peering no transitivo vs Transit Gateway `MEDIA`

| Campo | Detalle |
|-------|---------|
| **Escenario** | 3 VPCs (A, B, C) con peerings A↔B y B↔C configurados. VPC-C intenta alcanzar VPC-A |
| **Concepto** | Verificar que C no puede alcanzar A con peering. Luego reemplazar los peerings por Transit Gateway y verificar conectividad completa |
| **Demuestra** | VPC Peering no es transitivo: A↔B y B↔C no implica A↔C. Transit Gateway actúa como hub y resuelve el problema para N VPCs |
| **Coste est.** | < $0.50 en 1h (TGW $0.05/h por attachment x3 + datos procesados) |

---

### 🟡 Lab 5 — Session Manager vs Bastion Host `MEDIA`

| Campo | Detalle |
|-------|---------|
| **Escenario** | EC2 en subnet privada sin puerto 22 abierto en Security Group. Sin Bastion Host. Sin acceso a internet directo |
| **Concepto** | Acceso completo a la EC2 via AWS Systems Manager Session Manager usando VPC Endpoints para SSM (sin internet) |
| **Demuestra** | Acceso shell completo sin SSH, sin Bastion Host, sin puerto 22. Solo con IAM Instance Profile + SSM Agent + 3 VPC Interface Endpoints |
| **Coste est.** | < $0.30 en 1h (3x Interface Endpoints $0.01/h cada uno + EC2 t3.micro) |

---

### 🟡 Lab 6 — NACL stateless con puertos efímeros `MEDIA`

| Campo | Detalle |
|-------|---------|
| **Escenario** | Subnet con NACL restrictivo. Caso A: regla outbound para puertos efímeros (1024-65535). Caso B: sin esa regla |
| **Concepto** | Servidor HTTPS en EC2. Cliente externo intenta conectar en ambos casos. VPC Flow Logs para visualizar tráfico aceptado/rechazado |
| **Demuestra** | Caso A: HTTPS funciona (entrada 443 + salida efímeros). Caso B: requests entran pero respuestas no salen. Diferencia clara con Security Groups (stateful) |
| **Coste est.** | < $0.10 en 1h (solo EC2 t3.micro — NACLs son gratuitos) |

---

### 🟢 Lab 7 — Interface Endpoint para S3 desde on-premises (simulado) `BAJA`

| Campo | Detalle |
|-------|---------|
| **Escenario** | Simular on-premises con una segunda VPC conectada via VPC Peering (simula Direct Connect). Probar Gateway Endpoint vs Interface Endpoint |
| **Concepto** | Desde la VPC 'on-premises', intentar acceder a S3 via Gateway Endpoint (falla) y via Interface Endpoint (funciona) |
| **Demuestra** | Gateway Endpoint no es accesible desde redes externas a la VPC. Interface Endpoint sí es accesible via VPC Peering/Direct Connect. Aplica al patrón Direct Connect + S3 |
| **Coste est.** | < $0.20 en 1h (1x Interface Endpoint $0.01/h + VPC Peering gratuito) |

---

## 4. Orden de ejecución recomendado

| Fase | Lab | Título | Motivo |
|------|-----|--------|--------|
| Post-examen inmediato | Lab 1 | PrivateLink con CIDRs solapados | Concepto avanzado, muy visual, frecuente en entrevistas |
| Post-examen inmediato | Lab 2 | Gateway vs Interface Endpoint S3 | Impacto en coste real, muy frecuente en SAA-C03 |
| Post-examen inmediato | Lab 3 | NAT Gateway multi-AZ | Patrón de producción real, HA fundamental |
| Profundización | Lab 4 | VPC Peering vs Transit Gateway | Escala a entornos enterprise, base para SCS-C02 |
| Profundización | Lab 5 | Session Manager | Best practice de seguridad, elimina Bastion Hosts |
| Profundización | Lab 6 | NACLs stateless | Refuerzo conceptual, errores frecuentes en examen |
| Profundización | Lab 7 | Interface Endpoint on-prem | Más complejo, relevante para Direct Connect |

---

## 5. Notas importantes

### Coste y seguridad
- Siempre ejecutar `terraform destroy` al terminar cada lab
- Configurar AWS Budget Alert en $5/mes en la cuenta de laboratorio
- Usar `eu-west-1` por defecto — es la región de trabajo principal
- Los Interface Endpoints tienen coste por hora — destruir si no se usan

### Integración con el repo
- Crear carpeta `/networking/labs` para estos labs
- Cada lab en su propia subcarpeta con README y diagrama
- No mezclar labs con infraestructura de producción del portfolio

### Relación con certificaciones
- **SAA-C03**: Labs 1, 2, 3, 4 refuerzan conceptos del examen directamente
- **SCS-C02** (siguiente): Labs 5, 6, 7 más relevantes para security specialty
- **ANS-C01** (futuro): Todos los labs son base para Advanced Networking Specialty

---

*DATP-2028 · AWS Networking Labs · Post SAA-C03*
