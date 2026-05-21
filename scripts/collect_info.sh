#!/bin/bash
# ================================================================
# collect_info.sh
# Phase 0 — System Information Collection
# Outputs: /tmp/context_info.json, /tmp/iam_snapshot.json
# ================================================================
set -uo pipefail

PROJECT_ID=$(gcloud config get-value project 2>/dev/null)
if [ -z "$PROJECT_ID" ]; then
  echo "ERROR    Project not configured — run: gcloud config set project PROJECT_ID"
  exit 1
fi

TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
OUTDIR="${1:-/tmp}"
REGION="${REGION:-asia-southeast1}"

echo "════════════════════════════════════════════════════════════"
echo " COLLECT  System Information Collection"
echo " Project: $PROJECT_ID | $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo "════════════════════════════════════════════════════════════"

# ── 1. Project metadata ──────────────────────────────────────────
echo "INFO     [1/6] Collecting project metadata..."
PROJECT_INFO=$(gcloud projects describe "$PROJECT_ID" --format=json 2>/dev/null || echo '{}')
PROJECT_NUMBER=$(echo "$PROJECT_INFO" | python3 -c "
import json,sys
d=json.load(sys.stdin)
print(d.get('projectNumber',''))
" 2>/dev/null || echo "")

# ── 2. IAM snapshot ──────────────────────────────────────────────
echo "INFO     [2/6] Collecting IAM binding snapshot..."
IAM_POLICY=$(gcloud projects get-iam-policy "$PROJECT_ID" \
  --format=json 2>/dev/null || echo '{"bindings":[]}')
IAM_COUNT=$(echo "$IAM_POLICY" | python3 -c "
import json,sys
p=json.load(sys.stdin)
print(sum(len(b.get('members',[])) for b in p.get('bindings',[])))
" 2>/dev/null || echo "0")

# ── 3. Resource inventory ────────────────────────────────────────
echo "INFO     [3/6] Collecting resource inventory..."
VM_LIST=$(gcloud compute instances list \
  --project="$PROJECT_ID" \
  --format="json(name,zone,status,tags.items,networkInterfaces[0].subnetwork,networkInterfaces[0].accessConfigs)" \
  2>/dev/null || echo '[]')

VM_COUNT=$(echo "$VM_LIST" | python3 -c "
import json,sys; print(len(json.load(sys.stdin)))
" 2>/dev/null || echo "0")

BASTION_COUNT=$(echo "$VM_LIST" | python3 -c "
import json,sys
vms=json.load(sys.stdin)
print(sum(1 for v in vms if 'bastion-vm' in v.get('tags',{}).get('items',[])))
" 2>/dev/null || echo "0")

PRIVATE_VM_COUNT=$(echo "$VM_LIST" | python3 -c "
import json,sys
vms=json.load(sys.stdin)
print(sum(1 for v in vms if 'private-vm' in v.get('tags',{}).get('items',[])))
" 2>/dev/null || echo "0")

BUCKET_LIST=$(gsutil ls -p "$PROJECT_ID" 2>/dev/null | \
  sed 's|gs://||;s|/||' || echo "")
BUCKET_COUNT=$(echo "$BUCKET_LIST" | grep -c . 2>/dev/null || echo "0")

FW_LIST=$(gcloud compute firewall-rules list \
  --project="$PROJECT_ID" \
  --format="json(name,direction,allowed,sourceRanges,targetTags)" \
  2>/dev/null || echo '[]')
FW_COUNT=$(echo "$FW_LIST" | python3 -c "
import json,sys; print(len(json.load(sys.stdin)))
" 2>/dev/null || echo "0")

# ── 4. Cloud SQL instances ───────────────────────────────────────
echo "INFO     [4/6] Collecting Cloud SQL instances..."
SQL_LIST=$(gcloud sql instances list \
  --project="$PROJECT_ID" \
  --format="json(name,databaseVersion,state,settings.ipConfiguration,settings.databaseFlags)" \
  2>/dev/null || echo '[]')
SQL_COUNT=$(echo "$SQL_LIST" | python3 -c "
import json,sys; print(len(json.load(sys.stdin)))
" 2>/dev/null || echo "0")

# ── 5. API services ──────────────────────────────────────────────
echo "INFO     [5/6] Collecting enabled API services..."
API_LIST=$(gcloud services list --enabled \
  --project="$PROJECT_ID" \
  --format="value(config.name)" 2>/dev/null | sort || echo "")
API_COUNT=$(echo "$API_LIST" | grep -c . 2>/dev/null || echo "0")

CLOUDASSET_ON=$(echo "$API_LIST" | grep -c "cloudasset.googleapis.com" || echo "0")
SQLADMIN_ON=$(echo "$API_LIST"   | grep -c "sqladmin.googleapis.com"   || echo "0")
SCC_ON=$(echo "$API_LIST"        | grep -c "securitycenter.googleapis.com" || echo "0")

# ── 6. KMS keyrings ──────────────────────────────────────────────
echo "INFO     [6/6] Collecting KMS keyrings..."
KMS_LIST=$(gcloud kms keyrings list \
  --location="$REGION" \
  --project="$PROJECT_ID" \
  --format="value(name)" 2>/dev/null || echo "")
KMS_COUNT=$(echo "$KMS_LIST" | grep -c . 2>/dev/null || echo "0")

# ── Output context_info.json ─────────────────────────────────────
cat > "$OUTDIR/context_info.json" << JSONEOF
{
  "timestamp": "$TIMESTAMP",
  "project_id": "$PROJECT_ID",
  "project_number": "$PROJECT_NUMBER",
  "region": "$REGION",
  "resources": {
    "vms": $VM_COUNT,
    "bastion_vms": $BASTION_COUNT,
    "private_vms": $PRIVATE_VM_COUNT,
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

echo "$IAM_POLICY" > "$OUTDIR/iam_snapshot.json"

echo "────────────────────────────────────────────────────────────"
echo "OK       context_info.json"
echo "         vms=$VM_COUNT (bastion=$BASTION_COUNT private=$PRIVATE_VM_COUNT)"
echo "         buckets=$BUCKET_COUNT sql=$SQL_COUNT fw=$FW_COUNT kms=$KMS_COUNT"
echo "OK       iam_snapshot.json — bindings=$IAM_COUNT"
echo "OK       api_services — cloudasset=$CLOUDASSET_ON sqladmin=$SQLADMIN_ON scc=$SCC_ON"
echo "════════════════════════════════════════════════════════════"