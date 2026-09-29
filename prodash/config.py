"""Settings from the repo's .env file (never committed). See .env.example."""

import os
from dataclasses import dataclass
from functools import lru_cache

from dotenv import find_dotenv, load_dotenv


@dataclass(frozen=True)
class Settings:
    db_url: str
    supabase_url: str | None
    service_key: str | None
    client_id: str
    bucket: str


@lru_cache(maxsize=1)
def settings() -> Settings:
    # usecwd: finds the repo's .env from any notebook folder
    load_dotenv(find_dotenv(usecwd=True))
    db_url = os.getenv("PRODASH_DB_URL")
    if not db_url:
        raise RuntimeError(
            "PRODASH_DB_URL is not set. Copy .env.example to .env and paste the "
            "Supabase Session pooler connection string (port 5432)."
        )
    return Settings(
        db_url=db_url,
        supabase_url=os.getenv("SUPABASE_URL"),
        service_key=os.getenv("SUPABASE_SERVICE_ROLE_KEY"),
        client_id=os.getenv("PRODASH_CLIENT_ID", "PRODAIRY"),
        bucket=os.getenv("PRODASH_BUCKET", "raw-uploads"),
    )
