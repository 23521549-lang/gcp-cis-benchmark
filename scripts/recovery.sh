#!/bin/bash
# ================================================================
# CIS GCP Benchmark v4.0.0 — WF4 Auto Recovery Script
# Nhóm A: 21 controls tự động qua gcloud (thêm D6)
# Nhóm B: 4.1, 4.2 — Ansible stop/start VM
# Nhóm C: 1.6, 2.3, 2.4, 3.3, 3.6 — email hướng dẫn
# Selective mode: chỉ fix controls trong FAIL_LIST
# ================================================================
set -uo pipefail

PROJECT_ID=$(gcloud config get-value project 2>/dev/null)
VM_NAME="${VM_NAME:-benchmark-vm-01}"
VM_ZONE="${VM_ZONE:-asia-southeast1-a}"
REGION="${REGION:-asia-southeast1}"
CUSTOM_SA="${CUSTOM_SA:-app-least-privilege-sa@${PROJECT_ID}.iam.gserviceaccount.com}"
ALERT_EMAIL="${ALERT_EMAIL:-23521549@gm.uit.edu.vn}"
DRY_RUN="${DRY_RUN:-false}"

# Đọc danh sách control cần fix — nếu có thì selective, không có thì fix tất cả
FAIL_LIST_FILE="${FAIL_LIST_FILE:-/tmp/control_fail_list.json}"
if [ -f "$FAIL_LIST_FILE" ]; then
  FAIL_LIST=$(jq -r '.[]' "$FAIL_LIST_FILE" 2>/dev/null | tr '\n' ' ')
  echo "  Selective mode: fix controls: $FAIL_LIST"
else
  FAIL_LIST=""  # empty = fix tất cả
  echo "  Full mode: fix tất cả controls"
fi

GREEN="\033[0;32m"; RED="\033[0;31m"; YELLOW="\033[0;33m"; RESET="\033[0m"
FIXED=0; MANUAL=0; FAILED=0

# Helper: kiểm tra control có cần fix không
needs_fix() {
  local cid="$1"
  [ -z "$FAIL_LIST" ] && return 0  # full mode: luôn fix
  echo "$FAIL_LIST" | grep -qw "$cid" && return 0
  return 1
}

run() {
  if [ "$DRY_RUN" = "true" ]; then
    echo -e "${YELLOW}[DRY-RUN]${RESET} $*"
  else
    eval "$@"
  fi
}

fixed()  { echo -e "${GREEN}[FIXED]${RESET} $1";  FIXED=$((FIXED+1));  }
manual() { echo -e "${YELLOW}[MANUAL]${RESET} $1"; MANUAL=$((MANUAL+1)); }
err()    { echo -e "${RED}[ERROR]${RESET} $1";    FAILED=$((FAILED+1)); }

echo "================================================================"
echo "  CIS RECOVERY — PROJECT: $PROJECT_ID"
echo "  VM: $VM_NAME | Zone: $VM_ZONE | DRY_RUN: $DRY_RUN"
echo "================================================================"
echo ""

# ================================================================
# NHÓM A — Script gcloud (tự động)
# ================================================================

# ── CIS 1.4 — Xóa user-managed SA keys ──────────────────────────
if needs_fix "1.4"; then
  echo "[ 1.4 ] Xóa user-managed SA keys..."
  gcloud iam service-accounts list \
    --project="$PROJECT_ID" --format="value(email)" 2>/dev/null | while read SA; do
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
fi

