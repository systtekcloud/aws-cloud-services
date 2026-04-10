# Limpieza: Lab 02 — Workloads

```bash
# Borrar recursos del lab
kubectl delete namespace workloads

# Desinstalar ALB Ingress Controller (borra también los ALBs que creó)
helm uninstall aws-load-balancer-controller -n kube-system
kubectl delete serviceaccount aws-load-balancer-controller -n kube-system

# Verificar que no quedan ALBs huérfanos en AWS
aws elbv2 describe-load-balancers \
  --query 'LoadBalancers[?contains(LoadBalancerName, `eks`)].{Name:LoadBalancerName,DNS:DNSName}'
```
