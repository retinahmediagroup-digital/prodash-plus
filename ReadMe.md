# ProDash+
CRM and BI-led sales-push platform for ProDairy, built and operated by RMG Digital.

- `docs/` - ProDash+ SSOT (single source of truth), architecture, data dictionary, runbooks
- `sql/` - database schema and migrations (see `sql/README.md`)
- `prodash/` - Python package: CSV landing (bronze), cleansing, scoring
- `notebooks/` - working notebooks (see `notebooks/README.md` for setup)
- `dbt/` - silver and gold models (later phase)
- `web/` - Next.js web application
- `tests/` - SQL and Python tests

Customer data never goes in this repository.
