-- Enable pgvector extension for vector similarity search
CREATE EXTENSION IF NOT EXISTS vector;

-- Main embeddings table
CREATE TABLE IF NOT EXISTS embeddings (
    id SERIAL PRIMARY KEY,
    chunk_text TEXT NOT NULL,
    embedding vector(1024),  -- Titan Embeddings v2 produces 1024-dimensional vectors
    filename TEXT NOT NULL,
    chunk_index INTEGER NOT NULL,
    file_hash TEXT,  -- MD5 hash to detect file changes
    created_at TIMESTAMP DEFAULT NOW()
);

-- Index for fast vector similarity search using cosine distance
-- ivfflat is an approximate nearest neighbor algorithm
CREATE INDEX IF NOT EXISTS embeddings_vector_idx 
ON embeddings USING ivfflat (embedding vector_cosine_ops)
WITH (lists = 100);

-- Index for filtering by filename
CREATE INDEX IF NOT EXISTS embeddings_filename_idx ON embeddings(filename);

-- Table to track processed files (avoid reprocessing)
CREATE TABLE IF NOT EXISTS processed_files (
    filename TEXT PRIMARY KEY,
    file_hash TEXT NOT NULL,
    processed_at TIMESTAMP DEFAULT NOW(),
    chunk_count INTEGER
);
