# Troubleshooting — Security & Governance Lab

> 12 escenarios de diagnóstico con síntoma → causa → fix verificable

---

## TS-01: SCP bloquea aunque la IAM policy permita

**Síntoma**
```
An error occurred (AccessDenied) when calling the PutObject operation:
User: arn:aws:sts::333333333333:assumed-role/AWSReservedSSO_DevPowerUser_xxx/lab-dev
is not authorized ... with an explicit deny in a service control policy
```

La IAM policy del usuario tiene `s3:PutObject` permitido. La operación falla igualmente.

**Causa**
Las SCPs se evalúan **antes** que las IAM policies. Si hay un `Deny` en una SCP en cualquier OU ancestro de la cuenta, ese deny bloquea la acción independientemente de lo que diga la IAM policy. El mensaje "explicit deny in a service control policy" es la señal definitiva.

Orden de evaluación:
```
1. Deny explícito en SCP → DENY final (no hay override posible)
2. SCP no permite la acción → DENY
3. Permission Boundary (si existe) limita el máximo
4. IAM Identity-based policy → Allow/Deny
5. Resource-based policy → puede Allow adicional
6. Default → DENY implícito
```

**Diagnóstico**
```bash
# 1. Ver qué SCPs están aplicadas a la cuenta (desde Management Account)
aws organizations list-policies-for-target \
  --target-id $DEV_ACCOUNT_ID \
  --filter SERVICE_CONTROL_POLICY \
  --query 'Policies[*].[Name,Id]' --output table

# 2. Ver SCPs de cada OU ancestro
# Primero obtener la cadena de padres de la cuenta
aws organizations list-parents --child-id $DEV_ACCOUNT_ID \
  --query 'Parents[*].[Id,Type]' --output table

# 3. Ver el contenido de la SCP que bloquea
aws organizations describe-policy \
  --policy-id p-xxxx \
  --query 'Policy.Content' --output text | python3 -m json.tool
```

**Fix**
Opciones ordenadas de menos a más impacto:

1. **Si es un error de SCP**: Modificar la SCP para añadir la excepción necesaria (e.g., añadir el bucket específico como excepción)
2. **Si es un error de OU**: La cuenta está en la OU incorrecta — moverla a la OU adecuada
3. **Si es intencional**: La operación no debe estar permitida — explicar al usuario la restricción
4. **Excepción temporal**: Añadir condition en la SCP con `aws:PrincipalARN` para excluir un rol específico

> **Regla de oro:** Nunca modifiques SCPs en producción sin proceso de change management. Afectan a TODAS las cuentas de la OU.

---

## TS-02: SCP aplicada en OU equivocada (no bloquea donde debería)

**Síntoma**
La SCP `DenyRegionsExceptEUWest1` existe en Organizations, pero alguien creó un bucket en `us-east-1` en la cuenta de Producción sin error.

**Causa**
La SCP está adjuntada a la OU `Dev` en lugar de a la OU `Prod`. Los recursos de la cuenta Prod no heredan esa SCP porque no está en su cadena de OUs ancestros.

**Diagnóstico**
```bash
# 1. Verificar dónde está adjuntada la SCP
aws organizations list-targets-for-policy \
  --policy-id $SCP_REGIONS_ID \
  --query 'Targets[*].[Name,TargetId,Type]' --output table
# Si muestra OU: Dev en lugar de OU: Workloads o Root, eso es el problema

# 2. Verificar qué SCPs tiene aplicadas la Prod Account
PROD_ACCOUNT_ID="444444444444"
aws organizations list-policies-for-target \
  --target-id $PROD_ACCOUNT_ID \
  --filter SERVICE_CONTROL_POLICY \
  --query 'Policies[*].[Name,Id]' --output table
```

**Fix**
```bash
# Desadjuntar de la OU incorrecta
aws organizations detach-policy \
  --policy-id $SCP_REGIONS_ID \
  --target-id $OU_DEV

# Adjuntar a la OU correcta
aws organizations attach-policy \
  --policy-id $SCP_REGIONS_ID \
  --target-id $OU_WORKLOADS  # o $OU_PROD si solo debe aplicar a Prod

# Verificar de inmediato
aws organizations list-policies-for-target \
  --target-id $PROD_ACCOUNT_ID \
  --filter SERVICE_CONTROL_POLICY \
  --query 'Policies[*].[Name]' --output text
```

