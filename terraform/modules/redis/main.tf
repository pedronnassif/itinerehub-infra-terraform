###############################################################################
# Module: redis
# Creates a Memorystore Redis instance (managed, no VM overhead).
###############################################################################

variable "env" {
  type = string
}

variable "project_id" {
  type = string
}

variable "region" {
  type = string
}

variable "vpc_network_id" {
  description = "VPC network ID for private access"
  type        = string
}

variable "memory_size_gb" {
  type    = number
  default = 1
}

variable "tier" {
  description = "BASIC (no HA) or STANDARD_HA"
  type        = string
  default     = "BASIC"
}

variable "redis_version" {
  type    = string
  default = "REDIS_7_2"
}

variable "private_vpc_connection" {
  description = "Dependency on private VPC connection"
  type        = any
}

# ---------- Memorystore Redis -----------------------------------------------
resource "google_redis_instance" "redis" {
  name               = "${var.env}-ih-redis"
  project            = var.project_id
  region             = var.region
  tier               = var.tier
  memory_size_gb     = var.memory_size_gb
  redis_version      = var.redis_version
  authorized_network = var.vpc_network_id
  connect_mode       = "PRIVATE_SERVICE_ACCESS"
  display_name       = "${title(var.env)} Redis Cache"

  redis_configs = {
    "maxmemory-policy" = "allkeys-lru"
  }

  maintenance_policy {
    weekly_maintenance_window {
      day = "SUNDAY"
      start_time {
        hours   = 4
        minutes = 0
      }
    }
  }

  depends_on = [var.private_vpc_connection]
}

# ---------- Outputs ---------------------------------------------------------
output "host" {
  value = google_redis_instance.redis.host
}

output "port" {
  value = google_redis_instance.redis.port
}
