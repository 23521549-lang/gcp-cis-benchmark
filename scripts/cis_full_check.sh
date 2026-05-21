#!/bin/bash
# ================================================================
# cis_full_check.sh
# CIS GCP Foundation Benchmark v4.0.0 — Full Compliance Check
# Usage: ./cis_full_check.sh [text|json] [report_file] [baseline_file]
# ================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ID=$(gcloud config get-value project 2>/dev/null)
OUTPUT_FORMAT="${1:-text}"
REPORT_FILE="${2:-/tmp/cis_report_$(date +%Y%m%d_%H%M%S).json}"
BASELINE_FILE="${3:-/tmp/cis_baseline_latest.json}"

TOTAL_PASS=0; TOTAL_FAIL=0
DOMAIN_RESULTS=()
FAIL_CONTROLS=()
REGRESSION_CONTROLS=()

run_domain_check() {
  local domain_num="$1"
  local domain_name="$2"
  local script="$3"

  echo ""
  echo "════════════════════════════════════════════════════════════"
  echo " CHECK    [D${domain_num}] ${domain_name}"
  echo "════════════════════════════════════════════════════════════"

  if [ ! -f "$SCRIPT_DIR/$script" ]; then
    echo "ERROR    Script not found: $SCRIPT_DIR/$script"
    DOMAIN_RESULTS+=("{\"domain\":$domain_num,\"name\":\"$domain_name\",\"status\":\"ERROR\",\"pass\":0,\"fail\":0}")
    return 1
  fi

  chmod +x "$SCRIPT_DIR/$script"
  local OUTPUT
  OUTPUT=$("$SCRIPT_DIR/$script" 2>&1) || true
  echo "$OUTPUT"

  local D_PASS D_FAIL
  D_PASS=$(echo "$OUTPUT" | grep -cE "^PASS[[:space:]]+CIS-" || true)
  D_FAIL=$(echo "$OUTPUT" | grep -cE "^FAIL[[:space:]]+CIS-" || true)
  TOTAL_PASS=$((TOTAL_PASS + D_PASS))
  TOTAL_FAIL=$((TOTAL_FAIL + D_FAIL))

  while IFS= read -r line; do
    if echo "$line" | grep -qE "^FAIL[[:space:]]+CIS-"; then
      CID=$(echo "$line" | grep -oP '\d+\.\d+(\.\d+)?' | head -1 || true)
      [ -n "$CID" ] && FAIL_CONTROLS+=("$CID")
    fi
  done <<< "$OUTPUT"

  local STATUS="PASS"
  [ "$D_FAIL" -gt 0 ] && STATUS="FAIL"
  DOMAIN_RESULTS+=("{\"domain\":$domain_num,\"name\":\"$domain_name\",\"status\":\"$STATUS\",\"pass\":$D_PASS,\"fail\":$D_FAIL}")
}

# ── Header ────────────────────────────────────────────────────────
echo "════════════════════════════════════════════════════════════"
echo " CIS GCP Foundation Benchmark v4.0.0"
echo " Full Compliance Check — 29 Controls, 6 Domains"
echo " Project : $PROJECT_ID"
echo " Started : $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo "════════════════════════════════════════════════════════════"

# ── Run 6 domains ────────────────────────────────────────────────
run_domain_check 1 "Identity & Access Management" "check_iam.sh"
run_domain_check 2 "Logging & Monitoring"         "check_logging.sh"
run_domain_check 3 "Networking"                   "check_networking.sh"
run_domain_check 4 "Virtual Machines"             "check_vm.sh"
run_domain_check 5 "Storage"                      "check_storage.sh"
run_domain_check 6 "Cloud SQL PostgreSQL"          "check_sql.sh"

# ── Compliance summary ───────────────────────────────────────────
TOTAL=$((TOTAL_PASS + TOTAL_FAIL))
COMPLIANCE_PCT=0
[ "$TOTAL" -gt 0 ] && COMPLIANCE_PCT=$(( (TOTAL_PASS * 100) / TOTAL ))

