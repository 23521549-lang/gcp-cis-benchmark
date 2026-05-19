#!/bin/bash
# ================================================================
# Nhóm C — CIS controls cần xác nhận thủ công
# 1.6, 2.3, 2.4, 3.3, 3.6
# In hướng dẫn chi tiết + gửi vào notify
# ================================================================
set -uo pipefail

PROJECT_ID=$(gcloud config get-value project 2>/dev/null)
FAIL_LIST_FILE="${FAIL_LIST_FILE:-/tmp/control_fail_list.json}"
ALERT_EMAIL="${ALERT_EMAIL:-23521549@gm.uit.edu.vn}"
ALLOWED_CLIENT_CIDR="${ALLOWED_CLIENT_CIDR:-YOUR_IP/32}"

YELLOW="\033[0;33m"; CYAN="\033[0;36m"; RESET="\033[0m"
C_COUNT=0

manual() {
  echo -e "${YELLOW}[MANUAL REQUIRED]${RESET} $1"
  C_COUNT=$((C_COUNT+1))
}

step() { echo -e "  ${CYAN}→${RESET} $1"; }

# Kiểm tra control có cần fix không
needs_fix() {
  local cid="$1"
  if [ ! -f "$FAIL_LIST_FILE" ]; then
    return 0
  fi
  jq -r '.[]' "$FAIL_LIST_FILE" 2>/dev/null | grep -qw "$cid"
}

echo "================================================================"
echo "  NHÓM C — Manual Actions Required"
echo "  Project: $PROJECT_ID"
echo "  Email hướng dẫn sẽ gửi tới: $ALERT_EMAIL"
echo "================================================================"
echo ""

C_STEPS=""

# ── CIS 1.6 — SA User/Token Creator at project level ─────────────
if needs_fix "1.6"; then
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  manual "CIS 1.6 — SA User/Token Creator ở project level"
  echo "  Lý do không tự động: Cần xác nhận người dùng nào được phép"
  echo ""
  echo "  Kiểm tra:"
  step "gcloud projects get-iam-policy $PROJECT_ID --format=json | python3 -c \""
  step "  import json,sys; p=json.load(sys.stdin)"
  step "  roles=['roles/iam.serviceAccountUser','roles/iam.serviceAccountTokenCreator']"
  step "  [print(m,'->',b['role']) for b in p.get('bindings',[]) for m in b.get('members',[])"
  step "   if b['role'] in roles and m.startswith(('user:','group:'))]\""
  echo ""
  echo "  Fix (thay bằng email thực tế):"
  step "gcloud projects remove-iam-policy-binding $PROJECT_ID \\"
  step "  --member='user:EMAIL' --role='roles/iam.serviceAccountUser'"
  echo ""
  C_STEPS="${C_STEPS}CIS 1.6: Remove SA User/Token Creator binding at project level\n"
fi

# ── CIS 2.3 — Bucket Lock ────────────────────────────────────────
if needs_fix "2.3"; then
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  manual "CIS 2.3 — Retention Policy + Bucket Lock"
  echo "  Lý do không tự động: Bucket lock là VĨNH VIỄN, không thể undo"
  echo "  Cảnh báo: Sau khi lock, KHÔNG XÓA ĐƯỢC objects cho đến hết retention period"
  echo ""

  # Lấy tên log bucket
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

  echo "  Log bucket phát hiện: $LOG_BUCKET"
  echo ""
  echo "  Fix (qua Console):"
  step "Vào: https://console.cloud.google.com/storage/browser/$LOG_BUCKET"
  step "Bucket details > Protection > Retention policy"
  step "Set: 30 ngày (2592000 giây)"
  step "Click 'Lock' để khoá vĩnh viễn"
  echo ""
  echo "  Fix (qua CLI — THẬN TRỌNG):"
  step "gsutil retention set 30d gs://$LOG_BUCKET"
  step "gsutil retention lock gs://$LOG_BUCKET   # KHÔNG THỂ UNDO"
  echo ""
  C_STEPS="${C_STEPS}CIS 2.3: Set retention policy 30d + lock on gs://$LOG_BUCKET\n"
fi

