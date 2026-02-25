###############################################################################
# Module: mysql-database
# Creates a Cloud SQL MySQL instance with databases, backup, HA, and SSL.
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
  description = "VPC network ID for private IP"
  type        = string
}

variable "tier" {
  description = "Cloud SQL machine tier"
  type        = string
  default     = "db-custom-2-4096"
}

variable "ha" {
  description = "Enable Regional HA"
  type        = bool
  default     = true
}

variable "disk_size_gb" {
  type    = number
  default = 20
}

variable "databases" {
  description = "List of database names to create"
  type        = list(string)
}

variable "app_user_password" {
  description = "Application database user password"
  type        = string
  sensitive   = true
}

variable "backup_location" {
  type    = string
  default = "us"
}

variable "retained_backups" {
  type    = number
  default = 14
}

variable "private_vpc_connection" {
  description = "The private VPC connection dependency"
  type        = any
}

# ---------- Cloud SQL -------------------------------------------------------
resource "google_sql_database_instance" "db" {
  name                = "${var.env}-ih-db-cluster"
  project             = var.project_id
  database_version    = "MYSQL_8_0"
  region              = var.region
  deletion_protection = true

  depends_on = [var.private_vpc_connection]

  settings {
    tier              = var.tier
    availability_type = var.ha ? "REGIONAL" : "ZONAL"
    disk_size         = var.disk_size_gb
    disk_type         = "PD_SSD"
    disk_autoresize   = true
    edition           = "ENTERPRISE"
    pricing_plan      = "PER_USE"

    ip_configuration {
      ipv4_enabled                                  = false
      private_network                               = var.vpc_network_id
      require_ssl                                   = true
      ssl_mode                                      = "ENCRYPTED_ONLY"
      enable_private_path_for_google_cloud_services = true
    }

    backup_configuration {
      enabled                        = true
      binary_log_enabled             = true
      start_time                     = "03:00"
      location                       = var.backup_location
      point_in_time_recovery_enabled = true

      backup_retention_settings {
        retained_backups = var.retained_backups
        retention_unit   = "COUNT"
      }
      transaction_log_retention_days = 7
    }

    maintenance_window {
      day          = 7
      hour         = 4
      update_track = "stable"
    }

    insights_config {
      query_insights_enabled  = true
      query_plans_per_minute  = 5
      query_string_length     = 1024
      record_application_tags = true
      record_client_address   = false
    }

    database_flags {
      name  = "cloudsql_iam_authentication"
      value = "on"
    }

    database_flags {
      name  = "slow_query_log"
      value = "on"
    }

    database_flags {
      name  = "long_query_time"
      value = "1"
    }
  }
}

resource "google_sql_user" "app_user" {
  name     = "app-user"
  instance = google_sql_database_instance.db.name
  project  = var.project_id
  password = var.app_user_password
  host     = "%"
}

resource "google_sql_database" "dbs" {
  for_each = toset(var.databases)

  name     = each.value
  instance = google_sql_database_instance.db.name
  project  = var.project_id
}

# ---------- Outputs ---------------------------------------------------------
output "instance_name" {
  value = google_sql_database_instance.db.name
}

output "connection_name" {
  value = google_sql_database_instance.db.connection_name
}

output "private_ip" {
  value     = google_sql_database_instance.db.private_ip_address
  sensitive = true
}
