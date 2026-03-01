"""
Punto de entrada del sistema RAG.

Modos de uso:
  python main.py index               → indexa los documentos del directorio docs/
  python main.py query "pregunta"    → lanza una consulta al vectorstore existente
  python main.py reindex "pregunta"  → reindexa y lanza consulta
"""

import sys
import json
import config as settings
from rag.pipeline import (
    load_documents,
    split_documents,
    build_vectorstore,
    load_vectorstore,
    build_qa_chain,
    query,
)

import os
for root, dirs, files in os.walk("/app/web_scrapper/rag_data"):
    for f in files:
        print(os.path.join(root, f))


def cmd_index():
    """Carga documentos, genera chunks y construye el vectorstore."""
    print(f"\n{'='*50}")
    print(f"Indexando documentos desde: {settings.DOCS_DIR}")
    print(f"{'='*50}\n")

    docs = load_documents(settings.DOCS_DIR)
    if not docs:
        print("⚠️  No se encontraron documentos. Comprueba el directorio 'docs/'.")
        sys.exit(1)

    chunks = split_documents(docs)
    build_vectorstore(chunks)

    print("\n✅ Indexación completada.")


def cmd_query(question: str):
    """Carga el vectorstore existente y responde una pregunta."""
    print(f"\n{'='*50}")
    print(f"Pregunta: {question}")
    print(f"{'='*50}\n")

    vectorstore = load_vectorstore()
    chain_and_retriever = build_qa_chain(vectorstore)
    result = query(chain_and_retriever, question)

    print(f"\n💬 Respuesta:\n{result['answer']}\n")
    print("📄 Fuentes utilizadas:")
    for i, src in enumerate(result["sources"], 1):
        print(f"  {i}. {src['source']}")
        print(f"     \"{src['fragment']}\"")

    return result


def cmd_reindex(question: str):
    """Reindexa y después lanza la consulta."""
    cmd_index()
    cmd_query(question)


def interactive_mode():
    """Modo interactivo: el usuario escribe preguntas en bucle."""
    print("\n🤖 Modo interactivo RAG (escribe 'salir' para terminar)\n")
    vectorstore = load_vectorstore()
    chain_and_retriever = build_qa_chain(vectorstore)

    while True:
        try:
            question = input("Pregunta > ").strip()
        except (KeyboardInterrupt, EOFError):
            print("\n👋 Hasta luego.")
            break

        if question.lower() in ("salir", "exit", "quit"):
            print("👋 Hasta luego.")
            break

        if not question:
            continue

        result = query(chain_and_retriever, question)
        print(f"\n💬 {result['answer']}\n")
        for src in result["sources"]:
            print(f"   📎 {src['source']}")
        print()


if __name__ == "__main__":
    args = sys.argv[1:]

    if not args:
        interactive_mode()

    elif args[0] == "index":
        cmd_index()

    elif args[0] == "query":
        if len(args) < 2:
            print("Uso: python main.py query \"tu pregunta aquí\"")
            sys.exit(1)
        cmd_query(args[1])

    elif args[0] == "reindex":
        question = args[1] if len(args) > 1 else ""
        if not question:
            print("Uso: python main.py reindex \"tu pregunta aquí\"")
            sys.exit(1)
        cmd_reindex(question)

    else:
        print(__doc__)
        sys.exit(1)
