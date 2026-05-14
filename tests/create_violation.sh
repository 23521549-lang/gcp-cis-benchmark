#!/bin/bash
# ================================================================
# create_violation.sh — Tạo vi phạm CIS để test WF4
# Chỉ tạo vi phạm, KHÔNG tự fix
# Sau khi chạy: vào GitHub Actions → WF2 → Run workflow
# ================================================================

set -uo pipefail

PROJECT_ID=$(gcloud config get-value project 2>/dev/null)
VM_NAME="benchmark-vm-01"
VM_ZONE="asia-southeast1-b"
SCENARIO="${1:-help}"

BOLD="\033[1m"
GREEN="\033[0;32m"
RED="\033[0;31m"
YELLOW="\033[0;33m"
CYAN="\033[0;36m"
RESET="\033[0m"

header() {
  echo ""
  echo -e "${CYAN}${BOLD}════════════════════════════════════════════════════════════${RESET}"
  echo -e "${CYAN}${BOLD}  $1${RESET}"
  echo -e "${CYAN}${BOLD}════════════════════════════════════════════════════════════${RESET}"
}

ok()   { echo -e "  ${GREEN}✔${RESET}  $1"; }
info() { echo -e "  ${YELLOW}→${RESET}  $1"; }
err()  { echo -e "  ${RED}✘${RESET}  $1"; }

next_steps() {
  echo ""
  echo -e "${YELLOW}${BOLD}  Next steps:${RESET}"
  echo -e "  1. Go to GitHub Actions → WF2 — Scheduled CIS Monitor → Run workflow"
  echo -e "  2. WF2 detects violation → triggers WF4 automatically"
  echo -e "  3. Wait for WF4 to complete (~3-5 minutes)"
  echo -e "  4. Run: ${BOLD}bash tests/verify_fix.sh $SCENARIO${RESET}"
  echo ""
}

scenario_1() {
  header "Scenario 1 — CIS 4.5: Serial Port (Group A)"
  info "Violation: enabling serial port on VM"
  info "WF4 will: automatically disable it via gcloud (no VM restart needed)"
  echo ""

  gcloud compute instances add-metadata "$VM_NAME" \
    --zone="$VM_ZONE" \
    --metadata=serial-port-enable=true \
    --project="$PROJECT_ID" \
    --quiet 2>/dev/null

  CURRENT=$(gcloud compute instances describe "$VM_NAME" \
    --zone="$VM_ZONE" \
    --project="$PROJECT_ID" \
    --format="value(metadata.items[serial-port-enable])" 2>/dev/null)

  if [ "$CURRENT" = "true" ]; then
    ok "Violation created: serial-port-enable=true"
  else
    err "Failed to create violation"
    exit 1
  fi
  next_steps
}

scenario_2() {
  header "Scenario 2 — CIS 4.3 + 4.4: VM Metadata (Group A)"
  info "Violation: disabling block-project-ssh-keys and enable-oslogin"
  info "WF4 will: automatically restore both values via gcloud"
  echo ""

  gcloud compute instances add-metadata "$VM_NAME" \
    --zone="$VM_ZONE" \
    --metadata=block-project-ssh-keys=false,enable-oslogin=false \
    --project="$PROJECT_ID" \
    --quiet 2>/dev/null

  SSH=$(gcloud compute instances describe "$VM_NAME" \
    --zone="$VM_ZONE" --project="$PROJECT_ID" \
    --format="value(metadata.items[block-project-ssh-keys])" 2>/dev/null)
  OSLOGIN=$(gcloud compute instances describe "$VM_NAME" \
    --zone="$VM_ZONE" --project="$PROJECT_ID" \
    --format="value(metadata.items[enable-oslogin])" 2>/dev/null)

  ok "Violation created: block-project-ssh-keys=$SSH, enable-oslogin=$OSLOGIN"
  next_steps
}

