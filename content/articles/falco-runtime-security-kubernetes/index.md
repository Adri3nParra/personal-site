---
title: "Falco : Runtime Security Monitoring on Kubernetes"
date: 2026-04-12
draft: false
summary: "Trivy scanne les images, Kyverno valide les déploiements — mais qu'est-ce qui surveille ce qui se passe une fois les conteneurs lancés ? Falco, le CNCF project, surveille les syscalls en temps réel et alerte dès qu'un comportement anormal est détecté."
tags: ["Kubernetes", "Falco", "Sécurité", "DevOps", "eBPF"]
---

Dans l'article sur [Trivy et Kyverno](/articles/container-security-trivy-kyverno/), j'avais posé le cadre en trois couches : build, admission, runtime. Trivy et Kyverno couvrent les deux premières. Falco, c'est la troisième.

Le problème avec la sécurité Kubernetes, c'est qu'une image propre peut être compromise à l'exécution. Un conteneur qui part en prod sans vulnérabilité connue peut ensuite :
- Télécharger un script malveillant avec `curl`
- Ouvrir un shell interactif dans un conteneur de prod
- Lire des fichiers en dehors de son contexte attendu
- Établir une connexion vers un serveur C2

Trivy ne voit pas ça. Kyverno ne voit pas ça. Falco, si.

## Qu'est-ce que Falco ?

Falco est un outil open source de détection de menaces à l'exécution, originellement créé par Sysdig, maintenant un projet CNCF incubé. Il surveille les appels système (syscalls) du kernel Linux — la couche la plus basse observable sans modifier les applications.

Son principe : définir des **règles** qui décrivent un comportement anormal. Si un conteneur viole une règle, Falco génère une alerte.

Ce n'est pas un WAF, pas un IDS réseau — c'est un moniteur de comportement au niveau kernel.

```
Application
     │
     ▼
Syscalls (open, exec, connect, read…)
     │
     ▼
Falco intercepte et évalue les règles
     │
     ├── Comportement attendu → rien
     └── Violation de règle → alerte
```

## Architecture : eBPF vs kernel module

Falco peut s'insérer dans le kernel de deux façons :

| Mode | Mécanisme | Avantages | Inconvénients |
|---|---|---|---|
| Kernel module | Module `.ko` chargé dans le kernel | Maturité, support large | Kernel rebuild si version change, plus invasif |
| eBPF | Programme sandboxé dans le kernel | Sécurisé, pas de module, GKE/EKS/AKS compatible | Nécessite kernel ≥ 4.14 |
| Modern eBPF | eBPF CO-RE (Compile Once, Run Everywhere) | Pas de headers kernel requis | Kernel ≥ 5.8 requis |

En 2026, le mode **Modern eBPF** est recommandé. Les clouds majeurs l'exposent sans configuration spéciale.

```
┌─────────────────────────────────┐
│          Userspace              │
│                                 │
│   Falco daemon                  │
│   (rules engine + alerting)     │
└────────────────┬────────────────┘
                 │ events
┌────────────────▼────────────────┐
│          Kernel space           │
│                                 │
│   eBPF probe (Modern eBPF)      │
│   intercepte les syscalls       │
└─────────────────────────────────┘
```

## Installation via Helm

```bash
helm repo add falcosecurity https://falcosecurity.github.io/charts
helm repo update

helm install falco falcosecurity/falco \
  --namespace falco \
  --create-namespace \
  --set driver.kind=modern_ebpf \
  --set falcosidekick.enabled=true \
  --set falcosidekick.webui.enabled=true
```

Vérifier que les pods sont up :

```bash
kubectl get pods -n falco
# NAME                              READY   STATUS
# falco-xxxxx                       2/2     Running
# falco-falcosidekick-xxxxx         1/1     Running
# falco-falcosidekick-ui-xxxxx      1/1     Running
```

Le DaemonSet Falco tourne sur chaque nœud — c'est un prérequis pour intercepter tous les syscalls du cluster.

### Vérifier que Falco détecte

```bash
# Dans un namespace de test, lance un shell dans un conteneur
kubectl run test-pod --image=ubuntu --rm -it -- bash

# Dans le pod, essaie quelque chose de suspect
cat /etc/shadow
```

Côté Falco :

