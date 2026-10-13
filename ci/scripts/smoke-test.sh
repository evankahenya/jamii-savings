#!/usr/bin/env bash
# Runs ci/smoke-tests.txt against MI (direct) and the APIM gateway (with a token).
# Needs: TARGET_ENV MI_URL GATEWAY_URL, and apictl already logged in to $TARGET_ENV
# (deploy.sh does that). Exits non-zero if any check fails.
. "$(dirname "$0")/common.sh"
require_vars TARGET_ENV MI_URL GATEWAY_URL

TESTS="$REPO_ROOT/ci/smoke-tests.txt"
trim() { sed 's/^ *//; s/ *$//' <<<"$1"; }
context_of() { sed -n 's/^  context: //p' "$APIM_APIS_DIR/$1/api.yaml"; }
version_of() { sed -n 's/^  version: //p' "$APIM_APIS_DIR/$1/api.yaml"; }

# --- get a gateway token -----------------------------------------------------------
# `apictl get keys` subscribes apictl's helper app to each API and returns a token.
# Recreate that app every run: APIM never shows a client secret twice, so a stale app
# from an earlier run (or another apictl config) can't issue tokens.
apictl delete app -n default-apictl-app -e "$TARGET_ENV" -k >/dev/null 2>&1 || true
TOKEN=""
for api in $(api_names); do
  TOKEN=$(apictl get keys -n "$api" -v "$(version_of "$api")" -e "$TARGET_ENV" -k 2>/dev/null | grep -E '^eyJ' | tail -1) \
    || true
  [ -n "$TOKEN" ] || fail "could not get a gateway token for $api"
done
# (the last token is valid for every API: the same app is now subscribed to all of them)

call() {  # call <url> <method> <body> [auth header] -> prints status code
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

  got=$(call "$MI_URL$ctx$path" "$method" "$body")
  if [ "$got" = "$expected" ]; then ok "MI      $method $ctx$path -> $got"
  else fail "MI      $method $ctx$path -> $got (expected $expected)" || failures=$((failures + 1)); fi

  # the gateway may need a few seconds to load a new revision - retry for up to 60s
  for _ in $(seq 1 12); do
    got=$(call "$GATEWAY_URL$ctx/$ver$path" "$method" "$body" "Authorization: Bearer $TOKEN")
    [ "$got" = "$expected" ] && break
    sleep 5
  done
  if [ "$got" = "$expected" ]; then ok "Gateway $method $ctx/$ver$path -> $got"
  else fail "Gateway $method $ctx/$ver$path -> $got (expected $expected)" || failures=$((failures + 1)); fi
done < "$TESTS"

# every API must have been tested at least once
for api in $(api_names); do
  grep -q "^$api " "$TESTS" || { fail "no smoke test for $api in ci/smoke-tests.txt" || failures=$((failures + 1)); }
done

[ "$failures" -eq 0 ] || { echo "$failures smoke test(s) failed" >&2; exit 1; }
echo; echo "All smoke tests passed on $TARGET_ENV."
