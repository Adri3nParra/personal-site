---
title: "Kubernetes Monitoring : Stack Prometheus + Grafana"
date: 2026-03-29
draft: false
summary: "Mettre en place une stack de monitoring complète sur Kubernetes avec kube-prometheus-stack : installation, dashboards Grafana, règles d'alerte, Alertmanager et bonnes pratiques de production."
tags: ["Kubernetes", "Prometheus", "Grafana", "Monitoring", "DevOps"]
---

Un cluster Kubernetes sans monitoring, c'est piloter à l'aveugle. Tu ne sais pas quand un pod OOMKill, quand un nœud sature, ou quand la latence de ton API explose. La stack **Prometheus + Grafana** est le standard de facto pour le monitoring Kubernetes — et avec **kube-prometheus-stack**, tout s'installe en un seul chart Helm.

## Pourquoi kube-prometheus-stack

Il existe plusieurs façons d'installer Prometheus sur Kubernetes. La plus complète et la plus maintenue, c'est le chart Helm **kube-prometheus-stack** (anciennement prometheus-operator). Il embarque :

- **Prometheus Operator** — gère les instances Prometheus via des CRDs
- **Prometheus** — collecte et stocke les métriques (TSDB)
- **Grafana** — dashboards et visualisation
- **Alertmanager** — routage et notification des alertes
- **kube-state-metrics** — métriques sur l'état des objets Kubernetes (pods, deployments, nodes…)
- **node-exporter** — métriques système des nœuds (CPU, RAM, disque, réseau)
- **Règles d'alerte préconfigurées** — plus de 100 alertes prêtes à l'emploi

L'alternative serait d'installer chaque composant séparément. C'est faisable, mais c'est du travail de maintenance en plus pour aucun bénéfice réel.

## Installation

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
```

### Values de production

Le chart a des centaines de paramètres. Voici les essentiels pour un environnement de production :

```yaml
# values-monitoring.yaml

# --- Prometheus ---
prometheus:
  prometheusSpec:
    retention: 15d
    retentionSize: "40GB"
    resources:
      requests:
        cpu: 500m
        memory: 2Gi
      limits:
        cpu: "2"
        memory: 4Gi
    storageSpec:
      volumeClaimTemplate:
        spec:
          storageClassName: csi-cinder-high-speed  # adapter selon le provider
          accessModes: ["ReadWriteOnce"]
          resources:
            requests:
              storage: 50Gi
    # Scrape toutes les 30s au lieu de 1m par défaut
    scrapeInterval: 30s
    # Sélectionner les ServiceMonitor de tous les namespaces
    serviceMonitorSelectorNilUsesHelmValues: false
    podMonitorSelectorNilUsesHelmValues: false
    ruleSelectorNilUsesHelmValues: false

# --- Grafana ---
grafana:
  adminPassword: ""  # géré par un Secret externe
  persistence:
    enabled: true
    size: 5Gi
  dashboardProviders:
    dashboardproviders.yaml:
      apiVersion: 1
      providers:
        - name: custom
          orgId: 1
          folder: "Custom"
          type: file
          disableDeletion: false
          editable: true
          options:
            path: /var/lib/grafana/dashboards/custom
  sidecar:
    dashboards:
      enabled: true
      searchNamespace: ALL
    datasources:
      enabled: true

# --- Alertmanager ---
alertmanager:
  alertmanagerSpec:
    resources:
      requests:
        cpu: 50m
        memory: 64Mi
      limits:
        cpu: 200m
        memory: 128Mi

# --- kube-state-metrics ---
kube-state-metrics:
  resources:
    requests:
      cpu: 50m
      memory: 64Mi
    limits:
      cpu: 200m
      memory: 128Mi

# --- node-exporter ---
nodeExporter:
  resources:
    requests:
      cpu: 50m
      memory: 32Mi
    limits:
      cpu: 200m
      memory: 64Mi
```

```bash
helm install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --create-namespace \
  -f values-monitoring.yaml
```

### Vérifier l'installation

```bash
# Tous les pods doivent être Running
kubectl get pods -n monitoring

