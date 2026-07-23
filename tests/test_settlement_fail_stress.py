"""Tests for Phase V, Section 18 settlement-fail stress."""

from __future__ import annotations

from copy import deepcopy
from pathlib import Path
from typing import Any

import pandas as pd
import pytest

from ficc_liquidity.stress.settlement_fail_stress import (
    SettlementFailStressError,
    dataframe_digest,
    load_config,
    load_settings,
    prepare_baseline,
    prepare_funding,
    prepare_members,
    read_table,
    run_model,
)


@pytest.fixture
def config() -> dict[str, Any]:
    return {
        "model_version": "test-v1",
        "source": {"synthetic_id_pattern": r"^SYN-MBR-[0-9]{4}$"},
        "assumptions": {
            "liquidity_horizon_hours": 48,
            "fails_to_receive_share": 0.5,
            "fails_to_deliver_share": 0.5,
            "incoming_settlement_receipt_ratio": 0.8,
            "persistence_liquidity_rate": 0.2,
            "fail_penalty_rate_per_day": 0.001,
        },
        "scenarios": [
            {
                "name": "control",
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
            },
            {
                "name": "stress",
                "severity_rank": 1,
                "fails_to_receive_multiplier": 2.0,
                "fails_to_deliver_multiplier": 1.5,
                "additional_fails_to_receive_rate": 0.05,
                "additional_fails_to_deliver_rate": 0.03,
                "incoming_payment_delay_buckets": 1,
                "replacement_liquidity_rate": 1.1,
                "persistence_days": 3,
                "persistence_decay": 0.8,
                "funding_scenario_name": "severe_market_stress",
                "funding_stress_weight": 0.75,
            },
        ],
        "validation": {"reconciliation_tolerance_usd": 0.01},
    }


@pytest.fixture
def members() -> pd.DataFrame:
    return pd.DataFrame(
        {
            "member_id": ["SYN-MBR-0001", "SYN-MBR-0002"],
            "settlement_obligation_usd": [1000.0, 2000.0],
            "settlement_fail_usd": [20.0, 80.0],
            "settlement_fail_rate": [0.02, 0.04],
            "value_class": ["synthetic", "synthetic"],
            "actual_ficc_participant": [False, False],
            "participant_level_inference": [False, False],
        }
    )


@pytest.fixture
def baseline() -> pd.DataFrame:
    rows: list[dict[str, object]] = []
    for member_id, scale in (("SYN-MBR-0001", 1.0), ("SYN-MBR-0002", 2.0)):
        for order, bucket in enumerate(("open", "mid", "close"), start=1):
            rows.append(
                {
                    "member_id": member_id,
                    "bucket_order": order,
                    "time_bucket": bucket,
                    "elapsed_hours": (order - 1) * 24,
                    "liquidity_horizon_hours": 48,
                    "gross_settlement_obligation_usd": 100.0 * scale,
                    "total_cash_outflow_usd": 60.0 * scale,
                    "total_cash_inflow_usd": 10.0 * scale,
                    "cumulative_available_resources_usd": 500.0 * scale,
                    "value_class": "synthetic",
                    "actual_ficc_participant": False,
                    "participant_level_inference": False,
                }
            )
    return pd.DataFrame.from_records(rows)


@pytest.fixture
def funding() -> pd.DataFrame:
    rows: list[dict[str, object]] = []
    for scenario, amount in (("control", 0.0), ("severe_market_stress", 25.0)):
        for member_id in ("SYN-MBR-0001", "SYN-MBR-0002"):
            for order, bucket in enumerate(("open", "mid", "close"), start=1):
                rows.append(
                    {
                        "scenario_name": scenario,
                        "member_id": member_id,
                        "bucket_order": order,
                        "time_bucket": bucket,
                        "incremental_repo_funding_stress_outflow_usd": amount,
                        "value_class": "synthetic",
                        "actual_ficc_participant": False,
                        "participant_level_inference": False,
                    }
                )
    return pd.DataFrame.from_records(rows)


def test_load_settings(config: dict[str, Any]) -> None:
    settings = load_settings(config)
    assert settings.model_version == "test-v1"
    assert len(settings.scenarios) == 2


def test_model_passes(
    config: dict[str, Any],
    baseline: pd.DataFrame,
    members: pd.DataFrame,
    funding: pd.DataFrame,
) -> None:
    result = run_model(baseline, members, funding, config)
    assert result.passed
    assert len(result.scenario_summary) == 2


def test_zero_control(
    config: dict[str, Any],
    baseline: pd.DataFrame,
    members: pd.DataFrame,
    funding: pd.DataFrame,
) -> None:
    result = run_model(baseline, members, funding, config)
    control = result.cashflows.loc[result.cashflows["scenario_name"].eq("control")]
    assert control["incremental_combined_stress_outflow_usd"].eq(0.0).all()


