"""Independent sensitivity analysis for FICC liquidity stress validation.

The analysis uses the Section 25 independent calculation path and flat-file
contracts. It does not call production stress-calculation functions.
"""

from __future__ import annotations

import argparse
import json
import math
from collections.abc import Iterable, Mapping
from dataclasses import dataclass
from pathlib import Path
from typing import Any, cast

import pandas as pd
import yaml

from ficc_liquidity.validation.independent_implementation import (
    COMPONENT_COLUMNS,
    calculate_member_stress,
    calculate_qualified_resources,
)

REQUIRED_SENSITIVITIES: tuple[str, ...] = (
    "yield_shocks",
    "duration_assumptions",
    "sofr_spikes",
    "rollover_failure_percentages",
    "haircut_increases",
    "settlement_fail_percentages",
    "member_concentration",
    "liquidation_horizon",
    "default_set_size",
    "available_resource_assumptions",
)

VALID_DIRECTIONS: frozenset[str] = frozenset(
    {"nondecreasing", "nonincreasing", "flat", "unconstrained"}
)


@dataclass(frozen=True)
class SensitivitySpec:
    """Controlled sensitivity specification."""

    name: str
    values: tuple[float, ...]
    baseline: float
    requirement_direction: str
    resource_direction: str
    lcr_direction: str
    description: str


def _require_columns(frame: pd.DataFrame, required: Iterable[str], label: str) -> None:
    missing = sorted(set(required) - set(frame.columns))
    if missing:
        raise ValueError(f"{label} is missing required columns: {missing}")


def _as_float_tuple(values: Any, name: str) -> tuple[float, ...]:
    if not isinstance(values, list) or not values:
        raise ValueError(f"Sensitivity {name!r} must define a nonempty values list")
    converted = tuple(float(value) for value in values)
    if any(not math.isfinite(value) for value in converted):
        raise ValueError(f"Sensitivity {name!r} contains a non-finite value")
    if tuple(sorted(set(converted))) != converted:
        raise ValueError(f"Sensitivity {name!r} values must be unique and increasing")
    return converted


def load_sensitivity_specs(config: Mapping[str, Any]) -> tuple[SensitivitySpec, ...]:
    """Validate and load all ten required sensitivity definitions."""

    analysis = config.get("analysis")
    if not isinstance(analysis, Mapping):
        raise ValueError("The Section 26 config must contain an analysis mapping")
    dimensions = analysis.get("dimensions")
    if not isinstance(dimensions, Mapping):
        raise ValueError("analysis.dimensions must be a mapping")

    missing = sorted(set(REQUIRED_SENSITIVITIES) - set(dimensions))
    extra = sorted(set(dimensions) - set(REQUIRED_SENSITIVITIES))
    if missing or extra:
        raise ValueError(f"Sensitivity dimension mismatch. Missing={missing}; extra={extra}")

    specs: list[SensitivitySpec] = []
    for name in REQUIRED_SENSITIVITIES:
        raw = dimensions[name]
        if not isinstance(raw, Mapping):
            raise ValueError(f"Sensitivity {name!r} must be a mapping")
        values = _as_float_tuple(raw.get("values"), name)
        baseline_raw = raw.get("baseline")
        if baseline_raw is None:
            raise ValueError(f"Sensitivity {name!r} baseline is required")
        baseline = float(cast(float | int | str, baseline_raw))
        if baseline not in values:
            raise ValueError(f"Sensitivity {name!r} baseline must be included in values")
        directions = {
            "requirement_direction": str(raw.get("requirement_direction", "unconstrained")),
            "resource_direction": str(raw.get("resource_direction", "unconstrained")),
            "lcr_direction": str(raw.get("lcr_direction", "unconstrained")),
        }
        invalid = sorted(set(directions.values()) - VALID_DIRECTIONS)
        if invalid:
            raise ValueError(f"Sensitivity {name!r} has invalid directions: {invalid}")
        specs.append(
            SensitivitySpec(
                name=name,
                values=values,
                baseline=baseline,
                requirement_direction=directions["requirement_direction"],
                resource_direction=directions["resource_direction"],
                lcr_direction=directions["lcr_direction"],
                description=str(raw.get("description", "")).strip(),
            )
        )
    return tuple(specs)


