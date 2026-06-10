---
title: "K3S for Local Development: a mini production cluster"
date: 2026-03-29
draft: false
summary: "K3S isn't just a cluster for IoT. Here's how to use it as a local development environment that mirrors your production, without the €2,000 monthly cloud bills."
tags: ["Kubernetes", "K3S", "Development", "DevOps", "Homelab"]
---

When you work on microservice architectures that run on Kubernetes in production, developing locally on Docker Compose is a bit like rehearsing a play in your living room when the show is in a theater. The conditions are different, surprises are guaranteed, and the audience isn't fooled.

K3S, Rancher's (SUSE) lightweight Kubernetes cluster, is a different approach. Instead of developing on a degraded version of your infra, you run a real Kubernetes cluster on your machine. The same manifests, the same tools, the same concepts.

## Why K3S and not kind or Minikube?

| Criterion | K3S | kind | Minikube |
|---|---|---|---|
| Multi-node | Yes | Yes (via extra nodes) | No |
| Persistent cluster | Yes | No (reset on each restart) | Yes |
| Startup time | ~30s | ~60s | ~90s |
| Production-like | High | Medium | Medium |
| Resources | ~512 MB RAM | ~2 GB RAM | ~2 GB RAM |
| Docker integration | native | native | native |

K3S starts fast, consumes little, and unlike kind, your cluster persists between sessions. It's the most relevant choice for a daily dev environment.

## Installation

### Prerequisites

