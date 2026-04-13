# Limpieza: Lab 06 — GitOps

```bash
# Borrar Applications (el finalizer borra los recursos del cluster también)
argocd app delete root-dev --cascade    # borra root + todas las sub-apps
argocd app delete guestbook --cascade
argocd app delete guestbook-yaml --cascade

# Desinstalar ArgoCD
helm uninstall argocd -n argocd
kubectl delete namespace argocd

# Limpiar namespaces del lab
kubectl delete namespace dev monitoring 2>/dev/null || true
```
