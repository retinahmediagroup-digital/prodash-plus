"""Original CSV files in the private Supabase Storage bucket (default: raw-uploads).

Uses the secret key from .env, so run it only on trusted machines.
"""

from pathlib import Path

import requests

from prodash.config import settings


def auth_headers(key: str) -> dict[str, str]:
    """Headers for a Supabase server key.

    A secret key (sb_secret_...) is not a JWT: it goes in `apikey` only. A legacy
    service_role key is a JWT and goes in both headers. Supabase retires legacy
    keys at the end of 2026.
    """
    if key.startswith("sb_"):
        return {"apikey": key}
    return {"Authorization": f"Bearer {key}", "apikey": key}


def _base() -> tuple[str, dict[str, str]]:
    s = settings()
    if not (s.supabase_url and s.service_key):
        raise RuntimeError("SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY must be set in .env for storage access.")
    return f"{s.supabase_url.rstrip('/')}/storage/v1/object", auth_headers(s.service_key)


def upload(data: bytes, path: str, content_type: str = "text/csv") -> str:
    """Store bytes at bucket/path (overwrites the same path). Returns the path."""
    base, headers = _base()
    resp = requests.post(
        f"{base}/{settings().bucket}/{path}",
        headers={**headers, "Content-Type": content_type, "x-upsert": "true"},
        data=data,
        timeout=120,
    )
    resp.raise_for_status()
    return path


def download(path: str) -> bytes:
    base, headers = _base()
    resp = requests.get(f"{base}/{settings().bucket}/{path}", headers=headers, timeout=120)
    resp.raise_for_status()
    return resp.content


def download_to(path: str, dest: str | Path) -> Path:
    dest = Path(dest)
    dest.parent.mkdir(parents=True, exist_ok=True)
    dest.write_bytes(download(path))
    return dest
