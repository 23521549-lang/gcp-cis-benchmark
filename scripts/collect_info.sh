#!/bin/bash
# ================================================================
# Phase 0 — Thu thập thông tin hệ thống
# Chạy TRƯỚC mọi workflow để tạo context
# Output: /tmp/context_*.json
# ================================================================
set -uo pipefail

PROJECT_ID=$(gcloud config get-value project 2>/dev/null)
if [ -z "$PROJECT_ID" ]; then
  echo "ERROR: Chưa set project." && exit 1
fi

TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
OUTDIR="${1:-/tmp}"
GREEN="\033[0;32m"; CYAN="\033[0;36m"; RESET="\033[0m"

echo -e "${CYAN}================================================================${RESET}"
echo -e "${CYAN}  Phase 0 — Thu thập thông tin hệ thống${RESET}"
echo -e "${CYAN}  Project: $PROJECT_ID | $(date '+%Y-%m-%d %H:%M:%S')${RESET}"
echo -e "${CYAN}================================================================${RESET}"

# ── 1. Project metadata ──────────────────────────────────────────
echo "[ 1/6 ] Project metadata..."
PROJECT_INFO=$(gcloud projects describe "$PROJECT_ID" --format=json 2>/dev/null || echo '{}')
PROJECT_NUMBER=$(echo "$PROJECT_INFO" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('projectNumber',''))" 2>/dev/null || echo "")

# ── 2. IAM snapshot ──────────────────────────────────────────────
echo "[ 2/6 ] IAM binding snapshot..."
IAM_POLICY=$(gcloud projects get-iam-policy "$PROJECT_ID" --format=json 2>/dev/null || echo '{"bindings":[]}')
IAM_COUNT=$(echo "$IAM_POLICY" | python3 -c "
import json,sys
p=json.load(sys.stdin)
total=sum(len(b.get('members',[])) for b in p.get('bindings',[]))
print(total)
" 2>/dev/null || echo "0")

# ── 3. Resource inventory ────────────────────────────────────────
echo "[ 3/6 ] Resource inventory..."
VM_LIST=$(gcloud compute instances list --project="$PROJECT_ID" \
  --format="json(name,zone,status,serviceAccounts[0].email)" 2>/dev/null || echo '[]')
VM_COUNT=$(echo "$VM_LIST" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")

BUCKET_LIST=$(gsutil ls -p "$PROJECT_ID" 2>/dev/null | sed 's|gs://||;s|/||' || echo "")
BUCKET_COUNT=$(echo "$BUCKET_LIST" | grep -c . 2>/dev/null || echo "0")

SUBNET_LIST=$(gcloud compute networks subnets list --project="$PROJECT_ID" \
  --format="json(name,region,ipCidrRange)" 2>/dev/null || echo '[]')

FW_LIST=$(gcloud compute firewall-rules list --project="$PROJECT_ID" \
  --format="json(name,direction,allowed,sourceRanges,targetTags)" 2>/dev/null || echo '[]')
FW_COUNT=$(echo "$FW_LIST" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")

# ── 4. Cloud SQL instances ───────────────────────────────────────
echo "[ 4/6 ] Cloud SQL instances..."
SQL_LIST=$(gcloud sql instances list --project="$PROJECT_ID" \
  --format="json(name,databaseVersion,state,settings.ipConfiguration,settings.databaseFlags)" \
  2>/dev/null || echo '[]')
SQL_COUNT=$(echo "$SQL_LIST" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")

# ── 5. API services đang bật ──────────────────────────────────────
echo "[ 5/6 ] Enabled API services..."
API_LIST=$(gcloud services list --enabled --project="$PROJECT_ID" \
  --format="value(config.name)" 2>/dev/null | sort || echo "")
API_COUNT=$(echo "$API_LIST" | grep -c . 2>/dev/null || echo "0")

# Kiểm tra các API quan trọng CIS yêu cầu
CLOUDASSET_ON=$(echo "$API_LIST" | grep -c "cloudasset.googleapis.com" || echo "0")
SQLADMIN_ON=$(echo "$API_LIST"  | grep -c "sqladmin.googleapis.com"   || echo "0")
SCC_ON=$(echo "$API_LIST"       | grep -c "securitycenter.googleapis.com" || echo "0")

# ── 6. KMS keyrings ──────────────────────────────────────────────
echo "[ 6/6 ] KMS keyrings..."
REGION="${REGION:-asia-southeast1}"
KMS_LIST=$(gcloud kms keyrings list --location="$REGION" --project="$PROJECT_ID" \
  --format="value(name)" 2>/dev/null || echo "")
KMS_COUNT=$(echo "$KMS_LIST" | grep -c . 2>/dev/null || echo "0")

# ── Xuất context_info.json ───────────────────────────────────────
cat > "$OUTDIR/context_info.json" << JSONEOF
{
  "timestamp": "$TIMESTAMP",
  "project_id": "$PROJECT_ID",
  "project_number": "$PROJECT_NUMBER",
  "region": "$REGION",
  "resources": {
    "vms": $VM_COUNT,
    "buckets": $BUCKET_COUNT,
    "firewall_rules": $FW_COUNT,
    "sql_instances": $SQL_COUNT,
    "kms_keyrings": $KMS_COUNT
  },
  "iam": {
    "total_bindings": $IAM_COUNT
  },
  "api_services": {
    "total_enabled": $API_COUNT,
    "cloudasset_enabled": $CLOUDASSET_ON,
    "sqladmin_enabled": $SQLADMIN_ON,
    "securitycenter_enabled": $SCC_ON
  }
}
JSONEOF

# Lưu IAM snapshot riêng để dùng cho IAM diff
echo "$IAM_POLICY" > "$OUTDIR/iam_snapshot.json"

echo ""
echo -e "${GREEN}[OK]${RESET} context_info.json — VMs:$VM_COUNT Buckets:$BUCKET_COUNT SQL:$SQL_COUNT FW:$FW_COUNT"
echo -e "${GREEN}[OK]${RESET} iam_snapshot.json  — $IAM_COUNT bindings"
echo -e "${GREEN}[OK]${RESET} API: cloudasset=$CLOUDASSET_ON sqladmin=$SQLADMIN_ON scc=$SCC_ON"