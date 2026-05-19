#!/bin/bash
# ================================================================
# CIS GCP Benchmark v4.0.0 — Domain 5: Storage
# CIS 5.1 / 5.2
# ================================================================
set -uo pipefail

PROJECT_ID=$(gcloud config get-value project 2>/dev/null)
[ -z "$PROJECT_ID" ] && echo "ERROR: Chưa set project." && exit 1

GREEN="\033[0;32m"; RED="\033[0;31m"; YELLOW="\033[0;33m"; RESET="\033[0m"
PASS=0; FAIL=0

pass() { echo -e "${GREEN}[PASS]${RESET} $1"; PASS=$((PASS+1)); }
fail() { echo -e "${RED}[FAIL]${RESET} $1"; FAIL=$((FAIL+1)); }
info() { echo -e "${YELLOW}      $1${RESET}"; }

echo "================================================================"
echo "  CIS STORAGE CHECK — PROJECT: $PROJECT_ID"
echo "================================================================"
echo ""

BUCKETS=$(gsutil ls -p "$PROJECT_ID" 2>/dev/null | sed 's|gs://||;s|/||' || echo "")

if [ -z "$BUCKETS" ]; then
  echo -e "${YELLOW}[INFO]${RESET} Không có bucket nào trong project"
  exit 0
fi

PUBLIC_FAIL=0; UNIFORM_FAIL=0
PUBLIC_PASS=0; UNIFORM_PASS=0

while IFS= read -r BUCKET; do
  [ -z "$BUCKET" ] && continue

  # ── CIS 5.1 — Bucket không public ──────────────────────────────
  IAM=$(gsutil iam get "gs://$BUCKET" 2>/dev/null || echo "{}")
  IS_PUBLIC=$(echo "$IAM" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    for b in data.get('bindings',[]):
        for m in b.get('members',[]):
            if m in ['allUsers','allAuthenticatedUsers']:
                print(f'{m}->{b[\"role\"]}')
except: pass
" 2>/dev/null || echo "")

  if [ -z "$IS_PUBLIC" ]; then
    PUBLIC_PASS=$((PUBLIC_PASS+1))
  else
    PUBLIC_FAIL=$((PUBLIC_FAIL+1))
    fail "5.1 Bucket '$BUCKET' có public access: $IS_PUBLIC"
    info "Fix: gsutil iam ch -d allUsers gs://$BUCKET"
  fi

  # ── CIS 5.2 — Uniform Bucket-Level Access ──────────────────────
  UNIFORM=$(gsutil uniformbucketlevelaccess get "gs://$BUCKET" 2>/dev/null | \
    grep -i "Enabled:" | awk '{print $2}' || echo "False")

  if [ "$UNIFORM" = "True" ]; then
    UNIFORM_PASS=$((UNIFORM_PASS+1))
  else
    UNIFORM_FAIL=$((UNIFORM_FAIL+1))
    fail "5.2 Bucket '$BUCKET' chưa bật Uniform Bucket-Level Access"
    info "Fix: gsutil uniformbucketlevelaccess set on gs://$BUCKET"
  fi
done <<< "$BUCKETS"

# Summary CIS 5.1
if [ "$PUBLIC_FAIL" -eq 0 ]; then
  pass "CIS 5.1: Tất cả bucket không public ($PUBLIC_PASS buckets kiểm tra)"
fi

# Summary CIS 5.2
if [ "$UNIFORM_FAIL" -eq 0 ]; then
  pass "CIS 5.2: Tất cả bucket có Uniform Bucket-Level Access ($UNIFORM_PASS buckets)"
fi

TOTAL=$((PASS+FAIL))
echo "================================================================"
if [ "$FAIL" -eq 0 ]; then
  echo -e "  ${GREEN}KẾT QUẢ: $PASS/$TOTAL PASS — Đạt chuẩn CIS Storage${RESET}"
else
  echo -e "  KẾT QUẢ: ${GREEN}$PASS PASS${RESET} | ${RED}$FAIL FAIL${RESET} (tổng $TOTAL tiêu chí)"
fi
echo "================================================================"
exit $FAIL