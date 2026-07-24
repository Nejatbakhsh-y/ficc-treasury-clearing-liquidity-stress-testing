"""Cover 1 and Cover 2 liquidity analysis for synthetic clearing members.

The module consumes scenario-level member results produced by the Phase VI
scenario library. It ranks synthetic members deterministically by gross stressed
liquidity requirement and calculates Cover 1 and Cover 2 coverage diagnostics.
"""

from __future__ import annotations

import json
import math
import re
from collections.abc import Mapping, Sequence
from dataclasses import dataclass
from pathlib import Path
from typing import Any, cast

import pandas as pd
import yaml


class CoverAnalysisError(ValueError):
    """Raised when Section 22 configuration or scenario results are invalid."""


CANONICAL_ALIASES: Mapping[str, tuple[str, ...]] = {
    "member_id": ("member_id", "synthetic_member_id", "clearing_member_id"),
    "scenario_name": ("scenario_name", "hypothetical_scenario_name", "scenario_id"),
    "severity_rank": ("severity_rank", "scenario_severity_rank"),
    "stressed_liquidity_requirement_usd": (
        "stressed_liquidity_requirement_usd",
        "total_stressed_liquidity_requirement_usd",
        "integrated_stressed_liquidity_requirement_usd",
    ),
    "available_qualified_liquid_resources_usd": (
        "available_qualified_liquid_resources_usd",
        "available_resources_usd",
        "aqlr_usd",
    ),
    "settlement_liquidity_need_usd": (
        "settlement_liquidity_need_usd",
        "net_settlement_outflow_usd",
    ),
    "repo_rollover_need_usd": (
        "repo_rollover_need_usd",
        "repo_rollover_failure_outflow_usd",
    ),
    "incremental_funding_cost_usd": (
        "incremental_funding_cost_usd",
        "funding_cost_increase_usd",
    ),
    "additional_haircut_requirement_usd": (
        "additional_haircut_requirement_usd",
        "additional_collateral_requirement_total_usd",
    ),
    "treasury_liquidation_loss_usd": (
        "treasury_liquidation_loss_usd",
        "treasury_loss_usd",
    ),
    "settlement_fail_requirement_usd": (
        "settlement_fail_requirement_usd",
        "incremental_settlement_fail_outflow_usd",
    ),
    "concentration_adjustment_usd": (
        "concentration_adjustment_usd",
        "concentration_liquidity_adjustment_usd",
    ),
    "operational_liquidity_buffer_usd": (
        "operational_liquidity_buffer_usd",
        "operational_buffer_usd",
    ),
}

DEFAULT_COMPONENTS: tuple[tuple[str, str], ...] = (
    ("settlement_liquidity_need_usd", "settlement_liquidity_need"),
    ("repo_rollover_need_usd", "repo_rollover_need"),
    ("incremental_funding_cost_usd", "incremental_funding_cost"),
    ("additional_haircut_requirement_usd", "additional_haircut_requirement"),
    ("treasury_liquidation_loss_usd", "treasury_liquidation_loss"),
    ("settlement_fail_requirement_usd", "settlement_fail_requirement"),
    ("concentration_adjustment_usd", "concentration_adjustment"),
    ("operational_liquidity_buffer_usd", "operational_liquidity_buffer"),
)


@dataclass(frozen=True)
class CoverAnalysisSettings:
    """Controlled Section 22 calculation settings."""

    model_version: str
    synthetic_id_pattern: str
    cover_levels: tuple[int, ...]
    lcr_minimum_ratio: float
    reconciliation_tolerance_usd: float
    component_columns: tuple[tuple[str, str], ...]


@dataclass(frozen=True)
class CoverAnalysisResult:
    """Structured Section 22 result tables and validation checks."""

    cover_results: pd.DataFrame
    scenario_summary: pd.DataFrame
    selected_members: pd.DataFrame
    component_summary: pd.DataFrame
    checks: Mapping[str, bool]

    @property
    def passed(self) -> bool:
        """Return True when every controlled validation check passes."""
        return all(self.checks.values())


