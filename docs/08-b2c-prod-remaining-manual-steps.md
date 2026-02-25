# B2C Production — Remaining Manual Steps

> **Status:** Infrastructure fully provisioned (119 resources). SSL active.
> Terraform state is clean — no pending changes.
>
> This document covers the manual steps required to go from "infra ready" to
> "services running in production."

---

## 1. CI/CD — GitHub Actions Secrets

Service account keys were exported during provisioning and sit on the VM at:

| Environment | Key file | Service account |
|-------------|----------|-----------------|
| Staging | `/tmp/staging-cicd-key.json` | `staging-cicd@aitinerehub.iam.gserviceaccount.com` |
| Production | `/tmp/prod-cicd-key.json` | `prod-cicd@aitinerehub-b2c-prod.iam.gserviceaccount.com` |

### Steps

```bash
# 1. Base64-encode each key (GitHub secrets must be single-line)
base64 -w0 /tmp/staging-cicd-key.json   # → copy output
base64 -w0 /tmp/prod-cicd-key.json      # → copy output

# 2. In the B2C app GitHub repo → Settings → Secrets and variables → Actions
#    Create the following repository secrets:

#    GCP_SA_KEY_STAGING   = <base64 of staging key>
#    GCP_SA_KEY_PROD      = <base64 of prod key>
#    GCP_PROJECT_STAGING  = aitinerehub
#    GCP_PROJECT_PROD     = aitinerehub-b2c-prod

# 3. Delete local key files after adding to GitHub
rm /tmp/staging-cicd-key.json /tmp/prod-cicd-key.json
```

---

## 2. CI/CD — Deployment Workflows

Each service needs a GitHub Actions workflow (or a shared reusable workflow) that:

1. Authenticates to GCP using the SA key
2. Builds the Docker image
3. Pushes to the correct Artifact Registry
4. Deploys to Cloud Run

### Registry paths

| Environment | Docker registry |
|-------------|-----------------|
| Staging | `me-central1-docker.pkg.dev/aitinerehub/staging/<service-name>` |
| Production | `us-central1-docker.pkg.dev/aitinerehub-b2c-prod/production/<service-name>` |

### Example workflow snippet (prod)

```yaml
- name: Auth to GCP
  uses: google-github-actions/auth@v2
  with:
    credentials_json: ${{ secrets.GCP_SA_KEY_PROD }}

- name: Configure Docker for Artifact Registry
  run: gcloud auth configure-docker us-central1-docker.pkg.dev --quiet

- name: Build & Push
  run: |
    IMAGE="us-central1-docker.pkg.dev/aitinerehub-b2c-prod/production/$SERVICE_NAME:${{ github.sha }}"
    docker build -t "$IMAGE" .
    docker push "$IMAGE"

- name: Deploy to Cloud Run
  run: |
    gcloud run deploy "prod-$SERVICE_NAME" \
      --image "$IMAGE" \
      --region us-central1 \
      --project aitinerehub-b2c-prod
```

> **Note:** The Terraform Cloud Run module uses `lifecycle { ignore_changes = [image] }`,
> so CI/CD image deployments will NOT cause Terraform drift.

---

## 3. Deploy Real Container Images

All 14 Cloud Run services are currently running a **placeholder image**
(`us-docker.pkg.dev/cloudrun/container/hello:latest`). They must be replaced
with real application images.

### Production services to deploy

| Service | Cloud Run name | Port |
|---------|---------------|------|
| API Gateway | `prod-ih-spring-gw-service` | 5049 |
| User Service | `prod-user-service` | 5050 |
| Trip Service | `prod-trip-service` | 5051 |
| Location Service | `prod-location-service` | 5052 |
| Notification Service | `prod-notification-service` | 5053 |
| Financial Service | `prod-financial-service` | 5054 |
| Transportation Service | `prod-transportation-service` | 5055 |
| Booking Service | `prod-booking-service` | 5056 |
| Accommodation Service | `prod-aaccomodation-service` | 5057 |
| AI Service | `prod-ai-service` | 5058 |
| Assets Service | `prod-assets-service` | 5059 |
| Subscription Service | `prod-ih-subscription-service` | 5060 |
| Voucher Processing | `prod-ih-voucher-processing-service` | 5061 |
| Mobility Service | `prod-mobility-service` | 5065 |

### Quick manual deploy (before CI/CD is ready)

```bash
# Push image to prod Artifact Registry
docker tag <local-image> us-central1-docker.pkg.dev/aitinerehub-b2c-prod/production/<service-name>:v1
docker push us-central1-docker.pkg.dev/aitinerehub-b2c-prod/production/<service-name>:v1

# Deploy to Cloud Run
gcloud run deploy prod-<service-name> \
  --image us-central1-docker.pkg.dev/aitinerehub-b2c-prod/production/<service-name>:v1 \
  --region us-central1 \
  --project aitinerehub-b2c-prod
```

---

## 4. Application Environment Variables

Each Cloud Run service needs runtime environment variables. These should be set
via `gcloud run services update` or through the CI/CD deploy step.

### Common variables (all services)

```bash
SPRING_PROFILES_ACTIVE=prod
DB_HOST=<Cloud SQL private IP>           # from: terraform output -raw sql_private_ip
DB_PORT=3306
DB_USER=app-user
DB_PASSWORD=<from Secret Manager>        # ref: projects/aitinerehub-b2c-prod/secrets/prod-db-password
REDIS_HOST=<Redis private IP>            # from: terraform output -raw redis_host
REDIS_PORT=6379
CLOUD_SQL_CONNECTION=aitinerehub-b2c-prod:us-central1:prod-ih-db-cluster
```

