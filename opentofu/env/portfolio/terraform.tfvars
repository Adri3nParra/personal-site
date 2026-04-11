namespace_name        = "portfolio"
namespace_description = "Namespace Scaleway Containers pour le portfolio"
namespace_region      = "fr-par"
tags_list             = ["portfolio", "hugo", "nginx"]

container_name           = "portfolio"
container_description    = "Portfolio Hugo — nginx:alpine"
container_registry_image = "rg.fr-par.scw.cloud/funcscwportfolio7b05b454/portfolio:latest"
container_port           = 80
container_memory_limit   = 512
container_cpu_limit      = 400
container_min_scale      = 1
container_max_scale      = 1
container_http_option    = "redirected"
container_privacy        = "public"
