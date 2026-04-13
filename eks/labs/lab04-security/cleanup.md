# Limpieza: Lab 04 — Seguridad

```bash
# Borrar pods y namespaces del lab
kubectl delete namespace frontend backend database produccion
kubectl delete pod secrets-test -n workloads
kubectl delete serviceaccount secrets-reader-sa -n workloads

# Desinstalar CSI Driver
helm uninstall csi-secrets-store -n kube-system
kubectl delete -f https://raw.githubusercontent.com/aws/secrets-store-csi-driver-provider-aws/main/deployment/aws-provider-installer.yaml

# Borrar recursos AWS
aws secretsmanager delete-secret --secret-id eks-lab/db-credentials --force-delete-without-recovery
aws iam delete-role-policy --role-name eks-secrets-reader --policy-name read-secret 2>/dev/null || true
aws iam delete-role --role-name eks-secrets-reader 2>/dev/null || true
aws iam delete-role-policy --role-name eks-produccion-dynamo --policy-name dynamodb-write 2>/dev/null || true
aws iam delete-role --role-name eks-produccion-dynamo 2>/dev/null || true
```
