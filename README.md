# 🤖 RAG System with AWS Bedrock + Aurora PostgreSQL

Complete **Retrieval-Augmented Generation (RAG)** system that lets you ask questions about your documents using Claude from Bedrock. The system automatically processes documents when you upload them to S3 and maintains a synchronized vector database.

---

## 🎯 What does it do?

1. **You upload a document** (PDF, DOCX, TXT) to S3
2. **Lambda Processor** automatically:
   - Extracts the text
   - Splits it into chunks
   - Generates embeddings with **Bedrock Titan Embeddings**
   - Stores them in **Aurora Postgres + pgvector**
3. **You ask a question** via API
4. **Lambda Query** automatically:
   - Converts your question into an embedding
   - Searches for the most relevant chunks (similarity search)
   - Passes the context to **Claude (Bedrock)**
   - Claude responds based ONLY on your documents

---

## 🏗️ Architecture

```
┌─────────────┐
│ S3 (docs/)  │
└──────┬──────┘
       │ upload event
       ▼
┌─────────────────────┐
│ Lambda Processor    │
│ - Extract text      │
│ - Chunking          │
│ - Bedrock Embeddings│
└──────┬──────────────┘
       │ INSERT
       ▼
┌─────────────────────┐      ┌──────────────┐
│ Aurora Postgres     │◄─────│ Query API    │
│ + pgvector          │      │ (Lambda)     │
│ (Vector DB)         │      │              │
└─────────────────────┘      └──────┬───────┘
                                    │
                                    ▼
                             ┌──────────────┐
                             │ Bedrock      │
                             │ Claude 3.5   │
                             └──────────────┘
```

### Components

| Component | Purpose |
|---|---|
| **S3** | Document storage (`docs/`) |
| **Lambda Processor** | Automatic processing: chunking + embeddings |
| **Aurora Serverless v2** | Vector database (Postgres + pgvector) |
| **Lambda Query API** | REST endpoint for asking questions |
| **Bedrock Titan** | Embedding generation (vectors) |
| **Bedrock Claude** | LLM to answer questions with context |

---

## 🚀 Deployment

### Prerequisites
- AWS CLI configured
- Docker installed
- AWS account with Bedrock access (enable Claude and Titan models in your region)

### Enable models in Bedrock
```
AWS Console → Bedrock → Model access → Request access:
  ✓ Claude 3.5 Sonnet v2
  ✓ Titan Embeddings v2
```

### Deploy
```bash
cd rag
chmod +x deploy_rag.sh
./deploy_rag.sh
```

**Estimated time:** 10-15 minutes (Aurora takes ~5min to create)

The script creates:
- ✅ S3 bucket for documents
- ✅ Aurora Postgres Serverless v2 with pgvector
- ✅ 2 Lambdas (processor + query) as container images
- ✅ IAM roles with least-privilege permissions
- ✅ S3 event trigger
- ✅ Public Function URL for the API

---

## 📚 Usage

### 1. Upload documents
```bash
# Upload a PDF
aws s3 cp document.pdf s3://rag-system-docs/docs/document.pdf

# Upload multiple files
aws s3 cp folder/ s3://rag-system-docs/docs/ --recursive
```

**Supported formats:** PDF, DOCX, TXT

### 2. Monitor processing
```bash
# View processor logs
aws logs tail /aws/lambda/rag-system-processor --follow

# You should see:
# Processing file: s3://rag-system-docs/docs/document.pdf
# Extracted 15000 characters
# Created 23 chunks
# Processing chunk 1/23
# Successfully processed 23 chunks
```

### 3. Ask questions

The deploy gives you a **Function URL** (saved in `.rag-deployment-config`):

```bash
# Via curl
curl -X POST https://[your-function-url].lambda-url.eu-west-1.on.aws/ \
  -H 'Content-Type: application/json' \
  -d '{"question": "What is the main topic of the document?"}'

# Via Python
import requests
response = requests.post(
    'https://[your-function-url].lambda-url.eu-west-1.on.aws/',
    json={'question': 'What does it say about pricing?'}
)
print(response.json()['answer'])
```

