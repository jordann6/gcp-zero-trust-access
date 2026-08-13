# Repo-local conftest rules, layered on top of the shared suite in
# platform-guardrails.
#
# The shared policies are AWS-shaped by history: access keys, security groups,
# NAT gateways. None of those resource types appear here, so on a GCP repo they
# pass by being vacuously true. These are the GCP equivalents.
#
# Several of them exist specifically to catch a silent downgrade. The failure
# mode this repo has to defend against is not a resource that is obviously
# wrong, it is a perimeter or an access level that still exists, still applies,
# and no longer restricts anything. Those read as configured at a glance, which
# is exactly why they need a machine check.
#
# Everything here is checkable in the HCL itself. Anything that needs a resolved
# value or has to see inside a module belongs in plan-based policy.

package main

import rego.v1

gcp_blocks_of(v) := v if {
	is_array(v)
}

gcp_blocks_of(v) := [v] if {
	is_object(v)
}

gcp_resources contains r if {
	some file in input
	some type, named in file.contents.resource
	some name, block in named
	some body in gcp_blocks_of(block)
	r := {"type": type, "name": name, "body": body, "path": file.path}
}

# A default VPC arrives with permissive firewall rules nobody chose, in every
# region, including one that allows SSH from anywhere. This repo removes every
# inbound path except the IAP tunnel, and a default network reinstates one.
deny contains msg if {
	some r in gcp_resources
	r.type == "google_project"
	r.body.auto_create_network == true
	msg := sprintf(
		"%s: google_project.%s sets auto_create_network = true. The default VPC ships an SSH-from-anywhere rule.",
		[r.path, r.name],
	)
}

# An external IP is an inbound path that does not pass through IAP, which makes
# every access control in this repo optional.
deny contains msg if {
	some r in gcp_resources
	r.type == "google_compute_instance"
	some nic in gcp_blocks_of(r.body.network_interface)
	nic.access_config
	msg := sprintf(
		"%s: google_compute_instance.%s has an access_config, giving it a public address. Reachability here is meant to be the IAP tunnel and nothing else.",
		[r.path, r.name],
	)
}

# OS Login binds SSH to IAM. Without it the instance falls back to keys in
# metadata, which are standing credentials that outlive any access level.
#
# object.get with a default, rather than indexing the key directly. Indexing a
# key that is absent yields undefined, and `undefined != "TRUE"` is itself
# undefined rather than true, so the rule declined to fire on exactly the case
# it was written for: an instance whose metadata omits enable-oslogin
# altogether. It caught only an instance that set the key to some other value,
# which nobody does. Found 2026-08-13 by policy/fixtures/violations.tf.
#
# The `r.body.metadata` guard is gone with it. An instance with no metadata
# block at all has no enable-oslogin either, and it should fail the same way.
deny contains msg if {
	some r in gcp_resources
	r.type == "google_compute_instance"
	object.get(r.body, ["metadata", "enable-oslogin"], "") != "TRUE"
	msg := sprintf(
		"%s: google_compute_instance.%s does not set enable-oslogin = TRUE. SSH would fall back to metadata keys.",
		[r.path, r.name],
	)
}

# Private Google Access is what lets an instance with no external IP reach a
# Google API. Without it the in-perimeter path fails for reasons unrelated to
# the perimeter, which is a debugging trap more than a security one, but the
# usual fix people reach for is a NAT gateway and an internet route.
deny contains msg if {
	some r in gcp_resources
	r.type == "google_compute_subnetwork"
	not r.body.private_ip_google_access
	msg := sprintf(
		"%s: google_compute_subnetwork.%s does not enable private_ip_google_access.",
		[r.path, r.name],
	)
}

# The silent downgrade. A perimeter with no restricted services is a resource
# that exists, applies to the project, appears in the console, and protects
# nothing at all.
deny contains msg if {
	some r in gcp_resources
	r.type == "google_access_context_manager_service_perimeter"
	not r.body.status
	not r.body.spec
	msg := sprintf(
		"%s: google_access_context_manager_service_perimeter.%s has neither a status nor a spec. It restricts nothing.",
		[r.path, r.name],
	)
}

