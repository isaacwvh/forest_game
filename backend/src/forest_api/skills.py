"""Pure frozen-snapshot skill resolution, shared by growth and visitor systems."""

from dataclasses import dataclass
from decimal import Decimal
from fractions import Fraction

from forest_api.calculations import MICRO, exact
from forest_api.schemas import BehaviourDefinition
from forest_api.skill_rules import PlantSelector, SkillCaps, SkillEffect


def number(value: Fraction) -> str:
    return format(Decimal(value.numerator) / Decimal(value.denominator), "f")


@dataclass(frozen=True)
class PlantFacts:
    id: str
    species: str
    variant: str
    stage: str
    tags: tuple[str, ...]
    attraction: int
    profile_id: str
    profile_version: int
    behaviour: BehaviourDefinition


def matches(plant: PlantFacts, selector: PlantSelector | None) -> bool:
    return selector is None or (
        (not selector.species or plant.species in selector.species)
        and (not selector.variants or plant.variant in selector.variants)
        and (not selector.stages or plant.stage in selector.stages)
        and (not selector.tags or set(selector.tags) <= set(plant.tags))
    )


@dataclass(frozen=True)
class Candidate:
    effect: SkillEffect
    value: Fraction
    source: PlantFacts

    @property
    def key(self):
        effect = self.effect
        return effect.system, effect.scope, effect.metric or "", effect.stacking_group

    @property
    def order(self):
        return self.effect.id, self.source.profile_id, self.source.profile_version, self.source.id


