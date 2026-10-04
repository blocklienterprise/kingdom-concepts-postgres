# Kingdom Concepts Postgres

PostgreSQL 17 with pgvector and a production-ready Kingdom Concepts archive schema for Bunny Magic Containers.

The image is based on `pgvector/pgvector:pg17` and initializes:

- the `vector` extension
- the `pgcrypto` extension
- a `kingdom_archive` schema
- archive sources, documents, chunks, tags, document tags, and ingestion run tables
- full-text indexes for documents and chunks
- an HNSW cosine vector index for 1536-dimension embeddings
- a `kingdom_archive.match_document_chunks(...)` helper for similarity search

## Local Docker Usage

Create a local environment file:

```bash
cp .env.example .env
```

Edit `.env` and set a real local password:

```bash
POSTGRES_DB=kingdom_concepts
POSTGRES_USER=kingdom_concepts
POSTGRES_PASSWORD=replace-with-a-strong-password
```

Build and run locally:

```bash
docker compose up --build
```

Connect locally:

```bash
psql "postgresql://kingdom_concepts:replace-with-a-strong-password@localhost:5432/kingdom_concepts"
```

Check health:

```bash
docker compose ps
docker exec kingdom-concepts-postgres pg_isready -U kingdom_concepts -d kingdom_concepts
```

Stop the container:

```bash
docker compose down
```

Remove local data only when you intentionally want to reset the database:

```bash
docker compose down -v
```

## GHCR Image Publishing

GitHub Actions builds and publishes the image on every push to `main`.

Published tags:

```text
ghcr.io/blocklienterprise/kingdom-concepts-postgres:latest
ghcr.io/blocklienterprise/kingdom-concepts-postgres:<commit-sha>
```

The workflow uses GitHub-native authentication:

- `GITHUB_TOKEN`
- `permissions.packages: write`

No registry secrets are required.

For unauthenticated pulls from Bunny Magic Containers, make the GHCR package public after the first successful workflow run:

1. Open the repository on GitHub.
2. Go to Packages.
3. Open `kingdom-concepts-postgres`.
4. Set package visibility to public.

## Bunny Magic Containers Deployment

Use the public GHCR image:

```text
ghcr.io/blocklienterprise/kingdom-concepts-postgres:latest
```

Container settings:

```text
Port: 5432
Persistent volume mount: /var/lib/postgresql/data
```

Required environment variables:

```text
POSTGRES_DB=kingdom_concepts
POSTGRES_USER=kingdom_concepts
POSTGRES_PASSWORD=<strong-production-password>
```

Do not hardcode production secrets in this repository. Set `POSTGRES_PASSWORD` in Bunny Magic Containers as an environment variable or secret.

Health check:

```bash
pg_isready -U "$POSTGRES_USER" -d "$POSTGRES_DB"
```

If Bunny requires a shell command form, use:

```bash
CMD-SHELL pg_isready -U "$POSTGRES_USER" -d "$POSTGRES_DB" || exit 1
```

Suggested health check timing:

```text
Interval: 30 seconds
Timeout: 5 seconds
Start period: 20 seconds
Retries: 5
```

## Notes for n8n

Use Bunny's internal hostname or exposed connection details with the same database credentials:

```text
Host: <bunny-postgres-host>
Port: 5432
Database: kingdom_concepts
User: kingdom_concepts
Password: <POSTGRES_PASSWORD>
SSL: follow your Bunny networking configuration
```

## Schema

Primary archive tables live under:

```sql
kingdom_archive.archive_sources
kingdom_archive.documents
kingdom_archive.document_chunks
kingdom_archive.tags
kingdom_archive.document_tags
kingdom_archive.ingestion_runs
```

Vector search helper:

```sql
SELECT *
FROM kingdom_archive.match_document_chunks(
  '[0.01, 0.02, ...]'::vector(1536),
  10,
  '{}'::jsonb
);
```
