from __future__ import annotations

import math
from copy import deepcopy
from pathlib import Path
from typing import Any, cast

import pandas as pd
import pytest
import yaml

from ficc_liquidity.stress import repo_funding_stress as model


def _config() -> dict[str, Any]:
    return cast(
        dict[str, Any],
        yaml.safe_load(
            (Path(__file__).parents[1] / "configs" / "repo_funding_stress.yaml").read_text(
                encoding="utf-8"
            )
        ),
    )


def _members() -> pd.DataFrame:
    return pd.DataFrame(
        {
            "member_id": ["SYN-MBR-0001", "SYN-MBR-0002"],
            "value_class": ["synthetic", "synthetic"],
            "actual_ficc_participant": [False, False],
            "participant_level_inference": [False, False],
            "member_concentration_ratio": [0.20, 0.55],
            "funding_dependency_ratio": [0.40, 0.85],
            "net_repo_dependency_ratio": [0.50, 0.90],
        }
    )


def _baseline() -> pd.DataFrame:
    rows: list[dict[str, object]] = []
    for member_id, scale in (("SYN-MBR-0001", 1.0), ("SYN-MBR-0002", 1.4)):
        for bucket_order, (bucket, elapsed, repo, roll, financing, need, resources) in enumerate(
            (
                ("day1_open", 0, 100.0, 80.0, 20.0, 150.0, 120.0),
                ("day1_close", 12, 150.0, 120.0, 30.0, 240.0, 220.0),
                ("day2_close", 48, 250.0, 200.0, 50.0, 300.0, 350.0),
            ),
            start=1,
        ):
            baseline_need = need * scale
            available = resources * scale
            headroom = available - baseline_need
            rows.append(
                {
                    "member_id": member_id,
                    "bucket_order": bucket_order,
                    "time_bucket": bucket,
                    "elapsed_hours": elapsed,
                    "liquidity_horizon_hours": 48,
                    "repo_maturity_usd": repo * scale,
                    "repo_roll_amount_usd": roll * scale,
                    "financing_outflow_usd": financing * scale,
                    "total_cash_outflow_usd": (financing + 50.0) * scale,
                    "cumulative_net_liquidity_need_usd": baseline_need,
                    "cumulative_available_resources_usd": available,
                    "liquidity_headroom_usd": headroom,
                    "liquidity_shortfall_usd": max(-headroom, 0.0),
                    "value_class": "synthetic",
                    "actual_ficc_participant": False,
                    "participant_level_inference": False,
                }
            )
    return pd.DataFrame.from_records(rows)


def test_model_runs_all_scenarios_and_passes_validation() -> None:
    detailed, members, scenarios, validation = model.run_model(
        _baseline(),
        _members(),
        _config(),
    )

    assert validation.passed
    assert len(detailed) == len(_baseline()) * 4
    assert len(members) == 8
    assert len(scenarios) == 4
    assert scenarios["scenario_name"].tolist() == [
        "control",
        "moderate_market_stress",
        "severe_market_stress",
        "concentrated_funding_freeze",
    ]


def test_control_scenario_preserves_baseline_liquidity_need() -> None:
    detailed, _, _, _ = model.run_model(_baseline(), _members(), _config())
    control = detailed.loc[detailed["scenario_name"] == "control"]

    assert control["incremental_repo_funding_stress_outflow_usd"].eq(0.0).all()
    assert control["stressed_cumulative_net_liquidity_need_usd"].tolist() == pytest.approx(
        control["cumulative_net_liquidity_need_usd"].tolist()
    )


def test_rate_spike_and_funding_spread_are_translated_to_costs() -> None:
    detailed, _, _, _ = model.run_model(_baseline(), _members(), _config())
    severe = detailed.loc[detailed["scenario_name"] == "severe_market_stress"]

    assert severe["stressed_sofr_percent"].eq(7.0).all()
    assert severe["stressed_all_in_rate_percent"].eq(8.5).all()
    assert (severe["incremental_funding_cost_usd"] > 0.0).all()


