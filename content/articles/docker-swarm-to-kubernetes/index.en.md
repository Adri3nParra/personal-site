---
title: "Docker Swarm to Kubernetes: migration strategies"
date: 2026-03-29
draft: false
summary: "Migrating from Docker Swarm to Kubernetes doesn't happen over a weekend. Concept mapping, migration patterns, pitfalls to avoid and a concrete hands-on review of a production migration."
tags: ["Kubernetes", "Docker Swarm", "Migration", "DevOps", "Helm"]
---

Docker Swarm served its purpose. Simple to set up, integrated into Docker, sufficient for modest workloads. But past a certain point (scaling, observability, ecosystem, hiring), Kubernetes becomes unavoidable. The problem is that the migration isn't a simple syntax change. The concepts don't map 1:1, and the pitfalls are numerous.

## Why migrate?

Swarm works. But it stagnates. A few observations that push toward migration:

- **Limited ecosystem**: no equivalent to Helm, ArgoCD, Kyverno, Prometheus Operator… The tooling around Swarm is almost nonexistent
- **No CRDs**: impossible to extend the model with custom resources. Swarm only handles what Docker planned for
- **Hiring**: finding someone who knows Swarm in 2026 is harder than finding a Kubernetes profile
- **Cloud support**: OVH MKS, GKE, EKS, AKS… every cloud offers managed Kubernetes. None offers managed Swarm
- **Observability**: Swarm's native monitoring is limited to `docker service ls`. For real monitoring, you end up reinventing the wheel

The question isn't "should we migrate?" but "how do we migrate cleanly?".

## Concept mapping

Before touching the code, you need to understand how Swarm concepts translate to Kubernetes.

### Base resources

| Docker Swarm | Kubernetes | Notes |
|---|---|---|
| `docker stack` | Namespace + Helm Release | A Swarm stack = a logical namespace |
| `docker service` | Deployment + Service | Swarm mixes the two concepts |
| `replicas` | `spec.replicas` | Direct mapping |
| `docker config` | ConfigMap | Almost identical |
| `docker secret` | Secret | Same logic, plus base64 encoding |
| `docker network` (overlay) | NetworkPolicy + CNI | Kubernetes separates network and policy |
| `docker volume` | PersistentVolumeClaim | More structured on the Kubernetes side |

### Concepts without a direct equivalent

Some Swarm features have no direct counterpart in Kubernetes:

| Docker Swarm | Kubernetes | Approach |
|---|---|---|
| `deploy.placement.constraints` | `nodeSelector` / `affinity` | More expressive on the K8s side |
| `deploy.update_config` | `strategy.rollingUpdate` | Different parameters |
| `deploy.rollback_config` | `kubectl rollout undo` | Manual rollback or GitOps |
| Built-in routing mesh | LoadBalancer Service / Ingress | Requires an Ingress Controller |
| `docker stack deploy` | `helm install` / `kubectl apply` | ArgoCD for GitOps |

## Step-by-step migration

### Phase 1: inventory and prioritization

Before migrating anything, do a complete inventory:

```bash
# List all stacks
docker stack ls

# Detail each stack
docker stack services mon-app

# Export the config
docker stack config mon-app > mon-app-compose.yml
```

Classify your services into three categories:

1. **Simple stateless**: APIs, frontends, workers — easy migration
2. **Stateful**: databases, queues — complex migration, do last
3. **Infra**: reverse proxy, monitoring — to be replaced by the native Kubernetes equivalent

Always start with the simple stateless ones to validate the process.

### Phase 2: translating a docker-compose into Kubernetes manifests

Let's take a typical Swarm service:

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

The Kubernetes equivalent:

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
      maxUnavailable: 0  # Equivalent of order: start-first
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
    # content of config.yaml
---
# secret.yaml
apiVersion: v1
kind: Secret
metadata:
  name: db-credentials
  namespace: mon-app
type: Opaque
stringData:
  DB_PASSWORD: "changeme"  # In reality, use Sealed Secrets / Vault / ESO