---

## TS-03: Permission Set no aparece en el portal SSO

**Síntoma**
El usuario `lab-dev` entra al portal SSO y no ve la cuenta Dev Account o ve la cuenta pero no el Permission Set `DevPowerUser`.

**Causa A:** No existe asignación (Account Assignment) para ese usuario/grupo + permission set + cuenta.
**Causa B:** La asignación existe pero el permission set no está "provisionado" en la cuenta (paso adicional necesario tras crear assignments).
**Causa C:** La cuenta fue creada/invitada recientemente y Identity Center aún no la sincronizó.

**Diagnóstico**
```bash
# 1. Listar asignaciones para el permission set en la cuenta Dev
aws sso-admin list-account-assignments \
  --instance-arn $IDC_INSTANCE_ARN \
  --account-id $DEV_ACCOUNT_ID \
  --permission-set-arn $DEV_PS \
  --query 'AccountAssignments[*].[PrincipalType,PrincipalId]' \
  --output table

# 2. Verificar que el permission set está provisionado en la cuenta
aws sso-admin list-permission-sets-provisioned-to-account \
  --instance-arn $IDC_INSTANCE_ARN \
  --account-id $DEV_ACCOUNT_ID \
  --query 'PermissionSets' --output text

# 3. Ver el estado de provisioning
aws sso-admin list-account-assignment-creation-status \
  --instance-arn $IDC_INSTANCE_ARN \
  --query 'AccountAssignmentsCreationStatus[*].[Status,TargetId,PermissionSetArn]' \
  --output table
```

**Fix**
```bash
# Si no hay asignación: crearla
aws sso-admin create-account-assignment \
  --instance-arn $IDC_INSTANCE_ARN \
  --target-id $DEV_ACCOUNT_ID \
  --target-type AWS_ACCOUNT \
  --permission-set-arn $DEV_PS \
  --principal-type USER \
  --principal-id $LAB_DEV_USER_ID

# Si el permission set no está provisionado: forzar provisioning
aws sso-admin provision-permission-set \
  --instance-arn $IDC_INSTANCE_ARN \
  --permission-set-arn $DEV_PS \
  --target-type AWS_ACCOUNT \
  --target-id $DEV_ACCOUNT_ID
```

---

## TS-04: AssumeRole desde Identity Center falla — Trust Policy incorrecta

**Síntoma**
```
An error occurred (AccessDenied) when calling the AssumeRoleWithSAML operation:
Not authorized to perform sts:AssumeRoleWithSAML
```

O el usuario ve la cuenta en el portal SSO pero al hacer click en "Management console" obtiene un error.

**Causa**
La Trust Policy del IAM Role en la cuenta destino (creado por Identity Center) no tiene al SAML provider correcto como principal, o el SAML provider fue eliminado/recreado.

**Diagnóstico**
```bash
# 1. Ver el IAM Role creado por Identity Center en la cuenta destino
aws iam list-roles \
  --query 'Roles[?starts_with(RoleName, `AWSReservedSSO`)].[RoleName,RoleId]' \
  --output table

# 2. Ver la trust policy del rol
RESERVED_ROLE_NAME=$(aws iam list-roles \
  --query 'Roles[?starts_with(RoleName, `AWSReservedSSO_DevPowerUser`)].RoleName' \
  --output text | head -1)

aws iam get-role \
  --role-name "$RESERVED_ROLE_NAME" \
  --query 'Role.AssumeRolePolicyDocument' --output json | python3 -m json.tool

# 3. Verificar que el SAML provider existe
aws iam list-saml-providers \
  --query 'SAMLProviderList[*].[Arn]' --output text
```

**Fix**
El role `AWSReservedSSO_*` es gestionado por Identity Center — no lo modifiques manualmente. En cambio:

