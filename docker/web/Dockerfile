# syntax=docker/dockerfile:1
# Web front-end: static files only (the APIs are separate images behind the same Ingress host).
#   /     -> Scenario1/web  Orders Voice Analyst (calls /api/*)
#   /hr/  -> Scenario2/web  PTO Balance Lookup   (calls /pto/*; reached through oauth2-proxy)
# Build from the repo root:  docker build -f Scenario3/docker/web/Dockerfile -t web .
FROM nginxinc/nginx-unprivileged:1.28-alpine
COPY Scenario3/docker/web/nginx.conf /etc/nginx/conf.d/default.conf
COPY Scenario1/web/ /usr/share/nginx/html/
COPY Scenario2/web/ /usr/share/nginx/html/hr/
USER 101
EXPOSE 8080
