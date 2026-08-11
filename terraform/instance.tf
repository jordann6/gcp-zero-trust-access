# The in-perimeter instance.
#
# It exists for one reason: to be the inside of the boundary. The demo runs the
# same read from here and from a laptop, as the same service account, with the
# same permissions, and gets different answers. Without a machine inside the
# perimeter there is nothing to compare the denial against, and a demo that only
# shows a refusal has not shown that the data was ever readable.
#
# No external IP, no NAT, no public SSH. The only way in is the IAP TCP tunnel,
# which authenticates the human before a packet reaches port 22.

resource "google_compute_instance" "inside" {
  project      = google_project.workload.project_id
  name         = "${var.name_prefix}-inside"
  zone         = var.zone
  machine_type = "e2-micro"
  tags         = ["iap-ssh"]
  labels       = var.labels

  boot_disk {
    initialize_params {
      image = "debian-cloud/debian-12"
      size  = 10
      type  = "pd-balanced"
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.private.id
    # No access_config block. That absence is what denies the instance a public
    # address, and it is the difference between a bastion and a target.
  }

  # Identical to the identity the demo impersonates from outside. That is the
  # controlled variable: if the instance ran as a different, more privileged
  # account, the comparison would prove nothing.
  service_account {
    email  = google_service_account.analyst.email
    scopes = ["https://www.googleapis.com/auth/cloud-platform"]
  }

  metadata = {
    # OS Login binds SSH access to IAM rather than to keys pasted into project
    # metadata. Combined with the IAP tunnel it means there is no standing
    # credential on the instance and no key to leak.
    enable-oslogin = "TRUE"

    # Blocks the project-wide SSH keys that would otherwise be an alternate path
    # in, bypassing the IAM binding above.
    block-project-ssh-keys = "TRUE"
  }

  shielded_instance_config {
    enable_secure_boot          = true
    enable_vtpm                 = true
    enable_integrity_monitoring = true
  }

  # The demo reads the protected object with curl and a metadata-server token
  # rather than gcloud. The stock Debian image does not ship the Cloud CLI, and
  # installing it would need a route to the internet, which would need a NAT
  # gateway, which would cost more than the rest of this build combined and
  # would hand the instance the egress path the design removed on purpose.
  #
  # Reading the API directly also makes the mechanism visible: the token comes
  # from the metadata server, the request goes to the restricted VIP, and the
  # perimeter decision happens on the far side.
  metadata_startup_script = <<-EOT
    #!/bin/bash
    set -euo pipefail
    cat > /usr/local/bin/read-protected <<'SCRIPT'
    #!/bin/bash
    # Reads the protected object from inside the perimeter.
    set -euo pipefail
    BUCKET="$1"
    OBJECT="$${2:-customer-records.txt}"
    TOKEN=$(curl -s -H "Metadata-Flavor: Google" \
      "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token" \
      | sed -n 's/.*"access_token":"\([^"]*\)".*/\1/p')
    curl -s -w '\nHTTP %%{http_code}\n' -H "Authorization: Bearer $${TOKEN}" \
      "https://storage.googleapis.com/storage/v1/b/$${BUCKET}/o/$${OBJECT}?alt=media"
    SCRIPT
    chmod 0755 /usr/local/bin/read-protected
  EOT

  allow_stopping_for_update = true

  depends_on = [
    google_project_service.workload,
    google_compute_firewall.iap_ssh,
  ]
}
