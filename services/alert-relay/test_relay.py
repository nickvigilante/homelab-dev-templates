import time
import unittest
from unittest.mock import patch, MagicMock

from relay import build_prompt, handle_webhook, Dedupe


RESOLVED_PAYLOAD = {
    "receiver": "coder-investigator",
    "status": "resolved",
    "alerts": [
        {
            "status": "resolved",
            "labels": {"alertname": "KubeJobFailed", "severity": "warning"},
            "annotations": {"summary": "Job failed to complete."},
            "startsAt": "2026-09-25T07:30:20.898Z",
            "endsAt": "2026-09-25T23:43:20.898Z",
            "fingerprint": "10c688058232e656",
            "generatorURL": "https://prometheus.vigihome.net/graph?g0.expr=up",
        }
    ],
}

FIRING_PAYLOAD = {
    "receiver": "coder-investigator",
    "status": "firing",
    "alerts": [
        {
            "status": "firing",
            "labels": {"alertname": "ResticBackupStale", "severity": "warning"},
            "annotations": {
                "summary": "Nightly restic backup has not succeeded in over 25h",
                "description": "No successful restic-backup CronJob run in >25h.",
            },
            "startsAt": "2026-09-25T08:31:30.529Z",
            "endsAt": "0001-01-01T00:00:00Z",
            "fingerprint": "aa0842d6093b0fc4",
            "generatorURL": "https://prometheus.vigihome.net/graph?g0.expr=up",
        }
    ],
}

EMPTY_PAYLOAD = {"receiver": "coder-investigator", "status": "firing", "alerts": []}


class BuildPromptTests(unittest.TestCase):
    def test_includes_alertname_and_summary(self):
        prompt = build_prompt(FIRING_PAYLOAD["alerts"][0])
        self.assertIn("ResticBackupStale", prompt)
        self.assertIn("Nightly restic backup has not succeeded", prompt)

    def test_includes_investigate_only_contract(self):
        prompt = build_prompt(FIRING_PAYLOAD["alerts"][0])
        self.assertIn("do not modify", prompt.lower())


class DedupeTests(unittest.TestCase):
    def test_first_seen_is_not_a_duplicate(self):
        d = Dedupe(ttl_seconds=3600)
        self.assertFalse(d.seen_recently("fp1"))

    def test_second_call_within_ttl_is_a_duplicate(self):
        d = Dedupe(ttl_seconds=3600)
        d.seen_recently("fp1")
        self.assertTrue(d.seen_recently("fp1"))

    def test_call_after_ttl_expiry_is_not_a_duplicate(self):
        d = Dedupe(ttl_seconds=0)
        d.seen_recently("fp1")
        time.sleep(0.01)
        self.assertFalse(d.seen_recently("fp1"))


class HandleWebhookTests(unittest.TestCase):
    def setUp(self):
        self.dedupe = Dedupe(ttl_seconds=3600)

    @patch("relay.create_task")
    def test_resolved_alert_does_not_create_a_task(self, mock_create):
        handle_webhook(RESOLVED_PAYLOAD, self.dedupe)
        mock_create.assert_not_called()

    @patch("relay.create_task")
    def test_empty_alerts_list_does_not_crash(self, mock_create):
        handle_webhook(EMPTY_PAYLOAD, self.dedupe)
        mock_create.assert_not_called()

    @patch("relay.create_task")
    def test_firing_alert_creates_exactly_one_task(self, mock_create):
        handle_webhook(FIRING_PAYLOAD, self.dedupe)
        mock_create.assert_called_once()

    @patch("relay.create_task")
    def test_duplicate_fingerprint_within_ttl_creates_only_once(self, mock_create):
        handle_webhook(FIRING_PAYLOAD, self.dedupe)
        handle_webhook(FIRING_PAYLOAD, self.dedupe)
        mock_create.assert_called_once()

    @patch("relay.create_task", side_effect=RuntimeError("coder CLI failed"))
    def test_create_task_failure_does_not_raise(self, mock_create):
        # handle_webhook must swallow this -- the HTTP handler always
        # answers 200 to Alertmanager regardless, so Alertmanager's own
        # retry logic doesn't compound a downstream failure.
        try:
            handle_webhook(FIRING_PAYLOAD, self.dedupe)
        except RuntimeError:
            self.fail("handle_webhook must not propagate create_task errors")


class CreateTaskArgsTests(unittest.TestCase):
    @patch("relay.subprocess.run")
    def test_create_task_never_uses_shell_true(self, mock_run):
        from relay import create_task

        mock_run.return_value = MagicMock(returncode=0, stdout="", stderr="")
        create_task("some prompt with ; rm -rf / in it")
        _, kwargs = mock_run.call_args
        self.assertNotIn("shell", kwargs)
        args = mock_run.call_args[0][0]
        self.assertIsInstance(args, list)


if __name__ == "__main__":
    unittest.main()
