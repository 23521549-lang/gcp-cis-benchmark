#!/bin/bash
# ================================================================
# CIS GCP Benchmark v4.0.0 — Domain 1: Identity & Access Management
# CIS 1.4 / 1.5 / 1.6 / 1.10 / 1.14
# ================================================================
set -uo pipefail

PROJECT_ID=$(gcloud config get-value project 2>/dev/null)
[ -z "$PROJECT_ID" ] && echo "ERROR: Chưa set project." && exit 1

GREEN="\033[0;32m"; RED="\033[0;31m"; YELLOW="\033[0;33m"; RESET="\033[0m"
PASS=0; FAIL=0

pass() { echo -e "${GREEN}[PASS]${RESET} $1"; PASS=$((PASS+1)); }
fail() { echo -e "${RED}[FAIL]${RESET} $1"; FAIL=$((FAIL+1)); }
info() { echo -e "${YELLOW}      $1${RESET}"; }

echo "================================================================"
echo "  CIS IAM CHECK — PROJECT: $PROJECT_ID"
echo "================================================================"
echo ""

# ── CIS 1.4 — Không có user-managed SA keys ──────────────────────
echo "[ 1.4 ] GCP-managed SA keys only..."
USER_KEYS=$(gcloud iam service-accounts list \
  --project="$PROJECT_ID" \
  --format="value(email)" 2>/dev/null | while read SA; do
  KEYS=$(gcloud iam service-accounts keys list \
    --iam-account="$SA" \
    --managed-by=user \
    --format="value(name)" 2>/dev/null)
  [ -n "$KEYS" ] && echo "$SA" || true
done)

if [ -z "$USER_KEYS" ]; then
  pass "Không có user-managed SA keys nào tồn tại"
else
  fail "Phát hiện SA có user-managed keys:"
  echo "$USER_KEYS" | while IFS= read -r line; do [ -n "$line" ] && info "$line"; done
  info "Fix: xóa keys qua Console hoặc recovery.sh"
fi
echo ""

# ── CIS 1.5 — SA không có Admin privileges ───────────────────────
echo "[ 1.5 ] SA không có Admin privileges..."
ADMIN_SA=$(gcloud projects get-iam-policy "$PROJECT_ID" \
  --format=json 2>/dev/null | python3 -c "
import json, sys
policy = json.load(sys.stdin)
admin_roles = ['roles/owner','roles/editor','roles/iam.securityAdmin']
found = []
for b in policy.get('bindings',[]):
    if b.get('role') in admin_roles:
        for m in b.get('members',[]):
            if m.startswith('serviceAccount:'):
                found.append(f'{m} -> {b[\"role\"]}')
print('\n'.join(found))
" 2>/dev/null || echo "CHECK_ERROR")

if [ "$ADMIN_SA" = "CHECK_ERROR" ]; then
  fail "Không kiểm tra được IAM policy"
elif [ -z "$ADMIN_SA" ]; then
  pass "Không có SA nào có Admin privileges"
else
  fail "Phát hiện SA có Admin privileges:"
  echo "$ADMIN_SA" | while IFS= read -r line; do [ -n "$line" ] && info "$line"; done
fi
echo ""

# ── CIS 1.6 — SA User/Token Creator không ở project level ────────
echo "[ 1.6 ] SA User/Token Creator không gán ở project level..."
SA_USER_BINDINGS=$(gcloud projects get-iam-policy "$PROJECT_ID" \
  --format=json 2>/dev/null | python3 -c "
import json, sys
policy = json.load(sys.stdin)
risky = ['roles/iam.serviceAccountUser','roles/iam.serviceAccountTokenCreator']
found = []
for b in policy.get('bindings',[]):
    if b.get('role') in risky:
        for m in b.get('members',[]):
            if m.startswith(('user:','group:')):
                found.append(f'{m} -> {b[\"role\"]}')
print('\n'.join(found))
" 2>/dev/null || echo "CHECK_ERROR")

if [ "$SA_USER_BINDINGS" = "CHECK_ERROR" ]; then
  fail "Không kiểm tra được IAM policy"
elif [ -z "$SA_USER_BINDINGS" ]; then
  pass "Không có user/group nào được gán SA User/Token Creator ở project level"
else
  fail "Phát hiện SA User/Token Creator ở project level:"
  echo "$SA_USER_BINDINGS" | while IFS= read -r line; do [ -n "$line" ] && info "$line"; done
fi
echo ""

# ── CIS 1.10 — KMS key rotation ≤ 90 ngày ────────────────────────
echo "[ 1.10 ] KMS key rotation <= 90 ngày..."
REGION="${REGION:-asia-southeast1}"
KMS_ISSUES=$(gcloud kms keyrings list \
  --location="$REGION" \
  --project="$PROJECT_ID" \
  --format="value(name)" 2>/dev/null | while read KR; do
  gcloud kms keys list \
    --keyring="$KR" \
    --location="$REGION" \
    --project="$PROJECT_ID" \
    --format=json 2>/dev/null | python3 -c "
import json, sys
keys = json.load(sys.stdin)
for k in keys:
    rotation = k.get('rotationPeriod','')
    if not rotation:
        print(f'NO_ROTATION: {k[\"name\"]}')
    else:
        secs = int(rotation.replace('s',''))
        if secs > 7776000:
            days = secs // 86400
            print(f'TOO_LONG_{days}d: {k[\"name\"]}')
" 2>/dev/null || true
done)

if [ -z "$KMS_ISSUES" ]; then
  pass "Tất cả KMS keys có rotation <= 90 ngày"
else
  fail "Phát hiện KMS keys vi phạm:"
  echo "$KMS_ISSUES" | while IFS= read -r line; do [ -n "$line" ] && info "$line"; done
  info "Fix: gcloud kms keys update --rotation-period=7776000s"
fi
echo ""

# ── CIS 1.14 — API Key có restrictions ───────────────────────────
echo "[ 1.14 ] API Key có restrictions..."
API_KEYS_RAW=$(gcloud alpha services api-keys list \
  --project="$PROJECT_ID" \
  --format=json 2>/dev/null || echo "[]")

API_ISSUES=$(echo "$API_KEYS_RAW" | python3 -c "
import json, sys
keys = json.load(sys.stdin)
issues = []
for k in keys:
    name = k.get('displayName', k.get('name','?').split('/')[-1])
    restrictions = k.get('restrictions', {})
    has_api = bool(restrictions.get('apiTargets'))
    has_http = bool(restrictions.get('browserKeyRestrictions') or
                    restrictions.get('serverKeyRestrictions') or
                    restrictions.get('androidKeyRestrictions') or
                    restrictions.get('iosKeyRestrictions'))
    if not has_api and not has_http:
        issues.append(f'NO_RESTRICTION: {name}')
print('\n'.join(issues))
" 2>/dev/null || echo "")

if [ -z "$API_ISSUES" ]; then
  pass "Tất cả API keys đều có restrictions"
else
  fail "API keys không có restrictions:"
  echo "$API_ISSUES" | while IFS= read -r line; do [ -n "$line" ] && info "$line"; done
fi
echo ""

# ── Summary ───────────────────────────────────────────────────────
TOTAL=$((PASS+FAIL))
echo "================================================================"
if [ "$FAIL" -eq 0 ]; then
  echo -e "  ${GREEN}KẾT QUẢ: $PASS/$TOTAL PASS — Đạt chuẩn CIS IAM${RESET}"
else
  echo -e "  KẾT QUẢ: ${GREEN}$PASS PASS${RESET} | ${RED}$FAIL FAIL${RESET} (tổng $TOTAL tiêu chí)"
fi
echo "================================================================"
exit $FAIL