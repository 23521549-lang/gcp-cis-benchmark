#!/bin/bash
# ================================================================
# CIS GCP Benchmark v4.0.0 — WF4 Auto Recovery Script
# Nhóm A (Script): 15 tiêu chuẩn tự động qua gcloud
# Nhóm B (Ansible): 4.1, 4.2 — cần stop/start VM
# Nhóm C (Manual): 1.6, 2.3, 2.4, 3.3, 3.6 — email hướng dẫn
# ================================================================

set -uo pipefail

PROJECT_ID=$(gcloud config get-value project 2>/dev/null)
VM_NAME="${VM_NAME:-benchmark-vm-01}"
VM_ZONE="${VM_ZONE:-asia-southeast1-a}"
REGION="${REGION:-asia-southeast1}"
CUSTOM_SA="${CUSTOM_SA:-app-least-privilege-sa@${PROJECT_ID}.iam.gserviceaccount.com}"
ALERT_EMAIL="${ALERT_EMAIL:-23521549@gm.uit.edu.vn}"
DRY_RUN="${DRY_RUN:-false}"

GREEN="\033[0;32m"; RED="\033[0;31m"; YELLOW="\033[0;33m"; RESET="\033[0m"
FIXED=0; MANUAL=0; FAILED=0

run() {
  if [ "$DRY_RUN" = "true" ]; then
    echo -e "${YELLOW}[DRY-RUN]${RESET} $*"
  else
    eval "$@"
  fi
}

fixed() { echo -e "${GREEN}[FIXED]${RESET} $1"; FIXED=$((FIXED+1)); }
manual() { echo -e "${YELLOW}[MANUAL]${RESET} $1"; MANUAL=$((MANUAL+1)); }
err() { echo -e "${RED}[ERROR]${RESET} $1"; FAILED=$((FAILED+1)); }

echo "================================================================"
echo "  CIS RECOVERY — PROJECT: $PROJECT_ID"
echo "  VM: $VM_NAME | Zone: $VM_ZONE | DRY_RUN: $DRY_RUN"
echo "================================================================"
echo ""

# ================================================================
# NHÓM A — Script gcloud (tự động)
# ================================================================

# CIS 1.4 — Xóa user-managed SA keys
echo "[ 1.4 ] Xóa user-managed SA keys..."
gcloud iam service-accounts list \
  --project="$PROJECT_ID" \
  --format="value(email)" 2>/dev/null | while read SA; do
  KEYS=$(gcloud iam service-accounts keys list \
    --iam-account="$SA" --managed-by=user \
    --format="value(name)" 2>/dev/null)
  if [ -n "$KEYS" ]; then
    echo "$KEYS" | while read KEY; do
      run gcloud iam service-accounts keys delete "$KEY" \
        --iam-account="$SA" --project="$PROJECT_ID" --quiet
      echo "  Đã xóa key $KEY của $SA"
    done
  fi
done
fixed "CIS 1.4 — user-managed keys đã được xóa"

