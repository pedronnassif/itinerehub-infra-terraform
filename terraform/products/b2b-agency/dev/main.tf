###############################################################################
# Itinerehub B2B Agency – DEV
# GCP Project: aitinereagency (775123275503)
# Region:      us-central1
#
# Modular config using shared modules – mirrors the prod structure
# but with dev-appropriate sizing and security settings.
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
    prefix = "b2b-agency/dev"
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

# ---------- Variables -------------------------------------------------------
variable "project_id" {
  type    = string
  default = "aitinereagency"
}

variable "region" {
  type    = string
  default = "us-central1"
}

variable "env" {
  type    = string
  default = "dev"
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
    "cloudscheduler.googleapis.com",
    "identitytoolkit.googleapis.com",
    "aiplatform.googleapis.com",
    "vision.googleapis.com",
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
  primary_cidr     = "10.20.0.0/24"
  serverless_cidr  = "10.20.1.0/28"
  redis_cidr       = "10.20.2.0/28"
  enable_flow_logs = false
  enable_cloud_nat = false             # Cloud Run uses Direct VPC Egress, no NAT needed
}

###############################################################################
# 2. CLOUD SQL – PostgreSQL 16
###############################################################################

module "database" {
  source = "../../../modules/postgresql-database"

  env                    = var.env
  project_id             = var.project_id
  region                 = var.region
  vpc_network_id         = module.networking.vpc_id
  private_vpc_connection = module.networking.private_vpc_connection
  tier                   = "db-f1-micro"
  ha                     = false
  disk_size_gb           = 10
  app_user_password      = var.db_password
  backup_location        = "us"
  retained_backups       = 7

  databases = [
    "accommodationManagementService",
    "agencyManagementService",
    "customerManagementService",
    "dashboardManagementService",
    "documentManagementService",
    "expenseManagementService",
    "flightManagementService",
    "intelligentSearchService",
    "invoiceManagementService",
    "llmService",
    "localization",
    "locationService",
    "mobilityManagementService",
    "notificationService",
    "personManagementService",
    "transportManagementService",
    "travelerManagementService",
    "tripManagementService",
    "tripOperationsManagementService",
  ]
}

###############################################################################
# 3. ARTIFACT REGISTRY
###############################################################################

resource "google_artifact_registry_repository" "develop" {
  project       = var.project_id
  location      = var.region
  repository_id = "ith-docker-dev"
  format        = "DOCKER"
  description   = "B2B Agency dev Docker images"

  cleanup_policies {
    id     = "keep-recent"
    action = "KEEP"
    most_recent_versions {
      keep_count = 3
    }
  }

  cleanup_policies {
    id     = "delete-old-untagged"
    action = "DELETE"
    condition {
      older_than = "604800s"   # 7 days
      tag_state  = "UNTAGGED"
    }
  }
}

###############################################################################
# 4. SERVICE ACCOUNTS
###############################################################################

# CI/CD SA (Bitbucket pipelines)
resource "google_service_account" "cicd" {
  project      = var.project_id
  account_id   = "${var.env}-bitbucket-sa"
  display_name = "B2B Dev Bitbucket CI/CD"
}

# Cloud Run SA
resource "google_service_account" "cloud_run_sa" {
  project      = var.project_id
  account_id   = "${var.env}-cloudrun-sa"
  display_name = "B2B Dev Cloud Run SA"
}

