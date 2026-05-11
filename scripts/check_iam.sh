#!/bin/bash
# ================================================================
# CIS GCP Benchmark v4.0.0 — Domain 1: Identity & Access Management
# CIS 1.4 — Only GCP-managed SA keys
# CIS 1.5 — SA không có Admin privileges
# CIS 1.6 — Không gán SA User/Token Creator ở project level
# CIS 1.10 — KMS key rotation <= 90 ngày
# CIS 1.14 — API Key chỉ gọi API cần thiết
# ================================================================

set -euo pipefail
PROJECT_ID=$(gcloud config get-value project 2>/dev/null)

if [ -z "$PROJECT_ID" ]; then
  echo "ERROR: Chưa set project. Chạy: gcloud config set project <PROJECT_ID>"
  exit 1
fi

GREEN="\033[0;32m"; RED="\033[0;31m"; YELLOW="\033[0;33m"; RESET="\033[0m"
PASS=0; FAIL=0

pass() { echo -e "${GREEN}[PASS]${RESET} $1"; PASS=$((PASS+1)); }
fail() { echo -e "${RED}[FAIL]${RESET} $1"; FAIL=$((FAIL+1)); }
info() { echo -e "${YELLOW}      $1${RESET}"; }

echo "================================================================"
echo "  CIS IAM CHECK — PROJECT: $PROJECT_ID"
echo "================================================================"
echo ""

# ----------------------------------------------------------------
# CIS 1.4 — Chỉ dùng GCP-managed SA keys
# ----------------------------------------------------------------
echo "[ 1.4 ] GCP-managed SA keys only..."
USER_MANAGED_KEYS=$(gcloud iam service-accounts list \
  --project="$PROJECT_ID" \
  --format="value(email)" 2>/dev/null | while read SA; do
  KEYS=$(gcloud iam service-accounts keys list \
    --iam-account="$SA" \
    --managed-by=user \
    --format="value(name)" 2>/dev/null)
  if [ -n "$KEYS" ]; then
    echo "$SA"
  fi
done)

if [ -z "$USER_MANAGED_KEYS" ]; then
  pass "Không có user-managed SA keys nào tồn tại"
else
  fail "Phát hiện user-managed keys trên: $USER_MANAGED_KEYS"
  info "Sửa: xóa key hoặc enable org policy iam.disableServiceAccountKeyCreation"
fi
echo ""

