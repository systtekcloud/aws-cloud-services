# Troubleshooting 06 — Route53: TTL y propagación DNS

## Síntoma
Después de cambiar un registro A en Route53, algunos usuarios siguen viendo la IP antigua durante horas. O se cambió el ALB y el CNAME/Alias sigue resolviendo al ALB antiguo.

## Diagnóstico

```bash
source ~/.ec2-lab-env

# 1. Ver TTL actual del registro
aws route53 list-resource-record-sets \
  --hosted-zone-id "$HOSTED_ZONE_ID" \
  --query "ResourceRecordSets[?Name=='${FQDN}.'].[Name,Type,TTL,AliasTarget.DNSName]" \
  --output table

# 2. Verificar resolución desde múltiples servidores DNS
dig "$FQDN" @8.8.8.8 +short        # Google DNS
dig "$FQDN" @1.1.1.1 +short        # Cloudflare DNS
dig "$FQDN" @ns1.amazonaws.com +short  # NS de Route53

# 3. Ver el estado del cambio en Route53
aws route53 list-resource-record-sets \
  --hosted-zone-id "$HOSTED_ZONE_ID" \
  --query "ResourceRecordSets[?Name=='${FQDN}.']" \
  --output json

# 4. Verificar EvaluateTargetHealth en Alias records
aws route53 list-resource-record-sets \
  --hosted-zone-id "$HOSTED_ZONE_ID" \
  --query "ResourceRecordSets[?Name=='${FQDN}.'].AliasTarget" \
  --output table
```

## Conceptos clave de TTL

| Tipo de registro | TTL | Comportamiento |
|---|---|---|
| Registro A/CNAME estándar | Configurable (60-86400s) | Se cachea en resolvers por TTL segundos |
| Alias a ALB | No configurable | Hereda TTL del ALB (~60s) |
| Alias a CloudFront | No configurable | TTL de CF (~300s) |
| Alias a S3 website | No configurable | TTL de S3 (~300s) |

## Estrategia para cambios con mínimo impacto

```bash
# 48h antes del cambio → bajar TTL a 60s
aws route53 change-resource-record-sets \
  --hosted-zone-id "$HOSTED_ZONE_ID" \
  --change-batch '{
    "Changes": [{
      "Action": "UPSERT",
      "ResourceRecordSet": {
        "Name": "'"$FQDN"'",
        "Type": "A",
        "TTL": 60,
        "ResourceRecords": [{"Value": "OLD_IP"}]
      }
    }]
  }'

# Después del cambio → restaurar TTL alto
# TTL bajo consume más queries → mayor coste en Route53
```

## EvaluateTargetHealth — failover automático

```bash
# Con EvaluateTargetHealth=true en Alias a ALB:
# Si el ALB no tiene targets healthy, Route53 deja de responder con esa IP
# → failover a otro registro con SetIdentifier diferente (Weighted/Failover policy)

# Verificar estado de health check de Route53
aws route53 list-health-checks \
  --query 'HealthChecks[*].[Id,HealthCheckConfig.FullyQualifiedDomainName,HealthCheckStatus]' \
  --output table
```

## Exam Trap
Los **Alias records NO tienen TTL configurable** — el TTL lo gestiona AWS internamente según el recurso destino. Intentar configurar TTL en un Alias record → error. Los registros CNAME estándar sí tienen TTL configurable pero **no pueden usarse en el apex del dominio** (ej. `systtekcloud.dev.`); los Alias sí pueden.
