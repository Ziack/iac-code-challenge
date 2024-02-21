locals {
  nginx_name = "nginx"
  nginx_sha  = sha1(join("", [for f in fileset(path.module, "nginx/*") : filesha1(f)]))
}

# Build NGINX
# Create a docker image resource
resource "docker_image" "nginx" {
  name = local.nginx_name
  triggers = {
    dir_sha1 = local.nginx_sha
  }
  build {
    context = "./nginx"
    tag     = ["local-nginx:latest"]
    label = {
      author : "PaulFlorea"
    }

    auth_config {
      host_name = var.target.kind == "gke" ? "https://${var.target.gke_config.location}-docker.pkg.dev/${var.target.gke_config.project}/${var.target.docker_registry}" : ""
    }
  }
}

resource "docker_registry_image" "nginx" {
  count = var.target.kind == "gke" ? 1 : 0
  name  = docker_image.nginx.name
}

# Namespace
resource "kubernetes_namespace" "nginx" {
  metadata {

    name = local.nginx_name
  }
}

# 2 Replicasets
# * 0.5vcpu & 512Mi Limit
resource "kubernetes_deployment" "nginx" {
  metadata {
    name      = local.nginx_name
    namespace = kubernetes_namespace.nginx.metadata[0].name
    labels = {
      app     = local.nginx_name
      app_sha = local.nginx_sha
    }
  }

  spec {
    replicas = 2
    selector {
      match_labels = {
        app = local.nginx_name
      }
    }
    template {
      metadata {
        labels = {
          app = local.nginx_name
        }
      }

      spec {
        container {
          image             = "${docker_image.nginx.build.*.auth_config[0][0].host_name}${docker_image.nginx.build.*.tag[0][0]}"
          name              = docker_image.nginx.name
          image_pull_policy = "IfNotPresent"

          volume_mount {
            mount_path = "/var/log/nginx/"
            name       = kubernetes_persistent_volume_claim.nginx.metadata[0].name
          }

          liveness_probe {
            http_get {
              path = "/"
              port = 80
            }

            initial_delay_seconds = 3
            period_seconds        = 3
          }

          resources {
            limits = {
              cpu    = "0.5"
              memory = "512Mi"
            }
            requests = {
              cpu    = "250m"
              memory = "50Mi"
            }
          }
        }
        volume {
          name = kubernetes_persistent_volume_claim.nginx.metadata[0].name
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.nginx.metadata[0].name
          }
        }
      }
    }
  }
}

# * ClusterIP + Port 8080
resource "kubernetes_service" "nginx" {
  metadata {
    name      = local.nginx_name
    namespace = kubernetes_namespace.nginx.metadata[0].name
  }
  spec {
    selector = {
      app = kubernetes_deployment.nginx.metadata[0].name
    }
    port {
      port        = 8080
      target_port = 80
    }

    type = "ClusterIP"
  }
}

# * 1 Persistent Volume
#   * 2Gi capacity
#   * local file path (e.g., `${PWD}/pvc`)
resource "kubernetes_persistent_volume_claim" "nginx" {
  metadata {
    name      = "${local.nginx_name}-pvc"
    namespace = kubernetes_namespace.nginx.metadata[0].name
    labels = {
      type = "host_path"
    }
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "manual"
    resources {
      requests = {
        storage = "2Gi"
      }
    }
    volume_name = kubernetes_persistent_volume.nginx.metadata[0].name
  }
}
resource "kubernetes_persistent_volume" "nginx" {
  metadata {
    name = "${local.nginx_name}-pv"
    labels = {
      type = "host_path"
    }
  }
  spec {
    capacity = {
      storage = "2Gi"
    }
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "manual"
    persistent_volume_source {
      host_path {
        path = "${path.cwd}/pvc"
      }
    }
  }
}
