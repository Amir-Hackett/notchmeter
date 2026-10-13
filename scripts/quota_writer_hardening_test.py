#!/usr/bin/env python3
"""Hardening tests for the quota.json writer: schema, atomicity, permissions, secret hygiene."""

from __future__ import annotations

import base64
import io
import json
import os
import stat
import sys
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from datetime import datetime, timezone
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))

import quota_status as quota

NOW = datetime(2026, 10, 4, 15, 0, tzinfo=timezone.utc)


def good_report() -> dict:
    return {
        "updated_at": "2026-10-04T15:00:00Z",
        "accounts": [
            quota.row("a@example.com", "chatgpt", "open", 42, "2026-10-05T00:00:00Z"),
            quota.unknown_row("b@example.com", "supergrok"),
        ],
    }


class SchemaTests(unittest.TestCase):
    def test_valid_report_passes(self):
        quota.validate_report(good_report())

    def test_rejects_bad_shapes(self):
        bad = []
        r = good_report(); r["extra"] = 1; bad.append(r)
        r = good_report(); r["updated_at"] = "yesterday"; bad.append(r)
        r = good_report(); r["updated_at"] = "2026-10-04T15:00:00"; bad.append(r)
        r = good_report(); r["accounts"][0]["provider"] = "claude"; bad.append(r)
        r = good_report(); r["accounts"][0]["state"] = "full"; bad.append(r)
        r = good_report(); r["accounts"][0]["remaining"] = "42"; bad.append(r)
        r = good_report(); r["accounts"][0]["remaining"] = -1; bad.append(r)
        r = good_report(); r["accounts"][0]["remaining"] = True; bad.append(r)
        r = good_report(); r["accounts"][0]["remaining"] = float("nan"); bad.append(r)
        r = good_report(); r["accounts"][0]["resets_at"] = "soon"; bad.append(r)
        r = good_report(); r["accounts"][1]["remaining"] = 5; bad.append(r)  # unknown must stay unknown
        r = good_report(); del r["accounts"][0]["email"]; bad.append(r)
        r = good_report(); r["accounts"][0]["token"] = "x"; bad.append(r)
        for report in bad:
            with self.subTest(report=report), self.assertRaises(ValueError):
                quota.validate_report(report)

    def test_empty_machine_report_validates(self):
        with tempfile.TemporaryDirectory() as tmp:
            report, _ = quota.build_report(Path(tmp), env={}, now=NOW, transport=lambda *a: (_ for _ in ()).throw(AssertionError("no network")), oauth_clients={})
            quota.validate_report(report)
            for account in report["accounts"]:
                self.assertEqual(account["state"], "unknown")
                self.assertIsNone(account["remaining"])
                self.assertIsNone(account["resets_at"])


class AtomicWriteTests(unittest.TestCase):
    def test_writes_private_file_and_no_temp_left(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / ".notchmeter" / "quota.json"
            quota.write_quota(path, good_report())
            self.assertEqual(json.loads(path.read_text()), good_report())
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
            self.assertEqual(stat.S_IMODE(path.parent.stat().st_mode), 0o700)
            self.assertEqual(sorted(p.name for p in path.parent.iterdir()), ["quota.json"])

    def test_invalid_report_never_touches_existing_file(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "quota.json"
            quota.write_quota(path, good_report())
            before = path.read_bytes()
            bad = good_report(); bad["accounts"][0]["state"] = "bogus"
            with self.assertRaises(ValueError):
                quota.write_quota(path, bad)
            self.assertEqual(path.read_bytes(), before)
            self.assertEqual([p.name for p in path.parent.iterdir()], ["quota.json"])

    def test_failed_rename_keeps_previous_file_and_cleans_temp(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "quota.json"
            quota.write_quota(path, good_report())
            before = path.read_bytes()
            changed = good_report(); changed["accounts"][0]["remaining"] = 1
            with mock.patch.object(quota.os, "replace", side_effect=OSError("disk full")):
                with self.assertRaises(OSError):
                    quota.write_quota(path, changed)
            self.assertEqual(path.read_bytes(), before)
            self.assertEqual([p.name for p in path.parent.iterdir()], ["quota.json"])


class ErrorHandlingTests(unittest.TestCase):
    def test_main_returns_nonzero_when_quota_dir_is_unwritable(self):
        with tempfile.TemporaryDirectory() as tmp:
            home = Path(tmp)
            (home / ".notchmeter").write_text("not a directory")
            err = io.StringIO()
            with redirect_stdout(io.StringIO()), redirect_stderr(err):
                code = quota.main(home=home, env={}, now=NOW, transport=lambda *a: (500, b""))
            self.assertEqual(code, 1)
            self.assertIn("could not write", err.getvalue())

    def test_token_store_write_failure_keeps_old_store(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "auth.json"
            path.write_text('{"old": true}')
            with mock.patch.object(quota.os, "replace", side_effect=OSError("ro")):
                quota._atomic_json(path, {"new": True})
            self.assertEqual(json.loads(path.read_text()), {"old": True})
            self.assertEqual([p.name for p in path.parent.iterdir()], ["auth.json"])


class TokenParsingTests(unittest.TestCase):
    def test_malformed_jwts_do_not_raise(self):
        for token in ["", "abc", "a.b", "a.!!!.c", "a." + base64.urlsafe_b64encode(b"[1]").decode() + ".c", "a." + base64.urlsafe_b64encode(b"not json").decode() + ".c"]:
            with self.subTest(token=token):
                self.assertIsNone(quota.jwt_payload(token))

    def test_gocspx_extraction_ignores_short_or_missing_secrets(self):
        self.assertIsNone(quota.oauth_client_from_text("nothing to see here"))
        self.assertIsNone(quota.oauth_client_from_text("GOCSPX-short 123-abc.apps.googleusercontent.com"))


class SecretHygieneTests(unittest.TestCase):
    def test_main_output_never_contains_tokens(self):
        access = "h." + base64.urlsafe_b64encode(json.dumps({"exp": 1, "email": "a@example.com"}).encode()).decode().rstrip("=") + ".SIGNATURESECRET"
        refresh = "rt_REFRESHSECRETVALUE"
        with tempfile.TemporaryDirectory() as tmp:
            home = Path(tmp)
            (home / ".codex").mkdir()
            (home / ".codex" / "auth.json").write_text(json.dumps({"tokens": {"access_token": access, "refresh_token": refresh, "id_token": access}}))
            out, err = io.StringIO(), io.StringIO()
            with redirect_stdout(out), redirect_stderr(err):
                quota.main(home=home, env={}, now=NOW, transport=lambda *a: (401, b'{"error":"invalid_grant"}'))
            text = out.getvalue() + err.getvalue() + (home / ".notchmeter" / "quota.json").read_text()
            for secret in ("SIGNATURESECRET", "REFRESHSECRETVALUE", "GOCSPX-"):
                self.assertNotIn(secret, text)


if __name__ == "__main__":
    unittest.main()
