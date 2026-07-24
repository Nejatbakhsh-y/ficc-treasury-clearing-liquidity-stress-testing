from __future__ import annotations

from copy import deepcopy
from pathlib import Path
from typing import Any, cast

import pandas as pd
import pytest
import yaml

from ficc_liquidity.scenarios.hypothetical_scenarios import (
    REQUIRED_FAMILIES,
    REQUIRED_SCENARIOS,
    HypotheticalScenarioError,
    build_funding_config,
    build_haircut_config,
    build_integrated_config,
    build_settlement_config,
    build_treasury_scenarios,
    expand_treasury_shock,
    load_scenarios,
    load_settings,
    scenario_catalog_frame,
    treasury_shock_frame,
)

ROOT = Path(__file__).resolve().parents[1]


def _config() -> dict[str, Any]:
    path = ROOT / "configs" / "hypothetical_scenarios.yaml"
    loaded = yaml.safe_load(path.read_text(encoding="utf-8"))
    assert isinstance(loaded, dict)
    return cast(dict[str, Any], loaded)


def _treasury_config() -> dict[str, Any]:
    return {
        "maturity_buckets": {
            "bills_0_1y": {"midpoint_years": 0.5},
            "notes_1_3y": {"midpoint_years": 2.0},
            "notes_3_7y": {"midpoint_years": 5.0},
            "notes_7_10y": {"midpoint_years": 8.5},
            "bonds_10_30y": {"midpoint_years": 20.0},
            "strips_30y_plus": {"midpoint_years": 32.0},
        }
    }


def _funding_base() -> dict[str, Any]:
    return {
        "model_version": "section-16-v1",
        "scenarios": [
            {
                "name": "control",
                "enabled": True,
                "severity_rank": 0,
                "sofr_spike_bp": 0.0,
                "funding_spread_increase_bp": 0.0,
                "repo_rollover_failure_rate": 0.0,
                "lender_withdrawal_rate": 0.0,
                "refinancing_horizon_hours": 48,
                "collateral_haircut_increase": 0.0,
                "collateral_call_rate": 0.0,
                "concentration_threshold": 0.25,
                "concentration_multiplier": 0.0,
                "funding_dependency_multiplier": 0.0,
                "max_effective_unavailability_rate": 0.0,
            }
        ],
    }


def _haircut_base() -> dict[str, Any]:
    return {
        "model_version": "section-17-v1",
        "maturity_buckets": {
            "short": {
                "source_columns": ["short_usd"],
                "base_haircut_rate": 0.01,
                "eligibility_factor": 1.0,
            },
            "medium": {
                "source_columns": ["medium_usd"],
                "base_haircut_rate": 0.03,
                "eligibility_factor": 0.98,
            },
            "long": {
                "source_columns": ["long_usd"],
                "base_haircut_rate": 0.08,
                "eligibility_factor": 0.90,
            },
        },
        "scenarios": [
            {
                "name": "control",
                "enabled": True,
                "severity_rank": 0,
                "stress_multiplier": 1.0,
                "additive_haircut_rate": 0.0,
                "bucket_addons": {"short": 0.0, "medium": 0.0, "long": 0.0},
                "concentration_threshold": 1.0,
                "concentration_multiplier": 0.0,
                "additional_collateral_call_rate": 0.0,
                "inventory_availability_rate": 1.0,
                "maximum_haircut_rate": 0.50,
            }
        ],
    }


def _settlement_base() -> dict[str, Any]:
    return {
        "model_version": "section-18-v1",
        "scenarios": [
            {
                "name": "control",
                "enabled": True,
                "severity_rank": 0,
                "fails_to_receive_multiplier": 0.0,
                "fails_to_deliver_multiplier": 0.0,
                "additional_fails_to_receive_rate": 0.0,
                "additional_fails_to_deliver_rate": 0.0,
                "incoming_payment_delay_buckets": 0,
                "replacement_liquidity_rate": 0.0,
                "persistence_days": 1,
                "persistence_decay": 0.0,
                "funding_scenario_name": "control",
                "funding_stress_weight": 0.0,
            }
        ],
    }


def _integrated_base() -> dict[str, Any]:
    return {
        "model_version": "section-19-v1",
        "scenarios": [
            {
                "name": "control",
                "enabled": True,
                "severity_rank": 0,
                "funding_scenario_name": "control",
                "haircut_scenario_name": "control",
                "treasury_scenario_name": "NONE",
                "settlement_fail_scenario_name": "control",
                "concentration_threshold": 1.0,
                "concentration_multiplier": 0.0,
                "operational_liquidity_buffer_rate": 0.0,
            }
        ],
    }


def _scenarios() -> tuple[Any, ...]:
    config = _config()
    settings = load_settings(config, Path("."))
    return load_scenarios(config, settings.guardrails)


