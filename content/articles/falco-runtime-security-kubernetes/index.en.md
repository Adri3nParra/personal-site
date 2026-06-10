---
title: "Falco: Runtime Security Monitoring on Kubernetes"
date: 2026-04-12
draft: false
summary: "Trivy scans images, Kyverno validates deployments, but what watches over what happens once the containers are running? Falco, the CNCF project, monitors syscalls in real time and alerts as soon as abnormal behavior is detected."
tags: ["Kubernetes", "Falco", "Security", "DevOps", "eBPF"]
---

In the article on [Trivy and Kyverno](/en/articles/container-security-trivy-kyverno/), I laid out the framework in three layers: build, admission, runtime. Trivy and Kyverno cover the first two. Falco is the third.

The problem with Kubernetes security is that a clean image can be compromised at runtime. A container that ships to production with no known vulnerability can then:
- Download a malicious script with `curl`
- Open an interactive shell in a production container
- Read files outside its expected context
- Establish a connection to a C2 server

Trivy doesn't see that. Kyverno doesn't see that. Falco does.

## What is Falco?

Falco is an open source runtime threat detection tool, originally created by Sysdig, now an incubating CNCF project. It monitors the Linux kernel's system calls (syscalls), the lowest observable layer without modifying applications.

Its principle: define **rules** that describe abnormal behavior. If a container violates a rule, Falco generates an alert.

It's not a WAF, not a network IDS — it's a behavior monitor at the kernel level.

```
Application
     │
     ▼
Syscalls (open, exec, connect, read…)
     │
     ▼
Falco intercepts and evaluates the rules
     │
     ├── Expected behavior → nothing
     └── Rule violation → alert
```

## Architecture: eBPF vs kernel module

Falco can insert itself into the kernel in two ways:

| Mode | Mechanism | Advantages | Disadvantages |
|---|---|---|---|
| Kernel module | `.ko` module loaded into the kernel | Maturity, broad support | Kernel rebuild if version changes, more invasive |
| eBPF | Sandboxed program in the kernel | Secure, no module, GKE/EKS/AKS compatible | Requires kernel ≥ 4.14 |
| Modern eBPF | eBPF CO-RE (Compile Once, Run Everywhere) | No kernel headers required | Kernel ≥ 5.8 required |

In 2026, the **Modern eBPF** mode is recommended. The major clouds expose it without special configuration.

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
│   intercepts syscalls           │
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

Check that the pods are up:

```bash
kubectl get pods -n falco
# NAME                              READY   STATUS
# falco-xxxxx                       2/2     Running
# falco-falcosidekick-xxxxx         1/1     Running
# falco-falcosidekick-ui-xxxxx      1/1     Running
```

The Falco DaemonSet runs on every node — that's a prerequisite for intercepting all the cluster's syscalls.

### Checking that Falco detects

```bash
# In a test namespace, launch a shell in a container
kubectl run test-pod --image=ubuntu --rm -it -- bash

# In the pod, try something suspicious
cat /etc/shadow
```

On the Falco side:

```bash
kubectl logs -n falco -l app.kubernetes.io/name=falco -f | grep Warning
# 09:14:32.123 Warning Sensitive file opened for reading...
#   (user=root command=cat /etc/shadow container=test-pod)
```

## The default rules

Falco ships with ~100 ready-to-use rules. The most useful in production:

| Rule | Trigger | Priority |
|---|---|---|
| Terminal shell in container | interactive `bash`/`sh` in a container | WARNING |
| Sensitive file read | Reading `/etc/shadow`, `/etc/passwd` | WARNING |
| Write below root | Writing outside expected paths | ERROR |
| Unexpected network connection | Unplanned network connection | NOTICE |
| Outbound connection to C2 | Known C2 server IPs | CRITICAL |
| Container drift detected | New executable created in a container | CRITICAL |
| Read sensitive file untrusted | Reading K8s secrets/tokens | WARNING |