1. En Identity Center → **Settings** → verificar la configuración del SAML provider
2. Si el role fue modificado manualmente o borrado: eliminar y recrear la Account Assignment
   ```bash
   # Borrar y recrear la asignación para que IDC regenere el rol
   aws sso-admin delete-account-assignment \
     --instance-arn $IDC_INSTANCE_ARN \
     --target-id $DEV_ACCOUNT_ID \
     --target-type AWS_ACCOUNT \
     --permission-set-arn $DEV_PS \
     --principal-type USER \
     --principal-id $LAB_DEV_USER_ID

   sleep 30

   aws sso-admin create-account-assignment \
     --instance-arn $IDC_INSTANCE_ARN \
     --target-id $DEV_ACCOUNT_ID \
     --target-type AWS_ACCOUNT \
     --permission-set-arn $DEV_PS \
     --principal-type USER \
     --principal-id $LAB_DEV_USER_ID
   ```

---

## TS-05: CloudTrail no escribe en el S3 bucket — Bucket Policy o KMS

**Síntoma**
CloudTrail está activo (`IsLogging: true`) pero `LatestDeliveryTime` es `null` o muy antiguo. No llegan archivos al bucket S3 de Log Archive.

**Causa A:** La bucket policy no tiene la cláusula `AllowCloudTrailWrite` correcta (ARN del trail, `s3:x-amz-acl`).
**Causa B:** La KMS key policy no permite a `cloudtrail.amazonaws.com` usar la clave.
**Causa C:** El bucket está en una cuenta diferente y falta la condition `aws:SourceArn` apuntando al trail correcto.

**Diagnóstico**
```bash
# 1. Ver el estado del trail
aws cloudtrail get-trail-status --name "lab-org-trail" \
  --query '[IsLogging,LatestDeliveryError,LatestDeliveryTime,LatestNotificationError]' \
  --output table

# 2. Ver la bucket policy actual
aws s3api get-bucket-policy \
  --bucket $BUCKET_NAME \
  --query 'Policy' --output text | python3 -m json.tool

# 3. Verificar la KMS key policy
aws kms get-key-policy \
  --key-id $KMS_LOG_KEY_ARN \
  --policy-name default \
  --query 'Policy' --output text | python3 -m json.tool
```

**Fix para bucket policy — error más común:**
```bash
# El error típico en LatestDeliveryError es:
# "S3BucketPolicy: Insufficient permissions to access S3 bucket"
# Verificar que en la bucket policy existe:
#   "Principal": {"Service": "cloudtrail.amazonaws.com"},
#   "Action": "s3:PutObject",
#   "Resource": "arn:aws:s3:::BUCKET/cloudtrail/AWSLogs/MGMT_ACCOUNT_ID/*"
#   "Condition": {"StringEquals": {"s3:x-amz-acl": "bucket-owner-full-control"}}
# Y también el AllowCloudTrailACLCheck para s3:GetBucketAcl

# Para Organization Trail: el resource path debe incluir el comodín para todas las cuentas
# "Resource": "arn:aws:s3:::BUCKET/cloudtrail/AWSLogs/*"  (no solo MGMT_ACCOUNT_ID)
```

**Fix para KMS — error frecuente:**
```bash
# El error típico: "KMSAccessDenied: Insufficient permissions to access KMS key"
# Verificar que en la key policy existe la cláusula:
# {
#   "Principal": {"Service": "cloudtrail.amazonaws.com"},
#   "Action": ["kms:GenerateDataKey*", "kms:DescribeKey"],
#   "Condition": {"StringLike": {"kms:EncryptionContext:aws:cloudtrail:arn": "arn:aws:cloudtrail:*:MGMT_ACCOUNT:trail/*"}}
# }
```

---

## TS-06: AccessDenied en kms:Decrypt desde EC2

**Síntoma**
```
botocore.exceptions.ClientError: An error occurred (AccessDenied) when calling
the GetSecretValue operation: Access to KMS is not allowed
```

La EC2 tiene `secretsmanager:GetSecretValue` en su IAM policy pero la llamada falla.

**Causa**
El secreto está cifrado con un KMS CMK. Para descifrar el secreto, la EC2 necesita `kms:Decrypt` tanto en:
1. La **identity-based policy** del rol de EC2
2. La **key policy** de la KMS key (debe permitir al rol)

