---
title: "Traefik v3 Deep Dive: beyond basic Ingress"
date: 2026-03-29
draft: false
summary: "Traefik v3 isn't just an IngressController. Middlewares, IngressRoute CRD, TCP/UDP routing, plugins, dashboard and observability: everything that makes Traefik a complete reverse proxy on Kubernetes."
tags: ["Traefik", "Kubernetes", "Networking", "DevOps", "Ingress"]
---

If you use Traefik only to expose basic HTTP Ingresses, you're missing 80% of what the tool can do. With v3, Traefik clarified its API, dropped the experimental providers to make them GA, and introduced the Gateway API natively. But the real differentiator is the complete ecosystem it offers: chainable middlewares, TCP/UDP routing, community plugins, and native observability.

## Why v3 is a game changer

V3 isn't a complete rewrite, but it brings important changes:

- **Gateway API GA**: no more experimental feature gates (see [my article on the Gateway API](/en/articles/kubernetes-gateway-api/))
- **Removal of the v1alpha API**: IngressRoutes move to `traefik.io/v1alpha1` instead of the old `traefik.containo.us/v1alpha1`
- **HTTP/3 natively enabled**: QUIC on the HTTPS entrypoints
- **Native Prometheus metrics**: labels per router, service and entrypoint without external config
- **Wasm plugins**: WebAssembly extensions, without recompiling Traefik

## Helm installation: beyond the defaults

The official Helm chart works in three lines, but the default values are minimal. Here's a production baseline:

```yaml
# values-production.yaml
image:
  tag: v3.3

entryPoints:
  web:
    address: ":80"
    http:
      redirections:
        entryPoint:
          to: websecure
          scheme: https
  websecure:
    address: ":443"
    http3:
      enabled: true
    forwardedHeaders:
      trustedIPs:
        - "10.0.0.0/8"

providers:
  kubernetesCRD:
    enabled: true
    allowCrossNamespace: true
  kubernetesIngress:
    enabled: true
  kubernetesGateway:
    enabled: true

ingressRoute:
  dashboard:
    enabled: true
    matchRule: Host(`traefik.internal.example.com`)
    entryPoints:
      - websecure

metrics:
  prometheus:
    entryPoint: metrics
    addEntryPointsLabels: true
    addRoutersLabels: true
    addServicesLabels: true

logs:
  general:
    level: INFO
  access:
    enabled: true
    format: json

resources:
  requests:
    cpu: 100m
    memory: 128Mi
  limits:
    cpu: 500m
    memory: 256Mi

autoscaling:
  enabled: true
  minReplicas: 2
  maxReplicas: 5
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 70
```

```bash
helm repo add traefik https://traefik.github.io/charts
helm install traefik traefik/traefik \
  --namespace traefik \
  --create-namespace \
  -f values-production.yaml
```

## IngressRoute CRD: Traefik's real power

The standard Kubernetes Ingress is limited. Traefik's IngressRoute CRDs offer far more expressive native routing, without going through annotations.

### Classic HTTP routing

```yaml
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: mon-app
  namespace: production
spec:
  entryPoints:
    - websecure
  routes:
    - match: Host(`mon-app.example.com`)
      kind: Rule
      services:
        - name: mon-app-svc
          port: 8080
  tls:
    secretName: mon-app-tls
```

### Advanced routing: combining criteria

Traefik's matching syntax lets you combine host, path, headers, query params:

```yaml
routes:
  - match: >-
      Host(`api.example.com`) &&
      PathPrefix(`/v2`) &&
      Headers(`X-Api-Version`, `2`)
    kind: Rule
    services:
      - name: api-v2
        port: 8080
  - match: Host(`api.example.com`) && PathPrefix(`/v1`)
    kind: Rule
    services:
      - name: api-v1
        port: 8080
    priority: 10
```

It's a real expression language, not a list of annotations to guess.

## Middlewares: the processing chain

Middlewares are the heart of Traefik. They apply in order to each request. V3 offers around twenty natively.

### Defining a middleware

```yaml
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: security-headers
  namespace: traefik
spec:
  headers:
    stsSeconds: 63072000
    stsIncludeSubdomains: true
    stsPreload: true
    contentTypeNosniff: true
    browserXssFilter: true
    referrerPolicy: "strict-origin-when-cross-origin"
    frameDeny: true
    customResponseHeaders:
      X-Powered-By: ""
      Server: ""
```

