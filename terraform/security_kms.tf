resource "google_project_service" "kms_api" {
  service            = "cloudkms.googleapis.com"
  disable_on_destroy = false
}

resource "google_kms_key_ring" "my_keyring" {
  name       = "benchmark-keyring"
  location   = var.region
  depends_on = [google_project_service.kms_api]

  lifecycle {
    prevent_destroy = true
  }
}

# ================================================================
# CIS 1.10 — KMS rotation ≤ 90 ngày
# ================================================================
resource "google_kms_crypto_key" "my_crypto_key" {
  name            = "benchmark-crypto-key"
  key_ring        = "projects/${var.project_id}/locations/${var.region}/keyRings/benchmark-keyring"
  rotation_period = "7776000s"

  lifecycle {
    prevent_destroy = false
    ignore_changes  = [key_ring]
  }
}

# ================================================================
# CIS 1.9 — KMS key không public/anonymous
# ================================================================
resource "google_kms_crypto_key_iam_binding" "kms_binding" {
  crypto_key_id = google_kms_crypto_key.my_crypto_key.id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"

  members = [
    "serviceAccount:${google_service_account.app_sa.email}",
  ]
}
