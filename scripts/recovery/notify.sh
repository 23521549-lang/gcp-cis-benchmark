#!/bin/bash
# ================================================================
# Notify — Tổng hợp kết quả tất cả nhóm và gửi email thật
# ================================================================
set -uo pipefail

PROJECT_ID=$(gcloud config get-value project 2>/dev/null)
ALERT_EMAIL="${ALERT_EMAIL:-23521549@gm.uit.edu.vn}"
REPO="${REPO:-unknown}"
RUN_ID="${RUN_ID:-0}"
TRIGGER="${TRIGGER:-UNKNOWN}"
TRIGGER_REASON="${TRIGGER_REASON:-}"
GMAIL_USER="${GMAIL_USER:-}"
GMAIL_PASS="${GMAIL_PASS:-}"

# Kết quả từ các nhóm
TF_FAILED="${TF_FAILED:-false}"
ERROR_TYPE="${ERROR_TYPE:-NONE}"
PRE_FAIL="${PRE_FAIL:-0}"
POST_FAIL="${POST_FAIL:-0}"
POST_RATE="${POST_RATE:-0}"
RECOVERY_STATUS="${RECOVERY_STATUS:-UNKNOWN}"
L2_FAIL="${L2_FAIL:-0}"
L3_FAIL="${L3_FAIL:-0}"
D_ACTION="${D_ACTION:-NONE}"
D_FIXED="${D_FIXED:-false}"
E_FIXED="${E_FIXED:-false}"
F_FIXED="${F_FIXED:-false}"
G_CRITICAL="${G_CRITICAL:-false}"
G_LOOP_BLOCKED="${G_LOOP_BLOCKED:-false}"
G_FALSE_POSITIVE="${G_FALSE_POSITIVE:-false}"
SLA_BREACHED="${SLA_BREACHED:-false}"
WF4_START_TIME="${WF4_START_TIME:-$(date +%s)}"

LOG_URL="https://github.com/${REPO}/actions/runs/${RUN_ID}"
ELAPSED=$(( ($(date +%s) - WF4_START_TIME) / 60 ))

# ── Xác định Final Status & Severity ─────────────────────────────
SEVERITY="INFO"
FINAL_STATUS="UNKNOWN"

if [ "$G_LOOP_BLOCKED" = "true" ]; then
  FINAL_STATUS="CRITICAL — Recovery loop blocked, cần can thiệp thủ công ngay"
  SEVERITY="CRITICAL"
elif [ "$G_CRITICAL" = "true" ]; then
  FINAL_STATUS="CRITICAL — Data integrity issue, cần can thiệp ngay"
  SEVERITY="CRITICAL"
elif [ "$G_FALSE_POSITIVE" = "true" ]; then
  FINAL_STATUS="BUG — False positive trong check script"
  SEVERITY="HIGH"
elif [ "$TF_FAILED" = "true" ] && [ "${POST_FAIL:-99}" -gt 0 ]; then
  FINAL_STATUS="CRITICAL — Terraform lỗi + CIS còn FAIL"
  SEVERITY="CRITICAL"
elif [ "$SLA_BREACHED" = "true" ]; then
  FINAL_STATUS="WARNING — SLA breach"
  SEVERITY="HIGH"
elif [ "$TF_FAILED" = "true" ] && [ "${POST_FAIL:-0}" -eq 0 ]; then
  FINAL_STATUS="WARNING — Terraform lỗi, CIS đã OK"
  SEVERITY="MEDIUM"
elif [ "${POST_FAIL:-0}" -gt 0 ]; then
  FINAL_STATUS="WARNING — Còn ${POST_FAIL} CIS control FAIL"
  SEVERITY="MEDIUM"
elif [ "$RECOVERY_STATUS" = "SUCCESS" ]; then
  FINAL_STATUS="OK — Tất cả đã được xử lý thành công"
  SEVERITY="INFO"
fi

# ── Build email body ──────────────────────────────────────────────
EMAIL_SUBJECT="[$SEVERITY] GCP CIS Alert — $PROJECT_ID — $(date '+%Y-%m-%d %H:%M UTC')"

EMAIL_BODY="================================================================
GCP CIS BENCHMARK — SECURITY ALERT
[$FINAL_STATUS]
================================================================

Project   : $PROJECT_ID
Trigger   : $TRIGGER
Reason    : ${TRIGGER_REASON:-N/A}
Time      : $(date '+%Y-%m-%d %H:%M:%S UTC')
Elapsed   : ${ELAPSED} phút
Log URL   : $LOG_URL

----------------------------------------------------------------
CIS COMPLIANCE
----------------------------------------------------------------
Before recovery : $PRE_FAIL controls FAIL
After recovery  : ${POST_FAIL:-N/A} controls FAIL
Compliance rate : ${POST_RATE:-N/A}%
Recovery status : $RECOVERY_STATUS
Layer 2 issues  : ${L2_FAIL:-N/A}
Layer 3 findings: ${L3_FAIL:-N/A}
"

# Thêm chi tiết từng nhóm có vấn đề
if [ "$TF_FAILED" = "true" ]; then
  EMAIL_BODY="${EMAIL_BODY}
----------------------------------------------------------------
NHÓM D — Infrastructure Error
----------------------------------------------------------------
Error type : $ERROR_TYPE
Action     : $D_ACTION
Auto-fixed : $D_FIXED
"
fi

if [ "$G_LOOP_BLOCKED" = "true" ]; then
  EMAIL_BODY="${EMAIL_BODY}
