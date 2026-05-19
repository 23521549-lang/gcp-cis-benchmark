# ================================================================
# CIS 3.1 — Xóa default network
# ================================================================
resource "null_resource" "delete_default_network" {
  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = "DEFAULT=$(gcloud compute networks list --project=${var.project_id} --filter=name=default --format='value(name)' 2>/dev/null); if [ \"$DEFAULT\" = \"default\" ]; then gcloud compute networks delete default --project=${var.project_id} --quiet 2>/dev/null || true; fi"
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
# Subnet 1 — Public (Bastion Host)
# CIS 3.8 — VPC Flow Logs
# ================================================================
resource "google_compute_subnetwork" "subnet_public" {
  name          = "benchmark-subnet-public"
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
# Subnet 2 — Private App (App VM, no public IP)
# CIS 3.8 — VPC Flow Logs
# ================================================================
resource "google_compute_subnetwork" "subnet_private" {
  name                     = "benchmark-subnet-private"
  ip_cidr_range            = "10.20.0.0/24"
  region                   = var.region
  network                  = google_compute_network.vpc.id
  private_ip_google_access = true # App VM truy cập GCP APIs không cần Public IP

  log_config {
    aggregation_interval = "INTERVAL_5_SEC"
    flow_sampling        = 1
    metadata             = "INCLUDE_ALL_METADATA"
  }
}

# ================================================================
# Cloud NAT — cho Private VMs ra internet (download packages, etc)
# ================================================================
resource "google_compute_router" "nat_router" {
  name    = "benchmark-nat-router"
  region  = var.region
  network = google_compute_network.vpc.id
}

resource "google_compute_router_nat" "cloud_nat" {
  name                               = "benchmark-cloud-nat"
  router                             = google_compute_router.nat_router.name
  region                             = var.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "LIST_OF_SUBNETWORKS"

  subnetwork {
    name                    = google_compute_subnetwork.subnet_private.id
    source_ip_ranges_to_nat = ["ALL_IP_RANGES"]
  }
}

# ================================================================
# CIS 2.12 — DNS Logging
# CIS 3.3 — DNSSEC cho public zone
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
  description = "Public DNS zone with DNSSEC (CIS 3.3)"
  visibility  = "public"

  dnssec_config {
    state         = "on"
    non_existence = "nsec3"
  }
}

# CIS 2.12 — DNS Logging
resource "google_dns_policy" "dns_logging" {
  name           = "benchmark-dns-logging-policy"
  enable_logging = true

  networks {
    network_url = google_compute_network.vpc.self_link
  }
}

# ================================================================
# Firewall Rules
# CIS 3.6 — SSH chỉ từ IP cụ thể vào Bastion
# CIS 3.7 — Không mở RDP
# ================================================================

# Allow SSH từ IP cụ thể vào Bastion (Public Subnet)
resource "google_compute_firewall" "allow_ssh_bastion" {
  name    = "benchmark-allow-ssh-bastion"
  network = google_compute_network.vpc.name

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges = [var.allowed_client_cidr]
  target_tags   = ["bastion-vm"]
  description   = "CIS 3.6 — SSH only from allowed IP to Bastion"
}

# Allow SSH từ Bastion vào Private VMs (internal only)
resource "google_compute_firewall" "allow_ssh_internal" {
  name    = "benchmark-allow-ssh-internal"
  network = google_compute_network.vpc.name

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_tags = ["bastion-vm"]
  target_tags = ["private-vm"]
  description = "Allow SSH from Bastion to Private VMs"
}

# Allow internal traffic giữa các VM
resource "google_compute_firewall" "allow_internal" {
  name    = "benchmark-allow-internal"
  network = google_compute_network.vpc.name

  allow {
    protocol = "tcp"
    ports    = ["0-65535"]
  }
  allow {
    protocol = "udp"
    ports    = ["0-65535"]
  }
  allow {
    protocol = "icmp"
  }

  source_ranges = ["10.10.0.0/24", "10.20.0.0/24"]
  description   = "Allow internal traffic between subnets"
}

# Deny all ingress by default
resource "google_compute_firewall" "deny_all_ingress" {
  name      = "benchmark-deny-all-ingress"
  network   = google_compute_network.vpc.name
  priority  = 65534
  direction = "INGRESS"

  deny {
    protocol = "all"
  }

  source_ranges = ["0.0.0.0/0"]
  description   = "CIS 3.7 — Deny all ingress by default"
}
