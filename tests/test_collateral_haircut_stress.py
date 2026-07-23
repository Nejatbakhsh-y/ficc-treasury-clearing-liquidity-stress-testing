# mypy: ignore-errors
"""Tests for Phase V, Section 17 collateral haircut stress."""

from __future__ import annotations

from copy import deepcopy
from pathlib import Path
from typing import Any

import pandas as pd
import pytest

from ficc_liquidity.stress.collateral_haircut_stress import (
    CollateralHaircutStressError,
    dataframe_digest,
    load_settings,
    prepare_baseline,
    prepare_members,
    read_table,
    run_model,
)


def config() -> dict[str, Any]:
    """Return a compact valid Section 17 configuration."""
    return {
        "model_version": "section-17-test",
        "source": {"synthetic_id_pattern": r"^SYN-MBR-[0-9]{4}$"},
        "maturity_buckets": {
            "short": {
                "source_columns": ["treasury_short_usd"],
                "base_haircut_rate": 0.01,
                "eligibility_factor": 1.00,
            },
            "long": {
                "source_columns": ["treasury_long_usd"],
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
                "bucket_addons": {"short": 0.0, "long": 0.0},
                "concentration_threshold": 1.0,
                "concentration_multiplier": 0.0,
                "additional_collateral_call_rate": 0.0,
                "inventory_availability_rate": 1.0,
                "maximum_haircut_rate": 0.50,
            },
            {
                "name": "moderate",
                "enabled": True,
                "severity_rank": 1,
                "stress_multiplier": 1.25,
                "additive_haircut_rate": 0.01,
                "bucket_addons": {"short": 0.0, "long": 0.02},
                "concentration_threshold": 0.60,
                "concentration_multiplier": 0.20,
                "additional_collateral_call_rate": 0.02,
                "inventory_availability_rate": 0.90,
                "maximum_haircut_rate": 0.50,
            },
            {
                "name": "severe",
                "enabled": True,
                "severity_rank": 2,
                "stress_multiplier": 2.0,
                "additive_haircut_rate": 0.03,
                "bucket_addons": {"short": 0.01, "long": 0.05},
                "concentration_threshold": 0.40,
                "concentration_multiplier": 0.50,
                "additional_collateral_call_rate": 0.08,
                "inventory_availability_rate": 0.50,
                "maximum_haircut_rate": 0.50,
            },
        ],
        "validation": {"reconciliation_tolerance_usd": 0.01},
    }


def members() -> pd.DataFrame:
    """Return fictional synthetic member profiles."""
    return pd.DataFrame(
        [
            {
                "member_id": "SYN-MBR-0001",
                "treasury_short_usd": 700.0,
                "treasury_long_usd": 300.0,
                "total_treasury_position_usd": 1000.0,
                "repo_financing_need_usd": 400.0,
                "collateral_inventory_usd": 900.0,
                "available_qualified_liquid_resources_usd": 600.0,
                "value_class": "synthetic",
                "actual_ficc_participant": False,
                "participant_level_inference": False,
            },
            {
                "member_id": "SYN-MBR-0002",
                "treasury_short_usd": 200.0,
                "treasury_long_usd": 800.0,
                "total_treasury_position_usd": 1000.0,
                "repo_financing_need_usd": 650.0,
                "collateral_inventory_usd": 720.0,
                "available_qualified_liquid_resources_usd": 450.0,
                "value_class": "synthetic",
                "actual_ficc_participant": False,
                "participant_level_inference": False,
            },
        ]
    )


