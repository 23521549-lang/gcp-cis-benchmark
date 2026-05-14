#!/bin/bash
# ================================================================
# CIS GCP Benchmark v4.0.0 — Domain 2: Logging & Monitoring
# CIS 2.1 — Cloud Audit Logging đủ 3 loại, không exemptedMembers
# CIS 2.2 — Log Sink export toàn bộ log, không filter
# CIS 2.3 — Retention Policy + Bucket Lock
# CIS 2.4 — Alert: Project Ownership Changes
# CIS 2.12 — Cloud DNS Logging bật cho tất cả VPC
# CIS 2.13 — Cloud Asset Inventory API bật
# ================================================================

set -euo pipefail
PROJECT_ID=$(gcloud config get-value project 2>/dev/null)

if [ -z "$PROJECT_ID" ]; then
  echo "ERROR: Chưa set project."
  exit 1
fi

GREEN="\033[0;32m"; RED="\033[0;31m"; YELLOW="\033[0;33m"; RESET="\033[0m"
PASS=0; FAIL=0

pass() { echo -e "${GREEN}[PASS]${RESET} $1"; PASS=$((PASS+1)); }
fail() { echo -e "${RED}[FAIL]${RESET} $1"; FAIL=$((FAIL+1)); }
info() { echo -e "${YELLOW}      $1${RESET}"; }

echo "================================================================"
echo "  CIS LOGGING CHECK — PROJECT: $PROJECT_ID"
echo "================================================================"
echo ""

