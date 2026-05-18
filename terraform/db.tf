# ================================================================
# Cloud SQL PostgreSQL — CIS v4.0.0 compliant
# Domain 6: 6.4, 6.2.1, 6.2.2, 6.2.3, 6.2.4, 6.2.8
# ================================================================

resource "google_project_service" "sqladmin" {
  service            = "sqladmin.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "servicenetworking" {
  service            = "servicenetworking.googleapis.com"
  disable_on_destroy = false
}

resource "google_compute_global_address" "private_ip_range" {
  name          = "cloud-sql-private-range"
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = 16
  network       = google_compute_network.vpc.self_link
}

resource "google_sql_database_instance" "postgres" {
  name                = "benchmark-postgres"
  region              = var.region
  database_version    = "POSTGRES_15"
  deletion_protection = false

  lifecycle {
    ignore_changes = [settings[0].edition]
  }

  settings {
    tier              = "db-f1-micro"
    availability_type = "ZONAL"

    ip_configuration {
      ipv4_enabled = true

      authorized_networks {
        name  = "allowed-client"
        value = var.allowed_client_cidr
      }

      # CIS 6.4 — SSL bắt buộc cho mọi connection
      require_ssl = true
    }

    # CIS 6.2.1 — log_error_verbosity không được 'verbose'
    database_flags {
      name  = "log_error_verbosity"
      value = "default"
    }

    # CIS 6.2.2 — ghi log mỗi connection mới
    database_flags {
      name  = "log_connections"
      value = "on"
    }

    # CIS 6.2.3 — ghi log khi session kết thúc
    database_flags {
      name  = "log_disconnections"
      value = "on"
    }

    # CIS 6.2.4 — ghi log DDL statements
    database_flags {
      name  = "log_statement"
      value = "ddl"
    }

    # CIS 6.2.8 — pgAudit centralized logging
    database_flags {
      name  = "cloudsql.enable_pgaudit"
      value = "on"
    }

    # Giữ nguyên các flags hiện có
    database_flags {
      name  = "log_min_messages"
      value = "warning"
    }

    database_flags {
      name  = "log_min_error_statement"
      value = "error"
    }
  }

  depends_on = [google_project_service.sqladmin]
}

resource "google_sql_database" "app" {
  name     = "appdb"
  instance = google_sql_database_instance.postgres.name
}

resource "google_sql_user" "app" {
  name     = var.db_username
  instance = google_sql_database_instance.postgres.name
  password = var.db_password
}