def baseline() -> pd.DataFrame:
    """Return two time buckets per fictional member."""
    rows: list[dict[str, object]] = []
    for member_id, resources, need, eligible, cash in (
        ("SYN-MBR-0001", 700.0, 500.0, 600.0, 100.0),
        ("SYN-MBR-0002", 500.0, 475.0, 450.0, 50.0),
    ):
        rows.extend(
            [
                {
                    "member_id": member_id,
                    "bucket_order": 1,
                    "time_bucket": "open",
                    "cumulative_net_liquidity_need_usd": need * 0.5,
                    "cumulative_available_resources_usd": resources,
                    "eligible_collateral_liquidity_usd": eligible,
                    "available_cash_usd": cash,
                    "liquidity_headroom_usd": resources - need * 0.5,
                    "liquidity_shortfall_usd": 0.0,
                    "value_class": "synthetic",
                    "actual_ficc_participant": False,
                    "participant_level_inference": False,
                },
                {
                    "member_id": member_id,
                    "bucket_order": 2,
                    "time_bucket": "close",
                    "cumulative_net_liquidity_need_usd": need,
                    "cumulative_available_resources_usd": resources,
                    "eligible_collateral_liquidity_usd": eligible,
                    "available_cash_usd": cash,
                    "liquidity_headroom_usd": resources - need,
                    "liquidity_shortfall_usd": max(need - resources, 0.0),
                    "value_class": "synthetic",
                    "actual_ficc_participant": False,
                    "participant_level_inference": False,
                },
            ]
        )
    return pd.DataFrame.from_records(rows)


def test_settings_validate_and_order_scenarios() -> None:
    settings = load_settings(config())
    assert [item.name for item in settings.scenarios] == [
        "control",
        "moderate",
        "severe",
    ]
    assert [item.name for item in settings.maturity_buckets] == ["short", "long"]


@pytest.mark.parametrize(
    ("path", "value"),
    [
        (("maturity_buckets", "short", "base_haircut_rate"), 1.0),
        (("scenarios", 1, "stress_multiplier"), 0.9),
        (("scenarios", 1, "inventory_availability_rate"), 1.1),
        (("validation", "reconciliation_tolerance_usd"), -1.0),
    ],
)
def test_invalid_settings_are_rejected(
    path: tuple[object, ...],
    value: object,
) -> None:
    raw = deepcopy(config())
    target: Any = raw
    for key in path[:-1]:
        target = target[key]
    target[path[-1]] = value
    with pytest.raises(CollateralHaircutStressError):
        load_settings(raw)


def test_complete_model_passes_all_controls() -> None:
    result = run_model(members(), baseline(), config())
    assert result.passed
    assert all(result.checks.values())
    assert len(result.bucket_results) == 12
    assert len(result.member_summary) == 6
    assert len(result.scenario_summary) == 3


def test_control_scenario_is_zero_incremental_stress() -> None:
    result = run_model(members(), baseline(), config())
    control = result.member_summary.query("scenario_name == 'control'")
    assert control["additional_collateral_requirement_total_usd"].eq(0.0).all()
    assert control["collateral_resource_reduction_usd"].eq(0.0).all()
    assert (
        control["stressed_available_resources_usd"] == control["baseline_available_resources_usd"]
    ).all()


def test_haircuts_are_maturity_and_stress_dependent() -> None:
    result = run_model(members(), baseline(), config())
    member = result.bucket_results.query("member_id == 'SYN-MBR-0001'")
    control = member.query("scenario_name == 'control'").set_index("maturity_bucket")
    severe = member.query("scenario_name == 'severe'").set_index("maturity_bucket")
    assert control.loc["long", "base_haircut_rate"] > control.loc["short", "base_haircut_rate"]
    assert (
        severe.loc["short", "stressed_haircut_rate"] > control.loc["short", "stressed_haircut_rate"]
    )
    assert (
        severe.loc["long", "stressed_haircut_rate"] > severe.loc["short", "stressed_haircut_rate"]
    )


def test_concentration_multiplier_increases_haircut() -> None:
    result = run_model(members(), baseline(), config())
    severe = result.bucket_results.query("scenario_name == 'severe'")
    concentrated = severe.query("member_id == 'SYN-MBR-0002' and maturity_bucket == 'long'").iloc[0]
    less_concentrated = severe.query(
        "member_id == 'SYN-MBR-0001' and maturity_bucket == 'long'"
    ).iloc[0]
    assert concentrated["bucket_weight"] > less_concentrated["bucket_weight"]
    assert (
        concentrated["concentration_haircut_addon"]
        > less_concentrated["concentration_haircut_addon"]
    )


