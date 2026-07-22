"""Repo funding-stress model for synthetic clearing-member liquidity analysis.

The model overlays configurable repo-market funding shocks on the controlled
Section 14 baseline liquidity cash flows. It operates only on fictional member
records and never identifies or infers actual FICC participants.
"""

from __future__ import annotations

import math
import re
from collections.abc import Mapping
from dataclasses import dataclass
from pathlib import Path
from typing import Any, cast

import pandas as pd
import yaml


class RepoFundingStressError(ValueError):
    """Raised when repo funding-stress inputs or assumptions are invalid."""


@dataclass(frozen=True, slots=True)
class RepoFundingScenario:
    """One controlled repo funding-stress scenario."""

    name: str
    severity_rank: int
    sofr_spike_bp: float
    funding_spread_increase_bp: float
    repo_rollover_failure_rate: float
    lender_withdrawal_rate: float
    refinancing_horizon_hours: int
    collateral_haircut_increase: float
    collateral_call_rate: float
    concentration_threshold: float
    concentration_multiplier: float
    funding_dependency_multiplier: float
    max_effective_unavailability_rate: float


@dataclass(frozen=True, slots=True)
class RepoFundingStressSettings:
    """Validated Section 16 assumptions and scenario definitions."""

    model_version: str
    reference_sofr_percent: float
    baseline_liquidity_horizon_hours: int
    day_count_basis: int
    tolerance_usd: float
    synthetic_id_pattern: str
    scenarios: tuple[RepoFundingScenario, ...]


@dataclass(frozen=True, slots=True)
class ValidationResult:
    """Structured Section 16 validation result."""

    checks: Mapping[str, bool]

    @property
    def passed(self) -> bool:
        """Return true only when every validation check passes."""
        return all(self.checks.values())


