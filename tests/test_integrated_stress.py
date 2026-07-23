from __future__ import annotations

import math
from collections.abc import Callable
from copy import deepcopy
from pathlib import Path
from typing import Any, cast

import pandas as pd
import pytest
import yaml

from ficc_liquidity.stress.integrated_stress import (
    IntegratedStressError,
    IntegratedStressResult,
    build_double_count_controls,
    build_scenario_summary,
    dataframe_digest,
    load_config,
    load_settings,
    prepare_baseline_summary,
    prepare_funding_summary,
    prepare_haircut_summary,
    prepare_settlement_fail_summary,
    prepare_treasury_summary,
    read_table,
    run_integrated_stress,
    validate_results,
)


def config() -> dict[str, Any]:
    return {
        "model_version": "section-19-test",
        "source": {"synthetic_id_pattern": r"^SYN-MBR-[0-9]{4}$"},
        "integration": {
            "lcr_minimum_ratio": 1.0,
            "concentration_base_components": [
                "settlement_liquidity_need_usd",
                "settlement_fail_requirement_usd",
            ],
        },
        "validation": {"reconciliation_tolerance_usd": 0.01},
        "scenarios": [
            {
                "name": "control",
                "enabled": True,
                "severity_rank": 0,
                "funding_scenario_name": "funding_control",
                "haircut_scenario_name": "haircut_control",
                "treasury_scenario_name": "NONE",
                "settlement_fail_scenario_name": "settlement_control",
                "concentration_threshold": 1.0,
                "concentration_multiplier": 0.0,
                "operational_liquidity_buffer_rate": 0.0,
            },
            {
                "name": "moderate",
                "enabled": True,
                "severity_rank": 1,
                "funding_scenario_name": "funding_moderate",
                "haircut_scenario_name": "haircut_moderate",
                "treasury_scenario_name": "treasury_moderate",
                "settlement_fail_scenario_name": "settlement_moderate",
                "concentration_threshold": 0.30,
                "concentration_multiplier": 0.50,
                "operational_liquidity_buffer_rate": 0.05,
            },
            {
                "name": "severe",
                "enabled": True,
                "severity_rank": 2,
                "funding_scenario_name": "funding_severe",
                "haircut_scenario_name": "haircut_severe",
                "treasury_scenario_name": "treasury_severe",
                "settlement_fail_scenario_name": "settlement_severe",
                "concentration_threshold": 0.25,
                "concentration_multiplier": 0.75,
                "operational_liquidity_buffer_rate": 0.10,
            },
        ],
    }


def baseline() -> pd.DataFrame:
    return pd.DataFrame(
        {
            "member_id": ["SYN-MBR-0001", "SYN-MBR-0002"],
            "net_settlement_outflow_usd": [100.0, 200.0],
            "modeled_aqlr_usd": [500.0, 700.0],
            "value_class": ["synthetic", "synthetic"],
            "actual_ficc_participant": [False, False],
            "participant_level_inference": [False, False],
        }
    )


def funding() -> pd.DataFrame:
    rows: list[dict[str, object]] = []
    values = {
        "funding_control": ((0.0, 0.0, 0.0), (0.0, 0.0, 0.0)),
        "funding_moderate": ((20.0, 5.0, 3.0), (30.0, 7.0, 4.0)),
        "funding_severe": ((40.0, 10.0, 6.0), (60.0, 14.0, 8.0)),
    }
    for scenario_name, member_values in values.items():
        for index, (rollover, cost, collateral) in enumerate(member_values, start=1):
            rows.append(
                {
                    "scenario_name": scenario_name,
                    "member_id": f"SYN-MBR-{index:04d}",
                    "repo_rollover_failure_outflow_usd": rollover,
                    "incremental_funding_cost_usd": cost,
                    "additional_collateral_demand_usd": collateral,
                    "incremental_repo_funding_stress_outflow_usd": (rollover + cost + collateral),
                    "member_concentration_ratio": 0.40 if index == 1 else 0.60,
                    "value_class": "synthetic",
                    "actual_ficc_participant": False,
                    "participant_level_inference": False,
                }
            )
    return pd.DataFrame.from_records(rows)


def haircut() -> pd.DataFrame:
    rows: list[dict[str, object]] = []
    values = {
        "haircut_control": ((0.0, 0.0), (0.0, 0.0)),
        "haircut_moderate": ((10.0, 4.0), (15.0, 6.0)),
        "haircut_severe": ((20.0, 8.0), (30.0, 12.0)),
    }
    for scenario_name, member_values in values.items():
        for index, (requirement, reduction) in enumerate(member_values, start=1):
            rows.append(
                {
                    "scenario_name": scenario_name,
                    "member_id": f"SYN-MBR-{index:04d}",
                    "additional_collateral_requirement_total_usd": requirement,
                    "bucket_qualified_resource_reduction_usd": reduction,
                    "stressed_member_qualified_resources_usd": 500.0 - reduction,
                    "value_class": "synthetic",
                    "actual_ficc_participant": False,
                    "participant_level_inference": False,
                }
            )
    return pd.DataFrame.from_records(rows)


