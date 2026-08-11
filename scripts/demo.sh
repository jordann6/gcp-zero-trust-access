#!/usr/bin/env bash
#
# The demonstration, in six acts.
#
# The argument being made is that a valid credential is not access. Acts 4 and 5
# are the ones that carry it: the same service account, holding the same
# deliberately granted roles/storage.objectViewer, reads the same object and is
# refused from outside the perimeter while succeeding from inside it. Nothing is
# misconfigured in the refusal, which is what makes it worth showing.
#
#   ./scripts/demo.sh env      render .demo.env from terraform output
#   ./scripts/demo.sh act1     anonymous request never reaches the application
#   ./scripts/demo.sh act2     authenticated, wrong context, refused
#   ./scripts/demo.sh act3     authenticated, right context, admitted
#   ./scripts/demo.sh act4     entitled identity refused from outside the perimeter
#   ./scripts/demo.sh act5     same identity, same object, admitted from inside
#   ./scripts/demo.sh act6     the dry run that predicted act 4
#   ./scripts/demo.sh all      every act in order

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="${REPO_ROOT}/terraform"
ENV_FILE="${REPO_ROOT}/.demo.env"

rule() { printf '\n\033[1m%s\033[0m\n%s\n' "$1" "$(printf '=%.0s' {1..72})"; }
note() { printf '  %s\n' "$1"; }
pass() { printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; }

load_env() {
  if [ ! -f "${ENV_FILE}" ]; then
    echo "No ${ENV_FILE}. Run: ./scripts/demo.sh env" >&2
    exit 1
  fi
  # shellcheck source=/dev/null
  source "${ENV_FILE}"
}

cmd_env() {
  rule "Rendering ${ENV_FILE}"
  terraform -chdir="${TF_DIR}" output -raw demo_env >"${ENV_FILE}"
  note "wrote $(wc -l <"${ENV_FILE}" | tr -d ' ') variables"
  note "source ${ENV_FILE}"
}

# Act 1. No credential at all.
#
# IAP terminates the request before the container is reached. The response is a
# redirect to Google sign-in rather than anything the application produced,
# which is the distinction: this is not a 401 from an app, it is the app never
# having been consulted.
cmd_act1() {
  load_env
  rule "Act 1. Anonymous request to ${APP_URL}"

  local code body
  body="$(curl -s -o /dev/null -w '%{http_code} %{redirect_url}' "${APP_URL}" || true)"
  code="${body%% *}"
  note "HTTP ${body}"

  if [ "${code}" = "302" ] || [ "${code}" = "401" ] || [ "${code}" = "403" ]; then
    pass "request refused at the proxy, application never invoked"
  else
    fail "expected 302, 401, or 403, got ${code}. Is iap_enabled actually on?"
    return 1
  fi
}

# Act 2. The right person, from the wrong place.
#
# trusted_ip_ranges is pointed at TEST-NET-1, which no real request can come
# from, so the trusted access level becomes unsatisfiable. The IAM binding is
# untouched: the role is still held, the condition on it simply stops being met.
#
# This act deliberately does not disturb the perimeter. Perimeter ingress hangs
# off the management access level, which has no network condition, so Terraform
# keeps its access to the restricted services while the application-facing level
# is broken on purpose. That separation is in access_levels.tf and it exists for
# exactly this five minutes.
cmd_act2() {
  load_env
  rule "Act 2. Authenticated identity, revoked context"

  note "narrowing the trusted access level to TEST-NET-1 (192.0.2.0/24)"
  terraform -chdir="${TF_DIR}" apply -auto-approve -no-color \
    -var 'trusted_ip_ranges=["192.0.2.0/24"]' \
    -target=google_access_context_manager_access_level.trusted >/dev/null

  note "access levels take up to a minute or two to propagate"
  sleep 90

  note "open ${APP_URL} in a browser signed in as the admin principal"
  note "expected: an IAP page saying you do not have access, not a Google sign-in prompt"
  note "the role is unchanged. Check it:"
  note "  gcloud iap web get-iam-policy --resource-type=cloud-run --service=${APP_SERVICE} --region=${REGION} --project=${WORKLOAD_PROJECT}"
  read -r -p "  Press enter once you have seen the refusal, to restore the trusted range. " _

  note "restoring the real trusted range"
  terraform -chdir="${TF_DIR}" apply -auto-approve -no-color \
    -target=google_access_context_manager_access_level.trusted >/dev/null
  pass "context restored"
}

# Act 3. The right person from the right place.
cmd_act3() {
  load_env
  rule "Act 3. Authenticated identity, trusted context"

  note "current public IP: $(curl -s https://api.ipify.org || echo unknown)"
  note "trusted level: ${TRUSTED_LEVEL}"
  note "open ${APP_URL} in a browser signed in as the admin principal"
  note "expected: the Cloud Run hello page, served through IAP"
  note ""
  note "scripted access to an IAP-protected endpoint needs an OIDC token whose"
  note "audience is the IAP client, which is why this act is browser-verified"
  note "rather than curled. The machine-checkable half of the argument is acts"
  note "4 and 5, which need no browser at all."
}

