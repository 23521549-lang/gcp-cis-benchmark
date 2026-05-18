#!/bin/bash
# ================================================================
# CIS GCP Benchmark v4.0.0 — Domain 6: Cloud SQL PostgreSQL
# CIS 6.4   — SSL bắt buộc
# CIS 6.2.1 — log_error_verbosity = default/terse
# CIS 6.2.2 — log_connections = on
# CIS 6.2.3 — log_disconnections = on
# CIS 6.2.4 — log_statement = ddl/mod/all
# CIS 6.2.8 — cloudsql.enable_pgaudit = on
# ================================================================
set -uo pipefail

PROJECT_ID=$(gcloud config get-value project 2>/dev/null)
if [ -z "$PROJECT_ID" ]; then
  echo "ERROR: Chưa set project." && exit 1
fi

GREEN="\033[0;32m"; RED="\033[0;31m"; YELLOW="\033[0;33m"; RESET="\033[0m"
PASS=0; FAIL=0

pass() { echo -e "${GREEN}[PASS]${RESET} $1"; PASS=$((PASS+1)); }
fail() { echo -e "${RED}[FAIL]${RESET} $1"; FAIL=$((FAIL+1)); }
info() { echo -e "${YELLOW}      $1${RESET}"; }

echo "================================================================"
echo "  CIS CLOUD SQL CHECK — PROJECT: $PROJECT_ID"
echo "================================================================"
echo ""

# Lấy danh sách PostgreSQL instances
INSTANCES=$(gcloud sql instances list \
  --project="$PROJECT_ID" \
  --filter="databaseVersion~POSTGRES" \
  --format="value(name)" 2>/dev/null)

if [ -z "$INSTANCES" ]; then
  echo -e "${YELLOW}[INFO]${RESET} Không có PostgreSQL instance nào trong project"
  exit 0
fi

for INSTANCE in $INSTANCES; do
  echo "--- Instance: $INSTANCE ---"

  # Lấy toàn bộ config 1 lần để giảm API calls
  INSTANCE_JSON=$(gcloud sql instances describe "$INSTANCE" \
    --project="$PROJECT_ID" \
    --format=json 2>/dev/null || echo '{}')

  # Helper: parse flag value từ JSON
  get_flag() {
    local flag_name="$1"
    echo "$INSTANCE_JSON" | python3 -c "
import json, sys
d = json.load(sys.stdin)
flags = d.get('settings', {}).get('databaseFlags', [])
val = next((f['value'] for f in flags if f['name'] == '$flag_name'), 'NOT_SET')
print(val)
" 2>/dev/null || echo "NOT_SET"
  }

  # ── CIS 6.4 — require_ssl ──────────────────────────────────────
  echo "[ 6.4 ] SSL bắt buộc..."
  SSL_REQUIRED=$(echo "$INSTANCE_JSON" | python3 -c "
import json, sys
d = json.load(sys.stdin)
v = d.get('settings',{}).get('ipConfiguration',{}).get('requireSsl', False)
print(str(v))
" 2>/dev/null || echo "False")

  if [ "$SSL_REQUIRED" = "True" ]; then
    pass "6.4 requireSsl: True"
  else
    fail "6.4 requireSsl: False — mọi connection không cần SSL"
    info "Fix: gcloud sql instances patch $INSTANCE --require-ssl --project=$PROJECT_ID"
  fi

  # ── CIS 6.2.1 — log_error_verbosity ───────────────────────────
  echo "[ 6.2.1 ] log_error_verbosity..."
  V=$(get_flag "log_error_verbosity")
  if [[ "$V" == "default" || "$V" == "terse" ]]; then
    pass "6.2.1 log_error_verbosity: $V"
  else
    fail "6.2.1 log_error_verbosity: $V (cần 'default' hoặc 'terse')"
    info "Fix: --database-flags log_error_verbosity=default"
  fi

  # ── CIS 6.2.2 — log_connections ───────────────────────────────
  echo "[ 6.2.2 ] log_connections..."
  V=$(get_flag "log_connections")
  if [ "$V" = "on" ]; then
    pass "6.2.2 log_connections: on"
  else
    fail "6.2.2 log_connections: $V (cần 'on')"
    info "Fix: --database-flags log_connections=on"
  fi

  # ── CIS 6.2.3 — log_disconnections ────────────────────────────
  echo "[ 6.2.3 ] log_disconnections..."
  V=$(get_flag "log_disconnections")
  if [ "$V" = "on" ]; then
    pass "6.2.3 log_disconnections: on"
  else
    fail "6.2.3 log_disconnections: $V (cần 'on')"
    info "Fix: --database-flags log_disconnections=on"
  fi

  # ── CIS 6.2.4 — log_statement ─────────────────────────────────
  echo "[ 6.2.4 ] log_statement..."
  V=$(get_flag "log_statement")
  if [[ "$V" == "ddl" || "$V" == "mod" || "$V" == "all" ]]; then
    pass "6.2.4 log_statement: $V"
  else
    fail "6.2.4 log_statement: $V (cần 'ddl', 'mod', hoặc 'all')"
    info "Fix: --database-flags log_statement=ddl"
  fi

  # ── CIS 6.2.8 — pgaudit ───────────────────────────────────────
  echo "[ 6.2.8 ] pgaudit..."
  V=$(get_flag "cloudsql.enable_pgaudit")
  if [ "$V" = "on" ]; then
    pass "6.2.8 cloudsql.enable_pgaudit: on"
  else
    fail "6.2.8 cloudsql.enable_pgaudit: $V (cần 'on')"
    info "Fix: --database-flags cloudsql.enable_pgaudit=on"
  fi

  echo ""
done

echo "================================================================"
echo "  SQL Check — PASS: $PASS | FAIL: $FAIL"
echo "================================================================"
exit $FAIL