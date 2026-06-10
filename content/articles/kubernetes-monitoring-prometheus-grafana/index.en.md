---
title: "Kubernetes Monitoring: Prometheus + Grafana stack"
date: 2026-03-29
draft: false
summary: "Setting up a complete monitoring stack on Kubernetes with kube-prometheus-stack: installation, Grafana dashboards, alerting rules, Alertmanager and production best practices."
tags: ["Kubernetes", "Prometheus", "Grafana", "Monitoring", "DevOps"]
---

A Kubernetes cluster without monitoring is flying blind. You don't know when a pod gets OOMKilled, when a node saturates, or when your API's latency explodes. The **Prometheus + Grafana** stack is the de facto standard for Kubernetes monitoring, and with **kube-prometheus-stack**, everything installs in a single Helm chart.

## Why kube-prometheus-stack

There are several ways to install Prometheus on Kubernetes. The most complete and best maintained is the **kube-prometheus-stack** Helm chart (formerly prometheus-operator). It bundles:

- **Prometheus Operator**: manages Prometheus instances via CRDs
- **Prometheus**: collects and stores metrics (TSDB)
- **Grafana**: dashboards and visualization
- **Alertmanager**: alert routing and notification
- **kube-state-metrics**: metrics on the state of Kubernetes objects (pods, deployments, nodes…)
- **node-exporter**: node system metrics (CPU, RAM, disk, network)
- **Preconfigured alert rules**: more than 100 ready-to-use alerts

The alternative would be installing each component separately. It's doable, but it's extra maintenance work for no real benefit.

## Installation

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
```

### Production values

The chart has hundreds of parameters. Here are the essentials for a production environment:

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
          storageClassName: csi-cinder-high-speed  # adapt to the provider
          accessModes: ["ReadWriteOnce"]
          resources:
            requests:
              storage: 50Gi
    # Scrape every 30s instead of the default 1m
    scrapeInterval: 30s
    # Select ServiceMonitors from all namespaces
    serviceMonitorSelectorNilUsesHelmValues: false
    podMonitorSelectorNilUsesHelmValues: false
    ruleSelectorNilUsesHelmValues: false

# --- Grafana ---
grafana:
  adminPassword: ""  # managed by an external Secret
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

### Verifying the installation

```bash
# All pods should be Running
kubectl get pods -n monitoring

# The Operator's CRDs
kubectl get crd | grep monitoring.coreos.com
```

You should see these CRDs:

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

## The Prometheus Operator CRDs

The Operator introduces CRDs that let you configure monitoring declaratively, directly in Kubernetes.

### ServiceMonitor

It's the most-used object. It tells Prometheus which Services to scrape and how.

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: mon-app
  namespace: production
  labels:
    release: kube-prometheus-stack  # so Prometheus discovers it
spec:
  selector:
    matchLabels:
      app: mon-app
  endpoints:
    - port: metrics
      interval: 30s
      path: /metrics
```

Prometheus automatically discovers ServiceMonitors through the label selector. With `serviceMonitorSelectorNilUsesHelmValues: false` in the values, it picks them all up, without restriction.

### PodMonitor

For pods that don't have an associated Service (jobs, CronJobs…):

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

Alerting and recording rules are also declared as a CRD:

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
            summary: "mon-app P99 latency > 1s"
            description: "P99 latency has been at {{ $value }}s for 5 minutes."
```

The Operator automatically injects these rules into the Prometheus configuration. No need to touch the config files.

## Alertmanager: routing and notifications

Collecting metrics is good, being notified when things break is better. Alertmanager handles routing alerts to the right channels.

### Configuration

The Alertmanager config is done via a Kubernetes Secret or directly in the Helm values:

```yaml
# In values-monitoring.yaml
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

Important points:

- **group_by**: groups similar alerts to avoid spam
- **inhibit_rules**: a critical alert suppresses the associated warnings
- **send_resolved**: notifies when the alert is resolved (not just when it fires)
- **repeat_interval**: 4h for warnings, 1h for criticals

### Silencing an alert

During a planned maintenance:

```bash
# Via the Alertmanager API
kubectl port-forward -n monitoring svc/kube-prometheus-stack-alertmanager 9093:9093

# Create a 2h silence on a namespace
amtool silence add \
  --alertmanager.url=http://localhost:9093 \
  --comment="Planned maintenance" \
  --duration=2h \
  namespace="maintenance-ns"
```

## The alerts that really matter

kube-prometheus-stack comes with more than 100 preconfigured alert rules. It's a good starting point, but some are too sensitive (false positives) and others are missing. Here are the ones to watch in priority.

### Infrastructure

| Alert | What it detects |
|---|---|
| `KubeNodeNotReady` | Node in NotReady state for 15min |
| `KubeNodeUnreachable` | Unreachable node |
| `NodeFilesystemSpaceFillingUp` | Disk filling up (linear prediction) |
| `NodeMemoryHighUtilization` | Node RAM > 90% |
| `KubeletTooManyPods` | Node close to the pod limit |

### Workloads

| Alert | What it detects |
|---|---|
| `KubePodCrashLooping` | Pod in restart loop (> 0 restarts over 15min) |
| `KubePodNotReady` | Pod not Ready for 15min |
| `KubeDeploymentReplicasMismatch` | Desired replicas ≠ available replicas |
| `KubeStatefulSetReplicasMismatch` | Same for StatefulSets |
| `KubeJobFailed` | Failed Kubernetes Job |
| `KubeContainerOOMKilled` | Container killed by the OOM killer |

### Prometheus itself

| Alert | What it detects |
|---|---|
| `PrometheusTSDBCompactionsFailing` | TSDB compaction failing |
| `PrometheusRuleFailures` | Evaluation rules erroring |
| `AlertmanagerFailedNotifications` | Alertmanager can't send |