scenario_3() {
  header "Scenario 3 — CIS 4.1 + 4.2: VM Service Account (Group B)"
  info "Violation: switching VM to Default Compute SA"
  info "WF4 will: Ansible stops VM → swaps SA → restarts VM"
  echo ""

  PROJECT_NUMBER=$(gcloud projects describe "$PROJECT_ID" \
    --format="value(projectNumber)" 2>/dev/null)
  DEFAULT_SA="${PROJECT_NUMBER}-compute@developer.gserviceaccount.com"

  echo -e "  ${RED}WARNING: This will stop the VM briefly during WF4 recovery.${RESET}"
  echo "  Press Enter to continue or Ctrl+C to cancel..."
  read -r

  gcloud compute instances stop "$VM_NAME" \
    --zone="$VM_ZONE" \
    --project="$PROJECT_ID" \
    --quiet 2>/dev/null

  echo -n "  Waiting for VM to stop"
  until [ "$(gcloud compute instances describe "$VM_NAME" \
    --zone="$VM_ZONE" --project="$PROJECT_ID" \
    --format="value(status)" 2>/dev/null)" = "TERMINATED" ]; do
    echo -n "."
    sleep 5
  done
  echo ""

  gcloud compute instances set-service-account "$VM_NAME" \
    --zone="$VM_ZONE" \
    --project="$PROJECT_ID" \
    --service-account="$DEFAULT_SA" \
    --scopes=cloud-platform \
    --quiet 2>/dev/null

  gcloud compute instances start "$VM_NAME" \
    --zone="$VM_ZONE" \
    --project="$PROJECT_ID" \
    --quiet 2>/dev/null

  ok "Violation created: VM now using Default SA ($DEFAULT_SA)"
  next_steps
}

scenario_4() {
  header "Scenario 4 — Group C: Manual Guidance via Email"
  info "No violation needed — WF4 Group C sends email instructions"
  info "Covers: CIS 1.6, 2.3, 2.4, 3.3, 3.6"
  echo ""
  echo -e "  ${YELLOW}Steps:${RESET}"
  echo -e "  1. Go to GitHub Actions → WF4 — Intelligent Recovery → Run workflow"
  echo -e "  2. Fill in:"
  echo -e "     trigger:        MANUAL"
  echo -e "     cis_fail_count: 3"
  echo -e "     dry_run:        false"
  echo -e "  3. Check your email for step-by-step instructions"
  echo ""
}

scenario_all() {
  scenario_1
  sleep 2
  scenario_2
  sleep 2
  echo ""
  echo -e "${YELLOW}Note: Scenario 3 (VM SA swap) and Scenario 4 (email) skipped in 'all' mode.${RESET}"
  echo -e "Run them individually: bash tests/create_violation.sh 3"
}

# ----------------------------------------------------------------
# Main
# ----------------------------------------------------------------
echo -e "${BOLD}"
echo "  ╔══════════════════════════════════════════════════════════╗"
echo "  ║     WF4 Recovery — Create Test Violations                ║"
echo "  ╚══════════════════════════════════════════════════════════╝"
echo -e "${RESET}"
echo -e "  Project: ${BOLD}$PROJECT_ID${RESET}"
echo -e "  VM:      ${BOLD}$VM_NAME ($VM_ZONE)${RESET}"
echo ""

case "$SCENARIO" in
  1)   scenario_1 ;;
  2)   scenario_2 ;;
  3)   scenario_3 ;;
  4)   scenario_4 ;;
  all) scenario_all ;;
  help|*)
    echo "  Usage: bash tests/create_violation.sh [1|2|3|4|all]"
    echo ""
    echo "  1 — CIS 4.5: Serial port (Group A — fully automated)"
    echo "  2 — CIS 4.3 + 4.4: VM metadata (Group A — fully automated)"
    echo "  3 — CIS 4.1 + 4.2: VM Service Account (Group B — Ansible)"
    echo "  4 — Group C: Manual guidance via email"
    echo "  all — Run scenarios 1 and 2"
    ;;
esac