```

Key points of the translation:

- **`update_config.order: start-first`** → `maxUnavailable: 0` + `maxSurge: 1` — the new pod starts before cutting the old one
- **`resources.reservations`** → `resources.requests` — same concept, different name
- **`restart_policy`** → handled natively by the kubelet, no need to specify it
- **Probes**: Swarm only has the Docker healthcheck. Kubernetes separates liveness (restart) and readiness (remove from load balancing)

### Phase 3: Helm charts to industrialize

Translating each service into raw YAML works for a POC. In production, go through Helm — at first it's complicated but now Helm is indispensable:

```bash
helm create mon-api
```

The generated chart already contains a Deployment, Service, Ingress, ServiceAccount, and HPA. Adapt the `values.yaml`:

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

Advantage: a single parameterizable chart for all environments (dev, staging, prod) via `values-<env>.yaml`.

### Phase 4: networking and exposure

Swarm's routing mesh is replaced by an Ingress Controller. If you already use Traefik on Swarm (a common case), the transition is natural:

**Before (Swarm labels):**

```yaml
services:
  api:
    deploy:
      labels:
        - "traefik.http.routers.api.rule=Host(`api.example.com`)"
        - "traefik.http.services.api.loadbalancer.server.port=8080"
```

**After (IngressRoute CRD):**

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

The logic is the same, the syntax is structured instead of being crammed into labels.

For internal networking, Swarm uses overlay networks. In Kubernetes, all pods see each other by default. To restrict, use NetworkPolicies:

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

### Phase 5: data and volumes

This is the trickiest part. A Swarm `docker volume` attached to a stateful service doesn't migrate in one click.

**For databases:**

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
        storageClassName: csi-cinder  # Adapt to your provider
        resources:
          requests:
            storage: 20Gi
```

Data migration strategy:

1. **Dump/restore**: the simplest and safest for databases
2. **Replication**: if you can afford a longer migration time with a follower on the new cluster
3. **Volume copy**: `rsync` the Docker volume to a Kubernetes PV (requires access to both sides)

```bash
# Dump from Swarm
docker exec $(docker ps -q -f name=postgres) \
  pg_dump -U app -Fc app > dump.pgdata

# Restore into Kubernetes
kubectl cp dump.pgdata mon-app/postgres-0:/tmp/dump.pgdata
kubectl exec -n mon-app postgres-0 -- \
  pg_restore -U app -d app /tmp/dump.pgdata
```

### Phase 6: secrets

Docker Swarm secrets are stored in the cluster's Raft log. In Kubernetes, secrets are base64-encoded in etcd, not encrypted by default.

