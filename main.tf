# AWS Configuration (VPC, Subredes, Gateway, Route Tables, EC2, ELB)

provider "aws" {
  region = "us-west-2" # Region AWS test
}

# VPC Configuration
resource "aws_vpc" "my_vpc" {
  cidr_block = "10.0.0.0/16"
  enable_dns_support = true
  enable_dns_hostnames = true
  tags = {
    Name = "my-vpc"
  }
}

resource "aws_subnet" "my_subnet1" {
  vpc_id            = aws_vpc.my_vpc.id
  cidr_block        = "10.0.1.0/24"
  availability_zone = "us-west-2a"
  tags = {
    Name = "my-subnet-1"
  }
}

resource "aws_subnet" "my_subnet2" {
  vpc_id            = aws_vpc.my_vpc.id
  cidr_block        = "10.0.2.0/24"
  availability_zone = "us-west-2b"
  tags = {
    Name = "my-subnet-2"
  }
}

resource "aws_internet_gateway" "my_gw" {
  vpc_id = aws_vpc.my_vpc.id
  tags = {
    Name = "my-gateway"
  }
}

resource "aws_route_table" "my_route_table" {
  vpc_id = aws_vpc.my_vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.my_gw.id
  }

  tags = {
    Name = "my-route-table"
  }
}

resource "aws_route_table_association" "a" {
  subnet_id      = aws_subnet.my_subnet1.id
  route_table_id = aws_route_table.my_route_table.id
}

resource "aws_route_table_association" "b" {
  subnet_id      = aws_subnet.my_subnet2.id
  route_table_id = aws_route_table.my_route_table.id
}

# EC2 Configuration
resource "aws_security_group" "allow_web" {
  name        = "allow_web_traffic"
  description = "Allow web inbound traffic"
  vpc_id      = aws_vpc.my_vpc.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "allow_web"
  }
}

resource "aws_instance" "my_instance1" {
  ami                    = "ami-abcdefgh"  # AMI Ubuntu
  instance_type          = "t2.micro"
  subnet_id              = aws_subnet.my_subnet1.id
  vpc_security_group_ids = [aws_security_group.allow_web.id]

  tags = {
    Name = "MyInstance1"
  }
}

resource "aws_instance" "my_instance2" {
  ami                    = "ami-abcdefgh"  # AMI Ubuntu
  instance_type          = "t2.micro"
  subnet_id              = aws_subnet.my_subnet2.id
  vpc_security_group_ids = [aws_security_group.allow_web.id]

  tags = {
    Name = "MyInstance2"
  }
}

# ELB Configuration
resource "aws_elb" "my_elb" {
  name               = "my-elb"
  availability_zones = ["us-west-2a", "us-west-2b"]

  listener {
    instance_port     = 80
    instance_protocol = "HTTP"
    lb_port           = 80
    lb_protocol       = "HTTP"
  }

  health_check {
    target              = "HTTP:80/"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }

  instances                   = [aws_instance.my_instance1.id, aws_instance.my_instance2.id]
  cross_zone_load_balancing   = true
  idle_timeout                = 400
  connection_draining         = true
  connection_draining_timeout = 400

  tags = {
    Name = "my-elb"
  }
}

# Kubernetes and NGINX Configuration
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
