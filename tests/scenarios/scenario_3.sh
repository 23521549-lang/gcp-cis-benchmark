#!/bin/bash
# ================================================================
# Scenario 3 — Vi phạm nghiêm trọng cần Ansible
# WF2 phát hiện → trigger WF4 → Nhóm B: Ansible stop/swap/start VM
# Vi phạm: CIS 4.1 + 4.2 (VM dùng Default SA)
# ================================================================

BOLD="\033[1m"; CYAN="\033[0;36m"; YELLOW="\033[0;33m"
GREEN="\033[0;32m"; RED="\033[0;31m"; RESET="\033[0m"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"

PROJECT_ID=$(gcloud config get-value project 2>/dev/null)
VM_NAME="benchmark-vm-01"
VM_ZONE="asia-southeast1-b"
PROJECT_NUMBER=$(gcloud projects describe "$PROJECT_ID" \
  --format="value(projectNumber)" 2>/dev/null)
DEFAULT_SA="${PROJECT_NUMBER}-compute@developer.gserviceaccount.com"
CUSTOM_SA="app-least-privilege-sa@${PROJECT_ID}.iam.gserviceaccount.com"

clear
echo -e "${CYAN}${BOLD}"
echo "  ╔══════════════════════════════════════════════════════════╗"
echo "  ║  Scenario 3 — Vi phạm nghiêm trọng cần Ansible           ║"
echo "  ║  WF2 → WF4 Nhóm B → Ansible stop/swap SA/start VM        ║"
echo "  ╚══════════════════════════════════════════════════════════╝"
echo -e "${RESET}"

echo -e "  Mục tiêu:"
echo -e "  Chứng minh WF4 xử lý vi phạm phức tạp cần stop/start VM"
echo -e "  thông qua Ansible — idempotent và an toàn."
echo ""
echo -e "  Vi phạm tạo ra:  CIS 4.1 + 4.2 (VM dùng Default SA)"
echo -e "  WF4 nhóm:        ${YELLOW}${BOLD}Nhóm B — Ansible lifecycle management${RESET}"
echo -e "  Kết quả mong đợi: ${GREEN}${BOLD}VM dùng Custom SA → 21/21 PASS${RESET}"
echo ""
echo -e "  ${RED}Lưu ý: VM sẽ bị stop trong ~2 phút trong quá trình fix.${RESET}"
echo ""
echo "  Nhấn Enter để bắt đầu hoặc Ctrl+C để hủy..."
read -r

echo ""
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo -e "${YELLOW}  Step 1/5 — Tạo vi phạm CIS 4.1 + 4.2${RESET}"
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo ""
echo -e "  Đang swap VM sang Default SA..."
echo -e "  (cần stop VM trước khi thay SA)"
echo ""

gcloud compute instances stop "$VM_NAME" \
  --zone="$VM_ZONE" \
  --project="$PROJECT_ID" \
  --quiet 2>/dev/null

echo -n "  Chờ VM stop"
until [ "$(gcloud compute instances describe "$VM_NAME" \
  --zone="$VM_ZONE" --project="$PROJECT_ID" \
  --format="value(status)" 2>/dev/null)" = "TERMINATED" ]; do
  echo -n "."
  sleep 5
done
echo " done"

gcloud compute instances set-service-account "$VM_NAME" \
  --zone="$VM_ZONE" \
  --project="$PROJECT_ID" \
  --service-account="$DEFAULT_SA" \
  --scopes=cloud-platform \
  --quiet 2>/dev/null

gcloud compute instances start "$VM_NAME" \
  --zone="$VM_ZONE" \
  --project="$PROJECT_ID" \
  --quiet 2>/dev/null

echo -n "  Chờ VM start"
until [ "$(gcloud compute instances describe "$VM_NAME" \
  --zone="$VM_ZONE" --project="$PROJECT_ID" \
  --format="value(status)" 2>/dev/null)" = "RUNNING" ]; do
  echo -n "."
  sleep 5
done
echo " done"

echo ""
echo -e "  ${RED}✘${RESET}  CIS 4.1 — VM đang dùng Default SA: $DEFAULT_SA"
echo -e "  ${RED}✘${RESET}  CIS 4.2 — Default SA với Full Access scope"
echo ""

echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo -e "${YELLOW}  Step 2/5 — Xác nhận vi phạm tồn tại${RESET}"
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo ""
bash "$ROOT_DIR/scripts/check_vm.sh" 2>/dev/null || true
echo ""

echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo -e "${YELLOW}  Step 3/5 — Trigger WF2 để phát hiện và kích hoạt WF4${RESET}"
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo ""
echo -e "  1. Vào GitHub Actions"
echo -e "  2. Chọn ${BOLD}WF2 — Scheduled CIS Monitor${RESET}"
echo -e "  3. Bấm ${BOLD}Run workflow${RESET} → ${BOLD}Run workflow${RESET}"
echo ""
echo -e "  WF2 sẽ:"
echo -e "  → Phát hiện CIS 4.1 + 4.2 FAIL"
echo -e "  → Tự động trigger WF4 — Intelligent Recovery"
echo ""
echo "  Nhấn Enter khi WF2 đã bắt đầu chạy..."
read -r

echo ""
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo -e "${YELLOW}  Step 4/5 — Theo dõi WF4 Nhóm B (Ansible)${RESET}"
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo ""
echo -e "  Vào Actions → ${BOLD}WF4 — Intelligent Recovery${RESET} để theo dõi:"
echo ""
echo -e "  WF4 Nhóm B — Ansible đang xử lý:"
echo -e "  → ansible-playbook fix_vm_sa.yml"
echo -e "  → Stop VM benchmark-vm-01"
echo -e "  → Swap SA: Default → app-least-privilege-sa"
echo -e "  → Start VM benchmark-vm-01"
echo -e "  → Verify SA đã thay thành công"
echo ""
echo -e "  Thời gian dự kiến: ~5-8 phút"
echo ""
echo "  Nhấn Enter khi WF4 đã hoàn thành..."
read -r

echo ""
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo -e "${YELLOW}  Step 5/5 — Xác nhận đã fix và đạt 100%${RESET}"
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo ""
bash "$ROOT_DIR/tests/verify_fix.sh" 3
echo ""
bash "$ROOT_DIR/scripts/cis_full_check.sh"