"""Receive data: register it in ops.load_log and land it untouched in bronze.

    from prodash.landing import land_file
    result = land_file("data/prodairy_hf_2026-03_to_09.csv", branch_id="HF")
    result            # load_id, status, rows, shape, unknown columns, date range

API feeds land through land_batch() instead, inside the caller's transaction
(see prodash.sync). Both take the same path:
  1. SHA-256 fingerprint; the same data is never landed twice (a rejected or
     failed attempt can be retried after fixing HEADER_ALIASES or a field map).
  2. Stores the original in Storage: raw-uploads/<client>/<branch|ALL>/<date>/<sha>.<csv|json>
  3. Checks the columns against the data contract (prodash.contract).
  4. Writes every row, as text, to bronze.receipts_raw; unknown columns go to `extra`.
  5. Marks the load `loaded` (rows_loaded = rows_in_file) or `rejected` with the reason.

Cleansing to silver and publishing to gold happen after this, in the worker.
"""

import hashlib
import io
import json
import warnings
from dataclasses import dataclass, field
from datetime import date
from pathlib import Path

import pandas as pd
import psycopg
from psycopg.types.json import Jsonb

from prodash import storage
from prodash.config import settings
from prodash.contract import CONTRACT_COLUMNS, HeaderReport, check_headers
from prodash.db import copy_rows, transaction

BRONZE_COLUMNS = ["load_id", "row_num", "client_id", *CONTRACT_COLUMNS, "extra"]
LOCAL_TZ = "Africa/Harare"
_ISO = r"^\d{4}-\d{2}-\d{2}"                          # 2026-10-05, 2026-10-05T10:42...
_OFFSET = r"(?:Z|[+-]\d{2}(?::?\d{2})?)$"             # ...Z, ...+02:00, ...+0200


@dataclass
class LandingResult:
    load_id: int | None
    status: str                      # loaded | rejected | duplicate | empty (API batch with no rows)
    source_file: str
    rows_in_file: int
    shape: str | None = None
    min_receipt_date: date | None = None
    max_receipt_date: date | None = None
    unparsed_dates: int = 0
    unknown_columns: list[str] = field(default_factory=list)
    message: str | None = None


def read_raw_csv(data: bytes, encoding: str | None = None) -> pd.DataFrame:
    """Every cell as text, exactly as in the file (no NaN guessing, no type inference)."""
    for enc in [encoding] if encoding else ["utf-8-sig", "cp1252"]:
        try:
            df = pd.read_csv(io.BytesIO(data), dtype=str, keep_default_na=False, encoding=enc)
            return df.apply(lambda s: s.str.strip())
        except UnicodeDecodeError:
            continue
    raise ValueError("Could not decode the file as UTF-8 or Windows-1252; pass encoding=...")


def _as_text(value) -> str:
    if value is None:
        return ""
    if isinstance(value, (dict, list)):
        return json.dumps(value, sort_keys=True, ensure_ascii=False, default=str)
    return str(value).strip()


def records_frame(records: list[dict]) -> pd.DataFrame:
    """API records as a frame of text columns, like a CSV read by read_raw_csv."""
    columns = list(dict.fromkeys(key for rec in records for key in rec))
    rows = [[_as_text(rec.get(col)) for col in columns] for rec in records]
    return pd.DataFrame(rows, columns=columns, dtype=str)


def canonical_json(records: list[dict]) -> bytes:
    """The batch as stored and fingerprinted: keys sorted, compact, UTF-8."""
    return json.dumps(records, sort_keys=True, separators=(",", ":"), ensure_ascii=False,
                      default=str).encode("utf-8")


