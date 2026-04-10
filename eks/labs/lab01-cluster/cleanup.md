# Limpieza: Lab 01 — EKS Cluster

## Orden de limpieza

Siempre borrar en orden inverso a la creación (los recursos dependientes primero).

```bash
# 1. Borrar pods y namespaces del lab
kubectl delete pod --all -n lab
kubectl delete namespace lab

# 2. Borrar el cluster via Terraform (borra EKS + VPC + Fargate Profiles + Add-ons)
cd terraform/
terraform destroy -auto-approve

# Si prefieres eksctl:
# eksctl delete cluster --name eks-lab --region eu-west-1

# 3. Limpiar kubeconfig
kubectl config delete-context eks-dev
kubectl config delete-cluster eks-dev

# 4. Limpiar recursos IAM creados en el sub-lab 02 (si aplica)
aws iam delete-role-policy --role-name eks-s3-reader --policy-name s3-read 2>/dev/null || true
aws iam delete-role --role-name eks-s3-reader 2>/dev/null || true

# 5. Verificar que no quedan recursos
aws eks list-clusters --region eu-west-1
aws ec2 describe-vpcs --filters "Name=tag:Name,Values=eks-lab-*" --query 'Vpcs[].VpcId'
```

## Coste acumulado estimado (si se deja encendido)

| Recurso | Coste/hora |
|---------|-----------|
| EKS Control Plane | $0.10 |
| NAT Gateway | $0.045 |
| Fargate pods (si los hay) | Variable |
| **Total mínimo** | **~$0.145/hora = ~$3.50/día** |

**Borrar el cluster al terminar el lab** para evitar costes innecesarios.
