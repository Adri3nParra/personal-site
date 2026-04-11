---
title: "Taskfile : le remplaçant moderne de Makefile"
date: 2026-03-28
draft: false
summary: "Taskfile (Task) est un task runner écrit en Go qui remplace avantageusement Make pour les projets modernes. Retour sur son histoire, ses avantages, et un comparatif avec Make, Just et les scripts shell."
tags: ["Taskfile", "Task", "DevOps", "Build", "Go"]
---

Depuis des décennies, Make est l'outil de référence pour automatiser les tâches de build et de développement. Mais force est de constater que sa syntaxe cryptique et ses limitations en font un outil parfois douloureux au quotidien. Taskfile — aussi appelé **Task** — propose une alternative moderne, lisible et multi-plateforme. Voici pourquoi il mérite ton attention.

## Un peu d'histoire

### Make, le classique indémodable

Make est né en 1977 dans les laboratoires Bell, créé par Stuart Feldman pour remplacer les scripts shell utilisés pour compiler Unix. Son principe fondamental : un **Makefile** définit des règles basées sur des **cibles** (targets), des **prérequis**, et des **commandes** à exécuter. Make compare les dates de modification des fichiers pour ne rebuild que ce qui a changé.

```makefile
.PHONY: build
build:
    go build -o bin/myapp ./cmd/myapp
```

Pendant près de 50 ans, Make a été l'outil ubiquitous pour les projets C/C++, puis pour tout projet nécessitant de l'automatisation. Il est installé par défaut sur quasi toutes les distributions Unix/Linux/macOS.

### Les limites de Make

Make a été conçu pour un monde différent du nôtre :

- **Syntaxe opaque** : les tabulations vs espaces, les variables avec `$()` ou `${}`, les règles pattern `%` — tout est source de confusion.
- **Pas de support natif JSON/YAML** : les Makefiles sont du texte brut sans structure de données.
- **Écosystème limité** : pas de registry de tasks, pas de dépendances entre tasks résolues automatiquement.
- **Shell-dependency** : les commandes s'exécutent dans un sous-shell, ce qui peut varier selon l'OS.
- **Makefiles générés** : beaucoup de projets finissent par générer leur Makefile via des outils (cmake, automake, etc.), ajoutant une couche d'indirection.

### L'émergence des alternatives

La communauté a progressivement développé des alternatives :

- **Ant** (2000) — XML, verbose, popularisé par Java
- **Rake** (2004) — Ruby DSL, élégant mais Ruby-requis
- **Gradle** (2008) — Groovy/Kotlin, standard Java/Kotlin
- **Jake** (2010) — JavaScript, disparu
- **just** (2016) — Simplicité, recettes inspirées de Make mais modernisées
- **Task** (2017) — YAML, multi-plateforme, inspiré par Go

## Taskfile, c'est quoi ?

**Task** (github.com/go-task/task) est un task runner écrit en Go, disponible sous licence MIT. Il utilise des fichiers `Taskfile.yml` en YAML pour définir les tâches, ce qui le rend accessible à quiconque connaît déjà Kubernetes, GitHub Actions, ou Ansible.

### Installation

```bash
# macOS
brew install go-task/tap/go-task

# Linux (script officiel)
sh -c "$(curl -sL https://taskfile.dev/install.sh)"

# Windows (Scoop, Chocolatey, ou via GitHub releases)
scoop install task

# Via Go
go install github.com/go-task/task/v3/cmd/task@latest
```

### Un premier exemple

```yaml
version: '3'

tasks:
  default:
    deps: [build]
    cmds:
      - ./bin/myapp --help

  build:
    desc: Build the application
    dir: ./cmd/myapp
    cmds:
      - go build -o ../../bin/myapp .

  test:
    desc: Run tests
    cmds:
      - go test -v ./...

  lint:
    desc: Lint code
    cmds:
      - golangci-lint run

  clean:
    desc: Clean build artifacts
    cmds:
      - rm -rf bin/
```

```bash
# Lister les tâches disponibles
task --list

# Exécuter la tâche par défaut
task

# Exécuter une tâche spécifique
task build

# Exécuter avec une variable
task deploy ENV=production
```

## Les fonctionnalités qui font la différence

### Dépendances entre tâches

```yaml
tasks:
  build:
    deps: [deps, lint, test]
    cmds:
      - go build ./...

  deps:
    cmds:
      - go mod download

  lint:
    cmds:
      - golangci-lint run

  test:
    cmds:
      - go test ./...
```

