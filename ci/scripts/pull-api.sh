#!/usr/bin/env bash
# =====================================================================
# Copies an API's settings FROM API Manager INTO the repo, so changes made in the
# Publisher portal (rate limits, security, CORS, policies attached, business info...)
# can be committed. Without this, the next pipeline run would overwrite them.
#
# Run it from the repo root inside the Jenkins image (it has apictl):
#   docker run --rm -u root --add-host host.docker.internal:host-gateway -v "%cd%:/repo" -w /repo --entrypoint bash jamii-jenkins:2.541.3 ci/scripts/pull-api.sh AccountBalanceAPI
#   (Git Bash / PowerShell: use "$(pwd -W)" / "${PWD}" instead of "%cd%")
#
# It only updates Jamii_WSO2_Project/apim-apis/<API>/api.yaml. NOT pulled (the pipeline
# takes these from their own source files, so edit those instead):
#   - resources / paths / parameters  -> src/main/wso2mi/resources/api-definitions/<API>.yaml
#   - policy code (.j2)               -> apim-policies/
#   - per-environment backend URLs    -> apim-apis/<API>/params.yaml
#
# Optional env: TARGET_ENV (dev), APIM_URL (https://host.docker.internal:9443),
#               APIM_USER / APIM_PASS (admin / admin)
# =====================================================================
. "$(dirname "$0")/common.sh"

API=${1:?usage: pull-api.sh <API name, e.g. AccountBalanceAPI>}
VERSION=${2:-1.0.0}
export TARGET_ENV=${TARGET_ENV:-dev}
export APIM_URL=${APIM_URL:-https://host.docker.internal:9443}
export APIM_USER=${APIM_USER:-admin}
export APIM_PASS=${APIM_PASS:-admin}

DEST="$APIM_APIS_DIR/$API/api.yaml"
[ -d "$APIM_APIS_DIR/$API" ] || { echo "No folder $APIM_APIS_DIR/$API - is the API name right?" >&2; exit 1; }

log "Exporting $API $VERSION from API Manager ($TARGET_ENV)"
apictl_setup
apictl export api -n "$API" -v "$VERSION" -e "$TARGET_ENV" -k >/dev/null
ZIP="$HOME/.wso2apictl/exported/apis/$TARGET_ENV/${API}_${VERSION}.zip"

TMP=$(mktemp -d)
unzip -q "$ZIP" -d "$TMP"
# policyType/policyId are specific to this APIM instance and break importing into a fresh one
{
  echo "# Exported from API Manager ($TARGET_ENV) with ci/scripts/pull-api.sh - see that script for what is/isn't pulled."
  sed '/policyType:/d; /policyId:/d' "$TMP"/*/api.yaml
} > "$DEST"
rm -rf "${TMP:?}"
ok "updated ${DEST#"$REPO_ROOT"/}"

log "Checking the repo is still consistent"
bash "$REPO_ROOT/ci/scripts/validate.sh" | tail -1
echo
echo "Next: review the change with 'git diff', then commit it."
