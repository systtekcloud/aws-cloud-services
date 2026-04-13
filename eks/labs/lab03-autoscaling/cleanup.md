# Limpieza: Lab 03 — Autoscaling

```bash
# Borrar recursos del lab
kubectl delete deployment cpu-stress inflated sqs-worker -n workloads
kubectl delete hpa cpu-stress-hpa -n workloads
kubectl delete scaledobject sqs-scaledobject -n workloads

# Desinstalar Karpenter
helm uninstall karpenter -n karpenter
kubectl delete namespace karpenter
kubectl delete nodepool default
kubectl delete ec2nodeclass default

# Desinstalar KEDA
helm uninstall keda -n keda
kubectl delete namespace keda

# Borrar recursos AWS
aws sqs delete-queue --queue-url $QUEUE_URL 2>/dev/null || true
aws iam delete-role-policy --role-name keda-sqs-reader --policy-name sqs-read 2>/dev/null || true
aws iam delete-role --role-name keda-sqs-reader 2>/dev/null || true
```
