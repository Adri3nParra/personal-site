variable "ns_name" {
  description = "The unique name of the Containers namespace."
  type        = string
}

variable "ns_description" {
  description = "(Optional) The description of the namespace."
  type        = string
}

variable "ns_region" {
  description = "The region in which the namespace is created."
  type        = string
  default     = "PAR"
}

variable "tags_list" {
  description = "(Optional) The list of tags associated with the namespace."
  type        = list(string)
}
