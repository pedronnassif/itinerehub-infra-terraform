# Itinerehub B2C - Dev/Staging Environment Documentation

**Project:** aitinerehub (541454969801)
**Region:** me-central1 (Doha, Qatar)
**Date of Audit:** 2026-02-22

---

## 1. Architecture Overview

The dev/staging environment follows a **microservices architecture** running on **Google Cloud Run**, backed by **Cloud SQL (MySQL 8.0)**, with a self-managed **Redis cache on Compute Engine**. Services communicate via HTTP (service-to-service) and **Pub/Sub** for asynchronous events. A **Spring Cloud Gateway** acts as the API gateway routing requests to individual microservices.

```
                   ┌─────────────────┐
                   │   Mobile App    │
                   └────────┬────────┘
                            │
                   ┌────────▼────────┐
                   │  Spring Gateway │ (Cloud Run)
                   │  dev-ih-spring  │
                   │  -gw-service    │
                   └────────┬────────┘
                            │
          ┌─────────────────┼─────────────────┐
          │                 │                 │
   ┌──────▼──────┐  ┌──────▼──────┐  ┌──────▼──────┐
   │ User Service│  │ Trip Service│  │  Location   │  ... (16 services)
   └──────┬──────┘  └──────┬──────┘  └──────┬──────┘
          │                │                │
   ┌──────▼────────────────▼────────────────▼──────┐
   │              Cloud SQL (MySQL 8.0)             │
   │              dev-ih-db-cluster                 │
   │              db-f1-micro | 10 GB SSD           │
   └───────────────────────┬────────────────────────┘
                           │
                    ┌──────▼──────┐
                    │  Redis VM   │
                    │ (e2-custom) │
                    └─────────────┘
```

## 2. Networking

### VPC Networks

| Network | Type | Subnets | Peering |
|---------|------|---------|---------|
| `default` | Auto | 42 regions (auto-created) | None |
| `dev-itinerehub-vpc` | Custom | `dev-itinerehub-subnet` (10.0.0.0/28) | Service Networking (Cloud SQL) |
| `rc-itinerehub-vpc` | Custom | `rc-itinerehub-subnet` (10.128.0.0/28) | Service Networking (Cloud SQL) |
| `prod-itinerehub-vpc` | Custom | `prod-itinerehub-subnet` (192.168.0.0/28) | Service Networking (Cloud SQL) |

### VPC Access Connectors

| Connector | Network | Machine Type | Instances |
|-----------|---------|-------------|-----------|
| `dev-ih-vpc-connector` | dev-itinerehub-vpc | e2-micro | 2-10 |
| `rc-ih-vpc-connector` | rc-itinerehub-vpc | e2-micro | 2-10 |
| `prod-ih-vpc-connector` | prod-itinerehub-vpc | e2-micro | 2-10 |

### Firewall Rules

| Rule | Network | Direction | Source | Allow |
|------|---------|-----------|--------|-------|
| `allow-mysql` | dev-vpc | INGRESS | 10.0.0.0/28 | tcp:3306 |
| `allow-redis` | dev-vpc | INGRESS | 35.235.240.0/20 (IAP) | tcp:6379 |
| `allow-ssh` | dev-vpc | INGRESS | 35.235.240.0/20 (IAP) | tcp:22 |
| `dev-vpc-allow-http` | dev-vpc | INGRESS | 0.0.0.0/0 | tcp:80 |
| `dev-vpc-allow-https` | dev-vpc | INGRESS | 0.0.0.0/0 | tcp:443 |
| `allow-sonarqube` | default | INGRESS | 0.0.0.0/0 | tcp:9000 |

### Static IP Addresses

| Name | Type | Address | Usage |
|------|------|---------|-------|
| `dev-itinerehub-vpc-ip-range` | Internal /20 | 10.144.208.0 | VPC Peering (Cloud SQL) |
| `rc-itinerehub-vpc-ip-range` | Internal /20 | 10.72.112.0 | VPC Peering (Cloud SQL) |
| `prod-itinerehub-vpc-ip-range` | Internal /20 | 10.63.0.0 | VPC Peering (Cloud SQL) |
| `sonarqube-vm-static-ip` | External | 34.69.58.156 | SonarQube VM (us-central1) |