Les dépendances s'exécutent en parallèle par défaut. Pour une exécution séquentielle, utilise `depends`:

```yaml
tasks:
  setup:
    depends: [create-db, migrate-db]
    cmds:
      - echo "Setup complete"
```

### Variables d'environnement et interpolation

```yaml
version: '3'

env:
  APP_NAME: myapp
  VERSION: '1.0.0'

vars:
  BINARY_NAME: "{{.APP_NAME}}-{{.OS}}-{{.ARCH}}"

tasks:
  build:
    vars:
      OUTPUT: "./dist/{{.BINARY_NAME}}"
    cmds:
      - go build -ldflags="-X main.version={{.VERSION}}" -o {{.OUTPUT}} ./cmd/myapp
```

Task expose des variables:
- `.OS` — système d'exploitation (linux, darwin, windows)
- `.ARCH` — architecture (amd64, arm64, etc.)
- `.TASK` — nom de la tâche en cours
- `.CLI_ARGS` — arguments passés en ligne de commande

### Watching et builds

```yaml
version: '3'

tasks:
  dev:
    desc: Run development server with hot reload
    cmds:
      - task: watch-src
        watch: true
      - go run ./cmd/server

  watch-src:
    desc: Watch source files and rebuild
    cmds:
      - while true; do
          inotifywait -q -e modify src/*.go;
          go build ./cmd/server;
        done
    status:
      - test -f ./server
```

Ou en utilisant la directive `watch` native (v3.26+) :

```yaml
tasks:
  build:
    cmds:
      - go build ./...
    watch: true
    sources:
      - src/**/*.go
    generate:
      task: build
```

### Templates et includes

```yaml
# Taskfile.yml principal
version: '3'

includes:
  docker:
    taskfile: ./Taskfile.docker.yml
    vars:
      TAG: latest
  .shared: ./Taskfile.shared.yml
```

```yaml
# Taskfile.shared.yml
version: '3'

tasks:
  log:
    cmds:
      - echo "Version: {{.VERSION}}"
```

### Prompts interactifs

```yaml
tasks:
  deploy:
    prompt: "Are you sure you want to deploy to {{.ENV}}? [y/N]"
    confirm: true
    cmd: echo "Deploying..."
```

## Makefile vs Taskfile — Le comparatif

| | Makefile | Taskfile |
|---|---|---|
| **Syntaxe** | Make DSL | YAML |
| **Lisible** | ⭐⭐ | ⭐⭐⭐⭐⭐ |
| **Multi-plateforme** | ⚠️ (msys, gmake) | ✅ Natif |
| **Variables** | `${VAR}` ou `$(shell ...)` | `{{.VAR}}` |
| **Dépendances** | Manuelles | Automatiques avec `deps` |
| **Exécution parallèle** | `-j` flag global | Par défaut dans `deps` |
| **Fichiers de config** | Non | Oui (includes JSON/YAML) |
| **Prompts interactifs** | Non | Oui |
| **Watch mode** | Via tools externes | Natif |
| **Registry de tasks** | Non | Non (DIY) |
| **Installabilité** | Make installé | binary ou brew |

### Exemple Make vs Task

**Makefile** :

```makefile
.PHONY: build test lint clean

APP_NAME := myapp
VERSION := $(shell git describe --tags --always)
BIN := bin/$(APP_NAME)
SRC := $(wildcard cmd/**/*.go)

build: $(BIN)

$(BIN): $(SRC)
	go build -ldflags="-X main.version=$(VERSION)" -o $(BIN) ./cmd/myapp

test:
	go test -v ./...

lint:
	golangci-lint run

clean:
	rm -rf bin/

install: build
	install -Dm755 $(BIN) /usr/local/bin/$(APP_NAME)
```

**Taskfile.yml** :

```yaml
version: '3'

vars:
  APP_NAME: myapp
  VERSION:
    sh: git describe --tags --always
  BIN: bin/{{.APP_NAME}}

tasks:
  default:
    deps: [lint, test, build]

  build:
    desc: Build the application
    cmds:
      - go build -ldflags="-X main.version={{.VERSION}}" -o {{.BIN}} ./cmd/myapp

  test:
    desc: Run tests
    cmds:
      - go test -v ./...

  lint:
    desc: Lint code
    cmds:
      - golangci-lint run

  clean:
    desc: Clean artifacts
    cmds:
      - rm -rf bin/

  install:
    desc: Install binary
    deps: [build]
    cmds:
      - install -Dm755 {{.BIN}} /usr/local/bin/{{.APP_NAME}}
```

