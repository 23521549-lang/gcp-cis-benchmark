#!/bin/bash
# ================================================================
# verify_fix.sh — Xác nhận WF4 đã fix vi phạm
# Chạy sau khi WF4 hoàn thành trên GitHub Actions
# ================================================================

set -uo pipefail

PROJECT_ID=$(gcloud config get-value project 2>/dev/null)
VM_NAME="benchmark-vm-01"
VM_ZONE="asia-southeast1-b"
SCENARIO="${1:-all}"

BOLD="\033[1m"
GREEN="\033[0;32m"
RED="\033[0;31m"
YELLOW="\033[0;33m"
CYAN="\033[0;36m"
RESET="\033[0m"

PASS=0
FAIL=0

header() {
  echo ""
  echo -e "${CYAN}${BOLD}════════════════════════════════════════════════════════════${RESET}"
  echo -e "${CYAN}${BOLD}  $1${RESET}"
  echo -e "${CYAN}${BOLD}════════════════════════════════════════════════════════════${RESET}"
}

pass() { echo -e "  ${GREEN}✔  PASS${RESET}  $1"; PASS=$((PASS+1)); }
fail() { echo -e "  ${RED}✘  FAIL${RESET}  $1"; FAIL=$((FAIL+1)); }
info() { echo -e "  ${YELLOW}→${RESET}       $1"; }

verify_scenario_1() {
  header "Verify Scenario 1 — CIS 4.5: Serial Port"
  info "Expected: serial-port-enable = false"

  VAL=$(gcloud compute instances describe "$VM_NAME" \
    --zone="$VM_ZONE" --project="$PROJECT_ID" \
    --format="value(metadata.items[serial-port-enable])" 2>/dev/null)
  info "Current:  serial-port-enable = $VAL"

  if [ "$VAL" = "false" ] || [ -z "$VAL" ]; then
    pass "CIS 4.5 — Serial port disabled"
  else
    fail "CIS 4.5 — Serial port still enabled ($VAL)"
  fi
}

verify_scenario_2() {
  header "Verify Scenario 2 — CIS 4.3 + 4.4: VM Metadata"

  info "Expected: block-project-ssh-keys = true"
  SSH=$(gcloud compute instances describe "$VM_NAME" \
    --zone="$VM_ZONE" --project="$PROJECT_ID" \
    --format="value(metadata.items[block-project-ssh-keys])" 2>/dev/null)
  info "Current:  block-project-ssh-keys = $SSH"
  [ "$SSH" = "true" ] && pass "CIS 4.3 — block-project-ssh-keys enabled" || \
    fail "CIS 4.3 — block-project-ssh-keys not restored ($SSH)"

  info "Expected: enable-oslogin = true"
  OSLOGIN=$(gcloud compute instances describe "$VM_NAME" \
    --zone="$VM_ZONE" --project="$PROJECT_ID" \
    --format="value(metadata.items[enable-oslogin])" 2>/dev/null)
  info "Current:  enable-oslogin = $OSLOGIN"
  [ "$OSLOGIN" = "true" ] && pass "CIS 4.4 — OS Login enabled" || \
    fail "CIS 4.4 — OS Login not restored ($OSLOGIN)"
}

verify_scenario_3() {
  header "Verify Scenario 3 — CIS 4.1 + 4.2: VM Service Account"

  CUSTOM_SA="app-least-privilege-sa@${PROJECT_ID}.iam.gserviceaccount.com"
  PROJECT_NUMBER=$(gcloud projects describe "$PROJECT_ID" \
    --format="value(projectNumber)" 2>/dev/null)
  DEFAULT_SA="${PROJECT_NUMBER}-compute@developer.gserviceaccount.com"

  info "Expected: $CUSTOM_SA"
  CURRENT_SA=$(gcloud compute instances describe "$VM_NAME" \
    --zone="$VM_ZONE" --project="$PROJECT_ID" \
    --format="value(serviceAccounts[0].email)" 2>/dev/null)
  info "Current:  $CURRENT_SA"

  if [ "$CURRENT_SA" = "$CUSTOM_SA" ]; then
    pass "CIS 4.1 — VM using Custom SA"
    pass "CIS 4.2 — Not using Default SA with Full Access"
  else
    fail "CIS 4.1 — VM still using wrong SA ($CURRENT_SA)"
    fail "CIS 4.2 — Default SA risk not resolved"
  fi

  VM_STATUS=$(gcloud compute instances describe "$VM_NAME" \
    --zone="$VM_ZONE" --project="$PROJECT_ID" \
    --format="value(status)" 2>/dev/null)
  info "VM status: $VM_STATUS"
  [ "$VM_STATUS" = "RUNNING" ] && \
    pass "VM is running after SA swap" || \
    fail "VM is not running ($VM_STATUS)"
}

print_summary() {
  TOTAL=$((PASS+FAIL))
  echo ""
  echo -e "${CYAN}${BOLD}════════════════════════════════════════════════════════════${RESET}"
  echo -e "${CYAN}${BOLD}  Verification Summary${RESET}"
  echo -e "${CYAN}${BOLD}════════════════════════════════════════════════════════════${RESET}"
  echo -e "  ${GREEN}✔  Passed${RESET}  $PASS / $TOTAL checks"
  if [ "$FAIL" -gt 0 ]; then
    echo -e "  ${RED}✘  Failed${RESET}  $FAIL / $TOTAL checks"
    echo ""
    echo -e "  ${YELLOW}WF4 may still be running — wait 2-3 minutes and retry.${RESET}"
    echo -e "  Or check GitHub Actions → WF4 for details."
  else
    echo ""
    echo -e "  ${GREEN}${BOLD}WF4 recovery verified successfully.${RESET}"
  fi
  echo ""
}

# ----------------------------------------------------------------
# Main
# ----------------------------------------------------------------
echo -e "${BOLD}"
echo "  ╔══════════════════════════════════════════════════════════╗"
echo "  ║     WF4 Recovery — Verify Fix Results                    ║"
echo "  ╚══════════════════════════════════════════════════════════╝"
echo -e "${RESET}"
echo -e "  Project: ${BOLD}$PROJECT_ID${RESET}"
echo -e "  VM:      ${BOLD}$VM_NAME ($VM_ZONE)${RESET}"
echo -e "  Time:    ${BOLD}$(date '+%Y-%m-%d %H:%M:%S')${RESET}"

case "$SCENARIO" in
  1)   verify_scenario_1 ;;
  2)   verify_scenario_2 ;;
  3)   verify_scenario_3 ;;
  all)
    verify_scenario_1
    verify_scenario_2
    verify_scenario_3
    ;;
  *)
    echo "Usage: bash tests/verify_fix.sh [1|2|3|all]"
    exit 1
    ;;
esac

print_summary
exit $FAIL