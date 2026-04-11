---
title: "K3S for Local Development : Un mini cluster de production"
date: 2026-03-29
draft: false
summary: "K3S n'est pas qu'un cluster pour l'IoT. Voici comment l'utiliser comme environnement de développement local qui reflète ta prod, sans les 2000 euros de factures cloud par mois."
tags: ["Kubernetes", "K3S", "Développement", "DevOps", "Homelab"]
---

Quand tu bosses sur des architectures microservices qui tournent sur Kubernetes en production, développer en local sur Docker Compose, c'est un peu comme répéter une pièce de théâtre dans ton salon alors que le spectacle est en salle. Les conditions sont différentes, les surprises sont garanties, et le public n'est pas dupe.

K3S, le cluster Kubernetes léger de Rancher (SUSE), c'est une autre approche. Au lieu de développer sur une version dégradée de ton infra, tu tournes un vrai cluster Kubernetes sur ta machine. Les mêmes manifests, les mêmes outils, les mêmes concepts.

## Pourquoi K3S et pas kind ou Minikube ?

| Critère | K3S | kind | Minikube |
|---|---|---|---|
| Multi-nœuds | Oui | Oui (via nodes extra) | Non |
| Cluster persistant | Oui | Non (reset à chaque restart) | Oui |
| Temps de démarrage | ~30s | ~60s | ~90s |
| Production-like | Élevé | Moyen | Moyen |
| Ressources | ~512Mo RAM | ~2Go RAM | ~2Go RAM |
| Intégration Docker | native | native | native |

K3S démarre vite, consomme peu, et contrairement à kind, ton cluster persiste entre les sessions. C'est le choix le plus pertinent pour un environnement de dev quotidien.

## Installation

### Prérequis

- Linux (désolé, je ne travaille pas sur un autre OS)
- 2 Go RAM minimum (4 Go recommandé)
- Docker installé ou container.d

### Script d'installation

```bash
curl -sfL https://get.k3s.io | sh -
```

Ou via le binaire si tu préfères :

```bash
curl -Lo /usr/local/bin/k3s https://github.com/k3s-io/k3s/releases/download/v1.30.0+k3s1/k3s
chmod +x /usr/local/bin/k3s
k3s server
```

Le service K3S crée automatiquement son contexte kubectl. Pour accéder depuis ton host :

```bash
mkdir -p ~/.kube
sudo k3s kubectl config view --flatten > ~/.kube/config
sudo chmod 644 ~/.kube/config
```

Vérifie que ça fonctionne :

```bash
kubectl get nodes
# NAME        STATUS   ROLES                  AGE   VERSION
# localhost   Ready    control-plane,master   10s   v1.30.0+k3s1
```

## Setup pour un environnement production-like

Ton cluster de dev doit ressembler à ta prod sans en avoir les contraintes (quotas, network policies restrictives, etc.).

### Stockage

En production, tu as probablement un StorageClass sur un cloud provider. En local, utilise `local-path` :

```bash
kubectl get storageclass
# NAME                   PROVISIONER             RECLAIMPOLICY
# local-path (default)   rancher.io/local-path  Delete
```

Crée un PVC pour tes données persistantes :

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

En prod, tu as probablement Traefik, NGINX, ou un Ingress cloud. K3S inclut Traefik par défaut :

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

Configure `/etc/hosts` pour la résolution locale :

```bash
# /etc/hosts
127.0.0.1 api.local
127.0.0.1 frontend.local
127.0.0.1 postgres.local
```

### Namespaces par environnement

Isole tes namespaces comme en prod :

```bash
kubectl create namespace dev
kubectl create namespace staging
kubectl label namespaces dev env=dev
kubectl label namespaces staging env=staging
```

## Workflow de développement

### Option 1 : apply classique (workflow GitOps)

Quand tu veux tester tes manifests :

```bash
# Applique tout d'un coup
kubectl apply -k ./manifests/

# Ou fichier par fichier
kubectl apply -f ./manifests/api-deployment.yaml
kubectl apply -f ./manifests/api-service.yaml

# Vérifie que tout tourne
kubectl get all -n dev
# NAME                        READY   STATUS    RESTARTS   AGE
# pod/api-7d9f8b4c6-x2kz9     1/1     Running   0          45s
# pod/postgres-0              1/1     Running   0          2m
```

### Option 2 : dev loop avec Tilt ou Skaffold

