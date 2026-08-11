# The identity-aware front door.
#
# IAP sits in front of the Cloud Run service and terminates every request that
# is not authenticated and authorized. The application never sees an anonymous
# request, so it does not need a login page, a session store, or an opinion
# about who the caller is.
#
# IAP is enabled directly on the service rather than through a load balancer.
# The older pattern required an external HTTPS load balancer with a backend
# service, a managed certificate, and a domain, which is roughly twenty dollars
# a month of infrastructure standing in front of a container that scales to
# zero. Direct IAP protects the run.app endpoint itself and costs nothing.
#
# The image is Google's stock hello container on purpose. Nothing about this
# build is demonstrated by application code, and pulling in Artifact Registry, a
# Dockerfile, and a Cloud Build pipeline to serve a static page would add three
# moving parts that the access control does not depend on.

resource "google_cloud_run_v2_service" "app" {
  project  = google_project.workload.project_id
  name     = "${var.name_prefix}-app"
  location = var.region
  labels   = var.labels

  # Demo resource. Left on, terraform destroy fails and the teardown needs a
  # manual console step.
  deletion_protection = false

  # The endpoint is reachable, and that is fine. IAP is in the request path
  # ahead of the container, and the container itself grants nothing to
  # allUsers, so an unauthenticated request never reaches application code.
  # Network reachability is not the access control here, which is the entire
  # argument for identity-aware proxying over network-position trust.
  ingress = "INGRESS_TRAFFIC_ALL"

  iap_enabled = true

  template {
    containers {
      image = "us-docker.pkg.dev/cloudrun/container/hello"

      resources {
        limits = {
          cpu    = "1"
          memory = "512Mi"
        }
      }
    }

    scaling {
      min_instance_count = 0
      max_instance_count = 2
    }
  }

  depends_on = [
    google_project_service.workload,
    time_sleep.service_agents,
  ]
}

# IAP invokes the backend on the caller's behalf, so the IAP service agent needs
# run.invoker. Without this the front door authenticates correctly and then
# returns 403 from the backend, which looks like an authorization bug in the
# access level and is not.
resource "google_cloud_run_v2_service_iam_member" "iap_invoker" {
  project  = google_cloud_run_v2_service.app.project
  location = google_cloud_run_v2_service.app.location
  name     = google_cloud_run_v2_service.app.name
  role     = "roles/run.invoker"
  member   = local.iap_service_agent

  depends_on = [time_sleep.service_agents]
}

# The grant that decides who gets in, and under what conditions.
#
# This is the piece worth reading twice. The role alone is not the
# authorization: it is conditioned on the request satisfying the trusted access
# level, evaluated per request by the platform. Losing the trusted context
# revokes access without touching the role, and without any code in the
# application knowing that a policy exists.
#
# An IAM condition can reference an access level by name because access levels
# are first-class objects rather than inline policy text. The equivalent on AWS
# would be an aws:SourceIp condition written into the policy itself, which means
# the definition of "trusted" is copied into every policy that needs it.
resource "google_iap_web_cloud_run_service_iam_member" "admin" {
  project                = google_cloud_run_v2_service.app.project
  location               = google_cloud_run_v2_service.app.location
  cloud_run_service_name = google_cloud_run_v2_service.app.name
  role                   = "roles/iap.httpsResourceAccessor"
  member                 = var.admin_principal

  condition {
    title       = "trusted-context-only"
    description = "Access requires the request to satisfy the trusted access level, not merely to carry the role."
    expression  = "\"${google_access_context_manager_access_level.trusted.name}\" in request.auth.access_levels"
  }

  depends_on = [google_project_service.workload]
}

# Reaching the instance over the IAP TCP tunnel is a separate authorization from
# reaching the web app, on a separate role, and it is what removes the need for
# any inbound path to the instance at all.
resource "google_project_iam_member" "admin_tunnel" {
  project = google_project.workload.project_id
  role    = "roles/iap.tunnelResourceAccessor"
  member  = var.admin_principal
}

resource "google_project_iam_member" "admin_oslogin" {
  project = google_project.workload.project_id
  role    = "roles/compute.osAdminLogin"
  member  = var.admin_principal
}

# The instance runs as the analyst service account, so logging in gives the
# rights of that account and nothing more. Using the instance as a person
# requires being able to act as it.
resource "google_service_account_iam_member" "admin_uses_analyst" {
  service_account_id = google_service_account.analyst.name
  role               = "roles/iam.serviceAccountUser"
  member             = var.admin_principal
}
