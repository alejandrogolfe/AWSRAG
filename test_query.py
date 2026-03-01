#!/usr/bin/env python3
"""
Script para probar el sistema RAG
Usa la Lambda query API para hacer preguntas sobre los documentos
"""

import requests
import json
import sys
import os


def load_config():
    """Lee la configuración del archivo .rag-deployment-config"""
    config = {}
    config_file = '.rag-deployment-config'

    if not os.path.exists(config_file):
        print(f"❌ Error: No se encontró el archivo {config_file}")
        print(f"   Ejecuta primero ./deploy_rag.sh para crear la configuración")
        sys.exit(1)

    try:
        with open(config_file, 'r') as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith('#') and '=' in line:
                    key, value = line.split('=', 1)
                    config[key] = value

        return config
    except Exception as e:
        print(f"❌ Error leyendo configuración: {e}")
        sys.exit(1)


# Cargar configuración
CONFIG = load_config()
API_URL = CONFIG.get('QUERY_API_URL')

if not API_URL:
    print("❌ Error: QUERY_API_URL no encontrada en .rag-deployment-config")
    sys.exit(1)


def ask_question(question):
    """Envía una pregunta al RAG y muestra la respuesta"""

    print(f"\n{'=' * 80}")
    print(f"PREGUNTA: {question}")
    print(f"{'=' * 80}\n")

    payload = {
        "question": question
    }

    try:
        response = requests.post(
            API_URL,
            json=payload,
            headers={"Content-Type": "application/json"},
            timeout=60
        )

        response.raise_for_status()
        result = response.json()

        # Mostrar respuesta
        print(f"RESPUESTA:\n{result.get('answer', 'No answer')}\n")

        # Mostrar fuentes
        sources = result.get('sources', [])
        if sources:
            print(f"FUENTES ({len(sources)}):")
            for i, source in enumerate(sources, 1):
                filename = source.get('filename', 'Unknown')
                similarity = source.get('similarity', 0)
                print(f"  {i}. {filename} (similitud: {similarity:.2%})")

        print(f"\n{'=' * 80}\n")
        return result

    except requests.exceptions.RequestException as e:
        print(f"❌ Error de red: {e}")
        return None
    except json.JSONDecodeError as e:
        print(f"❌ Error decodificando JSON: {e}")
        print(f"Respuesta raw: {response.text}")
        return None
    except Exception as e:
        print(f"❌ Error inesperado: {e}")
        return None


def main():
    """Ejecuta preguntas de prueba"""

    print("🤖 Sistema RAG - Test de Consultas")
    print(f"📁 Proyecto: {CONFIG.get('PROJECT_NAME', 'N/A')}")
    print(f"🌍 Región: {CONFIG.get('AWS_REGION', 'N/A')}")
    print(f"🔗 API: {API_URL}\n")

    # Preguntas de ejemplo
    preguntas = [
        "¿De qué tratan los documentos?",
        "Resume el contenido principal",
        "¿Qué información relevante contienen?",
    ]

    # Si se pasa una pregunta por línea de comandos, usarla
    if len(sys.argv) > 1:
        pregunta_custom = " ".join(sys.argv[1:])
        preguntas = [pregunta_custom]

    # Hacer las preguntas
    for pregunta in preguntas:
        ask_question(pregunta)

        # Pequeña pausa entre preguntas
        if len(preguntas) > 1:
            input("Presiona Enter para siguiente pregunta...")


if __name__ == "__main__":
    main()