# Namespace

variable "namespace_name" {
  description = "The unique name of the Containers namespace."
  type        = string
}

variable "namespace_description" {
  description = "(Optional) The description of the namespace."
  type        = string
}

variable "namespace_region" {
  description = "The region in which the namespace is created."
  type        = string
  default     = "fr-par"
}

variable "tags_list" {
  description = "(Optional) The list of tags associated with the namespace."
  type        = list(string)
}

# Container

variable "container_name" {
  description = "Nom unique du container."
  type        = string
}

variable "container_description" {
  description = "Description du container."
  type        = string
  default     = null
}

variable "container_registry_image" {
  description = "URL de l'image dans le registry (ex: rg.fr-par.scw.cloud/<ns>/<image>:<tag>)."
  type        = string
}

variable "container_port" {
  description = "Port exposé par le container."
  type        = number
  default     = 80
}

variable "container_memory_limit" {
  description = "Mémoire allouée par instance en MB."
  type        = number
  default     = null
}

variable "container_cpu_limit" {
  description = "vCPU alloués par instance."
  type        = number
  default     = null
}

variable "container_min_scale" {
  description = "Nombre minimum d'instances actives."
  type        = number
  default     = 0
}

variable "container_max_scale" {
  description = "Nombre maximum d'instances pour l'autoscaling."
  type        = number
  default     = 1
}

variable "container_http_option" {
  description = "Gestion HTTP : \"enabled\" ou \"redirected\" (HTTP → HTTPS)."
  type        = string
  default     = "redirected"
}

variable "container_privacy" {
  description = "Niveau d'accès : \"public\" ou \"private\"."
  type        = string
  default     = "public"
}
