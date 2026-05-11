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
    }

    # Database flags cho PostgreSQL (CIS 6.2)
    database_flags {
      name  = "log_connections"
      value = "on"
    }
    database_flags {
      name  = "log_disconnections"
      value = "on"
    }
    database_flags {
      name  = "log_error_verbosity"
      value = "DEFAULT"
    }
    database_flags {
      name  = "log_min_messages"
      value = "WARNING"
    }
    database_flags {
      name  = "log_min_error_statement"
      value = "ERROR"
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
