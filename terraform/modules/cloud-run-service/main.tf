###############################################################################
# Module: cloud-run-service
# Creates a Cloud Run v2 service with Direct VPC Egress, health checks,
# and CPU idle for cost savings.
###############################################################################

variable "name" {
  description = "Cloud Run service name"
  type        = string
}

variable "project_id" {
  type = string
}

variable "region" {
  type = string
}

variable "image" {
  description = "Container image URL"
  type        = string
}

variable "port" {
  description = "Container port"
  type        = number
}

variable "cpu" {
  type    = string
  default = "1000m"
}

variable "memory" {
  type    = string
  default = "512Mi"
}

variable "min_instances" {
  type    = number
  default = 0
}

variable "max_instances" {
  type    = number
  default = 10
}

variable "service_account_email" {
  description = "Cloud Run service account"
  type        = string
}

variable "vpc_network" {
  description = "VPC network name for Direct VPC Egress"
  type        = string
}

variable "vpc_subnet" {
  description = "Subnet name for Direct VPC Egress"
  type        = string
}

variable "vpc_egress" {
  description = "VPC egress setting"
  type        = string
  default     = "PRIVATE_RANGES_ONLY"
}

variable "ingress" {
  description = "Ingress traffic setting"
  type        = string
  default     = "INGRESS_TRAFFIC_ALL"
}

variable "timeout" {
  type    = string
  default = "300s"
}

variable "cpu_idle" {
  description = "Scale down CPU when idle (cost saving)"
  type        = bool
  default     = true
}

variable "health_check_path" {
  description = "HTTP health check path (set empty to use TCP)"
  type        = string
  default     = "/actuator/health"
}

variable "is_public" {
  description = "Allow unauthenticated access"
  type        = bool
  default     = false
}

variable "invoker_service_account" {
  description = "SA email allowed to invoke (for private services)"
  type        = string
  default     = ""
}

# ---------- Cloud Run v2 Service -------------------------------------------
resource "google_cloud_run_v2_service" "service" {
  name     = var.name
  project  = var.project_id
  location = var.region
  ingress  = var.ingress

  template {
    scaling {
      min_instance_count = var.min_instances
      max_instance_count = var.max_instances
    }

    vpc_access {
      network_interfaces {
        network    = var.vpc_network
        subnetwork = var.vpc_subnet
      }
      egress = var.vpc_egress
    }

    timeout         = var.timeout
    service_account = var.service_account_email

    containers {
      image = var.image

      ports {
        container_port = var.port
      }

      resources {
        limits = {
          cpu    = var.cpu
          memory = var.memory
        }
        cpu_idle = var.cpu_idle
      }

      dynamic "startup_probe" {
        for_each = var.health_check_path != "" ? [1] : []
        content {
          http_get {
            path = var.health_check_path
            port = var.port
          }
          initial_delay_seconds = 10
          period_seconds        = 10
          timeout_seconds       = 5
          failure_threshold     = 30
        }
      }

      dynamic "startup_probe" {
        for_each = var.health_check_path == "" ? [1] : []
        content {
          tcp_socket {
            port = var.port
          }
          period_seconds  = 240
          timeout_seconds = 240
        }
      }

      dynamic "liveness_probe" {
        for_each = var.health_check_path != "" ? [1] : []
        content {
          http_get {
            path = "${var.health_check_path}/liveness"
            port = var.port
          }
          period_seconds  = 30
          timeout_seconds = 5
        }
      }
    }
  }

  lifecycle {
    ignore_changes = [
      template[0].containers[0].image,
      template[0].containers[0].env,
    ]
  }
}

# --- IAM: Public access -----------------------------------------------------
resource "google_cloud_run_service_iam_member" "public" {
  count = var.is_public ? 1 : 0

  project  = var.project_id
  location = var.region
  service  = google_cloud_run_v2_service.service.name
  role     = "roles/run.invoker"
  member   = "allUsers"
}

# --- IAM: Private access (SA only) -----------------------------------------
resource "google_cloud_run_service_iam_member" "private" {
  count = (!var.is_public && var.invoker_service_account != "") ? 1 : 0

  project  = var.project_id
  location = var.region
  service  = google_cloud_run_v2_service.service.name
  role     = "roles/run.invoker"
  member   = "serviceAccount:${var.invoker_service_account}"
}

# ---------- Outputs ---------------------------------------------------------
output "url" {
  value = google_cloud_run_v2_service.service.uri
}

output "name" {
  value = google_cloud_run_v2_service.service.name
}
