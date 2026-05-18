#!/bin/bash
# ================================================================
# CIS GCP Benchmark v4.0.0 — FULL CHECK (29 controls, 6 domain)
# Gọi tất cả domain scripts, so sánh với baseline, xuất JSON
# Usage: ./cis_full_check.sh [text|json] [report_file] [baseline_file]
# ================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ID=$(gcloud config get-value project 2>/dev/null)
OUTPUT_FORMAT="${1:-text}"
REPORT_FILE="${2:-/tmp/cis_report_$(date +%Y%m%d_%H%M%S).json}"
BASELINE_FILE="${3:-/tmp/cis_baseline_latest.json}"

GREEN="\033[0;32m"; RED="\033[0;31m"; YELLOW="\033[0;33m"
CYAN="\033[0;36m";  RESET="\033[0m"

TOTAL_PASS=0; TOTAL_FAIL=0
DOMAIN_RESULTS=()
FAIL_CONTROLS=()  # list control IDs bị FAIL — dùng cho WF4

run_domain_check() {
  local domain_num="$1"
  local domain_name="$2"
  local script="$3"

  echo ""
  echo -e "${CYAN}════════════════════════════════════════════════════════════${RESET}"
  echo -e "${CYAN}  DOMAIN $domain_num — $domain_name${RESET}"
  echo -e "${CYAN}════════════════════════════════════════════════════════════${RESET}"

  if [ ! -f "$SCRIPT_DIR/$script" ]; then
    echo -e "${RED}[ERROR]${RESET} Script không tìm thấy: $SCRIPT_DIR/$script"
    DOMAIN_RESULTS+=("{\"domain\":$domain_num,\"name\":\"$domain_name\",\"status\":\"ERROR\",\"pass\":0,\"fail\":0}")
    return 1
  fi

  chmod +x "$SCRIPT_DIR/$script"
  OUTPUT=$("$SCRIPT_DIR/$script" 2>&1) || true
  echo "$OUTPUT"

  D_PASS=$(echo "$OUTPUT" | grep -c "\[PASS\]" || true)
  D_FAIL=$(echo "$OUTPUT" | grep -c "\[FAIL\]" || true)
  TOTAL_PASS=$((TOTAL_PASS + D_PASS))
  TOTAL_FAIL=$((TOTAL_FAIL + D_FAIL))

  # Trích xuất control IDs bị FAIL từ output
  while IFS= read -r line; do
    if echo "$line" | grep -q "\[FAIL\]"; then
      CID=$(echo "$line" | grep -oP '(?<=\[FAIL\] )\d+\.\d+(\.\d+)?' || true)
      [ -n "$CID" ] && FAIL_CONTROLS+=("$CID")
    fi
  done <<< "$OUTPUT"

  STATUS="PASS"; [ "$D_FAIL" -gt 0 ] && STATUS="FAIL"
  DOMAIN_RESULTS+=("{\"domain\":$domain_num,\"name\":\"$domain_name\",\"status\":\"$STATUS\",\"pass\":$D_PASS,\"fail\":$D_FAIL}")
}

echo -e "${CYAN}"
echo "  ╔══════════════════════════════════════════════════════╗"
echo "  ║     CIS GCP Foundation Benchmark v4.0.0              ║"
echo "  ║     Full Compliance Check — 29 Controls, 6 Domains   ║"
echo -e "  ║     Project: $PROJECT_ID"
echo "  ╚══════════════════════════════════════════════════════╝"
echo -e "${RESET}"
echo "  Started: $(date '+%Y-%m-%d %H:%M:%S')"

run_domain_check 1 "Identity & Access Management" "check_iam.sh"
run_domain_check 2 "Logging & Monitoring"         "check_logging.sh"
run_domain_check 3 "Networking"                   "check_networking.sh"
run_domain_check 4 "Virtual Machines"             "check_vm.sh"
run_domain_check 5 "Storage"                      "check_storage.sh"
run_domain_check 6 "Cloud SQL PostgreSQL"          "check_sql.sh"

# ── Tổng kết ─────────────────────────────────────────────────────
TOTAL=$((TOTAL_PASS + TOTAL_FAIL))
COMPLIANCE_PCT=0
[ "$TOTAL" -gt 0 ] && COMPLIANCE_PCT=$(( (TOTAL_PASS * 100) / TOTAL ))

echo ""
echo "════════════════════════════════════════════════════════════"
echo "  TỔNG KẾT CIS COMPLIANCE"
echo "════════════════════════════════════════════════════════════"
if [ "$TOTAL_FAIL" -eq 0 ]; then
  echo -e "  ${GREEN}✓ FULLY COMPLIANT: $TOTAL_PASS/$TOTAL PASS (100%)${RESET}"
else
  echo -e "  ${GREEN}PASS: $TOTAL_PASS${RESET} | ${RED}FAIL: $TOTAL_FAIL${RESET} | Tổng: $TOTAL"
  echo -e "  Compliance rate: ${COMPLIANCE_PCT}%"
  if [ ${#FAIL_CONTROLS[@]} -gt 0 ]; then
    echo -e "  ${RED}Controls FAIL: ${FAIL_CONTROLS[*]}${RESET}"
  fi
fi
echo "  Completed: $(date '+%Y-%m-%d %H:%M:%S')"
echo "════════════════════════════════════════════════════════════"

# ── So sánh với baseline ──────────────────────────────────────────
REGRESSION_CONTROLS=()
if [ -f "$BASELINE_FILE" ]; then
  echo ""
  echo "  [ Baseline comparison ]"
  BASELINE_RATE=$(jq '.compliance_rate // 100' "$BASELINE_FILE" 2>/dev/null || echo "100")
  echo "  Baseline rate: ${BASELINE_RATE}% | Current: ${COMPLIANCE_PCT}%"

  if [ "$COMPLIANCE_PCT" -lt "$BASELINE_RATE" ]; then
    DIFF=$((BASELINE_RATE - COMPLIANCE_PCT))
    echo -e "  ${RED}⚠ REGRESSION: giảm ${DIFF}% so với baseline${RESET}"
    REGRESSION_CONTROLS=("${FAIL_CONTROLS[@]}")
  else
    echo -e "  ${GREEN}✓ Không có regression so với baseline${RESET}"
  fi
fi

# ── JSON output ───────────────────────────────────────────────────
if [ "$OUTPUT_FORMAT" = "json" ]; then
  DOMAINS_JSON=$(IFS=','; echo "${DOMAIN_RESULTS[*]}")
  FAIL_LIST_JSON=$(printf '%s\n' "${FAIL_CONTROLS[@]}" | \
    python3 -c "import sys,json; print(json.dumps([l.strip() for l in sys.stdin if l.strip()]))" 2>/dev/null || echo "[]")
  REGRESSION_JSON=$(printf '%s\n' "${REGRESSION_CONTROLS[@]}" | \
    python3 -c "import sys,json; print(json.dumps([l.strip() for l in sys.stdin if l.strip()]))" 2>/dev/null || echo "[]")

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
  "fail_controls": $FAIL_LIST_JSON,
  "regression_controls": $REGRESSION_JSON,
  "domains": [$DOMAINS_JSON]
}
EOF
  echo ""
  echo "JSON report: $REPORT_FILE"

  # Xuất control_fail_list.json để WF4 dùng
  echo "$FAIL_LIST_JSON" > /tmp/control_fail_list.json
fi

exit $TOTAL_FAIL