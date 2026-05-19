#!/bin/bash
# ================================================================
# CIS GCP Benchmark v4.0.0 — Domain 3: Networking
# CIS 3.1 / 3.3 / 3.6 / 3.7 / 3.8
# FIX: bỏ set -e để script không bị cắt giữa chừng
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
echo "  CIS NETWORKING CHECK — PROJECT: $PROJECT_ID"
echo "================================================================"
echo ""

# ── CIS 3.1 — Default network ─────────────────────────────────────
echo "[ 3.1 ] Default network không tồn tại..."
DEFAULT_NET=$(gcloud compute networks list \
  --project="$PROJECT_ID" \
  --filter="name=default" \
  --format="value(name)" 2>/dev/null || echo "")
if [ -z "$DEFAULT_NET" ]; then
  pass "3.1 Không tìm thấy mạng 'default' trong project"
else
  fail "3.1 Mạng 'default' vẫn còn tồn tại!"
  info "Fix: gcloud compute networks delete default --project=$PROJECT_ID"
fi
echo ""

# ── CIS 3.3 — DNSSEC ──────────────────────────────────────────────
echo "[ 3.3 ] DNSSEC bật cho Cloud DNS..."
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
    pass "3.3 Tất cả $TOTAL_ZONES DNS zone đã bật DNSSEC"
  else
    fail "3.3 DNS zones chưa bật DNSSEC:"
    echo "$DNSSEC_OFF" | while IFS= read -r line; do [ -n "$line" ] && info "$line"; done
    info "Fix: cập nhật dnssec_config { state = 'on' } trong vpc.tf"
  fi
else
  fail "3.3 Không có DNS Zone nào"
  info "Fix: thêm google_dns_managed_zone với dnssec_config trong vpc.tf"
fi
echo ""

# ── CIS 3.6 — SSH 0.0.0.0/0 ──────────────────────────────────────
echo "[ 3.6 ] SSH không mở 0.0.0.0/0..."
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
  pass "3.6 SSH (port 22) không mở cho 0.0.0.0/0"
else
  fail "3.6 Phát hiện rule mở SSH cho toàn Internet:"
  echo "$SSH_OPEN" | while IFS= read -r line; do [ -n "$line" ] && info "$line"; done
  info "Fix: giới hạn source_ranges xuống IP cụ thể trong terraform"
fi
echo ""

# ── CIS 3.7 — RDP 0.0.0.0/0 ──────────────────────────────────────
echo "[ 3.7 ] RDP không mở 0.0.0.0/0..."
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
  pass "3.7 RDP (port 3389) không mở cho 0.0.0.0/0"
else
  fail "3.7 Phát hiện rule mở RDP cho toàn Internet:"
  echo "$RDP_OPEN" | while IFS= read -r line; do [ -n "$line" ] && info "$line"; done
fi
echo ""

# ── CIS 3.8 — VPC Flow Logs ───────────────────────────────────────
echo "[ 3.8 ] VPC Flow Logs đúng cấu hình CIS..."
FLOW_RESULT=$(gcloud compute networks subnets list \
  --project="$PROJECT_ID" \
  --format=json 2>/dev/null | python3 -c "
import json, sys
subnets = json.load(sys.stdin)
ok = []; issues = []
for s in subnets:
    if s.get('purpose','PRIVATE') not in ['PRIVATE','']: continue
    name = s.get('name','?')
    region = s.get('region','').split('/')[-1]
    enabled = s.get('enableFlowLogs', False)
    lc = s.get('logConfig', {})
    fails = []
    if not enabled: fails.append('FlowLogs=off')
    if lc.get('aggregationInterval') != 'INTERVAL_5_SEC':
        fails.append(f'Interval={lc.get(\"aggregationInterval\",\"N/A\")}')
    if str(lc.get('flowSampling','')) not in ['1.0','1']:
        fails.append(f'Sampling={lc.get(\"flowSampling\",\"N/A\")}')
    if lc.get('metadata') != 'INCLUDE_ALL_METADATA':
        fails.append(f'Metadata={lc.get(\"metadata\",\"N/A\")}')
    if fails: issues.append(f'FAIL:{name}({region}):{\" \".join(fails)}')
    else: ok.append(f'OK:{name}')
for x in ok: print(x)
for x in issues: print(x)
" 2>/dev/null || echo "CHECK_ERROR")

if [ "$FLOW_RESULT" = "CHECK_ERROR" ]; then
  fail "3.8 Không kiểm tra được VPC Flow Logs"
else
  FAIL_COUNT=$(echo "$FLOW_RESULT" | grep -c "^FAIL:" || true)
  OK_COUNT=$(echo "$FLOW_RESULT"   | grep -c "^OK:"   || true)
  if [ "$FAIL_COUNT" -eq 0 ] && [ "$OK_COUNT" -gt 0 ]; then
    pass "3.8 Tất cả $OK_COUNT subnet đã bật VPC Flow Logs đúng cấu hình CIS"
  elif [ "$FAIL_COUNT" -gt 0 ]; then
    fail "3.8 Phát hiện subnet chưa đúng cấu hình CIS 3.8:"
    echo "$FLOW_RESULT" | grep "^FAIL:" | while IFS= read -r line; do info "${line#FAIL:}"; done
  else
    fail "3.8 Không tìm thấy subnet PRIVATE nào"
  fi
fi
echo ""

# ── Summary ───────────────────────────────────────────────────────
TOTAL=$((PASS+FAIL))
echo "================================================================"
if [ "$FAIL" -eq 0 ]; then
  echo -e "  ${GREEN}KẾT QUẢ: $PASS/$TOTAL PASS — Đạt chuẩn CIS Networking${RESET}"
else
  echo -e "  KẾT QUẢ: ${GREEN}$PASS PASS${RESET} | ${RED}$FAIL FAIL${RESET} (tổng $TOTAL tiêu chí)"
fi
echo "================================================================"
exit $FAIL