Si falta cualquiera de los dos, el acceso falla.

**Diagnóstico**
```bash
# 1. Ver qué KMS key usa el secreto
aws secretsmanager describe-secret \
  --secret-id "lab/db/credentials" \
  --query '[KmsKeyId,RotationEnabled]' --output table

# 2. Ver la identity policy del rol de EC2
aws iam get-role-policy \
  --role-name "lab-app-role" \
  --policy-name "lab-app-minimal-policy" \
  --query 'PolicyDocument' --output json | python3 -m json.tool

# 3. Ver la key policy de la KMS key
aws kms get-key-policy \
  --key-id $KMS_APP_KEY_ARN \
  --policy-name default \
  --query 'Policy' --output text | python3 -m json.tool

# 4. Usar el Policy Simulator para verificar permisos
aws iam simulate-principal-policy \
  --policy-source-arn "arn:aws:iam::${ACCOUNT_ID}:role/lab-app-role" \
  --action-names "kms:Decrypt" \
  --resource-arns $KMS_APP_KEY_ARN \
  --query 'EvaluationResults[*].[EvalActionName,EvalDecision]' \
  --output table
```

**Fix**
```bash
# Añadir kms:Decrypt a la identity policy del rol
# (ver policy completa en fase-06, sección 6.4)

# Y verificar que la key policy permite al rol:
aws kms get-key-policy --key-id $KMS_APP_KEY_ARN --policy-name default \
  --query 'Policy' --output text | \
  python3 -c "import sys,json; p=json.load(sys.stdin); \
  [print(s['Principal']) for s in p['Statement'] if 'lab-app-role' in str(s.get('Principal',''))]"
```

---

## TS-07: Config no evalúa recursos — Recorder sin permisos o mal configurado

**Síntoma**
Config está "activo" pero los recursos no aparecen o las reglas muestran "No resources in scope".

**Causa A:** El Config Recorder no está iniciado (`recording: false`).
**Causa B:** El IAM Role del recorder no tiene la policy `AWS_ConfigRole`.
**Causa C:** La regla tiene un scope que no incluye el tipo de recurso que buscas.

**Diagnóstico**
```bash
# 1. Estado del recorder
aws configservice describe-configuration-recorder-status \
  --query 'ConfigurationRecordersStatus[0].[name,recording,lastStatus,lastErrorCode,lastErrorMessage]' \
  --output table

# 2. Configuración del recorder
aws configservice describe-configuration-recorders \
  --query 'ConfigurationRecorders[0].[name,roleARN,recordingGroup]' \
  --output json | python3 -m json.tool

# 3. IAM Role policies del recorder
RECORDER_ROLE_NAME=$(aws configservice describe-configuration-recorders \
  --query 'ConfigurationRecorders[0].roleARN' --output text | awk -F'/' '{print $NF}')

aws iam list-attached-role-policies \
  --role-name "$RECORDER_ROLE_NAME" \
  --query 'AttachedPolicies[*].[PolicyName]' --output text

# 4. Estado de las reglas
aws configservice describe-config-rule-evaluation-status \
  --query 'ConfigRulesEvaluationStatus[*].[ConfigRuleName,LastSuccessfulEvaluationTime,LastFailedEvaluationTime,LastErrorCode]' \
  --output table
```

**Fix**
```bash
# Si el recorder no está iniciado
aws configservice start-configuration-recorder \
  --configuration-recorder-name default

# Si falta la policy AWS_ConfigRole
aws iam attach-role-policy \
  --role-name "$RECORDER_ROLE_NAME" \
  --policy-arn "arn:aws:iam::aws:policy/service-role/AWS_ConfigRole"

# Forzar re-evaluación de todas las reglas
aws configservice start-config-rules-evaluation \
  --config-rule-names "s3-bucket-public-read-prohibited" "encrypted-volumes"
```

---

## TS-08: Bucket de logs expuesto — Bucket Policy mal configurada

**Síntoma**
Access Analyzer detecta: `s3://org-cloudtrail-logs-222 is publicly accessible`. O alguien puede leer los logs desde fuera de la organización.

