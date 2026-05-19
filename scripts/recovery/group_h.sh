#!/bin/bash
# ================================================================
# Nhóm H — Operational / SLA breach
# SLA violation / Compliance degradation trend
# ================================================================
set -uo pipefail

PROJECT_ID=$(gcloud config get-value project 2>/dev/null)
TF_STATE_BUCKET="${TF_STATE_BUCKET:-tf-state-${PROJECT_ID}}"

GREEN="\033[0;32m"; YELLOW="\033[0;33m"; RED="\033[0;31m"; RESET="\033[0m"
H_FIXED=false
H_MANUAL_STEPS=""

fixed()  { echo -e "${GREEN}[FIXED]${RESET} $1";   H_FIXED=true; }
manual() { echo -e "${YELLOW}[MANUAL]${RESET} $1"; H_MANUAL_STEPS="${H_MANUAL_STEPS}\n  - $1"; }
warn()   { echo -e "${YELLOW}[WARN]${RESET} $1"; }

echo "================================================================"
echo "  NHÓM H — Operational / SLA Breach"
echo "  Project: $PROJECT_ID"
echo "================================================================"
echo ""

# ── H1: SLA breach check ──────────────────────────────────────────
echo "[ H1 ] Kiểm tra SLA..."
WF4_START_TIME="${WF4_START_TIME:-$(date +%s)}"
CURRENT_TIME=$(date +%s)
ELAPSED_MINUTES=$(( (CURRENT_TIME - WF4_START_TIME) / 60 ))

# Xác định severity từ fail list
HIGH_COUNT=0
MED_COUNT=0
if [ -f /tmp/control_fail_list.json ]; then
  HIGH_CONTROLS="1.5 1.6 2.1 3.1 3.6 3.7 5.1 4.1 4.2 6.4"
  FAIL_LIST=$(jq -r '.[]' /tmp/control_fail_list.json 2>/dev/null || echo "")
  for CID in $HIGH_CONTROLS; do
    echo "$FAIL_LIST" | grep -qw "$CID" && HIGH_COUNT=$((HIGH_COUNT+1)) || true
  done
  TOTAL_FAIL=$(echo "$FAIL_LIST" | grep -c . 2>/dev/null || echo 0)
  MED_COUNT=$((TOTAL_FAIL - HIGH_COUNT))
fi

SLA_HIGH=10   # phút
SLA_MED=20    # phút

echo "  Elapsed: ${ELAPSED_MINUTES} phút"
echo "  HIGH controls FAIL: $HIGH_COUNT (SLA: ${SLA_HIGH} phút)"
echo "  MEDIUM controls FAIL: $MED_COUNT (SLA: ${SLA_MED} phút)"

SLA_BREACHED=false
if [ "$HIGH_COUNT" -gt 0 ] && [ "$ELAPSED_MINUTES" -gt "$SLA_HIGH" ]; then
  warn "SLA BREACH: HIGH severity controls chưa fix sau ${ELAPSED_MINUTES} phút (SLA: ${SLA_HIGH} phút)"
  SLA_BREACHED=true
  manual "Escalate ngay — HIGH severity controls: $HIGH_COUNT controls chưa được fix"
  manual "Review WF4 log để xem bottleneck ở bước nào"
fi
if [ "$MED_COUNT" -gt 0 ] && [ "$ELAPSED_MINUTES" -gt "$SLA_MED" ]; then
  warn "SLA BREACH: MEDIUM severity controls chưa fix sau ${ELAPSED_MINUTES} phút (SLA: ${SLA_MED} phút)"
  SLA_BREACHED=true
  manual "Review recovery log — MEDIUM controls: $MED_COUNT controls chưa fix"
fi

[ "$SLA_BREACHED" = "false" ] && fixed "Trong SLA — elapsed: ${ELAPSED_MINUTES} phút"
echo "SLA_BREACHED=$SLA_BREACHED" >> "${GITHUB_ENV:-/dev/null}" 2>/dev/null || true

# ── H2: Compliance trend analysis ────────────────────────────────
echo "[ H2 ] Phân tích compliance trend..."

HISTORY_FILES=$(gsutil ls \
  "gs://${TF_STATE_BUCKET}/compliance_history/" \
  2>/dev/null | sort | tail -10 || echo "")

if [ -n "$HISTORY_FILES" ]; then
  TREND_DATA=$(echo "$HISTORY_FILES" | while read F; do
    gsutil cat "$F" 2>/dev/null | \
      python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('compliance_rate',0))" \
      2>/dev/null || echo "0"
  done)

  RATES=($TREND_DATA)
  COUNT=${#RATES[@]}

  if [ "$COUNT" -ge 3 ]; then
    # Tính trend đơn giản: so sánh nửa đầu với nửa sau
    HALF=$((COUNT/2))
    FIRST_HALF_SUM=0
    SECOND_HALF_SUM=0

    for i in "${!RATES[@]}"; do
      if [ "$i" -lt "$HALF" ]; then
        FIRST_HALF_SUM=$((FIRST_HALF_SUM + ${RATES[$i]%.*}))
      else
        SECOND_HALF_SUM=$((SECOND_HALF_SUM + ${RATES[$i]%.*}))
      fi
    done

    FIRST_AVG=$((FIRST_HALF_SUM / HALF))
    SECOND_AVG=$((SECOND_HALF_SUM / (COUNT - HALF)))
    DIFF=$((SECOND_AVG - FIRST_AVG))

    echo "  Trend: ${FIRST_AVG}% → ${SECOND_AVG}% (${DIFF:+}${DIFF}%)"
    echo "  Recent rates: ${RATES[*]}"

    if [ "$DIFF" -lt -5 ]; then
      warn "DEGRADATION TREND: Compliance giảm ${DIFF}% trong ${COUNT} lần check gần nhất"
      manual "Review lịch sử: gs://${TF_STATE_BUCKET}/compliance_history/"
      manual "Kiểm tra có thay đổi infrastructure hoặc policy nào gần đây không"
      manual "Xem xét tăng tần suất WF2 từ 6h lên 1h tạm thời"
    elif [ "$DIFF" -lt 0 ]; then
      warn "Nhẹ: Compliance giảm nhẹ ${DIFF}% — theo dõi thêm"
    else
      fixed "Trend ổn định hoặc tăng (+${DIFF}%)"
    fi
  else
    echo "  Chưa đủ dữ liệu lịch sử ($COUNT records) — cần ít nhất 3 lần WF2 chạy"
  fi
else
  echo "  Chưa có compliance history — WF2 chưa chạy lần nào"
  manual "Để WF2 tự chạy theo lịch hoặc trigger thủ công"
fi

# ── Xuất kết quả ─────────────────────────────────────────────────
echo ""
echo "================================================================"
echo "  Nhóm H Summary"
echo "  H_FIXED: $H_FIXED"
[ -n "$H_MANUAL_STEPS" ] && echo -e "  Manual steps:$H_MANUAL_STEPS"
echo "================================================================"

echo "H_FIXED=$H_FIXED"         >> "${GITHUB_ENV:-/dev/null}" 2>/dev/null || true
echo "H_MANUAL=$H_MANUAL_STEPS" >> "${GITHUB_ENV:-/dev/null}" 2>/dev/null || true
exit 0