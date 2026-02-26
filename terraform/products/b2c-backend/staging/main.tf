###############################################################################
# DEPRECATED — Staging environment removed 2026-02-26
#
# The staging environment was redundant: provisioned 2026-02-25 with zero
# deployment history (all 14 services had exactly 1 revision). RC is the
# mature release-candidate pipeline with 295+ cumulative deploys and serves
# as the sole pre-prod gate.
#
# Resources deleted from GCP:
#   - 14 Cloud Run services  (staging-*)
#   - Cloud SQL g1-small     (staging-ih-db-cluster)
#   - Memorystore Redis 1GB  (staging-ih-redis)
#   - 3 GCS buckets          (staging-ih-{assets,service,user}-bucket)
#   - 7 Pub/Sub topics + 3 subscriptions
#   - 1 Secret               (staging-db-password)
#
# Estimated savings: ~$65/mo
#
# To re-create staging in the future, restore this file from git history
# (commit prior to this change) and run `terraform apply`.
###############################################################################
