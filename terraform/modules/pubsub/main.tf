###############################################################################
# Module: pubsub
# Creates a Pub/Sub topic with optional subscription and dead letter queue.
###############################################################################

variable "project_id" {
  type = string
}

variable "topic_name" {
  type = string
}

variable "subscription_name" {
  description = "Subscription name (empty = no subscription)"
  type        = string
  default     = ""
}

variable "dead_letter_topic_id" {
  description = "Dead letter topic ID (empty = no DLQ)"
  type        = string
  default     = ""
}

variable "ack_deadline_seconds" {
  type    = number
  default = 20
}

variable "message_retention" {
  description = "Message retention duration"
  type        = string
  default     = "604800s"
}

variable "max_delivery_attempts" {
  type    = number
  default = 5
}

# ---------- Topic -----------------------------------------------------------
resource "google_pubsub_topic" "topic" {
  name    = var.topic_name
  project = var.project_id
}

# ---------- Subscription (optional) ----------------------------------------
resource "google_pubsub_subscription" "subscription" {
  count = var.subscription_name != "" ? 1 : 0

  name    = var.subscription_name
  project = var.project_id
  topic   = google_pubsub_topic.topic.id

  ack_deadline_seconds       = var.ack_deadline_seconds
  message_retention_duration = var.message_retention
  retain_acked_messages      = false

  expiration_policy {
    ttl = ""
  }

  dynamic "dead_letter_policy" {
    for_each = var.dead_letter_topic_id != "" ? [1] : []
    content {
      dead_letter_topic     = var.dead_letter_topic_id
      max_delivery_attempts = var.max_delivery_attempts
    }
  }
}

# ---------- Outputs ---------------------------------------------------------
output "topic_id" {
  value = google_pubsub_topic.topic.id
}

output "topic_name" {
  value = google_pubsub_topic.topic.name
}
