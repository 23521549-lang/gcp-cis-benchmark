#!/bin/bash
# ================================================================
# Scenario 2 — Phát hiện vi phạm và tự phục hồi
# WF2 phát hiện regression → trigger WF4 → Nhóm A tự fix
# Vi phạm: CIS 4.3 + 4.4 + 4.5 (VM metadata)
# ================================================================

BOLD="\033[1m"; CYAN="\033[0;36m"; YELLOW="\033[0;33m"
GREEN="\033[0;32m"; RED="\033[0;31m"; RESET="\033[0m"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"

PROJECT_ID=$(gcloud config get-value project 2>/dev/null)
VM_NAME="benchmark-vm-01"
VM_ZONE="asia-southeast1-b"

clear
echo -e "${CYAN}${BOLD}"
echo "  ╔══════════════════════════════════════════════════════════╗"
echo "  ║  Scenario 2 — Phát hiện vi phạm và tự phục hồi           ║"
echo "  ║  WF2 → phát hiện FAIL → trigger WF4 → Nhóm A tự fix      ║"
echo "  ╚══════════════════════════════════════════════════════════╝"
echo -e "${RESET}"

echo -e "  Mục tiêu:"
echo -e "  Chứng minh hệ thống tự phát hiện vi phạm CIS và tự fix"
echo -e "  hoàn toàn tự động, không cần can thiệp thủ công."
echo ""
echo -e "  Vi phạm tạo ra:  CIS 4.3 + 4.4 + 4.5 (VM metadata)"
echo -e "  WF4 nhóm:        ${GREEN}${BOLD}Nhóm A — gcloud script tự động${RESET}"
echo -e "  Kết quả mong đợi: ${GREEN}${BOLD}WF4 fix xong → 21/21 PASS${RESET}"
echo ""

echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo -e "${YELLOW}  Step 1/5 — Tạo vi phạm CIS${RESET}"
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo ""
echo -e "  Đang tạo 3 vi phạm trên VM ${BOLD}$VM_NAME${RESET}..."
echo ""

gcloud compute instances add-metadata "$VM_NAME" \
  --zone="$VM_ZONE" \
  --project="$PROJECT_ID" \
  --metadata=serial-port-enable=true,block-project-ssh-keys=false,enable-oslogin=false \
  --quiet 2>/dev/null

echo -e "  ${RED}✘${RESET}  CIS 4.5 — serial-port-enable  = true   (vi phạm)"
echo -e "  ${RED}✘${RESET}  CIS 4.3 — block-project-ssh-keys = false (vi phạm)"
echo -e "  ${RED}✘${RESET}  CIS 4.4 — enable-oslogin        = false  (vi phạm)"
echo ""

echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo -e "${YELLOW}  Step 2/5 — Xác nhận vi phạm tồn tại${RESET}"
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo ""
echo -e "  Chạy CIS VM check để xác nhận vi phạm..."
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
echo -e "  → Phát hiện CIS 4.3 + 4.4 + 4.5 FAIL"
echo -e "  → Tự động trigger WF4 — Intelligent Recovery"
echo ""
echo "  Nhấn Enter khi WF2 đã bắt đầu chạy..."
read -r

echo ""
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo -e "${YELLOW}  Step 4/5 — Theo dõi WF4 Nhóm A tự fix${RESET}"
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo ""
echo -e "  Vào Actions → ${BOLD}WF4 — Intelligent Recovery${RESET} để theo dõi:"
echo ""
echo -e "  WF4 Nhóm A đang tự fix:"
echo -e "  → gcloud instances add-metadata serial-port-enable=false"
echo -e "  → gcloud instances add-metadata block-project-ssh-keys=true"
echo -e "  → gcloud instances add-metadata enable-oslogin=true"
echo -e "  → Chạy post-recovery CIS check"
echo ""
echo -e "  Thời gian dự kiến: ~3 phút"
echo ""
echo "  Nhấn Enter khi WF4 đã hoàn thành..."
read -r

echo ""
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo -e "${YELLOW}  Step 5/5 — Xác nhận đã fix và đạt 100%${RESET}"
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo ""
bash "$ROOT_DIR/tests/verify_fix.sh" 2
echo ""
bash "$ROOT_DIR/scripts/cis_full_check.sh"