"""Run Phase VI, Section 21 hypothetical scenarios."""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
from collections.abc import Mapping
from datetime import UTC, datetime
from pathlib import Path
from typing import Any, cast

import pandas as pd

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "src"
if str(SRC) not in sys.path:
    sys.path.insert(0, str(SRC))

from ficc_liquidity.scenarios.hypothetical_scenarios import (  # noqa: E402
    HypotheticalScenario,
    HypotheticalScenarioError,
    build_funding_config,
    build_haircut_config,
    build_integrated_config,
    build_settlement_config,
    build_treasury_scenarios,
    expand_treasury_shock,
    load_scenarios,
    load_settings,
    load_yaml,
    scenario_catalog_frame,
    treasury_shock_frame,
)
from ficc_liquidity.stress.collateral_haircut_stress import (  # noqa: E402
    run_model as run_haircut_model,
)
from ficc_liquidity.stress.integrated_stress import (  # noqa: E402
    dataframe_digest,
    read_table,
    run_integrated_stress,
)
from ficc_liquidity.stress.repo_funding_stress import (  # noqa: E402
    run_model as run_funding_model,
)
from ficc_liquidity.stress.settlement_fail_stress import (  # noqa: E402
    run_model as run_settlement_model,
)
from ficc_liquidity.stress.treasury_yield_shock import (  # noqa: E402
    TreasuryYieldShockModel,
    load_stress_config,
)

FUNDING_ACCOUNTING_CHECKS: frozenset[str] = frozenset(
    {
        "scenario_cashflow_rows_complete",
        "member_scenario_rows_complete",
        "scenario_summary_complete",
        "unique_scenario_member_buckets",
        "nonnegative_stress_components",
        "sofr_rate_identity",
        "all_in_funding_rate_identity",
        "rollover_failure_bounded_by_roll_amount",
        "funding_stress_decomposition_identity",
        "stressed_liquidity_need_identity",
        "stressed_need_not_below_baseline",
        "stressed_headroom_identity",
        "stressed_shortfall_identity",
        "synthetic_members_only",
        "deterministic_reproduction",
    }
)

SETTLEMENT_ACCOUNTING_CHECKS: frozenset[str] = frozenset(
    {
        "complete_cashflow_matrix",
        "complete_member_matrix",
        "unique_cashflow_keys",
        "finite_nonnegative_stress_amounts",
        "fails_to_receive_bounds",
        "fails_to_deliver_bounds",
        "replacement_liquidity_identity",
        "delayed_payment_recovery_bounds",
        "combined_stress_identity",
        "liquidity_headroom_identity",
        "zero_shock_control",
        "severity_monotonicity",
        "scenario_aggregation_complete",
        "synthetic_identity_controls",
    }
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Run the controlled Section 21 hypothetical scenario framework."
    )
    parser.add_argument(
        "--config",
        type=Path,
        default=ROOT / "configs" / "hypothetical_scenarios.yaml",
    )
    parser.add_argument(
        "--smoke",
        action="store_true",
        help="Run three representative scenarios instead of the complete library.",
    )
    return parser.parse_args()


