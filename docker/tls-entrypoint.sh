#!/usr/bin/env bash
set -Eeuo pipefail
# Do not log secret values or enable shell tracing here.
fail() { printf 'PostgreSQL TLS setup: %s\n' "$1" >&2; exit 1; }
if [[ "${1:-}" == -* ]]; then set -- postgres "$@"; fi
mode="${POSTGRES_TLS_MODE:-off}"
case "$mode" in off|on|require) ;; *) fail 'POSTGRES_TLS_MODE must be off, on, or require.' ;; esac
if [[ "${1:-}" == postgres && "$mode" != off ]]; then
  umask 077
  directory=/run/kcil-postgres-tls
  mkdir -p "$directory"
  chmod 0700 "$directory"
  materialize() {
    local kind="$1" destination="$2" file_name="POSTGRES_TLS_${1}_FILE" encoded_name="POSTGRES_TLS_${1}_B64"
    local source_file="${!file_name:-}" encoded="${!encoded_name:-}"
    [[ -z "$source_file" || -z "$encoded" ]] || fail "Choose either a file or base64 secret for $kind, not both."
    if [[ -n "$source_file" ]]; then
      [[ -r "$source_file" && -s "$source_file" ]] || fail "$kind file is missing or unreadable."
      cat -- "$source_file" > "$destination"
    elif [[ -n "$encoded" ]]; then
      printf '%s' "$encoded" | base64 --decode > "$destination" 2>/dev/null || fail "$kind secret is not valid base64."
    else
      fail "$kind must be supplied securely before TLS can start."
    fi
    chmod 0600 "$destination"
  }
  materialize CERT "$directory/server.crt"
  materialize KEY "$directory/server.key"
  openssl x509 -in "$directory/server.crt" -noout -checkend 0 >/dev/null 2>&1 || fail 'Certificate is malformed or expired.'
  certificate_public=$(openssl x509 -in "$directory/server.crt" -pubkey -noout 2>/dev/null | openssl pkey -pubin -outform DER 2>/dev/null | sha256sum) || fail 'Certificate public key is invalid.'
  private_public=$(openssl pkey -in "$directory/server.key" -passin pass: -pubout -outform DER 2>/dev/null | sha256sum) || fail 'Private key must be valid and unencrypted.'
  [[ "$certificate_public" == "$private_public" ]] || fail 'Certificate and private key do not match.'
  set -- "$@" -c ssl=on -c "ssl_cert_file=$directory/server.crt" -c "ssl_key_file=$directory/server.key" -c ssl_min_protocol_version=TLSv1.2
  if [[ "$mode" == require ]]; then
    # Keep existing authentication policies, but reject unencrypted TCP first.
    # The official entrypoint initializes PGDATA before starting its temporary server.
    [[ "${PGDATA:-}" == /* && "$PGDATA" != *\"* && "$PGDATA" != *\\* && "$PGDATA" != *$'\n'* && "$PGDATA" != *$'\r'* ]] || fail 'PGDATA must be an absolute path without quotes or newlines.'
    printf 'hostnossl all all 0.0.0.0/0 reject\nhostnossl all all ::/0 reject\ninclude "%s/pg_hba.conf"\n' "$PGDATA" > "$directory/pg_hba.conf"
    chmod 0600 "$directory/pg_hba.conf"
    set -- "$@" -c "hba_file=$directory/pg_hba.conf"
  fi
  if [[ "$(id -u)" == 0 ]]; then chown -R postgres:postgres "$directory"; fi
fi
unset POSTGRES_TLS_KEY_B64 POSTGRES_TLS_CERT_B64
exec /usr/local/bin/docker-entrypoint.sh "$@"
