#!/bin/bash
# ================================================================
# reset.sh — Full infrastructure teardown and state cleanup
# Usage: bash reset.sh
# ================================================================

set -uo pipefail

PROJECT_ID="project-3a51a40b-8c9e-4126-804"
BUCKET_NAME="benchmark-storage-3a51a40b-8c9e-4126-804"
STATE_BUCKET="tf-state-3a51a40b-8c9e-4126-804"
REGION="asia-southeast1"
VM_NAME="benchmark-vm-01"
VM_ZONE="asia-southeast1-b"

# ----------------------------------------------------------------
# Colors & formatting
# ----------------------------------------------------------------
BOLD="\033[1m"
DIM="\033[2m"
GREEN="\033[0;32m"
RED="\033[0;31m"
YELLOW="\033[0;33m"
CYAN="\033[0;36m"
GRAY="\033[0;90m"
RESET="\033[0m"

STEP=0
ERRORS=0
SKIPPED=0
DELETED=0

# ----------------------------------------------------------------
# Logger functions
# ----------------------------------------------------------------
step() {
  STEP=$((STEP + 1))
  echo ""
  echo -e "${CYAN}${BOLD}[$STEP] $1${RESET}"
  echo -e "${GRAY}$(printf '%.0s─' {1..60})${RESET}"
}

ok() {
  DELETED=$((DELETED + 1))
  echo -e "  ${GREEN}✔${RESET}  $1"
}

skip() {
  SKIPPED=$((SKIPPED + 1))
  echo -e "  ${GRAY}–${RESET}  ${DIM}$1 — not found, skipping${RESET}"
}

warn() {
  echo -e "  ${YELLOW}!${RESET}  $1"
}

fail() {
  ERRORS=$((ERRORS + 1))
  echo -e "  ${RED}✘${RESET}  $1"
}

run() {
  local label="$1"
  shift
  if "$@" 2>/dev/null; then
    ok "$label"
  else
    skip "$label"
  fi
}

# ----------------------------------------------------------------
# Header
# ----------------------------------------------------------------
clear
echo -e "${BOLD}"
echo "  ╔══════════════════════════════════════════════════════════╗"
echo "  ║           GCP CIS Benchmark — Full Reset                 ║"
echo "  ╚══════════════════════════════════════════════════════════╝"
echo -e "${RESET}"
echo -e "  ${DIM}Project  ${RESET}${BOLD}$PROJECT_ID${RESET}"
echo -e "  ${DIM}Region   ${RESET}${BOLD}$REGION${RESET}"
echo -e "  ${DIM}Started  ${RESET}${BOLD}$(date '+%Y-%m-%d %H:%M:%S')${RESET}"
echo ""
echo -e "  ${RED}${BOLD}WARNING${RESET}  This action is irreversible."
echo -e "  ${DIM}Press Enter to continue or Ctrl+C to cancel...${RESET}"
read -r

# ----------------------------------------------------------------
# Step 1 — VM
# ----------------------------------------------------------------
step "Compute — Deleting VM instance"
run "VM: $VM_NAME" \
  gcloud compute instances delete "$VM_NAME" \
    --zone="$VM_ZONE" \
    --project="$PROJECT_ID" \
    --quiet

# ----------------------------------------------------------------
# Step 2 — Cloud SQL
# ----------------------------------------------------------------
step "Database — Deleting Cloud SQL instance"
run "SQL: benchmark-postgres" \
  gcloud sql instances delete benchmark-postgres \
    --project="$PROJECT_ID" \
    --quiet

# ----------------------------------------------------------------
# Step 3 — Firewall rules
# ----------------------------------------------------------------
step "Networking — Deleting firewall rules"
for RULE in benchmark-allow-ssh benchmark-deny-all-ingress; do
  run "Firewall: $RULE" \
    gcloud compute firewall-rules delete "$RULE" \
      --project="$PROJECT_ID" \
      --quiet
done

# ----------------------------------------------------------------
# Step 4 — Subnet
# ----------------------------------------------------------------
step "Networking — Deleting subnet"
run "Subnet: benchmark-subnet" \
  gcloud compute networks subnets delete benchmark-subnet \
    --region="$REGION" \
    --project="$PROJECT_ID" \
    --quiet

# ----------------------------------------------------------------
# Step 5 — VPC
# ----------------------------------------------------------------
step "Networking — Deleting VPC network"
run "VPC: benchmark-vpc" \
  gcloud compute networks delete benchmark-vpc \
    --project="$PROJECT_ID" \
    --quiet

# ----------------------------------------------------------------
# Step 6 — DNS
# ----------------------------------------------------------------
step "DNS — Deleting managed zones and policy"
for ZONE in benchmark-private-zone benchmark-public-zone benchmark-dns-zone; do
  run "DNS zone: $ZONE" \
    gcloud dns managed-zones delete "$ZONE" \
      --project="$PROJECT_ID" \
      --quiet
done

run "DNS policy: benchmark-dns-logging-policy" \
  gcloud dns policies delete benchmark-dns-logging-policy \
    --project="$PROJECT_ID" \
    --quiet

# ----------------------------------------------------------------
# Step 7 — KMS
# ----------------------------------------------------------------
step "KMS — Destroying crypto key versions"
gcloud kms keys versions list \
  --key=benchmark-crypto-key \
  --keyring=benchmark-keyring \
  --location="$REGION" \
  --project="$PROJECT_ID" \
  --format="value(name)" 2>/dev/null | while read -r VERSION; do
  run "KMS version: $(basename "$VERSION")" \
    gcloud kms keys versions destroy "$VERSION" \
      --project="$PROJECT_ID" \
      --quiet
done
warn "KMS KeyRing cannot be deleted — GCP limitation, skipping"