**Causa**
La bucket policy tiene una cláusula `Allow` sin restricción de `Principal` o con `Principal: "*"`, o el Block Public Access fue desactivado en algún momento.

**Diagnóstico**
```bash
# 1. Estado de Block Public Access del bucket
aws s3api get-public-access-block \
  --bucket $BUCKET_NAME \
  --query 'PublicAccessBlockConfiguration' --output json | python3 -m json.tool

# 2. Revisar bucket policy en busca de wildcards peligrosos
aws s3api get-bucket-policy \
  --bucket $BUCKET_NAME \
  --query 'Policy' --output text | \
  python3 -c "import sys,json; p=json.loads(sys.stdin.read()); \
  [print('⚠️ Statement con Principal:*:', s) for s in p['Statement'] \
   if s.get('Principal') == '*' and s.get('Effect') == 'Allow']"

# 3. Activar Access Analyzer para detectar exposición
aws accessanalyzer create-analyzer \
  --analyzer-name "lab-access-analyzer" \
  --type ACCOUNT \
  --region eu-west-1

aws accessanalyzer list-findings \
  --analyzer-arn "arn:aws:access-analyzer:eu-west-1:${ACCOUNT_ID}:analyzer/lab-access-analyzer" \
  --query 'findings[*].[resourceType,resource,isPublic,status]' \
  --output table
```

**Fix**
```bash
# 1. Restaurar Block Public Access (SIEMPRE debe estar activo en logs bucket)
aws s3api put-public-access-block \
  --bucket $BUCKET_NAME \
  --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,\
BlockPublicPolicy=true,RestrictPublicBuckets=true

# 2. Revisar y corregir la bucket policy
# La policy correcta del bucket de logs SOLO debe permitir:
# - cloudtrail.amazonaws.com para PutObject (con condition s3:x-amz-acl)
# - config.amazonaws.com para PutObject
# - La cuenta Log Archive (para administración)
# NO debe tener Principal: * con Effect: Allow

# 3. Añadir explicit DENY para acceso sin TLS (ya incluido en la policy de Fase 4)
# "Condition": {"Bool": {"aws:SecureTransport": "false"}} → "Effect": "Deny"

# 4. Archivar el finding en Access Analyzer tras corregirlo
aws accessanalyzer update-findings \
  --analyzer-arn "arn:aws:access-analyzer:eu-west-1:${ACCOUNT_ID}:analyzer/lab-access-analyzer" \
  --status ARCHIVED \
  --ids "finding-id-xxx"
```

---

## TS-09: SSM Session Manager no conecta — Instancia no aparece en Fleet Manager

**Síntoma**
```bash
aws ssm start-session --target i-0123456789
# An error occurred (TargetNotConnected) when calling the StartSession operation:
# i-0123456789 is not connected
```

La instancia no aparece en SSM → Fleet Manager.

**Causa A (más frecuente):** El IAM Role de la instancia no tiene la policy `AmazonSSMManagedInstanceCore`.
**Causa B:** La instancia no tiene el agente SSM instalado o está detenido.
**Causa C:** La instancia no tiene conectividad HTTPS saliente a los endpoints de SSM.
**Causa D:** El agente SSM está instalado pero la instancia se lanzó antes de que se adjuntara el Instance Profile.

**Diagnóstico**
```bash
# 1. Verificar que el Instance Profile tiene la policy correcta
INSTANCE_PROFILE=$(aws ec2 describe-instances \
  --instance-ids $INSTANCE_ID \
  --query 'Reservations[0].Instances[0].IamInstanceProfile.Arn' \
  --output text)

ROLE_NAME=$(aws iam get-instance-profile \
  --instance-profile-name $(echo $INSTANCE_PROFILE | awk -F'/' '{print $NF}') \
  --query 'InstanceProfile.Roles[0].RoleName' --output text)

aws iam list-attached-role-policies \
  --role-name "$ROLE_NAME" \
  --query 'AttachedPolicies[*].PolicyName' --output text
# Debe incluir: AmazonSSMManagedInstanceCore

# 2. Si la instancia es accesible (SSH temporalmente), verificar el agente
# sudo systemctl status amazon-ssm-agent
# sudo systemctl start amazon-ssm-agent
# sudo journalctl -u amazon-ssm-agent -n 50

# 3. Verificar conectividad HTTPS a SSM endpoints
# La instancia necesita acceso a:
# ssm.eu-west-1.amazonaws.com:443
# ssmmessages.eu-west-1.amazonaws.com:443
# ec2messages.eu-west-1.amazonaws.com:443
# Si la instancia está en subnet privada sin NAT: añadir VPC Interface Endpoints

# 4. Verificar Security Group (salida HTTPS)
aws ec2 describe-security-groups \
  --group-ids $SG_ID \
  --query 'SecurityGroups[0].IpPermissionsEgress[*].[IpProtocol,FromPort,ToPort,IpRanges[0].CidrIp]' \
  --output table
# Debe mostrar: tcp 443 443 0.0.0.0/0
```

