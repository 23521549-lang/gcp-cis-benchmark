#!/bin/bash
# ================================================================
# Scenario 1 — Happy Path
# Chứng minh toàn bộ hệ thống deploy và đạt chuẩn CIS 100%
# tự động chỉ với 1 lần bấm nút trên GitHub Actions
# ================================================================

BOLD="\033[1m"; CYAN="\033[0;36m"; YELLOW="\033[0;33m"
GREEN="\033[0;32m"; RESET="\033[0m"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"

clear
echo -e "${CYAN}${BOLD}"
echo "  ╔══════════════════════════════════════════════════════════╗"
echo "  ║  Scenario 1 — Happy Path                                 ║"
echo "  ║  WF1: Deploy toàn bộ hạ tầng + CIS check tự động         ║"
echo "  ╚══════════════════════════════════════════════════════════╝"
echo -e "${RESET}"

echo -e "  Mục tiêu:"
echo -e "  Chứng minh hệ thống deploy và kiểm tra 23 tiêu chuẩn CIS"
echo -e "  hoàn toàn tự động chỉ với 1 lần bấm nút."
echo ""
echo -e "  Kết quả mong đợi: ${GREEN}${BOLD}21/21 PASS (100%)${RESET}"
echo ""

echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo -e "${YELLOW}  Step 1/3 — Trigger WF1 trên GitHub Actions${RESET}"
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo ""
echo -e "  1. Vào repo GitHub"
echo -e "  2. Bấm tab ${BOLD}Actions${RESET}"
echo -e "  3. Chọn ${BOLD}WF1 — Initial Deploy & Bootstrap${RESET}"
echo -e "  4. Bấm ${BOLD}Run workflow${RESET} → ${BOLD}Run workflow${RESET}"
echo ""
echo -e "  WF1 sẽ chạy tự động theo thứ tự:"
echo -e "  Checkout → Auth GCP → Terraform Init → Plan → Apply → CIS Check"
echo ""
echo "  Nhấn Enter khi WF1 đã bắt đầu chạy..."
read -r

echo ""
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo -e "${YELLOW}  Step 2/3 — Theo dõi WF1 chạy${RESET}"
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo ""
echo -e "  Quan sát các step trên GitHub Actions:"
echo ""
echo -e "  ✔  Checkout"
echo -e "  ✔  Auth GCP"
echo -e "  ✔  Setup Terraform"
echo -e "  ✔  Terraform Init"
echo -e "  ✔  Terraform Validate"
echo -e "  ✔  Terraform Plan"
echo -e "  ✔  Terraform Apply     ← tạo toàn bộ hạ tầng GCP"
echo -e "  ✔  Run CIS Full Check  ← kiểm tra 23 tiêu chuẩn"
echo ""
echo "  Nhấn Enter khi WF1 đã hoàn thành..."
read -r

echo ""
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo -e "${YELLOW}  Step 3/3 — Xác nhận kết quả 100%${RESET}"
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo ""
echo -e "  Nhìn vào log WF1 trên GitHub Actions:"
echo -e "  → Deploy Summary: PASS"
echo -e "  → Compliance: 21 PASS / 0 FAIL (100%)"
echo ""
echo -e "  ${GREEN}${BOLD}Kịch bản 1 hoàn thành.${RESET}"