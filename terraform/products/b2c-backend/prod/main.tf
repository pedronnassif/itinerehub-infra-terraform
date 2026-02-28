###############################################################################
# Itinerehub B2C Backend – PRODUCTION
# GCP Project: aitinerehub-b2c-prod (800590950952)
# Region:      us-central1
###############################################################################

terraform {
  required_version = ">= 1.5"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
  }

  backend "gcs" {
    bucket = "itinerehub-tf-state"
    prefix = "b2c-backend/prod"
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

# ---------- Variables -------------------------------------------------------
variable "project_id" {
  type    = string
  default = "aitinerehub-b2c-prod"
}

variable "region" {
  type    = string
  default = "us-central1"
}

variable "env" {
  type    = string
  default = "prod"
}

variable "db_password" {
  type      = string
  sensitive = true
}

variable "alert_email" {
  type    = string
  default = ""
}

variable "domain" {
  description = "Custom domain for the HTTPS load balancer (e.g. api.itinerehub.com). Empty = HTTP only."
  type        = string
  default     = ""
}

# The dev project where Artifact Registry lives
variable "dev_project_id" {
  description = "Dev project ID for cross-project image pulls"
  type        = string
  default     = "aitinerehub"
}

###############################################################################
# 0. ENABLE APIS
###############################################################################

resource "google_project_service" "apis" {
  for_each = toset([
    "run.googleapis.com",
    "sqladmin.googleapis.com",
    "secretmanager.googleapis.com",
    "artifactregistry.googleapis.com",
    "compute.googleapis.com",
    "pubsub.googleapis.com",
    "servicenetworking.googleapis.com",
    "storage.googleapis.com",
    "iam.googleapis.com",
    "monitoring.googleapis.com",
    "logging.googleapis.com",
    "cloudtrace.googleapis.com",
    "redis.googleapis.com",
    "places.googleapis.com",
    "aiplatform.googleapis.com",
    "cloudscheduler.googleapis.com",
  ])

  project            = var.project_id
  service            = each.value
  disable_on_destroy = false
}

###############################################################################
# 1. NETWORKING
###############################################################################

module "networking" {
  source = "../../../modules/vpc-network"

  env              = var.env
  project_id       = var.project_id
  region           = var.region
  primary_cidr      = "10.10.0.0/24"
  serverless_cidr   = "10.10.1.0/28"
  redis_cidr        = "10.10.2.0/28"
  enable_flow_logs  = true
  flow_log_sampling = 0.1              # 10% sampling (saves ~80% on flow log costs)
  enable_cloud_nat  = false            # Cloud Run uses Direct VPC Egress, no NAT needed
}

###############################################################################
# 2. CLOUD SQL
###############################################################################

module "database" {
  source = "../../../modules/mysql-database"

  env                    = var.env
  project_id             = var.project_id
  region                 = var.region
  vpc_network_id         = module.networking.vpc_id
  private_vpc_connection = module.networking.private_vpc_connection
  tier                   = "db-custom-2-4096"
  ha                     = true
  disk_size_gb           = 20
  app_user_password      = var.db_password
  backup_location        = "us"
  retained_backups       = 14

  databases = [
    "auth-db",
    "user-db",
    "trip-db",
    "trip-service-db",
    "assets-db",
    "notification-db",
    "location-db",
    "financial-db",
    "transportation-db",
    "booking-db",
    "ai-db",
    "accomodation-db",
    "localization-db",
    "subscription-db",
  ]
}

###############################################################################
# 3. REDIS
###############################################################################

module "redis" {
  source = "../../../modules/redis"

  env                    = var.env
  project_id             = var.project_id
  region                 = var.region
  vpc_network_id         = module.networking.vpc_id
  private_vpc_connection = module.networking.private_vpc_connection
  memory_size_gb         = 1
  tier                   = "BASIC"
}

###############################################################################
# 4. ARTIFACT REGISTRY
###############################################################################

resource "google_artifact_registry_repository" "production" {
  project       = var.project_id
  location      = var.region
  repository_id = "production"
  format        = "DOCKER"
  description   = "B2C Production Docker images"

  cleanup_policies {
    id     = "keep-recent"
    action = "KEEP"
    most_recent_versions {
      keep_count = 10
    }
  }

  cleanup_policies {
    id     = "delete-old-untagged"
    action = "DELETE"
    condition {
      older_than = "2592000s"
      tag_state  = "UNTAGGED"
    }
  }
}

resource "google_artifact_registry_repository" "maven_prod" {
  project       = var.project_id
  location      = var.region
  repository_id = "production-pkg"
  format        = "MAVEN"
  description   = "B2C Production Maven packages"
}

###############################################################################
# 5. SERVICE ACCOUNTS
###############################################################################

resource "google_service_account" "cicd" {
  project      = var.project_id
  account_id   = "${var.env}-cicd"
  display_name = "B2C Prod CI/CD"
}

resource "google_service_account" "cloud_run_sa" {
  project      = var.project_id
  account_id   = "${var.env}-cloud-run-sa"
  display_name = "B2C Prod Cloud Run SA"
}

# Cloud Run SA permissions
resource "google_project_iam_member" "cloud_run_roles" {
  for_each = toset([
    "roles/secretmanager.secretAccessor",
    "roles/cloudsql.client",
    "roles/pubsub.publisher",
    "roles/pubsub.subscriber",
    "roles/storage.objectViewer",
    "roles/logging.logWriter",
    "roles/cloudtrace.agent",
    "roles/monitoring.metricWriter",
  ])

  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.cloud_run_sa.email}"
}

