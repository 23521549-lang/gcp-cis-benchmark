# ================================================================
# CIS 1.5 — SA không có Admin privileges
# Tạo Custom SA với quyền Least Privilege
# ================================================================
resource "google_service_account" "app_sa" {
  account_id   = "app-least-privilege-sa"
  display_name = "Application Service Account (Least Privilege)"
  description  = "CIS 1.5 — Dùng cho VM, không có quyền Admin"
}

# Chỉ cấp quyền đọc Storage — không roles/editor hay roles/owner
resource "google_project_iam_member" "sa_storage_viewer" {
  project = var.project_id
  role    = "roles/storage.objectViewer"
  member  = "serviceAccount:${google_service_account.app_sa.email}"
}

# Cho phép SA dùng OS Login (cần cho CIS 4.4)
resource "google_project_iam_member" "sa_oslogin" {
  project = var.project_id
  role    = "roles/compute.osLogin"
  member  = "serviceAccount:${google_service_account.app_sa.email}"
}

# ================================================================
# CIS 1.6 — Không gán SA User / Token Creator ở project level
# Kiểm tra và block bằng IAM Condition hoặc dùng deny policy
# Đây là audit binding — dùng google_project_iam_audit_config đã có ở logging.tf
# ================================================================

# ================================================================
# CIS 1.4 — Chỉ dùng GCP-managed SA keys
# Org policy block user-managed key creation
# (Bỏ comment nếu project thuộc Organization)
# ================================================================
# resource "google_project_organization_policy" "disable_sa_key_creation" {
#   project    = var.project_id
#   constraint = "constraints/iam.disableServiceAccountKeyCreation"
#   boolean_policy { enforced = true }
# }

# Thay thế: enforce bằng script kiểm tra định kỳ (WF2)
# Script check_iam.sh sẽ phát hiện nếu có user-managed key nào được tạo
