# syntax=docker/dockerfile:1
# Scenario 1 MCP server, built as one image per backend so each image only carries its own
# database connector:  mcp-databricks, mcp-mysql, mcp-snowflake.
# Build from the repo root:
#   docker build -f Scenario3/docker/mcp/Dockerfile --build-arg MCP_BACKEND=mysql -t mcp-mysql .
FROM python:3.12-slim
ARG MCP_BACKEND
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY Scenario3/docker/constraints.txt /tmp/constraints.txt
COPY Scenario1/mcp_servers/requirements.txt .
# Shared packages + only this backend's connector, keeping the versions in requirements.txt.
RUN case "$MCP_BACKEND" in \
      databricks) keep=databricks-sql-connector ;; \
      mysql)      keep=pymysql ;; \
      snowflake)  keep=snowflake-connector-python ;; \
      *) echo "MCP_BACKEND must be databricks|mysql|snowflake, got '$MCP_BACKEND'" >&2; exit 1 ;; \
    esac \
 && grep -Ev '^(databricks-sql-connector|pymysql|snowflake-connector-python)' requirements.txt > image-requirements.txt \
 && grep -E "^${keep}" requirements.txt >> image-requirements.txt \
 && PIP_CONSTRAINT=/tmp/constraints.txt pip install --no-cache-dir -r image-requirements.txt
COPY Scenario1/mcp_servers/backends.py Scenario1/mcp_servers/server.py Scenario1/mcp_servers/sql_guard.py ./
ENV MCP_BACKEND=${MCP_BACKEND}
RUN useradd -u 10001 -m mcp
USER 10001
EXPOSE 8080
CMD ["python", "server.py"]
