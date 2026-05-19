#!/bin/bash
# ================================================================
# Nhóm A — CIS policy tự động fix bằng gcloud
# 21 controls: IAM, Logging, Network, VM, Storage, Cloud SQL
# Hỗ trợ kiến trúc multi-subnet: Public + Private
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

GREEN="\033[0;32m"; RED="\033[0;31m"; YELLOW="\033[0;33m"; RESET="\033[0m"
FIXED=0; FAILED=0

run() {
  if [ "$DRY_RUN" = "true" ]; then
    echo -e "${YELLOW}[DRY-RUN]${RESET} $*"
  else
    eval "$@"
  fi
}

fixed() { echo -e "${GREEN}[FIXED]${RESET} $1"; FIXED=$((FIXED+1)); }
err()   { echo -e "${RED}[ERROR]${RESET} $1";   FAILED=$((FAILED+1)); }

needs_fix() {
  local cid="$1"
  if [ ! -f "$FAIL_LIST_FILE" ]; then
    return 0  # full mode
  fi
  jq -r '.[]' "$FAIL_LIST_FILE" 2>/dev/null | grep -qw "$cid"
}

echo "================================================================"
echo "  NHÓM A — gcloud Auto Recovery"
echo "  Project: $PROJECT_ID | DRY_RUN: $DRY_RUN"
echo "================================================================"
echo ""

# ── CIS 1.4 — Xóa user-managed SA keys ──────────────────────────
if needs_fix "1.4"; then
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
          --iam-account="$SA" --project="$PROJECT_ID" --quiet \
          && echo "  Deleted key: $KEY ($SA)" \
          || err "Không xóa được key $KEY"
      done
    fi
  done
  fixed "CIS 1.4 — user-managed keys đã xóa"
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
" 2>/dev/null || echo "")

  if [ -n "$ADMIN_BINDINGS" ]; then
    echo "$ADMIN_BINDINGS" | while IFS='|' read MEMBER ROLE; do
      run gcloud projects remove-iam-policy-binding "$PROJECT_ID" \
        --member="$MEMBER" --role="$ROLE" --quiet 2>/dev/null \
        && echo "  Removed: $MEMBER -> $ROLE" \
        || err "Không xóa được: $MEMBER -> $ROLE"
    done
    fixed "CIS 1.5 — Admin SA bindings đã xóa"
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
                 date -v+90d '+%Y-%m-%dT00:00:00Z' 2>/dev/null || echo "")
      if [ -n "$NEXT_ROT" ]; then
        run gcloud kms keys update "$KEY" \
          --keyring="$KR" --location="$REGION" \
          --rotation-period="7776000s" \
          --next-rotation-time="$NEXT_ROT" \
          --project="$PROJECT_ID" 2>/dev/null \
          && echo "  Updated: $KEY" \
          || err "Không update được: $KEY"
      fi
    done
  done
  fixed "CIS 1.10 — KMS rotation 90 ngày"
fi

# ── CIS 2.1 — Patch Audit Logging ────────────────────────────────
if needs_fix "2.1"; then
  echo "[ 2.1 ] Patch Cloud Audit Logging..."
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
      && fixed "CIS 2.1 — Audit logging patched" \
      || err "CIS 2.1 — Không patch được audit logging"
  fi
fi

# ── CIS 2.2 — Tạo Log Sink ───────────────────────────────────────
if needs_fix "2.2"; then
  echo "[ 2.2 ] Tạo/fix Log Sink đến Storage Bucket..."
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
        && fixed "CIS 2.2 — Log sink tạo thành công" \
        || err "CIS 2.2 — Không tạo được log sink"

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
          && fixed "CIS 2.2 — Filter đã xóa khỏi sink" \
          || err "CIS 2.2 — Không xóa được filter"
      else
        fixed "CIS 2.2 — Sink đã tồn tại và không có filter"
      fi
    fi
  else
    err "CIS 2.2 — Không tìm thấy bucket để tạo sink"
  fi
fi

