variable "target" {
  type = object({
    kind = string

    docker_registry = string

    # GKE connection information
    gke_config = optional(object({
      project  = string
      name     = string
      location = string
    }))

  })
  description = "The target Kubernetes cluster context and auth"

  validation {
    condition     = var.target.kind == "local" || var.target.kind == "gke"
    error_message = "The target kind must be either 'local' or 'gke'"
  }
  validation {
    condition     = var.target.kind == "local" || var.target.gke_config != null
    error_message = "gke_config must be provided if kind is gke"
  }
}