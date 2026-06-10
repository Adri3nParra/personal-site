---
title: "Contributing to open source: a Helm chart for transfer.sh"
date: 2026-02-20
draft: false
summary: "transfer.sh is a widely used command-line file-sharing tool, but it had no official Helm chart. I filled that gap with an open source contribution and opened a PR on the upstream repository."
tags: ["Kubernetes", "Helm", "Open Source", "DevOps"]
---

[transfer.sh](https://github.com/dutchcoders/transfer.sh) is a minimalist file-sharing tool designed for the command line: a `curl --upload-file` and you get a download link. Simple, effective, self-hostable. We actually use it on our internal Kubernetes cluster.

But digging into the repository, I realized the project offered **no official Helm chart**. A few basic Kubernetes manifests in a folder, no templating, no secret management, no support for the different storage backends. Not really usable as-is in a production environment.

## The observation

The project only documents a Docker deployment. For Kubernetes, you have to assemble the manifests by hand, with no abstraction, no structured configuration, and no way to cleanly manage the different storage backends transfer.sh supports (local, S3, Storj, Google Drive).

In a GitOps context with ArgoCD, this quickly becomes problematic: values depend on the environment, secrets must be injected cleanly, and you want to be able to deploy with a simple `helm upgrade`.

## What I built

I created a complete Helm chart that I [proposed as a pull request](https://github.com/dutchcoders/transfer.sh/pull/667) on the upstream repository.

### Chart structure

```
k8s/transfer.sh/
├── Chart.yaml
├── values.yaml
├── README.md
└── templates/
    ├── _helpers.tpl
    ├── configmap.yaml
    ├── deployment.yaml
    ├── hpa.yaml
    ├── httproute.yaml      # Gateway API
    ├── ingress.yaml
    ├── networkpolicy.yaml
    ├── pvc.yaml
    ├── service.yaml
    ├── serviceaccount.yaml
    └── NOTES.txt
```

### Storage backends

The chart covers the four backends supported by transfer.sh:

```yaml
# Local storage with PVC
provider: local
local:
  path: /data
  purgeEnabled: true
  purgeDays: 7

# Or S3 / MinIO
provider: s3
s3:
  endpoint: "https://s3.sbg.io.cloud.ovh.net"
  bucket: "mon-bucket"
  region: "sbg"
  credentials:
    existingSecret: "transfersh-s3-creds"
```

The local backend and the S3 backend were tested under real conditions (MinIO included). Storj and Google Drive are configurable but untested for lack of access.

### Secure by default

The chart applies strict security rules from the start:

- Runs as a **non-root user** (UID 5000) with the `latest-noroot` image
- **Read-only filesystem**: only mounted volumes are writable
- **Linux capabilities** dropped entirely
- Optional **NetworkPolicy** to restrict incoming traffic to the ingress controller only

```yaml
securityContext:
  runAsNonRoot: true
  runAsUser: 5000
  readOnlyRootFilesystem: true
  capabilities:
    drop: ["ALL"]
```

### Optional features

The chart exposes all of transfer.sh's options through values:

- **HTTP Basic authentication**: to protect uploads
- **Rate limiting**: 30 requests/minute by default
- **ClamAV**: antivirus scanning of uploaded files
- **HPA**: horizontal autoscaling
- **Standard Ingress** or **Gateway API** (HTTPRoute) depending on the controller in use
- **IP whitelist/blacklist** for access control

### Ingress compatibility

Support for both approaches:

```yaml
# Classic Ingress
ingress:
  enabled: true
  className: traefik
  hosts:
    - host: transfer.exemple.com
      paths: [{ path: /, pathType: Prefix }]

# Or Gateway API
gatewayAPI:
  enabled: true
  parentRefs:
    - name: main-gateway
      namespace: traefik
      sectionName: websecure
  hostnames:
    - transfer.exemple.com
```

## The upstream PR

[Pull request #667](https://github.com/dutchcoders/transfer.sh/pull/667) sparked interest from the maintainers. A project collaborator offered to test and maintain the chart, a sign that the need was real.

The initial feedback was about long-term maintainability, which is fair: an under-maintained Helm chart can become more of a burden than an asset. The discussion is ongoing.

## What it brought me

Contributing to an open source project used in production is a different exercise from writing code for yourself. You have to:

- **Document** for strangers — the README explains every option, the use cases and the tested backends.
- **Handle edge cases**: what happens if you enable HTTP auth and Gateway API at the same time? If the PVC isn't available?
- **Follow the conventions** of the existing project — naming, structure, Kubernetes label style.
- **Anticipate feedback**: maintainers have constraints (security, compatibility, maintainability) that aren't necessarily mine.

The contribution is open, the feedback positive. In the meantime, the chart is deployed and used in production on our cluster.
