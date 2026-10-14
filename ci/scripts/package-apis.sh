#!/usr/bin/env bash
# Packages every APIM API into an importable archive:
#   dist/apis/<API>_1.0.0.zip        <- apictl bundle (api.yaml + OpenAPI + policies)
#   dist/apis/<API>.params.yaml      <- per-environment settings used at import time
# The OpenAPI file and policies are copied in from their single source of truth.
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

  # copied with Windows line endings (\r) removed - files edited on Windows may have them
  for f in api.yaml api_meta.yaml deployment_environments.yaml; do
    sed 's/\r$//' "$src/$f" > "$dst/$f"
  done
  sed 's/\r$//' "$OAS_DIR/$api.yaml" > "$dst/Definitions/swagger.yaml"

  # Policies: APIM expects <name>_<version>.yaml (wrapped as an operation_policy_specification) + .j2
  # (sed 's/\r$//' strips Windows line endings - the policy files are edited on Windows)
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

# Custom rate-limiting tiers - imported by deploy.sh before the APIs that use them
TIERS_OUT="$DIST_DIR/rate-limiting-policies"
rm -rf "${TIERS_OUT:?}"; mkdir -p "$TIERS_OUT"
for f in "$RATE_LIMIT_DIR"/*.yaml; do
  [ -e "$f" ] || continue
  sed 's/\r$//' "$f" > "$TIERS_OUT/$(basename "$f")"
  ok "rate-limiting tier $(basename "$f" .yaml)"
done
