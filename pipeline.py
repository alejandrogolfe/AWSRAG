"""
RAG Pipeline principal.
Gestiona: carga de documentos, chunking, embeddings, almacenamiento y retrieval.

Estrategias de chunking disponibles (configurar en setup.yaml):
  - recursive          → split jerárquico clásico por caracteres
  - markdown_header    → respeta la estructura de cabeceras Markdown
  - sentence_window    → ventana de frases alrededor del chunk central
  - semantic           → agrupación por similitud semántica (requiere langchain-experimental)
  - parent_document    → indexa chunks pequeños, recupera el chunk padre más grande
  - proposition        → usa un LLM para convertir chunks en proposiciones atómicas
"""

import os
from pathlib import Path
from typing import List, Tuple, Union

from langchain_community.document_loaders import (
    DirectoryLoader,
    TextLoader,
    PyPDFLoader,
    UnstructuredMarkdownLoader,
)
from langchain_core.documents import Document
from langchain_core.runnables import RunnablePassthrough
from langchain_core.output_parsers import StrOutputParser
from langchain_core.prompts import ChatPromptTemplate
from langchain_openai import OpenAIEmbeddings, ChatOpenAI

import config as settings


# =============================================================================
# 1. CARGA DE DOCUMENTOS
# =============================================================================

def load_documents(directory: str) -> List[Document]:
    """
    Carga todos los documentos del directorio indicado.
    Las extensiones soportadas se configuran en setup.yaml → docs.supported_extensions.
    """
    docs = []
    path = Path(directory)

    if not path.exists():
        raise FileNotFoundError(f"Directorio no encontrado: {directory}")

    loader_map = {
        "**/*.txt": TextLoader,
        "**/*.md":  UnstructuredMarkdownLoader,
        "**/*.pdf": PyPDFLoader,
    }

    for glob_pattern in settings.DOCS_EXTENSIONS:
        loader_cls = loader_map.get(glob_pattern)
        if loader_cls is None:
            print(f"  ⚠️  Extensión sin loader registrado: {glob_pattern} — ignorada")
            continue

        loader = DirectoryLoader(
            directory,
            glob=glob_pattern,
            loader_cls=loader_cls,
            silent_errors=settings.DOCS_SILENT_ERRORS,
            show_progress=True,
        )
        loaded = loader.load()
        docs.extend(loaded)
        print(f"  [{glob_pattern}] → {len(loaded)} documento(s) cargado(s)")

    print(f"\nTotal documentos cargados: {len(docs)}")
    return docs


# =============================================================================
# 2. CHUNKING — múltiples estrategias
# =============================================================================

# Resultado especial para parent_document: devuelve (child_chunks, parent_chunks)
# El resto de estrategias devuelven List[Document] directamente.

def split_documents(docs: List[Document]) -> Union[List[Document], Tuple[List[Document], List[Document]]]:
    """
    Divide los documentos según la estrategia definida en setup.yaml → chunking.strategy.

    La mayoría de estrategias devuelven List[Document].
    La estrategia parent_document devuelve Tuple[child_chunks, parent_chunks]
    para que build_vectorstore pueda indexar correctamente ambos niveles.
    """
    strategy = settings.CHUNKING_STRATEGY
    cfg      = settings.CHUNKING_CONFIG

    print(f"\n🔪 Chunking strategy: '{strategy}'")

    if strategy == "recursive":
        chunks = _split_recursive(docs, cfg)

    elif strategy == "markdown_header":
        chunks = _split_markdown_header(docs, cfg)

    elif strategy == "sentence_window":
        chunks = _split_sentence_window(docs, cfg)

    elif strategy == "semantic":
        chunks = _split_semantic(docs, cfg)

    elif strategy == "parent_document":
        chunks = _split_parent_document(docs, cfg)   # devuelve (child, parent)

    elif strategy == "proposition":
        chunks = _split_proposition(docs, cfg)

    else:
        raise ValueError(f"Estrategia de chunking desconocida: '{strategy}'")

    if isinstance(chunks, tuple):
        child_chunks, parent_chunks = chunks
        print(f"Chunks hijo generados: {len(child_chunks)}  |  Chunks padre: {len(parent_chunks)}\n")
    else:
        print(f"Chunks generados: {len(chunks)}\n")

    return chunks


# ---------------------------------------------------------------------------
# 2a. Recursive Character Text Splitter
# ---------------------------------------------------------------------------

