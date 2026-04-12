---
title: "OpenTofu Avancé : State Encryption & Stratégies Multi-Environnements"
date: 2026-04-12
draft: false
summary: "L'article d'intro couvrait le pourquoi d'OpenTofu. Celui-ci couvre le comment en production : chiffrement du state avec plusieurs key providers, rotation de clés, migration d'un state existant, et les patterns multi-environnements qui tiennent à l'échelle."
tags: ["OpenTofu", "Terraform", "IaC", "DevOps", "Sécurité"]
---

L'[article d'introduction à OpenTofu](/articles/opentofu-decouverte/) couvrait l'histoire du fork et les nouvelles fonctionnalités. Deux sujets méritaient d'aller plus loin : le **chiffrement du state** — présenté avec un seul exemple HCL — et les **stratégies multi-environnements** — mentionnées sans être développées.

Ce sont pourtant les deux points qui font la différence entre un projet IaC qui tient en production et un qui finit en dette technique.

## Le state OpenTofu : ce qu'il contient vraiment

Avant de chiffrer, il faut comprendre ce qu'on protège. Le state file `terraform.tfstate` est un JSON qui contient l'état réel de ton infrastructure :

```json
{
  "resources": [
    {
      "type": "aws_db_instance",
      "instances": [
        {
          "attributes": {
            "username": "admin",
            "password": "monmotdepassedb",
            "endpoint": "rds.cluster.aws.com:5432"
          }
        }
      ]
    }
  ]
}
```

En clair. Sans chiffrement. Dans un bucket S3.

Tout ce que tu déclares dans ton IaC — mots de passe RDS, clés API, tokens Kubernetes, certificats — finit dans ce fichier. Un accès en lecture au bucket S3 qui stocke le state, c'est potentiellement accès à toute l'infrastructure.

## State Encryption : architecture

OpenTofu 1.7 introduit le chiffrement **côté client**. Ça signifie que le state est chiffré avant d'être envoyé au backend — S3, GCS, Scaleway Object Storage, ou autre. Le backend ne voit que du contenu chiffré.

```
tofu apply
    │
    ▼
State calculé (JSON clair)
    │
    ▼
Chiffrement local (AES-256-GCM)
    │   clé fournie par un key provider (KMS, passphrase…)
    ▼
State chiffré → Backend (S3, GCS…)
```

Le déchiffrement se fait à l'inverse au `tofu plan` : OpenTofu récupère le state chiffré, le déchiffre localement avec le key provider, et travaille sur le JSON clair en mémoire.

### La structure du bloc `encryption`

```hcl
terraform {
  encryption {
    # 1. Key provider : d'où vient la clé
    key_provider "..." "nom" {
      # configuration
    }

    # 2. Method : algorithme de chiffrement
    method "aes_gcm" "default" {
      keys = key_provider.<type>.<nom>
    }

    # 3. Ce qu'on chiffre
    state {
      method = method.aes_gcm.default
    }

    plan {
      method = method.aes_gcm.default
    }
  }
}
```

Les méthodes disponibles : `aes_gcm` (AES-256-GCM, recommandé) et `unencrypted` (pour désactiver explicitement).

## Key providers

### Passphrase — pour le dev/test

Le plus simple : une passphrase via variable d'environnement.

```hcl
terraform {
  encryption {
    key_provider "pbkdf2" "local" {
      passphrase = var.state_passphrase
    }

    method "aes_gcm" "default" {
      keys = key_provider.pbkdf2.local
    }

    state {
      method = method.aes_gcm.default
    }
  }
}

variable "state_passphrase" {
  type      = string
  sensitive = true
}
```

```bash
export TF_VAR_state_passphrase="ma-passphrase-longue-et-aleatoire"
tofu apply
```

Le key provider `pbkdf2` dérive une clé AES-256 depuis la passphrase avec PBKDF2-SHA512. Pas idéal pour la prod (la passphrase reste un secret à gérer), mais parfait pour du dev local ou des environnements jetables.

### AWS KMS — pour la prod sur AWS

