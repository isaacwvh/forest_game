import pytest
from pydantic import ValidationError

from forest_api.visitor_schemas import VisitorRuleDefinition


def definition(**changes):
    return VisitorRuleDefinition.model_validate(
        {
            "curve": {
                "k_micro_units": 2_000_000,
                "starter_probability": "0.5",
                "maximum_probability": "0.8",
                "slot_seconds": 30,
                "offline_fraction": "0.25",
                "offline_rate_cap_per_second": "0.01",
                "base_capacity": 30,
                "maximum_capacity": 120,
            },
            **changes,
        }
    )


@pytest.mark.parametrize(
    "changes",
    [
        {"lease_seconds": 30, "heartbeat_seconds": 15, "opportunity_seconds": 20},
        {"heartbeat_seconds": 15, "opportunity_seconds": 15},
        {"tokens_per_visit": 0},
        {"gap_slots": 0},
        {"slot_seconds": 10},
    ],
)
def test_invalid_or_unfair_visitor_configuration_fails(changes):
    with pytest.raises(ValidationError):
        definition(**changes)