# Act 4. The heart of it.
#
# The analyst service account holds roles/storage.objectViewer on this bucket
# and roles/bigquery.dataViewer on this dataset. Both were granted on purpose in
# data.tf. IAM permits this read. The perimeter denies it anyway, because the
# request originates outside the boundary.
#
# Impersonation, not a downloaded key. There is no key to download, which is
# itself part of the argument.
cmd_act4() {
  load_env
  rule "Act 4. Entitled identity, outside the perimeter"

  note "identity: ${ANALYST_SA}"
  note "holds roles/storage.objectViewer on gs://${PROTECTED_BUCKET}"
  note ""

  local out rc=0
  out="$(CLOUDSDK_AUTH_IMPERSONATE_SERVICE_ACCOUNT="${ANALYST_SA}" \
    gcloud storage cat "gs://${PROTECTED_BUCKET}/${PROTECTED_OBJECT}" \
    --project="${WORKLOAD_PROJECT}" 2>&1)" || rc=$?

  if printf '%s' "${out}" | grep -qi "VPC Service Controls\|vpcServiceControlsUniqueIdentifier\|SECURITY_POLICY_VIOLATED"; then
    pass "refused by the perimeter, not by IAM"
    printf '%s\n' "${out}" | sed 's/^/      /' | head -20
    local uid
    uid="$(printf '%s' "${out}" | grep -o 'vpcServiceControlsUniqueIdentifier[": ]*[A-Za-z0-9_-]*' | head -1 || true)"
    [ -n "${uid}" ] && note "correlate this in the audit log: ${uid}"
  elif [ "${rc}" -eq 0 ]; then
    fail "the read SUCCEEDED. The perimeter is not enforcing."
    note "check: terraform -chdir=terraform output perimeter_mode"
    note "if it says DRY_RUN, apply with -var enforce_perimeter=true"
    return 1
  else
    fail "denied, but not by the perimeter. Read the error before claiming the win:"
    printf '%s\n' "${out}" | sed 's/^/      /' | head -20
    return 1
  fi

  note ""
  note "same story on the second restricted service:"
  CLOUDSDK_AUTH_IMPERSONATE_SERVICE_ACCOUNT="${ANALYST_SA}" \
    bq --project_id="${WORKLOAD_PROJECT}" query --use_legacy_sql=false --format=none \
    "SELECT * FROM \`${WORKLOAD_PROJECT}.${PROTECTED_DATASET}.${PROTECTED_TABLE}\`" 2>&1 |
    sed 's/^/      /' | head -10 || true
}

# Act 5. The control variable.
#
# Same service account. Same object. Same permissions. The only thing that
# changed is where the request came from.
cmd_act5() {
  load_env
  rule "Act 5. Same identity, same object, inside the perimeter"

  note "instance ${INSTANCE} has no external IP and no NAT"
  note "reaching it at all requires roles/iap.tunnelResourceAccessor and the IAP tunnel"
  note ""

  local out rc=0
  out="$(gcloud compute ssh "${INSTANCE}" \
    --zone="${ZONE}" --project="${WORKLOAD_PROJECT}" --tunnel-through-iap \
    --command="read-protected ${PROTECTED_BUCKET} ${PROTECTED_OBJECT}" 2>&1)" || rc=$?

  if printf '%s' "${out}" | grep -q "SYNTHETIC RECORDS"; then
    pass "the object read cleanly from inside"
    printf '%s\n' "${out}" | grep -v "^Warning\|^External IP" | sed 's/^/      /' | head -15
    note ""
    note "IAM was identical in acts 4 and 5. Only the origin differed."
  else
    fail "the in-perimeter read did not return the object"
    printf '%s\n' "${out}" | sed 's/^/      /' | head -25
    note "if this hangs or refuses the login, suspect vpc_accessible_services:"
    note "dropping oslogin.googleapis.com from that list breaks SSH, not storage"
    return 1
  fi
}

# Act 6. The measurement that should precede enforcement.
#
# In dry-run the perimeter writes an audit entry for every request it would have
# denied. Applying enforcement without reading these is how a perimeter takes
# down a service nobody remembered was reaching across the boundary.
cmd_act6() {
  load_env
  rule "Act 6. Dry-run violations"

  local filter='protoPayload.metadata."@type"="type.googleapis.com/google.cloud.audit.VpcServiceControlAuditMetadata"'

  note "violations recorded against the workload project:"
  gcloud logging read "${filter}" \
    --project="${WORKLOAD_PROJECT}" --limit=10 --freshness=2h \
    --format='table(timestamp, protoPayload.metadata.dryRun, protoPayload.authenticationInfo.principalEmail, protoPayload.methodName)' \
    2>/dev/null || note "none in this project, try the organization scope below"

  note ""
  note "VPC Service Controls also logs at the organization level. If the project"
  note "scope is empty, the entries are there:"
  note "  gcloud logging read '${filter}' --organization=\$ORG_ID --limit=10"
  note ""
  note "dryRun=true means the request was allowed and would have been denied."
  note "dryRun absent or false means it was actually denied."
}

cmd_all() {
  cmd_env
  cmd_act1
  cmd_act2
  cmd_act3
  cmd_act4
  cmd_act5
  cmd_act6
  rule "Done"
}

case "${1:-all}" in
env) cmd_env ;;
act1) cmd_act1 ;;
act2) cmd_act2 ;;
act3) cmd_act3 ;;
act4) cmd_act4 ;;
act5) cmd_act5 ;;
act6) cmd_act6 ;;
all) cmd_all ;;
*)
  sed -n '3,20p' "${BASH_SOURCE[0]}"
  exit 1
  ;;
esac
