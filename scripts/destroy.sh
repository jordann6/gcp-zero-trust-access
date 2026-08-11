#!/usr/bin/env bash
#
# Teardown, in the order that actually works.
#
# The thing that makes this build different from the others in the portfolio is
# that most of its state is not in the project. Access policies, access levels,
# and service perimeters are organization-scoped objects. Deleting the workload
# project does not remove any of them:
#
#   1. A perimeter survives the deletion of every project inside it, and is left
#      pointing at a project number that no longer resolves. It still counts
#      against the organization's perimeter quota and it still has to be deleted
#      by hand later, at which point nobody remembers what it was for.
#   2. Access levels survive the perimeter, and an org-scoped access policy
#      cannot be deleted while it still holds any of them.
#   3. The access policy itself is a singleton per organization. Leaving a dead
#      one behind means the next build has to detect and adopt it instead of
#      creating one, which is why access_policy_name exists as a variable.
#
# So the perimeter comes down first, then the levels, then the project, then the
# policy. Reversing any two of those produces a delete that fails on a
# dependency and leaves the org half torn down.
#
# One more ordering constraint that is easy to get wrong: enforcement is dropped
# before anything else. Terraform reaches the restricted services through the
# perimeter's ingress rule, and if that rule or its access level is removed
# first, the destroy of the bucket and dataset fails with a policy violation and
# the state is left describing resources it can no longer see.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="${REPO_ROOT}/terraform"
ENV_FILE="${REPO_ROOT}/.demo.env"

rule() { printf '\n\033[1m%s\033[0m\n%s\n' "$1" "$(printf '=%.0s' {1..72})"; }
note() { printf '  %s\n' "$1"; }

if [ ! -f "${ENV_FILE}" ]; then
  echo "No ${ENV_FILE}. Run ./scripts/demo.sh env while the stack is still up." >&2
  exit 1
fi
# shellcheck source=/dev/null
source "${ENV_FILE}"

read -r -p "Destroy ${WORKLOAD_PROJECT} and the org-level perimeter? [yes/NO] " confirm
[ "${confirm}" = "yes" ] || { echo "Aborted."; exit 1; }

rule "1. Drop enforcement while Terraform still has a way in"
note "the perimeter goes to dry run, so the destroy of the restricted resources"
note "is not evaluated against a policy that is about to be deleted anyway"
terraform -chdir="${TF_DIR}" apply -auto-approve -no-color \
  -var 'enforce_perimeter=false' >/dev/null
note "perimeter now in dry run"

rule "2. Destroy the root module"
note "this removes the workload project, the perimeter, and both access levels"
terraform -chdir="${TF_DIR}" destroy -auto-approve -no-color \
  -var 'enforce_perimeter=false'

rule "3. Verify the organization-scoped objects are gone"
if [ -n "${ACCESS_POLICY_ID:-}" ]; then
  note "perimeters remaining under accessPolicies/${ACCESS_POLICY_ID}:"
  gcloud access-context-manager perimeters list \
    --policy="${ACCESS_POLICY_ID}" --format='value(name)' 2>/dev/null |
    sed 's/^/      /' || note "      none (or policy already deleted)"

  note "access levels remaining:"
  gcloud access-context-manager levels list \
    --policy="${ACCESS_POLICY_ID}" --format='value(name)' 2>/dev/null |
    sed 's/^/      /' || note "      none (or policy already deleted)"
fi

rule "4. The access policy"
note "Terraform deletes the policy only if it created it. If access_policy_name"
note "was set, the policy predates this build and is deliberately left alone."
note ""
note "To remove it by hand once it holds nothing:"
note "  gcloud access-context-manager policies delete ${ACCESS_POLICY_ID:-POLICY_ID}"

rule "5. Confirm the project is going away"
gcloud projects describe "${WORKLOAD_PROJECT}" \
  --format='value(projectId,lifecycleState)' 2>/dev/null |
  sed 's/^/      /' || note "      already gone"
note ""
note "DELETE_REQUESTED is the expected state. The project is unbilled from this"
note "point but continues to count against the billing account's linked-project"
note "cap for 30 days, which is worth remembering before starting the next build."

rule "6. Bootstrap layer"
note "the seed project holds the state bucket, so it goes last and only when you"
note "are certain the destroy above completed"
note ""
note "  cd bootstrap"
note "  terraform apply -auto-approve -var force_destroy_state=true"
note "  terraform destroy -auto-approve -var force_destroy_state=true"
note ""
note "force_destroy_state must be applied before the destroy. A versioned bucket"
note "with objects in it refuses to delete, and the flag is only read on apply."

rule "7. Residual billing check"
note "  gcloud compute instances list --project=${WORKLOAD_PROJECT}"
note "  gcloud run services list --project=${WORKLOAD_PROJECT}"
note "  gcloud storage buckets list --project=${WORKLOAD_PROJECT}"
note ""
note "All three should be empty or error with the project not found."

rm -f "${ENV_FILE}"
note ""
note "Removed ${ENV_FILE}."
