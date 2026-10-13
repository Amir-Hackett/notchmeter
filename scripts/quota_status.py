#!/usr/bin/env python3
"""Write ~/.notchmeter/quota.json for Agent Overlord.

The file is the contract. Each row is one account and one provider. ``state``
is ``open`` or ``exhausted`` only after a live provider response. ``remaining``
is filled only with a number that response carried. ``resets_at`` is filled
only with a timestamp that response carried. Anything else is ``unknown`` with
both fields null.

This command reads OAuth tokens a provider's own client already stored. It
never asks for a password and never embeds an OAuth client secret. When a
stored access token is expired and a refresh token is already on disk, it
refreshes that token and then probes. Antigravity's Google client is read
from the local ``agy`` binary at runtime. SuperGrok's client id is read from
``~/.grok/auth.json``. Codex uses its public client id. A refreshed SuperGrok
token is written back onto that entry's ``key``, ``access_token``,
``refresh_token``, and ``expires_at``. A refreshed Antigravity token is written
back only when the file still holds the refresh token that was used. Codex
refreshes stay in memory. It does not choose which account should run a job.
"""

from __future__ import annotations

import base64
import json
import math
import os
import re
import shutil
import subprocess
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass, replace
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Callable, Mapping

SCHEMA_KEYS = ("updated_at", "accounts")
ROW_KEYS = ("email", "provider", "state", "remaining", "resets_at")
STATES = ("open", "exhausted", "unknown")
PROVIDERS = ("chatgpt", "supergrok", "antigravity")

# Roster order is the file order. ascendmaui and johnmatveyev each have an
# Antigravity row beside their other providers.
ROSTER: tuple[tuple[str, str], ...] = (
    ("ascendmaui@gmail.com", "supergrok"),
    ("ascendmaui@gmail.com", "antigravity"),
    ("johnmatveyev@gmail.com", "chatgpt"),
    ("johnmatveyev@gmail.com", "supergrok"),
    ("johnmatveyev@gmail.com", "antigravity"),
    ("503meds@gmail.com", "antigravity"),
    ("ascendlifesc@gmail.com", "antigravity"),
    ("ascendlifeinsurance@gmail.com", "antigravity"),
    ("powerevllc@gmail.com", "antigravity"),
    ("jvmsalesllc@gmail.com", "antigravity"),
)

CHATGPT_URL = "https://chatgpt.com/backend-api/wham/usage"
SUPERGROK_URL = "https://cli-chat-proxy.grok.com/v1/billing?format=credits"
CODE_ASSIST_HOSTS = (
    "daily-cloudcode-pa.googleapis.com",
    "cloudcode-pa.googleapis.com",
)
USER_AGENT = "Notchmeter-quota-status/1"
EXPIRY_SKEW = timedelta(seconds=30)
PLACEHOLDER_RESET = timedelta(hours=5)
PLACEHOLDER_TOLERANCE = timedelta(seconds=120)

GOOGLE_TOKEN_URL = "https://oauth2.googleapis.com/token"
OPENAI_TOKEN_URL = "https://auth.openai.com/oauth/token"
XAI_TOKEN_URL = "https://auth.x.ai/oauth2/token"
# Public client id shipped by the Codex CLI. It is not a client secret.
OPENAI_CLIENT_ID = "app_EMoamEEZ73f0CkXaXp7hrann"
# Public prefix of the Antigravity CLI's Google client id. The secret is
# paired with it from `agy` at runtime and is never stored in this repository.
AGY_CLIENT_PREFIX = "1071006060591-"
_GOOGLE_SECRET_PREFIX = "GOC" + "SPX-"
# Google client secrets are 28 characters after the prefix. A longer match
# glues the next secret onto the first when `strings` prints them back to back.
_GOOGLE_SECRET_LENGTH = 28
GOOGLE_CLIENT_RE = re.compile(r"\d{10,}-[A-Za-z0-9_-]+\.apps\.googleusercontent\.com")
GOOGLE_SECRET_RE = re.compile(
    re.escape(_GOOGLE_SECRET_PREFIX) + rf"[A-Za-z0-9_-]{{{_GOOGLE_SECRET_LENGTH}}}"
)

PATH_CHATGPT = "scripts/quota_status.py:probe_chatgpt"
PATH_SUPERGROK = "scripts/quota_status.py:probe_supergrok"
PATH_ANTIGRAVITY = "scripts/quota_status.py:probe_antigravity"

Transport = Callable[[str, str, Mapping[str, str], bytes | None, float], tuple[int, bytes]]


@dataclass(frozen=True)
class Credential:
    email: str
    access_token: str
    expires_at: datetime | None
    source: str
    account_id: str | None = None
    logged_host: str | None = None
    refresh_token: str | None = None
    oauth_kind: str | None = None
    store_path: str | None = None
    store_key: str | None = None
    grok_client_id: str | None = None


@dataclass(frozen=True)
class Note:
    email: str
    provider: str
    state: str
    detail: str
    code_path: str


def quota_path(home: Path) -> Path:
    return home / ".notchmeter" / "quota.json"


def number(value: object) -> int | float | None:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    if isinstance(value, float) and (math.isnan(value) or math.isinf(value)):
        return None
    return value


def parse_time(value: object) -> datetime | None:
    if isinstance(value, str):
        text = value.strip()
        if not text:
            return None
        if text.endswith("Z"):
            text = text[:-1] + "+00:00"
        try:
            parsed = datetime.fromisoformat(text)
        except ValueError:
            return None
        if parsed.tzinfo is None:
            return None
        return parsed.astimezone(timezone.utc)
    parsed_number = number(value)
    if parsed_number is None:
        return None
    seconds = parsed_number / 1000 if parsed_number > 10_000_000_000 else parsed_number
    try:
        return datetime.fromtimestamp(seconds, timezone.utc)
    except (OverflowError, OSError, ValueError):
        return None


