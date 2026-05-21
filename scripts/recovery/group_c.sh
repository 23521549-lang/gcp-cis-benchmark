#!/bin/bash
# ================================================================
# group_c.sh
# Group C — Manual Action Guidance
# Controls requiring human confirmation: 1.6, 2.3, 2.4, 3.3, 3.6
# ================================================================
set -uo pipefail

PROJECT_ID=$(gcloud config get-value project 2>/dev/null)
FAIL_LIST_FILE="${FAIL_LIST_FILE:-/tmp/control_fail_list.json}"
ALERT_EMAIL="${ALERT_EMAIL:-23521549@gm.uit.edu.vn}"
ALLOWED_CLIENT_CIDR="${ALLOWED_CLIENT_CIDR:-YOUR_IP/32}"

C_COUNT=0

manual() { echo "MANUAL   $1"; C_COUNT=$((C_COUNT+1)); }
step()   { echo "         -> $1"; }
info()   { echo "INFO     $1"; }

needs_fix() {
  local cid="$1"
  [ ! -f "$FAIL_LIST_FILE" ] && return 0
  jq -r '.[]' "$FAIL_LIST_FILE" 2>/dev/null | grep -qw "$cid"
}

echo "════════════════════════════════════════════════════════════"
echo " GROUP C  Manual Action Guidance"
echo " Project: $PROJECT_ID"
echo " Contact: $ALERT_EMAIL"
echo " Time   : $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo "════════════════════════════════════════════════════════════"

C_STEPS=""

# ── CIS 1.6 — SA User/Token Creator at project level ─────────────
if needs_fix "1.6"; then
  echo "────────────────────────────────────────────────────────────"
  manual "CIS-1.6  SA User/Token Creator binding at project level"
  info   "Reason:  Requires confirmation of which users are authorized"
  echo ""
  info   "Inspect:"
  step "gcloud projects get-iam-policy $PROJECT_ID --format=json | python3 -c \\"
  step "  \"import json,sys; p=json.load(sys.stdin)\\"
  step "  roles=['roles/iam.serviceAccountUser','roles/iam.serviceAccountTokenCreator']\\"
  step "  [print(m,'->',b['role']) for b in p.get('bindings',[]) for m in b.get('members',[])\\"
  step "   if b['role'] in roles and m.startswith(('user:','group:'))]\""
  echo ""
  info   "Remediate:"
  step "gcloud projects remove-iam-policy-binding $PROJECT_ID \\"
  step "  --member='user:EMAIL' --role='roles/iam.serviceAccountUser'"
  echo ""
  C_STEPS="${C_STEPS}CIS-1.6: Remove SA User/Token Creator binding at project level\n"
fi