----------------------------------------------------------------
NHÓM G — CRITICAL: Recovery Loop Blocked
----------------------------------------------------------------
WF4 đã chạy quá nhiều lần mà không giải quyết được.
Recovery tự động đã bị dừng để tránh vòng lặp vô tận.

Hành động cần làm NGAY:
1. Xem log các lần recovery trước: $LOG_URL
2. Fix thủ công vấn đề
3. Reset counter:
   echo '0' | gsutil cp - gs://tf-state-3a51a40b-8c9e-4126-804/recovery/loop_counter.txt
4. Trigger lại WF4 manual
"
fi

if [ "$G_FALSE_POSITIVE" = "true" ]; then
  EMAIL_BODY="${EMAIL_BODY}
----------------------------------------------------------------
NHÓM G — BUG: False Positive Detected
----------------------------------------------------------------
Check script báo PASS nhưng GCP API xác nhận FAIL.
Kết quả check script không đáng tin.

Hành động:
1. Review logic trong check script tương ứng
2. So sánh: script output vs gcloud describe trực tiếp
3. Fix bug và commit
"
fi

if [ "$SLA_BREACHED" = "true" ]; then
  EMAIL_BODY="${EMAIL_BODY}
----------------------------------------------------------------
NHÓM H — SLA Breach
----------------------------------------------------------------
Recovery đã chạy ${ELAPSED} phút — vượt SLA.
HIGH controls SLA: 10 phút
MED controls SLA : 20 phút

Hành động: Xem log WF4 tìm bottleneck.
"
fi

# Action required section
EMAIL_BODY="${EMAIL_BODY}
----------------------------------------------------------------
HÀNH ĐỘNG TIẾP THEO
----------------------------------------------------------------"

case "$SEVERITY" in
  "CRITICAL")
    EMAIL_BODY="${EMAIL_BODY}
🔴 CẦN XỬ LÝ NGAY (trong 1 giờ)
- Xem log chi tiết: $LOG_URL
- Kiểm tra hạ tầng GCP: https://console.cloud.google.com/home/dashboard?project=$PROJECT_ID
";;
  "HIGH")
    EMAIL_BODY="${EMAIL_BODY}
🟠 CẦN XỬ LÝ SỚM (trong 6 giờ)
- Review log và fix: $LOG_URL
";;
  "MEDIUM")
    EMAIL_BODY="${EMAIL_BODY}
🟡 CẦN XỬ LÝ (trong 24 giờ)
- $LOG_URL
";;
  *)
    EMAIL_BODY="${EMAIL_BODY}
🟢 Không cần hành động thêm
";;
esac

EMAIL_BODY="${EMAIL_BODY}
================================================================
GCP CIS Benchmark Automation — project: $PROJECT_ID
================================================================"

# ── In ra log ─────────────────────────────────────────────────────
echo "================================================================"
echo "  NOTIFY SUMMARY"
echo "  FINAL_STATUS: $FINAL_STATUS"
echo "  SEVERITY    : $SEVERITY"
echo "  ALERT EMAIL : $ALERT_EMAIL"
echo "================================================================"
echo ""
echo "$EMAIL_BODY"

# ── Lưu email content ra file ────────────────────────────────────
echo "$EMAIL_BODY" > /tmp/notify_email.txt

# ── Gửi email thật qua Gmail SMTP ────────────────────────────────
if [ -n "$GMAIL_USER" ] && [ -n "$GMAIL_PASS" ]; then
  echo ""
  echo "  Đang gửi email tới $ALERT_EMAIL..."

  EMAIL_CONTENT="From: GCP Security Bot <$GMAIL_USER>
To: $ALERT_EMAIL
Subject: $EMAIL_SUBJECT
MIME-Version: 1.0
Content-Type: text/plain; charset=UTF-8

$EMAIL_BODY"

  echo "$EMAIL_CONTENT" | curl -s \
    --url "smtps://smtp.gmail.com:465" \
    --ssl-reqd \
    --mail-from "$GMAIL_USER" \
    --mail-rcpt "$ALERT_EMAIL" \
    --user "$GMAIL_USER:$GMAIL_PASS" \
    --upload-file - \
    2>/dev/null \
    && echo "  [OK] Email đã gửi tới $ALERT_EMAIL" \
    || echo "  [WARN] Gửi email thất bại — kiểm tra GMAIL_USER/GMAIL_APP_PASSWORD"
else
  echo ""
  echo "  [WARN] Chưa cấu hình email — thêm GitHub Secrets:"
  echo "    GMAIL_USER         = your.email@gmail.com"
  echo "    GMAIL_APP_PASSWORD = xxxx xxxx xxxx xxxx"
  echo "  Tạo App Password tại: myaccount.google.com/apppasswords"
fi

# ── Export ra GITHUB_ENV và file ──────────────────────────────────
{
  echo "FINAL_STATUS=$FINAL_STATUS"
  echo "SEVERITY=$SEVERITY"
} >> "${GITHUB_ENV:-/dev/null}" 2>/dev/null || true

# Lưu vào file để WF4 đọc lại
{
  echo "FINAL_STATUS=$FINAL_STATUS"
  echo "SEVERITY=$SEVERITY"
} > /tmp/notify_result.txt

echo ""
echo "================================================================"
echo "  Notify complete — SEVERITY: $SEVERITY"
echo "================================================================"

[ "$SEVERITY" = "INFO" ] && exit 0 || exit 1