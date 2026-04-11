resource "scaleway_container" "container" {
  name         = var.name
  namespace_id = var.namespace_id

  description = var.description
  tags        = var.tags
  privacy     = var.privacy
  protocol    = var.protocol
  http_option = var.http_option
  deploy      = var.deploy

  registry_image  = var.registry_image
  registry_sha256 = var.registry_sha256

  memory_limit        = var.memory_limit
  cpu_limit           = var.cpu_limit
  min_scale           = var.min_scale
  max_scale           = var.max_scale
  port                = var.port
  timeout             = var.timeout
  local_storage_limit = var.local_storage_limit
  sandbox             = var.sandbox

  environment_variables        = var.environment_variables
  secret_environment_variables = var.secret_environment_variables

  command = var.command
  args    = var.args

  private_network_id = var.private_network_id

  dynamic "scaling_option" {
    for_each = var.scaling_option != null ? [var.scaling_option] : []
    content {
      concurrent_requests_threshold = scaling_option.value.concurrent_requests_threshold
      cpu_usage_threshold           = scaling_option.value.cpu_usage_threshold
      memory_usage_threshold        = scaling_option.value.memory_usage_threshold
    }
  }

  dynamic "health_check" {
    for_each = var.health_check != null ? [var.health_check] : []
    content {
      failure_threshold = health_check.value.failure_threshold
      interval          = health_check.value.interval

      dynamic "http" {
        for_each = health_check.value.http_path != null ? [health_check.value.http_path] : []
        content {
          path = http.value
        }
      }
    }
  }
}