def iso_z(moment: datetime) -> str:
    return moment.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def row(email: str, provider: str, state: str, remaining: int | float | None, resets_at: str | None) -> dict:
    if state not in STATES:
        raise ValueError(state)
    if provider not in PROVIDERS:
        raise ValueError(provider)
    if state == "unknown":
        remaining = None
        resets_at = None
    return {
        "email": email,
        "provider": provider,
        "state": state,
        "remaining": remaining,
        "resets_at": resets_at,
    }


def unknown_row(email: str, provider: str) -> dict:
    return row(email, provider, "unknown", None, None)


def jwt_payload(token: str) -> dict | None:
    parts = token.split(".")
    if len(parts) < 2:
        return None
    segment = parts[1]
    padded = segment + "=" * (-len(segment) % 4)
    try:
        raw = base64.urlsafe_b64decode(padded.encode("ascii"))
        payload = json.loads(raw)
    except (ValueError, json.JSONDecodeError, UnicodeError):
        return None
    return payload if isinstance(payload, dict) else None


def email_from_claims(claims: dict) -> str | None:
    for key in ("email", "Email"):
        value = claims.get(key)
        if isinstance(value, str) and "@" in value:
            return value.strip().lower()
    profile = claims.get("https://api.openai.com/profile")
    if isinstance(profile, dict):
        value = profile.get("email")
        if isinstance(value, str) and "@" in value:
            return value.strip().lower()
    return None


def display_path(path: Path, home: Path) -> str:
    try:
        relative = path.resolve().relative_to(home.resolve())
    except ValueError:
        return str(path)
    return "~/" + relative.as_posix()


def read_json(path: Path) -> dict | None:
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError):
        return None
    return payload if isinstance(payload, dict) else None


def logged_code_assist_host(log_path: Path) -> str | None:
    try:
        size = log_path.stat().st_size
        with log_path.open("rb") as handle:
            if size > 65_536:
                handle.seek(size - 65_536)
            text = handle.read().decode("utf-8", errors="ignore")
    except OSError:
        return None
    found = re.findall(r"https://([a-z0-9.-]*cloudcode-pa\.googleapis\.com)", text, flags=re.IGNORECASE)
    if not found:
        return None
    host = found[-1].lower()
    return host if host in CODE_ASSIST_HOSTS else None


def _expired(expires_at: datetime | None, now: datetime) -> bool:
    return expires_at is not None and expires_at <= now + EXPIRY_SKEW


def discover_antigravity(home: Path, env: Mapping[str, str], now: datetime) -> tuple[list[Credential], list[Credential], int]:
    """Return (usable, expired, files whose email could not be read)."""
    roots = _antigravity_roots(home, env)
    usable: list[Credential] = []
    expired: list[Credential] = []
    nameless = 0
    seen: set[Path] = set()
    for root in roots:
        for token_path in (
            root / ".gemini" / "antigravity-cli" / "antigravity-oauth-token",
            root / ".gemini" / "oauth_creds.json",
        ):
            try:
                resolved = token_path.resolve()
            except OSError:
                resolved = token_path
            if resolved in seen or not token_path.is_file():
                continue
            seen.add(resolved)
            cred, named = _google_credential(token_path, root, home)
            if cred is None:
                if token_path.is_file():
                    nameless += 0 if named else 1
                continue
            if _expired(cred.expires_at, now):
                expired.append(cred)
            else:
                usable.append(cred)
    return usable, expired, nameless


def _antigravity_roots(home: Path, env: Mapping[str, str]) -> list[Path]:
    roots = [home]
    real = env.get("AGY_REAL_HOME", "").strip()
    if real:
        roots.append(Path(real).expanduser())
    found: list[Path] = []
    seen: set[Path] = set()
    for root in roots:
        if root in seen:
            continue
        seen.add(root)
        found.append(root)
        slots = root / ".agy-accounts"
        if not slots.is_dir():
            continue
        for child in sorted(slots.iterdir()):
            if child.is_dir() and not child.name.startswith("."):
                found.append(child)
    return found


def _first_text(*values: object) -> str | None:
    for value in values:
        if isinstance(value, str) and value.strip():
            return value.strip()
    return None


def _first_present(payload: dict, keys: tuple[str, ...]) -> object:
    for key in keys:
        if key in payload and payload[key] not in (None, ""):
            return payload[key]
    return None


def _google_material(payload: dict) -> tuple[str | None, str | None, object]:
    """Return access token, refresh token, and the expiry field that belongs to the access token.

    Antigravity's CLI nests those three under ``token``. A string ``token`` or a
    top-level ``access_token`` is the older shape. Identity-token expiry is ignored.
    """
    nested = payload.get("token")
    if isinstance(nested, dict):
        access = _first_text(nested.get("access_token"))
        if access is not None:
            refresh = _first_text(nested.get("refresh_token"), payload.get("refresh_token"))
            expiry = _first_present(nested, ("expiry", "expiry_date", "expires_at"))
            if expiry is None:
                expiry = _first_present(payload, ("expiry", "expiry_date", "expires_at"))
            return access, refresh, expiry
    string_token = payload.get("token") if isinstance(payload.get("token"), str) else None
    access = _first_text(payload.get("access_token"), string_token)
    if access is None:
        return None, None, None
    return access, _first_text(payload.get("refresh_token")), _first_present(payload, ("expiry", "expiry_date", "expires_at"))


def _google_expiry(expiry_field: object, bearer: str) -> datetime | None:
    parsed = parse_time(expiry_field)
    if parsed is not None:
        return parsed
    claims = jwt_payload(bearer)
    if not claims:
        return None
    return parse_time(claims.get("exp"))


def _google_kind(token_path: Path) -> str:
    if token_path.name == "oauth_creds.json" and ".agy-accounts" not in token_path.as_posix():
        return "gemini"
    return "antigravity"


