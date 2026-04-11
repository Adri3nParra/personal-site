---
title: "ArgoCD en pratique : GitOps simplifie"
date: 2026-03-28
draft: false
summary: "GitOps est le standard pour deployer sur Kubernetes, et ArgoCD en est l'implementation la plus populaire. Retour d'experience : comment ca marche, pourquoi c'est different d'un pipeline CI/CD classique, et comment structurer ses deploiements."
tags: ["GitOps", "ArgoCD", "Kubernetes", "DevOps"]
---

GitLab CI, Jenkins, GitHub Actions — les pipelines CI/CD, tout le monde connaît. Mais quand tu gères plusieurs clusters Kubernetes en production, les scripts de déploiement dans une pipeline ça pose vite des questions : qui a modifié quoi ? Comment rollbacker proprement ? Comment avoir un état desired vs actual visible ?

GitOps répond à ces questions. ArgoCD en est l'implémentation la plus répandue. Voici comment ça fonctionne concrètement.

## GitOps, kezako ?

Le principe est simple : **le dépôt Git est la seule source de vérité**. Ton code Kubernetes (manifests, Helm charts, Kustomize) vit dans Git. ArgoCD surveille ce dépôt et syncronise automatiquement l'état desiré (dans Git) avec l'état réel (dans le cluster).

```
Git (desired state)  →  ArgoCD  →  Kubernetes (actual state)
```

La différence fondamentale avec un pipeline CI/CD classique :

| | Pipeline CI/CD | GitOps (ArgoCD) |
|---|---|---|
| **Déclencheur** | push sur la branche, MR… | commit Git |
| **Qui déploie** | Runner / Agent CI | ArgoCD (pull) |
| **Rollback** | `git revert` + pipeline | `git revert` (ArgoCD sync) |
| **Visibilité** | Logs de pipeline | Dashboard temps réel |
| **Drift detection** | Manuelle | Automatique |

Dans un pipeline classique, tu pousses vers le cluster. Avec GitOps, ArgoCD tire les changements depuis le cluster.

## Installation

ArgoCD se déploie sur un cluster Kubernetes — souvent le même que celui qu'il gère, mais il peut gérer plusieurs clusters (y compris des clusters externes).

```bash
# Installation via Helm
helm repo add argo https://argoproj.github.io/argo-helm
helm install argocd argo/argo-cd \
  --namespace argocd \
  --create-namespace \
  --values - <<EOF
redis:
  enabled: true
server:
  ingress:
    enabled: true
    ingressClassName: traefik
    hosts:
      - argocd.example.com
EOF
```

