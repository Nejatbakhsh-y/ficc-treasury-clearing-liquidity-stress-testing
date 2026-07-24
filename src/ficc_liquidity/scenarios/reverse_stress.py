"""Reverse stress testing for synthetic clearing-member liquidity.

Phase VI, Section 23 searches for the smallest controlled stress parameter that
causes a member or member combination to fall below the configured liquidity
coverage threshold. The module is model-agnostic: existing Section 15-17 engines
supply exact component vectors through callables, while this module performs
liquidity aggregation, combination construction, threshold search, and controls.
"""

from __future__ import annotations

import hashlib
import math
import re
from collections.abc import Callable, Mapping
from dataclasses import dataclass
from itertools import combinations
from typing import Any, cast

import numpy as np
import pandas as pd


class ReverseStressError(ValueError):
    """Raised when reverse-stress inputs, assumptions, or outputs are invalid."""


ComponentEvaluator = Callable[[float], pd.Series]


@dataclass(frozen=True, slots=True)
class EvaluationSnapshot:
    """One evaluated stress point for members and optional member combinations."""

    parameter_value: float
    member_results: pd.DataFrame
    combination_results: pd.DataFrame
    criterion_type: str
    breached: bool
    breached_entity_id: str
    minimum_liquidity_coverage_ratio: float
    maximum_liquidity_shortfall_usd: float


@dataclass(frozen=True, slots=True)
class ThresholdResult:
    """Controlled binary-search result."""

    test_name: str
    parameter_unit: str
    search_status: str
    minimum_threshold: float
    safe_lower_bound: float
    breaching_upper_bound: float
    iterations: int
    criterion_type: str
    breached_entity_id: str
    liquidity_coverage_ratio: float
    liquidity_shortfall_usd: float
    minimality_check_pass: bool


@dataclass(frozen=True, slots=True)
class ReverseStressRun:
    """Section 23 result tables and validation checks."""

    thresholds: pd.DataFrame
    member_details: pd.DataFrame
    combination_ranking: pd.DataFrame
    search_trace: pd.DataFrame
    checks: Mapping[str, bool]

    @property
    def passed(self) -> bool:
        """Return true only when every Section 23 validation check passes."""
        return all(self.checks.values())