## 3. Compute Engine

| Instance | Zone | Machine Type | Status | Network IP | External IP | Purpose |
|----------|------|-------------|--------|-----------|-------------|---------|
| `dev-sonarqube-vm` | us-central1-c | e2-medium | TERMINATED | 10.128.0.8 | 34.69.58.156 | SonarQube code analysis |
| `dev-redis-vm` | me-central1-c | e2-custom-medium-1024 | RUNNING | 10.0.0.8 | 34.1.44.8 | Redis cache (dev) |
| `rc-redis-vm` | me-central1-c | e2-custom-medium-1024 | RUNNING | 10.128.0.6 | 34.1.33.108 | Redis cache (RC) |

All VMs run Ubuntu 22.04 LTS with 20 GB boot disks.

## 4. Cloud SQL

### Instances

| Instance | Version | Tier | Region | Availability | Disk | Status |
|----------|---------|------|--------|-------------|------|--------|
| `dev-ih-db-cluster` | MySQL 8.0.37 | db-f1-micro | me-central1 | ZONAL | 10 GB SSD | RUNNABLE |
| `rc-ih-db-cluster` | MySQL 8.0.37 | db-f1-micro | me-central1 | ZONAL | 10 GB SSD | RUNNABLE |
| `prod-ih-db-cluster` | MySQL 8.0.40 | db-f1-micro | me-central1 | ZONAL | 10 GB SSD | STOPPED |

### Configuration Details (dev-ih-db-cluster)

- **Backup:** Enabled, daily at 02:00 UTC, stored in EU, 7 retained
- **Binary logging:** Enabled (for point-in-time recovery)
- **SSL:** Not enforced (ALLOW_UNENCRYPTED_AND_ENCRYPTED)
- **IAM Auth:** Enabled (cloudsql_iam_authentication = on)
- **Query Insights:** Enabled
- **Auto-resize:** Enabled (no limit)
- **Maintenance:** Sundays at midnight, canary track

### Databases (dev instance - 17 application databases)

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
| `documentManagementService-db` | Document management |
| `llmService-db` | LLM service |
| `locationService-b2b-db` | B2B location |
| `subscription-db` | Subscriptions |

### Authorized Networks (dev)

The following developer IPs have direct SQL access:

| Name | IP |
|------|-----|
| Sourabh | 49.47.68.36 |
| Mauricio_1 | 179.116.91.216 |
| Dilip home | 223.233.74.251 |
| Venturedive-VPN-IP | 110.93.250.82 |
| Mohsin | 154.80.56.208 |
| Helio_home | 181.223.13.32 |
| Abid | 139.135.60.32 |
| Dilip-Office | 106.219.166.29 |
| Venture_Drive_Office | 110.93.250.90 |

## 5. Cloud Run Services

All services run in **me-central1** with the following common configuration:
- **CPU:** 1 vCPU (1000m)
- **Memory:** 1 Gi
- **Max instances:** 1 (dev/RC), 100 (prod-user-service)
- **VPC Connector:** dev-ih-vpc-connector
- **VPC Egress:** private-ranges-only
- **Cloud SQL Connection:** dev-ih-db-cluster
- **Startup CPU boost:** Enabled
- **Deployed by:** github-actions@aitinerehub.iam.gserviceaccount.com

### Dev Environment Services (16)

| Service | URL |
|---------|-----|
| `dev-ih-spring-gw-service` | (Gateway - routes to all services) |
| `dev-user-service` | User management, JWT auth |
| `dev-trip-service` | Trip CRUD operations |
| `dev-location-service` | Location data |
| `dev-notification-service` | Push/email notifications |
| `dev-financial-service` | Financial operations |
| `dev-transportation-service` | Transport bookings |
| `dev-booking-service` | Booking management |
| `dev-aaccomodation-service` | Accommodation |
| `dev-ai-service` | AI/ML features |
| `dev-assets-service` | Asset management |
| `dev-ih-subscription-service` | Subscriptions |
| `dev-ih-voucher-processing-service` | Voucher processing |
| `dev-document-management-service-b2b` | B2B documents |
| `dev-llm-service-b2b` | B2B LLM |
| `dev-location-service-b2b` | B2B locations |

