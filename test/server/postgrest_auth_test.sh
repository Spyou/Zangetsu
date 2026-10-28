#!/usr/bin/env bash
set -euo pipefail

base_url=${1:-http://127.0.0.1:3000}
routes=(history profile_history mylist profile_mylist list_categories
  profile_list_categories reading_history profile_reading_history
  viewer_profiles backups)

check() {
  local route=$1 label=$2
  shift 2
  local status
  status=$(curl --silent --output /dev/null --write-out '%{http_code}' \
    --max-time 5 "$@" "$base_url/$route") || status=000
  if [[ $status != 401 ]]; then
    printf '%s request for %s returned %s, expected 401\n' \
      "$label" "$route" "$status" >&2
    exit 1
  fi
}

for route in "${routes[@]}"; do
  check "$route" unauthenticated
  check "$route" invalid-token --header 'Authorization: Bearer invalid-token'
done

check rpc/profile_lock unauthenticated --request POST --header 'Content-Type: application/json' --data '{"p_action":"status"}'
check rpc/profile_lock invalid-token --request POST --header 'Authorization: Bearer invalid-token' --header 'Content-Type: application/json' --data '{"p_action":"status"}'

printf 'all %d routes reject unauthenticated and invalid-token requests\n' \
  "$((${#routes[@]} + 1))"
