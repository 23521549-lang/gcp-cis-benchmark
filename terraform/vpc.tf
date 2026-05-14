# ================================================================
# CIS 3.1 — Default network không tồn tại
# ================================================================
resource "null_resource" "delete_default_network" {
  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = "DEFAULT=$(gcloud compute networks list --project=${var.project_id} --filter=name=default --format=value(name) 2>/dev/null); if [ \"$DEFAULT\" = \"default\" ]; then gcloud compute networks delete default --project=${var.project_id} --quiet 2>/dev/null || true; fi"
  }
}

# ================================================================
# Custom VPC
# ================================================================
resource "google_compute_network" "vpc" {
  name                    = "benchmark-vpc"
  auto_create_subnetworks = false
  routing_mode            = "REGIONAL"
  depends_on              = [null_resource.delete_default_network]
}

# ================================================================
# CIS 3.8 — VPC Flow Logs
# ================================================================
resource "google_compute_subnetwork" "subnet" {
  name          = "benchmark-subnet"
  ip_cidr_range = "10.10.0.0/24"
  region        = var.region
  network       = google_compute_network.vpc.id

  log_config {
    aggregation_interval = "INTERVAL_5_SEC"
    flow_sampling        = 1
    metadata             = "INCLUDE_ALL_METADATA"
  }
}

# ================================================================
# CIS 2.12 — DNS Logging
# CIS 3.3 — DNSSEC chỉ áp dụng cho public zone
#            Private zone không hỗ trợ DNSSEC — tạo public zone riêng
# ================================================================
resource "google_dns_managed_zone" "private" {
  name        = "benchmark-private-zone"
  dns_name    = "benchmark.internal."
  description = "Private DNS zone for internal resolution"
  visibility  = "private"

  private_visibility_config {
    networks {
      network_url = google_compute_network.vpc.self_link
    }
  }
}

resource "google_dns_managed_zone" "public" {
  name        = "benchmark-public-zone"
  dns_name    = "benchmark-cis.com."
  description = "Public DNS zone with DNSSEC enabled (CIS 3.3)"
  visibility  = "public"

  dnssec_config {
    state         = "on"
    non_existence = "nsec3"
  }
}

# CIS 2.12 — DNS Logging bật cho VPC
resource "google_dns_policy" "dns_logging" {
  name           = "benchmark-dns-logging-policy"
  enable_logging = true

  networks {
    network_url = google_compute_network.vpc.self_link
  }
}

# ================================================================
# CIS 3.6 — SSH chỉ từ IP cụ thể
# CIS 3.7 — Không có rule nào mở RDP
# ================================================================
resource "google_compute_firewall" "allow_ssh" {
  name    = "benchmark-allow-ssh"
  network = google_compute_network.vpc.name

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges = [var.allowed_client_cidr]
  target_tags   = ["benchmark-vm"]
  description   = "CIS 3.6 — SSH only from allowed IP"
}

resource "google_compute_firewall" "deny_all_ingress" {
  name      = "benchmark-deny-all-ingress"
  network   = google_compute_network.vpc.name
  priority  = 65534
  direction = "INGRESS"

  deny {
    protocol = "all"
  }

  source_ranges = ["0.0.0.0/0"]
  description   = "Deny all ingress by default"
}