### Rate limiting

```yaml
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: rate-limit
  namespace: traefik
spec:
  rateLimit:
    average: 100
    burst: 200
    period: 1m
    sourceCriterion:
      ipStrategy:
        depth: 1
```

### Basic Auth

```yaml
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: basic-auth
  namespace: traefik
spec:
  basicAuth:
    secret: auth-secret
    removeHeader: true
```

The secret contains an htpasswd file:

```bash
htpasswd -nb admin mon-mot-de-passe | base64
# Create the secret with the encoded value
kubectl create secret generic auth-secret \
  --from-literal=users='admin:$apr1$...'  \
  -n traefik
```

### Chaining middlewares

```yaml
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: app-securisee
  namespace: production
spec:
  entryPoints:
    - websecure
  routes:
    - match: Host(`app.example.com`)
      kind: Rule
      middlewares:
        - name: rate-limit
          namespace: traefik
        - name: security-headers
          namespace: traefik
        - name: basic-auth
          namespace: traefik
      services:
        - name: app-svc
          port: 8080
  tls:
    secretName: app-tls
```

The order in the `middlewares` list is the execution order. Rate limit first, headers next, auth last — that's intentional: no point authenticating if the request is already rejected by the rate limit.

## TCP/UDP Routing

Traefik isn't limited to HTTP. IngressRouteTCP and IngressRouteUDP let you expose non-HTTP services.

### Exposing PostgreSQL over TCP

```yaml
apiVersion: traefik.io/v1alpha1
kind: IngressRouteTCP
metadata:
  name: postgres
  namespace: database
spec:
  entryPoints:
    - postgres  # custom entrypoint on port 5432
  routes:
    - match: HostSNI(`db.example.com`)
      services:
        - name: postgres-svc
          port: 5432
  tls:
    passthrough: true
```

You need to declare the corresponding entrypoint in the Helm values:

```yaml
ports:
  postgres:
    port: 5432
    expose:
      default: true
    protocol: TCP
```

### UDP service (DNS, games…)

```yaml
apiVersion: traefik.io/v1alpha1
kind: IngressRouteUDP
metadata:
  name: dns-forward
  namespace: dns
spec:
  entryPoints:
    - dns
  routes:
    - services:
        - name: coredns-external
          port: 53
```

## Plugins: extending Traefik without recompiling it

The Traefik plugin ecosystem is available in the Traefik Plugin Catalog. V3 supports Wasm plugins in addition to the classic Go ones.

### Example: GeoBlock

Block traffic by country directly at the reverse proxy level:

```yaml
# In the Helm values
experimental:
  plugins:
    geoblock:
      moduleName: github.com/nscuro/traefik-plugin-geoblock
      version: v0.14.0
```

```yaml
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: geoblock
spec:
  plugin:
    geoblock:
      allowLocalRequests: true
      logAllowedRequests: false
      logApiRequests: false
      api: "https://get.geojs.io/v1/ip/country/{ip}"
      allowedCountries:
        - FR
        - DE
        - BE
        - CH
```

Plugins are loaded when Traefik starts. No sidecar, no image rebuild.

## Dashboard and API

Traefik ships a web dashboard that gives a complete view of the routers, services, middlewares and entrypoints.

### Securing access

Never expose the dashboard without authentication. Recommended combination:

```yaml
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: traefik-dashboard
  namespace: traefik
spec:
  entryPoints:
    - websecure
  routes:
    - match: Host(`traefik.internal.example.com`)
      kind: Rule
      middlewares:
        - name: basic-auth
        - name: ip-whitelist
      services:
        - name: api@internal
          kind: TraefikService
  tls:
    secretName: traefik-dashboard-tls
```

The IP whitelist middleware to restrict to your network:

```yaml
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: ip-whitelist
  namespace: traefik
spec:
  ipAllowList:
    sourceRange:
      - "10.0.0.0/8"
      - "192.168.1.0/24"
```

### Programmatic API

Traefik's REST API is accessible internally for debugging:

```bash
# List HTTP routers
kubectl port-forward -n traefik svc/traefik 9000:9000
curl http://localhost:9000/api/http/routers | jq '.[].name'

# Check health
curl http://localhost:9000/ping
```

## Observability

### Prometheus metrics

With the Helm config above, Traefik exposes metrics on `/metrics`. The most useful:

