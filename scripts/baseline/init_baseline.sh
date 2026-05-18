#!/bin/bash
# ================================================================
# Phase 1 — Khởi tạo / cập nhật golden baseline
# Chạy sau WF1 (deploy) hoặc WF3 (upgrade) khi 100% PASS
# Upload lên GCS để WF2 so sánh
# ================================================================
set -uo pipefail

PROJECT_ID=$(gcloud config get-value project 2>/dev/null)
REPORT_FILE="${1:-/tmp/cis_report.json}"   # kết quả từ cis_full_check.sh
TRIGGER="${2:-MANUAL}"                      # WF1 | WF3 | MANUAL
CONTEXT_FILE="${3:-/tmp/context_info.json}"

# Lấy bucket từ terraform state hoặc env
TF_STATE_BUCKET="${TF_STATE_BUCKET:-tf-state-${PROJECT_ID}}"
BASELINE_PREFIX="gs://${TF_STATE_BUCKET}/baseline"
HISTORY_PREFIX="gs://${TF_STATE_BUCKET}/compliance_history"

TIMESTAMP=$(date -u +%Y%m%d_%H%M%S)
GREEN="\033[0;32m"; RED="\033[0;31m"; YELLOW="\033[0;33m"; RESET="\033[0m"

echo "================================================================"
echo "  Phase 1 — Baseline Management"
echo "  Trigger: $TRIGGER | Report: $REPORT_FILE"
echo "================================================================"

# ── Kiểm tra report hợp lệ ───────────────────────────────────────
if [ ! -f "$REPORT_FILE" ]; then
  echo -e "${RED}[ERROR]${RESET} Không tìm thấy report: $REPORT_FILE"
  exit 1
fi

COMPLIANCE_RATE=$(jq '.compliance_rate' "$REPORT_FILE" 2>/dev/null || echo "0")
TOTAL_FAIL=$(jq '.total_fail' "$REPORT_FILE" 2>/dev/null || echo "99")
TOTAL_PASS=$(jq '.total_pass' "$REPORT_FILE" 2>/dev/null || echo "0")

echo "  Compliance rate: ${COMPLIANCE_RATE}% | PASS: $TOTAL_PASS | FAIL: $TOTAL_FAIL"

# ── Chỉ lưu baseline khi 100% PASS ───────────────────────────────
if [ "$TOTAL_FAIL" -gt 0 ]; then
  echo -e "${YELLOW}[SKIP]${RESET} Không lưu baseline — còn $TOTAL_FAIL FAIL. Cần fix trước."
  exit 0
fi

echo -e "${GREEN}[OK]${RESET} 100% PASS — đang lưu golden baseline..."

# ── Tạo cis_baseline_latest.json với 29 controls ─────────────────
cat > /tmp/cis_baseline_latest.json << 'EOF'
{
  "cis_version": "4.0.0",
  "total_controls": 29,
  "domains": 6,
  "controls": [
    {"id":"1.4",   "domain":"IAM","expected":"PASS","severity":"MEDIUM","group":"A","max_fix_minutes":10},
    {"id":"1.5",   "domain":"IAM","expected":"PASS","severity":"HIGH",  "group":"A","max_fix_minutes":10},
    {"id":"1.6",   "domain":"IAM","expected":"PASS","severity":"HIGH",  "group":"C","max_fix_minutes":null},
    {"id":"1.10",  "domain":"IAM","expected":"PASS","severity":"MEDIUM","group":"A","max_fix_minutes":10},
    {"id":"1.14",  "domain":"IAM","expected":"PASS","severity":"MEDIUM","group":"A","max_fix_minutes":10},
    {"id":"2.1",   "domain":"Logging","expected":"PASS","severity":"HIGH",  "group":"A","max_fix_minutes":10},
    {"id":"2.2",   "domain":"Logging","expected":"PASS","severity":"MEDIUM","group":"A","max_fix_minutes":10},
    {"id":"2.3",   "domain":"Logging","expected":"PASS","severity":"LOW",   "group":"C","max_fix_minutes":null},
    {"id":"2.4",   "domain":"Logging","expected":"PASS","severity":"MEDIUM","group":"C","max_fix_minutes":null},
    {"id":"2.12",  "domain":"Logging","expected":"PASS","severity":"LOW",   "group":"A","max_fix_minutes":10},
    {"id":"2.13",  "domain":"Logging","expected":"PASS","severity":"LOW",   "group":"A","max_fix_minutes":10},
    {"id":"3.1",   "domain":"Networking","expected":"PASS","severity":"HIGH",  "group":"A","max_fix_minutes":10},
    {"id":"3.3",   "domain":"Networking","expected":"PASS","severity":"LOW",   "group":"C","max_fix_minutes":null},
    {"id":"3.6",   "domain":"Networking","expected":"PASS","severity":"HIGH",  "group":"C","max_fix_minutes":null},
    {"id":"3.7",   "domain":"Networking","expected":"PASS","severity":"HIGH",  "group":"A","max_fix_minutes":10},
    {"id":"3.8",   "domain":"Networking","expected":"PASS","severity":"MEDIUM","group":"A","max_fix_minutes":10},
    {"id":"4.1",   "domain":"VM","expected":"PASS","severity":"HIGH",  "group":"B","max_fix_minutes":20},
    {"id":"4.2",   "domain":"VM","expected":"PASS","severity":"HIGH",  "group":"B","max_fix_minutes":20},
    {"id":"4.3",   "domain":"VM","expected":"PASS","severity":"MEDIUM","group":"A","max_fix_minutes":10},
    {"id":"4.4",   "domain":"VM","expected":"PASS","severity":"MEDIUM","group":"A","max_fix_minutes":10},
    {"id":"4.5",   "domain":"VM","expected":"PASS","severity":"LOW",   "group":"A","max_fix_minutes":10},
    {"id":"5.1",   "domain":"Storage","expected":"PASS","severity":"HIGH",  "group":"A","max_fix_minutes":10},
    {"id":"5.2",   "domain":"Storage","expected":"PASS","severity":"MEDIUM","group":"A","max_fix_minutes":10},
    {"id":"6.4",   "domain":"CloudSQL","expected":"PASS","severity":"HIGH",  "group":"A","max_fix_minutes":10},
    {"id":"6.2.1", "domain":"CloudSQL","expected":"PASS","severity":"MEDIUM","group":"A","max_fix_minutes":10},
    {"id":"6.2.2", "domain":"CloudSQL","expected":"PASS","severity":"MEDIUM","group":"A","max_fix_minutes":10},
    {"id":"6.2.3", "domain":"CloudSQL","expected":"PASS","severity":"MEDIUM","group":"A","max_fix_minutes":10},
    {"id":"6.2.4", "domain":"CloudSQL","expected":"PASS","severity":"MEDIUM","group":"A","max_fix_minutes":10},
    {"id":"6.2.8", "domain":"CloudSQL","expected":"PASS","severity":"MEDIUM","group":"A","max_fix_minutes":10}
  ]
}
EOF

