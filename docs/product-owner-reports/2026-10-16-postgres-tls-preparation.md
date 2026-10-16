# PostgreSQL TLS preparation — uncommitted branch

Repository: blocklienterprise/kingdom-concepts-postgres.
Branch: `codex/postgres-tls-support`, created from local main `b9455eca8599c3d2e42eb3025b6a26edb9f8d48e`.
Owner requested inspection of the local app and a new branch for changes. The standing instruction
not to commit remains in force: no commit, push, registry publication, Bunny deployment or running
service restart was performed.

## Prepared

- TLS-aware image entrypoint, preserving the official image initialization and existing PGDATA.
- Explicit off/on/require modes, runtime mounted-file or base64 secret inputs, matching certificate/key
  and expiry checks, private key permissions and TLS 1.2 minimum. No production key/certificate created.
- Strict mode prepends plaintext TCP rejection through a runtime HBA include of the original file;
  no persistent authentication file, role, password or archive schema is rewritten.
- Base Compose keeps existing behavior; separate TLS overlay explicitly requires TLS and mounted secrets.
- Secret/build-context exclusions, secure deployment/client/renewal guidance and staged rollback notes.
  See `docs/TLS.md`. Main-only image publishing workflow is unchanged.

## Verification

Local image `kingdom-concepts-postgres:tls-test` builds successfully on this machine's ARM64 Docker.
Bash syntax and Compose overlay configuration validate, and `git diff --check` passes.
Disposable Docker smoke tests verify:

1. Existing default startup compatibility.
2. CA/hostname-verified encrypted connection and pg_stat_ssl confirmation.
3. Wrong hostname, untrusted CA and plaintext strict-mode connections rejected.
4. Original archive initialization still succeeds, key owner/permissions are postgres/0600.
5. Restart of an initialized test cluster preserves a marker table.
6. Mounted secret files and on-mode encrypted/plaintext compatibility for migration.
7. Mismatched key/certificate, missing secrets and invalid modes fail closed.

An initial test caught incorrect HBA filename quoting; corrected to PostgreSQL double-quoted include
syntax and the complete suite reran successfully. Only unique `kcil-tls-smoke-*` fixture containers
and volumes were used and removed. No existing Docker container/volume or real database was accessed.
Test-only keys/passwords lived in temporary files and were removed. No keys entered the image or Git.

## Pending live setup

Choose a hostname/IP identity and provision its matching CA-issued certificate/server key securely.
Build and publish a reviewed immutable image; apply secrets and the image to Bunny in a maintenance
window against the unchanged persistent volume, preserving the image entrypoint. Trial on mode,
verify all clients (KCIL, n8n and operators) with real trust/hostname checks, then explicitly cut over
to require mode and recheck plaintext rejection. Existing pooled clients need reconnect/restart.
None of these live steps has occurred or been verified. No x86_64 image build was performed locally.

KCIL live decision writes and reassessment remain separate verification/enablement gates. No protected
Hybrid or ingestion workflow, canonical record, human judgment or application deployment was changed.

Rollback procedure and TLS references are in `docs/TLS.md`. Do not destroy a database volume or rerun
archive initialization to adjust TLS. Await owner's code review before committing or publishing.
