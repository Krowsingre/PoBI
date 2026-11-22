#!/usr/bin/env bash
# Exercises the live game server the way the app does, then deletes the test player.
# Usage: smoke.sh <project url> <anon key> <service role key>
set -euo pipefail
base=$1 anon=$2 service=$3
# A real place from the catalogue, so the server's own position check applies.
IFS=$'\t' read -r place_id _ _ _ plat plon _ < <(head -n 1 ios/PoBI/Resources/nj_places.tsv)
uid=""
cleanup() {
  if [ -n "$uid" ] && [ -n "${rating:-}" ]; then
    curl -sS -o /dev/null -X DELETE "$base/storage/v1/object/receipts/$uid/$rating.jpg" \
      -H "apikey: $service" -H "Authorization: Bearer $service" || true
  fi
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
body="{\"id\":\"$rating\",\"place_id\":\"$place_id\",\"latitude\":$plat,\"longitude\":$plon,\"verdict\":\"plateIt\",\"stars\":2,\"storefront_photo\":false,\"pending\":[],\"typed_business\":null,\"typed_date\":null}"
expect "rate" 201 "$(call POST ratings "$body" "resolution=ignore-duplicates,return=minimal")"
expect "same rating again is harmless" 201 "$(call POST ratings "$body" "resolution=ignore-duplicates,return=minimal")"
printf '\xff\xd8\xff\xd9' > /tmp/receipt.jpg
code=$(curl -sS -o /tmp/out -w "%{http_code}" -X POST "$base/storage/v1/object/receipts/$uid/$rating.jpg" \
  -H "apikey: $anon" -H "Authorization: Bearer $token" -H "Content-Type: image/jpeg" \
  --data-binary @/tmp/receipt.jpg)
expect "upload a receipt photo to your own folder" 200 "$code"
code=$(curl -sS -o /tmp/out -w "%{http_code}" -X POST "$base/storage/v1/object/receipts/someone-else/$rating.jpg" \
  -H "apikey: $anon" -H "Authorization: Bearer $token" -H "Content-Type: image/jpeg" --data-binary @/tmp/receipt.jpg)
[ "$code" != 200 ] && echo "ok: can't upload into another player's folder ($code)" || { echo "FAIL: uploaded into another folder"; exit 1; }
expect "mark receipt uploaded" 204 "$(call PATCH "ratings?id=eq.$rating" '{"receipt_photo":true}' return=minimal)"
code=$(curl -sS -o /tmp/out -w "%{http_code}" -X POST "$base/rest/v1/rpc/review_queue" \
  -H "apikey: $anon" -H "Authorization: Bearer $token" -H "Content-Type: application/json" -d '{}')
[ "$code" != 200 ] && echo "ok: a non-reviewer can't open the review queue ($code)" || { echo "FAIL: queue open to everyone"; exit 1; }
far="{\"id\":\"$(cat /proc/sys/kernel/random/uuid)\",\"place_id\":\"$place_id\",\"latitude\":$(awk "BEGIN{print $plat+0.08}"),\"longitude\":$plon,\"accuracy\":10}"
code=$(call POST check_ins "$far" "return=minimal")
expect "far check-in refused" 400 "$code"
grep -q P0001 /tmp/out && echo "ok: refusal carries the rule's message: $(jq -r .message /tmp/out)"
near="{\"id\":\"$(cat /proc/sys/kernel/random/uuid)\",\"place_id\":\"$place_id\",\"latitude\":$(awk "BEGIN{print $plat+0.0003}"),\"longitude\":$plon,\"accuracy\":10}"
expect "near check-in" 201 "$(call POST check_ins "$near" "resolution=ignore-duplicates,return=minimal")"
fn() { # body -> prints HTTP status, body to /tmp/out
  curl -sS -o /tmp/out -w "%{http_code}" -X POST "$base/functions/v1/attest" \
    -H "apikey: $anon" -H "Authorization: Bearer $token" -H "Content-Type: application/json" -d "$1"
}
expect "App Attest hands out a challenge" 200 "$(fn '{"action":"challenge"}')"
expect "App Attest refuses an unknown key" 404 "$(fn "{\"action\":\"submit\",\"table\":\"ratings\",\"keyId\":\"nope\",\"assertion\":\"\",\"body\":\"{}\"}")"
fn '{"action":"challenge"}' >/dev/null; challenge=$(jq .challenge /tmp/out)
expect "App Attest refuses a fake attestation" 403 "$(fn "{\"action\":\"register\",\"keyId\":\"k\",\"attestation\":\"AAAA\",\"challenge\":$challenge}")"
