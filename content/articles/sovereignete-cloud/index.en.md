---
title: "Cloud sovereignty: why switch to a European provider"
date: 2026-03-28
draft: false
summary: "AWS, GCP and Azure dominate the public cloud, but European providers have matured. A hands-on review of OVHcloud and Scaleway, a technical comparison, and the case for a more sovereign cloud."
tags: ["Cloud", "OVHcloud", "Scaleway", "Sovereignty", "Kubernetes"]
---

When I work on Kubernetes infrastructure, the question of the cloud provider comes up often. AWS, GCP, Azure: the big three hold a de facto monopoly, with regions in Europe and marketing arguments about "data localization." But behind those slogans, the reality lies elsewhere. Here's a hands-on review after several years on OVHcloud (professional) and Scaleway (personal/POC), and a reflection on what cloud sovereignty really means.

## What is cloud sovereignty?

The term has become a marketing buzzword, but it covers real concerns:

- **Jurisdiction**: is your data subject to the U.S. Cloud Act (and therefore accessible to U.S. courts even on servers located in Europe)?
- **Governance**: who controls the infrastructure? An American, Chinese or European company?
- **Availability**: in case of a geopolitical crisis or a political decision, can a government block access to your services?
- **Regulatory compliance**: GDPR, TISAX (automotive), SecNumCloud (defense) — certifications specific to Europe.

The big tech companies have been subject to the **CLOUD Act** since 2018. Even if your data is stored in Paris or Frankfurt, Microsoft, Google or AWS can be compelled to hand it over to U.S. courts on simple request, without you knowing.

## European providers in 2026

### OVHcloud

It's the European cloud leader, based in Roubaix, publicly listed since 2021. They bet on proprietary infrastructure (servers, datacenters, network) rather than using standard hardware like the other clouds.

**Kubernetes: OVH MKS (Managed Kubernetes Service)**

```bash
# Creating an MKS cluster via CLI
ovhcli mks cluster create \
  --region gra7 \
  --name my-cluster \
  --version 1.34 \
  --nodepool-name default \
  --nodepool-flavorName b2-7
```

MKS is a fairly classic managed Kubernetes: control plane managed by OVH, worker nodes on you. The strong point: native integration with their ecosystem (Load Balancers, Object Storage, Managed PostgreSQL…) via the `ovh-cloud` plugin, or `openstack` (**a real preference of mine**).

The flavor catalog is broad, from b2-7 (2 vCPU, 7 GB RAM) to b128-384 for heavy workloads. Prices stay significantly below AWS or GCP, often 30 to 50% cheaper for equivalent configurations.

**What I like:**
- Transparent and competitive pricing
- A range of managed services (PostgreSQL, Redis, Kafka, Elasticsearch…)
- Presence in several European countries (France, Germany, Poland, United Kingdom…)
- SecNumCloud certified for certain services

