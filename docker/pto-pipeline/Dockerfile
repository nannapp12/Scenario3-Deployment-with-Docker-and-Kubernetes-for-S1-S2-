# syntax=docker/dockerfile:1
# Scenario 2 PostgreSQL pipelines, built as two images (same dependencies, different entrypoint):
#   handbook-ingest  (PIPELINE=ingest_handbook.py)  handbook -> chunks -> embeddings -> pgvector
#   employee-sync    (PIPELINE=sync_employees.py)   Databricks on AWS -> hr.employees
# Build from the repo root:
#   docker build -f Scenario3/docker/pto-pipeline/Dockerfile --build-arg PIPELINE=sync_employees.py -t employee-sync .
FROM python:3.12-slim
ARG PIPELINE
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 PIPELINE=${PIPELINE}
RUN test -n "$PIPELINE" || (echo "PIPELINE build arg is required" >&2; exit 1)
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY Scenario2/pipelines/postgres/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
# The script's own directory is on sys.path, so /app/common is importable as `common`.
COPY Scenario2/common ./common
COPY Scenario2/pipelines/postgres/*.py ./
RUN test -f "$PIPELINE" && useradd -u 10001 -m pipeline
USER 10001
ENTRYPOINT ["sh", "-c", "exec python \"$PIPELINE\" \"$@\"", "--"]
