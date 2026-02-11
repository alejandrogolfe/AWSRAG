FROM public.ecr.aws/lambda/python:3.12

# Copy requirements and install dependencies
COPY requirements.txt ${LAMBDA_TASK_ROOT}
RUN pip install --no-cache-dir -r requirements.txt

# Copy function code
COPY query.py ${LAMBDA_TASK_ROOT}

# Set the CMD to your handler
CMD ["query.lambda_handler"]