def _google_credential(token_path: Path, root: Path, home: Path) -> tuple[Credential | None, bool]:
    payload = read_json(token_path)
    if payload is None:
        return None, False
    token, refresh, expiry_field = _google_material(payload)
    if token is None:
        return None, False
    email = None
    id_token = payload.get("id_token")
    if isinstance(id_token, str):
        claims = jwt_payload(id_token)
        if claims:
            email = email_from_claims(claims)
    named = email is not None
    if email is None:
        email_file = root / "ACCOUNT_EMAIL"
        try:
            text = email_file.read_text(encoding="utf-8").strip().lower()
        except OSError:
            text = ""
        if "@" in text:
            email = text
    if email is None:
        return None, False
    log_path = root / ".gemini" / "antigravity-cli" / "cli.log"
    return Credential(
        email=email,
        access_token=token,
        expires_at=_google_expiry(expiry_field, token),
        source=display_path(token_path, home),
        logged_host=logged_code_assist_host(log_path),
        refresh_token=refresh,
        oauth_kind=_google_kind(token_path),
        store_path=str(token_path),
    ), named


def discover_codex(home: Path, env: Mapping[str, str], now: datetime) -> tuple[list[Credential], list[Credential], int]:
    paths: list[Path] = []
    custom = env.get("CODEX_HOME", "").strip()
    if custom:
        paths.append(Path(custom).expanduser() / "auth.json")
    paths.append(home / ".config" / "codex" / "auth.json")
    paths.append(home / ".codex" / "auth.json")
    return _scan_auth_files(paths, home, now, _codex_credential)


def discover_supergrok(home: Path, env: Mapping[str, str], now: datetime) -> tuple[list[Credential], list[Credential], int]:
    paths: list[Path] = []
    custom = env.get("GROK_HOME", "").strip()
    if custom:
        paths.append(Path(custom).expanduser() / "auth.json")
    paths.append(home / ".grok" / "auth.json")
    usable: list[Credential] = []
    expired: list[Credential] = []
    nameless = 0
    seen: set[Path] = set()
    for path in paths:
        try:
            resolved = path.resolve()
        except OSError:
            resolved = path
        if resolved in seen or not path.is_file():
            continue
        seen.add(resolved)
        payload = read_json(path)
        if payload is None:
            nameless += 1
            continue
        if _is_entry_map(payload):
            pairs = [(key, value) for key, value in payload.items() if isinstance(value, dict)]
        else:
            pairs = [(None, payload)]
        found_here = False
        for store_key, entry in pairs:
            if not isinstance(entry, dict):
                continue
            cred = _supergrok_entry(entry, path, home, store_key if isinstance(store_key, str) else None)
            if cred is None:
                continue
            found_here = True
            if _expired(cred.expires_at, now):
                expired.append(cred)
            else:
                usable.append(cred)
        if not found_here:
            nameless += 1
    return usable, expired, nameless


def _is_entry_map(payload: dict) -> bool:
    return any(
        isinstance(value, dict) and ("key" in value or "access_token" in value or "email" in value)
        for value in payload.values()
    )


def _supergrok_entry(entry: dict, path: Path, home: Path, store_key: str | None) -> Credential | None:
    email = entry.get("email")
    token = _first_text(entry.get("key"), entry.get("access_token"))
    if not isinstance(email, str) or "@" not in email:
        return None
    if token is None:
        return None
    refresh = entry.get("refresh_token")
    client_id = entry.get("oidc_client_id")
    return Credential(
        email=email.strip().lower(),
        access_token=token.strip(),
        expires_at=parse_time(entry.get("expires_at")),
        source=display_path(path, home),
        refresh_token=refresh.strip() if isinstance(refresh, str) and refresh.strip() else None,
        oauth_kind="supergrok",
        store_path=str(path),
        store_key=store_key,
        grok_client_id=client_id.strip() if isinstance(client_id, str) and client_id.strip() else None,
    )


def _scan_auth_files(paths: list[Path], home: Path, now: datetime, parse) -> tuple[list[Credential], list[Credential], int]:
    usable: list[Credential] = []
    expired: list[Credential] = []
    nameless = 0
    seen: set[Path] = set()
    for path in paths:
        try:
            resolved = path.resolve()
        except OSError:
            resolved = path
        if resolved in seen or not path.is_file():
            continue
        seen.add(resolved)
        cred = parse(path, home)
        if cred is None:
            nameless += 1
            continue
        if _expired(cred.expires_at, now):
            expired.append(cred)
        else:
            usable.append(cred)
    return usable, expired, nameless


def _codex_credential(path: Path, home: Path) -> Credential | None:
    payload = read_json(path)
    if payload is None:
        return None
    tokens = payload.get("tokens")
    if not isinstance(tokens, dict):
        return None
    token = tokens.get("access_token")
    if not isinstance(token, str) or not token.strip():
        return None
    access_claims = jwt_payload(token) or {}
    id_token = tokens.get("id_token")
    id_claims = jwt_payload(id_token) if isinstance(id_token, str) else None
    id_claims = id_claims or {}
    email = email_from_claims(id_claims) or email_from_claims(access_claims)
    if email is None:
        return None
    account_id = tokens.get("account_id")
    if not isinstance(account_id, str) or not account_id:
        account_id = _chatgpt_account_id(access_claims) or _chatgpt_account_id(id_claims)
    refresh = tokens.get("refresh_token")
    return Credential(
        email=email,
        access_token=token.strip(),
        expires_at=parse_time(access_claims.get("exp")),
        source=display_path(path, home),
        account_id=account_id,
        refresh_token=refresh.strip() if isinstance(refresh, str) and refresh.strip() else None,
        oauth_kind="codex",
    )


def _chatgpt_account_id(claims: dict) -> str | None:
    auth = claims.get("https://api.openai.com/auth")
    if not isinstance(auth, dict):
        return None
    value = auth.get("chatgpt_account_id")
    if isinstance(value, str) and value:
        return value
    return None


def _remaining_number(document: dict) -> int | float | None:
    for key in ("remaining", "remainingFraction", "remainingCredits", "remaining_credits", "remaining_percent"):
        parsed = number(document.get(key))
        if parsed is not None:
            return parsed
    return None


def _fraction(value: object) -> int | float | None:
    parsed = number(value)
    if parsed is None or parsed < 0 or parsed > 1:
        return None
    return parsed