def test_required_scenarios_and_families_are_complete() -> None:
    scenarios = _scenarios()
    assert {item.name for item in scenarios} == set(REQUIRED_SCENARIOS)
    assert {item.family for item in scenarios} >= REQUIRED_FAMILIES
    assert [item.display_order for item in scenarios] == list(range(1, 12))


def test_parallel_treasury_shock_expands_to_all_buckets() -> None:
    scenario = next(item for item in _scenarios() if item.name == "parallel_treasury_shock")
    vector = expand_treasury_shock(scenario, _treasury_config())
    assert len(vector) == 6
    assert set(vector.values()) == {150.0}


def test_curve_shapes_have_required_direction() -> None:
    scenarios = {item.name: item for item in _scenarios()}
    steep = list(expand_treasury_shock(scenarios["curve_steepening"], _treasury_config()).values())
    flat = list(expand_treasury_shock(scenarios["curve_flattening"], _treasury_config()).values())
    assert steep == sorted(steep)
    assert flat == sorted(flat, reverse=True)


def test_treasury_builder_excludes_none_shapes() -> None:
    built = build_treasury_scenarios(_scenarios(), _treasury_config())
    names = {row["name"] for row in built}
    assert "sofr_spike" not in names
    assert "parallel_treasury_shock" in names
    assert "combined_systemic_stress" in names


def test_component_builders_create_control_and_target() -> None:
    scenario = next(item for item in _scenarios() if item.name == "moderate_stress")
    funding = build_funding_config(_funding_base(), scenario, "section-21-test")
    haircut = build_haircut_config(_haircut_base(), scenario, "section-21-test")
    settlement = build_settlement_config(_settlement_base(), scenario, "section-21-test")
    integrated = build_integrated_config(
        _integrated_base(),
        scenario,
        "section-21-test",
        treasury_active=True,
    )

    assert [row["name"] for row in funding["scenarios"]] == ["control", "moderate_stress"]
    assert funding["scenarios"][1]["repo_rollover_failure_rate"] == pytest.approx(0.10)
    assert list(haircut["scenarios"][1]["bucket_addons"].values()) == pytest.approx(
        [0.0, 0.0075, 0.015]
    )
    assert settlement["scenarios"][1]["funding_scenario_name"] == "moderate_stress"
    assert integrated["scenarios"][1]["treasury_scenario_name"] == "moderate_stress"


def test_integrated_builder_uses_none_for_no_yield_shock() -> None:
    scenario = next(item for item in _scenarios() if item.name == "sofr_spike")
    built = build_integrated_config(
        _integrated_base(),
        scenario,
        "section-21-test",
        treasury_active=False,
    )
    assert built["scenarios"][1]["treasury_scenario_name"] == "NONE"


def test_catalog_and_treasury_frames_are_ordered() -> None:
    scenarios = _scenarios()
    catalog = scenario_catalog_frame(scenarios, _treasury_config())
    shocks = treasury_shock_frame(scenarios, _treasury_config())
    assert isinstance(catalog, pd.DataFrame)
    assert catalog["display_order"].tolist() == list(range(1, 12))
    assert not catalog["actual_ficc_participant"].any()
    assert shocks["display_order"].is_monotonic_increasing


def test_guardrail_violation_is_rejected() -> None:
    config = _config()
    scenarios = cast(list[dict[str, Any]], config["scenarios"])
    scenarios[0]["funding"]["sofr_spike_bp"] = 999.0
    settings = load_settings(config, Path("."))
    with pytest.raises(HypotheticalScenarioError, match="sofr_spike_bp"):
        load_scenarios(config, settings.guardrails)


def test_duplicate_display_order_is_rejected() -> None:
    config = _config()
    scenarios = cast(list[dict[str, Any]], config["scenarios"])
    scenarios[1]["display_order"] = scenarios[0]["display_order"]
    settings = load_settings(config, Path("."))
    with pytest.raises(HypotheticalScenarioError, match="display_order"):
        load_scenarios(config, settings.guardrails)


def test_missing_required_scenario_is_rejected() -> None:
    config = deepcopy(_config())
    scenarios = cast(list[dict[str, Any]], config["scenarios"])
    config["scenarios"] = [row for row in scenarios if row["name"] != "combined_systemic_stress"]
    settings = load_settings(config, Path("."))
    with pytest.raises(HypotheticalScenarioError, match="missing"):
        load_scenarios(config, settings.guardrails)


def test_settings_reject_nonpositive_guardrail() -> None:
    config = _config()
    guardrails = cast(dict[str, Any], config["guardrails"])
    guardrails["maximum_sofr_spike_bp"] = 0.0
    with pytest.raises(HypotheticalScenarioError, match="finite and positive"):
        load_settings(config, Path("."))


def test_settings_reject_negative_tolerance() -> None:
    config = _config()
    validation = cast(dict[str, Any], config["validation"])
    validation["reconciliation_tolerance_usd"] = -1.0
    with pytest.raises(HypotheticalScenarioError, match="must be nonnegative"):
        load_settings(config, Path("."))