def test_additional_collateral_requirement_decomposes() -> None:
    result = run_model(members(), baseline(), config())
    severe = result.bucket_results.query("scenario_name == 'severe'")
    expected = (
        severe["haircut_driven_collateral_call_usd"]
        + severe["scenario_additional_collateral_call_usd"]
    )
    pd.testing.assert_series_equal(
        severe["additional_collateral_requirement_usd"].reset_index(drop=True),
        expected.reset_index(drop=True),
        check_names=False,
    )


def test_available_collateral_constraint_creates_shortfall() -> None:
    constrained = members()
    constrained.loc[:, "collateral_inventory_usd"] = 300.0
    result = run_model(constrained, baseline(), config())
    severe = result.member_summary.query("scenario_name == 'severe'")
    assert (severe["collateral_shortfall_total_usd"] > 0.0).any()
    bucket = result.bucket_results.query("scenario_name == 'severe'")
    assert (
        bucket["collateral_posted_usd"] <= bucket["stressed_available_collateral_usd"] + 0.01
    ).all()


def test_more_inventory_reduces_collateral_shortfall() -> None:
    low = members()
    low.loc[:, "collateral_inventory_usd"] = 300.0
    high = members()
    high.loc[:, "collateral_inventory_usd"] = 1500.0
    low_result = run_model(low, baseline(), config())
    high_result = run_model(high, baseline(), config())
    low_shortfall = low_result.scenario_summary.query("scenario_name == 'severe'")[
        "collateral_shortfall_total_usd"
    ].iloc[0]
    high_shortfall = high_result.scenario_summary.query("scenario_name == 'severe'")[
        "collateral_shortfall_total_usd"
    ].iloc[0]
    assert high_shortfall <= low_shortfall


def test_synthetic_identity_controls_reject_actual_or_invalid_members() -> None:
    invalid = members()
    invalid.loc[0, "member_id"] = "ACTUAL-MEMBER"
    with pytest.raises(CollateralHaircutStressError):
        run_model(invalid, baseline(), config())

    actual = members()
    actual.loc[0, "actual_ficc_participant"] = True
    with pytest.raises(CollateralHaircutStressError):
        prepare_members(actual, load_settings(config()))


def test_missing_required_inputs_are_rejected() -> None:
    missing_member_field = members().drop(columns=["collateral_inventory_usd"])
    with pytest.raises(CollateralHaircutStressError):
        prepare_members(missing_member_field, load_settings(config()))

    missing_baseline_field = baseline().drop(columns=["cumulative_available_resources_usd"])
    with pytest.raises(CollateralHaircutStressError):
        prepare_baseline(missing_baseline_field, load_settings(config()))


def test_deterministic_under_input_row_reordering() -> None:
    first = run_model(members(), baseline(), config())
    second = run_model(
        members().sample(frac=1.0, random_state=10).reset_index(drop=True),
        baseline().sample(frac=1.0, random_state=11).reset_index(drop=True),
        config(),
    )
    assert dataframe_digest(first.bucket_results) == dataframe_digest(second.bucket_results)
    assert dataframe_digest(first.member_summary) == dataframe_digest(second.member_summary)


def test_csv_read_table_and_unsupported_extension(tmp_path: Path) -> None:
    csv_path = tmp_path / "members.csv"
    members().to_csv(csv_path, index=False)
    loaded = read_table(csv_path)
    assert len(loaded) == len(members())

    unsupported = tmp_path / "members.txt"
    unsupported.write_text("not a table", encoding="utf-8")
    with pytest.raises(CollateralHaircutStressError):
        read_table(unsupported)


def test_config_and_table_path_errors(tmp_path: Path) -> None:
    from ficc_liquidity.stress.collateral_haircut_stress import load_config

    with pytest.raises(CollateralHaircutStressError):
        load_config(tmp_path / "missing.yaml")
    with pytest.raises(CollateralHaircutStressError):
        read_table(tmp_path / "missing.csv")


