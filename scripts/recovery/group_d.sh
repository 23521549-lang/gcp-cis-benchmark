#!/bin/bash
# ================================================================
# group_d.sh
# Group D — Infrastructure Error Recovery
# Error types: TF_CONFLICT / TF_PERMISSION / TF_QUOTA /
#              TF_TIMEOUT / TF_STALE_PLAN / TF_UNKNOWN
# ================================================================
set -uo pipefail

PROJECT_ID=$(gcloud config get-value project 2>/dev/null)
ERROR_TYPE="${ERROR_TYPE:-TF_UNKNOWN}"
APPLY_LOG="${APPLY_LOG:-/tmp/tf_apply.txt}"

D_ACTION="NONE"
D_FIXED=false
D_MANUAL_STEPS=""

ok()     { echo "OK       $1"; D_FIXED=true; }
manual() { echo "MANUAL   $1"; D_MANUAL_STEPS="${D_MANUAL_STEPS}\n  - $1"; }
err()    { echo "ERROR    $1"; }
info()   { echo "INFO     $1"; }

echo "════════════════════════════════════════════════════════════"
echo " GROUP D  Infrastructure Error Recovery"
echo " Project: $PROJECT_ID"
echo " Error  : $ERROR_TYPE"
echo " Started: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo "════════════════════════════════════════════════════════════"

