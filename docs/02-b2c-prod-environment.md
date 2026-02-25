# Itinerehub B2C - Production Environment Design

**Target Project:** aitinerehub-b2c-prod (800590950952)
**Region:** us-central1 (Iowa, USA) - lowest cost tier 1 region
**Date:** 2026-02-22
**Updated:** 2026-02-25
**Terraform Path:** `terraform/products/b2c-backend/prod/`
**Remote State:** `gs://itinerehub-tf-state/b2c-backend/prod`

> **Note:** As of Feb 2025, B2C and B2B are separate GCP projects with independent
> Terraform configurations. The B2B Agency production environment is documented in
> [05-b2b-prod-environment.md](05-b2b-prod-environment.md). Three former B2B services
> (document-management, llm, location-b2b) that previously ran in this project have
> been moved to the B2B project.

### Environment Tiers

| Env | GCP Project | Terraform Path | State Prefix | Region |
|-----|-------------|----------------|--------------|--------|
| **Dev** | `aitinerehub` | `terraform/products/b2c-backend/dev/` | `b2c-backend/dev` | me-central1 |
| **Staging** | `aitinerehub` | `terraform/products/b2c-backend/staging/` | `b2c-backend/staging` | me-central1 |
| **Prod** | `aitinerehub-b2c-prod` | `terraform/products/b2c-backend/prod/` | `b2c-backend/prod` | us-central1 |

> Staging shares the `aitinerehub` GCP project with dev but uses a separate VPC (10.1.x CIDRs),
> its own service accounts, and a lightweight DB (`db-g1-small`). Traffic hits Cloud Run
> directly (no LB/Armor) to save cost — the full security stack is only deployed in prod.

---

## 1. Architecture Overview

The production environment follows the same microservices pattern as dev but with critical improvements for security, reliability, and cost optimization.

```
                    ┌─────────────────┐
                    │   Mobile App    │
                    └────────┬────────┘
                             │ HTTPS
                    ┌────────▼────────┐
                    │  Cloud Armor    │  WAF: SQLi, XSS, LFI, RFI, RCE
                    │  (WAF + DDoS)   │  Rate limit: 500 req/60s per IP
                    └────────┬────────┘
                    ┌────────▼────────┐
                    │  Global HTTPS   │  TLS 1.2+, managed SSL cert
                    │  Load Balancer  │  Custom domain (api.itinerehub.com)
                    └────────┬────────┘
                    ┌────────▼────────┐
                    │   Cloud CDN     │  CACHE_ALL_STATIC, TTL 300s
                    └────────┬────────┘
                    ┌────────▼────────┐
                    │ Serverless NEG  │  Routes to Cloud Run
                    └────────┬────────┘
                    ┌────────▼────────┐
                    │  Spring Gateway │ (Cloud Run - always on)
                    │  prod-ih-spring │   min: 1, max: 10
                    │  -gw-service    │   port: 5049
                    └────────┬────────┘
                             │ Internal (SA-authenticated)
           ┌─────────────────┼─────────────────┐
           │                 │                 │
    ┌──────▼──────┐  ┌──────▼──────┐  ┌──────▼──────┐
    │ User Service│  │ Trip Service│  │  Location   │  ... (14 B2C services)
    │ min:0 max:10│  │ min:0 max:10│  │ min:0 max:10│  Private access
    └──────┬──────┘  └──────┬──────┘  └──────┬──────┘
           │                │                │
    ┌──────▼────────────────▼────────────────▼──────┐
    │         Cloud SQL (MySQL 8.0) - HA             │
    │         db-custom-2-4096 | Private-only        │
    │         SSL enforced | 20 GB SSD               │
    └───────────────────────┬────────────────────────┘
                            │ Private Service Access
                     ┌──────▼──────┐
                     │ Memorystore │
                     │ Redis 7.2   │
                     │ 1 GB BASIC  │
                     └─────────────┘
```

## 2. Key Differences from Dev

