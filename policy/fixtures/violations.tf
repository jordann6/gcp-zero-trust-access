# A Terraform file that must fail the rules in ../gcp.rego.
#
# Nothing here is ever applied and `terraform validate` never sees it. CI runs
# conftest against it and fails the build if it PASSES.
#
# It exists because a Rego suite does not die by breaking, it dies by going
# vacuous. A rule whose first line stops matching the input shape returns no
# violations, and no violations is indistinguishable from a clean run. The
# platform-guardrails repo guards its own shared suite this way in
# self-test.yml; this is the same guard for the rules that live here.
#
# The rules in gcp.rego were not running at all until 2026-08-13. Both jobs in
# guardrails.yml passed skip_policy: true, so the conftest job was skipped
# entirely, while the workflow's header comment claimed conftest ran against
# policy/. Fourteen rules, zero executions, and a green check.
#
# When adding a rule to gcp.rego, add its violation here.

resource "google_project" "bad" {
  name       = "bad"
  project_id = "bad"

  # The default VPC ships an SSH-from-anywhere rule in every region.
  auto_create_network = true
}

resource "google_compute_instance" "bad" {
  name         = "bad"
  machine_type = "e2-micro"
  zone         = "us-central1-a"

  network_interface {
    network = "default"

    # A public address is an inbound path that never passes through IAP, which
    # makes every access control in the repo optional.
    access_config {}
  }

  # enable-oslogin is absent, so SSH falls back to keys in metadata: standing
  # credentials that outlive any access level.
  metadata = {
    foo = "bar"
  }
}

resource "google_compute_subnetwork" "bad" {
  name          = "bad"
  ip_cidr_range = "10.0.0.0/24"
  region        = "us-central1"
  network       = "bad"

  # private_ip_google_access omitted, so the in-perimeter path fails for
  # reasons unrelated to the perimeter.
}

resource "google_compute_firewall" "bad" {
  name    = "bad"
  network = "bad"

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  # Ingress is meant to be the IAP forwarding range and nothing else.
  source_ranges = ["0.0.0.0/0"]
}

# The silent downgrade: a perimeter with neither a status nor a spec exists,
# applies to the project, shows up in the console, and restricts nothing.
resource "google_access_context_manager_service_perimeter" "empty" {
  parent = "accessPolicies/123"
  name   = "accessPolicies/123/servicePerimeters/empty"
  title  = "empty"
}

# Restricting the API that removes perimeters means a bad perimeter can block
# the only call that would undo it.
resource "google_access_context_manager_service_perimeter" "self_locking" {
  parent = "accessPolicies/123"
  name   = "accessPolicies/123/servicePerimeters/self_locking"
  title  = "self_locking"

  status {
    restricted_services = [
      "storage.googleapis.com",
      "accesscontextmanager.googleapis.com",
    ]
  }
}

# An access level with no conditions is satisfied by everything, which is worse
# than no access level, because IAM conditions referencing it look like controls.
resource "google_access_context_manager_access_level" "empty" {
  parent = "accessPolicies/123"
  name   = "accessPolicies/123/accessLevels/empty"
  title  = "empty"

  basic {
  }
}

resource "google_project_iam_member" "bad" {
  project = "p"
  role    = "roles/owner"
  member  = "user:x@example.com"
}

resource "google_service_account_key" "bad" {
  service_account_id = "x"
}

# allUsers routes around IAP entirely: the container becomes reachable without
# the proxy ever being consulted.
resource "google_cloud_run_v2_service_iam_member" "bad" {
  name     = "bad"
  location = "us-central1"
  role     = "roles/run.invoker"
  member   = "allUsers"
}
