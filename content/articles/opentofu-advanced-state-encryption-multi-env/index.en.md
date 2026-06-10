---
title: "Advanced OpenTofu: State Encryption & Multi-Environment Strategies"
date: 2026-04-12
draft: false
summary: "The intro article covered the why of OpenTofu. This one covers the how in production: state encryption with several key providers, key rotation, migrating an existing state, and the multi-environment patterns that hold up at scale."
tags: ["OpenTofu", "Terraform", "IaC", "DevOps", "Security"]
---

The [OpenTofu introduction article](/en/articles/opentofu-decouverte/) covered the fork's history and the new features. Two topics deserved going deeper: **state encryption** (presented with a single HCL example) and **multi-environment strategies** (mentioned without being developed).

Yet these are the two points that make the difference between an IaC project that holds up in production and one that ends up as technical debt.

## The OpenTofu state: what it really contains

Before encrypting, you need to understand what you're protecting. The `terraform.tfstate` state file is a JSON that contains the actual state of your infrastructure:

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

In plaintext. Without encryption. In an S3 bucket.

Everything you declare in your IaC (RDS passwords, API keys, Kubernetes tokens, certificates) ends up in this file. Read access to the S3 bucket that stores the state is potentially access to the entire infrastructure.

## State Encryption: architecture

OpenTofu 1.7 introduces **client-side** encryption. This means the state is encrypted before being sent to the backend — S3, GCS, Scaleway Object Storage, or other. The backend only sees encrypted content.

```
tofu apply
    │
    ▼
Computed state (plaintext JSON)
    │
    ▼
Local encryption (AES-256-GCM)
    │   key provided by a key provider (KMS, passphrase…)
    ▼
Encrypted state → Backend (S3, GCS…)
```

Decryption happens in reverse on `tofu plan`: OpenTofu retrieves the encrypted state, decrypts it locally with the key provider, and works on the plaintext JSON in memory.

### The structure of the `encryption` block

```hcl
terraform {
  encryption {
    # 1. Key provider: where the key comes from
    key_provider "..." "nom" {
      # configuration
    }

    # 2. Method: encryption algorithm
    method "aes_gcm" "default" {
      keys = key_provider.<type>.<nom>
    }

    # 3. What we encrypt
    state {
      method = method.aes_gcm.default
    }

    plan {
      method = method.aes_gcm.default
    }
  }
}
```

The available methods: `aes_gcm` (AES-256-GCM, recommended) and `unencrypted` (to explicitly disable).

## Key providers

### Passphrase: for dev/test

The simplest: a passphrase via an environment variable.

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

The `pbkdf2` key provider derives an AES-256 key from the passphrase with PBKDF2-SHA512. Not ideal for production (the passphrase remains a secret to manage), but perfect for local dev or disposable environments.

### AWS KMS: for production on AWS

```hcl
terraform {
  encryption {
    key_provider "aws_kms" "prod" {
      kms_key_id = "arn:aws:kms:eu-west-1:123456789012:key/abcd-1234-efgh-5678"
      region     = "eu-west-1"

      # Optional: different key per env
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

Create the KMS key via OpenTofu itself (bootstrap required):

```hcl
resource "aws_kms_key" "opentofu_state" {
  description             = "Encryption key for the OpenTofu state"
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

The IAM policy for the CI/CD runner:

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

`GenerateDataKey` to encrypt, `Decrypt` to decrypt. Nothing more.

### GCP KMS: for production on GCP

```hcl
terraform {
  encryption {
    key_provider "gcp_kms" "prod" {
      kms_encryption_key = "projects/mon-projet/locations/europe-west1/keyRings/opentofu/cryptoKeys/state"

      # Credentials via Application Default Credentials or var
      credentials = file("sa-key.json")  # Avoid in prod, prefer GOOGLE_CREDENTIALS
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

### OpenBao/Vault: for on-premise or multi-cloud infra

OpenBao is the open source fork of Vault (the same situation as OpenTofu/Terraform):

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

Vault's transit secret engine generates and stores the keys. OpenTofu requests a Data Encryption Key (DEK) from Vault for each operation, and Vault keeps the KEK (Key Encryption Key). A clean separation of responsibilities.

## Key rotation

### Automatic rotation on the KMS side

AWS KMS and GCP KMS support automatic key rotation. Enable it on the KMS resource:

```hcl
resource "aws_kms_key" "opentofu_state" {
  enable_key_rotation = true  # Automatic annual rotation
}
```

OpenTofu handles this transparently: it can decrypt states encrypted with older versions of the key.

### Migrating to a new key manually

If you change key provider (passphrase → KMS, or from one key to another):

```hcl
terraform {
  encryption {
    # Old key (to decrypt)
    key_provider "pbkdf2" "old" {
      passphrase = var.old_passphrase
    }

    # New key (to encrypt)
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

      # Fallback to decrypt with the old key
      fallback {
        method = method.aes_gcm.old_method
      }
    }
  }
}
```

The `fallback` block says: "if the state can't be decrypted with `new_method`, try `old_method`." OpenTofu automatically re-encrypts the state with `new_method` on the next `apply`. Once migrated, remove the `fallback`.

## Migrating an existing unencrypted state

This is the most common case: you have an existing plaintext state and you want to enable encryption.

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

      # Allows reading an unencrypted state
      fallback {
        method = method.unencrypted
      }
    }
  }
}
```

Then:

```bash
tofu apply -refresh-only
```

The `-refresh-only` forces the state to be rewritten without modifying the infra. After this command, the state is encrypted. Then remove the `fallback` block.

```bash
# Check that the state is properly encrypted
aws s3 cp s3://mon-bucket/terraform.tfstate /tmp/check.tfstate
file /tmp/check.tfstate
# /tmp/check.tfstate: data  ← it's encrypted, not readable JSON
```

