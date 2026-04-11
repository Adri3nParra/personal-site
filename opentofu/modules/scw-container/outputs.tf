output "id" {
  value       = scaleway_container.container.id
  description = "Identifiant unique du container au format {region}/{id}."
}

output "domain_name" {
  value       = scaleway_container.container.domain_name
  description = "URL native du container (endpoint public Scaleway)."
}

output "status" {
  value       = scaleway_container.container.status
  description = "Statut opérationnel actuel du container."
}

output "cron_status" {
  value       = scaleway_container.container.cron_status
  description = "Statut des triggers cron associés au container."
}

output "error_message" {
  value       = scaleway_container.container.error_message
  description = "Message d'erreur si le container est en état d'erreur."
}

output "region" {
  value       = scaleway_container.container.region
  description = "Région de déploiement du container."
}