These rules cover the most common attack patterns: privilege escalation, exfiltration, lateral movement.

### List all active rules

```bash
kubectl exec -n falco daemonset/falco -- falco --list
```

## Anatomy of a rule

A Falco rule looks like this:

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

The key elements:
- **`condition`**: a filter in the Falco language (close to SQL)
- **`output`**: the alert message with enriched variables
- **`priority`**: `DEBUG`, `INFO`, `NOTICE`, `WARNING`, `ERROR`, `CRITICAL`
- **`tags`**: to filter and route alerts

### Macros and lists

Falco is composable via reusable macros and lists:

```yaml
# List of known shells
- list: shell_binaries
  items: [bash, sh, zsh, fish, ksh]

# Reusable macro
- macro: shell_procs
  condition: proc.name in (shell_binaries)

# Container macro (excludes the host)
- macro: container
  condition: container.id != host

# spawned_process macro
- macro: spawned_process
  condition: evt.type = execve and evt.dir = <
```

These macros are defined in the default rules and can be extended.

## Writing custom rules

### Case 1: detecting a connection to an unexpected external IP

Your service should only talk to the database and an internal API. Everything else is suspicious:

```yaml
- list: allowed_outbound_destinations
  items:
    - 10.0.0.0/8     # internal network
    - 192.168.0.0/16 # local network

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

### Case 2: monitoring access to Kubernetes secrets

ServiceAccount tokens are mounted in `/var/run/secrets/kubernetes.io/`. A container that reads its token directly is often suspicious (unless it's intended):

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

### Case 3: detecting the execution of `curl` or `wget`

In a production container, nobody needs to download anything:

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

### Deploying custom rules via Helm

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

## Falcosidekick: routing alerts

Falco generates alerts in its logs. Without Falcosidekick, you won't see anything in real time. Falcosidekick is an alerting proxy that supports ~50 destinations.

```
Falco ──► Falcosidekick ──► Slack
                       ├──► PagerDuty
                       ├──► Prometheus (Alertmanager)
                       ├──► Elasticsearch
                       ├──► Generic webhook
                       └──► Falco UI (web dashboard)
```

### Slack configuration

```yaml
# values-falco.yaml
falcosidekick:
  enabled: true
  config:
    slack:
      webhookurl: "https://hooks.slack.com/services/T.../B.../..."
      minimumpriority: warning  # Ignore DEBUG/INFO/NOTICE
      messageformat: >
        *[{priority}]* {rule} dans `{output_fields.k8s.ns.name}/{output_fields.k8s.pod.name}`
        _{output}_
```

```bash
helm upgrade falco falcosecurity/falco \
  --namespace falco \
  --values values-falco.yaml
```

The Slack alerts include: rule, priority, timestamp, pod name, namespace, image.

### Prometheus + Alertmanager integration

Falcosidekick exposes Prometheus metrics and can send to Alertmanager:

```yaml
falcosidekick:
  config:
    prometheusalertmanager:
      hostport: "http://alertmanager.monitoring:9093"
      minimumpriority: warning
```

Or via the exposed metrics:

```yaml
falcosidekick:
  config:
    prometheus:
      extralabels: "cluster=prod,team=platform"
