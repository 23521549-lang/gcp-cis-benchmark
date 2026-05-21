#!/bin/bash
# ================================================================
# init_baseline.sh
# Phase 1 — Initialize / Update Golden Baseline
# Runs after WF1 (deploy) or WF3 (upgrade) when 100% compliant
# Uploads snapshot to GCS for WF2 comparison
# ================================================================
set -uo pipefail

PROJECT_ID=$(gcloud config get-value project 2>/dev/null)
REPORT_FILE="${1:-/tmp/cis_report.json}"
TRIGGER="${2:-MANUAL}"
CONTEXT_FILE="${3:-/tmp/context_info.json}"

TF_STATE_BUCKET="${TF_STATE_BUCKET:-tf-state-${PROJECT_ID}}"
BASELINE_PREFIX="gs://${TF_STATE_BUCKET}/baseline"
HISTORY_PREFIX="gs://${TF_STATE_BUCKET}/compliance_history"
TIMESTAMP=$(date -u +%Y%m%d_%H%M%S)

echo "════════════════════════════════════════════════════════════"
echo " BASELINE Phase 1: Baseline Management"
echo " Trigger : $TRIGGER"
echo " Report  : $REPORT_FILE"
echo " Time    : $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo "════════════════════════════════════════════════════════════"

# ── Validate report ───────────────────────────────────────────────
if [ ! -f "$REPORT_FILE" ]; then
  echo "ERROR    Report file not found: $REPORT_FILE"
  exit 1
fi

COMPLIANCE_RATE=$(jq '.compliance_rate' "$REPORT_FILE" 2>/dev/null || echo "0")
TOTAL_FAIL=$(jq '.total_fail' "$REPORT_FILE" 2>/dev/null || echo "99")
TOTAL_PASS=$(jq '.total_pass' "$REPORT_FILE" 2>/dev/null || echo "0")

echo "INFO     Compliance: ${COMPLIANCE_RATE}% | Pass: $TOTAL_PASS | Fail: $TOTAL_FAIL"

# ── Only save baseline when 100% compliant ────────────────────────
if [ "$TOTAL_FAIL" -gt 0 ]; then
  echo "SKIP     Baseline not saved — $TOTAL_FAIL control(s) still failing"
  echo "         Fix all failures before saving baseline"
  exit 0
fi

echo "OK       100% compliant — saving golden baseline..."

# ── Build CIS baseline JSON ───────────────────────────────────────
cat > /tmp/cis_baseline_latest.json << 'EOF'
{
  "cis_version": "4.0.0",
  "total_controls": 29,
  "domains": 6,
  "controls": [
    {"id":"1.4",   "domain":"IAM",       "expected":"PASS","severity":"MEDIUM","group":"A","max_fix_minutes":10},
    {"id":"1.5",   "domain":"IAM",       "expected":"PASS","severity":"HIGH",  "group":"A","max_fix_minutes":10},
    {"id":"1.6",   "domain":"IAM",       "expected":"PASS","severity":"HIGH",  "group":"C","max_fix_minutes":null},
    {"id":"1.10",  "domain":"IAM",       "expected":"PASS","severity":"MEDIUM","group":"A","max_fix_minutes":10},
    {"id":"1.14",  "domain":"IAM",       "expected":"PASS","severity":"MEDIUM","group":"A","max_fix_minutes":10},
    {"id":"2.1",   "domain":"Logging",   "expected":"PASS","severity":"HIGH",  "group":"A","max_fix_minutes":10},
    {"id":"2.2",   "domain":"Logging",   "expected":"PASS","severity":"MEDIUM","group":"A","max_fix_minutes":10},
    {"id":"2.3",   "domain":"Logging",   "expected":"PASS","severity":"LOW",   "group":"C","max_fix_minutes":null},
    {"id":"2.4",   "domain":"Logging",   "expected":"PASS","severity":"MEDIUM","group":"C","max_fix_minutes":null},
    {"id":"2.12",  "domain":"Logging",   "expected":"PASS","severity":"LOW",   "group":"A","max_fix_minutes":10},
    {"id":"2.13",  "domain":"Logging",   "expected":"PASS","severity":"LOW",   "group":"A","max_fix_minutes":10},
    {"id":"3.1",   "domain":"Networking","expected":"PASS","severity":"HIGH",  "group":"A","max_fix_minutes":10},
    {"id":"3.3",   "domain":"Networking","expected":"PASS","severity":"LOW",   "group":"C","max_fix_minutes":null},
    {"id":"3.6",   "domain":"Networking","expected":"PASS","severity":"HIGH",  "group":"C","max_fix_minutes":null},
    {"id":"3.7",   "domain":"Networking","expected":"PASS","severity":"HIGH",  "group":"A","max_fix_minutes":10},
    {"id":"3.8",   "domain":"Networking","expected":"PASS","severity":"MEDIUM","group":"A","max_fix_minutes":10},
    {"id":"4.1",   "domain":"VM",        "expected":"PASS","severity":"HIGH",  "group":"B","max_fix_minutes":20},
    {"id":"4.2",   "domain":"VM",        "expected":"PASS","severity":"HIGH",  "group":"B","max_fix_minutes":20},
    {"id":"4.3",   "domain":"VM",        "expected":"PASS","severity":"MEDIUM","group":"A","max_fix_minutes":10},
    {"id":"4.4",   "domain":"VM",        "expected":"PASS","severity":"MEDIUM","group":"A","max_fix_minutes":10},
    {"id":"4.5",   "domain":"VM",        "expected":"PASS","severity":"LOW",   "group":"A","max_fix_minutes":10},
    {"id":"5.1",   "domain":"Storage",   "expected":"PASS","severity":"HIGH",  "group":"A","max_fix_minutes":10},
    {"id":"5.2",   "domain":"Storage",   "expected":"PASS","severity":"MEDIUM","group":"A","max_fix_minutes":10},
    {"id":"6.4",   "domain":"CloudSQL",  "expected":"PASS","severity":"HIGH",  "group":"A","max_fix_minutes":10},
    {"id":"6.2.1", "domain":"CloudSQL",  "expected":"PASS","severity":"MEDIUM","group":"A","max_fix_minutes":10},
    {"id":"6.2.2", "domain":"CloudSQL",  "expected":"PASS","severity":"MEDIUM","group":"A","max_fix_minutes":10},
    {"id":"6.2.3", "domain":"CloudSQL",  "expected":"PASS","severity":"MEDIUM","group":"A","max_fix_minutes":10},
    {"id":"6.2.4", "domain":"CloudSQL",  "expected":"PASS","severity":"MEDIUM","group":"A","max_fix_minutes":10},
    {"id":"6.2.8", "domain":"CloudSQL",  "expected":"PASS","severity":"MEDIUM","group":"A","max_fix_minutes":10}
  ]
}
EOF

