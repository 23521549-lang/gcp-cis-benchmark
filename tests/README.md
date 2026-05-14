# Test Scenarios — WF4 Intelligent Recovery

This directory contains scripts to simulate CIS compliance violations
and verify that the 4-workflow system responds correctly.

---

## Directory Structure

```text
tests/
├── README.md
├── create_violation.sh       # Create CIS violations on GCP
├── verify_fix.sh             # Verify WF4 fixed the violations
└── scenarios/
    ├── scenario_1.sh         # KB1 — Happy path (WF1 + 100% CIS)
    ├── scenario_2.sh         # KB2 — WF2 detects → WF4 Group A auto-fix
    ├── scenario_3.sh         # KB3 — WF2 detects → WF4 Group B Ansible
    └── scenario_4.sh         # KB4 — WF4 Group C manual email guidance
```

---

## How the Test Flow Works

The scenario scripts are **guided walkthroughs** — they print
step-by-step instructions and pause at key moments for you to
interact with GitHub Actions. The actual remediation is done
by WF4 on GitHub Actions, not by the scripts themselves.

```text
scenario_X.sh              GitHub Actions              verify_fix.sh
─────────────              ──────────────              ─────────────
Print instructions    →    WF2 detects FAIL       →    Confirm fixed
Create violation           triggers WF4
Pause and wait             WF4 remediates
                           (Group A / B / C)
```

---

## The 4 Scenarios

### Scenario 1 — Happy Path

**Goal:** Prove the system deploys infrastructure and passes
all 23 CIS controls automatically with a single button press.

**What happens:**

- Trigger WF1 on GitHub Actions
- Watch Terraform deploy all infrastructure
- CIS Full Check runs automatically
- Expected result: 21/21 PASS (100%)

**No violation created.** This scenario shows the baseline
healthy state of the system.

```bash
bash tests/scenarios/scenario_1.sh
```

---

### Scenario 2 — Detect and Auto-recover (Group A)

**Goal:** Prove WF2 detects regressions and WF4 fixes them
automatically without any human intervention.

**Violations created:** CIS 4.3 + 4.4 + 4.5 (VM metadata)

| Control | Violation                      | Fix method             |
| ------- | ------------------------------ | ---------------------- |
| CIS 4.5 | serial-port-enable = true      | gcloud metadata update |
| CIS 4.3 | block-project-ssh-keys = false | gcloud metadata update |
| CIS 4.4 | enable-oslogin = false         | gcloud metadata update |

**WF4 Group A** — fully automated via gcloud script. No VM restart needed.
Expected duration: ~3 minutes.

```bash
bash tests/scenarios/scenario_2.sh
```

---

### Scenario 3 — Serious Violation requiring Ansible (Group B)

**Goal:** Prove WF4 handles complex violations that require
stopping and restarting the VM safely through Ansible.

**Violation created:** CIS 4.1 + 4.2 (VM using Default SA)

| Control | Violation                         | Fix method                      |
| ------- | --------------------------------- | ------------------------------- |
| CIS 4.1 | VM using Default Compute SA       | Ansible: stop → swap SA → start |
| CIS 4.2 | Default SA with Full Access scope | Resolved together with 4.1      |

**WF4 Group B** — Ansible manages VM lifecycle. Idempotent and
safe to retry if interrupted. VM will be briefly stopped (~2 minutes).
Expected duration: ~5-8 minutes.

**Note:** Requires `VM_SSH_KEY` secret configured in GitHub.

```bash
bash tests/scenarios/scenario_3.sh
```

---

### Scenario 4 — Manual Guidance via Email (Group C)

**Goal:** Prove the system knows its own limits — controls that
require human confirmation are never auto-fixed. Instead, WF4
sends a step-by-step email with exact commands.

**No violation created.** WF4 is triggered directly with manual inputs.

Controls covered by Group C:

| Control | Why manual                                        |
| ------- | ------------------------------------------------- |
| CIS 1.6 | Need to verify which IAM bindings are legitimate  |
| CIS 2.3 | Bucket lock is irreversible — must confirm        |
| CIS 2.4 | Need to verify email channel is receiving alerts  |
| CIS 3.3 | DNSSEC needs DNS propagation test before enabling |
| CIS 3.6 | SSH firewall — must verify IP before changing     |

```bash
bash tests/scenarios/scenario_4.sh
```

---

## Running Individual Steps

If you want to run steps manually instead of using the scenario scripts:

```bash
# Step 1: Create violation
bash tests/create_violation.sh [1|2|3]

# Step 2: Trigger WF2 on GitHub Actions
# Go to: Actions → WF2 — Scheduled CIS Monitor → Run workflow

# Step 3: Wait for WF4 to complete

# Step 4: Verify the fix
bash tests/verify_fix.sh [1|2|3]
```

---

## Violation Reference

| Arg | Controls    | Violation created        | WF4 group |
| --- | ----------- | ------------------------ | --------- |
| `1` | 4.3 4.4 4.5 | VM metadata disabled     | A         |
| `2` | 4.3 4.4 4.5 | Same as above            | A         |
| `3` | 4.1 4.2     | VM swapped to Default SA | B         |

---

## Manual Cleanup

If WF4 does not trigger or fails mid-way, restore manually:

```bash
PROJECT_ID=$(gcloud config get-value project)
VM="benchmark-vm-01"
ZONE="asia-southeast1-b"

# Restore VM metadata (Scenario 2)
gcloud compute instances add-metadata $VM \
  --zone=$ZONE \
  --project=$PROJECT_ID \
  --metadata=serial-port-enable=false,block-project-ssh-keys=true,enable-oslogin=true

# Restore Custom SA (Scenario 3)
gcloud compute instances stop $VM --zone=$ZONE --project=$PROJECT_ID --quiet
gcloud compute instances set-service-account $VM \
  --zone=$ZONE \
  --project=$PROJECT_ID \
  --service-account=app-least-privilege-sa@${PROJECT_ID}.iam.gserviceaccount.com \
  --scopes=cloud-platform \
  --quiet
gcloud compute instances start $VM --zone=$ZONE --project=$PROJECT_ID --quiet
```

---

## Prerequisites

```bash
# Authenticate with GCP
gcloud auth login
gcloud config set project <YOUR_PROJECT_ID>

# Verify VM is accessible
gcloud compute instances list --project=<YOUR_PROJECT_ID>
```
