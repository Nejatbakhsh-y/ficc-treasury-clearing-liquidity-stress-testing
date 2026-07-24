"""Independent implementation verification for liquidity stress calculations.

This module is intentionally isolated from all production calculation modules.
It accepts flat-file input contracts and implements formulas directly using
pandas and Python standard-library functionality.
"""

from __future__ import annotations

import argparse
import ast
import json
import math
from collections.abc import Iterable
from dataclasses import dataclass
from pathlib import Path
from typing import Any, cast

import pandas as pd
import yaml

COMPONENT_COLUMNS: tuple[str, ...] = (
    "settlement_liquidity_need",
    "repo_rollover_need",
    "incremental_funding_cost",
    "additional_haircut_requirement",
    "treasury_liquidation_loss",
    "settlement_fail_requirement",
    "concentration_adjustment",
    "operational_liquidity_buffer",
)

MEMBER_INPUT_COLUMNS: tuple[str, ...] = (
    "scenario_id",
    "member_id",
    "treasury_market_value",
    "modified_duration",
    "convexity",
    "yield_shock_bps",
    "settlement_obligation",
    "settlement_inflow",
    "settlement_netting_credit",
    "repo_maturity",
    "repo_rollover_failure_rate",
    "refinanced_repo",
    "sofr_spike_bps",
    "funding_horizon_days",
    "collateral_market_value",
    "haircut_increase_pct",
    "concentration_multiplier",
    "fails_to_receive",
    "delayed_incoming_payments",
    "fails_to_deliver_credit",
    "fail_persistence_days",
    "concentration_base",
    "concentration_addon_pct",
    "operational_base",
    "operational_buffer_pct",
)

RESOURCE_INPUT_COLUMNS: tuple[str, ...] = (
    "scenario_id",
    "resource_id",
    "owner_member_id",
    "resource_type",
    "nominal_amount",
    "eligibility_flag",
    "liquidity_haircut_pct",
    "availability_factor",
)

COVER_RESULT_COLUMNS: tuple[str, ...] = (
    "scenario_id",
    "coverage_basis",
    "default_members",
    "stressed_requirement",
    "available_resources",
    "lcr",
    "liquidity_shortfall",
    "resource_utilization",
    "dominant_stress_component",
)


@dataclass(frozen=True)
class ComparisonTolerance:
    """Absolute and relative comparison tolerances."""

    absolute: float = 1.0e-8
    relative: float = 1.0e-8


def _require_columns(frame: pd.DataFrame, required: Iterable[str], label: str) -> None:
    missing = sorted(set(required) - set(frame.columns))
    if missing:
        raise ValueError(f"{label} is missing required columns: {missing}")


def _numeric(frame: pd.DataFrame, columns: Iterable[str], label: str) -> pd.DataFrame:
    result = frame.copy()
    for column in columns:
        try:
            result[column] = pd.to_numeric(result[column], errors="raise").astype(float)
        except (TypeError, ValueError) as exc:
            raise ValueError(f"{label}.{column} must be numeric") from exc
    return result


def _assert_nonnegative(frame: pd.DataFrame, columns: Iterable[str], label: str) -> None:
    for column in columns:
        if (frame[column] < 0.0).any():
            bad_rows = frame.index[frame[column] < 0.0].tolist()
            raise ValueError(f"{label}.{column} contains negative values at rows {bad_rows}")


def _assert_fraction(frame: pd.DataFrame, columns: Iterable[str], label: str) -> None:
    for column in columns:
        invalid = (frame[column] < 0.0) | (frame[column] > 1.0)
        if invalid.any():
            bad_rows = frame.index[invalid].tolist()
            raise ValueError(f"{label}.{column} must be between 0 and 1 at rows {bad_rows}")


def _as_bool(value: Any) -> bool:
    if isinstance(value, bool):
        return value
    normalized = str(value).strip().lower()
    if normalized in {"true", "1", "yes", "y"}:
        return True
    if normalized in {"false", "0", "no", "n", ""}:
        return False
    raise ValueError(f"Cannot interpret eligibility_flag value as Boolean: {value!r}")


