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
# Start at 09:00 KSA, Stop at 23:00 KSA (14h/day)
# Cron orchestration fires at 10:00 KSA — 1h boot buffer
###############################################################################

resource "google_compute_resource_policy" "dev_claude_agents_schedule" {
  name    = "dev-claude-agents-uptime"
  project = var.project_id
  region  = var.region

  instance_schedule_policy {
    vm_start_schedule {
      schedule = "0 9 * * *"
    }
    vm_stop_schedule {
      schedule = "0 23 * * *"
    }
    time_zone = "Asia/Riyadh"
  }
}

resource "terraform_data" "attach_schedule_to_vm" {
  triggers_replace = [
    google_compute_resource_policy.dev_claude_agents_schedule.id,
  ]

  provisioner "local-exec" {
    command = <<-EOT
      gcloud compute instances add-resource-policies dev-claude-agents \
        --resource-policies=${google_compute_resource_policy.dev_claude_agents_schedule.name} \
        --zone=${var.zone} \
        --project=${var.project_id}
    EOT
  }

  provisioner "local-exec" {
    when    = destroy
    command = <<-EOT
      gcloud compute instances remove-resource-policies dev-claude-agents \
        --resource-policies=dev-claude-agents-uptime \
        --zone=us-central1-a \
        --project=itinerehub-intelligence
    EOT
  }
}
