# Bootstrap layer.
#
# Creates the seed project and the Terraform state bucket. The seed acts as the
# quota project for API calls made with user credentials and holds nothing else.
#
# The seed staying out of the service perimeter is not an accident of layering,
# it is the single most important decision in this repo. The root module puts a
# VPC Service Controls perimeter around the workload project and restricts
# storage.googleapis.com inside it. If the state bucket lived in a project the
# perimeter covered, then the moment the perimeter went to enforced mode
# Terraform would lose the ability to read its own state from outside, and the
# only way back would be an org-level policy edit made by hand under pressure.
#
# The rule generalizes: the control plane that can remove a perimeter must never
# sit inside it.

resource "random_id" "suffix" {
  byte_length = 3
}

locals {
  seed_project_id = "${var.name_prefix}-seed-${random_id.suffix.hex}"

  # Every API the root module *calls*, not every API the built system uses.
  #
  # The root module sets user_project_override with billing_project pointed
  # here, which makes the seed the quota project for every call Terraform
  # makes. Google requires an API to be enabled on the quota project as well as
  # on the project the resource lands in, so creating a Cloud Run service in the
  # workload project fails with SERVICE_DISABLED naming the seed. The error
  # names a project you are not creating anything in, which is what makes it
  # confusing rather than obvious.
  seed_apis = [
    "accesscontextmanager.googleapis.com",
    "bigquery.googleapis.com",
    "cloudbilling.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "compute.googleapis.com",
    "dns.googleapis.com",
    "iam.googleapis.com",
    "iap.googleapis.com",
    "logging.googleapis.com",
    "run.googleapis.com",
    "serviceusage.googleapis.com",
    "storage.googleapis.com",
  ]
}

resource "google_project" "seed" {
  name            = local.seed_project_id
  project_id      = local.seed_project_id
  org_id          = var.org_id
  billing_account = var.billing_account
  labels          = merge(var.labels, { layer = "seed" })

  deletion_policy     = "DELETE"
  auto_create_network = false
}

resource "google_project_service" "seed" {
  for_each = toset(local.seed_apis)

  project            = google_project.seed.project_id
  service            = each.value
  disable_on_destroy = false
}

resource "google_project_iam_audit_config" "seed" {
  project = google_project.seed.project_id
  service = "allServices"

  dynamic "audit_log_config" {
    for_each = ["ADMIN_READ", "DATA_READ", "DATA_WRITE"]
    content {
      log_type = audit_log_config.value
    }
  }
}

resource "google_storage_bucket" "state_logs" {
  # checkov:skip=CKV_GCP_62: log bucket, so access logging terminates here.
  name     = "${local.seed_project_id}-tfstate-logs"
  project  = google_project.seed.project_id
  location = var.state_bucket_location

  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = true

  versioning {
    enabled = true
  }

  lifecycle_rule {
    condition {
      age = 90
    }
    action {
      type = "Delete"
    }
  }

  depends_on = [google_project_service.seed]
}

resource "google_storage_bucket" "state" {
  name     = "${local.seed_project_id}-tfstate"
  project  = google_project.seed.project_id
  location = var.state_bucket_location

  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = var.force_destroy_state

  versioning {
    enabled = true
  }

  logging {
    log_bucket        = google_storage_bucket.state_logs.name
    log_object_prefix = "tfstate/"
  }

  lifecycle_rule {
    condition {
      num_newer_versions = 20
    }
    action {
      type = "Delete"
    }
  }

  depends_on = [google_project_service.seed]
}