def classify_chatgpt(payload: dict) -> tuple[str, int | float | None, str | None]:
    windows = _chatgpt_windows(payload)
    if not windows:
        return "unknown", None, None
    exhausted = [window for window in windows if window["used"] >= 100]
    chosen = exhausted or windows
    remaining = next((window["remaining"] for window in chosen if window["remaining"] is not None), None)
    resets = [window["resets_at"] for window in chosen if window["resets_at"] is not None]
    resets_at = iso_z(min(resets)) if resets else None
    state = "exhausted" if exhausted else "open"
    return state, remaining, resets_at


def _chatgpt_windows(payload: dict) -> list[dict]:
    windows: list[dict] = []
    rate_limit = payload.get("rate_limit")
    if isinstance(rate_limit, dict):
        windows.extend(_rate_windows(rate_limit))
    extras = payload.get("additional_rate_limits")
    if isinstance(extras, list):
        for extra in extras:
            if not isinstance(extra, dict):
                continue
            nested = extra.get("rate_limit")
            windows.extend(_rate_windows(nested if isinstance(nested, dict) else extra))
    return windows


def _rate_windows(rate_limit: dict) -> list[dict]:
    windows: list[dict] = []
    for slot in ("primary_window", "secondary_window"):
        window = rate_limit.get(slot)
        if not isinstance(window, dict):
            continue
        used = number(window.get("used_percent"))
        if used is None or used < 0:
            continue
        windows.append({
            "used": used,
            "remaining": _remaining_number(window),
            "resets_at": parse_time(window.get("reset_at")),
        })
    return windows


def classify_supergrok(payload: dict) -> tuple[str, int | float | None, str | None]:
    config = payload.get("config")
    if not isinstance(config, dict):
        return "unknown", None, None
    remaining = _remaining_number(config)
    period = config.get("currentPeriod")
    reset_value = None
    if isinstance(period, dict):
        reset_value = period.get("end")
    if reset_value is None:
        reset_value = config.get("billingPeriodEnd")
    resets_at = parse_time(reset_value)
    reset_text = iso_z(resets_at) if resets_at is not None else None
    if remaining is not None:
        state = "exhausted" if remaining <= 0 else "open"
        return state, remaining, reset_text
    used = number(config.get("creditUsagePercent"))
    if used is not None and used >= 100:
        return "exhausted", None, reset_text
    return "open", None, reset_text


def classify_antigravity(payload: dict, now: datetime) -> tuple[str, int | float | None, str | None]:
    groups = payload.get("groups")
    if not isinstance(groups, list) or not groups:
        return "unknown", None, None
    buckets = _antigravity_buckets(groups)
    if not buckets:
        return "open", None, None
    if _placeholder(buckets, now):
        return "unknown", None, None
    zeros = [bucket for bucket in buckets if bucket["remaining"] == 0]
    if zeros:
        resets = [bucket["resets_at"] for bucket in zeros if bucket["resets_at"] is not None]
        return "exhausted", zeros[0]["remaining"], iso_z(min(resets)) if resets else None
    positive = [bucket for bucket in buckets if bucket["remaining"] is not None and bucket["remaining"] > 0]
    if positive:
        lowest = min(bucket["remaining"] for bucket in positive)
        carriers = [bucket for bucket in positive if bucket["remaining"] == lowest and bucket["resets_at"] is not None]
        reset_text = iso_z(min(bucket["resets_at"] for bucket in carriers)) if carriers else None
        return "open", lowest, reset_text
    resets = [bucket["resets_at"] for bucket in buckets if bucket["resets_at"] is not None]
    return "open", None, iso_z(min(resets)) if resets else None


def _antigravity_buckets(groups: list) -> list[dict]:
    buckets: list[dict] = []
    for group in groups:
        if not isinstance(group, dict):
            continue
        raw_buckets = group.get("buckets")
        if not isinstance(raw_buckets, list):
            continue
        for bucket in raw_buckets:
            if not isinstance(bucket, dict):
                continue
            remaining = _fraction(_direct_remaining(bucket))
            buckets.append({
                "remaining": remaining,
                "resets_at": parse_time(bucket.get("resetTime")),
            })
    return buckets


def _direct_remaining(bucket: dict) -> object:
    if "remainingFraction" in bucket:
        return bucket.get("remainingFraction")
    nested = bucket.get("remaining")
    if isinstance(nested, dict):
        if "remainingFraction" in nested:
            return nested.get("remainingFraction")
        if nested.get("case") == "remainingFraction":
            return nested.get("value")
    return None


def _placeholder(buckets: list[dict], now: datetime) -> bool:
    figured = [bucket for bucket in buckets if bucket["remaining"] is not None]
    if len(figured) < 2:
        return False
    if any(bucket["remaining"] < 0.999 for bucket in figured):
        return False
    if any(bucket["resets_at"] is None for bucket in figured):
        return False
    target = now + PLACEHOLDER_RESET
    return all(abs(bucket["resets_at"] - target) <= PLACEHOLDER_TOLERANCE for bucket in figured)


def exhaustion_message(body: bytes) -> str | None:
    text = body.decode("utf-8", errors="ignore")
    if len(text) > 4000:
        text = text[:4000]
    lowered = text.lower()
    phrases = (
        "quota exhausted",
        "quota exceeded",
        "usage limit reached",
        "usage limit exceeded",
        "out of credits",
        "no remaining quota",
        "resource_exhausted",
        "resource exhausted",
    )
    if not any(phrase in lowered for phrase in phrases):
        return None
    compact = " ".join(text.split())
    return compact[:240]


def access_denied(body: bytes) -> bool:
    text = body.decode("utf-8", errors="ignore").lower()
    if len(text) > 4000:
        text = text[:4000]
    phrases = (
        "permission_denied",
        "permission denied",
        "do not have a valid license",
        "not licensed",
        "unlicensed",
    )
    return any(phrase in text for phrase in phrases)


def _allowed(url: str) -> bool:
    parsed = urllib.parse.urlparse(url)
    if parsed.scheme != "https":
        return False
    host = (parsed.hostname or "").lower()
    if host == "chatgpt.com" and parsed.path == "/backend-api/wham/usage":
        return True
    if host == "cli-chat-proxy.grok.com" and parsed.path == "/v1/billing":
        return True
    if host in CODE_ASSIST_HOSTS and parsed.path == "/v1internal:retrieveUserQuotaSummary":
        return True
    if host == "oauth2.googleapis.com" and parsed.path == "/token":
        return True
    if host == "auth.openai.com" and parsed.path == "/oauth/token":
        return True
    if host == "auth.x.ai" and parsed.path == "/oauth2/token":
        return True
    return False


