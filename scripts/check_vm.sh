#!/bin/bash
# ================================================================
# check_vm.sh
# CIS GCP Benchmark v4.0.0 — Domain 4: Virtual Machines
# Controls: 4.1 / 4.2 / 4.3 / 4.4 / 4.5
# ================================================================
set -uo pipefail

PROJECT_ID=$(gcloud config get-value project 2>/dev/null)
[ -z "$PROJECT_ID" ] && echo "ERROR    Project not configured" && exit 1

PASS=0; FAIL=0

pass() { echo "PASS     $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL     $1"; FAIL=$((FAIL+1)); }
info() { echo "         $1"; }

echo "════════════════════════════════════════════════════════════"
echo " CHECK    [D4] Virtual Machines"
echo " Project: $PROJECT_ID"
echo "════════════════════════════════════════════════════════════"

PROJECT_NUMBER=$(gcloud projects describe "$PROJECT_ID" \
  --format="value(projectNumber)" 2>/dev/null || echo "")
DEFAULT_SA="${PROJECT_NUMBER}-compute@developer.gserviceaccount.com"

INSTANCES_JSON=$(gcloud compute instances list \
  --project="$PROJECT_ID" \
  --format=json 2>/dev/null || echo "[]")

INSTANCE_COUNT=$(echo "$INSTANCES_JSON" | python3 -c "
import json,sys; print(len(json.load(sys.stdin)))
" 2>/dev/null || echo "0")

if [ "$INSTANCE_COUNT" -eq 0 ]; then
  echo "INFO     No compute instances found in project"
  echo "════════════════════════════════════════════════════════════"
  echo " RESULT   [D4] Virtual Machines"
  echo "          Status: N/A (no instances)"
  echo "════════════════════════════════════════════════════════════"
  exit 0
fi

# ── Network topology (informational) ─────────────────────────────
echo "INFO     Network topology:"
echo "$INSTANCES_JSON" | python3 -c "
import json, sys
instances = json.load(sys.stdin)
for i in instances:
    name   = i.get('name','?')
    tags   = i.get('tags',{}).get('items',[])
    ifaces = i.get('networkInterfaces',[])
    has_public = any(len(n.get('accessConfigs',[])) > 0 for n in ifaces)
    subnet = ifaces[0].get('subnetwork','').split('/')[-1] if ifaces else '?'
    role   = 'bastion' if 'bastion-vm' in tags else ('private' if 'private-vm' in tags else 'other')
    ip_str = 'public-ip=yes' if has_public else 'public-ip=no'
    print(f'         vm={name} role={role} subnet={subnet} {ip_str}')
" 2>/dev/null || true
echo ""

# ── CIS 4.1 — No Default SA ──────────────────────────────────────
echo "CHECK    CIS-4.1  no-default-service-account"
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
  pass "CIS-4.1  result=compliant default-sa=absent"
else
  VM_COUNT_FAIL=$(echo "$VMS_DEFAULT_SA" | grep -c . || true)
  fail "CIS-4.1  result=non-compliant vms-with-default-sa=$VM_COUNT_FAIL"
  echo "$VMS_DEFAULT_SA" | while IFS= read -r line; do
    [ -n "$line" ] && info "Resource: vm=$line sa=$DEFAULT_SA"
  done
  info "Action:  Attach least-privilege SA via Ansible group_b.sh"
fi
echo ""

# ── CIS 4.2 — No Default SA with Full Access ─────────────────────
echo "CHECK    CIS-4.2  no-full-access-scope"
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
  pass "CIS-4.2  result=compliant full-access-scope=absent"
else
  VM_COUNT_FAIL=$(echo "$VMS_FULL_ACCESS" | grep -c . || true)
  fail "CIS-4.2  result=non-compliant vms-with-full-scope=$VM_COUNT_FAIL"
  echo "$VMS_FULL_ACCESS" | while IFS= read -r line; do
    [ -n "$line" ] && info "Resource: vm=$line scope=cloud-platform"
  done
  info "Action:  Replace default SA with least-privilege SA via group_b.sh"
fi
echo ""

# ── CIS 4.3 — Block project SSH keys ─────────────────────────────
echo "CHECK    CIS-4.3  block-project-ssh-keys"
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
  pass "CIS-4.3  result=compliant block-project-ssh-keys=true all-vms"
else
  VM_COUNT_FAIL=$(echo "$VMS_NO_BLOCK" | grep -c . || true)
  fail "CIS-4.3  result=non-compliant vms-without-block=$VM_COUNT_FAIL"
  echo "$VMS_NO_BLOCK" | while IFS= read -r line; do
    [ -n "$line" ] && info "Resource: vm=$line block-project-ssh-keys=false"
  done
  info "Action:  gcloud compute instances add-metadata VM --metadata=block-project-ssh-keys=true"
fi
echo ""

# ── CIS 4.4 — OS Login enabled ───────────────────────────────────
echo "CHECK    CIS-4.4  os-login-enabled"
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
  pass "CIS-4.4  result=compliant enable-oslogin=true all-vms"
else
  VM_COUNT_FAIL=$(echo "$VMS_NO_OSLOGIN" | grep -c . || true)
  fail "CIS-4.4  result=non-compliant vms-without-oslogin=$VM_COUNT_FAIL"
  echo "$VMS_NO_OSLOGIN" | while IFS= read -r line; do
    [ -n "$line" ] && info "Resource: vm=$line enable-oslogin=false"
  done
  info "Action:  gcloud compute instances add-metadata VM --metadata=enable-oslogin=true"
fi
echo ""

# ── CIS 4.5 — Serial port disabled ───────────────────────────────
echo "CHECK    CIS-4.5  serial-port-disabled"
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
  pass "CIS-4.5  result=compliant serial-port=disabled all-vms"
else
  VM_COUNT_FAIL=$(echo "$VMS_SERIAL" | grep -c . || true)
  fail "CIS-4.5  result=non-compliant vms-with-serial-port=$VM_COUNT_FAIL"
  echo "$VMS_SERIAL" | while IFS= read -r line; do
    [ -n "$line" ] && info "Resource: vm=$line serial-port-enable=true"
  done
  info "Action:  gcloud compute instances add-metadata VM --metadata=serial-port-enable=false"
fi
echo ""

# ── Bonus: Private VMs without Public IP ─────────────────────────
echo "CHECK    EXTRA    private-vm-no-public-ip"
VMS_PRIVATE_PUBLIC=$(echo "$INSTANCES_JSON" | python3 -c "
import json, sys
instances = json.load(sys.stdin)
found = []
for i in instances:
    tags = i.get('tags',{}).get('items',[])
    if 'private-vm' not in tags: continue
    ifaces = i.get('networkInterfaces',[])
    has_public = any(len(n.get('accessConfigs',[])) > 0 for n in ifaces)
    if has_public: found.append(i.get('name'))
print('\n'.join(found))
" 2>/dev/null || echo "")

if [ -z "$VMS_PRIVATE_PUBLIC" ]; then
  echo "INFO     EXTRA    private-vm-public-ip=absent architecture=correct"
else
  VM_COUNT_FAIL=$(echo "$VMS_PRIVATE_PUBLIC" | grep -c . || true)
  echo "##[warning] EXTRA    private-vms-with-public-ip=$VM_COUNT_FAIL (recommendation: use private-only)"
  echo "$VMS_PRIVATE_PUBLIC" | while IFS= read -r line; do
    [ -n "$line" ] && info "Resource: vm=$line has-public-ip=true"
  done
fi
echo ""

# ── Summary ───────────────────────────────────────────────────────
TOTAL=$((PASS+FAIL))
echo "════════════════════════════════════════════════════════════"
echo " RESULT   [D4] Virtual Machines"
printf "          Passed: %-3s  Failed: %-3s  Total: %s\n" "$PASS" "$FAIL" "$TOTAL"
[ "$FAIL" -eq 0 ] \
  && echo "          Status: COMPLIANT" \
  || echo "          Status: NON-COMPLIANT"
echo "════════════════════════════════════════════════════════════"
exit $FAIL