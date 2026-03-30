terraform {
  required_version = ">= 1.0"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

# ============== NETWORK ==============

resource "google_compute_network" "pg_ha_vpc" {
  name                    = "pg-ha-vpc"
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "subnets" {
  count                    = var.node_count
  name                     = "pg-subnet-${count.index + 1}"
  ip_cidr_range            = "192.168.${count.index + 1}.0/24"
  region                   = var.region
  network                  = google_compute_network.pg_ha_vpc.id
  private_ip_google_access = true
}

# Cloud NAT for egress internet access (no inbound)
resource "google_compute_router" "router" {
  name    = "pg-ha-router"
  region  = var.region
  network = google_compute_network.pg_ha_vpc.id
}

resource "google_compute_router_nat" "nat" {
  name                               = "pg-ha-nat"
  router                             = google_compute_router.router.name
  region                             = var.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"
}

# ============== FIREWALL ==============

resource "google_compute_firewall" "allow_internal" {
  name    = "allow-internal-db-ha"
  network = google_compute_network.pg_ha_vpc.id
  allow {
    protocol = "tcp"
    ports    = ["5432", "8008", "2222", "22"]
  }
  source_ranges = ["192.168.0.0/16"]
}

resource "google_compute_firewall" "allow_external_pg" {
  name    = "allow-external-pg"
  network = google_compute_network.pg_ha_vpc.id
  allow {
    protocol = "tcp"
    ports    = ["5432"]
  }
  source_ranges = var.allowed_external_ips
}

resource "google_compute_firewall" "allow_lb_health_check" {
  name    = "allow-lb-health-check"
  network = google_compute_network.pg_ha_vpc.id
  allow {
    protocol = "tcp"
    ports    = ["8008"]
  }
  source_ranges = ["35.191.0.0/16", "209.85.152.0/22", "209.85.204.0/22"]
}

# ============== SECRET MANAGER ==============

resource "google_secret_manager_secret" "pg_cluster_config" {
  secret_id = "pg-cluster-config"

  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_version" "pg_cluster_config_initial" {
  secret = google_secret_manager_secret.pg_cluster_config.id
  secret_data = jsonencode({
    node_count = var.node_count
    node_ips   = [] # Will be updated by null_resource after instance creation
  })
}