def test_stress_has_all_channels(
    config: dict[str, Any],
    baseline: pd.DataFrame,
    members: pd.DataFrame,
    funding: pd.DataFrame,
) -> None:
    result = run_model(baseline, members, funding, config)
    stress = result.cashflows.loc[result.cashflows["scenario_name"].eq("stress")]
    for column in (
        "fails_to_receive_usd",
        "fails_to_deliver_usd",
        "delayed_incoming_payment_outflow_usd",
        "required_replacement_liquidity_usd",
        "persistent_multi_day_fail_liquidity_usd",
        "combined_funding_shock_outflow_usd",
    ):
        assert stress[column].gt(0.0).any()


def test_delayed_recovery_is_shifted(
    config: dict[str, Any],
    baseline: pd.DataFrame,
    members: pd.DataFrame,
    funding: pd.DataFrame,
) -> None:
    result = run_model(baseline, members, funding, config)
    stress = result.cashflows.loc[
        result.cashflows["scenario_name"].eq("stress")
        & result.cashflows["member_id"].eq("SYN-MBR-0001")
    ].sort_values("bucket_order")
    assert stress["delayed_incoming_payment_recovery_usd"].iloc[0] == 0.0
    assert stress["delayed_incoming_payment_recovery_usd"].iloc[1] > 0.0


def test_replacement_identity(
    config: dict[str, Any],
    baseline: pd.DataFrame,
    members: pd.DataFrame,
    funding: pd.DataFrame,
) -> None:
    result = run_model(baseline, members, funding, config)
    stress = result.cashflows.loc[result.cashflows["scenario_name"].eq("stress")]
    expected = stress["fails_to_deliver_usd"] * 1.1
    pd.testing.assert_series_equal(
        stress["required_replacement_liquidity_usd"].reset_index(drop=True),
        expected.reset_index(drop=True),
        check_names=False,
    )


def test_deterministic_row_order_independent(
    config: dict[str, Any],
    baseline: pd.DataFrame,
    members: pd.DataFrame,
    funding: pd.DataFrame,
) -> None:
    first = run_model(baseline, members, funding, config)
    second = run_model(
        baseline.sample(frac=1.0, random_state=1),
        members.sample(frac=1.0, random_state=2),
        funding.sample(frac=1.0, random_state=3),
        config,
    )
    assert dataframe_digest(first.cashflows) == dataframe_digest(second.cashflows)


def test_invalid_identity_rejected(config: dict[str, Any], members: pd.DataFrame) -> None:
    invalid = members.copy()
    invalid.loc[0, "member_id"] = "ACTUAL-MEMBER"
    with pytest.raises(SettlementFailStressError, match="Non-synthetic"):
        prepare_members(invalid, load_settings(config))


def test_actual_participant_rejected(config: dict[str, Any], members: pd.DataFrame) -> None:
    invalid = members.copy()
    invalid.loc[0, "actual_ficc_participant"] = True
    with pytest.raises(SettlementFailStressError, match="Actual FICC"):
        prepare_members(invalid, load_settings(config))


def test_fail_above_obligation_rejected(config: dict[str, Any], members: pd.DataFrame) -> None:
    invalid = members.copy()
    invalid.loc[0, "settlement_fail_usd"] = 2000.0
    with pytest.raises(SettlementFailStressError, match="cannot exceed"):
        prepare_members(invalid, load_settings(config))


def test_inconsistent_fail_rate_rejected(config: dict[str, Any], members: pd.DataFrame) -> None:
    invalid = members.copy()
    invalid.loc[0, "settlement_fail_rate"] = 0.90
    with pytest.raises(SettlementFailStressError, match="inconsistent"):
        prepare_members(invalid, load_settings(config))


def test_missing_member_field_rejected(config: dict[str, Any], members: pd.DataFrame) -> None:
    with pytest.raises(SettlementFailStressError, match="fields are missing"):
        prepare_members(members.drop(columns="settlement_fail_usd"), load_settings(config))


def test_duplicate_baseline_key_rejected(config: dict[str, Any], baseline: pd.DataFrame) -> None:
    invalid = pd.concat([baseline, baseline.iloc[[0]]], ignore_index=True)
    with pytest.raises(SettlementFailStressError, match="must be unique"):
        prepare_baseline(invalid, load_settings(config))


def test_bad_horizon_rejected(config: dict[str, Any], baseline: pd.DataFrame) -> None:
    invalid = baseline.copy()
    invalid["liquidity_horizon_hours"] = 24
    with pytest.raises(SettlementFailStressError, match="horizon"):
        prepare_baseline(invalid, load_settings(config))


def test_duplicate_funding_key_rejected(config: dict[str, Any], funding: pd.DataFrame) -> None:
    invalid = pd.concat([funding, funding.iloc[[0]]], ignore_index=True)
    with pytest.raises(SettlementFailStressError, match="keys must be unique"):
        prepare_funding(invalid, load_settings(config))


