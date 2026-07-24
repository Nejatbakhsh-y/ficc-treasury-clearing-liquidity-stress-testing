"""Tests for Phase VI, Section 23 reverse stress testing."""

from __future__ import annotations

import math
from collections.abc import Callable

import pandas as pd
import pytest

from ficc_liquidity.scenarios.reverse_stress import (
    EvaluationSnapshot,
    ReverseStressError,
    build_member_combinations,
    build_member_results,
    dataframe_digest,
    make_snapshot,
    prepare_control,
    run_reverse_stress,
    search_threshold,
)


def integrated_control() -> pd.DataFrame:
    """Return controlled synthetic Section 19 results."""
    return pd.DataFrame(
        {
            "scenario_name": ["control", "control", "control"],
            "member_id": ["SYN-MBR-0001", "SYN-MBR-0002", "SYN-MBR-0003"],
            "stressed_liquidity_requirement_usd": [40.0, 40.0, 60.0],
            "available_qualified_liquid_resources_usd": [100.0, 80.0, 120.0],
            "value_class": ["synthetic", "synthetic", "synthetic"],
            "actual_ficc_participant": [False, False, False],
            "participant_level_inference": [False, False, False],
        }
    )


def reverse_config() -> dict[str, object]:
    """Return a compact controlled Section 23 configuration."""
    return {
        "search": {
            "yield_shock": {
                "lower_bound": 0.0,
                "upper_bound": 100.0,
                "parameter_tolerance": 0.001,
            },
            "rollover_failure": {
                "lower_bound": 0.0,
                "upper_bound": 1.0,
                "parameter_tolerance": 0.00001,
            },
            "haircut_increase": {
                "lower_bound": 0.0,
                "upper_bound": 0.5,
                "parameter_tolerance": 0.00001,
            },
            "combined_scenario": {
                "lower_bound": 0.0,
                "upper_bound": 1.0,
                "parameter_tolerance": 0.00001,
                "maximum_yield_shock_bp": 50.0,
                "maximum_rollover_failure_rate": 0.5,
                "maximum_haircut_increase_rate": 0.2,
            },
        },
        "member_combinations": {
            "combination_size": 2,
            "top_n": 3,
        },
        "validation": {
            "lcr_minimum_ratio": 1.0,
            "liquidity_tolerance_usd": 0.000001,
            "maximum_binary_search_iterations": 80,
        },
    }


def control_frame() -> pd.DataFrame:
    """Prepare the synthetic control frame."""
    return prepare_control(
        integrated_control(),
        control_scenario_name="control",
        synthetic_id_pattern=r"^SYN-MBR-[0-9]{4}$",
        lcr_minimum_ratio=1.0,
        tolerance_usd=0.01,
    )


def component(values: list[float]) -> pd.Series:
    """Return one member-indexed component vector."""
    return pd.Series(
        values,
        index=["SYN-MBR-0001", "SYN-MBR-0002", "SYN-MBR-0003"],
        dtype=float,
    )


def test_prepare_control_and_digest_are_deterministic() -> None:
    prepared = control_frame()
    assert prepared["member_id"].tolist() == [
        "SYN-MBR-0001",
        "SYN-MBR-0002",
        "SYN-MBR-0003",
    ]
    shuffled = prepared.sample(frac=1.0, random_state=7).reset_index(drop=True)
    assert dataframe_digest(prepared) == dataframe_digest(shuffled)


@pytest.mark.parametrize(
    ("mutator", "message"),
    [
        (
            lambda frame: frame.assign(member_id=["ACTUAL-1", "SYN-MBR-0002", "SYN-MBR-0003"]),
            "invalid synthetic identifiers",
        ),
        (
            lambda frame: pd.concat([frame, frame.iloc[[0]]], ignore_index=True),
            "one row per member",
        ),
        (
            lambda frame: frame.assign(actual_ficc_participant=[True, False, False]),
            "Actual FICC participant",
        ),
        (
            lambda frame: frame.assign(value_class=["observed", "synthetic", "synthetic"]),
            "value_class",
        ),
    ],
)
def test_prepare_control_rejects_invalid_inputs(
    mutator: Callable[[pd.DataFrame], pd.DataFrame], message: str
) -> None:
    mutate = mutator
    assert callable(mutate)
    with pytest.raises(ReverseStressError, match=message):
        prepare_control(
            mutate(integrated_control()),
            control_scenario_name="control",
            synthetic_id_pattern=r"^SYN-MBR-[0-9]{4}$",
            lcr_minimum_ratio=1.0,
            tolerance_usd=0.01,
        )


