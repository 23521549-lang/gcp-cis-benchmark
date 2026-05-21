#!/bin/bash
# ================================================================
# check_networking.sh
# CIS GCP Benchmark v4.0.0 — Domain 3: Networking
# Controls: 3.1 / 3.3 / 3.6 / 3.7 / 3.8
# ================================================================
set -uo pipefail

PROJECT_ID=$(gcloud config get-value project 2>/dev/null)
[ -z "$PROJECT_ID" ] && echo "ERROR    Project not configured" && exit 1

PASS=0; FAIL=0

pass() { echo "PASS     $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL     $1"; FAIL=$((FAIL+1)); }
info() { echo "         $1"; }

echo "════════════════════════════════════════════════════════════"
echo " CHECK    [D3] Networking"
echo " Project: $PROJECT_ID"
echo "════════════════════════════════════════════════════════════"

# ── CIS 3.1 — No default network ─────────────────────────────────
echo "CHECK    CIS-3.1  no-default-network"
DEFAULT_NET=$(gcloud compute networks list \
  --project="$PROJECT_ID" \
  --filter="name=default" \
  --format="value(name)" 2>/dev/null || echo "")
if [ -z "$DEFAULT_NET" ]; then
  pass "CIS-3.1  result=compliant network=default status=absent"
else
  fail "CIS-3.1  result=non-compliant network=default status=present"
  info "Action:  gcloud compute networks delete default --project=$PROJECT_ID"
fi
echo ""

# ── CIS 3.3 — DNSSEC enabled ─────────────────────────────────────
echo "CHECK    CIS-3.3  dnssec-enabled"
TOTAL_ZONES=$(gcloud dns managed-zones list \
  --project="$PROJECT_ID" \
  --format="value(name)" 2>/dev/null | wc -l | tr -d ' ' || echo "0")

