# Itinerehub B2B Agency - Production Environment Design

**Target Project:** aitinereagency-prod (to be created)
**Region:** us-central1 (Iowa, USA) - lowest cost tier 1 region
**Date:** 2026-02-25
**Terraform Path:** `terraform/products/b2b-agency/prod/`
**Remote State:** `gs://itinerehub-tf-state/b2b-agency/prod`

> **Note:** B2B Agency is a separate GCP project from B2C. It uses PostgreSQL 16
> (not MySQL) and Bitbucket CI/CD (not GitHub Actions). For the B2C production
> environment, see [02-b2c-prod-environment.md](02-b2c-prod-environment.md).

### Environment Tiers

| Env | GCP Project | Terraform Path | State Prefix | Region |
|-----|-------------|----------------|--------------|--------|
| **Dev** | `aitinereagency` | `terraform/products/b2b-agency/dev/` | `b2b-agency/dev` | us-central1 |
| **Staging** | `aitinereagency` | `terraform/products/b2b-agency/staging/` | `b2b-agency/staging` | us-central1 |
| **Prod** | `aitinereagency-prod` | `terraform/products/b2b-agency/prod/` | `b2b-agency/prod` | us-central1 |

> Staging shares the `aitinereagency` GCP project with dev but uses a separate VPC (10.21.x CIDRs),
> its own service accounts, and a lightweight DB (`db-g1-small`). Traffic hits Cloud Run
> directly (no LB/Armor) to save cost — the full security stack is only deployed in prod.

---

## 1. Architecture Overview

The B2B Agency production environment is a microservices platform for travel agencies, running on Cloud Run with a PostgreSQL database. It shares the same modular Terraform approach as B2C but with its own GCP project and distinct technology choices.

```
                    +---------------------+
                    |   Agent Portal      |
                    |   (Web App)         |
                    +---------+-----------+
                              | HTTPS
                    +---------v-----------+
                    |    Cloud Armor      |  WAF: SQLi, XSS, LFI, RFI, RCE
                    |    (WAF + DDoS)     |  Rate limit: 500 req/60s per IP
                    +---------+-----------+
                    +---------v-----------+
                    |   Global HTTPS      |  TLS 1.2+, managed SSL cert
                    |   Load Balancer     |  Custom domain (agency.itinerehub.com)
                    +---------+-----------+
                    +---------v-----------+
                    |    Cloud CDN        |  CACHE_ALL_STATIC, TTL 300s
                    +---------+-----------+
                    +---------v-----------+
                    |  Serverless NEG     |  Routes to Cloud Run
                    +---------+-----------+
                    +---------v-----------+
                    |    API Gateway      | (Cloud Run - always on)
                    |    api-gateway-prod |   min: 1, max: 10
                    |                     |   port: 8080
                    +---------+-----------+
                              | Internal (SA-authenticated)
           +------------------+------------------+
           |                  |                  |
    +------v------+   +------v------+   +------v------+
    | Agency Mgmt |   | Trip Mgmt  |   | Flight Mgmt |  ... (19 services)
    | min:0 max:10|   | min:0 max:10|   | min:0 max:10|  Private access
    +------+------+   +------+------+   +------+------+
           |                  |                  |
    +------v------------------v------------------v------+
    |         Cloud SQL (PostgreSQL 16) - HA             |
    |         db-custom-2-4096 | Private-only            |
    |         SSL enforced | 20 GB SSD                   |
    +----------------------------------------------------+
```

## 2. Key Differences from B2C

| Aspect | B2C | B2B Agency |
|--------|-----|------------|
| **GCP Project** | aitinerehub-b2c-prod | aitinereagency-prod |
| **Database** | MySQL 8.0 | PostgreSQL 16 |
| **Services** | 14 (custom ports 5049-5065) | 19 (uniform port 8080) |
| **CI/CD** | GitHub Actions | Bitbucket Pipelines |
| **Redis** | Memorystore (1 GB) | Not used |
| **Gateway** | Spring Gateway | API Gateway |
| **Extra APIs** | places, redis | cloudscheduler, identitytoolkit, vision |
| **Extra SAs** | storage-sa | pubsub-sa |

## 3. Networking Design

### VPC: `prod-itinerehub-vpc`

| Subnet | CIDR | Purpose |
|--------|------|---------|
| `prod-itinerehub-primary` | 10.20.0.0/24 | Cloud SQL, general workloads |
| `prod-itinerehub-serverless` | 10.20.1.0/28 | Cloud Run VPC connector (backup) |
| `prod-itinerehub-redis` | 10.20.2.0/28 | Reserved (not currently used) |
| Private Services (peering) | /20 auto-allocated | Cloud SQL private IP |

