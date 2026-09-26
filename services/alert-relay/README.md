# alert-relay

Translates Alertmanager `webhook_configs` POSTs into `coder task create`
calls against the `Investigate` template.
Stdlib-only Python (no framework) — see `docs/design-investigate.md` in
this repo for why.

## Environment

- `CODER_SESSION_TOKEN` (required) — a Coder API token, stored via
  `homelab`'s `k8s/coder/relay-external-secret.yaml`.
- `CODER_URL` (default `https://coder.vigihome.net`)
- `CODER_TEMPLATE` (default `Investigate`)
- `DEDUPE_TTL_SECONDS` (default `21600`, 6h)

## Local testing

```bash
python3 -m unittest test_relay -v
```
