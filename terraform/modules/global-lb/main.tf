###############################################################################
# Module: global-lb
# Creates a Global HTTPS Load Balancer with Cloud Armor (WAF/DDoS),
# Cloud CDN, managed SSL certificate, and Serverless NEG pointing
# to a Cloud Run service (the gateway).
#
# Architecture:
#   Internet → Cloud Armor → HTTPS LB → Cloud CDN → Serverless NEG → Cloud Run
###############################################################################

# ---------- Variables -------------------------------------------------------

variable "project_id" {
  type = string
}

variable "region" {
  type = string
}

variable "env" {
  type = string
}

variable "name_prefix" {
  description = "Prefix for all resource names (e.g. 'b2c' or 'b2b')"
  type        = string
}

variable "cloud_run_service_name" {
  description = "Name of the Cloud Run gateway service to route to"
  type        = string
}

variable "domain" {
  description = "Custom domain for the managed SSL cert (e.g. api.itinerehub.com). Empty = no managed cert."
  type        = string
  default     = ""
}

variable "enable_cdn" {
  description = "Enable Cloud CDN on the backend service"
  type        = bool
  default     = true
}

variable "cdn_default_ttl" {
  description = "Default CDN cache TTL in seconds"
  type        = number
  default     = 300
}

variable "cdn_max_ttl" {
  description = "Maximum CDN cache TTL in seconds"
  type        = number
  default     = 3600
}

variable "ssl_min_tls_version" {
  description = "Minimum TLS version (TLS_1_0, TLS_1_1, TLS_1_2)"
  type        = string
  default     = "TLS_1_2"
}

variable "armor_rate_limit_count" {
  description = "Max requests per interval per IP before rate limiting"
  type        = number
  default     = 500
}

variable "armor_rate_limit_interval_sec" {
  description = "Rate limit interval in seconds"
  type        = number
  default     = 60
}

variable "armor_ban_duration_sec" {
  description = "How long to ban an IP after exceeding rate limit"
  type        = number
  default     = 600
}

###############################################################################
# 1. CLOUD ARMOR – Security Policy (WAF + DDoS + Rate Limiting)
###############################################################################

resource "google_compute_security_policy" "waf" {
  project = var.project_id
  name    = "${var.env}-${var.name_prefix}-waf-policy"

  # --- Default rule: ALLOW ------------------------------------------------
  rule {
    action   = "allow"
    priority = 2147483647
    match {
      versioned_expr = "SRC_IPS_V1"
      config {
        src_ip_ranges = ["*"]
      }
    }
    description = "Default allow"
  }

  # --- OWASP Top 10: SQL injection ----------------------------------------
  rule {
    action   = "deny(403)"
    priority = 1000
    match {
      expr {
        expression = "evaluatePreconfiguredExpr('sqli-v33-stable')"
      }
    }
    description = "Block SQL injection (OWASP CRS v3.3)"
  }

  # --- OWASP Top 10: Cross-site scripting ---------------------------------
  rule {
    action   = "deny(403)"
    priority = 1001
    match {
      expr {
        expression = "evaluatePreconfiguredExpr('xss-v33-stable')"
      }
    }
    description = "Block XSS attacks (OWASP CRS v3.3)"
  }

  # --- OWASP Top 10: Local file inclusion ----------------------------------
  rule {
    action   = "deny(403)"
    priority = 1002
    match {
      expr {
        expression = "evaluatePreconfiguredExpr('lfi-v33-stable')"
      }
    }
    description = "Block local file inclusion"
  }

  # --- OWASP Top 10: Remote file inclusion ---------------------------------
  rule {
    action   = "deny(403)"
    priority = 1003
    match {
      expr {
        expression = "evaluatePreconfiguredExpr('rfi-v33-stable')"
      }
    }
    description = "Block remote file inclusion"
  }

  # --- OWASP Top 10: Remote code execution ---------------------------------
  rule {
    action   = "deny(403)"
    priority = 1004
    match {
      expr {
        expression = "evaluatePreconfiguredExpr('rce-v33-stable')"
      }
    }
    description = "Block remote code execution"
  }

  # --- OWASP Top 10: Scanner detection ------------------------------------
  rule {
    action   = "deny(403)"
    priority = 1005
    match {
      expr {
        expression = "evaluatePreconfiguredExpr('scannerdetection-v33-stable')"
      }
    }
    description = "Block known vulnerability scanners"
  }

  # --- OWASP Top 10: Protocol attack --------------------------------------
  rule {
    action   = "deny(403)"
    priority = 1006
    match {
      expr {
        expression = "evaluatePreconfiguredExpr('protocolattack-v33-stable')"
      }
    }
    description = "Block HTTP protocol attacks"
  }

  # --- OWASP Top 10: Session fixation -------------------------------------
  rule {
    action   = "deny(403)"
    priority = 1007
    match {
      expr {
        expression = "evaluatePreconfiguredExpr('sessionfixation-v33-stable')"
      }
    }
    description = "Block session fixation attacks"
  }

  # --- Rate limiting per IP -----------------------------------------------
  rule {
    action   = "rate_based_ban"
    priority = 2000
    match {
      versioned_expr = "SRC_IPS_V1"
      config {
        src_ip_ranges = ["*"]
      }
    }
    rate_limit_options {
      rate_limit_threshold {
        count        = var.armor_rate_limit_count
        interval_sec = var.armor_rate_limit_interval_sec
      }
      ban_duration_sec = var.armor_ban_duration_sec
      conform_action   = "allow"
      exceed_action    = "deny(429)"
      enforce_on_key   = "IP"
    }
    description = "Rate limit: ${var.armor_rate_limit_count} req/${var.armor_rate_limit_interval_sec}s per IP"
  }

  # --- Adaptive Protection (ML-based DDoS detection) ----------------------
  adaptive_protection_config {
    layer_7_ddos_defense_config {
      enable = true
    }
  }
}

