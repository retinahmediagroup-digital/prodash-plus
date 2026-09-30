"""API feeds that land shop data in bronze (see prodash.sync)."""

from prodash.sources.base import Page, Source, SourceNotReady
from prodash.sources.pos_api import PosApi

SOURCES: dict[str, Source] = {s.name: s for s in (PosApi(),)}

__all__ = ["SOURCES", "Page", "Source", "SourceNotReady"]
