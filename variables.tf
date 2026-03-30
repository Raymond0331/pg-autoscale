variable "project_id" {
  description = "GCP Project ID"
  type        = string
}

variable "region" {
  description = "GCP Region for deployment"
  type        = string
  default     = "asia-northeast1"
}

variable "zones" {
  description = "Availability zones for node placement"
  type        = list(string)
  default     = ["asia-northeast1-a", "asia-northeast1-b", "asia-northeast1-c"]
}

variable "machine_type" {
  description = "GCP machine type for PostgreSQL nodes"
  type        = string
  default     = "e2-medium"
}

variable "pg_password" {
  description = "PostgreSQL postgres user password"
  type        = string
  sensitive   = true
}

variable "node_count" {
  description = "Number of PostgreSQL HA nodes (3-10)"
  type        = number
  default     = 3
  validation {
    condition     = var.node_count >= 3 && var.node_count <= 10
    error_message = "node_count must be between 3 and 10 (minimum 3 nodes required for Raft quorum)."
  }
}

variable "allowed_external_ips" {
  description = "CIDR blocks allowed to access PostgreSQL externally"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}
