# syntax=docker/dockerfile:1
# Scenario 1 MySQL Orders refresh pipeline (runs as an hourly CronJob).
# Build from the repo root:  docker build -f Scenario3/docker/mysql-loader/Dockerfile -t mysql-loader .
FROM python:3.12-slim
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates && rm -rf /var/lib/apt/lists/*
WORKDIR /app
RUN pip install --no-cache-dir "pymysql>=1.1" "azure-identity>=1.17" "azure-storage-blob>=12.20"
COPY Scenario1/pipelines/mysql/load_orders.py .
RUN useradd -u 10001 -m loader
USER 10001
CMD ["python", "load_orders.py"]
