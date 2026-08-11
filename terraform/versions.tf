terraform {
  required_version = ">= 1.9"

  backend "gcs" {}

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 7.0"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.12"
    }
  }
}

# billing_project plus user_project_override is required when applying with user
# credentials. Without it, APIs that demand a quota project (accesscontextmanager
# and serviceusage among them) bill the call to Google's shared OAuth client
# project and fail with SERVICE_DISABLED on a project ID you do not recognize.
#
# The quota project is the seed, which is outside the perimeter, and that is
# correct for everything except the resources inside it. See below.
provider "google" {
  region                = var.region
  billing_project       = var.seed_project_id
  user_project_override = true
}

# The same provider, aimed at a quota project inside the perimeter, used only by
# the restricted resources.
#
# This exists because of a failure that took a while to read correctly. With
# enforcement on, Terraform could not manage the bucket or the dataset, while
# plain gcloud as the same user could. The ingress rule was not the problem: the
# violation was RESOURCES_NOT_IN_SAME_SERVICE_PERIMETER rather than
# NO_MATCHING_ACCESS_LEVEL, which is a different refusal with a different cause.
#
# user_project_override attaches the quota project to every API call. A call
# that reads a bucket inside the perimeter while billing a project outside it
# names two resources on opposite sides of the boundary, and the perimeter
# refuses it no matter who is asking. An ingress rule cannot fix that, because
# nothing about the identity is what is wrong.
#
# Pointing the quota project at the workload project puts both sides of the call
# in the same perimeter. The seed keeps holding state, outside, where the
# argument in projects.tf says it belongs: the GCS backend authenticates with
# ADC directly and does not carry a quota project override, so it is unaffected.
#
# This is why workload_name_suffix is an input rather than a random_id. Provider
# configuration cannot reference a resource, so the project ID has to be
# knowable before anything is created.
provider "google" {
  alias                 = "inperimeter"
  region                = var.region
  billing_project       = local.workload_project_id
  user_project_override = true
}
