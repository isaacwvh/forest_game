"""Deterministic pure SkillSnapshot cases consumed by native prediction tests."""

import json
import random
from copy import deepcopy
from decimal import Decimal
from pathlib import Path
from uuid import UUID

from forest_api import item_catalogue, woodland
from forest_api.activity_inputs import WORKOUT_TYPES
from forest_api.schemas import BehaviourDefinition
from forest_api.skill_rules import CAPS_V1, SkillCaps, SkillEffect
from forest_api.skills import ItemFacts, PlantFacts, SkillSnapshot

TARGET = (
    Path(__file__).resolve().parents[2]
    / "frontend/MovementForest/Resources/Fixtures/garden-strategy-contract.json"
)


def cases():
    records = woodland.release()["species"]
    item_records = item_catalogue.catalogue()

    def plant(record, i, stage="adult"):
        identifier = str(UUID(int=i))
        return {
            "plantId": identifier,
            "speciesId": record["id"],
            "variantId": "standard",
            "growthStage": stage,
            "growthMicroUnits": str(record["growth"][stage]),
            "modelKey": "",
            "thumbnailKey": "",
            "placement": None,
            "baseAttractionMicroUnits": str(record["attraction"][stage]),
            "gameplayTags": record["tags"],
            "clearanceRadius": float(record["radius"]),
            "pinnedProfiles": {
                k: {"id": "contract_" + record["id"], "version": 20}
                for k in ["growth", "behaviour", "attraction"]
            },
            "gardenSkills": BehaviourDefinition.model_validate(record["behaviour"]).model_dump(
                by_alias=True
            )["gardenEffects"],
        }

    def item(record, i):
        raw = (
            item_catalogue.profile(record["skillId"]) if record.get("skillId") else {"effects": []}
        )
        effects = []
        for effect in raw["effects"]:
            metrics = (
                ["workout_minutes." + k for k in sorted(set(WORKOUT_TYPES.values()))]
                if effect.get("metric") == "workouts"
                else [effect.get("metric")]
            )
            effects.extend(
                SkillEffect.model_validate({**effect, "metric": m}).model_dump(by_alias=True)
                for m in metrics
            )
        return {
            "ownedItemId": str(UUID(int=i)),
            "itemId": record["id"],
            "definitionVersion": 1,
            "displayName": record["displayName"],
            "description": record["description"],
            "rarity": record["rarity"],
            "assetVersion": record["assetVersion"],
            "modelKey": "",
            "thumbnailKey": "",
            "clearanceRadius": float(record["radius"]),
            "placement": None,
            "gardenSkills": [],
            "strategyRules": {
                "profileId": record.get("skillId") or record["id"],
                "profileVersion": 1,
                "effects": effects,
                "dailyGrant": raw.get("dailyGrant"),
            },
        }

    def case(name, plants, items=(), caps=None, flights=0):
        context = {
            "schemaVersion": 1,
            "policyVersion": "contract",
            "caps": caps or CAPS_V1,
            "dailyFlights": flights,
            "baseCapacity": 21600,
            "maximumCapacity": 64800,
            "capacityFlatMultiplier": 10,
            "welcomeSeconds": 20,
            "gameDate": "2026-11-17",
            "validUntil": "2099-01-01T00:00:00+00:00",
            "ruleVersion": "contract",
        }
        facts = []
        for p in plants:
            record = next(r for r in records if r["id"] == p["speciesId"])
            behaviour = {**record["behaviour"], "gardenEffects": p["gardenSkills"]}
            profile = p["pinnedProfiles"]["behaviour"]
            facts.append(
                PlantFacts(
                    p["plantId"],
                    p["speciesId"],
                    p["variantId"],
                    p["growthStage"],
                    tuple(p["gameplayTags"]),
                    int(p["baseAttractionMicroUnits"]),
                    profile["id"],
                    profile["version"],
                    BehaviourDefinition.model_validate(behaviour),
                )
            )
        sources = [
            ItemFacts(
                i["ownedItemId"],
                i["itemId"],
                i["definitionVersion"],
                i["strategyRules"]["profileId"],
                1,
                tuple(SkillEffect.model_validate(e) for e in i["strategyRules"]["effects"]),
                i["strategyRules"]["dailyGrant"],
            )
            for i in items
        ]
        snap = SkillSnapshot(
            tuple(facts),
            SkillCaps.model_validate(context["caps"]),
            "contract",
            flights=flights,
            items=tuple(sources),
        )

        def normal(value):
            return format(Decimal(value).normalize(), "f")

        summary = snap.summary()
        effects = sorted(
            "/".join(
                [
                    e["id"],
                    e["scope"],
                    e["metric"] or "",
                    e.get("stepBand", ""),
                    e["stackingGroup"],
                    normal(e["magnitude"]),
                    ",".join(sorted(e["recipientPlantIds"])),
                ]
            )
            for e in summary["activeSkills"]
        )
        factors = sorted(
            e["plantId"]
            + ":"
            + normal(e["waterFactor"])
            + ":"
            + ",".join(
                k + "=" + normal(e["activityFactors"][k]) for k in sorted(e["activityFactors"])
            )
            for e in summary["growthFactors"]
        )
        signature = "#".join(
            [
                str(snap.attraction()),
                str(snap.capacity(21600, 64800, flat_multiplier=10)),
                "|".join(effects),
                "|".join(factors),
            ]
        )
        return {
            "name": name,
            "plants": plants,
            "items": list(items),
            "context": context,
            "expectedSignature": signature,
        }

    result = [case("empty", [])]
    for n, record in enumerate(records):
        result.append(case("adult_" + record["id"], [plant(record, n + 1)]))
    all_plants = [plant(r, i + 1) for i, r in enumerate(records)]
    result.append(case("all_species", all_plants, flights=17))
    all_items = [item(r, i + 1000) for i, r in enumerate(item_records)]
    for i in all_items:
        result.append(case("item_" + i["itemId"], all_plants[:6], [i], flights=9))
    result.append(case("items_without_plants", [], all_items))
    result.append(case("all_mixed", all_plants, all_items, flights=99))
    for i in range(36):
        rng = random.Random(i)
        plants = [
            plant(rng.choice(records), n + 1, rng.choice(["sprout", "seedling", "young", "adult"]))
            for n in range(rng.randint(1, 35))
        ]
        items = [item(rng.choice(item_records), n + 1000) for n in range(rng.randint(0, 18))]
        result.append(case("mixed_" + str(i), plants, items, flights=rng.randint(0, 40)))
    caps = {
        **CAPS_V1,
        "activityBonus": "0.02",
        "waterBonus": "0.03",
        "plantAttractionBonus": "0.01",
        "gardenAttractionBonus": "0.02",
        "totalAttractionBonus": "0.03",
        "flatAttractionPoints": "0.5",
        "capacityBonus": "0.01",
    }
    result.append(case("shared_caps", all_plants, all_items, caps=caps, flights=99))
    moon = next(r for r in records if r["id"] == "moonwillow")
    old, new = plant(moon, 1), plant(moon, 2)
    old = deepcopy(old)
    old["gardenSkills"][0]["magnitude"]["value"] = "0.04"
    old["pinnedProfiles"]["behaviour"]["version"] = 2
    result.append(case("old_and_new_sleeping_dew", [old, new]))
    # Placement is irrelevant to the pure evaluator, membership is the input list.
    return result


if __name__ == "__main__":
    data = cases()
    TARGET.write_text(json.dumps({"cases": data}, separators=(",", ":")) + "\n", encoding="utf-8")
    print(f"Exported {len(data)} strategy cases to {TARGET}")
