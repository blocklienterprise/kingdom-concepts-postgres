# PostgreSQL TLS rollout

This branch prepares native PostgreSQL TLS on the existing TCP endpoint, port 5432.
Adding a Bunny CDN endpoint or switching on Origin SSL does not configure PostgreSQL TLS.
The Docker image must be built/published and its configuration applied to Bunny separately;
Compose changes alone do not change the hosted app.

## Modes

- `POSTGRES_TLS_MODE=off` (default): preserves the current startup/authentication behavior.
- `POSTGRES_TLS_MODE=on`: enables TLS with the supplied certificate but preserves existing
  authentication policy. Existing plaintext clients may still connect. This is a migration
  stage, not proof that every connection is encrypted.
- `POSTGRES_TLS_MODE=require`: enables TLS and rejects unencrypted IPv4/IPv6 TCP connections.
  A runtime-only HBA file adds those rejections before including the existing cluster HBA.
  Existing password/role and Unix-socket authentication rules are otherwise preserved.

No initialization SQL, persistent data directory, passwords or roles are rewritten by TLS setup.
A normal container restart is needed to apply new TLS configuration or rotate supplied material.
TLS mode validates certificate parsing/expiry and matching key, with TLS 1.2 minimum.
The client must additionally verify the CA chain and hostname; server startup alone does not
prove that the certificate is trusted or that the hostname is correct.

## Certificates and secrets

Choose the exact database identity first: preferably a hostname you control resolving directly
(DNS only, not HTTP/CDN proxying) to the Bunny Anycast IP. The server certificate must include
that hostname in its Subject Alternative Name. If clients retain a numeric IP as the host,
its SAN must contain that IP as an IP address instead. Do not issue a certificate for a name
that differs from the client's configured host.

Use a CA-issued certificate and matching unencrypted server private key, with a leaf-first
certificate chain. A private CA is possible only when every client explicitly trusts its
public CA certificate. Never deploy the CA private key to the container or clients. Handle
certificate issuance, secure custody and renewal separately; the image does not invent or
automatically generate a production certificate.

Supply exactly one input method per certificate/key:

| Mounted secret file | Base64 environment secret alternative |
| --- | --- |
| `POSTGRES_TLS_CERT_FILE` | `POSTGRES_TLS_CERT_B64` |
| `POSTGRES_TLS_KEY_FILE` | `POSTGRES_TLS_KEY_B64` |

For Bunny, use its secure server-side configuration to supply base64 values if file mounting
is unavailable. Base64 is an encoding, not encryption. Keep values out of chat, Git, Dockerfiles,
image layers, startup commands and logs. Generate encoded files locally without printing them:

```sh
umask 077
openssl base64 -A -in /secure/path/fullchain.crt > /secure/path/certificate.b64
openssl base64 -A -in /secure/path/server.key > /secure/path/private-key.b64
```

Copy through your trusted editor/dashboard into the secret settings. Do not commit these files.
The entrypoint materializes supplied values at runtime under `/run/kcil-postgres-tls`, with
0700 directory and 0600 postgres-owned key. Those files are outside the persistent archive data.
The base64 environment variables are removed before launching PostgreSQL (the hosting platform
still holds the configured secrets). Missing, malformed or mismatched TLS material stops startup;
there is no automatic downgrade to plaintext when mode is on/require.

## Local TLS use

The base Compose file continues using its existing data volume. The TLS overlay mounts secret
files and explicitly selects strict mode. This command restarts the existing local service;
do not run it against your real local cluster before reviewing its clients/backup:

```sh
POSTGRES_TLS_CERT_PATH=/secure/path/fullchain.crt \
POSTGRES_TLS_KEY_PATH=/secure/path/server.key \
docker compose -f docker-compose.yml -f docker-compose.tls.yml up --build -d
```

For isolated integration tests that do not touch the existing service:

```sh
docker build -t kingdom-concepts-postgres:tls-test .
bash tests/tls-smoke.sh
```

The smoke test creates only uniquely named disposable containers/volumes, no published ports,
with network isolation and test-only keys/passwords; cleanup removes only those fixtures.
Never run `docker compose down -v` as part of a TLS rollout.

## Controlled Bunny rollout

1. Confirm a recoverable backup and record the current image digest, container settings,
   endpoint and persistent mount. Keep `/var/lib/postgresql/data` and PGDATA unchanged.
   Record all consumers (n8n, KCIL, operators and any integrations).
2. Build/publish an immutable TLS-capable image tag after code review. This branch does not
   change the main-only publishing workflow; no image has been published by preparation.
3. Provision certificate/key secrets securely and start with `POSTGRES_TLS_MODE=on` to
   preserve existing clients. Leave Anycast TCP 5432 mapped to container 5432. Do not add CDN.
   Keep the image's TLS entrypoint: a custom Bunny startup/entrypoint override must not bypass it.
   Apply changes in a maintenance window; restarting PostgreSQL interrupts connections.
4. Verify TLS from a trusted client using the actual hostname, trusted CA, and `verify-full`.
   Check `SELECT ssl, version, cipher FROM pg_stat_ssl WHERE pid=pg_backend_pid();`.
   Verify wrong hostname and wrong/untrusted CA fail; don't disable certificate verification.
5. KCIL: configure the matching `PGHOST`, `DATABASE_TLS_MODE=require` and, for a private CA,
   `DATABASE_CA_CERT` (public CA certificate). Restart its process to replace any existing
   pooled plaintext sessions. Leave decision writes disabled until governance verification.
   n8n: update the existing Postgres credential to use verified TLS with the proper CA/name;
   do not modify the protected Hybrid/ingestion workflow definitions. Re-test every consumer.
6. After clients are verified, deploy `POSTGRES_TLS_MODE=require` and prove a new plaintext
   TCP connection is rejected. The wrapper preserves original HBA rules via include rather
   than overwriting pg_hba.conf. Existing socket administration policies remain as before.
7. Only then proceed with the separate authenticated KCIL decision-recording tests. Database
   TLS configuration does not automatically enable application writes or complete reassessment.

## Rollback

Keep the prior immutable image reference and secure settings. Before strict cutover, reverting
an on-mode trial can use the previous image/configuration against the unchanged volume. After
strict cutover, prefer restoring a known-good TLS-capable image and valid certificate rather
than reopening plaintext. An intentional switch to on/off weakens the transport policy and
requires owner authorization, not automatic fallback. Do not delete/recreate the database
volume, rerun archive initialization, or restore data merely to change TLS.

References: [PostgreSQL 17 TLS](https://www.postgresql.org/docs/17/ssl-tcp.html),
[PostgreSQL 17 HBA include rules](https://www.postgresql.org/docs/17/auth-pg-hba-conf.html).
