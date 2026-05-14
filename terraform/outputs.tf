output "vpc_name" {
  value = google_compute_network.vpc.name
}

output "subnet_name" {
  value = google_compute_subnetwork.subnet.name
}

output "vm_name" {
  value = google_compute_instance.vm.name
}

output "vm_public_ip" {
  value = google_compute_instance.vm.network_interface[0].access_config[0].nat_ip
}

output "postgres_instance_name" {
  value = google_sql_database_instance.postgres.name
}

output "postgres_public_ip" {
  value = google_sql_database_instance.postgres.public_ip_address
}

output "storage_bucket_name" {
  value = google_storage_bucket.log_bucket.name
}

output "log_sink_name" {
  value = google_logging_project_sink.log_sink.name
}

output "log_sink_writer_identity" {
  value = google_logging_project_sink.log_sink.writer_identity
}

output "app_sa_email" {
  value = google_service_account.app_sa.email
}

output "kms_crypto_key_id" {
  value = google_kms_crypto_key.my_crypto_key.id
}

output "dns_zone_name" {
  value = google_dns_managed_zone.public.name
}