# ----------------------------------------------------------------
# CIS 2.1 — Cloud Audit Logging đủ 3 loại, không exemptedMembers
# ----------------------------------------------------------------
echo "[ 2.1 ] Cloud Audit Logging..."
AUDIT_RESULT=$(gcloud projects get-iam-policy "$PROJECT_ID" \
  --format=json 2>/dev/null | python3 -c "
import json, sys
policy = json.load(sys.stdin)
configs = policy.get('auditConfigs', [])
issues = []
found_all_services = False
for c in configs:
    if c.get('service') == 'allServices':
        found_all_services = True
        types = [x.get('logType') for x in c.get('auditLogConfigs', [])]
        exempted = c.get('exemptedMembers', [])
        for required in ['ADMIN_READ', 'DATA_READ', 'DATA_WRITE']:
            if required not in types:
                issues.append(f'MISSING_TYPE:{required}')
        if exempted:
            issues.append(f'EXEMPTED_MEMBERS:{len(exempted)}')
if not found_all_services:
    issues.append('NO_ALL_SERVICES_CONFIG')
print('\n'.join(issues))
")

if [ -z "$AUDIT_RESULT" ]; then
  pass "allServices có đủ ADMIN_READ, DATA_READ, DATA_WRITE, không có exemptedMembers"
else
  fail "Audit logging vi phạm:"
  echo "$AUDIT_RESULT" | while read line; do info "$line"; done
fi
echo ""

# ----------------------------------------------------------------
# CIS 2.2 — Log Sink không có filter (export toàn bộ log)
# ----------------------------------------------------------------
echo "[ 2.2 ] Log Sink — không có filter..."
SINK_ISSUES=$(gcloud logging sinks list --project="$PROJECT_ID" \
  --format=json 2>/dev/null | python3 -c "
import json, sys
sinks = json.load(sys.stdin)
issues = []
storage_sinks = [s for s in sinks if 'storage.googleapis.com' in s.get('destination','')]
if not storage_sinks:
    issues.append('NO_STORAGE_SINK: không tìm thấy Log Sink nào đến Storage Bucket')
else:
    for s in storage_sinks:
        name = s.get('name', 'unknown').split('/')[-1]
        filt = s.get('filter', '').strip()
        if filt:
            issues.append(f'HAS_FILTER: {name} có filter — cần xóa để export toàn bộ log')
        else:
            print(f'OK: {name}')
for i in issues:
    print(i)
")

if echo "$SINK_ISSUES" | grep -q "^OK:"; then
  pass "Log Sink hợp lệ — không có filter"
  PROBLEMS=$(echo "$SINK_ISSUES" | grep -v "^OK:" || true)
  if [ -n "$PROBLEMS" ]; then
    fail "Một số sink có vấn đề:"
    echo "$PROBLEMS" | while read line; do info "$line"; done
  fi
else
  fail "Log Sink vi phạm:"
  echo "$SINK_ISSUES" | while read line; do info "$line"; done
fi
echo ""

# ----------------------------------------------------------------
# CIS 2.3 — Retention Policy + Bucket Lock
# ----------------------------------------------------------------
echo "[ 2.3 ] Retention Policy + Bucket Lock..."
BUCKET_NAME=$(gcloud logging sinks list --project="$PROJECT_ID" \
  --format="value(destination)" 2>/dev/null | \
  grep "storage.googleapis.com" | head -1 | \
  sed 's|storage.googleapis.com/||')

if [ -z "$BUCKET_NAME" ]; then
  fail "Không xác định được Bucket từ Log Sink"
else
  RETENTION=$(gsutil retention get "gs://$BUCKET_NAME" 2>/dev/null)
  LOCKED=$(echo "$RETENTION" | grep -i "LOCKED" || true)
  PERIOD=$(echo "$RETENTION" | grep -i "Duration" || true)

  if [ -n "$LOCKED" ] && [ -n "$PERIOD" ]; then
    pass "Bucket '$BUCKET_NAME' có Retention Policy và đã Locked"
    info "$PERIOD"
  elif [ -z "$PERIOD" ]; then
    fail "Bucket '$BUCKET_NAME' chưa có Retention Policy"
    info "Sửa: thêm retention_policy { is_locked=true } trong storage.tf"
  else
    fail "Bucket '$BUCKET_NAME' có Retention Policy nhưng chưa Lock"
    info "Sửa: đặt is_locked = true trong storage.tf"
  fi
fi
echo ""

# ----------------------------------------------------------------
# CIS 2.4 — Alert Policy cho Project Ownership Changes
# ----------------------------------------------------------------
echo "[ 2.4 ] Alert: Project Ownership Changes..."
METRIC_NAME=$(gcloud logging metrics list --project="$PROJECT_ID" \
  --format="value(name)" 2>/dev/null | grep "ownership" | head -1)

if [ -z "$METRIC_NAME" ]; then
  fail "Không tìm thấy Log Metric cho Ownership Changes"
  info "Sửa: thêm google_logging_metric 'project_ownership_changes_metric'"
else
  pass "Log Metric tồn tại: $METRIC_NAME"
  TOKEN=$(gcloud auth print-access-token 2>/dev/null)
  ALERT_CHECK=$(curl -s -H "Authorization: Bearer $TOKEN" \
    "https://monitoring.googleapis.com/v3/projects/$PROJECT_ID/alertPolicies" \
    2>/dev/null | python3 -c "
import json, sys
data = json.load(sys.stdin)
for p in data.get('alertPolicies', []):
    name = p.get('displayName','').lower()
    if 'ownership' in name:
        channels = p.get('notificationChannels', [])
        enabled = p.get('enabled', False)
        print(f'FOUND:{p[\"displayName\"]}:channels={len(channels)}:enabled={enabled}')
        break
" 2>/dev/null)

  if echo "$ALERT_CHECK" | grep -q "^FOUND:"; then
    CHANNELS=$(echo "$ALERT_CHECK" | grep -oP "channels=\K[0-9]+")
    ENABLED=$(echo "$ALERT_CHECK" | grep -oP "enabled=\K\w+")
    if [ "$CHANNELS" -gt 0 ] && [ "$ENABLED" = "True" ]; then
      pass "Alert Policy có Notification Channel và đang enabled"
    else
      fail "Alert Policy tồn tại nhưng: channels=$CHANNELS, enabled=$ENABLED"
      info "Sửa: thêm notification_channels và đặt enabled=true"
    fi
  else
    fail "Chưa có Alert Policy cho Ownership Changes"
    info "Sửa: thêm google_monitoring_alert_policy trong logging.tf"
  fi
fi
echo ""

# ----------------------------------------------------------------
# CIS 2.12 — Cloud DNS Logging bật cho tất cả VPC
# ----------------------------------------------------------------
echo "[ 2.12 ] Cloud DNS Logging..."
TOKEN=$(gcloud auth print-access-token 2>/dev/null)
DNS_POLICIES=$(curl -s -H "Authorization: Bearer $TOKEN" \
  "https://dns.googleapis.com/dns/v1/projects/$PROJECT_ID/policies" \
  2>/dev/null | python3 -c "
import json, sys
data = json.load(sys.stdin)
policies = data.get('policies', [])
logging_enabled = [p for p in policies if p.get('enableLogging', False)]
print(f'TOTAL:{len(policies)}:LOGGING:{len(logging_enabled)}')
for p in logging_enabled:
    print(f'  OK: {p[\"name\"]}')
" 2>/dev/null)

TOTAL=$(echo "$DNS_POLICIES" | head -1 | grep -oP "TOTAL:\K[0-9]+")
LOGGING=$(echo "$DNS_POLICIES" | head -1 | grep -oP "LOGGING:\K[0-9]+")

if [ "${TOTAL:-0}" -gt 0 ] && [ "${LOGGING:-0}" -gt 0 ] && [ "$TOTAL" -eq "$LOGGING" ]; then
  pass "Cloud DNS Logging bật cho tất cả $TOTAL DNS policy"
elif [ "${TOTAL:-0}" -eq 0 ]; then
  fail "Không có DNS Policy nào — cần tạo policy với enable_logging=true"
  info "Sửa: thêm google_dns_policy trong vpc.tf"
else
  fail "Chỉ $LOGGING/$TOTAL DNS Policy có logging bật"
  info "Sửa: bật enable_logging=true trên tất cả DNS policies"
fi
echo ""

# ----------------------------------------------------------------
# CIS 2.13 — Cloud Asset Inventory API
# ----------------------------------------------------------------
echo "[ 2.13 ] Cloud Asset Inventory API..."
ASSET_STATUS=$(gcloud services list --project="$PROJECT_ID" \
  --filter="name:cloudasset.googleapis.com" \
  --format="value(state)" 2>/dev/null)

if [ "$ASSET_STATUS" = "ENABLED" ]; then
  pass "cloudasset.googleapis.com đã bật"
else
  fail "cloudasset.googleapis.com chưa bật"
  info "Sửa: thêm google_project_service 'cloudasset.googleapis.com'"
fi
echo ""

# ----------------------------------------------------------------
# Tổng kết
# ----------------------------------------------------------------
TOTAL=$((PASS+FAIL))
echo "================================================================"
if [ "$FAIL" -eq 0 ]; then
  echo -e "  ${GREEN}KẾT QUẢ: $PASS/$TOTAL PASS — Đạt chuẩn CIS Logging${RESET}"
else
  echo -e "  KẾT QUẢ: ${GREEN}$PASS PASS${RESET} | ${RED}$FAIL FAIL${RESET} (tổng $TOTAL tiêu chí)"
fi
echo "================================================================"
exit $FAIL