# CI/CD SA permissions
resource "google_project_iam_member" "cicd_roles" {
  for_each = toset([
    "roles/run.admin",
    "roles/artifactregistry.writer",
    "roles/secretmanager.secretAccessor",
    "roles/iam.serviceAccountUser",
  ])

  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.cicd.email}"
}

# Cross-project: allow this project's Cloud Run SA to pull from dev Artifact Registry
resource "google_project_iam_member" "cross_project_ar_reader" {
  project = var.dev_project_id
  role    = "roles/artifactregistry.reader"
  member  = "serviceAccount:${google_service_account.cloud_run_sa.email}"
}

# Cross-project: allow CI/CD SA to pull from dev Artifact Registry
resource "google_project_iam_member" "cicd_cross_project_ar" {
  project = var.dev_project_id
  role    = "roles/artifactregistry.reader"
  member  = "serviceAccount:${google_service_account.cicd.email}"
}

# Storage admin SA (for services that write)
resource "google_service_account" "storage_sa" {
  project      = var.project_id
  account_id   = "${var.env}-storage-sa"
  display_name = "B2C Prod Storage SA"
}

resource "google_project_iam_member" "storage_admin" {
  project = var.project_id
  role    = "roles/storage.objectAdmin"
  member  = "serviceAccount:${google_service_account.storage_sa.email}"
}

###############################################################################
# 6. GCS BUCKETS
###############################################################################

resource "google_storage_bucket" "service_bucket" {
  name          = "${var.env}-ih-service-bucket"
  project       = var.project_id
  location      = var.region
  storage_class = "STANDARD"

  uniform_bucket_level_access = true
  versioning { enabled = true }

  lifecycle_rule {
    condition { age = 90 }
    action {
      type          = "SetStorageClass"
      storage_class = "NEARLINE"
    }
  }
  lifecycle_rule {
    condition { age = 365 }
    action {
      type          = "SetStorageClass"
      storage_class = "COLDLINE"
    }
  }
}

resource "google_storage_bucket" "assets_bucket" {
  name          = "${var.env}-ih-assets-bucket"
  project       = var.project_id
  location      = var.region
  storage_class = "STANDARD"

  uniform_bucket_level_access = true
}

resource "google_storage_bucket" "user_bucket" {
  name          = "${var.env}-ih-user-bucket"
  project       = var.project_id
  location      = var.region
  storage_class = "STANDARD"

  uniform_bucket_level_access = true
  versioning { enabled = true }
}

###############################################################################
# 7. PUB/SUB
###############################################################################

