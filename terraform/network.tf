# The network, built so that nothing in it can reach or be reached from the
# internet.
#
# There is no Cloud NAT and no external IP anywhere. That is partly cost, since
# a NAT gateway runs about $0.045 an hour and would dominate the bill for this
# build, but mostly it is the point: an instance with no route to the internet
# cannot exfiltrate to the internet, and the perimeter then only has to cover
# the Google APIs. Private Google Access is what keeps the instance useful
# without giving it that route.

resource "google_compute_network" "vpc" {
  project                 = google_project.workload.project_id
  name                    = "${var.name_prefix}-vpc"
  auto_create_subnetworks = false
  routing_mode            = "REGIONAL"

  depends_on = [google_project_service.workload]
}

resource "google_compute_subnetwork" "private" {
  project       = google_project.workload.project_id
  name          = "${var.name_prefix}-private"
  region        = var.region
  network       = google_compute_network.vpc.id
  ip_cidr_range = "10.20.0.0/24"

  # Without this an instance with no external IP cannot reach any Google API at
  # all, and the in-perimeter read in the demo fails for a reason that has
  # nothing to do with the perimeter.
  private_ip_google_access = true

  log_config {
    aggregation_interval = "INTERVAL_10_MIN"
    flow_sampling        = 0.5
    metadata             = "INCLUDE_ALL_METADATA"
  }
}

# SSH reaches the instance only through the IAP TCP forwarding range. There is
# no other ingress rule, no bastion with a public address, and no VPN.
#
# 35.235.240.0/20 is IAP's fixed forwarding range. Traffic arriving from it has
# already been authenticated and authorized by IAP against
# roles/iap.tunnelResourceAccessor, so the firewall rule is not the access
# control, it is the plumbing behind it.
resource "google_compute_firewall" "iap_ssh" {
  project       = google_project.workload.project_id
  name          = "${var.name_prefix}-allow-iap-ssh"
  network       = google_compute_network.vpc.name
  direction     = "INGRESS"
  priority      = 1000
  source_ranges = ["35.235.240.0/20"]
  target_tags   = ["iap-ssh"]

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  log_config {
    metadata = "INCLUDE_ALL_METADATA"
  }
}

# Everything else is denied inbound. GCP's implied rules already deny ingress,
# so this exists to make the denial explicit and to log it, which is the
# difference between believing traffic is blocked and being able to show it.
resource "google_compute_firewall" "deny_all_ingress" {
  project       = google_project.workload.project_id
  name          = "${var.name_prefix}-deny-all-ingress"
  network       = google_compute_network.vpc.name
  direction     = "INGRESS"
  priority      = 65000
  source_ranges = ["0.0.0.0/0"]

  deny {
    protocol = "all"
  }

  log_config {
    metadata = "INCLUDE_ALL_METADATA"
  }
}

# Egress to the restricted VIP only.
#
# The private DNS zone below sends every *.googleapis.com lookup to
# 199.36.153.4/30, the restricted VIP, which serves only APIs that support VPC
# Service Controls and refuses everything else. The default internet gateway
# route for that /30 is what makes it reachable without a NAT.
#
# The pairing matters. Private Google Access alone would resolve googleapis.com
# to the public VIP, and a request to the public VIP from inside the perimeter
# is a request that could reach a project outside it.
resource "google_compute_route" "restricted_vip" {
  project          = google_project.workload.project_id
  name             = "${var.name_prefix}-restricted-vip"
  network          = google_compute_network.vpc.name
  dest_range       = "199.36.153.4/30"
  next_hop_gateway = "default-internet-gateway"
  priority         = 1000
}

resource "google_dns_managed_zone" "googleapis" {
  project     = google_project.workload.project_id
  name        = "${var.name_prefix}-googleapis"
  dns_name    = "googleapis.com."
  description = "Sends all Google API traffic to the restricted VIP, which only serves VPC-SC aware services."
  visibility  = "private"

  private_visibility_config {
    networks {
      network_url = google_compute_network.vpc.id
    }
  }

  depends_on = [google_project_service.workload]
}

resource "google_dns_record_set" "googleapis_a" {
  project      = google_project.workload.project_id
  managed_zone = google_dns_managed_zone.googleapis.name
  name         = "restricted.googleapis.com."
  type         = "A"
  ttl          = 300
  rrdatas      = ["199.36.153.4", "199.36.153.5", "199.36.153.6", "199.36.153.7"]
}

resource "google_dns_record_set" "googleapis_cname" {
  project      = google_project.workload.project_id
  managed_zone = google_dns_managed_zone.googleapis.name
  name         = "*.googleapis.com."
  type         = "CNAME"
  ttl          = 300
  rrdatas      = ["restricted.googleapis.com."]
}
