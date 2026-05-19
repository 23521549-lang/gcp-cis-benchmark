#!/bin/bash
# ================================================================
# Nhóm D — Infrastructure errors (ngoài CIS policy)
# TF_CONFLICT / TF_PERMISSION / TF_QUOTA / TF_TIMEOUT / TF_UNKNOWN
# ================================================================
set -uo pipefail

PROJECT_ID=$(gcloud config get-value project 2>/dev/null)
ERROR_TYPE="${ERROR_TYPE:-TF_UNKNOWN}"
APPLY_LOG="${APPLY_LOG:-/tmp/tf_apply.txt}"

GREEN="\033[0;32m"; RED="\033[0;31m"; YELLOW="\033[0;33m"; RESET="\033[0m"
D_ACTION="NONE"
D_FIXED=false
D_MANUAL_STEPS=""

fixed()  { echo -e "${GREEN}[FIXED]${RESET} $1";   D_FIXED=true; }
manual() { echo -e "${YELLOW}[MANUAL]${RESET} $1"; D_MANUAL_STEPS="${D_MANUAL_STEPS}\n  - $1"; }
err()    { echo -e "${RED}[ERROR]${RESET} $1"; }

echo "================================================================"
echo "  NHÓM D — Infrastructure Error Recovery"
echo "  Error type: $ERROR_TYPE"
echo "  Project: $PROJECT_ID"
echo "================================================================"
echo ""

# ── TF_PERMISSION — Tự động fix ──────────────────────────────────
if echo "$ERROR_TYPE" | grep -q "TF_PERMISSION"; then
  echo "[ TF_PERMISSION ] Thiếu quyền Service Account..."

  # Fix 1: serviceAccountUser
  gcloud iam service-accounts add-iam-policy-binding \
    "app-least-privilege-sa@${PROJECT_ID}.iam.gserviceaccount.com" \
    --member="serviceAccount:github-actions-sa@${PROJECT_ID}.iam.gserviceaccount.com" \
    --role="roles/iam.serviceAccountUser" \
    --project="$PROJECT_ID" --quiet 2>/dev/null \
    && fixed "roles/iam.serviceAccountUser đã thêm cho github-actions-sa" \
    || err "Không thể thêm serviceAccountUser — kiểm tra quyền của github-actions-sa"

  # Fix 2: Kiểm tra và thêm các quyền cần thiết khác
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
    if sa in b.get('members',[]):
        has.add(b['role'])
missing = needed - has
for r in sorted(missing):
    print(r)
" 2>/dev/null || echo "")

  if [ -n "$MISSING_ROLES" ]; then
    echo "  Phát hiện roles còn thiếu:"
    echo "$MISSING_ROLES" | while read ROLE; do
      echo "    - $ROLE"
      gcloud projects add-iam-policy-binding "$PROJECT_ID" \
        --member="serviceAccount:github-actions-sa@${PROJECT_ID}.iam.gserviceaccount.com" \
        --role="$ROLE" --quiet 2>/dev/null \
        && echo -e "    ${GREEN}[FIXED]${RESET} $ROLE" \
        || echo -e "    ${RED}[ERROR]${RESET} $ROLE"
    done
    D_FIXED=true
  fi

  D_ACTION="PERMISSION_FIXED"
fi

# ── TF_CONFLICT — Hướng dẫn import ───────────────────────────────
if echo "$ERROR_TYPE" | grep -q "TF_CONFLICT"; then
  echo "[ TF_CONFLICT ] Resource đã tồn tại trên GCP..."

  # Tự động phát hiện resource nào bị conflict từ log
  CONFLICT_RESOURCES=""
  if [ -f "$APPLY_LOG" ]; then
    CONFLICT_RESOURCES=$(grep -oP "with \K[a-z_]+\.[a-z_]+" "$APPLY_LOG" 2>/dev/null || echo "")
  fi

  # Tự động import những resource có thể import tự động
  echo "  Đang thử tự động import các resource bị conflict..."

  # KMS KeyRing
  if echo "$CONFLICT_RESOURCES" | grep -q "google_kms_key_ring\|keyRing"; then
    cd terraform 2>/dev/null || true
    terraform import google_kms_key_ring.my_keyring \
      "projects/${PROJECT_ID}/locations/asia-southeast1/keyRings/benchmark-keyring" \
      2>/dev/null && fixed "google_kms_key_ring imported" \
      || manual "terraform import google_kms_key_ring.my_keyring projects/${PROJECT_ID}/locations/asia-southeast1/keyRings/benchmark-keyring"
    cd .. 2>/dev/null || true
  fi

  # Storage bucket
  if echo "$CONFLICT_RESOURCES" | grep -q "google_storage_bucket"; then
    BUCKET_NAME=$(grep -oP "bucket ['\"]?\Kbenchmark-storage[a-z0-9-]+" "$APPLY_LOG" 2>/dev/null | head -1 || echo "")
    if [ -n "$BUCKET_NAME" ]; then
      cd terraform 2>/dev/null || true
      terraform import google_storage_bucket.log_bucket "$BUCKET_NAME" \
        2>/dev/null && fixed "google_storage_bucket imported: $BUCKET_NAME" \
        || manual "terraform import google_storage_bucket.log_bucket $BUCKET_NAME"
      cd .. 2>/dev/null || true
    fi
  fi

  # Hướng dẫn thủ công cho những gì không tự động được
  manual "Kiểm tra resource còn conflict: cd terraform && terraform plan"
  manual "API Key: gcloud alpha services api-keys list --project=$PROJECT_ID → lấy ID → terraform import google_apikeys_key.restricted_api_key <ID>"
  manual "Sau khi import xong: trigger lại WF1"

  D_ACTION="CONFLICT_PARTIAL_AUTO"