| Aspect | Dev Environment | Production |
|--------|----------------|------------|
| **Region** | me-central1 (Doha) | us-central1 (Iowa) |
| **Cloud SQL tier** | db-f1-micro (shared) | db-custom-2-4096 (dedicated) |
| **Cloud SQL HA** | Zonal | Regional (automatic failover) |
| **Cloud SQL public IP** | Enabled + developer IPs | Disabled (private only) |
| **SSL/TLS** | Not enforced | ENCRYPTED_ONLY |
| **Redis** | Self-managed VM (e2-custom) | Memorystore (managed) |
| **VPC egress** | VPC Connector (e2-micro x2) | Direct VPC Egress (no overhead) |
| **Cloud Run scaling** | Max 1 instance | 0-10 instances (auto) |
| **Cloud Run memory** | 1 Gi (all services) | 512Mi-1Gi (right-sized) |
| **Service auth** | All services public | Only gateway public |
| **Secrets** | Hardcoded in env vars | Secret Manager references |
| **Monitoring** | None configured | CPU, error rate alerts |
| **Backups** | 7 days | 14 days + PITR |
| **GCS lifecycle** | None | Nearline at 90d, Coldline at 365d |
| **Registry cleanup** | None | Keep 10 recent, delete untagged after 30d |
| **Cloud NAT** | Not configured | Configured for outbound traffic |
| **Firewall** | Permissive (0.0.0.0/0 HTTP/S) | Default deny, explicit allow |
| **Flow logs** | Disabled | Enabled on primary subnet |
| **WAF / Cloud Armor** | None | OWASP CRS v3.3 rules + rate limiting |
| **Load Balancer** | None (direct Cloud Run) | Global HTTPS LB + Cloud CDN |
| **SSL Policy** | N/A | TLS 1.2+ MODERN profile |
| **Audit Logging** | None | Data Access logs on all critical services |

## 3. Networking Design

### VPC: `prod-itinerehub-vpc`

| Subnet | CIDR | Purpose |
|--------|------|---------|
| `prod-itinerehub-primary` | 10.10.0.0/24 | Cloud SQL, general workloads |
| `prod-itinerehub-serverless` | 10.10.1.0/28 | Cloud Run VPC connector (backup) |
| `prod-itinerehub-redis` | 10.10.2.0/28 | Memorystore Redis |
| Private Services (peering) | /20 auto-allocated | Cloud SQL private IP |

### Firewall Rules (Restrictive)

| Rule | Source | Allow | Priority |
|------|--------|-------|----------|
| Health checks | GCP LB ranges | TCP (all) | 1000 |
| IAP SSH | 35.235.240.0/20 | TCP:22 | 1000 |
| Internal | 10.10.0.0/16 | All | 65534 |
| Deny all ingress | 0.0.0.0/0 | DENY | 65535 |

### Cloud NAT

Configured for outbound internet access from private resources (Redis, Cloud SQL) without public IPs.

## 4. Cloud SQL Production Configuration

```
Instance:        prod-ih-db-cluster
Version:         MySQL 8.0 (latest stable)
Tier:            db-custom-2-4096 (2 vCPU, 4 GB RAM)
HA:              REGIONAL (automatic failover)
Disk:            20 GB PD-SSD, auto-resize
Public IP:       DISABLED
SSL:             ENCRYPTED_ONLY
User:            app-user (not root)
Backups:         Daily at 03:00 UTC, 14 retained, US location
PITR:            Enabled
Query Insights:  Enabled with app tags
Slow query log:  Enabled (threshold: 1 second)
Maintenance:     Sundays 04:00 UTC, stable track
```

## 5. Memorystore Redis (replaces VM)

```
Instance:      prod-ih-redis
Version:       Redis 7.2
Tier:          BASIC (1 GB) - upgrade to STANDARD_HA when needed
Network:       Private Service Access (no public IP)
Policy:        allkeys-lru
Maintenance:   Sundays 04:00 UTC
```

**Cost comparison:**
- Dev: e2-custom-medium-1024 VM = ~$25/month + management overhead
- Prod: Memorystore BASIC 1GB = ~$35/month but fully managed, no patching

## 6. Cloud Run Configuration

### Resource Profiles

| Service Type | CPU | Memory | Min | Max | cpu_idle |
|-------------|-----|--------|-----|-----|----------|
| Gateway | 1000m | 1Gi | 1 | 10 | true |
| Core services (user, trip, etc.) | 1000m | 512Mi | 0 | 10 | true |
| AI/LLM services | 1000m | 1Gi | 0 | 5 | true |
| Background services (voucher, subscription) | 1000m | 512Mi | 0 | 5 | true |
| Mobility service | 1000m | 512Mi | 0 | 5 | true |

### B2C Services (14 total)

| # | Service | Port | Memory | Min/Max |
|---|---------|------|--------|---------|
| 1 | `prod-ih-spring-gw-service` (Gateway) | 5049 | 1Gi | 1/10 |
| 2 | `prod-user-service` | 5050 | 512Mi | 0/10 |
| 3 | `prod-trip-service` | 5051 | 512Mi | 0/10 |
| 4 | `prod-location-service` | 5052 | 512Mi | 0/10 |
| 5 | `prod-notification-service` | 5053 | 512Mi | 0/5 |
| 6 | `prod-financial-service` | 5054 | 512Mi | 0/10 |
| 7 | `prod-transportation-service` | 5055 | 512Mi | 0/10 |
| 8 | `prod-booking-service` | 5056 | 512Mi | 0/10 |
| 9 | `prod-aaccomodation-service` | 5057 | 512Mi | 0/10 |
| 10 | `prod-ai-service` | 5058 | 1Gi | 0/5 |
| 11 | `prod-assets-service` | 5059 | 512Mi | 0/10 |
| 12 | `prod-ih-subscription-service` | 5060 | 512Mi | 0/5 |
| 13 | `prod-ih-voucher-processing-service` | 5061 | 512Mi | 0/5 |
| 14 | `prod-mobility-service` | 5065 | 512Mi | 0/5 |

