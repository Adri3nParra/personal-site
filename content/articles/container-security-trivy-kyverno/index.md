---
title: "Container Security : Trivy et Kyverno en production"
date: 2026-03-28
draft: false
summary: "Sécuriser un cluster Kubernetes en production, c'est pas qu'une question de réseau. Scan de vulnérabilités, politiques d'admission,least privilege : retour d'expérience avec Trivy et Kyverno."
tags: ["Kubernetes", "Sécurité", "Trivy", "Kyverno", "DevOps"]
---

Un cluster Kubernetes en production, c'est des dizaines d'images Docker qui tournent, des centaines de dépendances, et potentiellement des vulnérabilités connues. Laisser ça sans surveillance, c'est attendre l'incident.

Deux outils complémentaires couvrent la majorité des besoins : **Trivy** pour le scan et la détection, **Kyverno** pour les politiques d'admission. Le premier te montre les problèmes, le second les bloque.

## Trivy — le scanner de vulnérabilités

Trivy est open source (par Aqua Security), léger, et scanne tout : images Docker, fichiers filesystem, config Kubernetes, IaC (Terraform, CloudFormation)…

### Installation

```bash
# Via Helm sur le cluster
helm repo add aquasecurity https://aquasecurity.github.io/helm-charts
helm install trivy aquasecurity/trivy \
  --namespace trivy \
  --create-namespace
```

### Scan d'une image

```bash
# Scan basique
trivy image nginx:latest

# Format JSON pour automatisation
trivy image --format json --output report.json nginx:latest
```

La sortie :
```
nginx:latest (debian 12.8)
==========================
Total: 47 (unknown: 0, low: 12, medium: 23, high: 12, critical: 0)

Library                Type  Vulnerability    Severity  Status
--------------------- ----- --------------- --------- ------
libssl3               pkg   CVE-2024-12797   HIGH      Fixed
curl                  pkg   CVE-2024-12345  MEDIUM    Fixed
...
```

Trivy maintient une base de vulnérabilités à jour : NVD, GitHub Advisories, distributions Linux, bases Aqua, et même les CVE des principaux clouds.

### Scan CI/CD

Dans un pipeline GitLab :

```yaml
# .gitlab-ci.yml
trivy-scan:
  stage: security
  image:
    name: aquasec/trivy:latest
    entrypoint: [""]
  script:
    - trivy image --exit-code 1 --severity HIGH,CRITICAL $IMAGE_URL
  variables:
    IMAGE_URL: $CI_REGISTRY_IMAGE:$CI_COMMIT_SHA
  allow_failure: true  # Ou pas, selon ta politique
```

`--exit-code 1` fait échouer le job si des vulnérabilités HIGH/CRITICAL sont trouvées. `allow_failure: true` permet de garder le build fonctionnel tout en alertant.

### Scan Kubernetes Admission Controller

Trivy peut aussi bloquer les déploiements directement dans Kubernetes via un admission controller :

```bash
# Installation via Trivy Operator
kubectl apply -f https://raw.githubusercontent.com/aquasecurity/trivy-operator/main/deploy/static/trivy-operator.yaml
```

L'operator crée automatiquement des rapports de vulnérabilité pour chaque pod déployé :

```bash
kubectl get vulnerabilityreports
NAME                REPOSITORY          AGE
pod-replicaset-xxx  mon-app:latest     2d
```

### Les limites de Trivy

Trivy détecte les vulnérabilités connues dans les packages, mais :
- **Ne bloque pas l'exécution** sans admission controller
- **Ne contrôle pas le runtime** (comportement du conteneur une fois lancé)
- **Faux positifs possibles** sur des vulnérabilités non exploitables dans ton contexte

Pour le runtime, il faut Falco. Pour le contrôle des déploiements, il faut Kyverno.

## Kyverno — les politiques d'admission

Kyverno est un moteur de politiques pour Kubernetes. Contrairement à OPA/Gatekeeper qui utilise un DSL custom (Rego), Kyverno utilise des manifestes Kubernetes : si tu sais écrire un YAML, tu sais écrire une politique.

### Installation

```bash
# Via Helm
helm repo add kyverno https://kyverno.github.io/kyverno
helm install kyverno kyverno/kyverno \
  --namespace kyverno \
  --create-namespace \
  --values - <<EOF
backgroundController:
  replicas: 1
reportsController:
  replicas: 1
EOF
```

Vérifier :

