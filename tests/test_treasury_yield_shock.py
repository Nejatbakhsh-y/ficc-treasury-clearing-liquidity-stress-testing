"""Tests for the Section 15 Treasury yield-shock model."""

from __future__ import annotations

from copy import deepcopy
from typing import Any

import pandas as pd
import pytest

from ficc_liquidity.stress.treasury_yield_shock import (
    TreasuryYieldShockModel,
    TreasuryYieldStressError,
    build_shock_vector,
    derive_h15_bucket_shocks,
    duration_convexity_price_return,
)


@pytest.fixture
def config() -> dict[str, Any]:
    buckets = {
        "short": {
            "midpoint_years": 1.0,
            "modified_duration": 1.0,
            "convexity": 1.0,
            "liquidation_days": 1,
        },
        "intermediate": {
            "midpoint_years": 5.0,
            "modified_duration": 4.5,
            "convexity": 24.0,
            "liquidation_days": 2,
        },
        "long": {
            "midpoint_years": 10.0,
            "modified_duration": 8.0,
            "convexity": 80.0,
            "liquidation_days": 4,
        },
    }
    return {
        "input": {
            "required_member_id_pattern": r"^SYNTH_",
            "allow_par_value_as_market_value": True,
        },
        "h15": {
            "date_column_candidates": ["observation_date", "date"],
            "yield_unit": "percent",
            "key_rate_column_candidates": {
                "1.0": ["treasury_1y_yield"],
                "5.0": ["treasury_5y_yield"],
                "10.0": ["treasury_10y_yield"],
            },
        },
        "valuation": {
            "floor_price_factor": 0.0,
            "scale_shocks_by_sqrt_liquidation_horizon": True,
            "reference_liquidation_days": 1.0,
        },
        "market_impact": {
            "enabled": False,
            "reference_position_usd": 100_000_000.0,
            "base_impact_bp": 2.0,
            "size_exponent": 0.60,
            "maximum_impact_bp": 75.0,
            "concentration_threshold": 0.20,
            "concentration_multiplier_per_excess_share": 2.0,
        },
        "maturity_buckets": buckets,
        "scenarios": [],
    }


@pytest.fixture
def positions() -> pd.DataFrame:
    return pd.DataFrame(
        {
            "member_id": ["SYNTH_001", "SYNTH_001", "SYNTH_002"],
            "maturity_bucket": ["short", "long", "intermediate"],
            "market_value_usd": [100_000_000.0, 50_000_000.0, 75_000_000.0],
        }
    )


def test_duration_convexity_formula() -> None:
    result = duration_convexity_price_return(5.0, 20.0, 100.0)
    expected = -5.0 * 0.01 + 0.5 * 20.0 * 0.01**2
    assert result == pytest.approx(expected)


def test_positive_convexity_reduces_parallel_up_loss() -> None:
    linear = duration_convexity_price_return(5.0, 0.0, 100.0)
    curved = duration_convexity_price_return(5.0, 50.0, 100.0)
    assert curved > linear


def test_parallel_shift_is_equal_across_buckets(config: dict[str, Any]) -> None:
    shocks = build_shock_vector(
        {"name": "parallel", "type": "parallel", "shock_bp": 100.0},
        config["maturity_buckets"],
    )
    assert set(shocks.values()) == {100.0}


def test_steepening_vector_increases_with_maturity(config: dict[str, Any]) -> None:
    shocks = build_shock_vector(
        {
            "name": "steepener",
            "type": "bucket_vector",
            "shocks_bp": {"short": 25.0, "intermediate": 60.0, "long": 100.0},
        },
        config["maturity_buckets"],
    )
    assert shocks["short"] < shocks["intermediate"] < shocks["long"]


def test_flattening_vector_decreases_with_maturity(config: dict[str, Any]) -> None:
    shocks = build_shock_vector(
        {
            "name": "flattener",
            "type": "bucket_vector",
            "shocks_bp": {"short": 100.0, "intermediate": 60.0, "long": 25.0},
        },
        config["maturity_buckets"],
    )
    assert shocks["short"] > shocks["intermediate"] > shocks["long"]


def test_key_rate_shock_peaks_near_target(config: dict[str, Any]) -> None:
    shocks = build_shock_vector(
        {
            "name": "key5",
            "type": "key_rate",
            "key_rate_years": 5.0,
            "peak_bp": 100.0,
            "width_years": 6.0,
            "floor_bp": 0.0,
        },
        config["maturity_buckets"],
    )
    assert shocks["intermediate"] == pytest.approx(100.0)
    assert shocks["intermediate"] > shocks["short"]
    assert shocks["intermediate"] > shocks["long"]


