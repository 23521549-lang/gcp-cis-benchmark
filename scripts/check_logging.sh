#!/bin/bash
# ================================================================
# CIS GCP Benchmark v4.0.0 — Domain 2: Logging & Monitoring
# CIS 2.1 / 2.2 / 2.3 / 2.4 / 2.12 / 2.13
# FIX: bỏ set -e để script không bị cắt giữa chừng
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
echo "  CIS LOGGING CHECK — PROJECT: $PROJECT_ID"
echo "================================================================"
echo ""

# ── CIS 2.1 — Cloud Audit Logging ────────────────────────────────
echo "[ 2.1 ] Cloud Audit Logging..."
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
            if r not in types: issues.append(f'MISSING:{r}')
        if c.get('exemptedMembers'): issues.append('HAS_EXEMPTED_MEMBERS')
if not found: issues.append('NO_ALL_SERVICES_CONFIG')
print('\n'.join(issues))
" 2>/dev/null || echo "CHECK_ERROR")

if [ "$AUDIT_RESULT" = "CHECK_ERROR" ]; then
  fail "2.1 Không kiểm tra được audit logging"
elif [ -z "$AUDIT_RESULT" ]; then
  pass "2.1 allServices có đủ ADMIN_READ, DATA_READ, DATA_WRITE, không có exemptedMembers"
else
  fail "2.1 Audit logging vi phạm:"
  echo "$AUDIT_RESULT" | while IFS= read -r line; do info "$line"; done
fi
echo ""

# ── CIS 2.2 — Log Sink không có filter ───────────────────────────
echo "[ 2.2 ] Log Sink — không có filter..."
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
  fail "2.2 Không kiểm tra được log sink"
elif echo "$SINK_RESULT" | grep -q "^NO_STORAGE_SINK"; then
  fail "2.2 NO_STORAGE_SINK: không tìm thấy Log Sink nào đến Storage Bucket"
  info "Fix: gcloud logging sinks create benchmark-log-sink storage.googleapis.com/BUCKET --project=$PROJECT_ID"
elif echo "$SINK_RESULT" | grep -q "^HAS_FILTER:"; then
  fail "2.2 Log Sink có filter — cần xóa để export toàn bộ log"
  echo "$SINK_RESULT" | grep "^HAS_FILTER:" | while IFS= read -r line; do info "$line"; done
else
  pass "2.2 Log Sink hợp lệ — không có filter"
fi
echo ""

# ── CIS 2.3 — Retention Policy + Bucket Lock ─────────────────────
echo "[ 2.3 ] Retention Policy + Bucket Lock..."
BUCKET_NAME=$(gcloud logging sinks list --project="$PROJECT_ID" \
  --format="value(destination)" 2>/dev/null | \
  grep "storage.googleapis.com" | head -1 | \
  sed 's|storage.googleapis.com/||' || echo "")

if [ -z "$BUCKET_NAME" ]; then
  fail "2.3 Không xác định được Bucket từ Log Sink"
else
  RETENTION=$(gsutil retention get "gs://$BUCKET_NAME" 2>/dev/null || echo "")
  LOCKED=$(echo "$RETENTION" | grep -i "LOCKED" || true)
  PERIOD=$(echo "$RETENTION" | grep -i "Duration" || true)
  if [ -n "$LOCKED" ] && [ -n "$PERIOD" ]; then
    pass "2.3 Bucket '$BUCKET_NAME' có Retention Policy và đã Locked"
    info "$PERIOD"
  elif [ -z "$PERIOD" ]; then
    fail "2.3 Bucket '$BUCKET_NAME' chưa có Retention Policy"
    info "Fix: gsutil retention set 30d gs://$BUCKET_NAME && gsutil retention lock gs://$BUCKET_NAME"
  else
    fail "2.3 Bucket '$BUCKET_NAME' có Retention Policy nhưng chưa Lock"
    info "Fix: gsutil retention lock gs://$BUCKET_NAME"
  fi
fi
echo ""

# ── CIS 2.4 — Alert Policy ────────────────────────────────────────
echo "[ 2.4 ] Alert: Project Ownership Changes..."
METRIC_NAME=$(gcloud logging metrics list --project="$PROJECT_ID" \
  --format="value(name)" 2>/dev/null | grep -i "ownership" | head -1 || echo "")

if [ -z "$METRIC_NAME" ]; then
  fail "2.4 Không tìm thấy Log Metric cho Ownership Changes"
  info "Fix: thêm google_logging_metric trong logging.tf"
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
  $ALERT_OK && pass "2.4 Alert Policy có Notification Channel và đang enabled" \
    || fail "2.4 Alert Policy thiếu notification channel hoặc đang disabled"
fi
echo ""

# ── CIS 2.12 — Cloud DNS Logging ─────────────────────────────────
echo "[ 2.12 ] Cloud DNS Logging..."
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
  pass "2.12 Cloud DNS Logging bật cho tất cả $TOTAL_P DNS policy"
elif [ "${TOTAL_P:-0}" -eq 0 ]; then
  fail "2.12 Không có DNS Policy nào — cần tạo policy với enable_logging=true"
else
  fail "2.12 Chỉ ${LOGGING_P:-0}/${TOTAL_P:-0} DNS Policy có logging bật"
fi
echo ""

# ── CIS 2.13 — Cloud Asset API ────────────────────────────────────
echo "[ 2.13 ] Cloud Asset Inventory API..."
ASSET_STATUS=$(gcloud services list --project="$PROJECT_ID" \
  --filter="name:cloudasset.googleapis.com" \
  --format="value(state)" 2>/dev/null || echo "")
[ "$ASSET_STATUS" = "ENABLED" ] \
  && pass "2.13 cloudasset.googleapis.com đã bật" \
  || fail "2.13 cloudasset.googleapis.com chưa bật"
echo ""

# ── Summary ───────────────────────────────────────────────────────
TOTAL=$((PASS+FAIL))
echo "================================================================"
if [ "$FAIL" -eq 0 ]; then
  echo -e "  ${GREEN}KẾT QUẢ: $PASS/$TOTAL PASS — Đạt chuẩn CIS Logging${RESET}"
else
  echo -e "  KẾT QUẢ: ${GREEN}$PASS PASS${RESET} | ${RED}$FAIL FAIL${RESET} (tổng $TOTAL tiêu chí)"
fi
echo "================================================================"
exit $FAIL