For a clean migration, use [Sealed Secrets](https://github.com/bitnami-labs/sealed-secrets):

```bash
# Install the controller
helm repo add sealed-secrets https://bitnami-labs.github.io/sealed-secrets
helm install sealed-secrets sealed-secrets/sealed-secrets \
  --namespace kube-system

# Encrypt a secret
echo -n "mon-mot-de-passe" | \
  kubeseal --raw --namespace mon-app --name db-credentials --from-file=/dev/stdin

# Create a SealedSecret
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

The SealedSecret can be committed to Git safely. Only the controller in the cluster can decrypt it.

## The classic pitfalls

### 1. The "migrate everything at once" trap

Never do a big-bang migration. Migrate service by service, starting with the least critical. Keep Swarm running in parallel during the transition.

```
Week 1-2: Kubernetes infra (Traefik, monitoring, ArgoCD)
Week 3-4: Non-critical stateless services
Week 5-6: Critical stateless services
Week 7-8: Stateful services (databases, queues)
Week 9-10: DNS switchover, Swarm decommissioning
```

### 2. The healthcheck trap

Swarm has a single healthcheck. Kubernetes has three: `livenessProbe`, `readinessProbe`, and `startupProbe`. Not configuring them is a guarantee of 502s during deployments.

```yaml
# Common mistake: no probe
containers:
  - name: api
    image: mon-api:1.0
    # Kubernetes considers the pod Ready as soon as it starts
    # → traffic arrives before the app is ready
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

### 3. The internal DNS trap

In Swarm, services resolve by their name: `api` → internal resolution. In Kubernetes, it's the same but with nuances:

- `api` → resolution within the **same namespace**
- `api.mon-app` → cross-namespace resolution
- `api.mon-app.svc.cluster.local` → full FQDN

Tip: `<service>.<namespace>.svc.cluster.local` / `<pod>.<service>.<namespace>.svc.cluster.local` / etc.

If you had services communicating between Swarm stacks via shared networks, you have to adapt the URLs to include the namespace.

### 4. The logs trap

Swarm centralizes logs via `docker service logs`. In Kubernetes, logs are per pod and ephemeral. Without a logging stack, you lose everything on restart.

Install a collection stack from the start:

```yaml
# Loki + Promtail via Helm
helm repo add grafana https://grafana.github.io/helm-charts
helm install loki grafana/loki-stack \
  --namespace monitoring \
  --set promtail.enabled=true \
  --set loki.persistence.enabled=true \
  --set loki.persistence.size=10Gi
```

### 5. The resources trap

Swarm is permissive: no mandatory limits, no default quotas. Kubernetes isn't either, but the ecosystem strongly encourages best practices. Take advantage of the migration to set up:

```yaml
# ResourceQuota per namespace
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

## Migration tools

### Kompose: automatic conversion

[Kompose](https://kompose.io/) converts a `docker-compose.yml` into Kubernetes manifests:

```bash
kompose convert -f docker-compose.yml
```

It's a good starting point, but the result always needs adjustments:
- No probes generated
- No relevant resource limits
- No Ingress tailored to your setup
- Volumes are translated to basic PVCs

Use Kompose for the initial scaffolding, then refine manually.

### Per-service migration checklist

For each migrated service, check:

- [ ] Image accessible from the Kubernetes cluster (registry, pull secrets)
- [ ] Environment variables and secrets migrated
- [ ] Probes configured (liveness + readiness minimum)
- [ ] Resource requests and limits defined
- [ ] Network exposure (Service + Ingress/IngressRoute)
- [ ] Volumes and data migrated if stateful
- [ ] Monitoring working (metrics, logs)
- [ ] Rollback test (`kubectl rollout undo`)
- [ ] DNS updated or traffic switched over

## Swarm / Kubernetes coexistence

During the migration, both platforms coexist. A few patterns to manage the transition:

### Split DNS

Use DNS to direct traffic progressively:

```
api.example.com → Swarm (weight 100)
# Migration in progress...
api.example.com → Swarm (weight 50) + Kubernetes (weight 50)
# Validation...
api.example.com → Kubernetes (weight 100)
# Swarm decommissioning
```

### Cross-platform communication

If services on Swarm need to talk to services already migrated to Kubernetes:

```yaml
# ExternalName Service in Kubernetes
apiVersion: v1
kind: Service
metadata:
  name: legacy-service
  namespace: mon-app
spec:
  type: ExternalName
  externalName: legacy.swarm.internal
```

And conversely, expose the Kubernetes services via a NodePort or LoadBalancer accessible from the Swarm network.

## Best practices

1. **Migrate in pairs**: someone who knows the Swarm app + someone who knows Kubernetes
2. **GitOps from the first service**: set up ArgoCD before you start migrating. Each migrated service lands directly in GitOps
3. **Monitoring first**: install Prometheus + Grafana before migrating workloads. You want to see problems, not guess them
4. **Staging environment**: migrate to staging first, validate, then reproduce in prod
5. **Automate rollbacks**: test `kubectl rollout undo` on each service. In case of trouble, going back to Swarm must be possible as long as DNS hasn't switched
6. **Document the differences**: each migrated service should have a note on what changed (internal URLs, env variables, volumes)
7. **Don't migrate databases first**: it's tempting to "do it all at once," but stateful services are the riskiest. Keep them for the end
8. **Use the migration to clean up**: it's the opportunity to remove unused services, standardize naming conventions, and set up best practices (probes, limits, network policies)

## Conclusion

Migrating from Docker Swarm to Kubernetes is a project in itself. Not a file format change. The concepts are close but the details diverge enough that each service needs individual attention.

The key is to be gradual: infra first, stateless next, stateful last. With GitOps and monitoring in place from the start, every step is observable and reversible. And once the migration is complete, you gain access to the entire Kubernetes ecosystem ([Helm](/en/articles/transfersh-helm-chart/), [ArgoCD](/en/articles/argocd-introduction/), [Traefik IngressRoute](/en/articles/traefik-v3-deep-dive/), [Prometheus monitoring](/en/articles/kubernetes-monitoring-prometheus-grafana/), [Kyverno policies](/en/articles/container-security-trivy-kyverno/)) that has no equivalent on the Swarm side.
