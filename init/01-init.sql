\set ON_ERROR_STOP on

CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE SCHEMA IF NOT EXISTS kingdom_archive;

CREATE TABLE IF NOT EXISTS kingdom_archive.archive_sources (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL UNIQUE,
  source_type text NOT NULL DEFAULT 'manual',
  uri text,
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS kingdom_archive.documents (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  source_id uuid REFERENCES kingdom_archive.archive_sources(id) ON DELETE SET NULL,
  external_id text,
  title text NOT NULL,
  subtitle text,
  author text,
  content_type text NOT NULL DEFAULT 'text',
  language text NOT NULL DEFAULT 'en',
  canonical_url text,
  raw_content text,
  summary text,
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
  published_at timestamptz,
  captured_at timestamptz NOT NULL DEFAULT now(),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT documents_external_source_unique UNIQUE NULLS NOT DISTINCT (source_id, external_id)
);

CREATE TABLE IF NOT EXISTS kingdom_archive.document_chunks (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  document_id uuid NOT NULL REFERENCES kingdom_archive.documents(id) ON DELETE CASCADE,
  chunk_index integer NOT NULL,
  heading text,
  content text NOT NULL,
  token_count integer,
  embedding vector(1536),
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT document_chunks_document_index_unique UNIQUE (document_id, chunk_index)
);

CREATE TABLE IF NOT EXISTS kingdom_archive.tags (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL UNIQUE,
  description text,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS kingdom_archive.document_tags (
  document_id uuid NOT NULL REFERENCES kingdom_archive.documents(id) ON DELETE CASCADE,
  tag_id uuid NOT NULL REFERENCES kingdom_archive.tags(id) ON DELETE CASCADE,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (document_id, tag_id)
);

CREATE TABLE IF NOT EXISTS kingdom_archive.ingestion_runs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  source_id uuid REFERENCES kingdom_archive.archive_sources(id) ON DELETE SET NULL,
  status text NOT NULL DEFAULT 'pending',
  started_at timestamptz NOT NULL DEFAULT now(),
  finished_at timestamptz,
  documents_seen integer NOT NULL DEFAULT 0,
  documents_created integer NOT NULL DEFAULT 0,
  documents_updated integer NOT NULL DEFAULT 0,
  error_message text,
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb
);

CREATE INDEX IF NOT EXISTS archive_sources_metadata_gin
  ON kingdom_archive.archive_sources USING gin (metadata);

CREATE INDEX IF NOT EXISTS documents_source_id_idx
  ON kingdom_archive.documents (source_id);

CREATE INDEX IF NOT EXISTS documents_published_at_idx
  ON kingdom_archive.documents (published_at DESC NULLS LAST);

CREATE INDEX IF NOT EXISTS documents_metadata_gin
  ON kingdom_archive.documents USING gin (metadata);

CREATE INDEX IF NOT EXISTS documents_search_idx
  ON kingdom_archive.documents USING gin (
    to_tsvector('english', coalesce(title, '') || ' ' || coalesce(summary, '') || ' ' || coalesce(raw_content, ''))
  );

CREATE INDEX IF NOT EXISTS document_chunks_document_id_idx
  ON kingdom_archive.document_chunks (document_id);

CREATE INDEX IF NOT EXISTS document_chunks_search_idx
  ON kingdom_archive.document_chunks USING gin (
    to_tsvector('english', coalesce(heading, '') || ' ' || content)
  );

CREATE INDEX IF NOT EXISTS document_chunks_embedding_hnsw_idx
  ON kingdom_archive.document_chunks USING hnsw (embedding vector_cosine_ops)
  WHERE embedding IS NOT NULL;

CREATE OR REPLACE FUNCTION kingdom_archive.set_updated_at()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS archive_sources_set_updated_at ON kingdom_archive.archive_sources;
CREATE TRIGGER archive_sources_set_updated_at
BEFORE UPDATE ON kingdom_archive.archive_sources
FOR EACH ROW
EXECUTE FUNCTION kingdom_archive.set_updated_at();

DROP TRIGGER IF EXISTS documents_set_updated_at ON kingdom_archive.documents;
CREATE TRIGGER documents_set_updated_at
BEFORE UPDATE ON kingdom_archive.documents
FOR EACH ROW
EXECUTE FUNCTION kingdom_archive.set_updated_at();

CREATE OR REPLACE FUNCTION kingdom_archive.match_document_chunks(
  query_embedding vector(1536),
  match_count integer DEFAULT 10,
  filter_metadata jsonb DEFAULT '{}'::jsonb
)
RETURNS TABLE (
  chunk_id uuid,
  document_id uuid,
  title text,
  heading text,
  content text,
  metadata jsonb,
  similarity double precision
)
LANGUAGE sql
STABLE
AS $$
  SELECT
    c.id AS chunk_id,
    c.document_id,
    d.title,
    c.heading,
    c.content,
    c.metadata,
    1 - (c.embedding <=> query_embedding) AS similarity
  FROM kingdom_archive.document_chunks c
  JOIN kingdom_archive.documents d ON d.id = c.document_id
  WHERE c.embedding IS NOT NULL
    AND (filter_metadata = '{}'::jsonb OR c.metadata @> filter_metadata)
  ORDER BY c.embedding <=> query_embedding
  LIMIT match_count;
$$;
