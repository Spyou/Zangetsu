#!/usr/bin/env bash
set -euo pipefail

validate_jwks() {
  jq -e -s '
    length == 1 and (.[0] |
    type == "object" and
    (.keys | type == "array" and length > 0) and
    ([.keys[].kid] | length == (unique | length)) and
    all(.keys[];
      type == "object" and
      (.kid | type == "string" and length > 0) and
      (has("d") | not) and (has("p") | not) and (has("q") | not) and
      (has("dp") | not) and (has("dq") | not) and (has("qi") | not) and
      (has("k") | not) and (has("oth") | not) and
      ((.kty == "EC" and .crv == "P-256" and
        (.x | type == "string" and length > 0) and
        (.y | type == "string" and length > 0) and
        (.alg == null or .alg == "ES256")) or
       (.kty == "RSA" and
        (.n | type == "string" and length > 0) and
        (.e | type == "string" and length > 0) and
        (.alg == null or .alg == "RS256")))
    ))
  ' "$1" > /dev/null
}

if [[ ${1:-} == --validate && $# == 2 ]]; then
  validate_jwks "$2"
  exit
fi
if [[ $# != 0 ]]; then
  printf 'usage: %s [--validate jwks.json]\n' "$0" >&2
  exit 2
fi

# Only these fixed issuer/URL pairs may supply trusted signing keys.
cloud_issuer=https://eogwzrlfoercfwcfwlmv.supabase.co/auth/v1
vps_issuer=https://sb.AniAura.online/auth/v1
source_config=/etc/AniAura-sync/jwks-sources.json
destination=/etc/AniAura-sync/jwks.json
temp_dir=$(mktemp -d "${destination}.tmp.XXXXXX")
trap 'rm -rf "$temp_dir"' EXIT

if [[ -e $source_config || -L $source_config ]]; then
  cp "$source_config" "$temp_dir/sources.json"
else
  jq -n --arg issuer "$cloud_issuer" \
    '[{issuer: $issuer, url: ($issuer + "/.well-known/jwks.json")}]' > "$temp_dir/sources.json"
fi
jq -e -s --arg cloud "$cloud_issuer" --arg vps "$vps_issuer" '
  length == 1 and (.[0] |
  type == "array" and length > 0 and
  ([.[].issuer] | length == (unique | length)) and
  all(.[];
    type == "object" and
    (.issuer == $cloud or .issuer == $vps) and
    .url == (.issuer + "/.well-known/jwks.json")
  ))
' "$temp_dir/sources.json" > /dev/null
jq -r '.[] | [.issuer, .url] | @tsv' "$temp_dir/sources.json" > "$temp_dir/sources.tsv"

index=0
while IFS=$'\t' read -r issuer source_url; do
  source_file="$temp_dir/source-$index.json"
  # Do not read curlrc or follow redirects outside the approved endpoints.
  status=$(curl --disable --fail --silent --show-error --proto '=https' \
    --max-time 20 --retry 2 --max-filesize 1048576 --write-out '%{http_code}' \
    --output "$source_file" "$source_url")
  if [[ $status != 200 ]]; then
    printf 'JWKS endpoint did not return HTTP 200\n' >&2
    exit 1
  fi
  validate_jwks "$source_file"
  jq -e --arg issuer "$issuer" \
    'all(.keys[]; .issuer == null or .issuer == $issuer)' "$source_file" > /dev/null
  jq --arg issuer "$issuer" '.keys |= map(. + {issuer: $issuer})' \
    "$source_file" > "$temp_dir/tagged-$index.json"
  index=$((index + 1))
done < "$temp_dir/sources.tsv"

temp_file="$temp_dir/merged.json"
jq -s '{keys: [.[].keys[]]}' "$temp_dir"/tagged-*.json > "$temp_file"
validate_jwks "$temp_file"

if [[ ! -f $destination ]] || ! cmp --silent "$temp_file" "$destination"; then
  chown root:sync_authenticator "$temp_file"
  chmod 0640 "$temp_file"
  mv -f "$temp_file" "$destination"
fi
# Re-signal even if the file is unchanged: a previous reload may have failed.
systemctl kill --signal=SIGUSR2 AniAura-sync-stage.service
