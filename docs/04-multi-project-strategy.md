# Itinerehub - Multi-Project GCP Strategy

**Date:** 2026-02-25

---

## 1. Current State

Two GCP projects exist today, each serving dev/staging for one workstream:

| Project | ID | Number | Workstream | Region | Envs |
|---------|-----|--------|-----------|--------|------|
| **aitinerehub** | aitinerehub | 541454969801 | B2C Flutter app backend | me-central1 | dev, rc |
| **aitinereagency** | aitinereagency | 775123275503 | B2B React portal + Java backend | us-central1 | dev, qa, staging |

## 2. Target State

Two new production projects, one per workstream:

```
  ┌──────────────────────┐        ┌─────────────────────────┐
  │    aitinerehub        │        │    aitinereagency        │
  │    (existing)         │        │    (existing)            │
  │                       │        │                          │
  │  B2C Dev + RC         │        │  B2B Dev + QA + Staging  │
  │  16 Cloud Run srvcs   │        │  18 Cloud Run srvcs      │
  │  MySQL 8.0            │        │  PostgreSQL 16           │
  │  Redis VM             │        │  No Redis                │
  │  me-central1          │        │  us-central1             │
  │  GitHub Actions       │        │  Bitbucket Pipelines     │
  │                       │        │                          │
  │  Artifact Registry ──────┐  ┌────── Artifact Registry     │
  └──────────────────────┘   │  │  └─────────────────────────┘
                              │  │
         (image pull)         │  │         (image pull)
                              ▼  ▼
  ┌──────────────────────┐        ┌─────────────────────────┐
  │  aitinerehub-prod     │        │  aitinereagency-prod     │
  │  (NEW)                │        │  (NEW)                   │
  │                       │        │                          │
  │  B2C Production       │        │  B2B Production          │
  │  15 Cloud Run srvcs   │        │  19 Cloud Run srvcs      │
  │  MySQL 8.0 HA         │        │  PostgreSQL 16 HA        │
  │  Memorystore Redis    │        │  No Redis needed         │
  │  us-central1          │        │  us-central1             │
  │  SSL enforced         │        │  SSL enforced            │
  │  Private SQL only     │        │  Private SQL only        │
  └──────────────────────┘        └─────────────────────────┘
```

## 3. Key Differences Between Workstreams

| Aspect | B2C (aitinerehub) | B2B (aitinereagency) |
|--------|-------------------|----------------------|
| **App type** | Flutter mobile app | React web portal + Java backend |
| **Database** | MySQL 8.0 | PostgreSQL 16 |
| **Dev region** | me-central1 (Doha) | us-central1 (Iowa) |
| **Prod region** | us-central1 (cost) | us-central1 (same) |
| **Services** | 16 (custom ports) | 18 (uniform port 8080) |
| **Gateway** | Spring Cloud Gateway | API Gateway (Spring) |
| **CI/CD** | GitHub Actions | Bitbucket Pipelines |
| **Environments** | dev, rc | dev, qa, staging |
| **Redis** | Yes (cache) | No |
| **DB scheduling** | None | Start/stop on schedule |
| **Secrets approach** | Hardcoded env vars (170+) | Minimal secrets (3) |

## 4. Terraform Repository Structure

```
itinerehub-infrastructure/
│
├── modules/                                  # Shared across both workstreams
│   ├── cloud-run-service/main.tf             # Generic Cloud Run v2
│   ├── vpc-network/main.tf                   # VPC + NAT + firewall
│   ├── mysql-database/main.tf                # Cloud SQL MySQL (B2C)
│   ├── postgresql-database/main.tf           # Cloud SQL PostgreSQL (B2B)
│   ├── redis/main.tf                         # Memorystore Redis
│   ├── pubsub/main.tf                        # Pub/Sub topic + sub
│   └── monitoring/main.tf                    # Alert policies
│
├── products/
│   ├── b2c-backend/                          # aitinerehub workstream
│   │   ├── dev/main.tf                       # Documents existing aitinerehub
│   │   └── prod/                             # → aitinerehub-prod (NEW)
│   │       ├── main.tf
│   │       └── terraform.tfvars.example
│   │
│   └── b2b-agency/                           # aitinereagency workstream
│       └── prod/                             # → aitinereagency-prod (NEW)
│           ├── main.tf
│           └── terraform.tfvars.example
│
├── docs/
│   ├── 01-dev-environment.md                 # B2C dev audit
│   ├── 02-b2c-prod-environment.md             # B2C prod design
│   ├── 03-assessment.md                      # B2C assessment
│   ├── 04-multi-project-strategy.md          # This document
│   └── 05-b2b-agency-environment.md          # B2B dev audit
│
└── .gitignore
```

## 5. B2B Agency (aitinereagency) — Dev Audit

### Cloud Run Services (18 distinct services × 3 envs = 54 total)