def apply_sensitivity(
    members: pd.DataFrame,
    resources: pd.DataFrame,
    spec: SensitivitySpec,
    value: float,
) -> tuple[pd.DataFrame, pd.DataFrame, int | None]:
    """Return shocked copies of member and resource inputs plus optional default-set size."""

    member_shock = members.copy(deep=True)
    resource_shock = resources.copy(deep=True)
    default_set_size: int | None = None

    multiplier_columns: dict[str, tuple[str, ...]] = {
        "yield_shocks": ("yield_shock_bps",),
        "duration_assumptions": ("modified_duration",),
        "sofr_spikes": ("sofr_spike_bps",),
        "rollover_failure_percentages": ("repo_rollover_failure_rate",),
        "haircut_increases": ("haircut_increase_pct",),
        "settlement_fail_percentages": ("fails_to_receive", "delayed_incoming_payments"),
    }

    if spec.name in multiplier_columns:
        for column in multiplier_columns[spec.name]:
            member_shock[column] = pd.to_numeric(member_shock[column], errors="raise") * value
        if spec.name == "rollover_failure_percentages":
            member_shock["repo_rollover_failure_rate"] = member_shock[
                "repo_rollover_failure_rate"
            ].clip(lower=0.0, upper=1.0)
        elif spec.name == "haircut_increases":
            member_shock["haircut_increase_pct"] = member_shock["haircut_increase_pct"].clip(
                lower=0.0, upper=1.0
            )
    elif spec.name == "member_concentration":
        member_shock["concentration_multiplier"] = (
            pd.to_numeric(member_shock["concentration_multiplier"], errors="raise") * value
        ).clip(lower=0.0)
        member_shock["concentration_addon_pct"] = (
            pd.to_numeric(member_shock["concentration_addon_pct"], errors="raise") * value
        ).clip(lower=0.0, upper=1.0)
    elif spec.name == "liquidation_horizon":
        horizon_factor = math.sqrt(value / spec.baseline)
        member_shock["yield_shock_bps"] = (
            pd.to_numeric(member_shock["yield_shock_bps"], errors="raise") * horizon_factor
        )
    elif spec.name == "default_set_size":
        default_set_size = int(value)
        if float(default_set_size) != value or default_set_size < 1:
            raise ValueError("default_set_size values must be positive integers")
    elif spec.name == "available_resource_assumptions":
        resource_shock["availability_factor"] = (
            pd.to_numeric(resource_shock["availability_factor"], errors="raise") * value
        ).clip(lower=0.0, upper=1.0)
    else:
        raise ValueError(f"Unsupported sensitivity: {spec.name}")

    return member_shock, resource_shock, default_set_size


def calculate_default_set_result(
    member_results: pd.DataFrame,
    qualified_resources: pd.DataFrame,
    scenario_id: str,
    default_set_size: int,
) -> dict[str, Any]:
    """Calculate a generalized Cover N result from independent member calculations."""

    _require_columns(
        member_results,
        ["scenario_id", "member_id", "stressed_liquidity_requirement", *COMPONENT_COLUMNS],
        "member_results",
    )
    scenario_members = member_results.loc[
        member_results["scenario_id"].astype(str).eq(str(scenario_id))
    ].copy()
    if scenario_members.empty:
        raise ValueError(f"No member results were found for scenario {scenario_id!r}")
    if default_set_size > len(scenario_members):
        raise ValueError(
            f"Default-set size {default_set_size} exceeds member count {len(scenario_members)} "
            f"for scenario {scenario_id!r}"
        )

    ranked = scenario_members.sort_values(
        ["stressed_liquidity_requirement", "member_id"],
        ascending=[False, True],
        kind="mergesort",
    )
    selected = ranked.head(default_set_size)
    default_members = selected["member_id"].astype(str).tolist()
    stressed_requirement = float(selected["stressed_liquidity_requirement"].sum())

    scenario_resources = qualified_resources.loc[
        qualified_resources["scenario_id"].astype(str).eq(str(scenario_id))
    ].copy()
    resource_available = scenario_resources["owner_member_id"].eq("") | ~scenario_resources[
        "owner_member_id"
    ].astype(str).isin(default_members)
    available_resources = float(
        scenario_resources.loc[resource_available, "qualified_resource_amount"].sum()
    )
    component_totals = selected.loc[:, list(COMPONENT_COLUMNS)].sum(axis=0)
    dominant_component = str(component_totals.sort_values(ascending=False).index[0])
    lcr = available_resources / stressed_requirement if stressed_requirement > 0.0 else math.inf
    shortfall = max(stressed_requirement - available_resources, 0.0)
    utilization = (
        stressed_requirement / available_resources if available_resources > 0.0 else math.inf
    )

    return {
        "scenario_id": str(scenario_id),
        "default_set_size": default_set_size,
        "default_members": "|".join(default_members),
        "stressed_requirement": stressed_requirement,
        "available_resources": available_resources,
        "lcr": lcr,
        "liquidity_shortfall": shortfall,
        "resource_utilization": utilization,
        "dominant_stress_component": dominant_component,
    }


