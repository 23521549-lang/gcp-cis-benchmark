#!/bin/bash
# ================================================================
# group_h.sh
# Group H — Operational / SLA Breach Analysis
# H1: SLA breach check
# H2: Compliance trend analysis
# ================================================================
set -uo pipefail

PROJECT_ID=$(gcloud config get-value project 2>/dev/null)
TF_STATE_BUCKET="${TF_STATE_BUCKET:-tf-state-${PROJECT_ID}}"

H_FIXED=false
H_MANUAL_STEPS=""

ok()     { echo "OK       $1"; H_FIXED=true; }
manual() { echo "MANUAL   $1"; H_MANUAL_STEPS="${H_MANUAL_STEPS}\n  - $1"; }
warn()   { echo "WARN     $1"; }
info()   { echo "INFO     $1"; }

echo "════════════════════════════════════════════════════════════"
echo " GROUP H  Operational / SLA Breach Analysis"
echo " Project: $PROJECT_ID"
echo " Started: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo "════════════════════════════════════════════════════════════"

# ── H1: SLA breach check ──────────────────────────────────────────
echo "CHECK    H1  SLA compliance..."

WF4_START_TIME="${WF4_START_TIME:-$(date +%s)}"
CURRENT_TIME=$(date +%s)
ELAPSED_MINUTES=$(( (CURRENT_TIME - WF4_START_TIME) / 60 ))

HIGH_COUNT=0
MED_COUNT=0

if [ -f /tmp/control_fail_list.json ]; then
  COUNTS=$(python3 -c "
import json, sys
try:
    with open('/tmp/control_fail_list.json') as f:
        fail_list = json.load(f)
    high_controls = {'1.5','1.6','2.1','3.1','3.6','3.7','5.1','4.1','4.2','6.4'}
    high  = sum(1 for c in fail_list if str(c) in high_controls)
    total = len(fail_list)
    med   = max(total - high, 0)
    print(f'{high}|{med}')
except Exception:
    print('0|0')
" 2>/dev/null || echo "0|0")
  HIGH_COUNT=$(echo "$COUNTS" | cut -d'|' -f1)
  MED_COUNT=$(echo "$COUNTS"  | cut -d'|' -f2)
fi

SLA_HIGH=10
SLA_MED=20

info "H1  Elapsed        : ${ELAPSED_MINUTES} minutes"
info "H1  HIGH failures  : $HIGH_COUNT (SLA: ${SLA_HIGH} min)"
info "H1  MEDIUM failures: $MED_COUNT (SLA: ${SLA_MED} min)"

SLA_BREACHED=false

if [ "$HIGH_COUNT" -gt 0 ] && [ "$ELAPSED_MINUTES" -gt "$SLA_HIGH" ]; then
  warn "H1  SLA BREACH — HIGH severity: ${ELAPSED_MINUTES}min > ${SLA_HIGH}min SLA"
  SLA_BREACHED=true
  manual "H1  Escalate immediately — $HIGH_COUNT HIGH control(s) unresolved"
  manual "H1  Review WF4 log for bottlenecks in GitHub Actions artifacts"
fi

if [ "$MED_COUNT" -gt 0 ] && [ "$ELAPSED_MINUTES" -gt "$SLA_MED" ]; then
  warn "H1  SLA BREACH — MEDIUM severity: ${ELAPSED_MINUTES}min > ${SLA_MED}min SLA"
  SLA_BREACHED=true
  manual "H1  Review recovery log — $MED_COUNT MEDIUM control(s) unresolved"
fi

[ "$SLA_BREACHED" = "false" ] && \
  ok "H1  Within SLA — elapsed=${ELAPSED_MINUTES}min high=${SLA_HIGH}min med=${SLA_MED}min"

echo "SLA_BREACHED=$SLA_BREACHED" >> "${GITHUB_ENV:-/dev/null}" 2>/dev/null || true
echo ""

# ── H2: Compliance trend analysis ────────────────────────────────
echo "CHECK    H2  Compliance trend analysis..."

HISTORY_FILES=$(gsutil ls \
  "gs://${TF_STATE_BUCKET}/compliance_history/" \
  2>/dev/null | sort | tail -10 || echo "")

if [ -z "$HISTORY_FILES" ]; then
  info "H2  No compliance history yet — WF2 has not run"
  manual "H2  Allow WF2 to run on schedule or trigger manually"
else
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
  info "H2  History records  : $COUNT"
  info "H2  Recent rates (%): $RATES_TRIM"

  if [ "$COUNT" -ge 3 ]; then
    TREND=$(python3 -c "
rates = [int(x) for x in '$RATES_TRIM'.split() if x.strip().isdigit()]
if len(rates) < 3:
    print('0|0|0')
    exit()
half = len(rates) // 2
first_avg  = sum(rates[:half]) // max(half, 1)
second_avg = sum(rates[half:]) // max(len(rates) - half, 1)
diff = second_avg - first_avg
print(f'{first_avg}|{second_avg}|{diff}')
" 2>/dev/null || echo "0|0|0")

    FIRST_AVG=$(echo "$TREND"  | cut -d'|' -f1)
    SECOND_AVG=$(echo "$TREND" | cut -d'|' -f2)
    DIFF=$(echo "$TREND"       | cut -d'|' -f3)

    info "H2  Trend: ${FIRST_AVG}% -> ${SECOND_AVG}% (${DIFF:+}${DIFF}%)"

    if [ "${DIFF:-0}" -lt -5 ]; then
      warn "H2  DEGRADATION TREND — compliance decreased ${DIFF}% over recent history"
      manual "H2  Review: gs://${TF_STATE_BUCKET}/compliance_history/"
      manual "H2  Review recent infrastructure changes"
      manual "H2  Consider increasing WF2 frequency temporarily (every 1 hour)"
    elif [ "${DIFF:-0}" -gt 5 ]; then
      ok "H2  IMPROVING TREND — compliance increased +${DIFF}% over recent history"
    else
      ok "H2  STABLE TREND — compliance within ±5% variance"
    fi
  else
    info "H2  Insufficient history for trend analysis (need >= 3 records)"
  fi
fi

echo ""
echo "════════════════════════════════════════════════════════════"
echo " RESULT   Group H Operational Analysis"
echo "          SLA breached: $SLA_BREACHED"
echo "          Fixed       : $H_FIXED"
[ -n "$H_MANUAL_STEPS" ] && echo -e "          Manual:$H_MANUAL_STEPS"
echo "════════════════════════════════════════════════════════════"

{
  echo "H_FIXED=$H_FIXED"
  echo "SLA_BREACHED=$SLA_BREACHED"
} >> "${GITHUB_ENV:-/dev/null}" 2>/dev/null || true
exit 0