# ── CIS 2.12 — DNS Logging ────────────────────────────────────────
if needs_fix "2.12"; then
  echo "[ 2.12 ] Bật DNS logging..."
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
        && fixed "CIS 2.12 — DNS logging updated" \
        || err "CIS 2.12 — Không update DNS policy"
    else
      run gcloud dns policies create enable-dns-logging \
        --enable-logging --networks="$VPC_NAME" \
        --project="$PROJECT_ID" 2>/dev/null \
        && fixed "CIS 2.12 — DNS logging created" \
        || err "CIS 2.12 — Không tạo DNS policy"
    fi
  fi
fi

# ── CIS 2.13 — Cloud Asset API ───────────────────────────────────
if needs_fix "2.13"; then
  echo "[ 2.13 ] Bật Cloud Asset Inventory API..."
  run gcloud services enable cloudasset.googleapis.com \
    --project="$PROJECT_ID" 2>/dev/null \
    && fixed "CIS 2.13 — Cloud Asset API enabled" \
    || err "CIS 2.13 — Không enable được API"
fi

# ── CIS 3.1 — Xóa default network ────────────────────────────────
if needs_fix "3.1"; then
  echo "[ 3.1 ] Xóa default network..."
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
      && fixed "CIS 3.1 — Default network đã xóa" \
      || err "CIS 3.1 — Không xóa được default network"
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
      --project="$PROJECT_ID" --quiet 2>/dev/null \
      && echo "  Deleted RDP rule: $FR" \
      || err "Không xóa được: $FR"
  done
  fixed "CIS 3.7 — RDP rules 0.0.0.0/0 đã xóa"
fi

# ── CIS 3.8 — VPC Flow Logs (hỗ trợ multi-subnet) ───────────────
if needs_fix "3.8"; then
  echo "[ 3.8 ] Bật VPC Flow Logs trên tất cả subnet..."
  SKIP_PURPOSES="REGIONAL_MANAGED_PROXY GLOBAL_MANAGED_PROXY PRIVATE_SERVICE_CONNECT"
  gcloud compute networks subnets list \
    --project="$PROJECT_ID" \
    --filter="region:$REGION" \
    --format="value(name,region,purpose)" 2>/dev/null | \
    while read SUBNET REG PURPOSE; do
      # Bỏ qua managed proxy subnets
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
        && echo "  Flow logs enabled: $SUBNET ($REG)" \
        || err "Không enable được flow logs: $SUBNET"
    done
  fixed "CIS 3.8 — VPC Flow Logs enabled (tất cả subnet)"
fi

# ── CIS 4.3 — Block project-wide SSH keys (cả 2 VM) ─────────────
if needs_fix "4.3"; then
  echo "[ 4.3 ] Block project-wide SSH keys..."
  gcloud compute instances list \
    --project="$PROJECT_ID" \
    --format="value(name,zone)" 2>/dev/null | while read VM Z; do
    run gcloud compute instances add-metadata "$VM" \
      --zone="$Z" \
      --metadata="block-project-ssh-keys=true" \
      --project="$PROJECT_ID" 2>/dev/null \
      && echo "  Done: $VM" \
      || err "Không update được: $VM"
  done
  fixed "CIS 4.3 — Block project SSH keys (Bastion + App VM)"
fi

# ── CIS 4.4 — OS Login (cả 2 VM) ────────────────────────────────
if needs_fix "4.4"; then
  echo "[ 4.4 ] Bật OS Login..."
  gcloud compute instances list \
    --project="$PROJECT_ID" \
    --format="value(name,zone)" 2>/dev/null | while read VM Z; do
    run gcloud compute instances add-metadata "$VM" \
      --zone="$Z" \
      --metadata="enable-oslogin=true" \
      --project="$PROJECT_ID" 2>/dev/null \
      && echo "  Done: $VM" \
      || err "Không update được: $VM"
  done
  fixed "CIS 4.4 — OS Login enabled (Bastion + App VM)"
fi