def _percent_change(value: float, baseline: float) -> float:
    if math.isinf(value) and math.isinf(baseline):
        return 0.0
    if baseline == 0.0:
        return 0.0 if value == 0.0 else math.nan
    return (value - baseline) / abs(baseline)


def _elasticity(output_change: float, input_value: float, input_baseline: float) -> float:
    input_change = _percent_change(input_value, input_baseline)
    if input_change == 0.0 or math.isnan(input_change) or math.isnan(output_change):
        return math.nan
    return output_change / input_change


def run_sensitivity_grid(
    members: pd.DataFrame,
    resources: pd.DataFrame,
    specs: tuple[SensitivitySpec, ...],
) -> pd.DataFrame:
    """Run all sensitivity points for Cover 1, Cover 2, and variable default-set size."""

    member_scenarios = sorted(members["scenario_id"].astype(str).unique().tolist())
    resource_scenarios = sorted(resources["scenario_id"].astype(str).unique().tolist())
    if member_scenarios != resource_scenarios:
        raise ValueError(
            f"Member/resource scenario mismatch: members={member_scenarios}, "
            f"resources={resource_scenarios}"
        )

    records: list[dict[str, Any]] = []
    for spec in specs:
        for value in spec.values:
            shocked_members, shocked_resources, variable_size = apply_sensitivity(
                members, resources, spec, value
            )
            member_results = calculate_member_stress(shocked_members)
            qualified_resources = calculate_qualified_resources(shocked_resources)
            for scenario_id in member_scenarios:
                sizes_and_basis = (
                    ((1, "cover1"), (2, "cover2"))
                    if variable_size is None
                    else ((variable_size, "variable_default_set"),)
                )
                for default_size, coverage_basis in sizes_and_basis:
                    result = calculate_default_set_result(
                        member_results,
                        qualified_resources,
                        scenario_id,
                        default_size,
                    )
                    records.append(
                        {
                            "sensitivity_name": spec.name,
                            "sensitivity_value": value,
                            "baseline_value": spec.baseline,
                            "coverage_basis": coverage_basis,
                            **result,
                        }
                    )

    detailed = pd.DataFrame.from_records(records)
    baseline_columns = [
        "sensitivity_name",
        "scenario_id",
        "coverage_basis",
        "stressed_requirement",
        "available_resources",
        "lcr",
        "liquidity_shortfall",
        "default_members",
        "dominant_stress_component",
    ]
    baseline_mask = detailed["sensitivity_value"].eq(detailed["baseline_value"])
    baselines = detailed.loc[baseline_mask, baseline_columns].copy()
    baselines = baselines.rename(
        columns={
            "stressed_requirement": "baseline_stressed_requirement",
            "available_resources": "baseline_available_resources",
            "lcr": "baseline_lcr",
            "liquidity_shortfall": "baseline_liquidity_shortfall",
            "default_members": "baseline_default_members",
            "dominant_stress_component": "baseline_dominant_stress_component",
        }
    )
    if baselines.duplicated(["sensitivity_name", "scenario_id", "coverage_basis"]).any():
        raise ValueError("Each sensitivity group must have exactly one baseline result")

    detailed = detailed.merge(
        baselines,
        on=["sensitivity_name", "scenario_id", "coverage_basis"],
        how="left",
        validate="many_to_one",
    )
    detailed["requirement_change_pct"] = detailed.apply(
        lambda row: _percent_change(
            float(row["stressed_requirement"]), float(row["baseline_stressed_requirement"])
        ),
        axis=1,
    )
    detailed["resource_change_pct"] = detailed.apply(
        lambda row: _percent_change(
            float(row["available_resources"]), float(row["baseline_available_resources"])
        ),
        axis=1,
    )
    detailed["lcr_change_pct"] = detailed.apply(
        lambda row: _percent_change(float(row["lcr"]), float(row["baseline_lcr"])),
        axis=1,
    )
    detailed["requirement_elasticity"] = detailed.apply(
        lambda row: _elasticity(
            float(row["requirement_change_pct"]),
            float(row["sensitivity_value"]),
            float(row["baseline_value"]),
        ),
        axis=1,
    )
    detailed["lcr_elasticity"] = detailed.apply(
        lambda row: _elasticity(
            float(row["lcr_change_pct"]),
            float(row["sensitivity_value"]),
            float(row["baseline_value"]),
        ),
        axis=1,
    )
    detailed["default_set_changed"] = detailed["default_members"].ne(
        detailed["baseline_default_members"]
    )
    detailed["dominant_component_changed"] = detailed["dominant_stress_component"].ne(
        detailed["baseline_dominant_stress_component"]
    )
    detailed["lcr_below_one"] = detailed["lcr"].lt(1.0)
    detailed["shortfall_triggered"] = detailed["liquidity_shortfall"].gt(0.0)
    return detailed.sort_values(
        ["sensitivity_name", "scenario_id", "coverage_basis", "sensitivity_value"]
    ).reset_index(drop=True)