# ── CIS 2.3 — Retention Policy + Bucket Lock ─────────────────────
if needs_fix "2.3"; then
  echo "────────────────────────────────────────────────────────────"
  manual "CIS-2.3  Retention Policy + Bucket Lock"
  info   "Reason:  Bucket lock is PERMANENT and irreversible"
  info   "WARNING: After locking, objects cannot be deleted until retention expires"
  echo ""

  LOG_BUCKET=$(gcloud logging sinks list \
    --project="$PROJECT_ID" \
    --format=json 2>/dev/null | python3 -c "
import json, sys
sinks = json.load(sys.stdin)
for s in sinks:
    dest = s.get('destination','')
    if 'storage.googleapis.com' in dest:
        print(dest.split('/')[-1])
        break
" 2>/dev/null || echo "YOUR_LOG_BUCKET")

  info   "Target bucket: $LOG_BUCKET"
  echo ""
  info   "Option 1 — Console:"
  step "https://console.cloud.google.com/storage/browser/$LOG_BUCKET"
  step "Bucket details > Protection > Retention policy"
  step "Set: 30 days (2592000 seconds) then click Lock"
  echo ""
  info   "Option 2 — CLI (CAUTION — irreversible):"
  step "gsutil retention set 30d gs://$LOG_BUCKET"
  step "gsutil retention lock gs://$LOG_BUCKET"
  echo ""
  C_STEPS="${C_STEPS}CIS-2.3: Set retention 30d + lock on gs://$LOG_BUCKET (IRREVERSIBLE)\n"
fi

# ── CIS 2.4 — Alert Policy verification ──────────────────────────
if needs_fix "2.4"; then
  echo "────────────────────────────────────────────────────────────"
  manual "CIS-2.4  Alert Policy for Project Ownership Changes"
  info   "Reason:  Notification channel must be verified as working"
  echo ""
  info   "Inspect alert policies:"
  step "gcloud alpha monitoring policies list --project=$PROJECT_ID \\"
  step "  --format='table(displayName,enabled,conditions[0].displayName)'"
  echo ""
  info   "Inspect notification channels:"
  step "gcloud alpha monitoring channels list --project=$PROJECT_ID \\"
  step "  --format='table(displayName,type,labels)'"
  echo ""
  info   "If disabled:"
  step "gcloud alpha monitoring policies update POLICY_ID --enabled"
  echo ""
  info   "Verify via Console:"
  step "https://console.cloud.google.com/monitoring/alerting?project=$PROJECT_ID"
  step "Find: CIS 2.4 — Project Ownership Change Alert"
  step "Confirm: status=ENABLED, notification channel=active"
  echo ""
  C_STEPS="${C_STEPS}CIS-2.4: Verify alert policy enabled and notification channel active\n"
fi

# ── CIS 3.3 — DNSSEC ─────────────────────────────────────────────
if needs_fix "3.3"; then
  echo "────────────────────────────────────────────────────────────"
  manual "CIS-3.3  DNSSEC for Cloud DNS zones"
  info   "Reason:  Requires terraform apply to sync state correctly"
  echo ""
  info   "Inspect current DNS zones:"
  step "gcloud dns managed-zones list --project=$PROJECT_ID \\"
  step "  --format='table(name,dnsName,dnssecConfig.state)'"
  echo ""
  info   "Option 1 — Terraform (recommended):"
  step "Edit terraform/vpc.tf:"
  step "  resource \"google_dns_managed_zone\" \"public\" {"
  step "    dnssec_config { state = \"on\" }"
  step "  }"
  step "git add . && git commit -m 'fix: enable DNSSEC' && git push"
  step "WF3 will apply automatically"
  echo ""
  info   "Option 2 — Direct CLI (emergency only):"
  step "gcloud dns managed-zones update ZONE_NAME \\"
  step "  --dnssec-state=on --project=$PROJECT_ID"
  echo ""
  C_STEPS="${C_STEPS}CIS-3.3: Enable DNSSEC in vpc.tf and push to trigger WF3\n"
fi

# ── CIS 3.6 — SSH not open to 0.0.0.0/0 ─────────────────────────
if needs_fix "3.6"; then
  echo "────────────────────────────────────────────────────────────"
  manual "CIS-3.6  SSH firewall rule open to 0.0.0.0/0"
  info   "Reason:  Need to confirm authorized IPs before restricting"
  info   "WARNING: Incorrect update may cause loss of SSH access"
  echo ""
  info   "Inspect current SSH rules:"
  step "gcloud compute firewall-rules list --project=$PROJECT_ID \\"
  step "  --filter='allowed[].ports=22' \\"
  step "  --format='table(name,sourceRanges,targetTags)'"
  echo ""
  info   "Get your current public IP:"
  step "curl -s ifconfig.me"
  echo ""
  info   "Remediate (replace YOUR_IP with actual IP):"
  step "gcloud compute firewall-rules update benchmark-allow-ssh-bastion \\"
  step "  --source-ranges=$ALLOWED_CLIENT_CIDR \\"
  step "  --project=$PROJECT_ID"
  echo ""
  info   "Or update terraform.tfvars:"
  step "allowed_client_cidr = \"$ALLOWED_CLIENT_CIDR\""
  step "Then push to trigger WF3"
  echo ""
  C_STEPS="${C_STEPS}CIS-3.6: Restrict SSH source to specific IP: $ALLOWED_CLIENT_CIDR\n"
fi

# ── Summary ───────────────────────────────────────────────────────
echo "════════════════════════════════════════════════════════════"
echo " RESULT   Group C Manual Guidance"
printf "          Manual actions required: %s\n" "$C_COUNT"
if [ $C_COUNT -gt 0 ]; then
  echo "────────────────────────────────────────────────────────────"
  echo " ACTIONS  Required steps:"
  echo -e "$C_STEPS" | while IFS= read -r line; do
    [ -n "$line" ] && echo "          - $line"
  done
fi
echo "════════════════════════════════════════════════════════════"

echo "C_COUNT=$C_COUNT" >> "${GITHUB_ENV:-/dev/null}" 2>/dev/null || true
exit 0