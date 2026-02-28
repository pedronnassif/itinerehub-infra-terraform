###############################################################################
# Itinerehub Intelligence – DEV
# GCP Project: itinerehub-intelligence
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
    prefix = "intelligence/dev"
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

# ---------- Variables -------------------------------------------------------

variable "project_id" {
  type    = string
  default = "itinerehub-intelligence"
}

variable "region" {
  type    = string
  default = "us-central1"
}

variable "zone" {
  type    = string
  default = "us-central1-a"
}

###############################################################################
# VM UPTIME SCHEDULE – dev-claude-agents
#
# Stop at 01:00 KSA (Asia/Riyadh), Start at 07:00 KSA (Asia/Riyadh)
###############################################################################

resource "google_compute_resource_policy" "dev_claude_agents_schedule" {
  name    = "dev-claude-agents-uptime"
  project = var.project_id
  region  = var.region

  instance_schedule_policy {
    vm_start_schedule {
      schedule = "0 7 * * *"
    }
    vm_stop_schedule {
      schedule = "0 1 * * *"
    }
    time_zone = "Asia/Riyadh"
  }
}

resource "google_compute_instance_resource_policy_attachment" "dev_claude_agents" {
  name     = google_compute_resource_policy.dev_claude_agents_schedule.name
  project  = var.project_id
  zone     = var.zone
  instance = "dev-claude-agents"
}