def _direction_pass(values: pd.Series, direction: str, tolerance: float) -> bool:
    numeric = pd.to_numeric(values, errors="raise").astype(float)
    if direction == "unconstrained" or len(numeric) <= 1:
        return True
    differences = numeric.diff().dropna()
    scale = max(1.0, float(numeric.abs().max()))
    allowed = tolerance * scale
    if direction == "nondecreasing":
        return bool((differences >= -allowed).all())
    if direction == "nonincreasing":
        return bool((differences <= allowed).all())
    if direction == "flat":
        return bool((differences.abs() <= allowed).all())
    raise ValueError(f"Unsupported direction: {direction}")


def summarize_sensitivities(
    detailed: pd.DataFrame,
    specs: tuple[SensitivitySpec, ...],
    tolerance: float,
) -> pd.DataFrame:
    """Assess directionality, monotonicity, breaches, and rank/component changes."""

    spec_map = {spec.name: spec for spec in specs}
    records: list[dict[str, Any]] = []
    group_columns = ["sensitivity_name", "scenario_id", "coverage_basis"]
    for keys, group in detailed.groupby(group_columns, sort=True):
        sensitivity_name, scenario_id, coverage_basis = cast(tuple[str, str, str], keys)
        spec = spec_map[sensitivity_name]
        ordered = group.sort_values("sensitivity_value")
        requirement_pass = _direction_pass(
            ordered["stressed_requirement"], spec.requirement_direction, tolerance
        )
        resource_pass = _direction_pass(
            ordered["available_resources"], spec.resource_direction, tolerance
        )
        lcr_pass = _direction_pass(ordered["lcr"], spec.lcr_direction, tolerance)
        overall_pass = requirement_pass and resource_pass and lcr_pass
        finite_lcr_elasticity = pd.to_numeric(ordered["lcr_elasticity"], errors="coerce").dropna()
        finite_requirement_elasticity = pd.to_numeric(
            ordered["requirement_elasticity"], errors="coerce"
        ).dropna()
        baseline_row = ordered.loc[ordered["sensitivity_value"].eq(spec.baseline)].iloc[0]
        first = ordered.iloc[0]
        last = ordered.iloc[-1]
        records.append(
            {
                "sensitivity_name": sensitivity_name,
                "scenario_id": scenario_id,
                "coverage_basis": coverage_basis,
                "description": spec.description,
                "points_tested": len(ordered),
                "baseline_value": spec.baseline,
                "baseline_lcr": float(baseline_row["lcr"]),
                "minimum_lcr": float(ordered["lcr"].min()),
                "maximum_lcr": float(ordered["lcr"].max()),
                "endpoint_requirement_change_pct": _percent_change(
                    float(last["stressed_requirement"]), float(first["stressed_requirement"])
                ),
                "endpoint_resource_change_pct": _percent_change(
                    float(last["available_resources"]), float(first["available_resources"])
                ),
                "endpoint_lcr_change_pct": _percent_change(float(last["lcr"]), float(first["lcr"])),
                "maximum_absolute_requirement_elasticity": (
                    float(finite_requirement_elasticity.abs().max())
                    if not finite_requirement_elasticity.empty
                    else math.nan
                ),
                "maximum_absolute_lcr_elasticity": (
                    float(finite_lcr_elasticity.abs().max())
                    if not finite_lcr_elasticity.empty
                    else math.nan
                ),
                "lcr_breach_count": int(ordered["lcr_below_one"].sum()),
                "shortfall_count": int(ordered["shortfall_triggered"].sum()),
                "default_set_change_count": int(ordered["default_set_changed"].sum()),
                "dominant_component_change_count": int(ordered["dominant_component_changed"].sum()),
                "requirement_direction": spec.requirement_direction,
                "resource_direction": spec.resource_direction,
                "lcr_direction": spec.lcr_direction,
                "requirement_direction_status": "PASS" if requirement_pass else "FAIL",
                "resource_direction_status": "PASS" if resource_pass else "FAIL",
                "lcr_direction_status": "PASS" if lcr_pass else "FAIL",
                "overall_status": "PASS" if overall_pass else "FAIL",
            }
        )
    return pd.DataFrame.from_records(records).sort_values(group_columns).reset_index(drop=True)