def load_cover_analysis_config(path: str | Path) -> dict[str, Any]:
    """Load a Section 22 YAML configuration file."""

    config_path = Path(path)
    if not config_path.is_file():
        raise CoverAnalysisError(f"Cover-analysis configuration not found: {config_path}")
    loaded = yaml.safe_load(config_path.read_text(encoding="utf-8"))
    if not isinstance(loaded, dict):
        raise CoverAnalysisError("Cover-analysis configuration must be a YAML mapping.")
    return cast(dict[str, Any], loaded)


def settings_from_config(config: Mapping[str, Any]) -> CoverAnalysisSettings:
    """Build validated calculation settings from a configuration mapping."""

    model_version = str(config.get("model_version", "section-22-v1"))
    source = _mapping(config.get("source", {}), "source")
    selection = _mapping(config.get("selection", {}), "selection")
    metrics = _mapping(config.get("metrics", {}), "metrics")
    validation = _mapping(config.get("validation", {}), "validation")

    synthetic_id_pattern = str(source.get("synthetic_id_pattern", r"^SYN-MBR-[0-9]{4}$"))
    try:
        re.compile(synthetic_id_pattern)
    except re.error as exc:
        raise CoverAnalysisError("source.synthetic_id_pattern is not valid regex.") from exc

    raw_levels = selection.get("cover_levels", [1, 2])
    if not isinstance(raw_levels, Sequence) or isinstance(raw_levels, (str, bytes)):
        raise CoverAnalysisError("selection.cover_levels must be a sequence of positive integers.")
    cover_levels = tuple(int(level) for level in raw_levels)
    if cover_levels != (1, 2):
        raise CoverAnalysisError("Section 22 requires cover_levels to be exactly [1, 2].")

    lcr_minimum_ratio = float(metrics.get("lcr_minimum_ratio", 1.0))
    tolerance = float(validation.get("reconciliation_tolerance_usd", 0.01))
    if lcr_minimum_ratio <= 0.0:
        raise CoverAnalysisError("metrics.lcr_minimum_ratio must be positive.")
    if tolerance < 0.0:
        raise CoverAnalysisError("validation.reconciliation_tolerance_usd cannot be negative.")

    configured_components = metrics.get("component_columns")
    component_columns = _parse_components(configured_components)
    return CoverAnalysisSettings(
        model_version=model_version,
        synthetic_id_pattern=synthetic_id_pattern,
        cover_levels=cover_levels,
        lcr_minimum_ratio=lcr_minimum_ratio,
        reconciliation_tolerance_usd=tolerance,
        component_columns=component_columns,
    )


def _mapping(value: object, name: str) -> Mapping[str, Any]:
    if not isinstance(value, Mapping):
        raise CoverAnalysisError(f"{name} must be a mapping.")
    return cast(Mapping[str, Any], value)


def _parse_components(value: object) -> tuple[tuple[str, str], ...]:
    if value is None:
        return DEFAULT_COMPONENTS
    if not isinstance(value, Sequence) or isinstance(value, (str, bytes)):
        raise CoverAnalysisError("metrics.component_columns must be a sequence.")
    parsed: list[tuple[str, str]] = []
    for item in value:
        if not isinstance(item, Mapping):
            raise CoverAnalysisError("Each component definition must be a mapping.")
        column = str(item.get("column", "")).strip()
        label = str(item.get("label", "")).strip()
        if not column or not label:
            raise CoverAnalysisError("Each component requires nonempty column and label values.")
        parsed.append((column, label))
    if not parsed:
        raise CoverAnalysisError("At least one stress component is required.")
    if len({column for column, _ in parsed}) != len(parsed):
        raise CoverAnalysisError("Stress-component columns must be unique.")
    return tuple(parsed)