def calculate_member_stress(members: pd.DataFrame) -> pd.DataFrame:
    """Calculate each stress component directly from raw member inputs."""

    _require_columns(members, MEMBER_INPUT_COLUMNS, "members")
    frame = members.loc[:, list(MEMBER_INPUT_COLUMNS)].copy()
    frame["scenario_id"] = frame["scenario_id"].astype(str)
    frame["member_id"] = frame["member_id"].astype(str)

    numeric_columns = [
        column for column in MEMBER_INPUT_COLUMNS if column not in {"scenario_id", "member_id"}
    ]
    frame = _numeric(frame, numeric_columns, "members")

    nonnegative_columns = [
        "treasury_market_value",
        "modified_duration",
        "convexity",
        "settlement_obligation",
        "settlement_inflow",
        "settlement_netting_credit",
        "repo_maturity",
        "refinanced_repo",
        "funding_horizon_days",
        "collateral_market_value",
        "concentration_multiplier",
        "fails_to_receive",
        "delayed_incoming_payments",
        "fails_to_deliver_credit",
        "fail_persistence_days",
        "concentration_base",
        "operational_base",
    ]
    _assert_nonnegative(frame, nonnegative_columns, "members")
    _assert_fraction(
        frame,
        [
            "repo_rollover_failure_rate",
            "haircut_increase_pct",
            "concentration_addon_pct",
            "operational_buffer_pct",
        ],
        "members",
    )

    yield_change = frame["yield_shock_bps"] / 10_000.0
    duration_convexity_loss_rate = (
        frame["modified_duration"] * yield_change - 0.5 * frame["convexity"] * yield_change.pow(2)
    ).clip(lower=0.0)

    frame["settlement_liquidity_need"] = (
        frame["settlement_obligation"]
        - frame["settlement_inflow"]
        - frame["settlement_netting_credit"]
    ).clip(lower=0.0)
    frame["repo_rollover_need"] = frame["repo_maturity"] * frame["repo_rollover_failure_rate"]
    frame["incremental_funding_cost"] = (
        frame["refinanced_repo"]
        * (frame["sofr_spike_bps"] / 10_000.0)
        * (frame["funding_horizon_days"] / 360.0)
    ).clip(lower=0.0)
    frame["additional_haircut_requirement"] = (
        frame["collateral_market_value"]
        * frame["haircut_increase_pct"]
        * frame["concentration_multiplier"]
    )
    frame["treasury_liquidation_loss"] = (
        frame["treasury_market_value"] * duration_convexity_loss_rate
    )
    frame["settlement_fail_requirement"] = (
        frame["fails_to_receive"]
        + frame["delayed_incoming_payments"]
        - frame["fails_to_deliver_credit"]
    ).clip(lower=0.0) * frame["fail_persistence_days"].clip(lower=1.0)
    frame["concentration_adjustment"] = (
        frame["concentration_base"] * frame["concentration_addon_pct"]
    )
    frame["operational_liquidity_buffer"] = (
        frame["operational_base"] * frame["operational_buffer_pct"]
    )
    component_frame = frame.loc[:, list(COMPONENT_COLUMNS)]
    frame["stressed_liquidity_requirement"] = component_frame.sum(axis="columns")

    if frame.duplicated(["scenario_id", "member_id"]).any():
        duplicates = frame.loc[
            frame.duplicated(["scenario_id", "member_id"], keep=False),
            ["scenario_id", "member_id"],
        ].to_dict("records")
        raise ValueError(f"Duplicate scenario/member rows are not permitted: {duplicates}")

    return frame


def calculate_qualified_resources(resources: pd.DataFrame) -> pd.DataFrame:
    """Apply independent eligibility, haircut, and availability rules."""

    _require_columns(resources, RESOURCE_INPUT_COLUMNS, "resources")
    frame = resources.loc[:, list(RESOURCE_INPUT_COLUMNS)].copy()
    frame["scenario_id"] = frame["scenario_id"].astype(str)
    frame["resource_id"] = frame["resource_id"].astype(str)
    frame["resource_type"] = frame["resource_type"].astype(str)
    frame["owner_member_id"] = frame["owner_member_id"].fillna("").astype(str).str.strip()
    frame["eligibility_flag"] = frame["eligibility_flag"].map(_as_bool)

    frame = _numeric(
        frame,
        ["nominal_amount", "liquidity_haircut_pct", "availability_factor"],
        "resources",
    )
    _assert_nonnegative(frame, ["nominal_amount"], "resources")
    _assert_fraction(frame, ["liquidity_haircut_pct", "availability_factor"], "resources")

    frame["qualified_resource_amount"] = (
        frame["nominal_amount"]
        * (1.0 - frame["liquidity_haircut_pct"])
        * frame["availability_factor"]
        * frame["eligibility_flag"].astype(float)
    )

    if frame.duplicated(["scenario_id", "resource_id"]).any():
        duplicates = frame.loc[
            frame.duplicated(["scenario_id", "resource_id"], keep=False),
            ["scenario_id", "resource_id"],
        ].to_dict("records")
        raise ValueError(f"Duplicate scenario/resource rows are not permitted: {duplicates}")

    return frame


