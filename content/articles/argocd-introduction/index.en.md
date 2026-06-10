---
title: "ArgoCD in practice: GitOps made simple"
date: 2026-03-28
draft: false
summary: "GitOps is the standard for deploying to Kubernetes, and ArgoCD is its most popular implementation. A hands-on review: how it works, why it's different from a classic CI/CD pipeline, and how to structure your deployments."
tags: ["GitOps", "ArgoCD", "Kubernetes", "DevOps"]
---

GitLab CI, Jenkins, GitHub Actions: everyone knows CI/CD pipelines. But when you manage several Kubernetes clusters in production, deployment scripts inside a pipeline quickly raise questions: who changed what? How do you roll back cleanly? How do you get a visible desired vs. actual state?

GitOps answers these questions. ArgoCD is its most widespread implementation. Here's how it works concretely.

## GitOps, what's that?

The principle is simple: **the Git repository is the single source of truth**. Your Kubernetes code (manifests, Helm charts, Kustomize) lives in Git. ArgoCD watches this repository and automatically synchronizes the desired state (in Git) with the actual state (in the cluster).

```
Git (desired state)  →  ArgoCD  →  Kubernetes (actual state)
```

The fundamental difference from a classic CI/CD pipeline:

| | CI/CD pipeline | GitOps (ArgoCD) |
|---|---|---|
| **Trigger** | push to the branch, MR… | Git commit |
| **Who deploys** | CI Runner / Agent | ArgoCD (pull) |
| **Rollback** | `git revert` + pipeline | `git revert` (ArgoCD sync) |
| **Visibility** | Pipeline logs | Real-time dashboard |
| **Drift detection** | Manual | Automatic |

In a classic pipeline, you push to the cluster. With GitOps, ArgoCD pulls the changes from the cluster.

## Installation

ArgoCD is deployed on a Kubernetes cluster, often the same one it manages, but it can manage several clusters (including external clusters).

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

Accessing the dashboard (after creating the Ingress):

```bash
# Retrieve the admin password
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d
```

## The Application concept

The central object in ArgoCD is the **Application**. It's the relationship between a Git repository and a destination cluster/namespace.

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

This Application says: "Synchronize the content of `apps/mon-app` in the Git repository with the `production` namespace of the current cluster."

### Supported sources

ArgoCD doesn't only deploy raw YAML manifests:

- **Git repository**: raw manifests, Kustomize, Helm (inline values or files)
- **Helm repository**: charts from a Helm registry
- **OCI registry**: Docker/OCI charts (from GitHub Container Registry, Docker Hub…)
- **Bitbucket, GitLab, Azure DevOps**: in addition to GitHub

## Sync and Drift

### Drift detection

ArgoCD continuously compares the desired state (Git) with the actual state (cluster). If someone modifies a Deployment manually with `kubectl`, ArgoCD detects it and shows the application as **OutOfSync**.

```bash
# View the status
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

### Manual sync

```bash
# Manual sync
argocd app sync mon-app

# Specify a revision
argocd app sync mon-app --revision v2.1.0
```

### Automatic sync

With `syncPolicy.automated`, ArgoCD synchronizes automatically when it detects a change in Git:

```yaml
syncPolicy:
  automated:
    selfHeal: true    # Fixes drift automatically
    prune: true       # Deletes resources removed in Git
```

**Warning**: `selfHeal` can be dangerous in production if you don't test your changes. Many teams prefer a manual sync with an explicit `argocd app sync` in their CI pipeline.

## Kustomize or Helm?

That's THE question. Both work, both have their fans.

### Kustomize

Kustomize is built into `kubectl` and perfect for simple overlays:

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

ArgoCD generates the final manifest before applying it. You get a clean diff:

```bash
argocd app diff mon-app
```

### Helm

Helm remains indispensable when you use third-party charts (Bitnami, Prometheus, cert-manager…). ArgoCD integrates Helm natively:

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
# View the values
argocd app get mon-app --show-yaml
```

### My take

