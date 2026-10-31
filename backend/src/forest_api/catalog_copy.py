"""Approved descriptive catalogue copy; no progression or economy settings."""

from sqlalchemy import select
from sqlalchemy.orm import Session

from forest_api.models import GameCatalogue, Species

SPECIES_DESCRIPTIONS = {
    "oak": (
        "Broad-crowned oak with sculpted branches, grouped foliage and softly veined early leaves."
    ),
    "moonwillow": ("Curved trunk, cascading silver-green foliage and tiny crescent-shaped leaves"),
}


def update_descriptions(session: Session, *, apply: bool = False) -> dict:
    """Preview by default. Update existing text fields only, in one transaction."""
    with session.begin():
        catalogue = select(GameCatalogue).where(GameCatalogue.id == 1)
        if apply:
            catalogue = catalogue.with_for_update()
        if session.scalar(catalogue) is None:
            raise ValueError("Publish the catalogue before updating descriptive copy")
        query = select(Species).where(Species.id.in_(SPECIES_DESCRIPTIONS)).order_by(Species.id)
        if apply:
            query = query.with_for_update()
        rows = {row.id: row for row in session.scalars(query)}
        missing = sorted(set(SPECIES_DESCRIPTIONS) - rows.keys())
        if missing:
            raise ValueError("Catalogue species missing: " + ", ".join(missing))
        changed = []
        for key, description in SPECIES_DESCRIPTIONS.items():
            if rows[key].description != description:
                changed.append(key)
                if apply:
                    rows[key].description = description
        return {"applied": apply, "changedSpecies": sorted(changed)}
