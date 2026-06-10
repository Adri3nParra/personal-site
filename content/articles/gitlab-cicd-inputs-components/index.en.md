---
title: "GitLab CI/CD: inputs, components and the catalog — the end of copy-paste"
date: 2026-01-20
draft: false
summary: "GitLab has thoroughly reworked the reusability of its pipelines. Typed inputs replace fragile variables, components structure sharing, and the catalog lets you discover them. A practical overview."
tags: ["GitLab", "CI/CD", "DevOps", "Pipeline"]
---

For years, reusing GitLab pipelines relied on `include` + `variables`: no typing, no validation, unpredictable side effects. GitLab introduced a far more robust model with **typed inputs** (`spec:inputs`) and **CI/CD Components**, available as GA since GitLab 17.0. Combined with the **CI/CD Catalog**, they transform the way you build and share pipelines.

## The problem with variables

The classic approach works, but it has serious limitations:

```yaml
# template.yml
deploy:
  script: deploy.sh $ENVIRONMENT $REPLICAS
  variables:
    ENVIRONMENT: production
    REPLICAS: "3"
```

```yaml
# .gitlab-ci.yml
include:
  - local: template.yml
    variables:
      ENVIRONMENT: staging
```

The problems:

- **No typing**: `REPLICAS: "three"` raises no error.
- **Global scope**: variables leak into every job in the pipeline.
- **No validation**: no way to enforce a format, a list of allowed values or a required field.
- **Modifiable at runtime**: a job can overwrite a variable midway, making debugging complex.

## `spec:inputs`: typed and validated parameters

Inputs are declared in a YAML header separated by `---`. They are resolved **at pipeline creation**, not at runtime.

```yaml
# deploy-template.yml
spec:
  inputs:
    environment:
      description: "Target environment"
      type: string
      options:
        - staging
        - production
    replicas:
      type: number
      default: 3
    notify-slack:
      type: boolean
      default: false
---

deploy:
  stage: deploy
  script:
    - echo "Deploying to $[[ inputs.environment ]] with $[[ inputs.replicas ]] replicas"
    - if [ "$[[ inputs.notify-slack ]]" = "true" ]; then notify.sh; fi
  environment:
    name: $[[ inputs.environment ]]
```

You then call it via `include`:

```yaml
# .gitlab-ci.yml
include:
  - local: deploy-template.yml
    inputs:
      environment: staging
      replicas: 2
```

### The four types

| Type | Example | Validation |
|---|---|---|
| `string` | `"staging"` | `options`, `regex`, max length 1 KB |
| `number` | `3` | Rejects non-numeric values |
| `boolean` | `true` / `false` | Strict, `"yes"` or `1` are rejected |
| `array` | `["lint", "test"]` | JSON format required |

### Regex validation

To constrain a precise format:

```yaml
spec:
  inputs:
    image-tag:
      type: string
      regex: '^v\d+\.\d+\.\d+$'
      description: "Semver tag (e.g. v1.2.3)"
```

If the input doesn't match, the pipeline refuses to start. No more `deploy.sh v1.lol` in production.

### Conditional rules between inputs

Since GitLab 18.7, inputs can depend on one another with `rules`:

```yaml
spec:
  inputs:
    cloud_provider:
      type: string
      options: ["aws", "gcp"]
    instance_type:
      rules:
        - if: $[[ inputs.cloud_provider ]] == 'aws'
          options: ["t3.micro", "t3.small", "t3.medium"]
          default: "t3.micro"
        - if: $[[ inputs.cloud_provider ]] == 'gcp'
          options: ["e2-micro", "e2-small", "e2-medium"]
          default: "e2-micro"
```

The `instance_type` options change dynamically based on the chosen provider. The first matching rule wins.

## Pipeline inputs

Inputs aren't only useful for included templates — they also work at the level of the pipeline itself. This is where the `spec:inputs` keyword really shines: when a user runs a pipeline manually from the GitLab interface, they get a **typed form** instead of the free-text fields of variables.

```yaml
# .gitlab-ci.yml
spec:
  inputs:
    deploy-env:
      type: string
      options:
        - staging
        - production
      default: staging
      description: "Deployment environment"
    dry-run:
      type: boolean
      default: true
      description: "Run without applying changes"
---

deploy:
  stage: deploy
  script:
    - ./deploy.sh --env=$[[ inputs.deploy-env ]]
  rules:
    - if: $[[ inputs.dry-run ]] == false
```