def test_missing_funding_scenario_rejected(
    config: dict[str, Any],
    baseline: pd.DataFrame,
    members: pd.DataFrame,
    funding: pd.DataFrame,
) -> None:
    invalid = funding.loc[~funding["scenario_name"].eq("severe_market_stress")]
    with pytest.raises(SettlementFailStressError, match="was not found"):
        run_model(baseline, members, invalid, config)


def test_invalid_share_sum_rejected(config: dict[str, Any]) -> None:
    invalid = deepcopy(config)
    invalid["assumptions"]["fails_to_receive_share"] = 0.8
    with pytest.raises(SettlementFailStressError, match="sum to one"):
        load_settings(invalid)


def test_nonmonotonic_scenarios_rejected(config: dict[str, Any]) -> None:
    invalid = deepcopy(config)
    invalid["scenarios"][1]["persistence_days"] = 0
    with pytest.raises(SettlementFailStressError, match="must be positive"):
        load_settings(invalid)


@pytest.mark.parametrize(
    ("key", "value", "match"),
    [
        ("name", "", "nonempty name"),
        ("severity_rank", -1, "nonnegative"),
        ("fails_to_receive_multiplier", -1.0, "nonnegative"),
        ("fails_to_deliver_multiplier", -1.0, "nonnegative"),
        ("additional_fails_to_receive_rate", 1.1, "between zero and one"),
        ("incoming_payment_delay_buckets", -1, "nonnegative"),
        ("replacement_liquidity_rate", -0.1, "nonnegative"),
    ],
)
def test_invalid_scenario_controls_rejected(
    config: dict[str, Any], key: str, value: object, match: str
) -> None:
    invalid = deepcopy(config)
    invalid["scenarios"][1][key] = value
    with pytest.raises(SettlementFailStressError, match=match):
        load_settings(invalid)


def test_funding_name_required(config: dict[str, Any]) -> None:
    invalid = deepcopy(config)
    invalid["scenarios"][1]["funding_scenario_name"] = ""
    with pytest.raises(SettlementFailStressError, match="funding scenario name"):
        load_settings(invalid)


def test_empty_scenario_list_rejected(config: dict[str, Any]) -> None:
    invalid = deepcopy(config)
    invalid["scenarios"] = []
    with pytest.raises(SettlementFailStressError, match="nonempty list"):
        load_settings(invalid)


def test_duplicate_scenario_name_rejected(config: dict[str, Any]) -> None:
    invalid = deepcopy(config)
    invalid["scenarios"][1]["name"] = "control"
    with pytest.raises(SettlementFailStressError, match="names must be unique"):
        load_settings(invalid)


def test_empty_inputs_rejected(
    config: dict[str, Any],
) -> None:
    settings = load_settings(config)
    with pytest.raises(SettlementFailStressError, match="member input is empty"):
        prepare_members(pd.DataFrame(), settings)
    with pytest.raises(SettlementFailStressError, match="Baseline liquidity input is empty"):
        prepare_baseline(pd.DataFrame(), settings)
    with pytest.raises(SettlementFailStressError, match="funding-stress input is empty"):
        prepare_funding(pd.DataFrame(), settings)


def test_missing_baseline_and_funding_fields_rejected(
    config: dict[str, Any], baseline: pd.DataFrame, funding: pd.DataFrame
) -> None:
    settings = load_settings(config)
    with pytest.raises(SettlementFailStressError, match="baseline fields are missing"):
        prepare_baseline(baseline.drop(columns="elapsed_hours"), settings)
    with pytest.raises(SettlementFailStressError, match="funding fields are missing"):
        prepare_funding(funding.drop(columns="scenario_name"), settings)


def test_duplicate_member_rejected(config: dict[str, Any], members: pd.DataFrame) -> None:
    invalid = pd.concat([members, members.iloc[[0]]], ignore_index=True)
    with pytest.raises(SettlementFailStressError, match="must be unique"):
        prepare_members(invalid, load_settings(config))


def test_config_missing_rejected(tmp_path: Path) -> None:
    with pytest.raises(SettlementFailStressError, match="does not exist"):
        load_config(tmp_path / "missing.yaml")


def test_config_round_trip(tmp_path: Path, config: dict[str, Any]) -> None:
    import yaml

    path = tmp_path / "config.yaml"
    path.write_text(yaml.safe_dump(config), encoding="utf-8")
    loaded = load_config(path)
    assert loaded["model_version"] == "test-v1"


def test_read_table_csv(tmp_path: Path, members: pd.DataFrame) -> None:
    path = tmp_path / "members.csv"
    members.to_csv(path, index=False)
    loaded = read_table(path)
    assert len(loaded) == len(members)


def test_read_table_missing_rejected(tmp_path: Path) -> None:
    with pytest.raises(SettlementFailStressError, match="does not exist"):
        read_table(tmp_path / "missing.csv")


def test_read_table_extension_rejected(tmp_path: Path) -> None:
    path = tmp_path / "data.txt"
    path.write_text("x", encoding="utf-8")
    with pytest.raises(SettlementFailStressError, match="CSV or Parquet"):
        read_table(path)
