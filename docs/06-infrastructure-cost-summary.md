# Itinerehub — Infrastructure Cost Summary

**Date:** 2026-02-25
**Prepared by:** Engineering & Technology

---

## What Are We Building?

Itinerehub runs two products on Google Cloud Platform (GCP):

- **B2C Backend** — consumer-facing travel app (14 microservices, MySQL, Redis)
- **B2B Agency** — travel agency platform (19 microservices, PostgreSQL)

Each product has three environments: **Dev** (existing), **Staging**, and **Production**.

## New Infrastructure to Provision

| Environment | GCP Project | What's New | Status |
|-------------|-------------|------------|--------|
| B2C Staging | `aitinerehub` (shared with dev) | VPC, DB, Redis, 14 Cloud Run services, Pub/Sub | **To provision** |
| B2C Production | `aitinerehub-b2c-prod` (800590950952) | Full stack incl. LB, WAF, CDN, HA database | **To provision** |
| B2B Production | `aitinereagency-prod` | Full stack (Terraform ready, timing TBD) | Planned |

> B2C Dev, B2B Dev, and B2B Staging already exist and incur no additional cost.

---

## Monthly Cost Breakdown

### B2C Production — ~$220-330/month

| Resource | What It Does | Est. Cost |
|----------|-------------|-----------|
| Cloud SQL (MySQL, HA) | Primary database, auto-failover, encrypted | ~$120-150 |
| Redis (Memorystore) | In-memory cache for performance | ~$35 |
| Cloud Run (14 services) | Application containers, auto-scale | ~$30-80 |
| Load Balancer + CDN | Global HTTPS entry point, caching | ~$19-30 |
| Cloud Armor (WAF) | Blocks SQL injection, XSS, DDoS | ~$5-10 |
| Storage, Registry, Pub/Sub, Egress | Supporting services | ~$13-22 |

### B2C Staging — ~$75-100/month

| Resource | What It Does | Est. Cost |
|----------|-------------|-----------|
| Cloud SQL (MySQL) | Smaller DB for QA testing, no HA | ~$25-30 |
| Redis (Memorystore) | Same as prod (required by app) | ~$35 |
| Cloud Run (14 services) | Scale-to-zero when idle | ~$10-25 |
| Storage, Registry, Pub/Sub, Egress | Supporting services | ~$5-10 |

> Staging has no Load Balancer or WAF — QA traffic hits Cloud Run directly to save cost.

### B2B Production (when provisioned) — ~$190-310/month

| Resource | What It Does | Est. Cost |
|----------|-------------|-----------|
| Cloud SQL (PostgreSQL, HA) | Primary database, auto-failover | ~$120-150 |
| Cloud Run (19 services) | Application containers, auto-scale | ~$40-100 |
| Load Balancer + CDN + WAF | Security + performance | ~$24-40 |
| Storage, Registry, Pub/Sub, Egress | Supporting services | ~$8-18 |

---

## Total New Monthly Spend

| Scenario | B2C Staging | B2C Prod | B2B Prod | Total |
|----------|-------------|----------|----------|-------|
| **Phase 1 (now)** | $75-100 | $220-330 | — | **$295-430** |
| **Phase 2 (+ B2B prod)** | $75-100 | $220-330 | $190-310 | **$485-740** |
| **Phase 2 + 1yr CUD** | $75-100 | $190-295 | $160-275 | **$425-670** |

---

## How We Keep Costs Low

| Strategy | Saving | Applied To |
|----------|--------|------------|
| **Scale-to-zero** | Services shut down when idle, no charge | All Cloud Run services |
| **cpu_idle: true** | CPU de-allocated between requests | All Cloud Run services |
| **No Cloud NAT** | Cloud Run connects directly to VPC | All environments |
| **Staging: lightweight DB** | Shared-core instance (db-g1-small) | Staging |
| **Staging: no LB/WAF** | Traffic hits Cloud Run directly | Staging |
| **AR cleanup policies** | Auto-delete old Docker images | All environments |
| **Flow log sampling at 10%** | Reduces logging cost by ~80% | Production |

## Committed Use Discounts (Optional)

GCP offers discounts when you commit to running a database for 1 or 3 years. Since the production database runs 24/7, this is essentially free savings:

| Commitment | Cloud SQL Discount | Annual Saving (per product) |
|------------|-------------------|----------------------------|
| **1-year** | ~25% off | **~$360-450/year** |
| **3-year** | ~52% off | **~$750-935/year** |

> **Recommendation:** Purchase a 1-year CUD for B2C prod Cloud SQL after launch.
> This is done via the GCP Billing console — no code changes needed.

---

## Security Included in Production

Production environments come with enterprise-grade security at minimal additional cost:

- **Cloud Armor WAF** — blocks SQL injection, XSS, and 6 other OWASP attack categories
- **DDoS protection** — ML-based adaptive protection (Layer 7)
- **Rate limiting** — 500 requests/minute per IP, auto-ban abusers for 10 minutes
- **TLS 1.2+** — all traffic encrypted with managed SSL certificates
- **Private database** — no public IP, SSL-only connections
- **Audit logging** — all data access logged for compliance
- **Least-privilege IAM** — dedicated service accounts per concern, no broad permissions