def select_default_sets(member_results: pd.DataFrame) -> pd.DataFrame:
    """Select Cover 1 and Cover 2 from independently calculated requirements."""

    _require_columns(
        member_results,
        ["scenario_id", "member_id", "stressed_liquidity_requirement"],
        "member_results",
    )

    records: list[dict[str, Any]] = []
    for scenario_id, group in member_results.groupby("scenario_id", sort=True):
        ranked = group.sort_values(
            ["stressed_liquidity_requirement", "member_id"],
            ascending=[False, True],
            kind="mergesort",
        ).reset_index(drop=True)

        for coverage_basis, count in (("cover1", 1), ("cover2", 2)):
            selected = ranked.head(count)
            selected_frame = selected.loc[:, ["member_id", "stressed_liquidity_requirement"]]
            selected_records = cast(
                list[dict[str, Any]],
                selected_frame.to_dict(orient="records"),
            )

            for rank, row in enumerate(selected_records, start=1):
                records.append(
                    {
                        "scenario_id": str(scenario_id),
                        "coverage_basis": coverage_basis,
                        "default_rank": rank,
                        "member_id": str(row["member_id"]),
                        "member_stressed_requirement": float(row["stressed_liquidity_requirement"]),
                    }
                )

    return pd.DataFrame.from_records(records)


def calculate_cover_results(
    member_results: pd.DataFrame,
    qualified_resources: pd.DataFrame,
    default_sets: pd.DataFrame,
) -> pd.DataFrame:
    """Calculate requirements, resources, LCR, shortfalls, and utilization."""

    _require_columns(default_sets, ["scenario_id", "coverage_basis", "member_id"], "default_sets")
    records: list[dict[str, Any]] = []

    for (scenario_id, coverage_basis), selected in default_sets.groupby(
        ["scenario_id", "coverage_basis"], sort=True
    ):
        default_member_ids = selected.sort_values("default_rank")["member_id"].astype(str).tolist()
        member_mask = member_results["scenario_id"].astype(str).eq(
            str(scenario_id)
        ) & member_results["member_id"].astype(str).isin(default_member_ids)
        selected_members = member_results.loc[member_mask]
        if selected_members.empty:
            raise ValueError(f"No member calculations found for {scenario_id}/{coverage_basis}")

        stressed_requirement = float(selected_members["stressed_liquidity_requirement"].sum())

        scenario_resources = qualified_resources.loc[
            qualified_resources["scenario_id"].astype(str).eq(str(scenario_id))
        ].copy()
        resource_available = scenario_resources["owner_member_id"].eq("") | ~scenario_resources[
            "owner_member_id"
        ].isin(default_member_ids)
        available_resources = float(
            scenario_resources.loc[resource_available, "qualified_resource_amount"].sum()
        )

        component_totals = selected_members.loc[:, COMPONENT_COLUMNS].sum(axis=0)
        dominant_component = str(component_totals.sort_values(ascending=False).index[0])

        lcr = available_resources / stressed_requirement if stressed_requirement > 0.0 else math.inf
        liquidity_shortfall = max(stressed_requirement - available_resources, 0.0)
        resource_utilization = (
            stressed_requirement / available_resources if available_resources > 0.0 else math.inf
        )

        records.append(
            {
                "scenario_id": str(scenario_id),
                "coverage_basis": str(coverage_basis),
                "default_members": "|".join(default_member_ids),
                "stressed_requirement": stressed_requirement,
                "available_resources": available_resources,
                "lcr": lcr,
                "liquidity_shortfall": liquidity_shortfall,
                "resource_utilization": resource_utilization,
                "dominant_stress_component": dominant_component,
            }
        )

    result = pd.DataFrame.from_records(records)
    ordered_result = result.loc[:, list(COVER_RESULT_COLUMNS)]
    return ordered_result.sort_values(["scenario_id", "coverage_basis"]).reset_index(drop=True)


