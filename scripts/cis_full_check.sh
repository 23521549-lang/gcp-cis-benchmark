#!/bin/bash
# ================================================================
# CIS GCP Benchmark v4.0.0 — FULL CHECK (tất cả 23 tiêu chuẩn)
# Gọi tất cả script check theo từng domain và tổng hợp kết quả
# Output có thể parse bởi GitHub Actions (JSON mode)
# ================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ID=$(gcloud config get-value project 2>/dev/null)
OUTPUT_FORMAT="${1:-text}"  # text | json
REPORT_FILE="${2:-/tmp/cis_report_$(date +%Y%m%d_%H%M%S).json}"

GREEN="\033[0;32m"; RED="\033[0;31m"; YELLOW="\033[0;33m"
CYAN="\033[0;36m"; RESET="\033[0m"

TOTAL_PASS=0
TOTAL_FAIL=0
DOMAIN_RESULTS=()

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
  EXIT_CODE=$?

  echo "$OUTPUT"

  D_PASS=$(echo "$OUTPUT" | grep -c "\[PASS\]" || true)
  D_FAIL=$(echo "$OUTPUT" | grep -c "\[FAIL\]" || true)

  TOTAL_PASS=$((TOTAL_PASS + D_PASS))
  TOTAL_FAIL=$((TOTAL_FAIL + D_FAIL))

  STATUS="PASS"
  [ "$D_FAIL" -gt 0 ] && STATUS="FAIL"
  DOMAIN_RESULTS+=("{\"domain\":$domain_num,\"name\":\"$domain_name\",\"status\":\"$STATUS\",\"pass\":$D_PASS,\"fail\":$D_FAIL}")
}

echo -e "${CYAN}"
echo "  ╔══════════════════════════════════════════════════════╗"
echo "  ║     CIS GCP Foundation Benchmark v4.0.0              ║"
echo "  ║     Full Compliance Check — 23 Controls              ║"
echo -e "  ║     Project: $PROJECT_ID"
echo "  ╚══════════════════════════════════════════════════════╝"
echo -e "${RESET}"
echo "  Started: $(date '+%Y-%m-%d %H:%M:%S')"

run_domain_check 1 "Identity & Access Management" "check_iam.sh"
run_domain_check 2 "Logging & Monitoring" "check_logging.sh"
run_domain_check 3 "Networking" "check_networking.sh"
run_domain_check 4 "Virtual Machines" "check_vm.sh"
run_domain_check 5 "Storage" "check_storage.sh"

# ----------------------------------------------------------------
# Tổng kết cuối
# ----------------------------------------------------------------
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
fi
echo "  Completed: $(date '+%Y-%m-%d %H:%M:%S')"
echo "════════════════════════════════════════════════════════════"

# ----------------------------------------------------------------
# JSON output cho GitHub Actions
# ----------------------------------------------------------------
if [ "$OUTPUT_FORMAT" = "json" ]; then
  DOMAINS_JSON=$(IFS=','; echo "${DOMAIN_RESULTS[*]}")
  STATUS="PASS"
  [ "$TOTAL_FAIL" -gt 0 ] && STATUS="FAIL"
  cat > "$REPORT_FILE" << EOF
{
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "project_id": "$PROJECT_ID",
  "status": "$STATUS",
  "compliance_rate": $COMPLIANCE_PCT,
  "total_pass": $TOTAL_PASS,
  "total_fail": $TOTAL_FAIL,
  "total_controls": $TOTAL,
  "domains": [$DOMAINS_JSON]
}
EOF
  echo ""
  echo "JSON report: $REPORT_FILE"
fi

exit $TOTAL_FAIL