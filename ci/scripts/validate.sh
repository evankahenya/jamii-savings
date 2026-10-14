#!/usr/bin/env bash
# Static checks - fast, need no servers. Fails if anything is inconsistent, so we
# never start a deployment with a half-defined API.
. "$(dirname "$0")/common.sh"

errors=0
problem() { fail "$*" || true; errors=$((errors + 1)); }

log "Synapse/data-service XML is well-formed"
while IFS= read -r f; do
  if err=$(xmllint --noout "$f" 2>&1); then ok "${f#"$REPO_ROOT"/}"
  else problem "${f#"$REPO_ROOT"/}: $err"; fi
done < <(find "$MI_PROJECT/src/main/wso2mi" \( -name '*.xml' -o -name '*.dbs' -o -name '*.xsd' \) | sort)

log "Every APIM API has an MI API, an OpenAPI definition and per-env params"
for api in $(api_names); do
  dir="$APIM_APIS_DIR/$api"
  [ -f "$MI_APIS_DIR/$api.xml" ] || { problem "$api: no MI artifact $MI_APIS_DIR/$api.xml"; continue; }
  [ -f "$OAS_DIR/$api.yaml" ]    || problem "$api: no OpenAPI file $OAS_DIR/$api.yaml"
  for f in api.yaml api_meta.yaml deployment_environments.yaml params.yaml; do
    [ -f "$dir/$f" ] || problem "$api: missing $f"
  done
  for env in dev uat prod; do
    grep -q "name: $env.\{0,1\}\$" "$dir/params.yaml" 2>/dev/null || problem "$api: params.yaml has no '$env' environment"
  done
  # the APIM context must match the MI API context, otherwise the gateway calls the wrong backend
  mi_ctx=$(xmllint --xpath 'string(//*[local-name()="api"]/@context)' "$MI_APIS_DIR/$api.xml" 2>/dev/null || true)
  apim_ctx=$(yaml_value "$dir/api.yaml" context)
  if [ "$mi_ctx" = "$apim_ctx" ]; then ok "$api (context $apim_ctx)"
  else problem "$api: APIM context '$apim_ctx' != MI context '$mi_ctx'"; fi
done

log "APIM policies referenced by the APIs exist"
for p in $(grep -h 'policyName:' "$APIM_APIS_DIR"/*/api.yaml | awk '{print $NF}' | tr -d '\r' | sort -u); do
  if ls "$APIM_POLICIES_DIR"/*/"$p.yaml" "$APIM_POLICIES_DIR"/*/"$p.j2" >/dev/null 2>&1; then ok "$p"
  else problem "policy $p not found under apim-policies/"; fi
done

log "API-level rate-limiting tiers used by the APIs exist"
for f in "$RATE_LIMIT_DIR"/*.yaml; do
  [ -e "$f" ] || continue
  name=$(yaml_value "$f" policyName)
  [ "$name" = "$(basename "$f" .yaml)" ] || problem "${f#"$REPO_ROOT"/}: policyName '$name' must match the file name"
done
for api in $(api_names); do
  tier=$(yaml_value "$APIM_APIS_DIR/$api/api.yaml" apiThrottlingPolicy)
  [ -n "$tier" ] || continue
  if [[ " $BUILTIN_API_TIERS " == *" $tier "* ]]; then ok "$api uses built-in tier $tier"
  elif [ -f "$RATE_LIMIT_DIR/$tier.yaml" ]; then ok "$api uses custom tier $tier (${RATE_LIMIT_DIR#"$REPO_ROOT"/}/$tier.yaml)"
  else problem "$api uses tier '$tier', which is not built in and has no file in ${RATE_LIMIT_DIR#"$REPO_ROOT"/}/"; fi
done

if [ "$errors" -gt 0 ]; then
  echo; echo "Validation failed with $errors error(s)." >&2; exit 1
fi
echo; echo "Validation passed for: $(api_names | tr '\n' ' ')"