def _request(transport: Transport, method: str, url: str, headers: dict[str, str], body: bytes | None) -> tuple[int, bytes] | None:
    if not _allowed(url):
        return None
    try:
        status, payload = transport(method, url, headers, body, 20)
    except (urllib.error.URLError, TimeoutError, OSError):
        return None
    return status, payload


def _json_body(payload: bytes) -> dict | None:
    try:
        parsed = json.loads(payload)
    except json.JSONDecodeError:
        return None
    return parsed if isinstance(parsed, dict) else None


def _valid_google_secret(secret: str) -> bool:
    prefix = _GOOGLE_SECRET_PREFIX
    if not secret.startswith(prefix):
        return False
    body = secret[len(prefix):]
    if len(body) != _GOOGLE_SECRET_LENGTH:
        return False
    if prefix in body:
        return False
    return True


def _secret_gap(secret: re.Match[str], chosen: re.Match[str]) -> tuple[int, int]:
    if secret.end() <= chosen.start():
        return chosen.start() - secret.end(), 1
    if chosen.end() <= secret.start():
        return secret.start() - chosen.end(), 0
    return 0, 0


def oauth_client_candidates(text: str, prefer_prefix: str | None = None) -> tuple[str, ...] | None:
    """Return a client id and the nearest valid secrets, closest first.

    A secret that still contains a second prefix, or is not 28 characters, is
    skipped. When ``prefer_prefix`` is set, only that client id is used.
    """
    ids = list(GOOGLE_CLIENT_RE.finditer(text))
    secrets = [match for match in GOOGLE_SECRET_RE.finditer(text) if _valid_google_secret(match.group(0))]
    if not ids or not secrets:
        return None
    chosen = None
    if prefer_prefix:
        for match in ids:
            if match.group(0).startswith(prefer_prefix):
                chosen = match
                break
        if chosen is None:
            return None
    else:
        chosen = ids[0]
    picked: list[str] = []
    for match in sorted(secrets, key=lambda item: _secret_gap(item, chosen)):
        value = match.group(0)
        if value in picked:
            continue
        picked.append(value)
        if len(picked) == 4:
            break
    if not picked:
        return None
    return (chosen.group(0), *picked)


def oauth_client_from_text(text: str, prefer_prefix: str | None = None) -> tuple[str, str] | None:
    """Pair a Google client id with the nearest single client secret in ``text``."""
    candidates = oauth_client_candidates(text, prefer_prefix)
    if candidates is None or len(candidates) < 2:
        return None
    return candidates[0], candidates[1]


def discover_agy_oauth_client(env: Mapping[str, str]) -> tuple[str, ...] | None:
    """Read Antigravity's Google client from the environment or from ``agy``."""
    client_id = env.get("NOTCHMETER_AGY_OAUTH_CLIENT_ID", "").strip()
    client_secret = env.get("NOTCHMETER_AGY_OAUTH_CLIENT_SECRET", "").strip()
    if client_id and client_secret:
        return (client_id, client_secret)
    binary = shutil.which("agy")
    if not binary:
        return None
    text = _binary_text(binary)
    if not text:
        return None
    return oauth_client_candidates(text, AGY_CLIENT_PREFIX)


def _binary_text(path: str) -> str:
    try:
        completed = subprocess.run(
            ["strings", path],
            check=False,
            capture_output=True,
            timeout=30,
        )
    except (OSError, subprocess.TimeoutExpired):
        completed = None
    if completed is not None and completed.returncode == 0 and completed.stdout:
        return completed.stdout.decode("utf-8", errors="ignore")
    try:
        data = Path(path).read_bytes()
    except OSError:
        return ""
    return _ascii_runs(data)


def _ascii_runs(data: bytes, minimum: int = 12) -> str:
    parts: list[str] = []
    current = bytearray()
    for byte in data:
        if 32 <= byte < 127:
            current.append(byte)
            continue
        if len(current) >= minimum:
            parts.append(current.decode("ascii"))
        current.clear()
    if len(current) >= minimum:
        parts.append(current.decode("ascii"))
    return "\n".join(parts)


def _oauth_clients(
    env: Mapping[str, str],
    provided: Mapping[str, tuple[str, ...]] | None,
) -> Mapping[str, tuple[str, ...]]:
    if provided is not None:
        return provided
    found = discover_agy_oauth_client(env)
    if found is None:
        return {}
    return {"antigravity": found}


def _issued(document: dict, now: datetime) -> tuple[str, str | None, datetime | None] | None:
    access = document.get("access_token")
    if not isinstance(access, str) or not access.strip():
        return None
    refresh = document.get("refresh_token")
    refresh_token = refresh.strip() if isinstance(refresh, str) and refresh.strip() else None
    expires = parse_time(document.get("expires_at"))
    if expires is None:
        expires = parse_time(document.get("expiry"))
    if expires is None:
        seconds = number(document.get("expires_in"))
        if seconds is not None and seconds > 0:
            expires = now + timedelta(seconds=float(seconds))
    if expires is None:
        claims = jwt_payload(access.strip())
        if claims:
            expires = parse_time(claims.get("exp"))
    return access.strip(), refresh_token, expires


def _refresh_form(transport: Transport, url: str, fields: dict[str, str]) -> dict | None:
    body = urllib.parse.urlencode(fields).encode("utf-8")
    headers = {
        "Content-Type": "application/x-www-form-urlencoded",
        "Accept": "application/json",
        "User-Agent": USER_AGENT,
    }
    response = _request(transport, "POST", url, headers, body)
    if response is None or response[0] != 200:
        return None
    return _json_body(response[1])