**Fix**
```bash
# Caso A: Adjuntar la policy SSM al role
aws iam attach-role-policy \
  --role-name "lab-app-role" \
  --policy-arn "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"

# Si la instancia ya estaba lanzada sin el profile correcto:
aws ec2 associate-iam-instance-profile \
  --instance-id $INSTANCE_ID \
  --iam-instance-profile Name=lab-app-profile

# Caso C: Subnet privada sin NAT → VPC Interface Endpoints para SSM
aws ec2 create-vpc-endpoint \
  --vpc-id $VPC_ID \
  --service-name com.amazonaws.eu-west-1.ssm \
  --vpc-endpoint-type Interface \
  --subnet-ids $PRIVATE_SUBNET_ID \
  --security-group-ids $SG_ID \
  --private-dns-enabled

aws ec2 create-vpc-endpoint \
  --vpc-id $VPC_ID \
  --service-name com.amazonaws.eu-west-1.ssmmessages \
  --vpc-endpoint-type Interface \
  --subnet-ids $PRIVATE_SUBNET_ID \
  --security-group-ids $SG_ID \
  --private-dns-enabled

aws ec2 create-vpc-endpoint \
  --vpc-id $VPC_ID \
  --service-name com.amazonaws.eu-west-1.ec2messages \
  --vpc-endpoint-type Interface \
  --subnet-ids $PRIVATE_SUBNET_ID \
  --security-group-ids $SG_ID \
  --private-dns-enabled
```

---

## TS-10: Confusión "Guardrail Control Tower" vs SCP Custom

**Síntoma**
Un guardrail de Control Tower aparece bloqueando una acción. El equipo intenta modificar la SCP directamente en Organizations → la SCP tiene nombre `aws-guardrails-*` y parece que se puede editar, pero los cambios no persisten o causan errores en Control Tower.

**Causa**
Control Tower gestiona sus guardrails preventivos como SCPs en Organizations, pero las crea y mantiene él mismo. Modificar una SCP de Control Tower directamente rompe el estado del guardrail en el dashboard de Control Tower y puede causar un drift que Control Tower intentará reparar (sobreescribiendo tus cambios).

**Cómo distinguirlos**
```bash
# Ver todas las SCPs
aws organizations list-policies \
  --filter SERVICE_CONTROL_POLICY \
  --query 'Policies[*].[Name,Id,Description]' --output table

# SCPs de Control Tower: empiezan por "aws-guardrails-"
# SCPs custom: las que tú creaste (lab-*, SCP-*, etc.)
```

**Fix**
- **NO modifiques** SCPs con prefijo `aws-guardrails-*` directamente en Organizations
- Para cambiar guardrails de Control Tower: ir a **Control Tower** → **Guardrails** → Enable/Disable
- Para excepciones: crear una SCP custom **adicional** que permita la acción específica y adjuntarla a la OU o cuenta (el Allow en una SCP no puede superar un Deny de otra — necesitarías modificar el guardrail en CT)
- Si ya modificaste: ir a Control Tower → **Landing Zone** → **Repair** para restaurar el estado correcto

---

## TS-11: Delegated Admin no configurado — Efectos y cómo detectarlo

**Síntoma**
La cuenta Security Account tiene Config activado, pero no puede ver los config items de otras cuentas. El Config Aggregator en Security Account no muestra recursos de la org.

