variable "org_id" {
  description = "Numeric GCP organization ID."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{10,14}$", var.org_id))
    error_message = "org_id must be the numeric organization ID, not the domain name."
  }
}

variable "billing_account" {
  description = "Billing account ID in XXXXXX-XXXXXX-XXXXXX form."
  type        = string

  validation {
    condition     = can(regex("^[A-F0-9]{6}-[A-F0-9]{6}-[A-F0-9]{6}$", var.billing_account))
    error_message = "billing_account must look like 0X0X0X-0X0X0X-0X0X0X."
  }
}

variable "seed_project_id" {
  description = "Seed project from the bootstrap layer. Holds state and acts as the API quota project. Must stay outside the perimeter."
  type        = string
}

variable "name_prefix" {
  description = "Prefix for generated project IDs and resource names."
  type        = string
  default     = "jn-zta"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,10}$", var.name_prefix))
    error_message = "name_prefix must be lowercase letters, digits, and hyphens, 3 to 11 characters."
  }
}

variable "region" {
  description = "Region for the subnet, Cloud Run service, and BigQuery dataset."
  type        = string
  default     = "us-central1"
}

variable "zone" {
  description = "Zone for the in-perimeter instance."
  type        = string
  default     = "us-central1-a"
}

variable "admin_principal" {
  description = <<-EOT
    The human who administers this build, in IAM member form, for example
    "user:someone@example.com". Two things depend on it. It is the only principal
    the perimeter's ingress rule admits, which is what keeps Terraform able to
    manage the restricted services once enforcement is on. It is also the only
    principal granted IAP access to the web app, and that grant is conditioned on
    the trusted access level.
  EOT
  type        = string

  validation {
    condition     = can(regex("^(user|group|serviceAccount):", var.admin_principal))
    error_message = "admin_principal must be prefixed with user:, group:, or serviceAccount:."
  }
}

variable "trusted_ip_ranges" {
  description = <<-EOT
    CIDR ranges that satisfy the trusted access level, normally your current
    public IP as a /32. Get it with: curl -s https://api.ipify.org

    This is the honest limitation of a solo build. In a real deployment the
    strong half of an access level is the device policy, which requires
    endpoint verification on managed devices, and that requires Cloud Identity
    Premium or Workspace Enterprise. The device_policy block in access_levels.tf
    is written out and commented for that reason: an IP range is a weak proxy
    for a trusted device, and it is worth being explicit about which one is in
    use here.
  EOT
  type        = list(string)

  validation {
    condition     = length(var.trusted_ip_ranges) > 0
    error_message = "trusted_ip_ranges cannot be empty, or nothing satisfies the access level."
  }
}

variable "access_policy_name" {
  description = <<-EOT
    Numeric ID of an existing org-scoped Access Context Manager policy, if one
    already exists. Leave null to create one.

    An organization can hold exactly one org-scoped access policy. Creating a
    second fails, and the failure is not obvious from the error. Check first:
      gcloud access-context-manager policies list --organization=ORG_ID
  EOT
  type        = string
  default     = null
}

variable "enforce_perimeter" {
  description = <<-EOT
    false puts the perimeter in dry-run: it logs every request it would have
    denied and blocks nothing. true enforces.

    Always apply false first, read the dry-run violations, and only then flip to
    true. A perimeter enforced without that step is how people lock themselves
    out of their own data, and the dry-run spec exists precisely so that the
    blast radius is measurable before it is real.
  EOT
  type        = bool
  default     = false
}

variable "restricted_services" {
  description = <<-EOT
    Services the perimeter restricts. Deliberately narrow.

    accesscontextmanager.googleapis.com is absent on purpose and should stay
    absent. It is the API that removes the perimeter. Restricting it means a
    misconfigured perimeter can block the only call that would undo it, which
    turns a bad apply into a support ticket.

    compute and run are also absent: the demo needs the IAP tunnel and the
    Cloud Run front door reachable from outside, and the control being shown is
    on the data, not on the front door.
  EOT
  type        = list(string)
  default = [
    "storage.googleapis.com",
    "bigquery.googleapis.com",
  ]
}

variable "labels" {
  description = "Labels applied to the workload project and its resources."
  type        = map(string)
  default = {
    managed-by = "terraform"
    project    = "gcp-zero-trust-access"
  }
}
