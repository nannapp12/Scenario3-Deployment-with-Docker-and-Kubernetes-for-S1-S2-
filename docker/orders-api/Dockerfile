# syntax=docker/dockerfile:1
# Scenario 1 Orders agent API (FastAPI -> Foundry agent -> MCP servers). The web UI is a separate image.
# Build from the repo root:  docker build -f Scenario3/docker/orders-api/Dockerfile -t orders-api .
FROM python:3.12-slim
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
WORKDIR /srv
COPY Scenario3/docker/constraints.txt /tmp/constraints.txt
COPY Scenario1/api/requirements.txt .
RUN PIP_CONSTRAINT=/tmp/constraints.txt pip install --no-cache-dir -r requirements.txt
COPY Scenario1/api/app ./app
RUN useradd -u 10001 -m api
USER 10001
EXPOSE 8000
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000", "--proxy-headers", "--forwarded-allow-ips", "*"]