def _mapping(value: object, label: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise ReverseStressError(f"{label} must be a mapping.")
    return cast(dict[str, Any], value)


def _number(mapping: Mapping[str, Any], key: str) -> float:
    value = mapping.get(key)
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise ReverseStressError(f"{key} must be numeric.")
    result = float(value)
    if not math.isfinite(result):
        raise ReverseStressError(f"{key} must be finite.")
    return result


def _integer(mapping: Mapping[str, Any], key: str) -> int:
    value = mapping.get(key)
    if isinstance(value, bool) or not isinstance(value, int):
        raise ReverseStressError(f"{key} must be an integer.")
    return int(value)


def dataframe_digest(frame: pd.DataFrame) -> str:
    """Return a deterministic SHA-256 digest independent of row order."""
    ordered = frame.sort_index(axis=1).copy()
    sort_columns = [
        column
        for column in (
            "test_name",
            "parameter_value",
            "combination_id",
            "member_id",
        )
        if column in ordered.columns
    ]
    if sort_columns:
        ordered = ordered.sort_values(sort_columns, kind="stable")
    payload = ordered.to_csv(index=False, float_format="%.12g").encode("utf-8")
    return hashlib.sha256(payload).hexdigest()


def prepare_control(
    integrated_results: pd.DataFrame,
    *,
    control_scenario_name: str,
    synthetic_id_pattern: str,
    lcr_minimum_ratio: float,
    tolerance_usd: float,
) -> pd.DataFrame:
    """Select and validate one Section 19 control row per synthetic member."""
    if integrated_results.empty:
        raise ReverseStressError("Integrated stress results are empty.")
    required = {
        "scenario_name",
        "member_id",
        "stressed_liquidity_requirement_usd",
        "available_qualified_liquid_resources_usd",
    }
    missing = sorted(required - set(integrated_results.columns))
    if missing:
        raise ReverseStressError(f"Integrated results are missing required columns: {missing}")
    if lcr_minimum_ratio <= 0.0:
        raise ReverseStressError("lcr_minimum_ratio must be positive.")
    if tolerance_usd < 0.0:
        raise ReverseStressError("tolerance_usd must be nonnegative.")

    frame = integrated_results.loc[
        integrated_results["scenario_name"].astype(str).eq(control_scenario_name)
    ].copy()
    if frame.empty:
        raise ReverseStressError(
            f"Control scenario {control_scenario_name!r} was not found in integrated results."
        )
    frame["member_id"] = frame["member_id"].astype("string").str.strip()
    if frame["member_id"].isna().any() or (frame["member_id"] == "").any():
        raise ReverseStressError("Control results contain missing member identifiers.")
    invalid = [
        member_id
        for member_id in frame["member_id"].astype(str)
        if re.fullmatch(synthetic_id_pattern, member_id) is None
    ]
    if invalid:
        raise ReverseStressError(
            f"Control results contain invalid synthetic identifiers: {sorted(set(invalid))}"
        )
    if frame["member_id"].duplicated().any():
        raise ReverseStressError("Control results must contain one row per member.")

    for column in (
        "stressed_liquidity_requirement_usd",
        "available_qualified_liquid_resources_usd",
    ):
        frame[column] = pd.to_numeric(frame[column], errors="coerce")
        if frame[column].isna().any() or not frame[column].map(math.isfinite).all():
            raise ReverseStressError(f"{column} contains missing or nonfinite values.")
        if (frame[column] < -tolerance_usd).any():
            raise ReverseStressError(f"{column} must be nonnegative.")

    if (
        "actual_ficc_participant" in frame.columns
        and frame["actual_ficc_participant"].fillna(False).astype(bool).any()
    ):
        raise ReverseStressError("Actual FICC participant records are prohibited.")
    if (
        "participant_level_inference" in frame.columns
        and frame["participant_level_inference"].fillna(False).astype(bool).any()
    ):
        raise ReverseStressError("Participant-level inference records are prohibited.")
    if (
        "value_class" in frame.columns
        and not frame["value_class"].astype(str).eq("synthetic").all()
    ):
        raise ReverseStressError("Control results require value_class='synthetic'.")

    selected = frame[
        [
            "member_id",
            "stressed_liquidity_requirement_usd",
            "available_qualified_liquid_resources_usd",
        ]
    ].rename(
        columns={
            "stressed_liquidity_requirement_usd": "control_requirement_usd",
            "available_qualified_liquid_resources_usd": "available_resources_usd",
        }
    )
    selected["lcr_minimum_ratio"] = lcr_minimum_ratio
    selected["value_class"] = "synthetic"
    selected["actual_ficc_participant"] = False
    selected["participant_level_inference"] = False
    return selected.sort_values("member_id", kind="stable").reset_index(drop=True)


def _aligned_component(
    control: pd.DataFrame,
    values: pd.Series | None,
    label: str,
) -> pd.Series:
    if values is None:
        return pd.Series(0.0, index=control.index, dtype=float)
    if values.index.has_duplicates:
        raise ReverseStressError(f"{label} component contains duplicate member identifiers.")
    normalized = values.copy()
    normalized.index = normalized.index.astype(str)
    aligned = control["member_id"].astype(str).map(normalized)
    if aligned.isna().any():
        missing = control.loc[aligned.isna(), "member_id"].astype(str).tolist()
        raise ReverseStressError(f"{label} component is missing members: {missing}")
    numeric = pd.to_numeric(aligned, errors="coerce")
    if numeric.isna().any() or not numeric.map(math.isfinite).all():
        raise ReverseStressError(f"{label} component contains missing or nonfinite values.")
    if (numeric < 0.0).any():
        raise ReverseStressError(f"{label} component must be nonnegative.")
    return numeric.astype(float)


def build_member_results(
    control: pd.DataFrame,
    *,
    yield_losses: pd.Series | None = None,
    rollover_needs: pd.Series | None = None,
    haircut_requirements: pd.Series | None = None,
    lcr_minimum_ratio: float,
    tolerance_usd: float,
) -> pd.DataFrame:
    """Combine exact component vectors with the Section 19 control requirement."""
    if control.empty:
        raise ReverseStressError("Control frame is empty.")
    frame = control.copy(deep=True)
    frame["treasury_liquidation_loss_usd"] = _aligned_component(
        frame, yield_losses, "Yield-loss"
    ).to_numpy()
    frame["repo_rollover_need_usd"] = _aligned_component(
        frame, rollover_needs, "Rollover"
    ).to_numpy()
    frame["additional_haircut_requirement_usd"] = _aligned_component(
        frame, haircut_requirements, "Haircut"
    ).to_numpy()
    frame["stressed_liquidity_requirement_usd"] = (
        frame["control_requirement_usd"]
        + frame["treasury_liquidation_loss_usd"]
        + frame["repo_rollover_need_usd"]
        + frame["additional_haircut_requirement_usd"]
    )
    requirement = frame["stressed_liquidity_requirement_usd"].astype(float)
    resources = frame["available_resources_usd"].astype(float)
    frame["liquidity_coverage_ratio"] = np.where(
        requirement > tolerance_usd,
        resources / requirement,
        np.inf,
    )
    frame["liquidity_headroom_usd"] = resources - requirement
    frame["liquidity_shortfall_usd"] = (-frame["liquidity_headroom_usd"]).clip(lower=0.0)
    frame["lcr_status"] = np.where(
        requirement <= tolerance_usd,
        "NO_REQUIREMENT",
        np.where(frame["liquidity_coverage_ratio"] >= lcr_minimum_ratio, "PASS", "BREACH"),
    )
    frame["value_class"] = "synthetic"
    frame["actual_ficc_participant"] = False
    frame["participant_level_inference"] = False
    return frame.sort_values("member_id", kind="stable").reset_index(drop=True)


def build_member_combinations(
    member_results: pd.DataFrame,
    *,
    combination_size: int,
) -> pd.DataFrame:
    """Aggregate additive liquidity requirements and resources for all combinations."""
    if combination_size < 2:
        raise ReverseStressError("combination_size must be at least two.")
    if len(member_results) < combination_size:
        raise ReverseStressError(f"combination_size={combination_size} exceeds the member count.")
    required = {
        "member_id",
        "control_requirement_usd",
        "available_resources_usd",
        "treasury_liquidation_loss_usd",
        "repo_rollover_need_usd",
        "additional_haircut_requirement_usd",
        "stressed_liquidity_requirement_usd",
        "lcr_minimum_ratio",
    }
    missing = sorted(required - set(member_results.columns))
    if missing:
        raise ReverseStressError(f"Member results are missing combination fields: {missing}")

    indexed = member_results.set_index("member_id", drop=False)
    rows: list[dict[str, object]] = []
    member_ids = sorted(indexed.index.astype(str))
    for selected_ids in combinations(member_ids, combination_size):
        group = indexed.loc[list(selected_ids)]
        requirement = float(group["stressed_liquidity_requirement_usd"].sum())
        resources = float(group["available_resources_usd"].sum())
        lcr_limit = float(group["lcr_minimum_ratio"].iloc[0])
        lcr = resources / requirement if requirement > 0.0 else math.inf
        shortfall = max(requirement - resources, 0.0)
        rows.append(
            {
                "combination_id": "|".join(selected_ids),
                "combination_size": combination_size,
                "member_ids": ",".join(selected_ids),
                "control_requirement_usd": float(group["control_requirement_usd"].sum()),
                "treasury_liquidation_loss_usd": float(
                    group["treasury_liquidation_loss_usd"].sum()
                ),
                "repo_rollover_need_usd": float(group["repo_rollover_need_usd"].sum()),
                "additional_haircut_requirement_usd": float(
                    group["additional_haircut_requirement_usd"].sum()
                ),
                "stressed_liquidity_requirement_usd": requirement,
                "available_resources_usd": resources,
                "liquidity_coverage_ratio": lcr,
                "liquidity_headroom_usd": resources - requirement,
                "liquidity_shortfall_usd": shortfall,
                "lcr_status": "PASS" if lcr >= lcr_limit else "BREACH",
                "value_class": "synthetic",
                "actual_ficc_participant": False,
                "participant_level_inference": False,
            }
        )
    return (
        pd.DataFrame.from_records(rows)
        .sort_values(
            ["liquidity_coverage_ratio", "combination_id"],
            kind="stable",
        )
        .reset_index(drop=True)
    )


def make_snapshot(
    *,
    parameter_value: float,
    member_results: pd.DataFrame,
    criterion_type: str,
    combination_size: int,
    lcr_minimum_ratio: float,
    tolerance_usd: float,
) -> EvaluationSnapshot:
    """Build an evaluated point and identify the binding member or combination."""
    if criterion_type not in {"member", "combination"}:
        raise ReverseStressError("criterion_type must be 'member' or 'combination'.")
    combination_results = pd.DataFrame()
    if criterion_type == "combination":
        combination_results = build_member_combinations(
            member_results,
            combination_size=combination_size,
        )
        criterion = combination_results
        id_column = "combination_id"
    else:
        criterion = member_results
        id_column = "member_id"

    breached_rows = criterion.loc[
        (criterion["liquidity_coverage_ratio"] < lcr_minimum_ratio)
        | (criterion["liquidity_shortfall_usd"] > tolerance_usd)
    ].copy()
    breached = not breached_rows.empty
    binding_pool = breached_rows if breached else criterion
    binding = binding_pool.sort_values(
        ["liquidity_coverage_ratio", "liquidity_shortfall_usd", id_column],
        ascending=[True, False, True],
        kind="stable",
    ).iloc[0]
    return EvaluationSnapshot(
        parameter_value=parameter_value,
        member_results=member_results,
        combination_results=combination_results,
        criterion_type=criterion_type,
        breached=breached,
        breached_entity_id=str(binding[id_column]),
        minimum_liquidity_coverage_ratio=float(binding["liquidity_coverage_ratio"]),
        maximum_liquidity_shortfall_usd=float(binding["liquidity_shortfall_usd"]),
    )


def search_threshold(
    *,
    test_name: str,
    parameter_unit: str,
    lower_bound: float,
    upper_bound: float,
    parameter_tolerance: float,
    maximum_iterations: int,
    evaluator: Callable[[float], EvaluationSnapshot],
) -> tuple[ThresholdResult, EvaluationSnapshot, list[dict[str, object]]]:
    """Find the smallest breaching parameter by controlled monotone binary search."""
    if lower_bound < 0.0 or upper_bound <= lower_bound:
        raise ReverseStressError(f"{test_name} search bounds are invalid.")
    if parameter_tolerance <= 0.0:
        raise ReverseStressError(f"{test_name} parameter_tolerance must be positive.")
    if maximum_iterations < 1:
        raise ReverseStressError(f"{test_name} maximum_iterations must be positive.")

    trace: list[dict[str, object]] = []

    def evaluate(value: float, stage: str) -> EvaluationSnapshot:
        snapshot = evaluator(value)
        trace.append(
            {
                "test_name": test_name,
                "stage": stage,
                "parameter_value": value,
                "parameter_unit": parameter_unit,
                "criterion_type": snapshot.criterion_type,
                "breached": snapshot.breached,
                "binding_entity_id": snapshot.breached_entity_id,
                "minimum_liquidity_coverage_ratio": (snapshot.minimum_liquidity_coverage_ratio),
                "maximum_liquidity_shortfall_usd": (snapshot.maximum_liquidity_shortfall_usd),
            }
        )
        return snapshot

    low = lower_bound
    high = upper_bound
    low_snapshot = evaluate(low, "lower_bound")
    if low_snapshot.breached:
        result = ThresholdResult(
            test_name=test_name,
            parameter_unit=parameter_unit,
            search_status="BREACH_AT_LOWER_BOUND",
            minimum_threshold=low,
            safe_lower_bound=low,
            breaching_upper_bound=low,
            iterations=0,
            criterion_type=low_snapshot.criterion_type,
            breached_entity_id=low_snapshot.breached_entity_id,
            liquidity_coverage_ratio=low_snapshot.minimum_liquidity_coverage_ratio,
            liquidity_shortfall_usd=low_snapshot.maximum_liquidity_shortfall_usd,
            minimality_check_pass=True,
        )
        return result, low_snapshot, trace

    high_snapshot = evaluate(high, "upper_bound")
    if not high_snapshot.breached:
        result = ThresholdResult(
            test_name=test_name,
            parameter_unit=parameter_unit,
            search_status="NOT_REACHED",
            minimum_threshold=math.nan,
            safe_lower_bound=high,
            breaching_upper_bound=math.nan,
            iterations=0,
            criterion_type=high_snapshot.criterion_type,
            breached_entity_id=high_snapshot.breached_entity_id,
            liquidity_coverage_ratio=high_snapshot.minimum_liquidity_coverage_ratio,
            liquidity_shortfall_usd=high_snapshot.maximum_liquidity_shortfall_usd,
            minimality_check_pass=True,
        )
        return result, high_snapshot, trace

    iterations = 0
    while high - low > parameter_tolerance and iterations < maximum_iterations:
        midpoint = (low + high) / 2.0
        midpoint_snapshot = evaluate(midpoint, "binary_search")
        if midpoint_snapshot.breached:
            high = midpoint
            high_snapshot = midpoint_snapshot
        else:
            low = midpoint
            low_snapshot = midpoint_snapshot
        iterations += 1

    minimality_pass = (
        not low_snapshot.breached
        and high_snapshot.breached
        and high - low <= parameter_tolerance * 1.000001
    )
    result = ThresholdResult(
        test_name=test_name,
        parameter_unit=parameter_unit,
        search_status="FOUND",
        minimum_threshold=high,
        safe_lower_bound=low,
        breaching_upper_bound=high,
        iterations=iterations,
        criterion_type=high_snapshot.criterion_type,
        breached_entity_id=high_snapshot.breached_entity_id,
        liquidity_coverage_ratio=high_snapshot.minimum_liquidity_coverage_ratio,
        liquidity_shortfall_usd=high_snapshot.maximum_liquidity_shortfall_usd,
        minimality_check_pass=minimality_pass,
    )
    return result, high_snapshot, trace


def _search_block(config: Mapping[str, Any], key: str) -> dict[str, Any]:
    search = _mapping(config.get("search"), "search")
    return _mapping(search.get(key), f"search.{key}")


def _threshold_record(
    result: ThresholdResult,
    *,
    yield_shock_bp: float,
    rollover_failure_rate: float,
    haircut_increase_rate: float,
    combined_severity: float,
) -> dict[str, object]:
    return {
        "test_name": result.test_name,
        "parameter_unit": result.parameter_unit,
        "search_status": result.search_status,
        "minimum_threshold": result.minimum_threshold,
        "safe_lower_bound": result.safe_lower_bound,
        "breaching_upper_bound": result.breaching_upper_bound,
        "iterations": result.iterations,
        "criterion_type": result.criterion_type,
        "breached_entity_id": result.breached_entity_id,
        "liquidity_coverage_ratio": result.liquidity_coverage_ratio,
        "liquidity_shortfall_usd": result.liquidity_shortfall_usd,
        "yield_shock_bp": yield_shock_bp,
        "rollover_failure_rate": rollover_failure_rate,
        "haircut_increase_rate": haircut_increase_rate,
        "combined_severity": combined_severity,
        "minimality_check_pass": result.minimality_check_pass,
        "value_class": "synthetic",
        "actual_ficc_participant": False,
        "participant_level_inference": False,
    }


def run_reverse_stress(
    *,
    control: pd.DataFrame,
    yield_evaluator: ComponentEvaluator,
    rollover_evaluator: ComponentEvaluator,
    haircut_evaluator: ComponentEvaluator,
    config: Mapping[str, Any],
) -> ReverseStressRun:
    """Execute all Section 23 reverse-stress searches."""
    validation = _mapping(config.get("validation"), "validation")
    combinations_config = _mapping(config.get("member_combinations"), "member_combinations")
    lcr_minimum_ratio = _number(validation, "lcr_minimum_ratio")
    tolerance_usd = _number(validation, "liquidity_tolerance_usd")
    maximum_iterations = _integer(validation, "maximum_binary_search_iterations")
    combination_size = _integer(combinations_config, "combination_size")
    top_n = _integer(combinations_config, "top_n")
    if combination_size < 2:
        raise ReverseStressError("member_combinations.combination_size must be at least two.")
    if top_n < 1:
        raise ReverseStressError("member_combinations.top_n must be positive.")

    yield_config = _search_block(config, "yield_shock")
    rollover_config = _search_block(config, "rollover_failure")
    haircut_config = _search_block(config, "haircut_increase")
    combined_config = _search_block(config, "combined_scenario")

    def search_values(block: Mapping[str, Any]) -> tuple[float, float, float]:
        return (
            _number(block, "lower_bound"),
            _number(block, "upper_bound"),
            _number(block, "parameter_tolerance"),
        )

    yield_low, yield_high, yield_tolerance = search_values(yield_config)
    rollover_low, rollover_high, rollover_tolerance = search_values(rollover_config)
    haircut_low, haircut_high, haircut_tolerance = search_values(haircut_config)
    combined_low, combined_high, combined_tolerance = search_values(combined_config)

    combined_max_yield = _number(combined_config, "maximum_yield_shock_bp")
    combined_max_rollover = _number(combined_config, "maximum_rollover_failure_rate")
    combined_max_haircut = _number(combined_config, "maximum_haircut_increase_rate")
    if combined_max_yield < 0.0:
        raise ReverseStressError("maximum_yield_shock_bp must be nonnegative.")
    if not 0.0 <= combined_max_rollover <= 1.0:
        raise ReverseStressError("maximum_rollover_failure_rate must be between zero and one.")
    if not 0.0 <= combined_max_haircut < 1.0:
        raise ReverseStressError("maximum_haircut_increase_rate must be in [0, 1).")

    def member_snapshot(
        parameter: float,
        *,
        yield_losses: pd.Series | None = None,
        rollover_needs: pd.Series | None = None,
        haircut_requirements: pd.Series | None = None,
        criterion_type: str = "member",
    ) -> EvaluationSnapshot:
        members = build_member_results(
            control,
            yield_losses=yield_losses,
            rollover_needs=rollover_needs,
            haircut_requirements=haircut_requirements,
            lcr_minimum_ratio=lcr_minimum_ratio,
            tolerance_usd=tolerance_usd,
        )
        return make_snapshot(
            parameter_value=parameter,
            member_results=members,
            criterion_type=criterion_type,
            combination_size=combination_size,
            lcr_minimum_ratio=lcr_minimum_ratio,
            tolerance_usd=tolerance_usd,
        )

    yield_result, yield_snapshot, yield_trace = search_threshold(
        test_name="minimum_yield_shock",
        parameter_unit="basis_points",
        lower_bound=yield_low,
        upper_bound=yield_high,
        parameter_tolerance=yield_tolerance,
        maximum_iterations=maximum_iterations,
        evaluator=lambda value: member_snapshot(
            value,
            yield_losses=yield_evaluator(value),
        ),
    )
    rollover_result, rollover_snapshot, rollover_trace = search_threshold(
        test_name="minimum_rollover_failure_rate",
        parameter_unit="decimal_rate",
        lower_bound=rollover_low,
        upper_bound=rollover_high,
        parameter_tolerance=rollover_tolerance,
        maximum_iterations=maximum_iterations,
        evaluator=lambda value: member_snapshot(
            value,
            rollover_needs=rollover_evaluator(value),
        ),
    )
    haircut_result, haircut_snapshot, haircut_trace = search_threshold(
        test_name="minimum_haircut_increase",
        parameter_unit="decimal_rate",
        lower_bound=haircut_low,
        upper_bound=haircut_high,
        parameter_tolerance=haircut_tolerance,
        maximum_iterations=maximum_iterations,
        evaluator=lambda value: member_snapshot(
            value,
            haircut_requirements=haircut_evaluator(value),
        ),
    )

    def combined_snapshot(severity: float) -> EvaluationSnapshot:
        yield_shock = severity * combined_max_yield
        rollover_rate = severity * combined_max_rollover
        haircut_rate = severity * combined_max_haircut
        return member_snapshot(
            severity,
            yield_losses=yield_evaluator(yield_shock),
            rollover_needs=rollover_evaluator(rollover_rate),
            haircut_requirements=haircut_evaluator(haircut_rate),
            criterion_type="combination",
        )

    combined_result, combined_snapshot_result, combined_trace = search_threshold(
        test_name="minimum_combined_scenario",
        parameter_unit="normalized_severity",
        lower_bound=combined_low,
        upper_bound=combined_high,
        parameter_tolerance=combined_tolerance,
        maximum_iterations=maximum_iterations,
        evaluator=combined_snapshot,
    )

    threshold_rows = [
        _threshold_record(
            yield_result,
            yield_shock_bp=yield_result.minimum_threshold,
            rollover_failure_rate=0.0,
            haircut_increase_rate=0.0,
            combined_severity=0.0,
        ),
        _threshold_record(
            rollover_result,
            yield_shock_bp=0.0,
            rollover_failure_rate=rollover_result.minimum_threshold,
            haircut_increase_rate=0.0,
            combined_severity=0.0,
        ),
        _threshold_record(
            haircut_result,
            yield_shock_bp=0.0,
            rollover_failure_rate=0.0,
            haircut_increase_rate=haircut_result.minimum_threshold,
            combined_severity=0.0,
        ),
        _threshold_record(
            combined_result,
            yield_shock_bp=(
                combined_result.minimum_threshold * combined_max_yield
                if math.isfinite(combined_result.minimum_threshold)
                else math.nan
            ),
            rollover_failure_rate=(
                combined_result.minimum_threshold * combined_max_rollover
                if math.isfinite(combined_result.minimum_threshold)
                else math.nan
            ),
            haircut_increase_rate=(
                combined_result.minimum_threshold * combined_max_haircut
                if math.isfinite(combined_result.minimum_threshold)
                else math.nan
            ),
            combined_severity=combined_result.minimum_threshold,
        ),
    ]
    thresholds = pd.DataFrame.from_records(threshold_rows)

    snapshots = {
        "minimum_yield_shock": yield_snapshot,
        "minimum_rollover_failure_rate": rollover_snapshot,
        "minimum_haircut_increase": haircut_snapshot,
        "minimum_combined_scenario": combined_snapshot_result,
    }
    detail_frames: list[pd.DataFrame] = []
    for test_name, snapshot in snapshots.items():
        detail = snapshot.member_results.copy()
        detail.insert(0, "test_name", test_name)
        detail.insert(1, "parameter_value", snapshot.parameter_value)
        detail_frames.append(detail)
    member_details = pd.concat(detail_frames, ignore_index=True).sort_values(
        ["test_name", "member_id"], kind="stable"
    )

    combination_ranking = combined_snapshot_result.combination_results.copy()
    if not combination_ranking.empty:
        combination_ranking.insert(0, "test_name", "minimum_combined_scenario")
        combination_ranking.insert(
            1,
            "combined_severity",
            combined_snapshot_result.parameter_value,
        )
        combination_ranking = combination_ranking.sort_values(
            ["liquidity_coverage_ratio", "liquidity_shortfall_usd", "combination_id"],
            ascending=[True, False, True],
            kind="stable",
        ).head(top_n)
        combination_ranking = combination_ranking.reset_index(drop=True)

    search_trace = pd.DataFrame.from_records(
        [*yield_trace, *rollover_trace, *haircut_trace, *combined_trace]
    )
    finite_threshold_outputs = bool(
        thresholds.loc[
            thresholds["search_status"].ne("NOT_REACHED"),
            ["minimum_threshold", "liquidity_coverage_ratio", "liquidity_shortfall_usd"],
        ]
        .apply(lambda column: column.map(math.isfinite))
        .all()
        .all()
    )
    nonnegative_outputs = bool(
        (
            member_details[
                [
                    "control_requirement_usd",
                    "available_resources_usd",
                    "treasury_liquidation_loss_usd",
                    "repo_rollover_need_usd",
                    "additional_haircut_requirement_usd",
                    "stressed_liquidity_requirement_usd",
                    "liquidity_shortfall_usd",
                ]
            ]
            >= 0.0
        )
        .all()
        .all()
    )
    requirement_identity = bool(
        (
            member_details["stressed_liquidity_requirement_usd"]
            - member_details["control_requirement_usd"]
            - member_details["treasury_liquidation_loss_usd"]
            - member_details["repo_rollover_need_usd"]
            - member_details["additional_haircut_requirement_usd"]
        )
        .abs()
        .le(max(tolerance_usd, 1e-8))
        .all()
    )
    synthetic_only = bool(
        not member_details["actual_ficc_participant"].astype(bool).any()
        and not member_details["participant_level_inference"].astype(bool).any()
        and member_details["value_class"].astype(str).eq("synthetic").all()
    )
    checks = {
        "four_reverse_stress_tests_completed": len(thresholds) == 4,
        "threshold_search_minimality": bool(thresholds["minimality_check_pass"].all()),
        "finite_threshold_outputs": finite_threshold_outputs,
        "nonnegative_liquidity_outputs": nonnegative_outputs,
        "requirement_identity": requirement_identity,
        "combination_ranking_created": not combination_ranking.empty,
        "most_vulnerable_combination_identified": (
            not combination_ranking.empty
            and str(combination_ranking.iloc[0]["combination_id"]) != ""
        ),
        "synthetic_identity_controls": synthetic_only,
    }
    return ReverseStressRun(
        thresholds=thresholds.reset_index(drop=True),
        member_details=member_details.reset_index(drop=True),
        combination_ranking=combination_ranking,
        search_trace=search_trace.reset_index(drop=True),
        checks=checks,
    )
