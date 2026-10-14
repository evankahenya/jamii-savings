#!/usr/bin/env bash
# Shared helpers for the Jamii CI scripts. Source it:  . "$(dirname "$0")/common.sh"
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MI_PROJECT="$REPO_ROOT/Jamii_WSO2_Project"
APIM_APIS_DIR="$MI_PROJECT/apim-apis"
APIM_PRODUCTS_DIR="$MI_PROJECT/apim-api-products"         # API Products (group APIs; imported after them)
APIM_POLICIES_DIR="$MI_PROJECT/apim-policies"
RATE_LIMIT_DIR="$MI_PROJECT/apim-throttling-policies"   # custom rate-limiting tiers (apictl format)
# API-level ("advanced") tiers every API Manager already has - no file needed for these
BUILTIN_API_TIERS="Unlimited 10KPerMin 20KPerMin 50KPerMin"
OAS_DIR="$MI_PROJECT/src/main/wso2mi/resources/api-definitions"
MI_APIS_DIR="$MI_PROJECT/src/main/wso2mi/artifacts/apis"
DIST_DIR="$REPO_ROOT/dist"

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
ok()   { printf '    \033[32mOK\033[0m  %s\n' "$*"; }
warn() { printf '    \033[33mWARN\033[0m %s\n' "$*"; }
fail() { printf '    \033[31mFAIL\033[0m %s\n' "$*" >&2; return 1; }

# Reads "  <key>: value" from an apictl yaml file. Strips Windows line endings (\r):
# files edited/checked out on Windows have them, and they'd end up inside the value.
yaml_value() { sed -n "s/^  $2: *//p" "$1" | tr -d '\r' | head -1; }

# The APIs this pipeline manages = one folder per API under apim-apis/
api_names() { find "$APIM_APIS_DIR" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort; }
# ...and one folder per API Product under apim-api-products/ (may not exist)
product_names() { [ -d "$APIM_PRODUCTS_DIR" ] && find "$APIM_PRODUCTS_DIR" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort || true; }
# the apictl yaml of an API or API Product (smoke tests address both by name)
apim_yaml() { if [ -f "$APIM_APIS_DIR/$1/api.yaml" ]; then echo "$APIM_APIS_DIR/$1/api.yaml"; else echo "$APIM_PRODUCTS_DIR/$1/api_product.yaml"; fi; }
# APIs used by a product = the "    name:" entries under its apis: list
product_apis() { sed -n 's/^    name: *//p' "$APIM_PRODUCTS_DIR/$1/api_product.yaml" | tr -d '\r'; }

wait_until() {  # wait_until <what> <timeout seconds> <command...>  - retries every 10s until the command succeeds
  local what=$1 timeout=$2 waited=0; shift 2
  until "$@" >/dev/null 2>&1; do
    if [ "$waited" -ge "$timeout" ]; then fail "$what still not ready after ${timeout}s"; return 1; fi
    [ $((waited % 60)) -eq 0 ] && echo "    ... waiting for $what (${waited}s so far)"
    sleep 10; waited=$((waited + 10))
  done
}

require_vars() {
  local v
  for v in "$@"; do
    [ -n "${!v:-}" ] || { echo "Missing required variable: $v" >&2; exit 2; }
  done
}

# ---------------------------------------------------------------------------
# MI Management API  (https://<mi>:9164/management)
# ---------------------------------------------------------------------------
# NOTE: every helper returns 1 explicitly on failure, so it behaves the same with
# `set -e` (normal run) and without it (rollback runs with `set +e`).

mi_login() {
  MI_TOKEN=$(curl -skf -u "$MI_USER:$MI_PASS" "$MI_MGMT_URL/management/login" | jq -r '.AccessToken // empty') \
    || true
  [ -n "${MI_TOKEN:-}" ] || { fail "cannot log in to MI management API at $MI_MGMT_URL"; return 1; }
}

mi_api() {  # mi_api <METHOD> <path> [extra curl args...]  -> prints body, fails on HTTP >= 400
  local method=$1 path=$2; shift 2
  local out code
  out=$(mktemp)
  code=$(curl -sk -o "$out" -w '%{http_code}' -X "$method" -H "Authorization: Bearer $MI_TOKEN" "$@" \
         "$MI_MGMT_URL/management$path") || code=000
  cat "$out"; rm -f "$out"
  [ "$code" -ge 200 ] && [ "$code" -lt 400 ]
}

mi_capp_state() {  # prints: active | faulty | absent
  local name=$1 apps
  apps=$(mi_api GET /applications) || { fail "cannot list CApps on MI"; return 1; }
  if jq -e --arg n "$name" '.activeList[]? | select(.name == $n)' <<<"$apps" >/dev/null; then
    echo active
  elif jq -e --arg n "$name" \
       '.faultyList[]? | (if type == "object" then .name else . end) | select(startswith($n))' <<<"$apps" >/dev/null; then
    echo faulty
  else
    echo absent
  fi
}

mi_wait_capp() {  # mi_wait_capp <capp name> <wanted state> [timeout seconds]
  local name=$1 want=$2 timeout=${3:-120} waited=0 state
  while :; do
    state=$(mi_capp_state "$name") || return 1
    [ "$state" = "$want" ] && return 0
    if [ "$state" = faulty ] && [ "$want" = active ]; then
      fail "CApp $name was deployed as FAULTY on MI"; return 1
    fi
    if [ "$waited" -ge "$timeout" ]; then
      fail "timed out after ${timeout}s waiting for CApp $name to be $want (now: $state)"; return 1
    fi
    sleep 3; waited=$((waited + 3))
  done
}