module "dead_letter" {
  source     = "../../../modules/pubsub"
  project_id = var.project_id
  topic_name = "${var.env}-dead-letter-notifications"
}

module "notification_events" {
  source              = "../../../modules/pubsub"
  project_id          = var.project_id
  topic_name          = "${var.env}-notifications-events-topic"
  subscription_name   = "${var.env}-notifications-push-subscription"
  dead_letter_topic_id = module.dead_letter.topic_id
}

module "batch_push" {
  source              = "../../../modules/pubsub"
  project_id          = var.project_id
  topic_name          = "${var.env}-batch-push-notification-event-topic"
  subscription_name   = "${var.env}-batch-push-notification-subscription"
  dead_letter_topic_id = module.dead_letter.topic_id
}

module "notification_event" {
  source     = "../../../modules/pubsub"
  project_id = var.project_id
  topic_name = "${var.env}-notification-event-topic"
}

module "notification_push" {
  source     = "../../../modules/pubsub"
  project_id = var.project_id
  topic_name = "${var.env}-notification-push-topic"
}

module "notifications_retry" {
  source     = "../../../modules/pubsub"
  project_id = var.project_id
  topic_name = "${var.env}-notifications-retry-topic"
}

###############################################################################
# 8. CLOUD RUN – B2C SERVICES
###############################################################################

locals {
  image_base = "${var.region}-docker.pkg.dev/${var.project_id}/production"
  # Placeholder image for initial provisioning (before CI/CD pushes real images).
  # The lifecycle { ignore_changes = [image] } in the module means Terraform
  # won't revert to this after the first apply.
  placeholder_image = "us-docker.pkg.dev/cloudrun/container/hello:latest"

  b2c_services = {
    "${var.env}-ih-spring-gw-service" = {
      port = 5049, memory = "1Gi", min = 1, max = 10, is_public = true
    }
    "${var.env}-user-service" = {
      port = 5050, memory = "512Mi", min = 0, max = 10, is_public = false
    }
    "${var.env}-trip-service" = {
      port = 5051, memory = "512Mi", min = 0, max = 10, is_public = false
    }
    "${var.env}-location-service" = {
      port = 5052, memory = "512Mi", min = 0, max = 10, is_public = false
    }
    "${var.env}-notification-service" = {
      port = 5053, memory = "512Mi", min = 0, max = 5, is_public = false
    }
    "${var.env}-financial-service" = {
      port = 5054, memory = "512Mi", min = 0, max = 10, is_public = false
    }
    "${var.env}-transportation-service" = {
      port = 5055, memory = "512Mi", min = 0, max = 10, is_public = false
    }
    "${var.env}-booking-service" = {
      port = 5056, memory = "512Mi", min = 0, max = 10, is_public = false
    }
    "${var.env}-aaccomodation-service" = {
      port = 5057, memory = "512Mi", min = 0, max = 10, is_public = false
    }
    "${var.env}-ai-service" = {
      port = 5058, memory = "1Gi", min = 0, max = 5, is_public = false
    }
    "${var.env}-assets-service" = {
      port = 5059, memory = "512Mi", min = 0, max = 10, is_public = false
    }
    "${var.env}-ih-subscription-service" = {
      port = 5060, memory = "512Mi", min = 0, max = 5, is_public = false
    }
    "${var.env}-ih-voucher-processing-service" = {
      port = 5061, memory = "512Mi", min = 0, max = 5, is_public = false
    }
    "${var.env}-mobility-service" = {
      port = 5065, memory = "512Mi", min = 0, max = 5, is_public = false
    }
  }
}

module "b2c_services" {
  source   = "../../../modules/cloud-run-service"
  for_each = local.b2c_services

  name                    = each.key
  project_id              = var.project_id
  region                  = var.region
  image                   = local.placeholder_image
  port                    = each.value.port
  memory                  = each.value.memory
  min_instances           = each.value.min
  max_instances           = each.value.max
  service_account_email   = google_service_account.cloud_run_sa.email
  vpc_network             = module.networking.vpc_name
  vpc_subnet              = module.networking.primary_subnet_name
  is_public               = each.value.is_public
  invoker_service_account = each.value.is_public ? "" : google_service_account.cloud_run_sa.email
  enable_private_invoker  = !each.value.is_public
}

