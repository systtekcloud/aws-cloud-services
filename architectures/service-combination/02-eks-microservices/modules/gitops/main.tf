variable "environment"   { type = string }
variable "cluster_name"  { type = string }
variable "cluster_endpoint" { type = string }
variable "cluster_ca"    { type = string }

# ── ArgoCD via Helm (instalar en el cluster) ──────────────────────────────────
#
# Nota: este módulo asume que el provider kubernetes y helm están configurados
# con las credenciales del cluster EKS.

terraform {
  required_providers {
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.12"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.27"
    }
  }
}

resource "kubernetes_namespace" "argocd" {
  metadata {
    name = "argocd"
    labels = {
      name = "argocd"
    }
  }
}

resource "helm_release" "argocd" {
  name       = "argocd"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  version    = "6.7.11"
  namespace  = kubernetes_namespace.argocd.metadata[0].name

  values = [yamlencode({
    global = {
      domain = "argocd.${var.environment}.saas.internal"
    }

    server = {
      # En prod: habilitar TLS y exponer via ingress
      extraArgs = ["--insecure"] # Solo para dev
    }

    # Configurar repositorio Git de manifests
    configs = {
      repositories = {
        saas-gitops = {
          type = "git"
          url  = "https://github.com/mi-empresa/saas-k8s-manifests"
          # En prod: SSH key via secret de Kubernetes
        }
      }

      # RBAC de ArgoCD: admins vs read-only
      rbac = {
        "policy.default" = "role:readonly"
        "policy.csv"     = <<-POLICY
          p, role:admin, applications, *, */*, allow
          p, role:admin, clusters, get, *, allow
          p, role:admin, repositories, *, *, allow
          g, argocd-admins, role:admin
        POLICY
      }
    }

    # Notificaciones (Slack cuando hay sync/error)
    notifications = {
      enabled = true
    }
  })]

  depends_on = [kubernetes_namespace.argocd]
}

# ── ArgoCD App of Apps (root application) ────────────────────────────────────
# La root app despliega todas las demás apps (una por tenant)

resource "kubernetes_manifest" "root_app" {
  manifest = {
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "Application"
    metadata = {
      name      = "root"
      namespace = "argocd"
    }
    spec = {
      project = "default"
      source = {
        repoURL        = "https://github.com/mi-empresa/saas-k8s-manifests"
        targetRevision = "HEAD"
        path           = "apps/${var.environment}"
      }
      destination = {
        server    = "https://kubernetes.default.svc"
        namespace = "argocd"
      }
      syncPolicy = {
        automated = {
          prune    = true   # Borrar recursos que ya no están en Git
          selfHeal = true   # Revertir cambios manuales en el cluster
        }
        syncOptions = ["CreateNamespace=true"]
      }
    }
  }

  depends_on = [helm_release.argocd]
}

# ── Estructura de manifests en GitHub (documentación) ────────────────────────
# apps/
#   dev/
#     root.yaml            ← App of Apps
#     tenant-acme.yaml     ← ArgoCD Application para tenant Acme
#     tenant-beta.yaml
#   prod/
#     ...
#
# tenants/
#   acme/
#     namespace.yaml       ← Namespace + ResourceQuota + NetworkPolicy
#     api-service.yaml     ← Deployment + Service + HPA
#     worker-service.yaml
#   beta/
#     ...

output "argocd_namespace" { value = kubernetes_namespace.argocd.metadata[0].name }
