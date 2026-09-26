# syntax=docker/dockerfile:1
FROM python:3.13-slim

# Without this, a failed `curl | sh` below would exit 0 (only the
# trailing `sh`'s exit code counts) and silently continue the build on
# a corrupted/empty install.
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# Pin the coder CLI install script's target version alongside the
# server -- update in lockstep with templates/Base's own Coder version
# expectations if the server is ever upgraded.
# hadolint ignore=DL3008
RUN apt-get update && apt-get install -y --no-install-recommends curl ca-certificates \
    && curl -fsSL https://coder.vigihome.net/install.sh | sh \
    && apt-get purge -y curl && apt-get autoremove -y \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY relay.py .

USER 65534:65534
ENTRYPOINT ["python3", "/app/relay.py"]