**What can be annoying:**
- MKS lags 1-2 Kubernetes versions behind the latest releases (where's 1.35??)
- The ecosystem is less rich than big tech (no equivalent to Lambda, Fargate, complex CloudFormation…)
- Support can be slow depending on the plan

### Scaleway

Paris too, focused on the public cloud since 2015. Scaleway started with Bare Metal servers before diversifying. Their positioning: a modern cloud with a simple API and attractive prices.

**Kubernetes: Kapsule and Kosmos**

```bash
# Creation via the Scaleway CLI
scw k8s cluster create \
  name=my-cluster \
  version=1.34.0 \
  region=fr-par \
  pool-additional-config.size=L \
  pool-additional-config.node-type=DEV1-L
```

- **Kapsule**: managed Kubernetes cluster, similar to MKS
- **Kosmos**: multi-cloud Kubernetes (aggregates nodes across different infrastructures)

**Serverless Containers: my personal use**

Scaleway also has serverless containers (equivalent to Fargate/Lambda), serverless functions, and a marketplace with prebuilt images.

For personal projects, I'm more on **serverless** than bare metal. Containers is my playground: no server to manage, deploy in one command, scale from zero to infinity. This very portfolio runs on Scaleway Containers, a Docker container serving Hugo, for a few cents a month.

The ideal use case: static sites, lightweight APIs, bots, small services that don't justify a Kubernetes cluster.

**What I like:**
- Simple and well-documented API
- Serverless Containers for personal use (this portfolio runs on it)
- Genuinely handy serverless containers
- Paris and Amsterdam

**What can be annoying:**
- Fewer regions than OVHcloud
- A limited ecosystem compared to big tech (right now Scaleway is working hard and shipping lots of new things)

### And the others?

| Provider | Country | Strengths | Managed K8s |
|---|---|---|---|
| **Hetzner Cloud** | Germany | Unbeatable prices, good EU network | No (you have to fight with kubeadm) |
| **CloudFerro** | Poland | EU-focused (GAIA-X, Copernicus) | Yes (E2K) |
| **Outscale** | France | SecNumCloud certified, government-oriented | No (IaaS) |
| **Contabo** | Germany | Low prices, but opaque about localization | No |

## Technical comparison

For Kubernetes, here's how things line up:

| Criterion | OVHcloud MKS | Scaleway Kapsule | AWS EKS | GCP GKE |
|---|---|---|---|---|
| **Price (2 L nodes)** | ~€80/month | ~€70/month | ~€150/month | ~€140/month |
| **K8s versions** | 1.28 (2-3 month lag) | 1.30 (latest) | Latest | Latest |
| **Multi-region** | 7 countries | 2 regions | Global | Global |
| **Managed DB** | Yes (PostgreSQL, Redis…) | Yes (PostgreSQL, Redis…) | Yes (RDS, ElastiCache…) | Yes (Cloud SQL…) |
| **Object Storage** | S3-compatible | S3-compatible | S3 | GCS |
| **Certifications** | SecNumCloud (partial) | No | SOC2, ISO27001… | SOC2, ISO27001… |
| **Cloud Act** | No | No | Yes | Yes |

*Indicative prices for 2 nodes with 4 vCPU / 8 GB RAM*

The **S3-compatible** storage of OVHcloud and Scaleway matters: you can use `rclone`, `s3cmd`, or any S3 client without being locked to AWS. Storage costs you a fraction of the S3 price.

## The real advantages

Beyond the sovereignty talk, here's what concretely counts:

### 1. Regulatory compliance

If you work in defense, healthcare or the public sector, certifications matter. SecNumCloud (ANSSI) is the very demanding French standard. OVHcloud has several certified services, so does Outscale. It's often a contractual prerequisite.

### 2. Cost

The big tech companies charge "premium" rates justified by their ecosystem. If you just need VMs, Kubernetes and object storage, OVHcloud or Scaleway cut the bill by 2 or 3.

### 3. Administrative simplicity

A single European point of contact, a single GDPR point of contact, a single time zone for support. When you have an incident at 3 a.m., it's not an English-speaking chatbot that's going to bail you out.

### 4. The S3-compatible ecosystem

Object storage is the new standard. Photos, backups, CI artifacts, ML data — everything can go on S3. European offerings are 3 to 5 times cheaper than AWS S3:

- **AWS S3 Standard**: €23/TB/month
- **OVHcloud Object Storage**: €5/TB/month
- **Scaleway Object Storage**: €4/TB/month

For a cluster generating a few GB of logs and backups per day, the difference is significant.

## The real limits

To be honest, it's not all rosy:

### 1. The ecosystem stays limited

No Lambda, no Fargate, no Step Functions. If you need complex serverless or exotic managed services (Amazon Textract, GCP BigQuery…), you'll quickly run out of options.

### 2. The feature lag

MKS ships a new Kubernetes version 2-3 months after upstream. For some, that's acceptable. For others (an immediate CVE), it's a problem.

### 3. Technical debt

If you have old Terraform modules written for AWS, migrating to OVHcloud requires refactoring. The providers aren't 100% compatible.

### 4. The outage risk

OVHcloud has had major incidents (the SBG1 fire in 2021, a hack in 2022). So has Scaleway. But AWS has also had massive outages. The risk exists everywhere.

## When to go with a European provider?

**Yes if:**
- You have compliance constraints (strict GDPR, SecNumCloud, TISAX)
- You have a limited budget and need VMs/K8s/S3
- You have a technical team able to do without AWS/GCP managed services
- Cloud sovereignty is a commercial or regulatory argument

**No if:**
- You need ML/AI (SageMaker, Vertex AI, Bedrock…)
- You have complex serverless workloads
- Your team only knows the AWS/GCP ecosystem
- You have native integrations with services (Auth0, Datadog, etc.)

## Conclusion

European providers aren't an anti-big-tech geek utopia — they've become serious alternatives. OVHcloud and Scaleway cover 80% of a modern DevOps team's needs, at a price that lets you redeploy budget elsewhere.

My personal setup:

- **OVHcloud** for professional projects
- **Scaleway** for experiments and the lab
- **AWS** only when I have no choice

Cloud sovereignty isn't a dogma. It's a trade-off between cost, compliance, simplicity and services. For me, the balance is tilting more and more toward Europe.