def canonicalize_member_results(
    frame: pd.DataFrame,
    settings: CoverAnalysisSettings,
) -> pd.DataFrame:
    """Resolve aliases and validate scenario-level synthetic member results."""

    if frame.empty:
        raise CoverAnalysisError("Scenario member results are empty.")

    required = {
        "member_id",
        "scenario_name",
        "stressed_liquidity_requirement_usd",
        "available_qualified_liquid_resources_usd",
        *(column for column, _ in settings.component_columns),
    }
    rename_map: dict[str, str] = {}
    missing: list[str] = []
    for canonical in sorted(required | {"severity_rank"}):
        aliases = CANONICAL_ALIASES.get(canonical, (canonical,))
        source = next((name for name in aliases if name in frame.columns), None)
        if source is None:
            if canonical == "severity_rank":
                continue
            missing.append(canonical)
        elif source != canonical:
            rename_map[source] = canonical
    if missing:
        raise CoverAnalysisError(
            "Scenario member results are missing required columns: " + ", ".join(missing)
        )

    result = frame.rename(columns=rename_map).copy()
    result["member_id"] = result["member_id"].astype(str).str.strip()
    result["scenario_name"] = result["scenario_name"].astype(str).str.strip()
    if "severity_rank" not in result.columns:
        ordered_names = sorted(result["scenario_name"].unique().tolist())
        rank_map = {name: rank for rank, name in enumerate(ordered_names)}
        result["severity_rank"] = result["scenario_name"].map(rank_map)

    numeric_columns = [
        "severity_rank",
        "stressed_liquidity_requirement_usd",
        "available_qualified_liquid_resources_usd",
        *(column for column, _ in settings.component_columns),
    ]
    for column in numeric_columns:
        result[column] = pd.to_numeric(result[column], errors="raise")

    if result["member_id"].eq("").any() or result["scenario_name"].eq("").any():
        raise CoverAnalysisError("Member and scenario identifiers must be nonempty.")
    pattern = re.compile(settings.synthetic_id_pattern)
    invalid_ids = sorted(
        member_id
        for member_id in result["member_id"].unique().tolist()
        if pattern.fullmatch(str(member_id)) is None
    )
    if invalid_ids:
        raise CoverAnalysisError(
            "Only controlled synthetic member identifiers are permitted: "
            + ", ".join(invalid_ids[:5])
        )
    if result.duplicated(subset=["scenario_name", "member_id"]).any():
        raise CoverAnalysisError("Scenario/member records must be unique.")

    nonnegative_columns = [
        "stressed_liquidity_requirement_usd",
        "available_qualified_liquid_resources_usd",
        *(column for column, _ in settings.component_columns),
    ]
    if (result[nonnegative_columns] < 0.0).any().any():
        raise CoverAnalysisError(
            "Requirements, resources, and stress components cannot be negative."
        )
    if not result[numeric_columns].map(math.isfinite).all().all():
        raise CoverAnalysisError("Numeric scenario results must be finite.")

    component_total = result[[column for column, _ in settings.component_columns]].sum(axis=1)
    difference = (component_total - result["stressed_liquidity_requirement_usd"]).abs()
    if (difference > settings.reconciliation_tolerance_usd).any():
        maximum = float(difference.max())
        raise CoverAnalysisError(
            "Stress components do not reconcile to stressed liquidity requirement; "
            f"maximum difference is {maximum:.6f}."
        )

    result["liquidity_shortfall_usd"] = (
        result["stressed_liquidity_requirement_usd"]
        - result["available_qualified_liquid_resources_usd"]
    ).clip(lower=0.0)
    return result.sort_values(
        ["severity_rank", "scenario_name", "member_id"], kind="mergesort"
    ).reset_index(drop=True)