```bash
kubectl logs -n falco -l app.kubernetes.io/name=falco -f | grep Warning
# 09:14:32.123 Warning Sensitive file opened for reading...
#   (user=root command=cat /etc/shadow container=test-pod)
```

## Les règles par défaut

Falco est livré avec ~100 règles prêtes à l'emploi. Les plus utiles en production :

| Règle | Déclencheur | Priorité |
|---|---|---|
| Terminal shell in container | `bash`/`sh` interactif dans un conteneur | WARNING |
| Sensitive file read | Lecture de `/etc/shadow`, `/etc/passwd` | WARNING |
| Write below root | Écriture hors des chemins attendus | ERROR |
| Unexpected network connection | Connexion réseau non prévue | NOTICE |
| Outbound connection to C2 | IPs connues de serveurs C2 | CRITICAL |
| Container drift detected | Nouveau exécutable créé dans un conteneur | CRITICAL |
| Read sensitive file untrusted | Lecture de secrets/tokens K8s | WARNING |

Ces règles couvrent les patterns d'attaque les plus communs : escalade de privilèges, exfiltration, lateral movement.

### Lister toutes les règles actives

```bash
kubectl exec -n falco daemonset/falco -- falco --list
```

## Anatomie d'une règle

Une règle Falco ressemble à ça :

```yaml
- rule: Shell spawned in container
  desc: Un shell interactif a été ouvert dans un conteneur. Potentielle intrusion.
  condition: >
    spawned_process
    and container
    and shell_procs
    and proc.tty != 0
  output: >
    Shell interactif détecté (user=%user.name cmd=%proc.cmdline
    container=%container.name image=%container.image.repository:%container.image.tag
    k8s_pod=%k8s.pod.name k8s_ns=%k8s.ns.name)
  priority: WARNING
  tags: [shell, intrusion]
```

Les éléments clés :
- **`condition`** — filtre en langage Falco (proche de SQL)
- **`output`** — message d'alerte avec variables enrichies
- **`priority`** — `DEBUG`, `INFO`, `NOTICE`, `WARNING`, `ERROR`, `CRITICAL`
- **`tags`** — pour filtrer et router les alertes

### Les macros et les listes

Falco est composable via des macros et des listes réutilisables :

```yaml
# Liste de shells connus
- list: shell_binaries
  items: [bash, sh, zsh, fish, ksh]

# Macro réutilisable
- macro: shell_procs
  condition: proc.name in (shell_binaries)

# Macro container (exclut le host)
- macro: container
  condition: container.id != host

# Macro spawned_process
- macro: spawned_process
  condition: evt.type = execve and evt.dir = <
```

Ces macros sont définies dans les règles par défaut et peuvent être étendues.

## Écrire des règles personnalisées

### Cas 1 : détecter une connexion vers une IP externe inattendue

Ton service ne devrait parler qu'à la base de données et à une API interne. Tout le reste est suspect :

```yaml
- list: allowed_outbound_destinations
  items:
    - 10.0.0.0/8     # réseau interne
    - 192.168.0.0/16 # réseau local

- rule: Unexpected outbound connection
  desc: Connexion réseau vers une destination non autorisée
  condition: >
    outbound
    and container
    and not fd.net in (allowed_outbound_destinations)
    and container.image.repository = "mon-org/mon-api"
  output: >
    Connexion inattendue depuis le conteneur (dest=%fd.rip:%fd.rport
    container=%container.name pod=%k8s.pod.name ns=%k8s.ns.name)
  priority: WARNING
  tags: [network, exfiltration]
```

### Cas 2 : surveiller les accès aux secrets Kubernetes