mi_undeploy_capp() {  # removes <name>_<version> if present and waits until MI has dropped it
  local name=$1 file_base=$2 state
  state=$(mi_capp_state "$name") || return 1
  [ "$state" = absent ] && return 0
  mi_api DELETE "/applications/$file_base" >/dev/null || { fail "MI refused to remove $file_base"; return 1; }
  mi_wait_capp "$name" absent 120
}

mi_deploy_car() {  # mi_deploy_car <path to .car>  - the FILE NAME must be <name>_<version>.car
  local car=$1 file_base name resp
  file_base=$(basename "$car" .car)          # Jamii_WSO2_Project_1.0.0  (MI identifies the CApp by this)
  name=${file_base%_*}                       # Jamii_WSO2_Project
  # Remove the old version first, then upload: this way we can SEE the new one come up
  # (an in-place overwrite gives no reliable signal that the new file was picked up).
  mi_undeploy_capp "$name" "$file_base" || return 1
  resp=$(mi_api POST /applications -F "file=@$car") || { fail "MI upload failed: $resp"; return 1; }
  # MI answers HTTP 200 even for some failures - check the body too
  if jq -e '.Error' <<<"$resp" >/dev/null 2>&1; then fail "MI upload failed: $resp"; return 1; fi
  mi_wait_capp "$name" active 180
}

# ---------------------------------------------------------------------------
# API Manager via apictl
# ---------------------------------------------------------------------------
apictl_setup() {  # registers + logs in apictl environment "$TARGET_ENV"
  apictl remove env "$TARGET_ENV" >/dev/null 2>&1 || true
  apictl add env "$TARGET_ENV" --apim "$APIM_URL" >/dev/null
  printf '%s' "$APIM_PASS" | apictl login "$TARGET_ENV" -u "$APIM_USER" --password-stdin -k >/dev/null \
    || { fail "cannot log in to API Manager at $APIM_URL"; return 1; }
}

apim_ready() {  # APIM is up (health endpoint) AND accepts an apictl login
  curl -skf --max-time 10 "$APIM_URL/services/Version" >/dev/null && apictl_setup
}

apim_api_exists() {  # apim_api_exists <name>
  # uses export (reads the database) rather than "apictl get apis" (uses the search index,
  # which can lag behind or be empty after the APIM container is recreated)
  local zip="$HOME/.wso2apictl/exported/apis/$TARGET_ENV/${1}_1.0.0.zip"
  rm -f "$zip"
  apictl export api -n "$1" -v 1.0.0 -e "$TARGET_ENV" -k >/dev/null 2>&1 && [ -f "$zip" ]
}

# Security schemes listed under "securityScheme:" in an api.yaml / api_product.yaml
# (e.g. oauth2, api_key, oauth_basic_auth_api_key_mandatory), one per line
security_schemes() {
  awk '/^  securityScheme:/{f=1; next} f && /^ *- /{sub(/^ *- */, ""); print; next} f{exit}' "$1" | tr -d '\r'
}
# true when the API accepts ONLY API keys (API Key security without OAuth2)
uses_api_key_only() {
  local s; s=$(security_schemes "$1")
  grep -qx api_key <<<"$s" && ! grep -qx oauth2 <<<"$s"
}

# Generates an API key for a Developer Portal application (apictl can't do this).
# Uses the Developer Portal REST API: register a client, get a token, find the app, generate.
devportal_api_key() {  # devportal_api_key <application name>  -> prints the key
  local reg cid cs tok app
  reg=$(curl -sk -u "$APIM_USER:$APIM_PASS" -H 'Content-Type: application/json' \
        -d '{"callbackUrl":"https://localhost","clientName":"jamii_ci_smoke","owner":"'"$APIM_USER"'","grantType":"password refresh_token","saasApp":true}' \
        "$APIM_URL/client-registration/v0.17/register") || return 1
  cid=$(jq -r .clientId <<<"$reg"); cs=$(jq -r .clientSecret <<<"$reg")
  tok=$(curl -sk -u "$cid:$cs" --data-urlencode grant_type=password --data-urlencode "username=$APIM_USER" \
        --data-urlencode "password=$APIM_PASS" --data-urlencode 'scope=apim:subscribe apim:api_key apim:app_manage' \
        "$APIM_URL/oauth2/token" | jq -r '.access_token // empty')
  [ -n "$tok" ] || return 1
  app=$(curl -sk -H "Authorization: Bearer $tok" "$APIM_URL/api/am/devportal/v3/applications?query=$1" \
        | jq -r --arg n "$1" '.list[] | select(.name == $n) | .applicationId' | head -1)
  [ -n "$app" ] || return 1
  # APIM 4.7 requires a key name
  curl -sk -H "Authorization: Bearer $tok" -H 'Content-Type: application/json' \
       -d "{\"keyName\":\"jamii-ci-$(date +%s)\",\"validityPeriod\":3600,\"additionalProperties\":{}}" \
       "$APIM_URL/api/am/devportal/v3/applications/$app/api-keys/PRODUCTION/generate" | jq -r '.apikey // empty'
}

# Exports an API Product to <dest zip>; fails if it doesn't exist. (Export is used as the
# existence check because the product LIST is search-indexed and lags a few seconds.)
apim_export_product() {  # apim_export_product <name> <dest zip>
  local zip="$HOME/.wso2apictl/exported/api-products/$TARGET_ENV/${1}_1.0.0.zip"
  rm -f "$zip"
  apictl export api-product -n "$1" -v 1.0.0 -e "$TARGET_ENV" -k >/dev/null 2>&1 && [ -f "$zip" ] && mv "$zip" "$2"
}