def _mapping(value: object, label: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise HypotheticalScenarioError(f"{label} must be a YAML mapping.")
    return cast(dict[str, Any], value)


def _candidate_list(source: Mapping[str, Any], key: str) -> list[str]:
    raw = source.get(key)
    if not isinstance(raw, list) or not raw:
        raise HypotheticalScenarioError(f"source.{key} must be a nonempty list.")
    return [str(value) for value in raw]


def discover_input(candidates: list[str]) -> Path:
    for candidate in candidates:
        path = ROOT / candidate
        if path.exists():
            return path
    raise HypotheticalScenarioError(f"No controlled input exists among: {candidates}")


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def _write_frame(
    frame: pd.DataFrame,
    stem: Path,
    *,
    write_csv: bool,
    write_parquet: bool,
) -> list[Path]:
    written: list[Path] = []
    if write_csv:
        csv_path = stem.with_suffix(".csv")
        frame.to_csv(csv_path, index=False)
        written.append(csv_path)
    if write_parquet:
        parquet_path = stem.with_suffix(".parquet")
        try:
            frame.to_parquet(parquet_path, index=False)
            written.append(parquet_path)
        except (ImportError, ModuleNotFoundError, ValueError) as exc:
            print(f"Parquet output skipped: {exc}")
    return written


def _required_checks_pass(
    checks: Mapping[str, bool],
    required: frozenset[str] | None = None,
) -> bool:
    selected = set(checks) if required is None else set(required)
    missing = selected - set(checks)
    if missing:
        raise HypotheticalScenarioError(f"Required component checks are missing: {sorted(missing)}")
    return all(bool(checks[name]) for name in selected)


def _target_rows(frame: pd.DataFrame, scenario_name: str) -> pd.DataFrame:
    selected = frame.loc[frame["scenario_name"].astype(str).eq(scenario_name)].copy()
    if selected.empty:
        raise HypotheticalScenarioError(
            f"Component output is missing target scenario: {scenario_name}"
        )
    return selected


def _annotate(
    frame: pd.DataFrame,
    scenario: HypotheticalScenario,
) -> pd.DataFrame:
    result = frame.copy(deep=True)
    result["scenario_label"] = scenario.label
    result["scenario_family"] = scenario.family
    result["scenario_severity"] = scenario.severity
    result["display_order"] = scenario.display_order
    result["hypothetical_value_class"] = "hypothetical_assumptions_on_synthetic_members"
    result["actual_ficc_participant"] = False
    result["participant_level_inference"] = False
    return result


def _check_rows(
    scenario: HypotheticalScenario,
    component: str,
    checks: Mapping[str, bool],
    required: frozenset[str] | None,
) -> list[dict[str, object]]:
    required_names = set(checks) if required is None else set(required)
    return [
        {
            "scenario_name": scenario.name,
            "display_order": scenario.display_order,
            "component": component,
            "check_name": name,
            "required_for_section21": name in required_names,
            "passed": bool(value),
        }
        for name, value in sorted(checks.items())
    ]


def _manifest(
    path: Path,
    artifacts: list[tuple[Path, str, int | None]],
) -> None:
    records: list[dict[str, object]] = []
    generated_at = datetime.now(UTC).isoformat()
    for artifact, value_class, row_count in artifacts:
        records.append(
            {
                "section": 21,
                "artifact_path": artifact.relative_to(ROOT).as_posix(),
                "artifact_name": artifact.name,
                "value_class": value_class,
                "row_count": "" if row_count is None else row_count,
                "sha256": _sha256(artifact),
                "generated_at_utc": generated_at,
                "actual_ficc_participant": False,
                "participant_level_inference": False,
            }
        )
    path.parent.mkdir(parents=True, exist_ok=True)
    pd.DataFrame.from_records(records).to_csv(path, index=False)


def run() -> int:
    args = parse_args()
    config = load_yaml(args.config)
    settings = load_settings(config, ROOT)
    scenarios = load_scenarios(config, settings.guardrails)

    if args.smoke:
        smoke_names = {
            "moderate_stress",
            "curve_steepening",
            "combined_systemic_stress",
        }
        scenarios = tuple(scenario for scenario in scenarios if scenario.name in smoke_names)

    source = settings.source
    baseline_cashflow_path = discover_input(_candidate_list(source, "baseline_cashflow_candidates"))
    baseline_summary_path = discover_input(_candidate_list(source, "baseline_summary_candidates"))
    member_path = discover_input(_candidate_list(source, "member_profile_candidates"))
    treasury_position_path = discover_input(_candidate_list(source, "treasury_position_candidates"))

    baseline_cashflows = read_table(baseline_cashflow_path)
    baseline_summary = read_table(baseline_summary_path)
    members = read_table(member_path)
    treasury_positions = read_table(treasury_position_path)

    treasury_config_path = ROOT / str(source["treasury_config"])
    funding_config_path = ROOT / str(source["funding_config"])
    haircut_config_path = ROOT / str(source["haircut_config"])
    settlement_config_path = ROOT / str(source["settlement_config"])
    integrated_config_path = ROOT / str(source["integrated_config"])

    treasury_config = load_stress_config(treasury_config_path)
    treasury_input = treasury_config.get("input")
    if isinstance(treasury_input, dict):
        treasury_input["required_member_id_pattern"] = r"^SYN-MBR-[0-9]{4}$"
    funding_base = load_yaml(funding_config_path)
    haircut_base = load_yaml(haircut_config_path)
    settlement_base = load_yaml(settlement_config_path)
    integrated_base = load_yaml(integrated_config_path)

    catalog = scenario_catalog_frame(scenarios, treasury_config)
    treasury_shocks = treasury_shock_frame(scenarios, treasury_config)
    treasury_scenarios = build_treasury_scenarios(scenarios, treasury_config)
    if not treasury_scenarios:
        raise HypotheticalScenarioError("At least one hypothetical Treasury scenario is required.")
    treasury_result = TreasuryYieldShockModel(treasury_config).run(
        treasury_positions,
        treasury_scenarios,
    )
    treasury_summary = treasury_result.member_summary

    member_outputs: list[pd.DataFrame] = []
    summary_outputs: list[pd.DataFrame] = []
    control_outputs: list[pd.DataFrame] = []
    component_rows: list[dict[str, object]] = []
    check_rows: list[dict[str, object]] = []
    integrated_check_sets: dict[str, dict[str, bool]] = {}

    for scenario in scenarios:
        funding_config = build_funding_config(
            funding_base,
            scenario,
            settings.model_version,
        )
        (
            funding_cashflows,
            funding_members,
            funding_summary,
            funding_validation,
        ) = run_funding_model(
            baseline_cashflows,
            members,
            funding_config,
        )
        funding_checks = dict(funding_validation.checks)
        funding_required_pass = _required_checks_pass(
            funding_checks,
            FUNDING_ACCOUNTING_CHECKS,
        )
        check_rows.extend(
            _check_rows(
                scenario,
                "repo_funding",
                funding_checks,
                FUNDING_ACCOUNTING_CHECKS,
            )
        )

        haircut_config = build_haircut_config(
            haircut_base,
            scenario,
            settings.model_version,
        )
        haircut_result = run_haircut_model(
            members,
            baseline_cashflows,
            haircut_config,
        )
        haircut_checks = dict(haircut_result.checks)
        haircut_required_pass = _required_checks_pass(haircut_checks)
        check_rows.extend(
            _check_rows(
                scenario,
                "collateral_haircut",
                haircut_checks,
                None,
            )
        )

        settlement_config = build_settlement_config(
            settlement_base,
            scenario,
            settings.model_version,
        )
        settlement_result = run_settlement_model(
            baseline_cashflows,
            members,
            funding_cashflows,
            settlement_config,
        )
        settlement_checks = dict(settlement_result.checks)
        settlement_required_pass = _required_checks_pass(
            settlement_checks,
            SETTLEMENT_ACCOUNTING_CHECKS,
        )
        check_rows.extend(
            _check_rows(
                scenario,
                "settlement_fail",
                settlement_checks,
                SETTLEMENT_ACCOUNTING_CHECKS,
            )
        )

        treasury_active = bool(expand_treasury_shock(scenario, treasury_config))
        integrated_config = build_integrated_config(
            integrated_base,
            scenario,
            settings.model_version,
            treasury_active,
        )
        integrated_result = run_integrated_stress(
            baseline_summary,
            funding_members,
            haircut_result.member_summary,
            treasury_summary,
            settlement_result.cashflows,
            integrated_config,
        )
        integrated_checks = dict(integrated_result.checks)
        integrated_check_sets[scenario.name] = integrated_checks
        integrated_required_pass = _required_checks_pass(integrated_checks)
        check_rows.extend(
            _check_rows(
                scenario,
                "integrated_stress",
                integrated_checks,
                None,
            )
        )

        target_members = _annotate(
            _target_rows(integrated_result.member_results, scenario.name),
            scenario,
        )
        target_summary = _annotate(
            _target_rows(integrated_result.scenario_summary, scenario.name),
            scenario,
        )
        target_controls = _annotate(
            _target_rows(
                integrated_result.double_count_controls,
                scenario.name,
            ),
            scenario,
        )
        member_outputs.append(target_members)
        summary_outputs.append(target_summary)
        control_outputs.append(target_controls)

        funding_target = _target_rows(funding_summary, scenario.name).iloc[0]
        haircut_target = _target_rows(
            haircut_result.scenario_summary,
            scenario.name,
        ).iloc[0]
        settlement_target = _target_rows(
            settlement_result.scenario_summary,
            scenario.name,
        ).iloc[0]
        integrated_target = target_summary.iloc[0]
        component_rows.append(
            {
                "scenario_name": scenario.name,
                "display_order": scenario.display_order,
                "scenario_family": scenario.family,
                "treasury_active": treasury_active,
                "maximum_absolute_treasury_shock_bp": (
                    max(
                        abs(value)
                        for value in expand_treasury_shock(
                            scenario,
                            treasury_config,
                        ).values()
                    )
                    if treasury_active
                    else 0.0
                ),
                "funding_stress_outflow_usd": float(
                    funding_target["incremental_repo_funding_stress_outflow_usd"]
                ),
                "haircut_requirement_usd": float(
                    haircut_target["additional_collateral_requirement_total_usd"]
                ),
                "settlement_stress_usd": float(
                    settlement_target["total_incremental_combined_stress_usd"]
                ),
                "stressed_liquidity_requirement_usd": float(
                    integrated_target["total_stressed_liquidity_requirement_usd"]
                ),
                "aggregate_aqlr_usd": float(
                    integrated_target["total_available_qualified_liquid_resources_usd"]
                ),
                "aggregate_lcr": float(integrated_target["aggregate_liquidity_coverage_ratio"]),
                "funding_required_checks_pass": funding_required_pass,
                "haircut_required_checks_pass": haircut_required_pass,
                "settlement_required_checks_pass": settlement_required_pass,
                "integrated_checks_pass": integrated_required_pass,
            }
        )

    member_results = pd.concat(member_outputs, ignore_index=True)
    scenario_summary = pd.concat(summary_outputs, ignore_index=True)
    double_count_controls = pd.concat(control_outputs, ignore_index=True)
    component_summary = pd.DataFrame.from_records(component_rows)
    component_checks = pd.DataFrame.from_records(check_rows)

    for frame, columns in (
        (member_results, ["display_order", "member_id"]),
        (scenario_summary, ["display_order"]),
        (double_count_controls, ["display_order", "member_id"]),
        (component_summary, ["display_order"]),
        (component_checks, ["display_order", "component", "check_name"]),
    ):
        frame.sort_values(columns, kind="stable", inplace=True)
        frame.reset_index(drop=True, inplace=True)

    tolerance = settings.tolerance_usd
    expected_requirement = member_results[
        [
            "settlement_liquidity_need_usd",
            "repo_rollover_need_usd",
            "incremental_funding_cost_usd",
            "additional_haircut_requirement_usd",
            "treasury_liquidation_loss_usd",
            "settlement_fail_requirement_usd",
            "concentration_adjustment_usd",
            "operational_liquidity_buffer_usd",
        ]
    ].sum(axis=1)

    catalog_repeat = scenario_catalog_frame(scenarios, treasury_config)
    treasury_repeat = treasury_shock_frame(scenarios, treasury_config)
    checks = {
        "all_required_scenarios_created": len(catalog) == len(scenarios),
        "hypothetical_treasury_matrix_created": not treasury_shocks.empty,
        "scenario_definitions_deterministic": (
            catalog.equals(catalog_repeat) and treasury_shocks.equals(treasury_repeat)
        ),
        "all_component_required_checks_pass": bool(
            component_summary[
                [
                    "funding_required_checks_pass",
                    "haircut_required_checks_pass",
                    "settlement_required_checks_pass",
                    "integrated_checks_pass",
                ]
            ]
            .astype(bool)
            .all()
            .all()
        ),
        "all_integrated_checks_pass": all(
            all(values.values()) for values in integrated_check_sets.values()
        ),
        "stressed_requirement_identity": bool(
            (expected_requirement - member_results["stressed_liquidity_requirement_usd"])
            .abs()
            .le(tolerance)
            .all()
        ),
        "double_count_controls_pass": bool(
            double_count_controls["double_count_control_pass"].astype(bool).all()
        ),
        "synthetic_members_only": bool(
            not member_results["actual_ficc_participant"].astype(bool).any()
            and not member_results["participant_level_inference"].astype(bool).any()
        ),
        "unique_scenario_member_keys": not bool(
            member_results.duplicated(["scenario_name", "member_id"]).any()
        ),
    }

    settings.output_directory.mkdir(parents=True, exist_ok=True)
    settings.evidence_directory.mkdir(parents=True, exist_ok=True)
    settings.manifest_path.parent.mkdir(parents=True, exist_ok=True)

    frame_map = {
        "hypothetical_scenario_catalog": catalog,
        "hypothetical_treasury_shocks": treasury_shocks,
        "hypothetical_component_summary": component_summary,
        "hypothetical_component_checks": component_checks,
        "hypothetical_scenario_member_results": member_results,
        "hypothetical_scenario_summary": scenario_summary,
        "hypothetical_scenario_double_count_controls": double_count_controls,
    }
    output_files: list[Path] = []
    artifact_records: list[tuple[Path, str, int | None]] = []
    for name, frame in frame_map.items():
        written = _write_frame(
            frame,
            settings.output_directory / name,
            write_csv=settings.write_csv,
            write_parquet=settings.write_parquet,
        )
        output_files.extend(written)
        value_class = (
            "hypothetical_assumption"
            if name
            in {
                "hypothetical_scenario_catalog",
                "hypothetical_treasury_shocks",
            }
            else "modeled_synthetic_result"
        )
        artifact_records.extend((path, value_class, len(frame)) for path in written)

    evidence = {
        "section": 21,
        "model_version": settings.model_version,
        "generated_at_utc": datetime.now(UTC).isoformat(),
        "smoke_mode": bool(args.smoke),
        "scenario_count": len(scenarios),
        "member_result_rows": len(member_results),
        "catalog_digest": dataframe_digest(catalog),
        "member_result_digest": dataframe_digest(member_results),
        "checks": checks,
        "actual_ficc_participant": False,
        "participant_level_inference": False,
        "status": "PASS" if all(checks.values()) else "FAIL",
    }
    evidence_json = settings.evidence_directory / (
        "section21_hypothetical_scenarios_smoke.json"
        if args.smoke
        else "section21_hypothetical_scenarios.json"
    )
    evidence_json.write_text(
        json.dumps(evidence, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    evidence_md = evidence_json.with_suffix(".md")
    evidence_md.write_text(
        "\n".join(
            [
                "# Section 21 â€” Hypothetical Scenarios",
                "",
                f"- Status: **{evidence['status']}**",
                f"- Scenario count: {len(scenarios)}",
                f"- Member-result rows: {len(member_results)}",
                f"- Smoke mode: {bool(args.smoke)}",
                "",
                "## Validation checks",
                "",
                *[f"- {'PASS' if value else 'FAIL'} â€” {name}" for name, value in checks.items()],
                "",
                "All member-level observations are fictional synthetic records.",
                "No result identifies or infers an actual FICC participant.",
                "",
            ]
        ),
        encoding="utf-8",
    )
    artifact_records.extend(
        [
            (args.config.resolve(), "hypothetical_assumption", None),
            (evidence_json, "validation_evidence", None),
            (evidence_md, "validation_evidence", None),
        ]
    )
    _manifest(settings.manifest_path, artifact_records)

    print(f"Section 21 status: {evidence['status']}")
    print(f"Scenarios completed: {len(scenarios)}")
    print(f"Manifest: {settings.manifest_path.relative_to(ROOT)}")
    if not all(checks.values()):
        failed = [name for name, value in checks.items() if not value]
        raise HypotheticalScenarioError(f"Section 21 validation failed: {failed}")
    return 0


if __name__ == "__main__":
    raise SystemExit(run())
