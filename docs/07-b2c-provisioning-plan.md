# Provisioning Plan: B2C Staging + Production Environments

## Context

B2C dev is already live in the `aitinerehub` GCP project. We need to provision two new environments:
- **B2C Staging** — shares the `aitinerehub` project with dev (separate VPC, 10.1.x CIDRs)
- **B2C Production** — dedicated project `aitinerehub-b2c-prod` (project ID: 800590950952)

Terraform configs already exist at:
- `terraform/products/b2c-backend/staging/main.tf`
- `terraform/products/b2c-backend/prod/main.tf`

Execution VM: `dev-claude-agents` (Terraform + gcloud already installed & authenticated)

---

## Phase 0 — Prerequisites Check (~5 min)

Run from the VM before any Terraform commands:

```bash
# 1. Verify tooling
terraform version          # Must be >= 1.5
gcloud version
gcloud auth list           # Confirm authenticated identity

# 2. Check if state bucket exists
gsutil ls gs://itinerehub-tf-state/ 2>/dev/null && echo "EXISTS" || echo "MISSING"

# 3. If MISSING — create it:
gsutil mb -p aitinerehub -l me-central1 gs://itinerehub-tf-state/
gsutil versioning set on gs://itinerehub-tf-state/

# 4. Verify B2C prod project is accessible
gcloud projects describe aitinerehub-b2c-prod
```

---

## Phase 1 — B2C Staging Provisioning

**GCP Project:** `aitinerehub` (shared with dev)
**Terraform Path:** `terraform/products/b2c-backend/staging/`
**State Prefix:** `b2c-backend/staging`
**Estimated time:** 10-15 min (Cloud SQL is slowest)
**Estimated monthly cost:** ~$75-100/mo

### Step 1.1 — Create terraform.tfvars

```bash
cd ~/projects/itinerehub-infra-terraform/terraform/products/b2c-backend/staging/
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars` with real values:
- `project_id` = `"aitinerehub"`
- `region` = `"me-central1"`
- `env` = `"staging"`
- `db_password` = `"<generate-secure-password>"`
- `alert_email` = `"ops@ai-tinerehub.com"` (or leave empty to skip alerts)

### Step 1.2 — Init, Validate, Plan

```bash
terraform init
terraform validate
terraform plan -var-file=terraform.tfvars -out=staging.tfplan
```

**Review the plan output carefully.** Expected: ~50-60 resources to be created:
- 15 GCP API enablements
- 1 VPC + 3 subnets + 4 firewall rules + private service connection
- 1 Cloud SQL instance + 14 databases + 1 user
- 1 Redis instance
- 2 Artifact Registry repos
- 3 service accounts + ~8 IAM bindings
- 3 GCS buckets
- 6 Pub/Sub topics + subscriptions
- 14 Cloud Run services
- Audit logging config
- Monitoring alerts (if alert_email set)

### Step 1.3 — Apply

```bash
terraform apply staging.tfplan
```

### Step 1.4 — Verify

```bash
terraform output
# Spot-check key resources:
gcloud sql instances list --project=aitinerehub --filter="name~staging"
gcloud run services list --project=aitinerehub --region=me-central1 --filter="metadata.name~staging"
gcloud redis instances list --project=aitinerehub --region=me-central1
```

---

## Phase 2 — B2C Production Provisioning

**GCP Project:** `aitinerehub-b2c-prod` (800590950952) — dedicated project
**Terraform Path:** `terraform/products/b2c-backend/prod/`
**State Prefix:** `b2c-backend/prod`
**Estimated time:** 15-20 min (HA Cloud SQL + LB setup)
**Estimated monthly cost:** ~$220-330/mo

### Step 2.1 — Verify prod project permissions

```bash
gcloud auth list
gcloud projects describe aitinerehub-b2c-prod
# If not authenticated to prod project:
gcloud config set project aitinerehub-b2c-prod
```

### Step 2.2 — Create terraform.tfvars

```bash
cd ~/projects/itinerehub-infra-terraform/terraform/products/b2c-backend/prod/
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars` with real values:
- `project_id` = `"aitinerehub-b2c-prod"`
- `region` = `"me-central1"`
- `env` = `"prod"`
- `db_password` = `"<generate-different-secure-password>"`
- `alert_email` = `"ops@ai-tinerehub.com"`
- `domain` = `"api.itinerehub.com"` (or leave empty if DNS not ready yet)

### Step 2.3 — Init, Validate, Plan

```bash
terraform init
terraform validate
terraform plan -var-file=terraform.tfvars -out=prod.tfplan
```

**Review the plan output carefully.** Expected: ~70-80 resources (more than staging due to LB + CDN + Cloud Armor).

Additional prod-only resources:
- Global HTTPS Load Balancer + managed SSL cert
- Cloud Armor WAF security policy
- Cloud CDN configuration
- HA Cloud SQL (REGIONAL availability)
- Flow logs enabled (10% sampling)

### Step 2.4 — Apply

```bash
terraform apply prod.tfplan
```

### Step 2.5 — Verify

```bash
terraform output
gcloud sql instances list --project=aitinerehub-b2c-prod
gcloud run services list --project=aitinerehub-b2c-prod --region=me-central1
gcloud compute forwarding-rules list --project=aitinerehub-b2c-prod  # LB check
```

---

## Phase 3 — Post-Provisioning Tasks

### 3.1 — Store DB passwords in Secret Manager
```bash
# Staging
echo -n "<staging-db-password>" | gcloud secrets create staging-db-password \
  --project=aitinerehub --data-file=- --replication-policy=automatic

# Prod
echo -n "<prod-db-password>" | gcloud secrets create prod-db-password \
  --project=aitinerehub-b2c-prod --data-file=- --replication-policy=automatic
```

### 3.2 — DNS Setup (prod only, when ready)
- Point `api.itinerehub.com` → LB IP from `terraform output lb_ip`
- SSL cert will auto-provision once DNS propagates (~15-30 min)

### 3.3 — CI/CD Configuration
- Add `staging-cicd` service account key to GitHub Actions secrets
- Configure staging deployment workflow to push to `me-central1-docker.pkg.dev/aitinerehub/staging/`
- Configure prod deployment workflow to push to `me-central1-docker.pkg.dev/aitinerehub-b2c-prod/production/`

### 3.4 — Smoke Test
- Deploy a test image to the gateway service
- Verify VPC connectivity (Cloud Run → Cloud SQL, Cloud Run → Redis)
- Test Pub/Sub message flow

---

## Rollback Plan

If something goes wrong during provisioning:

```bash
# Destroy specific resources (staging example)
cd terraform/products/b2c-backend/staging/
terraform destroy -var-file=terraform.tfvars -target=module.cloud_run  # Targeted
terraform destroy -var-file=terraform.tfvars                           # Full teardown
```

Note: Cloud SQL has `deletion_protection = true` — must be disabled before destroy.

---

## Execution Order Summary

| # | Action | Time | Blocking? |
|---|--------|------|-----------|
| 0 | Prerequisites check + state bucket | 5 min | Yes |
| 1 | B2C Staging: init → plan → apply → verify | 15 min | Yes |
| 2 | B2C Prod: init → plan → apply → verify | 20 min | Yes |
| 3 | Post-provisioning (secrets, DNS, CI/CD) | 30 min | No |

**Total estimated time: ~1 hour**
