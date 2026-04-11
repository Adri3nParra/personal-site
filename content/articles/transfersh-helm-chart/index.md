---
title: "Contribuer à l'open source : un Helm chart pour transfer.sh"
date: 2026-02-20
draft: false
summary: "transfer.sh est un outil de partage de fichiers en ligne de commande très utilisé, mais il ne proposait aucun Helm chart officiel. J'ai comblé ce manque avec une contribution open source — et ouvert une PR sur le dépôt upstream."
tags: ["Kubernetes", "Helm", "Open Source", "DevOps"]
---

[transfer.sh](https://github.com/dutchcoders/transfer.sh) est un outil minimaliste de partage de fichiers pensé pour la ligne de commande : un `curl --upload-file` et tu obtiens un lien de téléchargement. Simple, efficace, auto-hébergeable. On l'utilise d'ailleurs sur notre cluster Kubernetes interne.

Mais en creusant le dépôt, je me suis rendu compte que le projet ne proposait **aucun Helm chart officiel**. Quelques manifests Kubernetes basiques dans un dossier, pas de templating, pas de gestion des secrets, pas de support des différents backends de stockage. Pas vraiment utilisable tel quel dans un environnement de production.

## Le constat

Le projet documente uniquement un déploiement Docker. Pour Kubernetes, il faut assembler les manifests à la main — sans abstraction, sans configuration structurée, sans possibilité de gérer proprement les différents backends de stockage que transfer.sh supporte (local, S3, Storj, Google Drive).

Dans un contexte GitOps avec ArgoCD, ça devient vite problématique : les valeurs dépendent de l'environnement, les secrets doivent être injectés proprement, et on veut pouvoir déployer avec un simple `helm upgrade`.

## Ce que j'ai développé

J'ai créé un Helm chart complet que j'ai [proposé en pull request](https://github.com/dutchcoders/transfer.sh/pull/667) sur le dépôt upstream.

### Structure du chart

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

### Backends de stockage

Le chart couvre les quatre backends supportés par transfer.sh :

```yaml
# Stockage local avec PVC
provider: local
local:
  path: /data
  purgeEnabled: true
  purgeDays: 7

# Ou S3 / MinIO
provider: s3
s3:
  endpoint: "https://s3.sbg.io.cloud.ovh.net"
  bucket: "mon-bucket"
  region: "sbg"
  credentials:
    existingSecret: "transfersh-s3-creds"
```

Le backend local et le backend S3 ont été testés en conditions réelles (MinIO inclus). Storj et Google Drive sont configurables mais non testés faute d'accès.

### Sécurité par défaut

Le chart applique des règles de sécurité strictes dès le départ :

- Exécution en **utilisateur non-root** (UID 5000) avec l'image `latest-noroot`
- **Filesystem en lecture seule** — seuls les volumes montés sont accessibles en écriture
- **Capabilities Linux droppées** entièrement
- **NetworkPolicy** optionnelle pour restreindre le trafic entrant au seul contrôleur d'ingress

```yaml
securityContext:
  runAsNonRoot: true
  runAsUser: 5000
  readOnlyRootFilesystem: true
  capabilities:
    drop: ["ALL"]
```

### Fonctionnalités optionnelles

Le chart expose toutes les options de transfer.sh via les values :

- **Authentification HTTP Basic** — pour protéger les uploads
- **Rate limiting** — 30 requêtes/minute par défaut
- **ClamAV** — scan antivirus des fichiers uploadés
- **HPA** — autoscaling horizontal
- **Ingress standard** ou **Gateway API** (HTTPRoute) selon le controller utilisé
- **Whitelist/Blacklist IP** pour le contrôle d'accès

### Compatibilité ingress

Support des deux approches :

```yaml
# Ingress classique
ingress:
  enabled: true
  className: traefik
  hosts:
    - host: transfer.exemple.com
      paths: [{ path: /, pathType: Prefix }]

# Ou Gateway API
gatewayAPI:
  enabled: true
  parentRefs:
    - name: main-gateway
      namespace: traefik
      sectionName: websecure
  hostnames:
    - transfer.exemple.com
```

## La PR upstream

La [pull request #667](https://github.com/dutchcoders/transfer.sh/pull/667) a suscité de l'intérêt côté mainteneurs. Un collaborateur du projet a proposé de tester et maintenir le chart — signe que le besoin était réel.

Le retour initial portait sur la question de la maintenabilité à long terme, ce qui est légitime : un chart Helm sous-maintenu peut devenir un fardeau plus qu'un atout. La discussion est en cours.

## Ce que ça m'a apporté

Contribuer à un projet open source utilisé en production, c'est un exercice différent d'écrire du code pour soi. Il faut :

- **Documenter** pour des inconnus — le README explique chaque option, les cas d'usage et les backends testés.
- **Gérer les cas limites** — que se passe-t-il si on active l'auth HTTP et Gateway API en même temps ? Si le PVC n'est pas disponible ?
- **Suivre les conventions** du projet existant — nommage, structure, style des labels Kubernetes.
- **Anticiper les retours** — les mainteneurs ont des contraintes (sécurité, compatibilité, maintenabilité) qui ne sont pas forcément les miennes.

La contribution est ouverte, les retours positifs. En attendant, le chart est déployé et utilisé en production sur notre cluster.