# Les CRDs de l'Operator
kubectl get crd | grep monitoring.coreos.com
```

Tu devrais voir ces CRDs :

```
alertmanagerconfigs.monitoring.coreos.com
alertmanagers.monitoring.coreos.com
podmonitors.monitoring.coreos.com
probes.monitoring.coreos.com
prometheuses.monitoring.coreos.com
prometheusrules.monitoring.coreos.com
servicemonitors.monitoring.coreos.com
thanosrulers.monitoring.coreos.com
```

## Les CRDs de Prometheus Operator

L'Operator introduit des CRDs qui permettent de configurer le monitoring de manière déclarative, directement dans Kubernetes.

### ServiceMonitor

C'est l'objet le plus utilisé. Il indique à Prometheus quels Services scraper et comment.

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: mon-app
  namespace: production
  labels:
    release: kube-prometheus-stack  # pour que Prometheus le découvre
spec:
  selector:
    matchLabels:
      app: mon-app
  endpoints:
    - port: metrics
      interval: 30s
      path: /metrics
```

Prometheus découvre automatiquement les ServiceMonitors grâce au label selector. Avec `serviceMonitorSelectorNilUsesHelmValues: false` dans les values, il les prend tous, sans restriction.

### PodMonitor

Pour les pods qui n'ont pas de Service associé (jobs, CronJobs…) :

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PodMonitor
metadata:
  name: batch-jobs
  namespace: production
spec:
  selector:
    matchLabels:
      app: batch-processor
  podMetricsEndpoints:
    - port: metrics
      interval: 60s
```

### PrometheusRule

Les règles d'alerte et de recording se déclarent aussi en CRD :

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: app-alerts
  namespace: production
  labels:
    release: kube-prometheus-stack
spec:
  groups:
    - name: mon-app.rules
      rules:
        - alert: AppHighLatency
          expr: >
            histogram_quantile(0.99,
              sum(rate(http_request_duration_seconds_bucket{app="mon-app"}[5m]))
              by (le)
            ) > 1
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: "Latence P99 de mon-app > 1s"
            description: "La latence P99 est à {{ $value }}s depuis 5 minutes."
```

L'Operator injecte automatiquement ces règles dans la configuration Prometheus. Pas besoin de toucher aux fichiers de config.

## Alertmanager : routage et notifications

Collecter des métriques c'est bien, être prévenu quand ça casse c'est mieux. Alertmanager gère le routage des alertes vers les bons canaux.

### Configuration

La config Alertmanager se fait via un Secret Kubernetes ou directement dans les values Helm :

```yaml
# Dans values-monitoring.yaml
alertmanager:
  config:
    global:
      resolve_timeout: 5m

    route:
      receiver: default
      group_by: ["alertname", "namespace"]
      group_wait: 30s
      group_interval: 5m
      repeat_interval: 4h
      routes:
        - receiver: critical-slack
          match:
            severity: critical
          repeat_interval: 1h
        - receiver: webhook-teams
          match:
            severity: warning

    receivers:
      - name: default
        slack_configs:
          - api_url: "https://hooks.slack.com/services/XXX/YYY/ZZZ"
            channel: "#monitoring"
            title: '{{ template "slack.default.title" . }}'
            text: '{{ template "slack.default.text" . }}'
            send_resolved: true

      - name: critical-slack
        slack_configs:
          - api_url: "https://hooks.slack.com/services/XXX/YYY/ZZZ"
            channel: "#incidents"
            title: '{{ .GroupLabels.alertname }}'
            text: >
              *Namespace:* {{ .CommonLabels.namespace }}
              *Description:* {{ .CommonAnnotations.description }}
            send_resolved: true

      - name: webhook-teams
        webhook_configs:
          - url: "http://prometheus-msteams:2000/alertmanager"
            send_resolved: true

    inhibit_rules:
      - source_match:
          severity: critical
        target_match:
          severity: warning
        equal: ["alertname", "namespace"]
```

Points importants :

- **group_by** — regroupe les alertes similaires pour éviter le spam
- **inhibit_rules** — une alerte critical supprime les warnings associés
- **send_resolved** — notifie quand l'alerte est résolue (pas juste quand elle se déclenche)
- **repeat_interval** — 4h pour les warnings, 1h pour les criticals

### Silencer une alerte

Pendant une maintenance planifiée :

```bash
# Via l'API Alertmanager
kubectl port-forward -n monitoring svc/kube-prometheus-stack-alertmanager 9093:9093

# Créer un silence de 2h sur un namespace
amtool silence add \
  --alertmanager.url=http://localhost:9093 \
  --comment="Maintenance planifiée" \
  --duration=2h \
  namespace="maintenance-ns"
```

## Les alertes qui comptent vraiment

kube-prometheus-stack arrive avec plus de 100 règles d'alerte préconfigurées. C'est un bon point de départ, mais certaines sont trop sensibles (faux positifs) et d'autres manquent. Voici celles qu'il faut surveiller en priorité.

### Infrastructure