def reconcile_aggregates(
    members: pd.DataFrame,
    qualified_resources: pd.DataFrame,
    controls: pd.DataFrame,
) -> pd.DataFrame:
    """Reconcile independent input totals to external aggregate controls."""

    required = (
        "scenario_id",
        "source_table",
        "metric_name",
        "expected_total",
        "absolute_tolerance",
        "relative_tolerance",
    )
    _require_columns(controls, required, "aggregate_controls")
    controls_frame = controls.copy()
    controls_frame["scenario_id"] = controls_frame["scenario_id"].astype(str)
    controls_frame["source_table"] = controls_frame["source_table"].astype(str).str.lower()
    controls_frame["metric_name"] = controls_frame["metric_name"].astype(str)
    controls_frame = _numeric(
        controls_frame,
        ["expected_total", "absolute_tolerance", "relative_tolerance"],
        "aggregate_controls",
    )

    records: list[dict[str, Any]] = []
    control_records = cast(
        list[dict[str, Any]],
        controls_frame.to_dict(orient="records"),
    )

    for control in control_records:
        scenario_id = str(control["scenario_id"])
        source_table = str(control["source_table"])
        metric_name = str(control["metric_name"])
        expected_total = float(control["expected_total"])
        absolute_tolerance = float(control["absolute_tolerance"])
        relative_tolerance = float(control["relative_tolerance"])

        if source_table == "members":
            source = members.loc[members["scenario_id"].astype(str).eq(scenario_id)]
        elif source_table == "resources":
            source = qualified_resources.loc[
                qualified_resources["scenario_id"].astype(str).eq(scenario_id)
            ]
        else:
            raise ValueError(f"Unsupported source_table: {source_table}")

        if metric_name not in source.columns:
            raise ValueError(
                f"Aggregate control metric {metric_name!r} is not present in {source_table}"
            )

        numeric_values = pd.to_numeric(
            source[metric_name],
            errors="raise",
        )

        actual_total = math.fsum(float(value) for value in numeric_values.tolist())

        absolute_difference = abs(actual_total - expected_total)

        relative_difference = (
            absolute_difference / abs(expected_total)
            if expected_total != 0.0
            else absolute_difference
        )

        passed = (
            absolute_difference <= absolute_tolerance or relative_difference <= relative_tolerance
        )

        records.append(
            {
                "scenario_id": scenario_id,
                "source_table": source_table,
                "metric_name": metric_name,
                "expected_total": expected_total,
                "actual_total": actual_total,
                "absolute_difference": absolute_difference,
                "relative_difference": relative_difference,
                "absolute_tolerance": absolute_tolerance,
                "relative_tolerance": relative_tolerance,
                "status": "PASS" if passed else "FAIL",
            }
        )

    return pd.DataFrame.from_records(records)


def compare_results(
    independent_results: pd.DataFrame,
    reference_results: pd.DataFrame,
    tolerance: ComparisonTolerance,
) -> pd.DataFrame:
    """Compare independent results with exported production or control results."""

    required_reference = [
        "scenario_id",
        "coverage_basis",
        "default_members",
        "stressed_requirement",
        "available_resources",
        "lcr",
        "liquidity_shortfall",
    ]
    _require_columns(reference_results, required_reference, "reference_results")

    independent = independent_results.copy()
    reference = reference_results.loc[:, required_reference].copy()
    independent["scenario_id"] = independent["scenario_id"].astype(str)
    independent["coverage_basis"] = independent["coverage_basis"].astype(str).str.lower()
    reference["scenario_id"] = reference["scenario_id"].astype(str)
    reference["coverage_basis"] = reference["coverage_basis"].astype(str).str.lower()

    numeric_metrics = [
        "stressed_requirement",
        "available_resources",
        "lcr",
        "liquidity_shortfall",
    ]
    reference = _numeric(reference, numeric_metrics, "reference_results")

    merged = independent.merge(
        reference,
        on=["scenario_id", "coverage_basis"],
        how="outer",
        suffixes=("_independent", "_reference"),
        indicator=True,
        validate="one_to_one",
    )

    records: list[dict[str, Any]] = []
    for _, row in merged.iterrows():
        key_status = "PASS" if row["_merge"] == "both" else "FAIL"
        independent_members = str(row.get("default_members_independent", "")).strip()
        reference_members = str(row.get("default_members_reference", "")).strip()
        member_status = (
            "PASS" if key_status == "PASS" and independent_members == reference_members else "FAIL"
        )
        records.append(
            {
                "scenario_id": str(row["scenario_id"]),
                "coverage_basis": str(row["coverage_basis"]),
                "metric": "default_members",
                "independent_value": independent_members,
                "reference_value": reference_members,
                "absolute_difference": math.nan,
                "relative_difference": math.nan,
                "absolute_tolerance": tolerance.absolute,
                "relative_tolerance": tolerance.relative,
                "status": member_status,
            }
        )

        for metric in numeric_metrics:
            independent_value = row.get(f"{metric}_independent", math.nan)
            reference_value = row.get(f"{metric}_reference", math.nan)
            if key_status == "FAIL" or pd.isna(independent_value) or pd.isna(reference_value):
                absolute_difference = math.inf
                relative_difference = math.inf
                status = "FAIL"
            else:
                absolute_difference = abs(float(independent_value) - float(reference_value))
                relative_difference = (
                    absolute_difference / abs(float(reference_value))
                    if float(reference_value) != 0.0
                    else absolute_difference
                )
                status = (
                    "PASS"
                    if absolute_difference <= tolerance.absolute
                    or relative_difference <= tolerance.relative
                    else "FAIL"
                )

            records.append(
                {
                    "scenario_id": str(row["scenario_id"]),
                    "coverage_basis": str(row["coverage_basis"]),
                    "metric": metric,
                    "independent_value": independent_value,
                    "reference_value": reference_value,
                    "absolute_difference": absolute_difference,
                    "relative_difference": relative_difference,
                    "absolute_tolerance": tolerance.absolute,
                    "relative_tolerance": tolerance.relative,
                    "status": status,
                }
            )

    return pd.DataFrame.from_records(records)