Pour un cycle refresh plus rapide, utilise [Tilt](https://tilt.dev/) :

```bash
# Installation
curl -fsSL https://raw.githubusercontent.com/tilt-dev/tilt/master/scripts/get-tilt.sh | bash
```

`Tiltfile` :

```python
# Tiltfile
k8s_yaml(['api-deployment.yaml', 'api-service.yaml', 'ingress.yaml'])
k8s_resource('api', port_forwards=8080)
docker_build('registry/api', '.')
```

Lancer `tilt up` et tu as :
- Rebuild automatique de l'image Docker sur modification du code
- Log streaming
- Port-forward automatique
- Interface web pour inspecter les ressources

### Option 3 : Helm pour industrialiser

Si ta prod utilise Helm (ce qui devrait être le cas), développe avec Helm :

```bash
# Template ton chart en local
helm template ./chart --namespace dev --set image.tag=dev

# Ou install directement (non recommandé en prod)
helm install api ./chart --namespace dev --create-namespace

# Upgrade après modification
helm upgrade api ./chart --namespace dev --set image.tag=dev2
```

values pour le développement :

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

## Debugging local

### Accéder aux logs

```bash
# Logs d'un pod
kubectl logs -n dev api-7d9f8b4c6-x2kz9 -f

# Logs de tous les pods d'un déploiement
kubectl logs -n dev -l app=api -f

# Logs précédent un crash
kubectl logs -n dev api-7d9f8b4c6-x2kz9 --previous
```

### Shell dans un container

```bash
kubectl exec -it -n dev api-7d9f8b4c6-x2kz9 -- /bin/sh
```

Ou plus direct avec `kubectl debug` (K8s 1.20+) :

```bash
kubectl debug -it -n dev api-7d9f8b4c6-x2kz9 --image=busybox --share-processes --copy-to=api-debug
```

### Port-forward pour le debug

```bash
# Forward un port local vers le service
kubectl port-forward -n dev svc/api 8080:8080

# Forward vers un pod directement
kubectl port-forward -n dev api-7d9f8b4c6-x2kz9 8080:8080

# Forward vers la base de données
kubectl port-forward -n dev svc/postgres 5432:5432
```

### Inspecter les ressources

```bash
# Describe pour voir les events et conditions
kubectl describe pod -n dev api-7d9f8b4c6-x2kz9

# Voir les resources requests/limits
kubectl top pod -n dev

# Lister les events
kubectl get events -n dev --sort-by='.lastTimestamp'
```

## Dashboard et tooling

### Kubernetes Dashboard

```bash
# Installation via Helm
helm repo add kubernetes-dashboard https://kubernetes.github.io/dashboard
helm install kubernetes-dashboard kubernetes-dashboard/kubernetes-dashboard -n kube-system

# Accès via kubectl proxy
kubectl proxy
# Puis ouvrir http://localhost:8001/api/v1/namespaces/kubernetes-dashboard/services/https:kubernetes-dashboard:/proxy/
```

Ou utilise `k9s`, plus léger et en terminal (perso, je suis plus CLI kubectl).

Interface en terminal avec navigation clavier, logs, describe, exec — tout ce qu'il faut sans quitter ta console.

## Limites et alternatives

K3S a des limites pour le dev local :

### Pas de load balancer intégré

En prod, tu as un LoadBalancer qui te donne une IP externe. En local, utilise `NodePort` ou `port-forward` pour accéder aux services depuis l'extérieur du cluster.

### Pas de ingress controller cloud

Tu dois configurer `/etc/hosts` manuellement ou utiliser [xip.io](http://xip.io/) pour du wildcard DNS local.

### Resources limitées

K3S tourne sur ta machine. Ne lance pas 50 pods en même temps. Utilise des namespaces pour isoler et éviter les conflits.

### Si tu as besoin de plusieurs nœuds

K3S supporte le multi-nœud pour tester des déploiements distribués :

```bash
# Sur le master
k3s server

# Sur un nœud worker (récupère le token d'abord)
cat /var/lib/rancher/k3s/server/node-token

# Sur le worker
curl -sfL https://get.k3s.io | K3S_URL=https://master:6443 K3S_TOKEN=<token> sh -
```

Pour des tests multi-nœuds ponctuels, [k3d](https://k3d.io/) est plus pratique (cluster dans Docker).

## Script de setup complet

Pour démarrer un environnement de dev K3S from scratch :

```bash
#!/bin/bash
set -e

NAMESPACE="dev"

echo "Installation de K3S..."
if ! command -v k3s &> /dev/null; then
    curl -sfL https://get.k3s.io | sh -
fi

echo "Configuration kubectl..."
mkdir -p ~/.kube
sudo k3s kubectl config view --flatten > ~/.kube/config
sudo chmod 644 ~/.kube/config

echo "Création du namespace de dev..."
kubectl create namespace $NAMESPACE 2>/dev/null || true

echo "Application des manifests de base..."
kubectl apply -f manifests/storage.yaml
kubectl apply -f manifests/ingress.yaml

echo "Vérification..."
kubectl get all -n $NAMESPACE

echo ""
echo "K3S prêt ! Cluster accessible via kubectl."
echo "Dashboard: kubectl proxy puis http://localhost:8001/api/v1/namespaces/kubernetes-dashboard/services/https:kubernetes-dashboard:/proxy/"
echo "Ou installe k9s: brew install derailed-dev/tools/k9s"
```

## Conclusion

K3S pour le développement local, c'est le compromis entre la simplicité de Docker Compose et la réalité de Kubernetes en production. Tu valides tes manifests, tu testes tes Helm charts, tu debug avec les vrais outils — le tout sans quitter ton terminal.

Les tools Rancher (k3s, k3d) forment un écosystème cohérent qui couvre installation, gestion et destruction des clusters. Que ce soit pour un cluster persistant sur ton poste ou des clusters éphémères en CI, K3S s'adapte.

Le vrai gain, c'est de réduire le gap entre "ça marche en dev" et "ça marche en prod". Si ton deployment, ton service, ton ingress et ton Helm chart fonctionnent en local sur K3S, ils ont de bonnes chances de fonctionner sur ton cluster prod — modulo les ressources cloud et les StorageClasses spécifiques.
