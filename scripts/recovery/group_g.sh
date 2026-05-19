#!/bin/bash
# ================================================================
# Nhóm G — Critical / Data integrity
# False positive / Recovery loop / State corruption
# ================================================================
set -uo pipefail

PROJECT_ID=$(gcloud config get-value project 2>/dev/null)
TF_STATE_BUCKET="${TF_STATE_BUCKET:-tf-state-${PROJECT_ID}}"
MAX_RECOVERY_LOOPS="${MAX_RECOVERY_LOOPS:-3}"

GREEN="\033[0;32m"; RED="\033[0;31m"; YELLOW="\033[0;33m"; RESET="\033[0m"
G_FIXED=false
G_CRITICAL=false
G_MANUAL_STEPS=""

fixed()    { echo -e "${GREEN}[FIXED]${RESET} $1";    G_FIXED=true; }
critical() { echo -e "${RED}[CRITICAL]${RESET} $1";   G_CRITICAL=true; }
manual()   { echo -e "${YELLOW}[MANUAL]${RESET} $1";  G_MANUAL_STEPS="${G_MANUAL_STEPS}\n  - $1"; }

echo "================================================================"
echo "  NHÓM G — Critical / Data Integrity"
echo "  Project: $PROJECT_ID"
echo "================================================================"
echo ""

# ── G1: Recovery loop detection ───────────────────────────────────
echo "[ G1 ] Kiểm tra recovery loop..."
LOOP_COUNTER_FILE="/tmp/wf4_loop_counter.txt"
LOOP_GCS_KEY="gs://${TF_STATE_BUCKET}/recovery/loop_counter.txt"

# Tải counter từ GCS
CURRENT_COUNT=$(gsutil cat "$LOOP_GCS_KEY" 2>/dev/null || echo "0")
CURRENT_COUNT=$((CURRENT_COUNT + 1))

echo "  Recovery attempt: $CURRENT_COUNT / $MAX_RECOVERY_LOOPS"

if [ "$CURRENT_COUNT" -ge "$MAX_RECOVERY_LOOPS" ]; then
  critical "RECOVERY LOOP DETECTED — WF4 đã chạy $CURRENT_COUNT lần mà không giải quyết được!"
  critical "Dừng tự động recovery để tránh vòng lặp vô tận"

  # Reset counter và mark as blocked
  echo "BLOCKED_$(date -u +%Y%m%d_%H%M%S)" | gsutil cp - "$LOOP_GCS_KEY" 2>/dev/null || true

  manual "Xem log của $CURRENT_COUNT lần recovery trước trong GitHub Actions artifacts"
  manual "Kiểm tra thủ công tại: https://console.cloud.google.com/home/dashboard?project=$PROJECT_ID"
  manual "Sau khi fix thủ công: reset counter bằng lệnh: echo '0' | gsutil cp - $LOOP_GCS_KEY"
  manual "Rồi trigger lại WF4 manual"

  echo "G_LOOP_BLOCKED=true" >> "${GITHUB_ENV:-/dev/null}" 2>/dev/null || true
  exit 2  # Exit code 2 = loop detected, stop everything
else
  # Cập nhật counter
  echo "$CURRENT_COUNT" | gsutil cp - "$LOOP_GCS_KEY" 2>/dev/null || true
  echo "  Counter updated: $CURRENT_COUNT"
  fixed "Chưa vượt giới hạn recovery loop"
fi

# ── G2: False positive detection ─────────────────────────────────
echo "[ G2 ] Kiểm tra false positive..."
L1_FAIL="${L1_FAIL:-0}"
L2_FAIL="${L2_FAIL:-0}"
L3_FAIL="${L3_FAIL:-0}"

echo "  Layer 1 (script) FAIL: $L1_FAIL"
echo "  Layer 2 (GCP API) FAIL: $L2_FAIL"
echo "  Layer 3 (SCC) FAIL: $L3_FAIL"

if [ "$L1_FAIL" -eq 0 ] && [ "$L2_FAIL" -gt 0 ]; then
  critical "FALSE POSITIVE: Script báo PASS nhưng GCP API báo FAIL"
  critical "Bug trong check script — kết quả không tin được"
  manual "Review logic trong check script tương ứng"
  manual "So sánh output của script với gcloud describe trực tiếp"
  manual "Fix bug trong script rồi commit + push"
  echo "G_FALSE_POSITIVE=true" >> "${GITHUB_ENV:-/dev/null}" 2>/dev/null || true
