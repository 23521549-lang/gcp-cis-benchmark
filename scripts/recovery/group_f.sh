#!/bin/bash
# ================================================================
# group_f.sh
# Group F — Pipeline Error Recovery
# F1: GCP auth check
# F2: Baseline missing
# F3: Script integrity
# F4: Ansible failure rollback
# ================================================================
set -uo pipefail

PROJECT_ID=$(gcloud config get-value project 2>/dev/null)
TF_STATE_BUCKET="${TF_STATE_BUCKET:-tf-state-${PROJECT_ID}}"
VM_NAME="${VM_NAME:-benchmark-vm-01}"
VM_ZONE="${VM_ZONE:-asia-southeast1-a}"
ANSIBLE_FAILED="${ANSIBLE_FAILED:-false}"

F_FIXED=false
F_MANUAL_STEPS=""

ok()     { echo "OK       $1"; F_FIXED=true; }
manual() { echo "MANUAL   $1"; F_MANUAL_STEPS="${F_MANUAL_STEPS}\n  - $1"; }
err()    { echo "ERROR    $1"; }
warn()   { echo "WARN     $1"; }
info()   { echo "INFO     $1"; }

echo "════════════════════════════════════════════════════════════"
echo " GROUP F  Pipeline Error Recovery"
echo " Project: $PROJECT_ID"
echo " Started: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo "════════════════════════════════════════════════════════════"

# ── F1: GCP Authentication ────────────────────────────────────────
echo "CHECK    F1  GCP authentication..."
AUTH_OK=$(gcloud auth list \
  --filter="status=ACTIVE" \
  --format="value(account)" 2>/dev/null | head -1 || echo "")

if [ -n "$AUTH_OK" ]; then
  info "F1  Active account: $AUTH_OK"

  SA_STATUS=$(gcloud iam service-accounts describe \
    "github-actions-sa@${PROJECT_ID}.iam.gserviceaccount.com" \
    --project="$PROJECT_ID" \
    --format="value(disabled)" 2>/dev/null || echo "unknown")

  if [ "$SA_STATUS" = "True" ]; then
    err "F1  github-actions-sa is DISABLED"
    manual "F1  Enable SA: gcloud iam service-accounts enable github-actions-sa@${PROJECT_ID}.iam.gserviceaccount.com"
    manual "F1  Generate new key and update GitHub Secret GCP_SA_KEY"
  else
    ok "F1  GCP auth valid — account=$AUTH_OK sa=enabled"
  fi
else
  err "F1  GCP authentication failed"
  manual "F1  Verify GitHub Secret GCP_SA_KEY is valid and not expired"
  manual "F1  Rotate key: gcloud iam service-accounts keys create key.json --iam-account=github-actions-sa@${PROJECT_ID}.iam.gserviceaccount.com"
  manual "F1  Update secret: GitHub Settings > Secrets > GCP_SA_KEY"
fi
echo ""

# ── F2: Baseline check ────────────────────────────────────────────
echo "CHECK    F2  Baseline file availability..."
BASELINE_EXISTS=$(gsutil stat \
  "gs://${TF_STATE_BUCKET}/baseline/cis_baseline_latest.json" \
  2>/dev/null && echo "true" || echo "false")

if [ "$BASELINE_EXISTS" = "false" ]; then
  warn "F2  Baseline not found in GCS"

  if [ -f "/tmp/post_recovery_report.json" ]; then
    POST_FAIL=$(jq '.total_fail' /tmp/post_recovery_report.json 2>/dev/null || echo "99")
    if [ "$POST_FAIL" -eq 0 ]; then
      info "F2  System 100% compliant — creating baseline automatically..."
      SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && cd .. && pwd)"
      if [ -f "$SCRIPT_DIR/baseline/init_baseline.sh" ]; then
        chmod +x "$SCRIPT_DIR/baseline/init_baseline.sh"
        "$SCRIPT_DIR/baseline/init_baseline.sh" \
          /tmp/post_recovery_report.json "F_AUTO_RECOVER" /tmp/context_info.json \
          2>/dev/null \
          && ok "F2  Baseline created automatically from recovery report" \
          || manual "F2  Run WF1 to create baseline: GitHub Actions > WF1 > Run workflow"
      else
        manual "F2  Run WF1 to create baseline"
      fi
    else
      manual "F2  System has $POST_FAIL failure(s) — fix CIS controls first then run WF1"
    fi
  else
    manual "F2  Run WF1 to create baseline: GitHub Actions > WF1 > Run workflow"
  fi
