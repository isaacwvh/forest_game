"""Apply backend-only access after a Supabase restore or Alembic migration.

Run with the migration owner's FOREST_DATABASE_URL, not the runtime credential.
Defaults to a read-only preview. The forest_runtime login must already exist.
"""

import argparse
import json
import os

from sqlalchemy import create_engine, text

from forest_api import (  # noqa: F401 - register the complete application schema
    activity_models,
    collection_models,
    expedition_models,
    history_models,
    item_models,
    milestone_models,
    progression_models,
    visitor_models,
    woodland_models,
)
from forest_api.models import Base


def configure(connection, *, apply=False):
    tables = sorted(set(Base.metadata.tables) | {"alembic_version"})
    actual = set(
        connection.scalars(text("SELECT tablename FROM pg_tables WHERE schemaname='public'"))
    )
    missing = set(tables) - actual
    if missing:
        raise RuntimeError(f"Migrate the schema first; missing tables: {sorted(missing)}")
    if not connection.scalar(
        text("SELECT EXISTS(SELECT 1 FROM pg_roles WHERE rolname='forest_runtime')")
    ):
        raise RuntimeError("Create the forest_runtime login before configuring access")
    role = connection.execute(
        text(
            "SELECT rolsuper,rolcreatedb,rolcreaterole,rolbypassrls FROM pg_roles "
            "WHERE rolname='forest_runtime'"
        )
    ).one()
    if any(role):
        raise RuntimeError("forest_runtime must not have elevated database privileges")
    owner = connection.scalar(text("SELECT current_user"))
    quote = connection.dialect.identifier_preparer.quote_identifier
    database_name = quote(connection.scalar(text("SELECT current_database()")))
    statements = [
        f"GRANT CONNECT ON DATABASE {database_name} TO forest_runtime",
        "GRANT USAGE ON SCHEMA public TO forest_runtime",
        "REVOKE CREATE ON SCHEMA public FROM PUBLIC,anon,authenticated,forest_runtime",
    ]
    for kind in ("TABLES", "SEQUENCES", "FUNCTIONS"):
        statements.append(
            f"ALTER DEFAULT PRIVILEGES FOR ROLE {quote(owner)} IN SCHEMA public "
            f"REVOKE ALL ON {kind} FROM PUBLIC,anon,authenticated,service_role"
        )
    # Function EXECUTE is globally granted to PUBLIC by PostgreSQL, so a
    # schema-only revoke cannot remove that default for future functions.
    statements.append(
        f"ALTER DEFAULT PRIVILEGES FOR ROLE {quote(owner)} REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC"
    )
    for table in tables:
        name = f"public.{quote(table)}"
        statements.extend(
            [
                f"REVOKE ALL ON TABLE {name} "
                "FROM PUBLIC,anon,authenticated,service_role,forest_runtime",
                f"ALTER TABLE {name} ENABLE ROW LEVEL SECURITY",
                f"DROP POLICY IF EXISTS forest_runtime_access ON {name}",
            ]
        )
        if table in {"alembic_version", "runtime_control"}:
            statements.extend(
                [
                    f"GRANT SELECT ON TABLE {name} TO forest_runtime",
                    f"CREATE POLICY forest_runtime_access ON {name} "
                    "FOR SELECT TO forest_runtime USING (true)",
                ]
            )
        else:
            statements.extend(
                [
                    f"GRANT SELECT,INSERT,UPDATE,DELETE ON TABLE {name} TO forest_runtime",
                    f"CREATE POLICY forest_runtime_access ON {name} "
                    "FOR ALL TO forest_runtime USING (true) WITH CHECK (true)",
                ]
            )
    sequences = list(
        connection.scalars(
            text(
                "SELECT DISTINCT s.relname FROM pg_class s "
                "JOIN pg_namespace n ON n.oid=s.relnamespace "
                "JOIN pg_depend d ON d.objid=s.oid AND d.deptype IN ('a','i') "
                "JOIN pg_class t ON t.oid=d.refobjid "
                "WHERE n.nspname='public' AND s.relkind='S' AND t.relname=ANY(:tables)"
            ),
            {"tables": tables},
        )
    )
    for sequence in sequences:
        name = f"public.{quote(sequence)}"
        statements.extend(
            [
                f"REVOKE ALL ON SEQUENCE {name} "
                "FROM PUBLIC,anon,authenticated,service_role,forest_runtime",
                f"GRANT USAGE,SELECT ON SEQUENCE {name} TO forest_runtime",
            ]
        )
    functions = connection.execute(
        text(
            "SELECT p.proname,pg_get_function_identity_arguments(p.oid) "
            "FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace "
            "WHERE n.nspname='public' AND left(p.proname,7)='forest_' ORDER BY p.proname"
        )
    ).all()
    for name, arguments in functions:
        signature = f"public.{quote(name)}({arguments})"
        statements.extend(
            [
                f"REVOKE ALL ON FUNCTION {signature} "
                "FROM PUBLIC,anon,authenticated,service_role,forest_runtime",
                f"GRANT EXECUTE ON FUNCTION {signature} TO forest_runtime",
            ]
        )
    if apply:
        for statement in statements:
            connection.execute(text(statement))
    return {
        "applied": apply,
        "tables": len(tables),
        "sequences": len(sequences),
        "functions": len(functions),
        "statements": len(statements),
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--apply", action="store_true")
    args = parser.parse_args()
    engine = create_engine(os.environ["FOREST_DATABASE_URL"], hide_parameters=True)
    try:
        with engine.begin() as connection:
            result = configure(connection, apply=args.apply)
        print(json.dumps(result))
    finally:
        engine.dispose()


if __name__ == "__main__":
    main()
