#!/usr/bin/env bash
# Copies Publisher changes for an API (or --product) back into the repo.
# Paths, policies and backend URLs come from their own files, so edit those directly.
#
# docker run --rm -u root --add-host host.docker.internal:host-gateway -v "%cd%:/repo" -w /repo --entrypoint bash jamii-jenkins:2.541.3 ci/scripts/pull-api.sh AccountBalanceAPI
. "$(dirname "$0")/common.sh"

KIND=api
if [ "${1:-}" = "--product" ]; then KIND=product; shift; fi
NAME=${1:?usage: pull-api.sh [--product] <name, e.g. AccountBalanceAPI or JamiiProducts>}
VERSION=${2:-1.0.0}
export TARGET_ENV=${TARGET_ENV:-dev}
export APIM_URL=${APIM_URL:-https://host.docker.internal:9443}
export APIM_USER=${APIM_USER:-admin}
export APIM_PASS=${APIM_PASS:-admin}
CLEAN=(-e '/^  id: /d' -e '/^    apiId: /d' -e '/policyType:/d' -e '/policyId:/d' -e '/^  createdTime:/d')

TMP=$(mktemp -d)
apictl_setup

if [ "$KIND" = api ]; then
  DEST="$APIM_APIS_DIR/$NAME/api.yaml"
  [ -d "$APIM_APIS_DIR/$NAME" ] || { echo "No folder $APIM_APIS_DIR/$NAME - is the API name right? (for an API Product add --product)" >&2; exit 1; }
  log "Exporting API $NAME $VERSION from API Manager ($TARGET_ENV)"
  apictl export api -n "$NAME" -v "$VERSION" -e "$TARGET_ENV" -k >/dev/null
  unzip -q "$HOME/.wso2apictl/exported/apis/$TARGET_ENV/${NAME}_${VERSION}.zip" -d "$TMP"
  sed "${CLEAN[@]}" "$TMP"/*/api.yaml > "$DEST"
  ok "updated ${DEST#"$REPO_ROOT"/}"
else
  DIR="$APIM_PRODUCTS_DIR/$NAME"
  log "Exporting API product $NAME $VERSION from API Manager ($TARGET_ENV)"
  apictl export api-product -n "$NAME" -v "$VERSION" -e "$TARGET_ENV" -k >/dev/null
  unzip -q "$HOME/.wso2apictl/exported/api-products/$TARGET_ENV/${NAME}_${VERSION}.zip" -d "$TMP"
  SRC=$(find "$TMP" -mindepth 1 -maxdepth 1 -type d | head -1)
  mkdir -p "$DIR/Definitions"
  sed "${CLEAN[@]}" "$SRC/api_product.yaml" > "$DIR/api_product.yaml"
  cp "$SRC/Definitions/swagger.yaml" "$DIR/Definitions/swagger.yaml"
  if [ ! -f "$DIR/api_product_meta.yaml" ]; then
    printf 'name: %s\nversion: %s\ndeploy:\n  import:\n    importApis: false\n    preserveProvider: true\n    updateApiProduct: true\n    rotateRevision: true\n' \
      "$NAME" "$VERSION" > "$DIR/api_product_meta.yaml"
  fi
  if [ ! -f "$DIR/deployment_environments.yaml" ]; then
    printf 'type: deployment_environments\nversion: v4.7.0\ndata:\n -\n   displayOnDevportal: true\n   deploymentEnvironment: Default\n' \
      > "$DIR/deployment_environments.yaml"
  fi
  ok "updated ${DIR#"$REPO_ROOT"/}/ (api_product.yaml, Definitions/swagger.yaml)"
  echo "    NOTE: CustomersAPI resources in the product must keep throttlingPolicy: ReqRes"
fi
rm -rf "${TMP:?}"

log "Checking the repo is still consistent"
bash "$REPO_ROOT/ci/scripts/validate.sh" | tail -1
echo
echo "Next: review the change with 'git diff', then commit it."