###############################################################################
# 9. GLOBAL HTTPS LOAD BALANCER + CLOUD ARMOR + CDN
###############################################################################

module "global_lb" {
  source = "../../../modules/global-lb"

  project_id             = var.project_id
  region                 = var.region
  env                    = var.env
  name_prefix            = "b2c"
  cloud_run_service_name = module.b2c_services["${var.env}-ih-spring-gw-service"].name
  domain                 = var.domain
  enable_cdn             = true
}

###############################################################################
# 10. AUDIT LOGGING
###############################################################################

module "audit_logging" {
  source     = "../../../modules/audit-logging"
  project_id = var.project_id
}

###############################################################################
# 11. MONITORING
###############################################################################

module "monitoring" {
  source = "../../../modules/monitoring"

  project_id  = var.project_id
  env         = var.env
  alert_email = var.alert_email
}

###############################################################################
# 12. CLOUD SQL DOWNTIME SCHEDULE (00:00–06:00 KSA daily)
#
# Two Cloud Scheduler jobs call the SQL Admin REST API to toggle the
# instance activation policy: NEVER = stopped, ALWAYS = running.
###############################################################################

resource "google_service_account" "sql_scheduler_sa" {
  project      = var.project_id
  account_id   = "${var.env}-sql-scheduler-sa"
  display_name = "B2C Prod Cloud SQL Scheduler"
}

resource "google_project_iam_member" "sql_scheduler_admin" {
  project = var.project_id
  role    = "roles/cloudsql.admin"
  member  = "serviceAccount:${google_service_account.sql_scheduler_sa.email}"
}

resource "google_cloud_scheduler_job" "sql_stop" {
  name      = "${var.env}-sql-stop-midnight"
  project   = var.project_id
  region    = var.region
  schedule  = "0 0 * * *"
  time_zone = "Asia/Riyadh"

  http_target {
    uri         = "https://sqladmin.googleapis.com/v1/projects/${var.project_id}/instances/${module.database.instance_name}"
    http_method = "PATCH"
    body        = base64encode(jsonencode({ settings = { activationPolicy = "NEVER" } }))
    headers     = { "Content-Type" = "application/json" }

    oauth_token {
      service_account_email = google_service_account.sql_scheduler_sa.email
      scope                 = "https://www.googleapis.com/auth/cloud-platform"
    }
  }

  depends_on = [google_project_service.apis]
}

resource "google_cloud_scheduler_job" "sql_start" {
  name      = "${var.env}-sql-start-morning"
  project   = var.project_id
  region    = var.region
  schedule  = "0 6 * * *"
  time_zone = "Asia/Riyadh"

  http_target {
    uri         = "https://sqladmin.googleapis.com/v1/projects/${var.project_id}/instances/${module.database.instance_name}"
    http_method = "PATCH"
    body        = base64encode(jsonencode({ settings = { activationPolicy = "ALWAYS" } }))
    headers     = { "Content-Type" = "application/json" }

    oauth_token {
      service_account_email = google_service_account.sql_scheduler_sa.email
      scope                 = "https://www.googleapis.com/auth/cloud-platform"
    }
  }

  depends_on = [google_project_service.apis]
}

###############################################################################
# OUTPUTS
###############################################################################

output "project_id" {
  value = var.project_id
}

output "vpc_id" {
  value = module.networking.vpc_id
}

output "sql_connection_name" {
  value = module.database.connection_name
}

output "redis_host" {
  value = module.redis.host
}

output "gateway_url" {
  value = module.b2c_services["${var.env}-ih-spring-gw-service"].url
}

output "cloud_run_urls" {
  value = { for k, v in module.b2c_services : k => v.url }
}

output "cloud_run_sa" {
  value = google_service_account.cloud_run_sa.email
}

output "cicd_sa" {
  value = google_service_account.cicd.email
}

output "lb_ip_address" {
  value = module.global_lb.lb_ip_address
}

output "cloud_armor_policy" {
  value = module.global_lb.security_policy_id
}
