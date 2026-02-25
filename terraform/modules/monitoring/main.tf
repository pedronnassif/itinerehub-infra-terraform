###############################################################################
# Module: monitoring
# Creates basic monitoring alerts for Cloud SQL and Cloud Run.
###############################################################################

variable "project_id" {
  type = string
}

variable "alert_email" {
  description = "Email for alert notifications (empty = no alerts)"
  type        = string
  default     = ""
}

variable "env" {
  type = string
}

# ---------- Notification Channel -------------------------------------------
resource "google_monitoring_notification_channel" "email" {
  count        = var.alert_email != "" ? 1 : 0
  project      = var.project_id
  display_name = "${title(var.env)} Alerts"
  type         = "email"

  labels = {
    email_address = var.alert_email
  }
}

# ---------- Cloud SQL CPU ---------------------------------------------------
resource "google_monitoring_alert_policy" "sql_cpu" {
  count        = var.alert_email != "" ? 1 : 0
  project      = var.project_id
  display_name = "${title(var.env)} - Cloud SQL CPU > 80%"
  combiner     = "OR"

  conditions {
    display_name = "CPU utilization"
    condition_threshold {
      filter          = "resource.type = \"cloudsql_database\" AND metric.type = \"cloudsql.googleapis.com/database/cpu/utilization\""
      comparison      = "COMPARISON_GT"
      threshold_value = 0.8
      duration        = "300s"
      aggregations {
        alignment_period   = "60s"
        per_series_aligner = "ALIGN_MEAN"
      }
    }
  }

  notification_channels = [google_monitoring_notification_channel.email[0].name]
}

# ---------- Cloud SQL Disk --------------------------------------------------
resource "google_monitoring_alert_policy" "sql_disk" {
  count        = var.alert_email != "" ? 1 : 0
  project      = var.project_id
  display_name = "${title(var.env)} - Cloud SQL Disk > 80%"
  combiner     = "OR"

  conditions {
    display_name = "Disk utilization"
    condition_threshold {
      filter          = "resource.type = \"cloudsql_database\" AND metric.type = \"cloudsql.googleapis.com/database/disk/utilization\""
      comparison      = "COMPARISON_GT"
      threshold_value = 0.8
      duration        = "300s"
      aggregations {
        alignment_period   = "60s"
        per_series_aligner = "ALIGN_MEAN"
      }
    }
  }

  notification_channels = [google_monitoring_notification_channel.email[0].name]
}

# ---------- Cloud Run 5xx ---------------------------------------------------
resource "google_monitoring_alert_policy" "run_errors" {
  count        = var.alert_email != "" ? 1 : 0
  project      = var.project_id
  display_name = "${title(var.env)} - Cloud Run 5xx Error Rate > 5%"
  combiner     = "OR"

  conditions {
    display_name = "5xx error rate"
    condition_threshold {
      filter          = "resource.type = \"cloud_run_revision\" AND metric.type = \"run.googleapis.com/request_count\" AND metric.labels.response_code_class = \"5xx\""
      comparison      = "COMPARISON_GT"
      threshold_value = 0.05
      duration        = "300s"
      aggregations {
        alignment_period   = "60s"
        per_series_aligner = "ALIGN_RATE"
      }
    }
  }

  notification_channels = [google_monitoring_notification_channel.email[0].name]
}