def treasury() -> pd.DataFrame:
    return pd.DataFrame(
        {
            "scenario_name": [
                "treasury_moderate",
                "treasury_moderate",
                "treasury_severe",
                "treasury_severe",
            ],
            "member_id": [
                "SYN-MBR-0001",
                "SYN-MBR-0002",
                "SYN-MBR-0001",
                "SYN-MBR-0002",
            ],
            "treasury_loss_usd": [12.0, 18.0, 24.0, 36.0],
            "value_class": ["synthetic"] * 4,
            "actual_ficc_participant": [False] * 4,
            "participant_level_inference": [False] * 4,
        }
    )


def settlement_fail() -> pd.DataFrame:
    rows: list[dict[str, object]] = []
    values = {
        "settlement_control": ((0.0, 0.0), (0.0, 0.0)),
        "settlement_moderate": ((8.0, 2.0), (10.0, 3.0)),
        "settlement_severe": ((16.0, 4.0), (20.0, 6.0)),
    }
    for scenario_name, member_values in values.items():
        for index, (settlement_only, funding_overlap) in enumerate(member_values, start=1):
            for bucket in ("open", "close"):
                rows.append(
                    {
                        "scenario_name": scenario_name,
                        "member_id": f"SYN-MBR-{index:04d}",
                        "time_bucket": bucket,
                        "incremental_settlement_fail_outflow_usd": settlement_only / 2.0,
                        "combined_funding_shock_outflow_usd": funding_overlap / 2.0,
                        "incremental_combined_stress_outflow_usd": (
                            settlement_only + funding_overlap
                        )
                        / 2.0,
                        "value_class": "synthetic",
                        "actual_ficc_participant": False,
                        "participant_level_inference": False,
                    }
                )
    return pd.DataFrame.from_records(rows)


def run_result() -> IntegratedStressResult:
    return run_integrated_stress(
        baseline(),
        funding(),
        haircut(),
        treasury(),
        settlement_fail(),
        config(),
    )


def test_load_config_and_settings(tmp_path: Path) -> None:
    path = tmp_path / "config.yaml"
    path.write_text(yaml.safe_dump(config()), encoding="utf-8")
    loaded = load_config(path)
    settings = load_settings(loaded)
    assert settings.model_version == "section-19-test"
    assert len(settings.scenarios) == 3


def test_load_config_rejects_missing_and_nonmapping(tmp_path: Path) -> None:
    with pytest.raises(IntegratedStressError, match="does not exist"):
        load_config(tmp_path / "missing.yaml")
    path = tmp_path / "bad.yaml"
    path.write_text("- not\n- a\n- mapping\n", encoding="utf-8")
    with pytest.raises(IntegratedStressError, match="YAML mapping"):
        load_config(path)


@pytest.mark.parametrize(
    ("mutator", "message"),
    [
        (
            lambda value: value["integration"].update(
                concentration_base_components=["unknown_component"]
            ),
            "unsupported component",
        ),
        (
            lambda value: value["integration"].update(
                concentration_base_components=[
                    "settlement_liquidity_need_usd",
                    "settlement_liquidity_need_usd",
                ]
            ),
            "must be unique",
        ),
        (
            lambda value: value["integration"].update(lcr_minimum_ratio=0.0),
            "must be positive",
        ),
        (
            lambda value: value["validation"].update(reconciliation_tolerance_usd=-1.0),
            "must be nonnegative",
        ),
        (
            lambda value: value["scenarios"][1].update(operational_liquidity_buffer_rate=1.1),
            "between zero and one",
        ),
        (
            lambda value: value["scenarios"][1].update(concentration_multiplier=-0.1),
            "must be nonnegative",
        ),
        (
            lambda value: value["scenarios"][1].update(name="control"),
            "names must be unique",
        ),
        (
            lambda value: value["scenarios"][1].update(severity_rank=0),
            "ranks must be unique",
        ),
    ],
)
def test_settings_reject_invalid_config(
    mutator: Callable[[dict[str, Any]], None], message: str
) -> None:
    value = deepcopy(config())
    mutator(value)
    with pytest.raises(IntegratedStressError, match=message):
        load_settings(value)


def test_settings_reject_nonmonotonic_controls() -> None:
    value = deepcopy(config())
    value["scenarios"][2]["concentration_multiplier"] = 0.25
    with pytest.raises(IntegratedStressError, match="nondecreasing"):
        load_settings(value)
    value = deepcopy(config())
    value["scenarios"][2]["concentration_threshold"] = 0.50
    with pytest.raises(IntegratedStressError, match="cannot increase"):
        load_settings(value)


