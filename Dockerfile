FROM pgvector/pgvector:pg17

LABEL org.opencontainers.image.title="kingdom-concepts-postgres"
LABEL org.opencontainers.image.description="PostgreSQL 17 with pgvector and Kingdom Concepts archive schema"
LABEL org.opencontainers.image.source="https://github.com/blocklienterprise/kingdom-concepts-postgres"

ENV PGDATA=/var/lib/postgresql/data/pgdata

RUN apt-get update \
    && apt-get install -y --no-install-recommends openssl ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY init/ /docker-entrypoint-initdb.d/
COPY --chmod=0755 docker/tls-entrypoint.sh /usr/local/bin/kcil-tls-entrypoint.sh

ENTRYPOINT ["/usr/local/bin/kcil-tls-entrypoint.sh"]
CMD ["postgres"]

HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=5 \
  CMD pg_isready -U "$POSTGRES_USER" -d "$POSTGRES_DB" || exit 1
