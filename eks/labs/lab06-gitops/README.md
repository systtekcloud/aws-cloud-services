# Lab 06: GitOps con ArgoCD

GitOps es el patrón donde Git es la fuente de verdad del estado del cluster. ArgoCD reconcilia continuamente el estado del cluster con lo que hay en Git.

---

## Sub-labs

| Sub-lab | Contenido | Tiempo |
|---------|-----------|--------|
| [01-argocd-setup](labs/01-argocd-setup/) | Instalar ArgoCD, acceder al dashboard, primera Application | 30 min |
| [02-app-of-apps](labs/02-app-of-apps/) | App of Apps pattern, gestionar múltiples aplicaciones desde Git | 30 min |

---

## El modelo mental de GitOps

```
Sin GitOps:
  Developer → kubectl apply → Cluster
  (el estado del cluster es lo que alguien hizo manualmente — puede no coincidir con el repo)

Con GitOps:
  Developer → git push → GitHub
               ↓ ArgoCD detecta cambio (webhook o polling)
             ArgoCD → kubectl apply → Cluster
             (el estado del cluster = lo que hay en Git — siempre sincronizado)
```

**Beneficios:**
- Rollback = `git revert` — el historial de cambios está en Git
- Audit trail = commits en Git — sabes quién cambió qué y cuándo
- DR = si el cluster se destruye, ArgoCD re-aplica todo desde Git en minutos
- Multi-cluster = un repositorio controla múltiples clusters

---

## Conceptos clave de ArgoCD

| Concepto | Descripción |
|----------|-------------|
| Application | Recurso que define: qué repo Git + qué path + qué cluster/namespace |
| AppProject | Grupo de Applications con restricciones (clusters, repos, namespaces permitidos) |
| Sync | Proceso de aplicar lo que hay en Git al cluster |
| Drift | Diferencia entre lo que hay en Git y lo que hay en el cluster |
| selfHeal | ArgoCD revierte cambios manuales en el cluster automáticamente |
| prune | ArgoCD borra recursos del cluster que ya no están en Git |
| App of Apps | Una Application que despliega otras Applications |

---

## Recursos

- [labs/01-argocd-setup/](labs/01-argocd-setup/) — Instalación y primera app
- [labs/02-app-of-apps/](labs/02-app-of-apps/) — App of Apps pattern
- [manifests/](manifests/) — Ejemplos de Application y AppProject
- [cleanup.md](cleanup.md)
