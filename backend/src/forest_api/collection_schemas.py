"""Strict authoring and mutation schemas; integer weights never use floats."""

from typing import Annotated
from uuid import UUID

from pydantic import Field, model_validator

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
    schema_version: Annotated[int, Field(strict=True, ge=1, le=1)] = 1
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
    definition: PackContract
    offer_id: Identifier
    offer_version: Annotated[int, Field(strict=True, ge=1, le=2147483647)]
    token_cost: Annotated[int, Field(strict=True, ge=1, le=9223372036854775807)]