else
  ok "F2  Baseline file exists in GCS"
fi
echo ""

# ── F3: Script integrity ───────────────────────────────────────────
echo "CHECK    F3  Script integrity..."
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && cd .. && pwd)"
SCRIPTS_OK=true

REQUIRED_SCRIPTS=(
  "check_iam.sh"
  "check_logging.sh"
  "check_networking.sh"
  "check_vm.sh"
  "check_storage.sh"
  "check_sql.sh"
  "cis_full_check.sh"
  "collect_info.sh"
  "recovery/group_a.sh"
  "recovery/group_b.sh"
  "recovery/group_c.sh"
  "recovery/group_d.sh"
  "recovery/group_e.sh"
  "recovery/group_f.sh"
  "recovery/group_g.sh"
  "recovery/group_h.sh"
  "recovery/notify.sh"
)

for SCRIPT in "${REQUIRED_SCRIPTS[@]}"; do
  if [ ! -f "${SCRIPT_DIR}/${SCRIPT}" ]; then
    err "F3  Missing: ${SCRIPT}"
    SCRIPTS_OK=false
    manual "F3  Script missing: $SCRIPT — check git repository"
  fi
done

$SCRIPTS_OK && ok "F3  All required scripts present"
echo ""

# ── F4: Ansible failure rollback ──────────────────────────────────
if [ "$ANSIBLE_FAILED" = "true" ]; then
  echo "CHECK    F4  Ansible failure — checking VM state..."

  VM_STATUS=$(gcloud compute instances describe "$VM_NAME" \
    --zone="$VM_ZONE" --project="$PROJECT_ID" \
    --format="value(status)" 2>/dev/null || echo "NOT_FOUND")

  info "F4  vm=$VM_NAME status=$VM_STATUS"

  if [ "$VM_STATUS" = "TERMINATED" ]; then
    info "F4  VM stopped after Ansible failure — restarting..."
    gcloud compute instances start "$VM_NAME" \
      --zone="$VM_ZONE" --project="$PROJECT_ID" --quiet 2>/dev/null \
      && ok "F4  VM restarted after Ansible failure: vm=$VM_NAME" \
      || err "F4  Failed to restart VM — manual intervention required"

    sleep 30
    VM_AFTER=$(gcloud compute instances describe "$VM_NAME" \
      --zone="$VM_ZONE" --project="$PROJECT_ID" \
      --format="value(status)" 2>/dev/null || echo "UNKNOWN")
    info "F4  VM status after restart: $VM_AFTER"

  elif [ "$VM_STATUS" = "NOT_FOUND" ]; then
    warn "F4  VM $VM_NAME not found"
    manual "F4  Trigger WF1 to recreate VM"
  else
    ok "F4  VM status=$VM_STATUS — no rollback needed"
  fi
else
  info "F4  Ansible did not fail — skipping rollback check"
fi
echo ""

# ── Summary ───────────────────────────────────────────────────────
echo "════════════════════════════════════════════════════════════"
echo " RESULT   Group F Pipeline Error Recovery"
echo "          Fixed : $F_FIXED"
[ -n "$F_MANUAL_STEPS" ] && echo -e "          Manual:$F_MANUAL_STEPS"
echo "════════════════════════════════════════════════════════════"

echo "F_FIXED=$F_FIXED" >> "${GITHUB_ENV:-/dev/null}" 2>/dev/null || true
exit 0