| Alerte | Ce qu'elle détecte |
|---|---|
| `KubeNodeNotReady` | Nœud en état NotReady depuis 15min |
| `KubeNodeUnreachable` | Nœud injoignable |
| `NodeFilesystemSpaceFillingUp` | Disque qui se remplit (prédiction linéaire) |
| `NodeMemoryHighUtilization` | RAM nœud > 90% |
| `KubeletTooManyPods` | Nœud proche de la limite de pods |

### Workloads

| Alerte | Ce qu'elle détecte |
|---|---|
| `KubePodCrashLooping` | Pod en restart loop (> 0 restarts sur 15min) |
| `KubePodNotReady` | Pod non Ready depuis 15min |
| `KubeDeploymentReplicasMismatch` | Replicas souhaités ≠ replicas disponibles |
| `KubeStatefulSetReplicasMismatch` | Idem pour les StatefulSets |
| `KubeJobFailed` | Job Kubernetes en échec |
| `KubeContainerOOMKilled` | Container tué par l'OOM killer |

### Prometheus lui-même

| Alerte | Ce qu'elle détecte |
|---|---|
| `PrometheusTSDBCompactionsFailing` | Compaction de la TSDB en échec |
| `PrometheusRuleFailures` | Règles d'évaluation en erreur |
| `AlertmanagerFailedNotifications` | Alertmanager n'arrive pas à envoyer |

### Règle custom à ajouter : OOMKilled

La règle par défaut ne détecte pas toujours proprement les OOMKill. En voici une plus fiable :

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: oomkill-alerts
  namespace: monitoring
  labels:
    release: kube-prometheus-stack
spec:
  groups:
    - name: oomkill
      rules:
        - alert: ContainerOOMKilled
          expr: >
            kube_pod_container_status_last_terminated_reason{reason="OOMKilled"} > 0
          for: 0m
          labels:
            severity: warning
          annotations:
            summary: "Container {{ $labels.container }} OOMKilled dans {{ $labels.namespace }}/{{ $labels.pod }}"
            description: "Le container a été tué par l'OOM killer. Vérifier les limites mémoire."
```

## Dashboards Grafana

kube-prometheus-stack installe une vingtaine de dashboards par défaut. Les plus utiles au quotidien :

### Dashboards intégrés

| Dashboard | Usage |
|---|---|
| **Kubernetes / Compute Resources / Cluster** | Vue globale CPU/RAM de tout le cluster |
| **Kubernetes / Compute Resources / Namespace (Pods)** | Consommation par namespace, drill-down par pod |
| **Kubernetes / Compute Resources / Pod** | Détail d'un pod : CPU, RAM, réseau, filesystem |
| **Kubernetes / Networking / Cluster** | Bande passante réseau entre pods/namespaces |
| **Node Exporter / Nodes** | Métriques système des nœuds |
| **Alertmanager / Overview** | État des alertes et des silences |

### Dashboard custom : vue SRE

Pour un dashboard opérationnel quotidien, créer un ConfigMap que Grafana charge automatiquement via le sidecar :

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-dashboard-sre
  namespace: monitoring
  labels:
    grafana_dashboard: "1"  # le sidecar Grafana détecte ce label
data:
  sre-overview.json: |
    {
      "title": "SRE Overview",
      "panels": [...]
    }
```

Le label `grafana_dashboard: "1"` est la convention du sidecar. Tout ConfigMap avec ce label est automatiquement monté comme dashboard dans Grafana.

En pratique, construire le dashboard dans l'UI Grafana, exporter le JSON, puis le stocker dans un ConfigMap versionné en Git. C'est la boucle GitOps du monitoring.

### Panels PromQL essentiels

Quelques requêtes à connaître pour construire des dashboards custom :

```promql
# CPU utilisé vs demandé par namespace
sum(rate(container_cpu_usage_seconds_total{namespace="production"}[5m]))
/
sum(kube_pod_container_resource_requests{namespace="production", resource="cpu"})

# Mémoire réelle vs limites par pod
container_memory_working_set_bytes{namespace="production"}
/
kube_pod_container_resource_limits{namespace="production", resource="memory"}

# Taux de restart par deployment
sum(increase(kube_pod_container_status_restarts_total{namespace="production"}[1h])) by (pod)

# Pods en attente de scheduling
kube_pod_status_phase{phase="Pending"} > 0

# PVC usage (si metrics-server ou kubelet metrics activés)
kubelet_volume_stats_used_bytes / kubelet_volume_stats_capacity_bytes
```

