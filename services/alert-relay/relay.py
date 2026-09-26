#!/usr/bin/env python3
"""Alertmanager webhook -> `coder task create` relay.

Deliberately minimal: stdlib only (http.server, json, subprocess), no
web framework. Holds CODER_SESSION_TOKEN; the only thing it does with
alert-derived text is pass it as a single argument to the `coder` CLI,
never through a shell, so a crafted alert label/annotation can't reach
command injection here (see docs/design-investigate.md).
"""
import json
import os
import subprocess
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

CODER_URL = os.environ.get("CODER_URL", "https://coder.vigihome.net")
CODER_TEMPLATE = os.environ.get("CODER_TEMPLATE", "Investigate")
DEDUPE_TTL_SECONDS = int(os.environ.get("DEDUPE_TTL_SECONDS", "21600"))  # 6h

INVESTIGATE_ONLY_CONTRACT = (
    "You are investigating a homelab Kubernetes alert. Gather evidence "
    "(kubectl get/describe/logs, and curl to Prometheus/Alertmanager's "
    "in-cluster Service DNS) and write a root-cause report to "
    "~/findings.md. Do NOT modify any cluster state -- your "
    "ServiceAccount has read-only RBAC (no exec, no secrets, no write "
    "verbs) so mutating commands will fail, and that is intentional: "
    "report a suggested fix, do not attempt to apply one."
)


class Dedupe:
    """Fingerprint -> last-seen timestamp, in-memory, TTL-bounded.

    No persistence: a relay restart at worst re-triggers one
    already-firing alert once. See docs/design-investigate.md.
    """

    def __init__(self, ttl_seconds: int):
        self.ttl_seconds = ttl_seconds
        self._seen: dict[str, float] = {}
        self._lock = threading.Lock()

    def seen_recently(self, fingerprint: str) -> bool:
        now = time.monotonic()
        with self._lock:
            last = self._seen.get(fingerprint)
            self._seen[fingerprint] = now
            if last is None:
                return False
            return (now - last) < self.ttl_seconds


def build_prompt(alert: dict) -> str:
    labels = alert.get("labels", {})
    annotations = alert.get("annotations", {})
    lines = [
        INVESTIGATE_ONLY_CONTRACT,
        "",
        f"Alert: {labels.get('alertname', 'unknown')}",
        f"Severity: {labels.get('severity', 'unknown')}",
        f"Started: {alert.get('startsAt', 'unknown')}",
        f"Summary: {annotations.get('summary', '')}",
        f"Description: {annotations.get('description', '')}",
        f"Labels: {json.dumps(labels)}",
        f"Prometheus query: {alert.get('generatorURL', '')}",
    ]
    return "\n".join(lines)


def create_task(prompt: str) -> None:
    result = subprocess.run(
        [
            "coder",
            "task",
            "create",
            "--template",
            CODER_TEMPLATE,
            "--input",
            prompt,
        ],
        capture_output=True,
        text=True,
        timeout=30,
        check=False,
    )
    if result.returncode != 0:
        raise RuntimeError(f"coder task create failed: {result.stderr}")


def handle_webhook(payload: dict, dedupe: Dedupe) -> None:
    for alert in payload.get("alerts", []):
        if alert.get("status") != "firing":
            continue
        fingerprint = alert.get("fingerprint", "")
        if fingerprint and dedupe.seen_recently(fingerprint):
            continue
        prompt = build_prompt(alert)
        try:
            create_task(prompt)
        except Exception as exc:  # noqa: BLE001 -- must never propagate
            print(f"create_task failed, continuing: {exc}", flush=True)


class Handler(BaseHTTPRequestHandler):
    dedupe = Dedupe(ttl_seconds=DEDUPE_TTL_SECONDS)

    def do_POST(self):  # noqa: N802 -- BaseHTTPRequestHandler naming
        if self.path != "/alertmanager-webhook":
            self.send_response(404)
            self.end_headers()
            return
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length)
        try:
            payload = json.loads(body)
        except json.JSONDecodeError:
            payload = {"alerts": []}
        handle_webhook(payload, self.dedupe)
        self.send_response(200)
        self.end_headers()

    def log_message(self, fmt, *args):  # quieter default access log
        print(f"{self.address_string()} - {fmt % args}", flush=True)


def main():
    if not os.environ.get("CODER_SESSION_TOKEN"):
        raise SystemExit("CODER_SESSION_TOKEN is required")
    server = ThreadingHTTPServer(("0.0.0.0", 8080), Handler)
    print("alert-relay listening on :8080", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