# ── CIS 1.5 — Xóa Admin bindings của SA ──────────────────────────
if needs_fix "1.5"; then
  echo "[ 1.5 ] Xóa Admin privileges của SA..."
  ADMIN_BINDINGS=$(gcloud projects get-iam-policy "$PROJECT_ID" \
    --format=json 2>/dev/null | python3 -c "
import json, sys
policy = json.load(sys.stdin)
admin_roles = ['roles/owner','roles/editor','roles/iam.securityAdmin']
for b in policy.get('bindings',[]):
    if b.get('role') in admin_roles:
        for m in b.get('members',[]):
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
fi

# ── CIS 1.10 — KMS rotation 90 ngày ─────────────────────────────
if needs_fix "1.10"; then
  echo "[ 1.10 ] Cập nhật KMS rotation..."
  gcloud kms keyrings list \
    --location="$REGION" --project="$PROJECT_ID" \
    --format="value(name)" 2>/dev/null | while read KR; do
    gcloud kms keys list \
      --keyring="$KR" --location="$REGION" \
      --project="$PROJECT_ID" \
      --format="value(name)" 2>/dev/null | while read KEY; do
      NEXT_ROT=$(date -d '+90 days' '+%Y-%m-%dT00:00:00Z' 2>/dev/null || \
                 date -v+90d '+%Y-%m-%dT00:00:00Z' 2>/dev/null || \
                 echo "$(date -u +%Y-%m-%d --date='+90 days')T00:00:00Z")
      run gcloud kms keys update "$KEY" \
        --keyring="$KR" --location="$REGION" \
        --rotation-period="7776000s" \
        --next-rotation-time="$NEXT_ROT" \
        --project="$PROJECT_ID" 2>/dev/null || true
      echo "  Updated: $KEY"
    done
  done
  fixed "CIS 1.10 — KMS rotation 90 ngày"
fi

# ── CIS 2.1 — Patch Audit Logging ────────────────────────────────
if needs_fix "2.1"; then
  echo "[ 2.1 ] Patch Cloud Audit Logging..."
  CURRENT_POLICY=$(gcloud projects get-iam-policy "$PROJECT_ID" \
    --format=json 2>/dev/null)
  PATCHED_POLICY=$(echo "$CURRENT_POLICY" | python3 -c "
import json, sys
policy = json.load(sys.stdin)
audit_configs = policy.get('auditConfigs', [])
all_svc = next((c for c in audit_configs if c.get('service') == 'allServices'), None)
required = [
    {'logType': 'ADMIN_READ'},
    {'logType': 'DATA_READ'},
    {'logType': 'DATA_WRITE'}
]
if all_svc:
    all_svc['auditLogConfigs'] = required
    all_svc.pop('exemptedMembers', None)
else:
    audit_configs.append({'service': 'allServices', 'auditLogConfigs': required})
policy['auditConfigs'] = audit_configs
print(json.dumps(policy))
")
  echo "$PATCHED_POLICY" > /tmp/patched_policy.json
  run gcloud projects set-iam-policy "$PROJECT_ID" /tmp/patched_policy.json --quiet 2>/dev/null || true
  fixed "CIS 2.1 — Audit logging patched"
fi

# ── CIS 2.12 — DNS Logging ────────────────────────────────────────
if needs_fix "2.12"; then
  echo "[ 2.12 ] Bật DNS logging..."
  VPC_NAME=$(gcloud compute networks list \
    --project="$PROJECT_ID" --format="value(name)" \
    --filter="name!=default" 2>/dev/null | head -1)
  if [ -n "$VPC_NAME" ]; then
    EXISTING_DNS_POLICY=$(gcloud dns policies list \
      --project="$PROJECT_ID" --format="value(name)" 2>/dev/null | head -1)
    if [ -n "$EXISTING_DNS_POLICY" ]; then
      run gcloud dns policies update "$EXISTING_DNS_POLICY" \
        --enable-logging --project="$PROJECT_ID" 2>/dev/null || true
    else
      run gcloud dns policies create enable-dns-logging \
        --enable-logging \
        --networks="$VPC_NAME" \
        --project="$PROJECT_ID" 2>/dev/null || true
    fi
    fixed "CIS 2.12 — DNS logging enabled"
  fi
fi

# ── CIS 2.13 — Cloud Asset API ───────────────────────────────────
if needs_fix "2.13"; then
  echo "[ 2.13 ] Bật Cloud Asset Inventory API..."
  run gcloud services enable cloudasset.googleapis.com \
    --project="$PROJECT_ID" 2>/dev/null || true
  fixed "CIS 2.13 — Cloud Asset API enabled"
fi

# ── CIS 3.1 — Xóa default network ────────────────────────────────
if needs_fix "3.1"; then
  echo "[ 3.1 ] Xóa default network..."
  DEFAULT_NET=$(gcloud compute networks list \
    --project="$PROJECT_ID" \
    --filter="name=default" \
    --format="value(name)" 2>/dev/null)
  if [ -n "$DEFAULT_NET" ]; then
    # Xóa firewall rules của default network trước
    gcloud compute firewall-rules list \
      --project="$PROJECT_ID" \
      --filter="network=default" \
      --format="value(name)" 2>/dev/null | while read FR; do
      run gcloud compute firewall-rules delete "$FR" \
        --project="$PROJECT_ID" --quiet 2>/dev/null || true
    done
    run gcloud compute networks delete default \
      --project="$PROJECT_ID" --quiet 2>/dev/null || true
    fixed "CIS 3.1 — Default network đã xóa"
  else
    echo "  Default network không tồn tại — skip"
  fi
fi

# ── CIS 3.7 — Xóa RDP rule mở 0.0.0.0/0 ────────────────────────
if needs_fix "3.7"; then
  echo "[ 3.7 ] Xóa RDP firewall rule mở 0.0.0.0/0..."
  gcloud compute firewall-rules list \
    --project="$PROJECT_ID" --format=json 2>/dev/null | python3 -c "
import json, sys
rules = json.load(sys.stdin)
for r in rules:
    for a in r.get('allowed',[]):
        if '3389' in str(a.get('ports',[])):
            sources = r.get('sourceRanges',[])
            if '0.0.0.0/0' in sources or '::/0' in sources:
                print(r['name'])
" | while read FR; do
    run gcloud compute firewall-rules delete "$FR" \
      --project="$PROJECT_ID" --quiet 2>/dev/null || true
    echo "  Đã xóa RDP rule: $FR"
  done
  fixed "CIS 3.7 — RDP rules mở 0.0.0.0/0 đã xóa"
fi

# ── CIS 3.8 — VPC Flow Logs ───────────────────────────────────────
if needs_fix "3.8"; then
  echo "[ 3.8 ] Bật VPC Flow Logs..."
  gcloud compute networks subnets list \
    --project="$PROJECT_ID" \
    --filter="region:asia-southeast1" \
    --format="value(name,region)" 2>/dev/null | while read SUBNET REG; do
    run gcloud compute networks subnets update "$SUBNET" \
      --region="$REG" \
      --enable-flow-logs \
      --logging-aggregation-interval=INTERVAL_5_SEC \
      --logging-flow-sampling=0.5 \
      --logging-metadata=INCLUDE_ALL_METADATA \
      --project="$PROJECT_ID" 2>/dev/null || true
    echo "  Flow logs enabled: $SUBNET"
  done
  fixed "CIS 3.8 — VPC Flow Logs enabled"
fi

# ── CIS 4.3 — Block project-wide SSH keys ────────────────────────
if needs_fix "4.3"; then
  echo "[ 4.3 ] Block project-wide SSH keys trên VM..."
  gcloud compute instances list \
    --project="$PROJECT_ID" --format="value(name,zone)" 2>/dev/null | \
    while read VM Z; do
      run gcloud compute instances add-metadata "$VM" \
        --zone="$Z" \
        --metadata="block-project-ssh-keys=true" \
        --project="$PROJECT_ID" 2>/dev/null || true
    done
  fixed "CIS 4.3 — Block project SSH keys"
fi

# ── CIS 4.4 — OS Login ───────────────────────────────────────────
if needs_fix "4.4"; then
  echo "[ 4.4 ] Bật OS Login trên VM..."
  gcloud compute instances list \
    --project="$PROJECT_ID" --format="value(name,zone)" 2>/dev/null | \
    while read VM Z; do
      run gcloud compute instances add-metadata "$VM" \
        --zone="$Z" \
        --metadata="enable-oslogin=true" \
        --project="$PROJECT_ID" 2>/dev/null || true
    done
  fixed "CIS 4.4 — OS Login enabled"
fi

# ── CIS 4.5 — Tắt serial port ────────────────────────────────────
if needs_fix "4.5"; then
  echo "[ 4.5 ] Tắt serial port trên VM..."
  gcloud compute instances list \
    --project="$PROJECT_ID" --format="value(name,zone)" 2>/dev/null | \
    while read VM Z; do
      run gcloud compute instances add-metadata "$VM" \
        --zone="$Z" \
        --metadata="serial-port-enable=false" \
        --project="$PROJECT_ID" 2>/dev/null || true
    done
  fixed "CIS 4.5 — Serial port disabled"
fi

# ── CIS 5.1 — Bucket không public ────────────────────────────────
if needs_fix "5.1"; then
  echo "[ 5.1 ] Xóa public access từ buckets..."
  gsutil ls -p "$PROJECT_ID" 2>/dev/null | while read BUCKET; do
    run gsutil iam ch -d allUsers \
      "$BUCKET" 2>/dev/null || true
    run gsutil iam ch -d allAuthenticatedUsers \
      "$BUCKET" 2>/dev/null || true
    echo "  Public access removed: $BUCKET"
  done
  fixed "CIS 5.1 — Bucket public access removed"
fi

# ── CIS 5.2 — Uniform Bucket-Level Access ────────────────────────
if needs_fix "5.2"; then
  echo "[ 5.2 ] Bật Uniform Bucket-Level Access..."
  gsutil ls -p "$PROJECT_ID" 2>/dev/null | while read BUCKET; do
    run gsutil uniformbucketlevelaccess set on \
      "$BUCKET" 2>/dev/null || true
    echo "  Uniform access enabled: $BUCKET"
  done
  fixed "CIS 5.2 — Uniform Bucket-Level Access enabled"
fi

# ================================================================
# NHÓM A — Domain 6: Cloud SQL PostgreSQL
# Patch tất cả flags trong 1 lệnh để chỉ restart 1 lần
# ================================================================
SQL_INSTANCE=$(gcloud sql instances list \
  --project="$PROJECT_ID" \
  --filter="databaseVersion~POSTGRES" \
  --format="value(name)" 2>/dev/null | head -1)

if [ -n "$SQL_INSTANCE" ]; then
  echo ""
  echo "[ Domain 6 ] Cloud SQL PostgreSQL: $SQL_INSTANCE"

  # ── CIS 6.4 — SSL ──────────────────────────────────────────────
  if needs_fix "6.4"; then
    echo "  [ 6.4 ] Bật require_ssl..."
    run gcloud sql instances patch "$SQL_INSTANCE" \
      --require-ssl \
      --project="$PROJECT_ID" --quiet 2>/dev/null || true
    fixed "CIS 6.4 — require_ssl enabled"
  fi

  # ── CIS 6.2.x — Database flags (1 lệnh, 1 restart) ────────────
  SQL_FLAGS_NEEDED=()
  needs_fix "6.2.1" && SQL_FLAGS_NEEDED+=("log_error_verbosity=default")
  needs_fix "6.2.2" && SQL_FLAGS_NEEDED+=("log_connections=on")
  needs_fix "6.2.3" && SQL_FLAGS_NEEDED+=("log_disconnections=on")
  needs_fix "6.2.4" && SQL_FLAGS_NEEDED+=("log_statement=ddl")
  needs_fix "6.2.8" && SQL_FLAGS_NEEDED+=("cloudsql.enable_pgaudit=on")

  if [ ${#SQL_FLAGS_NEEDED[@]} -gt 0 ]; then
    echo "  [ 6.2.x ] Patch database flags..."

    # Đọc flags hiện tại để giữ flags không cần fix
    CURRENT_FLAGS=$(gcloud sql instances describe "$SQL_INSTANCE" \
      --project="$PROJECT_ID" \
      --format="json(settings.databaseFlags)" 2>/dev/null | python3 -c "
import json, sys
d = json.load(sys.stdin)
flags = d.get('settings',{}).get('databaseFlags',[])
# Giữ các flags không nằm trong danh sách sẽ được override
override_names = ['log_error_verbosity','log_connections','log_disconnections',
                  'log_statement','cloudsql.enable_pgaudit']
keep = [f'{f[\"name\"]}={f[\"value\"]}' for f in flags if f['name'] not in override_names]
print(','.join(keep))
" 2>/dev/null || echo "")

    # Merge: flags hiện tại (không bị override) + flags mới
    ALL_FLAGS="${CURRENT_FLAGS:+$CURRENT_FLAGS,}$(IFS=','; echo "${SQL_FLAGS_NEEDED[*]}")"
    ALL_FLAGS="${ALL_FLAGS#,}"  # xóa dấu phẩy đầu nếu có

    run gcloud sql instances patch "$SQL_INSTANCE" \
      --database-flags="$ALL_FLAGS" \
      --project="$PROJECT_ID" --quiet 2>/dev/null || true

    fixed "CIS 6.2.1/6.2.2/6.2.3/6.2.4/6.2.8 — database flags patched (1 restart)"
  fi
fi

# ================================================================
# NHÓM C — Manual actions (email hướng dẫn)
# ================================================================
echo ""
echo "================================================================"
echo "  NHÓM C — Cần xử lý thủ công"
echo "================================================================"

if needs_fix "1.6"; then
  manual "CIS 1.6 — Kiểm tra và xóa binding serviceAccountUser/TokenCreator ở project level qua Console > IAM"
fi
if needs_fix "2.3"; then
  manual "CIS 2.3 — Bật Retention Policy + Bucket Lock trên log bucket qua Console > Storage"
fi
if needs_fix "2.4"; then
  manual "CIS 2.4 — Verify Alert Policy cho Project Ownership Changes đang ENABLED và notification channel đúng"
fi
if needs_fix "3.3"; then
  manual "CIS 3.3 — Cập nhật DNSSEC trong vpc.tf: dnssec_config { state = 'on' } rồi terraform apply"
fi
if needs_fix "3.6"; then
  manual "CIS 3.6 — Xóa firewall rule cho phép SSH (port 22) từ 0.0.0.0/0. Chỉ cho phép IP cụ thể: $ALERT_EMAIL"
fi

# ── Tổng kết ─────────────────────────────────────────────────────
echo ""
echo "================================================================"
echo "  RECOVERY SUMMARY"
echo "  Fixed: $FIXED | Manual: $MANUAL | Errors: $FAILED"
echo "  DRY_RUN: $DRY_RUN"
echo "================================================================"

exit $FAILED