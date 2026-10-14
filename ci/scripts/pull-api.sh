#!/usr/bin/env bash
# =====================================================================
# Copies an API's (or API Product's) settings FROM API Manager INTO the repo, so changes
# made in the Publisher portal (rate limits, security, CORS, policies attached, business
# info, the resources in a product...) can be committed. Without this, the next pipeline
# run would overwrite them.
#
# Run it from the repo root inside the Jenkins image (it has apictl):
#   docker run --rm -u root --add-host host.docker.internal:host-gateway -v "%cd%:/repo" -w /repo --entrypoint bash jamii-jenkins:2.541.3 ci/scripts/pull-api.sh AccountBalanceAPI
#   docker run --rm -u root --add-host host.docker.internal:host-gateway -v "%cd%:/repo" -w /repo --entrypoint bash jamii-jenkins:2.541.3 ci/scripts/pull-api.sh --product JamiiProducts
#   (Git Bash / PowerShell: use "$(pwd -W)" / "${PWD}" instead of "%cd%")
#
# API:     updates only Jamii_WSO2_Project/apim-apis/<API>/api.yaml. NOT pulled (the pipeline
#          takes these from their own source files, so edit those instead):
#            - resources / paths / parameters  -> src/main/wso2mi/resources/api-definitions/<API>.yaml
#            - policy code (.j2)               -> apim-policies/
#            - per-environment backend URLs    -> apim-apis/<API>/params.yaml
# Product: updates apim-api-products/<Product>/api_product.yaml and Definitions/swagger.yaml.
#          A new product gets its folder created. The copies of the APIs inside the export are
#          NOT kept - the APIs have their own folders in apim-apis/.
#
# Instance-specific IDs (apiId, policyId, policyType) are removed: they only exist in THIS
# API Manager and would break importing into a fresh one (e.g. a reviewer's).
#
# Optional env: TARGET_ENV (dev), APIM_URL (https://host.docker.internal:9443),
#               APIM_USER / APIM_PASS (admin / admin)
# =====================================================================
. "$(dirname "$0")/common.sh"

KIND=api
if [ "${1:-}" = "--product" ]; then KIND=product; shift; fi
NAME=${1:?usage: pull-api.sh [--product] <name, e.g. AccountBalanceAPI or JamiiProducts>}
VERSION=${2:-1.0.0}
export TARGET_ENV=${TARGET_ENV:-dev}
export APIM_URL=${APIM_URL:-https://host.docker.internal:9443}
export APIM_USER=${APIM_USER:-admin}
export APIM_PASS=${APIM_PASS:-admin}
HEADER="# Exported from API Manager ($TARGET_ENV) with ci/scripts/pull-api.sh - see that script for what is/isn't pulled."
CLEAN=(-e '/^  id: /d' -e '/^    apiId: /d' -e '/policyType:/d' -e '/policyId:/d' -e '/^  createdTime:/d')

TMP=$(mktemp -d)
apictl_setup

if [ "$KIND" = api ]; then
  DEST="$APIM_APIS_DIR/$NAME/api.yaml"
  [ -d "$APIM_APIS_DIR/$NAME" ] || { echo "No folder $APIM_APIS_DIR/$NAME - is the API name right? (for an API Product add --product)" >&2; exit 1; }
  log "Exporting API $NAME $VERSION from API Manager ($TARGET_ENV)"
  apictl export api -n "$NAME" -v "$VERSION" -e "$TARGET_ENV" -k >/dev/null
  unzip -q "$HOME/.wso2apictl/exported/apis/$TARGET_ENV/${NAME}_${VERSION}.zip" -d "$TMP"
  { echo "$HEADER"; sed "${CLEAN[@]}" "$TMP"/*/api.yaml; } > "$DEST"
  ok "updated ${DEST#"$REPO_ROOT"/}"
else
  DIR="$APIM_PRODUCTS_DIR/$NAME"
  log "Exporting API product $NAME $VERSION from API Manager ($TARGET_ENV)"
  apictl export api-product -n "$NAME" -v "$VERSION" -e "$TARGET_ENV" -k >/dev/null
  unzip -q "$HOME/.wso2apictl/exported/api-products/$TARGET_ENV/${NAME}_${VERSION}.zip" -d "$TMP"
  SRC=$(find "$TMP" -mindepth 1 -maxdepth 1 -type d | head -1)
  mkdir -p "$DIR/Definitions"
  { echo "$HEADER"; sed "${CLEAN[@]}" "$SRC/api_product.yaml"; } > "$DIR/api_product.yaml"
  cp "$SRC/Definitions/swagger.yaml" "$DIR/Definitions/swagger.yaml"
  # first pull of a new product: add the files the pipeline needs (later pulls keep yours)
  if [ ! -f "$DIR/api_product_meta.yaml" ]; then
    printf 'name: %s\nversion: %s\ndeploy:\n  import:\n    importApis: false\n    preserveProvider: true\n    updateApiProduct: true\n    rotateRevision: true\n' \
      "$NAME" "$VERSION" > "$DIR/api_product_meta.yaml"
  fi
  if [ ! -f "$DIR/deployment_environments.yaml" ]; then
    printf 'type: deployment_environments\nversion: v4.7.0\ndata:\n -\n   displayOnDevportal: true\n   deploymentEnvironment: Default\n' \
      > "$DIR/deployment_environments.yaml"
  fi
  ok "updated ${DIR#"$REPO_ROOT"/}/ (api_product.yaml, Definitions/swagger.yaml)"
  echo "    NOTE: a product has its OWN rate limit per resource. Resources from CustomersAPI must"
  echo "          keep 'throttlingPolicy: ReqRes', otherwise the product bypasses the reqres.in limit."
fi
rm -rf "${TMP:?}"

log "Checking the repo is still consistent"
bash "$REPO_ROOT/ci/scripts/validate.sh" | tail -1
echo
echo "Next: review the change with 'git diff', then commit it."
