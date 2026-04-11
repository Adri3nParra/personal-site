---
title: "Souverainete cloud : pourquoi basculer sur un hebergeur europeen"
date: 2026-03-28
draft: false
summary: "AWS, GCP, Azure dominent le cloud public, mais les hebergeurs europeens ont muri. Retour d'experience sur OVHCloud et Scaleway, comparaison technique, et arguments pour un cloud plus souverain."
tags: ["Cloud", "OVHCloud", "Scaleway", "Souverainete", "Kubernetes"]
---

Quand je bosse sur de l'infra Kubernetes, la question du cloud provider revient souvent. AWS, GCP, Azure : les trois grands ont le monopole de facto, avec des regions en Europe et des arguments marketings sur la "localisation des donnees". Mais derriere ces slogans, la realite est ailleurs. Retour d'experience apres plusieurs annees sur OVHCloud (pro) et Scaleway (perso/POC), et reflexion sur ce que signifie vraiment la souverainete cloud.

## C'est quoi, la souverainete cloud ?

Le terme est devenu un mot-valise marketing, mais il recouvre des enjeux reels :

- **Juridiction** : tes donnees sont-elles soumises au Cloud Act americain (et donc accessibles a la justice americaine meme sur des serveurs en Europe) ?
- **Gouvernance** : qui controle l'infrastructure ? Une entreprise americaine, chinoise, ou europenne ?
- **Disponibilite** : en cas de crise geopolitique ou de decision politique, un gouvernement peut-il bloquer l'acces a tes services ?
- **Conformite reglementaire** : RGPD, TISAX (automobile), SecNumCloud (defense) — des certifications specifiques a l'Europe.

Les GAFA sont soumis au **CLOUD Act** depuis 2018. Meme si tes donnees sont stockees a Paris ou Francfort, Microsoft, Google ou AWS peuvent etre forces de les transmettre a la justice americaine sur simple demande — sans que tu le saches.

## Les hebergeurs europeens en 2026

### OVHCloud

C'est le leader europeen du cloud, based a Roubaix, cote en bourse depuis 2021. Ils ont fait le pari d'une infrastructure proprietaire (serveurs, datacenters, reseau) plutot que d'utiliser du hardware standard comme les autres clouds.

**Kubernetes : OVH MKS (Managed Kubernetes Service)**

```bash
# Creation d'un cluster MKS via CLI
ovhcli mks cluster create \
  --region gra7 \
  --name my-cluster \
  --version 1.34 \
  --nodepool-name default \
  --nodepool-flavorName b2-7
```

MKS est un managed Kubernetes assez classique : control plane gere par OVH, noeuds workers a ta charge. Le point fort : integration native avec leur ecosysteme (Load Balancers, Object Storage, Managed PostgreSQL…) via le plugin `ovh-cloud` ou encore `openstack` (**vrai préfèrence pour lui**).

Le catalogue de flavors est large, du b2-7 (2 vCPU, 7 Go RAM) au b128-384 pour des workloads heavy. Les prix restent significativement en dessous d'AWS ou GCP — souvent 30 a 50% moins cher pour des configurations equivalentes.

**Ce que j'aime :**
- Prix transparent et competitif
- Gamme de services geres (PostgreSQL, Redis, Kafka, Elasticsearch…)
- Prescence dans plusieurs pays europeens (France, Allemagne, Pologne, Royaume-Uni…)
- Certifie SecNumCloud pour certains services

**Ce qui peut deranger :**
- MKS accuse un retard de 1-2 versions Kubernetes par rapport aux dernieres releases (where 1.35 ??)
- L'ecosysteme est moins riche que les GAFA (pas de equivalent a Lambda, Fargate, CloudFormation complexe…)
- Le support peut etre lent selon le plan

### Scaleway

Paris aussi, focus cloud public depuis 2015. Scaleway a commence avec des serveurs Bare Metal avant de se diversifier. Leur positionnement : un cloud moderne avec une API simple et des prix agres.

**Kubernetes : Kapsule et Kosmos**

```bash
# Creation via Scaleway CLI
scw k8s cluster create \
  name=my-cluster \
  version=1.34.0 \
  region=fr-par \
  pool-additional-config.size=L \
  pool-additional-config.node-type=DEV1-L
```

- **Kapsule** : cluster Kubernetes manage, similaires a MKS
- **Kosmos** : Kubernetes multi-cloud (aggreges des noeuds sur differentes infrastructures)

**Serverless Containers : mon usage perso**

Scaleway a aussi des serverless containers (equivalent Fargate/Lambda), des functions serverless, et un marketplace avec des images preconstruites.

Pour le perso, je suis plus sur du **serverless** que du bare metal. Containers est mon terrain de jeu : pas de serveur a gérer, deployer en une commande, scaler de zero a l'infini. Ce portfolio lui-meme tourne sur Scaleway Containers — un container Docker qui sert du Hugo, pour quelques centimes par mois.

Le use case ideal : sites statiques, APIs legères, bots, petits services qui ne justifient pas un cluster Kubernetes.

**Ce que j'aime :**
- API simple et bien documentee
- Serverless Containers pour le perso (ce portfolio tourne la-dessus)
- Serverless containers vraiment pratiques
- Paris et Amsterdam

**Ce qui peut deranger :**
- Moins de regions qu'OVHCloud
- Ecosysteme limite compare aux GAFA (en ce moment Scaleway travaille beaucoup et sort plein de nouvelles choses)