class SkillSnapshot:
    def __init__(self, plants: tuple[PlantFacts, ...], caps: SkillCaps, policy_version: str):
        self.plants = tuple(sorted(plants, key=lambda plant: plant.id))
        self.caps, self.policy_version = caps, policy_version
        self._selectors = {}
        self._resolved = {}
        self.candidates = []
        magnitudes = {}
        for plant in self.plants:
            if plant.stage != "adult":
                continue
            for effect in plant.behaviour.garden_effects:
                if effect.condition and len(self.selected(effect.condition.selector)) < (
                    effect.condition.minimum
                ):
                    continue
                key = (plant.profile_id, plant.profile_version, effect.id)
                if key not in magnitudes:
                    magnitude = effect.magnitude
                    value = exact(magnitude.value)
                    if magnitude.type == "per_copy":
                        value = min(
                            value * len(self.selected(magnitude.selector)), exact(magnitude.maximum)
                        )
                    magnitudes[key] = value
                if magnitudes[key]:
                    self.candidates.append(Candidate(effect, magnitudes[key], plant))
        operations = {}
        for candidate in self.candidates:
            old = operations.setdefault(candidate.key, candidate.effect.operation)
            if old != candidate.effect.operation:
                raise ValueError("A stacking group cannot mix percentage and flat units")

    def selected(self, selector):
        key = selector.model_dump_json() if selector else "all"
        if key not in self._selectors:
            self._selectors[key] = tuple(p for p in self.plants if matches(p, selector))
        return self._selectors[key]

    def resolve(self, scope, recipient=None, metric=None, operation="percent"):
        key = scope, recipient.id if recipient else None, metric, operation
        if key not in self._resolved:
            groups = {}
            for candidate in self.candidates:
                effect = candidate.effect
                if (effect.scope, effect.metric, effect.operation) != (scope, metric, operation):
                    continue
                if recipient is not None and not matches(recipient, effect.recipients):
                    continue
                groups.setdefault(effect.stacking_group, []).append(candidate)
            self._resolved[key] = tuple(
                (
                    sorted(group, key=lambda row: (-row.value, row.order))[0],
                    tuple(sorted(group, key=lambda row: row.order)),
                )
                for _, group in sorted(groups.items())
            )
        return self._resolved[key]

    def total(self, scope, recipient=None, metric=None, operation="percent"):
        return sum(
            (winner.value for winner, _ in self.resolve(scope, recipient, metric, operation)),
            Fraction(0),
        )

    def growth(self, plant, metrics):
        activity = {
            metric: 1 + min(self.total("activity", plant, metric), exact(self.caps.activity_bonus))
            for metric in metrics
        }
        water = 1 + min(self.total("water", plant), exact(self.caps.water_bonus))
        return activity, water

    def attraction(self):
        base = sum(p.attraction for p in self.plants)
        flat_requested = sum(
            (self.total("attraction_plant", p, operation="flat") * MICRO for p in self.plants),
            self.total("attraction_garden", operation="flat") * MICRO,
        )
        flat_budget = min(
            exact(self.caps.flat_attraction_points) * MICRO,
            exact(self.caps.flat_attraction_base_fraction) * base,
        )
        total = sum(
            (
                p.attraction
                * (
                    1
                    + min(
                        self.total("attraction_plant", p), exact(self.caps.plant_attraction_bonus)
                    )
                )
                for p in self.plants
            ),
            Fraction(0),
        )
        total *= 1 + min(self.total("attraction_garden"), exact(self.caps.garden_attraction_bonus))
        # Flat additions enter after percentage layers so the flat budget cannot amplify.
        total += min(flat_requested, flat_budget)
        return int(min(total, base * (1 + exact(self.caps.total_attraction_bonus))))

    def capacity(self, base, maximum):
        value = base * (1 + min(self.total("offline_capacity"), exact(self.caps.capacity_bonus)))
        value += min(self.total("offline_capacity", operation="flat"), self.caps.flat_capacity)
        return int(min(value, maximum, base * (1 + exact(self.caps.capacity_bonus))))

    def context(self, plant, metrics):
        activity, water = self.growth(plant, metrics)
        return {
            "policyVersion": self.policy_version,
            "caps": self.caps.model_dump(by_alias=True),
            "activityFactors": {metric: number(value) for metric, value in activity.items()},
            "waterFactor": number(water),
            "effects": self.effects(plant, metrics),
        }

    def effects(self, recipient=None, metrics=()):
        rows = []
        scopes = [("water", None), *(("activity", metric) for metric in sorted(metrics))]
        if recipient is None:
            scopes = [("attraction_garden", None), ("offline_capacity", None)]
        elif not metrics:
            scopes = [("attraction_plant", None), ("water", None)]
        for scope, metric in scopes:
            for operation in ("percent", "flat"):
                for winner, eligible in self.resolve(scope, recipient, metric, operation):
                    effect = winner.effect
                    rows.append(
                        {
                            "id": effect.id,
                            "name": effect.name,
                            "description": effect.description,
                            "system": effect.system,
                            "scope": scope,
                            "metric": metric,
                            "operation": operation,
                            "magnitude": number(winner.value),
                            "stackingGroup": effect.stacking_group,
                            "sourcePlantId": winner.source.id,
                            "profileId": winner.source.profile_id,
                            "profileVersion": winner.source.profile_version,
                            "eligibleSourcePlantIds": sorted({row.source.id for row in eligible}),
                        }
                    )
        return rows

    def summary(self):
        rows = {}
        factors = []
        for plant in self.plants:
            metrics = sorted(
                {row.effect.metric for row in self.candidates if row.effect.scope == "activity"}
            )
            activity, water = self.growth(plant, metrics)
            factors.append(
                {
                    "plantId": plant.id,
                    "waterFactor": number(water),
                    "waterCapReached": self.total("water", plant) >= exact(self.caps.water_bonus),
                    "activityCapReached": {
                        metric: self.total("activity", plant, metric)
                        >= exact(self.caps.activity_bonus)
                        for metric in metrics
                    },
                    "activityFactors": {k: number(v) for k, v in activity.items()},
                }
            )
            effects = self.effects(plant) + self.effects(plant, metrics)
            for row in effects:
                key = (
                    row["system"],
                    row["scope"],
                    row["metric"],
                    row["stackingGroup"],
                    row["profileId"],
                    row["profileVersion"],
                    row["id"],
                )
                entry = rows.setdefault(key, {**row, "recipientPlantIds": []})
                if plant.id not in entry["recipientPlantIds"]:
                    entry["recipientPlantIds"].append(plant.id)
        for row in self.effects():
            rows[
                (
                    row["system"],
                    row["scope"],
                    "",
                    row["stackingGroup"],
                    row["profileId"],
                    row["profileVersion"],
                    row["id"],
                )
            ] = {**row, "recipientPlantIds": []}
        return {
            "policyVersion": self.policy_version,
            "caps": self.caps.model_dump(by_alias=True),
            "activeSkills": sorted(
                rows.values(),
                key=lambda row: (
                    row["name"],
                    row["scope"],
                    row["metric"] or "",
                    row["profileVersion"],
                ),
            ),
            "growthFactors": factors,
        }