def test_prepare_baseline_validation() -> None:
    settings = load_settings(config())
    prepared = prepare_baseline_summary(baseline(), settings)
    assert list(prepared.columns) == [
        "member_id",
        "settlement_liquidity_need_usd",
        "available_qualified_liquid_resources_usd",
    ]
    invalid = baseline().drop(columns=["modeled_aqlr_usd"])
    with pytest.raises(IntegratedStressError, match="missing required fields"):
        prepare_baseline_summary(invalid, settings)
    invalid = baseline()
    invalid.loc[0, "net_settlement_outflow_usd"] = -1.0
    with pytest.raises(IntegratedStressError, match="must be nonnegative"):
        prepare_baseline_summary(invalid, settings)


def test_identity_and_uniqueness_controls() -> None:
    settings = load_settings(config())
    invalid = baseline()
    invalid.loc[0, "member_id"] = "ACTUAL-MEMBER"
    with pytest.raises(IntegratedStressError, match="non-synthetic"):
        prepare_baseline_summary(invalid, settings)
    invalid = baseline()
    invalid.loc[0, "actual_ficc_participant"] = True
    with pytest.raises(IntegratedStressError, match="prohibited"):
        prepare_baseline_summary(invalid, settings)
    invalid = pd.concat([baseline(), baseline().iloc[[0]]], ignore_index=True)
    with pytest.raises(IntegratedStressError, match="unique"):
        prepare_baseline_summary(invalid, settings)


def test_prepare_component_tables_and_optional_defaults() -> None:
    settings = load_settings(config())
    funding_input = funding().drop(
        columns=[
            "additional_collateral_demand_usd",
            "incremental_repo_funding_stress_outflow_usd",
        ]
    )
    prepared_funding = prepare_funding_summary(funding_input, settings)
    assert prepared_funding["additional_collateral_demand_usd"].eq(0.0).all()
    assert (
        prepared_funding["incremental_repo_funding_stress_outflow_usd"]
        == prepared_funding["repo_rollover_failure_outflow_usd"]
        + prepared_funding["incremental_funding_cost_usd"]
    ).all()
    assert not prepare_haircut_summary(haircut(), settings).empty
    assert not prepare_treasury_summary(treasury(), settings).empty


def test_prepare_funding_rejects_ratio_and_duplicate() -> None:
    settings = load_settings(config())
    invalid = funding()
    invalid.loc[0, "member_concentration_ratio"] = 1.1
    with pytest.raises(IntegratedStressError, match="must not exceed one"):
        prepare_funding_summary(invalid, settings)
    invalid = pd.concat([funding(), funding().iloc[[0]]], ignore_index=True)
    with pytest.raises(IntegratedStressError, match="unique"):
        prepare_funding_summary(invalid, settings)


def test_settlement_fail_aggregation_and_duplicate_bucket() -> None:
    settings = load_settings(config())
    prepared = prepare_settlement_fail_summary(settlement_fail(), settings)
    row = prepared.query(
        "scenario_name == 'settlement_moderate' and member_id == 'SYN-MBR-0001'"
    ).iloc[0]
    assert row["incremental_settlement_fail_outflow_usd"] == pytest.approx(8.0)
    assert row["combined_funding_shock_outflow_usd"] == pytest.approx(2.0)
    invalid = pd.concat([settlement_fail(), settlement_fail().iloc[[0]]], ignore_index=True)
    with pytest.raises(IntegratedStressError, match="time-bucket keys"):
        prepare_settlement_fail_summary(invalid, settings)


def test_integrated_component_math_and_lcr() -> None:
    result = run_result()
    assert result.passed
    row = result.member_results.query(
        "scenario_name == 'moderate' and member_id == 'SYN-MBR-0001'"
    ).iloc[0]
    assert row["settlement_liquidity_need_usd"] == pytest.approx(100.0)
    assert row["repo_rollover_need_usd"] == pytest.approx(20.0)
    assert row["incremental_funding_cost_usd"] == pytest.approx(5.0)
    assert row["additional_haircut_requirement_usd"] == pytest.approx(10.0)
    assert row["treasury_liquidation_loss_usd"] == pytest.approx(12.0)
    assert row["settlement_fail_requirement_usd"] == pytest.approx(8.0)
    assert row["concentration_adjustment_usd"] == pytest.approx(5.4)
    assert row["operational_liquidity_buffer_usd"] == pytest.approx(8.02)
    assert row["stressed_liquidity_requirement_usd"] == pytest.approx(168.42)
    assert row["liquidity_coverage_ratio"] == pytest.approx(500.0 / 168.42)


