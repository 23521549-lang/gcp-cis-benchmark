#!/bin/bash
# ================================================================
# CIS GCP Benchmark v4.0.0 — Domain 6: Cloud SQL PostgreSQL
# CIS 6.4 / 6.2.1 / 6.2.2 / 6.2.3 / 6.2.4 / 6.2.8
# Thêm check Private IP (best practice)
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
  echo -e "${YELLOW}[INFO]${RESET} Không có PostgreSQL instance nào trong project"
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

  # ── Network topology check ──────────────────────────────────────
  echo "  [ Network ] Kiểm tra SQL network config..."
  NET_INFO=$(echo "$INSTANCE_JSON" | python3 -c "
import json, sys
d = json.load(sys.stdin)
ip_cfg = d.get('settings',{}).get('ipConfiguration',{})
ipv4 = ip_cfg.get('ipv4Enabled', True)
private_net = ip_cfg.get('privateNetwork','')
# Lấy IP addresses
ips = d.get('ipAddresses',[])
private_ip = next((i['ipAddress'] for i in ips if i.get('type') == 'PRIVATE'), '')
public_ip  = next((i['ipAddress'] for i in ips if i.get('type') == 'PRIMARY'), '')
print(f'{ipv4}|{bool(private_net)}|{private_ip}|{public_ip}')
" 2>/dev/null || echo "True|False||")

  IPV4_ON=$(echo "$NET_INFO"    | cut -d'|' -f1)
  HAS_PRIVATE=$(echo "$NET_INFO" | cut -d'|' -f2)
  PRIVATE_IP=$(echo "$NET_INFO"  | cut -d'|' -f3)
  PUBLIC_IP=$(echo "$NET_INFO"   | cut -d'|' -f4)

  if [ "$IPV4_ON" = "False" ] && [ -n "$PRIVATE_IP" ]; then
    echo -e "  ${GREEN}[INFO]${RESET} Private IP: $PRIVATE_IP — tốt về bảo mật ✓"
  elif [ "$IPV4_ON" = "True" ] && [ -n "$PUBLIC_IP" ]; then
    echo -e "  ${YELLOW}[INFO]${RESET} Public IP: $PUBLIC_IP — cân nhắc chuyển sang Private IP"
  fi
  echo ""

  # ── CIS 6.4 — require_ssl ──────────────────────────────────────
  echo "  [ 6.4 ] SSL bắt buộc..."
  SSL=$(echo "$INSTANCE_JSON" | python3 -c "
import json, sys
d = json.load(sys.stdin)
v = d.get('settings',{}).get('ipConfiguration',{}).get('requireSsl', False)
print(v)
" 2>/dev/null || echo "False")

  if [ "$SSL" = "True" ]; then
    pass "6.4 requireSsl: True"
  else
    fail "6.4 requireSsl: False — mọi connection không cần SSL"
    info "Fix: gcloud sql instances patch $INSTANCE --require-ssl --project=$PROJECT_ID"
  fi

  # ── CIS 6.2.1 — log_error_verbosity ───────────────────────────
  echo "  [ 6.2.1 ] log_error_verbosity..."
  V=$(get_flag "log_error_verbosity")
  if [[ "$V" == "default" || "$V" == "terse" ]]; then
    pass "6.2.1 log_error_verbosity: $V"
  else
    fail "6.2.1 log_error_verbosity: $V (cần 'default' hoặc 'terse')"
    info "Fix: --database-flags log_error_verbosity=default"
  fi

  # ── CIS 6.2.2 — log_connections ───────────────────────────────
  echo "  [ 6.2.2 ] log_connections..."
  V=$(get_flag "log_connections")
  if [ "$V" = "on" ]; then
    pass "6.2.2 log_connections: on"
  else
    fail "6.2.2 log_connections: $V (cần 'on')"
    info "Fix: --database-flags log_connections=on"
  fi

  # ── CIS 6.2.3 — log_disconnections ────────────────────────────
  echo "  [ 6.2.3 ] log_disconnections..."
  V=$(get_flag "log_disconnections")
  if [ "$V" = "on" ]; then
    pass "6.2.3 log_disconnections: on"
  else
    fail "6.2.3 log_disconnections: $V (cần 'on')"
    info "Fix: --database-flags log_disconnections=on"
  fi

  # ── CIS 6.2.4 — log_statement ─────────────────────────────────
  echo "  [ 6.2.4 ] log_statement..."
  V=$(get_flag "log_statement")
  if [[ "$V" == "ddl" || "$V" == "mod" || "$V" == "all" ]]; then
    pass "6.2.4 log_statement: $V"
  else
    fail "6.2.4 log_statement: $V (cần 'ddl', 'mod', hoặc 'all')"
    info "Fix: --database-flags log_statement=ddl"
  fi

  # ── CIS 6.2.8 — pgaudit ───────────────────────────────────────
  echo "  [ 6.2.8 ] pgaudit..."
  V=$(get_flag "cloudsql.enable_pgaudit")
  if [ "$V" = "on" ]; then
    pass "6.2.8 cloudsql.enable_pgaudit: on"
  else
    fail "6.2.8 cloudsql.enable_pgaudit: $V (cần 'on')"
    info "Fix: --database-flags cloudsql.enable_pgaudit=on"
  fi

  echo ""
done <<< "$INSTANCES"

# ── Summary ───────────────────────────────────────────────────────
TOTAL=$((PASS+FAIL))
echo "================================================================"
echo "  SQL Check — PASS: $PASS | FAIL: $FAIL"
echo "================================================================"
exit $FAIL