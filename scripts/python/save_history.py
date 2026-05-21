#!/usr/bin/env python3
"""
save_history.py
Save compliance history after each WF2 run
Reads from /tmp/cis_report.json
Writes to /tmp/history_TIMESTAMP.json
"""
import json
import os
import sys
from datetime import datetime, timezone

REPORT_FILE = '/tmp/cis_report.json'
TIMESTAMP   = os.environ.get('TIMESTAMP', '')
DRIFT       = os.environ.get('DRIFT_DETECTED', 'false') == 'true'
IAM_ANOMALY = os.environ.get('IAM_ANOMALY',    'false') == 'true'
TRIGGER     = os.environ.get('TRIGGER',        'WF2_scheduled')

SEP = "────────────────────────────────────────────────────────────"

if not os.path.exists(REPORT_FILE):
    print("WARN     cis_report.json not found — skipping history save")
    sys.exit(0)

if not TIMESTAMP:
    TIMESTAMP = datetime.now(timezone.utc).strftime('%Y%m%d_%H%M%S')

with open(REPORT_FILE) as f:
    report = json.load(f)

history = {
    'timestamp':           report.get('timestamp', ''),
    'trigger':             TRIGGER,
    'compliance_rate':     report.get('compliance_rate', 0),
    'total':               report.get('total_controls', 29),
    'pass':                report.get('total_pass', 0),
    'fail':                report.get('total_fail', 0),
    'fail_controls':       report.get('fail_controls', []),
    'regression_controls': report.get('regression_controls', []),
    'drift_detected':      DRIFT,
    'iam_anomaly':         IAM_ANOMALY,
}

out_file = f"/tmp/history_{TIMESTAMP}.json"
with open(out_file, 'w') as f:
    json.dump(history, f, indent=2)

print(SEP)
print(f"OK       History saved: {out_file}")
print(f"         Rate: {history['compliance_rate']}%"
      f" | Pass: {history['pass']}"
      f" | Fail: {history['fail']}")
print(SEP)