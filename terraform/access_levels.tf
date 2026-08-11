# Access Context Manager: the access policy and the one access level everything
# else refers to.
#
# An organization holds exactly one org-scoped access policy. Creating a second
# fails, and the error does not say "one already exists" in so many words, so
# check before applying:
#
#   gcloud access-context-manager policies list --organization=ORG_ID
#
# If one is already there, pass its numeric ID as access_policy_name and this
# module will attach to it instead of creating one.

resource "google_access_context_manager_access_policy" "org" {
  count = var.access_policy_name == null ? 1 : 0

  parent = "organizations/${var.org_id}"
  title  = "org-access-policy"
}

locals {
  access_policy_id = coalesce(
    var.access_policy_name,
    try(google_access_context_manager_access_policy.org[0].name, null),
  )

  prefix              = replace(var.name_prefix, "-", "_")
  trusted_level_id    = "accessPolicies/${local.access_policy_id}/accessLevels/${local.prefix}_trusted"
  management_level_id = "accessPolicies/${local.access_policy_id}/accessLevels/${local.prefix}_management"
}

# The trusted context.
#
# Two conditions combined with AND, which is the whole idea in one resource:
# being the right person is not sufficient, and coming from the right place is
# not sufficient, and the request has to be both.
#
# This is where GCP differs most from the other two clouds. An AWS IAM policy
# can carry an aws:SourceIp condition, but it lives in the policy, so the same
# condition has to be repeated in every policy that needs it and drifts the
# moment one is missed. An access level is a named object evaluated by the
# platform, referenced by IAM conditions and by perimeter ingress rules alike.
# Changing what "trusted" means is one edit here, not an audit of every policy.
resource "google_access_context_manager_access_level" "trusted" {
  parent = "accessPolicies/${local.access_policy_id}"
  name   = local.trusted_level_id
  title  = "Trusted context: known identity from a known network"

  basic {
    combining_function = "AND"

    conditions {
      ip_subnetworks = var.trusted_ip_ranges
    }

    conditions {
      members = [var.admin_principal]
    }

    # The device policy is the half of this that actually matters in production,
    # and it is deliberately not enabled here because it cannot be. Every field
    # below depends on endpoint verification reporting device posture, which
    # requires enrolled, managed devices under Cloud Identity Premium or
    # Workspace Enterprise. A solo org on the free tier has no managed devices,
    # so turning this on would produce a level nothing can ever satisfy.
    #
    # Left in as a comment rather than deleted, because an IP range standing in
    # for a trusted device is the weakest link in this build and it is better
    # to name that than to let the config imply otherwise.
    #
    # device_policy {
    #   require_screen_lock          = true
    #   require_corp_owned           = true
    #   os_constraints {
    #     os_type                    = "DESKTOP_MAC"
    #     minimum_version            = "15.0.0"
    #     require_verified_chrome_os = false
    #   }
    # }
  }
}

# The management level: identity only, no network condition.
#
# Two levels rather than one, because they are load bearing in different places
# and one of them must never be allowed to fail.
#
# The trusted level above gates access to the application, and the demo revokes
# it on purpose by pointing trusted_ip_ranges at TEST-NET-1 to show a 403 that
# comes from context rather than from a missing role. If the perimeter's ingress
# rule also depended on that level, the same edit would cut Terraform off from
# the restricted services in the middle of the demo, and the apply that restores
# the setting could not read its own state to run. The demo would end by
# breaking the thing it was demonstrating.
#
# So the perimeter's ingress rule depends on this level instead: the
# administrator, from anywhere, and nothing else. That is a deliberate weakening
# and it should be named as one. It is the standard break-glass shape for a
# perimeter, on the reasoning that the ability to remove a control has to
# survive the control being wrong, and it is why the perimeter still holds
# against the analyst identity while remaining manageable by a human.
resource "google_access_context_manager_access_level" "management" {
  parent = "accessPolicies/${local.access_policy_id}"
  name   = local.management_level_id
  title  = "Management: administrator identity, deliberately without a network condition"

  basic {
    combining_function = "AND"

    conditions {
      members = [var.admin_principal]
    }
  }
}
