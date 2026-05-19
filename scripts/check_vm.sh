#!/bin/bash
# ================================================================
# CIS GCP Benchmark v4.0.0 — Domain 4: Virtual Machines
# CIS 4.1 / 4.2 / 4.3 / 4.4 / 4.5
# Hỗ trợ kiến trúc multi-VM: Bastion + App VM
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
echo "  CIS VIRTUAL MACHINES CHECK — PROJECT: $PROJECT_ID"
echo "================================================================"
echo ""

PROJECT_NUMBER=$(gcloud projects describe "$PROJECT_ID" \
  --format="value(projectNumber)" 2>/dev/null || echo "")
DEFAULT_SA="${PROJECT_NUMBER}-compute@developer.gserviceaccount.com"

INSTANCES_JSON=$(gcloud compute instances list \
  --project="$PROJECT_ID" \
  --format=json 2>/dev/null || echo "[]")

INSTANCE_COUNT=$(echo "$INSTANCES_JSON" | python3 -c "
import json,sys
print(len(json.load(sys.stdin)))
" 2>/dev/null || echo "0")

if [ "$INSTANCE_COUNT" -eq 0 ]; then
  echo -e "${YELLOW}[INFO]${RESET} Không có VM nào trong project"
  echo "================================================================"
  echo -e "  ${GREEN}KẾT QUẢ: Không có VM — bỏ qua domain 4${RESET}"
  echo "================================================================"
  exit 0
fi

# ── Network topology check ────────────────────────────────────────
echo "[ Topology ] Kiểm tra network topology..."
echo "$INSTANCES_JSON" | python3 -c "
import json, sys
instances = json.load(sys.stdin)
for i in instances:
    name   = i.get('name','?')
    tags   = i.get('tags',{}).get('items',[])
    ifaces = i.get('networkInterfaces',[])
    has_public = any(len(n.get('accessConfigs',[])) > 0 for n in ifaces)
    subnet = ifaces[0].get('subnetwork','').split('/')[-1] if ifaces else '?'
    role   = 'bastion' if 'bastion-vm' in tags else ('private' if 'private-vm' in tags else 'unknown')
    ip_str = 'Public IP' if has_public else 'Private only'
    print(f'  {role.upper():8} | {name:30} | {subnet:35} | {ip_str}')
" 2>/dev/null || true
echo ""

# ── CIS 4.1 — VM không dùng Default SA ───────────────────────────
echo "[ 4.1 ] VM không dùng Default Service Account..."
VMS_DEFAULT_SA=$(echo "$INSTANCES_JSON" | python3 -c "
import json, sys
instances = json.load(sys.stdin)
default_sa = '$DEFAULT_SA'
found = [i.get('name') for i in instances
         for sa in i.get('serviceAccounts',[])
         if sa.get('email') == default_sa]
print('\n'.join(found))
" 2>/dev/null || echo "")

if [ -z "$VMS_DEFAULT_SA" ]; then
  pass "4.1 Không có VM nào dùng Default Service Account"
else
  fail "4.1 Phát hiện VM dùng Default SA ($DEFAULT_SA):"
  echo "$VMS_DEFAULT_SA" | while IFS= read -r line; do
    [ -n "$line" ] && info "$line"
  done
fi
echo ""

# ── CIS 4.2 — VM không dùng Default SA với Full Access ───────────
echo "[ 4.2 ] VM không dùng Default SA với Full Access scope..."
VMS_FULL_ACCESS=$(echo "$INSTANCES_JSON" | python3 -c "
import json, sys
instances = json.load(sys.stdin)
default_sa = '$DEFAULT_SA'
found = []
for i in instances:
    for sa in i.get('serviceAccounts',[]):
        if sa.get('email') == default_sa:
            if 'https://www.googleapis.com/auth/cloud-platform' in sa.get('scopes',[]):
                found.append(i.get('name'))
print('\n'.join(found))
" 2>/dev/null || echo "")

if [ -z "$VMS_FULL_ACCESS" ]; then
  pass "4.2 Không có VM nào dùng Default SA với Full Access scope"
else
  fail "4.2 Phát hiện VM dùng Default SA với Full Access:"
  echo "$VMS_FULL_ACCESS" | while IFS= read -r line; do
    [ -n "$line" ] && info "$line"
  done
fi
echo ""

# ── CIS 4.3 — Block project-wide SSH keys ────────────────────────
echo "[ 4.3 ] Block project-wide SSH keys..."
VMS_NO_BLOCK=$(echo "$INSTANCES_JSON" | python3 -c "
import json, sys
instances = json.load(sys.stdin)
found = []
for i in instances:
    meta_items = i.get('metadata',{}).get('items',[])
    meta = {m['key']: m['value'] for m in meta_items}
    val = meta.get('block-project-ssh-keys','false').lower()
    if val not in ['true','1']:
        found.append(i.get('name'))
print('\n'.join(found))
" 2>/dev/null || echo "")

if [ -z "$VMS_NO_BLOCK" ]; then
  pass "4.3 Tất cả VM đã bật block-project-ssh-keys=true"
else
  fail "4.3 Phát hiện VM chưa block project SSH keys:"
  echo "$VMS_NO_BLOCK" | while IFS= read -r line; do
    [ -n "$line" ] && info "$line"
  done
fi
echo ""

# ── CIS 4.4 — OS Login ────────────────────────────────────────────
echo "[ 4.4 ] OS Login bật..."
VMS_NO_OSLOGIN=$(echo "$INSTANCES_JSON" | python3 -c "
import json, sys
instances = json.load(sys.stdin)
found = []
for i in instances:
    meta_items = i.get('metadata',{}).get('items',[])
    meta = {m['key']: m['value'] for m in meta_items}
    val = meta.get('enable-oslogin','false').lower()
    if val not in ['true','1']:
        found.append(i.get('name'))
print('\n'.join(found))
" 2>/dev/null || echo "")

if [ -z "$VMS_NO_OSLOGIN" ]; then
  pass "4.4 Tất cả VM đã bật enable-oslogin=true"
else
  fail "4.4 Phát hiện VM chưa bật OS Login:"
  echo "$VMS_NO_OSLOGIN" | while IFS= read -r line; do
    [ -n "$line" ] && info "$line"
  done
fi
echo ""

# ── CIS 4.5 — Serial port ─────────────────────────────────────────
echo "[ 4.5 ] Serial port không bật..."
VMS_SERIAL=$(echo "$INSTANCES_JSON" | python3 -c "
import json, sys
instances = json.load(sys.stdin)
found = []
for i in instances:
    meta_items = i.get('metadata',{}).get('items',[])
    meta = {m['key']: m['value'] for m in meta_items}
    val = meta.get('serial-port-enable','false').lower()
    if val in ['true','1']:
        found.append(i.get('name'))
print('\n'.join(found))
" 2>/dev/null || echo "")

if [ -z "$VMS_SERIAL" ]; then
  pass "4.5 Không có VM nào bật serial port"
else
  fail "4.5 Phát hiện VM bật serial port:"
  echo "$VMS_SERIAL" | while IFS= read -r line; do
    [ -n "$line" ] && info "$line"
  done
fi
echo ""

# ── Bonus: Private VM không có Public IP ─────────────────────────
echo "[ Bonus ] Kiểm tra Private VMs không có Public IP..."
VMS_PRIVATE_HAS_PUBLIC=$(echo "$INSTANCES_JSON" | python3 -c "
import json, sys
instances = json.load(sys.stdin)
found = []
for i in instances:
    tags = i.get('tags',{}).get('items',[])
    if 'private-vm' not in tags: continue
    ifaces = i.get('networkInterfaces',[])
    has_public = any(len(n.get('accessConfigs',[])) > 0 for n in ifaces)
    if has_public:
        found.append(i.get('name'))
print('\n'.join(found))
" 2>/dev/null || echo "")

if [ -z "$VMS_PRIVATE_HAS_PUBLIC" ]; then
  echo -e "${GREEN}[INFO]${RESET} Tất cả Private VMs không có Public IP — đúng kiến trúc"
else
  echo -e "${YELLOW}[WARN]${RESET} Private VMs đang có Public IP (nên dùng Private only):"
  echo "$VMS_PRIVATE_HAS_PUBLIC" | while IFS= read -r line; do
    [ -n "$line" ] && info "$line"
  done
fi
echo ""

# ── Summary ───────────────────────────────────────────────────────
TOTAL=$((PASS+FAIL))
echo "================================================================"
if [ "$FAIL" -eq 0 ]; then
  echo -e "  ${GREEN}KẾT QUẢ: $PASS/$TOTAL PASS — Đạt chuẩn CIS Virtual Machines${RESET}"
else
  echo -e "  KẾT QUẢ: ${GREEN}$PASS PASS${RESET} | ${RED}$FAIL FAIL${RESET} (tổng $TOTAL tiêu chí)"
fi
echo "================================================================"
exit $FAIL