def _refresh_google(
    cred: Credential,
    transport: Transport,
    client: tuple[str, ...],
    now: datetime,
) -> Credential | None:
    if len(client) < 2 or not cred.refresh_token or not client[0]:
        return None
    client_id = client[0]
    for client_secret in client[1:]:
        if not client_secret:
            continue
        document = _refresh_form(transport, GOOGLE_TOKEN_URL, {
            "grant_type": "refresh_token",
            "refresh_token": cred.refresh_token,
            "client_id": client_id,
            "client_secret": client_secret,
        })
        if document is None:
            continue
        issued = _issued(document, now)
        if issued is None:
            continue
        access, refresh, expires = issued
        kept_refresh = refresh or cred.refresh_token
        _persist_google(cred, access, kept_refresh, expires)
        return replace(
            cred,
            access_token=access,
            expires_at=expires,
            refresh_token=kept_refresh,
        )
    return None


def _refresh_openai(cred: Credential, transport: Transport, now: datetime) -> Credential | None:
    if not cred.refresh_token:
        return None
    body = json.dumps({
        "client_id": OPENAI_CLIENT_ID,
        "grant_type": "refresh_token",
        "refresh_token": cred.refresh_token,
    }).encode("utf-8")
    headers = {
        "Content-Type": "application/json",
        "Accept": "application/json",
        "User-Agent": USER_AGENT,
    }
    response = _request(transport, "POST", OPENAI_TOKEN_URL, headers, body)
    if response is None or response[0] != 200:
        return None
    document = _json_body(response[1])
    if document is None:
        return None
    issued = _issued(document, now)
    if issued is None:
        return None
    access, refresh, expires = issued
    return replace(
        cred,
        access_token=access,
        expires_at=expires,
        refresh_token=refresh or cred.refresh_token,
    )


def _atomic_json(path: Path, payload: dict) -> None:
    """Best-effort token persistence: a failure keeps the old store intact and is not fatal."""
    try:
        _atomic_write_bytes(path, (json.dumps(payload, indent=2) + "\n").encode("utf-8"))
    except OSError:
        return


def _atomic_write_bytes(path: Path, data: bytes) -> None:
    """Write data to path atomically with 0600 permissions.

    Uses a unique O_EXCL temp file in the same directory (no predictable name to pre-plant a
    symlink at), fsyncs it, then renames. On any failure the temp file is removed and the
    previous file is untouched.
    """
    fd, name = tempfile.mkstemp(prefix="." + path.name + ".", suffix=".tmp", dir=path.parent)
    temporary = Path(name)
    try:
        with os.fdopen(fd, "wb") as handle:
            os.fchmod(handle.fileno(), 0o600)
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    except BaseException:
        try:
            temporary.unlink()
        except OSError:
            pass
        raise
    os.chmod(path, 0o600)


def _expiry_replacement(previous: object, expires_at: datetime | None) -> object:
    if expires_at is None:
        return previous
    if isinstance(previous, (int, float)) and not isinstance(previous, bool):
        seconds = expires_at.timestamp()
        if previous > 10_000_000_000:
            return int(seconds * 1000)
        return int(seconds)
    return iso_z(expires_at)


def _assign_expiry(container: dict, expires_at: datetime | None) -> None:
    if expires_at is None:
        return
    for key in ("expiry", "expiry_date", "expires_at"):
        if key in container:
            container[key] = _expiry_replacement(container.get(key), expires_at)
            return
    container["expiry"] = iso_z(expires_at)


def _persist_google(cred: Credential, access_token: str, refresh_token: str | None, expires_at: datetime | None) -> None:
    """Write a refreshed Antigravity token back when the file still matches.

    A file that no longer holds this refresh token is left alone. The client
    secret is never written.
    """
    if cred.oauth_kind != "antigravity" or not cred.store_path or not cred.refresh_token:
        return
    path = Path(cred.store_path)
    payload = read_json(path)
    if payload is None:
        return
    current_access, current_refresh, _expiry = _google_material(payload)
    if current_refresh != cred.refresh_token and current_access != cred.access_token:
        return
    nested = payload.get("token")
    if isinstance(nested, dict) and isinstance(nested.get("access_token"), str):
        nested["access_token"] = access_token
        if refresh_token:
            nested["refresh_token"] = refresh_token
        _assign_expiry(nested, expires_at)
    elif isinstance(payload.get("access_token"), str):
        payload["access_token"] = access_token
        if refresh_token:
            payload["refresh_token"] = refresh_token
        _assign_expiry(payload, expires_at)
    elif isinstance(payload.get("token"), str):
        payload["token"] = access_token
        if refresh_token:
            payload["refresh_token"] = refresh_token
        _assign_expiry(payload, expires_at)
    else:
        return
    _atomic_json(path, payload)


def _persist_grok(cred: Credential, access_token: str, refresh_token: str | None, expires_at: datetime | None) -> None:
    if not cred.store_path:
        return
    path = Path(cred.store_path)
    payload = read_json(path)
    if payload is None:
        return
    if cred.store_key is None:
        entry = payload
    else:
        entry = payload.get(cred.store_key)
    if not isinstance(entry, dict):
        return
    entry["key"] = access_token
    entry["access_token"] = access_token
    if refresh_token:
        entry["refresh_token"] = refresh_token
    if expires_at is not None:
        entry["expires_at"] = iso_z(expires_at)
    _atomic_json(path, payload)


def _refresh_supergrok(cred: Credential, transport: Transport, now: datetime) -> Credential | None:
    if not cred.refresh_token or not cred.grok_client_id:
        return None
    document = _refresh_form(transport, XAI_TOKEN_URL, {
        "grant_type": "refresh_token",
        "refresh_token": cred.refresh_token,
        "client_id": cred.grok_client_id,
    })
    if document is None:
        return None
    issued = _issued(document, now)
    if issued is None:
        return None
    access, refresh, expires = issued
    kept_refresh = refresh or cred.refresh_token
    _persist_grok(cred, access, kept_refresh, expires)
    return replace(cred, access_token=access, expires_at=expires, refresh_token=kept_refresh)