def analyze_cover_sets(
    frame: pd.DataFrame,
    settings: CoverAnalysisSettings,
) -> CoverAnalysisResult:
    """Calculate deterministic Cover 1 and Cover 2 diagnostics for every scenario."""

    canonical = canonicalize_member_results(frame, settings)
    cover_rows: list[dict[str, object]] = []
    selected_rows: list[dict[str, object]] = []
    component_rows: list[dict[str, object]] = []

    grouped = canonical.groupby(["severity_rank", "scenario_name"], sort=True, dropna=False)
    for (severity_rank, scenario_name), scenario_frame in grouped:
        ranked = scenario_frame.sort_values(
            [
                "stressed_liquidity_requirement_usd",
                "liquidity_shortfall_usd",
                "member_id",
            ],
            ascending=[False, False, True],
            kind="mergesort",
        ).reset_index(drop=True)
        for cover_level in settings.cover_levels:
            selected = ranked.head(cover_level).copy()
            if len(selected) != cover_level:
                raise CoverAnalysisError(
                    f"Scenario {scenario_name!s} has fewer than {cover_level} members."
                )
            requirement = float(selected["stressed_liquidity_requirement_usd"].sum())
            resources = float(selected["available_qualified_liquid_resources_usd"].sum())
            shortfall = max(requirement - resources, 0.0)
            lcr = (
                resources / requirement
                if requirement > settings.reconciliation_tolerance_usd
                else math.nan
            )
            utilization = (
                requirement / resources
                if resources > settings.reconciliation_tolerance_usd
                else math.nan
            )

            component_totals = {
                column: float(selected[column].sum()) for column, _ in settings.component_columns
            }
            dominant_column, dominant_label = max(
                settings.component_columns,
                key=lambda pair: (component_totals[pair[0]], -_component_index(settings, pair[0])),
            )
            dominant_amount = component_totals[dominant_column]
            dominant_share = dominant_amount / requirement if requirement > 0.0 else math.nan
            selected_ids = selected["member_id"].astype(str).tolist()
            status = (
                "PASS" if math.isfinite(lcr) and lcr >= settings.lcr_minimum_ratio else "BREACH"
            )

            cover_rows.append(
                {
                    "scenario_name": str(scenario_name),
                    "severity_rank": int(cast(Any, severity_rank)),
                    "cover_standard": f"COVER_{cover_level}",
                    "cover_level": cover_level,
                    "selected_member_count": len(selected_ids),
                    "selected_member_ids_json": json.dumps(selected_ids),
                    "cover_stressed_requirement_usd": requirement,
                    "available_resources_usd": resources,
                    "liquidity_coverage_ratio": lcr,
                    "liquidity_shortfall_usd": shortfall,
                    "resource_utilization_ratio": utilization,
                    "dominant_stress_component": dominant_label,
                    "dominant_stress_component_column": dominant_column,
                    "dominant_stress_component_usd": dominant_amount,
                    "dominant_stress_component_share": dominant_share,
                    "lcr_minimum_ratio": settings.lcr_minimum_ratio,
                    "coverage_status": status,
                    "model_version": settings.model_version,
                    "value_class": "synthetic",
                    "actual_ficc_participant": False,
                    "participant_level_inference": False,
                }
            )

            for rank, (_, member) in enumerate(selected.iterrows(), start=1):
                selected_rows.append(
                    {
                        "scenario_name": str(scenario_name),
                        "severity_rank": int(cast(Any, severity_rank)),
                        "cover_standard": f"COVER_{cover_level}",
                        "cover_level": cover_level,
                        "selection_rank": rank,
                        "member_id": str(member["member_id"]),
                        "member_stressed_requirement_usd": float(
                            member["stressed_liquidity_requirement_usd"]
                        ),
                        "member_available_resources_usd": float(
                            member["available_qualified_liquid_resources_usd"]
                        ),
                        "member_liquidity_shortfall_usd": float(member["liquidity_shortfall_usd"]),
                        "model_version": settings.model_version,
                        "value_class": "synthetic",
                        "actual_ficc_participant": False,
                        "participant_level_inference": False,
                    }
                )

            for column, label in settings.component_columns:
                amount = component_totals[column]
                component_rows.append(
                    {
                        "scenario_name": str(scenario_name),
                        "severity_rank": int(cast(Any, severity_rank)),
                        "cover_standard": f"COVER_{cover_level}",
                        "cover_level": cover_level,
                        "component_column": column,
                        "component_name": label,
                        "component_amount_usd": amount,
                        "component_share_of_requirement": (
                            amount / requirement if requirement > 0.0 else math.nan
                        ),
                        "is_dominant_component": column == dominant_column,
                        "model_version": settings.model_version,
                        "value_class": "synthetic",
                        "actual_ficc_participant": False,
                        "participant_level_inference": False,
                    }
                )

    cover_results = (
        pd.DataFrame(cover_rows)
        .sort_values(["severity_rank", "scenario_name", "cover_level"], kind="mergesort")
        .reset_index(drop=True)
    )
    selected_members = (
        pd.DataFrame(selected_rows)
        .sort_values(
            ["severity_rank", "scenario_name", "cover_level", "selection_rank"],
            kind="mergesort",
        )
        .reset_index(drop=True)
    )
    component_summary = (
        pd.DataFrame(component_rows)
        .sort_values(
            ["severity_rank", "scenario_name", "cover_level", "component_name"],
            kind="mergesort",
        )
        .reset_index(drop=True)
    )
    scenario_summary = build_scenario_summary(cover_results)

    checks = _build_checks(
        canonical,
        cover_results,
        selected_members,
        component_summary,
        settings,
    )
    return CoverAnalysisResult(
        cover_results=cover_results,
        scenario_summary=scenario_summary,
        selected_members=selected_members,
        component_summary=component_summary,
        checks=checks,
    )


