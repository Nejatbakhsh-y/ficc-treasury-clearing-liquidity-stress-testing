"""Run Phase V Section 16 repo funding-stress analysis."""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
from datetime import UTC, datetime
from pathlib import Path
from typing import Any, cast

import pandas as pd

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "src"
if str(SRC) not in sys.path:
    sys.path.insert(0, str(SRC))

from ficc_liquidity.stress.repo_funding_stress import (  # noqa: E402
    RepoFundingStressError,
    load_config,
    read_table,
    run_model,
)


def parse_args() -> argparse.Namespace:
    """Parse controlled command-line arguments."""
    parser = argparse.ArgumentParser(
        description="Run Phase V Section 16 repo funding-stress analysis."
    )
    parser.add_argument(
        "--config",
        type=Path,
        default=ROOT / "configs" / "repo_funding_stress.yaml",
    )
    parser.add_argument("--baseline", type=Path, default=None)
    parser.add_argument("--members", type=Path, default=None)
    parser.add_argument("--sofr-input", type=Path, default=None)
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
        default=ROOT / "data" / "manifests" / "repo_funding_stress_manifest.csv",
    )
    parser.add_argument(
        "--allow-demo",
        action="store_true",
        help="Use controlled synthetic smoke data when project inputs are unavailable.",
    )
    parser.add_argument(
        "--smoke",
        action="store_true",
        help="Label generated evidence as a controlled smoke-test run.",
    )
    return parser.parse_args()


