#!/usr/bin/env bash
# Deploys the CAR, APIs and API products to one environment. On any failure,
# everything already changed is rolled back.
#
# Required: TARGET_ENV APIM_URL APIM_USER APIM_PASS MI_MGMT_URL MI_USER MI_PASS MI_URL GATEWAY_URL
# Optional: STATE_DIR, ENV_WAIT_SECONDS (default 1200)
. "$(dirname "$0")/common.sh"
require_vars TARGET_ENV APIM_URL APIM_USER APIM_PASS MI_MGMT_URL MI_USER MI_PASS MI_URL GATEWAY_URL

STATE_DIR=${STATE_DIR:-${JENKINS_HOME:-$REPO_ROOT/.ci-state}/jamii-state}
LAST_GOOD_DIR="$STATE_DIR/$TARGET_ENV/last-good"
LAST_GOOD=$(ls "$LAST_GOOD_DIR"/*.car 2>/dev/null | head -1 || true)
WORK="$DIST_DIR/deploy-$TARGET_ENV"
BACKUP="$WORK/backup"
mapfile -t APIS < <(api_names)
mapfile -t PRODUCTS < <(product_names)

IMPORTED=()
NEW_APIS=()
IMPORTED_PRODUCTS=()
NEW_PRODUCTS=()
MI_TOUCHED=false

is_in() { [[ " ${*:2} " == *" $1 "* ]]; }

rollback() {
  set +e
  local problems=0
  log "ROLLING BACK $TARGET_ENV"
  # subscriptions from the smoke test app block deleting APIs
  apictl delete app -n default-apictl-app -e "$TARGET_ENV" -k >/dev/null 2>&1
  # new products first, otherwise they block deleting their APIs
  local prod
  for prod in "${IMPORTED_PRODUCTS[@]}"; do
    is_in "$prod" "${NEW_PRODUCTS[@]}" || continue
    if apictl delete api-product -n "$prod" -v 1.0.0 -r admin -e "$TARGET_ENV" -k >/dev/null 2>&1; then
      ok "APIM: removed new API product $prod"
    else fail "APIM: could not remove API product $prod"; problems=$((problems + 1)); fi
  done
  for ((i = ${#IMPORTED[@]} - 1; i >= 0; i--)); do
    local api=${IMPORTED[$i]}
    if [[ " ${NEW_APIS[*]} " == *" $api "* ]]; then
      if apictl delete api -n "$api" -v 1.0.0 -r admin -e "$TARGET_ENV" -k >/dev/null 2>&1 || ! apim_api_exists "$api"; then
        ok "APIM: removed new API $api"
      else fail "APIM: could not remove $api"; problems=$((problems + 1)); fi
    else
      # --params redeploys to the gateway (the export doesn't include it)
      if apictl import api -f "$BACKUP/$api.zip" -e "$TARGET_ENV" --params "$DIST_DIR/apis/$api.params.yaml" \
           --update --rotate-revision -k >/dev/null 2>&1; then
        ok "APIM: restored previous $api"
      else fail "APIM: could not restore $api"; problems=$((problems + 1)); fi
    fi
  done
  for prod in "${IMPORTED_PRODUCTS[@]}"; do
    is_in "$prod" "${NEW_PRODUCTS[@]}" && continue
    if apictl import api-product -f "$BACKUP/products/$prod" -e "$TARGET_ENV" \
         --update-api-product --rotate-revision -k >/dev/null 2>&1; then
      ok "APIM: restored previous API product $prod"
    else fail "APIM: could not restore API product $prod"; problems=$((problems + 1)); fi
  done
  if $MI_TOUCHED; then
    if [ -n "$LAST_GOOD" ]; then
      if mi_deploy_car "$LAST_GOOD"; then ok "MI: restored last good CAR"
      else fail "MI: could not restore last good CAR"; problems=$((problems + 1)); fi
    else
      local base; base=$(basename "$CAR" .car)
      if mi_undeploy_capp "${base%_*}" "$base"; then warn "MI: no previous CAR known - removed the new CApp"
      else fail "MI: could not remove the new CApp"; problems=$((problems + 1)); fi
    fi
  fi
  if [ "$problems" -gt 0 ]; then
    echo "!!! ROLLBACK INCOMPLETE ($problems problem(s)) - $TARGET_ENV needs manual attention !!!" >&2
  else
    echo "Rollback complete - $TARGET_ENV is back to its previous state."
  fi
}

on_error() {
  local code=$? line=$1
  [ "$BASH_SUBSHELL" -gt 0 ] && exit "$code"
  trap - ERR
  echo >&2; echo "Deployment to $TARGET_ENV FAILED (line $line, exit $code)." >&2
  rollback
  exit 1
}

log "Pre-flight checks for $TARGET_ENV"
CARS=("$MI_PROJECT"/target/*.car)
[ "${#CARS[@]}" -eq 1 ] && [ -f "${CARS[0]}" ] || { echo "Expected exactly one .car in $MI_PROJECT/target" >&2; exit 1; }
CAR=${CARS[0]}; ok "CAR: $(basename "$CAR")"
for api in "${APIS[@]}"; do
  [ -f "$DIST_DIR/apis/${api}_1.0.0.zip" ] || { echo "Missing package for $api - run package-apis.sh" >&2; exit 1; }
done
ok "API packages: ${APIS[*]}"
for prod in "${PRODUCTS[@]}"; do
  [ -f "$DIST_DIR/api-products/${prod}_1.0.0.zip" ] || { echo "Missing package for API product $prod - run package-apis.sh" >&2; exit 1; }
done
[ "${#PRODUCTS[@]}" -eq 0 ] || ok "API product packages: ${PRODUCTS[*]}"
# wait in case the platform is still starting
ENV_WAIT_SECONDS=${ENV_WAIT_SECONDS:-1200}
wait_until "MI management API at $MI_MGMT_URL" "$ENV_WAIT_SECONDS" mi_login || exit 1
ok "MI management API: $MI_MGMT_URL"
wait_until "API Manager at $APIM_URL" "$ENV_WAIT_SECONDS" apim_ready || exit 1
ok "API Manager: $APIM_URL"
rm -rf "${WORK:?}"; mkdir -p "$BACKUP" "$LAST_GOOD_DIR"

set -E
trap 'on_error $LINENO' ERR

# tiers must exist before the APIs that use them; not rolled back
log "Custom rate-limiting tiers"
for f in "$DIST_DIR"/rate-limiting-policies/*.yaml; do
  [ -e "$f" ] || continue
  apictl import policy rate-limiting -f "$f" -e "$TARGET_ENV" --update -k >/dev/null
  ok "$(basename "$f" .yaml) created/updated"
done

log "Backing up current APIs from APIM"
for api in "${APIS[@]}"; do
  exported="$HOME/.wso2apictl/exported/apis/$TARGET_ENV/${api}_1.0.0.zip"
  rm -f "$exported"
  if apictl export api -n "$api" -v 1.0.0 -e "$TARGET_ENV" -k >/dev/null 2>&1 && [ -f "$exported" ]; then
    mv "$exported" "$BACKUP/$api.zip"
    ok "$api (backed up)"
  else
    NEW_APIS+=("$api"); ok "$api (new - will be created)"
  fi
done
for prod in "${PRODUCTS[@]}"; do
  if apim_export_product "$prod" "$WORK/$prod-export.zip"; then
    # keep a cleaned copy (no bundled APIs, no instance IDs)
    d="$BACKUP/products/$prod"; mkdir -p "$d"
    unzip -q "$WORK/$prod-export.zip" -d "$WORK/$prod-export"
    src=$(find "$WORK/$prod-export" -mindepth 1 -maxdepth 1 -type d | head -1)
    sed -e '/^  id: /d' -e '/^    apiId: /d' -e '/policyType:/d' -e '/policyId:/d' "$src/api_product.yaml" > "$d/api_product.yaml"
    sed 's/importApis: true/importApis: false/' "$src/api_product_meta.yaml" > "$d/api_product_meta.yaml"
    mkdir -p "$d/Definitions"; cp "$src/Definitions/swagger.yaml" "$d/Definitions/"
    cp "$APIM_PRODUCTS_DIR/$prod/deployment_environments.yaml" "$d/"
    ok "API product $prod (backed up)"
  else
    NEW_PRODUCTS+=("$prod"); ok "API product $prod (new - will be created)"
  fi
done
if [ -n "$LAST_GOOD" ]; then ok "MI rollback copy: $LAST_GOOD"
else warn "no previous CAR recorded for $TARGET_ENV - a rollback would remove the CApp"; fi

log "Deploying $(basename "$CAR") to MI"
MI_TOUCHED=true
mi_deploy_car "$CAR"
apis_on_mi=$(mi_api GET /apis | jq -r '.list[].name')
for api in "${APIS[@]}"; do
  grep -qx "$api" <<<"$apis_on_mi" || fail "MI did not deploy API $api"
done
ok "MI: CApp active, APIs live: $(tr '\n' ' ' <<<"$apis_on_mi")"

log "Importing APIs into API Manager"
for api in "${APIS[@]}"; do
  IMPORTED+=("$api")
  apictl import api -f "$DIST_DIR/apis/${api}_1.0.0.zip" -e "$TARGET_ENV" \
    --params "$DIST_DIR/apis/$api.params.yaml" --update --rotate-revision -k >/dev/null
  ok "$api imported, published and deployed to gateway"
done

if [ "${#PRODUCTS[@]}" -gt 0 ]; then
  log "Importing API Products"
  for prod in "${PRODUCTS[@]}"; do
    IMPORTED_PRODUCTS+=("$prod")
    apictl import api-product -f "$DIST_DIR/api-products/${prod}_1.0.0.zip" -e "$TARGET_ENV" \
      --update-api-product --rotate-revision -k >/dev/null
    ok "$prod imported, published and deployed to gateway"
  done
fi

log "Smoke testing"
bash "$REPO_ROOT/ci/scripts/smoke-test.sh"

trap - ERR
rm -f "${LAST_GOOD_DIR:?}"/*.car
cp "$CAR" "$LAST_GOOD_DIR/"
log "Deployment to $TARGET_ENV succeeded: MI CApp + ${#APIS[@]} APIs + ${#PRODUCTS[@]} API product(s)"
