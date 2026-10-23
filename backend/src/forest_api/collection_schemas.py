"""Strict authoring and mutation schemas; integer weights never use floats."""

from typing import Annotated, Literal
from uuid import UUID

from pydantic import Field, TypeAdapter, model_validator

from forest_api.schemas import DTO, PinnedProfiles

Weight = Annotated[int, Field(strict=True, ge=0, le=1_000_000)]
Identifier = Annotated[str, Field(pattern=r"^[a-z][a-z0-9_-]{0,99}$")]


class PackOutcome(DTO):
    species_id: Identifier
    variant_id: Identifier
    profiles: PinnedProfiles


class RarityPool(DTO):
    rarity: Annotated[str, Field(pattern=r"^[a-z][a-z0-9_]{0,31}$")]
    weight: Weight
    outcomes: Annotated[list[PackOutcome], Field(max_length=1000)]

    @model_validator(mode="after")
    def nonempty(self):
        if self.weight and not self.outcomes:
            raise ValueError("A positive-weight rarity requires at least one outcome")
        return self


class PackContract(DTO):
    schema_version: Literal[1] = 1
    display_name: Annotated[str, Field(min_length=1, max_length=100)]
    description: Annotated[str, Field(max_length=2000)]
    rarities: Annotated[list[RarityPool], Field(min_length=1, max_length=20)]

    @model_validator(mode="after")
    def coherent(self):
        if not sum(pool.weight for pool in self.rarities):
            raise ValueError("At least one rarity must have positive weight")
        if len({pool.rarity for pool in self.rarities}) != len(self.rarities):
            raise ValueError("Duplicate rarity")
        pairs = [(o.species_id, o.variant_id) for r in self.rarities for o in r.outcomes]
        if len(set(pairs)) != len(pairs):
            raise ValueError("Duplicate species/variant outcome")
        return self


class WeightedVariant(DTO):
    variant_id: Identifier
    weight: Weight
    profiles: PinnedProfiles


class SpeciesSelection(DTO):
    species_id: Identifier
    variants: Annotated[list[WeightedVariant], Field(min_length=1, max_length=1000)]

    @model_validator(mode="after")
    def valid_variants(self):
        if not sum(v.weight for v in self.variants):
            raise ValueError("A species needs a positive-weight variant")
        if len({v.variant_id for v in self.variants}) != len(self.variants):
            raise ValueError("Duplicate variant within species")
        return self


class SpeciesRarityPool(DTO):
    rarity: Annotated[str, Field(pattern=r"^[a-z][a-z0-9_]{0,31}$")]
    weight: Weight
    species: Annotated[list[SpeciesSelection], Field(max_length=1000)]

    @model_validator(mode="after")
    def nonempty(self):
        if self.weight and not self.species:
            raise ValueError("A positive-weight rarity needs a species")
        return self


class SpeciesPackContract(DTO):
    schema_version: Literal[2] = 2
    display_name: Annotated[str, Field(min_length=1, max_length=100)]
    description: Annotated[str, Field(max_length=2000)]
    rarities: Annotated[list[SpeciesRarityPool], Field(min_length=1, max_length=20)]

    @model_validator(mode="after")
    def coherent(self):
        if not sum(pool.weight for pool in self.rarities):
            raise ValueError("At least one rarity must have positive weight")
        if len({pool.rarity for pool in self.rarities}) != len(self.rarities):
            raise ValueError("Duplicate rarity")
        species = [s.species_id for pool in self.rarities for s in pool.species]
        if len(set(species)) != len(species):
            raise ValueError("A species must occur exactly once in a pack")
        return self


AnyPackContract = Annotated[
    PackContract | SpeciesPackContract, Field(discriminator="schema_version")
]
pack_adapter = TypeAdapter(AnyPackContract)


def parse_pack(value: dict) -> PackContract | SpeciesPackContract:
    return pack_adapter.validate_python(value)


def outcomes(pool):
    """Flatten only for dependency/retention checks, never for schema-2 sampling."""
    if isinstance(pool, RarityPool):
        return pool.outcomes
    return [
        PackOutcome(species_id=s.species_id, variant_id=v.variant_id, profiles=v.profiles)
        for s in pool.species
        for v in s.variants
    ]


class ExchangeRequest(DTO):
    request_id: UUID
    offer_id: Identifier
    offer_version: Annotated[int, Field(strict=True, ge=1, le=2147483647)]
    quantity: Annotated[int, Field(strict=True, ge=1, le=20)] = 1


class OpenPackRequest(DTO):
    request_id: UUID


class PublishPack(DTO):
    pack_id: Identifier
    version: Annotated[int, Field(strict=True, ge=1, le=2147483647)]
    is_fixture: bool = False
    definition: AnyPackContract
    offer_id: Identifier
    offer_version: Annotated[int, Field(strict=True, ge=1, le=2147483647)]
    token_cost: Annotated[int, Field(strict=True, ge=1, le=9223372036854775807)]
