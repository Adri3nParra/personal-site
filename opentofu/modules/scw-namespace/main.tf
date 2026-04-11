resource "scaleway_container_namespace" "namespace" {

  name        = var.ns_name
  description = var.ns_description
  region      = var.ns_region
  tags        = tolist(toset(var.tags_list))
}
