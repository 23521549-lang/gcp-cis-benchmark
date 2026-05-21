#!/bin/bash
# ================================================================
# notify.sh
# Recovery Notification — Send remediation report via email
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

# ── Determine severity and final status ──────────────────────────
SEVERITY="INFO"
FINAL_STATUS="UNKNOWN"

if [ "$G_LOOP_BLOCKED" = "true" ]; then
  FINAL_STATUS="CRITICAL"
  SEVERITY="CRITICAL"
elif [ "$G_CRITICAL" = "true" ]; then
  FINAL_STATUS="CRITICAL"
  SEVERITY="CRITICAL"
elif [ "$G_FALSE_POSITIVE" = "true" ]; then
  FINAL_STATUS="BUG"
  SEVERITY="HIGH"
elif [ "$TF_FAILED" = "true" ] && [ "${POST_FAIL:-99}" -gt 0 ]; then
  FINAL_STATUS="CRITICAL"
  SEVERITY="CRITICAL"
elif [ "$SLA_BREACHED" = "true" ]; then
  FINAL_STATUS="WARNING"
  SEVERITY="HIGH"
elif [ "$TF_FAILED" = "true" ] && [ "${POST_FAIL:-0}" -eq 0 ]; then
  FINAL_STATUS="WARNING"
  SEVERITY="MEDIUM"
elif [ "${POST_FAIL:-0}" -gt 0 ]; then
  FINAL_STATUS="WARNING"
  SEVERITY="MEDIUM"
elif [ "$RECOVERY_STATUS" = "SUCCESS" ]; then
  FINAL_STATUS="OK"
  SEVERITY="INFO"
fi

# ── Build email subject ───────────────────────────────────────────
EMAIL_SUBJECT="[$SEVERITY] GCP CIS Security Report — $PROJECT_ID — $(date -u '+%Y-%m-%d %H:%M UTC')"

# ── Build email body ──────────────────────────────────────────────
EMAIL_BODY="GCP SECURITY AUTOMATION REPORT
════════════════════════════════════════════════════════════
 Status  : $FINAL_STATUS
 Severity: $SEVERITY
════════════════════════════════════════════════════════════
 Project : $PROJECT_ID
 Trigger : $TRIGGER
 Reason  : ${TRIGGER_REASON:-N/A}
 Time    : $(date -u '+%Y-%m-%d %H:%M:%S UTC')
 Elapsed : ${ELAPSED} minutes
 Log URL : $LOG_URL
────────────────────────────────────────────────────────────
 CIS COMPLIANCE SUMMARY
────────────────────────────────────────────────────────────
 Before  : $PRE_FAIL failed controls
 After   : ${POST_FAIL:-N/A} failed controls
 Rate    : ${POST_RATE:-N/A}%
 Status  : $RECOVERY_STATUS
────────────────────────────────────────────────────────────
 VERIFICATION RESULTS
────────────────────────────────────────────────────────────
 Layer 1 (Script)  : $([ "${POST_FAIL:-99}" -eq 0 ] && echo PASS || echo FAIL)
 Layer 2 (GCP API) : $([ "${L2_FAIL:-0}" -eq 0 ] && echo PASS || echo "FAIL ($L2_FAIL issue(s))")
 Layer 3 (SCC)     : $([ "${L3_FAIL:-0}" -eq 0 ] && echo "PASS" || echo "FAIL ($L3_FAIL finding(s))")"

# ── Add remediation details ───────────────────────────────────────
EMAIL_BODY="${EMAIL_BODY}
────────────────────────────────────────────────────────────
 REMEDIATION DETAILS
────────────────────────────────────────────────────────────
 Group A (gcloud)  : fixed=$([ "$D_FIXED" = "true" ] && echo yes || echo no)
 Group B (Ansible) : $([ "$F_FIXED" = "true" ] && echo executed || echo skipped)
 Group D (Infra)   : action=$D_ACTION
 Group E (Security): fixed=$E_FIXED
 Group F (Pipeline): fixed=$F_FIXED"

# ── Add critical alerts ───────────────────────────────────────────
if [ "$G_LOOP_BLOCKED" = "true" ]; then
  EMAIL_BODY="${EMAIL_BODY}