def test_control_uses_settlement_need_only() -> None:
    result = run_result()
    control = result.member_results.query("scenario_name == 'control'")
    assert control["stressed_liquidity_requirement_usd"].tolist() == [100.0, 200.0]
    assert control["treasury_liquidation_loss_usd"].eq(0.0).all()


def test_double_count_controls_exclude_composites() -> None:
    result = run_result()
    row = result.double_count_controls.query(
        "scenario_name == 'moderate' and member_id == 'SYN-MBR-0001'"
    ).iloc[0]
    assert row["excluded_section16_additional_collateral_demand_usd"] == 3.0
    assert row["excluded_section16_composite_outflow_usd"] == 28.0
    assert row["excluded_section18_funding_shock_usd"] == 2.0
    assert row["excluded_section18_composite_outflow_usd"] == 10.0
    assert bool(row["double_count_control_pass"])


def test_missing_scenario_and_member_fail_closed() -> None:
    value = treasury().query("scenario_name != 'treasury_severe'")
    with pytest.raises(IntegratedStressError, match="scenario was not found"):
        run_integrated_stress(baseline(), funding(), haircut(), value, settlement_fail(), config())
    value = funding().query("member_id != 'SYN-MBR-0002'")
    with pytest.raises(IntegratedStressError, match="missing mapped members"):
        run_integrated_stress(baseline(), value, haircut(), treasury(), settlement_fail(), config())


def test_zero_requirement_convention() -> None:
    base = baseline()
    base["net_settlement_outflow_usd"] = 0.0
    value = deepcopy(config())
    value["scenarios"] = [value["scenarios"][0]]
    result = run_integrated_stress(base, funding(), haircut(), treasury(), settlement_fail(), value)
    assert result.member_results["lcr_status"].eq("NO_REQUIREMENT").all()
    assert all(math.isinf(value) for value in result.member_results["liquidity_coverage_ratio"])
    assert result.passed


def test_breach_status_and_summary() -> None:
    base = baseline()
    base["modeled_aqlr_usd"] = [50.0, 60.0]
    result = run_integrated_stress(
        base, funding(), haircut(), treasury(), settlement_fail(), config()
    )
    severe = result.member_results.query("scenario_name == 'severe'")
    assert severe["lcr_status"].eq("BREACH").all()
    summary = build_scenario_summary(result.member_results)
    assert summary.query("scenario_name == 'severe'")["breach_member_count"].iloc[0] == 2
    controls = build_double_count_controls(result.member_results)
    assert len(controls) == len(result.member_results)


def test_validate_results_detects_tampering() -> None:
    result = run_result()
    settings = load_settings(config())
    tampered = result.member_results.copy()
    current_requirement = float(cast(Any, tampered.loc[0, "stressed_liquidity_requirement_usd"]))
    tampered.loc[0, "stressed_liquidity_requirement_usd"] = current_requirement + 10.0
    checks = validate_results(
        tampered,
        result.scenario_summary,
        result.double_count_controls,
        baseline_member_count=2,
        settings=settings,
    )
    assert not checks["stressed_requirement_identity"]


def test_dataframe_digest_is_row_order_independent() -> None:
    result = run_result()
    shuffled = result.member_results.sample(frac=1.0, random_state=2026)
    assert dataframe_digest(result.member_results) == dataframe_digest(shuffled)


def test_read_table_csv_parquet_and_errors(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    frame = baseline()
    csv_path = tmp_path / "input.csv"
    frame.to_csv(csv_path, index=False)
    assert len(read_table(csv_path)) == 2
    parquet_path = tmp_path / "input.parquet"
    parquet_path.write_bytes(b"controlled-test-placeholder")
    monkeypatch.setattr(pd, "read_parquet", lambda _: frame.copy())
    assert len(read_table(parquet_path)) == 2
    unsupported = tmp_path / "input.txt"
    unsupported.write_text("x", encoding="utf-8")
    with pytest.raises(IntegratedStressError, match="CSV or Parquet"):
        read_table(unsupported)
    with pytest.raises(IntegratedStressError, match="does not exist"):
        read_table(tmp_path / "missing.csv")


def test_empty_inputs_fail_closed() -> None:
    settings = load_settings(config())
    with pytest.raises(IntegratedStressError, match="empty"):
        prepare_baseline_summary(pd.DataFrame(), settings)
    with pytest.raises(IntegratedStressError, match="empty"):
        prepare_funding_summary(pd.DataFrame(), settings)
    with pytest.raises(IntegratedStressError, match="empty"):
        prepare_haircut_summary(pd.DataFrame(), settings)
    with pytest.raises(IntegratedStressError, match="empty"):
        prepare_treasury_summary(pd.DataFrame(), settings)
    with pytest.raises(IntegratedStressError, match="empty"):
        prepare_settlement_fail_summary(pd.DataFrame(), settings)