**Causa**
Para que una cuenta miembro pueda administrar Config (u otros servicios) a nivel org, debe estar registrada como **delegated administrator** para `config.amazonaws.com` desde la Management Account.

**Diagnóstico**
```bash
# Desde Management Account: verificar delegated admins
aws organizations list-delegated-administrators \
  --service-principal config.amazonaws.com \
  --query 'DelegatedAdministrators[*].[Name,Id]' --output table

# Si está vacío → no hay delegated admin configurado para Config

# Verificar desde Security Account (si tiene acceso)
aws configservice describe-configuration-aggregators \
  --query 'ConfigurationAggregators[?OrganizationAggregationSource!=null].[ConfigurationAggregatorName]' \
  --output text
# Si devuelve nada → el aggregator no está usando el nivel org
```

**Fix**
```bash
# Desde Management Account: registrar Security Account como delegated admin
aws organizations register-delegated-administrator \
  --account-id $SECURITY_ACCOUNT_ID \
  --service-principal config.amazonaws.com

# En Security Account: crear el aggregator org-level
# (requiere el delegated admin para que la API org-level funcione)
```

---

## TS-12: Access Analyzer detecta exposición inesperada

**Síntoma**
Access Analyzer reporta: `arn:aws:s3:::lab-app-bucket allows public access` o `arn:aws:iam::xxx:role/lab-app-role can be assumed from external account yyy`.

**Causa y cómo interpretar**
Access Analyzer analiza resource-based policies (bucket policies, key policies, role trust policies) para detectar si recursos dentro de la zona de confianza (la cuenta o la org) son accesibles desde fuera de esa zona.

**Finding types:**
- `Public` → accesible desde internet (Principal: *)
- `Cross-account` → accesible desde otra cuenta AWS fuera de la zona de confianza
- `Cross-org` → accesible desde una cuenta fuera de tu Organizations

**Diagnóstico**
```bash
# Ver todos los findings activos
aws accessanalyzer list-findings \
  --analyzer-arn "arn:aws:access-analyzer:eu-west-1:${ACCOUNT_ID}:analyzer/lab-access-analyzer" \
  --filter '{"status": {"eq": ["ACTIVE"]}}' \
  --query 'findings[*].[resourceType,resource,isPublic,condition,principal]' \
  --output table

# Ver detalles de un finding específico
aws accessanalyzer get-finding \
  --analyzer-arn "arn:aws:access-analyzer:eu-west-1:${ACCOUNT_ID}:analyzer/lab-access-analyzer" \
  --id "finding-id-xxx" \
  --output json | python3 -m json.tool
```

**Acciones por tipo de finding**

| Finding | ¿Es esperado? | Acción |
|---------|--------------|--------|
| Bucket S3 público | Nunca en lab | Activar Block Public Access + revisar bucket policy |
| Role con cross-account trust | Posiblemente (si es intencional) | Si es intencional, **Archive** el finding con justificación |
| KMS key accesible desde otra cuenta | Solo si es el bucket de logs (cross-account para CloudTrail) | Archive con justificación: "Log Archive bucket — necesario para org trail" |
| S3 bucket accesible desde org-account X | OK si es la cuenta Log Archive leyendo sus propios logs | Archive |

```bash
# Archivar finding esperado (con documentación del motivo)
aws accessanalyzer update-findings \
  --analyzer-arn "arn:aws:access-analyzer:eu-west-1:${ACCOUNT_ID}:analyzer/lab-access-analyzer" \
  --status ARCHIVED \
  --ids "finding-id-xxx"

# Para findings de cross-account INESPERADOS:
# 1. Identificar el recurso (bucket, role, key)
# 2. Ver qué policy permite el acceso externo
# 3. Eliminar o restringir la cláusula de acceso externo
# 4. Access Analyzer re-evaluará automáticamente en la próxima pasada
```

> **Señal examen:** Access Analyzer es una herramienta de **validación proactiva** (no reactiva como CloudTrail). Analiza las políticas para detectar acceso no intencionado antes de que ocurra. Es diferente de Config (que detecta estado no compliant) y CloudTrail (que registra quién accedió).