def _split_recursive(docs: List[Document], cfg: dict) -> List[Document]:
    """
    Split jerárquico clásico. Intenta dividir por párrafos, luego líneas,
    luego frases y por último caracteres individuales.
    Bueno para texto genérico sin estructura clara.
    """
    from langchain_text_splitters import RecursiveCharacterTextSplitter

    splitter = RecursiveCharacterTextSplitter(
        chunk_size=cfg.get("chunk_size", 1000),
        chunk_overlap=cfg.get("chunk_overlap", 150),
        separators=cfg.get("separators", ["\n\n", "\n", ". ", " ", ""]),
        length_function=len,
    )
    chunks = splitter.split_documents(docs)
    print(f"  chunk_size={cfg.get('chunk_size')}  overlap={cfg.get('chunk_overlap')}")
    return chunks


# ---------------------------------------------------------------------------
# 2b. Markdown Header Splitter
# ---------------------------------------------------------------------------

def _split_markdown_header(docs: List[Document], cfg: dict) -> List[Document]:
    """
    Divide respetando la jerarquía de cabeceras Markdown (H1, H2, H3…).
    Las cabeceras se propagan como metadata del chunk → útil para filtrado.
    Aplica un segundo split por tamaño para no generar chunks gigantes.

    Mejor para: documentación técnica, wikis, READMEs.
    """
    from langchain_text_splitters import (
        MarkdownHeaderTextSplitter,
        RecursiveCharacterTextSplitter,
    )

    raw_headers = cfg.get("headers_to_split_on", [["#", "h1"], ["##", "h2"], ["###", "h3"]])
    headers_to_split_on = [tuple(h) for h in raw_headers]

    header_splitter = MarkdownHeaderTextSplitter(
        headers_to_split_on=headers_to_split_on,
        strip_headers=cfg.get("strip_headers", False),
    )

    size_splitter = RecursiveCharacterTextSplitter(
        chunk_size=cfg.get("chunk_size", 1000),
        chunk_overlap=cfg.get("chunk_overlap", 100),
    )

    all_chunks = []
    for doc in docs:
        header_chunks = header_splitter.split_text(doc.page_content)
        for hc in header_chunks:
            hc.metadata = {**doc.metadata, **hc.metadata}
        sized_chunks = size_splitter.split_documents(header_chunks)
        all_chunks.extend(sized_chunks)

    print(f"  headers={[h[0] for h in headers_to_split_on]}  "
          f"chunk_size={cfg.get('chunk_size')}  overlap={cfg.get('chunk_overlap')}")
    return all_chunks


# ---------------------------------------------------------------------------
# 2c. Sentence Window Splitter
# ---------------------------------------------------------------------------

def _split_sentence_window(docs: List[Document], cfg: dict) -> List[Document]:
    """
    Divide el texto en frases individuales.
    Para cada frase guarda una ventana de N frases de contexto en metadata
    (campo 'window_context') que se inyecta al LLM en el prompt.

    Ventaja: el retriever trabaja con chunks pequeños y precisos;
             el LLM recibe más contexto gracias a la ventana.

    Mejor para: QA sobre hechos concretos, documentos densos en datos.
    """
    import nltk

    try:
        nltk.data.find("tokenizers/punkt_tab")
    except LookupError:
        nltk.download("punkt_tab", quiet=True)

    window_size = cfg.get("window_size", 3)
    all_chunks  = []

    for doc in docs:
        sentences = nltk.sent_tokenize(doc.page_content)

        for i, sentence in enumerate(sentences):
            start = max(0, i - window_size)
            end   = min(len(sentences), i + window_size + 1)
            window_context = " ".join(sentences[start:end])

            chunk = Document(
                page_content=sentence,
                metadata={
                    **doc.metadata,
                    "window_context": window_context,
                    "sentence_index": i,
                },
            )
            all_chunks.append(chunk)

    print(f"  window_size={window_size} (frases de contexto a cada lado)")
    return all_chunks


# ---------------------------------------------------------------------------
# 2d. Semantic Splitter
# ---------------------------------------------------------------------------

def _split_semantic(docs: List[Document], cfg: dict) -> List[Document]:
    """
    Agrupa frases consecutivas por similitud semántica usando embeddings.
    Abre un nuevo chunk cuando la distancia entre frases supera un umbral.

    Mejor para: textos narrativos, artículos, transcripciones.
    Requiere: pip install langchain-experimental
    """
    try:
        from langchain_experimental.text_splitter import SemanticChunker
    except ImportError as e:
        raise ImportError(
            "La estrategia 'semantic' requiere langchain-experimental.\n"
            "Instala con: pip install langchain-experimental"
        ) from e

    embeddings = get_embeddings()

    splitter = SemanticChunker(
        embeddings=embeddings,
        breakpoint_threshold_type=cfg.get("breakpoint_threshold_type", "percentile"),
        breakpoint_threshold_amount=cfg.get("breakpoint_threshold_amount", 90),
    )

    chunks = splitter.split_documents(docs)
    print(f"  threshold_type={cfg.get('breakpoint_threshold_type')}  "
          f"threshold_amount={cfg.get('breakpoint_threshold_amount')}")
    return chunks