def _mapping(value: object, label: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise RepoFundingStressError(f"{label} must be a YAML mapping.")
    return cast(dict[str, Any], value)


def discover_input(root: Path, candidates: list[str]) -> Path | None:
    """Return the first existing candidate path."""
    for candidate in candidates:
        path = root / candidate
        if path.exists():
            return path
    return None


def _demo_members() -> pd.DataFrame:
    """Create controlled fictional member profiles for smoke testing."""
    return pd.DataFrame(
        {
            "member_id": ["SYN-MBR-0001", "SYN-MBR-0002", "SYN-MBR-0003"],
            "as_of_date": ["2026-06-30"] * 3,
            "value_class": ["synthetic"] * 3,
            "actual_ficc_participant": [False] * 3,
            "participant_level_inference": [False] * 3,
            "member_concentration_ratio": [0.18, 0.35, 0.58],
            "funding_dependency_ratio": [0.30, 0.62, 0.88],
            "net_repo_dependency_ratio": [0.45, 0.70, 0.92],
        }
    )


def _demo_baseline() -> pd.DataFrame:
    """Create controlled Section 14-compatible cash flows for smoke testing."""
    rows: list[dict[str, object]] = []
    buckets = (
        ("day1_open", 0, 0.20),
        ("day1_midday", 6, 0.30),
        ("day1_close", 12, 0.30),
        ("day2_open", 24, 0.15),
        ("day2_close", 48, 0.05),
    )
    for member_number, scale in ((1, 1.00), (2, 1.35), (3, 1.80)):
        member_id = f"SYN-MBR-{member_number:04d}"
        cumulative_need = 0.0
        available_resources = 320_000_000.0 * scale
        for bucket_order, (bucket, elapsed_hours, weight) in enumerate(
            buckets,
            start=1,
        ):
            repo_maturity = 500_000_000.0 * scale * weight
            repo_roll = repo_maturity * 0.80
            financing_outflow = repo_maturity - repo_roll
            settlement_outflow = 65_000_000.0 * scale * weight
            total_outflow = financing_outflow + settlement_outflow
            cumulative_need += total_outflow
            headroom = available_resources - cumulative_need
            rows.append(
                {
                    "member_id": member_id,
                    "as_of_date": "2026-06-30",
                    "bucket_order": bucket_order,
                    "time_bucket": bucket,
                    "elapsed_hours": elapsed_hours,
                    "liquidity_horizon_hours": 48,
                    "repo_maturity_usd": repo_maturity,
                    "repo_roll_amount_usd": repo_roll,
                    "financing_outflow_usd": financing_outflow,
                    "total_cash_outflow_usd": total_outflow,
                    "cumulative_net_liquidity_need_usd": cumulative_need,
                    "cumulative_available_resources_usd": available_resources,
                    "liquidity_headroom_usd": headroom,
                    "liquidity_shortfall_usd": max(-headroom, 0.0),
                    "value_class": "synthetic",
                    "actual_ficc_participant": False,
                    "participant_level_inference": False,
                }
            )
    return pd.DataFrame.from_records(rows)


def _latest_sofr_from_table(
    frame: pd.DataFrame,
    date_candidates: list[str],
    value_candidates: list[str],
) -> tuple[float, str]:
    """Extract the latest nonmissing SOFR observation in percent units."""
    value_column = next(
        (column for column in value_candidates if column in frame.columns),
        None,
    )
    if value_column is None:
        raise RepoFundingStressError(
            f"No configured SOFR value column was found; candidates={value_candidates}."
        )

    date_column = next(
        (column for column in date_candidates if column in frame.columns),
        None,
    )
    working = frame.copy(deep=True)
    working[value_column] = pd.to_numeric(
        working[value_column],
        errors="coerce",
    )
    working = working.dropna(subset=[value_column])
    if working.empty:
        raise RepoFundingStressError("SOFR input has no usable numeric observations.")

    if date_column is not None:
        working[date_column] = pd.to_datetime(
            working[date_column],
            errors="coerce",
        )
        working = working.dropna(subset=[date_column]).sort_values(
            date_column,
            kind="stable",
        )
        if working.empty:
            raise RepoFundingStressError("SOFR input has no usable dated observations.")
        observation_label = str(working[date_column].iloc[-1].date())
    else:
        observation_label = "latest_row"

    value = float(working[value_column].iloc[-1])
    if value < 0.0:
        raise RepoFundingStressError("SOFR observations cannot be negative.")
    return value, f"{value_column}@{observation_label}"


def resolve_reference_sofr(
    config: dict[str, Any],
    explicit_path: Path | None,
) -> tuple[float, str]:
    """Resolve observed SOFR where available, otherwise use the controlled fallback."""
    sofr = _mapping(config.get("sofr"), "sofr")
    candidates = [str(item) for item in sofr.get("input_candidates", [])]
    path = explicit_path or discover_input(ROOT, candidates)
    fallback = float(sofr.get("fallback_reference_percent", 0.0))

    if path is None:
        return fallback, "ASSUMED_CONFIG_FALLBACK"
    try:
        value, observation = _latest_sofr_from_table(
            read_table(path),
            [str(item) for item in sofr.get("date_column_candidates", [])],
            [str(item) for item in sofr.get("value_column_candidates", [])],
        )
    except (RepoFundingStressError, ValueError, TypeError) as exc:
        print(f"SOFR observation fallback used: {exc}")
        return fallback, f"ASSUMED_CONFIG_FALLBACK_AFTER_{path.name}"
    return value, f"{path.resolve()}::{observation}"


def dataframe_hash(frame: pd.DataFrame) -> str:
    """Calculate a deterministic SHA-256 hash for a tabular result."""
    ordered = frame.sort_index(axis=1)
    sort_columns = [
        column
        for column in (
            "severity_rank",
            "scenario_name",
            "member_id",
            "bucket_order",
        )
        if column in ordered.columns
    ]
    if sort_columns:
        ordered = ordered.sort_values(sort_columns, kind="stable")
    payload = ordered.to_csv(index=False, float_format="%.12g").encode("utf-8")
    return hashlib.sha256(payload).hexdigest()


def file_hash(path: Path) -> str:
    """Calculate a file SHA-256 hash."""
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def write_frame(
    frame: pd.DataFrame,
    stem: Path,
    *,
    write_parquet: bool,
) -> list[Path]:
    """Write controlled CSV and optional Parquet outputs."""
    written: list[Path] = []
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


def write_manifest(
    manifest_path: Path,
    files: list[tuple[Path, str, int | None]],
) -> None:
    """Write source-lineage and output-integrity metadata."""
    records: list[dict[str, object]] = []
    for path, value_class, row_count in files:
        records.append(
            {
                "section": 16,
                "artifact_path": str(path.resolve()),
                "artifact_name": path.name,
                "value_class": value_class,
                "row_count": row_count if row_count is not None else "",
                "sha256": file_hash(path),
                "generated_at_utc": datetime.now(UTC).isoformat(),
                "actual_ficc_participant": False,
                "participant_level_inference": False,
            }
        )
    manifest_path.parent.mkdir(parents=True, exist_ok=True)
    pd.DataFrame.from_records(records).to_csv(manifest_path, index=False)


def main() -> int:
    """Execute the controlled Section 16 workflow."""
    args = parse_args()
    config = load_config(args.config)
    source = _mapping(config.get("source"), "source")
    output = _mapping(config.get("output"), "output")

    baseline_path = args.baseline or discover_input(
        ROOT,
        [str(item) for item in source.get("baseline_cashflow_candidates", [])],
    )
    member_path = args.members or discover_input(
        ROOT,
        [str(item) for item in source.get("member_profile_candidates", [])],
    )

    if baseline_path is None or member_path is None:
        if not args.allow_demo:
            raise FileNotFoundError(
                "Section 14 baseline cash flows and Section 12 synthetic member profiles "
                "are required. Supply --baseline and --members, or use --allow-demo only "
                "for controlled smoke testing."
            )
        baseline = _demo_baseline()
        members = _demo_members()
        baseline_source = "CONTROLLED_SYNTHETIC_BASELINE_SMOKE_DATA"
        member_source = "CONTROLLED_SYNTHETIC_MEMBER_SMOKE_DATA"
    else:
        baseline = read_table(baseline_path)
        members = read_table(member_path)
        baseline_source = str(baseline_path.resolve())
        member_source = str(member_path.resolve())

    reference_sofr, sofr_source = resolve_reference_sofr(
        config,
        args.sofr_input,
    )
    assumptions = _mapping(config.get("assumptions"), "assumptions")
    assumptions["reference_sofr_percent"] = reference_sofr

    detailed, member_summary, scenario_summary, validation = run_model(
        baseline,
        members,
        config,
    )

    args.output_dir.mkdir(parents=True, exist_ok=True)
    args.evidence_dir.mkdir(parents=True, exist_ok=True)
    suffix = "_smoke" if args.smoke else ""
    write_parquet = bool(output.get("write_parquet", True))

    output_files: list[Path] = []
    output_files.extend(
        write_frame(
            detailed,
            args.output_dir / f"repo_funding_stress_cashflows{suffix}",
            write_parquet=write_parquet,
        )
    )
    output_files.extend(
        write_frame(
            member_summary,
            args.output_dir / f"repo_funding_stress_member_summary{suffix}",
            write_parquet=write_parquet,
        )
    )
    output_files.extend(
        write_frame(
            scenario_summary,
            args.output_dir / f"repo_funding_stress_scenario_summary{suffix}",
            write_parquet=write_parquet,
        )
    )

    gates = {
        label.replace("_", " ").title(): "PASS" if passed else "FAIL"
        for label, passed in validation.checks.items()
    }
    run_timestamp = datetime.now(UTC).isoformat()
    run_type = "SMOKE_TEST" if args.smoke else "CONTROLLED_MODEL_RUN"

    evidence = {
        "section": 16,
        "model": config.get("model_name", "repo_funding_stress"),
        "model_version": config.get("model_version", "section-16-v1"),
        "run_timestamp_utc": run_timestamp,
        "run_type": run_type,
        "baseline_source": baseline_source,
        "member_source": member_source,
        "sofr_source": sofr_source,
        "reference_sofr_percent": reference_sofr,
        "cashflow_rows": len(detailed),
        "member_scenario_rows": len(member_summary),
        "scenario_rows": len(scenario_summary),
        "scenario_names": scenario_summary["scenario_name"].tolist(),
        "result_sha256": dataframe_hash(detailed),
        "gates": gates,
        "limitations": [
            "All member-level records are synthetic and do not represent actual FICC participants.",
            (
                "SOFR spikes, lender withdrawal, rollover failure, collateral demand, "
                "and concentration parameters are explicit stress assumptions."
            ),
            (
                "Incremental funding costs use a simple annualized day-count approximation "
                "rather than contractual repricing."
            ),
            (
                "The model overlays Section 16 stress on Section 14 cash flows and does not "
                "infer bilateral lender identities."
            ),
        ],
    }

    evidence_json = args.evidence_dir / f"section16_repo_funding_stress{suffix}.json"
    evidence_json.write_text(
        json.dumps(evidence, indent=2),
        encoding="utf-8",
    )
    evidence_md = args.evidence_dir / f"section16_repo_funding_stress{suffix}.md"
    gate_lines = "\n".join(f"- {name}: **{status}**" for name, status in gates.items())
    evidence_md.write_text(
        "\n".join(
            [
                "# Section 16 Repo Funding-Stress Evidence",
                "",
                f"- Run timestamp (UTC): {run_timestamp}",
                f"- Run type: {run_type}",
                f"- Baseline source: `{baseline_source}`",
                f"- Synthetic member source: `{member_source}`",
                f"- SOFR source: `{sofr_source}`",
                f"- Reference SOFR: {reference_sofr:.4f} percent",
                f"- Cash-flow scenario rows: {len(detailed):,}",
                f"- Result SHA-256: `{evidence['result_sha256']}`",
                "",
                "## Completion gates",
                "",
                gate_lines,
                "",
                "## Scope limitation",
                "",
                "All member records are fictional and synthetic. No output identifies, "
                "represents, or infers an actual FICC participant or bilateral lender.",
                "",
            ]
        ),
        encoding="utf-8",
    )

    manifest_files: list[tuple[Path, str, int | None]] = [
        (args.config, "assumed", None),
        *[
            (
                path,
                "modeled",
                (
                    len(detailed)
                    if "cashflows" in path.name
                    else len(member_summary)
                    if "member_summary" in path.name
                    else len(scenario_summary)
                ),
            )
            for path in output_files
        ],
        (evidence_json, "modeled", None),
        (evidence_md, "modeled", None),
    ]
    if baseline_path is not None:
        manifest_files.append((baseline_path, "modeled", len(baseline)))
    if member_path is not None:
        manifest_files.append((member_path, "synthetic", len(members)))
    write_manifest(args.manifest, manifest_files)

    print(scenario_summary.to_string(index=False))
    print("")
    print("Completion gates:")
    for name, status in gates.items():
        print(f"  {name}: {status}")
    print(f"\nEvidence: {evidence_md}")
    print(f"Manifest: {args.manifest}")

    if any(status != "PASS" for status in gates.values()):
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
