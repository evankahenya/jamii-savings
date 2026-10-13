#!/usr/bin/env bash
# Shared helpers for the Jamii CI scripts. Source it:  . "$(dirname "$0")/common.sh"
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MI_PROJECT="$REPO_ROOT/Jamii_WSO2_Project"
APIM_APIS_DIR="$MI_PROJECT/apim-apis"
APIM_POLICIES_DIR="$MI_PROJECT/apim-policies"
OAS_DIR="$MI_PROJECT/src/main/wso2mi/resources/api-definitions"
MI_APIS_DIR="$MI_PROJECT/src/main/wso2mi/artifacts/apis"
DIST_DIR="$REPO_ROOT/dist"

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
ok()   { printf '    \033[32mOK\033[0m  %s\n' "$*"; }
warn() { printf '    \033[33mWARN\033[0m %s\n' "$*"; }
fail() { printf '    \033[31mFAIL\033[0m %s\n' "$*" >&2; return 1; }

# The APIs this pipeline manages = one folder per API under apim-apis/
api_names() { find "$APIM_APIS_DIR" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort; }

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

apim_api_exists() {  # apim_api_exists <name>   (the query is a partial match - grep -x makes it exact)
  apictl get apis -e "$TARGET_ENV" -k -q "name:$1" -l 100 --format '{{.Name}}' 2>/dev/null | grep -qx "$1"
}
