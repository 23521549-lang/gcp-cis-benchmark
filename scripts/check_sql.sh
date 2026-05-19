#!/bin/bash
# ================================================================
# CIS GCP Benchmark v4.0.0 — Domain 6: Cloud SQL PostgreSQL
# CIS 6.4 / 6.2.1 / 6.2.2 / 6.2.3 / 6.2.4 / 6.2.8
# ================================================================
set -uo pipefail

PROJECT_ID=$(gcloud config get-value project 2>/dev/null)
[ -z "$PROJECT_ID" ] && echo "ERROR: Chưa set project." && exit 1

GREEN="\033[0;32m"; RED="\033[0;31m"; YELLOW="\033[0;33m"; RESET="\033[0m"
PASS=0; FAIL=0

pass() { echo -e "${GREEN}[PASS]${RESET} $1"; PASS=$((PASS+1)); }
fail() { echo -e "${RED}[FAIL]${RESET} $1"; FAIL=$((FAIL+1)); }
info() { echo -e "${YELLOW}      $1${RESET}"; }

echo "================================================================"
echo "  CIS CLOUD SQL CHECK — PROJECT: $PROJECT_ID"
echo "================================================================"
echo ""

INSTANCES=$(gcloud sql instances list \
  --project="$PROJECT_ID" \
  --filter="databaseVersion~POSTGRES" \
  --format="value(name)" 2>/dev/null || echo "")

if [ -z "$INSTANCES" ]; then
  echo -e "${YELLOW}[INFO]${RESET} Không có PostgreSQL instance nào"
  exit 0
fi

while IFS= read -r INSTANCE; do
  [ -z "$INSTANCE" ] && continue
  echo "--- Instance: $INSTANCE ---"

  INSTANCE_JSON=$(gcloud sql instances describe "$INSTANCE" \
    --project="$PROJECT_ID" \
    --format=json 2>/dev/null || echo "{}")

  get_flag() {
    local fname="$1"
    echo "$INSTANCE_JSON" | python3 -c "
import json, sys
d = json.load(sys.stdin)
flags = d.get('settings',{}).get('databaseFlags',[])
val = next((f['value'] for f in flags if f['name'] == '$fname'), 'NOT_SET')
print(val)
" 2>/dev/null || echo "NOT_SET"
  }

  # ── CIS 6.4 — require_ssl ──────────────────────────────────────
  echo "[ 6.4 ] SSL bắt buộc..."
  SSL=$(echo "$INSTANCE_JSON" | python3 -c "
import json, sys
d = json.load(sys.stdin)
v = d.get('settings',{}).get('ipConfiguration',{}).get('requireSsl', False)
print(v)
" 2>/dev/null || echo "False")
  [ "$SSL" = "True" ] \
    && pass "6.4 requireSsl: True" \
    || { fail "6.4 requireSsl: False"; info "Fix: gcloud sql instances patch $INSTANCE --require-ssl"; }

  # ── CIS 6.2.1 — log_error_verbosity ───────────────────────────
  echo "[ 6.2.1 ] log_error_verbosity..."
  V=$(get_flag "log_error_verbosity")
  [[ "$V" == "default" || "$V" == "terse" ]] \
    && pass "6.2.1 log_error_verbosity: $V" \
    || { fail "6.2.1 log_error_verbosity: $V (cần default/terse)"; info "Fix: --database-flags log_error_verbosity=default"; }

  # ── CIS 6.2.2 — log_connections ───────────────────────────────
  echo "[ 6.2.2 ] log_connections..."
  V=$(get_flag "log_connections")
  [ "$V" = "on" ] \
    && pass "6.2.2 log_connections: on" \
    || { fail "6.2.2 log_connections: $V (cần on)"; info "Fix: --database-flags log_connections=on"; }

  # ── CIS 6.2.3 — log_disconnections ────────────────────────────
  echo "[ 6.2.3 ] log_disconnections..."
  V=$(get_flag "log_disconnections")
  [ "$V" = "on" ] \
    && pass "6.2.3 log_disconnections: on" \
    || { fail "6.2.3 log_disconnections: $V (cần on)"; info "Fix: --database-flags log_disconnections=on"; }

  # ── CIS 6.2.4 — log_statement ─────────────────────────────────
  echo "[ 6.2.4 ] log_statement..."
  V=$(get_flag "log_statement")
  [[ "$V" == "ddl" || "$V" == "mod" || "$V" == "all" ]] \
    && pass "6.2.4 log_statement: $V" \
    || { fail "6.2.4 log_statement: $V (cần ddl/mod/all)"; info "Fix: --database-flags log_statement=ddl"; }

  # ── CIS 6.2.8 — pgaudit ───────────────────────────────────────
  echo "[ 6.2.8 ] pgaudit..."
  V=$(get_flag "cloudsql.enable_pgaudit")
  [ "$V" = "on" ] \
    && pass "6.2.8 cloudsql.enable_pgaudit: on" \
    || { fail "6.2.8 cloudsql.enable_pgaudit: $V (cần on)"; info "Fix: --database-flags cloudsql.enable_pgaudit=on"; }

  echo ""
done <<< "$INSTANCES"

TOTAL=$((PASS+FAIL))
echo "================================================================"
echo "  SQL Check — PASS: $PASS | FAIL: $FAIL"
echo "================================================================"
exit $FAIL