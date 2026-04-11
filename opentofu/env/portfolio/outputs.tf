output "namespace_name" {
  value       = module.namespace.name
  description = "Nom du namespace Containers créé."
}

output "container_domain_name" {
  value       = module.container.domain_name
  description = "URL publique du container (endpoint Scaleway)."
}

output "container_status" {
  value       = module.container.status
  description = "Statut opérationnel du container."
}
