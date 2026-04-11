---
title: "Docker Swarm to Kubernetes : stratégies de migration"
date: 2026-03-29
draft: false
summary: "Migrer de Docker Swarm à Kubernetes ne se fait pas en un week-end. Mapping des concepts, patterns de migration, pièges à éviter et retour d'expérience concret sur une migration en production."
tags: ["Kubernetes", "Docker Swarm", "Migration", "DevOps", "Helm"]
---

Docker Swarm a rendu service. Simple à mettre en place, intégré à Docker, suffisant pour des charges modestes. Mais à partir d'un certain point — scaling, observabilité, écosystème, recrutement — Kubernetes devient incontournable. Le problème, c'est que la migration n'est pas un simple changement de syntaxe. Les concepts ne mappent pas 1:1, et les pièges sont nombreux.

## Pourquoi migrer ?

Swarm fonctionne. Mais il stagne. Quelques constats qui poussent à la migration :

- **Écosystème limité** — pas d'équivalent à Helm, ArgoCD, Kyverno, Prometheus Operator… L'outillage autour de Swarm est quasi inexistant
- **Pas de CRD** — impossible d'étendre le modèle avec des ressources custom. Swarm ne gère que ce que Docker a prévu
- **Recrutement** — trouver quelqu'un qui connaît Swarm en 2026, c'est plus dur que trouver un profil Kubernetes
- **Support cloud** — OVH MKS, GKE, EKS, AKS… tous les clouds proposent du Kubernetes managé. Aucun ne propose du Swarm managé
- **Observabilité** — le monitoring natif de Swarm se limite à `docker service ls`. Pour du vrai monitoring, tu finis par réinventer la roue

La question n'est pas "faut-il migrer ?" mais "comment migrer proprement ?".

## Mapping des concepts

Avant de toucher au code, il faut comprendre comment les concepts Swarm se traduisent en Kubernetes.

### Ressources de base

| Docker Swarm | Kubernetes | Notes |
|---|---|---|
| `docker stack` | Namespace + Helm Release | Un stack Swarm = un namespace logique |
| `docker service` | Deployment + Service | Swarm mélange les deux concepts |
| `replicas` | `spec.replicas` | Mapping direct |
| `docker config` | ConfigMap | Quasi identique |
| `docker secret` | Secret | Même logique, encodage base64 en plus |
| `docker network` (overlay) | NetworkPolicy + CNI | Kubernetes sépare réseau et politique |
| `docker volume` | PersistentVolumeClaim | Plus structuré côté Kubernetes |

### Concepts sans équivalent direct

Certaines fonctionnalités Swarm n'ont pas de pendant direct en Kubernetes :

| Docker Swarm | Kubernetes | Approche |
|---|---|---|
| `deploy.placement.constraints` | `nodeSelector` / `affinity` | Plus expressif côté K8s |
| `deploy.update_config` | `strategy.rollingUpdate` | Paramètres différents |
| `deploy.rollback_config` | `kubectl rollout undo` | Rollback manuel ou GitOps |
| Routing mesh intégré | Service type LoadBalancer / Ingress | Nécessite un Ingress Controller |
| `docker stack deploy` | `helm install` / `kubectl apply` | ArgoCD pour le GitOps |

## Migration pas à pas

### Phase 1 : inventaire et priorisation

Avant de migrer quoi que ce soit, fais l'inventaire complet :

```bash
# Lister tous les stacks
docker stack ls

# Détailler chaque stack
docker stack services mon-app

# Exporter la config
docker stack config mon-app > mon-app-compose.yml
```

Classe tes services en trois catégories :

1. **Stateless simples** — APIs, frontends, workers : migration facile
2. **Stateful** — bases de données, queues : migration complexe, à faire en dernier
3. **Infra** — reverse proxy, monitoring : à remplacer par l'équivalent Kubernetes natif

Commence toujours par les stateless simples pour valider le process.

