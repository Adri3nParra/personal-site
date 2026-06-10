---
title: "nerdctl: the Docker CLI for containerd"
date: 2026-03-01
draft: false
summary: "nerdctl mirrors Docker's syntax exactly, but talks to containerd directly. A handy tool for debugging a Kubernetes cluster, working without a Docker daemon, or experimenting with features Docker doesn't offer yet."
tags: ["containerd", "Docker", "Kubernetes", "Containers"]
---

If you work with Kubernetes, you've necessarily heard of containerd — it's the container runtime used by default ever since Docker was removed from the kubelet chain. But containerd ships with `ctr`, a low-level CLI that's verbose and not very ergonomic. **nerdctl** fills that gap with an interface identical to Docker's.

## Why nerdctl exists

Docker isn't just a runtime, it's a daemon (`dockerd`) that runs in the background and exposes a Unix socket. On a Kubernetes node, that daemon no longer exists: kubelet talks directly to containerd via CRI. `docker ps` sees nothing, `docker exec` doesn't work.

To interact with containers on a Kubernetes node, you have to go either through `crictl` (CRI-debug oriented, different syntax) or `ctr` (very low level). Neither one looks like Docker.

nerdctl solves this with a simple goal: **same syntax as Docker, but wired directly into containerd**.

```bash
# Docker
docker run -it --rm alpine sh
docker build -t mon-image .
docker compose up

# nerdctl: exactly the same
nerdctl run -it --rm alpine sh
nerdctl build -t mon-image .
nerdctl compose up
```

## The main use case: debugging on a Kubernetes node

On a Kubernetes node, all containers run in the containerd `k8s.io` namespace. nerdctl lets you inspect them directly:

```bash
# List all the cluster's containers on this node
nerdctl --namespace k8s.io ps -a

# Inspect the logs of a specific container
nerdctl --namespace k8s.io logs <container-id>

# Exec into a running container
nerdctl --namespace k8s.io exec -it <container-id> sh

# List the images present on the node
nerdctl --namespace k8s.io images
```

This is particularly useful for diagnosing image problems (corrupt layer, pull issue) or debugging a container whose logs aren't surfacing properly through kubectl.

## containerd namespaces

Unlike Docker, which has a global space, containerd organizes its resources into isolated **namespaces**:

| Namespace | Usage |
|---|---|
| `default` | Containers started manually via nerdctl |
| `k8s.io` | Containers managed by Kubernetes / kubelet |
| `moby` | Docker containers (if dockerd is present) |

Without `--namespace`, nerdctl operates in `default`. To see the Kubernetes containers, you have to explicitly target `k8s.io`.

## Features missing from Docker

nerdctl was created to experiment with containerd features not yet available in Docker.

### Lazy pulling

The classic image download waits until **all layers are downloaded** before starting the container. With advanced snapshotters, nerdctl can start a container **while the image is downloading**: only the data actually accessed is fetched.

```bash
# With the stargz snapshotter (images optimized for lazy pull)
nerdctl run --snapshotter=stargz ghcr.io/exemple/mon-image:latest
```

Useful for large ML images or environments with a slow connection.

### Image encryption

nerdctl supports `ocicrypt` to encrypt and decrypt OCI images:

```bash
# Encrypt an image with a public key
nerdctl image encrypt --recipient jwe:cle-publique.pem mon-image:latest mon-image:chiffree

# Decrypt on pull
nerdctl pull --unpack-key cle-privee.pem mon-image:chiffree
```

### Rootless mode

nerdctl can run **without root privileges**, which is useful on shared systems or to strengthen isolation. With `bypass4netns`, rootless network performance is comparable to root mode, which isn't the case with slirp4netns.

```bash
# Rootless installation
containerd-rootless-setuptool.sh install
nerdctl-rootless run -it --rm alpine
```

## Installation

nerdctl is distributed in two variants:

```bash
# Minimal: just the nerdctl binary
wget https://github.com/containerd/nerdctl/releases/latest/download/nerdctl-<version>-linux-amd64.tar.gz

# Full: nerdctl + BuildKit + CNI plugins + extras
wget https://github.com/containerd/nerdctl/releases/latest/download/nerdctl-full-<version>-linux-amd64.tar.gz
```

The `full` version is recommended for standalone use (without a Kubernetes cluster already in place). It includes everything needed for `nerdctl build` and networking.

## nerdctl vs ctr vs crictl

| | `docker` | `nerdctl` | `ctr` | `crictl` |
|---|---|---|---|---|
| **Syntax** | Reference | Docker-compatible | Low level | CRI-oriented |
| **Compose** | Yes | Yes | No | No |
| **Port mapping** | Yes | Yes | No | No |
| **k8s.io namespaces** | No | Yes | Yes | Yes |
| **Image build** | Yes | Yes (BuildKit) | No | No |
| **Rootless** | Partial | Yes (bypass4netns) | No | No |
| **Daemon required** | dockerd | containerd | containerd | containerd |

## Conclusion

nerdctl isn't there to replace Docker in local development workflows — Docker stays simpler for that. But on a Kubernetes node, on a Linux server without Docker, or for someone who wants to work directly with containerd without relearning a new syntax, it's the most ergonomic tool available.

The next time you find yourself typing `docker ps` on a Kubernetes node wondering why it returns nothing, the answer is nerdctl.
