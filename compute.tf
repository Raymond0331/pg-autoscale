# ============== STARTUP SCRIPT TEMPLATE ==============

# Build the comma-separated IP list from static IPs
locals {
  static_ips = [for i in range(1, var.node_count + 1) : "192.168.${i}.10"]
  node_ips_str = join(",", local.static_ips)
}

data "template_file" "startup_script" {
  template = file("${path.module}/scripts/startup.tpl")
  vars = {
    pg_password = var.pg_password
    node_count  = var.node_count
    node_ips    = local.node_ips_str
  }
}

# ============== STATIC IP ADDRESSES ==============

resource "google_compute_address" "pg_node_ips" {
  count        = var.node_count
  name         = "pg-node-${count.index + 1}-ip"
  subnetwork   = google_compute_subnetwork.subnets[count.index].id
  address_type = "INTERNAL"
  address      = "192.168.${count.index + 1}.10"
}

# ============== VM INSTANCES ==============

resource "google_compute_instance" "pg_nodes" {
  count        = var.node_count
  name         = "pg-node-${count.index + 1}"
  machine_type = var.machine_type
  zone         = var.zones[count.index % length(var.zones)]

  boot_disk {
    initialize_params {
      image = "ubuntu-os-cloud/ubuntu-2404-lts-amd64"
      size  = 50
      type  = "pd-ssd"
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.subnets[count.index].id
    network_ip = google_compute_address.pg_node_ips[count.index].address
  }

  metadata_startup_script = data.template_file.startup_script.rendered

  service_account {
    scopes = ["https://www.googleapis.com/auth/cloud-platform"]
  }

  depends_on = [
    google_secret_manager_secret.pg_cluster_config,
  ]

  # ============== GRACEFUL SCALE-IN ==============
  # Before destroying a node, gracefully remove it from Patroni cluster
  provisioner "local-exec" {
    command = <<-EOT
      echo "[pg-node-${count.index + 1}] Graceful shutdown: removing from Patroni cluster..."
      # Remove self so Raft cluster recognizes this node has left
      for i in {1..5}; do
        if timeout 30 patronictl -c /etc/patroni/patroni.yml remove pg-node-${count.index + 1} --force 2>/dev/null; then
          echo "[pg-node-${count.index + 1}] Successfully removed from cluster"
          break
        fi
        echo "[pg-node-${count.index + 1}] Remove attempt $i failed, retrying..."
        sleep 5
      done
      # Stop Patroni
      systemctl stop patroni 2>/dev/null || true
      # Ensure PostgreSQL also stops
      systemctl stop postgresql 2>/dev/null || true
      echo "[pg-node-${count.index + 1}] Shutdown complete, ready for Terraform destroy"
    EOT
    when = destroy
  }
}

# ============== DYNAMIC IP DISCOVERY ==============

data "google_compute_instance" "pg_nodes" {
  count = var.node_count
  name  = google_compute_instance.pg_nodes[count.index].name
  zone  = google_compute_instance.pg_nodes[count.index].zone
}

locals {
  node_ips      = data.google_compute_instance.pg_nodes[*].network_interface[0].network_ip
  node_ips_json = jsonencode(local.node_ips)
}

# ============== UPDATE SECRET MANAGER AFTER CREATION ==============

resource "null_resource" "update_secret" {
  depends_on = [data.google_compute_instance.pg_nodes]

  provisioner "local-exec" {
    command     = "bash -c 'echo \"{\\\"node_count\\\": ${var.node_count}, \\\"node_ips\\\": ${local.node_ips_json}}\" > \"${path.module}/secret_data.json\" && gcloud secrets versions add ${google_secret_manager_secret.pg_cluster_config.secret_id} --data-file=\"${path.module}/secret_data.json\" --project=${var.project_id} && rm -f \"${path.module}/secret_data.json\"'"
    interpreter = ["bash", "-c"]
  }
}

# ============== SCALE-OUT: RELOAD EXISTING NODES ==============
# When node_count increases, existing nodes reload Patroni config
# to discover new cluster members
resource "null_resource" "reload_existing_nodes" {
  depends_on = [null_resource.update_secret]

  triggers = {
    node_count = var.node_count
    node_names = join("-", [for i in google_compute_instance.pg_nodes : i.name])
  }

  provisioner "local-exec" {
    command = <<-EOT
      echo "Checking if this is a scale-out operation..."
      NEW_COUNT=${var.node_count}
      echo "Current node count: $$NEW_COUNT"

      # Get existing node IPs (excluding newly added last node)
      declare -a NODE_IPS
      for idx in $(seq 0 $((NEW_COUNT - 2))); do
        name="pg-node-$((idx + 1))"
        ip=$(gcloud compute instances describe "$$name" --zone=$(gcloud compute instances describe "$$name" --format='value(zone)' 2>/dev/null | sed 's|.*/||') --format='value(networkInterfaces[0].networkIP)' 2>/dev/null)
        if [[ -n "$$ip" ]]; then
          NODE_IPS+=("$$ip")
        fi
      done

      echo "Reloading Patroni on $${#NODE_IPS[@]} existing nodes..."
      for ip in "$${NODE_IPS[@]}"; do
        echo "Reloading Patroni on $$ip..."
        timeout 20 ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 -o LogLevel=ERROR \
          -i /tmp/pg_ssh_key \
          ubuntu@$$ip \
          "sudo patronictl -c /etc/patroni/patroni.yml reload pg-ha-cluster" 2>/dev/null || true
        echo "Reload command sent to $$ip"
      done
      echo "Scale-out reload complete"
    EOT
  }
}

# ============== TARGET POOL (LOAD BALANCER) ==============

resource "google_compute_target_pool" "pg_pool" {
  name      = "pg-pool"
  region    = var.region
  instances = google_compute_instance.pg_nodes[*].self_link
}

resource "google_compute_address" "pg_external_ip" {
  name   = "pg-external-ip"
  region = var.region
}

resource "google_compute_forwarding_rule" "pg_forwarding_rule" {
  name                  = "pg-external-forwarding-rule"
  region                = var.region
  ip_address            = google_compute_address.pg_external_ip.address
  ip_protocol           = "TCP"
  port_range            = "5432"
  load_balancing_scheme = "EXTERNAL"
  target                = google_compute_target_pool.pg_pool.id
}