# accesscontextmanager is the API that removes a perimeter. Restricting it means
# a bad perimeter can block the call that would undo it.
deny contains msg if {
	some r in gcp_resources
	r.type == "google_access_context_manager_service_perimeter"
	some block in gcp_blocks_of(r.body.status)
	some svc in block.restricted_services
	svc == "accesscontextmanager.googleapis.com"
	msg := sprintf(
		"%s: perimeter %s restricts accesscontextmanager.googleapis.com. That is the API that removes the perimeter.",
		[r.path, r.name],
	)
}

# An access level with no conditions is satisfied by everything, which is worse
# than no access level, because IAM conditions referencing it look like controls.
#
# object.get for the same reason as the oslogin rule above. `basic.conditions`
# on a `basic {}` block with nothing in it is undefined, and
# `count(gcp_blocks_of(undefined))` is undefined rather than 0, so an access
# level with no conditions block at all slipped past the rule whose entire
# purpose is to catch an access level with no conditions.
deny contains msg if {
	some r in gcp_resources
	r.type == "google_access_context_manager_access_level"
	some basic in gcp_blocks_of(r.body.basic)
	count(gcp_blocks_of(object.get(basic, "conditions", []))) == 0
	msg := sprintf(
		"%s: google_access_context_manager_access_level.%s has no conditions. Everything satisfies it.",
		[r.path, r.name],
	)
}

# Basic roles carry enough permission to edit the perimeter and the access
# levels that constrain them, which collapses the whole model.
basic_roles := {"roles/owner", "roles/editor"}

deny contains msg if {
	some r in gcp_resources
	r.type in {"google_project_iam_member", "google_project_iam_binding"}
	r.body.role in basic_roles
	msg := sprintf(
		"%s: %s.%s grants %s. Basic roles are not granted anywhere in this repo.",
		[r.path, r.type, r.name, r.body.role],
	)
}

# A service account key is a credential that authenticates forever, from
# anywhere, and survives the machine it was made on. The demo impersonates
# instead, and this gate exists so that stays true.
deny contains msg if {
	some r in gcp_resources
	r.type == "google_service_account_key"
	msg := sprintf(
		"%s: google_service_account_key.%s creates a long-lived JSON key. Impersonate instead.",
		[r.path, r.name],
	)
}

# allUsers on a Cloud Run service routes around IAP entirely: the container is
# then reachable without the proxy ever being consulted.
deny contains msg if {
	some r in gcp_resources
	r.type in {"google_cloud_run_v2_service_iam_member", "google_cloud_run_service_iam_member"}
	r.body.member in {"allUsers", "allAuthenticatedUsers"}
	msg := sprintf(
		"%s: %s.%s grants %s, which makes the service reachable without IAP.",
		[r.path, r.type, r.name, r.body.member],
	)
}

# Firewall rules open to the internet. The IAP forwarding range is the one
# source this repo admits, and it is not 0.0.0.0/0.
deny contains msg if {
	some r in gcp_resources
	r.type == "google_compute_firewall"
	r.body.allow
	some src in r.body.source_ranges
	src == "0.0.0.0/0"
	msg := sprintf(
		"%s: google_compute_firewall.%s allows traffic from 0.0.0.0/0. Ingress should come from 35.235.240.0/20 only.",
		[r.path, r.name],
	)
}

# Not a failure, a note. An access level resting on an IP range alone is a weak
# proxy for a trusted device, and it is worth being reminded of that rather than
# letting it read as a finished control.
warn contains msg if {
	some r in gcp_resources
	r.type == "google_access_context_manager_access_level"
	some basic in gcp_blocks_of(r.body.basic)
	not basic.device_policy
	msg := sprintf(
		"%s: access level %s has no device_policy. Network position is standing in for device trust.",
		[r.path, r.name],
	)
}
