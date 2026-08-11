# The VPC Service Controls perimeter.
#
# This is the control with no real equivalent on AWS or Azure. IAM answers "may
# this principal perform this action on this resource". The perimeter answers a
# question IAM cannot: "may this data leave". A credential that is valid,
# correctly scoped, and granted on purpose still cannot read an object across
# the boundary from an unapproved context, which is exactly the case that
# defeats IAM, because a stolen credential is by definition a valid one.
#
# The demo makes that concrete. A service account genuinely holding
# roles/storage.objectViewer reads the object from inside and is refused from
# outside. Same identity, same permission, same object, different origin.
#
# Dry run first, always. With enforce_perimeter = false the status block is
# permissive and the spec block carries the restrictions, so every request that
# would have been denied appears in the audit log marked as a dry run and
# nothing actually breaks. Flipping to true promotes the spec into status.
# Skipping that step is how people discover, in production, which service they
# forgot was reaching across the boundary.

locals {
  perimeter_short_name = "${replace(var.name_prefix, "-", "_")}_workload"
  perimeter_resources  = ["projects/${google_project.workload.number}"]

  # Services reachable from inside the VPC.
  #
  # Two entries here are for the machine, not for the workload, and both were
  # found by the dry run rather than by reasoning about it beforehand.
  #
  # oslogin is called by the guest agent on every SSH login. Restrict VPC
  # accessible services without it and the instance stops accepting logins,
  # which reads as a broken IAP tunnel and sends you debugging the wrong control
  # entirely.
  #
  # agentcommunication was not predicted at all. The dry run logged it as
  # SERVICE_NOT_ALLOWED_FROM_VPC within minutes of the instance booting: the
  # guest agent talks to it continuously, and nothing in the design of this
  # build suggested it existed. That is the entire argument for dry run in one
  # log line. Enforcing straight away would have half-broken the guest
  # environment, and the symptom would have surfaced later, somewhere else, and
  # looked nothing like a perimeter problem.
  vpc_allowed_services = [
    "agentcommunication.googleapis.com",
    "bigquery.googleapis.com",
    "compute.googleapis.com",
    "iamcredentials.googleapis.com",
    "logging.googleapis.com",
    "oslogin.googleapis.com",
    "storage.googleapis.com",
  ]
}

resource "google_access_context_manager_service_perimeter" "workload" {
  parent = "accessPolicies/${local.access_policy_id}"
  name   = "accessPolicies/${local.access_policy_id}/servicePerimeters/${local.perimeter_short_name}"
  title  = "Workload data perimeter"
  description = join(" ", [
    "Restricts Cloud Storage and BigQuery in the workload project.",
    "Ingress is admitted only for the administrator, via the management access level.",
  ])

  perimeter_type = "PERIMETER_TYPE_REGULAR"

  # Inhibits the implicit spec so the explicit dry run below is what gets
  # evaluated. Must be true whenever a spec block is present.
  use_explicit_dry_run_spec = !var.enforce_perimeter

  # Enforced configuration. In dry-run mode this is deliberately toothless: the
  # project is inside the perimeter but nothing is restricted, so nothing is
  # denied.
  status {
    resources           = local.perimeter_resources
    restricted_services = var.enforce_perimeter ? var.restricted_services : []
    access_levels       = var.enforce_perimeter ? [google_access_context_manager_access_level.management.name] : []

    dynamic "vpc_accessible_services" {
      for_each = var.enforce_perimeter ? [1] : []
      content {
        enable_restriction = true
        allowed_services   = local.vpc_allowed_services
      }
    }

    # The rule that keeps this manageable.
    #
    # Once storage and bigquery are restricted, Terraform itself is calling them
    # from outside the perimeter, so without an ingress rule the next apply or
    # destroy fails and the config that created the problem can no longer be
    # changed. This admits exactly one identity, through the management access
    # level, which is documented in access_levels.tf as a deliberate escape
    # hatch rather than an oversight.
    #
    # Note the consequence, since it is easy to miss: this is why the demo's
    # exfiltration attempt impersonates a service account rather than running as
    # the administrator. The administrator is admitted by this rule. The service
    # account is not, and that is the denial worth showing.
    dynamic "ingress_policies" {
      for_each = var.enforce_perimeter ? [1] : []
      content {
        ingress_from {
          identities = [var.admin_principal]
          sources {
            access_level = google_access_context_manager_access_level.management.name
          }
        }
        ingress_to {
          resources = ["*"]
          dynamic "operations" {
            for_each = var.restricted_services
            content {
              service_name = operations.value
              method_selectors {
                method = "*"
              }
            }
          }
        }
      }
    }
  }

  # Dry-run configuration: the restrictions as they will be, evaluated and
  # logged but not applied.
  dynamic "spec" {
    for_each = var.enforce_perimeter ? [] : [1]
    content {
      resources           = local.perimeter_resources
      restricted_services = var.restricted_services
      access_levels       = [google_access_context_manager_access_level.management.name]

      vpc_accessible_services {
        enable_restriction = true
        allowed_services   = local.vpc_allowed_services
      }

      ingress_policies {
        ingress_from {
          identities = [var.admin_principal]
          sources {
            access_level = google_access_context_manager_access_level.management.name
          }
        }
        ingress_to {
          resources = ["*"]
          dynamic "operations" {
            for_each = var.restricted_services
            content {
              service_name = operations.value
              method_selectors {
                method = "*"
              }
            }
          }
        }
      }
    }
  }

  lifecycle {
    # A perimeter that vanishes because a resource was renamed is a silent
    # downgrade to no protection at all. Renames should be deliberate.
    create_before_destroy = false
  }

  depends_on = [google_project_service.workload]
}
