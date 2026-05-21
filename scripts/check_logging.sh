#!/bin/bash
# ================================================================
# check_logging.sh
# CIS GCP Benchmark v4.0.0 — Domain 2: Logging & Monitoring
# Controls: 2.1 / 2.2 / 2.3 / 2.4 / 2.12 / 2.13
# ================================================================
set -uo pipefail

PROJECT_ID=$(gcloud config get-value project 2>/dev/null)
[ -z "$PROJECT_ID" ] && echo "ERROR    Project not configured" && exit 1

PASS=0; FAIL=0

pass() { echo "PASS     $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL     $1"; FAIL=$((FAIL+1)); }
info() { echo "         $1"; }

echo "════════════════════════════════════════════════════════════"
echo " CHECK    [D2] Logging & Monitoring"
echo " Project: $PROJECT_ID"
echo "════════════════════════════════════════════════════════════"

# ── CIS 2.1 — Cloud Audit Logging ────────────────────────────────
echo "CHECK    CIS-2.1  cloud-audit-logging"
AUDIT_RESULT=$(gcloud projects get-iam-policy "$PROJECT_ID" \
  --format=json 2>/dev/null | python3 -c "
import json, sys
policy = json.load(sys.stdin)
configs = policy.get('auditConfigs', [])
issues = []
found = False
for c in configs:
    if c.get('service') == 'allServices':
        found = True
        types = [x.get('logType') for x in c.get('auditLogConfigs', [])]
        for r in ['ADMIN_READ','DATA_READ','DATA_WRITE']:
            if r not in types: issues.append(f'missing={r}')
        if c.get('exemptedMembers'): issues.append('exempted-members=present')
if not found: issues.append('allServices=not-configured')
print(' '.join(issues))
" 2>/dev/null || echo "check-error")

if [ "$AUDIT_RESULT" = "check-error" ]; then
  fail "CIS-2.1  result=error unable-to-check-audit-config"
elif [ -z "$AUDIT_RESULT" ]; then
  pass "CIS-2.1  result=compliant allServices=ADMIN_READ,DATA_READ,DATA_WRITE exemptions=none"
else
  fail "CIS-2.1  result=non-compliant $AUDIT_RESULT"
  info "Action:  Configure audit logging for allServices with all log types"
fi
echo ""

# ── CIS 2.2 — Log Sink without filter ────────────────────────────
echo "CHECK    CIS-2.2  log-sink-no-filter"
SINK_RESULT=$(gcloud logging sinks list --project="$PROJECT_ID" \
  --format=json 2>/dev/null | python3 -c "
import json, sys
sinks = json.load(sys.stdin)
storage_sinks = [s for s in sinks if 'storage.googleapis.com' in s.get('destination','')]
if not storage_sinks:
    print('NO_STORAGE_SINK')
else:
    for s in storage_sinks:
        name = s.get('name','').split('/')[-1]
        filt = s.get('filter','').strip()
        if filt and filt != '(empty filter)':
            print(f'HAS_FILTER:{name}')
        else:
            print(f'OK:{name}')
" 2>/dev/null || echo "CHECK_ERROR")

if [ "$SINK_RESULT" = "CHECK_ERROR" ]; then
  fail "CIS-2.2  result=error unable-to-check-log-sinks"
elif echo "$SINK_RESULT" | grep -q "^NO_STORAGE_SINK"; then
  fail "CIS-2.2  result=non-compliant sink=none destination=storage"
  info "Action:  gcloud logging sinks create benchmark-log-sink storage.googleapis.com/BUCKET"
elif echo "$SINK_RESULT" | grep -q "^HAS_FILTER:"; then
  SINK_NAME=$(echo "$SINK_RESULT" | grep "^HAS_FILTER:" | sed 's/HAS_FILTER://')
  fail "CIS-2.2  result=non-compliant sink=$SINK_NAME filter=present"
  info "Action:  gcloud logging sinks update $SINK_NAME --log-filter=''"
else
  SINK_NAME=$(echo "$SINK_RESULT" | grep "^OK:" | sed 's/OK://')
  pass "CIS-2.2  result=compliant sink=$SINK_NAME filter=none"
fi
echo ""

# ── CIS 2.3 — Retention Policy + Bucket Lock ─────────────────────
echo "CHECK    CIS-2.3  retention-policy-bucket-lock"
BUCKET_NAME=$(gcloud logging sinks list --project="$PROJECT_ID" \
  --format="value(destination)" 2>/dev/null | \
  grep "storage.googleapis.com" | head -1 | \
  sed 's|storage.googleapis.com/||' || echo "")

if [ -z "$BUCKET_NAME" ]; then
  fail "CIS-2.3  result=error bucket=unknown (no log sink found)"
else
  RETENTION=$(gsutil retention get "gs://$BUCKET_NAME" 2>/dev/null || echo "")
  LOCKED=$(echo "$RETENTION" | grep -i "LOCKED" || true)
  PERIOD=$(echo "$RETENTION" | grep -i "Duration" || true)
  if [ -n "$LOCKED" ] && [ -n "$PERIOD" ]; then
    pass "CIS-2.3  result=compliant bucket=$BUCKET_NAME retention=locked"
    info "Period:  $PERIOD"
  elif [ -z "$PERIOD" ]; then
    fail "CIS-2.3  result=non-compliant bucket=$BUCKET_NAME retention=none"
    info "Action:  gsutil retention set 30d gs://$BUCKET_NAME"
    info "Action:  gsutil retention lock gs://$BUCKET_NAME"
  else
    fail "CIS-2.3  result=non-compliant bucket=$BUCKET_NAME retention=set lock=missing"
    info "Action:  gsutil retention lock gs://$BUCKET_NAME (IRREVERSIBLE)"
  fi
fi
echo ""

# ── CIS 2.4 — Alert Policy for Ownership Changes ─────────────────
echo "CHECK    CIS-2.4  alert-policy-ownership-changes"
METRIC_NAME=$(gcloud logging metrics list --project="$PROJECT_ID" \
  --format="value(name)" 2>/dev/null | grep -i "ownership" | head -1 || echo "")

if [ -z "$METRIC_NAME" ]; then
  fail "CIS-2.4  result=non-compliant metric=none type=ownership-changes"
  info "Action:  Create log-based metric for ownership changes"
else
  TOKEN=$(gcloud auth print-access-token 2>/dev/null || echo "")
  ALERT_OK=false
  if [ -n "$TOKEN" ]; then
    ALERT_CHECK=$(curl -s -H "Authorization: Bearer $TOKEN" \
      "https://monitoring.googleapis.com/v3/projects/$PROJECT_ID/alertPolicies" \
      2>/dev/null | python3 -c "
import json, sys
data = json.load(sys.stdin)
for p in data.get('alertPolicies', []):
    if 'ownership' in p.get('displayName','').lower():
        channels = len(p.get('notificationChannels', []))
        enabled = p.get('enabled', False)
        print(f'{channels}|{enabled}')
        break
" 2>/dev/null || echo "")
    if [ -n "$ALERT_CHECK" ]; then
      CHANNELS=$(echo "$ALERT_CHECK" | cut -d'|' -f1)
      ENABLED=$(echo "$ALERT_CHECK" | cut -d'|' -f2)
      if [ "${CHANNELS:-0}" -gt 0 ] && [ "$ENABLED" = "True" ]; then
        ALERT_OK=true
      fi
    fi
  fi
  $ALERT_OK \
    && pass "CIS-2.4  result=compliant alert=enabled channels=$CHANNELS" \
    || fail "CIS-2.4  result=non-compliant alert=disabled or channels=0"
fi
echo ""

# ── CIS 2.12 — Cloud DNS Logging ─────────────────────────────────
echo "CHECK    CIS-2.12 cloud-dns-logging"
TOKEN=$(gcloud auth print-access-token 2>/dev/null || echo "")
TOTAL_P=0; LOGGING_P=0
if [ -n "$TOKEN" ]; then
  DNS_RESULT=$(curl -s -H "Authorization: Bearer $TOKEN" \
    "https://dns.googleapis.com/dns/v1/projects/$PROJECT_ID/policies" \
    2>/dev/null | python3 -c "
import json, sys
data = json.load(sys.stdin)
policies = data.get('policies', [])
total = len(policies)
logging = sum(1 for p in policies if p.get('enableLogging', False))
print(f'{total}|{logging}')
" 2>/dev/null || echo "0|0")
  TOTAL_P=$(echo "$DNS_RESULT" | cut -d'|' -f1)
  LOGGING_P=$(echo "$DNS_RESULT" | cut -d'|' -f2)
fi

if [ "${TOTAL_P:-0}" -gt 0 ] && [ "${TOTAL_P:-0}" -eq "${LOGGING_P:-0}" ]; then
  pass "CIS-2.12 result=compliant dns-policies=$TOTAL_P logging-enabled=$LOGGING_P"
elif [ "${TOTAL_P:-0}" -eq 0 ]; then
  fail "CIS-2.12 result=non-compliant dns-policies=0"
  info "Action:  Create DNS policy with enable_logging=true"
else
  fail "CIS-2.12 result=non-compliant dns-policies=$TOTAL_P logging-enabled=$LOGGING_P"
  info "Action:  Enable logging on all DNS policies"
fi
echo ""

# ── CIS 2.13 — Cloud Asset Inventory API ─────────────────────────
echo "CHECK    CIS-2.13 cloud-asset-inventory-api"
ASSET_STATUS=$(gcloud services list --project="$PROJECT_ID" \
  --filter="name:cloudasset.googleapis.com" \
  --format="value(state)" 2>/dev/null || echo "")
if [ "$ASSET_STATUS" = "ENABLED" ]; then
  pass "CIS-2.13 result=compliant api=cloudasset.googleapis.com state=ENABLED"
else
  fail "CIS-2.13 result=non-compliant api=cloudasset.googleapis.com state=DISABLED"
  info "Action:  gcloud services enable cloudasset.googleapis.com"
fi
echo ""

# ── Summary ───────────────────────────────────────────────────────
TOTAL=$((PASS+FAIL))
echo "════════════════════════════════════════════════════════════"
echo " RESULT   [D2] Logging & Monitoring"
printf "          Passed: %-3s  Failed: %-3s  Total: %s\n" "$PASS" "$FAIL" "$TOTAL"
[ "$FAIL" -eq 0 ] \
  && echo "          Status: COMPLIANT" \
  || echo "          Status: NON-COMPLIANT"
echo "════════════════════════════════════════════════════════════"
exit $FAIL