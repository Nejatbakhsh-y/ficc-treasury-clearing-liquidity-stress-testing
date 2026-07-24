"""Run Phase VI, Section 22 Cover 1 and Cover 2 analysis."""

from __future__ import annotations

import argparse
import hashlib
import json
from datetime import UTC, datetime
from pathlib import Path
from typing import Any, cast

import pandas as pd

from ficc_liquidity.scenarios.cover_analysis import (
    CoverAnalysisError,
    analyze_cover_sets,
    deterministic_reproduction_check,
    load_cover_analysis_config,
    settings_from_config,
)


def parse_args() -> argparse.Namespace:
    """Parse command-line arguments."""

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--config",
        type=Path,
        default=Path("configs/cover_analysis.yaml"),
        help="Section 22 YAML configuration.",
    )
    parser.add_argument(
        "--input",
        type=Path,
        default=None,
        help="Optional explicit scenario-member result table.",
    )
    parser.add_argument(
        "--repo-root",
        type=Path,
        default=Path.cwd(),
        help="Repository root used to resolve configured relative paths.",
    )
    return parser.parse_args()


def resolve_input_path(
    repo_root: Path,
    config: dict[str, Any],
    explicit_input: Path | None,
) -> Path:
    """Resolve the first available controlled scenario-member result table."""

    if explicit_input is not None:
        candidate = explicit_input if explicit_input.is_absolute() else repo_root / explicit_input
        if candidate.is_file():
            return candidate
        raise CoverAnalysisError(f"Explicit scenario-member input was not found: {candidate}")

    source = config.get("source", {})
    if not isinstance(source, dict):
        raise CoverAnalysisError("source must be a mapping.")
    raw_candidates = source.get("member_result_candidates", [])
    if not isinstance(raw_candidates, list):
        raise CoverAnalysisError("source.member_result_candidates must be a list.")
    for value in raw_candidates:
        candidate = repo_root / str(value)
        if candidate.is_file():
            return candidate
    raise CoverAnalysisError(
        "No scenario-member result table was found. Run Section 21 first. Checked: "
        + ", ".join(str(value) for value in raw_candidates)
    )


def read_table(path: Path) -> pd.DataFrame:
    """Read a controlled CSV or Parquet table."""

    suffix = path.suffix.lower()
    if suffix == ".parquet":
        return pd.read_parquet(path)
    if suffix == ".csv":
        return pd.read_csv(path)
    raise CoverAnalysisError(f"Unsupported input table format: {path.suffix}")


def write_table(frame: pd.DataFrame, csv_path: Path, parquet_path: Path) -> None:
    """Write deterministic CSV and Parquet copies of a result table."""

    csv_path.parent.mkdir(parents=True, exist_ok=True)
    parquet_path.parent.mkdir(parents=True, exist_ok=True)
    frame.to_csv(csv_path, index=False, lineterminator="\n")
    frame.to_parquet(parquet_path, index=False)


def file_sha256(path: Path) -> str:
    """Calculate a SHA-256 digest for an artifact."""

    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def output_paths(repo_root: Path, config: dict[str, Any]) -> dict[str, Path]:
    """Resolve configured Section 22 output paths."""

    output = config.get("output", {})
    if not isinstance(output, dict):
        raise CoverAnalysisError("output must be a mapping.")
    defaults = {
        "cover_results_csv": "reports/tables/cover_analysis_results.csv",
        "cover_results_parquet": "reports/tables/cover_analysis_results.parquet",
        "scenario_summary_csv": "reports/tables/cover_analysis_scenario_summary.csv",
        "scenario_summary_parquet": "reports/tables/cover_analysis_scenario_summary.parquet",
        "selected_members_csv": "reports/tables/cover_analysis_selected_members.csv",
        "selected_members_parquet": "reports/tables/cover_analysis_selected_members.parquet",
        "component_summary_csv": "reports/tables/cover_analysis_component_summary.csv",
        "component_summary_parquet": "reports/tables/cover_analysis_component_summary.parquet",
        "evidence_json": "reports/evidence/section22_cover_analysis.json",
        "evidence_markdown": "reports/evidence/section22_cover_analysis.md",
        "manifest": "data/manifests/cover_analysis_manifest.csv",
    }
    return {name: repo_root / str(output.get(name, default)) for name, default in defaults.items()}


