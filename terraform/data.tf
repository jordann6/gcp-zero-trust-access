# The data the perimeter exists to protect, and the identity that is allowed to
# read it.
#
# The service account below is not a straw man. It holds roles/storage.objectViewer
# on the bucket and roles/bigquery.dataViewer on the dataset, granted deliberately,
# scoped to exactly those resources. By every IAM measure it is supposed to be
# able to read this data, and from inside the perimeter it does.
#
# That is what makes the denial in the demo mean something. Nothing is
# misconfigured, no permission is missing, and the read still fails from
# outside. If the demo used an identity with no permissions the denial would
# prove only that IAM works.

resource "google_service_account" "analyst" {
  project      = google_project.workload.project_id
  account_id   = "${var.name_prefix}-analyst"
  display_name = "Analyst identity: legitimately entitled to the protected data"
  description  = "Attached to the in-perimeter instance and impersonated from outside it. The permissions are identical in both cases, which is the point."

  depends_on = [google_project_service.workload]
}

# The administrator can mint tokens for the analyst account. This is what lets
# the demo attempt the read from outside as that identity, without ever creating
# a service account key.
#
# Impersonation rather than a key is not a detail. A downloaded key is a bearer
# credential with no expiry that survives the laptop it was created on, which is
# the failure mode this whole build is arguing against.
resource "google_service_account_iam_member" "admin_impersonates_analyst" {
  service_account_id = google_service_account.analyst.name
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = var.admin_principal
}

resource "google_storage_bucket" "protected" {
  provider = google.inperimeter

  name     = "${local.workload_project_id}-protected"
  project  = google_project.workload.project_id
  location = var.region

  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"

  # This is demo data that gets destroyed at the end of the exercise. On a real
  # bucket holding the kind of data worth a perimeter, this would be false.
  force_destroy = true

  versioning {
    enabled = true
  }

  labels = var.labels

  depends_on = [google_project_service.workload]
}

resource "google_storage_bucket_object" "secret" {
  provider = google.inperimeter

  name   = "customer-records.txt"
  bucket = google_storage_bucket.protected.name

  content = <<-EOT
    SYNTHETIC RECORDS. Not real data. Generated for a portfolio demonstration.

    account_id,name,region,contract_value
    ACME-0001,Northwind Trading,us-central1,420000
    ACME-0002,Contoso Freight,us-east4,265000
    ACME-0003,Fabrikam Logistics,europe-west1,910000

    If you can read this from outside the perimeter, the perimeter is not
    enforced. Check: terraform output perimeter_mode
  EOT
}

resource "google_storage_bucket_iam_member" "analyst_reads" {
  provider = google.inperimeter

  bucket = google_storage_bucket.protected.name
  role   = "roles/storage.objectViewer"
  member = google_service_account.analyst.member
}

resource "google_bigquery_dataset" "protected" {
  provider = google.inperimeter

  project    = google_project.workload.project_id
  dataset_id = "${replace(var.name_prefix, "-", "_")}_protected"
  location   = var.region
  labels     = var.labels

  description = "Second restricted service, so the demo shows the perimeter is a property of the boundary rather than a Cloud Storage feature."

  # Demo data. Lets terraform destroy remove the dataset without a manual pass.
  delete_contents_on_destroy = true

  depends_on = [google_project_service.workload]
}

# A view rather than a table, so there is something to read without running a
# load job and without storing a byte. Querying it exercises the same
# bigquery.googleapis.com path the perimeter restricts.
resource "google_bigquery_table" "revenue" {
  provider = google.inperimeter

  project             = google_project.workload.project_id
  dataset_id          = google_bigquery_dataset.protected.dataset_id
  table_id            = "quarterly_revenue"
  deletion_protection = false
  labels              = var.labels

  view {
    use_legacy_sql = false
    query          = <<-SQL
      SELECT 'FY26-Q3' AS period, 'Northwind Trading' AS account, 420000 AS contract_value
      UNION ALL SELECT 'FY26-Q3', 'Contoso Freight', 265000
      UNION ALL SELECT 'FY26-Q3', 'Fabrikam Logistics', 910000
    SQL
  }
}

resource "google_bigquery_dataset_iam_member" "analyst_reads" {
  provider = google.inperimeter

  project    = google_project.workload.project_id
  dataset_id = google_bigquery_dataset.protected.dataset_id
  role       = "roles/bigquery.dataViewer"
  member     = google_service_account.analyst.member
}

# Running a query needs job creation at the project level in addition to read
# access on the data itself.
resource "google_project_iam_member" "analyst_job_user" {
  project = google_project.workload.project_id
  role    = "roles/bigquery.jobUser"
  member  = google_service_account.analyst.member
}
