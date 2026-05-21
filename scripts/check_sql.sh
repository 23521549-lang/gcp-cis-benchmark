#!/bin/bash
# ================================================================
# check_sql.sh
# CIS GCP Benchmark v4.0.0 — Domain 6: Cloud SQL PostgreSQL
# Controls: 6.4 / 6.2.1 / 6.2.2 / 6.2.3 / 6.2.4 / 6.2.8
# ================================================================
set -uo pipefail

PROJECT_ID=$(gcloud config get-value project 2>/dev/null)
[ -z "$PROJECT_ID" ] && echo "ERROR    Project not configured" && exit 1

PASS=0; FAIL=0

pass() { echo "PASS     $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL     $1"; FAIL=$((FAIL+1)); }
info() { echo "         $1"; }

echo "════════════════════════════════════════════════════════════"
echo " CHECK    [D6] Cloud SQL PostgreSQL"
echo " Project: $PROJECT_ID"
echo "════════════════════════════════════════════════════════════"

INSTANCES=$(gcloud sql instances list \
  --project="$PROJECT_ID" \
  --filter="databaseVersion~POSTGRES" \
  --format="value(name)" 2>/dev/null || echo "")

if [ -z "$INSTANCES" ]; then
  echo "INFO     No PostgreSQL instances found in project"
  echo "════════════════════════════════════════════════════════════"
  echo " RESULT   [D6] Cloud SQL — Status: N/A (no instances)"
  echo "════════════════════════════════════════════════════════════"
  exit 0
fi

while IFS= read -r INSTANCE; do
  [ -z "$INSTANCE" ] && continue
  echo "INFO     Instance: $INSTANCE"

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

  # ── Network config (informational) ─────────────────────────────
  NET_INFO=$(echo "$INSTANCE_JSON" | python3 -c "
import json, sys
d = json.load(sys.stdin)
ip_cfg = d.get('settings',{}).get('ipConfiguration',{})
ipv4 = ip_cfg.get('ipv4Enabled', True)
ips = d.get('ipAddresses',[])
private_ip = next((i['ipAddress'] for i in ips if i.get('type') == 'PRIVATE'), '')
public_ip  = next((i['ipAddress'] for i in ips if i.get('type') == 'PRIMARY'), '')
print(f'{ipv4}|{private_ip}|{public_ip}')
" 2>/dev/null || echo "True||")

  IPV4_ON=$(echo "$NET_INFO"   | cut -d'|' -f1)
  PRIVATE_IP=$(echo "$NET_INFO" | cut -d'|' -f2)
  PUBLIC_IP=$(echo "$NET_INFO"  | cut -d'|' -f3)

  if [ "$IPV4_ON" = "False" ] && [ -n "$PRIVATE_IP" ]; then
    echo "INFO     Network: private-ip=$PRIVATE_IP public-ip=none (recommended)"
  elif [ -n "$PUBLIC_IP" ]; then
    echo "INFO     Network: public-ip=$PUBLIC_IP (consider private-ip only)"
  fi
  echo ""

  # ── CIS 6.4 — require_ssl ──────────────────────────────────────
  echo "CHECK    CIS-6.4  require-ssl"
  SSL=$(echo "$INSTANCE_JSON" | python3 -c "
import json, sys
d = json.load(sys.stdin)
v = d.get('settings',{}).get('ipConfiguration',{}).get('requireSsl', False)
print(v)
" 2>/dev/null || echo "False")
  if [ "$SSL" = "True" ]; then
    pass "CIS-6.4  result=compliant instance=$INSTANCE require-ssl=true"
  else
    fail "CIS-6.4  result=non-compliant instance=$INSTANCE require-ssl=false"
    info "Action:  gcloud sql instances patch $INSTANCE --require-ssl"
  fi

  # ── CIS 6.2.1 — log_error_verbosity ───────────────────────────
  echo "CHECK    CIS-6.2.1 log-error-verbosity"
  V=$(get_flag "log_error_verbosity")
  if [[ "$V" == "default" || "$V" == "terse" ]]; then
    pass "CIS-6.2.1 result=compliant instance=$INSTANCE log_error_verbosity=$V"
  else
    fail "CIS-6.2.1 result=non-compliant instance=$INSTANCE log_error_verbosity=$V expected=default|terse"
    info "Action:  --database-flags log_error_verbosity=default"
  fi

  # ── CIS 6.2.2 — log_connections ───────────────────────────────
  echo "CHECK    CIS-6.2.2 log-connections"
  V=$(get_flag "log_connections")
  if [ "$V" = "on" ]; then
    pass "CIS-6.2.2 result=compliant instance=$INSTANCE log_connections=on"
  else
    fail "CIS-6.2.2 result=non-compliant instance=$INSTANCE log_connections=$V expected=on"
    info "Action:  --database-flags log_connections=on"
  fi

  # ── CIS 6.2.3 — log_disconnections ────────────────────────────
  echo "CHECK    CIS-6.2.3 log-disconnections"
  V=$(get_flag "log_disconnections")
  if [ "$V" = "on" ]; then
    pass "CIS-6.2.3 result=compliant instance=$INSTANCE log_disconnections=on"
  else
    fail "CIS-6.2.3 result=non-compliant instance=$INSTANCE log_disconnections=$V expected=on"
    info "Action:  --database-flags log_disconnections=on"
  fi

  # ── CIS 6.2.4 — log_statement ─────────────────────────────────
  echo "CHECK    CIS-6.2.4 log-statement"
  V=$(get_flag "log_statement")
  if [[ "$V" == "ddl" || "$V" == "mod" || "$V" == "all" ]]; then
    pass "CIS-6.2.4 result=compliant instance=$INSTANCE log_statement=$V"
  else
    fail "CIS-6.2.4 result=non-compliant instance=$INSTANCE log_statement=$V expected=ddl|mod|all"
    info "Action:  --database-flags log_statement=ddl"
  fi

  # ── CIS 6.2.8 — pgaudit ───────────────────────────────────────
  echo "CHECK    CIS-6.2.8 pgaudit"
  V=$(get_flag "cloudsql.enable_pgaudit")
  if [ "$V" = "on" ]; then
    pass "CIS-6.2.8 result=compliant instance=$INSTANCE pgaudit=on"
  else
    fail "CIS-6.2.8 result=non-compliant instance=$INSTANCE pgaudit=$V expected=on"
    info "Action:  --database-flags cloudsql.enable_pgaudit=on"
  fi

  echo ""
done <<< "$INSTANCES"

TOTAL=$((PASS+FAIL))
echo "════════════════════════════════════════════════════════════"
echo " RESULT   [D6] Cloud SQL PostgreSQL"
printf "          Passed: %-3s  Failed: %-3s  Total: %s\n" "$PASS" "$FAIL" "$TOTAL"
[ "$FAIL" -eq 0 ] \
  && echo "          Status: COMPLIANT" \
  || echo "          Status: NON-COMPLIANT"
echo "════════════════════════════════════════════════════════════"
exit $FAIL