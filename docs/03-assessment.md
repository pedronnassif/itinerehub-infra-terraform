# Itinerehub B2C - Infrastructure Assessment

**Date:** 2026-02-22
**Scope:** GCP project `aitinerehub` (541454969801)

---

## Executive Summary

The current infrastructure uses sound architectural patterns (microservices on Cloud Run, managed MySQL) but has significant **security vulnerabilities** and **cost inefficiencies** that must be addressed before production launch. The most critical issues are hardcoded credentials in Cloud Run environment variables and the absence of SSL enforcement on database connections.

---

## What Is Working Well

### 1. Microservices Architecture
The clear separation of concerns across 16 microservices (user, trip, booking, etc.) with a Spring Cloud Gateway is a solid pattern. Each service has its own database schema, enabling independent scaling and deployment.

### 2. CI/CD Pipeline
GitHub Actions is properly integrated for continuous deployment to Cloud Run. Services are deployed via a dedicated `github-actions` service account with appropriate permissions.

### 3. Environment Isolation
Three distinct environments (dev, RC, prod) with separate VPCs, Cloud SQL instances, and VPC connectors provide good isolation. The naming convention (`dev-`, `rc-`, `prod-`) is consistent and clear.

### 4. VPC Design
Custom VPCs with private subnets, VPC peering for Cloud SQL, and VPC Access Connectors for Cloud Run enable proper network isolation. IAP-only SSH access to VMs is a good security practice.

### 5. Cloud SQL Configuration
- Deletion protection is enabled on all instances
- Automated backups with binary logging for point-in-time recovery
- Storage auto-resize prevents disk full scenarios
- IAM authentication is enabled as an option

### 6. Scale-to-Zero on Cloud Run
Using managed serverless with max 1 instance for dev/RC is cost-effective for non-production workloads.

### 7. Secret Manager Adoption
170+ secrets are stored in Secret Manager, showing an intention to centralize secret management.

---

## Critical Issues (Must Fix Before Production)

### CRITICAL-1: Hardcoded Credentials in Cloud Run Environment Variables

**Severity: CRITICAL**

Database passwords, token hashing keys, and B2B service credentials are hardcoded as plaintext environment variables in Cloud Run service configurations. This means:
- Anyone with Cloud Run viewer access can see production database passwords
- Credentials are visible in deployment logs and revision history
- No rotation mechanism exists

**Recommendation:** Use Secret Manager references in Cloud Run (`valueFrom.secretKeyRef`) instead of plaintext `value`. Example:
```yaml
env:
  - name: DATABASE_PASSWORD
    valueSource:
      secretKeyRef:
        secret: PROD_DATABASE_PASSWORD
        version: latest
```

### CRITICAL-2: SSL Not Enforced on Cloud SQL

**Severity: CRITICAL**

All three Cloud SQL instances have `sslMode: ALLOW_UNENCRYPTED_AND_ENCRYPTED`. This means database traffic can flow unencrypted over the network, even if it's within the VPC.

**Recommendation:** Set `ssl_mode = "ENCRYPTED_ONLY"` for all instances, especially production.

### CRITICAL-3: Cloud SQL Has Public IP with Developer IPs Whitelisted

**Severity: HIGH**

The dev instance has 10 individual developer IPs whitelisted for direct database access. These are residential/office IPs that change frequently, creating maintenance burden and security risk.

**Recommendation:**
- Remove all authorized networks from production
- Disable public IP entirely for production
- Use Cloud SQL Auth Proxy or IAP tunneling for developer access
- For dev, consider using Cloud SQL Auth Proxy through IAP instead of IP whitelisting

### CRITICAL-4: Using Root Database User

**Severity: HIGH**

The Cloud Run services connect to MySQL as `root` with full privileges. A compromised service could drop databases, create users, or exfiltrate all data.

**Recommendation:** Create least-privilege application users:
```sql
CREATE USER 'app-user'@'%' IDENTIFIED BY '...';
GRANT SELECT, INSERT, UPDATE, DELETE ON `user-db`.* TO 'app-user'@'%';
-- Repeat per service/database
```

---

## Important Issues (Should Fix)

### IMPORTANT-1: Self-Managed Redis on Compute Engine

**Severity: MEDIUM**

Redis runs on a custom e2 VM with an external IP, requiring manual patching, monitoring, and backup management.

**Recommendation:** Migrate to **Memorystore for Redis** (managed service). Cost difference is minimal (~$10/month more) but eliminates operational overhead and improves reliability.

### IMPORTANT-2: Default Compute Engine Service Account Used

**Severity: MEDIUM**

All Cloud Run services run as `541454969801-compute@developer.gserviceaccount.com` (the default compute SA), which typically has broad Editor-level permissions.

**Recommendation:** Create a dedicated service account per environment with only the permissions each service needs (Secret Manager access, Cloud SQL client, Pub/Sub publisher/subscriber, Storage viewer).

### IMPORTANT-3: No Monitoring or Alerting

**Severity: MEDIUM**

No alert policies, uptime checks, or monitoring dashboards are configured. Infrastructure issues would go unnoticed until users report problems.

**Recommendation:** Set up alerts for:
- Cloud SQL CPU > 80%, disk > 80%, connection errors
- Cloud Run 5xx error rate > 5%, latency P99 > 5s
- Pub/Sub dead letter queue depth > 0
- Create a Cloud Monitoring dashboard for the microservices fleet

### IMPORTANT-4: Publicly Accessible GCS Bucket

**Severity: MEDIUM**

The bucket `ih-flight-test-bucket` has `allUsers:READER` ACL, making its contents publicly accessible to anyone on the internet. This was likely set for testing but should be reviewed.

