FROM pgvector/pgvector:pg17

LABEL org.opencontainers.image.title="kingdom-concepts-postgres"
LABEL org.opencontainers.image.description="PostgreSQL 17 with pgvector and Kingdom Concepts archive schema"
LABEL org.opencontainers.image.source="https://github.com/blocklienterprise/kingdom-concepts-postgres"

COPY init/ /docker-entrypoint-initdb.d/

HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=5 \
  CMD pg_isready -U "$POSTGRES_USER" -d "$POSTGRES_DB" || exit 1