Le Taskfile est plus explicite (`desc`, `vars`, structure), le Makefile plus concis mais cryptique.

## Just vs Taskfile

**Just** (github.com/casey/just) est un autre competitor sérieux, écrit en Rust. Sa syntaxe de recettes ressemble à Make mais en mieux :

```just
# .justfile
APP_NAME := "myapp"
VERSION := `git describe --tags --always`

build:
    go build -ldflags="-X main.version={{VERSION}}" -o bin/{{APP_NAME}} ./cmd/myapp

test:
    go test -v ./...

default: build test
```

| | Just | Task |
|---|---|---|
| **Syntaxe** | DSL custom (recettes) | YAML |
| **Fichiers** | `.justfile` | `Taskfile.yml` |
| **Lisible** | ⭐⭐⭐⭐ | ⭐⭐⭐⭐ |
| **Learning curve** | Faible (syntaxe proche de Make) | Faible (YAML connu) |
| **Variables** | Similaire à Make | Template `{{.VAR}}` |
| **Includes** | Oui | Oui |
| **Watch mode** | Plugin | Natif |
| **Exécution parallèle** | Via recipe dependances | Automatique dans `deps` |
| **Prompts** | Non | Oui |

Just est excellent si tu préfères une syntaxe recipe-style. Task excelle dans les projets où le YAML est déjà le standard (Kubernetes, CI/CD).

## Cas d'usage

### Projet Go

```yaml
version: '3'

tasks:
  default:
    deps: [test, build]

  dev:
    desc: Run with hot reload
    cmds:
      - air

  test:
    cmds:
      - go test -race -v ./...

  lint:
    cmds:
      - golangci-lint run

  build:
    cmds:
      - go build -ldflags="-s -w" -o bin/myapp ./cmd/myapp

  container:
    deps: [build]
    cmds:
      - docker build -t myapp:{{.VERSION}} .

  release:
    deps: [test, lint]
    cmds:
      - goreleaser release --clean
```

### Projet Node.js

```yaml
version: '3'

tasks:
  default:
    deps: [lint, test]

  install:
    cmds:
      - npm install

  test:
    deps: [install]
    cmds:
      - npm run test

  lint:
    deps: [install]
    cmds:
      - npm run lint

  build:
    deps: [install]
    cmds:
      - npm run build

  docker:build:
    cmds:
      - docker build -t myapp:{{.TAG}} .

  docker:push:
    deps: [docker:build]
    cmds:
      - docker push myapp:{{.TAG}}
```

### Multi-services Docker Compose

```yaml
version: '3'

tasks:
  up:
    cmds:
      - docker compose up -d

  down:
    cmds:
      - docker compose down

  logs:
    cmds:
      - docker compose logs -f {{.SERVICE}}

  restart:
    deps: [down, up]

  db:migrate:
    cmds:
      - docker compose exec api npm run db:migrate

  db:seed:
    cmds:
      - docker compose exec api npm run db:seed
```

## L'état de l'écosystème en 2026

Task est un projet mature :

- **+15 000 étoiles** sur GitHub
- **1 million+ de téléchargements** par mois
- Support natif dans plusieurs IDE (VS Code extension)
- Intégration dans des outils CI/CD
- Équipe active avec releases régulières (v3.49.x en mars 2026)

Le projet reste maintenu par la communauté, sans corporate backing majeur — ce qui peut être un avantage (indépendance) ou un risque (dépendance aux contributeurs).

## Conclusion

Taskfile comble les lacunes de Make tout en gardant sa philosophie : un outil simple pour exécuter des tâches courantes. Le YAML le rend immédiatement accessible, les `deps` automatiques simplifient le graphe de dépendances, et le multi-plateforme élimine les surprises.

Personnellement, je l'utilise principalement pour bootstraper les composants de base dans un cluster Kubernetes, en définissant des tâches pour appliquer les manifests essentiels (Namespace, ServiceAccount, RBAC, CNI, etc.) et orchestrer le déploiement des Operators.

Un dernier conseil : quel que soit l'outil choisi, documente tes tasks avec `desc` ou commentaires. Un projet sans documentation de ses tâches, c'est un projet où chaque développeur réinvente la roue au déploiement.
