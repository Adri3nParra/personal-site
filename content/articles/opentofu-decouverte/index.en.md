---
title: "OpenTofu: the open source IaC tool carrying Terraform's torch"
date: 2025-12-05
draft: false
summary: "In August 2023, HashiCorp changed Terraform's license. A few weeks later, OpenTofu was born under the Linux Foundation's umbrella. A look at the project's genesis, what new things it brings, and why it deserves your attention."
tags: ["OpenTofu", "Terraform", "IaC", "DevOps", "Open Source"]
---

If you use Terraform daily, you've necessarily heard of OpenTofu. But between the media noise, the licensing debates and the announcements from both sides, it can be hard to see clearly. This article sets the record straight: why the fork exists, what it concretely brings, and how to get started.

## A bit of history

### Terraform, the de facto standard

Terraform was created by HashiCorp in 2014. Open source under the **MPL 2.0** license (Mozilla Public License), it quickly became the reference tool for managing infrastructure as code. Its declarative model, its extensible provider system and its state file convinced a massive community: thousands of providers, tens of thousands of modules, and near-universal adoption across the DevOps ecosystem.

For almost ten years, the ecosystem built itself around Terraform with full confidence — the MPL license guaranteed the code stayed free.

### The license change

On **August 10, 2023**, HashiCorp announced that all its products (including Terraform) would move to the **BSL 1.1** license (Business Source License). Concretely, the BSL allows use, modification and redistribution of the code, **except** to offer a product competing with HashiCorp.

The immediate consequences:

- **Vendors** offering managed IaC solutions could no longer rely on the Terraform code.
- **Community contributions** now fed a project whose license limited usage.
- The **legal uncertainty** (the notion of "competing product" remaining vague) cooled part of the ecosystem.

### The community's response

The reaction was fast and massive:

- **Mid-August 2023**: Publication of the **OpenTofu manifesto**, asking HashiCorp to return to an open source license. More than **130 companies** and **680 individuals** signed it. The GitHub repository accumulated more than **33,000 stars** within a few weeks — a figure Terraform had taken almost ten years to reach.
- **Late August 2023**: A private fork was created from the last MPL version of Terraform.
- **September 5, 2023**: The public `github.com/opentofu/opentofu` repository was launched, with an application to join the **Linux Foundation**.
- **January 2024**: **OpenTofu 1.6.0** shipped as GA, the first stable version of the fork.

The project is now hosted by the Linux Foundation, guaranteeing neutral, community-driven governance, without control by a single commercial entity.

## OpenTofu in practice

### A drop-in replacement

OpenTofu is designed as a **direct replacement** for Terraform. The `terraform` command becomes `tofu`, but the HCL syntax, the providers, the modules and the state files stay compatible.

```bash
# Before
terraform init
terraform plan
terraform apply

# After
tofu init
tofu plan
tofu apply
```

Existing `.tf` files work without modification. Providers from the Terraform registry are available through the OpenTofu registry. State files are interchangeable.

### The OpenTofu registry

OpenTofu maintains its own registry, based on a Homebrew-inspired architecture: a git-based system hosted on Cloudflare R2. Publishing a provider or a module is done through a simple pull request.

The registry today handles more than **6 million daily requests** and indexes over **4,000 providers** and **20,000 modules**.

## What OpenTofu brings on top

Since the fork, OpenTofu has diverged from Terraform with several exclusive features.

### State encryption (1.7)

This is probably the most anticipated feature. The Terraform state file contains sensitive data in plaintext — passwords, API keys, tokens. OpenTofu lets you encrypt it **client-side**, regardless of the storage backend.

```hcl
terraform {
  encryption {
    key_provider "aws_kms" "main" {
      kms_key_id = "arn:aws:kms:eu-west-1:123456789:key/abcd-1234"
      region     = "eu-west-1"
    }

    method "aes_gcm" "default" {
      keys = key_provider.aws_kms.main
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

Supported key providers include **AWS KMS**, **GCP KMS**, **OpenBao** (the open source fork of Vault), or simply a **passphrase** via an environment variable. Both state and plan can be encrypted.

For regulated environments (healthcare, finance, public sector), this feature alone can justify the migration.

### The `removed` block (1.7)

Terraform offered `terraform state rm` to remove a resource from the state without destroying it. OpenTofu makes this **declarative**:

```hcl
removed {
  from = aws_instance.legacy_server

  lifecycle {
    destroy = false
  }
}
```

The resource is removed from the state on the next `tofu apply`, but the infrastructure stays in place. No more manual state commands.

### Loop-based import (1.7)

Importing existing resources into the state now supports `for_each`:

```hcl
import {
  for_each = var.existing_instances
  to       = aws_instance.imported[each.key]
  id       = each.value
}
```

For large-scale migrations (taking over an existing AWS account with dozens of resources), it's a considerable time saver compared to `terraform import` one by one.

### Provider-defined functions (1.7)

Providers can expose native functions usable directly in HCL code. It's a language extension Terraform doesn't offer:

```hcl
# Example with a hypothetical provider
output "parsed" {
  value = provider::utils::parse_yaml(file("config.yml"))
}
```

### Early variable evaluation (1.8)

Before OpenTofu 1.8, variables and locals couldn't be used in certain contexts like module sources, backend configuration or state encryption. That limitation is lifted:

```hcl
variable "backend_bucket" {
  type    = string
  default = "my-tf-state"
}