```hcl
terraform {
  encryption {
    key_provider "aws_kms" "prod" {
      kms_key_id = "arn:aws:kms:eu-west-1:123456789012:key/abcd-1234-efgh-5678"
      region     = "eu-west-1"

      # Optionnel : clé différente selon l'env
      key_spec = "AES_256"
    }

    method "aes_gcm" "default" {
      keys = key_provider.aws_kms.prod
    }

    state {
      method = method.aes_gcm.default
    }

    plan {
      method = method.aes_gcm.default
    }
  }
}
```

Créer la clé KMS via OpenTofu lui-même (bootstrap nécessaire) :

```hcl
resource "aws_kms_key" "opentofu_state" {
  description             = "Clé de chiffrement pour le state OpenTofu"
  deletion_window_in_days = 30
  enable_key_rotation     = true

  tags = {
    Purpose = "opentofu-state-encryption"
    Env     = var.environment
  }
}

resource "aws_kms_alias" "opentofu_state" {
  name          = "alias/opentofu-state-${var.environment}"
  target_key_id = aws_kms_key.opentofu_state.key_id
}
```

L'IAM Policy pour le runner CI/CD :

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "kms:GenerateDataKey",
        "kms:Decrypt"
      ],
      "Resource": "arn:aws:kms:eu-west-1:123456789012:key/abcd-1234"
    }
  ]
}
```

`GenerateDataKey` pour chiffrer, `Decrypt` pour déchiffrer. Rien de plus.

### GCP KMS — pour la prod sur GCP

```hcl
terraform {
  encryption {
    key_provider "gcp_kms" "prod" {
      kms_encryption_key = "projects/mon-projet/locations/europe-west1/keyRings/opentofu/cryptoKeys/state"

      # Credentials via Application Default Credentials ou var
      credentials = file("sa-key.json")  # À éviter en prod — préférer GOOGLE_CREDENTIALS
    }

    method "aes_gcm" "default" {
      keys = key_provider.gcp_kms.prod
    }

    state {
      method = method.aes_gcm.default
    }
  }
}
```

### OpenBao/Vault — pour une infra on-premise ou multi-cloud

OpenBao est le fork open source de Vault (même situation que OpenTofu/Terraform) :

```hcl
terraform {
  encryption {
    key_provider "openbao" "vault" {
      address     = "https://vault.interne.example.com:8200"
      token       = var.vault_token
      transit_key = "opentofu-state"
      mount_path  = "transit"
    }

    method "aes_gcm" "default" {
      keys = key_provider.openbao.vault
    }

    state {
      method = method.aes_gcm.default
    }
  }
}
```

Le transit secret engine de Vault génère et stocke les clés. OpenTofu demande une Data Encryption Key (DEK) à Vault pour chaque opération, et Vault garde la KEK (Key Encryption Key). Séparation claire des responsabilités.

## Rotation de clés

### Rotation automatique côté KMS

AWS KMS et GCP KMS supportent la rotation automatique des clés. Active-la sur la ressource KMS :

```hcl
resource "aws_kms_key" "opentofu_state" {
  enable_key_rotation = true  # Rotation annuelle automatique
}
```

OpenTofu gère ça transparentement : il peut déchiffrer les states chiffrés avec d'anciennes versions de la clé.

### Migrer vers une nouvelle clé manuellement

Si tu changes de key provider (passphrase → KMS, ou d'une clé à une autre) :

```hcl
terraform {
  encryption {
    # Ancienne clé (pour déchiffrer)
    key_provider "pbkdf2" "old" {
      passphrase = var.old_passphrase
    }

    # Nouvelle clé (pour chiffrer)
    key_provider "aws_kms" "new" {
      kms_key_id = "arn:aws:kms:..."
      region     = "eu-west-1"
    }

    method "aes_gcm" "old_method" {
      keys = key_provider.pbkdf2.old
    }

    method "aes_gcm" "new_method" {
      keys = key_provider.aws_kms.new
    }

    state {
      method = method.aes_gcm.new_method

      # Fallback pour déchiffrer avec l'ancienne clé
      fallback {
        method = method.aes_gcm.old_method
      }
    }
  }
}
```

Le bloc `fallback` dit : "si le state ne peut pas être déchiffré avec `new_method`, essaie `old_method`". OpenTofu rechiffre automatiquement le state avec `new_method` au prochain `apply`. Une fois migré, retire le `fallback`.

## Migrer un state existant non chiffré

C'est le cas le plus courant : tu as un state existant en clair et tu veux l'activer.

```hcl
terraform {
  encryption {
    key_provider "aws_kms" "main" {
      kms_key_id = "arn:aws:kms:..."
      region     = "eu-west-1"
    }

    method "aes_gcm" "default" {
      keys = key_provider.aws_kms.main
    }

    state {
      method = method.aes_gcm.default

      # Permet de lire un state non chiffré
      fallback {
        method = method.unencrypted
      }
    }
  }
}
```

Puis :

```bash
tofu apply -refresh-only
```

Le `-refresh-only` force la réécriture du state sans modifier l'infra. Après cette commande, le state est chiffré. Retire ensuite le bloc `fallback`.

```bash
# Vérifier que le state est bien chiffré
aws s3 cp s3://mon-bucket/terraform.tfstate /tmp/check.tfstate
file /tmp/check.tfstate
# /tmp/check.tfstate: data  ← c'est chiffré, pas du JSON lisible
```

## Backends de state

### S3 + DynamoDB (AWS)

Le backend le plus utilisé. DynamoDB gère le lock distribué.

```hcl
terraform {
  backend "s3" {
    bucket         = var.state_bucket    # Variables dans backend : feature OpenTofu 1.8
    key            = "prod/terraform.tfstate"
    region         = "eu-west-1"
    dynamodb_table = "opentofu-state-lock"
    encrypt        = false               # Désactivé — on gère le chiffrement côté client
  }
}
```

Créer le bucket et la table DynamoDB :

```hcl
resource "aws_s3_bucket" "opentofu_state" {
  bucket = "mon-org-opentofu-state"

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.opentofu_state.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_dynamodb_table" "state_lock" {
  name         = "opentofu-state-lock"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }
}
```

### Scaleway Object Storage

Pour ceux qui sont sur Scaleway (comme ce site) :

```hcl
terraform {
  backend "s3" {
    # Scaleway expose une API S3-compatible
    bucket                      = "mon-opentofu-state"
    key                         = "prod/terraform.tfstate"
    region                      = "fr-par"
    endpoint                    = "https://s3.fr-par.scw.cloud"
    skip_credentials_validation = true
    skip_region_validation      = true
    skip_requesting_account_id  = true

    access_key = var.scw_access_key
    secret_key = var.scw_secret_key
  }
}
```

Scaleway n'a pas d'équivalent DynamoDB natif, donc pas de lock distribué par défaut. En équipe, utilise un backend HTTP (GitLab managed state) ou implémente un lock maison.

## Multi-environnements : le vrai débat

C'est le sujet qui divise le plus dans l'écosystème IaC. Deux approches principales :

| | Workspaces | Directories séparés |
|---|---|---|
| **Structure** | Un seul répertoire, plusieurs states | Un répertoire par env |
| **Isolation** | Partielle (même code, state séparé) | Totale (code et state) |
| **DRY** | Élevé | Plus de duplication |
| **Risque** | Apply sur le mauvais workspace | Faible |
| **Dérive entre envs** | Difficile à détecter | Explicite |
| **Idéal pour** | Envs quasi identiques | Envs avec divergences significatives |

### Pattern Workspaces

```
infra/
├── main.tf
├── variables.tf
├── outputs.tf
└── environments/
    ├── dev.tfvars
    ├── staging.tfvars
    └── prod.tfvars