if [ "${TOTAL_ZONES:-0}" -gt 0 ]; then
  DNSSEC_OFF=$(gcloud dns managed-zones list \
    --project="$PROJECT_ID" \
    --format=json 2>/dev/null | python3 -c "
import json, sys
zones = json.load(sys.stdin)
off = [z.get('name','?') for z in zones
       if z.get('visibility','public') != 'private'
       and z.get('dnssecConfig',{}).get('state','off') != 'on']
print('\n'.join(off))
" 2>/dev/null || echo "")
  if [ -z "$DNSSEC_OFF" ]; then
    pass "CIS-3.3  result=compliant zones=$TOTAL_ZONES dnssec=enabled"
  else
    FAIL_COUNT=$(echo "$DNSSEC_OFF" | grep -c . || true)
    fail "CIS-3.3  result=non-compliant zones-without-dnssec=$FAIL_COUNT"
    echo "$DNSSEC_OFF" | while IFS= read -r line; do
      [ -n "$line" ] && info "Resource: zone=$line dnssec=disabled"
    done
    info "Action:  Set dnssec_config { state = 'on' } in vpc.tf"
  fi
else
  fail "CIS-3.3  result=non-compliant dns-zones=0"
  info "Action:  Create managed DNS zone with DNSSEC enabled"
fi
echo ""

# ── CIS 3.6 — SSH not open to 0.0.0.0/0 ─────────────────────────
echo "CHECK    CIS-3.6  ssh-not-open-to-all"
SSH_OPEN=$(gcloud compute firewall-rules list \
  --project="$PROJECT_ID" \
  --format=json 2>/dev/null | python3 -c "
import json, sys
rules = json.load(sys.stdin)
found = []
for r in rules:
    if r.get('direction') != 'INGRESS': continue
    sources = r.get('sourceRanges', [])
    if '0.0.0.0/0' not in sources and '::/0' not in sources: continue
    for a in r.get('allowed', []):
        ports = a.get('ports', [])
        proto = a.get('IPProtocol','')
        if not ports and proto in ['tcp','all']:
            found.append(r['name'])
        elif any('22' in str(p) for p in ports):
            found.append(r['name'])
print('\n'.join(set(found)))
" 2>/dev/null || echo "")

if [ -z "$SSH_OPEN" ]; then
  pass "CIS-3.6  result=compliant ssh-port=22 source=restricted"
else
  RULE_COUNT=$(echo "$SSH_OPEN" | grep -c . || true)
  fail "CIS-3.6  result=non-compliant ssh-open-rules=$RULE_COUNT source=0.0.0.0/0"
  echo "$SSH_OPEN" | while IFS= read -r line; do
    [ -n "$line" ] && info "Resource: rule=$line"
  done
  info "Action:  Restrict source_ranges to specific IP in firewall rule"
fi
echo ""

# ── CIS 3.7 — RDP not open to 0.0.0.0/0 ─────────────────────────
echo "CHECK    CIS-3.7  rdp-not-open-to-all"
RDP_OPEN=$(gcloud compute firewall-rules list \
  --project="$PROJECT_ID" \
  --format=json 2>/dev/null | python3 -c "
import json, sys
rules = json.load(sys.stdin)
found = []
for r in rules:
    if r.get('direction') != 'INGRESS': continue
    sources = r.get('sourceRanges', [])
    if '0.0.0.0/0' not in sources and '::/0' not in sources: continue
    for a in r.get('allowed', []):
        if any('3389' in str(p) for p in a.get('ports', [])): found.append(r['name'])
print('\n'.join(set(found)))
" 2>/dev/null || echo "")

if [ -z "$RDP_OPEN" ]; then
  pass "CIS-3.7  result=compliant rdp-port=3389 source=restricted"
else
  RULE_COUNT=$(echo "$RDP_OPEN" | grep -c . || true)
  fail "CIS-3.7  result=non-compliant rdp-open-rules=$RULE_COUNT source=0.0.0.0/0"
  echo "$RDP_OPEN" | while IFS= read -r line; do
    [ -n "$line" ] && info "Resource: rule=$line"
  done
  info "Action:  Delete or restrict RDP firewall rule"
fi
echo ""

# ── CIS 3.8 — VPC Flow Logs ───────────────────────────────────────
echo "CHECK    CIS-3.8  vpc-flow-logs"
SKIP_PURPOSES="REGIONAL_MANAGED_PROXY GLOBAL_MANAGED_PROXY PRIVATE_SERVICE_CONNECT INTERNAL_HTTPS_LOAD_BALANCER"

FLOW_RESULT=$(gcloud compute networks subnets list \
  --project="$PROJECT_ID" \
  --format=json 2>/dev/null | python3 -c "
import json, sys
subnets = json.load(sys.stdin)
skip = ['REGIONAL_MANAGED_PROXY','GLOBAL_MANAGED_PROXY','PRIVATE_SERVICE_CONNECT','INTERNAL_HTTPS_LOAD_BALANCER']
ok = []; issues = []
for s in subnets:
    if s.get('purpose','PRIVATE') in skip: continue
    name   = s.get('name','?')
    region = s.get('region','').split('/')[-1]
    enabled = s.get('enableFlowLogs', False)
    lc = s.get('logConfig', {})
    fails = []
    if not enabled: fails.append('flow-logs=disabled')
    if lc.get('aggregationInterval') != 'INTERVAL_5_SEC':
        fails.append(f'interval={lc.get(\"aggregationInterval\",\"N/A\")}')
    if str(lc.get('flowSampling','')) not in ['1.0','1']:
        fails.append(f'sampling={lc.get(\"flowSampling\",\"N/A\")}')
    if lc.get('metadata') != 'INCLUDE_ALL_METADATA':
        fails.append(f'metadata={lc.get(\"metadata\",\"N/A\")}')
    if fails: issues.append(f'FAIL:{name}({region}) {\" \".join(fails)}')
    else: ok.append(f'OK:{name}({region})')
for x in ok: print(x)
for x in issues: print(x)
" 2>/dev/null || echo "CHECK_ERROR")

if [ "$FLOW_RESULT" = "CHECK_ERROR" ]; then
  fail "CIS-3.8  result=error unable-to-check-flow-logs"
else
  FAIL_COUNT=$(echo "$FLOW_RESULT" | grep -c "^FAIL:" || true)
  OK_COUNT=$(echo "$FLOW_RESULT"   | grep -c "^OK:"   || true)
  if [ "$FAIL_COUNT" -eq 0 ] && [ "$OK_COUNT" -gt 0 ]; then
    pass "CIS-3.8  result=compliant subnets=$OK_COUNT flow-logs=enabled interval=5s sampling=100%"
    echo "$FLOW_RESULT" | grep "^OK:" | while IFS= read -r line; do
      info "Resource: subnet=${line#OK:}"
    done
  elif [ "$FAIL_COUNT" -gt 0 ]; then
    fail "CIS-3.8  result=non-compliant non-compliant-subnets=$FAIL_COUNT"
    echo "$FLOW_RESULT" | grep "^FAIL:" | while IFS= read -r line; do
      info "Resource: subnet=${line#FAIL:}"
    done
    info "Action:  Enable flow logs with interval=INTERVAL_5_SEC sampling=1.0 metadata=INCLUDE_ALL"
  else
    fail "CIS-3.8  result=non-compliant subnets=0"
  fi
fi
echo ""

# ── Cloud NAT check (informational) ──────────────────────────────
echo "CHECK    EXTRA    cloud-nat-for-private-subnets"
NAT_COUNT=$(gcloud compute routers list \
  --project="$PROJECT_ID" \
  --format=json 2>/dev/null | python3 -c "
import json,sys
routers = json.load(sys.stdin)
nat_count = sum(len(r.get('nats',[])) for r in routers)
print(nat_count)
" 2>/dev/null || echo "0")

if [ "${NAT_COUNT:-0}" -gt 0 ]; then
  echo "INFO     EXTRA    cloud-nat=present count=$NAT_COUNT private-vms-have-outbound=true"
else
  echo "INFO     EXTRA    cloud-nat=absent private-vms-have-outbound=false"
fi
echo ""

# ── Summary ───────────────────────────────────────────────────────
TOTAL=$((PASS+FAIL))
echo "════════════════════════════════════════════════════════════"
echo " RESULT   [D3] Networking"
printf "          Passed: %-3s  Failed: %-3s  Total: %s\n" "$PASS" "$FAIL" "$TOTAL"
[ "$FAIL" -eq 0 ] \
  && echo "          Status: COMPLIANT" \
  || echo "          Status: NON-COMPLIANT"
echo "════════════════════════════════════════════════════════════"
exit $FAIL