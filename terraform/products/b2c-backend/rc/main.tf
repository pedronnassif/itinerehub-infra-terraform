###############################################################################
# Itinerehub B2C Backend – RC (Release Candidate)
# GCP Project: aitinerehub (541454969801)
# Region:      me-central1 (same project as dev — RC namespace)
#
# RC is the sole pre-prod gate, replacing the deleted staging environment.
# Most services use 512 MiB; ai-service and user-service require 1 GiB
# (OOM during Spring Boot startup at 512 MiB — see GCP_Cost_Optimization_Report).
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
    prefix = "b2c-backend/rc"
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
  default = "rc"
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
# 0. ENABLE APIS (shared project — these are likely already enabled by dev)
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
  primary_cidr     = "10.128.0.0/28"   # RC uses 10.128.x range
  serverless_cidr  = "10.128.1.0/28"
  redis_cidr       = "10.128.2.0/28"
  enable_flow_logs = false
  enable_cloud_nat = false              # Cloud Run uses Direct VPC Egress
}

###############################################################################
# 2. CLOUD SQL – MySQL 8.0 (same tier as dev: f1-micro)
###############################################################################

module "database" {
  source = "../../../modules/mysql-database"

  env                    = var.env
  project_id             = var.project_id
  region                 = var.region
  vpc_network_id         = module.networking.vpc_id
  private_vpc_connection = module.networking.private_vpc_connection
  tier                   = "db-f1-micro"
  ha                     = false
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
# 3. ARTIFACT REGISTRY (RC uses the shared "release" repo from dev)
###############################################################################

resource "google_artifact_registry_repository" "release" {
  project       = var.project_id
  location      = var.region
  repository_id = "release"
  format        = "DOCKER"
  description   = "B2C Release Candidate Docker images"

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
      older_than = "2592000s"  # 30 days
      tag_state  = "UNTAGGED"
    }
  }

  cleanup_policies {
    id     = "delete-old-tagged"
    action = "DELETE"
    condition {
      older_than = "2592000s"  # 30 days
      tag_state  = "TAGGED"
    }
  }
}

###############################################################################
# 4. SERVICE ACCOUNTS
###############################################################################

resource "google_service_account" "cloud_run_sa" {
  project      = var.project_id
  account_id   = "${var.env}-cloud-run-sa"
  display_name = "B2C RC Cloud Run SA"
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

# Storage SA
resource "google_service_account" "storage_sa" {
  project      = var.project_id
  account_id   = "${var.env}-storage-sa"
  display_name = "B2C RC Storage SA"
}

resource "google_project_iam_member" "storage_admin" {
  project = var.project_id
  role    = "roles/storage.objectAdmin"
  member  = "serviceAccount:${google_service_account.storage_sa.email}"
}

###############################################################################
# 5. GCS BUCKETS
###############################################################################

resource "google_storage_bucket" "service_bucket" {
  name          = "ih-${var.env}-service-bucket"
  project       = var.project_id
  location      = var.region
  storage_class = "STANDARD"

  uniform_bucket_level_access = true
}

resource "google_storage_bucket" "crm_bucket" {
  name          = "${var.env}-ih-crm"
  project       = var.project_id
  location      = var.region
  storage_class = "STANDARD"

  uniform_bucket_level_access = true
}

###############################################################################
# 6. PUB/SUB
###############################################################################

module "dead_letter" {
  source     = "../../../modules/pubsub"
  project_id = var.project_id
  topic_name = "${var.env}-dead-letter-notifications"
}

module "notification_events" {
  source               = "../../../modules/pubsub"
  project_id           = var.project_id
  topic_name           = "${var.env}-notifications-events-topic"
  subscription_name    = "${var.env}-notifications-push-subscriptions"
  dead_letter_topic_id = module.dead_letter.topic_id
}

module "batch_push" {
  source               = "../../../modules/pubsub"
  project_id           = var.project_id
  topic_name           = "${var.env}-batch-push-notification-event-topic"
  subscription_name    = "${var.env}-batch-push-notification-event-subscriptions"
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
  topic_name = "${var.env}.notifications-retry-topic"
}

###############################################################################
# 7. CLOUD RUN – B2C SERVICES (rc: max 3, most 512Mi; ai/user at 1Gi)
###############################################################################

locals {
  image_base = "${var.region}-docker.pkg.dev/${var.project_id}/release"
  # Placeholder image for initial provisioning (before CI/CD pushes real images).
  # The lifecycle { ignore_changes = [image] } in the module means Terraform
  # won't revert to this after the first apply.
  placeholder_image = "us-docker.pkg.dev/cloudrun/container/hello:latest"

  b2c_services = {
    "${var.env}-ih-spring-gw-service" = {
      port = 6049, memory = "512Mi", min = 0, max = 3, is_public = true
    }
    "${var.env}-user-service" = {
      port = 6059, memory = "1Gi", min = 0, max = 3, is_public = false
    }
    "${var.env}-trip-service" = {
      port = 6053, memory = "512Mi", min = 0, max = 3, is_public = false
    }
    "${var.env}-location-service" = {
      port = 6061, memory = "512Mi", min = 0, max = 3, is_public = false
    }
    "${var.env}-notification-service" = {
      port = 6057, memory = "512Mi", min = 0, max = 2, is_public = false
    }
    "${var.env}-financial-service" = {
      port = 6055, memory = "512Mi", min = 0, max = 3, is_public = false
    }
    "${var.env}-transportation-service" = {
      port = 6051, memory = "512Mi", min = 0, max = 3, is_public = false
    }
    "${var.env}-booking-service" = {
      port = 6062, memory = "512Mi", min = 0, max = 3, is_public = false
    }
    "${var.env}-aaccomodation-service" = {
      port = 6050, memory = "512Mi", min = 0, max = 3, is_public = false
    }
    "${var.env}-ai-service" = {
      port = 6056, memory = "1Gi", min = 0, max = 2, is_public = false
    }
    "${var.env}-assets-service" = {
      port = 6058, memory = "512Mi", min = 0, max = 3, is_public = false
    }
    "${var.env}-ih-subscription-service" = {
      port = 6054, memory = "512Mi", min = 0, max = 2, is_public = false
    }
    "${var.env}-ih-voucher-processing-service" = {
      port = 6065, memory = "512Mi", min = 0, max = 2, is_public = false
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
# 8. MONITORING (optional for RC)
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

output "gateway_url" {
  value = module.b2c_services["${var.env}-ih-spring-gw-service"].url
}

output "cloud_run_urls" {
  value = { for k, v in module.b2c_services : k => v.url }
}

output "cloud_run_sa" {
  value = google_service_account.cloud_run_sa.email
}
