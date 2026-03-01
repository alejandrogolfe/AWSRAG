"""
Lambda handler — Processor
Se dispara cuando se sube un documento a S3 (docs/).
Descarga el archivo, lo procesa con el pipeline RAG y lo indexa en RDS pgvector.
"""

import os
import json
import tempfile
import urllib.parse
import boto3

# Las variables de entorno las inyecta deploy_rag.sh en la Lambda:
#   DB_HOST, DB_NAME, DB_USER, DB_PASSWORD
#   OPENAI_API_KEY
#   CHUNKING_STRATEGY (opcional, default: recursive)
#   COLLECTION_NAME   (opcional, default: rag_docs)


def handler(event, context):
    """Punto de entrada de la Lambda."""
    print(f"Evento recibido: {json.dumps(event)}")

    s3 = boto3.client("s3")

    # Puede venir un batch de registros S3
    for record in event.get("Records", []):
        bucket = record["s3"]["bucket"]["name"]
        key    = urllib.parse.unquote_plus(record["s3"]["object"]["key"])

        print(f"Procesando: s3://{bucket}/{key}")

        # Ignorar carpetas y archivos no soportados
        if key.endswith("/"):
            print(f"Ignorando carpeta: {key}")
            continue

        ext = os.path.splitext(key)[1].lower()
        if ext not in (".txt", ".md", ".pdf"):
            print(f"Extensión no soportada: {ext} — ignorando {key}")
            continue

        # Descargar el archivo a /tmp (único directorio escribible en Lambda)
        with tempfile.TemporaryDirectory() as tmpdir:
            local_path = os.path.join(tmpdir, os.path.basename(key))
            print(f"Descargando a {local_path}...")
            s3.download_file(bucket, key, local_path)

            # Procesar con el pipeline
            _process_document(local_path)

    return {"statusCode": 200, "body": "OK"}


def _process_document(local_path: str):
    """Carga, trocea e indexa un único documento."""
    # Importamos aquí para que el cold start no falle si hay algún problema de config
    from pipeline import load_documents, split_documents, build_vectorstore

    print(f"Cargando documento: {local_path}")
    docs = load_documents(os.path.dirname(local_path))

    if not docs:
        print(f"⚠️  No se pudieron cargar documentos desde {local_path}")
        return

    print(f"Dividiendo en chunks...")
    chunks = split_documents(docs)

    print(f"Indexando en pgvector...")
    build_vectorstore(chunks)

    n = len(chunks) if not isinstance(chunks, tuple) else len(chunks[0])
    print(f"✅ Indexado correctamente: {n} chunks")