# ---------------------------------------------------------------------------
# 2e. Parent Document Retriever
# ---------------------------------------------------------------------------

def _split_parent_document(
    docs: List[Document], cfg: dict
) -> Tuple[List[Document], List[Document]]:
    """
    Genera dos niveles de chunks:
      - Chunks hijo (pequeños) → se indexan en el vectorstore para retrieval preciso.
      - Chunks padre (grandes) → se recuperan y envían al LLM para dar más contexto.

    El id del padre se almacena en metadata["parent_id"] de cada chunk hijo,
    y build_vectorstore usa ese vínculo para devolver el padre en lugar del hijo.

    Mejor para: documentos largos donde necesitas precisión en la búsqueda
                pero contexto amplio para generar la respuesta.
    """
    from langchain_text_splitters import RecursiveCharacterTextSplitter
    import uuid

    parent_splitter = RecursiveCharacterTextSplitter(
        chunk_size=cfg.get("parent_chunk_size", 2000),
        chunk_overlap=cfg.get("parent_chunk_overlap", 200),
    )
    child_splitter = RecursiveCharacterTextSplitter(
        chunk_size=cfg.get("child_chunk_size", 400),
        chunk_overlap=cfg.get("child_chunk_overlap", 50),
    )

    parent_chunks = parent_splitter.split_documents(docs)
    child_chunks  = []

    for parent in parent_chunks:
        parent_id = str(uuid.uuid4())
        parent.metadata["doc_id"] = parent_id

        children = child_splitter.split_documents([parent])
        for child in children:
            child.metadata["parent_id"] = parent_id
        child_chunks.extend(children)

    print(f"  parent_chunk_size={cfg.get('parent_chunk_size')}  "
          f"child_chunk_size={cfg.get('child_chunk_size')}")

    return child_chunks, parent_chunks


# ---------------------------------------------------------------------------
# 2f. Proposition Chunking
# ---------------------------------------------------------------------------

def _split_proposition(docs: List[Document], cfg: dict) -> List[Document]:
    """
    Usa un LLM para descomponer cada chunk en proposiciones atómicas autocontenidas.

    Ejemplo: "Apple fue fundada en 1976 por Steve Jobs en California" →
      - "Apple fue fundada en 1976."
      - "Apple fue fundada por Steve Jobs."
      - "Apple fue fundada en California."

    Cada proposición tiene todo el contexto necesario para entenderse sola,
    lo que mejora mucho la precisión del retrieval semántico.

    Coste: hace llamadas al LLM durante la indexación (una por chunk base).
    Mejor para: documentos densos en hechos, bases de conocimiento, FAQs.
    """
    from langchain_text_splitters import RecursiveCharacterTextSplitter

    # Primero hacemos un split base para no mandar documentos enteros al LLM
    base_splitter = RecursiveCharacterTextSplitter(
        chunk_size=cfg.get("base_chunk_size", 1500),
        chunk_overlap=cfg.get("base_chunk_overlap", 100),
    )
    base_chunks = base_splitter.split_documents(docs)

    llm = ChatOpenAI(
        model=cfg.get("proposition_model", settings.LLM_MODEL),
        temperature=0,
        openai_api_key=settings.OPENAI_API_KEY,
    )

    proposition_prompt = ChatPromptTemplate.from_template(
        """Descompón el siguiente texto en proposiciones atómicas.
Cada proposición debe:
- Ser una frase corta e independiente (autocontenida).
- Contener todo el contexto necesario para entenderse sin leer el resto.
- Expresar un único hecho o idea.

Devuelve SOLO las proposiciones, una por línea, sin numeración ni guiones.

Texto:
{text}

Proposiciones:"""
    )

    proposition_chain = proposition_prompt | llm | StrOutputParser()

    all_propositions = []
    total = len(base_chunks)

    for i, chunk in enumerate(base_chunks, 1):
        print(f"  Generando proposiciones: chunk {i}/{total}", end="\r")
        try:
            raw = proposition_chain.invoke({"text": chunk.page_content})
            propositions = [p.strip() for p in raw.strip().split("\n") if p.strip()]

            for prop in propositions:
                all_propositions.append(
                    Document(
                        page_content=prop,
                        metadata={
                            **chunk.metadata,
                            "original_chunk": chunk.page_content[:200],
                            "proposition": True,
                        },
                    )
                )
        except Exception as e:
            # Si falla un chunk, lo incluimos tal cual para no perder contenido
            print(f"\n  ⚠️  Error en chunk {i}, usando chunk original: {e}")
            all_propositions.append(chunk)

    print(f"\n  base_chunk_size={cfg.get('base_chunk_size')}  "
          f"model={cfg.get('proposition_model', settings.LLM_MODEL)}")
    return all_propositions