fi

# ── TF_QUOTA — Hướng dẫn thủ công ───────────────────────────────
if echo "$ERROR_TYPE" | grep -q "TF_QUOTA"; then
  echo "[ TF_QUOTA ] GCP Quota bị vượt..."

  # Phát hiện quota nào bị vượt từ log
  QUOTA_DETAIL=""
  if [ -f "$APPLY_LOG" ]; then
    QUOTA_DETAIL=$(grep -i "quota\|RESOURCE_EXHAUSTED" "$APPLY_LOG" 2>/dev/null | head -5 || echo "")
  fi

  manual "Kiểm tra quota tại: https://console.cloud.google.com/iam-admin/quotas?project=$PROJECT_ID"
  manual "Quota thường bị vượt: Compute instances, SQL instances, IP addresses"
  manual "Request tăng quota → chờ approve → trigger lại WF1"
  [ -n "$QUOTA_DETAIL" ] && manual "Chi tiết lỗi: $QUOTA_DETAIL"
  D_ACTION="QUOTA_MANUAL"
fi

# ── TF_TIMEOUT — Hướng dẫn thủ công ─────────────────────────────
if echo "$ERROR_TYPE" | grep -q "TF_TIMEOUT"; then
  echo "[ TF_TIMEOUT ] Timeout khi tạo resource..."
  manual "Chờ 5 phút để GCP ổn định"
  manual "Kiểm tra resource có được tạo không: gcloud compute instances list --project=$PROJECT_ID"
  manual "Nếu resource đã tạo nhưng state chưa có → terraform import rồi trigger lại WF1"
  manual "Nếu resource chưa tạo → trigger lại WF1 trực tiếp"
  D_ACTION="TIMEOUT_MANUAL"
fi

# ── TF_UNKNOWN — Hướng dẫn thủ công ─────────────────────────────
if [ "$ERROR_TYPE" = "TF_UNKNOWN" ] || [ "$ERROR_TYPE" = "NONE" ]; then
  echo "[ TF_UNKNOWN ] Lỗi không xác định..."
  manual "Xem log chi tiết trong GitHub Actions artifacts"
  manual "Kiểm tra terraform validate: cd terraform && terraform validate"
  manual "Thử plan lại: terraform plan -var=\"db_username=...\" ..."
  D_ACTION="UNKNOWN_MANUAL"
fi

# ── Xuất kết quả ─────────────────────────────────────────────────
echo ""
echo "================================================================"
echo "  Nhóm D Summary"
echo "  D_ACTION: $D_ACTION"
echo "  D_FIXED:  $D_FIXED"
[ -n "$D_MANUAL_STEPS" ] && echo -e "  Manual steps needed:$D_MANUAL_STEPS"
echo "================================================================"

echo "D_ACTION=$D_ACTION"   >> "${GITHUB_ENV:-/dev/null}" 2>/dev/null || true
echo "D_FIXED=$D_FIXED"     >> "${GITHUB_ENV:-/dev/null}" 2>/dev/null || true
echo "D_MANUAL=$D_MANUAL_STEPS" >> "${GITHUB_ENV:-/dev/null}" 2>/dev/null || true

# Exit 0 nếu đã fix được, 1 nếu cần manual
[ "$D_FIXED" = "true" ] && exit 0 || exit 1