### Per-service variables

Each service will need its own database name and any service-specific config:

```bash
# Example for user-service
DB_NAME=user-db

# Example for notification-service
DB_NAME=notification-db
PUBSUB_TOPIC=prod-notification-event-topic
```

### Setting env vars via gcloud

```bash
gcloud run services update prod-user-service \
  --region us-central1 \
  --project aitinerehub-b2c-prod \
  --set-env-vars "SPRING_PROFILES_ACTIVE=prod,DB_HOST=...,DB_NAME=user-db,REDIS_HOST=..."
```

> **Recommendation:** Use Secret Manager references for sensitive values instead
> of plain env vars:
> ```bash
> --set-secrets "DB_PASSWORD=prod-db-password:latest"
> ```

---

## 5. Smoke Testing

After deploying real images, verify end-to-end connectivity:

### 5.1 — Cloud Run → Cloud SQL

```bash
# Check gateway service logs for successful DB connection
gcloud logging read "resource.type=cloud_run_revision AND resource.labels.service_name=prod-ih-spring-gw-service" \
  --project=aitinerehub-b2c-prod --limit=20 --format="value(textPayload)"
```

### 5.2 — Cloud Run → Redis

```bash
# Verify Redis connectivity from service logs
gcloud logging read "resource.type=cloud_run_revision AND textPayload=~'Redis'" \
  --project=aitinerehub-b2c-prod --limit=10
```

### 5.3 — HTTPS Load Balancer

```bash
# Test the public endpoint (should hit the gateway)
curl -v https://api.itinerehub.com/actuator/health

# Verify SSL certificate
echo | openssl s_client -connect api.itinerehub.com:443 -servername api.itinerehub.com 2>/dev/null | openssl x509 -noout -dates
```

### 5.4 — Pub/Sub message flow

```bash
# Publish a test message
gcloud pubsub topics publish prod-notification-event-topic \
  --project=aitinerehub-b2c-prod \
  --message='{"test": true}'

# Check subscription for delivery
gcloud pubsub subscriptions pull prod-notifications-push-subscription \
  --project=aitinerehub-b2c-prod --auto-ack --limit=5
```

### 5.5 — Cloud Armor / WAF

```bash
# Verify WAF is blocking malicious requests
curl -v "https://api.itinerehub.com/?id=1%20OR%201=1"
# Expected: 403 Forbidden (SQL injection blocked by OWASP CRS)
```

---

## 6. Security Hardening

### 6.1 — Rotate DB password

The DB password was visible in the terraform.tfvars file during provisioning.
Rotate it:

```bash
# 1. Generate a new password
NEW_PW=$(openssl rand -base64 24)

# 2. Update Cloud SQL user
gcloud sql users set-password app-user \
  --instance=prod-ih-db-cluster \
  --project=aitinerehub-b2c-prod \
  --password="$NEW_PW" \
  --host=%

# 3. Update Secret Manager
echo -n "$NEW_PW" | gcloud secrets versions add prod-db-password \
  --project=aitinerehub-b2c-prod --data-file=-

# 4. Update terraform.tfvars with the new password
# 5. Update Cloud Run services to use the new password
# 6. Verify services reconnect successfully
```

### 6.2 — Delete local SA key files

```bash
rm -f /tmp/staging-cicd-key.json /tmp/prod-cicd-key.json
```

---

## 7. Reference — Infrastructure Endpoints

| Resource | Value |
|----------|-------|
| LB IP | `35.190.85.211` |
| Domain | `api.itinerehub.com` |
| Cloud SQL connection | `aitinerehub-b2c-prod:us-central1:prod-ih-db-cluster` |
| Cloud SQL instance | `prod-ih-db-cluster` |
| Redis instance | `prod-ih-redis` |
| Docker registry | `us-central1-docker.pkg.dev/aitinerehub-b2c-prod/production/` |
| Maven registry | `us-central1-docker.pkg.dev/aitinerehub-b2c-prod/production-pkg/` |
| Cloud Run SA | `prod-cloud-run-sa@aitinerehub-b2c-prod.iam.gserviceaccount.com` |
| CI/CD SA | `prod-cicd@aitinerehub-b2c-prod.iam.gserviceaccount.com` |
| Terraform state | `gs://itinerehub-tf-state/b2c-backend/prod` |
| GCP Project | `aitinerehub-b2c-prod` (800590950952) |
| Region | `us-central1` |

---

## Checklist

- [ ] Add CI/CD SA keys to GitHub Actions secrets
- [ ] Delete local key files from `/tmp/`
- [ ] Set up GitHub Actions deployment workflows
- [ ] Deploy real container images to all 14 services
- [ ] Configure application environment variables per service
- [ ] Wire Secret Manager references for DB password
- [ ] Smoke test: Gateway health check via `https://api.itinerehub.com`
- [ ] Smoke test: Cloud Run → Cloud SQL connectivity
- [ ] Smoke test: Cloud Run → Redis connectivity
- [ ] Smoke test: Pub/Sub message flow
- [ ] Smoke test: Cloud Armor WAF blocking
- [ ] Rotate DB password
- [ ] Verify monitoring alerts fire correctly (optional: trigger test alert)
