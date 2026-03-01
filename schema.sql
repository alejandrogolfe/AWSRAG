-- =============================================================================
-- Schema para langchain PGVector
-- Langchain crea estas tablas automáticamente, pero las pre-creamos aquí
-- para poder añadir los índices de rendimiento desde el primer momento.
-- =============================================================================

-- Habilitar extensión pgvector
CREATE EXTENSION IF NOT EXISTS vector;

-- Tabla de colecciones (langchain la crea con este nombre exacto)
CREATE TABLE IF NOT EXISTS langchain_pg_collection (
    name        VARCHAR     NOT NULL,
    cmetadata   JSON,
    uuid        UUID PRIMARY KEY
);

-- Tabla de embeddings (langchain la crea con este nombre exacto)
CREATE TABLE IF NOT EXISTS langchain_pg_embedding (
    collection_id   UUID        REFERENCES langchain_pg_collection(uuid) ON DELETE CASCADE,
    embedding       VECTOR(1536),  -- text-embedding-3-small produce 1536 dimensiones
    document        VARCHAR,
    cmetadata       JSON,
    custom_id       VARCHAR,
    uuid            UUID        PRIMARY KEY
);

-- Índice de búsqueda vectorial por similitud coseno (ivfflat = ANN aproximado, rápido)
CREATE INDEX IF NOT EXISTS langchain_pg_embedding_vector_idx
ON langchain_pg_embedding USING ivfflat (embedding vector_cosine_ops)
WITH (lists = 100);

-- Índice por collection_id para filtrar por colección rápidamente
CREATE INDEX IF NOT EXISTS langchain_pg_embedding_collection_idx
ON langchain_pg_embedding (collection_id);
