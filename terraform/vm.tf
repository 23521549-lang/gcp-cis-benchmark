data "google_compute_image" "ubuntu" {
  family  = "ubuntu-2404-lts-amd64"
  project = "ubuntu-os-cloud"
}

resource "google_compute_instance" "vm" {
  name         = "benchmark-vm-01"
  machine_type = "e2-micro"
  zone         = "asia-southeast1-b"
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

  service_account {
    email  = google_service_account.app_sa.email
    scopes = ["cloud-platform"]
  }

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
