# ================================================================
# CIS 3.1 — Default network không tồn tại
# Xóa default network bằng cách dùng null_resource + local-exec
# Terraform không quản lý resource này nên dùng gcloud trực tiếp
# ================================================================
resource "null_resource" "delete_default_network" {
  provisioner "local-exec" {
    command = <<-EOT
      DEFAULT=$(gcloud compute networks list \
        --project=${var.project_id} \
        --filter="name=default" \
        --format="value(name)" 2>/dev/null)
      if [ "$DEFAULT" = "default" ]; then
        echo "Đang xóa default network..."
        # Xóa firewall rules trước
        gcloud compute firewall-rules list \
          --project=${var.project_id} \
          --filter="network=default" \
          --format="value(name)" | \
          xargs -I {} gcloud compute firewall-rules delete {} \
          --project=${var.project_id} --quiet 2>/dev/null || true
        # Xóa network
        gcloud compute networks delete default \
          --project=${var.project_id} --quiet 2>/dev/null || true
        echo "Đã xóa default network."
      else
        echo "Default network không tồn tại — OK."
      fi
    EOT
  }
}

# ================================================================
# Custom VPC — benchmark-vpc (thay thế default)
# ================================================================
resource "google_compute_network" "vpc" {
  name                    = "benchmark-vpc"
  auto_create_subnetworks = false
  routing_mode            = "REGIONAL"
  depends_on              = [null_resource.delete_default_network]
}

# ================================================================
# Subnet — CIS 3.8 — VPC Flow Logs đủ 4 điều kiện:
#   aggregation_interval = INTERVAL_5_SEC
#   flow_sampling        = 1.0 (100%)
#   metadata             = INCLUDE_ALL_METADATA
#   filter_expr          = không có (logs_filtered = false)
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
# CIS 3.3 + CIS 2.12 — Cloud DNS Zone với DNSSEC + DNS Logging
# ================================================================
resource "google_dns_managed_zone" "main" {
  name        = "benchmark-dns-zone"
  dns_name    = "benchmark.internal."
  description = "Internal DNS zone với DNSSEC (CIS 3.3)"
  visibility  = "private"

  private_visibility_config {
    networks {
      network_url = google_compute_network.vpc.self_link
    }
  }

  # CIS 3.3 — DNSSEC bật
  dnssec_config {
    state         = "on"
    non_existence = "nsec3"
  }
}

# CIS 2.12 — DNS Logging bật cho VPC network
resource "google_dns_policy" "dns_logging" {
  name           = "benchmark-dns-logging-policy"
  enable_logging = true

  networks {
    network_url = google_compute_network.vpc.self_link
  }
}

# ================================================================
# CIS 3.6 — SSH chỉ từ IP cụ thể, không mở 0.0.0.0/0
# CIS 3.7 — RDP không mở 0.0.0.0/0 (không có rule nào mở port 3389)
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

  description = "CIS 3.6 — SSH chỉ từ IP được phép"
}

# Deny-all ingress tường minh — production hardening
resource "google_compute_firewall" "deny_all_ingress" {
  name      = "benchmark-deny-all-ingress"
  network   = google_compute_network.vpc.name
  priority  = 65534
  direction = "INGRESS"

  deny {
    protocol = "all"
  }

  source_ranges = ["0.0.0.0/0"]
  description   = "Deny all ingress mặc định — chỉ allow những gì khai báo tường minh"
}
