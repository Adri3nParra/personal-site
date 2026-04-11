---
title: "GitLab CI/CD : inputs, components et le catalogue — la fin du copier-coller"
date: 2026-01-20
draft: false
summary: "GitLab a profondément revu la réutilisabilité de ses pipelines. Les inputs typés remplacent les variables fragiles, les components structurent le partage, et le catalogue permet de les découvrir. Tour d'horizon pratique."
tags: ["GitLab", "CI/CD", "DevOps", "Pipeline"]
---

Pendant des années, la réutilisation de pipelines GitLab reposait sur `include` + `variables` : aucun typage, aucune validation, des effets de bord imprévisibles. GitLab a introduit un modèle bien plus robuste avec les **inputs typés** (`spec:inputs`) et les **CI/CD Components**, disponibles en GA depuis GitLab 17.0. Associés au **CI/CD Catalog**, ils transforment la manière de construire et partager des pipelines.

## Le problème avec les variables

L'approche classique fonctionne, mais elle a des limites sérieuses :

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

Les problèmes :

- **Pas de typage** — `REPLICAS: "trois"` ne lève aucune erreur.
- **Scope global** — les variables fuient vers tous les jobs de la pipeline.
- **Pas de validation** — aucun moyen d'imposer un format, une liste de valeurs autorisées ou un champ obligatoire.
- **Modifiables à l'exécution** — un job peut écraser une variable en cours de route, rendant le debug complexe.

## `spec:inputs` — des paramètres typés et validés

Les inputs sont déclarés dans un header YAML séparé par `---`. Ils sont résolus **à la création de la pipeline**, pas à l'exécution.

```yaml
# deploy-template.yml
spec:
  inputs:
    environment:
      description: "Environnement cible"
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
    - echo "Déploiement sur $[[ inputs.environment ]] avec $[[ inputs.replicas ]] réplicas"
    - if [ "$[[ inputs.notify-slack ]]" = "true" ]; then notify.sh; fi
  environment:
    name: $[[ inputs.environment ]]
```

On l'appelle ensuite via `include` :

```yaml
# .gitlab-ci.yml
include:
  - local: deploy-template.yml
    inputs:
      environment: staging
      replicas: 2
```

### Les quatre types

| Type | Exemple | Validation |
|---|---|---|
| `string` | `"staging"` | `options`, `regex`, longueur max 1 Ko |
| `number` | `3` | Rejet des valeurs non numériques |
| `boolean` | `true` / `false` | Strict — `"yes"` ou `1` sont rejetés |
| `array` | `["lint", "test"]` | Format JSON obligatoire |

### Validation par regex

Pour contraindre un format précis :

```yaml
spec:
  inputs:
    image-tag:
      type: string
      regex: '^v\d+\.\d+\.\d+$'
      description: "Tag semver (ex: v1.2.3)"
```

Si l'input ne matche pas, la pipeline refuse de démarrer. Plus de `deploy.sh v1.lol` en production.

### Règles conditionnelles entre inputs

Depuis GitLab 18.7, les inputs peuvent dépendre les uns des autres avec `rules` :

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

Les options de `instance_type` changent dynamiquement en fonction du provider choisi. La première règle qui matche gagne.

## Les inputs de pipeline

Les inputs ne servent pas qu'aux templates inclus — ils fonctionnent aussi au niveau de la pipeline elle-même. C'est là que le mot-clé `spec:inputs` prend tout son sens : quand un utilisateur lance une pipeline manuellement depuis l'interface GitLab, il obtient un **formulaire typé** au lieu des champs texte libres des variables.

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
      description: "Environnement de déploiement"
    dry-run:
      type: boolean
      default: true
      description: "Exécuter sans appliquer les changements"
---

deploy:
  stage: deploy
  script:
    - ./deploy.sh --env=$[[ inputs.deploy-env ]]
  rules:
    - if: $[[ inputs.dry-run ]] == false