Accès au dashboard (après création de l'Ingress) :

```bash
# Récupérer le mot de passe admin
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d
```

## Le concept d'Application

L'objet central dans ArgoCD, c'est l'**Application**. C'est la relation entre un dépôt Git et un cluster/namespace destination.

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: mon-app
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/mon-org/k8s-manifests
    targetRevision: main
    path: apps/mon-app
  destination:
    server: https://kubernetes.default.svc
    namespace: production
  syncPolicy:
    automated:
      selfHeal: true
      prune: true
```

Cette Application dit : "Syncronise le contenu de `apps/mon-app` dans le dépôt Git avec le namespace `production` du cluster courant."

### Les sources supportées

ArgoCD ne déploie pas que des manifests YAML bruts :

- **Git repository** — manifests bruts, Kustomize, Helm (values inline ou fichiers)
- **Helm repository** — charts depuis un registry Helm
- **OCI registry** — charts Docker/OCI (depuis GitHub Container Registry, Docker Hub…)
- **Bitbucket, GitLab, Azure DevOps** — en plus de GitHub

## Sync et Drift

### Drift detection

ArgoCD compare en permanence l'état desired (Git) avec l'état réel (cluster). Si quelqu'un modifie un Deployment manuellement avec `kubectl`, ArgoCD le détecte et affiche l'application comme **OutOfSync**.

```bash
# Voir le statut
argocd app get mon-app
```

```
Name:               mon-app
Project:            default
Server:             kubernetes.default.svc
Namespace:          production
URL:                https://argocd.example.com/applications/mon-app
Repo:               https://github.com/mon-org/k8s-manifests
Target:             a1b2c3d (main)
Sync Status:        OutOfSync (1 pod replica count differs)
Health Status:      Healthy
```

### Sync manuelle

```bash
# Sync manuelle
argocd app sync mon-app

# Spécifier une révision
argocd app sync mon-app --revision v2.1.0
```

### Sync automatique

Avec `syncPolicy.automated`, ArgoCD syncronise automatiquement quand il détecte un changement dans Git :

```yaml
syncPolicy:
  automated:
    selfHeal: true    # Corrige le drift automatiquement
    prune: true       # Supprime les ressources supprimées dans Git
```

**Attention** : `selfHeal` peut être dangereux en production si tu ne testes pas tes changements. Beaucoup d'équipes préfèrent une sync manuelle avec un `argocd app sync` explicite dans leur pipeline CI.

## Kustomize ou Helm ?

C'est LA question. Les deux fonctionnent, les deux ont des adeptes.

### Kustomize

Kustomize est intégré à `kubectl` et parfait pour les overlays simples :

```
base/
  deployment.yaml
  service.yaml
  kustomization.yaml
overlays/
  staging/
    kustomization.yaml
    replica-count.yaml
  production/
    kustomization.yaml
    replica-count.yaml
```

```yaml
# overlays/production/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ../../base
patches:
  - path: replica-count.yaml
    target:
      kind: Deployment
```

```yaml
# overlays/production/replica-count.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: mon-app
spec:
  replicas: 5
```

ArgoCD génère le manifest final avant de l'appliquer. Tu obtiens un diff propre :

```bash
argocd app diff mon-app
```

### Helm

Helm reste indispensable quand tu utilises des charts tiers (Bitnami, Prometheus, cert-manager…). ArgoCD intègre nativement Helm :

```yaml
spec:
  source:
    repoURL: https://prometheus-community.github.io/helm-charts
    chart: prometheus
    targetRevision: 25.0.0
    helm:
      valueFiles:
        - values.production.yaml
      values: |
        replicaCount: 3
        service:
          type: ClusterIP
```

```bash
# Voir les valeurs
argocd app get mon-app --show-yaml
```

### Mon avis

| | Kustomize | Helm |
|---|---|---|
| **Pour** | Simple, pas de syntaxe nouvelle | Templates puissants, registry de charts |
| **Contre** | Pas de fonctions conditionnelles | Complexité des templates pour les overlays |
| **Use case ideal** | Tes propres apps | Charts tiers, apps avec beaucoup de config |

## Projects — organiser les Applications

Les **AppProjects** permettent de regrouper les Applications et imposer des contraintes :

```yaml
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: production
  namespace: argocd
spec:
  sourceRepos:
    - https://github.com/mon-org/*
    - https://github.com/mon-org/k8s-manifests
  destinations:
    - server: https://kubernetes.default.svc
      namespace: production
  clusterResourceWhitelist:
    - group: ""
      kind: Namespace
  namespaceResourceBlacklist:
    - group: ""
      kind: ResourceQuota
```

Les contraintes possibles :
- **sourceRepos** — quels dépôts sont autorisés
- **destinations** — quels clusters/namespaces sont autorisés
- **namespaceResourceBlacklist** — resources que ArgoCD ne gère pas
- **clusterResourceWhitelist** — resources cluster-wide autorisées

Ça permet d'isoler les équipes : le projet "production" ne peut déployer que dans le namespace `production`, pas dans `staging` ou `kube-system`.

## Rollback en un clin d'oeil

C'est là que GitOps brille. Rollbacker, c'est juste revenir à un commit précédent :

```bash
# Lister les révisions déployées
argocd app history mon-app

ID  DATE                           COMMIT    MESSAGE
1   2026-03-01 10:00:00 +0100 CET  a1b2c3d   feat: ajout monitoring
2   2026-03-15 14:30:00 +0100 CET  d4e5f6g   fix: hotfix replicas
3   2026-03-20 09:15:00 +0100 CET  h7i8j9k   chore: dep updates

# Rollback vers la révision 2
argocd app rollback mon-app 2
```

ArgoCD redéploie le manifest à l'état du commit `d4e5f6g`. Pas besoin de `helm rollback`, pas de manipulation de state — Git fait tout.

## Intégration avec GitLab CI

Mon setup typique : la CI build et push l'image Docker, puis déclenche une sync ArgoCD :

```yaml
# .gitlab-ci.yml
build:
  stage: build
  image: docker:latest
  services:
    - docker:dind
  script:
    - docker build -t registry.example.com/mon-app:$CI_COMMIT_SHA .
    - docker push registry.example.com/mon-app:$CI_COMMIT_SHA
    - echo $CI_COMMIT_SHA > commit_sha.txt
  artifacts:
    paths:
      - commit_sha.txt

deploy:
  stage: deploy
  image: bitnami/argocd:latest
  script:
    - argocd login argocd.example.com --username $ARGOCD_USER --password $ARGOCD_PASSWORD
    - argocd app set mon-app --kustomize-images registry.example.com/mon-app=$CI_COMMIT_SHA
    - argocd app sync mon-app --force
  dependencies:
    - build
  when: manual
```

Le `when: manual` permet de valider avant de syncroniser. L'image tag est mise à jour via Kustomize (ou Helm values), et ArgoCD détecte le changement.

## Multi-cluster

Un ArgoCD installé sur un cluster "management" peut gérer d'autres clusters :

```bash
# Enregistrer un cluster externe dans ArgoCD
argocd cluster add mon-prod-cluster --name production
```

```bash
# Liste des clusters connus
argocd cluster list
SERVER                          NAME          VERSION  STATUS   MESSAGE
https://kubernetes.default.svc   in-cluster    1.30     True     Successful
https://prod.example.com:6443    production    1.29     True     Successful
```

L'Application peut alors cibler n'importe quel cluster enregistré :

```yaml
spec:
  destination:
    server: https://prod.example.com:6443
    namespace: production
```

Un seul ArgoCD, plusieurs clusters — c'est le setup que j'utilise en production.

## Webhooks — éviter le polling

Par défaut, ArgoCD poll le dépôt toutes les 3 minutes. Pour une réactivité immédiate, configure un webhook :

```yaml
# Dans ArgoCD configmap
data:
  resource.customizations: |
    argoproj.io/Application:
      health.lua: |
        ...
```

Le webhook se configure côté GitLab :

```
Settings → Webhooks → Add webhook
URL: https://argocd.example.com/api/webhook
Secret token: (generer un token)
Events: Push events
```

À chaque push, ArgoCD est notifié et syncronise immédiatement.

## Bonnes pratiques

### 1. Un dépôt par application (ou par domaine)

Évite le mega-repo avec 50 apps. Chaque dépôt = une Application ArgoCD = un cycle de vie indépendant. Plus facile à maintenir, plus simple à sécuriser.

### 2. Toujours un diff avant sync

```bash
argocd app diff mon-app --local ./manifests
```

Compare ton état local (non commité) avec ce qu'ArgoCD connaît. Évite les surprises.

### 3. Utiliser les PreSync Hooks pour les migrations

Si tu as besoin de migrer une BDD avant de déployer :

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: db-migration
  annotations:
    argocp.argoproj.io/hook: PreSync
    argocp.argoproj.io/hook-delete-policy: HookSucceeded
spec:
  template:
    spec:
      containers:
        - name: migrate
          image: mon-app:latest
          command: ["migrate.sh"]
      restartPolicy: Never
  backoffLimit: 3
```

`PreSync` s'exécute avant le déploiement, `Sync` pendant, `PostSync` après. `HookSucceeded` supprime le Job une fois terminé.

### 4. Rester sur une image tag stable

Évite les tags `latest` ou `main`. Utilise le SHA de l'image :

```yaml
image: registry.example.com/mon-app@sha256:a1b2c3d4...
```

Plus de doute sur "quelle version est déployée". Le SHA est déterministe.

## Conclusion

ArgoCD transforme la gestion Kubernetes en quelque chose de visible et reproductible. Le dépôt Git devient l'audit trail de tes déploiements, le dashboard montre l'état réel vs desired, et le rollback est une question de `git revert`.

Le coût : un cluster dédié à ArgoCD (ou le même si t'as les ressources) + la discipline de passer par Git pour tout changement. En retour, tu gagnes en traçabilité, en confiance dans les déploiements, et en temps passé à debugger "qui a cassé quoi".

C'est devenu le standard de facto pour le GitOps Kubernetes. Si tu gères plus de deux clusters, c'est presque indispensable.
