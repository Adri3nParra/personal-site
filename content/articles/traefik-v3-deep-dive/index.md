---
title: "Traefik v3 Deep Dive : au-delà de l'Ingress basique"
date: 2026-03-29
draft: false
summary: "Traefik v3 ne se résume pas à un IngressController. Middlewares, IngressRoute CRD, TCP/UDP routing, plugins, dashboard et observabilité : tout ce qui fait de Traefik un reverse proxy complet sur Kubernetes."
tags: ["Traefik", "Kubernetes", "Réseau", "DevOps", "Ingress"]
---

Si tu utilises Traefik uniquement pour exposer des Ingress HTTP basiques, tu passes à côté de 80 % de ce que l'outil sait faire. Avec la v3, Traefik a clarifié son API, abandonné les providers expérimentaux pour les rendre GA, et introduit la Gateway API en natif. Mais le vrai différenciateur, c'est l'écosystème complet qu'il propose : middlewares chaînables, routage TCP/UDP, plugins communautaires, et une observabilité native.

## Pourquoi la v3 change la donne

La v3 n'est pas une réécriture complète, mais elle apporte des changements importants :

- **Gateway API en GA** — plus besoin de feature gates expérimentaux (cf. [mon article sur la Gateway API](/articles/kubernetes-gateway-api/))
- **Suppression de l'API v1alpha** — les IngressRoute passent en `traefik.io/v1alpha1` au lieu de l'ancien `traefik.containo.us/v1alpha1`
- **HTTP/3 activable nativement** — QUIC sur les entrypoints HTTPS
- **Métriques Prometheus natives** — labels par router, service et entrypoint sans config externe
- **Wasm plugins** — extensions en WebAssembly, sans recompiler Traefik

## Installation Helm : au-delà des valeurs par défaut

Le chart Helm officiel fonctionne en trois lignes, mais les valeurs par défaut sont minimales. Voici une base de production :

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

## IngressRoute CRD : la vraie puissance de Traefik

L'Ingress standard de Kubernetes est limité. Les IngressRoute CRD de Traefik offrent un routage natif bien plus expressif, sans passer par des annotations.

### Routage HTTP classique

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

### Routage avancé : combinaison de critères

La syntaxe de matching de Traefik permet de combiner host, path, headers, query params :

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

C'est un vrai langage d'expressions, pas une liste d'annotations à deviner.

## Middlewares : la chaîne de traitement

Les middlewares sont le cœur de Traefik. Ils s'appliquent dans l'ordre sur chaque requête. La v3 en propose une vingtaine en natif.

### Définition d'un middleware

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

Le secret contient un fichier htpasswd :

```bash
htpasswd -nb admin mon-mot-de-passe | base64
# Créer le secret avec la valeur encodée
kubectl create secret generic auth-secret \
  --from-literal=users='admin:$apr1$...'  \
  -n traefik
```

### Chaîner les middlewares

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

L'ordre dans la liste `middlewares` est l'ordre d'exécution. Rate limit en premier, headers ensuite, auth en dernier — c'est intentionnel : pas la peine d'authentifier si la requête est déjà rejetée par le rate limit.

## TCP/UDP Routing

Traefik ne se limite pas au HTTP. Les IngressRouteTCP et IngressRouteUDP permettent d'exposer des services non-HTTP.

### Exposer PostgreSQL en TCP

```yaml
apiVersion: traefik.io/v1alpha1
kind: IngressRouteTCP
metadata:
  name: postgres
  namespace: database
spec:
  entryPoints:
    - postgres  # entrypoint custom sur le port 5432
  routes:
    - match: HostSNI(`db.example.com`)
      services:
        - name: postgres-svc
          port: 5432
  tls:
    passthrough: true
```

Il faut déclarer l'entrypoint correspondant dans les values Helm :

```yaml
ports:
  postgres:
    port: 5432
    expose:
      default: true
    protocol: TCP
```

### Service UDP (DNS, jeux…)

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

## Plugins : étendre Traefik sans le recompiler

L'écosystème de plugins Traefik est disponible sur le Traefik Plugin Catalog. La v3 supporte les plugins Wasm en plus du Go classique.

### Exemple : GeoBlock

Bloquer le trafic par pays directement au niveau du reverse proxy :