## State backends

### S3 + DynamoDB (AWS)

The most-used backend. DynamoDB handles the distributed lock.

```hcl
terraform {
  backend "s3" {
    bucket         = var.state_bucket    # Variables in backend: OpenTofu 1.8 feature
    key            = "prod/terraform.tfstate"
    region         = "eu-west-1"
    dynamodb_table = "opentofu-state-lock"
    encrypt        = false               # Disabled, we handle encryption client-side
  }
}
```

Create the bucket and the DynamoDB table:

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

For those on Scaleway (like this site):

```hcl
terraform {
  backend "s3" {
    # Scaleway exposes an S3-compatible API
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

Scaleway doesn't have a native DynamoDB equivalent, so no distributed lock by default. In a team, use an HTTP backend (GitLab managed state) or implement a homemade lock.

## Multi-environment: the real debate

This is the topic that divides the IaC ecosystem the most. Two main approaches:

| | Workspaces | Separate directories |
|---|---|---|
| **Structure** | A single directory, several states | One directory per env |
| **Isolation** | Partial (same code, separate state) | Total (code and state) |
| **DRY** | High | More duplication |
| **Risk** | Apply on the wrong workspace | Low |
| **Drift between envs** | Hard to detect | Explicit |
| **Ideal for** | Nearly identical envs | Envs with significant divergences |

### Workspaces pattern

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
# Create and switch
tofu workspace new staging
tofu workspace select staging

# Apply with the vars of the right env
tofu apply -var-file=environments/staging.tfvars
```

In the code, `terraform.workspace` gives the name of the active workspace:

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

The state is separated automatically by workspace:

```
s3://mon-bucket/
├── terraform.tfstate          ← default workspace
└── env:/
    ├── dev/terraform.tfstate
    ├── staging/terraform.tfstate
    └── prod/terraform.tfstate
```

**Workspace limits**: all the logic for differentiating between envs is in the main code. If prod and dev diverge a lot (different services, different network topology), the code becomes hard to read.

### Directories pattern: the Terragrunt-compatible approach

```
infra/
├── modules/                 # Reusable modules
│   ├── network/
│   ├── database/
│   └── application/
└── environments/
    ├── dev/
    │   ├── main.tf          # Calls the modules
    │   ├── backend.tf       # Specific backend
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

Each env is an independent OpenTofu project with its own backend. No risk of applying on the wrong env, and the divergences between envs are explicit and intentional.

### Hybrid pattern: the best of both

For complex infrastructures (several teams, several products), a mix of the two works well:

```
infra/
├── modules/           # Shared modules
├── shared/            # Infra common to all envs (root VPC, DNS…)
│   ├── main.tf
│   └── backend.tf
└── services/
    └── mon-app/
        ├── modules/   # Modules specific to mon-app
        └── envs/
            ├── dev/
            ├── staging/
            └── prod/
```

The `shared` is managed once (the `default` workspace). The services use the directories pattern. The `shared` outputs are read via `terraform_remote_state`:

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

## Multi-region provider `for_each`

An OpenTofu 1.9 feature. Deploy the same infra in several regions without duplicating the provider blocks:

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

# Deploy in each region
resource "aws_s3_bucket" "backup" {
  for_each = var.regions
  provider = aws[each.key]
  bucket   = "mon-org-backup-${each.key}"
}
```

Before OpenTofu 1.9:

```hcl
# What we were forced to do
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

With `for_each`, adding a region = adding a value in the variable. Nothing more.

## CI/CD pipelines

### GitLab CI with state encryption

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

The CI/CD secrets (KMS key, AWS credentials) are injected via GitLab's protected variables:

```bash
# CI/CD variables to configure in GitLab
AWS_ACCESS_KEY_ID     = (protected, masked)
AWS_SECRET_ACCESS_KEY = (protected, masked)
```

### Separating plan and apply into different jobs

The plan is generated and stored as an artifact. The apply reads this artifact. This guarantees that what's applied in prod is exactly what was reviewed.

```yaml
apply:
  script:
    # The plan.tfplan already contains the decision, no surprise
    - tofu apply plan.tfplan
  dependencies:
    - plan
```

## Best practices

### 1. Encrypt from the start

Enabling encryption on an existing state is possible but requires a manual operation. On a new project, enable it immediately.

### 2. One backend per environment

A separate state per env, never a state shared between dev and prod. Isolation is the golden rule.

```
s3://mon-org-state-dev/
s3://mon-org-state-prod/
```

Not `s3://mon-org-state/dev/terraform.tfstate` and `s3://mon-org-state/prod/terraform.tfstate` in the same bucket — IAM permissions are harder to control.

### 3. Version the backend

Enable S3/GCS versioning on the state buckets. If an `apply` fails halfway, you can restore the previous version of the state.

### 4. Never edit the state manually

```bash
# Never this
vim terraform.tfstate

# Always the OpenTofu commands
tofu state mv old_name.resource new_name.resource
tofu state rm resource_to_remove
tofu import resource_type.name resource_id
```

### 5. Protect the prod workspace

In CI/CD pipelines, GitLab/GitHub environments let you protect the prod apply behind a manual validation. Use them.

## Conclusion

The OpenTofu state is the most sensitive file of your infrastructure. Without encryption, read access to the bucket = access to all the secrets. With the client-side encryption introduced in 1.7, that's solved, whatever the security policy of your storage provider.

For multi-environment, there's no universal pattern. Workspaces for nearly identical envs, directories for envs that diverge, hybrid for complex infrastructures. What counts is consistency within the project: mixing approaches without a rule is a guarantee of a state nobody understands anymore.

These two topics are the foundation for moving from a basic use of OpenTofu (local commands that work) to a seriously managed infrastructure, in which the team can contribute with confidence.