# ── CIS 2.4 — Alert Policy verify ────────────────────────────────
if needs_fix "2.4"; then
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  manual "CIS 2.4 — Alert Policy cho Project Ownership Changes"
  echo "  Lý do không tự động: Cần verify notification channel hoạt động"
  echo ""
  echo "  Kiểm tra alert policy:"
  step "gcloud alpha monitoring policies list --project=$PROJECT_ID \\"
  step "  --format='table(displayName,enabled,conditions[0].displayName)'"
  echo ""
  echo "  Kiểm tra notification channels:"
  step "gcloud alpha monitoring channels list --project=$PROJECT_ID \\"
  step "  --format='table(displayName,type,labels)'"
  echo ""
  echo "  Nếu policy bị disabled:"
  step "gcloud alpha monitoring policies update POLICY_ID --enabled"
  echo ""
  echo "  Verify email channel hoạt động:"
  step "Vào: https://console.cloud.google.com/monitoring/alerting?project=$PROJECT_ID"
  step "Kiểm tra: CIS 2.4 — Project Ownership Change Alert đang ENABLED"
  step "Test notification: Send test notification"
  echo ""
  C_STEPS="${C_STEPS}CIS 2.4: Verify alert policy enabled and notification channel working\n"
fi

# ── CIS 3.3 — DNSSEC ─────────────────────────────────────────────
if needs_fix "3.3"; then
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  manual "CIS 3.3 — DNSSEC cho Cloud DNS zones"
  echo "  Lý do không tự động: Cần terraform apply để đồng bộ state"
  echo ""
  echo "  Kiểm tra DNS zones hiện tại:"
  step "gcloud dns managed-zones list --project=$PROJECT_ID \\"
  step "  --format='table(name,dnsName,dnssecConfig.state)'"
  echo ""
  echo "  Fix qua Terraform (khuyến nghị):"
  step "Sửa terraform/vpc.tf:"
  step "  resource \"google_dns_managed_zone\" \"public\" {"
  step "    dnssec_config { state = \"on\" }"
  step "  }"
  step "Rồi: git add . && git commit -m 'fix: enable DNSSEC' && git push"
  step "WF3 sẽ tự apply"
  echo ""
  echo "  Fix trực tiếp (nếu khẩn cấp):"
  step "gcloud dns managed-zones update ZONE_NAME \\"
  step "  --dnssec-state=on --project=$PROJECT_ID"
  echo ""
  C_STEPS="${C_STEPS}CIS 3.3: Enable DNSSEC in vpc.tf and terraform apply\n"
fi

# ── CIS 3.6 — SSH 0.0.0.0/0 ─────────────────────────────────────
if needs_fix "3.6"; then
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  manual "CIS 3.6 — SSH không mở 0.0.0.0/0"
  echo "  Lý do không tự động: Cần biết IP hợp lệ của người dùng trước khi xóa rule"
  echo "  Cảnh báo: Nếu xóa nhầm rule có thể mất SSH access vào VM"
  echo ""
  echo "  Kiểm tra SSH rules hiện tại:"
  step "gcloud compute firewall-rules list --project=$PROJECT_ID \\"
  step "  --filter='allowed[].ports=22' \\"
  step "  --format='table(name,sourceRanges,targetTags)'"
  echo ""
  echo "  IP của bạn hiện tại:"
  step "curl -s ifconfig.me"
  echo ""
  echo "  Fix (thay YOUR_IP bằng IP thực):"
  step "# Bước 1: Tìm tên rule SSH"
  step "gcloud compute firewall-rules list --project=$PROJECT_ID \\"
  step "  --filter='name~ssh AND allowed[].ports=22'"
  echo ""
  step "# Bước 2: Update rule với IP cụ thể"
  step "gcloud compute firewall-rules update benchmark-allow-ssh \\"
  step "  --source-ranges=$ALLOWED_CLIENT_CIDR \\"
  step "  --project=$PROJECT_ID"
  echo ""
  step "# Hoặc sửa trong terraform.tfvars:"
  step "  allowed_client_cidr = \"$ALLOWED_CLIENT_CIDR\""
  step "Rồi push để WF3 apply"
  echo ""
  C_STEPS="${C_STEPS}CIS 3.6: Update SSH firewall rule source from 0.0.0.0/0 to specific IP: $ALLOWED_CLIENT_CIDR\n"
fi

# ── Summary ───────────────────────────────────────────────────────
echo "================================================================"
echo "  Nhóm C Summary"
echo "  Manual actions cần làm: $C_COUNT"
echo "================================================================"

if [ $C_COUNT -gt 0 ]; then
  echo ""
  echo "  Tóm tắt việc cần làm:"
  echo -e "$C_STEPS" | while read line; do
    [ -n "$line" ] && echo "  • $line"
  done
fi

echo "C_COUNT=$C_COUNT"     >> "${GITHUB_ENV:-/dev/null}" 2>/dev/null || true
echo "C_STEPS=$C_STEPS"     >> "${GITHUB_ENV:-/dev/null}" 2>/dev/null || true

# Nhóm C không fail dù có manual steps — đây là expected behavior
exit 0