#!/bin/bash
# ================================================================
# Nhóm G — Critical / Data integrity
# G1: Recovery loop detection
# G2: False positive detection (Layer 1 vs Layer 2/3)
# G3: Terraform state check
# ================================================================
set -uo pipefail

PROJECT_ID=$(gcloud config get-value project 2>/dev/null)
TF_STATE_BUCKET="${TF_STATE_BUCKET:-tf-state-${PROJECT_ID}}"
MAX_RECOVERY_LOOPS="${MAX_RECOVERY_LOOPS:-3}"

# Nhận kết quả từ các layer
L1_FAIL="${L1_FAIL:-0}"
L2_FAIL="${L2_FAIL:-0}"
L3_FAIL="${L3_FAIL:-0}"

GREEN="\033[0;32m"; RED="\033[0;31m"; YELLOW="\033[0;33m"; RESET="\033[0m"
G_FIXED=false
G_CRITICAL=false
G_LOOP_BLOCKED=false
G_FALSE_POSITIVE=false
G_MANUAL_STEPS=""

fixed()    { echo -e "${GREEN}[FIXED]${RESET} $1";    G_FIXED=true; }
critical() { echo -e "${RED}[CRITICAL]${RESET} $1";   G_CRITICAL=true; }
manual()   { echo -e "${YELLOW}[MANUAL]${RESET} $1";  G_MANUAL_STEPS="${G_MANUAL_STEPS}\n  - $1"; }

echo "================================================================"
echo "  NHÓM G — Critical / Data Integrity"
echo "  Project: $PROJECT_ID"
echo "  L1=$L1_FAIL L2=$L2_FAIL L3=$L3_FAIL"
echo "================================================================"
echo ""

# ── G1: Recovery loop detection ───────────────────────────────────
echo "[ G1 ] Kiểm tra recovery loop..."
LOOP_GCS_KEY="gs://${TF_STATE_BUCKET}/recovery/loop_counter.txt"

CURRENT_COUNT=$(gsutil cat "$LOOP_GCS_KEY" 2>/dev/null | grep -oP '^\d+' || echo "0")
CURRENT_COUNT=$((CURRENT_COUNT + 1))
echo "  Recovery attempt: $CURRENT_COUNT / $MAX_RECOVERY_LOOPS"

if [ "$CURRENT_COUNT" -ge "$MAX_RECOVERY_LOOPS" ]; then
  critical "RECOVERY LOOP DETECTED — WF4 đã chạy $CURRENT_COUNT lần không hiệu quả!"
  echo "BLOCKED_$(date -u +%Y%m%d_%H%M%S)" | \
    gsutil cp - "$LOOP_GCS_KEY" 2>/dev/null || true
  G_LOOP_BLOCKED=true
  manual "Xem log $CURRENT_COUNT lần recovery trước trong GitHub Actions"
  manual "Fix thủ công rồi reset: echo '0' | gsutil cp - $LOOP_GCS_KEY"
  manual "Sau đó trigger lại WF4 manual"
else
  echo "$CURRENT_COUNT" | gsutil cp - "$LOOP_GCS_KEY" 2>/dev/null || true
  fixed "Counter updated: $CURRENT_COUNT/$MAX_RECOVERY_LOOPS"
fi
echo ""

# ── G2: False positive detection ─────────────────────────────────
echo "[ G2 ] Kiểm tra false positive..."
echo "  Layer 1 (script) FAIL: $L1_FAIL"
echo "  Layer 2 (GCP API) FAIL: $L2_FAIL"
echo "  Layer 3 (SCC) FAIL: $L3_FAIL"

if [ "${L1_FAIL:-0}" -eq 0 ] && [ "${L2_FAIL:-0}" -gt 0 ]; then
  critical "FALSE POSITIVE: Layer 1 PASS nhưng Layer 2 FAIL — bug trong check script"
  G_FALSE_POSITIVE=true
  manual "Review check script logic tương ứng"
  manual "So sánh: script output vs gcloud describe trực tiếp"
  manual "Fix bug → commit → push"
elif [ "${L1_FAIL:-0}" -gt 0 ] && [ "${L2_FAIL:-0}" -eq 0 ] && [ "${L3_FAIL:-0}" -eq 0 ]; then
  echo "  Layer 2+3 PASS — có thể timing issue (GCP chưa propagate)"
  manual "Chờ 5 phút rồi trigger lại WF4"
else
  fixed "Không phát hiện false positive — các layer đồng thuận"
fi
echo ""

# ── G3: Terraform state check ─────────────────────────────────────
echo "[ G3 ] Kiểm tra Terraform state..."
LOCK_FILE="gs://${TF_STATE_BUCKET}/terraform/state/default.tflock"
STATE_FILE="gs://${TF_STATE_BUCKET}/terraform/state/default.tfstate"

# Kiểm tra lock
LOCK_EXISTS=$(gsutil stat "$LOCK_FILE" 2>/dev/null && echo "true" || echo "false")
if [ "$LOCK_EXISTS" = "true" ]; then
  critical "Terraform state đang bị LOCK!"
  manual "Kiểm tra có workflow nào đang chạy không"
  manual "Nếu không có: gsutil rm $LOCK_FILE"
  manual "Hoặc: cd terraform && terraform force-unlock LOCK_ID"
fi

# Kiểm tra state file tồn tại
STATE_EXISTS=$(gsutil stat "$STATE_FILE" 2>/dev/null && echo "true" || echo "false")
if [ "$STATE_EXISTS" = "false" ]; then
  echo "  State file không tồn tại — chưa deploy hoặc state bị mất"
  manual "Chạy WF1 để khởi tạo hạ tầng"
else
  # Validate JSON — chỉ đọc field version, không parse toàn bộ
  STATE_VERSION=$(gsutil cat "$STATE_FILE" 2>/dev/null | \
    python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    print(d.get('version', '?'))
except Exception as e:
    print(f'error:{e}')
" 2>/dev/null || echo "error")

  if echo "$STATE_VERSION" | grep -q "^error"; then
    manual "State file có thể bị lỗi — kiểm tra:"
    manual "  gsutil cat $STATE_FILE | python3 -m json.tool | head -20"
  else
    fixed "Terraform state OK — version: $STATE_VERSION, no lock"
  fi
fi
echo ""

# ── Summary ───────────────────────────────────────────────────────
echo "================================================================"
echo "  Nhóm G Summary"
echo "  G_FIXED         : $G_FIXED"
echo "  G_CRITICAL      : $G_CRITICAL"
echo "  G_LOOP_BLOCKED  : $G_LOOP_BLOCKED"
echo "  G_FALSE_POSITIVE: $G_FALSE_POSITIVE"
[ -n "$G_MANUAL_STEPS" ] && echo -e "  Manual steps:$G_MANUAL_STEPS"
echo "================================================================"

# Export ra GITHUB_ENV
{
  echo "G_FIXED=$G_FIXED"
  echo "G_CRITICAL=$G_CRITICAL"
  echo "G_LOOP_BLOCKED=$G_LOOP_BLOCKED"
  echo "G_FALSE_POSITIVE=$G_FALSE_POSITIVE"
} >> "${GITHUB_ENV:-/dev/null}" 2>/dev/null || true

# Exit code: 2 = critical (stop all), 0 = OK
[ "$G_CRITICAL" = "true" ] || [ "$G_LOOP_BLOCKED" = "true" ] && exit 2 || exit 0