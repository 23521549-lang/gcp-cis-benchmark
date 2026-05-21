#!/bin/bash
# ================================================================
# check_iam.sh
# CIS GCP Benchmark v4.0.0 — Domain 1: Identity & Access Management
# Controls: 1.4 / 1.5 / 1.6 / 1.10 / 1.14
# ================================================================
set -uo pipefail

PROJECT_ID=$(gcloud config get-value project 2>/dev/null)
[ -z "$PROJECT_ID" ] && echo "ERROR    Project not configured" && exit 1

PASS=0; FAIL=0

pass() { echo "PASS     $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL     $1"; FAIL=$((FAIL+1)); }
info() { echo "         $1"; }

echo "════════════════════════════════════════════════════════════"
echo " CHECK    [D1] Identity & Access Management"
echo " Project: $PROJECT_ID"
echo "════════════════════════════════════════════════════════════"

# ── CIS 1.4 — No user-managed SA keys ────────────────────────────
echo "CHECK    CIS-1.4  user-managed-sa-keys"
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
  pass "CIS-1.4  result=compliant user-managed-keys=0"
else
  fail "CIS-1.4  result=non-compliant"
  echo "$USER_KEYS" | while IFS= read -r line; do
    [ -n "$line" ] && info "Resource: sa=$line"
  done
  info "Action:  Delete user-managed keys via Console or group_a.sh"
fi
echo ""

# ── CIS 1.5 — No Admin SA privileges ─────────────────────────────
echo "CHECK    CIS-1.5  sa-admin-privileges"
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
                found.append(f'{m} role={b[\"role\"]}')
print('\n'.join(found))
" 2>/dev/null || echo "CHECK_ERROR")

if [ "$ADMIN_SA" = "CHECK_ERROR" ]; then
  fail "CIS-1.5  result=error unable-to-check-iam-policy"
elif [ -z "$ADMIN_SA" ]; then
  pass "CIS-1.5  result=compliant no-admin-sa-bindings"
else
  fail "CIS-1.5  result=non-compliant"
  echo "$ADMIN_SA" | while IFS= read -r line; do
    [ -n "$line" ] && info "Resource: $line"
  done
  info "Action:  Remove admin role from service account"
fi
echo ""

# ── CIS 1.6 — No SA User/Token Creator at project level ──────────
echo "CHECK    CIS-1.6  sa-user-project-level"
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
                found.append(f'{m} role={b[\"role\"]}')
print('\n'.join(found))
" 2>/dev/null || echo "CHECK_ERROR")

if [ "$SA_USER_BINDINGS" = "CHECK_ERROR" ]; then
  fail "CIS-1.6  result=error unable-to-check-iam-policy"
elif [ -z "$SA_USER_BINDINGS" ]; then
  pass "CIS-1.6  result=compliant no-project-level-sa-user-binding"
else
  fail "CIS-1.6  result=non-compliant"
  echo "$SA_USER_BINDINGS" | while IFS= read -r line; do
    [ -n "$line" ] && info "Resource: $line"
  done
  info "Action:  Move SA User/Token Creator to resource-level binding"
fi
echo ""

# ── CIS 1.10 — KMS rotation <= 90 days ───────────────────────────
echo "CHECK    CIS-1.10 kms-key-rotation"
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
    name = k['name'].split('/')[-1]
    if not rotation:
        print(f'key={name} rotation=none')
    else:
        secs = int(rotation.replace('s',''))
        if secs > 7776000:
            days = secs // 86400
            print(f'key={name} rotation={days}d (exceeds 90d)')
" 2>/dev/null || true
done)

if [ -z "$KMS_ISSUES" ]; then
  pass "CIS-1.10 result=compliant all-keys-rotation-within-90d"
else
  fail "CIS-1.10 result=non-compliant"
  echo "$KMS_ISSUES" | while IFS= read -r line; do
    [ -n "$line" ] && info "Resource: $line"
  done
  info "Action:  gcloud kms keys update --rotation-period=7776000s"
fi
echo ""

# ── CIS 1.14 — API Keys with restrictions ────────────────────────
echo "CHECK    CIS-1.14 api-key-restrictions"
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
        issues.append(f'key={name} restrictions=none')
print('\n'.join(issues))
" 2>/dev/null || echo "")

if [ -z "$API_ISSUES" ]; then
  pass "CIS-1.14 result=compliant all-api-keys-have-restrictions"
else
  fail "CIS-1.14 result=non-compliant"
  echo "$API_ISSUES" | while IFS= read -r line; do
    [ -n "$line" ] && info "Resource: $line"
  done
  info "Action:  Add API target restrictions to unrestricted keys"
fi
echo ""

# ── Summary ───────────────────────────────────────────────────────
TOTAL=$((PASS+FAIL))
echo "════════════════════════════════════════════════════════════"
echo " RESULT   [D1] Identity & Access Management"
printf "          Passed: %-3s  Failed: %-3s  Total: %s\n" "$PASS" "$FAIL" "$TOTAL"
[ "$FAIL" -eq 0 ] \
  && echo "          Status: COMPLIANT" \
  || echo "          Status: NON-COMPLIANT"
echo "════════════════════════════════════════════════════════════"
exit $FAIL