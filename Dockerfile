FROM amazon/aws-lambda-python:3.11

COPY requirements.txt .
COPY .env .env
RUN pip install --no-cache-dir -r requirements.txt --target "${LAMBDA_TASK_ROOT}"

COPY . ${LAMBDA_TASK_ROOT}

CMD ["main.lambda_handler"]