def test_rollover_failure_withdrawal_and_shorter_horizon_raise_unavailability() -> None:
    _, member_summary, _, _ = model.run_model(_baseline(), _members(), _config())
    pivot = member_summary.pivot(
        index="member_id",
        columns="scenario_name",
        values="effective_funding_unavailability_rate",
    )

    assert (pivot["moderate_market_stress"] < pivot["severe_market_stress"]).all()
    assert (pivot["severe_market_stress"] < pivot["concentrated_funding_freeze"]).all()


def test_concentrated_dependent_member_has_larger_stress_rate() -> None:
    _, member_summary, _, _ = model.run_model(_baseline(), _members(), _config())
    moderate = member_summary.loc[
        member_summary["scenario_name"] == "moderate_market_stress"
    ].set_index("member_id")

    member_2_rate = cast(
        float,
        moderate.at[
            "SYN-MBR-0002",
            "effective_funding_unavailability_rate",
        ],
    )
    member_1_rate = cast(
        float,
        moderate.at[
            "SYN-MBR-0001",
            "effective_funding_unavailability_rate",
        ],
    )

    assert member_2_rate > member_1_rate


def test_collateral_demands_are_added_to_funding_stress() -> None:
    detailed, _, _, _ = model.run_model(_baseline(), _members(), _config())
    stressed = detailed.loc[detailed["scenario_name"] != "control"]

    assert (stressed["additional_collateral_demand_usd"] > 0.0).all()
    assert stressed["incremental_repo_funding_stress_outflow_usd"].tolist() == pytest.approx(
        (
            stressed["repo_rollover_failure_outflow_usd"]
            + stressed["incremental_funding_cost_usd"]
            + stressed["additional_collateral_demand_usd"]
        ).tolist()
    )


def test_model_is_deterministic_for_input_row_order() -> None:
    first = model.run_model(_baseline(), _members(), _config())
    second = model.run_model(
        _baseline().iloc[::-1].reset_index(drop=True),
        _members().iloc[::-1].reset_index(drop=True),
        _config(),
    )

    assert first[0].equals(second[0])
    assert first[1].equals(second[1])
    assert first[2].equals(second[2])
    assert first[3].passed and second[3].passed


@pytest.mark.parametrize(
    ("field", "value", "message"),
    [
        ("repo_rollover_failure_rate", 1.1, "between zero and one"),
        ("lender_withdrawal_rate", -0.1, "between zero and one"),
        ("refinancing_horizon_hours", 72, "cannot exceed"),
        ("funding_spread_increase_bp", -1.0, "nonnegative"),
        ("severity_rank", -1, "nonnegative"),
    ],
)
def test_invalid_scenario_assumptions_are_rejected(
    field: str,
    value: object,
    message: str,
) -> None:
    config = deepcopy(_config())
    config["scenarios"][1][field] = value

    with pytest.raises(model.RepoFundingStressError, match=message):
        model.load_settings(config)


def test_duplicate_scenario_names_and_ranks_are_rejected() -> None:
    duplicate_name = deepcopy(_config())
    duplicate_name["scenarios"][1]["name"] = "control"
    with pytest.raises(model.RepoFundingStressError, match="names must be unique"):
        model.load_settings(duplicate_name)

    duplicate_rank = deepcopy(_config())
    duplicate_rank["scenarios"][1]["severity_rank"] = 0
    with pytest.raises(model.RepoFundingStressError, match="ranks must be unique"):
        model.load_settings(duplicate_rank)


@pytest.mark.parametrize(
    ("target", "column", "value", "message"),
    [
        ("baseline", "member_id", "REAL-MEMBER", "Non-synthetic"),
        ("members", "actual_ficc_participant", True, "Actual FICC"),
        ("members", "funding_dependency_ratio", 1.1, "between zero and one"),
        ("baseline", "repo_roll_amount_usd", -1.0, "negative"),
    ],
)
def test_invalid_inputs_are_rejected(
    target: str,
    column: str,
    value: object,
    message: str,
) -> None:
    baseline = _baseline()
    members = _members()
    if target == "baseline":
        baseline.loc[0, column] = cast(Any, value)
    else:
        members.loc[0, column] = cast(Any, value)

    with pytest.raises(model.RepoFundingStressError, match=message):
        model.run_model(baseline, members, _config())


