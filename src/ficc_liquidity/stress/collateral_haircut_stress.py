"""Collateral haircut-stress model for synthetic clearing-member liquidity analysis.

Section 17 applies maturity-dependent, scenario-dependent, and concentration-
sensitive Treasury haircuts to fictional clearing-member collateral. The model
calculates additional collateral requirements, enforces available-collateral
constraints, and translates collateral deficits and resource erosion into
stressed liquidity coverage. It never identifies or infers an actual FICC
participant.
"""

from __future__ import annotations

import hashlib
import math
import re
from collections.abc import Mapping
from dataclasses import dataclass
from pathlib import Path
from typing import Any, cast

import pandas as pd
import yaml


class CollateralHaircutStressError(ValueError):
    """Raised when Section 17 inputs or assumptions are invalid."""


@dataclass(frozen=True, slots=True)
class MaturityHaircut:
    """Controlled maturity-bucket haircut assumptions."""

    name: str
    source_columns: tuple[str, ...]
    base_haircut_rate: float
    eligibility_factor: float


@dataclass(frozen=True, slots=True)
class HaircutScenario:
    """One controlled collateral haircut-stress scenario."""

    name: str
    severity_rank: int
    stress_multiplier: float
    additive_haircut_rate: float
    bucket_addons: Mapping[str, float]
    concentration_threshold: float
    concentration_multiplier: float
    additional_collateral_call_rate: float
    inventory_availability_rate: float
    maximum_haircut_rate: float


@dataclass(frozen=True, slots=True)
class CollateralHaircutStressSettings:
    """Validated Section 17 settings."""

    model_version: str
    tolerance_usd: float
    synthetic_id_pattern: str
    maturity_buckets: tuple[MaturityHaircut, ...]
    scenarios: tuple[HaircutScenario, ...]


@dataclass(frozen=True, slots=True)
class CollateralHaircutStressResult:
    """Section 17 model outputs and validation status."""

    bucket_results: pd.DataFrame
    member_summary: pd.DataFrame
    scenario_summary: pd.DataFrame
    checks: Mapping[str, bool]

    @property
    def passed(self) -> bool:
        """Return true only when every validation check passes."""
        return all(self.checks.values())