### Phase 2 : traduire un docker-compose en manifestes Kubernetes

Prenons un service Swarm typique :

```yaml
# docker-compose.yml (Swarm mode)
version: "3.8"
services:
  api:
    image: registry.example.com/mon-api:1.5.2
    deploy:
      replicas: 3
      update_config:
        parallelism: 1
        delay: 10s
        order: start-first
      resources:
        limits:
          cpus: "0.5"
          memory: 256M
        reservations:
          cpus: "0.25"
          memory: 128M
      restart_policy:
        condition: on-failure
    environment:
      - DATABASE_URL=postgres://db:5432/app
      - LOG_LEVEL=info
    configs:
      - source: api-config
        target: /app/config.yaml
    secrets:
      - db-password
    networks:
      - backend
    ports:
      - "8080:8080"

configs:
  api-config:
    file: ./config.yaml

secrets:
  db-password:
    external: true

networks:
  backend:
    driver: overlay
```

L'équivalent Kubernetes :

```yaml
# deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: api
  namespace: mon-app
spec:
  replicas: 3
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0  # Equivalent de order: start-first
  selector:
    matchLabels:
      app: api
  template:
    metadata:
      labels:
        app: api
    spec:
      containers:
        - name: api
          image: registry.example.com/mon-api:1.5.2
          ports:
            - containerPort: 8080
          env:
            - name: DATABASE_URL
              value: "postgres://db:5432/app"
            - name: LOG_LEVEL
              value: "info"
          envFrom:
            - secretRef:
                name: db-credentials
          volumeMounts:
            - name: config
              mountPath: /app/config.yaml
              subPath: config.yaml
          resources:
            requests:
              cpu: 250m
              memory: 128Mi
            limits:
              cpu: 500m
              memory: 256Mi
          livenessProbe:
            httpGet:
              path: /health
              port: 8080
            initialDelaySeconds: 10
          readinessProbe:
            httpGet:
              path: /ready
              port: 8080
            initialDelaySeconds: 5
      volumes:
        - name: config
          configMap:
            name: api-config
---
# service.yaml
apiVersion: v1
kind: Service
metadata:
  name: api
  namespace: mon-app
spec:
  selector:
    app: api
  ports:
    - port: 8080
      targetPort: 8080
---
# configmap.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: api-config
  namespace: mon-app
data:
  config.yaml: |
    # contenu de config.yaml
---
# secret.yaml
apiVersion: v1
kind: Secret
metadata:
  name: db-credentials
  namespace: mon-app
type: Opaque
stringData:
  DB_PASSWORD: "changeme"  # En vrai, utilise Sealed Secrets / Vault / ESO
```

Points clés de la traduction :

- **`update_config.order: start-first`** → `maxUnavailable: 0` + `maxSurge: 1` — le nouveau pod démarre avant de couper l'ancien
- **`resources.reservations`** → `resources.requests` — même concept, nom différent
- **`restart_policy`** → géré nativement par le kubelet, pas besoin de le spécifier
- **Probes** — Swarm n'a que le healthcheck Docker. Kubernetes sépare liveness (redémarrer) et readiness (retirer du load balancing)

### Phase 3 : Helm charts pour industrialiser

Traduire chaque service en YAML brut, ça marche pour un POC. En production, passe par Helm, au début c'est compliqué mais maintenant Helm met indispensable :

```bash
helm create mon-api
```

Le chart généré contient déjà un Deployment, Service, Ingress, ServiceAccount, et HPA. Adapte les `values.yaml` :

```yaml
# values.yaml
replicaCount: 3

image:
  repository: registry.example.com/mon-api
  tag: "1.5.2"

resources:
  requests:
    cpu: 250m
    memory: 128Mi
  limits:
    cpu: 500m
    memory: 256Mi

env:
  DATABASE_URL: "postgres://db:5432/app"
  LOG_LEVEL: "info"

ingress:
  enabled: true
  className: traefik
  hosts:
    - host: api.example.com
      paths:
        - path: /
          pathType: Prefix
```