def parse_receipt_dates(values: pd.Series, date_format: str | None, dayfirst: bool) -> pd.Series:
    """Receipt times as naive Harare time; unparseable values become NaT.

    ISO 8601 values (2026-10-05, 2026-10-05T10:42:00+02:00) are always read
    year-month-day, and times with a UTC offset are converted to Harare time;
    dayfirst applies only to other formats (17/04/2026).
    """
    values = values.replace("", None)

    def naive(parsed: pd.Series) -> pd.Series:
        if isinstance(parsed.dtype, pd.DatetimeTZDtype):
            parsed = parsed.dt.tz_convert(LOCAL_TZ).dt.tz_localize(None)
        return parsed.astype("datetime64[us]")

    with warnings.catch_warnings():
        warnings.simplefilter("ignore", UserWarning)   # pandas' format-inference notices
        if date_format:
            return naive(pd.to_datetime(values, format=date_format, errors="coerce"))
        text = values.astype("string")
        iso = text.str.match(_ISO).fillna(False).astype(bool)
        aware = iso & text.str.contains(_OFFSET).fillna(False).astype(bool)
        out = pd.Series(pd.NaT, index=values.index, dtype="datetime64[us]")
        parts = [
            (aware, dict(format="ISO8601", utc=True)),
            (iso & ~aware, dict(format="ISO8601")),
            (~iso, dict(dayfirst=dayfirst)),
        ]
        for mask, kwargs in parts:
            if mask.any():
                out[mask] = naive(pd.to_datetime(values[mask], errors="coerce", **kwargs))
    return out


def _land(
    conn: psycopg.Connection,
    df: pd.DataFrame,
    data: bytes,
    *,
    source: str,
    source_file: str,
    branch_id: str | None,
    client_id: str,
    uploaded_by: str | None,
    date_format: str | None,
    dayfirst: bool,
    store: bool,
    extension: str,
    content_type: str,
) -> LandingResult:
    """Steps 1-5 above for one CSV file or API batch, inside the caller's transaction."""
    sha = hashlib.sha256(data).hexdigest()
    report: HeaderReport = check_headers(list(df.columns))
    result = LandingResult(load_id=None, status="rejected", source_file=source_file,
                           rows_in_file=len(df), shape=report.shape, unknown_columns=report.unknown)

    existing = conn.execute(
        "select load_id, status from ops.load_log where client_id = %s and file_sha256 = %s for update",
        (client_id, sha),
    ).fetchone()
    if existing and existing[1] not in ("rejected", "failed"):
        result.load_id, result.status = existing[0], "duplicate"
        result.message = f"Already received as load {existing[0]} (status {existing[1]}); not landed again."
        return result

    storage_path = f"{client_id}/{branch_id or 'ALL'}/{date.today():%Y-%m-%d}/{sha}.{extension}"
    if existing:  # retry of a rejected/failed attempt: reuse its load_id
        load_id = existing[0]
        conn.execute("delete from bronze.receipts_raw where load_id = %s", (load_id,))
        conn.execute(
            """update ops.load_log
                  set status = 'started', source = %s, source_file = %s, storage_path = %s, branch_id = %s,
                      rows_in_file = %s, rows_loaded = null, file_shape = %s, uploaded_by = %s,
                      error_message = null, min_receipt_date = null, max_receipt_date = null,
                      started_at = now(), finished_at = null
                where load_id = %s""",
            (source, source_file, storage_path, branch_id, len(df), report.shape, uploaded_by, load_id),
        )
    else:
        load_id = conn.execute(
            """insert into ops.load_log (client_id, source, source_file, file_sha256, storage_path,
                                        branch_id, rows_in_file, file_shape, uploaded_by)
               values (%s, %s, %s, %s, %s, %s, %s, %s, %s) returning load_id""",
            (client_id, source, source_file, sha, storage_path, branch_id, len(df), report.shape, uploaded_by),
        ).fetchone()[0]
    result.load_id = load_id

    def reject(message: str) -> LandingResult:
        conn.execute(
            "update ops.load_log set status = 'rejected', error_message = %s, finished_at = now() where load_id = %s",
            (message, load_id),
        )
        result.message = message
        return result

    if not report.ok:
        parts = []
        if report.missing:
            parts.append("missing columns: " + ", ".join(report.missing))
        if report.duplicates:
            parts.append("columns mapped twice: " + ", ".join(report.duplicates))
        return reject("Header check failed; " + "; ".join(parts) +
                      ". Add the real column names to prodash.contract.HEADER_ALIASES (or the feed's field map) and retry.")
    if df.empty:
        return reject("No data rows.")

    # rename contract columns only; unknown columns keep their original name for `extra`
    renamed = df.rename(columns={h: t for h, t in report.mapping.items() if t in CONTRACT_COLUMNS})
    dates = parse_receipt_dates(renamed["receipt_datetime"], date_format, dayfirst)
    result.unparsed_dates = int(dates.isna().sum())
    if dates.notna().sum() == 0:
        return reject("No receipt_datetime value could be parsed; pass date_format=..., e.g. '%Y-%m-%d %H:%M'.")
    result.min_receipt_date = dates.min().date()
    result.max_receipt_date = dates.max().date()

    if store:
        storage.upload(data, storage_path, content_type=content_type)

    unknown = report.unknown

    def rows():
        for i, rec in enumerate(renamed.to_dict("records"), start=1):
            extra = {c: rec[c] for c in unknown if rec.get(c, "") != ""}
            yield [load_id, i, client_id,
                   *[(rec.get(c) or None) for c in CONTRACT_COLUMNS],
                   Jsonb(extra) if extra else None]

    copy_rows(conn, "bronze.receipts_raw", BRONZE_COLUMNS, rows())

    conn.execute(
        """update ops.load_log
              set status = 'loaded', rows_loaded = %s, min_receipt_date = %s, max_receipt_date = %s,
                  finished_at = now()
            where load_id = %s""",
        (len(df), result.min_receipt_date, result.max_receipt_date, load_id),
    )
    result.status = "loaded"
    if result.unparsed_dates:
        result.message = (f"{result.unparsed_dates} rows have an unparseable receipt_datetime; "
                          "they are in bronze and will be rejected in silver.")
    return result


