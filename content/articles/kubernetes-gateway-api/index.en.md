---
title: "Kubernetes Gateway API: the successor to Ingress is here"
date: 2025-11-10
draft: false
summary: "The Gateway API has been GA since Kubernetes 1.28. Here's why it advantageously replaces Ingress, how it works, and how to set it up with Traefik."
tags: ["Kubernetes", "Gateway API", "Traefik", "Networking"]
---

**Ingress** has served us well, but it quickly hits its limits: endless proprietary annotations, no separation of responsibilities, features missing from the official spec. The **Gateway API** was designed to fix all of that. It's been **GA since Kubernetes 1.28** (October 2023) and is supported by most current network controllers.

## Why replace Ingress?

Ingress suffers from several structural problems:

- **Limited expressiveness**: basic HTTP routing is in the spec, everything else goes through `nginx.ingress.kubernetes.io/...` or `traefik.ingress.kubernetes.io/...` annotations that aren't portable.
- **No role separation**: infra and application teams modify the same object.
- **Advanced features missing**: traffic splitting, header matching, complex redirects, TCP/UDP routing — all out of spec.

The Gateway API solves these three problems with a role-oriented model and a rich spec.

## The key resources

The Gateway API introduces a hierarchy of three main resources:

```
GatewayClass  →  defined by the infra provider (e.g. Traefik, Cilium, Istio)
    └── Gateway  →  defined by the ops / cluster admin
            └── HTTPRoute / TCPRoute / GRPCRoute  →  defined by the app devs
```

### GatewayClass

Declares which controller manages the Gateways. Created once by the infra provider.

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: traefik
spec:
  controllerName: traefik.io/gateway-controller
```

### Gateway

Defines a network entry point (equivalent to a reverse proxy's "listener"). It's the ops who manages it, not the devs.

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

This is the object application teams create in their own namespace.

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

## Features missing from Ingress

### Traffic splitting (canary / blue-green)

No proprietary annotation, straight in the standard spec:

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

### HTTP → HTTPS redirect

```yaml
rules:
  - filters:
      - type: RequestRedirect
        requestRedirect:
          scheme: https
          statusCode: 301
```

### Path rewriting

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

### Header-based routing

Useful for preview environments or A/B routing:

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

## Separation of responsibilities

This is the real organizational gain. The Gateway API defines three personas:

| Persona | Resources | Responsibility |
|---|---|---|
| **Infrastructure provider** | `GatewayClass` | Deploying the controller (Traefik, Cilium…) |
| **Cluster operator** | `Gateway` | Listeners, TLS, allowed namespaces |
| **Application developer** | `HTTPRoute`, `TCPRoute`… | Application routing in their namespace |

Each team only touches the objects that concern it. No more need to grant cluster-wide access to expose an application.

## Installation with Traefik

Traefik has supported the Gateway API since v3. You first need to install the official CRDs:

```bash
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.0/standard-install.yaml
```

Then enable the feature gate in Traefik (Helm values):

```yaml
# values.yaml
providers:
  kubernetesGateway:
    enabled: true

experimental:
  kubernetesGateway:
    enabled: true
```

Check that the CRDs are properly installed:

```bash
kubectl get crd | grep gateway.networking.k8s.io
```

## Project status and experimental channels

The Gateway API is versioned in two channels:

- **Standard**: `HTTPRoute`, `Gateway`, `GatewayClass`, `GRPCRoute` — **GA**
- **Experimental**: `TCPRoute`, `TLSRoute`, `UDPRoute`, `BackendLBPolicy` — beta, subject to change

```bash
# Install the experimental channel (includes standard)
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.0/experimental-install.yaml
```

## Migrating from Ingress

No automatic migration, but the mapping is direct:

| Ingress | Gateway API |
|---|---|
| `spec.rules[].host` | `HTTPRoute.spec.hostnames` |
| `spec.rules[].http.paths` | `HTTPRoute.spec.rules[].matches` |
| `spec.tls` | `Gateway.spec.listeners[].tls` |
| Proprietary annotations | Native filters in `HTTPRoute` |

Ingress and the Gateway API can coexist during the migration: Traefik handles both simultaneously.

## Conclusion

The Gateway API is no longer a preview, it's **production-ready** and actively developed. If you're starting a new cluster or have time to migrate, now is the right moment. The role separation alone justifies the change in multi-team environments.

The next versions (v1.3+) should bring mesh routing (service-to-service) into the standard spec, which could compete directly with solutions like Istio for simple use cases.
