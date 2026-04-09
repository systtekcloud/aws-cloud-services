# Lab 06.01 — Inspector en EC2

> **Coste:** GRATIS durante 30 días de free trial | **Prerrequisito:** SSM Agent en la instancia EC2

---

## Objetivo

Habilitar Amazon Inspector, lanzar una EC2 con SSM Agent y verificar que Inspector escanea automáticamente los paquetes instalados, generando findings con CVEs.

---

## Prerrequisito: SSM Agent

Inspector usa SSM (Systems Manager) para comunicarse con las instancias EC2 **sin agente adicional**. La instancia necesita:
1. SSM Agent instalado (incluido por defecto en Amazon Linux 2023, Ubuntu 22.04, Windows)
2. IAM Instance Profile con `AmazonSSMManagedInstanceCore`
3. Conectividad a SSM endpoints (internet o VPC endpoints)

---

## Paso 1 — Habilitar Inspector

```bash
export AWS_REGION="eu-west-1"

# Habilitar Inspector para EC2 y ECR
aws inspector2 enable \
  --resource-types EC2 ECR \
  --region "$AWS_REGION"

echo "Inspector habilitado para EC2 y ECR"
```

```bash
# Verificar el estado
aws inspector2 describe-organization-configuration \
  --region "$AWS_REGION" 2>/dev/null || \
aws inspector2 list-coverage \
  --region "$AWS_REGION" \
  --query 'coveredResources[0]' \
  --output json 2>/dev/null || echo "Inspector iniciando..."

# Verificar que está habilitado
aws inspector2 batch-get-account-status \
  --account-ids "$(aws sts get-caller-identity --query Account --output text)" \
  --region "$AWS_REGION" \
  --query 'accounts[].{Estado:state,EC2:resourceState.ec2.status,ECR:resourceState.ecr.status}' \
  --output table
```

---

## Paso 2 — Crear IAM Role para EC2

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

# Crear IAM Role para la instancia
aws iam create-role \
  --role-name lab06-ec2-inspector-role \
  --assume-role-policy-document '{
    "Version": "2012-10-17",
    "Statement": [{
      "Effect": "Allow",
      "Principal": {"Service": "ec2.amazonaws.com"},
      "Action": "sts:AssumeRole"
    }]
  }' 2>/dev/null || echo "Role ya existe"

# Adjuntar política SSM (necesaria para Inspector)
aws iam attach-role-policy \
  --role-name lab06-ec2-inspector-role \
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore

# Crear Instance Profile
aws iam create-instance-profile \
  --instance-profile-name lab06-ec2-inspector-profile 2>/dev/null || true

aws iam add-role-to-instance-profile \
  --instance-profile-name lab06-ec2-inspector-profile \
  --role-name lab06-ec2-inspector-role 2>/dev/null || true

echo "IAM Role e Instance Profile creados"
```

---

## Paso 3 — Lanzar instancia EC2

```bash
# Obtener AMI Amazon Linux 2023
AMI_ID=$(aws ec2 describe-images \
  --owners amazon \
  --filters \
    "Name=name,Values=al2023-ami-2023*-x86_64" \
    "Name=state,Values=available" \
  --query 'sort_by(Images, &CreationDate)[-1].ImageId' \
  --output text \
  --region "$AWS_REGION")

echo "AMI: $AMI_ID"

# Obtener VPC y subnet por defecto
VPC_ID=$(aws ec2 describe-vpcs \
  --filters "Name=isDefault,Values=true" \
  --query 'Vpcs[0].VpcId' --output text --region "$AWS_REGION")

SUBNET_ID=$(aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --query 'Subnets[0].SubnetId' --output text --region "$AWS_REGION")

echo "VPC: $VPC_ID | Subnet: $SUBNET_ID"

# Lanzar instancia (sin SSH key, acceso via SSM)
INSTANCE_ID=$(aws ec2 run-instances \
  --image-id "$AMI_ID" \
  --instance-type t3.micro \
  --subnet-id "$SUBNET_ID" \
  --iam-instance-profile Name=lab06-ec2-inspector-profile \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=lab06-inspector-target},{Key=Lab,Value=lab06-inspector}]' \
  --metadata-options "HttpTokens=required,HttpEndpoint=enabled" \
  --region "$AWS_REGION" \
  --query 'Instances[0].InstanceId' --output text)

echo "Instancia lanzada: $INSTANCE_ID"
```

```bash
# Esperar a que la instancia esté running
aws ec2 wait instance-running \
  --instance-ids "$INSTANCE_ID" \
  --region "$AWS_REGION"

