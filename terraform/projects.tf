# The workload project. One project, and it is the only thing inside the
# perimeter.
#
# The seed project from the bootstrap layer stays outside. That separation is
# the reason a bad perimeter here is recoverable: Terraform reads its state from
# a bucket the perimeter does not cover, so it can always plan the change that
# removes the perimeter.

resource "random_id" "suffix" {
  byte_length = 3
}

locals {
  workload_project_id = "${var.name_prefix}-work-${random_id.suffix.hex}"

  workload_apis = [
    "bigquery.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "compute.googleapis.com",
    "dns.googleapis.com",
    "iam.googleapis.com",
    "iamcredentials.googleapis.com",
    "iap.googleapis.com",
    "logging.googleapis.com",
    "run.googleapis.com",
    "storage.googleapis.com",
  ]
}

resource "google_project" "workload" {
  name            = local.workload_project_id
  project_id      = local.workload_project_id
  org_id          = var.org_id
  billing_account = var.billing_account
  labels          = merge(var.labels, { layer = "workload" })

  deletion_policy = "DELETE"

  # No default VPC. The default network ships firewall rules that allow SSH from
  # anywhere, which is the exact assumption this build exists to remove.
  auto_create_network = false
}

resource "google_project_service" "workload" {
  for_each = toset(local.workload_apis)

  project            = google_project.workload.project_id
  service            = each.value
  disable_on_destroy = false
}

# Data access logs are off by default, and without them a VPC Service Controls
# violation is visible but the successful reads it should be compared against
# are not. The dry-run exercise is much less useful with only half the picture.
resource "google_project_iam_audit_config" "workload" {
  project = google_project.workload.project_id
  service = "allServices"

  dynamic "audit_log_config" {
    for_each = ["ADMIN_READ", "DATA_READ", "DATA_WRITE"]
    content {
      log_type = audit_log_config.value
    }
  }
}

# The IAP service agent is created when the IAP API is enabled, and it is the
# principal that actually invokes Cloud Run once IAP fronts the service.
#
# The email is constructed from the project number rather than read from
# google_project_service_identity, which does not cover every service and moves
# between the google and google-beta providers. The sleep is because service
# agent creation trails the API enablement by a few seconds, and an IAM binding
# to a principal that does not exist yet fails.
resource "time_sleep" "service_agents" {
  depends_on      = [google_project_service.workload]
  create_duration = "60s"
}

locals {
  iap_service_agent = "serviceAccount:service-${google_project.workload.number}@gcp-sa-iap.iam.gserviceaccount.com"
}
