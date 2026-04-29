#!/usr/bin/sh
set -eu

ulimit -n

if [ -n "${RLIMIT_NOFILE:-}" ]; then
  echo "Setting RLIMIT_NOFILE to ${RLIMIT_NOFILE}"
  ulimit -Sn "$RLIMIT_NOFILE"
fi

export ERL_CRASH_DUMP="${ERL_CRASH_DUMP:-/tmp/erl_crash.dump}"
export ELIXIR_ERL_OPTIONS="${ELIXIR_ERL_OPTIONS:-+fnu}"

json_field() {
  field="$1"
  awk -v key="$field" '
    BEGIN { RS = "\0" }
    {
      pat = "\"" key "\"[[:space:]]*:[[:space:]]*\""
      if (match($0, pat)) {
        s = substr($0, RSTART + RLENGTH)
        out = ""
        i = 1
        while (i <= length(s)) {
          c = substr(s, i, 1)
          if (c == "\\") {
            out = out substr(s, i, 2)
            i += 2
            continue
          }
          if (c == "\"") {
            break
          }
          out = out c
          i++
        }
        gsub(/\\"/, "\"", out)
        gsub(/\\\\/, "\\", out)
        gsub(/\\n/, "\n", out)
        gsub(/\\t/, "\t", out)
        gsub(/\\r/, "\r", out)
        gsub(/\\\//, "/", out)
        print out
      }
    }
  '
}

sha256_hex() {
  openssl dgst -sha256 -hex | awk '{ print $NF }'
}

hmac_sha256_hex() {
  openssl dgst -sha256 -mac HMAC -macopt "hexkey:$1" | awk '{ print $NF }'
}

generate_certs() {
  : "${AWS_CONTAINER_CREDENTIALS_RELATIVE_URI:?AWS_CONTAINER_CREDENTIALS_RELATIVE_URI is required}"
  : "${CLUSTER_SECRET_ID:?CLUSTER_SECRET_ID is required}"
  : "${CLUSTER_SECRET_REGION:?CLUSTER_SECRET_REGION is required}"

  creds="$(curl -fsS "http://169.254.170.2${AWS_CONTAINER_CREDENTIALS_RELATIVE_URI}")"
  aws_access_key="$(printf '%s' "$creds" | json_field "AccessKeyId")"
  aws_secret_key="$(printf '%s' "$creds" | json_field "SecretAccessKey")"
  aws_session_token="$(printf '%s' "$creds" | json_field "Token")"

  if [ -z "$aws_access_key" ] || [ -z "$aws_secret_key" ] || [ -z "$aws_session_token" ]; then
    echo "Failed to obtain ECS task role credentials" >&2
    return 1
  fi

  service="secretsmanager"
  region="$CLUSTER_SECRET_REGION"
  host="secretsmanager.${region}.amazonaws.com"
  endpoint="https://${host}/"
  amz_target="secretsmanager.GetSecretValue"
  content_type="application/x-amz-json-1.1"
  amz_date="$(date -u +"%Y%m%dT%H%M%SZ")"
  short_date="$(date -u +"%Y%m%d")"
  payload="$(printf '{"SecretId":"%s"}' "$CLUSTER_SECRET_ID")"
  payload_hash="$(printf '%s' "$payload" | sha256_hex)"
  signed_headers="content-type;host;x-amz-date;x-amz-security-token;x-amz-target"
  canonical_request="$(
    printf '%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n\n%s\n%s' \
      "POST" \
      "/" \
      "" \
      "content-type:${content_type}" \
      "host:${host}" \
      "x-amz-date:${amz_date}" \
      "x-amz-security-token:${aws_session_token}" \
      "x-amz-target:${amz_target}" \
      "$signed_headers" \
      "$payload_hash"
  )"
  canonical_request_hash="$(printf '%s' "$canonical_request" | sha256_hex)"
  credential_scope="${short_date}/${region}/${service}/aws4_request"
  string_to_sign="$(printf 'AWS4-HMAC-SHA256\n%s\n%s\n%s' "$amz_date" "$credential_scope" "$canonical_request_hash")"

  k_secret_hex="$(printf 'AWS4%s' "$aws_secret_key" | od -An -tx1 -v | tr -d ' \n')"
  k_date="$(printf '%s' "$short_date" | hmac_sha256_hex "$k_secret_hex")"
  k_region="$(printf '%s' "$region" | hmac_sha256_hex "$k_date")"
  k_service="$(printf '%s' "$service" | hmac_sha256_hex "$k_region")"
  k_signing="$(printf '%s' "aws4_request" | hmac_sha256_hex "$k_service")"
  signature="$(printf '%s' "$string_to_sign" | hmac_sha256_hex "$k_signing")"
  authorization="AWS4-HMAC-SHA256 Credential=${aws_access_key}/${credential_scope}, SignedHeaders=${signed_headers}, Signature=${signature}"

  response="$(
    curl -fsS -X POST "$endpoint" \
      -H "Content-Type: ${content_type}" \
      -H "Host: ${host}" \
      -H "X-Amz-Date: ${amz_date}" \
      -H "X-Amz-Security-Token: ${aws_session_token}" \
      -H "X-Amz-Target: ${amz_target}" \
      -H "Authorization: ${authorization}" \
      --data-binary "$payload"
  )"
  secret_string="$(printf '%s' "$response" | json_field "SecretString")"

  if [ -z "$secret_string" ]; then
    echo "SecretString not found in Secrets Manager response" >&2
    return 1
  fi

  printf '%s' "$secret_string" | json_field "key" | base64 -d > ca.key
  printf '%s' "$secret_string" | json_field "cert" | base64 -d > ca.cert

  if [ ! -s ca.key ] || [ ! -s ca.cert ]; then
    echo "Failed to extract ca.key/ca.cert from secret" >&2
    return 1
  fi

  openssl req -new -nodes -out server.csr -keyout server.key \
    -subj "/C=US/ST=Delaware/L=New Castle/O=Supabase Inc/CN=$(hostname -f)"
  openssl x509 -req -in server.csr -days 90 -CA ca.cert -CAkey ca.key -out server.cert
  rm -f ca.key

  cwd="$(pwd)"
  export GEN_RPC_CACERTFILE="$cwd/ca.cert"
  export GEN_RPC_KEYFILE="$cwd/server.key"
  export GEN_RPC_CERTFILE="$cwd/server.cert"
  chmod a+r "$GEN_RPC_CACERTFILE"
  chmod a+r "$GEN_RPC_KEYFILE"
  chmod a+r "$GEN_RPC_CERTFILE"
  cat > inet_tls.conf <<EOF
