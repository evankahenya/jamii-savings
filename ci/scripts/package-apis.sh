#!/usr/bin/env bash
# Builds the apictl bundles for the APIs, products and rate-limit tiers into dist/
. "$(dirname "$0")/common.sh"

STAGE="$DIST_DIR/stage"
OUT="$DIST_DIR/apis"
rm -rf "$STAGE" "$OUT"
mkdir -p "$STAGE" "$OUT"

for api in $(api_names); do
  log "Packaging $api"
  src="$APIM_APIS_DIR/$api"
  dst="$STAGE/$api"
  mkdir -p "$dst/Definitions" "$dst/Policies"

  for f in api.yaml api_meta.yaml deployment_environments.yaml; do
    sed 's/\r$//' "$src/$f" > "$dst/$f"
  done
  sed 's/\r$//' "$OAS_DIR/$api.yaml" > "$dst/Definitions/swagger.yaml"

  # APIM expects Policies/<name>_<version>.yaml wrapped as an operation_policy_specification
  for p in $(grep 'policyName:' "$src/api.yaml" | awk '{print $NF}' | tr -d '\r' | sort -u); do
    spec=$(ls "$APIM_POLICIES_DIR"/*/"$p.yaml")
    ver=$(sed -n 's/^version: *//p' "$spec" | tr -d '\r')
    {
      echo "type: operation_policy_specification"
      echo "version: v4.7.0"
      echo "data:"
      sed 's/\r$//; s/^/  /' "$spec"
    } > "$dst/Policies/${p}_${ver}.yaml"
    sed 's/\r$//' "$(dirname "$spec")/$p.j2" > "$dst/Policies/${p}_${ver}.j2"
    ok "policy $p $ver"
  done

  apictl bundle -s "$dst" -d "$OUT" >/dev/null
  sed 's/\r$//' "$src/params.yaml" > "$OUT/$api.params.yaml"
  ok "$(ls "$OUT"/"$api"_*.zip | xargs -n1 basename)"
done

rm -rf "$STAGE"
log "Packaged $(ls "$OUT"/*.zip | wc -l) API archive(s) into ${OUT#"$REPO_ROOT"/}"

TIERS_OUT="$DIST_DIR/rate-limiting-policies"
rm -rf "${TIERS_OUT:?}"; mkdir -p "$TIERS_OUT"
for f in "$RATE_LIMIT_DIR"/*.yaml; do
  [ -e "$f" ] || continue
  sed 's/\r$//' "$f" > "$TIERS_OUT/$(basename "$f")"
  ok "rate-limiting tier $(basename "$f" .yaml)"
done

PRODUCTS_OUT="$DIST_DIR/api-products"
rm -rf "${PRODUCTS_OUT:?}"; mkdir -p "$PRODUCTS_OUT"
for prod in $(product_names); do
  dst="$STAGE/$prod"
  mkdir -p "$dst/Definitions"
  for f in api_product.yaml api_product_meta.yaml deployment_environments.yaml Definitions/swagger.yaml; do
    sed 's/\r$//' "$APIM_PRODUCTS_DIR/$prod/$f" > "$dst/$f"
  done
  apictl bundle -s "$dst" -d "$PRODUCTS_OUT" >/dev/null
  ok "API product $(ls "$PRODUCTS_OUT"/"$prod"_*.zip | xargs -n1 basename)"
done
rm -rf "${STAGE:?}"