def test_missing_member_profile_is_rejected() -> None:
    members = _members().iloc[:1].copy()
    with pytest.raises(model.RepoFundingStressError, match="missing from member profiles"):
        model.run_model(_baseline(), members, _config())


def test_member_ratios_can_be_derived_from_synthetic_source_fields() -> None:
    members = pd.DataFrame(
        {
            "member_id": ["SYN-MBR-0001", "SYN-MBR-0002"],
            "value_class": ["synthetic", "synthetic"],
            "actual_ficc_participant": [False, False],
            "treasury_position_bills_0_1y_usd": [60.0, 40.0],
            "treasury_position_notes_1_3y_usd": [40.0, 60.0],
            "total_treasury_position_usd": [100.0, 100.0],
            "repo_financing_need_usd": [50.0, 80.0],
            "reverse_repo_position_usd": [10.0, 20.0],
            "treasury_transaction_activity_usd": [100.0, 100.0],
        }
    )
    settings = model.load_settings(_config())
    prepared = model.prepare_members(members, settings)

    assert prepared["member_concentration_ratio"].tolist() == pytest.approx([0.6, 0.6])
    assert prepared["funding_dependency_ratio"].tolist() == pytest.approx([0.5, 0.8])
    assert prepared["net_repo_dependency_ratio"].tolist() == pytest.approx([0.8, 0.75])


def test_read_table_supports_csv_and_rejects_other_formats(tmp_path: Path) -> None:
    csv_path = tmp_path / "input.csv"
    _members().to_csv(csv_path, index=False)
    assert len(model.read_table(csv_path)) == 2

    invalid_path = tmp_path / "input.txt"
    invalid_path.write_text("x", encoding="utf-8")
    with pytest.raises(model.RepoFundingStressError, match="CSV or Parquet"):
        model.read_table(invalid_path)


def test_configuration_loader_rejects_missing_and_nonmapping_files(tmp_path: Path) -> None:
    missing = tmp_path / "missing.yaml"
    with pytest.raises(model.RepoFundingStressError, match="does not exist"):
        model.load_config(missing)

    invalid = tmp_path / "invalid.yaml"
    invalid.write_text("- not\n- a\n- mapping\n", encoding="utf-8")
    with pytest.raises(model.RepoFundingStressError, match="must be a YAML mapping"):
        model.load_config(invalid)


@pytest.mark.parametrize(
    ("mutation", "message"),
    [
        (lambda config: config.update({"scenarios": []}), "nonempty list"),
        (
            lambda config: config["assumptions"].update({"baseline_liquidity_horizon_hours": 0}),
            "must be positive",
        ),
        (
            lambda config: [
                scenario.update({"enabled": False}) for scenario in config["scenarios"]
            ],
            "enabled scenario",
        ),
        (
            lambda config: config.update({"model_version": ""}),
            "model_version",
        ),
        (
            lambda config: config["assumptions"].update({"reference_sofr_percent": -0.1}),
            "reference_sofr_percent",
        ),
        (
            lambda config: config["assumptions"].update({"day_count_basis": 0}),
            "day_count_basis",
        ),
        (
            lambda config: config["validation"].update({"reconciliation_tolerance_usd": -0.1}),
            "reconciliation_tolerance",
        ),
        (
            lambda config: config["scenarios"][1].update({"name": ""}),
            "nonempty name",
        ),
        (
            lambda config: config["scenarios"][1].update({"sofr_spike_bp": -1.0}),
            "sofr_spike_bp",
        ),
        (
            lambda config: config["scenarios"][1].update({"refinancing_horizon_hours": 0}),
            "must be positive",
        ),
        (
            lambda config: config["scenarios"][1].update({"concentration_multiplier": -1.0}),
            "concentration_multiplier",
        ),
        (
            lambda config: config["scenarios"][1].update({"funding_dependency_multiplier": -1.0}),
            "funding_dependency_multiplier",
        ),
        (
            lambda config: config["scenarios"][1].update({"funding_spread_increase_bp": math.nan}),
            "must be finite",
        ),
        (
            lambda config: config["scenarios"][1].update({"severity_rank": 1.5}),
            "must be an integer",
        ),
    ],
)
def test_additional_invalid_configurations_are_rejected(
    mutation: Any,
    message: str,
) -> None:
    config = deepcopy(_config())
    mutation(config)
    with pytest.raises(model.RepoFundingStressError, match=message):
        model.load_settings(config)