```yaml
# Dans les values Helm
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

Les plugins sont chargés au démarrage de Traefik. Pas de sidecar, pas de rebuild d'image.

## Dashboard et API

Traefik embarque un dashboard web qui donne une vue complète sur les routers, services, middlewares et entrypoints.

### Sécuriser l'accès

Ne jamais exposer le dashboard sans authentification. Combinaison recommandée :

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

Le middleware IP whitelist pour restreindre à ton réseau :

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

### API programmatique

L'API REST de Traefik est accessible en interne pour le debug :

```bash
# Lister les routers HTTP
kubectl port-forward -n traefik svc/traefik 9000:9000
curl http://localhost:9000/api/http/routers | jq '.[].name'

# Vérifier la santé
curl http://localhost:9000/ping
```

## Observabilité

### Métriques Prometheus

Avec la config Helm ci-dessus, Traefik expose des métriques sur `/metrics`. Les plus utiles :

| Métrique | Description |
|---|---|
| `traefik_entrypoint_requests_total` | Nombre total de requêtes par entrypoint |
| `traefik_router_requests_total` | Requêtes par router (avec code HTTP) |
| `traefik_service_request_duration_seconds` | Latence par service backend |
| `traefik_entrypoint_open_connections` | Connexions actives |
| `traefik_tls_certs_not_after` | Expiration des certificats TLS |

Exemple de règle d'alerte Prometheus :

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
          summary: "Taux d'erreurs 5xx supérieur à 5%"

      - alert: TraefikCertExpiringSoon
        expr: >
          (traefik_tls_certs_not_after - time()) / 86400 < 14
        for: 1h
        labels:
          severity: warning
        annotations:
          summary: "Certificat TLS expire dans moins de 14 jours"
```

### Access logs structurés

Les access logs en JSON sont directement ingérables par Loki, Elasticsearch ou Datadog :

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

### Dashboards Grafana

Avec les labels `addRoutersLabels` et `addServicesLabels` activés, tu peux construire des dashboards Grafana précis. Quelques panels essentiels :

- **Requêtes par seconde par router** — `sum(rate(traefik_router_requests_total[5m])) by (router)`
- **Latence P99 par service** — `histogram_quantile(0.99, sum(rate(traefik_service_request_duration_seconds_bucket[5m])) by (le, service))`
- **Répartition des codes HTTP** — `sum(rate(traefik_router_requests_total[5m])) by (code)` en stacked bar
- **Connexions ouvertes** — `traefik_entrypoint_open_connections` pour détecter les connexions pendantes

Le dashboard communautaire Grafana ID **17346** est un bon point de départ — il couvre les métriques entrypoint, router et service. À adapter ensuite selon tes besoins.

## Cert-Manager et Traefik : TLS automatisé

Traefik peut gérer ses propres certificats via ACME, mais en production Kubernetes on préfère déléguer ça à Cert-Manager :

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

Traefik lit automatiquement les secrets TLS référencés dans les IngressRoute. Pas de config supplémentaire côté Traefik.

## Bonnes pratiques en production

Quelques règles tirées de l'expérience :

1. **Toujours au moins 2 replicas** — un reverse proxy qui tombe, c'est tout le cluster qui est coupé
2. **PodDisruptionBudget** — `minAvailable: 1` minimum
3. **Anti-affinité** — ne pas mettre les deux replicas sur le même nœud
4. **Redirection HTTP → HTTPS** au niveau de l'entrypoint, pas dans chaque IngressRoute
5. **Access logs en JSON** — indispensable pour le debug et le monitoring
6. **Rate limit global** avant l'auth — économise des ressources
7. **Séparer les entrypoints** internes et externes si tu as du trafic intra-cluster
8. **Monitorer les certificats** — l'alerte sur `traefik_tls_certs_not_after` peut sauver un week-end

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
# Anti-affinité dans les values Helm
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

Traefik v3 est bien plus qu'un Ingress Controller. C'est un reverse proxy complet avec du routage expressif, des middlewares chaînables, du TCP/UDP, des plugins, et une observabilité native. Si tu l'utilises déjà en mode basique, prends le temps d'explorer les IngressRoute CRD et les middlewares — c'est là que se trouve la vraie valeur ajoutée.

Et si tu gères plusieurs équipes sur le même cluster, combine ça avec la [Gateway API](/articles/kubernetes-gateway-api/) pour la séparation des responsabilités. Les deux approches cohabitent parfaitement dans Traefik v3.
