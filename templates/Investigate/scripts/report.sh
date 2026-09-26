#!/usr/bin/env sh
set -eu

# Runs after Claude Code's own install/session completes. Emails
# ~/findings.md via the smtp-relay secret if Claude Code wrote one --
# mirrors homelab's restic-backup CronJob send_email pattern so there's
# one email-sending recipe in the whole homelab stack, not two.

FINDINGS="$HOME/findings.md"
if [ ! -f "$FINDINGS" ]; then
  echo "No findings.md written; skipping notification email." >&2
  exit 0
fi

if [ -z "${SMTP_HOST:-}" ] || [ -z "${SMTP_USER:-}" ] || [ -z "${SMTP_PASS:-}" ]; then
  echo "SMTP env not populated; skipping notification email." >&2
  exit 0
fi

if ! command -v curl >/dev/null 2>&1; then
  echo "curl not available; skipping notification email." >&2
  exit 0
fi

{
  printf 'From: %s\r\n' "$SMTP_FROM"
  printf 'To: %s\r\n' "$SMTP_TO"
  printf 'Subject: [homelab] Investigate findings\r\n'
  printf 'Date: %s\r\n' "$(date)"
  printf 'MIME-Version: 1.0\r\n'
  printf 'Content-Type: text/plain; charset=UTF-8\r\n'
  printf '\r\n'
  cat "$FINDINGS"
  printf '\r\n'
} | curl -sS --max-time 30 \
  --url "smtps://${SMTP_HOST}:${SMTP_PORT:-465}" \
  --user "$SMTP_USER:$SMTP_PASS" \
  --mail-from "$SMTP_FROM" \
  --mail-rcpt "$SMTP_TO" \
  --upload-file - >/dev/null 2>&1 || echo "email send failed, findings.md is still on disk" >&2