```bash
kubectl get pods -n kyverno
NAME                          READY   STATUS
kyverno-admission-controller   1/1     Running
kyverno-reports-controller-0   1/1     Running
kyverno-background-controller  1/1     Running
```

## Écrire une politique

Une politique Kyverno est un `ClusterPolicy` ou une `Policy` (namespace-scoped). Exemple : interdire les conteneurs qui tournent en root :

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: disallow-root-user
spec:
  validationFailureAction: Enforce  # Bloque au lieu de juste alerter - Perso sur le cluster de dev -> Audit
  rules:
    - name: validate-runAsNonRoot
      match:
        resources:
          kinds:
            - Pod
      validate:
        message: "Les conteneurs ne doivent pas tourner en root."
        pattern:
          spec:
            containers:
              - (runAsNonRoot): true
            initContainers:
              - (runAsNonRoot): true
```

`(runAsNonRoot): true` — les parenthèses signifient "cette valeur doit exister et être true". Sans parenthèses, ça vérifie juste la présence.

### Valider avant d'appliquer

Les politiques ont trois modes :

| Mode | Comportement |
|---|---|
| `Audit` | Log les violations, n'empêche pas le déploiement |
| `Enforce` | Bloque le déploiement si violation |

```yaml
spec:
  validationFailureAction: Audit  # Pour tester avant d'Enforce
```

Un `Audit` permet de valider que ta politique ne génère pas de faux positifs avant de passer en production.

## Politiques utiles en production

### 1. Interdire les latest tags

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-image-tag
spec:
  validationFailureAction: Enforce
  rules:
    - name: require-image-tag
      match:
        resources:
          kinds:
            - Pod
      validate:
        message: "Chaque image doit avoir un tag explicite (pas latest)."
        pattern:
          spec:
            containers:
              - image: "!*:latest"
```

Le `!` signifie "ne doit pas correspondre au pattern". `*:latest` interdit le tag `latest`.

### 2. Require resource limits

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-resources
spec:
  validationFailureAction: Enforce
  rules:
    - name: require-limits
      match:
        resources:
          kinds:
            - Pod
      validate:
        message: "Les conteneurs doivent avoir des resource limits."
        pattern:
          spec:
            containers:
              - resources:
                  limits:
                    memory: "?*"
                    cpu: "?*"
```

`"?*"` signifie "au moins une valeur définie".

### 3. Bloquer les privileged pods

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: disallow-privileged-containers
spec:
  validationFailureAction: Enforce
  rules:
    - name: privileged-containers
      match:
        resources:
          kinds:
            - Pod
      validate:
        message: "Les conteneurs privileged ne sont pas autorisés."
        pattern:
          spec:
            =(containers):
              - securityContext:
                  (privileged): "!*true"
```

`=(containers)` avec `=` signifie "s'il existe, alors". Ça permet de ne pas bloquer les pods sans conteneurs (edge case).

### 4. Restreindre les capabilities Linux

Par défaut, un conteneur a beaucoup de capabilities système. Interdire les plus dangereuses :

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: restrict-capabilities
spec:
  validationFailureAction: Enforce
  rules:
    - name: drop-capabilities
      match:
        resources:
          kinds:
            - Pod
      validate:
        message: "Les capabilities SYS_ADMIN, NET_ADMIN et SYS_MODULE sont interdites."
        deny:
          conditions:
            - key: "[SYS_ADMIN, NET_ADMIN, SYS_MODULE]"
              operator: AnyIn
              value: "{{ request.object.spec.[containers, initContainers, ephemeralContainers].[*].securityContext.capabilities.add[] }}"
```

### 5. Régénérer les secrets injectés

Kyverno peut aussi muter les ressources. Exemple : ajouter un sidecar de monitoring automatiquement :

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: add-monitoring-sidecar
spec:
  mutation:
    rules:
      - name: add-envoy-sidecar
        match:
          resources:
            kinds:
              - Deployment
            namespaces:
              - production
        mutate:
          patchStrategicMerge:
            spec:
              template:
                spec:
                  containers:
                    - name: envoy
                      image: envoyproxy/envoy:latest
                      ports:
                        - containerPort: 9901
                          name: admin
```

Déployer dans `production` ? Kyverno ajoute automatiquement le sidecar.

## Trivy + Kyverno : le combo

Les deux outils se complètent :