def build_findings(summary: pd.DataFrame) -> pd.DataFrame:
    """Create a controlled findings register from sensitivity outcomes."""

    records: list[dict[str, Any]] = []
    for finding_number, (_, row) in enumerate(summary.iterrows(), start=1):
        failed = str(row["overall_status"]) == "FAIL"
        breach_count = int(row["lcr_breach_count"])
        if failed:
            severity = "High"
            status = "Open"
            observation = (
                "One or more expected directional relationships failed under the controlled "
                "sensitivity grid."
            )
            recommendation = (
                "Investigate model logic, clipping, default-set transitions, and resource "
                "exclusions before validation approval."
            )
        elif breach_count > 0:
            severity = "Medium"
            status = "Observation"
            observation = (
                f"The sensitivity grid produced {breach_count} LCR observations below 1.0 while "
                "maintaining expected directional behavior."
            )
            recommendation = (
                "Confirm that the breach thresholds and management actions are reflected in model "
                "governance and limit monitoring."
            )
        else:
            severity = "Observation"
            status = "Closed"
            observation = "Expected directional behavior was preserved and no LCR breach occurred."
            recommendation = (
                "Retain the tested range as regression evidence for future model changes."
            )
        records.append(
            {
                "finding_id": f"S26-{finding_number:03d}",
                "sensitivity_name": str(row["sensitivity_name"]),
                "scenario_id": str(row["scenario_id"]),
                "coverage_basis": str(row["coverage_basis"]),
                "severity": severity,
                "status": status,
                "observation": observation,
                "recommendation": recommendation,
            }
        )
    return pd.DataFrame.from_records(records)


def _resolve(project_root: Path, value: str) -> Path:
    path = Path(value)
    return path if path.is_absolute() else project_root / path


