"""Run Phase V, Section 19 integrated stressed-liquidity requirements."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import re
import sys
from copy import deepcopy
from datetime import UTC, datetime
from pathlib import Path
from typing import Any, cast

import pandas as pd

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "src"
if str(SRC) not in sys.path:
    sys.path.insert(0, str(SRC))

from ficc_liquidity.stress.integrated_stress import (  # noqa: E402
    IntegratedStressError,
    dataframe_digest,
    load_config,
    load_settings,
    read_table,
    run_integrated_stress,
)
from ficc_liquidity.stress.treasury_yield_shock import (  # noqa: E402
    StressRunResult,
    TreasuryYieldShockModel,
    load_stress_config,
)


def parse_args() -> argparse.Namespace:
    """Parse controlled Section 19 command-line arguments."""
    parser = argparse.ArgumentParser(
        description="Run Phase V Section 19 integrated stressed-liquidity requirements."
    )
    parser.add_argument(
        "--config",
        type=Path,
        default=ROOT / "configs" / "integrated_stress_engine.yaml",
    )
    parser.add_argument("--baseline", type=Path, default=None)
    parser.add_argument("--funding", type=Path, default=None)
    parser.add_argument("--haircut", type=Path, default=None)
    parser.add_argument("--treasury", type=Path, default=None)
    parser.add_argument("--settlement-fail", type=Path, default=None)
    parser.add_argument("--members", type=Path, default=None)
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=ROOT / "reports" / "tables",
    )
    parser.add_argument(
        "--evidence-dir",
        type=Path,
        default=ROOT / "reports" / "evidence",
    )
    parser.add_argument(
        "--manifest",
        type=Path,
        default=ROOT / "data" / "manifests" / "integrated_stress_engine_manifest.csv",
    )
    parser.add_argument("--smoke", action="store_true")
    return parser.parse_args()


def _mapping(value: object, label: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise IntegratedStressError(f"{label} must be a YAML mapping.")
    return cast(dict[str, Any], value)


def discover_input(root: Path, candidates: list[str]) -> Path | None:
    """Return the first existing controlled input candidate."""
    for candidate in candidates:
        path = root / candidate
        if path.exists():
            return path
    return None


def _candidate_list(source: dict[str, Any], key: str) -> list[str]:
    raw = source.get(key)
    if not isinstance(raw, list) or not raw:
        raise IntegratedStressError(f"source.{key} must be a nonempty list.")
    return [str(value) for value in raw]


def _required_input(
    supplied: Path | None,
    root: Path,
    source: dict[str, Any],
    key: str,
    label: str,
) -> Path:
    path = supplied or discover_input(root, _candidate_list(source, key))
    if path is None:
        raise IntegratedStressError(
            f"{label} was not found. Supply the corresponding command-line input."
        )
    return path


def file_hash(path: Path) -> str:
    """Return a file SHA-256 digest."""
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def write_frame(
    frame: pd.DataFrame,
    stem: Path,
    *,
    write_csv: bool,
    write_parquet: bool,
) -> list[Path]:
    """Write a controlled result frame."""
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


def _treasury_mapping(config: dict[str, Any]) -> list[dict[str, Any]]:
    adapter = _mapping(config.get("treasury_adapter"), "treasury_adapter")
    raw = adapter.get("maturity_mapping")
    if not isinstance(raw, list) or not raw:
        raise IntegratedStressError("treasury_adapter.maturity_mapping must be a nonempty list.")
    mappings = [_mapping(item, "treasury maturity mapping") for item in raw]
    weight_sums: dict[str, float] = {}
    for mapping in mappings:
        source_column = str(mapping.get("source_column", "")).strip()
        target_bucket = str(mapping.get("target_bucket", "")).strip()
        weight_raw = mapping.get("weight")
        if (
            not source_column
            or not target_bucket
            or isinstance(weight_raw, bool)
            or not isinstance(weight_raw, (int, float))
        ):
            raise IntegratedStressError(
                "Every Treasury adapter mapping requires source_column, "
                "target_bucket, and numeric weight."
            )
        weight = float(weight_raw)
        if not math.isfinite(weight) or weight <= 0.0:
            raise IntegratedStressError(
                "Treasury adapter mapping weights must be finite and positive."
            )
        weight_sums[source_column] = weight_sums.get(source_column, 0.0) + weight
    invalid = {
        source_column: weight
        for source_column, weight in weight_sums.items()
        if not math.isclose(weight, 1.0, abs_tol=1e-12)
    }
    if invalid:
        raise IntegratedStressError(
            f"Treasury adapter weights must sum to one for each source column: {invalid}"
        )
    return mappings


def build_treasury_adapter_positions(
    profiles: pd.DataFrame,
    config: dict[str, Any],
    synthetic_id_pattern: str,
) -> pd.DataFrame:
    """Bridge Section 12 maturity buckets to the validated Section 15 model."""
    if profiles.empty:
        raise IntegratedStressError("Synthetic member profiles are empty.")
    mappings = _treasury_mapping(config)
    required_columns = {
        "member_id",
        *(str(mapping["source_column"]) for mapping in mappings),
    }
    missing = sorted(required_columns - set(profiles.columns))
    if missing:
        raise IntegratedStressError(
            f"Synthetic profiles are missing Treasury adapter fields: {missing}"
        )
    frame = profiles.copy(deep=True)
    frame["member_id"] = frame["member_id"].astype("string").str.strip()
    invalid_ids = [
        member_id
        for member_id in frame["member_id"].astype(str)
        if re.fullmatch(synthetic_id_pattern, member_id) is None
    ]
    if invalid_ids:
        raise IntegratedStressError(
            f"Treasury adapter received invalid synthetic identifiers: {sorted(set(invalid_ids))}"
        )
    source_columns = sorted({str(mapping["source_column"]) for mapping in mappings})
    for column in source_columns:
        frame[column] = pd.to_numeric(frame[column], errors="coerce")
        if frame[column].isna().any() or bool((frame[column] < 0.0).any()):
            raise IntegratedStressError(
                f"Treasury adapter field {column} must be finite and nonnegative."
            )
    records: list[dict[str, object]] = []
    as_of_column = "as_of_date" if "as_of_date" in frame.columns else None
    for _, row in frame.iterrows():
        for mapping in mappings:
            source_column = str(mapping["source_column"])
            records.append(
                {
                    "member_id": str(row["member_id"]),
                    "as_of_date": (row[as_of_column] if as_of_column is not None else pd.NaT),
                    "maturity_bucket": str(mapping["target_bucket"]),
                    "market_value_usd": float(row[source_column]) * float(mapping["weight"]),
                    "valuation_source": (f"section19_bucket_bridge:{source_column}"),
                }
            )
    positions = pd.DataFrame.from_records(records)
    if positions.empty:
        raise IntegratedStressError("Treasury adapter produced no synthetic position records.")
    return positions


def build_treasury_adapter_summary(
    profiles: pd.DataFrame,
    config: dict[str, Any],
    required_scenarios: set[str],
    synthetic_id_pattern: str,
    root: Path,
) -> tuple[pd.DataFrame, StressRunResult]:
    """Run the validated Section 15 model on a controlled Section 12 bucket bridge."""
    source = _mapping(config.get("source"), "source")
    config_path = root / str(
        source.get("treasury_yield_config", "configs/treasury_yield_stress.yaml")
    )
    treasury_config = deepcopy(load_stress_config(config_path))
    treasury_config["input"]["required_member_id_pattern"] = synthetic_id_pattern
    positions = build_treasury_adapter_positions(profiles, config, synthetic_id_pattern)
    configured_scenarios = {
        str(scenario.get("name")): scenario
        for scenario in treasury_config["scenarios"]
        if bool(scenario.get("enabled", True))
    }
    missing = sorted(required_scenarios - set(configured_scenarios))
    if missing:
        raise IntegratedStressError(
            f"Section 15 configuration lacks mapped Treasury scenarios: {missing}"
        )
    selected = [configured_scenarios[name] for name in sorted(required_scenarios)]
    stress_result = TreasuryYieldShockModel(treasury_config).run(positions, scenarios=selected)
    summary = stress_result.member_summary.copy(deep=True)
    summary["value_class"] = "synthetic"
    summary["actual_ficc_participant"] = False
    summary["participant_level_inference"] = False
    return summary, stress_result


def treasury_summary_is_compatible(
    treasury: pd.DataFrame,
    required_scenarios: set[str],
    synthetic_id_pattern: str,
) -> bool:
    """Return whether an existing Section 15 summary can be joined safely."""
    required = {"scenario_name", "member_id", "treasury_loss_usd"}
    if treasury.empty or not required.issubset(treasury.columns):
        return False
    if not required_scenarios.issubset(set(treasury["scenario_name"].astype(str))):
        return False
    return bool(
        treasury["member_id"]
        .astype(str)
        .map(lambda value: re.fullmatch(synthetic_id_pattern, value) is not None)
        .all()
    )


def write_manifest(
    manifest_path: Path,
    files: list[tuple[Path, str, int | None]],
) -> None:
    """Write source-lineage and output-integrity metadata."""
    generated_at = datetime.now(UTC).isoformat()
    records = [
        {
            "section": 19,
            "artifact_path": str(path.resolve()),
            "artifact_name": path.name,
            "value_class": value_class,
            "row_count": row_count if row_count is not None else "",
            "sha256": file_hash(path),
            "generated_at_utc": generated_at,
            "actual_ficc_participant": False,
            "participant_level_inference": False,
        }
        for path, value_class, row_count in files
    ]
    manifest_path.parent.mkdir(parents=True, exist_ok=True)
    pd.DataFrame.from_records(records).to_csv(manifest_path, index=False)


def _json_records(frame: pd.DataFrame) -> list[dict[str, object]]:
    safe = frame.replace([math.inf, -math.inf], None)
    return cast(list[dict[str, object]], safe.to_dict(orient="records"))


def _write_evidence_markdown(
    path: Path,
    evidence: dict[str, object],
    scenario_summary: pd.DataFrame,
) -> None:
    checks = cast(dict[str, bool], evidence["checks"])
    lines = [
        "# Section 19 â€” Integrated Stressed Liquidity Requirement",
        "",
        f"- Generated at: `{evidence['generated_at_utc']}`",
        f"- Run type: `{evidence['run_type']}`",
        f"- Model version: `{evidence['model_version']}`",
        f"- Deterministic reproduction: `{evidence['deterministic_reproduction']}`",
        f"- Final decision: `{evidence['final_decision']}`",
        "",
        "## Validation gates",
        "",
        "| Gate | Result |",
        "|---|---|",
    ]
    lines.extend(
        f"| {name.replace('_', ' ')} | {'PASS' if passed else 'FAIL'} |"
        for name, passed in checks.items()
    )
    lines.extend(
        [
            "",
            "## Scenario results",
            "",
            "| Scenario | Requirement (USD) | AQLR (USD) | LCR | Breach members |",
            "|---|---:|---:|---:|---:|",
        ]
    )
    for _, row in scenario_summary.sort_values("severity_rank").iterrows():
        lines.append(
            "| {scenario} | {requirement:,.2f} | {resources:,.2f} | "
            "{lcr:.6f} | {breaches} |".format(
                scenario=row["scenario_name"],
                requirement=float(row["total_stressed_liquidity_requirement_usd"]),
                resources=float(row["total_available_qualified_liquid_resources_usd"]),
                lcr=float(row["aggregate_liquidity_coverage_ratio"]),
                breaches=int(row["breach_member_count"]),
            )
        )
    lines.extend(
        [
            "",
            "## No-double-counting disposition",
            "",
            "The engine selects atomic Section 16 repo-rollover and funding-cost "
            "components instead of the Section 16 composite outflow. It selects "
            "the Section 18 settlement-only requirement instead of the Section 18 "
            "combined settlement-and-funding outflow. It uses the Section 14 "
            "modeled AQLR numerator rather than the Section 17 stressed AQLR field, "
            "because the Section 17 field already subtracts posted collateral and "
            "would duplicate the separately included haircut requirement.",
            "",
            "All member records are fictional synthetic observations. No output "
            "identifies or infers an actual FICC participant.",
            "",
        ]
    )
    path.write_text("\n".join(lines), encoding="utf-8")


def main() -> int:
    """Execute the controlled Section 19 workflow."""
    args = parse_args()
    config = load_config(args.config)
    settings = load_settings(config)
    source = _mapping(config.get("source"), "source")
    output = _mapping(config.get("output"), "output")

    baseline_path = _required_input(
        args.baseline,
        ROOT,
        source,
        "baseline_summary_candidates",
        "Section 14 baseline summary",
    )
    funding_path = _required_input(
        args.funding,
        ROOT,
        source,
        "funding_summary_candidates",
        "Section 16 funding summary",
    )
    haircut_path = _required_input(
        args.haircut,
        ROOT,
        source,
        "haircut_summary_candidates",
        "Section 17 haircut summary",
    )
    settlement_path = _required_input(
        args.settlement_fail,
        ROOT,
        source,
        "settlement_fail_cashflow_candidates",
        "Section 18 settlement-fail cash flows",
    )

    baseline = read_table(baseline_path)
    funding = read_table(funding_path)
    haircut = read_table(haircut_path)
    settlement_fail = read_table(settlement_path)

    required_treasury_scenarios = {
        scenario.treasury_scenario_name
        for scenario in settings.scenarios
        if scenario.treasury_scenario_name.upper() != "NONE"
    }
    treasury_path = args.treasury or discover_input(
        ROOT, _candidate_list(source, "treasury_summary_candidates")
    )
    treasury_adapter_result: StressRunResult | None = None
    profiles_path: Path | None = None
    profiles_row_count: int | None = None
    treasury_config_path: Path | None = None
    treasury_source: str
    if treasury_path is not None:
        treasury = read_table(treasury_path)
        if treasury_summary_is_compatible(
            treasury,
            required_treasury_scenarios,
            settings.synthetic_id_pattern,
        ):
            treasury_source = str(treasury_path.resolve())
        else:
            treasury_path = None
    if treasury_path is None:
        profiles_path = _required_input(
            args.members,
            ROOT,
            source,
            "synthetic_member_profile_candidates",
            "Section 12 synthetic member profiles",
        )
        profiles = read_table(profiles_path)
        profiles_row_count = len(profiles)
        treasury_config_path = ROOT / str(
            source.get(
                "treasury_yield_config",
                "configs/treasury_yield_stress.yaml",
            )
        )
        treasury, treasury_adapter_result = build_treasury_adapter_summary(
            profiles,
            config,
            required_treasury_scenarios,
            settings.synthetic_id_pattern,
            ROOT,
        )
        treasury_source = f"SECTION19_CONTROLLED_ADAPTER_FROM_{profiles_path.resolve()}"

    first = run_integrated_stress(
        baseline,
        funding,
        haircut,
        treasury,
        settlement_fail,
        config,
    )
    second = run_integrated_stress(
        baseline,
        funding,
        haircut,
        treasury,
        settlement_fail,
        config,
    )
    deterministic = (
        dataframe_digest(first.member_results) == dataframe_digest(second.member_results)
        and dataframe_digest(first.scenario_summary) == dataframe_digest(second.scenario_summary)
        and dataframe_digest(first.double_count_controls)
        == dataframe_digest(second.double_count_controls)
    )

    args.output_dir.mkdir(parents=True, exist_ok=True)
    args.evidence_dir.mkdir(parents=True, exist_ok=True)
    write_csv = bool(output.get("write_csv", True))
    write_parquet = bool(output.get("write_parquet", True))
    suffix = "_smoke" if args.smoke else ""
    written: list[tuple[Path, str, int | None]] = []

    member_files = write_frame(
        first.member_results,
        args.output_dir / f"integrated_stress_member_results{suffix}",
        write_csv=write_csv,
        write_parquet=write_parquet,
    )
    written.extend((path, "modeled", len(first.member_results)) for path in member_files)
    scenario_files = write_frame(
        first.scenario_summary,
        args.output_dir / f"integrated_stress_scenario_summary{suffix}",
        write_csv=write_csv,
        write_parquet=write_parquet,
    )
    written.extend((path, "modeled", len(first.scenario_summary)) for path in scenario_files)
    control_files = write_frame(
        first.double_count_controls,
        args.output_dir / f"integrated_stress_double_count_controls{suffix}",
        write_csv=write_csv,
        write_parquet=write_parquet,
    )
    written.extend((path, "modeled", len(first.double_count_controls)) for path in control_files)

    if treasury_adapter_result is not None:
        adapter_files = write_frame(
            treasury,
            args.output_dir / f"treasury_yield_stress_member_summary_section19_adapter{suffix}",
            write_csv=write_csv,
            write_parquet=write_parquet,
        )
        written.extend((path, "modeled", len(treasury)) for path in adapter_files)
        adapter_position_files = write_frame(
            treasury_adapter_result.positions,
            args.output_dir / f"treasury_yield_stress_positions_section19_adapter{suffix}",
            write_csv=write_csv,
            write_parquet=write_parquet,
        )
        written.extend(
            (path, "modeled", len(treasury_adapter_result.positions))
            for path in adapter_position_files
        )

    checks = dict(first.checks)
    checks["deterministic_reproduction"] = deterministic
    final_pass = first.passed and deterministic
    generated_at = datetime.now(UTC).isoformat()
    evidence: dict[str, object] = {
        "section": 19,
        "model": "integrated_stressed_liquidity_requirement",
        "model_version": settings.model_version,
        "generated_at_utc": generated_at,
        "run_type": "SMOKE_TEST" if args.smoke else "CONTROLLED_MODEL_RUN",
        "sources": {
            "baseline": str(baseline_path.resolve()),
            "funding": str(funding_path.resolve()),
            "haircut": str(haircut_path.resolve()),
            "treasury": treasury_source,
            "treasury_adapter_config": (
                str(treasury_config_path.resolve()) if treasury_config_path is not None else ""
            ),
            "settlement_fail": str(settlement_path.resolve()),
        },
        "member_scenario_rows": len(first.member_results),
        "scenario_rows": len(first.scenario_summary),
        "double_count_control_rows": len(first.double_count_controls),
        "checks": checks,
        "deterministic_reproduction": deterministic,
        "scenario_results": _json_records(first.scenario_summary),
        "final_decision": "PASS" if final_pass else "FAIL",
        "actual_ficc_participant": False,
        "participant_level_inference": False,
    }
    evidence_json = args.evidence_dir / f"section19_integrated_stress_engine{suffix}.json"
    evidence_md = args.evidence_dir / f"section19_integrated_stress_engine{suffix}.md"
    evidence_json.write_text(
        json.dumps(evidence, indent=2, sort_keys=True, allow_nan=False) + "\n",
        encoding="utf-8",
    )
    _write_evidence_markdown(evidence_md, evidence, first.scenario_summary)
    written.extend(
        [
            (args.config, "assumed", None),
            (baseline_path, "modeled", len(baseline)),
            (funding_path, "modeled", len(funding)),
            (haircut_path, "modeled", len(haircut)),
            (settlement_path, "modeled", len(settlement_fail)),
            (evidence_json, "modeled", None),
            (evidence_md, "modeled", None),
        ]
    )
    if treasury_path is not None:
        written.append((treasury_path, "modeled", len(treasury)))
    if profiles_path is not None and profiles_row_count is not None:
        written.append((profiles_path, "synthetic", profiles_row_count))
    if treasury_config_path is not None:
        written.append((treasury_config_path, "assumed", None))
    args.manifest.parent.mkdir(parents=True, exist_ok=True)
    write_manifest(args.manifest, written)

    print("Section 19 validation gates")
    for name, passed in checks.items():
        print(f"  {'PASS' if passed else 'FAIL'}: {name}")
    print(first.scenario_summary.to_string(index=False))
    print(f"FINAL DECISION: {'PASS' if final_pass else 'FAIL'}")
    return 0 if final_pass else 1


if __name__ == "__main__":
    raise SystemExit(main())