### Custom rule to add: OOMKilled

The default rule doesn't always detect OOMKills cleanly. Here's a more reliable one:

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
            summary: "Container {{ $labels.container }} OOMKilled in {{ $labels.namespace }}/{{ $labels.pod }}"
            description: "The container was killed by the OOM killer. Check the memory limits."
```

## Grafana dashboards

kube-prometheus-stack installs around twenty dashboards by default. The most useful day to day:

### Built-in dashboards

| Dashboard | Usage |
|---|---|
| **Kubernetes / Compute Resources / Cluster** | Global CPU/RAM view of the whole cluster |
| **Kubernetes / Compute Resources / Namespace (Pods)** | Consumption per namespace, drill-down per pod |
| **Kubernetes / Compute Resources / Pod** | Detail of a pod: CPU, RAM, network, filesystem |
| **Kubernetes / Networking / Cluster** | Network bandwidth between pods/namespaces |
| **Node Exporter / Nodes** | Node system metrics |
| **Alertmanager / Overview** | State of alerts and silences |

### Custom dashboard: SRE view

For a daily operational dashboard, create a ConfigMap that Grafana loads automatically via the sidecar:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-dashboard-sre
  namespace: monitoring
  labels:
    grafana_dashboard: "1"  # the Grafana sidecar detects this label
data:
  sre-overview.json: |
    {
      "title": "SRE Overview",
      "panels": [...]
    }
```

The `grafana_dashboard: "1"` label is the sidecar convention. Any ConfigMap with this label is automatically mounted as a dashboard in Grafana.

In practice, build the dashboard in the Grafana UI, export the JSON, then store it in a ConfigMap versioned in Git. That's the GitOps loop of monitoring.

### Essential PromQL panels

A few queries to know for building custom dashboards:

```promql
# CPU used vs requested per namespace
sum(rate(container_cpu_usage_seconds_total{namespace="production"}[5m]))
/
sum(kube_pod_container_resource_requests{namespace="production", resource="cpu"})

# Actual memory vs limits per pod
container_memory_working_set_bytes{namespace="production"}
/
kube_pod_container_resource_limits{namespace="production", resource="memory"}

# Restart rate per deployment
sum(increase(kube_pod_container_status_restarts_total{namespace="production"}[1h])) by (pod)

# Pods waiting to be scheduled
kube_pod_status_phase{phase="Pending"} > 0

# PVC usage (if metrics-server or kubelet metrics enabled)
kubelet_volume_stats_used_bytes / kubelet_volume_stats_capacity_bytes
```

## Recording Rules: PromQL performance

Recording rules precompute complex queries to speed up dashboards and alerts. kube-prometheus-stack includes many by default, but for custom metrics:

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

Naming convention: `level:metric:operations`. This avoids recomputing a `histogram_quantile` over thousands of series on every dashboard refresh.

## Retention and storage

Prometheus stores its metrics in a local TSDB. In production, you need to size it correctly.

### Estimating disk space

Approximate formula:

```
space = active_series × size_per_sample × samples_per_day × retention_days
```

In practice, for a medium-sized cluster (50 pods, ~50,000 active series):
- **15 days of retention** → ~20-30 GB
- **30 days of retention** → ~40-60 GB

The two parameters to configure:

```yaml
prometheus:
  prometheusSpec:
    retention: 15d        # max duration
    retentionSize: "40GB" # max size (whichever is reached first wins)
```

### Long-term retention

To keep metrics beyond 15-30 days, Prometheus alone isn't enough. The options:

- **Thanos**: a sidecar that pushes blocks to object storage (S3, MinIO), with deduplication and compaction
- **VictoriaMetrics**: a drop-in replacement for Prometheus with better compression and native long retention
- **Cortex / Mimir**: distributed storage for multi-tenant setups

For most clusters, 15-30 days locally is enough. Recording rules aggregate the important data, and long-term dashboards rely on these precomputed metrics.

## Exposing Grafana

In production, Grafana is exposed via an IngressRoute or a Gateway API. Example with a Traefik IngressRoute:

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

## Best practices

1. **Always use persistent storage** on Prometheus — without a PVC, a restart = losing all metrics
2. **`serviceMonitorSelectorNilUsesHelmValues: false`**: otherwise Prometheus only scrapes ServiceMonitors with the chart's label
3. **Size the memory**: Prometheus consumes ~2 bytes per active series in RAM. 100k series = ~200 MB minimum, plan generously
4. **Don't scrape too frequently**: 30s is a good compromise. 10s on a large cluster is a quick way to saturate Prometheus
5. **Use recording rules** for complex dashboard queries — a `histogram_quantile` over 100k series every 5s hurts
6. **Label alerts** with `namespace`, `severity`, and `team` for Alertmanager routing
7. **Test alerts**: an alert that has never fired — nobody knows if it works. Use `promtool`:

```bash
# Check the rules' syntax
promtool check rules rules.yaml

# Test a PromQL expression
promtool query instant http://localhost:9090 'up == 0'
```

8. **Separate infra and application alerts**: infra alerts in the `monitoring` namespace, application alerts in the app's namespace

## Conclusion

The Prometheus + Grafana stack via kube-prometheus-stack is the minimum foundation of any production Kubernetes cluster. The installation is simple, the default dashboards already cover 80% of the needs, and the Operator's CRDs let you add application monitoring declaratively.

The real work starts after the installation: fine-tuning alerts to reduce noise, creating dashboards tailored to your teams, and sizing the retention. But with the basics laid out in this article, you have what you need to monitor a production cluster properly.