def write_evidence(
    paths: dict[str, Path],
    source_path: Path,
    config_path: Path,
    result: object,
    deterministic_pass: bool,
) -> None:
    """Write controlled JSON and Markdown validation evidence."""

    from ficc_liquidity.scenarios.cover_analysis import CoverAnalysisResult

    typed_result = cast(CoverAnalysisResult, result)
    generated_at = datetime.now(UTC).isoformat()
    checks = dict(typed_result.checks)
    checks["deterministic_reproduction"] = deterministic_pass
    final_pass = all(checks.values())

    evidence = {
        "section": 22,
        "generated_at_utc": generated_at,
        "run_type": "CONTROLLED_MODEL_RUN",
        "model_version": str(typed_result.cover_results["model_version"].iloc[0]),
        "source_table": str(source_path.resolve()),
        "configuration": str(config_path.resolve()),
        "scenario_count": int(typed_result.scenario_summary.shape[0]),
        "cover_result_rows": int(typed_result.cover_results.shape[0]),
        "selected_member_rows": int(typed_result.selected_members.shape[0]),
        "component_rows": int(typed_result.component_summary.shape[0]),
        "checks": checks,
        "final_decision": "PASS" if final_pass else "FAIL",
        "actual_ficc_participant": False,
        "participant_level_inference": False,
    }
    json_path = paths["evidence_json"]
    markdown_path = paths["evidence_markdown"]
    json_path.parent.mkdir(parents=True, exist_ok=True)
    json_path.write_text(json.dumps(evidence, indent=2, sort_keys=True) + "\n", encoding="utf-8")

    lines = [
        "# Section 22 â€” Cover 1 and Cover 2 Analysis",
        "",
        f"- Generated at: `{generated_at}`",
        f"- Source table: `{source_path.as_posix()}`",
        f"- Scenario count: `{typed_result.scenario_summary.shape[0]}`",
        f"- Cover-result rows: `{typed_result.cover_results.shape[0]}`",
        "- Actual FICC participants represented: `NO`",
        "- Participant-level inference performed: `NO`",
        "",
        "## Validation checks",
        "",
    ]
    lines.extend(
        f"- {name.replace('_', ' ').title()}: `{'PASS' if passed else 'FAIL'}`"
        for name, passed in sorted(checks.items())
    )
    lines.extend(
        [
            "",
            "## Metric definitions",
            "",
            "- Cover 1: the synthetic member with the largest gross stressed liquidity "
            "requirement within each scenario.",
            "- Cover 2: the two synthetic members with the largest gross stressed liquidity "
            "requirements within each scenario.",
            "- Available resources: sum of selected members' available qualified liquid resources.",
            "- LCR: available resources divided by the Cover stressed requirement.",
            "- Liquidity shortfall: maximum of requirement minus resources and zero.",
            "- Resource utilization: Cover stressed requirement divided by available resources.",
            "- Dominant stress component: largest aggregated atomic stress component for "
            "the selected Cover set.",
            "",
            f"## Final decision: {'PASS' if final_pass else 'FAIL'}",
            "",
        ]
    )
    markdown_path.write_text("\n".join(lines), encoding="utf-8")


def write_manifest(
    paths: dict[str, Path],
    source_path: Path,
    config_path: Path,
) -> None:
    """Write Section 22 artifact lineage and integrity metadata."""

    generated_at = datetime.now(UTC).isoformat()
    rows: list[dict[str, object]] = []
    artifact_paths = [
        config_path,
        source_path,
        paths["cover_results_csv"],
        paths["cover_results_parquet"],
        paths["scenario_summary_csv"],
        paths["scenario_summary_parquet"],
        paths["selected_members_csv"],
        paths["selected_members_parquet"],
        paths["component_summary_csv"],
        paths["component_summary_parquet"],
        paths["evidence_json"],
        paths["evidence_markdown"],
    ]
    for path in artifact_paths:
        if not path.is_file():
            continue
        row_count: int | None = None
        if path.suffix.lower() == ".csv":
            row_count = int(pd.read_csv(path).shape[0])
        elif path.suffix.lower() == ".parquet":
            row_count = int(pd.read_parquet(path).shape[0])
        rows.append(
            {
                "section": 22,
                "artifact_path": str(path.resolve()),
                "artifact_name": path.name,
                "value_class": "assumed" if path == config_path else "synthetic",
                "row_count": row_count,
                "sha256": file_sha256(path),
                "generated_at_utc": generated_at,
                "actual_ficc_participant": False,
                "participant_level_inference": False,
            }
        )
    manifest_path = paths["manifest"]
    manifest_path.parent.mkdir(parents=True, exist_ok=True)
    pd.DataFrame(rows).to_csv(manifest_path, index=False, lineterminator="\n")


def main() -> int:
    """Execute Section 22 and return a process exit code."""

    args = parse_args()
    repo_root = args.repo_root.resolve()
    config_path = args.config if args.config.is_absolute() else repo_root / args.config
    config = load_cover_analysis_config(config_path)
    settings = settings_from_config(config)
    source_path = resolve_input_path(repo_root, config, args.input)
    source_frame = read_table(source_path)
    result = analyze_cover_sets(source_frame, settings)
    deterministic_pass = deterministic_reproduction_check(source_frame, settings)
    paths = output_paths(repo_root, config)

    write_table(
        result.cover_results,
        paths["cover_results_csv"],
        paths["cover_results_parquet"],
    )
    write_table(
        result.scenario_summary,
        paths["scenario_summary_csv"],
        paths["scenario_summary_parquet"],
    )
    write_table(
        result.selected_members,
        paths["selected_members_csv"],
        paths["selected_members_parquet"],
    )
    write_table(
        result.component_summary,
        paths["component_summary_csv"],
        paths["component_summary_parquet"],
    )
    write_evidence(paths, source_path, config_path, result, deterministic_pass)
    write_manifest(paths, source_path, config_path)

    final_pass = result.passed and deterministic_pass
    reported_checks = {**result.checks, "deterministic_reproduction": deterministic_pass}
    for check_name, passed in sorted(reported_checks.items()):
        print(f"{check_name}: {'PASS' if passed else 'FAIL'}")
    print(f"Scenarios analyzed: {result.scenario_summary.shape[0]}")
    print(f"Cover rows written: {result.cover_results.shape[0]}")
    print(f"FINAL DECISION: {'PASS' if final_pass else 'FAIL'}")
    return 0 if final_pass else 1


if __name__ == "__main__":
    raise SystemExit(main())