### Key Settings

- **Direct VPC Egress:** Eliminates VPC connector cost (~$7/month per connector)
- **cpu_idle: true:** CPU is only allocated during request processing (cost saving)
- **Health checks:** HTTP-based startup and liveness probes via `/actuator/health`
- **Timeout:** 300s
- **Service account:** Dedicated `prod-cloud-run-sa` (not default compute SA)

### Access Control

- **Gateway:** Public (`allUsers` invoker)
- **All other services:** Private (only invokable by `prod-cloud-run-sa`)

## 7. Artifact Registry

```
Repository:     production (Docker)
Cleanup:        Keep 10 most recent versions, delete untagged after 30 days
Maven:          production-pkg

Estimated savings: ~50-100 GB storage reduction per year from cleanup policies
```

## 8. GCS Buckets

| Bucket | Features |
|--------|----------|
| `prod-ih-service-bucket` | Versioning, lifecycle (Nearline@90d, Coldline@365d) |
| `prod-ih-assets-bucket` | CORS configured, uniform access |
| `prod-ih-user-bucket` | Versioning enabled |

## 9. Service Accounts (Least Privilege)

| Account | Roles |
|---------|-------|
| `prod-cicd` | run.admin, artifactregistry.writer, secretmanager.secretAccessor, iam.serviceAccountUser |
| `prod-cloud-run-sa` | secretmanager.secretAccessor, cloudsql.client, pubsub.publisher, pubsub.subscriber, storage.objectViewer, logging.logWriter, cloudtrace.agent, monitoring.metricWriter |
| `prod-storage-sa` | storage.objectAdmin |

## 10. Security: Cloud Armor + HTTPS Load Balancer + CDN

### Global HTTPS Load Balancer

All external traffic enters through a Global HTTPS Load Balancer, providing:
- **TLS termination** with managed SSL certificate and TLS 1.2+ MODERN policy
- **Static global IP** for DNS (A record for `api.itinerehub.com`)
- **Serverless NEG** routing to the Spring Gateway Cloud Run service

### Cloud Armor (WAF + DDoS)

A `google_compute_security_policy` is attached to the backend service with:

| Rule | Priority | Action | Description |
|------|----------|--------|-------------|
| SQLi (CRS v3.3) | 1000 | deny(403) | Block SQL injection |
| XSS (CRS v3.3) | 1001 | deny(403) | Block cross-site scripting |
| LFI | 1002 | deny(403) | Block local file inclusion |
| RFI | 1003 | deny(403) | Block remote file inclusion |
| RCE | 1004 | deny(403) | Block remote code execution |
| Scanner detection | 1005 | deny(403) | Block known scanners |
| Protocol attack | 1006 | deny(403) | Block HTTP protocol attacks |
| Session fixation | 1007 | deny(403) | Block session fixation |
| Rate limit | 2000 | rate_based_ban | 500 req/60s per IP, 10 min ban |
| Default | max | allow | Allow all other traffic |

**Adaptive Protection:** ML-based Layer 7 DDoS detection is enabled.

### Cloud CDN

Enabled on the backend service with:
- **Cache mode:** CACHE_ALL_STATIC
- **Default TTL:** 300s (5 minutes)
- **Max TTL:** 3600s (1 hour)
- **Serve while stale:** 86400s (24 hours)

### Audit Logging

Data Access audit logs are enabled for: Cloud SQL, Cloud Run, Cloud Storage, Secret Manager, IAM, and Artifact Registry.

## 11. Monitoring & Alerting

| Alert | Condition | Duration |
|-------|-----------|----------|
| Cloud SQL CPU | > 80% utilization | 5 minutes |
| Cloud Run 5xx | > 5% error rate | 5 minutes |

**Recommended additions (post-launch):**
- Cloud SQL disk usage > 80%
- Cloud SQL connection count > threshold
- Cloud Run latency P99 > 5s
- Pub/Sub dead letter queue depth > 0
- Uptime checks on gateway endpoint

## 12. Cost Estimate (Monthly)

