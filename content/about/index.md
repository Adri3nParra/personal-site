---
title: "À propos"
draft: false
---

Platform Engineer avec **6 ans d'expérience**, spécialisé dans l'architecture, l'industrialisation et la sécurisation de **plateformes Kubernetes sur des infrastructures cloud et hybrides**.

Je suis quelqu'un de très curieux, je teste régulièrement de nouveaux outils, je lis des annonces de releases comme d'autres lisent les actualités, et j'ai souvent un POC qui tourne en local sur un truc qui m'a intrigué la semaine d'avant. Cette curiosité n'est pas un à-côté : c'est ce qui fait que je comprends rapidement un nouvel environnement, que je propose des solutions auxquelles l'équipe n'avait pas pensé, et que je reste à jour dans un écosystème qui évolue vite.

Le reste du temps, j'aime les environnements simples, fiables et proches de la production. Pragmatique, je privilégie les solutions robustes et reproductibles plutôt que la complexité pour la complexité. J'aime particulièrement partir d'un besoin, poser les contraintes de réseau, sécurité, résilience, données et exploitation, puis construire une architecture cloud cohérente. Mon approche s'appuie sur Linux, l'Infrastructure as Code, GitOps et l'observabilité pour rendre ces plateformes compréhensibles et exploitables par toute l'équipe.

Certifié **CKA**, **CKAD**, **CKS**, **KCNA** et **KCSA**, je suis également **Kubestronaut CNCF**.

## Compétences techniques

**Cloud & Infrastructure as Code**
AWS · OVHcloud · Scaleway · OpenStack · GCP/GKE · OpenTofu/Terraform · Terragrunt · S3 · IAM · Réseaux cloud

**Kubernetes & GitOps**
Kubernetes · Helm · Argo CD · Argo Rollouts · Traefik · Gateway API · Docker Swarm

**CI/CD & Supply Chain**
GitLab CI/CD · Jenkins · Harbor · Nexus · SonarQube · Dependency-Track · Cosign

**Sécurité**
Kyverno · Falco · Trivy · CrowdSec · External Secrets · Sealed Secrets · Gitleaks · Keycloak

**Observabilité**
Prometheus · Grafana · Loki · Alloy · Alertmanager · Zabbix

**Réseau & Ingress**
Traefik · Cert-Manager · Calico · NetworkPolicy · DNS · TLS · HTTP/S

**Systèmes & BDD**
Linux (Debian / Ubuntu / RHEL) · PostgreSQL · MySQL · Progress OpenEdge · Bash · PowerShell

## Formation

**Master en Informatique** — EPSI, Nantes · 2020–2022

**Licence professionnelle** — EPSI, Nantes · 2019–2020

**BTS SIO** — EPSI, Nantes · 2017–2019

**Bac STI2D, Option SIN** — La Joliverie, Saint-Sébastien-sur-Loire · 2016–2017

## Langues

Français — Natif · Anglais — B2 · Espagnol — B1

## Certifications

<div style="display: flex; gap: 2rem; flex-wrap: wrap; margin-bottom: 1rem;">

  <div style="text-align: center; max-width: 160px;">
    <a href="https://www.credly.com/users/adrien-parra.05aa4654" target="_blank" rel="noopener">
      <img src="/kubernetes-cka-color.png" alt="CKA - Certified Kubernetes Administrator" width="140" />
    </a>
    <p style="margin-top: 0.5rem; font-size: 0.85rem;"><strong>CKA</strong> - Mars 2026</p>
  </div>
  <div style="text-align: center; max-width: 160px;">
    <a href="https://www.credly.com/users/adrien-parra.05aa4654" target="_blank" rel="noopener">
      <img src="/kubernetes-ckad-color.png" alt="CKAD - Certified Kubernetes Application Developer" width="140" />
    </a>
    <p style="margin-top: 0.5rem; font-size: 0.85rem;"><strong>CKAD</strong> - Avril 2026</p>
  </div>
  <div style="text-align: center; max-width: 160px;">
    <a href="https://www.credly.com/users/adrien-parra.05aa4654" target="_blank" rel="noopener">
      <img src="/kubernetes-security-specialist-color.png" alt="CKS - Certified Kubernetes Security Specialist" width="140" />
    </a>
    <p style="margin-top: 2.4rem; font-size: 0.85rem;"><strong>CKS</strong> - Mai 2026</p>
  </div>
  <div style="text-align: center; max-width: 160px;">
    <a href="https://www.credly.com/users/adrien-parra.05aa4654" target="_blank" rel="noopener">
      <img src="/kubernetes-kcna-color.png" alt="KCNA - Kubernetes and Cloud Native Associate" width="140" />
    </a>
    <p style="margin-top: 0.5rem; font-size: 0.85rem;"><strong>KCNA</strong> - Avril 2026</p>
  </div>
  <div style="text-align: center; max-width: 160px;">
    <a href="https://www.credly.com/users/adrien-parra.05aa4654" target="_blank" rel="noopener">
      <img src="/kubernetes-kcsa-color.png" alt="KCSA - Kubernetes and Cloud Native Security Associate" width="140" />
    </a>
    <p style="margin-top: 0.5rem; font-size: 0.85rem;"><strong>KCSA</strong> - Mai 2026</p>
  </div>
  <div style="text-align: center; max-width: 160px;">
    <a href="https://www.credly.com/users/adrien-parra.05aa4654" target="_blank" rel="noopener">
      <img src="/kubestronaut-stacked-color.png" alt="Kubestronaut" width="140" />
    </a>
    <p style="margin-top: 3.5rem; font-size: 0.85rem;"><strong>Kubestronaut</strong> - Mai 2026</p>
  </div>
</div>

## Environnement de travail

Je travaille **100%** Linux (**et j'y tiens énormément**) - **Ubuntu 24.04** au quotidien, Windows uniquement pour le jeu. Ça fait une vraie différence : les outils, les réflexes et les environnements sont cohérents du poste à la prod.

Pour le développement et la veille, je tourne un cluster **K3S** local qui me permet de tester des charts Helm, des manifests ou des nouvelles technos avant de les approcher en production. J'utilise **nerdctl** pour le build et la manipulation d'images — CLI compatible Docker mais par-dessus containerd, sans démon.

L'éditeur c'est **VSCode**, le terminal c'est Bash, et les outils du quotidien sont ceux qu'on retrouve dans n'importe quel environnement Platform sérieux : kubectl, Helm, OpenTofu, git.

## Open source

J'ai créé un **chart Helm complet pour [transfer.sh](/articles/transfersh-helm-chart/)**, avec plusieurs backends de stockage, Ingress et Gateway API, HPA, NetworkPolicy et options de sécurité. La contribution a été proposée au projet upstream.

Je contribue également à des charts que j'utilise réellement, notamment autour de l'intégration de PostgreSQL. L'open source est pour moi une façon très concrète de tester mes pratiques face à d'autres contraintes et d'améliorer les outils que j'exploite.

## En dehors du travail

Open Source & Linux 🐧 · Moto 🏍️ · Raid sur WoW 🛡️
