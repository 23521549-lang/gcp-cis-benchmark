# GCP CIS Benchmark — Automated Compliance & Self-Healing

[![CIS](https://img.shields.io/badge/CIS-GCP%20Foundation%20v4.0.0-blue?style=flat-square)](https://www.cisecurity.org)
[![Terraform](https://img.shields.io/badge/Terraform-%E2%89%A5%201.7-7B42BC?style=flat-square&logo=terraform)](https://www.terraform.io)
[![WF1 Deploy](https://img.shields.io/github/actions/workflow/status/23521549-lang/gcp-cis-benchmark/wf1_deploy.yml?label=WF1%20Deploy&style=flat-square)](../../actions/workflows/wf1_deploy.yml)
[![WF2 Monitor](https://img.shields.io/github/actions/workflow/status/23521549-lang/gcp-cis-benchmark/wf2_monitor.yml?label=WF2%20Monitor&style=flat-square)](../../actions/workflows/wf2_monitor.yml)

**Compliance as Code** for Google Cloud Platform: Terraform deploys infrastructure that is compliant by design with the **CIS GCP Foundation Benchmark v4.0.0**, Bash auditors verify the *live* environment **every 6 hours**, and an intelligent recovery workflow **fixes violations automatically** — with loop protection, drift detection, and human-in-the-loop escalation for risky changes.

```text
Deploy (Terraform) ──► Audit (Bash, 6 domains) ──► Regression detected
        ▲                                                │
        │                                                ▼
        └──── Auto-remediate (gcloud / Ansible) ◄── Classify & target
                        │                          (only failed controls)
                        ├── loop detected? ──► abort + alert (Group G)
                        └── high-risk?     ──► email step-by-step runbook
                                               (human-in-the-loop, Group C)
```

---

## Table of Contents

- [Control Coverage](#control-coverage)
- [How It Works](#how-it-works)
- [The Four Workflows](#the-four-workflows)
- [Recovery Engine — 8 Groups](#recovery-engine--8-groups)
- [Test Scenarios](#test-scenarios)
- [Repository Layout](#repository-layout)
- [Setup](#setup)
- [Running Locally](#running-locally)

---

## Control Coverage

Audits **6 domains** of CIS GCP Foundation Benchmark v4.0.0 — 23 core controls plus the Cloud SQL domain:

| Domain | Controls | Enforced by (Terraform) |
|---|---|---|
| 1 — Identity & Access Management | 1.4, 1.5, 1.6, 1.10, 1.14 | `security_iam.tf`, `security_kms.tf`, `security_apikey.tf` |
| 2 — Logging & Monitoring | 2.1, 2.2, 2.3, 2.4, 2.12, 2.13 | `logging.tf`, `storage.tf`, `vpc.tf` |
| 3 — Networking | 3.1, 3.3, 3.6, 3.7, 3.8 | `vpc.tf` |
| 4 — Virtual Machines | 4.1, 4.2, 4.3, 4.4, 4.5 | `vm.tf` |
| 5 — Storage | 5.1, 5.2 | `storage.tf` |
| 6 — Cloud SQL (PostgreSQL) | 6.4, 6.2.1–6.2.4, 6.2.8 | `db.tf` |

Each control is implemented **twice, independently**: enforced in Terraform and verified by a separate Bash auditor against the live environment via `gcloud` — so a compliant deploy is proven, not assumed.

---

## How It Works

1. **Deploy** — Terraform provisions the full environment (VPC, VMs, Cloud SQL PostgreSQL, Cloud Storage, KMS, audit logging), state in a GCS backend.
2. **Audit** — `cis_full_check.sh` runs six per-domain checkers (`check_iam.sh`, `check_networking.sh`, …), parses PASS/FAIL per control, and emits a JSON compliance report plus a **targeted fail list**.
3. **Baseline & drift** — reports and IAM snapshots are versioned in GCS; Python utilities (`iam_diff.py`, `save_history.py`) compare current state against baseline to detect **unauthorized IAM changes and Terraform drift**.
4. **Monitor** — a cron workflow re-audits every 6 hours: fully compliant → silent; regression → recovery is dispatched automatically with context (fail count, trigger reason).
5. **Recover** — the recovery engine remediates by group (below), waits 120s for GCP propagation, then **re-audits to verify** the fix, and emails a report: what failed, what was fixed, what needs a human.

---

## The Four Workflows

| Workflow | Trigger | Purpose |
|---|---|---|
| **WF1 — Deploy** | push to `main` | `terraform plan/apply` + full CIS audit; failures dispatch WF4 |
| **WF2 — Monitor** | cron `0 */6 * * *` | Continuous compliance check; alert-only-on-failure (silent when green) |
| **WF3 — Safe Upgrade** | push after first deploy | Detects which CIS **domains** a change affects; plans, applies, and re-verifies only those |
| **WF4 — Recovery** | dispatched by WF1/WF2/WF3, or manual (with **dry-run mode**) | Tiered remediation engine below |

---

## Recovery Engine — 8 Groups

The core design decision: **not every failure should be fixed the same way — and some should not be auto-fixed at all.**

| Group | Scope | Strategy |
|---|---|---|
| **A** | CIS misconfigurations (IAM, logging, networking, VM, storage, SQL) | Idempotent `gcloud` remediation, **targeted by fail list** — only failed controls are touched; supports `DRY_RUN` |
| **B** | CIS 4.1 / 4.2 — VM service-account swap | **Ansible playbook**: checks current SA, stops the VM only if needed, swaps SA, restarts — fully idempotent |
| **C** | 5 high-risk controls (1.6, 2.3, 2.4, 3.3, 3.6) | **Never auto-applied** — emails a step-by-step remediation runbook (human-in-the-loop) |
| **D** | Terraform failures | Classifies error type (`CONFLICT / PERMISSION / QUOTA / TIMEOUT / STALE_PLAN / UNKNOWN`) and applies the matching recovery |
| **E** | Security anomalies | IAM diff vs. baseline (unauthorized bindings) + Terraform drift detection |
| **F** | Pipeline errors | GCP auth validation, missing-baseline bootstrap |
| **G** | Safety guards | **Recovery-loop detection** (counter in GCS — aborts instead of looping forever) + false-positive detection |
| **H** | Operations | SLA-breach check and compliance-trend analysis over report history |

Every recovery run: pre-check → remediate → **wait 120s for propagation** → post-check verification → email report.

---

## Test Scenarios

`tests/` contains guided end-to-end scenarios that **deliberately break compliance** and verify the system heals itself:

```text
scenario_1.sh   Happy path — one-click deploy reaches 100% CIS compliance
scenario_2.sh   Inject violation → WF2 detects → WF4 Group A auto-fixes
scenario_3.sh   VM service-account violation → WF4 Group B (Ansible) fixes
scenario_4.sh   High-risk violation → WF4 Group C emails a manual runbook
create_violation.sh / verify_fix.sh — violation injection and verification
```

---

## Repository Layout

```text
├── terraform/                   # compliant-by-design infra (VPC, VM, SQL,
│   │                            # storage, logging, IAM, KMS, API keys)
│   └── scripts/                 # helper copies used by workflows
├── scripts/
│   ├── cis_full_check.sh        # 6-domain audit → JSON report + fail list
│   ├── check_{iam,logging,networking,vm,storage,sql}.sh
│   ├── collect_info.sh          # environment snapshot
│   ├── baseline/init_baseline.sh
│   ├── python/                  # iam_diff.py, save_history.py
│   └── recovery/                # group_a.sh … group_h.sh, notify.sh
├── ansible/                     # fix_vm_sa.yml (CIS 4.1/4.2), inventory
├── tests/                       # 4 guided failure/recovery scenarios
└── .github/workflows/           # wf1_deploy, wf2_monitor, wf3_upgrade,
                                 # wf4_recovery
```

---

## Setup

> One-time bootstrap — GitHub Actions needs GCP credentials that must exist before it can run.

```bash
gcloud auth login && gcloud config set project <PROJECT_ID>
gsutil mb -p <PROJECT_ID> -l <REGION> gs://tf-state-<PROJECT_ID>

gcloud iam service-accounts create github-actions-sa --project=<PROJECT_ID>
# grant: roles/editor, roles/iam.securityAdmin, roles/storage.admin
gcloud iam service-accounts keys create github-actions-key.json \
  --iam-account=github-actions-sa@<PROJECT_ID>.iam.gserviceaccount.com
```

GitHub repository secrets: `GCP_SA_KEY`, `DB_USERNAME`, `DB_PASSWORD`, `ALLOWED_CLIENT_CIDR`, `VM_SSH_KEY`. Non-sensitive values have defaults in `variables.tf`.

---

## Running Locally

```bash
cd terraform && terraform init && terraform apply   # deploy
bash scripts/cis_full_check.sh                      # full 6-domain audit
bash scripts/cis_full_check.sh json /tmp/report.json
DRY_RUN=true bash scripts/recovery/group_a.sh       # preview remediation
bash tests/scenarios/scenario_2.sh                  # guided self-heal demo
```