# =============================================================================
# 3. EMBEDDINGS
# =============================================================================

def get_embeddings():
    return OpenAIEmbeddings(
        model=settings.EMBEDDING_MODEL,
        openai_api_key=settings.OPENAI_API_KEY,
    )


# =============================================================================
# 4. VECTORSTORE — backends
# =============================================================================

def _get_chroma(from_documents: bool, chunks: List[Document] = None,
                collection_name: str = None):
    from langchain_community.vectorstores import Chroma

    embeddings = get_embeddings()
    col_name = collection_name or settings.COLLECTION_NAME

    if from_documents:
        vs = Chroma.from_documents(
            documents=chunks,
            embedding=embeddings,
            persist_directory=settings.VECTORSTORE_PATH,
            collection_name=col_name,
        )
        print(f"[chroma] Vectorstore creado en: {settings.VECTORSTORE_PATH} (col: {col_name})")
    else:
        vs = Chroma(
            persist_directory=settings.VECTORSTORE_PATH,
            embedding_function=embeddings,
            collection_name=col_name,
        )
        print(f"[chroma] Vectorstore cargado desde: {settings.VECTORSTORE_PATH} (col: {col_name})")

    return vs


def _get_pgvector(from_documents: bool, chunks: List[Document] = None,
                  collection_name: str = None):
    from langchain_community.vectorstores import PGVector

    embeddings = get_embeddings()
    col_name = collection_name or settings.COLLECTION_NAME

    connection_string = PGVector.connection_string_from_db_params(
        driver="psycopg2",
        host=settings.RDS_HOST,
        port=settings.RDS_PORT,
        database=settings.RDS_DB,
        user=settings.RDS_USER,
        password=settings.RDS_PASSWORD,
    )

    if from_documents:
        vs = PGVector.from_documents(
            documents=chunks,
            embedding=embeddings,
            collection_name=col_name,
            connection_string=connection_string,
        )
        print(f"[pgvector] Indexado en RDS → {settings.RDS_HOST}/{settings.RDS_DB}")
    else:
        vs = PGVector(
            collection_name=col_name,
            connection_string=connection_string,
            embedding_function=embeddings,
        )
        print(f"[pgvector] Cargado desde RDS → {settings.RDS_HOST}/{settings.RDS_DB}")

    return vs


def _get_vectorstore(from_documents: bool, chunks: List[Document] = None,
                     collection_name: str = None):
    """Dispatcher interno que elige el backend configurado."""
    backend = settings.VECTORSTORE_BACKEND.lower()
    if backend == "chroma":
        return _get_chroma(from_documents, chunks, collection_name)
    elif backend == "pgvector":
        return _get_pgvector(from_documents, chunks, collection_name)
    else:
        raise ValueError(f"Backend desconocido: '{backend}'")


def build_vectorstore(chunks):
    """
    Crea o actualiza el vectorstore.
    Para parent_document, recibe una tupla (child_chunks, parent_chunks)
    e indexa los hijos en la colección principal y los padres en una colección
    auxiliar '<collection>_parents' para recuperarlos en tiempo de consulta.
    """
    if isinstance(chunks, tuple):
        # Estrategia parent_document
        child_chunks, parent_chunks = chunks

        # Indexar hijos (los que se buscan)
        _get_vectorstore(from_documents=True, chunks=child_chunks)

        # Guardar padres en colección separada (solo para recuperación, no para búsqueda)
        parent_col = settings.COLLECTION_NAME + "_parents"
        _get_vectorstore(from_documents=True, chunks=parent_chunks,
                         collection_name=parent_col)
        print(f"[parent_document] {len(child_chunks)} hijos + {len(parent_chunks)} padres indexados")
    else:
        _get_vectorstore(from_documents=True, chunks=chunks)


def load_vectorstore():
    """Carga el vectorstore de chunks hijos (el que se usa para búsqueda)."""
    return _get_vectorstore(from_documents=False)


def _load_parent_store():
    """Carga la colección de chunks padre (solo para parent_document)."""
    parent_col = settings.COLLECTION_NAME + "_parents"
    return _get_vectorstore(from_documents=False, collection_name=parent_col)


