module "namespace" {
  source = "../../modules/scw-namespace"

  ns_name        = var.namespace_name
  ns_description = var.namespace_description
  ns_region      = var.namespace_region
  tags_list      = var.tags_list
}

module "container" {
  source     = "../../modules/scw-container"
  depends_on = [module.namespace]

  name         = var.container_name
  namespace_id = module.namespace.id
  description  = var.container_description

  registry_image = var.container_registry_image
  port           = var.container_port
  memory_limit   = var.container_memory_limit
  cpu_limit      = var.container_cpu_limit
  min_scale      = var.container_min_scale
  max_scale      = var.container_max_scale
  http_option    = var.container_http_option
  privacy        = var.container_privacy
  tags           = var.tags_list
}