# ----------------------------------------------------------------
# Step 8 — API Keys
# ----------------------------------------------------------------
step "Security — Deleting API keys"
gcloud services api-keys list \
  --project="$PROJECT_ID" \
  --format="value(name)" 2>/dev/null | while read -r KEY; do
  run "API key: $(basename "$KEY")" \
    gcloud services api-keys delete "$KEY" \
      --project="$PROJECT_ID" \
      --quiet
done

# ----------------------------------------------------------------
# Step 9 — Service Account
# ----------------------------------------------------------------
step "IAM — Deleting service account"
run "SA: app-least-privilege-sa" \
  gcloud iam service-accounts delete \
    "app-least-privilege-sa@${PROJECT_ID}.iam.gserviceaccount.com" \
    --project="$PROJECT_ID" \
    --quiet

# ----------------------------------------------------------------
# Step 10 — Logging
# ----------------------------------------------------------------
step "Logging — Deleting sinks and metrics"
run "Log sink: benchmark-log-sink" \
  gcloud logging sinks delete benchmark-log-sink \
    --project="$PROJECT_ID" \
    --quiet

for METRIC in \
  project_ownership_changes_metric \
  audit_config_changes_metric \
  custom_role_changes_metric; do
  run "Log metric: $METRIC" \
    gcloud logging metrics delete "$METRIC" \
      --project="$PROJECT_ID" \
      --quiet
done

# ----------------------------------------------------------------
# Step 11 — Alert Policies & Notification Channels
# ----------------------------------------------------------------
step "Monitoring — Deleting alert policies and notification channels"
TOKEN=$(gcloud auth print-access-token 2>/dev/null)

curl -s -H "Authorization: Bearer $TOKEN" \
  "https://monitoring.googleapis.com/v3/projects/$PROJECT_ID/alertPolicies" \
  2>/dev/null | python3 -c "
import json, sys
data = json.load(sys.stdin)
for p in data.get('alertPolicies', []): print(p.get('name',''))
" 2>/dev/null | while read -r POLICY; do
  if curl -s -X DELETE \
    -H "Authorization: Bearer $TOKEN" \
    "https://monitoring.googleapis.com/v3/$POLICY" 2>/dev/null | grep -q "{}"; then
    ok "Alert policy: $(basename "$POLICY")"
  fi
done

curl -s -H "Authorization: Bearer $TOKEN" \
  "https://monitoring.googleapis.com/v3/projects/$PROJECT_ID/notificationChannels" \
  2>/dev/null | python3 -c "
import json, sys
data = json.load(sys.stdin)
for c in data.get('notificationChannels', []): print(c.get('name',''))
" 2>/dev/null | while read -r CHANNEL; do
  if curl -s -X DELETE \
    -H "Authorization: Bearer $TOKEN" \
    "https://monitoring.googleapis.com/v3/$CHANNEL?force=true" 2>/dev/null | grep -q "{}"; then
    ok "Notification channel: $(basename "$CHANNEL")"
  fi
done

# ----------------------------------------------------------------
# Step 12 — Storage bucket
# ----------------------------------------------------------------
step "Storage — Deleting log bucket"
LOCKED=$(gsutil retention get "gs://$BUCKET_NAME" 2>/dev/null | grep -i "LOCKED" || true)
if [ -n "$LOCKED" ]; then
  fail "Bucket '$BUCKET_NAME' has a retention lock and cannot be deleted (CIS 2.3)"
  warn "Update storage_bucket_name in terraform.tfvars before redeploying"
  warn "Suggested: benchmark-storage-$(date +%s)"
else
  run "Bucket: $BUCKET_NAME" \
    gsutil rm -rf "gs://$BUCKET_NAME"
fi

# ----------------------------------------------------------------
# Step 13 — Terraform state
# ----------------------------------------------------------------
step "Terraform — Clearing remote state"
run "State: gs://$STATE_BUCKET/terraform/state/" \
  gsutil rm -r "gs://$STATE_BUCKET/terraform/state/"

# ----------------------------------------------------------------
# Summary
# ----------------------------------------------------------------
echo ""
echo -e "${GRAY}$(printf '%.0s═' {1..62})${RESET}"
echo -e "${BOLD}  Summary${RESET}"
echo -e "${GRAY}$(printf '%.0s─' {1..62})${RESET}"
echo -e "  ${GREEN}✔${RESET}  Deleted   ${BOLD}$DELETED${RESET} resources"
echo -e "  ${GRAY}–${RESET}  Skipped   ${BOLD}$SKIPPED${RESET} resources"
[ "$ERRORS" -gt 0 ] && echo -e "  ${RED}✘${RESET}  Errors    ${BOLD}$ERRORS${RESET} resources"
echo -e "  ${DIM}Completed $(date '+%Y-%m-%d %H:%M:%S')${RESET}"
echo -e "${GRAY}$(printf '%.0s─' {1..62})${RESET}"
echo ""
echo -e "${BOLD}  Next steps${RESET}"
echo ""
if [ -n "$LOCKED" ]; then
  echo -e "  ${YELLOW}1.${RESET} Update storage_bucket_name in terraform/terraform.tfvars"
  echo -e "     ${DIM}storage_bucket_name = \"benchmark-storage-$(date +%s)\"${RESET}"
  echo ""
fi
echo -e "  ${YELLOW}2.${RESET} Redeploy via GitHub Actions"
echo -e "     ${DIM}git add . && git commit -m \"chore: reset and redeploy\" && git push${RESET}"
echo ""
echo -e "  ${YELLOW}   Or deploy locally${RESET}"
echo -e "     ${DIM}cd terraform && terraform init && terraform apply${RESET}"
echo -e "${GRAY}$(printf '%.0s═' {1..62})${RESET}"
echo ""