def _mapping(value: object, label: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise CollateralHaircutStressError(f"{label} must be a YAML mapping.")
    return cast(dict[str, Any], value)


def _number(mapping: Mapping[str, Any], key: str) -> float:
    value = mapping.get(key)
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise CollateralHaircutStressError(f"{key} must be numeric.")
    result = float(value)
    if not math.isfinite(result):
        raise CollateralHaircutStressError(f"{key} must be finite.")
    return result


def _integer(mapping: Mapping[str, Any], key: str) -> int:
    value = mapping.get(key)
    if isinstance(value, bool) or not isinstance(value, int):
        raise CollateralHaircutStressError(f"{key} must be an integer.")
    return int(value)


def _bounded_rate(value: float, label: str) -> None:
    if not 0.0 <= value <= 1.0:
        raise CollateralHaircutStressError(f"{label} must be between zero and one.")


def load_config(path: str | Path) -> dict[str, Any]:
    """Load a controlled Section 17 YAML configuration."""
    config_path = Path(path)
    if not config_path.exists():
        raise CollateralHaircutStressError(f"Configuration does not exist: {config_path}")
    loaded = yaml.safe_load(config_path.read_text(encoding="utf-8"))
    return _mapping(loaded, "Configuration")


def _load_maturity_bucket(name: str, raw: Mapping[str, Any]) -> MaturityHaircut:
    source_columns_raw = raw.get("source_columns")
    if not isinstance(source_columns_raw, list) or not source_columns_raw:
        raise CollateralHaircutStressError(
            f"maturity_buckets.{name}.source_columns must be a nonempty list."
        )
    source_columns = tuple(str(value).strip() for value in source_columns_raw)
    if any(not value for value in source_columns):
        raise CollateralHaircutStressError(
            f"maturity_buckets.{name}.source_columns contains an empty value."
        )
    bucket = MaturityHaircut(
        name=name,
        source_columns=source_columns,
        base_haircut_rate=_number(raw, "base_haircut_rate"),
        eligibility_factor=_number(raw, "eligibility_factor"),
    )
    _bounded_rate(bucket.base_haircut_rate, f"{name}.base_haircut_rate")
    _bounded_rate(bucket.eligibility_factor, f"{name}.eligibility_factor")
    if bucket.base_haircut_rate >= 1.0:
        raise CollateralHaircutStressError(f"{name}.base_haircut_rate must be below one.")
    return bucket


def _load_scenario(
    raw: Mapping[str, Any],
    bucket_names: tuple[str, ...],
) -> HaircutScenario:
    name = str(raw.get("name", "")).strip()
    if not name:
        raise CollateralHaircutStressError("Every scenario must have a nonempty name.")

    addons_raw = _mapping(raw.get("bucket_addons", {}), f"{name}.bucket_addons")
    unknown = sorted(set(addons_raw) - set(bucket_names))
    if unknown:
        raise CollateralHaircutStressError(
            f"{name}.bucket_addons contains unknown maturity buckets: {unknown}"
        )
    addons = {bucket: float(addons_raw.get(bucket, 0.0)) for bucket in bucket_names}
    if any(not math.isfinite(value) or value < 0.0 for value in addons.values()):
        raise CollateralHaircutStressError(
            f"{name}.bucket_addons must contain finite nonnegative rates."
        )

    scenario = HaircutScenario(
        name=name,
        severity_rank=_integer(raw, "severity_rank"),
        stress_multiplier=_number(raw, "stress_multiplier"),
        additive_haircut_rate=_number(raw, "additive_haircut_rate"),
        bucket_addons=addons,
        concentration_threshold=_number(raw, "concentration_threshold"),
        concentration_multiplier=_number(raw, "concentration_multiplier"),
        additional_collateral_call_rate=_number(raw, "additional_collateral_call_rate"),
        inventory_availability_rate=_number(raw, "inventory_availability_rate"),
        maximum_haircut_rate=_number(raw, "maximum_haircut_rate"),
    )
    if scenario.severity_rank < 0:
        raise CollateralHaircutStressError("severity_rank must be nonnegative.")
    for label, value in (
        ("additive_haircut_rate", scenario.additive_haircut_rate),
        ("concentration_threshold", scenario.concentration_threshold),
        ("additional_collateral_call_rate", scenario.additional_collateral_call_rate),
        ("inventory_availability_rate", scenario.inventory_availability_rate),
        ("maximum_haircut_rate", scenario.maximum_haircut_rate),
    ):
        _bounded_rate(value, f"{name}.{label}")
    if scenario.maximum_haircut_rate >= 1.0:
        raise CollateralHaircutStressError(f"{name}.maximum_haircut_rate must be below one.")
    if scenario.stress_multiplier < 1.0:
        raise CollateralHaircutStressError(f"{name}.stress_multiplier must be at least one.")
    if scenario.concentration_multiplier < 0.0:
        raise CollateralHaircutStressError(f"{name}.concentration_multiplier must be nonnegative.")
    return scenario


def load_settings(config: Mapping[str, Any]) -> CollateralHaircutStressSettings:
    """Validate and convert the Section 17 configuration."""
    maturity_raw = _mapping(config.get("maturity_buckets"), "maturity_buckets")
    if not maturity_raw:
        raise CollateralHaircutStressError("At least one maturity bucket is required.")
    maturity_buckets = tuple(
        _load_maturity_bucket(str(name), _mapping(raw, f"maturity_buckets.{name}"))
        for name, raw in maturity_raw.items()
    )
    bucket_names = tuple(bucket.name for bucket in maturity_buckets)

    scenarios_raw = config.get("scenarios")
    if not isinstance(scenarios_raw, list) or not scenarios_raw:
        raise CollateralHaircutStressError("scenarios must be a nonempty list.")
    scenarios = tuple(
        _load_scenario(_mapping(raw, "scenario"), bucket_names)
        for raw in scenarios_raw
        if bool(_mapping(raw, "scenario").get("enabled", True))
    )
    if not scenarios:
        raise CollateralHaircutStressError("At least one enabled scenario is required.")
    names = [scenario.name for scenario in scenarios]
    ranks = [scenario.severity_rank for scenario in scenarios]
    if len(set(names)) != len(names):
        raise CollateralHaircutStressError("Scenario names must be unique.")
    if len(set(ranks)) != len(ranks):
        raise CollateralHaircutStressError("Scenario severity ranks must be unique.")

    validation = _mapping(config.get("validation"), "validation")
    source = _mapping(config.get("source"), "source")
    settings = CollateralHaircutStressSettings(
        model_version=str(config.get("model_version", "section-17-v1")).strip(),
        tolerance_usd=_number(validation, "reconciliation_tolerance_usd"),
        synthetic_id_pattern=str(source.get("synthetic_id_pattern", r"^SYN-MBR-[0-9]{4}$")),
        maturity_buckets=maturity_buckets,
        scenarios=tuple(sorted(scenarios, key=lambda item: item.severity_rank)),
    )
    if not settings.model_version:
        raise CollateralHaircutStressError("model_version must be populated.")
    if settings.tolerance_usd < 0.0:
        raise CollateralHaircutStressError("reconciliation_tolerance_usd must be nonnegative.")

    previous: HaircutScenario | None = None
    for scenario in settings.scenarios:
        maximum_base = max(bucket.base_haircut_rate for bucket in maturity_buckets)
        if scenario.maximum_haircut_rate < maximum_base:
            raise CollateralHaircutStressError(
                f"{scenario.name}.maximum_haircut_rate cannot be below a base haircut."
            )
        if previous is not None:
            if scenario.stress_multiplier < previous.stress_multiplier:
                raise CollateralHaircutStressError(
                    "Scenario stress_multiplier must be nondecreasing by severity."
                )
            if scenario.additive_haircut_rate < previous.additive_haircut_rate:
                raise CollateralHaircutStressError(
                    "Scenario additive_haircut_rate must be nondecreasing by severity."
                )
            if scenario.additional_collateral_call_rate < previous.additional_collateral_call_rate:
                raise CollateralHaircutStressError(
                    "Additional collateral calls must be nondecreasing by severity."
                )
            if scenario.inventory_availability_rate > previous.inventory_availability_rate:
                raise CollateralHaircutStressError(
                    "Inventory availability cannot improve as severity increases."
                )
        previous = scenario
    return settings


def read_table(path: str | Path) -> pd.DataFrame:
    """Read a CSV or Parquet table."""
    table_path = Path(path)
    if not table_path.exists():
        raise CollateralHaircutStressError(f"Input table does not exist: {table_path}")
    if table_path.suffix.lower() == ".csv":
        return pd.read_csv(table_path)
    if table_path.suffix.lower() in {".parquet", ".pq"}:
        return pd.read_parquet(table_path)
    raise CollateralHaircutStressError("Input tables must be CSV or Parquet.")


def dataframe_digest(frame: pd.DataFrame) -> str:
    """Return a deterministic digest independent of input row order."""
    ordered_columns = sorted(str(column) for column in frame.columns)
    ordered = frame[ordered_columns].copy()
    sort_columns = [
        column
        for column in (
            "scenario_name",
            "member_id",
            "maturity_bucket",
            "bucket_order",
        )
        if column in ordered.columns
    ]
    if sort_columns:
        ordered = ordered.sort_values(sort_columns, kind="stable")
    payload = ordered.to_csv(index=False, float_format="%.12g").encode("utf-8")
    return hashlib.sha256(payload).hexdigest()


def _validate_identity(
    frame: pd.DataFrame,
    synthetic_id_pattern: str,
) -> None:
    if "member_id" not in frame.columns:
        raise CollateralHaircutStressError("Synthetic inputs require member_id.")
    member_ids = frame["member_id"].astype("string").str.strip()
    if member_ids.isna().any() or (member_ids == "").any():
        raise CollateralHaircutStressError("Synthetic member identifiers cannot be missing.")
    invalid = [
        member_id
        for member_id in member_ids.astype(str)
        if re.fullmatch(synthetic_id_pattern, member_id) is None
    ]
    if invalid:
        raise CollateralHaircutStressError(
            f"Non-synthetic or invalid member identifiers detected: {sorted(set(invalid))}"
        )
    if (
        "actual_ficc_participant" in frame.columns
        and frame["actual_ficc_participant"].fillna(False).astype(bool).any()
    ):
        raise CollateralHaircutStressError("Actual FICC participant records are prohibited.")
    if (
        "participant_level_inference" in frame.columns
        and frame["participant_level_inference"].fillna(False).astype(bool).any()
    ):
        raise CollateralHaircutStressError("Participant-level inference records are prohibited.")
    if (
        "value_class" in frame.columns
        and not frame["value_class"].astype(str).eq("synthetic").all()
    ):
        raise CollateralHaircutStressError("Every member record must use value_class='synthetic'.")


def _numeric_nonnegative(frame: pd.DataFrame, columns: list[str]) -> None:
    for column in columns:
        frame[column] = pd.to_numeric(frame[column], errors="coerce")
        if frame[column].isna().any() or (~frame[column].map(math.isfinite)).any():
            raise CollateralHaircutStressError(f"{column} contains missing or nonfinite values.")
        if (frame[column] < 0.0).any():
            raise CollateralHaircutStressError(f"{column} must be nonnegative.")


def _find_source_column(
    frame: pd.DataFrame,
    candidates: tuple[str, ...],
    bucket_name: str,
) -> str:
    lookup = {str(column).lower(): str(column) for column in frame.columns}
    for candidate in candidates:
        found = lookup.get(candidate.lower())
        if found is not None:
            return found
    raise CollateralHaircutStressError(
        f"No source column was found for maturity bucket {bucket_name}. "
        f"Expected one of {list(candidates)}."
    )


def prepare_members(
    members: pd.DataFrame,
    settings: CollateralHaircutStressSettings,
) -> pd.DataFrame:
    """Validate synthetic members and convert maturity positions to long form."""
    if members.empty:
        raise CollateralHaircutStressError("Synthetic member input is empty.")
    frame = members.copy(deep=True)
    frame["member_id"] = frame["member_id"].astype("string").str.strip()
    _validate_identity(frame, settings.synthetic_id_pattern)
    if frame["member_id"].duplicated().any():
        raise CollateralHaircutStressError("Synthetic member identifiers must be unique.")

    required_member_fields = [
        "repo_financing_need_usd",
        "collateral_inventory_usd",
        "available_qualified_liquid_resources_usd",
    ]
    missing = sorted(set(required_member_fields) - set(frame.columns))
    if missing:
        raise CollateralHaircutStressError(
            f"Required synthetic-member fields are missing: {missing}"
        )
    _numeric_nonnegative(frame, required_member_fields)

    source_by_bucket = {
        bucket.name: _find_source_column(frame, bucket.source_columns, bucket.name)
        for bucket in settings.maturity_buckets
    }
    _numeric_nonnegative(frame, list(source_by_bucket.values()))

    total_position = sum(
        (frame[source] for source in source_by_bucket.values()),
        start=pd.Series(0.0, index=frame.index),
    )
    if (total_position <= 0.0).any():
        raise CollateralHaircutStressError(
            "Every member must have a positive Treasury collateral position."
        )
    if "total_treasury_position_usd" in frame.columns:
        reported = pd.to_numeric(frame["total_treasury_position_usd"], errors="coerce")
        if reported.isna().any():
            raise CollateralHaircutStressError(
                "total_treasury_position_usd contains invalid values."
            )
        difference = (reported - total_position).abs()
        if (difference > max(settings.tolerance_usd, 5.0)).any():
            raise CollateralHaircutStressError(
                "Treasury maturity positions do not reconcile to the reported total."
            )

    parts: list[pd.DataFrame] = []
    for order, bucket in enumerate(settings.maturity_buckets, start=1):
        source = source_by_bucket[bucket.name]
        part = frame[
            [
                "member_id",
                "repo_financing_need_usd",
                "collateral_inventory_usd",
                "available_qualified_liquid_resources_usd",
            ]
        ].copy()
        part["maturity_bucket"] = bucket.name
        part["bucket_order"] = order
        part["source_column"] = source
        part["market_value_usd"] = frame[source].to_numpy()
        part["total_treasury_position_usd"] = total_position.to_numpy()
        part["bucket_weight"] = part["market_value_usd"] / part["total_treasury_position_usd"]
        part["base_haircut_rate"] = bucket.base_haircut_rate
        part["eligibility_factor"] = bucket.eligibility_factor
        parts.append(part)

    long = pd.concat(parts, ignore_index=True)
    long["member_concentration_ratio"] = long.groupby("member_id")["bucket_weight"].transform("max")
    long["repo_exposure_allocated_usd"] = long["repo_financing_need_usd"] * long["bucket_weight"]
    long["collateral_inventory_allocated_usd"] = (
        long["collateral_inventory_usd"] * long["bucket_weight"]
    ).clip(upper=long["market_value_usd"])
    long["qualified_resources_allocated_usd"] = (
        long["available_qualified_liquid_resources_usd"] * long["bucket_weight"]
    )
    long["value_class"] = "synthetic"
    long["actual_ficc_participant"] = False
    long["participant_level_inference"] = False

    weight_sums = long.groupby("member_id")["bucket_weight"].sum()
    if not weight_sums.map(lambda value: math.isclose(value, 1.0, abs_tol=1e-10)).all():
        raise CollateralHaircutStressError("Maturity-bucket weights do not reconcile to one.")
    return long.sort_values(["member_id", "bucket_order"], kind="stable").reset_index(drop=True)


def prepare_baseline(
    baseline: pd.DataFrame,
    settings: CollateralHaircutStressSettings,
) -> pd.DataFrame:
    """Select and validate the final Section 14 liquidity-horizon row per member."""
    if baseline.empty:
        raise CollateralHaircutStressError("Baseline liquidity input is empty.")
    required = {
        "member_id",
        "bucket_order",
        "time_bucket",
        "cumulative_net_liquidity_need_usd",
        "cumulative_available_resources_usd",
        "eligible_collateral_liquidity_usd",
        "available_cash_usd",
        "liquidity_headroom_usd",
        "liquidity_shortfall_usd",
    }
    missing = sorted(required - set(baseline.columns))
    if missing:
        raise CollateralHaircutStressError(
            f"Required baseline liquidity fields are missing: {missing}"
        )
    frame = baseline.copy(deep=True)
    frame["member_id"] = frame["member_id"].astype("string").str.strip()
    _validate_identity(frame, settings.synthetic_id_pattern)
    numeric = sorted(required - {"member_id", "time_bucket"})
    _numeric_nonnegative(
        frame,
        [column for column in numeric if column not in {"liquidity_headroom_usd"}],
    )
    frame["liquidity_headroom_usd"] = pd.to_numeric(
        frame["liquidity_headroom_usd"], errors="coerce"
    )
    if frame["liquidity_headroom_usd"].isna().any():
        raise CollateralHaircutStressError("liquidity_headroom_usd contains invalid values.")
    frame = frame.sort_values(["member_id", "bucket_order"], kind="stable").drop_duplicates(
        "member_id", keep="last"
    )
    if frame["member_id"].duplicated().any():
        raise CollateralHaircutStressError("Final baseline rows must be unique by member.")

    expected_headroom = (
        frame["cumulative_available_resources_usd"] - frame["cumulative_net_liquidity_need_usd"]
    )
    if ((expected_headroom - frame["liquidity_headroom_usd"]).abs() > settings.tolerance_usd).any():
        raise CollateralHaircutStressError("Baseline liquidity headroom identity failed.")
    expected_shortfall = (-expected_headroom).clip(lower=0.0)
    if (
        (expected_shortfall - frame["liquidity_shortfall_usd"]).abs() > settings.tolerance_usd
    ).any():
        raise CollateralHaircutStressError("Baseline liquidity shortfall identity failed.")

    selected = frame[
        [
            "member_id",
            "bucket_order",
            "time_bucket",
            "cumulative_net_liquidity_need_usd",
            "cumulative_available_resources_usd",
            "eligible_collateral_liquidity_usd",
            "available_cash_usd",
            "liquidity_headroom_usd",
            "liquidity_shortfall_usd",
        ]
    ].rename(
        columns={
            "bucket_order": "baseline_final_bucket_order",
            "time_bucket": "baseline_final_time_bucket",
            "cumulative_net_liquidity_need_usd": "baseline_liquidity_need_usd",
            "cumulative_available_resources_usd": "baseline_available_resources_usd",
            "eligible_collateral_liquidity_usd": "baseline_eligible_collateral_liquidity_usd",
            "available_cash_usd": "baseline_available_cash_usd",
            "liquidity_headroom_usd": "baseline_liquidity_headroom_usd",
            "liquidity_shortfall_usd": "baseline_liquidity_shortfall_usd",
        }
    )
    return selected.sort_values("member_id", kind="stable").reset_index(drop=True)


def _scenario_bucket_results(
    member_buckets: pd.DataFrame,
    scenario: HaircutScenario,
) -> pd.DataFrame:
    frame = member_buckets.copy(deep=True)
    frame["scenario_name"] = scenario.name
    frame["severity_rank"] = scenario.severity_rank
    frame["stress_multiplier"] = scenario.stress_multiplier
    frame["additive_haircut_rate"] = scenario.additive_haircut_rate
    frame["bucket_haircut_addon"] = frame["maturity_bucket"].map(scenario.bucket_addons)
    concentration_excess = (frame["bucket_weight"] - scenario.concentration_threshold).clip(
        lower=0.0
    )
    frame["concentration_threshold"] = scenario.concentration_threshold
    frame["concentration_excess"] = concentration_excess
    frame["concentration_haircut_addon"] = concentration_excess * scenario.concentration_multiplier
    frame["raw_stressed_haircut_rate"] = (
        frame["base_haircut_rate"] * scenario.stress_multiplier
        + scenario.additive_haircut_rate
        + frame["bucket_haircut_addon"]
        + frame["concentration_haircut_addon"]
    )
    frame["maximum_haircut_rate"] = scenario.maximum_haircut_rate
    frame["stressed_haircut_rate"] = (
        frame[["raw_stressed_haircut_rate", "base_haircut_rate"]]
        .max(axis=1)
        .clip(upper=scenario.maximum_haircut_rate)
    )
    frame["haircut_increase_rate"] = frame["stressed_haircut_rate"] - frame["base_haircut_rate"]

    frame["baseline_required_collateral_usd"] = frame["repo_exposure_allocated_usd"] / (
        1.0 - frame["base_haircut_rate"]
    )
    frame["stressed_required_collateral_before_call_usd"] = frame["repo_exposure_allocated_usd"] / (
        1.0 - frame["stressed_haircut_rate"]
    )
    frame["haircut_driven_collateral_call_usd"] = (
        frame["stressed_required_collateral_before_call_usd"]
        - frame["baseline_required_collateral_usd"]
    ).clip(lower=0.0)
    frame["additional_collateral_call_rate"] = scenario.additional_collateral_call_rate
    frame["scenario_additional_collateral_call_usd"] = (
        frame["repo_exposure_allocated_usd"] * scenario.additional_collateral_call_rate
    )
    frame["additional_collateral_requirement_usd"] = (
        frame["haircut_driven_collateral_call_usd"]
        + frame["scenario_additional_collateral_call_usd"]
    )

    frame["baseline_excess_collateral_inventory_usd"] = (
        frame["collateral_inventory_allocated_usd"] - frame["baseline_required_collateral_usd"]
    ).clip(lower=0.0)
    frame["baseline_eligible_excess_collateral_usd"] = (
        frame["baseline_excess_collateral_inventory_usd"] * frame["eligibility_factor"]
    )
    frame["inventory_availability_rate"] = scenario.inventory_availability_rate
    valuation_factor = (
        (1.0 - frame["stressed_haircut_rate"]) / (1.0 - frame["base_haircut_rate"])
    ).clip(lower=0.0, upper=1.0)
    frame["stressed_available_collateral_usd"] = (
        frame["baseline_eligible_excess_collateral_usd"]
        * scenario.inventory_availability_rate
        * valuation_factor
    )
    frame["collateral_posted_usd"] = frame[
        [
            "additional_collateral_requirement_usd",
            "stressed_available_collateral_usd",
        ]
    ].min(axis=1)
    frame["collateral_shortfall_usd"] = (
        frame["additional_collateral_requirement_usd"] - frame["collateral_posted_usd"]
    ).clip(lower=0.0)

    frame["haircut_market_value_loss_usd"] = (
        frame["market_value_usd"] * frame["haircut_increase_rate"]
    )
    frame["inventory_unavailability_loss_usd"] = (
        frame["baseline_eligible_excess_collateral_usd"]
        - frame["stressed_available_collateral_usd"]
    ).clip(lower=0.0)
    frame["gross_collateral_resource_reduction_usd"] = (
        frame["haircut_market_value_loss_usd"]
        + frame["inventory_unavailability_loss_usd"]
        + frame["collateral_posted_usd"]
    )
    frame["qualified_resource_reduction_usd"] = frame[
        [
            "gross_collateral_resource_reduction_usd",
            "qualified_resources_allocated_usd",
        ]
    ].min(axis=1)
    frame["stressed_qualified_resources_allocated_usd"] = (
        frame["qualified_resources_allocated_usd"] - frame["qualified_resource_reduction_usd"]
    ).clip(lower=0.0)
    frame["model_version"] = ""
    frame["value_class"] = "synthetic"
    frame["actual_ficc_participant"] = False
    frame["participant_level_inference"] = False
    return frame


def _build_member_summary(
    bucket_results: pd.DataFrame,
    baseline: pd.DataFrame,
    settings: CollateralHaircutStressSettings,
) -> pd.DataFrame:
    sum_columns = [
        "market_value_usd",
        "repo_exposure_allocated_usd",
        "collateral_inventory_allocated_usd",
        "qualified_resources_allocated_usd",
        "baseline_required_collateral_usd",
        "stressed_required_collateral_before_call_usd",
        "haircut_driven_collateral_call_usd",
        "scenario_additional_collateral_call_usd",
        "additional_collateral_requirement_usd",
        "baseline_excess_collateral_inventory_usd",
        "stressed_available_collateral_usd",
        "collateral_posted_usd",
        "collateral_shortfall_usd",
        "haircut_market_value_loss_usd",
        "inventory_unavailability_loss_usd",
        "gross_collateral_resource_reduction_usd",
        "qualified_resource_reduction_usd",
        "stressed_qualified_resources_allocated_usd",
    ]
    grouped = (
        bucket_results.groupby(
            ["scenario_name", "severity_rank", "member_id"],
            as_index=False,
            sort=True,
        )[sum_columns]
        .sum()
        .rename(
            columns={
                "market_value_usd": "total_treasury_collateral_market_value_usd",
                "repo_exposure_allocated_usd": "total_repo_exposure_usd",
                "collateral_inventory_allocated_usd": "treasury_collateral_inventory_usd",
                "qualified_resources_allocated_usd": "member_qualified_resources_usd",
                "baseline_required_collateral_usd": "baseline_required_collateral_total_usd",
                "stressed_required_collateral_before_call_usd": (
                    "stressed_required_collateral_total_usd"
                ),
                "additional_collateral_requirement_usd": (
                    "additional_collateral_requirement_total_usd"
                ),
                "stressed_available_collateral_usd": "available_collateral_to_meet_calls_usd",
                "collateral_posted_usd": "collateral_posted_total_usd",
                "collateral_shortfall_usd": "collateral_shortfall_total_usd",
                "qualified_resource_reduction_usd": "bucket_qualified_resource_reduction_usd",
                "stressed_qualified_resources_allocated_usd": (
                    "stressed_member_qualified_resources_usd"
                ),
            }
        )
    )
    summary = grouped.merge(
        baseline,
        on="member_id",
        how="left",
        validate="many_to_one",
    )
    if summary["baseline_liquidity_need_usd"].isna().any():
        raise CollateralHaircutStressError(
            "Every synthetic member must have a final baseline liquidity row."
        )

    summary["collateral_resource_reduction_usd"] = summary[
        [
            "bucket_qualified_resource_reduction_usd",
            "baseline_eligible_collateral_liquidity_usd",
        ]
    ].min(axis=1)
    summary["stressed_eligible_collateral_liquidity_usd"] = (
        summary["baseline_eligible_collateral_liquidity_usd"]
        - summary["collateral_resource_reduction_usd"]
    ).clip(lower=0.0)
    summary["stressed_available_resources_usd"] = (
        summary["baseline_available_resources_usd"] - summary["collateral_resource_reduction_usd"]
    ).clip(lower=0.0)
    summary["stressed_liquidity_need_usd"] = (
        summary["baseline_liquidity_need_usd"] + summary["collateral_shortfall_total_usd"]
    )
    summary["stressed_liquidity_headroom_usd"] = (
        summary["stressed_available_resources_usd"] - summary["stressed_liquidity_need_usd"]
    )
    summary["stressed_liquidity_shortfall_usd"] = (
        -summary["stressed_liquidity_headroom_usd"]
    ).clip(lower=0.0)
    denominator = summary["stressed_liquidity_need_usd"].replace(0.0, math.nan)
    summary["stressed_liquidity_coverage_ratio"] = (
        summary["stressed_available_resources_usd"] / denominator
    ).fillna(math.inf)
    summary["model_version"] = settings.model_version
    summary["value_class"] = "synthetic"
    summary["actual_ficc_participant"] = False
    summary["participant_level_inference"] = False
    return summary.sort_values(["severity_rank", "member_id"], kind="stable").reset_index(drop=True)


def _build_scenario_summary(member_summary: pd.DataFrame) -> pd.DataFrame:
    sum_columns = [
        "additional_collateral_requirement_total_usd",
        "collateral_posted_total_usd",
        "collateral_shortfall_total_usd",
        "collateral_resource_reduction_usd",
        "baseline_available_resources_usd",
        "stressed_available_resources_usd",
        "baseline_liquidity_need_usd",
        "stressed_liquidity_need_usd",
        "baseline_liquidity_shortfall_usd",
        "stressed_liquidity_shortfall_usd",
    ]
    summary = member_summary.groupby(
        ["scenario_name", "severity_rank"],
        as_index=False,
        sort=True,
    )[sum_columns].sum()
    member_metrics = member_summary.groupby(
        ["scenario_name", "severity_rank"], as_index=False, sort=True
    ).agg(
        member_count=("member_id", "nunique"),
        members_with_collateral_shortfall=(
            "collateral_shortfall_total_usd",
            lambda series: int((series > 0.0).sum()),
        ),
        members_with_liquidity_shortfall=(
            "stressed_liquidity_shortfall_usd",
            lambda series: int((series > 0.0).sum()),
        ),
        minimum_liquidity_coverage_ratio=(
            "stressed_liquidity_coverage_ratio",
            "min",
        ),
    )
    return (
        summary.merge(
            member_metrics,
            on=["scenario_name", "severity_rank"],
            how="left",
            validate="one_to_one",
        )
        .sort_values("severity_rank", kind="stable")
        .reset_index(drop=True)
    )


def validate_results(
    bucket_results: pd.DataFrame,
    member_summary: pd.DataFrame,
    scenario_summary: pd.DataFrame,
    member_buckets: pd.DataFrame,
    baseline: pd.DataFrame,
    settings: CollateralHaircutStressSettings,
) -> dict[str, bool]:
    """Run Section 17 accounting, constraint, and identity checks."""
    tolerance = settings.tolerance_usd
    expected_bucket_rows = len(member_buckets) * len(settings.scenarios)
    expected_member_rows = member_buckets["member_id"].nunique() * len(settings.scenarios)

    key_unique = not bucket_results.duplicated(
        ["scenario_name", "member_id", "maturity_bucket"]
    ).any()
    numeric_nonnegative = [
        "market_value_usd",
        "repo_exposure_allocated_usd",
        "collateral_inventory_allocated_usd",
        "baseline_required_collateral_usd",
        "stressed_required_collateral_before_call_usd",
        "additional_collateral_requirement_usd",
        "stressed_available_collateral_usd",
        "collateral_posted_usd",
        "collateral_shortfall_usd",
        "qualified_resource_reduction_usd",
    ]
    nonnegative = (bucket_results[numeric_nonnegative] >= -tolerance).all().all()
    finite = (
        bucket_results[numeric_nonnegative]
        .apply(lambda series: series.map(math.isfinite))
        .all()
        .all()
    )

    haircut_bounds = (
        (bucket_results["stressed_haircut_rate"] >= bucket_results["base_haircut_rate"] - 1e-12)
        & (
            bucket_results["stressed_haircut_rate"]
            <= bucket_results["maximum_haircut_rate"] + 1e-12
        )
        & (bucket_results["stressed_haircut_rate"] < 1.0)
    ).all()

    requirement_identity = (
        (
            bucket_results["additional_collateral_requirement_usd"]
            - bucket_results["haircut_driven_collateral_call_usd"]
            - bucket_results["scenario_additional_collateral_call_usd"]
        ).abs()
        <= tolerance
    ).all()
    constraint_identity = (
        (
            bucket_results["collateral_posted_usd"]
            <= bucket_results["stressed_available_collateral_usd"] + tolerance
        )
        & (
            (
                bucket_results["collateral_shortfall_usd"]
                - (
                    bucket_results["additional_collateral_requirement_usd"]
                    - bucket_results["collateral_posted_usd"]
                )
            ).abs()
            <= tolerance
        )
    ).all()

    member_liquidity_identity = (
        (
            member_summary["stressed_liquidity_headroom_usd"]
            - (
                member_summary["stressed_available_resources_usd"]
                - member_summary["stressed_liquidity_need_usd"]
            )
        ).abs()
        <= tolerance
    ).all() and (
        (
            member_summary["stressed_liquidity_shortfall_usd"]
            - (-member_summary["stressed_liquidity_headroom_usd"]).clip(lower=0.0)
        ).abs()
        <= tolerance
    ).all()

    control = member_summary.loc[member_summary["severity_rank"] == 0]
    control_zero = (
        not control.empty
        and (control["additional_collateral_requirement_total_usd"].abs() <= tolerance).all()
        and (control["collateral_resource_reduction_usd"].abs() <= tolerance).all()
        and (
            (
                control["stressed_available_resources_usd"]
                - control["baseline_available_resources_usd"]
            ).abs()
            <= tolerance
        ).all()
    )

    haircut_monotonic = True
    for _, group in bucket_results.sort_values("severity_rank").groupby(
        ["member_id", "maturity_bucket"], sort=False
    ):
        if (group["stressed_haircut_rate"].diff().dropna() < -1e-12).any():
            haircut_monotonic = False
            break

    synthetic_only = (
        bucket_results["member_id"]
        .astype(str)
        .map(lambda value: re.fullmatch(settings.synthetic_id_pattern, value) is not None)
        .all()
        and not bucket_results["actual_ficc_participant"].astype(bool).any()
        and not bucket_results["participant_level_inference"].astype(bool).any()
    )

    scenario_aggregates = len(scenario_summary) == len(settings.scenarios) and scenario_summary[
        "scenario_name"
    ].nunique() == len(settings.scenarios)
    baseline_complete = set(member_buckets["member_id"]) == set(baseline["member_id"])

    return {
        "complete_bucket_matrix": len(bucket_results) == expected_bucket_rows,
        "complete_member_matrix": len(member_summary) == expected_member_rows,
        "unique_bucket_keys": key_unique,
        "finite_nonnegative_amounts": bool(finite and nonnegative),
        "haircut_bounds": bool(haircut_bounds),
        "additional_requirement_identity": bool(requirement_identity),
        "available_collateral_constraint": bool(constraint_identity),
        "liquidity_identities": bool(member_liquidity_identity),
        "zero_shock_control": bool(control_zero),
        "severity_monotonicity": bool(haircut_monotonic),
        "scenario_aggregation_complete": bool(scenario_aggregates),
        "baseline_member_coverage": bool(baseline_complete),
        "synthetic_identity_controls": bool(synthetic_only),
    }


def calculate_collateral_haircut_stress(
    members: pd.DataFrame,
    baseline: pd.DataFrame,
    settings: CollateralHaircutStressSettings,
) -> CollateralHaircutStressResult:
    """Calculate controlled Section 17 haircut stress."""
    member_buckets = prepare_members(members, settings)
    baseline_final = prepare_baseline(baseline, settings)

    scenario_frames = [
        _scenario_bucket_results(member_buckets, scenario) for scenario in settings.scenarios
    ]
    bucket_results = pd.concat(scenario_frames, ignore_index=True)
    bucket_results["model_version"] = settings.model_version
    bucket_results = bucket_results.sort_values(
        ["severity_rank", "member_id", "bucket_order"], kind="stable"
    ).reset_index(drop=True)

    member_summary = _build_member_summary(
        bucket_results,
        baseline_final,
        settings,
    )
    scenario_summary = _build_scenario_summary(member_summary)
    checks = validate_results(
        bucket_results,
        member_summary,
        scenario_summary,
        member_buckets,
        baseline_final,
        settings,
    )
    return CollateralHaircutStressResult(
        bucket_results=bucket_results,
        member_summary=member_summary,
        scenario_summary=scenario_summary,
        checks=checks,
    )


def run_model(
    members: pd.DataFrame,
    baseline: pd.DataFrame,
    config: Mapping[str, Any],
) -> CollateralHaircutStressResult:
    """Load settings and execute the Section 17 model."""
    return calculate_collateral_haircut_stress(
        members,
        baseline,
        load_settings(config),
    )
