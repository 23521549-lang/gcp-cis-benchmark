#!/bin/bash
# ================================================================
# group_e.sh
# Group E — Security Anomaly Recovery
# E1: IAM anomaly (unauthorized bindings)
# E2: Terraform drift
# E3: SCC HIGH findings
# ================================================================
set -uo pipefail

PROJECT_ID=$(gcloud config get-value project 2>/dev/null)
REGION="${REGION:-asia-southeast1}"
IAM_BASELINE="${IAM_BASELINE:-/tmp/iam_baseline_latest.json}"
IAM_CURRENT="${IAM_CURRENT:-/tmp/iam_snapshot.json}"

E_FIXED=false
E_MANUAL_STEPS=""

ok()     { echo "OK       $1"; E_FIXED=true; }
manual() { echo "MANUAL   $1"; E_MANUAL_STEPS="${E_MANUAL_STEPS}\n  - $1"; }
warn()   { echo "WARN     $1"; }
info()   { echo "INFO     $1"; }

echo "════════════════════════════════════════════════════════════"
echo " GROUP E  Security Anomaly Recovery"
echo " Project: $PROJECT_ID"
echo " Started: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo "════════════════════════════════════════════════════════════"

# ── E1: IAM Anomaly ───────────────────────────────────────────────
IAM_ANOMALY="${IAM_ANOMALY:-false}"
if [ "$IAM_ANOMALY" = "true" ]; then
  echo "RUN      E1  IAM anomaly — scanning unauthorized bindings..."

  if [ -f "$IAM_BASELINE" ] && [ -f "$IAM_CURRENT" ]; then
    NEW_BINDINGS=$(IAM_BASELINE="$IAM_BASELINE" IAM_CURRENT="$IAM_CURRENT" \
      python3 - << 'PYEOF'
import json, sys, os
with open(os.environ['IAM_BASELINE']) as f: baseline = json.load(f)
with open(os.environ['IAM_CURRENT'])  as f: current  = json.load(f)

def get_bindings(policy):
    result = set()
    for b in policy.get('bindings', []):
        role = b.get('role', '')
        for m in b.get('members', []):
            result.add(f"{m}|{role}")
    return result

new_bindings = get_bindings(current) - get_bindings(baseline)
for b in sorted(new_bindings):
    member, role = b.split('|', 1)
    risk = 'HIGH' if any(r in role for r in
           ['owner','editor','admin','securityAdmin']) else 'LOW'
    print(f"{risk}|{member}|{role}")
PYEOF
)

    if [ -n "$NEW_BINDINGS" ]; then
      HIGH_BINDINGS=$(echo "$NEW_BINDINGS" | grep "^HIGH|" || true)
      LOW_BINDINGS=$(echo "$NEW_BINDINGS"  | grep "^LOW|"  || true)

      if [ -n "$HIGH_BINDINGS" ]; then
        warn "E1  HIGH risk bindings detected — removing automatically:"
        echo "$HIGH_BINDINGS" | while IFS='|' read RISK MEMBER ROLE; do
          gcloud projects remove-iam-policy-binding "$PROJECT_ID" \
            --member="$MEMBER" --role="$ROLE" --quiet 2>/dev/null \
            && ok "E1  Removed HIGH risk binding: member=$MEMBER role=$ROLE" \
            || echo "ERROR    E1  Failed to remove: member=$MEMBER role=$ROLE"
        done
        E_FIXED=true
      fi

      if [ -n "$LOW_BINDINGS" ]; then
        warn "E1  LOW risk bindings need review:"
        echo "$LOW_BINDINGS" | while IFS='|' read RISK MEMBER ROLE; do
          manual "E1  Verify if authorized: member=$MEMBER role=$ROLE"
          manual "    Remove if not authorized: gcloud projects remove-iam-policy-binding $PROJECT_ID --member=$MEMBER --role=$ROLE"
        done
      fi
    else
      info "E1  No unauthorized bindings found"
    fi
  else
    warn "E1  IAM baseline not available — run WF1 to create baseline"
    manual "E1  Trigger WF1 to generate IAM baseline"
  fi
fi

# ── E2: Terraform Drift ───────────────────────────────────────────
DRIFT_DETECTED="${DRIFT_DETECTED:-false}"
if [ "$DRIFT_DETECTED" = "true" ]; then
  echo "RUN      E2  Terraform drift — identifying changed resources..."

  if [ -d "terraform" ]; then
    DRIFT_PLAN=$(cd terraform && terraform plan \
      -var="db_username=${DB_USERNAME:-dummy}" \
      -var="db_password=${DB_PASSWORD:-dummy}" \
      -var="allowed_client_cidr=${ALLOWED_CLIENT_CIDR:-0.0.0.0/32}" \
      -no-color -input=false 2>&1 | \
      grep "^  [~#]" | head -10 || echo "")

    if [ -n "$DRIFT_PLAN" ]; then
      warn "E2  Drifted resources:"
      echo "$DRIFT_PLAN" | while IFS= read -r line; do
        echo "         $line"
      done
      manual "E2  Review drift: cd terraform && terraform plan"
      manual "E2  Apply to restore: terraform apply (if change is unauthorized)"
      manual "E2  Import if legitimate: terraform import resource_type.name RESOURCE_ID"
    fi
  fi

  manual "E2  Check who changed the resource: Cloud Audit Logs"
  manual "    https://console.cloud.google.com/logs/query?project=$PROJECT_ID"
fi

# ── E3: SCC Findings ──────────────────────────────────────────────
SCC_FINDINGS="${SCC_FINDINGS:-}"
if [ -n "$SCC_FINDINGS" ]; then
  echo "RUN      E3  SCC findings — checking HIGH severity..."

  SCC_ENABLED=$(gcloud services list --enabled \
    --project="$PROJECT_ID" \
    --filter="config.name=securitycenter.googleapis.com" \
    --format="value(config.name)" 2>/dev/null || echo "")

  if [ -n "$SCC_ENABLED" ]; then
    HIGH_FINDINGS=$(gcloud scc findings list \
      --project="$PROJECT_ID" \
      --filter="state=ACTIVE AND severity=HIGH" \
      --format="value(category,resourceName)" 2>/dev/null || echo "")

    if [ -n "$HIGH_FINDINGS" ]; then
      warn "E3  HIGH severity SCC findings:"
      echo "$HIGH_FINDINGS" | while IFS= read -r line; do
        echo "         $line"
        manual "E3  Investigate SCC finding: $line"
      done
      manual "E3  Details: https://console.cloud.google.com/security/command-center/findings?project=$PROJECT_ID"
    else
      ok "E3  No HIGH severity SCC findings"
    fi
  else
    manual "E3  Enable SCC: gcloud services enable securitycenter.googleapis.com --project=$PROJECT_ID"
  fi
fi

# ── Summary ───────────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════════════════════════"
echo " RESULT   Group E Security Anomaly Recovery"
echo "          Fixed : $E_FIXED"
[ -n "$E_MANUAL_STEPS" ] && echo -e "          Manual:$E_MANUAL_STEPS"
echo "════════════════════════════════════════════════════════════"

{
  echo "E_FIXED=$E_FIXED"
} >> "${GITHUB_ENV:-/dev/null}" 2>/dev/null || true
exit 0