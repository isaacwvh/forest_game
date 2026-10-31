"""Descriptive text updates must leave every gameplay fact unchanged."""

import pytest
from sqlalchemy import select

from forest_api.catalog_copy import SPECIES_DESCRIPTIONS, update_descriptions
from forest_api.launch_balance import publish
from forest_api.models import Base, Species


def snapshot(app):
    with app.state.database.engine.connect() as connection:
        return {
            table.name: [
                dict(row)
                for row in connection.execute(
                    select(table).order_by(*table.primary_key.columns)
                ).mappings()
            ]
            for table in Base.metadata.sorted_tables
        }


@pytest.fixture
def published(app, register):
    with app.state.database.sessions() as session:
        publish(session, app.state.settings)
    register()
    with app.state.database.sessions.begin() as session:
        for row in session.scalars(select(Species)):
            row.description = "Movement Forest initial collection."
    return app


def test_preview_never_changes_any_game_or_catalogue_record(published):
    before = snapshot(published)
    with published.state.database.sessions() as session:
        result = update_descriptions(session)
    assert result == {"applied": False, "changedSpecies": ["moonwillow", "oak"]}
    assert snapshot(published) == before


def test_apply_changes_only_two_text_fields_and_is_repeat_safe(published, client, headers):
    before = snapshot(published)
    with published.state.database.sessions() as session:
        result = update_descriptions(session, apply=True)
    assert result == {"applied": True, "changedSpecies": ["moonwillow", "oak"]}
    after = snapshot(published)
    for row in after[Species.__table__.name]:
        assert row["description"] == SPECIES_DESCRIPTIONS[row["id"]]
        row["description"] = "Movement Forest initial collection."
    assert after == before
    with published.state.database.sessions() as session:
        assert update_descriptions(session, apply=True) == {
            "applied": True,
            "changedSpecies": [],
        }
    response = client.get("/v1/catalog", headers=headers())
    assert response.status_code == 200
    assert {s["speciesId"]: s["description"] for s in response.json()["species"]} == (
        SPECIES_DESCRIPTIONS
    )


def test_missing_species_refuses_a_partial_update(app):
    before = snapshot(app)
    with (
        app.state.database.sessions() as session,
        pytest.raises(ValueError, match="Catalogue species missing"),
    ):
        update_descriptions(session, apply=True)
    assert snapshot(app) == before


def test_fresh_publication_includes_approved_copy(app):
    with app.state.database.sessions() as session:
        publish(session, app.state.settings)
    with app.state.database.sessions() as session:
        assert {s.id: s.description for s in session.scalars(select(Species))} == (
            SPECIES_DESCRIPTIONS
        )