elif [ "$L1_FAIL" -gt 0 ] && [ "$L2_FAIL" -eq 0 ] && [ "$L3_FAIL" -eq 0 ]; then
  echo "  Layer 2 và 3 PASS — có thể là timing issue, GCP chưa propagate"
  manual "Chờ 5 phút rồi trigger lại WF4"
  echo "G_FALSE_POSITIVE=false" >> "${GITHUB_ENV:-/dev/null}" 2>/dev/null || true
else
  fixed "Không phát hiện false positive — các layer đồng thuận"
  echo "G_FALSE_POSITIVE=false" >> "${GITHUB_ENV:-/dev/null}" 2>/dev/null || true
fi

# ── G3: Terraform state corruption ───────────────────────────────
echo "[ G3 ] Kiểm tra Terraform state..."
TF_STATE_OK=true

# Kiểm tra state lock
LOCK_FILE="gs://${TF_STATE_BUCKET}/terraform/state/default.tflock"
LOCK_EXISTS=$(gsutil stat "$LOCK_FILE" 2>/dev/null && echo "true" || echo "false")

if [ "$LOCK_EXISTS" = "true" ]; then
  # Kiểm tra lock có quá cũ không (>30 phút)
  LOCK_AGE=$(gsutil ls -l "$LOCK_FILE" 2>/dev/null | \
    awk '{print $2}' | head -1 || echo "")
  echo "  State lock tồn tại — created: $LOCK_AGE"
  critical "Terraform state đang bị lock!"
  manual "Kiểm tra có workflow nào đang chạy không: GitHub Actions > All workflows"
  manual "Nếu không có workflow nào chạy: force-unlock bằng lệnh:"
  manual "  gsutil rm $LOCK_FILE"
  manual "  HOẶC: cd terraform && terraform force-unlock <LOCK_ID>"
  TF_STATE_OK=false
fi

# Validate state file
STATE_FILE="gs://${TF_STATE_BUCKET}/terraform/state/default.tfstate"
STATE_VALID=$(gsutil cat "$STATE_FILE" 2>/dev/null | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    print('valid' if 'version' in d else 'invalid')
except:
    print('corrupt')
" 2>/dev/null || echo "not_found")

echo "  State file: $STATE_VALID"

case "$STATE_VALID" in
  "valid")
    $TF_STATE_OK && fixed "Terraform state OK — không có lock, state hợp lệ"
    ;;
  "corrupt")
    critical "State file bị CORRUPT!"
    manual "Tìm backup: gsutil ls gs://${TF_STATE_BUCKET}/terraform/state/"
    manual "Restore từ backup: gsutil cp gs://...backup.tfstate gs://${TF_STATE_BUCKET}/terraform/state/default.tfstate"
    manual "Hoặc: terraform state pull > state_backup.json && terraform state push state_backup.json"
    ;;
  "not_found")
    echo "  State file không tồn tại — hệ thống chưa được deploy lần nào"
    manual "Chạy WF1 để khởi tạo lần đầu"
    ;;
esac

# ── Xuất kết quả ─────────────────────────────────────────────────
echo ""
echo "================================================================"
echo "  Nhóm G Summary"
echo "  G_FIXED:    $G_FIXED"
echo "  G_CRITICAL: $G_CRITICAL"
[ -n "$G_MANUAL_STEPS" ] && echo -e "  Manual steps:$G_MANUAL_STEPS"
echo "================================================================"

echo "G_FIXED=$G_FIXED"         >> "${GITHUB_ENV:-/dev/null}" 2>/dev/null || true
echo "G_CRITICAL=$G_CRITICAL"   >> "${GITHUB_ENV:-/dev/null}" 2>/dev/null || true
echo "G_MANUAL=$G_MANUAL_STEPS" >> "${GITHUB_ENV:-/dev/null}" 2>/dev/null || true

# Critical = exit 2 để WF4 biết cần stop
[ "$G_CRITICAL" = "true" ] && exit 2 || exit 0