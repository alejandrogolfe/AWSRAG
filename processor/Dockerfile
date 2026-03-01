FROM public.ecr.aws/lambda/python:3.11

# Dependencias del sistema para psycopg2 y procesado de PDFs
RUN yum install -y gcc postgresql-devel poppler-utils libmagic && yum clean all

# Copiar requirements e instalar
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copiar el código del pipeline RAG
COPY handler.py       ${LAMBDA_TASK_ROOT}/
COPY pipeline.py      ${LAMBDA_TASK_ROOT}/
COPY config.py        ${LAMBDA_TASK_ROOT}/
COPY setup.yaml       ${LAMBDA_TASK_ROOT}/

CMD ["handler.handler"]