Avantage : un seul chart paramétrable pour tous les environnements (dev, staging, prod) via des `values-<env>.yaml`.

### Phase 4 : réseau et exposition

Le routing mesh de Swarm est remplacé par un Ingress Controller. Si tu utilises déjà Traefik en Swarm (cas courant), la transition est naturelle :

**Avant (Swarm labels) :**

```yaml
services:
  api:
    deploy:
      labels:
        - "traefik.http.routers.api.rule=Host(`api.example.com`)"
        - "traefik.http.services.api.loadbalancer.server.port=8080"
```

**Après (IngressRoute CRD) :**

```yaml
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: api
  namespace: mon-app
spec:
  entryPoints:
    - websecure
  routes:
    - match: Host(`api.example.com`)
      kind: Rule
      services:
        - name: api
          port: 8080
  tls:
    secretName: api-tls
```

La logique est la même, la syntaxe est structurée au lieu d'être entassée dans des labels.

Pour le réseau interne, Swarm utilise des overlay networks. En Kubernetes, tous les pods se voient par défaut. Pour restreindre, utilise des NetworkPolicy :

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: api-network
  namespace: mon-app
spec:
  podSelector:
    matchLabels:
      app: api
  policyTypes:
    - Ingress
    - Egress
  ingress:
    - from:
        - podSelector:
            matchLabels:
              app: frontend
      ports:
        - port: 8080
  egress:
    - to:
        - podSelector:
            matchLabels:
              app: postgres
      ports:
        - port: 5432
```

### Phase 5 : données et volumes

C'est la partie la plus délicate. Un `docker volume` Swarm attaché à un service stateful ne se migre pas en un clic.

**Pour les bases de données :**

```yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: postgres
  namespace: mon-app
spec:
  serviceName: postgres
  replicas: 1
  selector:
    matchLabels:
      app: postgres
  template:
    metadata:
      labels:
        app: postgres
    spec:
      containers:
        - name: postgres
          image: postgres:16
          ports:
            - containerPort: 5432
          env:
            - name: POSTGRES_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: postgres-secret
                  key: password
          volumeMounts:
            - name: data
              mountPath: /var/lib/postgresql/data
  volumeClaimTemplates:
    - metadata:
        name: data
      spec:
        accessModes: ["ReadWriteOnce"]
        storageClassName: csi-cinder  # Adapter selon ton provider
        resources:
          requests:
            storage: 20Gi
```

Stratégie de migration des données :

1. **Dump/restore** — le plus simple et le plus sûr pour les BDD
2. **Réplication** — si tu peux te permettre un temps de migration plus long avec un follower sur le nouveau cluster
3. **Copie de volume** — `rsync` du volume Docker vers un PV Kubernetes (nécessite un accès aux deux côtés)

```bash
# Dump depuis Swarm
docker exec $(docker ps -q -f name=postgres) \
  pg_dump -U app -Fc app > dump.pgdata

# Restore dans Kubernetes
kubectl cp dump.pgdata mon-app/postgres-0:/tmp/dump.pgdata
kubectl exec -n mon-app postgres-0 -- \
  pg_restore -U app -d app /tmp/dump.pgdata
```

### Phase 6 : secrets

Les secrets Docker Swarm sont stockés dans le Raft log du cluster. En Kubernetes, les secrets sont en base64 dans etcd — pas chiffrés par défaut.

Pour une migration propre, utilise [Sealed Secrets](https://github.com/bitnami-labs/sealed-secrets) :

```bash
# Installer le controller
helm repo add sealed-secrets https://bitnami-labs.github.io/sealed-secrets
helm install sealed-secrets sealed-secrets/sealed-secrets \
  --namespace kube-system

# Chiffrer un secret
echo -n "mon-mot-de-passe" | \
  kubeseal --raw --namespace mon-app --name db-credentials --from-file=/dev/stdin

