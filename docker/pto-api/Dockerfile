# syntax=docker/dockerfile:1
# Scenario 2 PTO agent API (GET /pto/{employee_id}). The web UI is a separate image.
# Build from the repo root:  docker build -f Scenario3/docker/pto-api/Dockerfile -t pto-api .
FROM python:3.12-slim
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates && rm -rf /var/lib/apt/lists/*
WORKDIR /srv
COPY Scenario2/api/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY Scenario2/common ./common
COPY Scenario2/api/app ./app
RUN useradd -u 10001 -m api
USER 10001
EXPOSE 8000
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000", "--proxy-headers", "--forwarded-allow-ips", "*"]
