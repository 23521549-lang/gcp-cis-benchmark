data "google_compute_image" "ubuntu" {
  family  = "ubuntu-2404-lts-amd64"
  project = "ubuntu-os-cloud"
}

# ================================================================
# Bastion Host VM — Public Subnet
# Entry point SSH, không chạy workload
# ================================================================
resource "google_compute_instance" "bastion" {
  name         = "benchmark-bastion-01"
  machine_type = "e2-micro"
  zone         = var.zone
  tags         = ["bastion-vm"]

  boot_disk {
    initialize_params {
      image = data.google_compute_image.ubuntu.self_link
      size  = 20
      type  = "pd-standard"
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.subnet_public.id
    # Public IP để SSH từ ngoài vào
    access_config {}
  }

  service_account {
    email  = google_service_account.app_sa.email
    scopes = ["cloud-platform"]
  }

  # CIS 4.3 + 4.4 + 4.5
  metadata = {
    block-project-ssh-keys = "true"
    enable-oslogin         = "true"
    serial-port-enable     = "false"
    enable-osconfig        = "TRUE"
  }

  depends_on = [
    google_service_account.app_sa,
    google_compute_subnetwork.subnet_public,
  ]
}

# ================================================================
# App VM — Private Subnet (no public IP)
# CIS 4.1 / 4.2 / 4.3 / 4.4 / 4.5
# ================================================================
resource "google_compute_instance" "vm" {
  name         = "benchmark-vm-01"
  machine_type = "e2-micro"
  zone         = var.zone
  tags         = ["private-vm"]

  boot_disk {
    initialize_params {
      image = data.google_compute_image.ubuntu.self_link
      size  = 20
      type  = "pd-standard"
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.subnet_private.id
    # Không có access_config = không có Public IP (CIS best practice)
  }

  service_account {
    email  = google_service_account.app_sa.email
    scopes = ["cloud-platform"]
  }

  # CIS 4.3 — Block project SSH keys
  # CIS 4.4 — OS Login
  # CIS 4.5 — Serial port off
  metadata = {
    block-project-ssh-keys = "true"
    enable-oslogin         = "true"
    serial-port-enable     = "false"
    enable-osconfig        = "TRUE"
  }

  depends_on = [
    google_service_account.app_sa,
    google_compute_subnetwork.subnet_private,
    google_compute_router_nat.cloud_nat,
  ]
}
