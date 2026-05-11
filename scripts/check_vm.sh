#!/bin/bash
# ================================================================
# CIS GCP Benchmark v4.0.0 — Domain 4: Virtual Machines
# CIS 4.1 — VM không dùng Default SA
# CIS 4.2 — VM không dùng Default SA với Full Access scope
# CIS 4.3 — Block project-wide SSH keys
# CIS 4.4 — OS Login bật
# CIS 4.5 — Serial port không bật
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
echo "  CIS VIRTUAL MACHINES CHECK — PROJECT: $PROJECT_ID"
echo "================================================================"
echo ""

PROJECT_NUMBER=$(gcloud projects describe "$PROJECT_ID" \
  --format="value(projectNumber)" 2>/dev/null)
DEFAULT_SA="${PROJECT_NUMBER}-compute@developer.gserviceaccount.com"

# ----------------------------------------------------------------
# CIS 4.1 — VM không dùng Default SA
# ----------------------------------------------------------------
echo "[ 4.1 ] VM không dùng Default Service Account..."
VMS_WITH_DEFAULT_SA=$(gcloud compute instances list \
  --project="$PROJECT_ID" \
  --format=json 2>/dev/null | python3 -c "
import json, sys
instances = json.load(sys.stdin)
default_sa = '${DEFAULT_SA}'
found = []
for i in instances:
    for sa in i.get('serviceAccounts', []):
        if sa.get('email') == default_sa:
            found.append(i.get('name'))
print('\n'.join(found))
")

if [ -z "$VMS_WITH_DEFAULT_SA" ]; then
  pass "Không có VM nào dùng Default Service Account"
else
  fail "Phát hiện VM dùng Default SA ($DEFAULT_SA):"
  echo "$VMS_WITH_DEFAULT_SA" | while read line; do info "$line"; done
  info "Sửa: gán Custom SA trong vm.tf (CIS 4.1) — cần Ansible để stop/start VM"
fi
echo ""

# ----------------------------------------------------------------
# CIS 4.2 — VM không dùng Default SA với Full Access scope
# ----------------------------------------------------------------
echo "[ 4.2 ] VM không dùng Default SA với Full Access scope..."
VMS_FULL_ACCESS=$(gcloud compute instances list \
  --project="$PROJECT_ID" \
  --format=json 2>/dev/null | python3 -c "
import json, sys
instances = json.load(sys.stdin)
default_sa = '${DEFAULT_SA}'
found = []
for i in instances:
    for sa in i.get('serviceAccounts', []):
        if sa.get('email') == default_sa:
            scopes = sa.get('scopes', [])
            if 'https://www.googleapis.com/auth/cloud-platform' in scopes:
                found.append(i.get('name'))
print('\n'.join(found))
")

if [ -z "$VMS_FULL_ACCESS" ]; then
  pass "Không có VM nào dùng Default SA với Full Access scope"
else
  fail "Phát hiện VM dùng Default SA với Full Access scope:"
  echo "$VMS_FULL_ACCESS" | while read line; do info "$line"; done
  info "Sửa: đi kèm với 4.1 — dùng Ansible để thay SA"
fi
echo ""

# ----------------------------------------------------------------
# CIS 4.3 — Block project-wide SSH keys
# ----------------------------------------------------------------
echo "[ 4.3 ] Block project-wide SSH keys..."
VMS_NO_BLOCK=$(gcloud compute instances list \
  --project="$PROJECT_ID" \
  --format=json 2>/dev/null | python3 -c "
import json, sys
instances = json.load(sys.stdin)
found = []
for i in instances:
    metadata = i.get('metadata', {})
    items = {m['key']: m['value'] for m in metadata.get('items', [])}
    val = items.get('block-project-ssh-keys', 'false').lower()
    if val != 'true':
        found.append(f'{i[\"name\"]} (block-project-ssh-keys={val})')
print('\n'.join(found))
")

if [ -z "$VMS_NO_BLOCK" ]; then
  pass "Tất cả VM đã bật block-project-ssh-keys=true"
else
  fail "Phát hiện VM chưa block project-wide SSH keys:"
  echo "$VMS_NO_BLOCK" | while read line; do info "$line"; done
  info "Sửa: gcloud compute instances add-metadata VM --metadata=block-project-ssh-keys=true"
fi
echo ""

# ----------------------------------------------------------------
# CIS 4.4 — OS Login bật
# ----------------------------------------------------------------
echo "[ 4.4 ] OS Login bật..."
VMS_NO_OSLOGIN=$(gcloud compute instances list \
  --project="$PROJECT_ID" \
  --format=json 2>/dev/null | python3 -c "
import json, sys
instances = json.load(sys.stdin)
found = []
for i in instances:
    metadata = i.get('metadata', {})
    items = {m['key']: m['value'] for m in metadata.get('items', [])}
    val = items.get('enable-oslogin', 'false').lower()
    if val != 'true':
        found.append(f'{i[\"name\"]} (enable-oslogin={val})')
print('\n'.join(found))
")

if [ -z "$VMS_NO_OSLOGIN" ]; then
  pass "Tất cả VM đã bật enable-oslogin=true"
else
  fail "Phát hiện VM chưa bật OS Login:"
  echo "$VMS_NO_OSLOGIN" | while read line; do info "$line"; done
  info "Sửa: gcloud compute instances add-metadata VM --metadata=enable-oslogin=true"
fi
echo ""

# ----------------------------------------------------------------
# CIS 4.5 — Serial port không bật
# ----------------------------------------------------------------
echo "[ 4.5 ] Serial port không bật..."
VMS_SERIAL=$(gcloud compute instances list \
  --project="$PROJECT_ID" \
  --format=json 2>/dev/null | python3 -c "
import json, sys
instances = json.load(sys.stdin)
found = []
for i in instances:
    metadata = i.get('metadata', {})
    items = {m['key']: m['value'] for m in metadata.get('items', [])}
    val = items.get('serial-port-enable', '0').lower()
    if val in ['1', 'true']:
        found.append(i.get('name'))
print('\n'.join(found))
")

if [ -z "$VMS_SERIAL" ]; then
  pass "Không có VM nào bật serial port"
else
  fail "Phát hiện VM đang bật serial port:"
  echo "$VMS_SERIAL" | while read line; do info "$line"; done
  info "Sửa: gcloud compute instances add-metadata VM --metadata=serial-port-enable=false"
fi
echo ""

# ----------------------------------------------------------------
# Tổng kết
# ----------------------------------------------------------------
TOTAL=$((PASS+FAIL))
echo "================================================================"
if [ "$FAIL" -eq 0 ]; then
  echo -e "  ${GREEN}KẾT QUẢ: $PASS/$TOTAL PASS — Đạt chuẩn CIS Virtual Machines${RESET}"
else
  echo -e "  KẾT QUẢ: ${GREEN}$PASS PASS${RESET} | ${RED}$FAIL FAIL${RESET} (tổng $TOTAL tiêu chí)"
fi
echo "================================================================"
exit $FAIL