**Recommendation:** Remove public access unless explicitly needed. If needed for a CDN use case, front it with Cloud CDN and signed URLs.

### IMPORTANT-5: Inconsistent Bucket Security Settings

**Severity: MEDIUM**

Several buckets (`ih-dev-service-bucket`, `ih-flight-test-bucket`, `ih-rc-service-bucket`) use fine-grained ACLs instead of uniform bucket-level access. This makes access harder to audit and manage.

**Recommendation:** Enable uniform bucket-level access on all buckets. This is a GCP best practice and simplifies IAM.

### IMPORTANT-6: Overly Broad IAM for `ih-bucket-user` Service Account

**Severity: MEDIUM**

The `ih-bucket-user` service account has an unusually broad set of permissions including: `apigateway.admin`, `pubsub.editor/publisher/subscriber`, `storage.objectAdmin`, `secretmanager.secretAccessor`, and `serviceusage.consumer`. A bucket user SA should only need storage permissions.

**Recommendation:** Audit and reduce permissions. Create separate SAs for different concerns (storage, pubsub, secrets).

### IMPORTANT-7: No Lifecycle Policies on GCS or Artifact Registry

**Severity: LOW**

Artifact Registry repositories are accumulating images without cleanup (~180 GB total). GCS buckets have no lifecycle policies or versioning.

**Recommendation:**
- Add cleanup policies to Artifact Registry (keep 10 recent, delete untagged after 30 days)
- Add GCS lifecycle rules (transition to Nearline/Coldline for old data)
- Enable versioning on data-critical buckets

### IMPORTANT-8: Multiple External Users with Broad Access

**Severity: MEDIUM**

Several VentureDive and external developer accounts have significant access including `viewer`, `secretmanager.secretAccessor`, `run.viewer`, `cloudsql.editor`, and `storage.objectAdmin` roles. If any of these are former team members or contractors, their access should be revoked.

**Recommendation:** Conduct quarterly IAM access reviews. Remove accounts no longer needed. Use Google Groups for team-based access instead of individual accounts.

### IMPORTANT-9: VPC Connector vs Direct VPC Egress

**Severity: LOW (COST)**

Each VPC Access Connector runs minimum 2 x e2-micro instances (~$7/month each). Three connectors = ~$21/month minimum even when idle.

**Recommendation:** For production, use **Direct VPC Egress** (Cloud Run v2 feature) instead of VPC connectors. This eliminates the connector instances and their costs.

---

## Cost Optimization Opportunities

| Issue | Current Cost | After Optimization | Savings |
|-------|-------------|-------------------|---------|
| Redis VM with external IP | ~$25/month | Memorystore ~$35/month | +$10 but managed |
| SonarQube VM (terminated) with static IP | ~$7/month (IP only) | Release static IP | $7/month |
| 3 VPC Connectors (6 VMs) | ~$21/month | Direct VPC Egress | $21/month |
| Artifact Registry (180 GB) | ~$18/month | Cleanup policies (~50 GB) | $13/month |
| Region: me-central1 | Premium pricing | us-central1 (cheapest) | ~15-20% |
| All services 1Gi memory | Overprovisioned | Right-size to 512Mi | Variable |

### Region Cost Comparison

| Resource | me-central1 | us-central1 | Savings |
|----------|------------|-------------|---------|
| Cloud Run (per vCPU-s) | $0.00002400 | $0.00002400 | 0% |
| Cloud SQL (db-f1-micro) | ~$10/month | ~$8/month | ~20% |
| Memorystore Redis 1GB | ~$40/month | ~$35/month | ~12% |
| GCS Standard (per GB) | $0.023 | $0.020 | ~13% |

us-central1 is recommended for production as the cheapest tier-1 region, unless data residency requirements mandate a specific region.

---

## Recommendations Summary

### Phase 1: Pre-Launch (Must Do)

1. **Move all secrets out of Cloud Run env vars** into Secret Manager references
2. **Enforce SSL** on Cloud SQL (`ENCRYPTED_ONLY`)
3. **Disable public IP** on production Cloud SQL
4. **Create dedicated application database users** (not root)
5. **Create dedicated Cloud Run service accounts** (not default compute SA)
6. **Set up basic monitoring alerts** (CPU, errors, disk)

### Phase 2: Launch

7. **Deploy to production** via Terraform in new project (us-central1)
8. **Use Memorystore Redis** instead of self-managed VM
9. **Use Direct VPC Egress** instead of VPC connectors
10. **Right-size Cloud Run memory** to 512Mi (most services)
11. **Enable Cloud Run health checks** (HTTP-based, not TCP)

### Phase 3: Post-Launch

12. **Add Artifact Registry cleanup policies**
13. **Add GCS lifecycle rules**
14. **Release unused static IPs** (SonarQube)
15. **Set up Cloud Monitoring dashboards**
16. **Enable Cloud Trace** for distributed tracing
17. **Consider per-service database users** for further isolation
18. **Implement database connection pooling** if not already done
19. **Add uptime checks** for the gateway endpoint
20. **Review and remove unused service accounts** (testi-799, testing-access-helio)

---

## Risk Assessment

| Risk | Probability | Impact | Mitigation |
|------|------------|--------|------------|
| Data breach via hardcoded credentials | Medium | Critical | Move to Secret Manager refs |
| Database compromise via unencrypted traffic | Low | Critical | Enforce SSL |
| Unauthorized DB access via whitelisted IPs | Medium | High | Remove public IP, use IAP |
| Service outage undetected | High | High | Set up monitoring/alerting |
| Runaway costs from uncontrolled scaling | Low | Medium | Set max instances, budget alerts |
| Redis data loss | Medium | Medium | Migrate to Memorystore |
| Artifact Registry storage bloat | High | Low | Cleanup policies |
