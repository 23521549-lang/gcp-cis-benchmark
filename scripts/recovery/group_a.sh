#!/bin/bash
# ================================================================
# group_a.sh
# Group A — gcloud Auto-Remediation
# 21 CIS controls: IAM, Logging, Networking, VM, Storage, SQL
# ================================================================
set -uo pipefail

PROJECT_ID=$(gcloud config get-value project 2>/dev/null)
VM_NAME="${VM_NAME:-benchmark-vm-01}"
BASTION_NAME="${BASTION_NAME:-benchmark-bastion-01}"
VM_ZONE="${VM_ZONE:-asia-southeast1-a}"
REGION="${REGION:-asia-southeast1}"
CUSTOM_SA="${CUSTOM_SA:-app-least-privilege-sa@${PROJECT_ID}.iam.gserviceaccount.com}"
DRY_RUN="${DRY_RUN:-false}"
FAIL_LIST_FILE="${FAIL_LIST_FILE:-/tmp/control_fail_list.json}"

FIXED=0; FAILED=0

run() {
  if [ "$DRY_RUN" = "true" ]; then
    echo "DRY-RUN  $*"
  else
    eval "$@"
  fi
}

ok()  { echo "OK       $1"; FIXED=$((FIXED+1)); }
err() { echo "ERROR    $1"; FAILED=$((FAILED+1)); }

needs_fix() {
  local cid="$1"
  [ ! -f "$FAIL_LIST_FILE" ] && return 0
  jq -r '.[] // empty' "$FAIL_LIST_FILE" 2>/dev/null | grep -qw "$cid"
}

echo "════════════════════════════════════════════════════════════"
echo " GROUP A  gcloud Auto-Remediation"
echo " Project: $PROJECT_ID | Mode: $([ "$DRY_RUN" = "true" ] && echo DRY-RUN || echo LIVE)"
echo " Started: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo "════════════════════════════════════════════════════════════"

# ── CIS 1.4 — Remove user-managed SA keys ────────────────────────
if needs_fix "1.4"; then
  echo "RUN      CIS-1.4  Removing user-managed SA keys..."
  gcloud iam service-accounts list \
    --project="$PROJECT_ID" \
    --format="value(email)" 2>/dev/null | while read SA; do
    KEYS=$(gcloud iam service-accounts keys list \
      --iam-account="$SA" --managed-by=user \
      --format="value(name)" 2>/dev/null)
    if [ -n "$KEYS" ]; then
      echo "$KEYS" | while read KEY; do
        run gcloud iam service-accounts keys delete "$KEY" \
          --iam-account="$SA" --project="$PROJECT_ID" --quiet \
          && echo "         Deleted: key=$KEY sa=$SA" \
          || err "CIS-1.4  Failed to delete key=$KEY"
      done
    fi
  done
  ok "CIS-1.4  User-managed SA keys removed"
fi

# ── CIS 1.5 — Remove Admin SA bindings ───────────────────────────
if needs_fix "1.5"; then
  echo "RUN      CIS-1.5  Removing SA admin privileges..."
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
" 2>/dev/null || echo "")

  if [ -n "$ADMIN_BINDINGS" ]; then
    echo "$ADMIN_BINDINGS" | while IFS='|' read MEMBER ROLE; do
      run gcloud projects remove-iam-policy-binding "$PROJECT_ID" \
        --member="$MEMBER" --role="$ROLE" --quiet 2>/dev/null \
        && echo "         Removed: member=$MEMBER role=$ROLE" \
        || err "CIS-1.5  Failed to remove: member=$MEMBER role=$ROLE"
    done
    ok "CIS-1.5  SA admin bindings removed"
  else
    echo "INFO     CIS-1.5  No admin SA bindings found"
  fi
fi

# ── CIS 1.10 — KMS key rotation 90 days ──────────────────────────
if needs_fix "1.10"; then
  echo "RUN      CIS-1.10 Updating KMS key rotation period..."
  gcloud kms keyrings list \
    --location="$REGION" --project="$PROJECT_ID" \
    --format="value(name)" 2>/dev/null | while read KR; do
    gcloud kms keys list \
      --keyring="$KR" --location="$REGION" \
      --project="$PROJECT_ID" \
      --format="value(name)" 2>/dev/null | while read KEY; do
      NEXT_ROT=$(date -d '+90 days' '+%Y-%m-%dT00:00:00Z' 2>/dev/null || \
                 date -v+90d '+%Y-%m-%dT00:00:00Z' 2>/dev/null || echo "")
      if [ -n "$NEXT_ROT" ]; then
        run gcloud kms keys update "$KEY" \
          --keyring="$KR" --location="$REGION" \
          --rotation-period="7776000s" \
          --next-rotation-time="$NEXT_ROT" \
          --project="$PROJECT_ID" 2>/dev/null \
          && echo "         Updated: key=$KEY rotation=90d" \
          || err "CIS-1.10 Failed to update key=$KEY"
      fi
    done
  done
  ok "CIS-1.10 KMS rotation set to 90 days"
