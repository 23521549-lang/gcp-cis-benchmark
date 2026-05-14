#!/bin/bash
# ================================================================
# CIS GCP Benchmark v4.0.0 — Domain 3: Networking
# CIS 3.1 — Default network không tồn tại
# CIS 3.3 — DNSSEC bật cho Cloud DNS
# CIS 3.6 — SSH không mở 0.0.0.0/0
# CIS 3.7 — RDP không mở 0.0.0.0/0
# CIS 3.8 — VPC Flow Logs đúng 4 điều kiện
# ================================================================

set -euo pipefail
PROJECT_ID=$(gcloud config get-value project 2>/dev/null)

if [ -z "$PROJECT_ID" ]; then
  echo "ERROR: Chưa set project."
  exit 1
fi

GREEN="\033[0;32m"; RED="\033[0;31m"; YELLOW="\033[0;33m"; RESET="\033[0m"
PASS=0; FAIL=0

pass() { echo -e "${GREEN}[PASS]${RESET} $1"; PASS=$((PASS+1)); }
fail() { echo -e "${RED}[FAIL]${RESET} $1"; FAIL=$((FAIL+1)); }
info() { echo -e "${YELLOW}      $1${RESET}"; }

echo "================================================================"
echo "  CIS NETWORKING CHECK — PROJECT: $PROJECT_ID"
echo "================================================================"
echo ""

# ----------------------------------------------------------------
# CIS 3.1 — Default network không tồn tại
# ----------------------------------------------------------------
echo "[ 3.1 ] Default network không tồn tại..."
DEFAULT_NET=$(gcloud compute networks list \
  --project="$PROJECT_ID" \
  --filter="name=default" \
  --format="value(name)" 2>/dev/null)

if [ -z "$DEFAULT_NET" ]; then
  pass "Không tìm thấy mạng 'default' trong project"
else
  fail "Mạng 'default' vẫn còn tồn tại!"
  info "Sửa: gcloud compute networks delete default --project=$PROJECT_ID"
fi
echo ""

# ----------------------------------------------------------------
# CIS 3.3 — DNSSEC bật cho tất cả Cloud DNS zones
# ----------------------------------------------------------------
echo "[ 3.3 ] DNSSEC bật cho Cloud DNS..."
TOTAL_ZONES=$(gcloud dns managed-zones list \
  --project="$PROJECT_ID" \
  --format="value(name)" 2>/dev/null | wc -l | tr -d ' ')

