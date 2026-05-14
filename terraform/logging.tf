# ============================================================
# APIs
# ============================================================
resource "google_project_service" "logging_api" {
  service            = "logging.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "monitoring_api" {
  service            = "monitoring.googleapis.com"
  disable_on_destroy = false
}

# CIS 2.13 — Cloud Asset Inventory
resource "google_project_service" "asset_api" {
  service            = "cloudasset.googleapis.com"
  disable_on_destroy = false
}

# ============================================================
# Notification Channel
# ============================================================
resource "google_monitoring_notification_channel" "email_alert" {
  display_name = "Security Alert Email"
  type         = "email"
  labels = {
    email_address = var.alert_email
  }
  depends_on = [google_project_service.monitoring_api]
}

# ============================================================
# CIS 2.1 — Cloud Audit Logging
# ============================================================
resource "google_project_iam_audit_config" "audit_logs" {
  project = var.project_id
  service = "allServices"

  audit_log_config { log_type = "ADMIN_READ" }
  audit_log_config { log_type = "DATA_READ" }
  audit_log_config { log_type = "DATA_WRITE" }

  depends_on = [google_project_service.logging_api]
}

# ============================================================
# CIS 2.2 — Log Sink
# ============================================================
resource "google_logging_project_sink" "log_sink" {
  name                   = "benchmark-log-sink"
  destination            = "storage.googleapis.com/${google_storage_bucket.log_bucket.name}"
  unique_writer_identity = true

  depends_on = [
    google_project_service.logging_api,
    google_storage_bucket.log_bucket
  ]
}

resource "google_storage_bucket_iam_member" "log_sink_writer" {
  bucket = google_storage_bucket.log_bucket.name
  role   = "roles/storage.objectCreator"
  member = google_logging_project_sink.log_sink.writer_identity
}

# ============================================================
# CIS 2.4 — Metric: Project Ownership Changes
# ============================================================
resource "google_logging_metric" "project_ownership_changes" {
  name = "project_ownership_changes_metric"

  filter = <<-EOT
    (protoPayload.serviceName="cloudresourcemanager.googleapis.com")
    AND (ProjectOwnership OR projectOwnerInvitee)
    OR (protoPayload.serviceData.policyDelta.bindingDeltas.action="REMOVE"
        AND protoPayload.serviceData.policyDelta.bindingDeltas.role="roles/owner")
    OR (protoPayload.serviceData.policyDelta.bindingDeltas.action="ADD"
        AND protoPayload.serviceData.policyDelta.bindingDeltas.role="roles/owner")
  EOT

  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
    unit        = "1"
  }

  depends_on = [google_project_service.logging_api]
}

# ============================================================
# CIS 2.5 — Metric: Audit Config Changes
# ============================================================
resource "google_logging_metric" "audit_config_changes" {
  name = "audit_config_changes_metric"

  filter = <<-EOT
    protoPayload.methodName="SetIamPolicy"
    AND protoPayload.serviceData.policyDelta.auditConfigDeltas:*
  EOT

  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
    unit        = "1"
  }

  depends_on = [google_project_service.logging_api]
}

# ============================================================
# CIS 2.6 — Metric: Custom Role Changes
# ============================================================
resource "google_logging_metric" "custom_role_changes" {
  name = "custom_role_changes_metric"

  filter = <<-EOT
    resource.type="iam_role"
    AND protoPayload.methodName="google.iam.admin.v1.CreateRole"
    OR protoPayload.methodName="google.iam.admin.v1.DeleteRole"
    OR protoPayload.methodName="google.iam.admin.v1.UpdateRole"
  EOT

  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
    unit        = "1"
  }

  depends_on = [google_project_service.logging_api]
}

# ============================================================
# Chờ metrics sẵn sàng trước khi tạo alert policies
# GCP cần ~2 phút sau khi tạo metric mới dùng được
# ============================================================
resource "time_sleep" "wait_for_metrics" {
  create_duration = "120s"

  depends_on = [
    google_logging_metric.project_ownership_changes,
    google_logging_metric.audit_config_changes,
    google_logging_metric.custom_role_changes,
  ]
}

# ============================================================
# CIS 2.4 — Alert: Project Ownership Changes
# ============================================================
resource "google_monitoring_alert_policy" "project_ownership_alert" {
  display_name = "CIS 2.4 — Project Ownership Change Alert"
  combiner     = "OR"

  conditions {
    display_name = "Ownership change detected"
    condition_threshold {
      filter          = "metric.type=\"logging.googleapis.com/user/project_ownership_changes_metric\" AND resource.type=\"global\""
      comparison      = "COMPARISON_GT"
      threshold_value = 0
      duration        = "0s"
      aggregations {
        alignment_period   = "60s"
        per_series_aligner = "ALIGN_RATE"
      }
    }
  }

  notification_channels = [google_monitoring_notification_channel.email_alert.name]
  enabled               = true

  depends_on = [
    google_project_service.monitoring_api,
    google_logging_metric.project_ownership_changes,
    time_sleep.wait_for_metrics,
  ]
}

# ============================================================
# CIS 2.5 — Alert: Audit Config Changes
# ============================================================
resource "google_monitoring_alert_policy" "audit_config_alert" {
  display_name = "CIS 2.5 — Audit Config Change Alert"
  combiner     = "OR"

  conditions {
    display_name = "Audit config change detected"
    condition_threshold {
      filter          = "metric.type=\"logging.googleapis.com/user/audit_config_changes_metric\" AND resource.type=\"global\""
      comparison      = "COMPARISON_GT"
      threshold_value = 0
      duration        = "0s"
      aggregations {
        alignment_period   = "60s"
        per_series_aligner = "ALIGN_RATE"
      }
    }
  }

  notification_channels = [google_monitoring_notification_channel.email_alert.name]
  enabled               = true

  depends_on = [
    google_project_service.monitoring_api,
    google_logging_metric.audit_config_changes,
    time_sleep.wait_for_metrics,
  ]
}

# ============================================================
# CIS 2.6 — Alert: Custom Role Changes
# ============================================================
resource "google_monitoring_alert_policy" "custom_role_alert" {
  display_name = "CIS 2.6 — Custom Role Change Alert"
  combiner     = "OR"

  conditions {
    display_name = "Custom role change detected"
    condition_threshold {
      filter          = "metric.type=\"logging.googleapis.com/user/custom_role_changes_metric\" AND resource.type=\"global\""
      comparison      = "COMPARISON_GT"
      threshold_value = 0
      duration        = "0s"
      aggregations {
        alignment_period   = "60s"
        per_series_aligner = "ALIGN_RATE"
      }
    }
  }

  notification_channels = [google_monitoring_notification_channel.email_alert.name]
  enabled               = true

  depends_on = [
    google_project_service.monitoring_api,
    google_logging_metric.custom_role_changes,
    time_sleep.wait_for_metrics,
  ]
}
