"""Integrated stressed-liquidity requirement for synthetic clearing members.

Section 19 combines atomic outputs from Sections 14 through 18 without adding
composite totals that would duplicate their constituent stress components.
"""

from __future__ import annotations

import hashlib
import math
import re
from collections.abc import Mapping
from dataclasses import dataclass
from pathlib import Path
from typing import Any, cast

import numpy as np
import pandas as pd
import yaml


class IntegratedStressError(ValueError):
    """Raised when Section 19 configuration, inputs, or identities are invalid."""


ATOMIC_COMPONENT_COLUMNS: tuple[str, ...] = (
    "settlement_liquidity_need_usd",
    "repo_rollover_need_usd",
    "incremental_funding_cost_usd",
    "additional_haircut_requirement_usd",
    "treasury_liquidation_loss_usd",
    "settlement_fail_requirement_usd",
)
REQUIRED_COMPONENT_COLUMNS: tuple[str, ...] = (
    *ATOMIC_COMPONENT_COLUMNS,
    "concentration_adjustment_usd",
    "operational_liquidity_buffer_usd",
)


@dataclass(frozen=True, slots=True)
class IntegratedScenario:
    """One controlled integrated-liquidity scenario."""

    name: str
    severity_rank: int
    funding_scenario_name: str
    haircut_scenario_name: str
    treasury_scenario_name: str
    settlement_fail_scenario_name: str
    concentration_threshold: float
    concentration_multiplier: float
    operational_liquidity_buffer_rate: float


@dataclass(frozen=True, slots=True)
class IntegratedStressSettings:
    """Validated Section 19 settings."""

    model_version: str
    tolerance_usd: float
    lcr_minimum_ratio: float
    synthetic_id_pattern: str
    concentration_base_components: tuple[str, ...]
    scenarios: tuple[IntegratedScenario, ...]


@dataclass(frozen=True, slots=True)
class IntegratedStressResult:
    """Section 19 member results, summaries, controls, and validation checks."""

    member_results: pd.DataFrame
    scenario_summary: pd.DataFrame
    double_count_controls: pd.DataFrame
    checks: Mapping[str, bool]

    @property
    def passed(self) -> bool:
        """Return true only when every Section 19 validation check passes."""
        return all(self.checks.values())