def _mapping(value: object, label: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise RepoFundingStressError(f"{label} must be a YAML mapping.")
    return cast(dict[str, Any], value)


def _number(mapping: Mapping[str, Any], key: str) -> float:
    value = mapping.get(key)
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise RepoFundingStressError(f"{key} must be numeric.")
    result = float(value)
    if not math.isfinite(result):
        raise RepoFundingStressError(f"{key} must be finite.")
    return result


def _integer(mapping: Mapping[str, Any], key: str) -> int:
    value = mapping.get(key)
    if isinstance(value, bool) or not isinstance(value, int):
        raise RepoFundingStressError(f"{key} must be an integer.")
    return int(value)


def load_config(path: str | Path) -> dict[str, Any]:
    """Load a controlled YAML configuration."""
    config_path = Path(path)
    if not config_path.exists():
        raise RepoFundingStressError(f"Configuration does not exist: {config_path}")
    loaded = yaml.safe_load(config_path.read_text(encoding="utf-8"))
    return _mapping(loaded, "Configuration")


def _bounded_rate(value: float, label: str, *, upper_inclusive: bool = True) -> None:
    upper_valid = value <= 1.0 if upper_inclusive else value < 1.0
    if value < 0.0 or not upper_valid:
        comparator = "between zero and one" if upper_inclusive else "at least zero and below one"
        raise RepoFundingStressError(f"{label} must be {comparator}.")


def _load_scenario(
    raw_scenario: Mapping[str, Any],
    baseline_horizon_hours: int,
) -> RepoFundingScenario:
    scenario = RepoFundingScenario(
        name=str(raw_scenario.get("name", "")).strip(),
        severity_rank=_integer(raw_scenario, "severity_rank"),
        sofr_spike_bp=_number(raw_scenario, "sofr_spike_bp"),
        funding_spread_increase_bp=_number(raw_scenario, "funding_spread_increase_bp"),
        repo_rollover_failure_rate=_number(raw_scenario, "repo_rollover_failure_rate"),
        lender_withdrawal_rate=_number(raw_scenario, "lender_withdrawal_rate"),
        refinancing_horizon_hours=_integer(raw_scenario, "refinancing_horizon_hours"),
        collateral_haircut_increase=_number(raw_scenario, "collateral_haircut_increase"),
        collateral_call_rate=_number(raw_scenario, "collateral_call_rate"),
        concentration_threshold=_number(raw_scenario, "concentration_threshold"),
        concentration_multiplier=_number(raw_scenario, "concentration_multiplier"),
        funding_dependency_multiplier=_number(raw_scenario, "funding_dependency_multiplier"),
        max_effective_unavailability_rate=_number(
            raw_scenario,
            "max_effective_unavailability_rate",
        ),
    )
    if not scenario.name:
        raise RepoFundingStressError("Every scenario must have a nonempty name.")
    if scenario.severity_rank < 0:
        raise RepoFundingStressError("severity_rank must be nonnegative.")
    if scenario.sofr_spike_bp < 0.0:
        raise RepoFundingStressError("sofr_spike_bp must be nonnegative.")
    if scenario.funding_spread_increase_bp < 0.0:
        raise RepoFundingStressError("funding_spread_increase_bp must be nonnegative.")
    for label, value in (
        ("repo_rollover_failure_rate", scenario.repo_rollover_failure_rate),
        ("lender_withdrawal_rate", scenario.lender_withdrawal_rate),
        ("collateral_haircut_increase", scenario.collateral_haircut_increase),
        ("collateral_call_rate", scenario.collateral_call_rate),
        ("concentration_threshold", scenario.concentration_threshold),
        (
            "max_effective_unavailability_rate",
            scenario.max_effective_unavailability_rate,
        ),
    ):
        _bounded_rate(value, label)
    if scenario.refinancing_horizon_hours <= 0:
        raise RepoFundingStressError("refinancing_horizon_hours must be positive.")
    if scenario.refinancing_horizon_hours > baseline_horizon_hours:
        raise RepoFundingStressError(
            "refinancing_horizon_hours cannot exceed the baseline liquidity horizon."
        )
    if scenario.concentration_multiplier < 0.0:
        raise RepoFundingStressError("concentration_multiplier must be nonnegative.")
    if scenario.funding_dependency_multiplier < 0.0:
        raise RepoFundingStressError("funding_dependency_multiplier must be nonnegative.")
    return scenario


def load_settings(config: Mapping[str, Any]) -> RepoFundingStressSettings:
    """Validate and convert the repo funding-stress configuration."""
    assumptions = _mapping(config.get("assumptions"), "assumptions")
    validation = _mapping(config.get("validation"), "validation")
    source = _mapping(config.get("source"), "source")
    raw_scenarios = config.get("scenarios")
    if not isinstance(raw_scenarios, list) or not raw_scenarios:
        raise RepoFundingStressError("scenarios must be a nonempty list.")

    baseline_horizon_hours = _integer(
        assumptions,
        "baseline_liquidity_horizon_hours",
    )
    if baseline_horizon_hours <= 0:
        raise RepoFundingStressError("baseline_liquidity_horizon_hours must be positive.")

    scenarios: list[RepoFundingScenario] = []
    for raw_scenario in raw_scenarios:
        scenario_mapping = _mapping(raw_scenario, "scenario")
        if not bool(scenario_mapping.get("enabled", True)):
            continue
        scenarios.append(_load_scenario(scenario_mapping, baseline_horizon_hours))
    if not scenarios:
        raise RepoFundingStressError("At least one enabled scenario is required.")

    names = [scenario.name for scenario in scenarios]
    if len(set(names)) != len(names):
        raise RepoFundingStressError("Scenario names must be unique.")
    ranks = [scenario.severity_rank for scenario in scenarios]
    if len(set(ranks)) != len(ranks):
        raise RepoFundingStressError("Scenario severity ranks must be unique.")

    settings = RepoFundingStressSettings(
        model_version=str(config.get("model_version", "section-16-v1")).strip(),
        reference_sofr_percent=_number(assumptions, "reference_sofr_percent"),
        baseline_liquidity_horizon_hours=baseline_horizon_hours,
        day_count_basis=_integer(assumptions, "day_count_basis"),
        tolerance_usd=_number(validation, "reconciliation_tolerance_usd"),
        synthetic_id_pattern=str(source.get("synthetic_id_pattern", r"^SYN-MBR-[0-9]{4}$")),
        scenarios=tuple(sorted(scenarios, key=lambda item: item.severity_rank)),
    )
    if not settings.model_version:
        raise RepoFundingStressError("model_version must be populated.")
    if settings.reference_sofr_percent < 0.0:
        raise RepoFundingStressError("reference_sofr_percent must be nonnegative.")
    if settings.day_count_basis <= 0:
        raise RepoFundingStressError("day_count_basis must be positive.")
    if settings.tolerance_usd < 0.0:
        raise RepoFundingStressError("reconciliation_tolerance_usd must be nonnegative.")
    return settings


def read_table(path: str | Path) -> pd.DataFrame:
    """Read a CSV or Parquet table."""
    table_path = Path(path)
    if not table_path.exists():
        raise RepoFundingStressError(f"Input table does not exist: {table_path}")
    suffix = table_path.suffix.lower()
    if suffix == ".csv":
        return pd.read_csv(table_path)
    if suffix in {".parquet", ".pq"}:
        return pd.read_parquet(table_path)
    raise RepoFundingStressError("Input tables must be CSV or Parquet.")


def _validate_synthetic_identity(
    frame: pd.DataFrame,
    synthetic_id_pattern: str,
) -> None:
    member_ids = frame["member_id"].astype("string").str.strip()
    if member_ids.isna().any():
        raise RepoFundingStressError("Synthetic member identifiers cannot be missing.")
    invalid = [
        member_id
        for member_id in member_ids.astype(str)
        if re.fullmatch(synthetic_id_pattern, member_id) is None
    ]
    if invalid:
        raise RepoFundingStressError(
            f"Non-synthetic or invalid member identifiers detected: {sorted(set(invalid))}"
        )
    if (
        "actual_ficc_participant" in frame.columns
        and frame["actual_ficc_participant"].fillna(False).astype(bool).any()
    ):
        raise RepoFundingStressError("Actual FICC participant records are prohibited.")
    if (
        "participant_level_inference" in frame.columns
        and frame["participant_level_inference"].fillna(False).astype(bool).any()
    ):
        raise RepoFundingStressError("Participant-level inference records are prohibited.")
    if (
        "value_class" in frame.columns
        and not frame["value_class"].astype(str).eq("synthetic").all()
    ):
        raise RepoFundingStressError("Every member record must use value_class='synthetic'.")


def prepare_baseline(
    baseline: pd.DataFrame,
    settings: RepoFundingStressSettings,
) -> pd.DataFrame:
    """Canonicalize and validate Section 14 baseline cash-flow records."""
    if baseline.empty:
        raise RepoFundingStressError("Baseline liquidity cash-flow input is empty.")
    required = {
        "member_id",
        "bucket_order",
        "time_bucket",
        "elapsed_hours",
        "liquidity_horizon_hours",
        "repo_maturity_usd",
        "repo_roll_amount_usd",
        "financing_outflow_usd",
        "total_cash_outflow_usd",
        "cumulative_net_liquidity_need_usd",
        "cumulative_available_resources_usd",
        "liquidity_headroom_usd",
        "liquidity_shortfall_usd",
    }
    missing = sorted(required - set(baseline.columns))
    if missing:
        raise RepoFundingStressError(f"Required baseline cash-flow columns are missing: {missing}")

    frame = baseline.copy(deep=True)
    frame["member_id"] = frame["member_id"].astype("string").str.strip()
    _validate_synthetic_identity(frame, settings.synthetic_id_pattern)
    if frame.duplicated(["member_id", "time_bucket"]).any():
        raise RepoFundingStressError("Baseline member and time-bucket combinations must be unique.")

    numeric_columns = sorted(required - {"member_id", "time_bucket"})
    for column in numeric_columns:
        frame[column] = pd.to_numeric(frame[column], errors="coerce")
        if frame[column].isna().any() or (~frame[column].map(math.isfinite)).any():
            raise RepoFundingStressError(f"{column} contains missing or nonfinite values.")

    nonnegative = [column for column in numeric_columns if column not in {"liquidity_headroom_usd"}]
    if (frame[nonnegative] < -settings.tolerance_usd).any().any():
        raise RepoFundingStressError(
            "Baseline nonnegative cash-flow components contain negative values."
        )
    if not frame["liquidity_horizon_hours"].eq(settings.baseline_liquidity_horizon_hours).all():
        raise RepoFundingStressError(
            "Baseline liquidity-horizon values do not match the Section 16 configuration."
        )

    frame["value_class"] = "synthetic"
    frame["actual_ficc_participant"] = False
    frame["participant_level_inference"] = False
    return frame.sort_values(
        ["member_id", "bucket_order"],
        kind="stable",
    ).reset_index(drop=True)


def _derive_member_ratios(frame: pd.DataFrame) -> pd.DataFrame:
    result = frame.copy(deep=True)
    treasury_columns = [
        column
        for column in result.columns
        if column.startswith("treasury_position_") and column.endswith("_usd")
    ]

    if "member_concentration_ratio" not in result.columns:
        if not treasury_columns:
            raise RepoFundingStressError(
                "member_concentration_ratio is missing and cannot be derived."
            )
        if "total_treasury_position_usd" not in result.columns:
            raise RepoFundingStressError(
                "total_treasury_position_usd is required to derive concentration."
            )
        total = pd.to_numeric(
            result["total_treasury_position_usd"],
            errors="coerce",
        )
        if total.isna().any() or (total <= 0.0).any():
            raise RepoFundingStressError(
                "total_treasury_position_usd is required to derive concentration."
            )
        result["member_concentration_ratio"] = (
            result[treasury_columns].apply(pd.to_numeric, errors="coerce").max(axis=1) / total
        )

    if "funding_dependency_ratio" not in result.columns:
        required = {"repo_financing_need_usd", "treasury_transaction_activity_usd"}
        if not required.issubset(result.columns):
            raise RepoFundingStressError(
                "funding_dependency_ratio is missing and cannot be derived."
            )
        activity = pd.to_numeric(
            result["treasury_transaction_activity_usd"],
            errors="coerce",
        )
        if activity.isna().any() or (activity <= 0.0).any():
            raise RepoFundingStressError("treasury_transaction_activity_usd must be positive.")
        result["funding_dependency_ratio"] = (
            pd.to_numeric(result["repo_financing_need_usd"], errors="coerce") / activity
        )

    if "net_repo_dependency_ratio" not in result.columns:
        required = {"repo_financing_need_usd", "reverse_repo_position_usd"}
        if not required.issubset(result.columns):
            raise RepoFundingStressError(
                "net_repo_dependency_ratio is missing and cannot be derived."
            )
        repo = pd.to_numeric(result["repo_financing_need_usd"], errors="coerce")
        reverse = pd.to_numeric(
            result["reverse_repo_position_usd"],
            errors="coerce",
        )
        if repo.isna().any() or (repo <= 0.0).any():
            raise RepoFundingStressError("repo_financing_need_usd must be positive.")
        result["net_repo_dependency_ratio"] = (repo - reverse).clip(lower=0.0) / repo

    return result


def prepare_members(
    members: pd.DataFrame,
    settings: RepoFundingStressSettings,
) -> pd.DataFrame:
    """Canonicalize member concentration and funding-dependency inputs."""
    if members.empty:
        raise RepoFundingStressError("Synthetic member profile input is empty.")
    if "member_id" not in members.columns:
        raise RepoFundingStressError("Synthetic member profiles require member_id.")

    frame = _derive_member_ratios(members)
    frame["member_id"] = frame["member_id"].astype("string").str.strip()
    _validate_synthetic_identity(frame, settings.synthetic_id_pattern)
    if frame["member_id"].duplicated().any():
        raise RepoFundingStressError("Synthetic member identifiers must be unique.")

    ratio_columns = [
        "member_concentration_ratio",
        "funding_dependency_ratio",
        "net_repo_dependency_ratio",
    ]
    for column in ratio_columns:
        frame[column] = pd.to_numeric(frame[column], errors="coerce")
        if frame[column].isna().any() or (~frame[column].map(math.isfinite)).any():
            raise RepoFundingStressError(f"{column} contains missing or nonfinite values.")
        if ((frame[column] < 0.0) | (frame[column] > 1.0)).any():
            raise RepoFundingStressError(f"{column} must be between zero and one.")

    frame["value_class"] = "synthetic"
    frame["actual_ficc_participant"] = False
    frame["participant_level_inference"] = False
    return (
        frame[
            [
                "member_id",
                "member_concentration_ratio",
                "funding_dependency_ratio",
                "net_repo_dependency_ratio",
                "value_class",
                "actual_ficc_participant",
                "participant_level_inference",
            ]
        ]
        .sort_values("member_id", kind="stable")
        .reset_index(drop=True)
    )


def _scenario_frame(
    baseline: pd.DataFrame,
    members: pd.DataFrame,
    scenario: RepoFundingScenario,
    settings: RepoFundingStressSettings,
) -> pd.DataFrame:
    frame = baseline.merge(
        members[
            [
                "member_id",
                "member_concentration_ratio",
                "funding_dependency_ratio",
                "net_repo_dependency_ratio",
            ]
        ],
        on="member_id",
        how="left",
        validate="many_to_one",
    )
    if (
        frame[
            [
                "member_concentration_ratio",
                "funding_dependency_ratio",
                "net_repo_dependency_ratio",
            ]
        ]
        .isna()
        .any()
        .any()
    ):
        raise RepoFundingStressError(
            "Every baseline member must have a matching synthetic member profile."
        )

    frame["scenario_name"] = scenario.name
    frame["severity_rank"] = scenario.severity_rank
    frame["reference_sofr_percent"] = settings.reference_sofr_percent
    frame["sofr_spike_bp"] = scenario.sofr_spike_bp
    frame["funding_spread_increase_bp"] = scenario.funding_spread_increase_bp
    frame["stressed_sofr_percent"] = (
        settings.reference_sofr_percent + scenario.sofr_spike_bp / 100.0
    )
    frame["stressed_all_in_rate_percent"] = (
        frame["stressed_sofr_percent"] + scenario.funding_spread_increase_bp / 100.0
    )
    frame["refinancing_horizon_hours"] = scenario.refinancing_horizon_hours
    frame["refinancing_cycle_multiplier"] = settings.baseline_liquidity_horizon_hours / float(
        scenario.refinancing_horizon_hours
    )

    concentration_excess = (
        frame["member_concentration_ratio"] - scenario.concentration_threshold
    ).clip(lower=0.0)
    frame["funding_concentration_factor"] = (
        1.0 + scenario.concentration_multiplier * concentration_excess
    )
    frame["funding_dependency_factor"] = (
        1.0
        + scenario.funding_dependency_multiplier
        * frame["funding_dependency_ratio"]
        * frame["net_repo_dependency_ratio"]
    )

    base_unavailability = 1.0 - (
        (1.0 - scenario.repo_rollover_failure_rate) * (1.0 - scenario.lender_withdrawal_rate)
    )
    per_cycle_unavailability = (
        base_unavailability
        * frame["funding_concentration_factor"]
        * frame["funding_dependency_factor"]
    ).clip(
        lower=0.0,
        upper=scenario.max_effective_unavailability_rate,
    )
    frame["per_cycle_funding_unavailability_rate"] = per_cycle_unavailability
    effective_unavailability = (
        1.0 - (1.0 - per_cycle_unavailability) ** frame["refinancing_cycle_multiplier"]
    )
    frame["effective_funding_unavailability_rate"] = effective_unavailability.clip(
        lower=0.0,
        upper=scenario.max_effective_unavailability_rate,
    )

    frame["repo_rollover_failure_outflow_usd"] = (
        frame["repo_roll_amount_usd"] * frame["effective_funding_unavailability_rate"]
    )
    frame["successful_repo_refinancing_usd"] = (
        frame["repo_roll_amount_usd"] - frame["repo_rollover_failure_outflow_usd"]
    ).clip(lower=0.0)
    frame["stressed_financing_outflow_usd"] = (
        frame["financing_outflow_usd"] + frame["repo_rollover_failure_outflow_usd"]
    )

    incremental_rate_decimal = (
        scenario.sofr_spike_bp + scenario.funding_spread_increase_bp
    ) / 10_000.0
    funding_days = settings.baseline_liquidity_horizon_hours / 24.0
    frame["incremental_funding_cost_usd"] = (
        frame["successful_repo_refinancing_usd"]
        * incremental_rate_decimal
        * funding_days
        / float(settings.day_count_basis)
    )

    frame["additional_haircut_collateral_demand_usd"] = (
        frame["successful_repo_refinancing_usd"]
        * scenario.collateral_haircut_increase
        * frame["funding_concentration_factor"]
    )
    frame["additional_margin_call_usd"] = (
        frame["repo_maturity_usd"]
        * scenario.collateral_call_rate
        * frame["funding_dependency_factor"]
    )
    frame["additional_collateral_demand_usd"] = (
        frame["additional_haircut_collateral_demand_usd"] + frame["additional_margin_call_usd"]
    )
    frame["incremental_repo_funding_stress_outflow_usd"] = (
        frame["repo_rollover_failure_outflow_usd"]
        + frame["incremental_funding_cost_usd"]
        + frame["additional_collateral_demand_usd"]
    )
    frame["cumulative_incremental_repo_funding_stress_outflow_usd"] = frame.groupby(
        "member_id",
        sort=False,
    )["incremental_repo_funding_stress_outflow_usd"].cumsum()
    frame["stressed_total_cash_outflow_usd"] = (
        frame["total_cash_outflow_usd"] + frame["incremental_repo_funding_stress_outflow_usd"]
    )
    frame["stressed_cumulative_net_liquidity_need_usd"] = (
        frame["cumulative_net_liquidity_need_usd"]
        + frame["cumulative_incremental_repo_funding_stress_outflow_usd"]
    )
    frame["stressed_liquidity_headroom_usd"] = (
        frame["cumulative_available_resources_usd"]
        - frame["stressed_cumulative_net_liquidity_need_usd"]
    )
    frame["stressed_liquidity_shortfall_usd"] = (-frame["stressed_liquidity_headroom_usd"]).clip(
        lower=0.0
    )
    frame["repo_rollover_failure_rate"] = scenario.repo_rollover_failure_rate
    frame["lender_withdrawal_rate"] = scenario.lender_withdrawal_rate
    frame["collateral_haircut_increase"] = scenario.collateral_haircut_increase
    frame["collateral_call_rate"] = scenario.collateral_call_rate
    frame["concentration_threshold"] = scenario.concentration_threshold
    frame["concentration_multiplier"] = scenario.concentration_multiplier
    frame["funding_dependency_multiplier"] = scenario.funding_dependency_multiplier
    frame["model_version"] = settings.model_version
    frame["value_class"] = "synthetic"
    frame["actual_ficc_participant"] = False
    frame["participant_level_inference"] = False
    return frame


def _member_summary(
    detailed: pd.DataFrame,
    settings: RepoFundingStressSettings,
) -> pd.DataFrame:
    rows: list[dict[str, object]] = []
    for (scenario_name, member_id), group in detailed.groupby(
        ["scenario_name", "member_id"],
        sort=True,
    ):
        ordered = group.sort_values("bucket_order", kind="stable")
        baseline_roll = float(ordered["repo_roll_amount_usd"].sum())
        failed_roll = float(ordered["repo_rollover_failure_outflow_usd"].sum())
        baseline_peak = float(ordered["cumulative_net_liquidity_need_usd"].max())
        stressed_peak = float(ordered["stressed_cumulative_net_liquidity_need_usd"].max())
        available_resources = float(ordered["cumulative_available_resources_usd"].max())
        stressed_shortfall = float(ordered["stressed_liquidity_shortfall_usd"].max())
        first_shortfall = ordered.loc[
            ordered["stressed_liquidity_shortfall_usd"] > settings.tolerance_usd,
            "time_bucket",
        ]
        rows.append(
            {
                "scenario_name": str(scenario_name),
                "severity_rank": int(ordered["severity_rank"].iloc[0]),
                "member_id": str(member_id),
                "reference_sofr_percent": float(ordered["reference_sofr_percent"].iloc[0]),
                "stressed_sofr_percent": float(ordered["stressed_sofr_percent"].iloc[0]),
                "stressed_all_in_rate_percent": float(
                    ordered["stressed_all_in_rate_percent"].iloc[0]
                ),
                "refinancing_horizon_hours": int(ordered["refinancing_horizon_hours"].iloc[0]),
                "member_concentration_ratio": float(ordered["member_concentration_ratio"].iloc[0]),
                "funding_dependency_ratio": float(ordered["funding_dependency_ratio"].iloc[0]),
                "net_repo_dependency_ratio": float(ordered["net_repo_dependency_ratio"].iloc[0]),
                "baseline_repo_maturity_usd": float(ordered["repo_maturity_usd"].sum()),
                "baseline_repo_roll_amount_usd": baseline_roll,
                "effective_funding_unavailability_rate": (
                    failed_roll / baseline_roll if baseline_roll > 0.0 else 0.0
                ),
                "repo_rollover_failure_outflow_usd": failed_roll,
                "incremental_funding_cost_usd": float(
                    ordered["incremental_funding_cost_usd"].sum()
                ),
                "additional_collateral_demand_usd": float(
                    ordered["additional_collateral_demand_usd"].sum()
                ),
                "incremental_repo_funding_stress_outflow_usd": float(
                    ordered["incremental_repo_funding_stress_outflow_usd"].sum()
                ),
                "baseline_peak_liquidity_need_usd": baseline_peak,
                "stressed_peak_liquidity_need_usd": stressed_peak,
                "available_resources_usd": available_resources,
                "baseline_minimum_liquidity_headroom_usd": float(
                    ordered["liquidity_headroom_usd"].min()
                ),
                "stressed_minimum_liquidity_headroom_usd": float(
                    ordered["stressed_liquidity_headroom_usd"].min()
                ),
                "maximum_stressed_liquidity_shortfall_usd": stressed_shortfall,
                "stressed_liquidity_coverage_ratio": (
                    available_resources / max(stressed_peak, 0.01)
                ),
                "first_stressed_shortfall_bucket": (
                    str(first_shortfall.iloc[0]) if not first_shortfall.empty else ""
                ),
                "funding_stress_status": (
                    "COVERED" if stressed_shortfall <= settings.tolerance_usd else "SHORTFALL"
                ),
                "model_version": settings.model_version,
                "value_class": "synthetic",
                "actual_ficc_participant": False,
                "participant_level_inference": False,
            }
        )
    return (
        pd.DataFrame.from_records(rows)
        .sort_values(
            ["severity_rank", "member_id"],
            kind="stable",
        )
        .reset_index(drop=True)
    )


def _scenario_summary(member_summary: pd.DataFrame) -> pd.DataFrame:
    rows: list[dict[str, object]] = []
    for scenario_name, group in member_summary.groupby("scenario_name", sort=True):
        rows.append(
            {
                "scenario_name": str(scenario_name),
                "severity_rank": int(group["severity_rank"].iloc[0]),
                "member_count": int(group["member_id"].nunique()),
                "reference_sofr_percent": float(group["reference_sofr_percent"].iloc[0]),
                "stressed_sofr_percent": float(group["stressed_sofr_percent"].iloc[0]),
                "stressed_all_in_rate_percent": float(
                    group["stressed_all_in_rate_percent"].iloc[0]
                ),
                "refinancing_horizon_hours": int(group["refinancing_horizon_hours"].iloc[0]),
                "baseline_repo_maturity_usd": float(group["baseline_repo_maturity_usd"].sum()),
                "repo_rollover_failure_outflow_usd": float(
                    group["repo_rollover_failure_outflow_usd"].sum()
                ),
                "incremental_funding_cost_usd": float(group["incremental_funding_cost_usd"].sum()),
                "additional_collateral_demand_usd": float(
                    group["additional_collateral_demand_usd"].sum()
                ),
                "incremental_repo_funding_stress_outflow_usd": float(
                    group["incremental_repo_funding_stress_outflow_usd"].sum()
                ),
                "aggregate_stressed_peak_liquidity_need_usd": float(
                    group["stressed_peak_liquidity_need_usd"].sum()
                ),
                "aggregate_maximum_stressed_shortfall_usd": float(
                    group["maximum_stressed_liquidity_shortfall_usd"].sum()
                ),
                "members_with_shortfall": int(group["funding_stress_status"].eq("SHORTFALL").sum()),
                "maximum_member_shortfall_usd": float(
                    group["maximum_stressed_liquidity_shortfall_usd"].max()
                ),
                "model_version": str(group["model_version"].iloc[0]),
                "value_class": "synthetic",
                "actual_ficc_participant": False,
                "participant_level_inference": False,
            }
        )
    return (
        pd.DataFrame.from_records(rows)
        .sort_values(
            "severity_rank",
            kind="stable",
        )
        .reset_index(drop=True)
    )


def calculate_repo_funding_stress(
    baseline: pd.DataFrame,
    members: pd.DataFrame,
    settings: RepoFundingStressSettings,
) -> tuple[pd.DataFrame, pd.DataFrame, pd.DataFrame]:
    """Apply every enabled scenario to Section 14 baseline cash flows."""
    prepared_baseline = prepare_baseline(baseline, settings)
    prepared_members = prepare_members(members, settings)
    member_ids = set(prepared_members["member_id"].astype(str))
    missing_members = sorted(set(prepared_baseline["member_id"].astype(str)) - member_ids)
    if missing_members:
        raise RepoFundingStressError(
            f"Baseline members are missing from member profiles: {missing_members}"
        )

    scenario_frames = [
        _scenario_frame(
            prepared_baseline,
            prepared_members,
            scenario,
            settings,
        )
        for scenario in settings.scenarios
    ]
    detailed = (
        pd.concat(scenario_frames, ignore_index=True)
        .sort_values(
            ["severity_rank", "member_id", "bucket_order"],
            kind="stable",
        )
        .reset_index(drop=True)
    )
    member_summary = _member_summary(detailed, settings)
    scenario_summary = _scenario_summary(member_summary)
    return detailed, member_summary, scenario_summary


def _within_tolerance(
    left: pd.Series,
    right: pd.Series,
    tolerance: float,
) -> bool:
    differences = (
        pd.to_numeric(left, errors="coerce") - pd.to_numeric(right, errors="coerce")
    ).abs()
    return bool(differences.le(tolerance).all())


def validate_results(
    baseline: pd.DataFrame,
    members: pd.DataFrame,
    detailed: pd.DataFrame,
    member_summary: pd.DataFrame,
    scenario_summary: pd.DataFrame,
    settings: RepoFundingStressSettings,
) -> ValidationResult:
    """Validate Section 16 mechanics, accounting identities, and scope controls."""
    prepared_baseline = prepare_baseline(baseline, settings)
    prepared_members = prepare_members(members, settings)
    expected_rows = len(prepared_baseline) * len(settings.scenarios)
    expected_member_rows = prepared_baseline["member_id"].nunique() * len(settings.scenarios)

    scenario_requirements = {
        "sofr_rate_spikes_implemented": any(
            scenario.sofr_spike_bp > 0.0 for scenario in settings.scenarios
        ),
        "funding_cost_increases_implemented": any(
            scenario.funding_spread_increase_bp > 0.0 for scenario in settings.scenarios
        ),
        "repo_rollover_failures_implemented": any(
            scenario.repo_rollover_failure_rate > 0.0 for scenario in settings.scenarios
        ),
        "partial_lender_withdrawal_implemented": any(
            scenario.lender_withdrawal_rate > 0.0 for scenario in settings.scenarios
        ),
        "shorter_refinancing_horizons_implemented": any(
            scenario.refinancing_horizon_hours < settings.baseline_liquidity_horizon_hours
            for scenario in settings.scenarios
        ),
        "increased_collateral_demands_implemented": any(
            scenario.collateral_haircut_increase > 0.0 or scenario.collateral_call_rate > 0.0
            for scenario in settings.scenarios
        ),
        "funding_concentration_implemented": any(
            scenario.concentration_multiplier > 0.0 for scenario in settings.scenarios
        ),
    }

    nonnegative_columns = [
        "repo_rollover_failure_outflow_usd",
        "successful_repo_refinancing_usd",
        "stressed_financing_outflow_usd",
        "incremental_funding_cost_usd",
        "additional_haircut_collateral_demand_usd",
        "additional_margin_call_usd",
        "additional_collateral_demand_usd",
        "incremental_repo_funding_stress_outflow_usd",
        "cumulative_incremental_repo_funding_stress_outflow_usd",
        "stressed_cumulative_net_liquidity_need_usd",
        "stressed_liquidity_shortfall_usd",
    ]
    nonnegative = bool((detailed[nonnegative_columns] >= -settings.tolerance_usd).all().all())
    rate_identity = _within_tolerance(
        detailed["stressed_sofr_percent"],
        detailed["reference_sofr_percent"] + detailed["sofr_spike_bp"] / 100.0,
        1e-12,
    )
    all_in_rate_identity = _within_tolerance(
        detailed["stressed_all_in_rate_percent"],
        detailed["stressed_sofr_percent"] + detailed["funding_spread_increase_bp"] / 100.0,
        1e-12,
    )
    rollover_bounded = bool(
        (
            detailed["repo_rollover_failure_outflow_usd"]
            <= detailed["repo_roll_amount_usd"] + settings.tolerance_usd
        ).all()
    )
    decomposition = _within_tolerance(
        detailed["incremental_repo_funding_stress_outflow_usd"],
        detailed["repo_rollover_failure_outflow_usd"]
        + detailed["incremental_funding_cost_usd"]
        + detailed["additional_collateral_demand_usd"],
        settings.tolerance_usd,
    )
    stressed_need_identity = _within_tolerance(
        detailed["stressed_cumulative_net_liquidity_need_usd"],
        detailed["cumulative_net_liquidity_need_usd"]
        + detailed["cumulative_incremental_repo_funding_stress_outflow_usd"],
        settings.tolerance_usd,
    )
    stressed_need_not_below_baseline = bool(
        (
            detailed["stressed_cumulative_net_liquidity_need_usd"] + settings.tolerance_usd
            >= detailed["cumulative_net_liquidity_need_usd"]
        ).all()
    )
    headroom_identity = _within_tolerance(
        detailed["stressed_liquidity_headroom_usd"],
        detailed["cumulative_available_resources_usd"]
        - detailed["stressed_cumulative_net_liquidity_need_usd"],
        settings.tolerance_usd,
    )
    shortfall_identity = _within_tolerance(
        detailed["stressed_liquidity_shortfall_usd"],
        (-detailed["stressed_liquidity_headroom_usd"]).clip(lower=0.0),
        settings.tolerance_usd,
    )
    synthetic_only = bool(
        detailed["value_class"].eq("synthetic").all()
        and not detailed["actual_ficc_participant"].astype(bool).any()
        and not detailed["participant_level_inference"].astype(bool).any()
        and member_summary["value_class"].eq("synthetic").all()
        and scenario_summary["value_class"].eq("synthetic").all()
        and len(prepared_members) >= prepared_baseline["member_id"].nunique()
    )

    checks = {
        **scenario_requirements,
        "scenario_cashflow_rows_complete": len(detailed) == expected_rows,
        "member_scenario_rows_complete": len(member_summary) == expected_member_rows,
        "scenario_summary_complete": len(scenario_summary) == len(settings.scenarios),
        "unique_scenario_member_buckets": not detailed.duplicated(
            ["scenario_name", "member_id", "time_bucket"]
        ).any(),
        "nonnegative_stress_components": nonnegative,
        "sofr_rate_identity": rate_identity,
        "all_in_funding_rate_identity": all_in_rate_identity,
        "rollover_failure_bounded_by_roll_amount": rollover_bounded,
        "funding_stress_decomposition_identity": decomposition,
        "stressed_liquidity_need_identity": stressed_need_identity,
        "stressed_need_not_below_baseline": stressed_need_not_below_baseline,
        "stressed_headroom_identity": headroom_identity,
        "stressed_shortfall_identity": shortfall_identity,
        "synthetic_members_only": synthetic_only,
    }
    return ValidationResult(checks=checks)


def run_model(
    baseline: pd.DataFrame,
    members: pd.DataFrame,
    config: Mapping[str, Any],
) -> tuple[pd.DataFrame, pd.DataFrame, pd.DataFrame, ValidationResult]:
    """Run the deterministic Section 16 model and validate all outputs."""
    settings = load_settings(config)
    detailed, member_summary, scenario_summary = calculate_repo_funding_stress(
        baseline,
        members,
        settings,
    )
    validation = validate_results(
        baseline,
        members,
        detailed,
        member_summary,
        scenario_summary,
        settings,
    )

    shuffled_baseline = baseline.sample(
        frac=1.0,
        random_state=2026,
    ).reset_index(drop=True)
    shuffled_members = members.sample(
        frac=1.0,
        random_state=2026,
    ).reset_index(drop=True)
    repeated = calculate_repo_funding_stress(
        shuffled_baseline,
        shuffled_members,
        settings,
    )
    deterministic = (
        detailed.equals(repeated[0])
        and member_summary.equals(repeated[1])
        and scenario_summary.equals(repeated[2])
    )
    checks = dict(validation.checks)
    checks["deterministic_reproduction"] = deterministic
    return detailed, member_summary, scenario_summary, ValidationResult(checks=checks)


__all__ = [
    "RepoFundingScenario",
    "RepoFundingStressError",
    "RepoFundingStressSettings",
    "ValidationResult",
    "calculate_repo_funding_stress",
    "load_config",
    "load_settings",
    "prepare_baseline",
    "prepare_members",
    "read_table",
    "run_model",
    "validate_results",
]