> Uses the shared `vpc-network` module with non-overlapping CIDRs (10.20.x vs B2C's 10.10.x).

### Firewall Rules

Same restrictive rules as B2C via the shared `vpc-network` module:
- Health checks, IAP SSH, internal traffic allowed
- Default deny all ingress

### Cloud NAT

Configured for outbound internet access from private resources.

## 4. Cloud SQL - PostgreSQL 16

```
Instance:        prod-ith-postgres
Version:         PostgreSQL 16
Tier:            db-custom-2-4096 (2 vCPU, 4 GB RAM)
HA:              REGIONAL (automatic failover)
Disk:            20 GB PD-SSD, auto-resize
Public IP:       DISABLED
SSL:             ENCRYPTED_ONLY
User:            app-user (not root)
Backups:         Daily at 03:00 UTC, 14 retained, US location
PITR:            Enabled
Query Insights:  Enabled with app tags
Slow query log:  Queries > 1 second logged
Maintenance:     Sundays 04:00 UTC, stable track
```

> Uses the shared `postgresql-database` module.

## 5. Cloud Run Configuration

All 19 services use port 8080 (uniform, unlike B2C's custom ports).

### B2B Services (19 total)

| # | Service | Memory | Min/Max |
|---|---------|--------|---------|
| 1 | `api-gateway-prod` (Gateway) | 1Gi | 1/10 |
| 2 | `accommodation-management-service-prod` | 512Mi | 0/5 |
| 3 | `agency-management-service-prod` | 512Mi | 0/10 |
| 4 | `customer-management-service-prod` | 512Mi | 0/10 |
| 5 | `dashboard-management-service-prod` | 512Mi | 0/5 |
| 6 | `document-management-service-prod` | 512Mi | 0/5 |
| 7 | `expense-management-service-prod` | 512Mi | 0/5 |
| 8 | `flight-management-service-prod` | 512Mi | 0/10 |
| 9 | `intelligent-search-service-prod` | 1Gi | 0/5 |
| 10 | `invoice-management-service-prod` | 512Mi | 0/5 |
| 11 | `llm-service-prod` | 1Gi | 0/5 |
| 12 | `location-service-prod` | 512Mi | 0/5 |
| 13 | `mobility-management-service-prod` | 512Mi | 0/5 |
| 14 | `notification-service-prod` | 512Mi | 0/5 |
| 15 | `person-management-service-prod` | 512Mi | 0/10 |
| 16 | `transport-management-service-prod` | 512Mi | 0/10 |
| 17 | `traveler-management-service-prod` | 512Mi | 0/10 |
| 18 | `trip-management-service-prod` | 512Mi | 0/10 |
| 19 | `trip-operations-management-service-prod` | 512Mi | 0/5 |

### Key Settings

- **Port:** 8080 (all services, uniform)
- **Direct VPC Egress:** Via shared `cloud-run-service` module
- **cpu_idle: true:** Cost saving
- **Health checks:** HTTP `/actuator/health`
- **Timeout:** 300s
- **Service account:** Dedicated `prod-cloudrun-sa`

### Access Control

- **API Gateway:** Public (`allUsers` invoker)
- **All other services:** Private (only invokable by `prod-cloudrun-sa`)

## 6. Databases (19 schemas)

| Database | Purpose |
|----------|---------|
| `accommodationManagementService` | Accommodation bookings |
| `agencyManagementService` | Agency profiles and settings |
| `customerManagementService` | Customer records |
| `dashboardManagementService` | Dashboard analytics |
| `documentManagementService` | Document storage/management |
| `expenseManagementService` | Expense tracking |
| `flightManagementService` | Flight bookings |
| `intelligentSearchService` | AI-powered search |
| `invoiceManagementService` | Invoice generation |
| `llmService` | LLM/AI features |
| `localization` | i18n/localization |
| `locationService` | Location data |
| `mobilityManagementService` | Mobility services |
| `notificationService` | Notifications |
| `personManagementService` | Person/contact records |
| `transportManagementService` | Transport bookings |
| `travelerManagementService` | Traveler profiles |
| `tripManagementService` | Trip CRUD |
| `tripOperationsManagementService` | Trip operations |

## 7. Artifact Registry

```
Repository:     ith-docker-prod (Docker)
Cleanup:        Keep 10 most recent versions, delete untagged after 30 days
```

## 8. GCS Buckets

| Bucket | Features |
|--------|----------|
| `ith-agent-portal-prod` | Agent portal assets, uniform access |
| `itinerehub-assets-prod` | Versioning, lifecycle (Nearline@90d) |

## 9. Pub/Sub Topics

| Topic | Subscription |
|-------|-------------|
| `ih_pubsub_notification_prod` | `ih_pubsub_notification_prod-sub` |
| `ih_file_upload_request_prod` | `ih_file_upload_request_prod-sub` |
| `ih_file_upload_response_prod` | `ih_file_upload_response_prod-sub` |
| `ih-traveler-management-prod` | `ih-traveler-management-prod-sub` |
| `ih-trip-management-prod` | (topic only, no subscription) |

## 10. Service Accounts (Least Privilege)

| Account | Roles |
|---------|-------|
| `prod-bitbucket-sa` (CI/CD) | run.admin, artifactregistry.writer, secretmanager.secretAccessor, iam.serviceAccountUser |
| `prod-cloudrun-sa` | secretmanager.secretAccessor, cloudsql.client, pubsub.publisher, pubsub.subscriber, storage.objectViewer, logging.logWriter, cloudtrace.agent, monitoring.metricWriter |
| `prod-pubsub-sa` | Pub/Sub operations |

### Cross-Project Access

- `prod-cloudrun-sa` has `artifactregistry.reader` on dev project (`aitinereagency`)
- `prod-bitbucket-sa` has `artifactregistry.reader` on dev project (`aitinereagency`)

## 11. Security: Cloud Armor + HTTPS Load Balancer + CDN

### Global HTTPS Load Balancer

All external traffic enters through a Global HTTPS Load Balancer, providing:
- **TLS termination** with managed SSL certificate and TLS 1.2+ MODERN policy
- **Static global IP** for DNS (A record for `agency.itinerehub.com`)
- **Serverless NEG** routing to the API Gateway Cloud Run service

### Cloud Armor (WAF + DDoS)

Same security policy as B2C (shared `global-lb` module):

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

Enabled on the backend service with CACHE_ALL_STATIC, 300s default TTL, 3600s max TTL.

### Audit Logging

Data Access audit logs enabled for: Cloud SQL, Cloud Run, Cloud Storage, Secret Manager, IAM, and Artifact Registry.

## 12. Monitoring & Alerting

Via the shared `monitoring` module:

| Alert | Condition | Duration |
|-------|-----------|----------|
| Cloud SQL CPU | > 80% utilization | 5 minutes |
| Cloud SQL Disk | > 80% utilization | 5 minutes |
| Cloud Run 5xx | > 5% error rate | 5 minutes |

## 13. Cost Estimate (Monthly)

> **Note:** B2B dev and staging already exist in the `aitinereagency` project.
> The table below estimates cost for the **new** B2B production project only.

### B2B Production (new GCP project: `aitinereagency-prod`)

| Resource | Configuration | Est. Cost |
|----------|--------------|-----------|
| Cloud SQL PostgreSQL (HA) | db-custom-2-4096, REGIONAL | ~$120-150 |
| Cloud Run (19 services) | Scale to 0, cpu_idle | ~$40-100 |
| HTTPS Load Balancer | Global, forwarding rules | ~$18-25 |
| Cloud Armor | WAF policy + adaptive protection | ~$5-10 |
| Cloud CDN | Cache egress savings | ~$1-5 |
| GCS Storage | ~30 GB | ~$1-2 |
| Artifact Registry | ~20 GB | ~$2 |
| Pub/Sub | Low volume | ~$1-5 |
| Networking (egress) | ~50 GB/month | ~$4-6 |
| **B2B Prod Total** | | **~$190-310/month** |

### Committed Use Discounts (CUDs)

For production Cloud SQL, consider purchasing a CUD:

| Commitment | Discount | Prod DB Cost (from ~$120-150) |
|------------|----------|-------------------------------|
| **1-year** | ~25% off | **~$90-113/month** |
| **3-year** | ~52% off | **~$58-72/month** |

**How to purchase:**
1. Go to [GCP Console → Billing → Committed use discounts](https://console.cloud.google.com/billing)
2. Select the `aitinereagency-prod` project
3. Choose **Cloud SQL** → region `us-central1`
4. Select the DB tier (`db-custom-2-4096`) and commit for 1 or 3 years
5. The discount applies automatically to matching instances — no changes to Terraform needed

## 14. Deployment Workflow

1. Create new GCP project (`aitinereagency-prod`)
2. Ensure the GCS bucket `itinerehub-tf-state` exists for remote state
3. `cd terraform/products/b2b-agency/prod/`
4. Run `terraform init` to initialise the GCS backend
5. Run `terraform plan -var-file=terraform.tfvars` to review
6. Run `terraform apply` to create infrastructure
7. Update Bitbucket Pipelines with new project ID and service account
8. Deploy services via CI/CD
9. Configure custom domain (if applicable)
10. Set up monitoring dashboards
11. Perform load testing before go-live