| | Trivy | Kyverno |
|---|---|---|
| **Quand** | Build, admission, scan continu | Admission controller |
| **Quoi** | Vulnérabilités, config, IaC | Politiques (validate/mutate/generate) |
| **Action** | Détecte | Bloque ou modifie |

Mon setup typique :

```
CI/CD Pipeline
  └─ Trivy scan (exit-code si HIGH/CRITICAL)
  └─ Push image

GitOps Deployment
  └─ ArgoCD détecte le nouveau manifest

Kubernetes Admission
  ├─ Kyverno valide (pas de latest, limits requis, pas de root…)
  └─ Trivy Operator scanne les images déployées
```

### Admission avec Trivy Operator

Le Trivy Operator peut aussi bloquer via Kyverno :

```bash
# Activer l'admission controller
helm upgrade --install trivy aquasecurity/trivy \
  --namespace trivy \
  --set trivy.operator.rbac.jobAnnotations."checks\.trivy\.dev/required"="true"
```

Les vulnérabilités HIGH/CRITICAL dans une image peuvent bloquer le déploiement.

## Génération automatique

Kyverno peut générer des ressources automatiquement. Exemple : créer un NetworkPolicy quand un Namespace est créé :

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: default-deny-network
spec:
  rules:
    - name: deny-all
      match:
        resources:
          kinds:
            - Namespace
      generate:
        apiVersion: networking.k8s.io/v1
        kind: NetworkPolicy
        name: deny-all
        namespace: "{{ request.object.metadata.name }}"
        synchronize: true
        data:
          spec:
            podSelector: {}
            policyTypes:
              - Ingress
              - Egress
```

Chaque nouveau namespace aura automatiquement une politique `deny-all` qui bloque tout le trafic.

## Audit et rapports

Kyverno génère des rapports d'audit :

```bash
# Voir les violations
kubectl get polr -A

NAMESPACE    POLICY               RESOURCE            RESULT   MESSAGE
production   require-resources    deployment/mon-app  Pass     -
staging      require-resources    deployment/mon-app  Fail     Les conteneurs...
```

Intégration avec Prometheus :

```yaml
# Activer les métriques
kubectl get pods -n kyverno -l app.kubernetes.io/component=reports-controller
```

Les métriques incluent :
- `kyverno_policy_results_total` — résultats de politiques
- `kyverno_policy_execution_duration_seconds` — latence d'exécution

Grafana peut afficher les violations par namespace et politique.

## Bonnes pratiques

### 1. Commencer en Audit

Passe toutes tes politiques en `Audit` pendant une semaine. Vérifie les violations dans `kubectl get polr -A`. Corrige les workloads non conformes avant de passer en `Enforce`.

### 2. Exclure les exceptions

 Certaines ressources système nécessitent des exceptions :

```yaml
spec:
  validationFailureAction: Enforce
  exclude:
    - resources:
        namespaces:
          - kube-system
        kinds:
          - Pod
        names:
          - coredns-*
```

### 3. Versionner tes politiques

Traite tes politiques comme du code : Git, pull requests, review. Kyverno supporte les `ClusterPolicy` versionnées :

```yaml
metadata:
  annotations:
    policies.kyverno.io/title: Require Resources
    policies.kyverno.io/subject: Pod
    policies.kyverno.io/description: >
      Cette politique oblige les conteneurs à avoir des resources limits.
```

### 4. Combiner avec Falco

Kyverno et Trivy couvrent le build et l'admission. Falco surveille le runtime :
- Trivy : "cette image a des vulnérabilités connues"
- Kyverno : "ce déploiement ne respecte pas les politiques"
- Falco : "ce conteneur fait quelque chose de suspect maintenant"

Trois couches, trois moments différents.

## Conclusion

Sécuriser un cluster Kubernetes, c'est plusieurs couches :

1. **Build** — Trivy scanne les images avant de les push
2. **Admission** — Kyverno valide les manifestes au déploiement
3. **Runtime** — Falco (hors scope ici) détecte les comportements anormaux

Trivy et Kyverno couvrent les deux premières couches sans friction. Trivy s'intègre naturellement dans une CI, Kyverno s'intègre dans le contrôle plane Kubernetes. Les deux sont open source, maintenus activement, et la communauté fournit des politiques prêtes à l'emploi.

Le gain concret : tu bloques les déploiements non conformes, tu forces les équipes à utiliser des images patchées, et tu as de la visibilité sur les vulnérabilités. C'est pas parfait, mais c'est un excellent point de départ.
