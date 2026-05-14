# ================================================================
# Log Bucket — dùng cho Log Sink (CIS 2.2)
# CIS 2.3 — Retention Policy + Bucket Lock
# CIS 5.1 — Không public/anonymous
# CIS 5.2 — Uniform Bucket-Level Access bật
# ================================================================
resource "google_storage_bucket" "log_bucket" {
  name                        = var.storage_bucket_name
  location                    = "ASIA-SOUTHEAST1"
  force_destroy               = false
  uniform_bucket_level_access = true # CIS 5.2

  # CIS 2.3 — Retention Policy 30 ngày + Bucket Lock
  retention_policy {
    is_locked        = true
    retention_period = 2592000 # 30 ngày tính bằng giây
  }
}

# CIS 5.1 — Đảm bảo không có IAM binding cho allUsers hay allAuthenticatedUsers
# Terraform sẽ báo lỗi nếu cố gán public access
resource "google_storage_bucket_iam_binding" "log_bucket_no_public" {
  bucket = google_storage_bucket.log_bucket.name
  role   = "roles/storage.objectViewer"

  # Chỉ grant cho app SA — không có allUsers
  members = [
    "serviceAccount:${google_service_account.app_sa.email}",
  ]

  depends_on = [google_service_account.app_sa]
}
