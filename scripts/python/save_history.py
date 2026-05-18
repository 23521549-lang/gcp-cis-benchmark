#!/usr/bin/env python3
"""
Lưu compliance history sau mỗi lần WF2 chạy
Đọc từ /tmp/cis_report.json, ghi ra /tmp/history_TIMESTAMP.json
"""
import json, os, sys

report_file = '/tmp/cis_report.json'
timestamp   = os.environ.get('TIMESTAMP', '')
drift       = os.environ.get('DRIFT_DETECTED', 'false') == 'true'
iam_anomaly = os.environ.get('IAM_ANOMALY',    'false') == 'true'
trigger     = os.environ.get('TRIGGER',        'WF2_scheduled')

if not os.path.exists(report_file):
    print("[WARN] Không tìm thấy cis_report.json — skip")
    sys.exit(0)

if not timestamp:
    from datetime import datetime, timezone
    timestamp = datetime.now(timezone.utc).strftime('%Y%m%d_%H%M%S')

with open(report_file) as f:
    report = json.load(f)

history = {
    'timestamp':           report.get('timestamp', ''),
    'trigger':             trigger,
    'compliance_rate':     report.get('compliance_rate', 0),
    'total':               report.get('total_controls', 29),
    'pass':                report.get('total_pass', 0),
    'fail':                report.get('total_fail', 0),
    'fail_controls':       report.get('fail_controls', []),
    'regression_controls': report.get('regression_controls', []),
    'drift_detected':      drift,
    'iam_anomaly':         iam_anomaly,
}

out_file = f"/tmp/history_{timestamp}.json"
with open(out_file, 'w') as f:
    json.dump(history, f, indent=2)

print(f"[OK] Saved: {out_file}")
print(f"     Rate: {history['compliance_rate']}% | PASS: {history['pass']} | FAIL: {history['fail']}")