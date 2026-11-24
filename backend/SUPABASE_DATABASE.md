# Local API with Supabase PostgreSQL

The game database was migrated to the existing Singapore Supabase project on
24 November 2026. FastAPI and both workers still run locally. Cloud Run and the
official CI/CD release workflow are separate, pending work.

The ignored `backend/.env` selects `compose.supabase.yaml` through `COMPOSE_FILE`.
Run routine commands from `backend/`; the API remains on localhost port 8000,
so the existing Tailscale route and iOS game API URL remain applicable.

```powershell
docker compose up -d --wait --wait-timeout 90
docker compose ps
docker compose logs --tail 10 shop maintenance
docker compose down
```

The `maintenance` profile and existing family flags remain enabled in this
machine's ignored environment. API connections are bounded to 2; each worker is
bounded to 1, with no overflow. Stop the full stack when pausing local testing.
No schema migration, seeding or publication runs on normal startup.

## Backend releases with schema changes

Validate changes against disposable local PostgreSQL databases first. Make a
new application backup before schema-changing releases. Then, from `backend/`:

```powershell
docker compose stop api shop maintenance
docker compose build api
docker compose run --rm migrate
docker compose run --rm migrate python scripts/configure_supabase_runtime.py --apply
docker compose up -d --wait --wait-timeout 90
```

Run each release step only after the previous one succeeds. Migration failures
must leave game writers stopped until reviewed. The API currently requires an
exact Alembic revision, so use a maintenance window for schema changes. A code
rollback after migration needs confirmed compatibility with the hosted schema.

The migration service uses the ignored `.env.supabase-operator` credential.
The API and workers receive only the restricted `forest_runtime` credential.
Supabase automatically enables RLS on new public tables; the permission script
gives that trusted backend role access while revoking direct client-role access.
Rerun it after every schema migration, before reopening gameplay. Keep the Data
API off. Never run development seed commands or the test suite on the hosted DB.

## Credentials, backups and the old local database

- Certificates are mounted read-only at `/etc/forest-db/ca.crt`; all hosted
  connections require certificate/hostname-verified TLS.
- `.env`, `.env.supabase-*` and `.local-supabase/` are ignored by Git. They contain
  credentials and/or private game backups and must not be committed or shared.
- The verified initial custom-format archive and verification reports are in
  `backend/.local-supabase/`. Keep encrypted off-site backups as well; this local
  copy alone is not an ongoing backup system.
- The original `movement-forest_forest-db` volume is preserved. It becomes stale
  once the hosted game accepts writes and is not an automatic rollback target.
- `compose.yaml` remains the explicit original local-database configuration.
  Do not use it for the migrated live game or restart old writers against it.
- The initial restore preserved all five game profiles, including one separate
  development-token profile; only four profiles map to current Supabase Auth users.

The first hosted acceptance still needs real iPhone login, sync, purchases,
placement and retry/recovery checks. Keep artwork bundled. The known frontend
catalog-copy line-ending checksum issue is fixed in the Cloud Run support source.
See [the first Cloud Run release guide](CLOUD_RUN.md): it adds schema
`0023_cloud_runtime`, which must be installed with the old writers stopped before
running the new image. Live Cloud Run/native acceptance remains a release check.