echo "Instancia running: $INSTANCE_ID"
```

---

## Paso 4 — Verificar cobertura de Inspector

```bash
# Inspector debería detectar la instancia automáticamente (puede tardar 5-10 min)
aws inspector2 list-coverage \
  --filter-criteria '{
    "ec2InstanceTags": [{
      "comparison": "EQUALS",
      "key": "Lab",
      "value": "lab06-inspector"
    }]
  }' \
  --region "$AWS_REGION" \
  --query 'coveredResources[].{ID:resourceId,Tipo:resourceType,Estado:scanStatus.statusCode}' \
  --output table
```

---

## Paso 5 — Explorar findings de EC2

```bash
# Ver findings de la instancia (puede tardar 15-30 min el primer escaneo)
aws inspector2 list-findings \
  --filter-criteria '{
    "resourceType": [{"comparison": "EQUALS", "value": "AWS_EC2_INSTANCE"}],
    "findingStatus": [{"comparison": "EQUALS", "value": "ACTIVE"}]
  }' \
  --sort-criteria '{"field": "SEVERITY", "sortOrder": "DESC"}' \
  --region "$AWS_REGION" \
  --query 'findings[].{CVE:packageVulnerabilityDetails.vulnerabilityId,Paquete:packageVulnerabilityDetails.vulnerablePackages[0].name,Version:packageVulnerabilityDetails.vulnerablePackages[0].version,Fix:packageVulnerabilityDetails.vulnerablePackages[0].fixedInVersion,Severidad:severity}' \
  --output table
```

```bash
# Filtrar solo CRITICAL y HIGH
aws inspector2 list-findings \
  --filter-criteria '{
    "resourceType": [{"comparison": "EQUALS", "value": "AWS_EC2_INSTANCE"}],
    "severity": [
      {"comparison": "EQUALS", "value": "CRITICAL"},
      {"comparison": "EQUALS", "value": "HIGH"}
    ]
  }' \
  --region "$AWS_REGION" \
  --query 'findings[].{CVE:packageVulnerabilityDetails.vulnerabilityId,Paquete:packageVulnerabilityDetails.vulnerablePackages[0].name,Severidad:severity,CVSS:packageVulnerabilityDetails.cvss[0].baseScore}' \
  --output table
```

---

## validate.sh

```bash
#!/usr/bin/env bash
set -euo pipefail

REGION="eu-west-1"
GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
pass() { echo -e "${GREEN}[PASS]${NC} $*"; }
fail() { echo -e "${RED}[FAIL]${NC} $*"; exit 1; }

echo "=== Lab 06.01 — Inspector EC2 Scanning ==="

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

# Verificar que Inspector está habilitado
STATUS=$(aws inspector2 batch-get-account-status \
  --account-ids "$ACCOUNT_ID" \
  --region "$REGION" \
  --query 'accounts[0].state' --output text 2>/dev/null || echo "DISABLED")

if [[ "$STATUS" == "ENABLED" ]]; then
  pass "Inspector habilitado"
else
  fail "Inspector no está habilitado (estado: $STATUS)"
fi

# Verificar que EC2 scanning está activo
EC2_STATUS=$(aws inspector2 batch-get-account-status \
  --account-ids "$ACCOUNT_ID" \
  --region "$REGION" \
  --query 'accounts[0].resourceState.ec2.status' --output text 2>/dev/null || echo "DISABLED")

if [[ "$EC2_STATUS" == "ENABLED" ]]; then
  pass "Inspector EC2 scanning activo"
else
  fail "Inspector EC2 scanning no activo (estado: $EC2_STATUS)"
fi

# Verificar cobertura
COVERED=$(aws inspector2 list-coverage \
  --region "$REGION" \
  --query 'length(coveredResources)' --output text 2>/dev/null || echo "0")

if [[ "$COVERED" -gt 0 ]]; then
  pass "Inspector cubre $COVERED recursos"
else
  echo "INFO: Aún sin recursos cubiertos (puede tardar 5-10 min)"
fi

# Contar findings
FINDINGS=$(aws inspector2 list-findings \
  --filter-criteria '{"findingStatus": [{"comparison": "EQUALS", "value": "ACTIVE"}]}' \
  --region "$REGION" \
  --query 'length(findings)' --output text 2>/dev/null || echo "0")

echo "INFO: Findings activos: $FINDINGS (el primer escaneo puede tardar 15-30 min)"
```

---

## Resumen SAA-C03

| Pregunta | Respuesta |
|---------|---------|
| ¿Qué necesita Inspector para escanear EC2? | SSM Agent + IAM Role con `AmazonSSMManagedInstanceCore` |
| ¿Instala Inspector un agente en la EC2? | **No** — usa SSM Agent que ya está en la instancia |
| ¿Qué detecta en EC2? | CVEs en paquetes instalados + vulnerabilidades de red |
| ¿Cuándo escanea? | Continuo — cada vez que se publica un nuevo CVE re-escanea |
