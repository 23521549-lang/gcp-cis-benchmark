#!/bin/bash
# ================================================================
# Nhóm E — Security anomaly (IAM anomaly / Drift / SCC finding)
# ================================================================
set -uo pipefail

PROJECT_ID=$(gcloud config get-value project 2>/dev/null)
REGION="${REGION:-asia-southeast1}"
IAM_BASELINE="${IAM_BASELINE:-/tmp/iam_baseline_latest.json}"
IAM_CURRENT="${IAM_CURRENT:-/tmp/iam_snapshot.json}"

GREEN="\033[0;32m"; RED="\033[0;31m"; YELLOW="\033[0;33m"; RESET="\033[0m"
E_FIXED=false
E_MANUAL_STEPS=""

fixed()  { echo -e "${GREEN}[FIXED]${RESET} $1";   E_FIXED=true; }
manual() { echo -e "${YELLOW}[MANUAL]${RESET} $1"; E_MANUAL_STEPS="${E_MANUAL_STEPS}\n  - $1"; }
warn()   { echo -e "${YELLOW}[WARN]${RESET} $1"; }

echo "================================================================"
echo "  NHÓM E — Security Anomaly"
echo "  Project: $PROJECT_ID"
echo "================================================================"
echo ""

# ── E1: IAM Anomaly — Xóa binding không hợp lệ ──────────────────
IAM_ANOMALY="${IAM_ANOMALY:-false}"
if [ "$IAM_ANOMALY" = "true" ]; then
  echo "[ E1 ] IAM Anomaly — Phát hiện binding mới ngoài Terraform..."

  if [ -f "$IAM_BASELINE" ] && [ -f "$IAM_CURRENT" ]; then
    NEW_BINDINGS=$(python3 - << 'PYEOF'
import json, sys, os

with open(os.environ.get('IAM_BASELINE', '/tmp/iam_baseline_latest.json')) as f:
    baseline = json.load(f)
with open(os.environ.get('IAM_CURRENT', '/tmp/iam_snapshot.json')) as f:
    current = json.load(f)

def get_bindings(policy):
    result = set()
    for b in policy.get('bindings', []):
        role = b.get('role', '')
        for m in b.get('members', []):
            result.add(f"{m}|{role}")
    return result

baseline_set = get_bindings(baseline)
current_set  = get_bindings(current)
new_bindings = current_set - baseline_set

# Phân loại: HIGH risk (owner/editor) vs LOW risk
for b in sorted(new_bindings):
    member, role = b.split('|', 1)
    risk = 'HIGH' if any(r in role for r in ['owner','editor','admin','securityAdmin']) else 'LOW'
    print(f"{risk}|{member}|{role}")
PYEOF
)

    if [ -n "$NEW_BINDINGS" ]; then
      HIGH_BINDINGS=$(echo "$NEW_BINDINGS" | grep "^HIGH|" || true)
      LOW_BINDINGS=$(echo "$NEW_BINDINGS"  | grep "^LOW|"  || true)

      # Tự động xóa HIGH risk binding
      if [ -n "$HIGH_BINDINGS" ]; then
        echo "  HIGH RISK bindings — tự động xóa:"
        echo "$HIGH_BINDINGS" | while IFS='|' read RISK MEMBER ROLE; do
          echo "    Xóa: $MEMBER → $ROLE"
          gcloud projects remove-iam-policy-binding "$PROJECT_ID" \
            --member="$MEMBER" --role="$ROLE" --quiet 2>/dev/null \
            && echo -e "    ${GREEN}[FIXED]${RESET} Đã xóa binding nguy hiểm" \
            || echo -e "    ${RED}[ERROR]${RESET} Không xóa được — cần xử lý thủ công"
        done
        E_FIXED=true
      fi

      # LOW risk — chỉ cảnh báo + hướng dẫn
      if [ -n "$LOW_BINDINGS" ]; then
        echo "  LOW RISK bindings — cần xác nhận:"
        echo "$LOW_BINDINGS" | while IFS='|' read RISK MEMBER ROLE; do
          manual "Xác nhận binding hợp lệ không: $MEMBER → $ROLE"
          manual "Nếu không hợp lệ: gcloud projects remove-iam-policy-binding $PROJECT_ID --member=$MEMBER --role=$ROLE"
        done
      fi
    else
      echo "  Không tìm thấy binding bất thường sau khi kiểm tra lại"
    fi
  else
    warn "Không có baseline IAM để so sánh — chạy WF1 trước để tạo baseline"
    manual "Trigger WF1 để tạo IAM baseline mới"
  fi
fi

# ── E2: Terraform Drift — Import lại resource bị drift ───────────
DRIFT_DETECTED="${DRIFT_DETECTED:-false}"
if [ "$DRIFT_DETECTED" = "true" ]; then
  echo "[ E2 ] Terraform Drift — Resource bị thay đổi ngoài Terraform..."

  # Chạy terraform plan để phát hiện drift cụ thể
  if [ -d "terraform" ]; then
    DRIFT_PLAN=$(cd terraform && terraform plan \
      -var="db_username=${DB_USERNAME:-dummy}" \
      -var="db_password=${DB_PASSWORD:-dummy}" \
      -var="allowed_client_cidr=${ALLOWED_CLIENT_CIDR:-0.0.0.0/32}" \
      -no-color -input=false 2>&1 | grep "^  [~#]" | head -10 || echo "")

    if [ -n "$DRIFT_PLAN" ]; then
      echo "  Resources bị drift:"
      echo "$DRIFT_PLAN"
      manual "Xem chi tiết: cd terraform && terraform plan"
      manual "Nếu thay đổi không hợp lệ: terraform apply để đưa về đúng state"
      manual "Nếu thay đổi hợp lệ: terraform import resource_type.name <resource_id>"
    fi
  fi

  manual "Kiểm tra ai đã thay đổi resource: Cloud Audit Logs > activity"
  manual "URL: https://console.cloud.google.com/logs/query?project=$PROJECT_ID"
fi

# ── E3: SCC Finding HIGH severity ────────────────────────────────
SCC_FINDINGS="${SCC_FINDINGS:-}"
if [ -n "$SCC_FINDINGS" ]; then
  echo "[ E3 ] SCC Findings — GCP phát hiện security issue..."

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
      echo "  HIGH severity findings:"
      echo "$HIGH_FINDINGS" | while read LINE; do
        echo "    - $LINE"
        manual "Investigate SCC finding: $LINE"
      done
      manual "Chi tiết: https://console.cloud.google.com/security/command-center/findings?project=$PROJECT_ID"
    else
      echo "  Không có HIGH severity findings hiện tại"
      E_FIXED=true
    fi
  else
    manual "Enable Security Command Center: gcloud services enable securitycenter.googleapis.com --project=$PROJECT_ID"
  fi
fi

# ── Xuất kết quả ─────────────────────────────────────────────────
echo ""
echo "================================================================"
echo "  Nhóm E Summary"
echo "  E_FIXED: $E_FIXED"
[ -n "$E_MANUAL_STEPS" ] && echo -e "  Manual steps:$E_MANUAL_STEPS"
echo "================================================================"

echo "E_FIXED=$E_FIXED"         >> "${GITHUB_ENV:-/dev/null}" 2>/dev/null || true
echo "E_MANUAL=$E_MANUAL_STEPS" >> "${GITHUB_ENV:-/dev/null}" 2>/dev/null || true
exit 0