### B2C Production (new GCP project: `aitinerehub-b2c-prod`)

| Resource | Configuration | Est. Cost |
|----------|--------------|-----------|
| Cloud SQL (HA) | db-custom-2-4096, REGIONAL | ~$120-150 |
| Memorystore Redis | BASIC 1GB | ~$35 |
| Cloud Run (14 services) | Scale to 0, cpu_idle | ~$30-80 |
| HTTPS Load Balancer | Global, forwarding rules | ~$18-25 |
| Cloud Armor | WAF policy + adaptive protection | ~$5-10 |
| Cloud CDN | Cache egress savings | ~$1-5 |
| GCS Storage | ~50 GB | ~$1-2 |
| Artifact Registry | ~30 GB | ~$3 |
| Pub/Sub | Low volume | ~$1-5 |
| Networking (egress) | ~100 GB/month | ~$8-12 |
| **Prod Total** | | **~$220-330/month** |

### B2C Staging (same GCP project as dev: `aitinerehub`)

| Resource | Configuration | Est. Cost |
|----------|--------------|-----------|
| Cloud SQL | db-g1-small, ZONAL (no HA) | ~$25-30 |
| Memorystore Redis | BASIC 1GB | ~$35 |
| Cloud Run (14 services) | Scale to 0, max 2-3 | ~$10-25 |
| GCS Storage | ~10 GB | ~$0.50 |
| Artifact Registry | ~10 GB | ~$1 |
| Pub/Sub | Low volume | ~$1-3 |
| Networking (egress) | ~20 GB/month | ~$2-4 |
| **Staging Total** | | **~$75-100/month** |

> Staging accesses Cloud Run directly (no LB / Cloud Armor / CDN).
> The full security stack is tested in production only.

### New B2C Infrastructure Cost Summary

| Environment | Status | Est. Monthly Cost |
|-------------|--------|-------------------|
| Dev | Existing (no new cost) | — |
| **Staging** | **New** | **~$75-100** |
| **Prod** | **New** | **~$220-330** |
| **New monthly spend** | | **~$295-430/month** |

### Committed Use Discounts (CUDs)

For production Cloud SQL, consider purchasing a CUD to reduce the DB cost significantly:

| Commitment | Discount | Prod DB Cost (from ~$120-150) | Break-even |
|------------|----------|-------------------------------|------------|
| **1-year** | ~25% off | **~$90-113/month** | Month 1 |
| **3-year** | ~52% off | **~$58-72/month** | Month 1 |

**How to purchase:**
1. Go to [GCP Console → Billing → Committed use discounts](https://console.cloud.google.com/billing)
2. Select the `aitinerehub-b2c-prod` project
3. Choose **Cloud SQL** → region `us-central1`
4. Select the DB tier (`db-custom-2-4096`) and commit for 1 or 3 years
5. The discount applies automatically to matching instances — no changes to Terraform needed

> **Recommendation:** Start with a **1-year commitment** for the production Cloud SQL instance.
> This saves ~$30-38/month with no risk since the DB will run continuously.
> Evaluate 3-year once the platform is stable and traffic patterns are understood.

**Notes:**
- Cloud Run with `cpu_idle: true` and `min_instances: 0` provides massive savings during low-traffic periods
- us-central1 (prod) is GCP's cheapest tier-1 region
- Cloud NAT is not deployed (Cloud Run uses Direct VPC Egress)
- The db-custom-2-4096 tier can be downgraded to db-f1-micro initially if budget is tight (~$10/month), but this is not recommended for production

## 13. Databases (14 schemas)

| Database | Purpose |
|----------|---------|
| `auth-db` | Authentication |
| `user-db` | User management |
| `trip-db` / `trip-service-db` | Trip management |
| `assets-db` | Digital assets |
| `notification-db` | Notifications |
| `location-db` | Location data |
| `financial-db` | Financial/payments |
| `transportation-db` | Transportation |
| `booking-db` | Bookings |
| `ai-db` | AI features |
| `accomodation-db` | Accommodation |
| `localization-db` | i18n/localization |
| `subscription-db` | Subscriptions |

## 14. Deployment Workflow

1. Create new GCP project (`aitinerehub-b2c-prod`)
2. Create the GCS bucket `itinerehub-tf-state` for remote state
3. `cd terraform/products/b2c-backend/prod/`
4. Run `terraform init` to initialise the GCS backend
5. Run `terraform plan -var-file=terraform.tfvars` to review
6. Run `terraform apply` to create infrastructure
7. Update GitHub Actions workflows with new project ID and service account
8. Deploy services via CI/CD
9. Configure custom domain (if applicable)
10. Set up monitoring dashboards
11. Perform load testing before go-live