────────────────────────────────────────────────────────────
 CRITICAL — RECOVERY LOOP BLOCKED
────────────────────────────────────────────────────────────
 Automated recovery has been halted after repeated failures.
 Manual intervention is required.

 Required Actions:
 1. Review previous recovery logs: $LOG_URL
 2. Fix the root cause manually
 3. Reset loop counter:
    echo '0' | gsutil cp - gs://tf-state-3a51a40b-8c9e-4126-804/recovery/loop_counter.txt
 4. Re-trigger WF4 manually"
fi

if [ "$G_FALSE_POSITIVE" = "true" ]; then
  EMAIL_BODY="${EMAIL_BODY}
────────────────────────────────────────────────────────────
 BUG — FALSE POSITIVE DETECTED
────────────────────────────────────────────────────────────
 Layer 1 (script) reports PASS but Layer 2 (GCP API) reports FAIL.
 Check script logic may contain a bug.

 Required Actions:
 1. Compare script output vs direct gcloud describe output
 2. Fix the check script logic
 3. Commit and push the fix"
fi

# ── Add action required section ───────────────────────────────────
EMAIL_BODY="${EMAIL_BODY}
────────────────────────────────────────────────────────────
 REQUIRED ACTION
────────────────────────────────────────────────────────────"

case "$SEVERITY" in
  "CRITICAL")
    EMAIL_BODY="${EMAIL_BODY}
 Priority: IMMEDIATE (within 1 hour)
 - Review log: $LOG_URL
 - GCP Console: https://console.cloud.google.com/home/dashboard?project=$PROJECT_ID"
    ;;
  "HIGH")
    EMAIL_BODY="${EMAIL_BODY}
 Priority: URGENT (within 6 hours)
 - Review log: $LOG_URL"
    ;;
  "MEDIUM")
    EMAIL_BODY="${EMAIL_BODY}
 Priority: NORMAL (within 24 hours)
 - Review log: $LOG_URL"
    ;;
  *)
    EMAIL_BODY="${EMAIL_BODY}
 Priority: NONE — No action required"
    ;;
esac

EMAIL_BODY="${EMAIL_BODY}
════════════════════════════════════════════════════════════
 GCP CIS Security Automation | project=$PROJECT_ID
════════════════════════════════════════════════════════════"

# ── Print to log ──────────────────────────────────────────────────
echo "════════════════════════════════════════════════════════════"
echo " NOTIFY   Recovery Report"
echo " Status : $FINAL_STATUS | Severity: $SEVERITY"
echo " Email  : $ALERT_EMAIL"
echo "════════════════════════════════════════════════════════════"
echo ""
echo "$EMAIL_BODY"
echo ""

# ── Save to file ──────────────────────────────────────────────────
echo "$EMAIL_BODY" > /tmp/notify_email.txt

# ── Send via Gmail SMTP ───────────────────────────────────────────
if [ -n "$GMAIL_USER" ] && [ -n "$GMAIL_PASS" ]; then
  echo "INFO     Sending email to $ALERT_EMAIL..."

  EMAIL_CONTENT="From: GCP Security Automation <$GMAIL_USER>
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
    && echo "OK       Email delivered to $ALERT_EMAIL" \
    || echo "##[warning]Email delivery failed — check GMAIL_USER and GMAIL_APP_PASSWORD secrets"
else
  echo "##[warning]Email not configured — add GMAIL_USER and GMAIL_APP_PASSWORD to GitHub Secrets"
  echo "INFO     Report saved to /tmp/notify_email.txt"
fi

# ── Export to GITHUB_ENV ──────────────────────────────────────────
{
  echo "FINAL_STATUS=$FINAL_STATUS"
  echo "SEVERITY=$SEVERITY"
} >> "${GITHUB_ENV:-/dev/null}" 2>/dev/null || true

{
  echo "FINAL_STATUS=$FINAL_STATUS"
  echo "SEVERITY=$SEVERITY"
} > /tmp/notify_result.txt

echo ""
echo "════════════════════════════════════════════════════════════"
echo " DONE     Notification complete — severity=$SEVERITY"
echo "════════════════════════════════════════════════════════════"

[ "$SEVERITY" = "INFO" ] && exit 0 || exit 1