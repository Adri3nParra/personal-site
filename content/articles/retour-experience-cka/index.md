---
title: "CKA : retour d'expérience sur la certification Kubernetes Administrator"
date: 2026-03-15
draft: false
summary: "J'ai passé et obtenu le CKA (Certified Kubernetes Administrator) en mars 2026. Voici comment je m'y suis préparé, ce que l'examen teste vraiment, et ce que j'en retire concrètement."
tags: ["Kubernetes", "CKA", "Certification", "DevOps"]
---

J'utilise Kubernetes au quotidien depuis plusieurs années. J'ai monté des clusters, géré des pipelines GitOps, débuggé des pods à 2h du matin. Alors pourquoi passer le CKA plutôt que de simplement continuer à bosser ? Parce qu'il y a une différence entre *utiliser* Kubernetes et *comprendre* Kubernetes — et cet examen force à combler les lacunes.

## Ce qu'est le CKA

Le **Certified Kubernetes Administrator** est une certification pratique délivrée par la Linux Foundation et la CNCF. Pas de QCM, pas de questions théoriques à cocher : c'est **deux heures de terminal**, un vrai cluster Kubernetes, et une série de tâches à accomplir. On est évalué sur ce qu'on sait faire, pas sur ce qu'on sait réciter.

Le score minimum pour réussir est de **66%**. Les tâches couvrent l'ensemble du périmètre d'un administrateur K8s.

## Les domaines couverts

L'examen se découpe en plusieurs domaines pondérés :

| Domaine | Poids |
|---|---|
| Stockage | 10% |
| Troubleshooting | 30% |
| Architecture des workloads | 15% |
| Services & Networking | 20% |
| Gestion du cluster | 25% |

Le **troubleshooting** représente à lui seul presque un tiers de l'examen. C'est le vrai test : pas besoin de connaître la documentation par cœur, il faut savoir diagnostiquer ce qui ne va pas et le corriger sous pression.

## La préparation

J'avais un avantage de départ : Kubernetes en production depuis plusieurs années. Mais l'examen couvre des aspects qu'on ne touche pas forcément au quotidien quand on travaille sur du Managed Kubernetes — la gestion du cluster lui-même, les certificats, etcd, kubeadm.

### Ce qui m'a aidé

- **La pratique régulière** — avoir un vrai cluster sous les mains au quotidien reste la meilleure préparation. Savoir où chercher sans tâtonner dans la doc, ça se construit sur la durée.
- **killer.sh** — l'environnement de simulation fourni avec l'examen. Deux sessions incluses dans le pass, nettement plus difficile que le vrai examen. Si tu passes killer.sh, tu passes le CKA.
- **La documentation officielle** — l'examen autorise `kubernetes.io/docs`. Savoir naviguer rapidement dans la doc (recherche, signets) est une compétence en soi. Inutile de tout mémoriser, mais il faut savoir où aller vite.

### Les points sur lesquels j'ai dû bosser

- **kubeadm** — initialiser un cluster, joindre un node, upgrader le control plane. Pas quelque chose qu'on fait souvent sur du MKS.
- **etcd backup/restore** — la procédure exacte avec `etcdctl`, les flags, les chemins. Classique à l'examen.
- **Network Policies** — le concept est simple, mais écrire les YAML correctement sous pression sans erreur, ça mérite de s'y entraîner.
- **RBAC** — créer des ServiceAccounts, des Roles, des ClusterRoleBindings. Pas complexe, mais chronophage si on n'a pas les commandes en tête.

## L'examen

Deux heures. Environ 15 à 20 tâches de difficulté variable. Un browser avec accès à la documentation officielle Kubernetes, et c'est tout.

Quelques observations :

**La gestion du temps est critique.** Chaque tâche a un poids indiqué. Passer vingt minutes sur une tâche à 4% et louper deux tâches à 8% chacune, c'est une mauvaise stratégie. Je marquais les tâches complexes et j'y revenais en fin d'examen.

**`kubectl` est ton meilleur ami.** Les flags `--dry-run=client -o yaml`, `kubectl explain`, `kubectl describe` — les avoir en mémoire musculaire fait gagner un temps précieux.

**L'environnement est multi-cluster.** Chaque tâche précise sur quel cluster travailler. Oublier de faire le `kubectl config use-context` avant de commencer, c'est l'erreur classique qui coûte cher.

**Copier-coller depuis la doc.** Pour les YAML complexes (Network Policies, PersistentVolumes), je cherchais directement un exemple dans la documentation et j'adaptais. Plus rapide et moins risqué que d'écrire de mémoire.

## Ce que ça change

Honnêtement, le CKA n'a pas révolutionné ma façon de travailler au quotidien. Mais il a comblé des angles morts réels — notamment sur la couche cluster elle-même, que le Managed Kubernetes abstrait complètement. Comprendre ce qu'il se passe sous le capot change la lecture des incidents.

Il y a aussi un aspect plus pragmatique : c'est une certification reconnue dans l'industrie, portée par la CNCF. Elle valide une compétence de manière objective, indépendamment du contexte dans lequel on a acquis cette expérience.

La prochaine étape : le **CKAD** (Certified Kubernetes Application Developer), pour compléter avec la perspective développeur.

## Conseils si tu te prépares

1. **Pratique, pas lecture** — les vidéos et les livres ne suffisent pas. Il faut des heures de terminal.
2. **Maîtrise les impératives** — `kubectl create deployment`, `kubectl expose`, `kubectl create role` avec les bons flags. Le YAML à la main c'est lent.
3. **killer.sh obligatoire** — fais les deux sessions, lis les corrections, comprends pourquoi tu as raté.
4. **Apprends à naviguer dans la doc** — bookmarke les pages Network Policy, PV/PVC, kubeadm upgrade, etcd backup avant l'examen.
5. **Gère ton temps** — note le poids de chaque tâche, commence par ce que tu maîtrises, reviens sur le complexe en fin d'examen.