# Créer un SealedSecret
cat <<EOF | kubeseal --format yaml > sealed-secret.yaml
apiVersion: v1
kind: Secret
metadata:
  name: db-credentials
  namespace: mon-app
type: Opaque
stringData:
  DB_PASSWORD: "mon-mot-de-passe"
EOF
```

Le SealedSecret peut être commité dans Git en toute sécurité. Seul le controller dans le cluster peut le déchiffrer.

## Les pièges classiques

### 1. Le piège du "on migre tout d'un coup"

Ne fais jamais une migration big bang. Migre service par service, en commençant par les moins critiques. Garde Swarm en parallèle pendant la transition.

```
Semaine 1-2 : Infra Kubernetes (Traefik, monitoring, ArgoCD)
Semaine 3-4 : Services stateless non critiques
Semaine 5-6 : Services stateless critiques
Semaine 7-8 : Services stateful (BDD, queues)
Semaine 9-10 : Bascule DNS, décommissionnement Swarm
```

### 2. Le piège du healthcheck

Swarm a un seul healthcheck. Kubernetes en a trois : `livenessProbe`, `readinessProbe`, et `startupProbe`. Ne pas les configurer, c'est garantir des 502 pendant les déploiements.

```yaml
# Erreur courante : pas de probe
containers:
  - name: api
    image: mon-api:1.0
    # Kubernetes considère le pod Ready dès le start
    # → le trafic arrive avant que l'app soit prête
    # → 502

# Correct
containers:
  - name: api
    image: mon-api:1.0
    startupProbe:
      httpGet:
        path: /health
        port: 8080
      failureThreshold: 30
      periodSeconds: 2
    livenessProbe:
      httpGet:
        path: /health
        port: 8080
      periodSeconds: 10
    readinessProbe:
      httpGet:
        path: /ready
        port: 8080
      periodSeconds: 5
```

### 3. Le piège du DNS interne

En Swarm, les services se résolvent par leur nom : `api` → résolution interne. En Kubernetes, c'est pareil mais avec des nuances :

- `api` → résolution dans le **même namespace**
- `api.mon-app` → résolution cross-namespace
- `api.mon-app.svc.cluster.local` → FQDN complet

Tips: `<service>.<namespace>.svc.cluster.local` / `<pod>.<service>.<namespace>.svc.cluster.local` / etc

Si tu avais des services qui communiquaient entre stacks Swarm via des réseaux partagés, il faut adapter les URLs pour inclure le namespace.

### 4. Le piège des logs

Swarm centralise les logs via `docker service logs`. En Kubernetes, les logs sont par pod et éphémères. Sans stack de logging, tu perds tout au redémarrage.

Installe une stack de collecte dès le début :

```yaml
# Loki + Promtail via Helm
helm repo add grafana https://grafana.github.io/helm-charts
helm install loki grafana/loki-stack \
  --namespace monitoring \
  --set promtail.enabled=true \
  --set loki.persistence.enabled=true \
  --set loki.persistence.size=10Gi
```

### 5. Le piège des ressources

Swarm est permissif : pas de limits obligatoires, pas de quotas par défaut. Kubernetes non plus, mais l'écosystème encourage fortement les bonnes pratiques. Profite de la migration pour mettre en place :

```yaml
# ResourceQuota par namespace
apiVersion: v1
kind: ResourceQuota
metadata:
  name: default-quota
  namespace: mon-app
spec:
  hard:
    requests.cpu: "4"
    requests.memory: 4Gi
    limits.cpu: "8"
    limits.memory: 8Gi
    pods: "20"