terraform {
  backend "s3" {
    bucket = var.backend_bucket   # Impossible in Terraform, OK in OpenTofu
    key    = "state.tfstate"
    region = "eu-west-1"
  }
}
```

### The `.tofu` extension (1.8)

OpenTofu introduces the `.tofu` extension alongside `.tf`. When a `main.tofu` and a `main.tf` file coexist, OpenTofu uses the `.tofu`. This lets you use OpenTofu-specific features while keeping the `.tf` files for Terraform compatibility.

### Provider `for_each` (1.9)

The most requested feature by the community: iterating over providers for multi-region or multi-account deployments.

```hcl
variable "regions" {
  default = ["eu-west-1", "us-east-1", "ap-southeast-1"]
}

provider "aws" {
  for_each = toset(var.regions)
  region   = each.value
}
```

No more duplicated `provider` blocks and manual aliases for each region.

### The `-exclude` flag (1.9)

Exclude specific resources from a `plan` or `apply`:

```bash
tofu apply -exclude=aws_instance.expensive_one
```

Useful for partially applying a plan without touching certain sensitive resources.

## Terraform vs OpenTofu: where do we stand?

| | Terraform | OpenTofu |
|---|---|---|
| **License** | BSL 1.1 | MPL 2.0 (open source) |
| **Governance** | HashiCorp (IBM) | Linux Foundation |
| **State encryption** | No | Yes (1.7+) |
| **`removed` block** | No | Yes (1.7+) |
| **Provider `for_each`** | No | Yes (1.9+) |
| **Variables in backend** | No | Yes (1.8+) |
| **`for_each` import** | No | Yes (1.7+) |
| **Registry** | registry.terraform.io | registry.opentofu.org |
| **IDE support** | Official extension | Native JetBrains (2024.3+), VS Code in progress |
| **HCL compatibility** | Reference | Compatible + extensions |

Worth noting: HashiCorp was **acquired by IBM** in late 2023 for $6.4 billion, which didn't reassure open source advocates.

## Migrating from Terraform to OpenTofu

The migration is designed to be **simple and reversible**.

### Steps

1. **Back up the state** and the code:

```bash
cp terraform.tfstate terraform.tfstate.backup
```

2. **Install OpenTofu**:

```bash
# macOS
brew install opentofu

# Linux (official script)
curl -fsSL https://get.opentofu.org/install-opentofu.sh | sh

# Or via your distribution's package manager
```

3. **Initialize and verify**:

```bash
tofu init
tofu plan
```

The `plan` should show no changes if the infrastructure is in sync with the state.

4. **Test with a minor change** before switching over completely.

### What changes

- The `terraform` command → `tofu`
- The `TF_VAR_*` environment variable stays supported
- `.tf` files stay compatible
- The state file is interchangeable (as long as you don't encrypt with OpenTofu — encryption is one-way)
- Providers and modules from the Terraform registry are mirrored on the OpenTofu registry

### What doesn't change

The HCL syntax, the project structure, the backends, the provisioners, the data sources — everything works identically.

## The ecosystem today

OpenTofu isn't a marginal project. As of March 2026:

- **23,000+** GitHub stars
- **1.5 million+ downloads**
- **6 million requests/day** on the registry
- Native support in **JetBrains 2024.3+**
- Integration in the major CI/CD tools (GitLab, GitHub Actions, Spacelift, env0, Scalr)
- Supported by the major cloud providers in their documentation

The community is active: each major release counts between 30 and 50 unique contributors and more than 150 pull requests.

## Conclusion

OpenTofu isn't just a protest fork, it's a project that moves faster than its elder on the features the community has been asking for for years. State encryption, provider `for_each`, early variable evaluation: these are real operational gains, not gadgets.

If you're starting a new infrastructure project, there's no longer a technical reason to choose Terraform over OpenTofu. If you have an existing Terraform setup, the migration is nearly transparent, and reversible.

The real risk today is staying on a tool whose license can change at the whim of a vendor's decisions, when an alternative governed by the Linux Foundation offers the same capabilities, and more.