def test_liquidation_horizon_scales_shock(config: dict[str, Any], positions: pd.DataFrame) -> None:
    scenario = {"name": "parallel", "family": "parallel", "type": "parallel", "shock_bp": 100.0}
    result = TreasuryYieldShockModel(config).apply_scenario(positions, scenario)
    short_shock = result.loc[result["maturity_bucket"] == "short", "horizon_scaled_shock_bp"].iloc[
        0
    ]
    long_shock = result.loc[result["maturity_bucket"] == "long", "horizon_scaled_shock_bp"].iloc[0]
    assert short_shock == pytest.approx(100.0)
    assert long_shock == pytest.approx(200.0)


def test_market_impact_increases_with_position_size(config: dict[str, Any]) -> None:
    stressed_config = deepcopy(config)
    stressed_config["market_impact"]["enabled"] = True
    frame = pd.DataFrame(
        {
            "member_id": ["SYNTH_001", "SYNTH_002"],
            "maturity_bucket": ["short", "short"],
            "market_value_usd": [10_000_000.0, 500_000_000.0],
        }
    )
    scenario = {"name": "parallel", "family": "parallel", "type": "parallel", "shock_bp": 100.0}
    result = TreasuryYieldShockModel(stressed_config).apply_scenario(frame, scenario)
    impacts = result.sort_values("market_value_usd")["market_impact_bp"].tolist()
    assert impacts[1] > impacts[0]


def test_model_is_deterministic(config: dict[str, Any], positions: pd.DataFrame) -> None:
    scenario = {"name": "parallel", "family": "parallel", "type": "parallel", "shock_bp": 100.0}
    model = TreasuryYieldShockModel(config)
    first = model.apply_scenario(positions, scenario)
    second = model.apply_scenario(positions, scenario)
    pd.testing.assert_frame_equal(first, second)


def test_h15_changes_are_converted_to_basis_points(config: dict[str, Any]) -> None:
    h15 = pd.DataFrame(
        {
            "observation_date": ["2020-03-02", "2020-03-16"],
            "treasury_1y_yield": [1.00, 0.50],
            "treasury_5y_yield": [1.10, 0.70],
            "treasury_10y_yield": [1.20, 0.90],
        }
    )
    shocks = derive_h15_bucket_shocks(
        h15,
        "2020-03-02",
        "2020-03-16",
        config,
    )
    assert shocks["short"] == pytest.approx(-50.0)
    assert shocks["intermediate"] == pytest.approx(-40.0)
    assert shocks["long"] == pytest.approx(-30.0)


def test_non_synthetic_member_identifier_is_rejected(
    config: dict[str, Any],
    positions: pd.DataFrame,
) -> None:
    invalid = positions.copy()
    invalid.loc[0, "member_id"] = "ACTUAL_MEMBER_NAME"
    scenario = {"name": "parallel", "family": "parallel", "type": "parallel", "shock_bp": 100.0}
    with pytest.raises(TreasuryYieldStressError, match="Synthetic-member safeguard"):
        TreasuryYieldShockModel(config).apply_scenario(invalid, scenario)


def test_wide_member_positions_are_melted_to_buckets(config: dict[str, Any]) -> None:
    wide_config = deepcopy(config)
    wide_config["input"]["wide_position_column_candidates"] = {
        "short": ["treasury_short_usd"],
        "intermediate": ["treasury_intermediate_usd"],
        "long": ["treasury_long_usd"],
    }
    wide = pd.DataFrame(
        {
            "member_id": ["SYNTH_001"],
            "treasury_short_usd": [10_000_000.0],
            "treasury_intermediate_usd": [20_000_000.0],
            "treasury_long_usd": [30_000_000.0],
        }
    )
    scenario = {
        "name": "parallel",
        "family": "parallel",
        "type": "parallel",
        "shock_bp": 100.0,
    }
    result = TreasuryYieldShockModel(wide_config).apply_scenario(wide, scenario)
    assert set(result["maturity_bucket"]) == {"short", "intermediate", "long"}
    assert result["market_value_usd"].sum() == pytest.approx(60_000_000.0)


def test_run_produces_member_and_scenario_summaries(
    config: dict[str, Any],
    positions: pd.DataFrame,
) -> None:
    scenarios = [
        {"name": "up", "family": "parallel", "type": "parallel", "shock_bp": 100.0},
        {"name": "down", "family": "parallel", "type": "parallel", "shock_bp": -100.0},
    ]
    result = TreasuryYieldShockModel(config).run(positions, scenarios=scenarios)
    assert len(result.scenario_summary) == 2
    assert set(result.member_summary["member_id"]) == {"SYNTH_001", "SYNTH_002"}
    assert (result.positions["treasury_loss_usd"] >= 0).all()
