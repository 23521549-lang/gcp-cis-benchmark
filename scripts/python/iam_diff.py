#!/usr/bin/env python3
"""
Phase 2c — IAM anomaly detection
So sánh IAM snapshot hiện tại với baseline
Exit 0 = không có anomaly
Exit 1 = phát hiện binding mới
"""
import json, sys, os

baseline_file = os.environ.get('IAM_BASELINE', '/tmp/iam_baseline_latest.json')
current_file  = os.environ.get('IAM_CURRENT',  '/tmp/iam_snapshot.json')

if not os.path.exists(baseline_file):
    print("[INFO] Baseline IAM chưa có — skip diff")
    sys.exit(0)

if not os.path.exists(current_file):
    print("[INFO] IAM snapshot hiện tại không có — skip diff")
    sys.exit(0)

with open(baseline_file) as f:
    baseline = json.load(f)
with open(current_file) as f:
    current = json.load(f)

def get_bindings(policy):
    result = set()
    for b in policy.get('bindings', []):
        role = b.get('role', '')
        for m in b.get('members', []):
            result.add(f"{m}|{role}")
    return result

baseline_bindings = get_bindings(baseline)
current_bindings  = get_bindings(current)
new_bindings      = current_bindings - baseline_bindings
removed_bindings  = baseline_bindings - current_bindings

if new_bindings:
    print("⚠ NEW BINDINGS (không có trong baseline):")
    for b in sorted(new_bindings):
        member, role = b.split('|', 1)
        print(f"  + {member} -> {role}")

if removed_bindings:
    print("ℹ REMOVED BINDINGS (có trong baseline nhưng không còn):")
    for b in sorted(removed_bindings):
        member, role = b.split('|', 1)
        print(f"  - {member} -> {role}")

if not new_bindings and not removed_bindings:
    print("✓ IAM bindings không thay đổi so với baseline")
    sys.exit(0)

sys.exit(1 if new_bindings else 0)