# ── TF_PERMISSION — Auto-fix ──────────────────────────────────────
if echo "$ERROR_TYPE" | grep -q "TF_PERMISSION"; then
  echo "RUN      TF_PERMISSION  Granting missing IAM permissions..."

  gcloud iam service-accounts add-iam-policy-binding \
    "app-least-privilege-sa@${PROJECT_ID}.iam.gserviceaccount.com" \
    --member="serviceAccount:github-actions-sa@${PROJECT_ID}.iam.gserviceaccount.com" \
    --role="roles/iam.serviceAccountUser" \
    --project="$PROJECT_ID" --quiet 2>/dev/null \
    && ok "TF_PERMISSION  roles/iam.serviceAccountUser granted to github-actions-sa" \
    || err "TF_PERMISSION  Failed to grant serviceAccountUser — check SA permissions"

  MISSING_ROLES=$(gcloud projects get-iam-policy "$PROJECT_ID" \
    --format=json 2>/dev/null | python3 -c "
import json, sys
policy = json.load(sys.stdin)
needed = {
  'roles/compute.admin',
  'roles/storage.admin',
  'roles/iam.serviceAccountAdmin',
  'roles/cloudsql.admin',
  'roles/cloudkms.admin',
  'roles/logging.admin',
  'roles/monitoring.admin',
}
sa = 'serviceAccount:github-actions-sa@${PROJECT_ID}.iam.gserviceaccount.com'
has = set()
for b in policy.get('bindings',[]):
    if sa in b.get('members',[]): has.add(b['role'])
for r in sorted(needed - has): print(r)
" 2>/dev/null || echo "")

  if [ -n "$MISSING_ROLES" ]; then
    info "Granting missing roles to github-actions-sa:"
    echo "$MISSING_ROLES" | while read ROLE; do
      gcloud projects add-iam-policy-binding "$PROJECT_ID" \
        --member="serviceAccount:github-actions-sa@${PROJECT_ID}.iam.gserviceaccount.com" \
        --role="$ROLE" --quiet 2>/dev/null \
        && echo "         Granted: role=$ROLE" \
        || echo "         Failed:  role=$ROLE"
    done
    D_FIXED=true
  fi

  D_ACTION="PERMISSION_FIXED"
fi

# ── TF_CONFLICT — Auto-import + guidance ─────────────────────────
if echo "$ERROR_TYPE" | grep -q "TF_CONFLICT"; then
  echo "RUN      TF_CONFLICT  Attempting auto-import of conflicting resources..."

  CONFLICT_RESOURCES=""
  [ -f "$APPLY_LOG" ] && \
    CONFLICT_RESOURCES=$(grep -oP "with \K[a-z_]+\.[a-z_]+" "$APPLY_LOG" 2>/dev/null || echo "")

  if echo "$CONFLICT_RESOURCES" | grep -q "google_kms_key_ring\|keyRing"; then
    cd terraform 2>/dev/null || true
    terraform import google_kms_key_ring.my_keyring \
      "projects/${PROJECT_ID}/locations/asia-southeast1/keyRings/benchmark-keyring" \
      2>/dev/null \
      && ok "TF_CONFLICT  Imported: google_kms_key_ring.my_keyring" \
      || manual "terraform import google_kms_key_ring.my_keyring projects/${PROJECT_ID}/locations/asia-southeast1/keyRings/benchmark-keyring"
    cd .. 2>/dev/null || true
  fi

  if echo "$CONFLICT_RESOURCES" | grep -q "google_storage_bucket"; then
    BUCKET_NAME=$(grep -oP "bucket ['\"]?\Kbenchmark-storage[a-z0-9-]+" \
      "$APPLY_LOG" 2>/dev/null | head -1 || echo "")
    if [ -n "$BUCKET_NAME" ]; then
      cd terraform 2>/dev/null || true
      terraform import google_storage_bucket.log_bucket "$BUCKET_NAME" \
        2>/dev/null \
        && ok "TF_CONFLICT  Imported: google_storage_bucket.log_bucket ($BUCKET_NAME)" \
        || manual "terraform import google_storage_bucket.log_bucket $BUCKET_NAME"
      cd .. 2>/dev/null || true
    fi
  fi

  manual "Check remaining conflicts: cd terraform && terraform plan"
  manual "API Key import: gcloud alpha services api-keys list --project=$PROJECT_ID -> terraform import google_apikeys_key.restricted_api_key KEY_ID"
  manual "Re-trigger WF1 after all imports complete"
  D_ACTION="CONFLICT_PARTIAL_AUTO"
fi

# ── TF_QUOTA — Manual guidance ────────────────────────────────────
if echo "$ERROR_TYPE" | grep -q "TF_QUOTA"; then
  echo "INFO     TF_QUOTA  GCP quota exceeded"
  QUOTA_DETAIL=""
  [ -f "$APPLY_LOG" ] && \
    QUOTA_DETAIL=$(grep -i "quota\|RESOURCE_EXHAUSTED" "$APPLY_LOG" 2>/dev/null | head -5 || echo "")

  manual "Review quota: https://console.cloud.google.com/iam-admin/quotas?project=$PROJECT_ID"
  manual "Common limits: Compute instances, SQL instances, IP addresses"
  manual "Request quota increase -> wait for approval -> re-trigger WF1"
  [ -n "$QUOTA_DETAIL" ] && manual "Error detail: $QUOTA_DETAIL"
  D_ACTION="QUOTA_MANUAL"
fi

# ── TF_TIMEOUT — Manual guidance ──────────────────────────────────
if echo "$ERROR_TYPE" | grep -q "TF_TIMEOUT"; then
  echo "INFO     TF_TIMEOUT  Resource provisioning timed out"
  manual "Wait 5 minutes for GCP to stabilize"
  manual "Check if resource was created: gcloud compute instances list --project=$PROJECT_ID"
  manual "If created but not in state -> terraform import -> re-trigger WF1"
  manual "If not created -> re-trigger WF1 directly"
  D_ACTION="TIMEOUT_MANUAL"
fi

# ── TF_UNKNOWN / NONE — Manual guidance ──────────────────────────
if [ "$ERROR_TYPE" = "TF_UNKNOWN" ] || [ "$ERROR_TYPE" = "NONE" ]; then
  echo "INFO     TF_UNKNOWN  Unclassified infrastructure error"
  manual "Check detailed log in GitHub Actions artifacts"
  manual "Validate config: cd terraform && terraform validate"
  manual "Run plan manually: terraform plan -var='db_username=...' ..."
  D_ACTION="UNKNOWN_MANUAL"
fi

# ── Summary ───────────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════════════════════════"
echo " RESULT   Group D Infrastructure Error Recovery"
echo "          Action : $D_ACTION"
echo "          Fixed  : $D_FIXED"
[ -n "$D_MANUAL_STEPS" ] && echo -e "          Manual:$D_MANUAL_STEPS"
echo "════════════════════════════════════════════════════════════"

{
  echo "D_ACTION=$D_ACTION"
  echo "D_FIXED=$D_FIXED"
} >> "${GITHUB_ENV:-/dev/null}" 2>/dev/null || true

[ "$D_FIXED" = "true" ] && exit 0 || exit 1