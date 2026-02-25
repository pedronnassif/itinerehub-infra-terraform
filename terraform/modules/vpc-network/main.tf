###############################################################################
# Module: vpc-network
# Creates a VPC with subnets, Cloud NAT, firewall rules, and
# private service access (for Cloud SQL / Memorystore).
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

variable "primary_cidr" {
  description = "CIDR for the primary subnet"
  type        = string
  default     = "10.10.0.0/24"
}

variable "serverless_cidr" {
  description = "CIDR for serverless VPC connector subnet"
  type        = string
  default     = "10.10.1.0/28"
}

variable "redis_cidr" {
  description = "CIDR for Redis subnet"
  type        = string
  default     = "10.10.2.0/28"
}

variable "enable_flow_logs" {
  type    = bool
  default = true
}

variable "enable_cloud_nat" {
  description = "Create Cloud NAT. Only needed when VMs or GKE nodes require outbound internet. Cloud Run with Direct VPC Egress does NOT need NAT."
  type        = bool
  default     = false
}

variable "flow_log_sampling" {
  description = "Flow log sampling rate (0.0 to 1.0). Lower = cheaper. 0.5 is default, 0.1 recommended for prod cost savings."
  type        = number
  default     = 0.5
}

# ---------- VPC -------------------------------------------------------------
resource "google_compute_network" "vpc" {
  name                    = "${var.env}-itinerehub-vpc"
  project                 = var.project_id
  auto_create_subnetworks = false
  mtu                     = 1460
  routing_mode            = "REGIONAL"
}

# ---------- Subnets ---------------------------------------------------------
resource "google_compute_subnetwork" "primary" {
  name                     = "${var.env}-itinerehub-primary"
  project                  = var.project_id
  ip_cidr_range            = var.primary_cidr
  region                   = var.region
  network                  = google_compute_network.vpc.id
  private_ip_google_access = true

  dynamic "log_config" {
    for_each = var.enable_flow_logs ? [1] : []
    content {
      aggregation_interval = "INTERVAL_10_MIN"
      flow_sampling        = var.flow_log_sampling
      metadata             = "INCLUDE_ALL_METADATA"
    }
  }
}

resource "google_compute_subnetwork" "serverless" {
  name                     = "${var.env}-itinerehub-serverless"
  project                  = var.project_id
  ip_cidr_range            = var.serverless_cidr
  region                   = var.region
  network                  = google_compute_network.vpc.id
  private_ip_google_access = true
}

resource "google_compute_subnetwork" "redis" {
  name                     = "${var.env}-itinerehub-redis"
  project                  = var.project_id
  ip_cidr_range            = var.redis_cidr
  region                   = var.region
  network                  = google_compute_network.vpc.id
  private_ip_google_access = true
}

# ---------- Private Services Access -----------------------------------------
resource "google_compute_global_address" "private_ip_range" {
  name          = "${var.env}-itinerehub-vpc-ip-range"
  project       = var.project_id
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = 20
  network       = google_compute_network.vpc.id
}

resource "google_service_networking_connection" "private_vpc_connection" {
  network                 = google_compute_network.vpc.id
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.private_ip_range.name]
}

# ---------- Cloud NAT (conditional – only needed for VMs/GKE) ---------------
resource "google_compute_router" "router" {
  count   = var.enable_cloud_nat ? 1 : 0
  name    = "${var.env}-itinerehub-router"
  project = var.project_id
  region  = var.region
  network = google_compute_network.vpc.id
}

resource "google_compute_router_nat" "nat" {
  count                              = var.enable_cloud_nat ? 1 : 0
  name                               = "${var.env}-itinerehub-nat"
  project                            = var.project_id
  router                             = google_compute_router.router[0].name
  region                             = var.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}

# ---------- Firewall Rules --------------------------------------------------
resource "google_compute_firewall" "allow_health_checks" {
  name    = "${var.env}-allow-health-checks"
  project = var.project_id
  network = google_compute_network.vpc.name

  allow {
    protocol = "tcp"
  }

  source_ranges = [
    "35.191.0.0/16",
    "130.211.0.0/22",
    "209.85.152.0/22",
    "209.85.204.0/22",
  ]
  direction = "INGRESS"
  priority  = 1000
}

resource "google_compute_firewall" "allow_iap_ssh" {
  name    = "${var.env}-allow-iap-ssh"
  project = var.project_id
  network = google_compute_network.vpc.name

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges = ["35.235.240.0/20"]
  direction     = "INGRESS"
  priority      = 1000
}

resource "google_compute_firewall" "allow_internal" {
  name    = "${var.env}-allow-internal"
  project = var.project_id
  network = google_compute_network.vpc.name

  allow {
    protocol = "tcp"
    ports    = ["0-65535"]
  }
  allow {
    protocol = "udp"
    ports    = ["0-65535"]
  }
  allow {
    protocol = "icmp"
  }

  source_ranges = ["10.0.0.0/8"]
  direction     = "INGRESS"
  priority      = 65534
}

resource "google_compute_firewall" "deny_all_ingress" {
  name    = "${var.env}-deny-all-ingress"
  project = var.project_id
  network = google_compute_network.vpc.name

  deny {
    protocol = "all"
  }

  source_ranges = ["0.0.0.0/0"]
  direction     = "INGRESS"
  priority      = 65535
}

# ---------- Outputs ---------------------------------------------------------
output "vpc_id" {
  value = google_compute_network.vpc.id
}

output "vpc_name" {
  value = google_compute_network.vpc.name
}

output "primary_subnet_name" {
  value = google_compute_subnetwork.primary.name
}

output "primary_subnet_id" {
  value = google_compute_subnetwork.primary.id
}

output "private_vpc_connection" {
  value = google_service_networking_connection.private_vpc_connection
}
