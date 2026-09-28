"""Database access for notebooks and pipeline jobs.

    from prodash.db import read_sql, transaction
    branches = read_sql("select * from gold.dim_branch")
    with transaction() as conn:          # commits on success, rolls back on error
        conn.execute("update ops.load_log set ... where load_id = %s", (load_id,))
"""

from collections.abc import Iterable, Iterator, Sequence
from contextlib import contextmanager
from functools import lru_cache

import pandas as pd
import psycopg
from psycopg import sql
from sqlalchemy import create_engine
from sqlalchemy.engine import Engine

from prodash.config import settings


def _sqlalchemy_url(url: str) -> str:
    # psycopg 3 driver for SQLAlchemy
    for prefix in ("postgresql://", "postgres://"):
        if url.startswith(prefix):
            return "postgresql+psycopg://" + url[len(prefix):]
    return url


@lru_cache(maxsize=1)
def engine() -> Engine:
    return create_engine(_sqlalchemy_url(settings().db_url), pool_pre_ping=True)


def read_sql(query: str, params: dict | None = None) -> pd.DataFrame:
    """Run a SELECT and return a DataFrame. Use %(name)s placeholders with params."""
    with engine().connect() as conn:
        # a plain string goes to psycopg as-is, so %(name)s placeholders work
        return pd.read_sql_query(query, conn, params=params)


@contextmanager
def transaction() -> Iterator[psycopg.Connection]:
    """One database transaction: everything inside commits together or not at all."""
    with psycopg.connect(settings().db_url) as conn:
        with conn.transaction():
            yield conn


def copy_rows(
    conn: psycopg.Connection,
    table: str,
    columns: Sequence[str],
    rows: Iterable[Sequence],
) -> None:
    """Bulk-insert rows with COPY (fast for whole files). table is 'schema.name'."""
    schema, name = table.split(".", 1)
    stmt = sql.SQL("copy {}.{} ({}) from stdin").format(
        sql.Identifier(schema),
        sql.Identifier(name),
        sql.SQL(", ").join(sql.Identifier(c) for c in columns),
    )
    with conn.cursor() as cur, cur.copy(stmt) as copy:
        for row in rows:
            copy.write_row(row)