```

L'utilisateur voit un **dropdown** pour l'environnement et une **checkbox** pour le dry-run — au lieu de deux champs texte où il faut deviner le format attendu. La pipeline est limitée à 20 inputs maximum.

### Sécurité : inputs vs variables

GitLab recommande désormais les inputs plutôt que les variables pour les déclenchements manuels. Les raisons :

- Les inputs sont **validés et typés** avant que la pipeline ne démarre.
- Les variables sont des **chaînes de caractères injectées comme variables d'environnement**, exposées à tous les jobs.
- Depuis GitLab 17.7, il est possible de **désactiver les variables de pipeline** pour forcer l'utilisation des inputs.

## CI/CD Components — des briques réutilisables

Un component est un template structuré, versionné et publiable. Il se distingue d'un simple `include` par sa découvrabilité et son cycle de vie.

### Structure d'un projet component

```
templates/
├── sast-scan.yml                # Component "sast-scan"
└── container-build/
    ├── template.yml             # Component "container-build"
    └── Dockerfile
README.md
LICENSE.md
.gitlab-ci.yml
```

### Exemple de component

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

### Utilisation avec `include:component`

```yaml
include:
  - component: $CI_SERVER_FQDN/mon-org/security-tools/sast-scan@1.0.0
    inputs:
      stage: build
      rules-config: "p/owasp-top-ten"
```

Le format de référence suit la convention : `instance/groupe/projet/nom-component@version`.

### Versioning

Les components supportent plusieurs stratégies de version :

| Méthode | Exemple | Recommandation |
|---|---|---|
| Tag semver | `@1.0.0` | Production |
| Version partielle | `@1` ou `@1.2` | Dernière release compatible |
| Branche | `@main` | Développement uniquement |
| SHA | `@e3262fdd...` | Maximum de reproductibilité |
| Latest | `@~latest` | À éviter en production |

Avec les versions partielles, `@1` résout automatiquement vers la dernière release `1.*.*`. C'est un bon compromis entre stabilité et mises à jour de sécurité.

## Le CI/CD Catalog

Le catalogue (`gitlab.com/explore/catalog`) permet de découvrir et partager des components publiquement ou au sein d'une instance.

### Publier un component

1. Activer le toggle **CI/CD Catalog** dans les paramètres du projet.
2. Taguer une release avec un tag semver :

```yaml
# .gitlab-ci.yml du projet component
create-release:
  stage: release
  script: echo "Release $CI_COMMIT_TAG"
  rules:
    - if: $CI_COMMIT_TAG =~ /^v\d+\.\d+\.\d+$/
  release:
    tag_name: $CI_COMMIT_TAG
    description: "Release $CI_COMMIT_TAG"
```

Le component apparaît alors dans le catalogue avec sa documentation (extraite du `README.md`), ses inputs, et son historique de versions.

### Visibilité

La visibilité du component dans le catalogue suit celle du projet :

- **Private** — seuls les membres du projet y accèdent.
- **Internal** — tous les utilisateurs authentifiés de l'instance.
- **Public** — tout le monde.

## Fonctions de manipulation

Les inputs supportent trois fonctions chaînables (3 max par bloc d'interpolation) :

```yaml
script:
  # Étend les variables CI/CD dans la valeur de l'input
  - echo "$[[ inputs.cmd | expand_vars ]]"

  # Tronque une valeur (offset, longueur)
  - echo "short-$[[ inputs.long-name | truncate(0,8) ]]"

  # Échappe les métacaractères shell POSIX
  - echo '$[[ inputs.user-data | posix_escape ]]'
```

`expand_vars` est particulièrement utile pour combiner inputs et variables CI/CD comme `$CI_COMMIT_SHA` ou `$CI_PIPELINE_ID`.

## Migration progressive

Les inputs et les variables cohabitent sans problème. Une migration progressive est possible :

1. **Ajouter `spec:inputs`** aux templates existants en gardant les `variables` comme fallback.
2. **Convertir les `include` classiques** en `include:component` une fois le template packagé.
3. **Désactiver les variables de pipeline** quand tous les déclenchements manuels utilisent les inputs.

```yaml
# Étape intermédiaire : input avec fallback variable
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

Les inputs et components ne sont pas un gadget — ils changent fondamentalement la façon de structurer les pipelines GitLab. Les inputs apportent le **typage et la validation** qui manquaient cruellement aux variables, les components apportent la **modularité et le versioning**, et le catalogue apporte la **découvrabilité**.

Si tu maintiens des pipelines partagées entre plusieurs projets ou équipes, le passage aux components est un investissement qui se rentabilise rapidement : moins de duplication, moins de bugs silencieux, et une interface utilisateur bien plus claire pour les déclenchements manuels.
