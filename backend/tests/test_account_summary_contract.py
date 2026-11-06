"""The native fixture was exported by the disposable real-HTTP progression smoke flow."""

import json
from pathlib import Path

import pytest

from forest_api.progression_schemas import AccountSummary

FIXTURE = (
    Path(__file__).resolve().parents[2]
    / "frontend/MovementForest/Resources/Fixtures/account-summary-contract.json"
)


@pytest.mark.parametrize("key", ["fresh", "grown"])
def test_native_account_summary_contract(key):
    value = AccountSummary.model_validate(json.loads(FIXTURE.read_text(encoding="utf-8"))[key])
    assert value.profile.username == "progression_smoke"
    assert value.wallet.initialized
    if key == "grown":
        assert value.progression.lifetime_recorded_steps == "37250"
        assert value.progression.level == 5
        assert value.wallet.gem_balance == "3"