def _component_index(settings: CoverAnalysisSettings, column: str) -> int:
    return next(index for index, pair in enumerate(settings.component_columns) if pair[0] == column)


def build_scenario_summary(cover_results: pd.DataFrame) -> pd.DataFrame:
    """Create one wide row per scenario with explicit Cover 1 and Cover 2 metrics."""

    if cover_results.empty:
        raise CoverAnalysisError("Cover results are empty.")
    rows: list[dict[str, object]] = []
    for (severity_rank, scenario_name), group in cover_results.groupby(
        ["severity_rank", "scenario_name"], sort=True, dropna=False
    ):
        by_level = {int(row["cover_level"]): row for _, row in group.iterrows()}
        if set(by_level) != {1, 2}:
            raise CoverAnalysisError(
                f"Scenario {scenario_name!s} does not contain Cover 1 and Cover 2."
            )
        row: dict[str, object] = {
            "scenario_name": str(scenario_name),
            "severity_rank": int(cast(Any, severity_rank)),
            "model_version": str(by_level[1]["model_version"]),
            "value_class": "synthetic",
            "actual_ficc_participant": False,
            "participant_level_inference": False,
        }
        for level in (1, 2):
            source = by_level[level]
            prefix = f"cover_{level}"
            row[f"{prefix}_member_ids_json"] = source["selected_member_ids_json"]
            row[f"{prefix}_stressed_requirement_usd"] = source["cover_stressed_requirement_usd"]
            row[f"{prefix}_available_resources_usd"] = source["available_resources_usd"]
            row[f"{prefix}_liquidity_coverage_ratio"] = source["liquidity_coverage_ratio"]
            row[f"{prefix}_liquidity_shortfall_usd"] = source["liquidity_shortfall_usd"]
            row[f"{prefix}_resource_utilization_ratio"] = source["resource_utilization_ratio"]
            row[f"{prefix}_dominant_stress_component"] = source["dominant_stress_component"]
            row[f"{prefix}_dominant_stress_component_usd"] = source["dominant_stress_component_usd"]
            row[f"{prefix}_coverage_status"] = source["coverage_status"]
        rows.append(row)
    return (
        pd.DataFrame(rows)
        .sort_values(["severity_rank", "scenario_name"], kind="mergesort")
        .reset_index(drop=True)
    )