**Response:**
```json
{
  "question": "What is the main topic?",
  "answer": "Based on the provided context, the document discusses...",
  "sources": [
    {
      "filename": "docs/document.pdf",
      "chunk_index": 3,
      "similarity": 0.87
    }
  ]
}
```

### 4. Update documents

If you upload a file with the **same name but different content**, the system:
- ✅ Detects the change (MD5 hash)
- ✅ Deletes old chunks
- ✅ Processes and stores new ones
- ✅ RAG updates automatically

---

## 🔧 Advanced configuration

### Change chunk size
Edit `processor/processor.py`:
```python
def chunk_text(text, chunk_size=1000, chunk_overlap=200):  # ← adjust here
```

### Change number of retrieved chunks
Edit `query/query.py`:
```python
def similarity_search(query_embedding, top_k=5):  # ← adjust top_k
```

Or pass in the request:
```bash
curl -X POST [url] -d '{"question": "...", "top_k": 10}'
```

### Change Claude model
Edit `query/query.py`:
```python
modelId='anthropic.claude-3-5-sonnet-20241022-v2:0'  # ← change model
```

---

## 💾 Direct database access

```bash
# Connect with psql
psql -h [DB_ENDPOINT] -U ragadmin -d ragdb

# View all processed documents
SELECT filename, chunk_count FROM processed_files;

# View chunks from a document
SELECT chunk_index, LEFT(chunk_text, 100) 
FROM embeddings 
WHERE filename = 'docs/document.pdf' 
ORDER BY chunk_index;

# Manual similarity search
SELECT chunk_text, 1 - (embedding <=> '[0.1,0.2,...]'::vector) as similarity
FROM embeddings
ORDER BY embedding <=> '[0.1,0.2,...]'::vector
LIMIT 5;
```

---

## 📊 Estimated costs

For **1000 documents processed** + **1000 queries/month**:

| Service | Approx. cost |
|---|---|
| Aurora Serverless v2 (0.5 ACU minimum) | ~$43/month |
| Lambda processor (900s timeout, 1GB) | ~$2 |
| Lambda query (60s average, 512MB) | ~$0.50 |
| Bedrock Titan Embeddings | ~$0.13 (1M input tokens) |
| Bedrock Claude 3.5 Sonnet | ~$15 (500k in, 100k out) |
| **TOTAL** | **~$60/month** |

---

## 🧹 Cleanup

```bash
chmod +x clean_rag.sh
./clean_rag.sh
```

**⚠️ WARNING:** This deletes EVERYTHING (S3, Lambda, Aurora, roles). Data is not recoverable.

---

## 🎓 Educational aspects

This project lets you learn:

1. **Vector embeddings** - How texts are converted to numerical vectors
2. **Similarity search** - Cosine distance search in vector space
3. **RAG pattern** - Retrieval-Augmented Generation from scratch
4. **Event-driven architecture** - S3 events → Lambda triggers
5. **Serverless databases** - Aurora Serverless v2 + pgvector
6. **Container images in Lambda** - How to package heavy dependencies
7. **Bedrock integration** - Using foundation models (Titan, Claude)

Each component is inspectable and modifiable for experimentation.

---

## 🔍 Debugging

### Lambda doesn't trigger
```bash
# Verify S3 trigger
aws s3api get-bucket-notification-configuration --bucket rag-system-docs

# Verify permissions
aws lambda get-policy --function-name rag-system-processor
```

### Database connection error
```bash
# Verify Lambda is in correct VPC
aws lambda get-function-configuration --function-name rag-system-processor

# Verify security group allows port 5432
aws ec2 describe-security-groups --group-ids [SG_ID]
```

### Embeddings not generated
```bash
# Verify Bedrock access
aws bedrock list-foundation-models --region eu-west-1

# View detailed logs
aws logs tail /aws/lambda/rag-system-processor --follow --format short
```

---

## 📖 References

- [pgvector Documentation](https://github.com/pgvector/pgvector)
- [Bedrock User Guide](https://docs.aws.amazon.com/bedrock/)
- [Aurora Serverless v2](https://docs.aws.amazon.com/AmazonRDS/latest/AuroraUserGuide/aurora-serverless-v2.html)
