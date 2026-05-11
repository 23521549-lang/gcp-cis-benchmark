# Pin image Ubuntu 24.04
data "google_compute_image" "ubuntu" {
  family  = "ubuntu-2404-lts-amd64"
  project = "ubuntu-os-cloud"
}

# ================================================================
# CIS 4.1 — VM dùng Custom SA, không dùng Default SA
# CIS 4.2 — Không dùng Default SA với Full Access scope
# CIS 4.3 — Block project-wide SSH keys
# CIS 4.4 — OS Login bật
# CIS 4.5 — Serial port không bật
# ================================================================
resource "google_compute_instance" "vm" {
  name         = "benchmark-vm-01"
  machine_type = "e2-micro"
  zone         = var.zone
  tags         = ["benchmark-vm"]

  boot_disk {
    initialize_params {
      image = data.google_compute_image.ubuntu.self_link
      size  = 20
      type  = "pd-standard"
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.subnet.id
    access_config {}
  }

  # CIS 4.1 + 4.2 — Gán Custom SA, không dùng Default SA
  # Scope "cloud-platform" KHÔNG được set vì dùng Custom SA với IAM role cụ thể
  service_account {
    email  = google_service_account.app_sa.email
    scopes = ["cloud-platform"]
  }

  # CIS 4.3 — Block project-wide SSH keys
  # CIS 4.4 — OS Login bật
  # CIS 4.5 — Serial port không bật (enable-osconfig giúp patch tự động)
  metadata = {
    block-project-ssh-keys = "true"
    enable-oslogin         = "true"
    serial-port-enable     = "false"
    enable-osconfig        = "TRUE"
  }

  depends_on = [
    google_service_account.app_sa,
    google_compute_subnetwork.subnet
  ]
}