### RC Environment Services (16 matching services with `rc-` prefix)

### Feature Branch Services (3)
- `feature-ih-spring-gw-service`
- `feature-trip-service`
- `feature-user-service`

### Prod Services (1 - partially set up)
- `prod-user-service` (max 100 instances, 512Mi memory)

## 6. GCS Buckets

| Bucket | Purpose |
|--------|---------|
| `aitinerehub_dev` | General dev storage |
| `dev-ih-assets-bucket` | Dev assets |
| `dev-ih-user-bucket` | Dev user data |
| `ih-dev-service-bucket` | Dev service files (gateway config) |
| `ih-flight-test-bucket` | Flight test data |
| `ih-rc-service-bucket` | RC service files |
| `ih-crm` | CRM data (dev) |
| `rc-ih-crm` | CRM data (RC) |
| `onboarding-screen-cdn-bucket` | Onboarding screen CDN assets |
| `cloud-ai-platform-*` | AI Platform managed bucket |

## 7. Pub/Sub

### Topics

| Topic | Purpose |
|-------|---------|
| `dev-notification-event-topic` | Notification events |
| `dev-notification-push-topic` | Push notification triggers |
| `dev-notifications-events-topic` | General notification events |
| `dev-batch-push-notification-event-topic` | Batch push notifications |
| `dev-notifications-retry-topic` | Retry failed notifications |
| `dead-letter-notifications` | Dead letter queue |
| (Matching `rc-` prefixed topics) | RC environment |

### Subscriptions

| Subscription | Topic |
|-------------|-------|
| `dev-notifications-push-subscriptions` | dev-notifications-events-topic |
| `dev-batch-push-notification-event-subscriptions` | dev-batch-push-notification-event-topic |
| (Matching `rc-` subscriptions) | RC topics |

## 8. Artifact Registry

### Docker Repositories (me-central1)

| Repository | Size | Description |
|-----------|------|-------------|
| `develop` | ~35 GB | All dev images (consolidated) |
| `release` | ~30 GB | Release candidate images |
| `production` | 0 | Empty - not yet used |
| `ih-user-service` | ~28 GB | User service (legacy per-service) |
| `ih-trip-service` | ~20 GB | Trip service |
| `ih-notification-service` | ~12 GB | Notification service |
| `ih-financial-service` | ~11 GB | Financial service |
| `ih-transportation-service` | ~12 GB | Transportation service |
| `ih-location-service-b2b` | ~10 GB | B2B Location service |
| `ih-location-service` | ~8 GB | Location service |
| (+ 6 more per-service repos) | | |

### Maven Repository

| Repository | Size | Description |
|-----------|------|-------------|
| `develop-pkg` | ~1.3 MB | Maven packages |

## 9. Secret Manager

**~170+ secrets** are stored covering:
- Database credentials (DEV_, RC_, PROD_ prefixed)
- API keys (SendGrid, Google Maps, AeroDataBox, Pixel, CurrencyLayer)
- Service configuration (env files, server ports, database URLs)
- Pub/Sub topic/subscription names
- JWT configuration
- Redis host configuration
- Artifact Registry names
- VPC connector names
- Service account keys

## 10. Service Accounts

| Account | Purpose |
|---------|---------|
| `github-actions@` | CI/CD deployments |
| `secret-manager@` | Secret access |
| `ih-bucket-user@` | GCS operations |
| `dev-gateway-sa@` | Gateway service |
| `dev-trip-service-sa@` | Trip service |
| `dev-user-service-sa@` | User service |
| `ih-oauth@` | OAuth operations |
| `ih-gcp-resource-manager@` | Resource management |
| `local-dev-mauricio@` | Local development |
| `testing-access-helio@` | Testing access |
| `testi-799@` | Testing |

## 11. IAM & Access Control

### Project Owners

| User | Email |
|------|-------|
| Pedro | pedro.n.nassif@gmail.com |
| Dilip | d.k.tekwani15@gmail.com |
| Helio | hsilvaj@gmail.com |
| Mauricio | mporto@gmail.com |
| Osama | osama.tariq@venturedive.com |

### Custom Roles