def _refresh_ready(cred: Credential, clients: Mapping[str, tuple[str, ...]]) -> bool:
    if not cred.refresh_token:
        return False
    if cred.oauth_kind == "supergrok":
        return bool(cred.grok_client_id)
    if cred.oauth_kind == "codex":
        return True
    if cred.oauth_kind == "antigravity":
        client = clients.get("antigravity")
        return client is not None and len(client) >= 2 and bool(client[0]) and any(client[1:])
    if cred.oauth_kind == "gemini":
        return False
    return False


def _silent_refresh(
    cred: Credential,
    transport: Transport,
    clients: Mapping[str, tuple[str, ...]],
    now: datetime,
) -> Credential | None:
    if cred.oauth_kind == "supergrok":
        return _refresh_supergrok(cred, transport, now)
    if cred.oauth_kind == "codex":
        return _refresh_openai(cred, transport, now)
    if cred.oauth_kind == "antigravity":
        client = clients.get("antigravity")
        if client is None:
            return None
        return _refresh_google(cred, transport, client, now)
    if cred.oauth_kind == "gemini":
        return None
    return None


def probe_chatgpt(
    email: str,
    creds: list[Credential],
    expired: list[Credential],
    nameless: int,
    transport: Transport,
    clients: Mapping[str, tuple[str, ...]],
    now: datetime,
) -> tuple[dict, Note]:
    def call(cred: Credential) -> tuple[str, int | float | None, str | None] | None:
        return _call_chatgpt(cred, transport)

    return _probe_matching(
        email,
        "chatgpt",
        creds,
        expired,
        nameless,
        PATH_CHATGPT,
        "Codex auth.json",
        call,
        transport,
        clients,
        now,
    )


def probe_supergrok(
    email: str,
    creds: list[Credential],
    expired: list[Credential],
    nameless: int,
    transport: Transport,
    clients: Mapping[str, tuple[str, ...]],
    now: datetime,
) -> tuple[dict, Note]:
    def call(cred: Credential) -> tuple[str, int | float | None, str | None] | None:
        return _call_supergrok(cred, transport)

    return _probe_matching(
        email,
        "supergrok",
        creds,
        expired,
        nameless,
        PATH_SUPERGROK,
        "~/.grok/auth.json",
        call,
        transport,
        clients,
        now,
    )


def probe_antigravity(
    email: str,
    creds: list[Credential],
    expired: list[Credential],
    nameless: int,
    transport: Transport,
    clients: Mapping[str, tuple[str, ...]],
    now: datetime,
) -> tuple[dict, Note]:
    def call(cred: Credential) -> tuple[str, int | float | None, str | None] | None:
        return _call_antigravity(cred, transport, now)

    return _probe_matching(
        email,
        "antigravity",
        creds,
        expired,
        nameless,
        PATH_ANTIGRAVITY,
        "antigravity-oauth-token or oauth_creds.json",
        call,
        transport,
        clients,
        now,
    )


def _probe_matching(email, provider, creds, expired, nameless, code_path, label, call, transport, clients, now) -> tuple[dict, Note]:
    matched = [cred for cred in creds if cred.email == email]
    expired_matched = [cred for cred in expired if cred.email == email]
    if not matched and not expired_matched:
        detail = f"no {label} names this email"
        if nameless:
            detail += f"; {nameless} credential file(s) had no email and were not queried"
        return unknown_row(email, provider), Note(email, provider, "unknown", detail, code_path)
    usable = list(matched)
    attempted = False
    if not usable:
        for cred in expired_matched:
            if _refresh_ready(cred, clients):
                attempted = True
            fresh = _silent_refresh(cred, transport, clients, now)
            if fresh is not None and not _expired(fresh.expires_at, now):
                usable.append(fresh)
    if not usable and expired_matched:
        reason = "silent refresh failed" if attempted else "silent refresh unavailable"
        return unknown_row(email, provider), Note(
            email,
            provider,
            "unknown",
            f"stored access token in {expired_matched[0].source} is expired; {reason}",
            code_path,
        )
    readings = []
    for cred in usable:
        reading = call(cred)
        if reading is not None:
            readings.append((cred, reading))
    if not readings:
        return unknown_row(email, provider), Note(
            email,
            provider,
            "unknown",
            f"credential in {usable[0].source} did not return a quota document",
            code_path,
        )
    unique = {(state, remaining, resets_at) for _, (state, remaining, resets_at) in readings}
    if len(unique) != 1:
        return unknown_row(email, provider), Note(
            email,
            provider,
            "unknown",
            "live responses for this email disagreed, so none was chosen",
            code_path,
        )
    state, remaining, resets_at = readings[0][1]
    detail = f"live {state} from {readings[0][0].source}"
    return row(email, provider, state, remaining, resets_at), Note(email, provider, state, detail, code_path)


def _call_chatgpt(cred: Credential, transport: Transport) -> tuple[str, int | float | None, str | None] | None:
    headers = {
        "Authorization": f"Bearer {cred.access_token}",
        "Accept": "application/json",
        "User-Agent": USER_AGENT,
    }
    if cred.account_id:
        headers["ChatGPT-Account-Id"] = cred.account_id
    response = _request(transport, "GET", CHATGPT_URL, headers, None)
    if response is None:
        return None
    status, payload = response
    if status != 200:
        if exhaustion_message(payload):
            return "exhausted", None, None
        return None
    document = _json_body(payload)
    if document is None:
        return None
    state, remaining, resets_at = classify_chatgpt(document)
    if state == "unknown":
        return None
    return state, remaining, resets_at


def _call_supergrok(cred: Credential, transport: Transport) -> tuple[str, int | float | None, str | None] | None:
    headers = {
        "Authorization": f"Bearer {cred.access_token}",
        "Accept": "application/json",
        "User-Agent": USER_AGENT,
        "x-grok-client-mode": "cli",
    }
    response = _request(transport, "GET", SUPERGROK_URL, headers, None)
    if response is None:
        return None
    status, payload = response
    if status != 200:
        if exhaustion_message(payload):
            return "exhausted", None, None
        return None
    document = _json_body(payload)
    if document is None:
        return None
    return classify_supergrok(document)


