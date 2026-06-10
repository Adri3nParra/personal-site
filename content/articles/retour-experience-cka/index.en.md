---
title: "CKA: a hands-on review of the Kubernetes Administrator certification"
date: 2026-03-15
draft: false
summary: "I sat and passed the CKA (Certified Kubernetes Administrator) in March 2026. Here's how I prepared, what the exam really tests, and what I concretely took away from it."
tags: ["Kubernetes", "CKA", "Certification", "DevOps"]
---

I've been using Kubernetes daily for several years. I've built clusters, run GitOps pipelines, debugged pods at 2 a.m. So why take the CKA rather than just keep working? Because there's a difference between *using* Kubernetes and *understanding* Kubernetes, and this exam forces you to fill the gaps.

## What the CKA is

The **Certified Kubernetes Administrator** is a hands-on certification delivered by the Linux Foundation and the CNCF. No multiple choice, no theoretical boxes to tick: it's **two hours of terminal**, a real Kubernetes cluster, and a series of tasks to complete. You're assessed on what you can do, not on what you can recite.

The minimum passing score is **66%**. The tasks cover the full scope of a K8s administrator.

## The domains covered

The exam is split into several weighted domains:

| Domain | Weight |
|---|---|
| Storage | 10% |
| Troubleshooting | 30% |
| Workload architecture | 15% |
| Services & Networking | 20% |
| Cluster management | 25% |

**Troubleshooting** alone accounts for almost a third of the exam. That's the real test: you don't need to know the documentation by heart, you need to know how to diagnose what's wrong and fix it under pressure.

## Preparation

I had a head start: Kubernetes in production for several years. But the exam covers aspects you don't necessarily touch day to day when you work on Managed Kubernetes — managing the cluster itself, certificates, etcd, kubeadm.

### What helped me

- **Regular practice**: having a real cluster at hand every day is still the best preparation. Knowing where to look without fumbling through the docs is built over time.
- **killer.sh**: the simulation environment provided with the exam. Two sessions included in the pass, noticeably harder than the real exam. If you pass killer.sh, you pass the CKA.
- **The official documentation**: the exam allows `kubernetes.io/docs`. Knowing how to navigate the docs quickly (search, bookmarks) is a skill in itself. No need to memorize everything, but you need to know where to go fast.

### The points I had to work on

- **kubeadm**: initializing a cluster, joining a node, upgrading the control plane. Not something you often do on MKS.
- **etcd backup/restore**: the exact procedure with `etcdctl`, the flags, the paths. A classic at the exam.
- **Network Policies**: the concept is simple, but writing the YAML correctly under pressure without errors is worth practicing.
- **RBAC**: creating ServiceAccounts, Roles, ClusterRoleBindings. Not complex, but time-consuming if you don't have the commands in mind.

## The exam

Two hours. Around 15 to 20 tasks of varying difficulty. A browser with access to the official Kubernetes documentation, and that's it.

A few observations:

**Time management is critical.** Each task has a stated weight. Spending twenty minutes on a 4% task and missing two 8% tasks is a bad strategy. I flagged the complex tasks and came back to them at the end of the exam.

**`kubectl` is your best friend.** The `--dry-run=client -o yaml` flags, `kubectl explain`, `kubectl describe` — having them in muscle memory saves precious time.

**The environment is multi-cluster.** Each task specifies which cluster to work on. Forgetting to run `kubectl config use-context` before you start is the classic mistake that costs you dearly.

**Copy-paste from the docs.** For complex YAML (Network Policies, PersistentVolumes), I'd look up an example directly in the documentation and adapt it. Faster and less risky than writing from memory.

## What it changes

Honestly, the CKA didn't revolutionize the way I work day to day. But it filled real blind spots, especially around the cluster layer itself, which Managed Kubernetes abstracts away entirely. Understanding what happens under the hood changes how you read incidents.

There's also a more pragmatic side: it's an industry-recognized certification, backed by the CNCF. It validates a skill objectively, regardless of the context in which you acquired that experience.

Next step: the **CKAD** (Certified Kubernetes Application Developer), to round things out with the developer perspective.

## Tips if you're preparing

1. **Practice, not reading**: videos and books aren't enough. You need hours of terminal.
2. **Master the imperative commands**: `kubectl create deployment`, `kubectl expose`, `kubectl create role` with the right flags. Writing YAML by hand is slow.
3. **killer.sh is mandatory**: do both sessions, read the corrections, understand why you failed.
4. **Learn to navigate the docs**: bookmark the Network Policy, PV/PVC, kubeadm upgrade and etcd backup pages before the exam.
5. **Manage your time**: note the weight of each task, start with what you're confident on, come back to the complex ones at the end.
