variable "project_id" {
  type        = string
  description = "GCP Project ID"
  default     = "project-3a51a40b-8c9e-4126-804"
}

variable "region" {
  type    = string
  default = "asia-southeast1"
}

variable "zone" {
  type    = string
  default = "asia-southeast1-a"
}

variable "db_username" {
  type        = string
  sensitive   = true
  description = "PostgreSQL username"
}

variable "db_password" {
  type        = string
  sensitive   = true
  description = "PostgreSQL password"
}

variable "allowed_client_cidr" {
  type        = string
  description = "IP CIDR được phép SSH vào VM (CIS 3.6)"
  sensitive   = true
}

variable "storage_bucket_name" {
  type    = string
  default = "benchmark-storage-3a51a40b-8c9e-4126-804"
}

variable "alert_email" {
  type        = string
  description = "Email nhận cảnh báo bảo mật"
  default     = "23521549@gm.uit.edu.vn"
}

# Last updated: 2026-05-14
# Last updated: 2026-05-14
