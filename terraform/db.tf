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

# Private IP range cho Cloud SQL (VPC Peering)
resource "google_compute_global_address" "private_ip_range" {
  name          = "cloud-sql-private-range"
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = 16
  network       = google_compute_network.vpc.self_link
}

# VPC Peering để SQL dùng Private IP
resource "google_service_networking_connection" "private_vpc_connection" {
  network                 = google_compute_network.vpc.id
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.private_ip_range.name]

  depends_on = [google_project_service.servicenetworking]
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
      # CIS 6.4 — SSL bắt buộc
      require_ssl = true
      # Private IP — không cần Public IP
      ipv4_enabled    = false
      private_network = google_compute_network.vpc.id
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

    # CIS 6.2.8 — pgAudit
    database_flags {
      name  = "cloudsql.enable_pgaudit"
      value = "on"
    }

    database_flags {
      name  = "log_min_messages"
      value = "warning"
    }

    database_flags {
      name  = "log_min_error_statement"
      value = "error"
    }
  }

  depends_on = [
    google_project_service.sqladmin,
    google_service_networking_connection.private_vpc_connection,
  ]
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