```

Available metrics:
- `falcosidekick_inputs_total` — events received by priority
- `falcosidekick_outputs_total` — alerts sent by destination

### Falco UI

Falcosidekick UI is a web dashboard to visualize alerts in real time:

```bash
# Port-forward to the UI
kubectl port-forward -n falco svc/falco-falcosidekick-ui 2802:2802
# Open http://localhost:2802
```

The dashboard shows a history of events, filterable by priority, rule, namespace, and pod.

## Concrete detection scenarios

### Detecting a reverse shell

An attacker who gains code execution in a container often opens a reverse shell. Falco detects this via several combined rules:

1. `Shell spawned in container` — a shell is opened
2. `Unexpected outbound connection` — an outbound connection to an external IP
3. `Network activity from non-expected process` — a shell process doing networking

All three alerts in less than a second is a strong signal.

### Detecting container drift

Container drift = a new binary is created or modified in a running container. This is never supposed to happen in an immutable image:

```bash
# Built-in rule: Container Drift Detected
# Triggers if a new executable file is created in a container
```

If your image is immutable (which it should be), and an executable appears, it's an intrusion.

### Detecting credential reads

```bash
# /var/run/secrets/ : K8s tokens
# /root/.kube/config : kubeconfig
# /etc/kubernetes/ : cluster certs
# ~/.aws/credentials : AWS
```

Falco monitors these paths by default. An API container reading `/etc/kubernetes/admin.conf` is abnormal.

## Tuning false positives

The default rules generate false positives on some legitimate workloads. To manage them:

### Exclude known containers

```yaml
- rule: Terminal shell in container
  # Override the existing rule to exclude debug pods
  exceptions:
    - name: known_debug_pods
      fields: [k8s.pod.name]
      comps: [startswith]
      values:
        - [debug-]
        - [toolbox-]
```

### Exclude by namespace

```yaml
- macro: not_monitoring_ns
  condition: >
    k8s.ns.name != "monitoring"
    and k8s.ns.name != "kube-system"
    and k8s.ns.name != "falco"
```

### Adjust the minimum priority

To reduce noise, only handle WARNING and above:

```yaml
# values-falco.yaml
falco:
  jsonOutput: true
  logLevel: warning
  priority: warning  # Only log WARNING and above
```

## Limits

### What Falco doesn't do

- **Doesn't block**: Falco detects and alerts, it doesn't stop the process. To block, combine it with an admission controller or an isolation mechanism.
- **No complete network forensics**: Falco monitors connections (IP, port) but not packet content.
- **Doesn't replace a SIEM**: Falco generates events, but long-term aggregation and correlation is the job of Elasticsearch/Splunk/Loki.

### Kernel overhead

eBPF has a CPU cost (~1-3% per node depending on the syscall load). On very active nodes (lots of I/O or forks), watch the Falco daemon's metrics.

```bash
kubectl top pod -n falco
# NAME            CPU(cores)   MEMORY(bytes)
# falco-xxxxx     42m          128Mi
```

## Best practices

### 1. Start in observation mode

Never deploy Falco in production and act on every alert without having calibrated the rules. Spend two weeks in observation mode, note the false positives, and adapt.

### 2. Version custom rules

Your rules are code. Git + PR + review before deploying to production.

```
rules/
├── network-rules.yaml
├── credential-access.yaml
└── container-integrity.yaml
```

### 3. Enrich alerts

Falco can send Kubernetes context in each alert. Enable K8s metadata enrichment:

```yaml
falco:
  plugins:
    - name: k8saudit
      library_path: libk8saudit.so
```

Your alerts will automatically include: pod, namespace, image, labels, annotations.

### 4. Pair with Kubernetes audit logs

Falco can also ingest the K8s Audit Logs (API server) via the `k8saudit` plugin. This lets you detect:
- Creation of suspicious ClusterRoleBindings
- Abnormal RBAC access
- Requests to sensitive resources (secrets, configmaps)

```yaml
# values-falco.yaml
falco:
  plugins:
    - name: k8saudit
      library_path: libk8saudit.so
      open_params: "http://0.0.0.0:9765/k8s-audit"
```

## Conclusion

Falco completes the Kubernetes security triangle:

| Layer | Tool | Moment |
|---|---|---|
| Build | Trivy | Image scan before push |
| Admission | Kyverno | Validation at deployment |
| Runtime | Falco | Continuous monitoring |

None of these three layers is sufficient on its own. A clean image can be compromised. A compliant deployment can drift. Falco is the last line of defense — it detects what slips past the first two.

The overhead is low (eBPF), the deployment is simple (Helm in 5 minutes), and the default rules cover the essentials. The real work is the calibration: reducing false positives, writing the business rules, wiring the alerts into what your team already monitors.