## Recording Rules : performances PromQL

Les recording rules précalculent des requêtes complexes pour accélérer les dashboards et les alertes. kube-prometheus-stack en inclut beaucoup par défaut, mais pour des métriques custom :

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: recording-rules
  namespace: monitoring
  labels:
    release: kube-prometheus-stack
spec:
  groups:
    - name: app.recording
      interval: 30s
      rules:
        - record: namespace:http_requests:rate5m
          expr: >
            sum(rate(http_requests_total[5m])) by (namespace)

        - record: namespace:http_request_duration:p99
          expr: >
            histogram_quantile(0.99,
              sum(rate(http_request_duration_seconds_bucket[5m]))
              by (le, namespace)
            )
```

Convention de nommage : `level:metric:operations`. Ça évite de recalculer un `histogram_quantile` sur des milliers de séries à chaque refresh de dashboard.

## Rétention et stockage

Prometheus stocke ses métriques dans une TSDB locale. En production, il faut dimensionner correctement.

### Estimer l'espace disque

Formule approximative :

```
espace = séries_actives × taille_par_sample × samples_par_jour × jours_rétention
```

En pratique, pour un cluster de taille moyenne (50 pods, ~50 000 séries actives) :
- **15 jours de rétention** → ~20-30 Go
- **30 jours de rétention** → ~40-60 Go

Les deux paramètres à configurer :

```yaml
prometheus:
  prometheusSpec:
    retention: 15d        # durée max
    retentionSize: "40GB" # taille max (le premier atteint gagne)
```

### Rétention longue durée

Pour garder des métriques au-delà de 15-30 jours, Prometheus seul ne suffit pas. Les options :

- **Thanos** — sidecar qui pousse les blocs vers du stockage objet (S3, MinIO), avec déduplication et compaction
- **VictoriaMetrics** — remplacement drop-in de Prometheus avec meilleure compression et rétention native longue
- **Cortex / Mimir** — stockage distribué pour du multi-tenant

Pour la majorité des clusters, 15-30 jours en local suffisent. Les recording rules agrègent les données importantes, et les dashboards long terme s'appuient sur ces métriques précalculées.

## Exposer Grafana

En production, Grafana est exposé via un IngressRoute ou une Gateway API. Exemple avec un IngressRoute Traefik :

```yaml
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: grafana
  namespace: monitoring
spec:
  entryPoints:
    - websecure
  routes:
    - match: Host(`grafana.example.com`)
      kind: Rule
      middlewares:
        - name: security-headers
          namespace: traefik
      services:
        - name: kube-prometheus-stack-grafana
          port: 80
  tls:
    secretName: grafana-tls
```

## Bonnes pratiques

1. **Toujours mettre du stockage persistant** sur Prometheus — sans PVC, un restart = perte de toutes les métriques
2. **`serviceMonitorSelectorNilUsesHelmValues: false`** — sinon Prometheus ne scrape que les ServiceMonitors avec le label du chart
3. **Dimensionner la mémoire** — Prometheus consomme ~2 octets par série active en RAM. 100k séries = ~200 Mo minimum, prévoir large
4. **Ne pas scraper trop fréquemment** — 30s est un bon compromis. 10s sur un gros cluster, c'est un moyen rapide de saturer Prometheus
5. **Utiliser les recording rules** pour les requêtes de dashboard complexes — un `histogram_quantile` sur 100k séries toutes les 5s, ça fait mal
6. **Labelliser les alertes** avec `namespace`, `severity`, et `team` pour le routage Alertmanager
7. **Tester les alertes** — une alerte qui n'a jamais fired, personne ne sait si elle fonctionne. Utiliser `promtool` :

```bash
# Vérifier la syntaxe des règles
promtool check rules rules.yaml

# Tester une expression PromQL
promtool query instant http://localhost:9090 'up == 0'
```

8. **Séparer les alertes infra et applicatives** — les alertes infra dans le namespace `monitoring`, les alertes applicatives dans le namespace de l'app

## Conclusion

La stack Prometheus + Grafana via kube-prometheus-stack, c'est le socle minimum de tout cluster Kubernetes en production. L'installation est simple, les dashboards par défaut couvrent déjà 80 % des besoins, et les CRDs de l'Operator permettent d'ajouter du monitoring applicatif de manière déclarative.

Le vrai travail commence après l'installation : affiner les alertes pour réduire le bruit, créer des dashboards adaptés à tes équipes, et dimensionner la rétention. Mais avec les bases posées dans cet article, tu as de quoi monitorer un cluster de production correctement.
