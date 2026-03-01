"""
Interfaz Streamlit para el sistema RAG en AWS.
Conecta directamente a RDS pgvector usando el mismo pipeline.py.
Lee la configuración de DB desde .rag-deployment-config o variables de entorno.

Ejecutar: streamlit run app.py --server.port=8501 --server.address=0.0.0.0
"""

import os
import streamlit as st
from pathlib import Path

# ---------------------------------------------------------------------------
# Cargar variables de conexión desde .rag-deployment-config si existen
# (el archivo lo genera deploy_rag.sh automáticamente)
# ---------------------------------------------------------------------------
_config_file = Path(__file__).parent / ".rag-deployment-config"
if _config_file.exists():
    for line in _config_file.read_text().splitlines():
        if "=" in line and not line.startswith("#"):
            k, v = line.split("=", 1)
            # Solo setear si no está ya en el entorno
            os.environ.setdefault(k.strip(), v.strip())

# ---------------------------------------------------------------------------
# Validar que tenemos lo mínimo para arrancar
# ---------------------------------------------------------------------------
_missing = [v for v in ("DB_HOST", "DB_NAME", "DB_USER", "DB_PASSWORD", "OPENAI_API_KEY")
            if not os.environ.get(v)]

# ── Configuración de página ───────────────────────────────────────────────────
st.set_page_config(
    page_title="RAG Chatbot",
    page_icon="🤖",
    layout="centered",
)

st.title("🤖 RAG Chatbot")
st.caption("Haz preguntas sobre los documentos indexados en AWS.")

if _missing:
    st.error(f"❌ Faltan variables de entorno: {', '.join(_missing)}")
    st.info("Asegúrate de que `.rag-deployment-config` está en el mismo directorio que `app.py`, "
            "o define las variables de entorno manualmente.")
    st.stop()

# ── Importar pipeline (funciona tanto en EC2 como en local) ──────────────────
try:
    from rag.pipeline import load_vectorstore, build_qa_chain, query as rag_query
except ImportError:
    from pipeline import load_vectorstore, build_qa_chain, query as rag_query

# ── Cargar pipeline (una sola vez por sesión) ─────────────────────────────────
@st.cache_resource(show_spinner="Conectando con la base de conocimiento…")
def get_chain():
    vectorstore = load_vectorstore()
    return build_qa_chain(vectorstore)

try:
    chain_and_retriever = get_chain()
except Exception as e:
    st.error(f"❌ No se pudo conectar con RDS pgvector: {e}")
    st.info("Comprueba que la base de datos está inicializada y que los parámetros de conexión son correctos.")
    st.stop()

# ── Historial de mensajes ─────────────────────────────────────────────────────
if "messages" not in st.session_state:
    st.session_state.messages = []

for msg in st.session_state.messages:
    with st.chat_message(msg["role"]):
        st.markdown(msg["content"])
        if msg.get("sources"):
            with st.expander("📄 Fuentes utilizadas", expanded=False):
                for i, src in enumerate(msg["sources"], 1):
                    st.markdown(f"**{i}. `{src['source']}`**")
                    st.caption(f"> {src['fragment']}")

# ── Input del usuario ─────────────────────────────────────────────────────────
if question := st.chat_input("Escribe tu pregunta…"):
    st.session_state.messages.append({"role": "user", "content": question})
    with st.chat_message("user"):
        st.markdown(question)

    with st.chat_message("assistant"):
        with st.spinner("Consultando la base de conocimiento…"):
            try:
                result = rag_query(chain_and_retriever, question)
                answer  = result["answer"]
                sources = result["sources"]
            except Exception as e:
                answer  = f"❌ Error al procesar la consulta: {e}"
                sources = []

        st.markdown(answer)
        if sources:
            with st.expander("📄 Fuentes utilizadas", expanded=False):
                for i, src in enumerate(sources, 1):
                    st.markdown(f"**{i}. `{src['source']}`**")
                    st.caption(f"> {src['fragment']}")

    st.session_state.messages.append({
        "role": "assistant",
        "content": answer,
        "sources": sources,
    })

# ── Sidebar ───────────────────────────────────────────────────────────────────
with st.sidebar:
    st.header("⚙️ Conexión")
    st.code(os.environ.get("DB_HOST", "—"), language=None)
    st.caption("RDS endpoint activo")

# ── Limpiar chat ──────────────────────────────────────────────────────────────
if st.session_state.messages:
    if st.button("🗑️ Limpiar conversación", use_container_width=True):
        st.session_state.messages = []
        st.rerun()
