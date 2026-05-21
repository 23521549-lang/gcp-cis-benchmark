#!/bin/bash
# ================================================================
# check_storage.sh
# CIS GCP Benchmark v4.0.0 — Domain 5: Storage
# Controls: 5.1 / 5.2
# ================================================================
set -uo pipefail

PROJECT_ID=$(gcloud config get-value project 2>/dev/null)
[ -z "$PROJECT_ID" ] && echo "ERROR    Project not configured" && exit 1

PASS=0; FAIL=0

pass() { echo "PASS     $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL     $1"; FAIL=$((FAIL+1)); }
info() { echo "         $1"; }

echo "════════════════════════════════════════════════════════════"
echo " CHECK    [D5] Storage"
echo " Project: $PROJECT_ID"
echo "════════════════════════════════════════════════════════════"

BUCKETS=$(gsutil ls -p "$PROJECT_ID" 2>/dev/null | sed 's|gs://||;s|/||' || echo "")

if [ -z "$BUCKETS" ]; then
  echo "INFO     No storage buckets found in project"
  echo "════════════════════════════════════════════════════════════"
  echo " RESULT   [D5] Storage — Status: N/A (no buckets)"
  echo "════════════════════════════════════════════════════════════"
  exit 0
fi

PUBLIC_FAIL=0; UNIFORM_FAIL=0
PUBLIC_PASS=0; UNIFORM_PASS=0

while IFS= read -r BUCKET; do
  [ -z "$BUCKET" ] && continue

  # ── CIS 5.1 — No public access ─────────────────────────────────
  IAM=$(gsutil iam get "gs://$BUCKET" 2>/dev/null || echo "{}")
  IS_PUBLIC=$(echo "$IAM" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    for b in data.get('bindings',[]):
        for m in b.get('members',[]):
            if m in ['allUsers','allAuthenticatedUsers']:
                print(f'{m}={b[\"role\"]}')
except: pass
" 2>/dev/null || echo "")

  if [ -z "$IS_PUBLIC" ]; then
    PUBLIC_PASS=$((PUBLIC_PASS+1))
  else
    PUBLIC_FAIL=$((PUBLIC_FAIL+1))
    fail "CIS-5.1  result=non-compliant bucket=$BUCKET $IS_PUBLIC"
    info "Action:  gsutil iam ch -d allUsers gs://$BUCKET"
  fi

  # ── CIS 5.2 — Uniform Bucket-Level Access ──────────────────────
  UNIFORM=$(gsutil uniformbucketlevelaccess get "gs://$BUCKET" 2>/dev/null | \
    grep -i "Enabled:" | awk '{print $2}' || echo "False")

  if [ "$UNIFORM" = "True" ]; then
    UNIFORM_PASS=$((UNIFORM_PASS+1))
  else
    UNIFORM_FAIL=$((UNIFORM_FAIL+1))
    fail "CIS-5.2  result=non-compliant bucket=$BUCKET uniform-access=disabled"
    info "Action:  gsutil uniformbucketlevelaccess set on gs://$BUCKET"
  fi

done <<< "$BUCKETS"

TOTAL_BUCKETS=$(echo "$BUCKETS" | grep -c . || echo "0")

[ "$PUBLIC_FAIL" -eq 0 ] && \
  pass "CIS-5.1  result=compliant public-access=absent buckets=$TOTAL_BUCKETS"
[ "$UNIFORM_FAIL" -eq 0 ] && \
  pass "CIS-5.2  result=compliant uniform-access=enabled buckets=$TOTAL_BUCKETS"

echo ""
TOTAL=$((PASS+FAIL))
echo "════════════════════════════════════════════════════════════"
echo " RESULT   [D5] Storage"
printf "          Passed: %-3s  Failed: %-3s  Total: %s\n" "$PASS" "$FAIL" "$TOTAL"
[ "$FAIL" -eq 0 ] \
  && echo "          Status: COMPLIANT" \
  || echo "          Status: NON-COMPLIANT"
echo "════════════════════════════════════════════════════════════"
exit $FAIL