# Merge với timestamp và project info
CONTEXT_RESOURCES="{}"
[ -f "$CONTEXT_FILE" ] && CONTEXT_RESOURCES=$(jq '.resources' "$CONTEXT_FILE" 2>/dev/null || echo "{}")

python3 - << PYEOF
import json, sys
with open('/tmp/cis_baseline_latest.json') as f:
    baseline = json.load(f)
baseline['baseline_id'] = '${TIMESTAMP}'
baseline['project_id']  = '${PROJECT_ID}'
baseline['trigger']     = '${TRIGGER}'
baseline['resources']   = ${CONTEXT_RESOURCES}
with open('/tmp/cis_baseline_latest.json','w') as f:
    json.dump(baseline, f, indent=2)
print("baseline JSON OK")
PYEOF

# ── Upload lên GCS ────────────────────────────────────────────────
echo "  Uploading to GCS..."
gsutil cp /tmp/cis_baseline_latest.json \
  "${BASELINE_PREFIX}/cis_baseline_latest.json" 2>/dev/null && \
  echo -e "${GREEN}[OK]${RESET} cis_baseline_latest.json uploaded"

gsutil cp /tmp/cis_baseline_latest.json \
  "${BASELINE_PREFIX}/cis_baseline_${TIMESTAMP}.json" 2>/dev/null && \
  echo -e "${GREEN}[OK]${RESET} cis_baseline_${TIMESTAMP}.json (historical)"

# Upload IAM snapshot nếu có
if [ -f /tmp/iam_snapshot.json ]; then
  gsutil cp /tmp/iam_snapshot.json \
    "${BASELINE_PREFIX}/iam_baseline_latest.json" 2>/dev/null && \
    echo -e "${GREEN}[OK]${RESET} iam_baseline_latest.json uploaded"
fi

# ── Lưu compliance_history ────────────────────────────────────────
HIST_FILE="/tmp/history_${TIMESTAMP}.json"
python3 - << PYEOF
import json
with open('${REPORT_FILE}') as f:
    report = json.load(f)
history = {
    'timestamp': report.get('timestamp',''),
    'trigger': '${TRIGGER}',
    'compliance_rate': report.get('compliance_rate', 100),
    'total': report.get('total_controls', 29),
    'pass': report.get('total_pass', 29),
    'fail': 0,
    'regression': [],
    'drift_detected': False,
    'iam_anomaly': False,
    'baseline_updated': True
}
with open('${HIST_FILE}','w') as f:
    json.dump(history, f, indent=2)
print("history JSON OK")
PYEOF

gsutil cp "$HIST_FILE" \
  "${HISTORY_PREFIX}/${TIMESTAMP}.json" 2>/dev/null && \
  echo -e "${GREEN}[OK]${RESET} compliance_history/${TIMESTAMP}.json uploaded"

echo ""
echo "================================================================"
echo -e "  ${GREEN}✓ Golden baseline lưu thành công — ID: $TIMESTAMP${RESET}"
echo "================================================================"