def _mapping(value: object, label: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise IntegratedStressError(f"{label} must be a YAML mapping.")
    return cast(dict[str, Any], value)


def _number(mapping: Mapping[str, Any], key: str) -> float:
    value = mapping.get(key)
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise IntegratedStressError(f"{key} must be numeric.")
    result = float(value)
    if not math.isfinite(result):
        raise IntegratedStressError(f"{key} must be finite.")
    return result


def _integer(mapping: Mapping[str, Any], key: str) -> int:
    value = mapping.get(key)
    if isinstance(value, bool) or not isinstance(value, int):
        raise IntegratedStressError(f"{key} must be an integer.")
    return int(value)


def _bounded_rate(value: float, label: str) -> None:
    if not 0.0 <= value <= 1.0:
        raise IntegratedStressError(f"{label} must be between zero and one.")


def load_config(path: str | Path) -> dict[str, Any]:
    """Load a controlled Section 19 YAML configuration."""
    config_path = Path(path)
    if not config_path.exists():
        raise IntegratedStressError(f"Configuration does not exist: {config_path}")
    loaded = yaml.safe_load(config_path.read_text(encoding="utf-8"))
    return _mapping(loaded, "Configuration")


def _load_scenario(raw: Mapping[str, Any]) -> IntegratedScenario:
    scenario = IntegratedScenario(
        name=str(raw.get("name", "")).strip(),
        severity_rank=_integer(raw, "severity_rank"),
        funding_scenario_name=str(raw.get("funding_scenario_name", "")).strip(),
        haircut_scenario_name=str(raw.get("haircut_scenario_name", "")).strip(),
        treasury_scenario_name=str(raw.get("treasury_scenario_name", "")).strip(),
        settlement_fail_scenario_name=str(raw.get("settlement_fail_scenario_name", "")).strip(),
        concentration_threshold=_number(raw, "concentration_threshold"),
        concentration_multiplier=_number(raw, "concentration_multiplier"),
        operational_liquidity_buffer_rate=_number(raw, "operational_liquidity_buffer_rate"),
    )
    if not scenario.name:
        raise IntegratedStressError("Every scenario must have a nonempty name.")
    if scenario.severity_rank < 0:
        raise IntegratedStressError("severity_rank must be nonnegative.")
    for label, rate_value in (
        ("concentration_threshold", scenario.concentration_threshold),
        (
            "operational_liquidity_buffer_rate",
            scenario.operational_liquidity_buffer_rate,
        ),
    ):
        _bounded_rate(rate_value, f"{scenario.name}.{label}")
    if scenario.concentration_multiplier < 0.0:
        raise IntegratedStressError(
            f"{scenario.name}.concentration_multiplier must be nonnegative."
        )
    for label, scenario_name_value in (
        ("funding_scenario_name", scenario.funding_scenario_name),
        ("haircut_scenario_name", scenario.haircut_scenario_name),
        ("treasury_scenario_name", scenario.treasury_scenario_name),
        ("settlement_fail_scenario_name", scenario.settlement_fail_scenario_name),
    ):
        if not scenario_name_value:
            raise IntegratedStressError(f"{scenario.name}.{label} cannot be empty.")
    return scenario


def load_settings(config: Mapping[str, Any]) -> IntegratedStressSettings:
    """Validate and convert the Section 19 configuration."""
    source = _mapping(config.get("source"), "source")
    integration = _mapping(config.get("integration"), "integration")
    validation = _mapping(config.get("validation"), "validation")
    raw_components = integration.get("concentration_base_components")
    if not isinstance(raw_components, list) or not raw_components:
        raise IntegratedStressError(
            "integration.concentration_base_components must be a nonempty list."
        )
    concentration_base_components = tuple(str(value).strip() for value in raw_components)
    if any(not value for value in concentration_base_components):
        raise IntegratedStressError(
            "integration.concentration_base_components cannot contain empty values."
        )
    unknown_components = sorted(set(concentration_base_components) - set(ATOMIC_COMPONENT_COLUMNS))
    if unknown_components:
        raise IntegratedStressError(
            f"Concentration adjustment contains unsupported component columns: {unknown_components}"
        )
    if len(set(concentration_base_components)) != len(concentration_base_components):
        raise IntegratedStressError("Concentration base component names must be unique.")

    raw_scenarios = config.get("scenarios")
    if not isinstance(raw_scenarios, list) or not raw_scenarios:
        raise IntegratedStressError("scenarios must be a nonempty list.")
    scenarios = tuple(
        sorted(
            (
                _load_scenario(_mapping(raw, "scenario"))
                for raw in raw_scenarios
                if bool(_mapping(raw, "scenario").get("enabled", True))
            ),
            key=lambda item: item.severity_rank,
        )
    )
    if not scenarios:
        raise IntegratedStressError("At least one enabled scenario is required.")
    if len({item.name for item in scenarios}) != len(scenarios):
        raise IntegratedStressError("Scenario names must be unique.")
    if len({item.severity_rank for item in scenarios}) != len(scenarios):
        raise IntegratedStressError("Scenario severity ranks must be unique.")

    settings = IntegratedStressSettings(
        model_version=str(config.get("model_version", "section-19-v1")).strip(),
        tolerance_usd=_number(validation, "reconciliation_tolerance_usd"),
        lcr_minimum_ratio=_number(integration, "lcr_minimum_ratio"),
        synthetic_id_pattern=str(source.get("synthetic_id_pattern", r"^SYN-MBR-[0-9]{4}$")),
        concentration_base_components=concentration_base_components,
        scenarios=scenarios,
    )
    if not settings.model_version:
        raise IntegratedStressError("model_version must be populated.")
    if settings.tolerance_usd < 0.0:
        raise IntegratedStressError("reconciliation_tolerance_usd must be nonnegative.")
    if settings.lcr_minimum_ratio <= 0.0:
        raise IntegratedStressError("lcr_minimum_ratio must be positive.")

    previous: IntegratedScenario | None = None
    for scenario in scenarios:
        if previous is not None:
            if scenario.concentration_multiplier < previous.concentration_multiplier:
                raise IntegratedStressError(
                    "concentration_multiplier must be nondecreasing by severity."
                )
            if (
                scenario.operational_liquidity_buffer_rate
                < previous.operational_liquidity_buffer_rate
            ):
                raise IntegratedStressError(
                    "operational_liquidity_buffer_rate must be nondecreasing by severity."
                )
            if scenario.concentration_threshold > previous.concentration_threshold:
                raise IntegratedStressError(
                    "concentration_threshold cannot increase with severity."
                )
        previous = scenario
    return settings


def read_table(path: str | Path) -> pd.DataFrame:
    """Read a CSV or Parquet input table."""
    table_path = Path(path)
    if not table_path.exists():
        raise IntegratedStressError(f"Input table does not exist: {table_path}")
    if table_path.suffix.lower() == ".csv":
        return pd.read_csv(table_path)
    if table_path.suffix.lower() in {".parquet", ".pq"}:
        return pd.read_parquet(table_path)
    raise IntegratedStressError("Input tables must be CSV or Parquet.")


def dataframe_digest(frame: pd.DataFrame) -> str:
    """Return a deterministic SHA-256 digest independent of row order."""
    ordered = frame.sort_index(axis=1)
    sort_columns = [
        column
        for column in ("severity_rank", "scenario_name", "member_id")
        if column in ordered.columns
    ]
    if sort_columns:
        ordered = ordered.sort_values(sort_columns, kind="stable")
    payload = ordered.to_csv(index=False, float_format="%.12g").encode("utf-8")
    return hashlib.sha256(payload).hexdigest()


def _require_columns(
    frame: pd.DataFrame,
    required: set[str],
    label: str,
) -> None:
    missing = sorted(required - set(frame.columns))
    if missing:
        raise IntegratedStressError(f"{label} is missing required fields: {missing}")


def _validate_identity(
    frame: pd.DataFrame,
    synthetic_id_pattern: str,
    label: str,
) -> None:
    if "member_id" not in frame.columns:
        raise IntegratedStressError(f"{label} requires member_id.")
    member_ids = frame["member_id"].astype("string").str.strip()
    if member_ids.isna().any() or (member_ids == "").any():
        raise IntegratedStressError(f"{label} contains missing member identifiers.")
    invalid = [
        member_id
        for member_id in member_ids.astype(str)
        if re.fullmatch(synthetic_id_pattern, member_id) is None
    ]
    if invalid:
        raise IntegratedStressError(
            f"{label} contains non-synthetic identifiers: {sorted(set(invalid))}"
        )
    if (
        "actual_ficc_participant" in frame.columns
        and frame["actual_ficc_participant"].fillna(False).astype(bool).any()
    ):
        raise IntegratedStressError(f"{label} contains prohibited actual-participant records.")
    if (
        "participant_level_inference" in frame.columns
        and frame["participant_level_inference"].fillna(False).astype(bool).any()
    ):
        raise IntegratedStressError(f"{label} contains prohibited participant-level inference.")
    if (
        "value_class" in frame.columns
        and not frame["value_class"].astype(str).eq("synthetic").all()
    ):
        raise IntegratedStressError(f"{label} requires value_class='synthetic' for every record.")


def _numeric(
    frame: pd.DataFrame,
    columns: list[str],
    *,
    nonnegative: bool,
    label: str,
) -> None:
    for column in columns:
        frame[column] = pd.to_numeric(frame[column], errors="coerce")
        finite = frame[column].map(math.isfinite)
        if frame[column].isna().any() or not bool(finite.all()):
            raise IntegratedStressError(f"{label}.{column} contains missing or nonfinite values.")
        if nonnegative and bool((frame[column] < 0.0).any()):
            raise IntegratedStressError(f"{label}.{column} must be nonnegative.")


def prepare_baseline_summary(
    baseline: pd.DataFrame,
    settings: IntegratedStressSettings,
) -> pd.DataFrame:
    """Validate and canonicalize Section 14 member-level baseline data."""
    if baseline.empty:
        raise IntegratedStressError("Section 14 baseline summary is empty.")
    required = {
        "member_id",
        "net_settlement_outflow_usd",
        "modeled_aqlr_usd",
    }
    _require_columns(baseline, required, "Section 14 baseline summary")
    frame = baseline.copy(deep=True)
    frame["member_id"] = frame["member_id"].astype("string").str.strip()
    _validate_identity(frame, settings.synthetic_id_pattern, "Section 14 baseline summary")
    if bool(frame["member_id"].duplicated().any()):
        raise IntegratedStressError("Section 14 baseline summary must be unique by member_id.")
    _numeric(
        frame,
        ["net_settlement_outflow_usd", "modeled_aqlr_usd"],
        nonnegative=True,
        label="Section 14 baseline summary",
    )
    selected = frame[["member_id", "net_settlement_outflow_usd", "modeled_aqlr_usd"]].rename(
        columns={
            "net_settlement_outflow_usd": "settlement_liquidity_need_usd",
            "modeled_aqlr_usd": "available_qualified_liquid_resources_usd",
        }
    )
    return selected.sort_values("member_id", kind="stable").reset_index(drop=True)


def prepare_funding_summary(
    funding: pd.DataFrame,
    settings: IntegratedStressSettings,
) -> pd.DataFrame:
    """Validate atomic Section 16 funding-stress components."""
    if funding.empty:
        raise IntegratedStressError("Section 16 funding summary is empty.")
    required = {
        "scenario_name",
        "member_id",
        "repo_rollover_failure_outflow_usd",
        "incremental_funding_cost_usd",
        "member_concentration_ratio",
    }
    _require_columns(funding, required, "Section 16 funding summary")
    frame = funding.copy(deep=True)
    frame["scenario_name"] = frame["scenario_name"].astype("string").str.strip()
    frame["member_id"] = frame["member_id"].astype("string").str.strip()
    _validate_identity(frame, settings.synthetic_id_pattern, "Section 16 funding summary")
    if bool(frame.duplicated(["scenario_name", "member_id"]).any()):
        raise IntegratedStressError(
            "Section 16 funding summary must be unique by scenario and member."
        )
    optional = {
        "additional_collateral_demand_usd": 0.0,
        "incremental_repo_funding_stress_outflow_usd": np.nan,
    }
    for column, default in optional.items():
        if column not in frame.columns:
            frame[column] = default
    numeric_columns = [
        "repo_rollover_failure_outflow_usd",
        "incremental_funding_cost_usd",
        "member_concentration_ratio",
        "additional_collateral_demand_usd",
    ]
    _numeric(
        frame,
        numeric_columns,
        nonnegative=True,
        label="Section 16 funding summary",
    )
    if bool((frame["member_concentration_ratio"] > 1.0).any()):
        raise IntegratedStressError("Section 16 member_concentration_ratio must not exceed one.")
    if frame["incremental_repo_funding_stress_outflow_usd"].isna().all():
        frame["incremental_repo_funding_stress_outflow_usd"] = (
            frame["repo_rollover_failure_outflow_usd"]
            + frame["incremental_funding_cost_usd"]
            + frame["additional_collateral_demand_usd"]
        )
    _numeric(
        frame,
        ["incremental_repo_funding_stress_outflow_usd"],
        nonnegative=True,
        label="Section 16 funding summary",
    )
    return frame.sort_values(["scenario_name", "member_id"], kind="stable").reset_index(drop=True)


def prepare_haircut_summary(
    haircut: pd.DataFrame,
    settings: IntegratedStressSettings,
) -> pd.DataFrame:
    """Validate Section 17 additional-collateral requirements."""
    if haircut.empty:
        raise IntegratedStressError("Section 17 haircut summary is empty.")
    required = {
        "scenario_name",
        "member_id",
        "additional_collateral_requirement_total_usd",
    }
    _require_columns(haircut, required, "Section 17 haircut summary")
    frame = haircut.copy(deep=True)
    frame["scenario_name"] = frame["scenario_name"].astype("string").str.strip()
    frame["member_id"] = frame["member_id"].astype("string").str.strip()
    _validate_identity(frame, settings.synthetic_id_pattern, "Section 17 haircut summary")
    if bool(frame.duplicated(["scenario_name", "member_id"]).any()):
        raise IntegratedStressError(
            "Section 17 haircut summary must be unique by scenario and member."
        )
    for column in (
        "bucket_qualified_resource_reduction_usd",
        "stressed_member_qualified_resources_usd",
    ):
        if column not in frame.columns:
            frame[column] = 0.0
    _numeric(
        frame,
        [
            "additional_collateral_requirement_total_usd",
            "bucket_qualified_resource_reduction_usd",
            "stressed_member_qualified_resources_usd",
        ],
        nonnegative=True,
        label="Section 17 haircut summary",
    )
    return frame.sort_values(["scenario_name", "member_id"], kind="stable").reset_index(drop=True)


def prepare_treasury_summary(
    treasury: pd.DataFrame,
    settings: IntegratedStressSettings,
) -> pd.DataFrame:
    """Validate Section 15 member-level Treasury losses."""
    if treasury.empty:
        raise IntegratedStressError("Section 15 Treasury summary is empty.")
    required = {"scenario_name", "member_id", "treasury_loss_usd"}
    _require_columns(treasury, required, "Section 15 Treasury summary")
    frame = treasury.copy(deep=True)
    frame["scenario_name"] = frame["scenario_name"].astype("string").str.strip()
    frame["member_id"] = frame["member_id"].astype("string").str.strip()
    _validate_identity(frame, settings.synthetic_id_pattern, "Section 15 Treasury summary")
    if bool(frame.duplicated(["scenario_name", "member_id"]).any()):
        raise IntegratedStressError(
            "Section 15 Treasury summary must be unique by scenario and member."
        )
    _numeric(
        frame,
        ["treasury_loss_usd"],
        nonnegative=True,
        label="Section 15 Treasury summary",
    )
    return frame.sort_values(["scenario_name", "member_id"], kind="stable").reset_index(drop=True)


def prepare_settlement_fail_summary(
    settlement_fail: pd.DataFrame,
    settings: IntegratedStressSettings,
) -> pd.DataFrame:
    """Aggregate Section 18 settlement-only stress while excluding funding composites."""
    if settlement_fail.empty:
        raise IntegratedStressError("Section 18 settlement-fail cash flows are empty.")
    required = {
        "scenario_name",
        "member_id",
        "incremental_settlement_fail_outflow_usd",
    }
    _require_columns(settlement_fail, required, "Section 18 settlement-fail cash flows")
    frame = settlement_fail.copy(deep=True)
    frame["scenario_name"] = frame["scenario_name"].astype("string").str.strip()
    frame["member_id"] = frame["member_id"].astype("string").str.strip()
    _validate_identity(
        frame, settings.synthetic_id_pattern, "Section 18 settlement-fail cash flows"
    )
    if "time_bucket" in frame.columns and bool(
        frame.duplicated(["scenario_name", "member_id", "time_bucket"]).any()
    ):
        raise IntegratedStressError(
            "Section 18 scenario, member, and time-bucket keys must be unique."
        )
    optional = {
        "combined_funding_shock_outflow_usd": 0.0,
        "incremental_combined_stress_outflow_usd": np.nan,
    }
    for column, default in optional.items():
        if column not in frame.columns:
            frame[column] = default
    _numeric(
        frame,
        [
            "incremental_settlement_fail_outflow_usd",
            "combined_funding_shock_outflow_usd",
        ],
        nonnegative=True,
        label="Section 18 settlement-fail cash flows",
    )
    if frame["incremental_combined_stress_outflow_usd"].isna().all():
        frame["incremental_combined_stress_outflow_usd"] = (
            frame["incremental_settlement_fail_outflow_usd"]
            + frame["combined_funding_shock_outflow_usd"]
        )
    _numeric(
        frame,
        ["incremental_combined_stress_outflow_usd"],
        nonnegative=True,
        label="Section 18 settlement-fail cash flows",
    )
    summary = (
        frame.groupby(["scenario_name", "member_id"], as_index=False, sort=True)
        .agg(
            incremental_settlement_fail_outflow_usd=(
                "incremental_settlement_fail_outflow_usd",
                "sum",
            ),
            combined_funding_shock_outflow_usd=(
                "combined_funding_shock_outflow_usd",
                "sum",
            ),
            incremental_combined_stress_outflow_usd=(
                "incremental_combined_stress_outflow_usd",
                "sum",
            ),
        )
        .reset_index(drop=True)
    )
    return summary


def _select_scenario(
    frame: pd.DataFrame,
    scenario_name: str,
    label: str,
) -> pd.DataFrame:
    selected = frame.loc[frame["scenario_name"].astype(str).eq(scenario_name)].copy()
    if selected.empty:
        raise IntegratedStressError(f"{label} scenario was not found: {scenario_name}")
    return selected


def _merge_component(
    base: pd.DataFrame,
    component: pd.DataFrame,
    columns: list[str],
    label: str,
) -> pd.DataFrame:
    selected = component[["member_id", *columns]]
    merged = base.merge(selected, on="member_id", how="left", validate="one_to_one")
    if bool(merged[columns].isna().any().any()):
        missing_members = sorted(
            merged.loc[merged[columns].isna().any(axis=1), "member_id"].astype(str)
        )
        raise IntegratedStressError(f"{label} is missing mapped members: {missing_members}")
    return merged


def _scenario_member_results(
    baseline: pd.DataFrame,
    funding: pd.DataFrame,
    haircut: pd.DataFrame,
    treasury: pd.DataFrame,
    settlement_fail: pd.DataFrame,
    scenario: IntegratedScenario,
    settings: IntegratedStressSettings,
) -> pd.DataFrame:
    frame = baseline.copy(deep=True)

    funding_selected = _select_scenario(
        funding, scenario.funding_scenario_name, "Section 16 funding"
    ).rename(
        columns={
            "repo_rollover_failure_outflow_usd": "repo_rollover_need_usd",
            "additional_collateral_demand_usd": (
                "excluded_section16_additional_collateral_demand_usd"
            ),
            "incremental_repo_funding_stress_outflow_usd": (
                "excluded_section16_composite_outflow_usd"
            ),
        }
    )
    frame = _merge_component(
        frame,
        funding_selected,
        [
            "repo_rollover_need_usd",
            "incremental_funding_cost_usd",
            "member_concentration_ratio",
            "excluded_section16_additional_collateral_demand_usd",
            "excluded_section16_composite_outflow_usd",
        ],
        "Section 16 funding",
    )

    haircut_selected = _select_scenario(
        haircut, scenario.haircut_scenario_name, "Section 17 haircut"
    ).rename(
        columns={
            "additional_collateral_requirement_total_usd": ("additional_haircut_requirement_usd"),
            "bucket_qualified_resource_reduction_usd": ("excluded_section17_aqlr_reduction_usd"),
        }
    )
    frame = _merge_component(
        frame,
        haircut_selected,
        [
            "additional_haircut_requirement_usd",
            "excluded_section17_aqlr_reduction_usd",
        ],
        "Section 17 haircut",
    )

    if scenario.treasury_scenario_name.upper() == "NONE":
        frame["treasury_liquidation_loss_usd"] = 0.0
    else:
        treasury_selected = _select_scenario(
            treasury, scenario.treasury_scenario_name, "Section 15 Treasury"
        ).rename(columns={"treasury_loss_usd": "treasury_liquidation_loss_usd"})
        frame = _merge_component(
            frame,
            treasury_selected,
            ["treasury_liquidation_loss_usd"],
            "Section 15 Treasury",
        )

    settlement_selected = _select_scenario(
        settlement_fail,
        scenario.settlement_fail_scenario_name,
        "Section 18 settlement-fail",
    ).rename(
        columns={
            "incremental_settlement_fail_outflow_usd": ("settlement_fail_requirement_usd"),
            "combined_funding_shock_outflow_usd": ("excluded_section18_funding_shock_usd"),
            "incremental_combined_stress_outflow_usd": ("excluded_section18_composite_outflow_usd"),
        }
    )
    frame = _merge_component(
        frame,
        settlement_selected,
        [
            "settlement_fail_requirement_usd",
            "excluded_section18_funding_shock_usd",
            "excluded_section18_composite_outflow_usd",
        ],
        "Section 18 settlement-fail",
    )

    concentration_base = pd.Series(0.0, index=frame.index, dtype=float)
    for column in settings.concentration_base_components:
        concentration_base = concentration_base + frame[column].astype(float)
    frame["concentration_base_usd"] = concentration_base
    frame["concentration_excess_ratio"] = (
        frame["member_concentration_ratio"] - scenario.concentration_threshold
    ).clip(lower=0.0)
    frame["concentration_adjustment_usd"] = (
        frame["concentration_base_usd"]
        * frame["concentration_excess_ratio"]
        * scenario.concentration_multiplier
    )

    frame["pre_buffer_stressed_liquidity_requirement_usd"] = frame[
        [
            *ATOMIC_COMPONENT_COLUMNS,
            "concentration_adjustment_usd",
        ]
    ].sum(axis=1)
    frame["operational_liquidity_buffer_usd"] = (
        frame["pre_buffer_stressed_liquidity_requirement_usd"]
        * scenario.operational_liquidity_buffer_rate
    )
    frame["stressed_liquidity_requirement_usd"] = (
        frame["pre_buffer_stressed_liquidity_requirement_usd"]
        + frame["operational_liquidity_buffer_usd"]
    )
    requirement = frame["stressed_liquidity_requirement_usd"].astype(float)
    resources = frame["available_qualified_liquid_resources_usd"].astype(float)
    frame["liquidity_coverage_ratio"] = np.where(
        requirement > settings.tolerance_usd,
        resources / requirement,
        np.inf,
    )
    frame["liquidity_headroom_usd"] = resources - requirement
    frame["liquidity_shortfall_usd"] = (-frame["liquidity_headroom_usd"]).clip(lower=0.0)
    frame["lcr_status"] = np.where(
        requirement <= settings.tolerance_usd,
        "NO_REQUIREMENT",
        np.where(
            frame["liquidity_coverage_ratio"] >= settings.lcr_minimum_ratio,
            "PASS",
            "BREACH",
        ),
    )

    frame["section16_composite_identity_difference_usd"] = (
        frame["excluded_section16_composite_outflow_usd"]
        - frame["repo_rollover_need_usd"]
        - frame["incremental_funding_cost_usd"]
        - frame["excluded_section16_additional_collateral_demand_usd"]
    )
    frame["section18_composite_identity_difference_usd"] = (
        frame["excluded_section18_composite_outflow_usd"]
        - frame["settlement_fail_requirement_usd"]
        - frame["excluded_section18_funding_shock_usd"]
    )
    frame["double_count_control_pass"] = frame[
        "section16_composite_identity_difference_usd"
    ].abs().le(settings.tolerance_usd) & frame[
        "section18_composite_identity_difference_usd"
    ].abs().le(settings.tolerance_usd)
    frame["excluded_overlapping_candidate_amount_usd"] = (
        frame["excluded_section16_additional_collateral_demand_usd"]
        + frame["excluded_section18_funding_shock_usd"]
        + frame["excluded_section17_aqlr_reduction_usd"]
    )

    frame["scenario_name"] = scenario.name
    frame["severity_rank"] = scenario.severity_rank
    frame["funding_scenario_name"] = scenario.funding_scenario_name
    frame["haircut_scenario_name"] = scenario.haircut_scenario_name
    frame["treasury_scenario_name"] = scenario.treasury_scenario_name
    frame["settlement_fail_scenario_name"] = scenario.settlement_fail_scenario_name
    frame["concentration_threshold"] = scenario.concentration_threshold
    frame["concentration_multiplier"] = scenario.concentration_multiplier
    frame["operational_liquidity_buffer_rate"] = scenario.operational_liquidity_buffer_rate
    frame["lcr_minimum_ratio"] = settings.lcr_minimum_ratio
    frame["model_version"] = settings.model_version
    frame["value_class"] = "synthetic"
    frame["actual_ficc_participant"] = False
    frame["participant_level_inference"] = False
    return frame.sort_values("member_id", kind="stable").reset_index(drop=True)


def build_scenario_summary(member_results: pd.DataFrame) -> pd.DataFrame:
    """Aggregate member-level integrated requirements by scenario."""
    rows: list[dict[str, object]] = []
    for (scenario_name, severity_rank), group in member_results.groupby(
        ["scenario_name", "severity_rank"], sort=True
    ):
        total_requirement = float(group["stressed_liquidity_requirement_usd"].sum())
        total_resources = float(group["available_qualified_liquid_resources_usd"].sum())
        aggregate_lcr = total_resources / total_requirement if total_requirement > 0.0 else math.inf
        row: dict[str, object] = {
            "scenario_name": str(scenario_name),
            "severity_rank": int(cast(Any, severity_rank)),
            "member_count": int(group["member_id"].nunique()),
        }
        for column in REQUIRED_COMPONENT_COLUMNS:
            row[f"total_{column}"] = float(group[column].sum())
        row.update(
            {
                "total_stressed_liquidity_requirement_usd": total_requirement,
                "total_available_qualified_liquid_resources_usd": total_resources,
                "aggregate_liquidity_coverage_ratio": aggregate_lcr,
                "minimum_member_liquidity_coverage_ratio": float(
                    group["liquidity_coverage_ratio"].min()
                ),
                "breach_member_count": int((group["lcr_status"] == "BREACH").sum()),
                "double_count_control_failures": int((~group["double_count_control_pass"]).sum()),
                "scenario_status": (
                    "PASS"
                    if bool((group["lcr_status"].isin(["PASS", "NO_REQUIREMENT"])).all())
                    else "BREACH"
                ),
                "model_version": str(group["model_version"].iloc[0]),
                "value_class": "synthetic",
                "actual_ficc_participant": False,
                "participant_level_inference": False,
            }
        )
        rows.append(row)
    return (
        pd.DataFrame.from_records(rows)
        .sort_values("severity_rank", kind="stable")
        .reset_index(drop=True)
    )


def build_double_count_controls(member_results: pd.DataFrame) -> pd.DataFrame:
    """Return the auditable component-selection and overlap-control table."""
    columns = [
        "scenario_name",
        "severity_rank",
        "member_id",
        "funding_scenario_name",
        "haircut_scenario_name",
        "treasury_scenario_name",
        "settlement_fail_scenario_name",
        "repo_rollover_need_usd",
        "incremental_funding_cost_usd",
        "additional_haircut_requirement_usd",
        "settlement_fail_requirement_usd",
        "excluded_section16_additional_collateral_demand_usd",
        "excluded_section16_composite_outflow_usd",
        "excluded_section18_funding_shock_usd",
        "excluded_section18_composite_outflow_usd",
        "excluded_section17_aqlr_reduction_usd",
        "excluded_overlapping_candidate_amount_usd",
        "section16_composite_identity_difference_usd",
        "section18_composite_identity_difference_usd",
        "double_count_control_pass",
        "model_version",
        "value_class",
        "actual_ficc_participant",
        "participant_level_inference",
    ]
    return member_results[columns].copy()


def validate_results(
    member_results: pd.DataFrame,
    scenario_summary: pd.DataFrame,
    double_count_controls: pd.DataFrame,
    baseline_member_count: int,
    settings: IntegratedStressSettings,
) -> dict[str, bool]:
    """Validate Section 19 accounting identities and no-double-counting controls."""
    expected_rows = baseline_member_count * len(settings.scenarios)
    numeric_columns = [
        *REQUIRED_COMPONENT_COLUMNS,
        "stressed_liquidity_requirement_usd",
        "available_qualified_liquid_resources_usd",
        "liquidity_shortfall_usd",
    ]
    finite = (
        member_results[numeric_columns].apply(lambda column: column.map(math.isfinite).all()).all()
    )
    nonnegative = bool((member_results[numeric_columns] >= 0.0).all().all())
    expected_requirement = member_results[
        [
            *ATOMIC_COMPONENT_COLUMNS,
            "concentration_adjustment_usd",
            "operational_liquidity_buffer_usd",
        ]
    ].sum(axis=1)
    requirement_identity = bool(
        (expected_requirement - member_results["stressed_liquidity_requirement_usd"])
        .abs()
        .le(settings.tolerance_usd)
        .all()
    )
    positive_requirement = (
        member_results["stressed_liquidity_requirement_usd"] > settings.tolerance_usd
    )
    expected_lcr = (
        member_results.loc[positive_requirement, "available_qualified_liquid_resources_usd"]
        / member_results.loc[positive_requirement, "stressed_liquidity_requirement_usd"]
    )
    lcr_identity = bool(
        (expected_lcr - member_results.loc[positive_requirement, "liquidity_coverage_ratio"])
        .abs()
        .le(1e-12)
        .all()
    )
    zero_requirement_lcr = bool(
        np.isinf(
            member_results.loc[~positive_requirement, "liquidity_coverage_ratio"].to_numpy(
                dtype=float
            )
        ).all()
    )
    aggregate_monotonic = bool(
        scenario_summary.sort_values("severity_rank")[
            "total_stressed_liquidity_requirement_usd"
        ].is_monotonic_increasing
    )
    expected_status = np.where(
        ~positive_requirement,
        "NO_REQUIREMENT",
        np.where(
            member_results["liquidity_coverage_ratio"] >= settings.lcr_minimum_ratio,
            "PASS",
            "BREACH",
        ),
    )
    status_identity = bool(
        (member_results["lcr_status"].astype(str).to_numpy() == expected_status).all()
    )
    no_actual_participants = bool(
        not member_results["actual_ficc_participant"].astype(bool).any()
        and not member_results["participant_level_inference"].astype(bool).any()
    )
    scenario_rows_complete = len(scenario_summary) == len(settings.scenarios) and set(
        scenario_summary["scenario_name"]
    ) == {scenario.name for scenario in settings.scenarios}
    return {
        "expected_member_scenario_rows": len(member_results) == expected_rows,
        "unique_member_scenario_keys": not bool(
            member_results.duplicated(["scenario_name", "member_id"]).any()
        ),
        "finite_required_outputs": bool(finite),
        "nonnegative_required_outputs": nonnegative,
        "stressed_requirement_identity": requirement_identity,
        "lcr_identity": lcr_identity,
        "zero_requirement_lcr_convention": zero_requirement_lcr,
        "lcr_status_identity": status_identity,
        "double_count_controls_pass": bool(
            double_count_controls["double_count_control_pass"].all()
        ),
        "scenario_summary_complete": scenario_rows_complete,
        "aggregate_requirement_nondecreasing": aggregate_monotonic,
        "synthetic_only": no_actual_participants,
    }


def run_integrated_stress(
    baseline_summary: pd.DataFrame,
    funding_summary: pd.DataFrame,
    haircut_summary: pd.DataFrame,
    treasury_summary: pd.DataFrame,
    settlement_fail_cashflows: pd.DataFrame,
    config: Mapping[str, Any],
) -> IntegratedStressResult:
    """Run the controlled Section 19 integrated stress engine."""
    settings = load_settings(config)
    baseline = prepare_baseline_summary(baseline_summary, settings)
    funding = prepare_funding_summary(funding_summary, settings)
    haircut = prepare_haircut_summary(haircut_summary, settings)
    treasury = prepare_treasury_summary(treasury_summary, settings)
    settlement_fail = prepare_settlement_fail_summary(settlement_fail_cashflows, settings)
    outputs = [
        _scenario_member_results(
            baseline,
            funding,
            haircut,
            treasury,
            settlement_fail,
            scenario,
            settings,
        )
        for scenario in settings.scenarios
    ]
    member_results = pd.concat(outputs, ignore_index=True).sort_values(
        ["severity_rank", "member_id"], kind="stable"
    )
    member_results = member_results.reset_index(drop=True)
    scenario_summary = build_scenario_summary(member_results)
    double_count_controls = build_double_count_controls(member_results)
    checks = validate_results(
        member_results,
        scenario_summary,
        double_count_controls,
        baseline_member_count=len(baseline),
        settings=settings,
    )
    return IntegratedStressResult(
        member_results=member_results,
        scenario_summary=scenario_summary,
        double_count_controls=double_count_controls,
        checks=checks,
    )
