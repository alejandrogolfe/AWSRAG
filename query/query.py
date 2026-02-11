import json
import boto3
import os
import psycopg2
from psycopg2.extras import RealDictCursor

bedrock = boto3.client('bedrock-runtime', region_name=os.environ.get('AWS_REGION', 'us-east-1'))

# Database connection parameters from environment
DB_HOST = os.environ['DB_HOST']
DB_NAME = os.environ['DB_NAME']
DB_USER = os.environ['DB_USER']
DB_PASSWORD = os.environ['DB_PASSWORD']


def get_db_connection():
    """Create database connection"""
    return psycopg2.connect(
        host=DB_HOST,
        database=DB_NAME,
        user=DB_USER,
        password=DB_PASSWORD,
        port=5432
    )


def get_embedding(text):
    """Generate embedding using Bedrock Titan Embeddings"""
    body = json.dumps({
        "inputText": text
    })
    
    response = bedrock.invoke_model(
        modelId='amazon.titan-embed-text-v2:0',
        body=body,
        contentType='application/json',
        accept='application/json'
    )
    
    response_body = json.loads(response['body'].read())
    return response_body['embedding']


def similarity_search(query_embedding, top_k=5):
    """Perform vector similarity search in Postgres"""
    conn = get_db_connection()
    cursor = conn.cursor(cursor_factory=RealDictCursor)
    
    # Convert embedding to PostgreSQL vector format
    embedding_str = '[' + ','.join(map(str, query_embedding)) + ']'
    
    # Query using cosine distance (<=> operator)
    cursor.execute(
        """
        SELECT 
            chunk_text,
            filename,
            chunk_index,
            1 - (embedding <=> %s::vector) as similarity
        FROM embeddings
        ORDER BY embedding <=> %s::vector
        LIMIT %s
        """,
        (embedding_str, embedding_str, top_k)
    )
    
    results = cursor.fetchall()
    cursor.close()
    conn.close()
    
    return results


def query_claude(question, context_chunks):
    """Query Claude with retrieved context"""
    
    # Build context from retrieved chunks
    context = "\n\n".join([
        f"[Documento: {chunk['filename']}, Fragmento {chunk['chunk_index']}]\n{chunk['chunk_text']}"
        for chunk in context_chunks
    ])
    
    # Build prompt
    prompt = f"""Eres un asistente que responde preguntas basándose únicamente en el contexto proporcionado.

Contexto:
{context}

Pregunta: {question}

Instrucciones:
- Responde SOLO basándote en la información del contexto
- Si la respuesta no está en el contexto, di "No tengo información suficiente para responder esa pregunta"
- Cita el documento fuente cuando sea relevante
- Sé conciso y preciso

Respuesta:"""
    
    # Call Bedrock Claude
    body = json.dumps({
        "anthropic_version": "bedrock-2023-05-31",
        "max_tokens": 2000,
        "temperature": 0.1,
        "messages": [
            {
                "role": "user",
                "content": prompt
            }
        ]
    })
    
    response = bedrock.invoke_model(
        modelId='anthropic.claude-3-5-sonnet-20241022-v2:0',
        body=body,
        contentType='application/json',
        accept='application/json'
    )
    
    response_body = json.loads(response['body'].read())
    return response_body['content'][0]['text']


def lambda_handler(event, context):
    """Main Lambda handler for RAG queries"""
    try:
        # Parse request body
        if 'body' in event:
            body = json.loads(event['body']) if isinstance(event['body'], str) else event['body']
        else:
            body = event
        
        question = body.get('question')
        top_k = body.get('top_k', 5)
        
        if not question:
            return {
                'statusCode': 400,
                'body': json.dumps({'error': 'Missing required field: question'})
            }
        
        print(f"Question: {question}")
        
        # Generate embedding for the question
        print("Generating question embedding...")
        query_embedding = get_embedding(question)
        
        # Perform similarity search
        print(f"Searching for top {top_k} similar chunks...")
        context_chunks = similarity_search(query_embedding, top_k)
        
        print(f"Found {len(context_chunks)} relevant chunks")
        for chunk in context_chunks:
            print(f"  - {chunk['filename']} (similarity: {chunk['similarity']:.3f})")
        
        # Query Claude with context
        print("Querying Claude with context...")
        answer = query_claude(question, context_chunks)
        
        # Return response
        return {
            'statusCode': 200,
            'headers': {
                'Content-Type': 'application/json',
                'Access-Control-Allow-Origin': '*'
            },
            'body': json.dumps({
                'question': question,
                'answer': answer,
                'sources': [
                    {
                        'filename': chunk['filename'],
                        'chunk_index': chunk['chunk_index'],
                        'similarity': float(chunk['similarity'])
                    }
                    for chunk in context_chunks
                ]
            }, ensure_ascii=False)
        }
        
    except Exception as e:
        print(f"Error processing query: {str(e)}")
        return {
            'statusCode': 500,
            'body': json.dumps({'error': str(e)})
        }
