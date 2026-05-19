#!/bin/bash
# ================================================================
# Nhóm B — CIS 4.1 + 4.2: Ansible stop/start VM
# Tách từ WF4 ra script độc lập
# ================================================================
set -uo pipefail

PROJECT_ID=$(gcloud config get-value project 2>/dev/null)
VM_NAME="${VM_NAME:-benchmark-vm-01}"
VM_ZONE="${VM_ZONE:-asia-southeast1-a}"
ANSIBLE_DIR="${ANSIBLE_DIR:-ansible}"
FAIL_LIST_FILE="${FAIL_LIST_FILE:-/tmp/control_fail_list.json}"
SSH_KEY_FILE="${SSH_KEY_FILE:-/tmp/gcp_key}"

GREEN="\033[0;32m"; RED="\033[0;31m"; YELLOW="\033[0;33m"; RESET="\033[0m"
B_FIXED=false

fixed() { echo -e "${GREEN}[FIXED]${RESET} $1"; B_FIXED=true; }
err()   { echo -e "${RED}[ERROR]${RESET} $1"; }

echo "================================================================"
echo "  NHÓM B — Ansible VM Service Account (CIS 4.1 + 4.2)"
echo "  VM: $VM_NAME | Zone: $VM_ZONE"
echo "================================================================"
echo ""

# Kiểm tra có cần chạy không
NEED_ANSIBLE=false
if [ -f "$FAIL_LIST_FILE" ]; then
  jq -r '.[]' "$FAIL_LIST_FILE" 2>/dev/null | \
    grep -qE "^4\.[12]$" && NEED_ANSIBLE=true || true
else
  NEED_ANSIBLE=true  # full mode
fi

if [ "$NEED_ANSIBLE" = "false" ]; then
  echo "CIS 4.1/4.2 không trong fail list — skip Nhóm B"
  echo "B_FIXED=false" >> "${GITHUB_ENV:-/dev/null}" 2>/dev/null || true
  exit 0
fi

# Kiểm tra VM có tồn tại không
VM_STATUS=$(gcloud compute instances describe "$VM_NAME" \
  --zone="$VM_ZONE" --project="$PROJECT_ID" \
  --format="value(status)" 2>/dev/null || echo "NOT_FOUND")

if [ "$VM_STATUS" = "NOT_FOUND" ]; then
  err "VM $VM_NAME không tồn tại — skip Ansible"
  echo "B_FIXED=false" >> "${GITHUB_ENV:-/dev/null}" 2>/dev/null || true
  exit 1
fi

echo "  VM status: $VM_STATUS"

# Lấy VM IP
VM_IP=$(gcloud compute instances describe "$VM_NAME" \
  --zone="$VM_ZONE" \
  --project="$PROJECT_ID" \
  --format="value(networkInterfaces[0].accessConfigs[0].natIP)" \
  2>/dev/null || echo "")

if [ -z "$VM_IP" ]; then
  err "Không lấy được VM IP — không chạy được Ansible"
  echo "  Thử dùng internal IP..."
  VM_IP=$(gcloud compute instances describe "$VM_NAME" \
    --zone="$VM_ZONE" --project="$PROJECT_ID" \
    --format="value(networkInterfaces[0].networkIP)" \
    2>/dev/null || echo "")
fi

if [ -z "$VM_IP" ]; then
  err "Không có IP nào — skip Ansible"
  echo "B_FIXED=false" >> "${GITHUB_ENV:-/dev/null}" 2>/dev/null || true
  exit 1
fi

echo "  VM IP: $VM_IP"

# Cập nhật inventory
sed -i "s/benchmark-vm-01 .*/benchmark-vm-01 ansible_host=$VM_IP/" \
  "$ANSIBLE_DIR/inventory.ini" 2>/dev/null || \
  echo "benchmark-vm-01 ansible_host=$VM_IP" > "$ANSIBLE_DIR/inventory.ini"

# Setup SSH key
mkdir -p ~/.ssh
if [ -f "$SSH_KEY_FILE" ]; then
  cp "$SSH_KEY_FILE" ~/.ssh/gcp_key
else
  echo "${VM_SSH_KEY:-}" > ~/.ssh/gcp_key
fi
chmod 600 ~/.ssh/gcp_key

# Verify SSH key không rỗng
if [ ! -s ~/.ssh/gcp_key ]; then
  err "SSH key rỗng — không chạy được Ansible"
  echo "B_FIXED=false" >> "${GITHUB_ENV:-/dev/null}" 2>/dev/null || true
  exit 1
fi

# Chạy Ansible playbook
echo "  Chạy Ansible playbook..."
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
  # Verify SA đã đổi
  sleep 10
  CURRENT_SA=$(gcloud compute instances describe "$VM_NAME" \
    --zone="$VM_ZONE" --project="$PROJECT_ID" \
    --format="value(serviceAccounts[0].email)" 2>/dev/null || echo "")
  CUSTOM_SA="app-least-privilege-sa@${PROJECT_ID}.iam.gserviceaccount.com"

  if [ "$CURRENT_SA" = "$CUSTOM_SA" ]; then
    fixed "CIS 4.1 + 4.2 — SA đã đổi sang: $CUSTOM_SA"
  else
    err "SA sau Ansible: $CURRENT_SA (expected: $CUSTOM_SA)"
    ANSIBLE_EXIT=1
  fi
else
  err "Ansible playbook thất bại (exit: $ANSIBLE_EXIT)"

  # Kiểm tra VM có bị stuck TERMINATED không
  VM_STATUS_AFTER=$(gcloud compute instances describe "$VM_NAME" \
    --zone="$VM_ZONE" --project="$PROJECT_ID" \
    --format="value(status)" 2>/dev/null || echo "UNKNOWN")

  if [ "$VM_STATUS_AFTER" = "TERMINATED" ]; then
    echo "  VM bị stopped sau Ansible fail — đang start lại..."
    gcloud compute instances start "$VM_NAME" \
      --zone="$VM_ZONE" --project="$PROJECT_ID" --quiet 2>/dev/null \
      && echo "  VM đã start lại" \
      || err "Không start được VM — cần xử lý thủ công"
    echo "ANSIBLE_FAILED=true" >> "${GITHUB_ENV:-/dev/null}" 2>/dev/null || true
  fi
fi

echo ""
echo "================================================================"
echo "  Nhóm B Summary"
echo "  B_FIXED: $B_FIXED | Ansible exit: $ANSIBLE_EXIT"
echo "================================================================"

echo "B_FIXED=$B_FIXED"         >> "${GITHUB_ENV:-/dev/null}" 2>/dev/null || true
echo "B_ANSIBLE_EXIT=$ANSIBLE_EXIT" >> "${GITHUB_ENV:-/dev/null}" 2>/dev/null || true

[ $ANSIBLE_EXIT -eq 0 ] && exit 0 || exit 1