"""Once-per-account/date/tier flat water, separate from percentage and Health evidence."""

from forest_api import collection, discovery
from forest_api.calculations import MICRO, stage_for
from forest_api.expedition_models import ItemStepGrant, ItemStepState
from forest_api.models import PlayerProgress


def recent(session, owner):
    from decimal import Decimal

    from sqlalchemy import select

    return [
        {
            "gameDate": r.game_date.isoformat(),
            "tier": r.tier,
            "water": str(
                Decimal(sum(int(a["awardedMicroUnits"]) for a in r.provenance["awards"])) / MICRO
            ),
            "plantCount": len(r.provenance["awards"]),
        }
        for r in session.scalars(
            select(ItemStepGrant)
            .where(ItemStepGrant.owner_id == owner)
            .order_by(ItemStepGrant.game_date.desc(), ItemStepGrant.tier.desc())
            .limit(9)
        )
    ]


def settle_steps(
    session, settings, garden, plants, presenter, snapshot, days, boundary, accounting
):
    sources = [i for i in snapshot.items if i.triggered_grants]
    if not sources:
        return
    family = "alignment_of_worlds"
    profiles = {
        p.id: presenter.profile("growth", p.growth_profile_id, p.growth_profile_version)
        for p in plants
    }
    for day in days:
        if day.newly_eligible_steps <= 0:
            continue
        key = garden.owner_id, day.game_date, family
        state = session.get(ItemStepState, key)
        if state is None:
            state = ItemStepState(
                owner_id=garden.owner_id, game_date=day.game_date, family=family, steps=0
            )
            session.add(state)
        state.steps = min(6000, state.steps + day.newly_eligible_steps)
        session.flush()
        for threshold, water in ((2000, 3), (4000, 4), (6000, 5)):
            if state.steps < threshold or session.get(ItemStepGrant, (*key, threshold)) is not None:
                continue
            accounting.before_change(session, garden, boundary)
            before = {
                p.id: stage_for(p.growth_micro_units, profiles[p.id].thresholds) for p in plants
            }
            awards = []
            for plant in plants:
                growth = profiles[plant.id]
                prior = plant.growth_micro_units
                after = min(prior + water * MICRO, growth.thresholds["adult"])
                plant.growth_micro_units = after
                progress = session.get(PlayerProgress, garden.owner_id)
                if prior < growth.thresholds["seedling"] <= after and progress:
                    progress.first_seedling_at = progress.first_seedling_at or boundary
                if prior < growth.thresholds["adult"] <= after and plant.first_matured_at is None:
                    plant.first_matured_at = boundary
                    plant.fractional_state = {}
                    if progress:
                        progress.first_maturity_count = collection.checked(
                            progress.first_maturity_count + 1
                        )
                awards.append(
                    {
                        "plantId": str(plant.id),
                        "beforeGrowth": str(prior),
                        "afterGrowth": str(after),
                        "awardedMicroUnits": str(after - prior),
                        "requestedMicroUnits": str(water * MICRO),
                    }
                )
            session.add(
                ItemStepGrant(
                    owner_id=garden.owner_id,
                    game_date=day.game_date,
                    family=family,
                    tier=threshold,
                    boundary=boundary,
                    provenance={
                        "version": 1,
                        "sources": [
                            {
                                "ownedItemId": i.id,
                                "profileId": i.profile_id,
                                "profileVersion": i.profile_version,
                            }
                            for i in sources
                        ],
                        "steps": state.steps,
                        "awards": awards,
                    },
                )
            )
            session.flush()
            discovery.record_reached(session, garden.owner_id, plants, boundary)
            from forest_api.expeditions import observe_garden

            observe_garden(session, garden, boundary, before=before)
            accounting.after_change(session, garden, boundary)