| Metric | Description |
|---|---|
| `traefik_entrypoint_requests_total` | Total number of requests per entrypoint |
| `traefik_router_requests_total` | Requests per router (with HTTP code) |
| `traefik_service_request_duration_seconds` | Latency per backend service |
| `traefik_entrypoint_open_connections` | Active connections |
| `traefik_tls_certs_not_after` | TLS certificate expiration |

Example Prometheus alert rule:

```yaml
groups:
  - name: traefik
    rules:
      - alert: TraefikHighErrorRate
        expr: >
          sum(rate(traefik_router_requests_total{code=~"5.."}[5m]))
          /
          sum(rate(traefik_router_requests_total[5m]))
          > 0.05
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "5xx error rate above 5%"

      - alert: TraefikCertExpiringSoon
        expr: >
          (traefik_tls_certs_not_after - time()) / 86400 < 14
        for: 1h
        labels:
          severity: warning
        annotations:
          summary: "TLS certificate expires in less than 14 days"
```

### Structured access logs

JSON access logs can be directly ingested by Loki, Elasticsearch or Datadog:

```json
{
  "ClientAddr": "10.42.0.15:52340",
  "Duration": 2450000,
  "OriginStatus": 200,
  "RequestHost": "app.example.com",
  "RequestMethod": "GET",
  "RequestPath": "/api/health",
  "RouterName": "mon-app-production@kubernetescrd",
  "ServiceName": "mon-app-svc-production@kubernetescrd",
  "entryPointName": "websecure",
  "TLSVersion": "1.3"
}
```

### Grafana dashboards

With the `addRoutersLabels` and `addServicesLabels` labels enabled, you can build precise Grafana dashboards. A few essential panels:

- **Requests per second per router**: `sum(rate(traefik_router_requests_total[5m])) by (router)`
- **P99 latency per service**: `histogram_quantile(0.99, sum(rate(traefik_service_request_duration_seconds_bucket[5m])) by (le, service))`
- **HTTP code distribution**: `sum(rate(traefik_router_requests_total[5m])) by (code)` as a stacked bar
- **Open connections**: `traefik_entrypoint_open_connections` to detect hanging connections

The community Grafana dashboard ID **17346** is a good starting point — it covers the entrypoint, router and service metrics. Adapt it afterward to your needs.

## Cert-Manager and Traefik: automated TLS

Traefik can manage its own certificates via ACME, but in production Kubernetes we prefer to delegate that to Cert-Manager:

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: wildcard-example
  namespace: traefik
spec:
  secretName: wildcard-example-tls
  issuerRef:
    name: letsencrypt-prod
    kind: ClusterIssuer
  dnsNames:
    - "*.example.com"
    - "example.com"
```

Traefik automatically reads the TLS secrets referenced in the IngressRoutes. No extra config on the Traefik side.

## Best practices in production

A few rules drawn from experience:

1. **Always at least 2 replicas**: a reverse proxy that goes down cuts off the entire cluster
2. **PodDisruptionBudget**: `minAvailable: 1` minimum
3. **Anti-affinity**: don't put both replicas on the same node
4. **HTTP → HTTPS redirect** at the entrypoint level, not in each IngressRoute
5. **JSON access logs**: indispensable for debugging and monitoring
6. **Global rate limit** before auth, saves resources
7. **Separate internal and external entrypoints** if you have intra-cluster traffic
8. **Monitor certificates**: the alert on `traefik_tls_certs_not_after` can save a weekend

```yaml
# PodDisruptionBudget
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: traefik
  namespace: traefik
spec:
  minAvailable: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: traefik
```

```yaml
# Anti-affinity in the Helm values
affinity:
  podAntiAffinity:
    preferredDuringSchedulingIgnoredDuringExecution:
      - weight: 100
        podAffinityTerm:
          labelSelector:
            matchLabels:
              app.kubernetes.io/name: traefik
          topologyKey: kubernetes.io/hostname
```

## Conclusion

Traefik v3 is much more than an Ingress Controller. It's a complete reverse proxy with expressive routing, chainable middlewares, TCP/UDP, plugins, and native observability. If you already use it in basic mode, take the time to explore the IngressRoute CRDs and the middlewares — that's where the real added value lies.

And if you manage several teams on the same cluster, combine that with the [Gateway API](/en/articles/kubernetes-gateway-api/) for the separation of responsibilities. The two approaches coexist perfectly in Traefik v3.