def _write_csv(frame: pd.DataFrame, path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    frame.to_csv(path, index=False, float_format="%.12f")


def run_analysis(config_path: Path) -> dict[str, Any]:
    """Execute Section 26 and write auditable validation artifacts."""

    config_path = config_path.resolve()
    project_root = config_path.parent.parent
    loaded = yaml.safe_load(config_path.read_text(encoding="utf-8"))
    if not isinstance(loaded, Mapping):
        raise ValueError("The Section 26 config must be a mapping")
    config = cast(Mapping[str, Any], loaded)
    specs = load_sensitivity_specs(config)

    inputs = config.get("inputs")
    outputs = config.get("outputs")
    analysis = config.get("analysis")
    if not isinstance(inputs, Mapping) or not isinstance(outputs, Mapping):
        raise ValueError("The Section 26 config must define inputs and outputs mappings")
    if not isinstance(analysis, Mapping):
        raise ValueError("The Section 26 config must define an analysis mapping")

    members_path = _resolve(project_root, str(inputs["members"]))
    resources_path = _resolve(project_root, str(inputs["resources"]))
    members = pd.read_csv(members_path)
    resources = pd.read_csv(resources_path, keep_default_na=False)
    tolerance = float(analysis.get("monotonic_tolerance", 1.0e-10))
    if tolerance < 0.0:
        raise ValueError("analysis.monotonic_tolerance must be nonnegative")

    detailed = run_sensitivity_grid(members, resources, specs)
    summary = summarize_sensitivities(detailed, specs, tolerance)
    findings = build_findings(summary)
    baselines = detailed.loc[detailed["sensitivity_value"].eq(detailed["baseline_value"])].copy()

    detailed_path = _resolve(project_root, str(outputs["detailed_results"]))
    summary_path = _resolve(project_root, str(outputs["summary_table"]))
    baselines_path = _resolve(project_root, str(outputs["baseline_results"]))
    findings_path = _resolve(project_root, str(outputs["findings_register"]))
    evidence_json_path = _resolve(project_root, str(outputs["evidence_json"]))
    evidence_txt_path = _resolve(project_root, str(outputs["evidence_txt"]))

    _write_csv(detailed, detailed_path)
    _write_csv(summary, summary_path)
    _write_csv(baselines, baselines_path)
    _write_csv(findings, findings_path)

    failed_groups = int(summary["overall_status"].eq("FAIL").sum())
    sensitivity_impact = (
        summary.groupby("sensitivity_name", sort=True)["endpoint_lcr_change_pct"]
        .apply(lambda series: float(series.abs().max()))
        .sort_values(ascending=False)
    )
    most_sensitive = str(sensitivity_impact.index[0]) if not sensitivity_impact.empty else ""
    evidence: dict[str, Any] = {
        "section": 26,
        "name": "sensitivity_analysis",
        "overall_status": "PASS" if failed_groups == 0 else "FAIL",
        "required_sensitivities": list(REQUIRED_SENSITIVITIES),
        "sensitivities_executed": sorted(detailed["sensitivity_name"].unique().tolist()),
        "scenarios_tested": sorted(detailed["scenario_id"].unique().tolist()),
        "detailed_rows": len(detailed),
        "summary_groups": len(summary),
        "failed_directional_groups": failed_groups,
        "lcr_breach_observations": int(detailed["lcr_below_one"].sum()),
        "shortfall_observations": int(detailed["shortfall_triggered"].sum()),
        "default_set_changes": int(detailed["default_set_changed"].sum()),
        "dominant_component_changes": int(detailed["dominant_component_changed"].sum()),
        "most_lcr_sensitive_dimension": most_sensitive,
        "independence_boundary": (
            "Uses the Section 25 independent flat-file calculation path and does not call "
            "production stress functions."
        ),
    }
    evidence_json_path.parent.mkdir(parents=True, exist_ok=True)
    evidence_json_path.write_text(
        json.dumps(evidence, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )

    lines = [
        "PHASE VII SECTION 26 - SENSITIVITY ANALYSIS",
        f"OVERALL STATUS: {evidence['overall_status']}",
        f"SENSITIVITIES EXECUTED: {len(evidence['sensitivities_executed'])}",
        f"SCENARIOS TESTED: {', '.join(evidence['scenarios_tested'])}",
        f"DETAILED ROWS: {evidence['detailed_rows']}",
        f"FAILED DIRECTIONAL GROUPS: {failed_groups}",
        f"LCR BREACH OBSERVATIONS: {evidence['lcr_breach_observations']}",
        f"SHORTFALL OBSERVATIONS: {evidence['shortfall_observations']}",
        f"MOST LCR-SENSITIVE DIMENSION: {most_sensitive}",
        "",
        "INDEPENDENCE BOUNDARY:",
        str(evidence["independence_boundary"]),
    ]
    evidence_txt_path.parent.mkdir(parents=True, exist_ok=True)
    evidence_txt_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return evidence


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Run Phase VII Section 26 sensitivity analysis")
    parser.add_argument(
        "--config",
        type=Path,
        default=Path("configs/sensitivity_analysis.yaml"),
        help="Path to the controlled Section 26 YAML configuration",
    )
    return parser


def main() -> int:
    args = build_parser().parse_args()
    evidence = run_analysis(args.config)
    print(json.dumps(evidence, indent=2, sort_keys=True))
    return 0 if evidence["overall_status"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