```

## Outils de migration

### Kompose — conversion automatique

[Kompose](https://kompose.io/) convertit un `docker-compose.yml` en manifestes Kubernetes :

```bash
kompose convert -f docker-compose.yml
```

C'est un bon point de départ, mais le résultat nécessite toujours des ajustements :
- Pas de probes générées
- Pas de resource limits pertinentes
- Pas d'Ingress adapté à ton setup
- Les volumes sont traduits en PVC basiques

Utilise Kompose pour le scaffolding initial, puis affine manuellement.

### Checklist de migration par service

Pour chaque service migré, vérifie :

- [ ] Image accessible depuis le cluster Kubernetes (registry, pull secrets)
- [ ] Variables d'environnement et secrets migrés
- [ ] Probes configurées (liveness + readiness minimum)
- [ ] Resource requests et limits définis
- [ ] Exposition réseau (Service + Ingress/IngressRoute)
- [ ] Volumes et données migrés si stateful
- [ ] Monitoring fonctionnel (métriques, logs)
- [ ] Test de rollback (`kubectl rollout undo`)
- [ ] DNS mis à jour ou trafic basculé

## Cohabitation Swarm / Kubernetes

Pendant la migration, les deux plateformes coexistent. Quelques patterns pour gérer la transition :

### Split DNS

Utilise le DNS pour diriger le trafic progressivement :

```
api.example.com → Swarm (poids 100)
# Migration en cours...
api.example.com → Swarm (poids 50) + Kubernetes (poids 50)
# Validation...
api.example.com → Kubernetes (poids 100)
# Décommissionnement Swarm
```

### Communication inter-plateformes

Si des services sur Swarm doivent parler à des services déjà migrés sur Kubernetes :

```yaml
# ExternalName Service dans Kubernetes
apiVersion: v1
kind: Service
metadata:
  name: legacy-service
  namespace: mon-app
spec:
  type: ExternalName
  externalName: legacy.swarm.internal
```

Et inversement, expose les services Kubernetes via un NodePort ou LoadBalancer accessible depuis le réseau Swarm.

## Bonnes pratiques

1. **Migre en binôme** — quelqu'un qui connaît l'app Swarm + quelqu'un qui connaît Kubernetes
2. **GitOps dès le premier service** — mets ArgoCD en place avant de commencer à migrer. Chaque service migré arrive directement en GitOps
3. **Monitoring d'abord** — installe Prometheus + Grafana avant de migrer les workloads. Tu veux voir les problèmes, pas les deviner
4. **Environnement de staging** — migre d'abord en staging, valide, puis reproduis en prod
5. **Automatise les rollbacks** — teste `kubectl rollout undo` sur chaque service. En cas de problème, le retour sur Swarm doit être possible tant que le DNS n'est pas basculé
6. **Documente les différences** — chaque service migré doit avoir une note sur ce qui a changé (URLs internes, variables d'env, volumes)
7. **Ne migre pas les bases de données en premier** — c'est tentant de "tout faire d'un coup", mais les stateful sont les plus risqués. Garde-les pour la fin
8. **Profite de la migration pour nettoyer** — c'est l'occasion de supprimer les services inutilisés, de standardiser les conventions de nommage, et de mettre en place les bonnes pratiques (probes, limits, network policies)

## Conclusion

Migrer de Docker Swarm à Kubernetes, c'est un projet en soi. Pas un changement de format de fichier. Les concepts sont proches mais les détails divergent suffisamment pour que chaque service nécessite une attention individuelle.

La clé, c'est la progressivité : infra d'abord, stateless ensuite, stateful en dernier. Avec du GitOps et du monitoring en place dès le départ, chaque étape est observable et réversible. Et une fois la migration terminée, tu accèdes à tout l'écosystème Kubernetes — [Helm](/articles/transfersh-helm-chart/), [ArgoCD](/articles/argocd-introduction/), [Traefik IngressRoute](/articles/traefik-v3-deep-dive/), [monitoring Prometheus](/articles/kubernetes-monitoring-prometheus-grafana/), [politiques Kyverno](/articles/container-security-trivy-kyverno/) — qui n'a pas d'équivalent côté Swarm.