def test_position_reconciliation_and_source_column_errors() -> None:
    settings = load_settings(config())
    mismatched = members()
    mismatched.loc[0, "total_treasury_position_usd"] = 9999.0
    with pytest.raises(CollateralHaircutStressError):
        prepare_members(mismatched, settings)

    missing_bucket = members().drop(columns=["treasury_long_usd"])
    with pytest.raises(CollateralHaircutStressError):
        prepare_members(missing_bucket, settings)


def test_baseline_accounting_identity_errors() -> None:
    settings = load_settings(config())
    bad_headroom = baseline()
    bad_headroom.loc[bad_headroom["bucket_order"] == 2, "liquidity_headroom_usd"] += 10.0
    with pytest.raises(CollateralHaircutStressError):
        prepare_baseline(bad_headroom, settings)

    bad_shortfall = baseline()
    bad_shortfall.loc[bad_shortfall["bucket_order"] == 2, "liquidity_shortfall_usd"] = 10.0
    with pytest.raises(CollateralHaircutStressError):
        prepare_baseline(bad_shortfall, settings)


def test_disabled_scenarios_and_duplicate_scenarios_are_rejected() -> None:
    no_enabled = deepcopy(config())
    for scenario in no_enabled["scenarios"]:
        scenario["enabled"] = False
    with pytest.raises(CollateralHaircutStressError):
        load_settings(no_enabled)

    duplicate = deepcopy(config())
    duplicate["scenarios"][2]["name"] = "moderate"
    with pytest.raises(CollateralHaircutStressError):
        load_settings(duplicate)


def test_more_configuration_validation_branches() -> None:
    unknown_bucket = deepcopy(config())
    unknown_bucket["scenarios"][1]["bucket_addons"]["unknown"] = 0.01
    with pytest.raises(CollateralHaircutStressError):
        load_settings(unknown_bucket)

    duplicate_rank = deepcopy(config())
    duplicate_rank["scenarios"][2]["severity_rank"] = 1
    with pytest.raises(CollateralHaircutStressError):
        load_settings(duplicate_rank)

    nonmonotonic = deepcopy(config())
    nonmonotonic["scenarios"][2]["additional_collateral_call_rate"] = 0.01
    with pytest.raises(CollateralHaircutStressError):
        load_settings(nonmonotonic)


def test_member_numeric_and_classification_controls() -> None:
    settings = load_settings(config())
    negative = members()
    negative.loc[0, "repo_financing_need_usd"] = -1.0
    with pytest.raises(CollateralHaircutStressError):
        prepare_members(negative, settings)

    wrong_class = members()
    wrong_class.loc[0, "value_class"] = "observed"
    with pytest.raises(CollateralHaircutStressError):
        prepare_members(wrong_class, settings)

    duplicate = pd.concat([members(), members().iloc[[0]]], ignore_index=True)
    with pytest.raises(CollateralHaircutStressError):
        prepare_members(duplicate, settings)


def test_baseline_identity_and_numeric_controls() -> None:
    settings = load_settings(config())
    nonnumeric = baseline()
    nonnumeric["available_cash_usd"] = nonnumeric["available_cash_usd"].astype(object)
    nonnumeric.loc[0, "available_cash_usd"] = "bad"
    with pytest.raises(CollateralHaircutStressError):
        prepare_baseline(nonnumeric, settings)

    actual = baseline()
    actual.loc[0, "participant_level_inference"] = True
    with pytest.raises(CollateralHaircutStressError):
        prepare_baseline(actual, settings)


def test_empty_inputs_are_rejected() -> None:
    settings = load_settings(config())
    with pytest.raises(CollateralHaircutStressError):
        prepare_members(pd.DataFrame(), settings)
    with pytest.raises(CollateralHaircutStressError):
        prepare_baseline(pd.DataFrame(), settings)
