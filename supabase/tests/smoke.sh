#!/usr/bin/env bash
# Exercises the live game server the way the app does, then deletes the test player.
# Usage: smoke.sh <project url> <anon key> <service role key>
set -euo pipefail
base=$1 anon=$2 service=$3
uid=""
cleanup() {
  if [ -n "$uid" ]; then
    curl -sS -o /dev/null -w "Deleted test player: HTTP %{http_code}\n" -X DELETE \
      "$base/auth/v1/admin/users/$uid" -H "apikey: $service" -H "Authorization: Bearer $service"
  fi
}
trap cleanup EXIT

code=$(curl -sS -o /tmp/auth -w "%{http_code}" -X POST "$base/auth/v1/signup" \
  -H "apikey: $anon" -H "Content-Type: application/json" -d '{}')
if [ "$code" != 200 ]; then echo "FAIL: guest sign-in (HTTP $code)"; jq -c '{code, error_code, msg}' /tmp/auth || cat /tmp/auth; exit 1; fi
auth=$(cat /tmp/auth)
token=$(jq -r .access_token <<<"$auth")
uid=$(jq -r .user.id <<<"$auth")
echo "Guest sign-in works."

call() { # method path body prefer -> prints HTTP status, body to /tmp/out
  curl -sS -o /tmp/out -w "%{http_code}" -X "$1" "$base/rest/v1/$2" \
    -H "apikey: $anon" -H "Authorization: Bearer $token" \
    -H "Content-Type: application/json" -H "Prefer: $4" -d "$3"
}
expect() { # name wanted got
  if [ "$2" != "$3" ]; then echo "FAIL: $1 (wanted $2, got $3)"; cat /tmp/out; echo; exit 1; fi
  echo "ok: $1"
}

expect "create player" 201 "$(call POST players "{\"id\":\"$uid\"}" "resolution=ignore-duplicates,return=minimal")"
expect "pick team" 204 "$(call PATCH "players?id=eq.$uid&team=is.null" '{"team":"team1"}' return=minimal)"
rating=$(cat /proc/sys/kernel/random/uuid)
body="{\"id\":\"$rating\",\"place_id\":\"smoke-test\",\"latitude\":40.22,\"longitude\":-74.55,\"verdict\":\"plateIt\",\"stars\":2,\"storefront_photo\":false,\"pending\":[],\"typed_business\":null,\"typed_date\":null}"
expect "rate" 201 "$(call POST ratings "$body" "resolution=ignore-duplicates,return=minimal")"
expect "same rating again is harmless" 201 "$(call POST ratings "$body" "resolution=ignore-duplicates,return=minimal")"
far="{\"id\":\"$(cat /proc/sys/kernel/random/uuid)\",\"place_id\":\"smoke-test\",\"latitude\":40.30,\"longitude\":-74.55,\"accuracy\":10}"
code=$(call POST check_ins "$far" "return=minimal")
expect "far check-in refused" 400 "$code"
grep -q P0001 /tmp/out && echo "ok: refusal carries the rule's message: $(jq -r .message /tmp/out)"
near="{\"id\":\"$(cat /proc/sys/kernel/random/uuid)\",\"place_id\":\"smoke-test\",\"latitude\":40.2203,\"longitude\":-74.55,\"accuracy\":10}"
expect "near check-in" 201 "$(call POST check_ins "$near" "resolution=ignore-duplicates,return=minimal")"