```

```bash
# Créer et switcher
tofu workspace new staging
tofu workspace select staging

# Appliquer avec les vars du bon env
tofu apply -var-file=environments/staging.tfvars
```

Dans le code, `terraform.workspace` donne le nom du workspace actif :

```hcl
resource "aws_instance" "api" {
  instance_type = terraform.workspace == "prod" ? "t3.medium" : "t3.micro"

  tags = {
    Environment = terraform.workspace
  }
}

resource "aws_db_instance" "postgres" {
  instance_class    = local.db_config[terraform.workspace].instance_class
  multi_az          = local.db_config[terraform.workspace].multi_az
}

locals {
  db_config = {
    dev     = { instance_class = "db.t3.micro",  multi_az = false }
    staging = { instance_class = "db.t3.small",  multi_az = false }
    prod    = { instance_class = "db.t3.medium", multi_az = true  }
  }
}
```

Le state est séparé automatiquement par workspace :

```
s3://mon-bucket/
├── terraform.tfstate          ← workspace default
└── env:/
    ├── dev/terraform.tfstate
    ├── staging/terraform.tfstate
    └── prod/terraform.tfstate
```

**Limites des workspaces** : toute la logique de différenciation entre envs est dans le code principal. Si prod et dev divergent beaucoup (services différents, topologie réseau différente), le code devient difficile à lire.

### Pattern Directories — l'approche Terragrunt-compatible

```
infra/
├── modules/                 # Modules réutilisables
│   ├── network/
│   ├── database/
│   └── application/
└── environments/
    ├── dev/
    │   ├── main.tf          # Appelle les modules
    │   ├── backend.tf       # Backend spécifique
    │   └── terraform.tfvars
    ├── staging/
    │   ├── main.tf
    │   ├── backend.tf
    │   └── terraform.tfvars
    └── prod/
        ├── main.tf
        ├── backend.tf
        └── terraform.tfvars