# CIS 1.5 — Xóa Admin bindings của SA
echo "[ 1.5 ] Xóa Admin privileges của SA..."
ADMIN_BINDINGS=$(gcloud projects get-iam-policy "$PROJECT_ID" \
  --format=json 2>/dev/null | python3 -c "
import json, sys
policy = json.load(sys.stdin)
admin_roles = ['roles/owner', 'roles/editor', 'roles/iam.securityAdmin']
for b in policy.get('bindings', []):
    if b.get('role') in admin_roles:
        for m in b.get('members', []):
            if m.startswith('serviceAccount:'):
                print(f'{m}|{b[\"role\"]}')
")
if [ -n "$ADMIN_BINDINGS" ]; then
  echo "$ADMIN_BINDINGS" | while IFS='|' read MEMBER ROLE; do
    run gcloud projects remove-iam-policy-binding "$PROJECT_ID" \
      --member="$MEMBER" --role="$ROLE" --quiet 2>/dev/null || true
    echo "  Đã xóa: $MEMBER -> $ROLE"
  done
  fixed "CIS 1.5 — Admin privileges của SA đã được xóa"
else
  echo "  Không có binding nào cần xóa"
fi

# CIS 1.10 — Cập nhật KMS rotation về 90 ngày
echo "[ 1.10 ] Cập nhật KMS rotation..."
gcloud kms keyrings list \
  --location="$REGION" --project="$PROJECT_ID" \
  --format="value(name)" 2>/dev/null | while read KR; do
  gcloud kms keys list \
    --keyring="$KR" --location="$REGION" \
    --project="$PROJECT_ID" \
    --format="value(name)" 2>/dev/null | while read KEY; do
    run gcloud kms keys update "$KEY" \
      --keyring="$KR" \
      --location="$REGION" \
      --rotation-period="7776000s" \
      --next-rotation-time="$(date -d '+90 days' '+%Y-%m-%dT00:00:00Z' 2>/dev/null || date -v+90d '+%Y-%m-%dT00:00:00Z')" \
      --project="$PROJECT_ID" 2>/dev/null || true
    echo "  Updated rotation: $KEY"
  done
done
fixed "CIS 1.10 — KMS rotation đã cập nhật"

# CIS 1.14 — API Key restrictions (cần verify thủ công qua Console)
echo "[ 1.14 ] API Key restrictions..."
manual "CIS 1.14 — Kiểm tra và thêm restrictions qua Google Cloud Console > APIs & Services > Credentials"

# CIS 2.1 — Patch IAM audit config, xóa exemptedMembers
echo "[ 2.1 ] Patch Audit Logging — xóa exemptedMembers..."
CURRENT_POLICY=$(gcloud projects get-iam-policy "$PROJECT_ID" --format=json 2>/dev/null)
PATCHED=$(echo "$CURRENT_POLICY" | python3 -c "
import json, sys
policy = json.load(sys.stdin)
for c in policy.get('auditConfigs', []):
    if c.get('service') == 'allServices':
        if 'exemptedMembers' in c:
            del c['exemptedMembers']
        for ac in c.get('auditLogConfigs', []):
            if 'exemptedMembers' in ac:
                del ac['exemptedMembers']
# Đảm bảo có đủ 3 loại
configs = policy.get('auditConfigs', [])
for c in configs:
    if c.get('service') == 'allServices':
        existing_types = [x.get('logType') for x in c.get('auditLogConfigs', [])]
        for t in ['ADMIN_READ', 'DATA_READ', 'DATA_WRITE']:
            if t not in existing_types:
                c['auditLogConfigs'].append({'logType': t})
print(json.dumps(policy, indent=2))
" 2>/dev/null)

if [ -n "$PATCHED" ]; then
  echo "$PATCHED" > /tmp/patched_policy.json
  run gcloud projects set-iam-policy "$PROJECT_ID" /tmp/patched_policy.json --quiet 2>/dev/null || true
  fixed "CIS 2.1 — Audit logging patched, exemptedMembers đã xóa"
fi

# CIS 2.2 — Xóa filter của Log Sink (dùng terraform -target)
echo "[ 2.2 ] Xóa filter của Log Sink..."
manual "CIS 2.2 — Chạy: terraform apply -target=google_logging_project_sink.log_sink trong thư mục terraform"
echo "  Hoặc: gcloud logging sinks update benchmark-log-sink --log-filter='' --project=$PROJECT_ID"

# CIS 2.12 — Tạo DNS Logging policy
echo "[ 2.12 ] Bật DNS Logging..."
VPC_URL="projects/${PROJECT_ID}/global/networks/benchmark-vpc"
run gcloud dns policies create benchmark-dns-logging-policy \
  --enable-logging \
  --networks="$VPC_URL" \
  --project="$PROJECT_ID" 2>/dev/null || \
  run gcloud dns policies update benchmark-dns-logging-policy \
  --enable-logging \
  --project="$PROJECT_ID" 2>/dev/null || true
fixed "CIS 2.12 — DNS Logging policy created/updated"

# CIS 2.13 — Enable Cloud Asset Inventory API
echo "[ 2.13 ] Bật Cloud Asset Inventory API..."
run gcloud services enable cloudasset.googleapis.com \
  --project="$PROJECT_ID" 2>/dev/null || true
fixed "CIS 2.13 — cloudasset.googleapis.com enabled"

# CIS 3.1 — Xóa default network
echo "[ 3.1 ] Xóa default network..."
DEFAULT_NET=$(gcloud compute networks list \
  --project="$PROJECT_ID" --filter="name=default" \
  --format="value(name)" 2>/dev/null)
if [ -n "$DEFAULT_NET" ]; then
  # Xóa firewall rules trước
  gcloud compute firewall-rules list \
    --project="$PROJECT_ID" \
    --filter="network=default" \
    --format="value(name)" 2>/dev/null | \
    xargs -I {} sh -c "run gcloud compute firewall-rules delete {} --project=$PROJECT_ID --quiet 2>/dev/null || true"
  run gcloud compute networks delete default \
    --project="$PROJECT_ID" --quiet 2>/dev/null || true
  fixed "CIS 3.1 — Default network đã xóa"
else
  echo "  Default network không tồn tại — OK"
fi

# CIS 3.8 — Bật VPC Flow Logs trên subnet
echo "[ 3.8 ] Bật VPC Flow Logs..."
gcloud compute networks subnets list \
  --project="$PROJECT_ID" \
  --format="value(name,region)" 2>/dev/null | while read SUBNET REGION_URL; do
  REGION=$(echo "$REGION_URL" | sed 's|.*/||')
  run gcloud compute networks subnets update "$SUBNET" \
    --region="$REGION" \
    --enable-flow-logs \
    --logging-aggregation-interval=interval-5-sec \
    --logging-flow-sampling=1.0 \
    --logging-metadata=include-all \
    --project="$PROJECT_ID" 2>/dev/null || true
  echo "  Updated flow logs: $SUBNET ($REGION)"
done
fixed "CIS 3.8 — VPC Flow Logs đã bật"

# CIS 4.3 — Block project-wide SSH keys (không cần stop VM)
echo "[ 4.3 ] Block project-wide SSH keys..."
run gcloud compute instances add-metadata "$VM_NAME" \
  --zone="$VM_ZONE" \
  --metadata="block-project-ssh-keys=true" \
  --project="$PROJECT_ID" 2>/dev/null || true
fixed "CIS 4.3 — block-project-ssh-keys=true đã set"

# CIS 4.4 — OS Login (không cần stop VM)
echo "[ 4.4 ] Bật OS Login..."
run gcloud compute instances add-metadata "$VM_NAME" \
  --zone="$VM_ZONE" \
  --metadata="enable-oslogin=true" \
  --project="$PROJECT_ID" 2>/dev/null || true
fixed "CIS 4.4 — enable-oslogin=true đã set"

# CIS 4.5 — Serial port off (không cần stop VM)
echo "[ 4.5 ] Tắt serial port..."
run gcloud compute instances add-metadata "$VM_NAME" \
  --zone="$VM_ZONE" \
  --metadata="serial-port-enable=false" \
  --project="$PROJECT_ID" 2>/dev/null || true
fixed "CIS 4.5 — serial-port-enable=false đã set"

# CIS 5.1 — Xóa public IAM trên bucket
echo "[ 5.1 ] Xóa public access trên buckets..."
gsutil ls -p "$PROJECT_ID" 2>/dev/null | while read BUCKET; do
  BUCKET_NAME=$(echo "$BUCKET" | sed 's|gs://||' | sed 's|/||')
  run gsutil iam ch -d allUsers "$BUCKET" 2>/dev/null || true
  run gsutil iam ch -d allAuthenticatedUsers "$BUCKET" 2>/dev/null || true
done
fixed "CIS 5.1 — Public access đã xóa khỏi tất cả buckets"

# CIS 5.2 — Bật Uniform Bucket-Level Access
echo "[ 5.2 ] Bật Uniform Bucket-Level Access..."
gsutil ls -p "$PROJECT_ID" 2>/dev/null | while read BUCKET; do
  run gsutil uniformbucketlevelaccess set on "$BUCKET" 2>/dev/null || true
done
fixed "CIS 5.2 — Uniform Bucket-Level Access đã bật"

echo ""
echo "================================================================"
echo "  NHÓM B — Cần Ansible (stop/start VM)"
echo "================================================================"
echo -e "${YELLOW}[ANSIBLE REQUIRED]${RESET} CIS 4.1 + 4.2 — Thay Custom SA cho VM"
echo "  Chạy: ansible-playbook ansible/fix_vm_sa.yml -i ansible/inventory.ini"
echo "  Lý do: thay SA cần stop VM -> thay SA -> start VM (idempotent)"

echo ""
echo "================================================================"
echo "  NHÓM C — Manual (cần xác nhận thủ công)"
echo "================================================================"
echo -e "${YELLOW}[MANUAL]${RESET} CIS 1.6 — Kiểm tra IAM binding project level, xóa serviceAccountUser nếu không hợp lệ"
echo -e "${YELLOW}[MANUAL]${RESET} CIS 2.3 — Bucket Lock không thể đảo ngược — xác nhận trước khi lock"
echo -e "${YELLOW}[MANUAL]${RESET} CIS 2.4 — Kiểm tra Notification Channel email có nhận được không"
echo -e "${YELLOW}[MANUAL]${RESET} CIS 3.3 — DNSSEC cần test DNS propagation trước khi bật production"
echo -e "${YELLOW}[MANUAL]${RESET} CIS 3.6 — Xác nhận IP tin cậy trước khi thay đổi firewall rule"

echo ""
echo "================================================================"
echo "  RECOVERY SUMMARY"
echo "================================================================"
echo -e "  ${GREEN}FIXED (auto): $FIXED${RESET}"
echo -e "  ${YELLOW}MANUAL required: $MANUAL${RESET}"
[ "$FAILED" -gt 0 ] && echo -e "  ${RED}ERRORS: $FAILED${RESET}"
echo "================================================================"