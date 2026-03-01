# Troubleshooting 07 — Global Accelerator: tráfico no llega al endpoint

## Síntoma
Las IPs anycast de Global Accelerator no responden, o el tráfico llega al GA pero no al ALB. O el failover no funciona como se esperaba.

## Diagnóstico

```bash
source ~/.ec2-lab-env

# 1. Estado del Accelerator
aws globalaccelerator describe-accelerator \
  --accelerator-arn "$GA_ARN" \
  --region us-east-1 \
  --query 'Accelerator.{Name:Name,Status:Status,IPs:IpSets[0].IpAddresses,Enabled:Enabled}' \
  --output table

# 2. Estado del Endpoint Group
aws globalaccelerator describe-endpoint-group \
  --endpoint-group-arn "$GA_EG_ARN" \
  --region us-east-1 \
  --query 'EndpointGroup.{Region:EndpointGroupRegion,Health:EndpointDescriptions[0].HealthState,HealthReason:EndpointDescriptions[0].HealthReason}' \
  --output table

# 3. Test de conectividad directa a las IPs anycast
GA_IP=$(echo "$GA_IPS" | awk '{print $1}')
curl -v --connect-timeout 10 "http://${GA_IP}/health"

# 4. Traceroute para ver si el tráfico llega a AWS backbone
traceroute "$GA_IP"

# 5. Ver listener del GA
aws globalaccelerator describe-listener \
  --listener-arn "$GA_LISTENER_ARN" \
  --region us-east-1 \
  --query 'Listener.{Protocol:Protocol,Ports:PortRanges}'
```

## Causas comunes

| Causa | Síntoma | Solución |
|---|---|---|
| GA deshabilitado | `Enabled: false` | `aws globalaccelerator update-accelerator --accelerator-arn $GA_ARN --enabled --region us-east-1` |
| Endpoint no healthy | `HealthState: UNHEALTHY` | Verificar que el ALB tiene targets healthy y el health check path es correcto |
| SG del ALB no acepta desde GA | `HealthState: UNHEALTHY` | GA health check viene de IPs propietarias de AWS — el SG del ALB debe aceptar `0.0.0.0/0` en los puertos del listener, o añadir el prefix list de GA |
| Puerto no en listener de GA | El listener GA tiene `80-80` pero el endpoint ALB escucha 443 | Añadir `443` al port range del listener de GA |
| `ClientIPPreservationEnabled` falla | Error al registrar el endpoint | Requiere que el ALB tenga el atributo `routing.http.x-forwarded-for-mode=append` |
| Propagación GA tardía | No responde recién creado | GA puede tardar 2-3 minutos en propagar globalmente |

## SG: GA Health Checks

Global Accelerator realiza health checks desde su propia infraestructura. Para que el ALB sea marcado como healthy:

```bash
# Opción 1 (más simple para labs): permitir todo en el SG del ALB
# Ya configurado con 0.0.0.0/0 en el puerto 80/443

# Opción 2 (más segura): usar el managed prefix list de GA
# El prefix list com.amazonaws.global.globalaccelerator contiene las IPs de GA
aws ec2 describe-managed-prefix-lists \
  --filters "Name=prefix-list-name,Values=com.amazonaws.global.globalaccelerator" \
  --query 'PrefixLists[0].PrefixListId' --output text
```

## Exam Trap
**Global Accelerator NO es un CDN** — no cachea contenido. CloudFront sí. GA enruta tráfico TCP/UDP por el backbone de AWS para reducir latencia y proporcionar failover <30s. Si el examen pregunta "reducir latencia de contenido estático globalmente" → CloudFront. Si pregunta "failover rápido multi-región sin TTL DNS" → Global Accelerator.
