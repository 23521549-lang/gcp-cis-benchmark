#!/bin/bash
# ================================================================
# group_b.sh
# Group B — Ansible VM Service Account Remediation
# CIS 4.1 + 4.2: Stop VM -> Swap SA -> Start VM
# ================================================================
set -uo pipefail

PROJECT_ID=$(gcloud config get-value project 2>/dev/null)
VM_NAME="${VM_NAME:-benchmark-vm-01}"
VM_ZONE="${VM_ZONE:-asia-southeast1-a}"
ANSIBLE_DIR="${ANSIBLE_DIR:-ansible}"
FAIL_LIST_FILE="${FAIL_LIST_FILE:-/tmp/control_fail_list.json}"
SSH_KEY_FILE="${SSH_KEY_FILE:-/tmp/gcp_key}"

B_FIXED=false

ok()  { echo "OK       $1"; B_FIXED=true; }
err() { echo "ERROR    $1"; }
info(){ echo "INFO     $1"; }

echo "════════════════════════════════════════════════════════════"
echo " GROUP B  Ansible VM Service Account Remediation"
echo " VM     : $VM_NAME | Zone: $VM_ZONE"
echo " Started: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo "════════════════════════════════════════════════════════════"

# ── Check if remediation needed ───────────────────────────────────
NEED_ANSIBLE=false
if [ -f "$FAIL_LIST_FILE" ]; then
  jq -r '.[]' "$FAIL_LIST_FILE" 2>/dev/null | \
    grep -qE "^4\.[12]$" && NEED_ANSIBLE=true || true
else
  NEED_ANSIBLE=true
fi

if [ "$NEED_ANSIBLE" = "false" ]; then
  info "CIS-4.1/4.2 not in fail list — skipping Group B"
  echo "B_FIXED=false" >> "${GITHUB_ENV:-/dev/null}" 2>/dev/null || true
  exit 0
fi

# ── Verify VM exists ──────────────────────────────────────────────
VM_STATUS=$(gcloud compute instances describe "$VM_NAME" \
  --zone="$VM_ZONE" --project="$PROJECT_ID" \
  --format="value(status)" 2>/dev/null || echo "NOT_FOUND")

if [ "$VM_STATUS" = "NOT_FOUND" ]; then
  err "VM not found: vm=$VM_NAME — skipping Ansible"
  echo "B_FIXED=false" >> "${GITHUB_ENV:-/dev/null}" 2>/dev/null || true
  exit 1
fi

info "vm=$VM_NAME status=$VM_STATUS"

# ── Get VM IP ─────────────────────────────────────────────────────
VM_IP=$(gcloud compute instances describe "$VM_NAME" \
  --zone="$VM_ZONE" --project="$PROJECT_ID" \
  --format="value(networkInterfaces[0].accessConfigs[0].natIP)" \
  2>/dev/null || echo "")

if [ -z "$VM_IP" ]; then
  err "No public IP — trying internal IP..."
  VM_IP=$(gcloud compute instances describe "$VM_NAME" \
    --zone="$VM_ZONE" --project="$PROJECT_ID" \
    --format="value(networkInterfaces[0].networkIP)" \
    2>/dev/null || echo "")
fi

if [ -z "$VM_IP" ]; then
  err "No IP available — cannot run Ansible"
  echo "B_FIXED=false" >> "${GITHUB_ENV:-/dev/null}" 2>/dev/null || true
  exit 1
fi

info "vm-ip=$VM_IP"

# ── Update inventory ──────────────────────────────────────────────
sed -i "s/benchmark-vm-01 .*/benchmark-vm-01 ansible_host=$VM_IP/" \
  "$ANSIBLE_DIR/inventory.ini" 2>/dev/null || \
  echo "benchmark-vm-01 ansible_host=$VM_IP" > "$ANSIBLE_DIR/inventory.ini"

# ── Setup SSH key ─────────────────────────────────────────────────
mkdir -p ~/.ssh
if [ -f "$SSH_KEY_FILE" ]; then
  cp "$SSH_KEY_FILE" ~/.ssh/gcp_key
else
  echo "${VM_SSH_KEY:-}" > ~/.ssh/gcp_key
fi
chmod 600 ~/.ssh/gcp_key

if [ ! -s ~/.ssh/gcp_key ]; then
  err "SSH key is empty — cannot run Ansible"
  echo "B_FIXED=false" >> "${GITHUB_ENV:-/dev/null}" 2>/dev/null || true
  exit 1
fi

# ── Run Ansible playbook ──────────────────────────────────────────
info "Running Ansible playbook..."
set +e
ansible-playbook \
  -i "$ANSIBLE_DIR/inventory.ini" \
  "$ANSIBLE_DIR/fix_vm_sa.yml" \
  --private-key=~/.ssh/gcp_key \
  --ssh-extra-args="-o StrictHostKeyChecking=no -o ConnectTimeout=30" \
  -v 2>&1 | tee /tmp/ansible_output.txt
ANSIBLE_EXIT=$?
set -e

if [ $ANSIBLE_EXIT -eq 0 ]; then
  sleep 10
  CURRENT_SA=$(gcloud compute instances describe "$VM_NAME" \
    --zone="$VM_ZONE" --project="$PROJECT_ID" \
    --format="value(serviceAccounts[0].email)" 2>/dev/null || echo "")
  CUSTOM_SA="app-least-privilege-sa@${PROJECT_ID}.iam.gserviceaccount.com"

  if [ "$CURRENT_SA" = "$CUSTOM_SA" ]; then
    ok "CIS-4.1+4.2 SA replaced: vm=$VM_NAME sa=$CUSTOM_SA"
  else
    err "CIS-4.1+4.2 SA mismatch after Ansible: got=$CURRENT_SA expected=$CUSTOM_SA"
    ANSIBLE_EXIT=1
  fi
else
  err "Ansible playbook failed: exit=$ANSIBLE_EXIT"

  VM_STATUS_AFTER=$(gcloud compute instances describe "$VM_NAME" \
    --zone="$VM_ZONE" --project="$PROJECT_ID" \
    --format="value(status)" 2>/dev/null || echo "UNKNOWN")

  if [ "$VM_STATUS_AFTER" = "TERMINATED" ]; then
    info "VM stopped after Ansible failure — restarting..."
    gcloud compute instances start "$VM_NAME" \
      --zone="$VM_ZONE" --project="$PROJECT_ID" --quiet 2>/dev/null \
      && info "VM restarted" \
      || err "Failed to restart VM — manual intervention required"
    echo "ANSIBLE_FAILED=true" >> "${GITHUB_ENV:-/dev/null}" 2>/dev/null || true
  fi
fi

echo ""
echo "════════════════════════════════════════════════════════════"
echo " RESULT   Group B Ansible Remediation"
printf "          Fixed: %s | Ansible exit: %s\n" "$B_FIXED" "$ANSIBLE_EXIT"
echo "════════════════════════════════════════════════════════════"

{
  echo "B_FIXED=$B_FIXED"
  echo "B_ANSIBLE_EXIT=$ANSIBLE_EXIT"
} >> "${GITHUB_ENV:-/dev/null}" 2>/dev/null || true

[ $ANSIBLE_EXIT -eq 0 ] && exit 0 || exit 1