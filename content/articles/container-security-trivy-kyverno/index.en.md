---
title: "Container Security: Trivy and Kyverno in production"
date: 2026-03-28
draft: false
summary: "Securing a production Kubernetes cluster isn't just a networking question. Vulnerability scanning, admission policies, least privilege: a hands-on review with Trivy and Kyverno."
tags: ["Kubernetes", "Security", "Trivy", "Kyverno", "DevOps"]
---

A production Kubernetes cluster means dozens of Docker images running, hundreds of dependencies, and potentially known vulnerabilities. Leaving that unmonitored is waiting for the incident.

Two complementary tools cover most of the needs: **Trivy** for scanning and detection, **Kyverno** for admission policies. The first shows you the problems, the second blocks them.

## Trivy: the vulnerability scanner

Trivy is open source (by Aqua Security), lightweight, and scans everything: Docker images, filesystem files, Kubernetes config, IaC (Terraform, CloudFormation)…

### Installation

```bash
# Via Helm on the cluster
helm repo add aquasecurity https://aquasecurity.github.io/helm-charts
helm install trivy aquasecurity/trivy \
  --namespace trivy \
  --create-namespace
```

### Scanning an image

```bash
# Basic scan
trivy image nginx:latest

# JSON format for automation
trivy image --format json --output report.json nginx:latest
```

The output:
```
nginx:latest (debian 12.8)
==========================
Total: 47 (unknown: 0, low: 12, medium: 23, high: 12, critical: 0)

Library                Type  Vulnerability    Severity  Status
--------------------- ----- --------------- --------- ------
libssl3               pkg   CVE-2024-12797   HIGH      Fixed
curl                  pkg   CVE-2024-12345  MEDIUM    Fixed
...
```

Trivy maintains an up-to-date vulnerability database: NVD, GitHub Advisories, Linux distributions, Aqua databases, and even the CVEs of the major clouds.

### CI/CD scanning

In a GitLab pipeline:

```yaml
# .gitlab-ci.yml
trivy-scan:
  stage: security
  image:
    name: aquasec/trivy:latest
    entrypoint: [""]
  script:
    - trivy image --exit-code 1 --severity HIGH,CRITICAL $IMAGE_URL
  variables:
    IMAGE_URL: $CI_REGISTRY_IMAGE:$CI_COMMIT_SHA
  allow_failure: true  # Or not, depending on your policy
```

`--exit-code 1` fails the job if HIGH/CRITICAL vulnerabilities are found. `allow_failure: true` keeps the build working while still alerting.

### Kubernetes Admission Controller scanning

Trivy can also block deployments directly in Kubernetes via an admission controller:

```bash
# Installation via the Trivy Operator
kubectl apply -f https://raw.githubusercontent.com/aquasecurity/trivy-operator/main/deploy/static/trivy-operator.yaml
```

The operator automatically creates vulnerability reports for each deployed pod:

```bash
kubectl get vulnerabilityreports
NAME                REPOSITORY          AGE
pod-replicaset-xxx  mon-app:latest     2d
```

### Trivy's limits

Trivy detects known vulnerabilities in packages, but:
- **Doesn't block execution** without an admission controller
- **Doesn't control the runtime** (the container's behavior once started)
- **Possible false positives** on vulnerabilities not exploitable in your context

For the runtime, you need Falco. For deployment control, you need Kyverno.

## Kyverno: admission policies

Kyverno is a policy engine for Kubernetes. Unlike OPA/Gatekeeper, which uses a custom DSL (Rego), Kyverno uses Kubernetes manifests: if you can write YAML, you can write a policy.

### Installation

```bash
# Via Helm
helm repo add kyverno https://kyverno.github.io/kyverno
helm install kyverno kyverno/kyverno \
  --namespace kyverno \
  --create-namespace \
  --values - <<EOF
backgroundController:
  replicas: 1
reportsController:
  replicas: 1
EOF
```

Verify:

```bash
kubectl get pods -n kyverno
NAME                          READY   STATUS
kyverno-admission-controller   1/1     Running
kyverno-reports-controller-0   1/1     Running
kyverno-background-controller  1/1     Running
```

## Writing a policy

A Kyverno policy is a `ClusterPolicy` or a `Policy` (namespace-scoped). Example: disallow containers running as root:

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: disallow-root-user
spec:
  validationFailureAction: Enforce  # Blocks instead of just alerting - Personally on the dev cluster -> Audit
  rules:
    - name: validate-runAsNonRoot
      match:
        resources:
          kinds:
            - Pod
      validate:
        message: "Les conteneurs ne doivent pas tourner en root."
        pattern:
          spec:
            containers:
              - (runAsNonRoot): true
            initContainers:
              - (runAsNonRoot): true
```

`(runAsNonRoot): true` — the parentheses mean "this value must exist and be true." Without parentheses, it just checks for presence.

### Validate before applying

Policies have three modes:

| Mode | Behavior |
|---|---|
| `Audit` | Logs violations, doesn't prevent the deployment |
| `Enforce` | Blocks the deployment on violation |

```yaml
spec:
  validationFailureAction: Audit  # To test before Enforce
```

An `Audit` lets you verify that your policy doesn't generate false positives before moving to production.

## Useful policies in production

### 1. Disallow latest tags

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-image-tag
spec:
  validationFailureAction: Enforce
  rules:
    - name: require-image-tag
      match:
        resources:
          kinds:
            - Pod
      validate:
        message: "Chaque image doit avoir un tag explicite (pas latest)."
        pattern:
          spec:
            containers:
              - image: "!*:latest"
```

The `!` means "must not match the pattern." `*:latest` disallows the `latest` tag.

### 2. Require resource limits

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-resources
spec:
  validationFailureAction: Enforce
  rules:
    - name: require-limits
      match:
        resources:
          kinds:
            - Pod
      validate:
        message: "Les conteneurs doivent avoir des resource limits."
        pattern:
          spec:
            containers:
              - resources:
                  limits:
                    memory: "?*"
                    cpu: "?*"
```

`"?*"` means "at least one value defined."

### 3. Block privileged pods

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: disallow-privileged-containers
spec:
  validationFailureAction: Enforce
  rules:
    - name: privileged-containers
      match:
        resources:
          kinds:
            - Pod
      validate:
        message: "Les conteneurs privileged ne sont pas autorisés."
        pattern:
          spec:
            =(containers):
              - securityContext:
                  (privileged): "!*true"
```

`=(containers)` with `=` means "if it exists, then." This avoids blocking pods without containers (an edge case).

### 4. Restrict Linux capabilities

By default, a container has many system capabilities. Disallow the most dangerous ones:

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: restrict-capabilities
spec:
  validationFailureAction: Enforce
  rules:
    - name: drop-capabilities
      match:
        resources:
          kinds:
            - Pod
      validate:
        message: "Les capabilities SYS_ADMIN, NET_ADMIN et SYS_MODULE sont interdites."
        deny:
          conditions:
            - key: "[SYS_ADMIN, NET_ADMIN, SYS_MODULE]"
              operator: AnyIn
              value: "{{ request.object.spec.[containers, initContainers, ephemeralContainers].[*].securityContext.capabilities.add[] }}"
```

### 5. Inject sidecars automatically

Kyverno can also mutate resources. Example: add a monitoring sidecar automatically:

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: add-monitoring-sidecar
spec:
  mutation:
    rules:
      - name: add-envoy-sidecar
        match:
          resources:
            kinds:
              - Deployment
            namespaces:
              - production
        mutate:
          patchStrategicMerge:
            spec:
              template:
                spec:
                  containers:
                    - name: envoy
                      image: envoyproxy/envoy:latest
                      ports:
                        - containerPort: 9901
                          name: admin
```

Deploy to `production`? Kyverno adds the sidecar automatically.

## Trivy + Kyverno: the combo

The two tools complement each other:

| | Trivy | Kyverno |
|---|---|---|
| **When** | Build, admission, continuous scan | Admission controller |
| **What** | Vulnerabilities, config, IaC | Policies (validate/mutate/generate) |
| **Action** | Detects | Blocks or modifies |

My typical setup:

```
CI/CD Pipeline
  └─ Trivy scan (exit-code on HIGH/CRITICAL)
  └─ Push image

GitOps Deployment
  └─ ArgoCD detects the new manifest

Kubernetes Admission
  ├─ Kyverno validates (no latest, limits required, no root…)
  └─ Trivy Operator scans deployed images
```

### Admission with the Trivy Operator

The Trivy Operator can also block via Kyverno:

```bash
# Enable the admission controller
helm upgrade --install trivy aquasecurity/trivy \
  --namespace trivy \
  --set trivy.operator.rbac.jobAnnotations."checks\.trivy\.dev/required"="true"
```

HIGH/CRITICAL vulnerabilities in an image can block the deployment.

## Automatic generation

Kyverno can generate resources automatically. Example: create a NetworkPolicy when a Namespace is created:

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: default-deny-network
spec:
  rules:
    - name: deny-all
      match:
        resources:
          kinds:
            - Namespace
      generate:
        apiVersion: networking.k8s.io/v1
        kind: NetworkPolicy
        name: deny-all
        namespace: "{{ request.object.metadata.name }}"
        synchronize: true
        data:
          spec:
            podSelector: {}
            policyTypes:
              - Ingress
              - Egress
```

Every new namespace will automatically have a `deny-all` policy that blocks all traffic.

## Audit and reports

Kyverno generates audit reports:

```bash
# View violations
kubectl get polr -A

NAMESPACE    POLICY               RESOURCE            RESULT   MESSAGE
production   require-resources    deployment/mon-app  Pass     -
staging      require-resources    deployment/mon-app  Fail     Les conteneurs...
```

Integration with Prometheus:

```yaml
# Enable metrics
kubectl get pods -n kyverno -l app.kubernetes.io/component=reports-controller
```

The metrics include:
- `kyverno_policy_results_total` — policy results
- `kyverno_policy_execution_duration_seconds` — execution latency

Grafana can display violations by namespace and policy.

## Best practices

### 1. Start in Audit mode

Put all your policies in `Audit` for a week. Check the violations in `kubectl get polr -A`. Fix the non-compliant workloads before moving to `Enforce`.

### 2. Exclude exceptions

Some system resources require exceptions:

```yaml
spec:
  validationFailureAction: Enforce
  exclude:
    - resources:
        namespaces:
          - kube-system
        kinds:
          - Pod
        names:
          - coredns-*
```

### 3. Version your policies

Treat your policies as code: Git, pull requests, review. Kyverno supports versioned `ClusterPolicy` resources:

```yaml
metadata:
  annotations:
    policies.kyverno.io/title: Require Resources
    policies.kyverno.io/subject: Pod
    policies.kyverno.io/description: >
      Cette politique oblige les conteneurs à avoir des resources limits.
```

### 4. Combine with Falco

Kyverno and Trivy cover the build and admission. Falco watches the runtime:
- Trivy: "this image has known vulnerabilities"
- Kyverno: "this deployment doesn't respect the policies"
- Falco: "this container is doing something suspicious right now"

Three layers, three different moments.

## Conclusion

Securing a Kubernetes cluster is several layers:

1. **Build**: Trivy scans images before pushing them
2. **Admission**: Kyverno validates manifests at deployment
3. **Runtime**: Falco (out of scope here) detects abnormal behavior

Trivy and Kyverno cover the first two layers without friction. Trivy integrates naturally into a CI, Kyverno integrates into the Kubernetes control plane. Both are open source, actively maintained, and the community provides ready-to-use policies.

The concrete gain: you block non-compliant deployments, you force teams to use patched images, and you have visibility into vulnerabilities. It's not perfect, but it's an excellent starting point.