| Role | Permissions | Purpose |
|------|------------|---------|
| `Aitinere_backend_dev` | cloudsql.instances.connect/get, pubsub read | Backend developer access |
| `CloudSQLIPWhitelistManager` | cloudsql.instances.get/list/update | Manage SQL IP whitelist |
| `DBStart_Stop_Operator` | cloudsql.instances.get/update | Start/stop SQL instances |
| `VMStart_Stop_Operator` | compute.instances.get/list/start/stop | Start/stop VMs |

### Key IAM Bindings

| Service Account | Key Roles |
|----------------|-----------|
| `github-actions@` | run.admin, artifactregistry.writer, cloudbuild, secretmanager.secretAccessor, iam.serviceAccountUser/TokenCreator, pubsub.admin, storage.objectAdmin |
| `ih-bucket-user@` | apigateway.admin, pubsub.editor/publisher/subscriber, storage.objectAdmin/Creator/User/Viewer, secretmanager.secretAccessor, serviceusage.consumer |
| `ih-gcp-resource-manager@` | cloudsql.admin, compute.networkAdmin |
| `testing-access-helio@` | cloudsql.admin, monitoring.viewer |
| `local-dev-mauricio@` | Aitinere_backend_dev (custom) |

### External User Access (VentureDive Developers)

| User | Roles |
|------|-------|
| sourabh.bhardwaj202@ | Aitinere_backend_dev, pubsub.subscriber, viewer |
| mohsin.anees@venturedive | monitoring.viewer, viewer |
| abid.hussain@venturedive | logging.viewAccessor, run.viewer, storage.objectAdmin, viewer |
| anas.ateeq@venturedive | logging.viewAccessor, run.viewer, secretmanager.secretAccessor/viewer |
| laiba.taha@venturedive | logging.viewAccessor, run.viewer, secretmanager.secretAccessor/viewer |
| kanwar@exiliensoft | cloudsql.editor, viewer |

## 12. GCS Bucket Details

| Bucket | Location | Class | Uniform Access | Public Prevention | Created |
|--------|----------|-------|----------------|-------------------|---------|
| `aitinerehub_dev` | US-CENTRAL1 | STANDARD | Yes | Inherited | 2025-02-10 |
| `cloud-ai-platform-*` | US-CENTRAL1 | REGIONAL | No | Inherited | 2025-05-27 |
| `dev-ih-assets-bucket` | ME-CENTRAL1 | STANDARD | Yes | Enforced | 2025-04-04 |
| `dev-ih-user-bucket` | ME-CENTRAL1 | STANDARD | Yes | Enforced | 2025-02-25 |
| `ih-crm` | ME-CENTRAL1 | STANDARD | Yes | Inherited | 2025-03-25 |
| `ih-dev-service-bucket` | ME-CENTRAL1 | STANDARD | No | Inherited | 2025-06-26 |
| `ih-flight-test-bucket` | ME-CENTRAL1 | STANDARD | No | Inherited | 2025-05-19 |
| `ih-rc-service-bucket` | ME-CENTRAL1 | STANDARD | No | Inherited | 2026-01-13 |
| `onboarding-screen-cdn-bucket` | ME-CENTRAL1 | STANDARD | Yes | Inherited | 2026-02-19 |
| `rc-ih-crm` | ME-CENTRAL1 | STANDARD | Yes | Inherited | 2025-06-24 |

**Notes:**
- `ih-flight-test-bucket` has **allUsers:READER** ACL (publicly accessible)
- `ih-dev-service-bucket` uses fine-grained ACLs (not uniform bucket-level access)
- `ih-crm` and `rc-ih-crm` have website config (`mainPageSuffix: index.html`) — used as static hosting
- No lifecycle policies configured on any bucket
- No versioning enabled on any bucket

## 13. Enabled APIs (63 total)

Key APIs beyond defaults:
- AI Platform, Vision AI, Generative Language, Places API
- Cloud Run, Cloud Build, Artifact Registry
- Cloud SQL Admin, Redis, Firestore
- Pub/Sub, Eventarc, Cloud Scheduler
- Secret Manager, IAM
- VPC Access, Service Networking, DNS
- Container (GKE), GKE Backup
- Binary Authorization, Container Analysis
- API Gateway
- Android Publisher, Play Developer Reporting
