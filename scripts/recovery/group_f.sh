#!/bin/bash
# ================================================================
# Nhóm F — Pipeline / workflow errors
# Script crash / Auth expired / Baseline missing / Ansible failure
# ================================================================
set -uo pipefail

PROJECT_ID=$(gcloud config get-value project 2>/dev/null)
TF_STATE_BUCKET="${TF_STATE_BUCKET:-tf-state-${PROJECT_ID}}"

GREEN="\033[0;32m"; RED="\033[0;31m"; YELLOW="\033[0;33m"; RESET="\033[0m"
F_FIXED=false
F_MANUAL_STEPS=""

fixed()  { echo -e "${GREEN}[FIXED]${RESET} $1";   F_FIXED=true; }
manual() { echo -e "${YELLOW}[MANUAL]${RESET} $1"; F_MANUAL_STEPS="${F_MANUAL_STEPS}\n  - $1"; }
err()    { echo -e "${RED}[ERROR]${RESET} $1"; }

echo "================================================================"
echo "  NHÓM F — Pipeline Error Recovery"
echo "  Project: $PROJECT_ID"
echo "================================================================"
echo ""

# ── F1: GCP Auth check ────────────────────────────────────────────
echo "[ F1 ] Kiểm tra GCP authentication..."
AUTH_OK=$(gcloud auth list --filter="status=ACTIVE" --format="value(account)" 2>/dev/null | head -1)
if [ -n "$AUTH_OK" ]; then
  echo "  Auth OK — Active account: $AUTH_OK"

  # Kiểm tra SA có bị disable không
  SA_STATUS=$(gcloud iam service-accounts describe \
    "github-actions-sa@${PROJECT_ID}.iam.gserviceaccount.com" \
    --project="$PROJECT_ID" \
    --format="value(disabled)" 2>/dev/null || echo "unknown")

  if [ "$SA_STATUS" = "True" ]; then
    err "github-actions-sa bị DISABLED!"
    manual "Enable SA: gcloud iam service-accounts enable github-actions-sa@${PROJECT_ID}.iam.gserviceaccount.com"
    manual "Sau đó tạo key mới và cập nhật GitHub Secret GCP_SA_KEY"
  else
    fixed "GCP auth và SA đều OK"
  fi
else
  err "GCP authentication FAILED"
  manual "Kiểm tra GitHub Secret GCP_SA_KEY còn hợp lệ không"
  manual "Tạo key mới: gcloud iam service-accounts keys create key.json --iam-account=github-actions-sa@${PROJECT_ID}.iam.gserviceaccount.com"
  manual "Cập nhật GitHub Secret: Settings > Secrets > GCP_SA_KEY"
fi

# ── F2: Baseline missing ──────────────────────────────────────────
echo "[ F2 ] Kiểm tra baseline file..."
BASELINE_EXISTS=$(gsutil stat \
  "gs://${TF_STATE_BUCKET}/baseline/cis_baseline_latest.json" \
  2>/dev/null && echo "true" || echo "false")

if [ "$BASELINE_EXISTS" = "false" ]; then
  warn "Baseline file không tồn tại!"

  # Tự động tạo baseline từ check hiện tại nếu 100% PASS
  if [ -f "/tmp/post_recovery_report.json" ]; then
    POST_FAIL=$(jq '.total_fail' /tmp/post_recovery_report.json 2>/dev/null || echo "99")
    if [ "$POST_FAIL" -eq 0 ]; then
      echo "  Hệ thống đang 100% PASS — đang tạo baseline mới..."
      chmod +x "$(dirname "$0")/../baseline/init_baseline.sh" 2>/dev/null || true
      "$(dirname "$0")/../baseline/init_baseline.sh" \
        /tmp/post_recovery_report.json "F_AUTO_RECOVER" /tmp/context_info.json \
        2>/dev/null && fixed "Baseline mới đã được tạo" \
        || manual "Chạy WF1 để tạo baseline: GitHub Actions > WF1 > Run workflow"
    else
      manual "Hệ thống còn $POST_FAIL FAIL — fix CIS trước rồi chạy WF1 để tạo baseline"
    fi
  else
    manual "Chạy WF1 để tạo baseline: GitHub Actions > WF1 > Run workflow"
  fi
else
  fixed "Baseline file tồn tại"
fi

# ── F3: Script crash detection ────────────────────────────────────
echo "[ F3 ] Kiểm tra script integrity..."
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPTS_OK=true

for SCRIPT in check_iam.sh check_logging.sh check_networking.sh \
              check_vm.sh check_storage.sh check_sql.sh \
              cis_full_check.sh recovery.sh; do
  if [ ! -f "${SCRIPT_DIR}/${SCRIPT}" ]; then
    err "Script không tìm thấy: ${SCRIPT_DIR}/${SCRIPT}"
    SCRIPTS_OK=false
    manual "Script bị thiếu: $SCRIPT — kiểm tra git repository"
  fi
done

$SCRIPTS_OK && fixed "Tất cả scripts tồn tại"

# ── F4: Ansible failure — Rollback VM ────────────────────────────
ANSIBLE_FAILED="${ANSIBLE_FAILED:-false}"
VM_NAME="${VM_NAME:-benchmark-vm-01}"
VM_ZONE="${VM_ZONE:-asia-southeast1-a}"

if [ "$ANSIBLE_FAILED" = "true" ]; then
  echo "[ F4 ] Ansible failure — Kiểm tra và rollback VM..."

  VM_STATUS=$(gcloud compute instances describe "$VM_NAME" \
    --zone="$VM_ZONE" --project="$PROJECT_ID" \
    --format="value(status)" 2>/dev/null || echo "NOT_FOUND")

  echo "  VM status: $VM_STATUS"

  if [ "$VM_STATUS" = "TERMINATED" ]; then
    echo "  VM đang STOPPED — đang khởi động lại..."
    gcloud compute instances start "$VM_NAME" \
      --zone="$VM_ZONE" --project="$PROJECT_ID" --quiet 2>/dev/null \
      && fixed "VM đã được start lại sau Ansible failure" \
      || err "Không thể start VM — cần kiểm tra thủ công"

    # Verify VM running
    sleep 30
    VM_STATUS_AFTER=$(gcloud compute instances describe "$VM_NAME" \
      --zone="$VM_ZONE" --project="$PROJECT_ID" \
      --format="value(status)" 2>/dev/null || echo "UNKNOWN")
    echo "  VM status sau start: $VM_STATUS_AFTER"

  elif [ "$VM_STATUS" = "NOT_FOUND" ]; then
    manual "VM $VM_NAME không tồn tại — trigger WF1 để tạo lại hạ tầng"
  else
    echo "  VM status: $VM_STATUS — không cần rollback"
    fixed "VM đang chạy bình thường"
  fi
fi

# ── Xuất kết quả ─────────────────────────────────────────────────
echo ""
echo "================================================================"
echo "  Nhóm F Summary"
echo "  F_FIXED: $F_FIXED"
[ -n "$F_MANUAL_STEPS" ] && echo -e "  Manual steps:$F_MANUAL_STEPS"
echo "================================================================"

echo "F_FIXED=$F_FIXED"         >> "${GITHUB_ENV:-/dev/null}" 2>/dev/null || true
echo "F_MANUAL=$F_MANUAL_STEPS" >> "${GITHUB_ENV:-/dev/null}" 2>/dev/null || true
exit 0