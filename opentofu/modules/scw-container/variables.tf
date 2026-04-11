# Obligatoires

variable "name" {
  type        = string
  description = "Nom unique du container. Attention : le modifier recrée la ressource."
}

variable "namespace_id" {
  type        = string
  description = "ID du namespace Containers parent."
}

# Image

variable "registry_image" {
  type        = string
  default     = null
  description = "URL de l'image dans le registry (ex: rg.fr-par.scw.cloud/<ns>/<image>:<tag>)."
}

variable "registry_sha256" {
  type        = string
  default     = null
  description = "SHA256 de l'image. Un changement déclenche un redéploiement."
}

# Compute

variable "memory_limit" {
  type        = number
  default     = null
  description = "Mémoire allouée par instance en MB."
}

variable "cpu_limit" {
  type        = number
  default     = null
  description = "vCPU alloués par instance (doit correspondre au tableau de compatibilité mémoire/vCPU)."
}

variable "min_scale" {
  type        = number
  default     = null
  description = "Nombre minimum d'instances actives. Ne peut pas être 0 si scaling_option utilise cpu/memory_usage_threshold."
}

variable "max_scale" {
  type        = number
  default     = null
  description = "Nombre maximum d'instances pour l'autoscaling."
}

variable "port" {
  type        = number
  default     = null
  description = "Port exposé par le container."
}

variable "timeout" {
  type        = number
  default     = 300
  description = "Durée maximale de traitement d'une requête en secondes avant interruption."
}

variable "local_storage_limit" {
  type        = number
  default     = null
  description = "Limite de stockage local en MB."
}

variable "sandbox" {
  type        = string
  default     = null
  description = "Environnement d'exécution du container."
}

# Réseau & sécurité

variable "privacy" {
  type        = string
  default     = "public"
  description = "Niveau d'accès : \"public\" (appels anonymes autorisés) ou \"private\" (authentification requise)."

  validation {
    condition     = contains(["public", "private"], var.privacy)
    error_message = "privacy doit être \"public\" ou \"private\"."
  }
}

variable "protocol" {
  type        = string
  default     = "http1"
  description = "Protocole de communication : \"http1\" ou \"h2c\" (HTTP/2 cleartext)."

  validation {
    condition     = contains(["http1", "h2c"], var.protocol)
    error_message = "protocol doit être \"http1\" ou \"h2c\"."
  }
}

variable "http_option" {
  type        = string
  default     = "enabled"
  description = "Gestion HTTP : \"enabled\" (HTTP + HTTPS) ou \"redirected\" (HTTP redirigé vers HTTPS)."

  validation {
    condition     = contains(["enabled", "redirected"], var.http_option)
    error_message = "http_option doit être \"enabled\" ou \"redirected\"."
  }
}

variable "private_network_id" {
  type        = string
  default     = null
  description = "ID du réseau privé pour la connectivité VPC (fonctionnalité beta)."
}

# Variables d'environnement

variable "environment_variables" {
  type        = map(string)
  default     = {}
  description = "Variables d'environnement standard accessibles au container."
}

variable "secret_environment_variables" {
  type        = map(string)
  default     = {}
  sensitive   = true
  description = "Variables d'environnement sensibles stockées de façon sécurisée."
}

# Déploiement

variable "deploy" {
  type        = bool
  default     = true
  description = "Active le déploiement en production du container."
}

variable "description" {
  type        = string
  default     = null
  description = "Description du container."
}

variable "tags" {
  type        = list(string)
  default     = []
  description = "Tags associés au container."
}

variable "command" {
  type        = list(string)
  default     = null
  description = "Commande d'entrée exécutée au démarrage (override le ENTRYPOINT de l'image)."
}

variable "args" {
  type        = list(string)
  default     = null
  description = "Arguments de la commande (override le CMD de l'image)."
}

# Blocs

variable "scaling_option" {
  type = object({
    concurrent_requests_threshold = optional(number)
    cpu_usage_threshold           = optional(number)
    memory_usage_threshold        = optional(number)
  })
  default     = null
  description = <<-EOT
    Critère de déclenchement de l'autoscaling. Un seul champ peut être défini à la fois.
    - concurrent_requests_threshold : scale sur le nombre de requêtes concurrentes par instance.
    - cpu_usage_threshold           : scale sur le % d'utilisation CPU.
    - memory_usage_threshold        : scale sur le % d'utilisation mémoire.
    Note : cpu/memory_usage_threshold nécessitent min_scale >= 1.
  EOT
}

variable "health_check" {
  type = object({
    http_path         = optional(string)
    failure_threshold = optional(number)
    interval          = optional(string)
  })
  default     = null
  description = <<-EOT
    Sonde de santé du container. Un échec pendant le déploiement annule celui-ci.
    - http_path         : chemin HTTP de la sonde (ex: "/healthz").
    - failure_threshold : nombre d'échecs consécutifs avant de marquer le container unhealthy.
    - interval          : durée entre deux sondes (ex: "10s").
  EOT
}
