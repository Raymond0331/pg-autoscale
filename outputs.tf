output "node_ips" {
  description = "Internal IP addresses of PostgreSQL nodes"
  value       = local.node_ips
}

output "node_names" {
  description = "Names of PostgreSQL nodes"
  value       = google_compute_instance.pg_nodes[*].name
}

output "external_ip" {
  description = "External IP address for PostgreSQL access"
  value       = google_compute_address.pg_external_ip.address
}

output "target_pool" {
  description = "Target Pool self-link"
  value       = google_compute_target_pool.pg_pool.self_link
}

output "node_count" {
  description = "Current number of nodes in cluster"
  value       = var.node_count
}

output "secret_id" {
  description = "Secret Manager secret ID for cluster config"
  value       = google_secret_manager_secret.pg_cluster_config.secret_id
}
