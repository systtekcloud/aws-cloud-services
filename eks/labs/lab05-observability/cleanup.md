# Limpieza: Lab 05 — Observabilidad

```bash
# Borrar recursos del lab
kubectl delete deployment xray-demo -n workloads
kubectl delete serviceaccount xray-sa -n workloads

# Desinstalar Fluent Bit (si instalado via Helm)
helm uninstall fluent-bit -n amazon-cloudwatch 2>/dev/null || true

# Desinstalar add-on Container Insights
aws eks delete-addon --cluster-name eks-dev --addon-name amazon-cloudwatch-observability

# Borrar log groups (opcional — pueden tener datos históricos útiles)
aws logs delete-log-group --log-group-name "/aws/eks/eks-dev/containers" 2>/dev/null || true

# Borrar recursos IAM
aws iam detach-role-policy --role-name eks-xray --policy-arn arn:aws:iam::aws:policy/AWSXRayDaemonWriteAccess 2>/dev/null || true
aws iam delete-role --role-name eks-xray 2>/dev/null || true
```