# Pub/Sub SA
resource "google_service_account" "pubsub_sa" {
  project      = var.project_id
  account_id   = "${var.env}-pubsub-sa"
  display_name = "B2B Dev Pub/Sub SA"
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

###############################################################################
# 5. GCS BUCKETS
###############################################################################

resource "google_storage_bucket" "agent_portal" {
  name          = "ith-agent-portal-${var.env}"
  project       = var.project_id
  location      = var.region
  storage_class = "STANDARD"

  uniform_bucket_level_access = true
}

resource "google_storage_bucket" "assets" {
  name          = "itinerehub-assets-${var.env}"
  project       = var.project_id
  location      = var.region
  storage_class = "STANDARD"

  uniform_bucket_level_access = true
}

###############################################################################
# 6. PUB/SUB
###############################################################################

module "notification_topic" {
  source            = "../../../modules/pubsub"
  project_id        = var.project_id
  topic_name        = "ih_pubsub_notification_${var.env}"
  subscription_name = "ih_pubsub_notification_${var.env}-sub"
}

module "file_upload_request" {
  source            = "../../../modules/pubsub"
  project_id        = var.project_id
  topic_name        = "ih_file_upload_request_${var.env}"
  subscription_name = "ih_file_upload_request_${var.env}-sub"
}

module "file_upload_response" {
  source            = "../../../modules/pubsub"
  project_id        = var.project_id
  topic_name        = "ih_file_upload_response_${var.env}"
  subscription_name = "ih_file_upload_response_${var.env}-sub"
}

module "traveler_management" {
  source            = "../../../modules/pubsub"
  project_id        = var.project_id
  topic_name        = "ih-traveler-management-${var.env}"
  subscription_name = "ih-traveler-management-${var.env}-sub"
}

module "trip_management" {
  source     = "../../../modules/pubsub"
  project_id = var.project_id
  topic_name = "ih-trip-management-${var.env}"
}

###############################################################################
# 7. CLOUD RUN – B2B SERVICES (dev: max 1 instance, port 8080)
###############################################################################

locals {
  image_base = "${var.region}-docker.pkg.dev/${var.project_id}/ith-docker-dev"

  b2b_services = {
    "api-gateway-${var.env}" = {
      memory = "1Gi", min = 0, max = 1, is_public = true
    }
    "accommodation-management-service-${var.env}" = {
      memory = "512Mi", min = 0, max = 1, is_public = false
    }
    "agency-management-service-${var.env}" = {
      memory = "512Mi", min = 0, max = 1, is_public = false
    }
    "customer-management-service-${var.env}" = {
      memory = "512Mi", min = 0, max = 1, is_public = false
    }
    "dashboard-management-service-${var.env}" = {
      memory = "512Mi", min = 0, max = 1, is_public = false
    }
    "document-management-service-${var.env}" = {
      memory = "512Mi", min = 0, max = 1, is_public = false
    }
    "expense-management-service-${var.env}" = {
      memory = "512Mi", min = 0, max = 1, is_public = false
    }
    "flight-management-service-${var.env}" = {
      memory = "512Mi", min = 0, max = 1, is_public = false
    }
    "intelligent-search-service-${var.env}" = {
      memory = "1Gi", min = 0, max = 1, is_public = false
    }
    "invoice-management-service-${var.env}" = {
      memory = "512Mi", min = 0, max = 1, is_public = false
    }
    "llm-service-${var.env}" = {
      memory = "1Gi", min = 0, max = 1, is_public = false
    }
    "location-service-${var.env}" = {
      memory = "512Mi", min = 0, max = 1, is_public = false
    }
    "mobility-management-service-${var.env}" = {
      memory = "512Mi", min = 0, max = 1, is_public = false
    }
    "notification-service-${var.env}" = {
      memory = "512Mi", min = 0, max = 1, is_public = false
    }
    "person-management-service-${var.env}" = {
      memory = "512Mi", min = 0, max = 1, is_public = false
    }
    "transport-management-service-${var.env}" = {
      memory = "512Mi", min = 0, max = 1, is_public = false
    }
    "traveler-management-service-${var.env}" = {
      memory = "512Mi", min = 0, max = 1, is_public = false
    }
    "trip-management-service-${var.env}" = {
      memory = "512Mi", min = 0, max = 1, is_public = false
    }
    "trip-operations-management-service-${var.env}" = {
      memory = "512Mi", min = 0, max = 1, is_public = false
    }
  }
}

module "b2b_services" {
  source   = "../../../modules/cloud-run-service"
  for_each = local.b2b_services

  name                    = each.key
  project_id              = var.project_id
  region                  = var.region
  image                   = "${local.image_base}/${each.key}:latest"
  port                    = 8080 # B2B uses uniform port
  memory                  = each.value.memory
  min_instances           = each.value.min
  max_instances           = each.value.max
  service_account_email   = google_service_account.cloud_run_sa.email
  vpc_network             = module.networking.vpc_name
  vpc_subnet              = module.networking.primary_subnet_name
  is_public               = each.value.is_public
  invoker_service_account = each.value.is_public ? "" : google_service_account.cloud_run_sa.email
}

###############################################################################
# 8. MONITORING (optional for dev)
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
  value = module.b2b_services["api-gateway-${var.env}"].url
}

output "cloud_run_urls" {
  value = { for k, v in module.b2b_services : k => v.url }
}

output "cloud_run_sa" {
  value = google_service_account.cloud_run_sa.email
}

output "cicd_sa" {
  value = google_service_account.cicd.email
}