if [ "$TOTAL_ZONES" -gt 0 ]; then
  DNSSEC_OFF=$(gcloud dns managed-zones list \
    --project="$PROJECT_ID" \
    --format=json 2>/dev/null | python3 -c "
import json, sys
zones = json.load(sys.stdin)
off = []
for z in zones:
    visibility = z.get('visibility', 'public')
    if visibility == 'private':
        continue
    state = z.get('dnssecConfig', {}).get('state', 'off')
    if state != 'on':
        off.append(z.get('name', 'unknown'))
print('\n'.join(off))
")
  if [ -z "$DNSSEC_OFF" ]; then
    pass "Tất cả $TOTAL_ZONES DNS zone đã bật DNSSEC"
  else
    fail "Phát hiện DNS zones chưa bật DNSSEC:"
    echo "$DNSSEC_OFF" | while read line; do info "$line"; done
    info "Sửa: cập nhật dnssec_config { state = 'on' } trong vpc.tf"
  fi
else
  fail "Không có DNS Zone nào — cần tạo zone với DNSSEC"
  info "Sửa: thêm google_dns_managed_zone với dnssec_config trong vpc.tf"
fi
echo ""

# ----------------------------------------------------------------
# CIS 3.6 — SSH không mở 0.0.0.0/0 (port 22)
# ----------------------------------------------------------------
echo "[ 3.6 ] SSH không mở 0.0.0.0/0..."
SSH_OPEN=$(gcloud compute firewall-rules list \
  --project="$PROJECT_ID" \
  --format="value(name,allowed[].ports,direction,sourceRanges)" 2>/dev/null | \
  grep "INGRESS" | grep "\b22\b" | grep "0.0.0.0/0" | awk '{print $1}')

if [ -z "$SSH_OPEN" ]; then
  pass "SSH (port 22) không được mở cho 0.0.0.0/0"
else
  fail "Phát hiện firewall rule mở SSH cho toàn Internet: $SSH_OPEN"
  info "Sửa: giới hạn source_ranges xuống IP cụ thể"
fi
echo ""

# ----------------------------------------------------------------
# CIS 3.7 — RDP không mở 0.0.0.0/0 (port 3389)
# ----------------------------------------------------------------
echo "[ 3.7 ] RDP không mở 0.0.0.0/0..."
RDP_OPEN=$(gcloud compute firewall-rules list \
  --project="$PROJECT_ID" \
  --format="value(name,allowed[].ports,direction,sourceRanges)" 2>/dev/null | \
  grep "INGRESS" | grep "3389" | grep "0.0.0.0/0" | awk '{print $1}')

if [ -z "$RDP_OPEN" ]; then
  pass "RDP (port 3389) không được mở cho 0.0.0.0/0"
else
  fail "Phát hiện firewall rule mở RDP cho toàn Internet: $RDP_OPEN"
  info "Sửa: xóa rule hoặc giới hạn source_ranges"
fi
echo ""

# ----------------------------------------------------------------
# CIS 3.8 — VPC Flow Logs đúng 4 điều kiện
#   1. enableFlowLogs = true
#   2. aggregationInterval = INTERVAL_5_SEC
#   3. flowSampling = 1.0
#   4. metadata = INCLUDE_ALL_METADATA
#   5. filterExpr KHÔNG có (logs_filtered = false)
# ----------------------------------------------------------------
echo "[ 3.8 ] VPC Flow Logs đúng 4 điều kiện..."
FLOW_ISSUES=$(gcloud compute networks subnets list \
  --project="$PROJECT_ID" \
  --format=json 2>/dev/null | python3 -c "
import sys, json
subnets = json.load(sys.stdin)
issues = []
ok = []
for s in subnets:
    if s.get('purpose', 'PRIVATE') not in ['PRIVATE', '']:
        continue
    name = s.get('name', 'Unknown')
    region = s.get('region', '').split('/')[-1]
    enabled = s.get('enableFlowLogs', False)
    log_config = s.get('logConfig', {})
    interval = log_config.get('aggregationInterval', 'N/A')
    sampling = log_config.get('flowSampling', 'N/A')
    metadata = log_config.get('metadata', 'N/A')
    has_filter = 'filterExpr' in log_config and bool(log_config.get('filterExpr','').strip())

    fails = []
    if not enabled: fails.append('FlowLogs=off')
    if interval != 'INTERVAL_5_SEC': fails.append(f'Interval={interval}')
    if str(sampling) not in ['1.0', '1']: fails.append(f'Sampling={sampling}')
    if metadata != 'INCLUDE_ALL_METADATA': fails.append(f'Metadata={metadata}')
    if has_filter: fails.append('HasFilter=true')

    if fails:
        issues.append(f'FAIL subnet={name} ({region}): {\" \".join(fails)}')
    else:
        ok.append(f'OK subnet={name} ({region})')

for line in ok: print(line)
for line in issues: print(line)
")

FAIL_COUNT=$(echo "$FLOW_ISSUES" | grep -c "^FAIL" || true)
OK_COUNT=$(echo "$FLOW_ISSUES" | grep -c "^OK" || true)

if [ "$FAIL_COUNT" -eq 0 ] && [ "$OK_COUNT" -gt 0 ]; then
  pass "Tất cả $OK_COUNT subnet đã bật VPC Flow Logs đúng cấu hình CIS"
elif [ "$FAIL_COUNT" -gt 0 ]; then
  fail "Phát hiện subnet chưa đúng cấu hình CIS 3.8:"
  echo "$FLOW_ISSUES" | grep "^FAIL" | sed 's/^FAIL //' | while read line; do info "$line"; done
  if [ "$OK_COUNT" -gt 0 ]; then
    info "Đã pass: $OK_COUNT subnet"
  fi
else
  fail "Không tìm thấy subnet PRIVATE nào"
fi
echo ""

# ----------------------------------------------------------------
# Tổng kết
# ----------------------------------------------------------------
TOTAL=$((PASS+FAIL))
echo "================================================================"
if [ "$FAIL" -eq 0 ]; then
  echo -e "  ${GREEN}KẾT QUẢ: $PASS/$TOTAL PASS — Đạt chuẩn CIS Networking${RESET}"
else
  echo -e "  KẾT QUẢ: ${GREEN}$PASS PASS${RESET} | ${RED}$FAIL FAIL${RESET} (tổng $TOTAL tiêu chí)"
fi
echo "================================================================"
exit $FAIL