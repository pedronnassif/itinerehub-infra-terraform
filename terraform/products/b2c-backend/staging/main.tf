###############################################################################
# Itinerehub B2C Backend – STAGING
# GCP Project: aitinerehub (same project as dev — staging namespace)
# Region:      me-central1 (same as dev)
#
# Staging uses reduced capacity to save cost. Traffic hits Cloud Run
# directly (no LB/Armor) — the full security stack is tested in prod.
# Shares the aitinerehub project with dev, using separate VPC / resource
# names via env prefix.
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
    prefix = "b2c-backend/staging"
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

# ---------- Variables -------------------------------------------------------
variable "project_id" {
  type    = string
  default = "aitinerehub"
}

variable "region" {
  type    = string
  default = "me-central1"
}

variable "env" {
  type    = string
  default = "staging"
}

variable "db_password" {
  type      = string
  sensitive = true
}

variable "alert_email" {
  type    = string
  default = ""
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
  ])

  project            = var.project_id
  service            = each.value
  disable_on_destroy = false
}

###############################################################################
# 1. NETWORKING (separate VPC from dev, non-overlapping CIDRs)
###############################################################################

module "networking" {
  source = "../../../modules/vpc-network"

  env              = var.env
  project_id       = var.project_id
  region           = var.region
  primary_cidr     = "10.1.0.0/24"    # dev = 10.0.x, staging = 10.1.x
  serverless_cidr  = "10.1.1.0/28"
  redis_cidr       = "10.1.2.0/28"
  enable_flow_logs = false
  enable_cloud_nat = false             # Cloud Run uses Direct VPC Egress, no NAT needed
}

###############################################################################
# 2. CLOUD SQL – MySQL 8.0 (mid-tier: between dev f1-micro and prod 2-4096)
###############################################################################

module "database" {
  source = "../../../modules/mysql-database"

  env                    = var.env
  project_id             = var.project_id
  region                 = var.region
  vpc_network_id         = module.networking.vpc_id
  private_vpc_connection = module.networking.private_vpc_connection
  tier                   = "db-g1-small"         # Shared-core, 1.7 GB (cost-optimised for staging)
  ha                     = false                 # No HA for staging (save cost)
  disk_size_gb           = 10
  app_user_password      = var.db_password
  backup_location        = "eu"
  retained_backups       = 7

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

resource "google_artifact_registry_repository" "staging" {
  project       = var.project_id
  location      = var.region
  repository_id = "staging"
  format        = "DOCKER"
  description   = "B2C Staging Docker images"

  cleanup_policies {
    id     = "keep-recent"
    action = "KEEP"
    most_recent_versions {
      keep_count = 5
    }
  }

  cleanup_policies {
    id     = "delete-old-untagged"
    action = "DELETE"
    condition {
      older_than = "1209600s"   # 14 days (shorter than prod's 30)
      tag_state  = "UNTAGGED"
    }
  }
}

resource "google_artifact_registry_repository" "maven_staging" {
  project       = var.project_id
  location      = var.region
  repository_id = "staging-pkg"
  format        = "MAVEN"
  description   = "B2C Staging Maven packages"
}

###############################################################################
# 5. SERVICE ACCOUNTS
###############################################################################

resource "google_service_account" "cicd" {
  project      = var.project_id
  account_id   = "${var.env}-cicd"
  display_name = "B2C Staging GitHub Actions CI/CD"
}

resource "google_service_account" "cloud_run_sa" {
  project      = var.project_id
  account_id   = "${var.env}-cloud-run-sa"
  display_name = "B2C Staging Cloud Run SA"
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

# Storage SA
resource "google_service_account" "storage_sa" {
  project      = var.project_id
  account_id   = "${var.env}-storage-sa"
  display_name = "B2C Staging Storage SA"
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
# 8. CLOUD RUN – B2C SERVICES (staging: max 3, gateway min 1)
###############################################################################

locals {
  image_base = "${var.region}-docker.pkg.dev/${var.project_id}/staging"
  # Placeholder image for initial provisioning (before CI/CD pushes real images).
  # The lifecycle { ignore_changes = [image] } in the module means Terraform
  # won't revert to this after the first apply.
  placeholder_image = "us-docker.pkg.dev/cloudrun/container/hello:latest"

  b2c_services = {
    "${var.env}-ih-spring-gw-service" = {
      port = 5049, memory = "1Gi", min = 0, max = 3, is_public = true   # scale-to-zero in staging (save ~$10/mo)
    }
    "${var.env}-user-service" = {
      port = 5050, memory = "512Mi", min = 0, max = 3, is_public = false
    }
    "${var.env}-trip-service" = {
      port = 5051, memory = "512Mi", min = 0, max = 3, is_public = false
    }
    "${var.env}-location-service" = {
      port = 5052, memory = "512Mi", min = 0, max = 3, is_public = false
    }
    "${var.env}-notification-service" = {
      port = 5053, memory = "512Mi", min = 0, max = 2, is_public = false
    }
    "${var.env}-financial-service" = {
      port = 5054, memory = "512Mi", min = 0, max = 3, is_public = false
    }
    "${var.env}-transportation-service" = {
      port = 5055, memory = "512Mi", min = 0, max = 3, is_public = false
    }
    "${var.env}-booking-service" = {
      port = 5056, memory = "512Mi", min = 0, max = 3, is_public = false
    }
    "${var.env}-aaccomodation-service" = {
      port = 5057, memory = "512Mi", min = 0, max = 3, is_public = false
    }
    "${var.env}-ai-service" = {
      port = 5058, memory = "1Gi", min = 0, max = 2, is_public = false
    }
    "${var.env}-assets-service" = {
      port = 5059, memory = "512Mi", min = 0, max = 3, is_public = false
    }
    "${var.env}-ih-subscription-service" = {
      port = 5060, memory = "512Mi", min = 0, max = 2, is_public = false
    }
    "${var.env}-ih-voucher-processing-service" = {
      port = 5061, memory = "512Mi", min = 0, max = 2, is_public = false
    }
    "${var.env}-mobility-service" = {
      port = 5065, memory = "512Mi", min = 0, max = 2, is_public = false
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
# 9. AUDIT LOGGING
###############################################################################

module "audit_logging" {
  source     = "../../../modules/audit-logging"
  project_id = var.project_id
}

###############################################################################
# 10. MONITORING
###############################################################################

module "monitoring" {
  source = "../../../modules/monitoring"

  project_id  = var.project_id
  env         = var.env
  alert_email = var.alert_email
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