| Service | Purpose |
|---------|---------|
| `api-gateway` | API Gateway (public) |
| `accommodation-management-service` | Hotel/stay management |
| `agency-management-service` | Travel agency CRUD |
| `customer-management-service` | Customer management |
| `dashboard-management-service` | Analytics dashboards |
| `document-management-service` | Document handling |
| `expense-management-service` | Expense tracking |
| `flight-management-service` | Flight bookings |
| `intelligent-search-service` | AI-powered search |
| `invoice-management-service` | Invoice generation |
| `llm-service` | LLM/AI features |
| `location-service` | Location data |
| `mobility-management-service` | Mobility |
| `notification-service` | Push/email |
| `person-management-service` | Person/contact mgmt |
| `transport-management-service` | Ground transport |
| `traveler-management-service` | Traveler profiles |
| `trip-management-service` | Trip CRUD |
| `trip-operations-management-service` | Trip operations |

### Cloud SQL (PostgreSQL 16)

| Instance | Tier | Status |
|----------|------|--------|
| ith-postgres-dev | db-g1-small | RUNNABLE |
| ith-postgres-qa | db-custom-1-3840 | RUNNABLE |
| ith-postgres-staging | db-custom-1-3840 | RUNNABLE |

DB start/stop via Cloud Scheduler (weekdays only) — good cost optimization.

### Databases (19 per instance)

accommodationManagementService, agencyManagementService, customerManagementService, dashboardManagementService, documentManagementService, expenseManagementService, flightManagementService, intelligentSearchService, invoiceManagementService, llmService, localization, locationService, mobilityManagementService, notificationService, personManagementService, transportManagementService, travelerManagementService, tripManagementService, tripOperationsManagementService

### Artifact Registry (~520 GB — needs cleanup)

| Repository | Size |
|-----------|------|
| ith-docker-dev | 176 GB |
| ith-docker-qa | 146 GB |
| ith-docker-staging | 198 GB |

### GCS Buckets

ith-agent-portal-dev/qa/staging, ith-website-dev, itinerehub-assets-dev/qa/staging

### Pub/Sub Topics (per environment)

ih_pubsub_notification, ih_file_upload_request, ih_file_upload_response, ih-traveler-management, ih-trip-management

### Notable Service Accounts

ith-bitbucket-sa (CI/CD), cloudrun-service, cloud-scheduler-sql, ith-pubsub-sa, ith-identity-platform-sa, cdn-signedurl-generator, firebase-adminsdk

### B2B Security Issues (same as B2C)

- SSL not enforced on PostgreSQL (ALLOW_UNENCRYPTED_AND_ENCRYPTED)
- Public IP enabled with VPN IPs whitelisted
- Default auto-create VPC (not custom subnets)
- Only default firewall rules (SSH/RDP open to 0.0.0.0/0)

## 6. Cost Estimate (Monthly)

### B2C Production (aitinerehub-prod)

| Resource | Config | Est. Cost |
|----------|--------|-----------|
| Cloud SQL MySQL HA | db-custom-2-4096 | ~$120-150 |
| Memorystore Redis | BASIC 1GB | ~$35 |
| Cloud Run (15 srvcs) | scale-to-zero, cpu_idle | ~$30-80 |
| GCS + AR + NAT + Pub/Sub | | ~$25-50 |
| **B2C Total** | | **~$210-315** |

### B2B Production (aitinereagency-prod)

| Resource | Config | Est. Cost |
|----------|--------|-----------|
| Cloud SQL PostgreSQL HA | db-custom-2-4096 | ~$120-150 |
| Cloud Run (19 srvcs) | scale-to-zero, cpu_idle | ~$40-100 |
| GCS + AR + NAT + Pub/Sub | | ~$25-50 |
| **B2B Total** | | **~$185-300** |

### Combined Total: ~$395-615/month

## 7. Setup Steps

### Step 1: Create GCP Projects
```bash
gcloud projects create aitinerehub-prod --name="Itinerehub B2C Production"
gcloud projects create aitinereagency-prod --name="Itinerehub B2B Agency Production"

gcloud billing projects link aitinerehub-prod --billing-account=BILLING_ACCOUNT_ID
gcloud billing projects link aitinereagency-prod --billing-account=BILLING_ACCOUNT_ID
```

### Step 2: Create Terraform State Bucket
```bash
gcloud storage buckets create gs://itinerehub-tf-state \
  --project=aitinerehub --location=us-central1 \
  --uniform-bucket-level-access
```

### Step 3: Deploy B2C Production
```bash
cd products/b2c-backend/prod
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars
terraform init && terraform plan && terraform apply
```

### Step 4: Deploy B2B Production
```bash
cd products/b2b-agency/prod
cp terraform.tfvars.example terraform.tfvars
terraform init && terraform plan && terraform apply
```

### Step 5: Update CI/CD
- **GitHub Actions** (B2C): Add `aitinerehub-prod` SA key as secret
- **Bitbucket Pipelines** (B2B): Add `aitinereagency-prod` SA key as secret
- Configure image promotion pipelines for both workstreams