def test_member_results_and_combinations_reconcile() -> None:
    members = build_member_results(
        control_frame(),
        yield_losses=component([10.0, 20.0, 5.0]),
        rollover_needs=component([5.0, 10.0, 5.0]),
        haircut_requirements=component([0.0, 15.0, 0.0]),
        lcr_minimum_ratio=1.0,
        tolerance_usd=0.01,
    )
    second = members.loc[members["member_id"].eq("SYN-MBR-0002")].iloc[0]
    assert second["stressed_liquidity_requirement_usd"] == pytest.approx(85.0)
    assert second["liquidity_shortfall_usd"] == pytest.approx(5.0)
    assert second["lcr_status"] == "BREACH"

    pairs = build_member_combinations(members, combination_size=2)
    assert len(pairs) == 3
    pair = pairs.loc[pairs["combination_id"].eq("SYN-MBR-0001|SYN-MBR-0002")].iloc[0]
    assert pair["stressed_liquidity_requirement_usd"] == pytest.approx(140.0)
    assert pair["available_resources_usd"] == pytest.approx(180.0)


def test_component_alignment_controls() -> None:
    control = control_frame()
    duplicate = pd.Series(
        [1.0, 2.0],
        index=["SYN-MBR-0001", "SYN-MBR-0001"],
    )
    with pytest.raises(ReverseStressError, match="duplicate"):
        build_member_results(
            control,
            yield_losses=duplicate,
            lcr_minimum_ratio=1.0,
            tolerance_usd=0.01,
        )

    missing = pd.Series([1.0], index=["SYN-MBR-0001"])
    with pytest.raises(ReverseStressError, match="missing members"):
        build_member_results(
            control,
            yield_losses=missing,
            lcr_minimum_ratio=1.0,
            tolerance_usd=0.01,
        )

    negative = component([1.0, -1.0, 1.0])
    with pytest.raises(ReverseStressError, match="nonnegative"):
        build_member_results(
            control,
            yield_losses=negative,
            lcr_minimum_ratio=1.0,
            tolerance_usd=0.01,
        )


def test_snapshot_supports_members_and_combinations() -> None:
    members = build_member_results(
        control_frame(),
        yield_losses=component([0.0, 50.0, 0.0]),
        lcr_minimum_ratio=1.0,
        tolerance_usd=0.01,
    )
    member_snapshot = make_snapshot(
        parameter_value=25.0,
        member_results=members,
        criterion_type="member",
        combination_size=2,
        lcr_minimum_ratio=1.0,
        tolerance_usd=0.01,
    )
    assert member_snapshot.breached
    assert member_snapshot.breached_entity_id == "SYN-MBR-0002"
    assert member_snapshot.combination_results.empty

    combination_snapshot = make_snapshot(
        parameter_value=25.0,
        member_results=members,
        criterion_type="combination",
        combination_size=2,
        lcr_minimum_ratio=1.0,
        tolerance_usd=0.01,
    )
    assert not combination_snapshot.combination_results.empty

    with pytest.raises(ReverseStressError, match="criterion_type"):
        make_snapshot(
            parameter_value=0.0,
            member_results=members,
            criterion_type="invalid",
            combination_size=2,
            lcr_minimum_ratio=1.0,
            tolerance_usd=0.01,
        )