echo ""
echo "════════════════════════════════════════════════════════════"
echo " RESULT   CIS Compliance Summary"
echo "────────────────────────────────────────────────────────────"
printf " %-10s %-6s %-6s %-6s %s\n" "Domain" "Pass" "Fail" "Total" "Status"
echo " ──────────────────────────────────────────────────────────"
for entry in "${DOMAIN_RESULTS[@]}"; do
  D_NUM=$(echo "$entry" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['domain'])" 2>/dev/null)
  D_NAME=$(echo "$entry" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['name'])" 2>/dev/null)
  D_PASS=$(echo "$entry" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['pass'])" 2>/dev/null)
  D_FAIL=$(echo "$entry" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['fail'])" 2>/dev/null)
  D_STAT=$(echo "$entry" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['status'])" 2>/dev/null)
  D_TOT=$((D_PASS + D_FAIL))
  printf " D%-9s %-6s %-6s %-6s %s\n" "$D_NUM" "$D_PASS" "$D_FAIL" "$D_TOT" "$D_STAT"
done
echo " ──────────────────────────────────────────────────────────"
printf " %-10s %-6s %-6s %-6s %s%%\n" "TOTAL" "$TOTAL_PASS" "$TOTAL_FAIL" "$TOTAL" "$COMPLIANCE_PCT"
echo "────────────────────────────────────────────────────────────"

if [ "$TOTAL_FAIL" -eq 0 ]; then
  echo " RESULT   COMPLIANT — All $TOTAL controls passing (100%)"
else
  echo " RESULT   NON-COMPLIANT — $TOTAL_FAIL/$TOTAL controls failing ($COMPLIANCE_PCT%)"
  if [ ${#FAIL_CONTROLS[@]} -gt 0 ]; then
    echo "          Failed controls: ${FAIL_CONTROLS[*]}"
  fi
fi
echo " INFO     Completed: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo "════════════════════════════════════════════════════════════"

# ── Baseline comparison ───────────────────────────────────────────
if [ -f "$BASELINE_FILE" ]; then
  echo ""
  BASELINE_RATE=$(jq '.compliance_rate // 100' "$BASELINE_FILE" 2>/dev/null || echo "100")
  echo " BASELINE Comparison"
  echo "          Baseline : ${BASELINE_RATE}%"
  echo "          Current  : ${COMPLIANCE_PCT}%"
  if [ "$COMPLIANCE_PCT" -lt "$BASELINE_RATE" ]; then
    DIFF=$((BASELINE_RATE - COMPLIANCE_PCT))
    echo "##[warning] REGRESSION: compliance decreased by ${DIFF}% from baseline"
    REGRESSION_CONTROLS=("${FAIL_CONTROLS[@]}")
  else
    echo " INFO     No regression detected"
  fi
fi

# ── JSON output ───────────────────────────────────────────────────
if [ "$OUTPUT_FORMAT" = "json" ]; then
  DOMAINS_JSON=$(IFS=','; echo "${DOMAIN_RESULTS[*]}")

  FAIL_JSON="[]"
  if [ ${#FAIL_CONTROLS[@]} -gt 0 ]; then
    FAIL_JSON=$(printf '%s\n' "${FAIL_CONTROLS[@]}" | \
      python3 -c "import sys,json; print(json.dumps([l.strip() for l in sys.stdin if l.strip()]))" \
      2>/dev/null || echo "[]")
  fi

  REGRESSION_JSON="[]"
  if [ ${#REGRESSION_CONTROLS[@]} -gt 0 ]; then
    REGRESSION_JSON=$(printf '%s\n' "${REGRESSION_CONTROLS[@]}" | \
      python3 -c "import sys,json; print(json.dumps([l.strip() for l in sys.stdin if l.strip()]))" \
      2>/dev/null || echo "[]")
  fi

  STATUS="PASS"; [ "$TOTAL_FAIL" -gt 0 ] && STATUS="FAIL"

  cat > "$REPORT_FILE" << EOF
{
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "project_id": "$PROJECT_ID",
  "status": "$STATUS",
  "compliance_rate": $COMPLIANCE_PCT,
  "total_pass": $TOTAL_PASS,
  "total_fail": $TOTAL_FAIL,
  "total_controls": $TOTAL,
  "fail_controls": $FAIL_JSON,
  "regression_controls": $REGRESSION_JSON,
  "domains": [$DOMAINS_JSON]
}
EOF
  echo ""
  echo "OK       JSON report: $REPORT_FILE"
  echo "$FAIL_JSON" > /tmp/control_fail_list.json
fi

[ "$TOTAL_FAIL" -gt 0 ] && exit 1 || exit 0