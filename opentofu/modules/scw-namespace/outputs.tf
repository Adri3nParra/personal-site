output "id" {
  value       = scaleway_container_namespace.namespace.id
  description = "ID du namespace Containers."
}

output "name" {
  value       = scaleway_container_namespace.namespace.name
  description = "Nom du namespace"
}

output "description" {
  value       = scaleway_container_namespace.namespace.description
  description = "Description du namespace"
}

output "region" {
  value       = scaleway_container_namespace.namespace.region
  description = "Région du namespace"
}

output "tags" {
  value       = scaleway_container_namespace.namespace.tags
  description = "Tags du namespace"
}