def test_search_threshold_found_lower_bound_and_not_reached() -> None:
    control = control_frame()

    def evaluator(value: float) -> EvaluationSnapshot:
        members = build_member_results(
            control,
            yield_losses=component([value, 2.0 * value, 0.5 * value]),
            lcr_minimum_ratio=1.0,
            tolerance_usd=0.000001,
        )
        return make_snapshot(
            parameter_value=value,
            member_results=members,
            criterion_type="member",
            combination_size=2,
            lcr_minimum_ratio=1.0,
            tolerance_usd=0.000001,
        )

    found, snapshot, trace = search_threshold(
        test_name="yield",
        parameter_unit="bp",
        lower_bound=0.0,
        upper_bound=100.0,
        parameter_tolerance=0.001,
        maximum_iterations=80,
        evaluator=evaluator,
    )
    assert found.search_status == "FOUND"
    assert 20.0 <= found.minimum_threshold <= 20.002
    assert snapshot.breached
    assert found.minimality_check_pass
    assert len(trace) > 2

    lower_breach, _, _ = search_threshold(
        test_name="yield",
        parameter_unit="bp",
        lower_bound=30.0,
        upper_bound=100.0,
        parameter_tolerance=0.001,
        maximum_iterations=80,
        evaluator=evaluator,
    )
    assert lower_breach.search_status == "BREACH_AT_LOWER_BOUND"
    assert lower_breach.minimum_threshold == 30.0

    not_reached, _, _ = search_threshold(
        test_name="yield",
        parameter_unit="bp",
        lower_bound=0.0,
        upper_bound=1.0,
        parameter_tolerance=0.001,
        maximum_iterations=80,
        evaluator=evaluator,
    )
    assert not_reached.search_status == "NOT_REACHED"
    assert math.isnan(not_reached.minimum_threshold)


@pytest.mark.parametrize(
    ("lower", "upper", "tolerance", "iterations"),
    [
        (-1.0, 1.0, 0.1, 10),
        (1.0, 1.0, 0.1, 10),
        (0.0, 1.0, 0.0, 10),
        (0.0, 1.0, 0.1, 0),
    ],
)
def test_search_threshold_rejects_invalid_controls(
    lower: float,
    upper: float,
    tolerance: float,
    iterations: int,
) -> None:
    with pytest.raises(ReverseStressError):
        search_threshold(
            test_name="invalid",
            parameter_unit="unit",
            lower_bound=lower,
            upper_bound=upper,
            parameter_tolerance=tolerance,
            maximum_iterations=iterations,
            evaluator=lambda value: make_snapshot(
                parameter_value=value,
                member_results=build_member_results(
                    control_frame(),
                    lcr_minimum_ratio=1.0,
                    tolerance_usd=0.01,
                ),
                criterion_type="member",
                combination_size=2,
                lcr_minimum_ratio=1.0,
                tolerance_usd=0.01,
            ),
        )


def test_run_reverse_stress_completes_all_required_tests() -> None:
    control = control_frame()

    def yield_evaluator(value: float) -> pd.Series:
        return component([value, 2.0 * value, 0.5 * value])

    def rollover_evaluator(value: float) -> pd.Series:
        return component([100.0 * value, 200.0 * value, 50.0 * value])

    def haircut_evaluator(value: float) -> pd.Series:
        return component([120.0 * value, 160.0 * value, 80.0 * value])

    result = run_reverse_stress(
        control=control,
        yield_evaluator=yield_evaluator,
        rollover_evaluator=rollover_evaluator,
        haircut_evaluator=haircut_evaluator,
        config=reverse_config(),
    )
    assert result.passed
    assert result.thresholds["test_name"].tolist() == [
        "minimum_yield_shock",
        "minimum_rollover_failure_rate",
        "minimum_haircut_increase",
        "minimum_combined_scenario",
    ]
    assert not result.combination_ranking.empty
    assert result.combination_ranking.iloc[0]["combination_size"] == 2
    assert set(result.member_details["test_name"]) == set(result.thresholds["test_name"])
    assert result.search_trace["breached"].isin([True, False]).all()


def test_run_reverse_stress_rejects_invalid_combination_config() -> None:
    config = reverse_config()
    config["member_combinations"] = {"combination_size": 1, "top_n": 3}
    with pytest.raises(ReverseStressError, match="combination_size"):
        run_reverse_stress(
            control=control_frame(),
            yield_evaluator=lambda value: component([value, value, value]),
            rollover_evaluator=lambda value: component([value, value, value]),
            haircut_evaluator=lambda value: component([value, value, value]),
            config=config,
        )