```

```hcl
# environments/prod/main.tf
module "network" {
  source = "../../modules/network"

  vpc_cidr       = "10.0.0.0/16"
  private_subnets = ["10.0.1.0/24", "10.0.2.0/24"]
}

module "database" {
  source = "../../modules/database"

  instance_class = "db.t3.medium"
  multi_az       = true
  subnet_ids     = module.network.private_subnet_ids
}
```

```hcl
# environments/dev/main.tf
module "network" {
  source = "../../modules/network"

  vpc_cidr       = "172.16.0.0/16"
  private_subnets = ["172.16.1.0/24"]
}

module "database" {
  source = "../../modules/database"

  instance_class = "db.t3.micro"
  multi_az       = false
  subnet_ids     = module.network.private_subnet_ids
}
```

Chaque env est un projet OpenTofu indépendant avec son backend. Pas de risque d'apply sur le mauvais env, et les divergences entre envs sont explicites et voulues.

### Pattern hybride : le meilleur des deux

Pour des infras complexes — plusieurs équipes, plusieurs produits — un mix des deux fonctionne bien :

```
infra/
├── modules/           # Modules partagés
├── shared/            # Infra commune à tous les envs (VPC racine, DNS…)
│   ├── main.tf
│   └── backend.tf
└── services/
    └── mon-app/
        ├── modules/   # Modules spécifiques à mon-app
        └── envs/
            ├── dev/
            ├── staging/
            └── prod/
```

Le `shared` est géré une seule fois (workspace `default`). Les services utilisent le pattern directories. Les outputs du `shared` sont lus via `terraform_remote_state` :

```hcl
# services/mon-app/envs/prod/main.tf
data "terraform_remote_state" "shared" {
  backend = "s3"
  config = {
    bucket = "mon-org-opentofu-state"
    key    = "shared/terraform.tfstate"
    region = "eu-west-1"
  }
}

module "application" {
  source = "../../modules/application"

  vpc_id     = data.terraform_remote_state.shared.outputs.vpc_id
  subnet_ids = data.terraform_remote_state.shared.outputs.private_subnets
}
```

## Provider `for_each` multi-région

Feature OpenTofu 1.9. Déployer la même infra dans plusieurs régions sans dupliquer les blocs provider :

```hcl
variable "regions" {
  type    = set(string)
  default = ["eu-west-1", "eu-central-1"]
}

provider "aws" {
  for_each = var.regions
  alias    = each.key
  region   = each.value
}

# Déployer dans chaque région
resource "aws_s3_bucket" "backup" {
  for_each = var.regions
  provider = aws[each.key]
  bucket   = "mon-org-backup-${each.key}"
}
```

Avant OpenTofu 1.9 :

```hcl
# Ce qu'on était obligé de faire
provider "aws" {
  alias  = "eu-west-1"
  region = "eu-west-1"
}

provider "aws" {
  alias  = "eu-central-1"
  region = "eu-central-1"
}

