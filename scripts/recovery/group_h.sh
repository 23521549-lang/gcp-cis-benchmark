#!/bin/bash
# ================================================================
# Nhóm H — Operational / SLA breach
# H1: SLA breach check
# H2: Compliance trend analysis
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

# Đọc fail list an toàn — tránh syntax error
HIGH_COUNT=0
MED_COUNT=0

if [ -f /tmp/control_fail_list.json ]; then
  # Dùng python3 để parse an toàn, không dùng jq arithmetic trực tiếp
  COUNTS=$(python3 -c "
import json, sys
try:
    with open('/tmp/control_fail_list.json') as f:
        fail_list = json.load(f)
    high_controls = {'1.5','1.6','2.1','3.1','3.6','3.7','5.1','4.1','4.2','6.4'}
    high = sum(1 for c in fail_list if str(c) in high_controls)
    total = len(fail_list)
    med = total - high
    print(f'{high}|{max(med,0)}')
except Exception:
    print('0|0')
" 2>/dev/null || echo "0|0")

  HIGH_COUNT=$(echo "$COUNTS" | cut -d'|' -f1)
  MED_COUNT=$(echo "$COUNTS"  | cut -d'|' -f2)
fi

SLA_HIGH=10   # phút cho HIGH severity
SLA_MED=20    # phút cho MEDIUM severity

echo "  Elapsed: ${ELAPSED_MINUTES} phút"
echo "  HIGH controls FAIL: $HIGH_COUNT (SLA: ${SLA_HIGH} phút)"
echo "  MEDIUM controls FAIL: $MED_COUNT (SLA: ${SLA_MED} phút)"

SLA_BREACHED=false

if [ "$HIGH_COUNT" -gt 0 ] && [ "$ELAPSED_MINUTES" -gt "$SLA_HIGH" ]; then
  warn "SLA BREACH: HIGH controls chưa fix sau ${ELAPSED_MINUTES} phút (SLA: ${SLA_HIGH})"
  SLA_BREACHED=true
  manual "Escalate ngay — $HIGH_COUNT HIGH controls chưa fix"
  manual "Review WF4 log tìm bottleneck trong GitHub Actions artifacts"
fi

if [ "$MED_COUNT" -gt 0 ] && [ "$ELAPSED_MINUTES" -gt "$SLA_MED" ]; then
  warn "SLA BREACH: MEDIUM controls chưa fix sau ${ELAPSED_MINUTES} phút (SLA: ${SLA_MED})"
  SLA_BREACHED=true
  manual "Review recovery log — $MED_COUNT MEDIUM controls chưa fix"
fi

[ "$SLA_BREACHED" = "false" ] && fixed "Trong SLA — elapsed: ${ELAPSED_MINUTES} phút"
echo "SLA_BREACHED=$SLA_BREACHED" >> "${GITHUB_ENV:-/dev/null}" 2>/dev/null || true
echo ""

# ── H2: Compliance trend analysis ────────────────────────────────
echo "[ H2 ] Phân tích compliance trend..."

HISTORY_FILES=$(gsutil ls \
  "gs://${TF_STATE_BUCKET}/compliance_history/" \
  2>/dev/null | sort | tail -10 || echo "")

if [ -z "$HISTORY_FILES" ]; then
  echo "  Chưa có compliance history — WF2 chưa chạy lần nào"
  manual "Để WF2 tự chạy theo lịch hoặc trigger thủ công"
else
  # Thu thập rates
  RATES=""
  while IFS= read -r F; do
    [ -z "$F" ] && continue
    RATE=$(gsutil cat "$F" 2>/dev/null | \
      python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    print(int(d.get('compliance_rate', 0)))
except:
    print(0)
" 2>/dev/null || echo "0")
    RATES="${RATES} ${RATE}"
  done <<< "$HISTORY_FILES"

  RATES_TRIM=$(echo "$RATES" | xargs)
  COUNT=$(echo "$RATES_TRIM" | wc -w | tr -d ' ')
  echo "  History records: $COUNT"
  echo "  Recent rates: $RATES_TRIM"

  if [ "$COUNT" -ge 3 ]; then
    TREND=$(python3 -c "
rates = [int(x) for x in '$RATES_TRIM'.split() if x.strip().isdigit()]
if len(rates) < 3:
    print('0|0|0')
    exit()
half = len(rates) // 2
first_avg = sum(rates[:half]) // max(half, 1)
second_avg = sum(rates[half:]) // max(len(rates) - half, 1)
diff = second_avg - first_avg
print(f'{first_avg}|{second_avg}|{diff}')
" 2>/dev/null || echo "0|0|0")

    FIRST_AVG=$(echo "$TREND" | cut -d'|' -f1)
    SECOND_AVG=$(echo "$TREND" | cut -d'|' -f2)
    DIFF=$(echo "$TREND" | cut -d'|' -f3)
    echo "  Trend: ${FIRST_AVG}% → ${SECOND_AVG}% (${DIFF:+}${DIFF}%)"

    if [ "${DIFF:-0}" -lt -5 ]; then
      warn "DEGRADATION TREND: Compliance giảm ${DIFF}% trong lịch sử gần đây"
      manual "Kiểm tra lịch sử: gs://${TF_STATE_BUCKET}/compliance_history/"
      manual "Review infrastructure thay đổi gần đây"
      manual "Cân nhắc tăng tần suất WF2 lên mỗi 1 giờ tạm thời"
    elif [ "${DIFF:-0}" -lt 0 ]; then
      warn "Compliance giảm nhẹ ${DIFF}% — cần theo dõi thêm"
    else
      fixed "Compliance trend ổn định hoặc tăng (+${DIFF}%)"
    fi
  else
    echo "  Chưa đủ dữ liệu ($COUNT records) — cần ít nhất 3 lần WF2 chạy"
  fi
fi
echo ""

# ── Summary ───────────────────────────────────────────────────────
echo "================================================================"
echo "  Nhóm H Summary"
echo "  H_FIXED      : $H_FIXED"
echo "  SLA_BREACHED : $SLA_BREACHED"
[ -n "$H_MANUAL_STEPS" ] && echo -e "  Manual steps:$H_MANUAL_STEPS"
echo "================================================================"

{
  echo "H_FIXED=$H_FIXED"
  echo "SLA_BREACHED=$SLA_BREACHED"
} >> "${GITHUB_ENV:-/dev/null}" 2>/dev/null || true

exit 0