def _build_checks(
    canonical: pd.DataFrame,
    cover_results: pd.DataFrame,
    selected_members: pd.DataFrame,
    component_summary: pd.DataFrame,
    settings: CoverAnalysisSettings,
) -> dict[str, bool]:
    scenario_count = int(canonical["scenario_name"].nunique())
    cover1 = cover_results.loc[cover_results["cover_level"] == 1]
    cover2 = cover_results.loc[cover_results["cover_level"] == 2]
    merged = cover1.merge(
        cover2,
        on=["scenario_name", "severity_rank"],
        suffixes=("_cover1", "_cover2"),
        validate="one_to_one",
    )
    tolerance = settings.reconciliation_tolerance_usd
    identity_difference = (
        cover_results["cover_stressed_requirement_usd"]
        - cover_results["available_resources_usd"]
        - cover_results["liquidity_shortfall_usd"]
    )
    positive_gap = (
        cover_results["cover_stressed_requirement_usd"] >= cover_results["available_resources_usd"]
    )
    identity_ok = (identity_difference.loc[positive_gap].abs() <= tolerance).all() and (
        cover_results.loc[~positive_gap, "liquidity_shortfall_usd"] <= tolerance
    ).all()

    component_totals = component_summary.groupby(
        ["scenario_name", "severity_rank", "cover_level"], sort=True
    )["component_amount_usd"].sum()
    requirement_totals = cover_results.set_index(["scenario_name", "severity_rank", "cover_level"])[
        "cover_stressed_requirement_usd"
    ]
    component_difference = (component_totals - requirement_totals).abs()

    return {
        "scenario_coverage_complete": len(cover_results) == scenario_count * 2,
        "cover_1_member_count": bool((cover1["selected_member_count"] == 1).all()),
        "cover_2_member_count": bool((cover2["selected_member_count"] == 2).all()),
        "cover_2_not_less_than_cover_1": bool(
            (
                merged["cover_stressed_requirement_usd_cover2"] + tolerance
                >= merged["cover_stressed_requirement_usd_cover1"]
            ).all()
        ),
        "available_resources_nonnegative": bool(
            (cover_results["available_resources_usd"] >= 0.0).all()
        ),
        "liquidity_shortfall_identity": bool(identity_ok),
        "component_reconciliation": bool((component_difference <= tolerance).all()),
        "one_dominant_component_per_cover": bool(
            component_summary.groupby(["scenario_name", "severity_rank", "cover_level"], sort=True)[
                "is_dominant_component"
            ]
            .sum()
            .eq(1)
            .all()
        ),
        "selected_members_unique_within_cover": not selected_members.duplicated(
            subset=["scenario_name", "cover_level", "member_id"]
        ).any(),
        "synthetic_identifiers_only": bool(
            canonical["member_id"].astype(str).str.fullmatch(settings.synthetic_id_pattern).all()
        ),
        "actual_ficc_participants_excluded": True,
    }


def deterministic_reproduction_check(
    frame: pd.DataFrame,
    settings: CoverAnalysisSettings,
) -> bool:
    """Verify that input row order cannot alter Cover 1 or Cover 2 selection."""

    first = analyze_cover_sets(frame, settings)
    shuffled = frame.sample(frac=1.0, random_state=2026).reset_index(drop=True)
    second = analyze_cover_sets(shuffled, settings)
    comparable_columns = [
        "scenario_name",
        "severity_rank",
        "cover_level",
        "selected_member_ids_json",
        "cover_stressed_requirement_usd",
        "available_resources_usd",
        "liquidity_shortfall_usd",
        "dominant_stress_component",
    ]
    return first.cover_results[comparable_columns].equals(second.cover_results[comparable_columns])
