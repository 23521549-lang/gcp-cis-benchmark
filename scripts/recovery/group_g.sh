#!/bin/bash
# ================================================================
# group_g.sh
# Group G — Critical Checks & Data Integrity
# G1: Recovery loop detection
# G2: False positive detection (L1 vs L2/L3)
# G3: Terraform state integrity
# ================================================================
set -uo pipefail

PROJECT_ID=$(gcloud config get-value project 2>/dev/null)
TF_STATE_BUCKET="${TF_STATE_BUCKET:-tf-state-${PROJECT_ID}}"
MAX_RECOVERY_LOOPS="${MAX_RECOVERY_LOOPS:-3}"

L1_FAIL="${L1_FAIL:-0}"
L2_FAIL="${L2_FAIL:-0}"
L3_FAIL="${L3_FAIL:-0}"

G_FIXED=false
G_CRITICAL=false
G_LOOP_BLOCKED=false
G_FALSE_POSITIVE=false
G_MANUAL_STEPS=""

ok()       { echo "OK       $1"; G_FIXED=true; }
critical() { echo "CRITICAL $1"; G_CRITICAL=true; }
manual()   { echo "MANUAL   $1"; G_MANUAL_STEPS="${G_MANUAL_STEPS}\n  - $1"; }
warn()     { echo "WARN     $1"; }
info()     { echo "INFO     $1"; }

echo "════════════════════════════════════════════════════════════"
echo " GROUP G  Critical Checks & Data Integrity"
echo " Project: $PROJECT_ID"
echo " L1=$L1_FAIL L2=$L2_FAIL L3=$L3_FAIL"
echo " Started: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo "════════════════════════════════════════════════════════════"

# ── G1: Recovery loop detection ───────────────────────────────────
echo "CHECK    G1  Recovery loop detection..."
LOOP_GCS_KEY="gs://${TF_STATE_BUCKET}/recovery/loop_counter.txt"

CURRENT_COUNT=$(gsutil cat "$LOOP_GCS_KEY" 2>/dev/null | grep -oP '^\d+' || echo "0")
CURRENT_COUNT=$((CURRENT_COUNT + 1))
info "G1  Recovery attempt: $CURRENT_COUNT / $MAX_RECOVERY_LOOPS"

if [ "$CURRENT_COUNT" -ge "$MAX_RECOVERY_LOOPS" ]; then
  critical "G1  Recovery loop detected — $CURRENT_COUNT attempts without resolution"
  echo "BLOCKED_$(date -u +%Y%m%d_%H%M%S)" | \
    gsutil cp - "$LOOP_GCS_KEY" 2>/dev/null || true
  G_LOOP_BLOCKED=true
  manual "G1  Review previous $CURRENT_COUNT recovery logs in GitHub Actions"
  manual "G1  Fix root cause manually then reset counter:"
  manual "    echo '0' | gsutil cp - $LOOP_GCS_KEY"
  manual "G1  Re-trigger WF4 manually after fix"
else
  echo "$CURRENT_COUNT" | gsutil cp - "$LOOP_GCS_KEY" 2>/dev/null || true
  ok "G1  Loop counter updated: $CURRENT_COUNT/$MAX_RECOVERY_LOOPS"
fi
echo ""

# ── G2: False positive detection ─────────────────────────────────
echo "CHECK    G2  False positive detection..."
info "G2  Layer 1 (script)  fail=$L1_FAIL"
info "G2  Layer 2 (GCP API) fail=$L2_FAIL"
info "G2  Layer 3 (SCC)     fail=$L3_FAIL"

if [ "${L1_FAIL:-0}" -eq 0 ] && [ "${L2_FAIL:-0}" -gt 0 ]; then
  critical "G2  False positive — Layer 1 PASS but Layer 2 FAIL: check script has a bug"
  G_FALSE_POSITIVE=true
  manual "G2  Compare script output vs direct gcloud describe output"
  manual "G2  Fix the check script logic and push the fix"
elif [ "${L1_FAIL:-0}" -gt 0 ] && [ "${L2_FAIL:-0}" -eq 0 ] && [ "${L3_FAIL:-0}" -eq 0 ]; then
  warn "G2  Layer 2+3 PASS but Layer 1 FAIL — possible GCP propagation delay"
  manual "G2  Wait 5 minutes then re-trigger WF4"
else
  ok "G2  All layers consistent — no false positive detected"
fi
echo ""

# ── G3: Terraform state integrity ─────────────────────────────────
echo "CHECK    G3  Terraform state integrity..."
LOCK_FILE="gs://${TF_STATE_BUCKET}/terraform/state/default.tflock"
STATE_FILE="gs://${TF_STATE_BUCKET}/terraform/state/default.tfstate"

LOCK_EXISTS=$(gsutil stat "$LOCK_FILE" 2>/dev/null && echo "true" || echo "false")
if [ "$LOCK_EXISTS" = "true" ]; then
  critical "G3  Terraform state is LOCKED"
  manual "G3  Check for running workflows in GitHub Actions"
  manual "G3  If no workflow running: gsutil rm $LOCK_FILE"
  manual "G3  Or: cd terraform && terraform force-unlock LOCK_ID"
fi

STATE_EXISTS=$(gsutil stat "$STATE_FILE" 2>/dev/null && echo "true" || echo "false")
if [ "$STATE_EXISTS" = "false" ]; then
  warn "G3  State file not found — infrastructure not deployed or state lost"
  manual "G3  Run WF1 to initialize infrastructure"
else
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
    warn "G3  State file may be corrupted"
    manual "G3  Inspect: gsutil cat $STATE_FILE | python3 -m json.tool | head -20"
  else
    ok "G3  Terraform state valid — version=$STATE_VERSION lock=none"
  fi
fi
echo ""

# ── Summary ───────────────────────────────────────────────────────
echo "════════════════════════════════════════════════════════════"
echo " RESULT   Group G Critical Checks"
echo "          Fixed         : $G_FIXED"
echo "          Critical      : $G_CRITICAL"
echo "          Loop blocked  : $G_LOOP_BLOCKED"
echo "          False positive: $G_FALSE_POSITIVE"
[ -n "$G_MANUAL_STEPS" ] && echo -e "          Manual:$G_MANUAL_STEPS"
echo "════════════════════════════════════════════════════════════"

{
  echo "G_FIXED=$G_FIXED"
  echo "G_CRITICAL=$G_CRITICAL"
  echo "G_LOOP_BLOCKED=$G_LOOP_BLOCKED"
  echo "G_FALSE_POSITIVE=$G_FALSE_POSITIVE"
} >> "${GITHUB_ENV:-/dev/null}" 2>/dev/null || true

[ "$G_CRITICAL" = "true" ] || [ "$G_LOOP_BLOCKED" = "true" ] && exit 2 || exit 0