# ── CIS 4.5 — Tắt serial port (cả 2 VM) ─────────────────────────
if needs_fix "4.5"; then
  echo "[ 4.5 ] Tắt serial port..."
  gcloud compute instances list \
    --project="$PROJECT_ID" \
    --format="value(name,zone)" 2>/dev/null | while read VM Z; do
    run gcloud compute instances add-metadata "$VM" \
      --zone="$Z" \
      --metadata="serial-port-enable=false" \
      --project="$PROJECT_ID" 2>/dev/null \
      && echo "  Done: $VM" \
      || err "Không update được: $VM"
  done
  fixed "CIS 4.5 — Serial port disabled (Bastion + App VM)"
fi

# ── CIS 5.1 — Bucket không public ────────────────────────────────
if needs_fix "5.1"; then
  echo "[ 5.1 ] Xóa public access từ buckets..."
  gsutil ls -p "$PROJECT_ID" 2>/dev/null | while read BUCKET; do
    run gsutil iam ch -d allUsers "$BUCKET" 2>/dev/null || true
    run gsutil iam ch -d allAuthenticatedUsers "$BUCKET" 2>/dev/null || true
    echo "  Public access removed: $BUCKET"
  done
  fixed "CIS 5.1 — Bucket public access removed"
fi

# ── CIS 5.2 — Uniform Bucket-Level Access ────────────────────────
if needs_fix "5.2"; then
  echo "[ 5.2 ] Bật Uniform Bucket-Level Access..."
  gsutil ls -p "$PROJECT_ID" 2>/dev/null | while read BUCKET; do
    run gsutil uniformbucketlevelaccess set on "$BUCKET" 2>/dev/null \
      && echo "  Done: $BUCKET" \
      || err "Không enable được: $BUCKET"
  done
  fixed "CIS 5.2 — Uniform access enabled"
fi

# ── Domain 6: Cloud SQL PostgreSQL ───────────────────────────────
SQL_INSTANCE=$(gcloud sql instances list \
  --project="$PROJECT_ID" \
  --filter="databaseVersion~POSTGRES" \
  --format="value(name)" 2>/dev/null | head -1)

if [ -n "$SQL_INSTANCE" ]; then
  echo ""
  echo "[ Domain 6 ] Cloud SQL: $SQL_INSTANCE"

  # CIS 6.4 — SSL
  if needs_fix "6.4"; then
    echo "  [ 6.4 ] Bật require_ssl..."
    run gcloud sql instances patch "$SQL_INSTANCE" \
      --require-ssl \
      --project="$PROJECT_ID" --quiet 2>/dev/null \
      && fixed "CIS 6.4 — require_ssl enabled" \
      || err "CIS 6.4 — Không patch được SSL"
  fi

  # CIS 6.2.x — Database flags (1 lệnh, 1 restart)
  SQL_FLAGS_NEW=()
  needs_fix "6.2.1" && SQL_FLAGS_NEW+=("log_error_verbosity=default")
  needs_fix "6.2.2" && SQL_FLAGS_NEW+=("log_connections=on")
  needs_fix "6.2.3" && SQL_FLAGS_NEW+=("log_disconnections=on")
  needs_fix "6.2.4" && SQL_FLAGS_NEW+=("log_statement=ddl")
  needs_fix "6.2.8" && SQL_FLAGS_NEW+=("cloudsql.enable_pgaudit=on")

  if [ ${#SQL_FLAGS_NEW[@]} -gt 0 ]; then
    echo "  [ 6.2.x ] Patch database flags..."
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
      && fixed "CIS 6.2.x + 6.2.8 — database flags patched (1 restart)" \
      || err "CIS 6.2.x — Không patch được database flags"
  fi
fi

# ── Summary ───────────────────────────────────────────────────────
echo ""
echo "================================================================"
echo "  Nhóm A Summary"
echo "  FIXED: $FIXED | FAILED: $FAILED"
echo "================================================================"

echo "A_FIXED=$FIXED"   >> "${GITHUB_ENV:-/dev/null}" 2>/dev/null || true
echo "A_FAILED=$FAILED" >> "${GITHUB_ENV:-/dev/null}" 2>/dev/null || true

[ "$FAILED" -eq 0 ] && exit 0 || exit 1