def land_file(
    path: str | Path,
    branch_id: str | None = None,
    *,
    client_id: str | None = None,
    uploaded_by: str | None = None,
    date_format: str | None = None,
    dayfirst: bool = True,
    encoding: str | None = None,
    store: bool = True,
) -> LandingResult:
    """Land one CSV. branch_id is the file's branch (e.g. 'HF'); None for an all-branch file."""
    path = Path(path)
    data = path.read_bytes()
    df = read_raw_csv(data, encoding)
    with transaction() as conn:
        return _land(conn, df, data, source="csv", source_file=path.name, branch_id=branch_id,
                     client_id=client_id or settings().client_id, uploaded_by=uploaded_by,
                     date_format=date_format, dayfirst=dayfirst, store=store,
                     extension="csv", content_type="text/csv")


def land_batch(
    conn: psycopg.Connection,
    records: list[dict],
    *,
    branch_id: str,
    batch_label: str,
    source: str = "api",
    client_id: str | None = None,
    date_format: str | None = None,
    dayfirst: bool = False,
    store: bool = True,
) -> LandingResult:
    """Land one batch of API records: flat dicts keyed by contract column (see prodash.sources).

    Runs in the caller's transaction, so the feed's cursor can move in the same
    commit. Keys outside the contract are kept in `extra`; an empty branch is
    filled with branch_id. The stored JSON is the batch exactly as landed.
    """
    if not records:
        return LandingResult(load_id=None, status="empty", source_file=batch_label, rows_in_file=0)
    records = [{**rec, "branch": rec.get("branch") or branch_id} for rec in records]
    return _land(conn, records_frame(records), canonical_json(records), source=source,
                 source_file=batch_label, branch_id=branch_id, client_id=client_id or settings().client_id,
                 uploaded_by=None, date_format=date_format, dayfirst=dayfirst, store=store,
                 extension="json", content_type="application/json")
