---
title: "OpenTofu : l'IaC open source qui reprend le flambeau de Terraform"
date: 2025-12-05
draft: false
summary: "En août 2023, HashiCorp a changé la licence de Terraform. Quelques semaines plus tard, OpenTofu naissait sous l'égide de la Linux Foundation. Retour sur la genèse du projet, ce qu'il apporte de nouveau, et pourquoi il mérite votre attention."
tags: ["OpenTofu", "Terraform", "IaC", "DevOps", "Open Source"]
---

Si tu utilises Terraform au quotidien, tu as forcément entendu parler d'OpenTofu. Mais entre le bruit médiatique, les débats de licence et les annonces des deux côtés, il est parfois difficile d'y voir clair. Cet article fait le point : pourquoi le fork existe, ce qu'il apporte concrètement, et comment s'y mettre.

## Un peu d'histoire

### Terraform, le standard de facto

Terraform a été créé par HashiCorp en 2014. Open source sous licence **MPL 2.0** (Mozilla Public License), il est rapidement devenu l'outil de référence pour gérer de l'infrastructure as code. Son modèle déclaratif, son système de providers extensible et son state file ont convaincu une communauté massive : des milliers de providers, des dizaines de milliers de modules, et une adoption quasi universelle dans l'écosystème DevOps.

Pendant presque dix ans, l'écosystème s'est construit autour de Terraform en toute confiance — la licence MPL garantissait que le code restait libre.

### Le changement de licence

Le **10 août 2023**, HashiCorp a annoncé le passage de tous ses produits — dont Terraform — sous licence **BSL 1.1** (Business Source License). Concrètement, la BSL permet l'utilisation, la modification et la redistribution du code, **sauf** pour proposer un produit concurrent d'HashiCorp.

Les conséquences immédiates :

- Les **éditeurs** proposant des solutions d'IaC managée ne pouvaient plus s'appuyer sur le code Terraform.
- Les **contributions communautaires** alimentaient désormais un projet dont la licence limitait l'usage.
- L'**incertitude juridique** — la notion de "produit concurrent" restant floue — a refroidi une partie de l'écosystème.

### La réponse de la communauté

La réaction a été rapide et massive :

- **Mi-août 2023** — Publication du **manifeste OpenTofu**, demandant à HashiCorp de revenir à une licence open source. Plus de **130 entreprises** et **680 individus** signent le manifeste. Le dépôt GitHub accumule plus de **33 000 étoiles** en quelques semaines — un chiffre que Terraform avait mis presque dix ans à atteindre.
- **Fin août 2023** — Un fork privé est créé à partir de la dernière version MPL de Terraform.
- **5 septembre 2023** — Le dépôt public `github.com/opentofu/opentofu` est lancé, avec un dossier de candidature pour rejoindre la **Linux Foundation**.
- **Janvier 2024** — **OpenTofu 1.6.0** sort en GA, première version stable du fork.

Le projet est désormais hébergé par la Linux Foundation, garantissant une gouvernance neutre et communautaire, sans contrôle par une seule entité commerciale.

## OpenTofu en pratique

### Un drop-in replacement

OpenTofu est conçu comme un **remplacement direct** de Terraform. La commande `terraform` devient `tofu`, mais la syntaxe HCL, les providers, les modules et les state files restent compatibles.

```bash
# Avant
terraform init
terraform plan
terraform apply

# Après
tofu init
tofu plan
tofu apply
```

Les fichiers `.tf` existants fonctionnent sans modification. Les providers du registre Terraform sont disponibles via le registre OpenTofu. Les state files sont interchangeables.

### Le registre OpenTofu

OpenTofu maintient son propre registre, basé sur une architecture inspirée de Homebrew : un système git-based hébergé sur Cloudflare R2. Publier un provider ou un module se fait via une simple pull request.

Le registre traite aujourd'hui plus de **6 millions de requêtes quotidiennes** et indexe plus de **4 000 providers** et **20 000 modules**.

## Ce qu'OpenTofu apporte en plus

Depuis le fork, OpenTofu a divergé de Terraform avec plusieurs fonctionnalités exclusives.

### Chiffrement du state (1.7)

C'est probablement la fonctionnalité la plus attendue. Le state file Terraform contient des données sensibles en clair — mots de passe, clés API, tokens. OpenTofu permet de le chiffrer **côté client**, quel que soit le backend de stockage.

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

Les key providers supportés incluent **AWS KMS**, **GCP KMS**, **OpenBao** (le fork open source de Vault), ou simplement une **passphrase** via variable d'environnement. Le state et le plan sont tous les deux chiffrables.

Pour les environnements réglementés (santé, finance, secteur public), cette fonctionnalité seule peut justifier la migration.

### Le bloc `removed` (1.7)

Terraform proposait `terraform state rm` pour retirer une ressource du state sans la détruire. OpenTofu rend ça **déclaratif** :

```hcl
removed {
  from = aws_instance.legacy_server

  lifecycle {
    destroy = false
  }
}
```

La ressource est retirée du state au prochain `tofu apply`, mais l'infrastructure reste en place. Plus besoin de commandes manuelles sur le state.

### Import en boucle (1.7)

L'import de ressources existantes dans le state supporte désormais `for_each` :

```hcl
import {
  for_each = var.existing_instances
  to       = aws_instance.imported[each.key]
  id       = each.value
}
```

Pour les migrations à grande échelle — reprendre un compte AWS existant avec des dizaines de ressources — c'est un gain de temps considérable par rapport aux `terraform import` un par un.