# ----------------------------------------------------------------
# CIS 1.5 — SA không có Admin privileges
# ----------------------------------------------------------------
echo "[ 1.5 ] SA không có Admin privileges..."
ADMIN_SA=$(gcloud projects get-iam-policy "$PROJECT_ID" \
  --format=json 2>/dev/null | python3 -c "
import json, sys
policy = json.load(sys.stdin)
admin_roles = ['roles/owner', 'roles/editor', 'roles/iam.securityAdmin']
found = []
for b in policy.get('bindings', []):
    if b.get('role') in admin_roles:
        for m in b.get('members', []):
            if m.startswith('serviceAccount:'):
                found.append(f'{m} -> {b[\"role\"]}')
print('\n'.join(found))
")

if [ -z "$ADMIN_SA" ]; then
  pass "Không có SA nào có Admin privileges"
else
  fail "Phát hiện SA với Admin privileges:"
  echo "$ADMIN_SA" | while read line; do info "$line"; done
fi
echo ""

# ----------------------------------------------------------------
# CIS 1.6 — Không gán serviceAccountUser / serviceAccountTokenCreator ở project level
# ----------------------------------------------------------------
echo "[ 1.6 ] SA User/Token Creator không gán ở project level..."
DANGEROUS_BINDINGS=$(gcloud projects get-iam-policy "$PROJECT_ID" \
  --format=json 2>/dev/null | python3 -c "
import json, sys
policy = json.load(sys.stdin)
dangerous = ['roles/iam.serviceAccountUser', 'roles/iam.serviceAccountTokenCreator']
found = []
for b in policy.get('bindings', []):
    if b.get('role') in dangerous:
        for m in b.get('members', []):
            if m.startswith('user:') or m.startswith('group:'):
                found.append(f'{m} -> {b[\"role\"]}')
print('\n'.join(found))
")

if [ -z "$DANGEROUS_BINDINGS" ]; then
  pass "Không có user/group nào được gán SA User/Token Creator ở project level"
else
  fail "Phát hiện binding nguy hiểm ở project level:"
  echo "$DANGEROUS_BINDINGS" | while read line; do info "$line"; done
  info "Sửa: remove binding hoặc chuyển xuống resource level"
fi
echo ""

# ----------------------------------------------------------------
# CIS 1.10 — KMS key rotation <= 90 ngày
# ----------------------------------------------------------------
echo "[ 1.10 ] KMS key rotation <= 90 ngày..."
KMS_ISSUES=$(gcloud kms keyrings list \
  --location="asia-southeast1" \
  --project="$PROJECT_ID" \
  --format="value(name)" 2>/dev/null | while read KR; do
  gcloud kms keys list \
    --keyring="$KR" \
    --location="asia-southeast1" \
    --project="$PROJECT_ID" \
    --format=json 2>/dev/null | python3 -c "
import json, sys
keys = json.load(sys.stdin)
for k in keys:
    period = k.get('rotationPeriod', '')
    if not period:
        print(f'NO_ROTATION: {k[\"name\"]}')
    else:
        seconds = int(period.rstrip('s'))
        if seconds > 7776000:  # 90 ngày
            days = seconds // 86400
            print(f'TOO_LONG ({days}d): {k[\"name\"]}')
"
done)

if [ -z "$KMS_ISSUES" ]; then
  pass "Tất cả KMS keys có rotation <= 90 ngày"
else
  fail "Phát hiện KMS keys vi phạm:"
  echo "$KMS_ISSUES" | while read line; do info "$line"; done
  info "Sửa: gcloud kms keys update --rotation-period=7776000s"
fi
echo ""

# ----------------------------------------------------------------
# CIS 1.14 — API Key chỉ gọi API cần thiết
# ----------------------------------------------------------------
echo "[ 1.14 ] API Key có restrictions..."
TOKEN=$(gcloud auth print-access-token 2>/dev/null)
API_KEYS=$(curl -s -H "Authorization: Bearer $TOKEN" \
  "https://apikeys.googleapis.com/v2/projects/$PROJECT_ID/locations/global/keys" \
  2>/dev/null | python3 -c "
import json, sys
data = json.load(sys.stdin)
keys = data.get('keys', [])
unrestricted = []
for k in keys:
    restrictions = k.get('restrictions', {})
    api_targets = restrictions.get('apiTargets', [])
    if not api_targets:
        unrestricted.append(k.get('displayName', k.get('name', 'unknown')))
print('\n'.join(unrestricted))
" 2>/dev/null)

if [ -z "$API_KEYS" ]; then
  pass "Tất cả API keys đều có restrictions"
else
  fail "Phát hiện API key không có restrictions:"
  echo "$API_KEYS" | while read line; do info "$line"; done
  info "Sửa: thêm api_targets restrictions vào API key"
fi
echo ""

# ----------------------------------------------------------------
# Tổng kết
# ----------------------------------------------------------------
TOTAL=$((PASS+FAIL))
echo "================================================================"
if [ "$FAIL" -eq 0 ]; then
  echo -e "  ${GREEN}KẾT QUẢ: $PASS/$TOTAL PASS — Đạt chuẩn CIS IAM${RESET}"
else
  echo -e "  KẾT QUẢ: ${GREEN}$PASS PASS${RESET} | ${RED}$FAIL FAIL${RESET} (tổng $TOTAL tiêu chí)"
fi
echo "================================================================"
exit $FAIL