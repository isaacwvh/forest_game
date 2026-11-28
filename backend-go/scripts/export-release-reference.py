"""Regenerate the Go test release from the tracked Python publication reference."""

import json
import os
import sys
from datetime import timedelta
from pathlib import Path
from urllib.parse import urlsplit

from alembic import command
from alembic.config import Config
from sqlalchemy import create_engine, text
from sqlalchemy.orm import Session

GO = Path(__file__).resolve().parents[1]
BACKEND = GO.parent / "backend"
sys.path.insert(0, str(BACKEND / "src"))

from forest_api import (  # noqa: E402
    expeditions,
    item_catalogue,
    item_commerce,
    launch_balance,
    milestone_tracks,
    visitor_rescale,
    woodland,
)
from forest_api.config import Settings  # noqa: E402


GROUPS = {
    "woodland": {
        "skill_policies": "version",
        "economy_configs": "version",
        "visitor_rules": "version",
        "growth_profiles": "id, version",
        "growth_rule_profiles": "id, version",
        "attraction_profiles": "id, version",
        "plant_species": "id",
        "plant_variants": "species_id, variant_id",
        "plant_stages": "species_id, variant_id, stage",
        "game_catalogue": "id",
        "pack_definitions": "id, version",
        "pack_members": "pack_id, pack_version, species_id, variant_id",
        "exchange_offers": "id, version",
    },
    "items": {
        "item_definitions": "id, version",
        "item_value_definitions": "item_id, item_version",
        "item_skill_profiles": "id, version",
        "item_skill_bindings": "item_id, item_version",
        "item_shop_offers": "id, version",
        "shop_releases": "version",
    },
    "milestones": {"milestone_policies": "version"},
    "expedition": {
        "item_definitions": "id, version",
        "item_value_definitions": "item_id, item_version",
        "expedition_templates": "version",
    },
}

# The Go publisher sets effective times for the target database at publication.
OMIT = {
    "economy_configs": "effective_at",
    "visitor_rules": "effective_at",
    "shop_releases": "effective_week, published_at",
    "milestone_policies": "effective_at",
    "expedition_templates": "published_at",
}


def snapshot(engine, tables):
    result = {}
    with engine.connect() as connection:
        for table, keys in tables.items():
            row = "to_jsonb(r)"
            for column in OMIT.get(table, "").split(", "):
                if column:
                    row += f" - '{column}'"
            result[table] = [
                json.loads(value)
                for value in connection.scalars(
                    text(f"SELECT ({row})::text FROM public.{table} r ORDER BY {keys}")
                )
            ]
    return result


def main():
    dsn = os.environ["FOREST_DATABASE_URL"]
    url = urlsplit(dsn)
    if (
        url.scheme != "postgresql+psycopg"
        or url.hostname != "127.0.0.1"
        or url.query
        or not url.path.startswith("/forest_go_reference_")
    ):
        raise SystemExit("Use a freshly created loopback database named forest_go_reference_*")

    settings = Settings(
        _env_file=None,
        database_url=dsn,
        environment="test",
        auth_mode="development",
        dev_auth_secret="local-reference-only-test-signing-key",
    )
    engine = create_engine(dsn, hide_parameters=True)
    with engine.connect() as connection:
        if connection.scalar(text("SELECT to_regclass('public.game_catalogue') IS NOT NULL")):
            raise SystemExit("Reference database already contains an application schema")
    cfg = Config(str(BACKEND / "alembic.ini"))
    cfg.set_main_option("script_location", (BACKEND / "migrations").as_posix())
    command.upgrade(cfg, "head")

    with Session(engine) as session:
        launch_balance.publish(session, settings)
    with Session(engine) as session:
        launch = session.scalar(text("SELECT effective_at FROM economy_configs"))
    with Session(engine) as session:
        visitor_rescale.publish(session, settings, clock=lambda: launch + timedelta(seconds=1))
    with Session(engine) as session:
        woodland.publish(session, settings, apply=True, clock=lambda: launch + timedelta(seconds=2))
    with Session(engine) as session:
        milestone_tracks.activate(session, settings, apply=True)
    with Session(engine) as session:
        item_commerce.publish(session, apply=True)
    with Session(engine) as session:
        item_catalogue.publish(session, apply=True)

    # Capture Shop content before expedition publication adds its reward items.
    result = {
        group: snapshot(engine, tables)
        for group, tables in GROUPS.items()
        if group != "expedition"
    }
    with Session(engine) as session:
        today = session.scalar(text("SELECT (clock_timestamp() AT TIME ZONE 'UTC')::date"))
    month = (today.replace(day=28) + timedelta(days=4)).replace(day=1)
    with Session(engine) as session:
        expeditions.publish(session, settings, month, apply=True)
    result["expedition"] = snapshot(engine, GROUPS["expedition"])
    for table in ("item_definitions", "item_value_definitions"):
        result["expedition"][table] = [
            row for row in result["expedition"][table] if row not in result["items"][table]
        ]

    destination = GO / "internal" / "server" / "release" / "woodland.json"
    destination.parent.mkdir(exist_ok=True)
    with destination.open("w", encoding="utf-8", newline="\n") as output:
        output.write("{\n")
        for i, (group, tables) in enumerate(result.items()):
            output.write((",\n" if i else "") + f'  "{group}": {{\n')
            for j, (table, rows) in enumerate(tables.items()):
                output.write((",\n" if j else "") + f'    "{table}": [\n')
                output.write(",\n".join(
                    "      " + json.dumps(row, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
                    for row in rows
                ))
                output.write("\n    ]")
            output.write("\n  }")
        output.write("\n}\n")


if __name__ == "__main__":
    main()