resource "aws_s3_bucket" "backup_eu_west" {
  provider = aws.eu-west-1
  bucket   = "mon-org-backup-eu-west-1"
}

resource "aws_s3_bucket" "backup_eu_central" {
  provider = aws.eu-central-1
  bucket   = "mon-org-backup-eu-central-1"
}
```

Avec `for_each`, ajouter une région = ajouter une valeur dans la variable. Rien de plus.

## Pipelines CI/CD

### GitLab CI avec chiffrement du state

```yaml
# .gitlab-ci.yml
variables:
  TF_ROOT: ${CI_PROJECT_DIR}/infra/environments/prod
  TF_STATE_NAME: prod
  AWS_REGION: eu-west-1

default:
  image:
    name: ghcr.io/opentofu/opentofu:1.9
    entrypoint: [""]

stages:
  - validate
  - plan
  - apply

.tofu_base:
  before_script:
    - cd ${TF_ROOT}
    - tofu init
  environment:
    name: production

validate:
  extends: .tofu_base
  stage: validate
  script:
    - tofu validate
    - tofu fmt -check

plan:
  extends: .tofu_base
  stage: plan
  script:
    - tofu plan -out=plan.tfplan
  artifacts:
    paths:
      - ${TF_ROOT}/plan.tfplan
    expire_in: 1 hour

apply:
  extends: .tofu_base
  stage: apply
  script:
    - tofu apply plan.tfplan
  when: manual
  only:
    - main
```

Les secrets CI/CD (clé KMS, credentials AWS) sont injectés via les variables protégées GitLab :

```bash
# Variables CI/CD à configurer dans GitLab
AWS_ACCESS_KEY_ID     = (protected, masked)
AWS_SECRET_ACCESS_KEY = (protected, masked)
```

### Séparer plan et apply dans des jobs différents

Le plan est généré et stocké en artifact. L'apply lit cet artifact. Ça garantit que ce qui est appliqué en prod est exactement ce qui a été reviewé.

```yaml
apply:
  script:
    # Le plan.tfplan contient déjà la décision — pas de surprise
    - tofu apply plan.tfplan
  dependencies:
    - plan
```

## Bonnes pratiques

### 1. Chiffrer dès le début

Activer le chiffrement sur un state existant est possible mais demande une opération manuelle. Sur un nouveau projet, active-le immédiatement.

### 2. Un backend par environnement

Un state séparé par env — jamais un state partagé entre dev et prod. L'isolation est la règle d'or.

```
s3://mon-org-state-dev/
s3://mon-org-state-prod/
```

Pas de `s3://mon-org-state/dev/terraform.tfstate` et `s3://mon-org-state/prod/terraform.tfstate` dans le même bucket — les permissions IAM sont plus difficiles à contrôler.

### 3. Versionner le backend

Active le versioning S3/GCS sur les buckets de state. Si un `apply` rate à mi-chemin, tu peux restaurer la version précédente du state.

### 4. Ne jamais éditer le state manuellement

```bash
# Jamais ça
vim terraform.tfstate

# Toujours les commandes OpenTofu
tofu state mv old_name.resource new_name.resource
tofu state rm resource_to_remove
tofu import resource_type.name resource_id
```

### 5. Protéger le workspace prod

Dans les pipelines CI/CD, les environments GitLab/GitHub permettent de protéger l'apply en prod derrière une validation manuelle. Utilise-les.

## Conclusion

Le state OpenTofu, c'est le fichier le plus sensible de ton infrastructure. Sans chiffrement, un accès lecture au bucket = accès à tous les secrets. Avec le chiffrement côté client introduit en 1.7, c'est réglé — quelle que soit la politique de sécurité de ton provider de stockage.

Pour le multi-environnements, il n'y a pas de pattern universel. Workspaces pour des envs quasi identiques, directories pour des envs qui divergent, hybride pour les infras complexes. Ce qui compte, c'est la cohérence dans le projet : mixer les approches sans règle, c'est la garantie d'un state qu'on ne comprend plus.

Ces deux sujets sont la base pour passer d'un usage basique d'OpenTofu — des commandes en local qui marchent — à une infrastructure managée sérieusement, dans laquelle l'équipe peut contribuer en confiance.