### Fonctions définies par les providers (1.7)

Les providers peuvent exposer des fonctions natives utilisables directement dans le code HCL. C'est une extension du langage que Terraform ne propose pas :

```hcl
# Exemple avec un provider hypothétique
output "parsed" {
  value = provider::utils::parse_yaml(file("config.yml"))
}
```

### Évaluation anticipée des variables (1.8)

Avant OpenTofu 1.8, les variables et locals ne pouvaient pas être utilisés dans certains contextes comme les sources de modules, la configuration backend ou le chiffrement du state. Cette limitation est levée :

```hcl
variable "backend_bucket" {
  type    = string
  default = "my-tf-state"
}

terraform {
  backend "s3" {
    bucket = var.backend_bucket   # Impossible en Terraform, OK en OpenTofu
    key    = "state.tfstate"
    region = "eu-west-1"
  }
}
```

### Extension `.tofu` (1.8)

OpenTofu introduit l'extension `.tofu` en complément de `.tf`. Quand un fichier `main.tofu` et `main.tf` coexistent, OpenTofu utilise le `.tofu`. Cela permet d'utiliser des fonctionnalités spécifiques à OpenTofu tout en gardant les fichiers `.tf` pour la compatibilité Terraform.

### Provider `for_each` (1.9)

La fonctionnalité la plus demandée par la communauté : itérer sur les providers pour des déploiements multi-régions ou multi-comptes.

```hcl
variable "regions" {
  default = ["eu-west-1", "us-east-1", "ap-southeast-1"]
}

provider "aws" {
  for_each = toset(var.regions)
  region   = each.value
}
```

Fini les blocs `provider` dupliqués et les alias manuels pour chaque région.

### Le flag `-exclude` (1.9)

Exclure des ressources spécifiques d'un `plan` ou `apply` :

```bash
tofu apply -exclude=aws_instance.expensive_one
```

Utile pour appliquer partiellement un plan sans toucher à certaines ressources sensibles.

## Terraform vs OpenTofu — où en est-on ?

| | Terraform | OpenTofu |
|---|---|---|
| **Licence** | BSL 1.1 | MPL 2.0 (open source) |
| **Gouvernance** | HashiCorp (IBM) | Linux Foundation |
| **State encryption** | Non | Oui (1.7+) |
| **Bloc `removed`** | Non | Oui (1.7+) |
| **Provider `for_each`** | Non | Oui (1.9+) |
| **Variables dans backend** | Non | Oui (1.8+) |
| **Import `for_each`** | Non | Oui (1.7+) |
| **Registre** | registry.terraform.io | registry.opentofu.org |
| **Support IDE** | Extension officielle | JetBrains natif (2024.3+), VS Code en cours |
| **Compatibilité HCL** | Référence | Compatible + extensions |

À noter : HashiCorp a été **racheté par IBM** fin 2023 pour 6,4 milliards de dollars, ce qui n'a pas rassuré les partisans de l'open source.

## Migrer de Terraform à OpenTofu

La migration est conçue pour être **simple et réversible**.

### Étapes

1. **Sauvegarder le state** et le code :

```bash
cp terraform.tfstate terraform.tfstate.backup
```

2. **Installer OpenTofu** :

```bash
# macOS
brew install opentofu

# Linux (script officiel)
curl -fsSL https://get.opentofu.org/install-opentofu.sh | sh

# Ou via le gestionnaire de paquets de ta distribution
```

3. **Initialiser et vérifier** :

```bash
tofu init
tofu plan
```

Le `plan` ne devrait montrer aucun changement si l'infrastructure est en phase avec le state.

4. **Tester avec un changement mineur** avant de basculer complètement.

### Ce qui change

- La commande `terraform` → `tofu`
- La variable d'environnement `TF_VAR_*` reste supportée
- Les fichiers `.tf` restent compatibles
- Le state file est interchangeable (tant que tu ne chiffres pas avec OpenTofu — le chiffrement est unidirectionnel)
- Les providers et modules du registre Terraform sont mirrorés sur le registre OpenTofu

### Ce qui ne change pas

La syntaxe HCL, la structure des projets, les backends, les provisioners, les data sources — tout fonctionne à l'identique.

## L'écosystème aujourd'hui

OpenTofu n'est pas un projet marginal. En mars 2026 :

- **+23 000 étoiles** GitHub
- **+1,5 million de téléchargements**
- **6 millions de requêtes/jour** sur le registre
- Support natif dans **JetBrains 2024.3+**
- Intégration dans les principaux outils CI/CD (GitLab, GitHub Actions, Spacelift, env0, Scalr)
- Supporté par les grands cloud providers dans leurs documentations

La communauté est active : chaque release majeure compte entre 30 et 50 contributeurs uniques et plus de 150 pull requests.

## Conclusion

OpenTofu n'est pas juste un fork protestataire — c'est un projet qui avance plus vite que son aîné sur les fonctionnalités que la communauté demande depuis des années. Le chiffrement du state, le provider `for_each`, l'évaluation anticipée des variables : ce sont des vrais gains opérationnels, pas des gadgets.

Si tu démarres un nouveau projet d'infrastructure, il n'y a plus de raison technique de choisir Terraform plutôt qu'OpenTofu. Si tu as un existant Terraform, la migration est quasi transparente — et réversible.

Le vrai risque aujourd'hui, c'est de rester sur un outil dont la licence peut évoluer au gré des décisions d'un éditeur, alors qu'une alternative gouvernée par la Linux Foundation offre les mêmes capacités — et plus.
