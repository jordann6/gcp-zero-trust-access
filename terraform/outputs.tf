output "workload_project_id" {
  description = "The project inside the perimeter."
  value       = google_project.workload.project_id
}

output "app_url" {
  description = "Cloud Run endpoint, fronted by IAP. Reachable by anyone, useful to nobody without the trusted context."
  value       = google_cloud_run_v2_service.app.uri
}

output "protected_bucket" {
  description = "Bucket the perimeter restricts."
  value       = google_storage_bucket.protected.name
}

output "protected_dataset" {
  description = "BigQuery dataset the perimeter restricts."
  value       = google_bigquery_dataset.protected.dataset_id
}

output "analyst_service_account" {
  description = "Identity that legitimately holds read access to the protected data, and is still refused from outside the perimeter."
  value       = google_service_account.analyst.email
}

output "instance_name" {
  description = "In-perimeter instance, reachable only through the IAP TCP tunnel."
  value       = google_compute_instance.inside.name
}

output "access_policy_id" {
  description = "Numeric ID of the org-scoped access policy. Pass this back as access_policy_name on a rebuild so a second one is not attempted."
  value       = local.access_policy_id
}

output "trusted_access_level" {
  description = "Access level gating the IAP grant. Identity AND network."
  value       = google_access_context_manager_access_level.trusted.name
}

output "management_access_level" {
  description = "Access level gating perimeter ingress. Identity only, deliberately, so a wrong perimeter stays fixable."
  value       = google_access_context_manager_access_level.management.name
}

output "perimeter_mode" {
  description = "Whether the perimeter is enforcing or logging what it would deny."
  value       = var.enforce_perimeter ? "ENFORCED" : "DRY_RUN (nothing is being blocked)"
}

output "demo_env" {
  description = "Rendered by scripts/demo.sh env into .demo.env, which the demo and destroy scripts source."
  value       = <<-EOT
    export WORKLOAD_PROJECT="${google_project.workload.project_id}"
    export WORKLOAD_PROJECT_NUMBER="${google_project.workload.number}"
    export SEED_PROJECT="${var.seed_project_id}"
    export REGION="${var.region}"
    export ZONE="${var.zone}"
    export APP_URL="${google_cloud_run_v2_service.app.uri}"
    export APP_SERVICE="${google_cloud_run_v2_service.app.name}"
    export PROTECTED_BUCKET="${google_storage_bucket.protected.name}"
    export PROTECTED_OBJECT="${google_storage_bucket_object.secret.name}"
    export PROTECTED_DATASET="${google_bigquery_dataset.protected.dataset_id}"
    export PROTECTED_TABLE="${google_bigquery_table.revenue.table_id}"
    export ANALYST_SA="${google_service_account.analyst.email}"
    export INSTANCE="${google_compute_instance.inside.name}"
    export ACCESS_POLICY_ID="${local.access_policy_id}"
    export TRUSTED_LEVEL="${google_access_context_manager_access_level.trusted.name}"
    export MANAGEMENT_LEVEL="${google_access_context_manager_access_level.management.name}"
    export PERIMETER_NAME="${local.perimeter_short_name}"
    export PERIMETER_ENFORCED="${var.enforce_perimeter}"
  EOT
}
