# v4 — DNS Global: Route53 + Global Accelerator + ACM HTTPS

Añade capa de DNS y entrega global: ACM wildcard para HTTPS, Route53 con política Weighted para A/B entre regiones, y Global Accelerator para routing anycast con failover en <30 segundos.

```
Internet
   │
   ├─── Global Accelerator (anycast IPs)
   │         │
   │    Backbone AWS ──────► ALB eu-west-1
   │                  └────► ALB eu-central-1 (opcional)
   │
   └─── Route53 (app.systtekcloud.dev)
             │  Weighted policy
             ├─ 90% ──► ALB eu-west-1
             └─ 10% ──► ALB eu-central-1 (opcional)
```

**Diferencia clave Route53 vs Global Accelerator:**
- Route53: DNS-based, TTL caching, failover ~TTL segundos
- Global Accelerator: anycast IPs, backbone routing, failover <30s, no DNS TTL

---

## Fase A — CLI

```bash
source ~/.ec2-lab-env
bash cli/01-acm-cert.sh       # Wildcard certificate + DNS validation
bash cli/02-alb-https.sh      # Listener HTTPS:443 en el ALB
bash cli/03-route53.sh        # Hosted zone + A record Weighted
bash cli/04-global-accel.sh   # Global Accelerator + endpoint group
bash cli/05-validacion.sh     # Verificar DNS + HTTPS + GA
```

### Cleanup
```bash
bash cli/99-cleanup.sh
```

---

## Fase B — Terraform

```bash
cd terraform/
terraform init
terraform plan \
  -var="alb_arn=$ALB_ARN" \
  -var="alb_dns_name=$ALB_DNS" \
  -var="alb_zone_id=$ALB_ZONE_ID" \
  -var="domain=systtekcloud.dev" \
  -var="subdomain=app"
terraform apply
```

---

## Resultados esperados

- `curl https://app.systtekcloud.dev/health` → 200 (vía HTTPS con ACM cert)
- `dig app.systtekcloud.dev` → responde con IP del ALB (Alias record)
- Global Accelerator: 2 IPs anycast estáticas, `curl https://<ga-ip>/health`
- `nslookup app.systtekcloud.dev 8.8.8.8` → ALIAS → ALB DNS
- EvaluateTargetHealth=true en Alias record (failover automático si ALB unhealthy)

---

## Exam Traps

| Trampa | Realidad |
|---|---|
| Global Accelerator se configura desde eu-west-1 | GA es global; se configura desde `us-east-1` via CLI (`--region us-east-1`) |
| Route53 Alias record tiene TTL configurable | Alias records NO tienen TTL propio; heredan el TTL del recurso destino |
| ACM cert en eu-west-1 vale para CloudFront | CloudFront requiere cert en `us-east-1`; ALB usa cert en la región del ALB |
| Global Accelerator sustituye a Route53 | Son complementarios; GA para latencia/failover, Route53 para DNS resolution |
| Lowering TTL es instantáneo | El TTL bajo tarda en propagarse según caches anteriores (hasta el TTL anterior) |
| EvaluateTargetHealth false en Alias → Route53 no hace failover | Con false, Route53 ignora la salud del ALB y siempre responde con ese registro |
