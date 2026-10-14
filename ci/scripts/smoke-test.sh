#!/usr/bin/env bash
# Runs ci/smoke-tests.txt against MI and the gateway. Called by deploy.sh.
. "$(dirname "$0")/common.sh"
require_vars TARGET_ENV MI_URL GATEWAY_URL

TESTS="$REPO_ROOT/ci/smoke-tests.txt"
trim() { sed 's/\r$//; s/^ *//; s/ *$//' <<<"$1"; }
context_of() { yaml_value "$(apim_yaml "$1")" context; }
version_of() { yaml_value "$(apim_yaml "$1")" version; }

# recreate apictl's helper app each run - a stale one can't issue tokens
apictl delete app -n default-apictl-app -e "$TARGET_ENV" -k >/dev/null 2>&1 || true
TOKEN=""
for api in $(api_names) $(product_names); do
  TOKEN=$(apictl get keys -n "$api" -v "$(version_of "$api")" -e "$TARGET_ENV" -k 2>/dev/null | grep -E '^eyJ' | tail -1) \
    || true
  [ -n "$TOKEN" ] || fail "could not get a gateway token for $api"
done

APIKEY=""
for api in $(api_names); do
  uses_api_key_only "$(apim_yaml "$api")" || continue
  require_vars APIM_URL APIM_USER APIM_PASS
  APIKEY=$(devportal_api_key default-apictl-app) || true
  [ -n "$APIKEY" ] || fail "could not generate an API key (needed for $api, which uses API Key security)"
  break
done
auth_for() {
  local y h; y=$(apim_yaml "$1")
  if uses_api_key_only "$y"; then
    h=$(yaml_value "$y" apiKeyHeader)
    echo "${h:-ApiKey}: $APIKEY"
  else echo "Authorization: Bearer $TOKEN"; fi
}

call() {  # call <url> <method> <body> [header]
  local url=$1 method=$2 body=$3 auth=${4:-}
  local args=(-sk -o /dev/null -w '%{http_code}' -X "$method" --max-time 30)
  [ -n "$auth" ] && args+=(-H "$auth")
  [ -n "$body" ] && args+=(-H 'Content-Type: application/json' -d "$body")
  curl "${args[@]}" "$url" || echo 000
}

failures=0
log "Smoke tests on $TARGET_ENV"
while IFS='|' read -r api method path expected body; do
  api=$(trim "$api"); [ -z "$api" ] || [ "${api:0:1}" = "#" ] && continue
  method=$(trim "$method"); path=$(trim "$path"); expected=$(trim "$expected"); body=$(trim "$body")
  ctx=$(context_of "$api"); ver=$(version_of "$api")

  # products only exist on the gateway
  if [ -d "$APIM_APIS_DIR/$api" ]; then
    got=$(call "$MI_URL$ctx$path" "$method" "$body")
    if [ "$got" = "$expected" ]; then ok "MI      $method $ctx$path -> $got"
    else fail "MI      $method $ctx$path -> $got (expected $expected)" || failures=$((failures + 1)); fi
  fi

  # retry while the gateway picks up the new revision
  for _ in $(seq 1 12); do
    got=$(call "$GATEWAY_URL$ctx/$ver$path" "$method" "$body" "$(auth_for "$api")")
    [ "$got" = "$expected" ] && break
    sleep 5
  done
  how=$(auth_for "$api" | cut -d: -f1)
  if [ "$got" = "$expected" ]; then ok "Gateway $method $ctx/$ver$path -> $got  ($how)"
  else fail "Gateway $method $ctx/$ver$path -> $got (expected $expected)" || failures=$((failures + 1)); fi
done < "$TESTS"

for api in $(api_names) $(product_names); do
  grep -q "^$api " "$TESTS" || { fail "no smoke test for $api in ci/smoke-tests.txt" || failures=$((failures + 1)); }
done

[ "$failures" -eq 0 ] || { echo "$failures smoke test(s) failed" >&2; exit 1; }
echo; echo "All smoke tests passed on $TARGET_ENV."