### Et les autres ?

| Provider | Pays | Points forts | K8s manage |
|---|---|---|---|
| **Hetzner Cloud** | Allemagne | Prix imbattables, bon reseau EU | Non (il faut se batter avec kubeadm) |
| **CloudFerro** | Pologne | Specialise EU (GAIA-X, Copernicus) | Oui (E2K) |
| **Outscale** | France | Certifie SecNumCloud, dedie government | Non (IaaS) |
| **Contabo** | Allemagne | Prix bas, mais opacite sur la localisation | Non |

## Comparaison technique

Pour du Kubernetes, voila comment ca se positionne :

| Critere | OVHCloud MKS | Scaleway Kapsule | AWS EKS | GCP GKE |
|---|---|---|---|---|
| **Prix (2 noeuds L)`** | ~80€/mois | ~70€/mois | ~150€/mois | ~140€/mois |
| **Versions K8s** | 1.28 (lag 2-3 mois) | 1.30 (latest) | Latest | Latest |
| **Multi-region** | 7 pays | 2 regions | Global | Global |
| **Managed DB** | Oui (PostgreSQL, Redis…) | Oui (PostgreSQL, Redis…) | Oui (RDS, ElastiCache…) | Oui (Cloud SQL…) |
| **Object Storage** | S3-compatible | S3-compatible | S3 | GCS |
| **Certifications** | SecNumCloud (partiel) | Non | SOC2, ISO27001… | SOC2, ISO27001… |
| **Cloud Act** | Non | Non | Oui | Oui |

*Prix indicatifs pour 2 noeuds avec 4 vCPU / 8 Go RAM*

Le **S3-compatible** d'OVHCloud et Scaleway est important : tu peux utiliser `rclone`, `s3cmd`, ou n'importe quel client S3 sans etre lie a AWS. Le stockage te coute une fraction du prix de S3.

## Les vrais avantages

Au-dela du discours souverainete, voici ce qui compte concretement :

### 1. La conformite reglementaire

Si tu bosses dans la defense, la sante, ou le secteur public, les certifications comptent. SecNumCloud (ANSSI) est le standard francais, tres exigeant. OVHCloud a plusieurs services certifies, Outscale aussi. C'est souvent un pre-requis contractuel.

### 2. Le cout

Les GAFA pratiquent des tarifs "premium" justifies par leur ecosysteme. Si t'as juste besoin de VMs, de Kubernetes et de stockage objet, OVHCloud ou Scaleway divisent la facture par 2 ou 3.

### 3. La simplicite administrative

Un seul interlocuteur europen, un seul interlocuteur RGPD, un seul fuseau horaire pour le support. Quand t'as un incident a 3h du mat', c'est pas un chatbot en anglais qui va te depanner.

### 4. L'ecosysteme S3-compatible

Le stockage objet est le nouveau standard. Photos, backups, artifacts CI, donnees ML — tout peut aller sur du S3. Les offres europeennes sont 3 a 5 fois moins cheres qu'AWS S3 :

- **AWS S3 Standard** : 23€/To/mois
- **OVHCloud Object Storage** : 5€/To/mois
- **Scaleway Object Storage** : 4€/To/mois

Pour un cluster qui genere quelques Go de logs et backups par jour, la difference est significative.

## Les vraies limites

Etre honnete, c'est pas tout rose :

### 1. L'ecosysteme reste limite

Pas de Lambda, pas de Fargate, pas de Step Functions. Si t'as besoin de serverless complexe ou de services geres exotiques (Amazon Textract, GCP BigQuery…), t'auras vite fait le tour.

### 2. Le lag fonctionnel

MKS sort une nouvelle version Kubernetes 2-3 mois apres upstream. Pour certains, c'est acceptable. Pour d'autres ( CVE immediate ), c'est genant.

### 3. La dette technique

Si t'as des vieux modules Terraform ecrits pour AWS, la migration vers OVHCloud demande du refactoring. Les providers ne sont pas 100% compatibles.

### 4. L'outage risque

OVHCloud a eu des gros incidents (incendie SBG1 en 2021, hack 2022). Scaleway aussi. Mais AWS a aussi eu des pannes massives. Le risque existe partout.

## Quand partir sur un hebergeur europen ?

**Oui si :**
- T'as des contraintes de conformite (RGPD strict, SecNumCloud, TISAX)
- T'as un budget limite et t'as besoin de VMs/K8s/S3
- T'as une equipe technique capable de se passer des services geres AWS/GCP
- La souverainete cloud est un argument commercial ou reglementaire

**Non si :**
- T'as besoin de ML/AI (SageMaker, Vertex AI, Bedrock…)
- T'as des workloads serverless complexes
- Ton equipe ne connait que l'ecosysteme AWS/GCP
- T'as des integrations native avec des services (Auth0, Datadog, etc.)

## Conclusion

Les hebergeurs europeens ne sont pas une utopie de Geeks anti-GAFA — ils sont devenus des alternatives serieuses. OVHCloud et Scaleway couvrent 80% des besoins d'une equipe DevOps moderne, a un prix qui permet de redployer des budgets ailleurs.

Mon set-up personnel :

- **OVHCloud** pour les projets pro
- **Scaleway** pour les experiments et le lab
- **AWS** uniquement quand j'ai pas le choix

La souverainete cloud, c'est pas un dogme. C'est un arbitrage entre cout, conformite, simplicite et services. Pour moi, le balance penche de plus en plus vers l'Europe.