def test_unsupported_treasury_shape_is_rejected() -> None:
    config = _config()
    scenarios = cast(list[dict[str, Any]], config["scenarios"])
    scenarios[0]["treasury"]["shape"] = "twist"
    settings = load_settings(config, Path("."))
    with pytest.raises(HypotheticalScenarioError, match="unsupported"):
        load_scenarios(config, settings.guardrails)


def test_invalid_curve_direction_is_rejected() -> None:
    config = _config()
    scenarios = cast(list[dict[str, Any]], config["scenarios"])
    steepening = next(row for row in scenarios if row["name"] == "curve_steepening")
    steepening["treasury"]["short_end_bp"] = 200.0
    steepening["treasury"]["long_end_bp"] = 100.0
    settings = load_settings(config, Path("."))
    with pytest.raises(HypotheticalScenarioError, match="steepening requires"):
        load_scenarios(config, settings.guardrails)


def test_invalid_funding_horizon_is_rejected() -> None:
    config = _config()
    scenarios = cast(list[dict[str, Any]], config["scenarios"])
    scenarios[0]["funding"]["refinancing_horizon_hours"] = 0
    settings = load_settings(config, Path("."))
    with pytest.raises(HypotheticalScenarioError, match="must be positive"):
        load_scenarios(config, settings.guardrails)


def test_invalid_haircut_multiplier_is_rejected() -> None:
    config = _config()
    scenarios = cast(list[dict[str, Any]], config["scenarios"])
    scenarios[0]["haircut"]["stress_multiplier"] = 0.99
    settings = load_settings(config, Path("."))
    with pytest.raises(HypotheticalScenarioError, match="at least one"):
        load_scenarios(config, settings.guardrails)


def test_invalid_settlement_persistence_is_rejected() -> None:
    config = _config()
    scenarios = cast(list[dict[str, Any]], config["scenarios"])
    scenarios[0]["settlement"]["persistence_days"] = 0
    settings = load_settings(config, Path("."))
    with pytest.raises(HypotheticalScenarioError, match="must be positive"):
        load_scenarios(config, settings.guardrails)


def test_invalid_integrated_buffer_is_rejected() -> None:
    config = _config()
    scenarios = cast(list[dict[str, Any]], config["scenarios"])
    scenarios[0]["integrated"]["operational_liquidity_buffer_rate"] = 0.50
    settings = load_settings(config, Path("."))
    with pytest.raises(HypotheticalScenarioError, match="operational_liquidity_buffer_rate"):
        load_scenarios(config, settings.guardrails)


def test_duplicate_scenario_name_is_rejected() -> None:
    config = _config()
    scenarios = cast(list[dict[str, Any]], config["scenarios"])
    scenarios[1]["name"] = scenarios[0]["name"]
    settings = load_settings(config, Path("."))
    with pytest.raises(HypotheticalScenarioError, match="names must be unique"):
        load_scenarios(config, settings.guardrails)


def test_unknown_bucket_vector_is_rejected_when_expanded() -> None:
    config = _config()
    scenarios = cast(list[dict[str, Any]], config["scenarios"])
    scenario_row = scenarios[0]
    scenario_row["treasury"] = {
        "shape": "bucket_vector",
        "shocks_bp": {"unknown_bucket": 25.0},
    }
    settings = load_settings(config, Path("."))
    scenario = load_scenarios(config, settings.guardrails)[0]
    with pytest.raises(HypotheticalScenarioError, match="unknown Treasury buckets"):
        expand_treasury_shock(scenario, _treasury_config())


def test_single_bucket_curve_expansion_is_supported() -> None:
    scenario = next(item for item in _scenarios() if item.name == "curve_steepening")
    config = {"maturity_buckets": {"only": {"midpoint_years": 2.0}}}
    assert expand_treasury_shock(scenario, config) == {"only": 25.0}


def test_empty_scenario_list_is_rejected() -> None:
    config = _config()
    config["scenarios"] = []
    settings = load_settings(config, Path("."))
    with pytest.raises(HypotheticalScenarioError, match="nonempty"):
        load_scenarios(config, settings.guardrails)


def test_base_configuration_requires_control_scenario() -> None:
    scenario = next(item for item in _scenarios() if item.name == "moderate_stress")
    with pytest.raises(HypotheticalScenarioError, match="control scenario"):
        build_funding_config(
            {"scenarios": [{"name": "not_control"}]},
            scenario,
            "section-21-test",
        )


def test_empty_haircut_maturity_buckets_are_rejected() -> None:
    scenario = next(item for item in _scenarios() if item.name == "moderate_stress")
    base = _haircut_base()
    base["maturity_buckets"] = {}
    with pytest.raises(HypotheticalScenarioError, match="cannot be empty"):
        build_haircut_config(base, scenario, "section-21-test")