def _call_antigravity(cred: Credential, transport: Transport, now: datetime) -> tuple[str, int | float | None, str | None] | None:
    hosts: list[str] = []
    if cred.logged_host in CODE_ASSIST_HOSTS:
        hosts.append(cred.logged_host)
    for host in CODE_ASSIST_HOSTS:
        if host not in hosts:
            hosts.append(host)
    headers = {
        "Authorization": f"Bearer {cred.access_token}",
        "Content-Type": "application/json",
        "Accept": "application/json",
        "User-Agent": "antigravity",
        "Client-Metadata": '{"ideType":"ANTIGRAVITY","platform":"MACOS","pluginType":"GEMINI"}',
    }
    saw_placeholder = False
    for host in hosts:
        url = f"https://{host}/v1internal:retrieveUserQuotaSummary"
        response = _request(transport, "POST", url, headers, b"{}")
        if response is None:
            continue
        status, payload = response
        if status in (401, 403):
            if access_denied(payload):
                return None
            if status == 403 and exhaustion_message(payload):
                return "exhausted", None, None
            return None
        if status != 200:
            continue
        document = _json_body(payload)
        if document is None:
            continue
        state, remaining, resets_at = classify_antigravity(document, now)
        if state == "unknown" and remaining is None and _looks_like_summary(document):
            saw_placeholder = True
            continue
        if state == "unknown":
            continue
        return state, remaining, resets_at
    if saw_placeholder:
        return None
    return None


def _looks_like_summary(document: dict) -> bool:
    groups = document.get("groups")
    return isinstance(groups, list) and len(groups) > 0


def build_report(
    home: Path,
    *,
    env: Mapping[str, str] | None = None,
    now: datetime | None = None,
    transport: Transport | None = None,
    oauth_clients: Mapping[str, tuple[str, ...]] | None = None,
) -> tuple[dict, list[Note]]:
    environment = env if env is not None else os.environ
    moment = now if now is not None else datetime.now(timezone.utc)
    client = transport if transport is not None else urllib_transport
    clients = _oauth_clients(environment, oauth_clients)
    agy_ok, agy_expired, agy_nameless = discover_antigravity(home, environment, moment)
    codex_ok, codex_expired, codex_nameless = discover_codex(home, environment, moment)
    grok_ok, grok_expired, grok_nameless = discover_supergrok(home, environment, moment)
    accounts = []
    notes: list[Note] = []
    for email, provider in ROSTER:
        if provider == "chatgpt":
            built, note = probe_chatgpt(email, codex_ok, codex_expired, codex_nameless, client, clients, moment)
        elif provider == "supergrok":
            built, note = probe_supergrok(email, grok_ok, grok_expired, grok_nameless, client, clients, moment)
        elif provider == "antigravity":
            built, note = probe_antigravity(email, agy_ok, agy_expired, agy_nameless, client, clients, moment)
        else:
            raise AssertionError(provider)
        accounts.append(built)
        notes.append(note)
    report = {"updated_at": iso_z(moment), "accounts": accounts}
    return report, notes


def urllib_transport(method: str, url: str, headers: Mapping[str, str], body: bytes | None, timeout: float) -> tuple[int, bytes]:
    request = urllib.request.Request(url, data=body, headers=dict(headers), method=method)
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return response.status, response.read()
    except urllib.error.HTTPError as error:
        return error.code, error.read()


def validate_report(report: object) -> None:
    """Reject anything that does not match the quota.json schema before it reaches disk."""
    if not isinstance(report, dict) or set(report) != {"updated_at", "accounts"}:
        raise ValueError("report must have exactly updated_at and accounts")
    if parse_time(report["updated_at"]) is None or not isinstance(report["updated_at"], str):
        raise ValueError("updated_at must be an ISO 8601 timestamp with a zone")
    accounts = report["accounts"]
    if not isinstance(accounts, list):
        raise ValueError("accounts must be a list")
    keys = {"email", "provider", "state", "remaining", "resets_at"}
    for account in accounts:
        if not isinstance(account, dict) or set(account) != keys:
            raise ValueError("account rows must have exactly " + ", ".join(sorted(keys)))
        if not isinstance(account["email"], str) or not account["email"]:
            raise ValueError("email must be a non-empty string")
        if account["provider"] not in PROVIDERS:
            raise ValueError("unknown provider")
        if account["state"] not in STATES:
            raise ValueError("unknown state")
        remaining = account["remaining"]
        if remaining is not None and (number(remaining) is None or remaining < 0):
            raise ValueError("remaining must be null or a non-negative number")
        resets_at = account["resets_at"]
        if resets_at is not None and (not isinstance(resets_at, str) or parse_time(resets_at) is None):
            raise ValueError("resets_at must be null or an ISO 8601 timestamp")
        if account["state"] == "unknown" and (remaining is not None or resets_at is not None):
            raise ValueError("an unknown row must not carry remaining or resets_at")


def write_quota(path: Path, report: dict) -> None:
    """Validate, then write atomically: a unique temp file in the same directory, fsync, rename.

    A failure at any step leaves the previous quota.json untouched and no temp file behind.
    """
    validate_report(report)
    data = (json.dumps(report, indent=2) + "\n").encode("utf-8")
    path.parent.mkdir(parents=True, exist_ok=True)
    os.chmod(path.parent, 0o700)
    _atomic_write_bytes(path, data)


def main(argv: list[str] | None = None, *, home: Path | None = None, env: Mapping[str, str] | None = None, transport: Transport | None = None, now: datetime | None = None) -> int:
    del argv
    root = home if home is not None else Path.home()
    report, notes = build_report(root, env=env, now=now, transport=transport)
    destination = quota_path(root)
    try:
        write_quota(destination, report)
    except (OSError, ValueError) as error:
        # Never echo the report or any token here; the error names only the path and the reason.
        print(f"could not write {destination}: {type(error).__name__}: {error}", file=sys.stderr)
        return 1
    json.dump(report, sys.stdout, indent=2)
    sys.stdout.write("\n")
    for note in notes:
        print(f"{note.email} {note.provider} {note.state}: {note.detail} ({note.code_path})", file=sys.stderr)
    print(f"wrote {destination}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
