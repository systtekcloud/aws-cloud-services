# Lab 06 — NACLs Stateless: Puertos Efímeros y Flow Logs

> **Concepto SAA-C03:** Los NACLs son stateless — requieren reglas explícitas para el tráfico de respuesta (puertos efímeros 1024-65535). Los Security Groups son stateful — no.

**Coste estimado:** < $0.05 en < 1h
**Stack:** Terraform ≥ 1.10 · Terragrunt ≥ 0.54 · eu-west-1

---

## Concepto demostrado

```
Con NACL completo:          Con NACL sin efímeros outbound:

Cliente → ALB → EC2         Cliente → ALB → EC2
  request:  ALLOW ✓           request:  ALLOW ✓  (inbound 80)
  response: ALLOW ✓           response: REJECT ✗  (outbound efímeros eliminada)
  curl: 200 OK                curl: timeout — nginx recibió pero no puede responder
```

---

## SG vs NACL

| | Security Group | NACL |
|--|--|--|
| Estado | Stateful | Stateless |
| Reglas de respuesta | Automáticas | Manuales |
| Nivel | ENI (instancia) | Subnet |
| Evaluación | Todas las reglas | Primera que coincide |
| Default | Deny all inbound | Allow all |

---

## Despliegue

```bash
# Sustituir <ACCOUNT_ID> en terragrunt/terragrunt.hcl
cd terragrunt/lab06 && terragrunt apply
```

---

## Validación

```bash
./validate.sh
```

El script:
1. Verifica curl funciona (NACL completo)
2. Elimina regla outbound de efímeros → curl cuelga
3. Muestra Flow Logs con ACCEPT/REJECT
4. Restaura la regla → curl funciona

---

## Destruir

```bash
cd terragrunt/lab06 && terragrunt destroy
```
