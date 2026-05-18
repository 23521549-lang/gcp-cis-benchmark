resource "google_project_service" "kms_api" {
  service            = "cloudkms.googleapis.com"
  disable_on_destroy = false
}

resource "google_kms_key_ring" "my_keyring" {
  name       = "benchmark-keyring"
  location   = var.region
  depends_on = [google_project_service.kms_api]
  lifecycle {
    prevent_destroy = true # keyring không xóa được
  }
}

# ================================================================
# CIS 1.10 — KMS rotation ≤ 90 ngày
# 90 ngày = 90 * 24 * 60 * 60 = 7776000 giây
# ================================================================
resource "google_kms_crypto_key" "my_crypto_key" {
  name            = "benchmark-crypto-key"
  key_ring        = google_kms_key_ring.my_keyring.id
  rotation_period = "7776000s"

  lifecycle {
    prevent_destroy = false
    ignore_changes  = [key_ring]
  }
}

# ================================================================
# CIS 1.9 — KMS key không public/anonymous
# Đảm bảo allUsers và allAuthenticatedUsers không có quyền
# ================================================================
resource "google_kms_crypto_key_iam_binding" "kms_binding" {
  crypto_key_id = google_kms_crypto_key.my_crypto_key.id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"

  members = [
    "serviceAccount:${google_service_account.app_sa.email}",
  ]
}