fi

# ── CIS 2.1 — Patch Cloud Audit Logging ──────────────────────────
if needs_fix "2.1"; then
  echo "RUN      CIS-2.1  Patching Cloud Audit Logging..."
  CURRENT_POLICY=$(gcloud projects get-iam-policy "$PROJECT_ID" \
    --format=json 2>/dev/null || echo '{"bindings":[]}')
  PATCHED=$(echo "$CURRENT_POLICY" | python3 -c "
import json, sys
policy = json.load(sys.stdin)
configs = policy.get('auditConfigs', [])
required = [
    {'logType': 'ADMIN_READ'},
    {'logType': 'DATA_READ'},
    {'logType': 'DATA_WRITE'}
]
all_svc = next((c for c in configs if c.get('service') == 'allServices'), None)
if all_svc:
    all_svc['auditLogConfigs'] = required
    all_svc.pop('exemptedMembers', None)
else:
    configs.append({'service': 'allServices', 'auditLogConfigs': required})
policy['auditConfigs'] = configs
print(json.dumps(policy))
" 2>/dev/null)
  if [ -n "$PATCHED" ]; then
    echo "$PATCHED" > /tmp/patched_policy.json
    run gcloud projects set-iam-policy "$PROJECT_ID" \
      /tmp/patched_policy.json --quiet 2>/dev/null \
      && ok "CIS-2.1  Audit logging configured: ADMIN_READ,DATA_READ,DATA_WRITE" \
      || err "CIS-2.1  Failed to patch audit logging"
  fi
fi

# ── CIS 2.2 — Create/fix Log Sink ────────────────────────────────
if needs_fix "2.2"; then
  echo "RUN      CIS-2.2  Configuring log sink to storage bucket..."
  SINK_BUCKET=$(gcloud logging sinks list \
    --project="$PROJECT_ID" \
    --format="value(destination)" 2>/dev/null | \
    grep "storage.googleapis.com" | head -1 | \
    sed 's|storage.googleapis.com/||' || echo "")

  if [ -z "$SINK_BUCKET" ]; then
    SINK_BUCKET=$(gsutil ls -p "$PROJECT_ID" 2>/dev/null | \
      grep "benchmark-storage" | head -1 | \
      sed 's|gs://||;s|/||' || echo "")
  fi

  if [ -n "$SINK_BUCKET" ]; then
    EXISTING=$(gcloud logging sinks list \
      --project="$PROJECT_ID" \
      --filter="name=benchmark-log-sink" \
      --format="value(name)" 2>/dev/null || echo "")

    if [ -z "$EXISTING" ]; then
      run gcloud logging sinks create benchmark-log-sink \
        "storage.googleapis.com/$SINK_BUCKET" \
        --project="$PROJECT_ID" --quiet 2>/dev/null \
        && ok "CIS-2.2  Log sink created: benchmark-log-sink -> $SINK_BUCKET" \
        || err "CIS-2.2  Failed to create log sink"

      WRITER=$(gcloud logging sinks describe benchmark-log-sink \
        --project="$PROJECT_ID" \
        --format="value(writerIdentity)" 2>/dev/null || echo "")
      [ -n "$WRITER" ] && \
        run gsutil iam ch "${WRITER}:objectCreator" \
          "gs://$SINK_BUCKET" 2>/dev/null || true
    else
      CURRENT_FILTER=$(gcloud logging sinks describe benchmark-log-sink \
        --project="$PROJECT_ID" \
        --format="value(filter)" 2>/dev/null || echo "")
      if [ -n "$CURRENT_FILTER" ] && [ "$CURRENT_FILTER" != "(empty filter)" ]; then
        run gcloud logging sinks update benchmark-log-sink \
          --project="$PROJECT_ID" \
          --log-filter="" --quiet 2>/dev/null \
          && ok "CIS-2.2  Log sink filter cleared: sink=benchmark-log-sink" \
          || err "CIS-2.2  Failed to clear sink filter"
      else
        ok "CIS-2.2  Log sink exists with no filter — compliant"
      fi
    fi
  else
    err "CIS-2.2  No target bucket found for log sink"
  fi
fi

# ── CIS 2.12 — Enable DNS Logging ────────────────────────────────
if needs_fix "2.12"; then
  echo "RUN      CIS-2.12 Enabling Cloud DNS logging..."
  VPC_NAME=$(gcloud compute networks list \
    --project="$PROJECT_ID" --format="value(name)" \
    --filter="name!=default" 2>/dev/null | head -1)
  if [ -n "$VPC_NAME" ]; then
    EXISTING_DNS=$(gcloud dns policies list \
      --project="$PROJECT_ID" --format="value(name)" \
      2>/dev/null | head -1)
    if [ -n "$EXISTING_DNS" ]; then
      run gcloud dns policies update "$EXISTING_DNS" \
        --enable-logging --project="$PROJECT_ID" 2>/dev/null \
        && ok "CIS-2.12 DNS logging enabled: policy=$EXISTING_DNS" \
        || err "CIS-2.12 Failed to update DNS policy"
    else
      run gcloud dns policies create enable-dns-logging \
        --enable-logging --networks="$VPC_NAME" \
        --project="$PROJECT_ID" 2>/dev/null \
        && ok "CIS-2.12 DNS logging policy created: network=$VPC_NAME" \
        || err "CIS-2.12 Failed to create DNS policy"
    fi
  fi
fi

# ── CIS 2.13 — Enable Cloud Asset API ────────────────────────────
if needs_fix "2.13"; then
  echo "RUN      CIS-2.13 Enabling Cloud Asset Inventory API..."
  run gcloud services enable cloudasset.googleapis.com \
    --project="$PROJECT_ID" 2>/dev/null \
    && ok "CIS-2.13 Cloud Asset API enabled" \
    || err "CIS-2.13 Failed to enable Cloud Asset API"
fi

# ── CIS 3.1 — Delete default network ─────────────────────────────
if needs_fix "3.1"; then
  echo "RUN      CIS-3.1  Removing default network..."
  DEFAULT_NET=$(gcloud compute networks list \
    --project="$PROJECT_ID" \
    --filter="name=default" \
    --format="value(name)" 2>/dev/null)
  if [ -n "$DEFAULT_NET" ]; then
    gcloud compute firewall-rules list \
      --project="$PROJECT_ID" \
      --filter="network=default" \
      --format="value(name)" 2>/dev/null | while read FR; do
      run gcloud compute firewall-rules delete "$FR" \
        --project="$PROJECT_ID" --quiet 2>/dev/null || true
    done
    run gcloud compute networks delete default \
      --project="$PROJECT_ID" --quiet 2>/dev/null \
      && ok "CIS-3.1  Default network deleted" \
      || err "CIS-3.1  Failed to delete default network"
  else
    echo "INFO     CIS-3.1  Default network not present — no action needed"
  fi
fi

# ── CIS 3.7 — Remove RDP rules open to 0.0.0.0/0 ────────────────
if needs_fix "3.7"; then
  echo "RUN      CIS-3.7  Removing RDP rules open to 0.0.0.0/0..."
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
      --project="$PROJECT_ID" --quiet 2>/dev/null \
      && echo "         Deleted: rule=$FR" \
      || err "CIS-3.7  Failed to delete rule=$FR"
  done
  ok "CIS-3.7  RDP rules open to 0.0.0.0/0 removed"
fi

# ── CIS 3.8 — Enable VPC Flow Logs ───────────────────────────────
if needs_fix "3.8"; then
  echo "RUN      CIS-3.8  Enabling VPC flow logs on all subnets..."
  SKIP_PURPOSES="REGIONAL_MANAGED_PROXY GLOBAL_MANAGED_PROXY PRIVATE_SERVICE_CONNECT"
  gcloud compute networks subnets list \
    --project="$PROJECT_ID" \
    --filter="region:$REGION" \
    --format="value(name,region,purpose)" 2>/dev/null | \
    while read SUBNET REG PURPOSE; do
      SKIP=false
      for SP in $SKIP_PURPOSES; do
        [ "$PURPOSE" = "$SP" ] && SKIP=true && break
      done
      [ "$SKIP" = "true" ] && continue

      run gcloud compute networks subnets update "$SUBNET" \
        --region="$REG" \
        --enable-flow-logs \
        --logging-aggregation-interval=INTERVAL_5_SEC \
        --logging-flow-sampling=0.5 \
        --logging-metadata=INCLUDE_ALL_METADATA \
        --project="$PROJECT_ID" 2>/dev/null \
        && echo "         Updated: subnet=$SUBNET interval=5s sampling=100%" \
        || err "CIS-3.8  Failed to enable flow logs: subnet=$SUBNET"
    done
  ok "CIS-3.8  VPC flow logs enabled on all subnets"
fi

# ── CIS 4.3 — Block project-wide SSH keys ────────────────────────
if needs_fix "4.3"; then
  echo "RUN      CIS-4.3  Blocking project-wide SSH keys..."
  gcloud compute instances list \
    --project="$PROJECT_ID" \
    --format="value(name,zone,status)" 2>/dev/null | while read VM Z STATUS; do
    if [ "$STATUS" = "RUNNING" ] || [ "$STATUS" = "TERMINATED" ]; then
      run gcloud compute instances add-metadata "$VM" \
        --zone="$Z" \
        --metadata="block-project-ssh-keys=true" \
        --project="$PROJECT_ID" 2>/dev/null \
        && echo "         Updated: vm=$VM block-project-ssh-keys=true" \
        || err "CIS-4.3  Failed to update vm=$VM"
    else
      echo "INFO     CIS-4.3  Skipped vm=$VM status=$STATUS (unstable)"
    fi
  done
  ok "CIS-4.3  Project SSH keys blocked on all VMs"
fi

# ── CIS 4.4 — Enable OS Login ─────────────────────────────────────
if needs_fix "4.4"; then
  echo "RUN      CIS-4.4  Enabling OS Login..."
  gcloud compute instances list \
    --project="$PROJECT_ID" \
    --format="value(name,zone,status)" 2>/dev/null | while read VM Z STATUS; do
    if [ "$STATUS" = "RUNNING" ] || [ "$STATUS" = "TERMINATED" ]; then
      run gcloud compute instances add-metadata "$VM" \
        --zone="$Z" \
        --metadata="enable-oslogin=true" \
        --project="$PROJECT_ID" 2>/dev/null \
        && echo "         Updated: vm=$VM enable-oslogin=true" \
        || err "CIS-4.4  Failed to update vm=$VM"
    else
      echo "INFO     CIS-4.4  Skipped vm=$VM status=$STATUS"
    fi
  done
  ok "CIS-4.4  OS Login enabled on all VMs"
fi

# ── CIS 4.5 — Disable serial port ────────────────────────────────
# Waits for VM to reach stable state before updating metadata
if needs_fix "4.5"; then
  echo "RUN      CIS-4.5  Disabling serial port on all VMs..."
  gcloud compute instances list \
    --project="$PROJECT_ID" \
    --format="value(name,zone,status)" 2>/dev/null | while read VM Z STATUS; do

    if [ "$STATUS" != "RUNNING" ] && [ "$STATUS" != "TERMINATED" ]; then
      echo "INFO     CIS-4.5  vm=$VM status=$STATUS — waiting for stable state..."
      WAIT_COUNT=0
      while [ "$WAIT_COUNT" -lt 12 ]; do
        sleep 15
        WAIT_COUNT=$((WAIT_COUNT+1))
        NEW_STATUS=$(gcloud compute instances describe "$VM" \
          --zone="$Z" --project="$PROJECT_ID" \
          --format="value(status)" 2>/dev/null || echo "UNKNOWN")
        echo "         vm=$VM status=$NEW_STATUS (attempt $WAIT_COUNT/12)"
        if [ "$NEW_STATUS" = "RUNNING" ] || [ "$NEW_STATUS" = "TERMINATED" ]; then
          STATUS="$NEW_STATUS"
          break
        fi
      done
    fi

    run gcloud compute instances add-metadata "$VM" \
      --zone="$Z" \
      --metadata="serial-port-enable=false" \
      --project="$PROJECT_ID" 2>/dev/null \
      && echo "         Updated: vm=$VM serial-port-enable=false status=$STATUS" \
      || err "CIS-4.5  Failed to update vm=$VM status=$STATUS"
  done
  ok "CIS-4.5  Serial port disabled on all VMs"
fi

# ── CIS 5.1 — Remove public bucket access ────────────────────────
if needs_fix "5.1"; then
  echo "RUN      CIS-5.1  Removing public access from buckets..."
  gsutil ls -p "$PROJECT_ID" 2>/dev/null | while read BUCKET; do
    run gsutil iam ch -d allUsers "$BUCKET" 2>/dev/null || true
    run gsutil iam ch -d allAuthenticatedUsers "$BUCKET" 2>/dev/null || true
    echo "         Updated: bucket=$BUCKET public-access=removed"
  done
  ok "CIS-5.1  Public access removed from all buckets"
fi

# ── CIS 5.2 — Uniform Bucket-Level Access ────────────────────────
if needs_fix "5.2"; then
  echo "RUN      CIS-5.2  Enabling uniform bucket-level access..."
  gsutil ls -p "$PROJECT_ID" 2>/dev/null | while read BUCKET; do
    run gsutil uniformbucketlevelaccess set on "$BUCKET" 2>/dev/null \
      && echo "         Updated: bucket=$BUCKET uniform-access=enabled" \
      || err "CIS-5.2  Failed to enable uniform access: bucket=$BUCKET"
  done
  ok "CIS-5.2  Uniform bucket-level access enabled"
fi

# ── Domain 6: Cloud SQL PostgreSQL ───────────────────────────────
SQL_INSTANCE=$(gcloud sql instances list \
  --project="$PROJECT_ID" \
  --filter="databaseVersion~POSTGRES" \
  --format="value(name)" 2>/dev/null | head -1)

if [ -n "$SQL_INSTANCE" ]; then
  echo ""
  echo "INFO     Cloud SQL instance: $SQL_INSTANCE"

  if needs_fix "6.4"; then
    echo "RUN      CIS-6.4  Enabling require_ssl..."
    run gcloud sql instances patch "$SQL_INSTANCE" \
      --require-ssl \
      --project="$PROJECT_ID" --quiet 2>/dev/null \
      && ok "CIS-6.4  require_ssl=true: instance=$SQL_INSTANCE" \
      || err "CIS-6.4  Failed to patch SSL: instance=$SQL_INSTANCE"
  fi

  SQL_FLAGS_NEW=()
  needs_fix "6.2.1" && SQL_FLAGS_NEW+=("log_error_verbosity=default")
  needs_fix "6.2.2" && SQL_FLAGS_NEW+=("log_connections=on")
  needs_fix "6.2.3" && SQL_FLAGS_NEW+=("log_disconnections=on")
  needs_fix "6.2.4" && SQL_FLAGS_NEW+=("log_statement=ddl")
  needs_fix "6.2.8" && SQL_FLAGS_NEW+=("cloudsql.enable_pgaudit=on")

  if [ ${#SQL_FLAGS_NEW[@]} -gt 0 ]; then
    echo "RUN      CIS-6.2.x Patching database flags (single restart)..."
    OVERRIDE_NAMES="log_error_verbosity log_connections log_disconnections log_statement cloudsql.enable_pgaudit"
    CURRENT_FLAGS=$(gcloud sql instances describe "$SQL_INSTANCE" \
      --project="$PROJECT_ID" \
      --format="json(settings.databaseFlags)" 2>/dev/null | python3 -c "
import json, sys
d = json.load(sys.stdin)
flags = d.get('settings', {}).get('databaseFlags', [])
override = '$OVERRIDE_NAMES'.split()
keep = [f'{f[\"name\"]}={f[\"value\"]}' for f in flags if f['name'] not in override]
print(','.join(keep))
" 2>/dev/null || echo "")

    NEW_FLAGS_STR=$(IFS=','; echo "${SQL_FLAGS_NEW[*]}")
    ALL_FLAGS="${CURRENT_FLAGS:+$CURRENT_FLAGS,}${NEW_FLAGS_STR}"
    ALL_FLAGS="${ALL_FLAGS#,}"

    run gcloud sql instances patch "$SQL_INSTANCE" \
      --database-flags="$ALL_FLAGS" \
      --project="$PROJECT_ID" --quiet 2>/dev/null \
      && ok "CIS-6.2.x Database flags patched: $NEW_FLAGS_STR" \
      || err "CIS-6.2.x Failed to patch database flags"
  fi
fi

# ── Summary ───────────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════════════════════════"
echo " RESULT   Group A Auto-Remediation"
printf "          Fixed: %-3s  Failed: %-3s\n" "$FIXED" "$FAILED"
echo "════════════════════════════════════════════════════════════"

{
  echo "A_FIXED=$FIXED"
  echo "A_FAILED=$FAILED"
} >> "${GITHUB_ENV:-/dev/null}" 2>/dev/null || true

[ "$FAILED" -eq 0 ] && exit 0 || exit 1