def test_disabled_scenario_is_excluded() -> None:
    config = deepcopy(_config())
    config["scenarios"][3]["enabled"] = False
    settings = model.load_settings(config)
    assert [scenario.name for scenario in settings.scenarios] == [
        "control",
        "moderate_market_stress",
        "severe_market_stress",
    ]


@pytest.mark.parametrize(
    ("mutation", "message"),
    [
        (lambda frame: frame.drop(frame.index), "input is empty"),
        (
            lambda frame: frame.drop(columns="repo_maturity_usd"),
            "Required baseline",
        ),
        (
            lambda frame: pd.concat([frame, frame.iloc[[0]]], ignore_index=True),
            "must be unique",
        ),
        (
            lambda frame: frame.assign(repo_maturity_usd=float("nan")),
            "missing or nonfinite",
        ),
        (
            lambda frame: frame.assign(liquidity_horizon_hours=24),
            "do not match",
        ),
        (
            lambda frame: frame.assign(participant_level_inference=True),
            "Participant-level inference",
        ),
        (
            lambda frame: frame.assign(value_class="observed"),
            "value_class",
        ),
    ],
)
def test_additional_invalid_baselines_are_rejected(
    mutation: Any,
    message: str,
) -> None:
    settings = model.load_settings(_config())
    with pytest.raises(model.RepoFundingStressError, match=message):
        model.prepare_baseline(mutation(_baseline()), settings)


@pytest.mark.parametrize(
    ("mutation", "message"),
    [
        (lambda frame: frame.drop(frame.index), "input is empty"),
        (lambda frame: frame.drop(columns="member_id"), "require member_id"),
        (
            lambda frame: pd.concat([frame, frame.iloc[[0]]], ignore_index=True),
            "must be unique",
        ),
        (
            lambda frame: frame.assign(member_concentration_ratio=float("nan")),
            "missing or nonfinite",
        ),
        (
            lambda frame: frame.assign(participant_level_inference=True),
            "Participant-level inference",
        ),
        (
            lambda frame: frame.assign(value_class="assumed"),
            "value_class",
        ),
    ],
)
def test_additional_invalid_member_profiles_are_rejected(
    mutation: Any,
    message: str,
) -> None:
    settings = model.load_settings(_config())
    with pytest.raises(model.RepoFundingStressError, match=message):
        model.prepare_members(mutation(_members()), settings)


def test_ratio_derivation_requires_source_fields() -> None:
    settings = model.load_settings(_config())

    no_treasury = _members().drop(columns="member_concentration_ratio")
    with pytest.raises(model.RepoFundingStressError, match="cannot be derived"):
        model.prepare_members(no_treasury, settings)

    incomplete = _members().drop(columns="funding_dependency_ratio")
    with pytest.raises(model.RepoFundingStressError, match="cannot be derived"):
        model.prepare_members(incomplete, settings)

    incomplete_net = _members().drop(columns="net_repo_dependency_ratio")
    with pytest.raises(model.RepoFundingStressError, match="cannot be derived"):
        model.prepare_members(incomplete_net, settings)


def test_read_table_rejects_missing_path(tmp_path: Path) -> None:
    with pytest.raises(model.RepoFundingStressError, match="does not exist"):
        model.read_table(tmp_path / "missing.csv")
