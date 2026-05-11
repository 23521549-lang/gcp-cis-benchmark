resource "google_project_service" "apikeys_api" {
  service            = "apikeys.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "translate_api" {
  service            = "translate.googleapis.com"
  disable_on_destroy = false
}

# ================================================================
# CIS 1.14 — API Key chỉ được phép gọi API cần thiết
# ================================================================
resource "google_apikeys_key" "restricted_api_key" {
  name         = "restricted-app-key"
  display_name = "Restricted API Key — translate only"
  project      = var.project_id

  restrictions {
    api_targets {
      service = "translate.googleapis.com"
    }
  }

  depends_on = [
    google_project_service.apikeys_api,
    google_project_service.translate_api
  ]
}
