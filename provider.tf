# Set the required provider and versions
terraform {
  required_providers {
    # We recommend pinning to the specific version of the Docker Provider you're using
    # since new versions are released frequently
    docker = {
      source  = "kreuzwerker/docker"
      version = "3.0.2"
    }

    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "2.20.0"
    }
  }
}

provider "docker" {}


provider "kubernetes" {
  config_path    = "~/.kube/config"
  config_context = "docker-desktop" #TODO: Replace with var later
}


# data "google_client_config" "default" {}
# data "google_container_cluster" "my_cluster" {
#   project  = var.deploy_target.gke_config.project
#   name     = var.deploy_target.gke_config.name
#   location = var.deploy_target.gke_config.location
# }
# provider "kubernetes" {
#   alias                  = "gcp"
#   host                   = "https://${data.google_container_cluster.my_cluster.endpoint}"
#   token                  = data.google_client_config.default.access_token
#   cluster_ca_certificate = base64decode(data.google_container_cluster.my_cluster.master_auth[0].cluster_ca_certificate)
# }