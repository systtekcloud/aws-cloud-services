# Sub-lab 01: Crear cluster EKS con Fargate

## Objetivo

Crear un cluster EKS funcional, configurar kubectl, y desplegar los primeros pods en Fargate.

---

## Paso 1: Crear el cluster con eksctl

```bash
# Instalar eksctl si no está instalado
curl -sLO "https://github.com/eksctl-io/eksctl/releases/latest/download/eksctl_Linux_amd64.tar.gz"
tar -xzf eksctl_Linux_amd64.tar.gz && sudo mv eksctl /usr/local/bin/

# Crear cluster con Fargate (sin nodos EC2)
eksctl create cluster \
  --name eks-lab \
  --region eu-west-1 \
  --version 1.31 \
  --fargate \
  --without-nodegroup  # Solo Fargate, sin nodo EC2

# Esto tarda 15-20 min. Crea:
# - EKS Control Plane
# - VPC con subnets públicas y privadas
# - Fargate Profile para namespaces "default" y "kube-system"
# - Actualiza ~/.kube/config automáticamente
```

## Paso 2: Verificar el cluster

```bash
# Verificar kubectl conectado al cluster
kubectl cluster-info
# Kubernetes control plane is running at https://XXXX.gr7.eu-west-1.eks.amazonaws.com

# Ver nodos — en Fargate no hay nodos fijos hasta que se schedula un pod
kubectl get nodes
# NAME                                              STATUS   ROLES    AGE   VERSION
# fargate-ip-10-0-x-x.eu-west-1.compute.internal   Ready    <none>   10s   v1.31.x

# Ver pods del sistema (en Fargate)
kubectl get pods -n kube-system
# NAME                       READY   STATUS    RESTARTS   AGE
# coredns-xxxxx              1/1     Running   0          5m
# coredns-yyyyy              1/1     Running   0          5m
```

## Paso 3: Desplegar el primer pod

```bash
# Crear namespace para los labs
kubectl create namespace lab

# Desplegar un pod de Nginx simple
kubectl run nginx --image=nginx:1.27 --namespace=lab

# Ver el pod (puede tardar 30-90s en Fargate — cold start)
kubectl get pod nginx -n lab -w
# NAME    READY   STATUS              RESTARTS   AGE
# nginx   0/1     Pending             0          0s
# nginx   0/1     ContainerCreating   0          30s
# nginx   1/1     Running             0          90s

# Ver los logs
kubectl logs nginx -n lab

# Acceder al pod interactivamente
kubectl exec -it nginx -n lab -- /bin/bash
```

## Paso 4: Entender el Fargate Profile

```bash
# Ver Fargate Profiles del cluster
eksctl get fargateprofile --cluster eks-lab

# NAME            SELECTOR_NAMESPACE   SELECTOR_LABELS
# fp-default      default
# fp-kube-system  kube-system

# Crear un Fargate Profile para un namespace propio
eksctl create fargateprofile \
  --cluster eks-lab \
  --name fp-lab \
  --namespace lab \
  --labels tier=frontend

# Ahora pods en namespace "lab" con label tier=frontend van a Fargate
kubectl run test --image=nginx --namespace=lab --labels=tier=frontend
```

## Paso 5: Actualizar kubeconfig (si tienes múltiples clusters)

```bash
# Añadir cluster al kubeconfig sin sobrescribir
aws eks update-kubeconfig --name eks-lab --region eu-west-1 --alias eks-lab

# Ver todos los contextos
kubectl config get-contexts

# Cambiar de contexto
kubectl config use-context eks-lab

# Ver contexto actual
kubectl config current-context
```

## Paso 6: Explorar el cluster desde la consola AWS

```bash
# Ver info del cluster
aws eks describe-cluster --name eks-lab --query 'cluster.{Version:version,Status:status,Endpoint:endpoint}'

# Ver add-ons instalados
aws eks list-addons --cluster-name eks-lab

# Ver versión de cada add-on
aws eks describe-addon --cluster-name eks-lab --addon-name vpc-cni
aws eks describe-addon --cluster-name eks-lab --addon-name coredns
aws eks describe-addon --cluster-name eks-lab --addon-name kube-proxy
```

## Qué observar

1. **Cold start de Fargate:** el primer pod en un namespace tarda ~90s. Los siguientes son más rápidos (~20-30s) porque el nodo virtual ya está aprovisionado.

2. **IPs de pods = IPs de VPC:** cada pod tiene una IP de tu VPC (comprueba con `kubectl get pod nginx -n lab -o wide`).

3. **Sin nodos EC2:** `kubectl get nodes` muestra nodos "fargate-*" que son microVMs de Firecracker. No existen hasta que hay pods.

4. **Control Plane inalcanzable vía SSH:** el control plane lo gestiona AWS. Solo tienes acceso al data plane.