# =============================================================================
# 5. RETRIEVAL + LLM
# =============================================================================

PROMPT_TEMPLATE = """\
Eres un asistente útil. Responde la pregunta basándote únicamente en el siguiente contexto.
Si no puedes encontrar la respuesta en el contexto, di que no lo sabes.

Contexto:
{context}

Pregunta: {question}
"""

SENTENCE_WINDOW_PROMPT_TEMPLATE = """\
Eres un asistente útil. Responde la pregunta basándote únicamente en el siguiente contexto.
Si no puedes encontrar la respuesta en el contexto, di que no lo sabes.

Contexto (con ventana de frases adyacentes):
{context}

Pregunta: {question}
"""


def build_qa_chain(vectorstore) -> Tuple:
    """
    Monta la cadena RAG con LCEL.
    Cada estrategia de chunking puede tener su propia lógica de recuperación:
      - sentence_window → expande el contexto con la ventana almacenada en metadata
      - parent_document → sustituye el chunk hijo por su chunk padre antes de pasar al LLM
      - el resto        → comportamiento estándar
    """
    strategy = settings.CHUNKING_STRATEGY

    base_retriever = vectorstore.as_retriever(
        search_type=settings.RETRIEVER_SEARCH_TYPE,
        search_kwargs={
            "k": settings.RETRIEVER_K,
            "fetch_k": settings.RETRIEVER_FETCH_K,
            **(
                {"score_threshold": settings.RETRIEVER_SCORE_THRESHOLD}
                if settings.RETRIEVER_SEARCH_TYPE == "similarity_score_threshold"
                else {}
            ),
        },
    )

    llm = ChatOpenAI(
        model=settings.LLM_MODEL,
        temperature=settings.LLM_TEMPERATURE,
        max_tokens=settings.LLM_MAX_TOKENS,
        openai_api_key=settings.OPENAI_API_KEY,
    )

    # -- Selección de prompt según estrategia --
    use_window = strategy == "sentence_window"
    prompt = ChatPromptTemplate.from_template(
        SENTENCE_WINDOW_PROMPT_TEMPLATE if use_window else PROMPT_TEMPLATE
    )

    # -- Función de formateo de contexto según estrategia --
    if strategy == "sentence_window":
        def format_docs(docs: List[Document]) -> str:
            return "\n\n".join(
                doc.metadata.get("window_context", doc.page_content) for doc in docs
            )

    elif strategy == "parent_document":
        # Cargamos la colección de padres para hacer el swap hijo → padre
        parent_store = _load_parent_store()
        parent_docs_map = {
            doc.metadata["doc_id"]: doc
            for doc in parent_store.get()["documents"]  # type: ignore
        } if hasattr(parent_store, "get") else {}

        def format_docs(docs: List[Document]) -> str:
            expanded = []
            for child in docs:
                parent_id = child.metadata.get("parent_id")
                parent = parent_docs_map.get(parent_id)
                # Si encontramos el padre usamos su contenido, si no el hijo
                expanded.append(parent.page_content if parent else child.page_content)
            return "\n\n".join(expanded)

    else:
        def format_docs(docs: List[Document]) -> str:
            return "\n\n".join(doc.page_content for doc in docs)

    chain = (
        {"context": base_retriever | format_docs, "question": RunnablePassthrough()}
        | prompt
        | llm
        | StrOutputParser()
    )

    return chain, base_retriever


# =============================================================================
# 6. CONSULTA
# =============================================================================

def query(chain_and_retriever: Tuple, question: str) -> dict:
    """
    Lanza una pregunta al sistema RAG y devuelve respuesta + fuentes.
    """
    chain, retriever = chain_and_retriever

    source_docs = retriever.invoke(question)
    answer      = chain.invoke(question)

    fragment_len = settings.LOG_MAX_FRAGMENT_LENGTH
    strategy     = settings.CHUNKING_STRATEGY

    sources = []
    for doc in source_docs:
        entry = {
            "source":   doc.metadata.get("source", "desconocido"),
            "fragment": doc.page_content[:fragment_len] + "...",
        }
        # Metadata extra según estrategia
        if strategy == "markdown_header":
            entry["headers"] = {k: v for k, v in doc.metadata.items()
                                 if k in ("h1", "h2", "h3")}
        elif strategy == "proposition":
            entry["original_chunk"] = doc.metadata.get("original_chunk", "")
        elif strategy == "parent_document":
            entry["parent_id"] = doc.metadata.get("parent_id", "")

        sources.append(entry)

    return {
        "question":          question,
        "answer":            answer,
        "sources":           sources,
        "chunking_strategy": strategy,
    }
