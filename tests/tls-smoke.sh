#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
image="${1:-kingdom-concepts-postgres:tls-test}"
work=$(mktemp -d)
prefix="kcil-tls-smoke-$$-$RANDOM"
containers=()
cleanup() {
  for name in "${containers[@]}"; do
    docker rm -f "$name" >/dev/null 2>&1 || true
    docker volume rm "$name-data" >/dev/null 2>&1 || true
  done
  rm -rf "$work"
}
trap cleanup EXIT
# All certificates/passwords are disposable test fixtures, never owner credentials.
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj '/CN=KCIL disposable test CA' -keyout "$work/ca.key" -out "$work/ca.crt" >/dev/null 2>&1
openssl req -new -newkey rsa:2048 -nodes -subj '/CN=localhost' -keyout "$work/server.key" -out "$work/server.csr" >/dev/null 2>&1
printf 'subjectAltName=DNS:localhost\nbasicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\n' > "$work/extensions"
openssl x509 -req -in "$work/server.csr" -CA "$work/ca.crt" -CAkey "$work/ca.key" -CAcreateserial -days 1 -extfile "$work/extensions" -out "$work/server.crt" >/dev/null 2>&1
password=$(openssl rand -hex 24)
printf 'POSTGRES_DB=tls_test\nPOSTGRES_USER=tls_test\nPOSTGRES_PASSWORD=%s\n' "$password" > "$work/server.env"
printf 'PGPASSWORD=%s\n' "$password" > "$work/client.env"
unset password
{
  cat "$work/server.env"
  printf 'POSTGRES_TLS_MODE=require\nPOSTGRES_TLS_CERT_B64='
  openssl base64 -A -in "$work/server.crt"
  printf '\nPOSTGRES_TLS_KEY_B64='
  openssl base64 -A -in "$work/server.key"
  printf '\n'
} > "$work/tls.env"
wait_ready() {
  for ((i=0;i<90;i++)); do
    if [[ "$(docker inspect -f '{{.State.Running}}' "$1")" != true ]]; then
      printf 'Disposable database did not start.\n' >&2; docker logs "$1" 2>&1 | tail -25 >&2; return 1
    fi
    if docker exec "$1" pg_isready -h localhost -U tls_test -d tls_test >/dev/null 2>&1; then return 0; fi
    sleep 1
  done
  printf 'Disposable database startup timed out.\n' >&2; return 1
}
run_db() {
  containers+=("$1")
  docker run -d --name "$1" --network none --mount "type=volume,source=$1-data,target=/var/lib/postgresql/data" --env-file "$2" "$image" >/dev/null
  wait_ready "$1"
}
query() { docker exec --env-file "$work/client.env" "$1" psql -XAt "host=$2 dbname=tls_test user=tls_test sslmode=$3 sslrootcert=/tmp/test-ca.crt" -c "$4"; }
expect_failure() { if "$@" >/dev/null 2>&1; then printf 'Expected rejection but connection/setup succeeded.\n' >&2; exit 1; fi; }
plain="$prefix-off"
run_db "$plain" "$work/server.env"
[[ "$(query "$plain" localhost disable 'SELECT 1')" == 1 ]]
printf 'PASS: existing default non-TLS startup remains compatible.\n'
strict="$prefix-require"
run_db "$strict" "$work/tls.env"
docker cp "$work/ca.crt" "$strict:/tmp/test-ca.crt" >/dev/null
[[ "$(query "$strict" localhost verify-full 'SELECT ssl FROM pg_stat_ssl WHERE pid=pg_backend_pid()')" == t ]]
expect_failure query "$strict" 127.0.0.1 verify-full 'SELECT 1'
expect_failure query "$strict" localhost disable 'SELECT 1'
expect_failure docker exec --env-file "$work/client.env" "$strict" psql -XAt 'host=localhost dbname=tls_test user=tls_test sslmode=verify-full sslrootcert=/etc/ssl/certs/ca-certificates.crt' -c 'SELECT 1'

[[ "$(query "$strict" localhost verify-full "SELECT count(*) FROM information_schema.schemata WHERE schema_name='kingdom_archive'")" == 1 ]]
[[ "$(docker exec "$strict" stat -c '%a:%U' /run/kcil-postgres-tls/server.key)" == '600:postgres' ]]
printf 'PASS: verified TLS, hostname mismatch rejection, plaintext rejection, original initialization, private key permissions.\n'
# Restart the SAME disposable cluster with TLS to exercise an existing initialized PGDATA.
docker exec "$strict" psql -U tls_test -d tls_test -c 'CREATE TABLE tls_smoke_marker(value int); INSERT INTO tls_smoke_marker VALUES(17)' >/dev/null
docker restart "$strict" >/dev/null
wait_ready "$strict"
[[ "$(query "$strict" localhost verify-full 'SELECT value FROM tls_smoke_marker')" == 17 ]]
printf 'PASS: TLS restart preserves an already initialized cluster.\n'
# Test mounted secret files and the non-breaking TLS-enabled migration stage.
compatible="$prefix-on"
containers+=("$compatible")
docker run -d --name "$compatible" --network none --mount "type=volume,source=$compatible-data,target=/var/lib/postgresql/data" --mount "type=bind,source=$work,target=/fixture,readonly" --env-file "$work/server.env" --env POSTGRES_TLS_MODE=on --env POSTGRES_TLS_CERT_FILE=/fixture/server.crt --env POSTGRES_TLS_KEY_FILE=/fixture/server.key "$image" >/dev/null
wait_ready "$compatible"
docker cp "$work/ca.crt" "$compatible:/tmp/test-ca.crt" >/dev/null
[[ "$(query "$compatible" localhost verify-full 'SELECT ssl FROM pg_stat_ssl WHERE pid=pg_backend_pid()')" == t ]]
[[ "$(query "$compatible" localhost disable 'SELECT 1')" == 1 ]]
printf 'PASS: mounted secret files and TLS migration mode preserve existing clients.\n'
mismatch="$prefix-mismatch"
containers+=("$mismatch")
{
  cat "$work/tls.env"
  printf 'POSTGRES_TLS_KEY_B64='
  openssl base64 -A -in "$work/ca.key"
  printf '\n'
} > "$work/mismatch.env"
expect_failure docker run --name "$mismatch" --network none --env-file "$work/mismatch.env" "$image"
printf 'PASS: mismatched certificate/key and untrusted CA are rejected.\n'
missing="$prefix-missing"
containers+=("$missing")
expect_failure docker run --name "$missing" --network none --env POSTGRES_TLS_MODE=require "$image"
printf 'PASS: required TLS never falls back when credentials are missing.\n'
invalid="$prefix-invalid"
containers+=("$invalid")
expect_failure docker run --name "$invalid" --network none --env POSTGRES_TLS_MODE=invalid "$image"
printf 'PASS: invalid TLS mode fails closed.\n'
printf 'All disposable PostgreSQL TLS checks passed. No existing containers or volumes were modified.\n'
