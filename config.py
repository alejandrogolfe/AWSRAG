"""
Configuración centralizada del sistema RAG.

Lee setup.yaml y expone los valores como atributos accesibles.
Las variables de entorno tienen prioridad sobre el YAML.

En AWS (Lambda / EC2) las variables de entorno las inyecta deploy_rag.sh.
En local, se leen desde el .env o setup.yaml como siempre.
"""

import os
from pathlib import Path
from typing import Any
from dotenv import load_dotenv
import yaml

load_dotenv(override=True)

# ---------------------------------------------------------------------------
# Carga del YAML — opcional en Lambda (puede no existir en el entorno)
# ---------------------------------------------------------------------------

_CONFIG_FILE = Path(__file__).parent / "setup.yaml"

def _load_yaml(path: Path) -> dict:
    if not path.exists():
        return {}   # En Lambda es normal que no esté
    with open(path, "r", encoding="utf-8") as f:
        return yaml.safe_load(f) or {}

_cfg = _load_yaml(_CONFIG_FILE)


def _get(keys: str, default: Any = None) -> Any:
    """Acceso por ruta de puntos: _get('chunking.recursive.chunk_size')."""
    parts = keys.split(".")
    node = _cfg
    for part in parts:
        if not isinstance(node, dict):
            return default
        node = node.get(part, default)
        if node is None:
            return default
    return node


# ---------------------------------------------------------------------------
# API Key (solo desde entorno — nunca en YAML)
# ---------------------------------------------------------------------------

OPENAI_API_KEY: str = os.environ.get("OPENAI_API_KEY", "")
if not OPENAI_API_KEY:
    import warnings
    warnings.warn("OPENAI_API_KEY no está definida en las variables de entorno.", stacklevel=2)

# ---------------------------------------------------------------------------
# LLM
# ---------------------------------------------------------------------------

LLM_MODEL: str         = os.environ.get("LLM_MODEL",         _get("llm.model", "gpt-4o-mini"))
LLM_TEMPERATURE: float = float(os.environ.get("LLM_TEMPERATURE", _get("llm.temperature", 0.0)))
LLM_MAX_TOKENS: int    = int(os.environ.get("LLM_MAX_TOKENS",    _get("llm.max_tokens", 1024)))

# ---------------------------------------------------------------------------
# Embeddings
# ---------------------------------------------------------------------------

EMBEDDING_MODEL: str = os.environ.get("EMBEDDING_MODEL", _get("embeddings.model", "text-embedding-3-small"))

# ---------------------------------------------------------------------------
# Vectorstore
# ---------------------------------------------------------------------------

VECTORSTORE_BACKEND: str = os.environ.get("VECTORSTORE_BACKEND", _get("vectorstore.backend", "pgvector"))
VECTORSTORE_PATH: str    = os.environ.get("VECTORSTORE_PATH",    _get("vectorstore.path", "./vectorstore"))
COLLECTION_NAME: str     = os.environ.get("COLLECTION_NAME",     _get("vectorstore.collection_name", "rag_docs"))

# PGVector / RDS — en AWS estas llegan como variables de entorno desde deploy_rag.sh
RDS_HOST: str     = os.environ.get("DB_HOST",     _get("vectorstore.pgvector.host", "localhost"))
RDS_PORT: int     = int(os.environ.get("DB_PORT", _get("vectorstore.pgvector.port", 5432)))
RDS_DB: str       = os.environ.get("DB_NAME",     _get("vectorstore.pgvector.database", "ragdb"))
RDS_USER: str     = os.environ.get("DB_USER",     _get("vectorstore.pgvector.user", "ragadmin"))
RDS_PASSWORD: str = os.environ.get("DB_PASSWORD", _get("vectorstore.pgvector.password", ""))

# ---------------------------------------------------------------------------
# Retrieval
# ---------------------------------------------------------------------------

RETRIEVER_SEARCH_TYPE: str       = _get("retrieval.search_type", "mmr")
RETRIEVER_K: int                 = int(_get("retrieval.k", 4))
RETRIEVER_FETCH_K: int           = int(_get("retrieval.fetch_k", 12))
RETRIEVER_SCORE_THRESHOLD: float = float(_get("retrieval.score_threshold", 0.7))

# ---------------------------------------------------------------------------
# Chunking
# ---------------------------------------------------------------------------

CHUNKING_STRATEGY: str = os.environ.get("CHUNKING_STRATEGY", _get("chunking.strategy", "recursive"))
CHUNKING_CONFIG: dict  = _get(f"chunking.{CHUNKING_STRATEGY}", {})

CHUNK_SIZE: int    = int(CHUNKING_CONFIG.get("chunk_size", 1000))
CHUNK_OVERLAP: int = int(CHUNKING_CONFIG.get("chunk_overlap", 150))

# ---------------------------------------------------------------------------
# Documentos
# ---------------------------------------------------------------------------

# En Lambda, el handler pasa el directorio de /tmp directamente — esta variable
# solo se usa cuando se ejecuta main.py en local.
DOCS_DIR: str             = os.environ.get("DOCS_DIR", _get("docs.directory", "./docs"))
DOCS_EXTENSIONS: list     = _get("docs.supported_extensions", ["**/*.txt", "**/*.md", "**/*.pdf"])
DOCS_SILENT_ERRORS: bool  = bool(_get("docs.silent_errors", True))

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

LOG_LEVEL: str               = _get("logging.level", "INFO")
LOG_SHOW_SOURCES: bool       = bool(_get("logging.show_sources", True))
LOG_MAX_FRAGMENT_LENGTH: int = int(_get("logging.max_fragment_length", 200))


# ---------------------------------------------------------------------------
# Validación — solo si hay YAML cargado (en Lambda puede estar vacío)
# ---------------------------------------------------------------------------

if _cfg:
    _VALID_STRATEGIES = {"recursive", "markdown_header", "sentence_window", "semantic", "parent_document", "proposition"}
    _VALID_BACKENDS   = {"chroma", "pgvector"}

    if CHUNKING_STRATEGY not in _VALID_STRATEGIES:
        raise ValueError(
            f"chunking.strategy='{CHUNKING_STRATEGY}' no es válido. "
            f"Opciones: {sorted(_VALID_STRATEGIES)}"
        )
    if VECTORSTORE_BACKEND not in _VALID_BACKENDS:
        raise ValueError(
            f"vectorstore.backend='{VECTORSTORE_BACKEND}' no es válido. "
            f"Opciones: {sorted(_VALID_BACKENDS)}"
        )