The user sees a **dropdown** for the environment and a **checkbox** for the dry-run, instead of two text fields where they have to guess the expected format. The pipeline is limited to a maximum of 20 inputs.

### Security: inputs vs variables

GitLab now recommends inputs over variables for manual triggers. The reasons:

- Inputs are **validated and typed** before the pipeline starts.
- Variables are **strings injected as environment variables**, exposed to all jobs.
- Since GitLab 17.7, you can **disable pipeline variables** to force the use of inputs.

## CI/CD Components: reusable building blocks

A component is a structured, versioned and publishable template. It differs from a simple `include` by its discoverability and lifecycle.

### Structure of a component project

```
templates/
├── sast-scan.yml                # "sast-scan" component
└── container-build/
    ├── template.yml             # "container-build" component
    └── Dockerfile
README.md
LICENSE.md
.gitlab-ci.yml
```

### Component example

```yaml
# templates/sast-scan.yml
spec:
  inputs:
    stage:
      default: test
    image:
      default: "semgrep/semgrep:latest"
    rules-config:
      type: string
      default: "p/default"
---

sast:
  stage: $[[ inputs.stage ]]
  image: $[[ inputs.image ]]
  script:
    - semgrep --config $[[ inputs.rules-config ]] .
  allow_failure: true
```

### Usage with `include:component`

```yaml
include:
  - component: $CI_SERVER_FQDN/mon-org/security-tools/sast-scan@1.0.0
    inputs:
      stage: build
      rules-config: "p/owasp-top-ten"
```

The reference format follows the convention: `instance/group/project/component-name@version`.

### Versioning

Components support several versioning strategies:

| Method | Example | Recommendation |
|---|---|---|
| Semver tag | `@1.0.0` | Production |
| Partial version | `@1` or `@1.2` | Latest compatible release |
| Branch | `@main` | Development only |
| SHA | `@e3262fdd...` | Maximum reproducibility |
| Latest | `@~latest` | Avoid in production |

With partial versions, `@1` automatically resolves to the latest `1.*.*` release. It's a good compromise between stability and security updates.

## The CI/CD Catalog

The catalog (`gitlab.com/explore/catalog`) lets you discover and share components publicly or within an instance.

### Publishing a component

1. Enable the **CI/CD Catalog** toggle in the project settings.
2. Tag a release with a semver tag:

```yaml
# .gitlab-ci.yml of the component project
create-release:
  stage: release
  script: echo "Release $CI_COMMIT_TAG"
  rules:
    - if: $CI_COMMIT_TAG =~ /^v\d+\.\d+\.\d+$/
  release:
    tag_name: $CI_COMMIT_TAG
    description: "Release $CI_COMMIT_TAG"
```

The component then appears in the catalog with its documentation (extracted from the `README.md`), its inputs, and its version history.

### Visibility

The component's visibility in the catalog follows that of the project:

- **Private**: only project members can access it.
- **Internal**: all authenticated users of the instance.
- **Public**: everyone.

## Manipulation functions

Inputs support three chainable functions (3 max per interpolation block):

```yaml
script:
  # Expands CI/CD variables in the input value
  - echo "$[[ inputs.cmd | expand_vars ]]"

  # Truncates a value (offset, length)
  - echo "short-$[[ inputs.long-name | truncate(0,8) ]]"

  # Escapes POSIX shell metacharacters
  - echo '$[[ inputs.user-data | posix_escape ]]'
```

`expand_vars` is especially useful for combining inputs and CI/CD variables like `$CI_COMMIT_SHA` or `$CI_PIPELINE_ID`.

## Gradual migration

Inputs and variables coexist without issue. A gradual migration is possible:

1. **Add `spec:inputs`** to existing templates while keeping the `variables` as a fallback.
2. **Convert classic `include`s** to `include:component` once the template is packaged.
3. **Disable pipeline variables** once all manual triggers use inputs.

```yaml
# Intermediate step: input with variable fallback
spec:
  inputs:
    environment:
      default: production
---

deploy:
  variables:
    ENV: $[[ inputs.environment ]]
  script:
    - deploy.sh $ENV
```

## Conclusion

Inputs and components aren't a gadget, they fundamentally change the way GitLab pipelines are structured. Inputs bring the **typing and validation** that variables sorely lacked, components bring **modularity and versioning**, and the catalog brings **discoverability**.

If you maintain pipelines shared across several projects or teams, moving to components is an investment that pays off quickly: less duplication, fewer silent bugs, and a much clearer user interface for manual triggers.