Les tokens ServiceAccount sont montés dans `/var/run/secrets/kubernetes.io/`. Un conteneur qui lit son token directement est souvent suspect (sauf si c'est prévu) :

```yaml
- macro: k8s_token_read
  condition: >
    open_read
    and fd.name startswith /var/run/secrets/kubernetes.io/serviceaccount

- rule: K8s serviceaccount token read
  desc: Un processus lit le token ServiceAccount
  condition: >
    k8s_token_read
    and container
    and not proc.name in (allowed_k8s_clients)
  output: >
    Token K8s lu (user=%user.name cmd=%proc.cmdline
    file=%fd.name container=%container.name pod=%k8s.pod.name)
  priority: WARNING
  tags: [k8s, credentials]
```

### Cas 3 : détecter l'exécution de `curl` ou `wget`

Dans un conteneur de prod, personne n'a besoin de télécharger quoi que ce soit :

```yaml
- list: download_tools
  items: [curl, wget, nc, netcat, ncat]

- rule: Download tool executed in container
  desc: Un outil de téléchargement a été exécuté dans un conteneur
  condition: >
    spawned_process
    and container
    and proc.name in (download_tools)
  output: >
    Outil de téléchargement détecté (cmd=%proc.cmdline
    container=%container.name pod=%k8s.pod.name ns=%k8s.ns.name)
  priority: ERROR
  tags: [malware, download]
```

### Déployer des règles personnalisées via Helm

```yaml
# values-falco.yaml
customRules:
  custom-rules.yaml: |-
    - list: allowed_outbound_destinations
      items:
        - 10.0.0.0/8

    - rule: Unexpected outbound connection
      desc: Connexion réseau vers une destination non autorisée
      condition: >
        outbound and container
        and not fd.net in (allowed_outbound_destinations)
      output: >
        Connexion inattendue (dest=%fd.rip:%fd.rport pod=%k8s.pod.name)
      priority: WARNING
      tags: [network]
```

```bash
helm upgrade falco falcosecurity/falco \
  --namespace falco \
  --values values-falco.yaml
```

## Falcosidekick — router les alertes

Falco génère des alertes dans ses logs. Sans Falcosidekick, tu ne verras rien en temps réel. Falcosidekick est un proxy d'alerting qui supporte ~50 destinations.

```
Falco ──► Falcosidekick ──► Slack
                       ├──► PagerDuty
                       ├──► Prometheus (Alertmanager)
                       ├──► Elasticsearch
                       ├──► Webhook générique
                       └──► Falco UI (dashboard web)
```

### Configuration Slack

```yaml
# values-falco.yaml
falcosidekick:
  enabled: true
  config:
    slack:
      webhookurl: "https://hooks.slack.com/services/T.../B.../..."
      minimumpriority: warning  # Ignorer DEBUG/INFO/NOTICE
      messageformat: >
        *[{priority}]* {rule} dans `{output_fields.k8s.ns.name}/{output_fields.k8s.pod.name}`
        _{output}_
```

```bash
helm upgrade falco falcosecurity/falco \
  --namespace falco \
  --values values-falco.yaml
```

Les alertes Slack incluent : rule, priority, timestamp, pod name, namespace, image.

### Intégration Prometheus + Alertmanager

Falcosidekick expose des métriques Prometheus et peut envoyer vers Alertmanager :

```yaml
falcosidekick:
  config:
    prometheusalertmanager:
      hostport: "http://alertmanager.monitoring:9093"
      minimumpriority: warning
```

Ou via les métriques exposées :

```yaml
falcosidekick:
  config:
    prometheus:
      extralabels: "cluster=prod,team=platform"
```

Métriques disponibles :
- `falcosidekick_inputs_total` — événements reçus par priorité
- `falcosidekick_outputs_total` — alertes envoyées par destination

### Falco UI

Falcosidekick UI est un dashboard web pour visualiser les alertes en temps réel :

```bash
# Port-forward vers le UI
kubectl port-forward -n falco svc/falco-falcosidekick-ui 2802:2802
# Ouvrir http://localhost:2802
```

Le dashboard affiche un historique des événements, filtrable par priorité, règle, namespace, et pod.

## Scénarios de détection concrets

### Détection d'un reverse shell

Un attaquant qui obtient l'exécution de code dans un conteneur ouvre souvent un reverse shell. Falco détecte ça via plusieurs règles combinées :

1. `Shell spawned in container` — un shell est ouvert
2. `Unexpected outbound connection` — connexion sortante vers une IP externe
3. `Network activity from non-expected process` — processus shell qui fait du réseau

Les trois alertes en moins d'une seconde, c'est un signal fort.

### Détection de container drift

Container drift = un nouveau binaire est créé ou modifié dans un conteneur en cours d'exécution. Ce n'est jamais censé arriver dans une image immutable :

```bash
# Règle intégrée : Container Drift Detected
# Se déclenche si un nouveau fichier exécutable est créé dans un conteneur
```

Si ton image est immutable (ce qu'elle devrait être), et qu'un exécutable apparaît, c'est une intrusion.

### Détection de lecture de credentials

```bash
# /var/run/secrets/ — tokens K8s
# /root/.kube/config — kubeconfig
# /etc/kubernetes/ — certs cluster
# ~/.aws/credentials — AWS
```

Falco surveille ces chemins par défaut. Un conteneur API qui lit `/etc/kubernetes/admin.conf`, c'est anormal.

## Ajuster les faux positifs

Les règles par défaut génèrent des faux positifs sur certains workloads légitimes. Pour les gérer :

### Exclure des containers connus

```yaml
- rule: Terminal shell in container
  # Override de la règle existante pour exclure les pods de debug
  exceptions:
    - name: known_debug_pods
      fields: [k8s.pod.name]
      comps: [startswith]
      values:
        - [debug-]
        - [toolbox-]
```

### Exclure par namespace

```yaml
- macro: not_monitoring_ns
  condition: >
    k8s.ns.name != "monitoring"
    and k8s.ns.name != "kube-system"
    and k8s.ns.name != "falco"
```

### Ajuster la priorité minimale

Pour réduire le bruit, ne traiter que les WARNING et au-dessus :

```yaml
# values-falco.yaml
falco:
  jsonOutput: true
  logLevel: warning
  priority: warning  # Ne loguer que WARNING et au-dessus
```

## Limites

### Ce que Falco ne fait pas

- **Ne bloque pas** — Falco détecte et alerte, il n'arrête pas le processus. Pour bloquer, combine avec un admission controller ou un mécanisme d'isolation.
- **Pas de forensics réseau complet** — Falco surveille les connexions (IP, port) mais pas le contenu des paquets.
- **Ne remplace pas un SIEM** — Falco génère des événements, mais l'agrégation et la corrélation sur le long terme, c'est Elasticsearch/Splunk/Loki.

### Overhead kernel

eBPF a un coût CPU (~1-3% par nœud selon la charge de syscalls). Sur des nœuds très actifs (beaucoup d'I/O ou de fork), surveille les métriques du daemon Falco.

```bash
kubectl top pod -n falco
# NAME            CPU(cores)   MEMORY(bytes)
# falco-xxxxx     42m          128Mi
```

## Bonnes pratiques

### 1. Commencer en mode observation

Ne jamais déployer Falco en prod et agir sur chaque alerte sans avoir calibré les règles. Passe deux semaines en mode observation, note les faux positifs, et adapte.

### 2. Versionner les règles personnalisées

Tes règles sont du code. Git + PR + review avant de déployer en prod.

```
rules/
├── network-rules.yaml
├── credential-access.yaml
└── container-integrity.yaml
```

### 3. Enrichir les alertes

Falco peut envoyer le contexte Kubernetes dans chaque alerte. Active l'enrichissement K8s metadata :

```yaml
falco:
  plugins:
    - name: k8saudit
      library_path: libk8saudit.so
```

Tes alertes incluront automatiquement : pod, namespace, image, labels, annotations.

### 4. Coupler avec les audit logs Kubernetes

Falco peut aussi ingérer les K8s Audit Logs (API server) via le plugin `k8saudit`. Ça permet de détecter :
- Création de ClusterRoleBinding suspects
- Accès RBAC anormaux
- Requêtes vers des ressources sensibles (secrets, configmaps)

```yaml
# values-falco.yaml
falco:
  plugins:
    - name: k8saudit
      library_path: libk8saudit.so
      open_params: "http://0.0.0.0:9765/k8s-audit"
```

## Conclusion

Falco complète le triangle de sécurité Kubernetes :

| Couche | Outil | Moment |
|---|---|---|
| Build | Trivy | Image scan avant push |
| Admission | Kyverno | Validation au déploiement |
| Runtime | Falco | Surveillance en continu |

Pas de ces trois couches n'est suffisante seule. Une image propre peut être compromise. Un déploiement conforme peut dériver. Falco est la dernière ligne de défense — il détecte ce qui échappe aux deux premières.

L'overhead est faible (eBPF), le déploiement est simple (Helm en 5 minutes), et les règles par défaut couvrent l'essentiel. Le vrai travail, c'est le calibrage : réduire les faux positifs, écrire les règles métier, brancher les alertes sur ce que ton équipe surveille déjà.