CONTEXT_RESOURCES="{}"
[ -f "$CONTEXT_FILE" ] && \
  CONTEXT_RESOURCES=$(jq '.resources' "$CONTEXT_FILE" 2>/dev/null || echo "{}")

python3 - << PYEOF
import json
with open('/tmp/cis_baseline_latest.json') as f:
    baseline = json.load(f)
baseline['baseline_id']  = '${TIMESTAMP}'
baseline['project_id']   = '${PROJECT_ID}'
baseline['trigger']      = '${TRIGGER}'
baseline['compliance']   = ${COMPLIANCE_RATE}
baseline['resources']    = ${CONTEXT_RESOURCES}
with open('/tmp/cis_baseline_latest.json','w') as f:
    json.dump(baseline, f, indent=2)
print("INFO     Baseline JSON assembled successfully")
PYEOF

# ── Upload to GCS ─────────────────────────────────────────────────
echo "INFO     Uploading baseline to GCS..."

gsutil cp /tmp/cis_baseline_latest.json \
  "${BASELINE_PREFIX}/cis_baseline_latest.json" 2>/dev/null \
  && echo "OK       cis_baseline_latest.json uploaded" \
  || echo "##[warning]Failed to upload cis_baseline_latest.json"

gsutil cp /tmp/cis_baseline_latest.json \
  "${BASELINE_PREFIX}/cis_baseline_${TIMESTAMP}.json" 2>/dev/null \
  && echo "OK       cis_baseline_${TIMESTAMP}.json uploaded (historical)" \
  || echo "##[warning]Failed to upload historical baseline"

if [ -f /tmp/iam_snapshot.json ]; then
  gsutil cp /tmp/iam_snapshot.json \
    "${BASELINE_PREFIX}/iam_baseline_latest.json" 2>/dev/null \
    && echo "OK       iam_baseline_latest.json uploaded" \
    || echo "##[warning]Failed to upload IAM baseline"
fi

# ── Save compliance history ───────────────────────────────────────
HIST_FILE="/tmp/history_${TIMESTAMP}.json"
python3 - << PYEOF
import json
with open('${REPORT_FILE}') as f:
    report = json.load(f)
history = {
    'timestamp':        report.get('timestamp',''),
    'trigger':          '${TRIGGER}',
    'compliance_rate':  report.get('compliance_rate', 100),
    'total':            report.get('total_controls', 29),
    'pass':             report.get('total_pass', 29),
    'fail':             0,
    'regression':       [],
    'drift_detected':   False,
    'iam_anomaly':      False,
    'baseline_updated': True
}
with open('${HIST_FILE}','w') as f:
    json.dump(history, f, indent=2)
print("INFO     History JSON written: ${HIST_FILE}")
PYEOF

gsutil cp "$HIST_FILE" \
  "${HISTORY_PREFIX}/${TIMESTAMP}.json" 2>/dev/null \
  && echo "OK       compliance_history/${TIMESTAMP}.json uploaded" \
  || echo "##[warning]Failed to upload compliance history"

echo ""
echo "════════════════════════════════════════════════════════════"
echo " DONE     Golden baseline saved — id=$TIMESTAMP"
echo "          rate=${COMPLIANCE_RATE}% trigger=$TRIGGER"
echo "════════════════════════════════════════════════════════════"