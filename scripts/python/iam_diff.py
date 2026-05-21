#!/usr/bin/env python3
"""
iam_diff.py
Phase 2c — IAM Anomaly Detection
Compare current IAM snapshot against baseline
Exit 0 = no anomaly detected
Exit 1 = new bindings detected (possible unauthorized change)
"""
import json
import sys
import os

BASELINE_FILE = os.environ.get('IAM_BASELINE', '/tmp/iam_baseline_latest.json')
CURRENT_FILE  = os.environ.get('IAM_CURRENT',  '/tmp/iam_snapshot.json')

SEP = "────────────────────────────────────────────────────────────"

def header(title):
    print(SEP)
    print(f" IAM-DIFF {title}")
    print(SEP)

def get_bindings(policy):
    result = set()
    for b in policy.get('bindings', []):
        role = b.get('role', '')
        for m in b.get('members', []):
            result.add(f"{m}|{role}")
    return result

header("IAM Anomaly Detection")

if not os.path.exists(BASELINE_FILE):
    print("INFO     Baseline IAM not found — skipping diff")
    print("         Run WF1 to create initial baseline")
    sys.exit(0)

if not os.path.exists(CURRENT_FILE):
    print("INFO     Current IAM snapshot not found — skipping diff")
    sys.exit(0)

with open(BASELINE_FILE) as f:
    baseline = json.load(f)
with open(CURRENT_FILE) as f:
    current = json.load(f)

baseline_bindings = get_bindings(baseline)
current_bindings  = get_bindings(current)
new_bindings      = current_bindings - baseline_bindings
removed_bindings  = baseline_bindings - current_bindings

if new_bindings:
    print(f"WARN     New bindings not in baseline: {len(new_bindings)}")
    for b in sorted(new_bindings):
        member, role = b.split('|', 1)
        risk = "HIGH" if any(r in role for r in
               ['owner','editor','admin','securityAdmin']) else "LOW"
        print(f"         [{risk}] {member} -> {role}")

if removed_bindings:
    print(f"INFO     Removed bindings (in baseline, not in current): {len(removed_bindings)}")
    for b in sorted(removed_bindings):
        member, role = b.split('|', 1)
        print(f"         [-] {member} -> {role}")

if not new_bindings and not removed_bindings:
    print("OK       IAM bindings unchanged from baseline")
    print(f"         Total bindings: {len(current_bindings)}")
    sys.exit(0)

print(SEP)
sys.exit(1 if new_bindings else 0)