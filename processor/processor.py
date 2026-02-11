import json
import boto3
import hashlib
import os
import io
import psycopg2
from psycopg2.extras import execute_values
from langchain.text_splitter import RecursiveCharacterTextSplitter
import PyPDF2
import docx

s3 = boto3.client('s3')
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


def extract_text(file_obj, filename):
    """Extract text from different file types"""
    file_lower = filename.lower()
    
    if file_lower.endswith('.pdf'):
        return extract_pdf(file_obj)
    elif file_lower.endswith('.docx'):
        return extract_docx(file_obj)
    elif file_lower.endswith('.txt'):
        return file_obj.read().decode('utf-8')
    else:
        raise ValueError(f"Unsupported file type: {filename}")


def extract_pdf(file_obj):
    """Extract text from PDF"""
    pdf_reader = PyPDF2.PdfReader(io.BytesIO(file_obj.read()))
    text = ""
    for page in pdf_reader.pages:
        text += page.extract_text() + "\n"
    return text


def extract_docx(file_obj):
    """Extract text from DOCX"""
    doc = docx.Document(io.BytesIO(file_obj.read()))
    text = ""
    for paragraph in doc.paragraphs:
        text += paragraph.text + "\n"
    return text


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


def chunk_text(text, chunk_size=1000, chunk_overlap=200):
    """Split text into chunks"""
    splitter = RecursiveCharacterTextSplitter(
        chunk_size=chunk_size,
        chunk_overlap=chunk_overlap,
        separators=["\n\n", "\n", ". ", " ", ""]
    )
    return splitter.split_text(text)


def lambda_handler(event, context):
    """Main Lambda handler"""
    try:
        # Extract S3 event information
        bucket = event['Records'][0]['s3']['bucket']['name']
        key = event['Records'][0]['s3']['object']['key']
        
        print(f"Processing file: s3://{bucket}/{key}")
        
        # Download file from S3
        response = s3.get_object(Bucket=bucket, Key=key)
        file_content = response['Body']
        
        # Calculate file hash
        file_bytes = s3.get_object(Bucket=bucket, Key=key)['Body'].read()
        file_hash = hashlib.md5(file_bytes).hexdigest()
        
        # Connect to database
        conn = get_db_connection()
        cursor = conn.cursor()
        
        # Check if file already processed with same hash
        cursor.execute(
            "SELECT file_hash FROM processed_files WHERE filename = %s",
            (key,)
        )
        result = cursor.fetchone()
        
        if result and result[0] == file_hash:
            print(f"File {key} already processed with same hash. Skipping.")
            cursor.close()
            conn.close()
            return {
                'statusCode': 200,
                'body': json.dumps('File already processed')
            }
        
        # Extract text from file
        print("Extracting text...")
        response = s3.get_object(Bucket=bucket, Key=key)
        text = extract_text(response['Body'], key)
        
        print(f"Extracted {len(text)} characters")
        
        # Chunk the text
        print("Chunking text...")
        chunks = chunk_text(text)
        print(f"Created {len(chunks)} chunks")
        
        # Process each chunk: generate embedding and store
        print("Generating embeddings and storing...")
        embeddings_data = []
        
        for i, chunk in enumerate(chunks):
            print(f"Processing chunk {i+1}/{len(chunks)}")
            
            # Generate embedding
            embedding = get_embedding(chunk)
            
            # Prepare data for batch insert
            embeddings_data.append((
                chunk,
                embedding,
                key,
                i,
                file_hash
            ))
        
        # Delete old chunks if file was re-uploaded
        cursor.execute("DELETE FROM embeddings WHERE filename = %s", (key,))
        
        # Batch insert embeddings
        execute_values(
            cursor,
            """
            INSERT INTO embeddings (chunk_text, embedding, filename, chunk_index, file_hash)
            VALUES %s
            """,
            embeddings_data,
            template="(%s, %s::vector, %s, %s, %s)"
        )
        
        # Update processed_files table
        cursor.execute(
            """
            INSERT INTO processed_files (filename, file_hash, chunk_count)
            VALUES (%s, %s, %s)
            ON CONFLICT (filename) 
            DO UPDATE SET file_hash = EXCLUDED.file_hash, 
                          processed_at = NOW(),
                          chunk_count = EXCLUDED.chunk_count
            """,
            (key, file_hash, len(chunks))
        )
        
        conn.commit()
        cursor.close()
        conn.close()
        
        print(f"Successfully processed {len(chunks)} chunks from {key}")
        
        return {
            'statusCode': 200,
            'body': json.dumps({
                'message': 'File processed successfully',
                'filename': key,
                'chunks': len(chunks)
            })
        }
        
    except Exception as e:
        print(f"Error processing file: {str(e)}")
        raise