def verify_import_independence(module_path: Path) -> list[str]:
    """Return prohibited internal imports found in the independent module."""

    source = module_path.read_text(encoding="utf-8")
    tree = ast.parse(source)
    violations: list[str] = []
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            for alias in node.names:
                if alias.name.startswith("ficc_liquidity"):
                    violations.append(alias.name)
        elif isinstance(node, ast.ImportFrom):
            module = node.module or ""
            if module.startswith("ficc_liquidity"):
                violations.append(module)
    return sorted(set(violations))


def _resolve(project_root: Path, value: str | None) -> Path | None:
    if value is None or str(value).strip() == "":
        return None
    path = Path(value)
    return path if path.is_absolute() else project_root / path


def _required_resolve(project_root: Path, value: str | None, label: str) -> Path:
    path = _resolve(project_root, value)
    if path is None:
        raise ValueError(f"A path is required for {label}")
    return path


def _write_table(frame: pd.DataFrame, path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    frame.to_csv(path, index=False, float_format="%.12f")


def run_verification(
    config_path: Path,
    production_results_override: Path | None = None,
    comparison_label_override: str | None = None,
) -> dict[str, Any]:
    """Execute Section 25 from flat files and write evidence artifacts."""

    config_path = config_path.resolve()
    project_root = config_path.parent.parent
    config = yaml.safe_load(config_path.read_text(encoding="utf-8"))
    if not isinstance(config, dict):
        raise ValueError("The independent verification config must be a mapping")

    inputs = config["inputs"]
    outputs = config["outputs"]
    comparison_config = config.get("comparison", {})

    members_path = _required_resolve(project_root, inputs["members"], "inputs.members")
    resources_path = _required_resolve(project_root, inputs["resources"], "inputs.resources")
    controls_path = _required_resolve(
        project_root, inputs["aggregate_controls"], "inputs.aggregate_controls"
    )

    members = pd.read_csv(members_path)
    resources = pd.read_csv(resources_path, keep_default_na=False)
    controls = pd.read_csv(controls_path)

    member_results = calculate_member_stress(members)
    qualified_resources = calculate_qualified_resources(resources)
    default_sets = select_default_sets(member_results)
    cover_results = calculate_cover_results(member_results, qualified_resources, default_sets)
    reconciliation = reconcile_aggregates(members, qualified_resources, controls)

    reference_path = production_results_override
    if reference_path is None:
        reference_path = _resolve(project_root, comparison_config.get("results_path"))
    elif not reference_path.is_absolute():
        reference_path = project_root / reference_path

    comparison_label = (
        comparison_label_override or comparison_config.get("label") or "not_configured"
    )
    tolerance = ComparisonTolerance(
        absolute=float(comparison_config.get("absolute_tolerance", 1.0e-8)),
        relative=float(comparison_config.get("relative_tolerance", 1.0e-8)),
    )

    if reference_path is not None and reference_path.exists():
        reference_results = pd.read_csv(reference_path)
        comparison = compare_results(cover_results, reference_results, tolerance)
        comparison_status = "PASS" if comparison["status"].eq("PASS").all() else "FAIL"
    else:
        comparison = pd.DataFrame(
            columns=[
                "scenario_id",
                "coverage_basis",
                "metric",
                "independent_value",
                "reference_value",
                "absolute_difference",
                "relative_difference",
                "absolute_tolerance",
                "relative_tolerance",
                "status",
            ]
        )
        comparison_status = "NOT_RUN"

    module_path = (
        project_root / "src" / "ficc_liquidity" / "validation" / "independent_implementation.py"
    )
    prohibited_imports = verify_import_independence(module_path)
    independence_status = "PASS" if not prohibited_imports else "FAIL"
    reconciliation_status = "PASS" if reconciliation["status"].eq("PASS").all() else "FAIL"

    output_paths: dict[str, Path] = {
        str(name): _required_resolve(project_root, str(value), f"outputs.{name}")
        for name, value in outputs.items()
    }
    _write_table(member_results, output_paths["member_calculations"])
    _write_table(qualified_resources, output_paths["qualified_resources"])
    _write_table(default_sets, output_paths["default_sets"])
    _write_table(cover_results, output_paths["cover_results"])
    _write_table(reconciliation, output_paths["aggregate_reconciliation"])
    _write_table(comparison, output_paths["calculation_comparison"])

    required_gates = [independence_status, reconciliation_status]
    if bool(comparison_config.get("required", True)):
        required_gates.append(comparison_status)
    overall_status = "PASS" if all(status == "PASS" for status in required_gates) else "FAIL"

    summary: dict[str, Any] = {
        "section": "25",
        "title": "Independent implementation verification",
        "overall_status": overall_status,
        "independence_status": independence_status,
        "prohibited_internal_imports": prohibited_imports,
        "aggregate_reconciliation_status": reconciliation_status,
        "comparison_status": comparison_status,
        "comparison_label": comparison_label,
        "comparison_path": str(reference_path) if reference_path is not None else None,
        "scenario_count": int(member_results["scenario_id"].nunique()),
        "member_scenario_count": len(member_results),
        "cover_result_count": len(cover_results),
        "aggregate_control_count": len(reconciliation),
        "aggregate_control_failures": int(reconciliation["status"].eq("FAIL").sum()),
        "comparison_failures": int(comparison["status"].eq("FAIL").sum())
        if not comparison.empty
        else 0,
        "formula_components": list(COMPONENT_COLUMNS),
        "production_functions_called": False,
    }

    summary_json = output_paths["summary_json"]
    summary_json.parent.mkdir(parents=True, exist_ok=True)
    summary_json.write_text(json.dumps(summary, indent=2), encoding="utf-8")

    evidence_lines = [
        "SECTION 25 â€” INDEPENDENT IMPLEMENTATION VERIFICATION",
        "=" * 57,
        f"Overall status: {overall_status}",
        f"Import independence: {independence_status}",
        f"Aggregate reconciliation: {reconciliation_status}",
        f"Calculation comparison: {comparison_status}",
        f"Comparison label: {comparison_label}",
        f"Scenarios: {summary['scenario_count']}",
        f"Member-scenario calculations: {summary['member_scenario_count']}",
        f"Cover results: {summary['cover_result_count']}",
        f"Aggregate controls: {summary['aggregate_control_count']}",
        f"Aggregate failures: {summary['aggregate_control_failures']}",
        f"Comparison failures: {summary['comparison_failures']}",
        "Production calculation functions called: NO",
        "",
        "Independent components:",
        *[f"- {component}" for component in COMPONENT_COLUMNS],
        "",
        "Files are calculated from CSV input contracts. The independent module does not import",
        "or call any production liquidity, stress, scenario, default-set, or resource functions.",
    ]
    evidence_txt = output_paths["evidence_txt"]
    evidence_txt.parent.mkdir(parents=True, exist_ok=True)
    evidence_txt.write_text("\n".join(evidence_lines) + "\n", encoding="utf-8")

    return summary


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--config",
        type=Path,
        default=Path("configs/independent_verification.yaml"),
    )
    parser.add_argument(
        "--production-results",
        type=Path,
        default=None,
        help="Optional exported production result CSV. No production functions are imported.",
    )
    parser.add_argument(
        "--comparison-label",
        type=str,
        default=None,
        help="Evidence label for the compared result set.",
    )
    return parser


def main() -> int:
    args = build_parser().parse_args()
    summary = run_verification(
        args.config,
        production_results_override=args.production_results,
        comparison_label_override=args.comparison_label,
    )
    print(json.dumps(summary, indent=2))
    return 0 if summary["overall_status"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
