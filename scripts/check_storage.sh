#!/bin/bash
# ================================================================
# CIS GCP Benchmark v4.0.0 — Domain 5: Storage
# CIS 5.1 — Bucket không public/anonymous
# CIS 5.2 — Uniform Bucket-Level Access bật
# ================================================================

set -euo pipefail
PROJECT_ID=$(gcloud config get-value project 2>/dev/null)

if [ -z "$PROJECT_ID" ]; then
  echo "ERROR: Chưa set project."
  exit 1
fi

GREEN="\033[0;32m"; RED="\033[0;31m"; YELLOW="\033[0;33m"; RESET="\033[0m"
PASS=0; FAIL=0

pass() { echo -e "${GREEN}[PASS]${RESET} $1"; PASS=$((PASS+1)); }
fail() { echo -e "${RED}[FAIL]${RESET} $1"; FAIL=$((FAIL+1)); }
info() { echo -e "${YELLOW}      $1${RESET}"; }

echo "================================================================"
echo "  CIS STORAGE CHECK — PROJECT: $PROJECT_ID"
echo "================================================================"
echo ""

# Lấy danh sách tất cả buckets
BUCKETS=$(gsutil ls -p "$PROJECT_ID" 2>/dev/null | sed 's|gs://||' | sed 's|/||')

if [ -z "$BUCKETS" ]; then
  echo -e "${YELLOW}[INFO]${RESET} Không có bucket nào trong project"
  exit 0
fi

PUBLIC_FAIL=0
UNIFORM_FAIL=0
PUBLIC_PASS=0
UNIFORM_PASS=0

while read BUCKET; do
  # ----------------------------------------------------------------
  # CIS 5.1 — Bucket không public/anonymous
  # ----------------------------------------------------------------
  IAM=$(gsutil iam get "gs://$BUCKET" 2>/dev/null)
  IS_PUBLIC=$(echo "$IAM" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    public_members = ['allUsers', 'allAuthenticatedUsers']
    for b in data.get('bindings', []):
        for m in b.get('members', []):
            if m in public_members:
                print(f'PUBLIC:{m}->{b[\"role\"]}')
except: pass
")

  if [ -z "$IS_PUBLIC" ]; then
    PUBLIC_PASS=$((PUBLIC_PASS+1))
  else
    PUBLIC_FAIL=$((PUBLIC_FAIL+1))
    fail "Bucket '$BUCKET' có public access: $IS_PUBLIC"
    info "Sửa: gsutil iam ch -d allUsers:objectViewer gs://$BUCKET"
  fi

  # ----------------------------------------------------------------
  # CIS 5.2 — Uniform Bucket-Level Access
  # ----------------------------------------------------------------
  UNIFORM=$(gsutil uniformbucketlevelaccess get "gs://$BUCKET" 2>/dev/null | \
    grep -i "Enabled:" | awk '{print $2}')

  if [ "$UNIFORM" = "True" ]; then
    UNIFORM_PASS=$((UNIFORM_PASS+1))
  else
    UNIFORM_FAIL=$((UNIFORM_FAIL+1))
    fail "Bucket '$BUCKET' chưa bật Uniform Bucket-Level Access"
    info "Sửa: gsutil uniformbucketlevelaccess set on gs://$BUCKET"
    info "   hoặc: storage buckets update gs://$BUCKET --uniform-bucket-level-access"
  fi
done <<< "$BUCKETS"

# CIS 5.1 summary
if [ "$PUBLIC_FAIL" -eq 0 ]; then
  pass "CIS 5.1: Tất cả bucket không public ($PUBLIC_PASS buckets kiểm tra)"
else
  PASS_TEMP=$PASS
  PASS=$((PASS+PUBLIC_PASS > 0 ? 0 : 0))  # đã tính fail ở trên
fi

# CIS 5.2 summary
if [ "$UNIFORM_FAIL" -eq 0 ]; then
  pass "CIS 5.2: Tất cả bucket có Uniform Bucket-Level Access ($UNIFORM_PASS buckets)"
fi

[ "$PUBLIC_FAIL" -gt 0 ] && FAIL=$((FAIL+1))
[ "$UNIFORM_FAIL" -gt 0 ] && FAIL=$((FAIL+1))

echo ""
TOTAL=$((PASS+FAIL))
echo "================================================================"
if [ "$FAIL" -eq 0 ]; then
  echo -e "  ${GREEN}KẾT QUẢ: $PASS/$TOTAL PASS — Đạt chuẩn CIS Storage${RESET}"
else
  echo -e "  KẾT QUẢ: ${GREEN}$PASS PASS${RESET} | ${RED}$FAIL FAIL${RESET} (tổng $TOTAL tiêu chí)"
fi
echo "================================================================"
exit $FAIL