[
  {server, [
    {certfile, "${GEN_RPC_CERTFILE}"},
    {keyfile, "${GEN_RPC_KEYFILE}"},
    {secure_renegotiate, true}
  ]},
  {client, [
    {cacertfile, "${GEN_RPC_CACERTFILE}"},
    {verify, verify_none},
    {secure_renegotiate, true}
  ]}
].
EOF
  export ERL_AFLAGS="${ERL_AFLAGS:-} -proto_dist inet_tls -ssl_dist_optfile ${cwd}/inet_tls.conf"
}

run_as_nobody() {
  exec /usr/bin/setpriv --reuid=65534 --regid=65534 --clear-groups "$@"
}

run_step_as_nobody() {
  /usr/bin/setpriv --reuid=65534 --regid=65534 --clear-groups "$@"
}

if [ -n "${GENERATE_CLUSTER_CERTS:-}" ]; then
  generate_certs
fi

echo "Running migrations"
run_step_as_nobody /app/bin/migrate

if [ "${SEED_SELF_HOST:-}" = true ]; then
  echo "Seeding selfhosted Realtime"
  run_step_as_nobody /app/bin/realtime eval 'Realtime.Release.seeds(Realtime.Repo)'
fi

echo "Starting Realtime"
ulimit -n
run_as_nobody "$@"