| | Kustomize | Helm |
|---|---|---|
| **Pros** | Simple, no new syntax | Powerful templates, chart registry |
| **Cons** | No conditional functions | Template complexity for overlays |
| **Ideal use case** | Your own apps | Third-party charts, apps with lots of config |

## Projects: organizing Applications

**AppProjects** let you group Applications and enforce constraints:

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

The possible constraints:
- **sourceRepos**: which repositories are allowed
- **destinations**: which clusters/namespaces are allowed
- **namespaceResourceBlacklist**: resources ArgoCD doesn't manage
- **clusterResourceWhitelist**: allowed cluster-wide resources

This lets you isolate teams: the "production" project can only deploy to the `production` namespace, not to `staging` or `kube-system`.

## Rollback in the blink of an eye

This is where GitOps shines. Rolling back is just going back to a previous commit:

```bash
# List deployed revisions
argocd app history mon-app

ID  DATE                           COMMIT    MESSAGE
1   2026-03-01 10:00:00 +0100 CET  a1b2c3d   feat: add monitoring
2   2026-03-15 14:30:00 +0100 CET  d4e5f6g   fix: hotfix replicas
3   2026-03-20 09:15:00 +0100 CET  h7i8j9k   chore: dep updates

# Rollback to revision 2
argocd app rollback mon-app 2
```

ArgoCD redeploys the manifest at the state of commit `d4e5f6g`. No need for `helm rollback`, no state manipulation — Git does everything.

## Integration with GitLab CI

My typical setup: CI builds and pushes the Docker image, then triggers an ArgoCD sync:

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

The `when: manual` lets you validate before synchronizing. The image tag is updated via Kustomize (or Helm values), and ArgoCD detects the change.

## Multi-cluster

An ArgoCD installed on a "management" cluster can manage other clusters:

```bash
# Register an external cluster in ArgoCD
argocd cluster add mon-prod-cluster --name production
```

```bash
# List of known clusters
argocd cluster list
SERVER                          NAME          VERSION  STATUS   MESSAGE
https://kubernetes.default.svc   in-cluster    1.30     True     Successful
https://prod.example.com:6443    production    1.29     True     Successful
```

The Application can then target any registered cluster:

```yaml
spec:
  destination:
    server: https://prod.example.com:6443
    namespace: production
```

A single ArgoCD, several clusters — that's the setup I use in production.

## Webhooks: avoiding polling

By default, ArgoCD polls the repository every 3 minutes. For immediate responsiveness, configure a webhook:

```yaml
# In the ArgoCD configmap
data:
  resource.customizations: |
    argoproj.io/Application:
      health.lua: |
        ...
```

The webhook is configured on the GitLab side:

```
Settings → Webhooks → Add webhook
URL: https://argocd.example.com/api/webhook
Secret token: (generate a token)
Events: Push events
```

On each push, ArgoCD is notified and synchronizes immediately.

## Best practices

### 1. One repository per application (or per domain)

Avoid the mega-repo with 50 apps. Each repository = one ArgoCD Application = an independent lifecycle. Easier to maintain, simpler to secure.

### 2. Always diff before sync

```bash
argocd app diff mon-app --local ./manifests
```

Compares your local (uncommitted) state with what ArgoCD knows. Avoids surprises.

### 3. Use PreSync Hooks for migrations

If you need to migrate a database before deploying:

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

`PreSync` runs before the deployment, `Sync` during, `PostSync` after. `HookSucceeded` deletes the Job once finished.

### 4. Stick to a stable image tag

Avoid `latest` or `main` tags. Use the image SHA:

```yaml
image: registry.example.com/mon-app@sha256:a1b2c3d4...
```

No more doubt about "which version is deployed." The SHA is deterministic.

## Conclusion

ArgoCD turns Kubernetes management into something visible and reproducible. The Git repository becomes the audit trail of your deployments, the dashboard shows actual vs. desired state, and rolling back is a matter of `git revert`.

The cost: a cluster dedicated to ArgoCD (or the same one if you have the resources) + the discipline of going through Git for every change. In return, you gain traceability, confidence in deployments, and time saved debugging "who broke what."

It's become the de facto standard for Kubernetes GitOps. If you manage more than two clusters, it's almost indispensable.