###############################################################################
# 2. SSL POLICY (TLS 1.2+ minimum)
###############################################################################

resource "google_compute_ssl_policy" "tls" {
  project         = var.project_id
  name            = "${var.env}-${var.name_prefix}-ssl-policy"
  min_tls_version = var.ssl_min_tls_version
  profile         = "MODERN"
}

###############################################################################
# 3. MANAGED SSL CERTIFICATE (optional – requires domain)
###############################################################################

resource "google_compute_managed_ssl_certificate" "cert" {
  count   = var.domain != "" ? 1 : 0
  project = var.project_id
  name    = "${var.env}-${var.name_prefix}-ssl-cert"

  managed {
    domains = [var.domain]
  }
}

###############################################################################
# 4. SERVERLESS NEG → Cloud Run
###############################################################################

resource "google_compute_region_network_endpoint_group" "gateway_neg" {
  project               = var.project_id
  name                  = "${var.env}-${var.name_prefix}-gateway-neg"
  region                = var.region
  network_endpoint_type = "SERVERLESS"

  cloud_run {
    service = var.cloud_run_service_name
  }
}

###############################################################################
# 5. BACKEND SERVICE (+ Cloud Armor + Cloud CDN)
###############################################################################

resource "google_compute_backend_service" "gateway" {
  project = var.project_id
  name    = "${var.env}-${var.name_prefix}-gateway-backend"

  protocol              = "HTTPS"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  security_policy       = google_compute_security_policy.waf.id

  # Cloud CDN
  enable_cdn = var.enable_cdn
  dynamic "cdn_policy" {
    for_each = var.enable_cdn ? [1] : []
    content {
      cache_mode                   = "CACHE_ALL_STATIC"
      default_ttl                  = var.cdn_default_ttl
      max_ttl                      = var.cdn_max_ttl
      negative_caching             = true
      serve_while_stale            = 86400
      signed_url_cache_max_age_sec = 0
    }
  }

  log_config {
    enable      = true
    sample_rate = 1.0
  }

  backend {
    group = google_compute_region_network_endpoint_group.gateway_neg.id
  }
}

###############################################################################
# 6. URL MAP
###############################################################################

resource "google_compute_url_map" "gateway" {
  project         = var.project_id
  name            = "${var.env}-${var.name_prefix}-url-map"
  default_service = google_compute_backend_service.gateway.id
}

###############################################################################
# 7. HTTPS PROXY
###############################################################################

# With managed SSL cert (custom domain)
resource "google_compute_target_https_proxy" "gateway" {
  count   = var.domain != "" ? 1 : 0
  project = var.project_id
  name    = "${var.env}-${var.name_prefix}-https-proxy"
  url_map = google_compute_url_map.gateway.id

  ssl_certificates = [google_compute_managed_ssl_certificate.cert[0].id]
  ssl_policy       = google_compute_ssl_policy.tls.id
}

# Without custom domain (self-signed / no cert – HTTP proxy for testing)
resource "google_compute_target_http_proxy" "gateway_http" {
  count   = var.domain == "" ? 1 : 0
  project = var.project_id
  name    = "${var.env}-${var.name_prefix}-http-proxy"
  url_map = google_compute_url_map.gateway.id
}

###############################################################################
# 8. GLOBAL FORWARDING RULE (Static IP + listener)
###############################################################################

resource "google_compute_global_address" "lb_ip" {
  project = var.project_id
  name    = "${var.env}-${var.name_prefix}-lb-ip"
}

# HTTPS forwarding rule (when domain is set)
resource "google_compute_global_forwarding_rule" "https" {
  count                 = var.domain != "" ? 1 : 0
  project               = var.project_id
  name                  = "${var.env}-${var.name_prefix}-https-rule"
  ip_address            = google_compute_global_address.lb_ip.address
  ip_protocol           = "TCP"
  port_range            = "443"
  target                = google_compute_target_https_proxy.gateway[0].id
  load_balancing_scheme = "EXTERNAL_MANAGED"
}

# HTTP forwarding rule (fallback / redirect target, or for testing without domain)
resource "google_compute_global_forwarding_rule" "http" {
  project               = var.project_id
  name                  = "${var.env}-${var.name_prefix}-http-rule"
  ip_address            = google_compute_global_address.lb_ip.address
  ip_protocol           = "TCP"
  port_range            = "80"
  target                = var.domain != "" ? google_compute_target_https_proxy.gateway[0].id : google_compute_target_http_proxy.gateway_http[0].id
  load_balancing_scheme = "EXTERNAL_MANAGED"
}

###############################################################################
# OUTPUTS
###############################################################################

output "lb_ip_address" {
  description = "Global static IP of the load balancer"
  value       = google_compute_global_address.lb_ip.address
}

output "security_policy_id" {
  description = "Cloud Armor security policy ID"
  value       = google_compute_security_policy.waf.id
}

output "backend_service_id" {
  description = "Backend service ID"
  value       = google_compute_backend_service.gateway.id
}

output "cdn_enabled" {
  value = var.enable_cdn
}

output "url_map_id" {
  value = google_compute_url_map.gateway.id
}
