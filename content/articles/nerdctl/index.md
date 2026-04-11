---
title: "nerdctl : le CLI Docker pour containerd"
date: 2026-03-01
draft: false
summary: "nerdctl reprend la syntaxe Docker à l'identique, mais s'appuie sur containerd directement. Un outil utile pour déboguer un cluster Kubernetes, travailler sans Docker daemon, ou expérimenter des fonctionnalités que Docker ne propose pas encore."
tags: ["containerd", "Docker", "Kubernetes", "Conteneurs"]
---

Si tu travailles avec Kubernetes, tu as forcément entendu parler de containerd — c'est le runtime de conteneurs utilisé par défaut depuis que Docker a été retiré de la chaîne kubelet. Mais containerd vient avec `ctr`, un CLI bas niveau, verbeux et peu ergonomique. **nerdctl** comble ce vide avec une interface identique à Docker.

## Pourquoi nerdctl existe

Docker n'est pas juste un runtime — c'est un daemon (`dockerd`) qui tourne en arrière-plan et expose une socket Unix. Sur un nœud Kubernetes, ce daemon n'existe plus : kubelet parle directement à containerd via CRI. `docker ps` ne voit rien, `docker exec` ne fonctionne pas.

Pour interagir avec les conteneurs sur un nœud Kubernetes, il faut soit passer par `crictl` (orienté debug CRI, syntaxe différente), soit par `ctr` (très bas niveau). Ni l'un ni l'autre ne ressemble à Docker.

nerdctl résout ça avec un objectif simple : **même syntaxe que Docker, mais branché directement sur containerd**.

```bash
# Docker
docker run -it --rm alpine sh
docker build -t mon-image .
docker compose up

# nerdctl — exactement pareil
nerdctl run -it --rm alpine sh
nerdctl build -t mon-image .
nerdctl compose up
```

## Le cas d'usage principal : déboguer sur un nœud Kubernetes

Sur un nœud Kubernetes, tous les conteneurs tournent dans le namespace containerd `k8s.io`. nerdctl permet de les inspecter directement :

```bash
# Lister tous les conteneurs du cluster sur ce nœud
nerdctl --namespace k8s.io ps -a

# Inspecter les logs d'un conteneur spécifique
nerdctl --namespace k8s.io logs <container-id>

# Exec dans un conteneur en cours d'exécution
nerdctl --namespace k8s.io exec -it <container-id> sh

# Lister les images présentes sur le nœud
nerdctl --namespace k8s.io images
```

C'est particulièrement utile pour diagnostiquer des problèmes d'images (layer corrompu, problème de pull) ou déboguer un conteneur dont les logs ne remontent pas correctement via kubectl.

## Les namespaces containerd

Contrairement à Docker qui a un espace global, containerd organise ses ressources en **namespaces** isolés :

| Namespace | Usage |
|---|---|
| `default` | Conteneurs lancés manuellement via nerdctl |
| `k8s.io` | Conteneurs gérés par Kubernetes / kubelet |
| `moby` | Conteneurs Docker (si dockerd est présent) |

Sans `--namespace`, nerdctl opère dans `default`. Pour voir les conteneurs Kubernetes, il faut explicitement cibler `k8s.io`.

## Fonctionnalités absentes de Docker

nerdctl a été créé pour expérimenter des fonctionnalités de containerd pas encore disponibles dans Docker.

### Lazy pulling

Le téléchargement classique d'une image attend que **tous les layers soient téléchargés** avant de démarrer le conteneur. Avec les snapshotters avancés, nerdctl peut démarrer un conteneur **pendant que l'image se télécharge** — seules les données réellement accédées sont récupérées.

```bash
# Avec le snapshotter stargz (images optimisées pour le lazy pull)
nerdctl run --snapshotter=stargz ghcr.io/exemple/mon-image:latest
```

Utile pour les grosses images ML ou les environnements avec une connexion lente.

### Chiffrement d'images

nerdctl supporte `ocicrypt` pour chiffrer et déchiffrer des images OCI :

```bash
# Chiffrer une image avec une clé publique
nerdctl image encrypt --recipient jwe:cle-publique.pem mon-image:latest mon-image:chiffree

# Déchiffrer au pull
nerdctl pull --unpack-key cle-privee.pem mon-image:chiffree
```

### Mode rootless

nerdctl peut tourner **sans privilèges root**, ce qui est utile sur des systèmes partagés ou pour renforcer l'isolation. Avec `bypass4netns`, les performances réseau en rootless sont comparables au mode root — ce qui n'est pas le cas avec slirp4netns.

```bash
# Installation rootless
containerd-rootless-setuptool.sh install
nerdctl-rootless run -it --rm alpine
```

## Installation

nerdctl se distribue en deux variantes :

```bash
# Minimal — juste le binaire nerdctl
wget https://github.com/containerd/nerdctl/releases/latest/download/nerdctl-<version>-linux-amd64.tar.gz

# Full — nerdctl + BuildKit + CNI plugins + extras
wget https://github.com/containerd/nerdctl/releases/latest/download/nerdctl-full-<version>-linux-amd64.tar.gz
```

La version `full` est recommandée pour un usage autonome (sans cluster Kubernetes déjà en place). Elle inclut tout le nécessaire pour `nerdctl build` et le networking.

## nerdctl vs ctr vs crictl

| | `docker` | `nerdctl` | `ctr` | `crictl` |
|---|---|---|---|---|
| **Syntaxe** | Référence | Compatible Docker | Bas niveau | Orienté CRI |
| **Compose** | Oui | Oui | Non | Non |
| **Port mapping** | Oui | Oui | Non | Non |
| **Namespaces k8s.io** | Non | Oui | Oui | Oui |
| **Build d'images** | Oui | Oui (BuildKit) | Non | Non |
| **Rootless** | Partiel | Oui (bypass4netns) | Non | Non |
| **Daemon requis** | dockerd | containerd | containerd | containerd |

## Conclusion

nerdctl n'est pas là pour remplacer Docker dans les workflows de développement locaux — Docker reste plus simple pour ça. Mais sur un nœud Kubernetes, sur un serveur Linux sans Docker, ou pour quelqu'un qui veut travailler directement avec containerd sans réapprendre une nouvelle syntaxe, c'est l'outil le plus ergonomique disponible.

La prochaine fois que tu te retrouves à taper `docker ps` sur un nœud Kubernetes en te demandant pourquoi ça ne retourne rien, la réponse c'est nerdctl.
