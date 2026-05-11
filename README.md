# GCP CIS Benchmark Automation

[![CIS Compliance](https://img.shields.io/badge/CIS-GCP%20Foundation%20v4.0.0-blue?style=flat-square)](https://www.cisecurity.org)
[![Terraform](https://img.shields.io/badge/Terraform-~>%201.7-7B42BC?style=flat-square&logo=terraform)](https://www.terraform.io)
[![WF1 Deploy](https://img.shields.io/github/actions/workflow/status/YOUR_ORG/gcp-cis-benchmark/wf1_deploy.yml?label=WF1%20Deploy&style=flat-square)](../../actions/workflows/wf1_deploy.yml)
[![WF2 Monitor](https://img.shields.io/github/actions/workflow/status/YOUR_ORG/gcp-cis-benchmark/wf2_monitor.yml?label=WF2%20Monitor&style=flat-square)](../../actions/workflows/wf2_monitor.yml)

Automated deployment and security compliance checking on GCP
based on the **CIS Google Cloud Platform Foundation Benchmark v4.0.0** — 23 controls, 5 domains.

---

## Table of Contents

- [Coverage](#coverage)
- [Architecture](#architecture)
- [Workflows](#workflows)
- [Prerequisites](#prerequisites)
- [First-time Setup](#first-time-setup)
- [Running Locally](#running-locally)
- [Recovery](#recovery)

---

## Coverage

| Domain                           | Controls                              | Files                                                    |
| -------------------------------- | ------------------------------------- | -------------------------------------------------------- |
| 1 — Identity & Access Management | `1.4` `1.5` `1.6` `1.10` `1.14`       | `security_iam.tf` `security_kms.tf` `security_apikey.tf` |
| 2 — Logging & Monitoring         | `2.1` `2.2` `2.3` `2.4` `2.12` `2.13` | `logging.tf` `storage.tf` `vpc.tf`                       |
| 3 — Networking                   | `3.1` `3.3` `3.6` `3.7` `3.8`         | `vpc.tf`                                                 |
| 4 — Virtual Machines             | `4.1` `4.2` `4.3` `4.4` `4.5`         | `vm.tf`                                                  |
| 5 — Storage                      | `5.1` `5.2`                           | `storage.tf`                                             |

Total: **23 controls across 5 domains**

---

## Architecture

```text
gcp-cis-benchmark/
├── terraform/
│   ├── provider.tf             # GCS backend + Google provider
│   ├── variables.tf            # Input variables
│   ├── outputs.tf              # Output values
│   ├── vpc.tf                  # CIS 3.1 3.3 3.6 3.7 3.8 2.12
│   ├── vm.tf                   # CIS 4.1 4.2 4.3 4.4 4.5
│   ├── db.tf                   # Cloud SQL PostgreSQL
│   ├── storage.tf              # CIS 2.3 5.1 5.2
│   ├── logging.tf              # CIS 2.1 2.2 2.4 2.13
│   ├── security_iam.tf         # CIS 1.4 1.5 1.6
│   ├── security_kms.tf         # CIS 1.9 1.10
│   ├── security_apikey.tf      # CIS 1.14
│   └── terraform.tfvars        # LOCAL ONLY — do not commit
├── scripts/
│   ├── check_iam.sh            # Domain 1 check
│   ├── check_logging.sh        # Domain 2 check
│   ├── check_networking.sh     # Domain 3 check
│   ├── check_vm.sh             # Domain 4 check
│   ├── check_storage.sh        # Domain 5 check
│   ├── cis_full_check.sh       # Full 23-control check, outputs JSON report
│   └── recovery.sh             # Auto-fix Group A, guide for B/C
├── ansible/
│   ├── inventory.ini           # VM inventory
│   └── fix_vm_sa.yml           # CIS 4.1 4.2 — swap VM service account
├── .github/
│   └── workflows/
│       ├── wf1_deploy.yml      # Initial deploy
│       ├── wf2_monitor.yml     # Scheduled monitor every 6h
│       ├── wf3_upgrade.yml     # Safe upgrade with smart domain detection
│       └── wf4_recovery.yml    # Intelligent auto-recovery
├── .gitignore
└── README.md
```

---

## Workflows

| Workflow                | Trigger                         | Purpose                                               |
| ----------------------- | ------------------------------- | ----------------------------------------------------- |
| WF1 — Initial Deploy    | push to main                    | Deploy full infrastructure + run 23-control CIS check |
| WF2 — Scheduled Monitor | cron every 6h                   | Continuous compliance monitoring, detect regressions  |
| WF3 — Safe Upgrade      | push to main after first deploy | Plan, apply, verify only affected domains             |
| WF4 — Auto Recovery     | Called by WF1/WF2/WF3 or manual | Intelligent recovery across 3 groups                  |

When a push lands on main, WF1 runs terraform plan and apply, then
runs cis_full_check.sh against all 23 controls. If all controls pass,
an INFO email is sent. If any control fails, WF4 is triggered automatically.

WF4 splits remediation into three groups. Group A covers 15 controls
that can be fixed immediately via gcloud script. Group B covers 2 controls
that require stopping and restarting the VM, handled by Ansible. Group C
covers 5 controls that require human confirmation, for which WF4 sends
a step-by-step email.

WF2 runs silently every 6 hours. If all controls pass, no action is taken
and no email is sent. If a regression is detected, WF4 is triggered.

---

## Prerequisites

- [Google Cloud SDK](https://cloud.google.com/sdk/docs/install) installed and authenticated
- [Terraform](https://developer.hashicorp.com/terraform/install) >= 1.7
- A GCP project with billing enabled
- A GitHub repository

---

## First-time Setup

> These steps must be done manually once. This is a bootstrap problem —
> GitHub Actions needs GCP credentials to run, but those credentials must
> exist before GitHub Actions can create them.

### Step 1 — Authenticate with GCP

```bash
gcloud auth login
gcloud config set project <YOUR_PROJECT_ID>
gcloud auth application-default login
```

### Step 2 — Create GCS bucket for Terraform state

Terraform stores infrastructure state in this bucket. It must exist before
`terraform init` runs, so it cannot be created by Terraform itself.

```bash
gsutil mb \
  -p <YOUR_PROJECT_ID> \
  -l <YOUR_REGION> \
  gs://tf-state-<YOUR_PROJECT_ID>
```

Then update `terraform/provider.tf` to match:

```hcl
terraform {
  backend "gcs" {
    bucket = "tf-state-<YOUR_PROJECT_ID>"
    prefix = "terraform/state"
  }
}
```

### Step 3 — Create Service Account for GitHub Actions

GitHub Actions uses this service account to authenticate with GCP.

```bash
# Create the service account
gcloud iam service-accounts create github-actions-sa \
  --display-name="GitHub Actions SA" \
  --project=<YOUR_PROJECT_ID>

# Grant permission to deploy infrastructure
gcloud projects add-iam-policy-binding <YOUR_PROJECT_ID> \
  --member="serviceAccount:github-actions-sa@<YOUR_PROJECT_ID>.iam.gserviceaccount.com" \
  --role="roles/editor"

# Grant permission to manage IAM policies
gcloud projects add-iam-policy-binding <YOUR_PROJECT_ID> \
  --member="serviceAccount:github-actions-sa@<YOUR_PROJECT_ID>.iam.gserviceaccount.com" \
  --role="roles/iam.securityAdmin"

# Grant permission to manage Storage (for Terraform state)
gcloud projects add-iam-policy-binding <YOUR_PROJECT_ID> \
  --member="serviceAccount:github-actions-sa@<YOUR_PROJECT_ID>.iam.gserviceaccount.com" \
  --role="roles/storage.admin"

# Create JSON key file
gcloud iam service-accounts keys create github-actions-key.json \
  --iam-account=github-actions-sa@<YOUR_PROJECT_ID>.iam.gserviceaccount.com
```

> Keep `github-actions-key.json` secure and never commit it to the repository.

### Step 4 — Configure GitHub Secrets

Go to your repository on GitHub:
**Settings** > **Secrets and variables** > **Actions** > **New repository secret**

| Secret                | Value                                      | Why secret                |
| --------------------- | ------------------------------------------ | ------------------------- |
| `GCP_SA_KEY`          | Full contents of `github-actions-key.json` | GCP credentials           |
| `DB_USERNAME`         | Your database username                     | Login credentials         |
| `DB_PASSWORD`         | Your database password                     | Login credentials         |
| `ALLOWED_CLIENT_CIDR` | Your IP in CIDR format, e.g. `x.x.x.x/32`  | Exposes your IP if leaked |

To find your current IPv4 address:

```bash
curl -4 ifconfig.me
```

Variables that are not sensitive (`project_id`, `region`, `alert_email`, etc.)
already have defaults in `variables.tf` and do not need to be added as secrets.

### Step 5 — Configure terraform.tfvars for local use

Create `terraform/terraform.tfvars` and fill in your values:

```hcl
project_id          = "<YOUR_PROJECT_ID>"
db_username         = "<YOUR_DB_USERNAME>"
db_password         = "<YOUR_DB_PASSWORD>"
allowed_client_cidr = "<YOUR_IP>/32"
alert_email         = "<YOUR_EMAIL>"
```

> `terraform.tfvars` is listed in `.gitignore` and will never be committed.

### Step 6 — Push to GitHub to trigger WF1

```bash
git init
git add .
git commit -m "initial: CIS GCP Benchmark v4.0.0"
git branch -M main
git remote add origin https://github.com/<YOUR_ORG>/gcp-cis-benchmark.git
git push -u origin main
```

### Step 7 — Monitor WF1

Go to the **Actions** tab in your GitHub repository and open **WF1 — Initial Deploy**.

```text
Checkout
Auth GCP
Setup Terraform
Terraform Init
Terraform Validate
Terraform Plan
Terraform Apply        <-- creates all infrastructure on GCP
Run CIS Full Check     <-- checks all 23 controls
    |
    |-- all PASS --> send INFO email
    '-- any FAIL --> trigger WF4 auto-recovery
```

Once WF1 completes, WF2 runs automatically every 6 hours with no further action required.

---

## Running Locally

```bash
# Authenticate
gcloud auth login
gcloud config set project <YOUR_PROJECT_ID>

# Deploy infrastructure
cd terraform
terraform init
terraform plan
terraform apply

# Run full CIS check
cd ../scripts
bash cis_full_check.sh

# If any controls fail, run auto-recovery
bash recovery.sh
```

---

## Recovery

Controls are split into three groups based on how they can be remediated.

| Group              | Controls                                                                                      | Method                                                    |
| ------------------ | --------------------------------------------------------------------------------------------- | --------------------------------------------------------- |
| A — Automated (15) | `1.4` `1.5` `1.10` `1.14` `2.1` `2.2` `2.12` `2.13` `3.1` `3.8` `4.3` `4.4` `4.5` `5.1` `5.2` | `recovery.sh` via gcloud                                  |
| B — Ansible (2)    | `4.1` `4.2`                                                                                   | `ansible-playbook fix_vm_sa.yml` — requires VM stop/start |
| C — Manual (5)     | `1.6` `2.3` `2.4` `3.3` `3.6`                                                                 | WF4 sends email with step-by-step instructions            |

Group B requires Ansible because replacing a VM's service account requires
stopping the VM, swapping the SA, then restarting — Ansible manages this
lifecycle safely with idempotent retries.

Group C requires human confirmation because the actions are irreversible
(bucket lock), need email verification (alert channel), or require
validating external state before applying (DNS propagation, SSH IP whitelist).
