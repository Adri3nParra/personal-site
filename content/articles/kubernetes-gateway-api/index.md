---
title: "Kubernetes Gateway API : le successeur d'Ingress est là"
date: 2025-11-10
draft: false
summary: "La Gateway API est GA depuis Kubernetes 1.28. Voici pourquoi elle remplace avantageusement Ingress, comment elle fonctionne, et comment la mettre en place avec Traefik."
tags: ["Kubernetes", "Gateway API", "Traefik", "Réseau"]
---

L'**Ingress** a rendu de bons services, mais il atteint vite ses limites : annotations propriétaires à n'en plus finir, pas de séparation des responsabilités, des fonctionnalités manquantes dans la spec officielle. La **Gateway API** a été conçue pour corriger tout ça. Elle est **GA depuis Kubernetes 1.28** (octobre 2023) et supportée par la majorité des controllers réseau actuels.

## Pourquoi remplacer Ingress ?

L'Ingress souffre de plusieurs problèmes structurels :

- **Expressivité limitée** — le routage HTTP basique est dans la spec, tout le reste passe par des annotations `nginx.ingress.kubernetes.io/...` ou `traefik.ingress.kubernetes.io/...` qui ne sont pas portables.
- **Pas de séparation des rôles** — l'infra et les équipes applicatives modifient le même objet.
- **Fonctionnalités avancées absentes** — traffic splitting, header matching, redirections complexes, TCP/UDP routing : tout est hors-spec.

La Gateway API résout ces trois problèmes avec un modèle orienté rôles et une spec riche.

## Les ressources clés

La Gateway API introduit une hiérarchie de trois ressources principales :

```
GatewayClass  →  défini par l'infra provider (ex: Traefik, Cilium, Istio)
    └── Gateway  →  défini par l'ops / cluster admin
            └── HTTPRoute / TCPRoute / GRPCRoute  →  défini par les devs app
```

### GatewayClass

Déclare quel controller gère les Gateways. Créé une fois par l'infra provider.

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: traefik
spec:
  controllerName: traefik.io/gateway-controller
```

### Gateway

Définit un point d'entrée réseau (équivalent au "listener" d'un reverse proxy). C'est l'ops qui le gère, pas les devs.

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: main-gateway
  namespace: traefik
spec:
  gatewayClassName: traefik
  listeners:
    - name: web
      port: 80
      protocol: HTTP
      allowedRoutes:
        namespaces:
          from: All
    - name: websecure
      port: 443
      protocol: HTTPS
      tls:
        mode: Terminate
        certificateRefs:
          - name: tls-secret
      allowedRoutes:
        namespaces:
          from: All
```

### HTTPRoute

C'est l'objet que les équipes applicatives créent dans leur propre namespace.

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: mon-app
  namespace: production
spec:
  parentRefs:
    - name: main-gateway
      namespace: traefik
      sectionName: websecure
  hostnames:
    - "mon-app.example.com"
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: mon-app-svc
          port: 8080
```

## Fonctionnalités absentes d'Ingress

### Traffic splitting (canary / blue-green)

Sans annotation propriétaire, dans la spec standard :

```yaml
rules:
  - backendRefs:
      - name: app-v1
        port: 8080
        weight: 90
      - name: app-v2
        port: 8080
        weight: 10
```

### Redirection HTTP → HTTPS

```yaml
rules:
  - filters:
      - type: RequestRedirect
        requestRedirect:
          scheme: https
          statusCode: 301
```

### Réécriture de chemin

```yaml
rules:
  - matches:
      - path:
          type: PathPrefix
          value: /api
    filters:
      - type: URLRewrite
        urlRewrite:
          path:
            type: ReplacePrefixMatch
            replacePrefixMatch: /
    backendRefs:
      - name: api-svc
        port: 3000
```

### Routage par header

Utile pour les environnements de preview ou le routing A/B :

```yaml
rules:
  - matches:
      - headers:
          - name: X-Env
            value: staging
    backendRefs:
      - name: app-staging
        port: 8080
```

## Séparation des responsabilités

C'est le vrai gain organisationnel. La Gateway API définit trois personas :

| Persona | Ressources | Responsabilité |
|---|---|---|
| **Infrastructure provider** | `GatewayClass` | Déploiement du controller (Traefik, Cilium…) |
| **Cluster operator** | `Gateway` | Listeners, TLS, namespaces autorisés |
| **Application developer** | `HTTPRoute`, `TCPRoute`… | Routing applicatif dans son namespace |

Chaque équipe ne touche qu'aux objets qui la concernent. Plus besoin de donner accès cluster-wide pour exposer une application.

## Installation avec Traefik

Traefik supporte la Gateway API depuis la v3. Il faut d'abord installer les CRDs officiels :

```bash
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.0/standard-install.yaml
```

Puis activer le feature gate dans Traefik (values Helm) :

```yaml
# values.yaml
providers:
  kubernetesGateway:
    enabled: true

experimental:
  kubernetesGateway:
    enabled: true
```

Vérifier que les CRDs sont bien installés :

```bash
kubectl get crd | grep gateway.networking.k8s.io
```

## État du projet et canaux expérimentaux

La Gateway API est versionnée en deux canaux :

- **Standard** — `HTTPRoute`, `Gateway`, `GatewayClass`, `GRPCRoute` : **GA**
- **Experimental** — `TCPRoute`, `TLSRoute`, `UDPRoute`, `BackendLBPolicy` : beta, susceptibles d'évoluer

```bash
# Installer le canal experimental (inclut standard)
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.0/experimental-install.yaml
```

## Migration depuis Ingress

Pas de migration automatique, mais le mapping est direct :

| Ingress | Gateway API |
|---|---|
| `spec.rules[].host` | `HTTPRoute.spec.hostnames` |
| `spec.rules[].http.paths` | `HTTPRoute.spec.rules[].matches` |
| `spec.tls` | `Gateway.spec.listeners[].tls` |
| Annotations propriétaires | Filtres natifs dans `HTTPRoute` |

Il est possible de faire cohabiter Ingress et Gateway API pendant la migration : Traefik gère les deux simultanément.

## Conclusion

La Gateway API n'est plus une preview — elle est **production-ready** et activement développée. Si tu démarres un nouveau cluster ou que tu as du temps pour migrer, c'est le bon moment. La séparation des rôles seule justifie le changement dans les environnements multi-équipes.

Les prochaines versions (v1.3+) devraient amener le routage mesh (service-to-service) dans la spec standard, ce qui pourrait concurrencer directement des solutions comme Istio pour les cas d'usage simples.