- Linux (sorry, I don't work on another OS)
- 2 GB RAM minimum (4 GB recommended)
- Docker installed or containerd

### Installation script

```bash
curl -sfL https://get.k3s.io | sh -
```

Or via the binary if you prefer:

```bash
curl -Lo /usr/local/bin/k3s https://github.com/k3s-io/k3s/releases/download/v1.30.0+k3s1/k3s
chmod +x /usr/local/bin/k3s
k3s server
```

The K3S service automatically creates its kubectl context. To access it from your host:

```bash
mkdir -p ~/.kube
sudo k3s kubectl config view --flatten > ~/.kube/config
sudo chmod 644 ~/.kube/config
```

Check that it works:

```bash
kubectl get nodes
# NAME        STATUS   ROLES                  AGE   VERSION
# localhost   Ready    control-plane,master   10s   v1.30.0+k3s1
```

## Setup for a production-like environment

Your dev cluster should resemble your production without its constraints (quotas, restrictive network policies, etc.).

### Storage

In production, you probably have a StorageClass on a cloud provider. Locally, use `local-path`:

```bash
kubectl get storageclass
# NAME                   PROVISIONER             RECLAIMPOLICY
# local-path (default)   rancher.io/local-path  Delete
```

Create a PVC for your persistent data:

```yaml
# pvc.yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: postgres-data
  namespace: dev
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: local-path
  resources:
    requests:
      storage: 1Gi
```

### Ingress

In production, you probably have Traefik, NGINX, or a cloud Ingress. K3S includes Traefik by default:

```yaml
# ingress.yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: api
  namespace: dev
  annotations:
    kubernetes.io/ingress.class: traefik
spec:
  rules:
    - host: api.local
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: api
                port:
                  number: 8080
```

Configure `/etc/hosts` for local resolution:

```bash
# /etc/hosts
127.0.0.1 api.local
127.0.0.1 frontend.local
127.0.0.1 postgres.local
```

### Namespaces per environment

Isolate your namespaces like in production:

```bash
kubectl create namespace dev
kubectl create namespace staging
kubectl label namespaces dev env=dev
kubectl label namespaces staging env=staging
```

## Development workflow

### Option 1: classic apply (GitOps workflow)

When you want to test your manifests:

```bash
# Apply everything at once
kubectl apply -k ./manifests/

# Or file by file
kubectl apply -f ./manifests/api-deployment.yaml
kubectl apply -f ./manifests/api-service.yaml

# Check that everything is running
kubectl get all -n dev
# NAME                        READY   STATUS    RESTARTS   AGE
# pod/api-7d9f8b4c6-x2kz9     1/1     Running   0          45s
# pod/postgres-0              1/1     Running   0          2m
```

### Option 2: dev loop with Tilt or Skaffold

For a faster refresh cycle, use [Tilt](https://tilt.dev/):

```bash
# Installation
curl -fsSL https://raw.githubusercontent.com/tilt-dev/tilt/master/scripts/get-tilt.sh | bash
```

`Tiltfile`:

```python
# Tiltfile
k8s_yaml(['api-deployment.yaml', 'api-service.yaml', 'ingress.yaml'])
k8s_resource('api', port_forwards=8080)
docker_build('registry/api', '.')
```

Run `tilt up` and you get:
- Automatic Docker image rebuild on code change
- Log streaming
- Automatic port-forward
- A web interface to inspect resources

### Option 3: Helm to industrialize

If your production uses Helm (which should be the case), develop with Helm:

```bash
# Template your chart locally
helm template ./chart --namespace dev --set image.tag=dev

# Or install directly (not recommended in prod)
helm install api ./chart --namespace dev --create-namespace

# Upgrade after a change
helm upgrade api ./chart --namespace dev --set image.tag=dev2
```

Values for development:

```yaml
# values-dev.yaml
replicaCount: 1

image:
  tag: dev

resources:
  requests:
    cpu: 100m
    memory: 64Mi
  limits:
    cpu: 200m
    memory: 128Mi

ingress:
  enabled: true
  className: traefik
  host: api.local

probes:
  enabled: true
```

## Local debugging

### Accessing logs

```bash
# Logs of a pod
kubectl logs -n dev api-7d9f8b4c6-x2kz9 -f

# Logs of all pods in a deployment
kubectl logs -n dev -l app=api -f

# Logs preceding a crash
kubectl logs -n dev api-7d9f8b4c6-x2kz9 --previous
```

### Shell into a container

```bash
kubectl exec -it -n dev api-7d9f8b4c6-x2kz9 -- /bin/sh
```

Or more directly with `kubectl debug` (K8s 1.20+):

```bash
kubectl debug -it -n dev api-7d9f8b4c6-x2kz9 --image=busybox --share-processes --copy-to=api-debug
```

### Port-forward for debugging

```bash
# Forward a local port to the service
kubectl port-forward -n dev svc/api 8080:8080

# Forward to a pod directly
kubectl port-forward -n dev api-7d9f8b4c6-x2kz9 8080:8080

# Forward to the database
kubectl port-forward -n dev svc/postgres 5432:5432
```

### Inspecting resources

```bash
# Describe to see events and conditions
kubectl describe pod -n dev api-7d9f8b4c6-x2kz9

# View resource requests/limits
kubectl top pod -n dev

# List events
kubectl get events -n dev --sort-by='.lastTimestamp'
```

## Dashboard and tooling

### Kubernetes Dashboard

```bash
# Installation via Helm
helm repo add kubernetes-dashboard https://kubernetes.github.io/dashboard
helm install kubernetes-dashboard kubernetes-dashboard/kubernetes-dashboard -n kube-system

# Access via kubectl proxy
kubectl proxy
# Then open http://localhost:8001/api/v1/namespaces/kubernetes-dashboard/services/https:kubernetes-dashboard:/proxy/
```

Or use `k9s`, lighter and terminal-based (personally, I'm more of a kubectl CLI person).

A terminal interface with keyboard navigation, logs, describe, exec — everything you need without leaving your console.

## Limits and alternatives

K3S has limits for local dev:

### No built-in load balancer

In production, you have a LoadBalancer that gives you an external IP. Locally, use `NodePort` or `port-forward` to access services from outside the cluster.

### No cloud ingress controller

You have to configure `/etc/hosts` manually or use [xip.io](http://xip.io/) for local wildcard DNS.

### Limited resources

K3S runs on your machine. Don't launch 50 pods at once. Use namespaces to isolate and avoid conflicts.

### If you need multiple nodes

K3S supports multi-node to test distributed deployments:

```bash
# On the master
k3s server

# On a worker node (get the token first)
cat /var/lib/rancher/k3s/server/node-token

# On the worker
curl -sfL https://get.k3s.io | K3S_URL=https://master:6443 K3S_TOKEN=<token> sh -
```

For occasional multi-node tests, [k3d](https://k3d.io/) is more convenient (cluster inside Docker).

## Complete setup script

To start a K3S dev environment from scratch:

```bash
#!/bin/bash
set -e

NAMESPACE="dev"

echo "Installing K3S..."
if ! command -v k3s &> /dev/null; then
    curl -sfL https://get.k3s.io | sh -
fi

echo "Configuring kubectl..."
mkdir -p ~/.kube
sudo k3s kubectl config view --flatten > ~/.kube/config
sudo chmod 644 ~/.kube/config

echo "Creating the dev namespace..."
kubectl create namespace $NAMESPACE 2>/dev/null || true

echo "Applying base manifests..."
kubectl apply -f manifests/storage.yaml
kubectl apply -f manifests/ingress.yaml

echo "Verifying..."
kubectl get all -n $NAMESPACE

echo ""
echo "K3S ready! Cluster accessible via kubectl."
echo "Dashboard: kubectl proxy then http://localhost:8001/api/v1/namespaces/kubernetes-dashboard/services/https:kubernetes-dashboard:/proxy/"
echo "Or install k9s: brew install derailed-dev/tools/k9s"
```

## Conclusion

K3S for local development is the compromise between the simplicity of Docker Compose and the reality of Kubernetes in production. You validate your manifests, you test your Helm charts, you debug with the real tools, all without leaving your terminal.

The Rancher tools (k3s, k3d) form a coherent ecosystem covering installation, management and destruction of clusters. Whether for a persistent cluster on your workstation or ephemeral clusters in CI, K3S adapts.

The real gain is reducing the gap between "it works in dev" and "it works in prod." If your deployment, your service, your ingress and your Helm chart work locally on K3S, they have a good chance of working on your production cluster, modulo the cloud resources and specific StorageClasses.
