"""Run Phase V, Section 18 settlement-fail stress."""

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

from ficc_liquidity.stress.settlement_fail_stress import (  # noqa: E402
    SettlementFailStressError,
    dataframe_digest,
    load_config,
    read_table,
    run_model,
)


def parse_args() -> argparse.Namespace:
    """Parse controlled command-line arguments."""
    parser = argparse.ArgumentParser(description="Run Phase V Section 18 settlement-fail stress.")
    parser.add_argument(
        "--config",
        type=Path,
        default=ROOT / "configs" / "settlement_fail_stress.yaml",
    )
    parser.add_argument("--baseline", type=Path, default=None)
    parser.add_argument("--members", type=Path, default=None)
    parser.add_argument("--funding", type=Path, default=None)
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
        default=ROOT / "data" / "manifests" / "settlement_fail_stress_manifest.csv",
    )
    parser.add_argument("--allow-demo", action="store_true")
    parser.add_argument("--smoke", action="store_true")
    return parser.parse_args()


def _mapping(value: object, label: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise SettlementFailStressError(f"{label} must be a YAML mapping.")
    return cast(dict[str, Any], value)


def discover_input(root: Path, candidates: list[str]) -> Path | None:
    """Return the first existing controlled input candidate."""
    for candidate in candidates:
        path = root / candidate
        if path.exists():
            return path
    return None


def _demo_members() -> pd.DataFrame:
    return pd.DataFrame(
        {
            "member_id": ["SYN-MBR-0001", "SYN-MBR-0002", "SYN-MBR-0003"],
            "settlement_obligation_usd": [400_000_000.0, 650_000_000.0, 900_000_000.0],
            "settlement_fail_usd": [8_000_000.0, 26_000_000.0, 63_000_000.0],
            "settlement_fail_rate": [0.02, 0.04, 0.07],
            "value_class": ["synthetic"] * 3,
            "actual_ficc_participant": [False] * 3,
            "participant_level_inference": [False] * 3,
        }
    )


def _demo_baseline() -> pd.DataFrame:
    rows: list[dict[str, object]] = []
    buckets = (
        ("day1_open", 0, 0.20),
        ("day1_midday", 6, 0.30),
        ("day1_close", 12, 0.30),
        ("day2_open", 24, 0.15),
        ("day2_close", 48, 0.05),
    )
    for member_number, scale in ((1, 1.0), (2, 1.4), (3, 1.9)):
        member_id = f"SYN-MBR-{member_number:04d}"
        resources = 350_000_000.0 * scale
        cumulative = 0.0
        for order, (bucket, elapsed, weight) in enumerate(buckets, start=1):
            gross_settlement = 400_000_000.0 * scale * weight
            outflow = gross_settlement * 0.35
            inflow = gross_settlement * 0.10
            cumulative = max(cumulative + outflow - inflow, 0.0)
            rows.append(
                {
                    "member_id": member_id,
                    "bucket_order": order,
                    "time_bucket": bucket,
                    "elapsed_hours": elapsed,
                    "liquidity_horizon_hours": 48,
                    "gross_settlement_obligation_usd": gross_settlement,
                    "total_cash_outflow_usd": outflow,
                    "total_cash_inflow_usd": inflow,
                    "cumulative_available_resources_usd": resources,
                    "cumulative_net_liquidity_need_usd": cumulative,
                    "liquidity_headroom_usd": resources - cumulative,
                    "liquidity_shortfall_usd": max(cumulative - resources, 0.0),
                    "value_class": "synthetic",
                    "actual_ficc_participant": False,
                    "participant_level_inference": False,
                }
            )
    return pd.DataFrame.from_records(rows)


def _demo_funding() -> pd.DataFrame:
    rows: list[dict[str, object]] = []
    scenario_scales = {
        "control": 0.0,
        "moderate_market_stress": 0.04,
        "severe_market_stress": 0.10,
        "concentrated_funding_freeze": 0.20,
    }
    for scenario_name, scenario_scale in scenario_scales.items():
        for member_number, member_scale in ((1, 1.0), (2, 1.4), (3, 1.9)):
            for order, bucket in enumerate(
                ("day1_open", "day1_midday", "day1_close", "day2_open", "day2_close"),
                start=1,
            ):
                rows.append(
                    {
                        "scenario_name": scenario_name,
                        "member_id": f"SYN-MBR-{member_number:04d}",
                        "bucket_order": order,
                        "time_bucket": bucket,
                        "incremental_repo_funding_stress_outflow_usd": (
                            20_000_000.0 * member_scale * scenario_scale * order
                        ),
                        "value_class": "synthetic",
                        "actual_ficc_participant": False,
                        "participant_level_inference": False,
                    }
                )
    return pd.DataFrame.from_records(rows)


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
    """Write controlled result files."""
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


def write_manifest(
    manifest_path: Path,
    files: list[tuple[Path, str, int | None]],
) -> None:
    """Write source-lineage and output-integrity metadata."""
    generated_at = datetime.now(UTC).isoformat()
    records = [
        {
            "section": 18,
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


def main() -> int:
    """Execute the controlled Section 18 workflow."""
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
    funding_path = args.funding or discover_input(
        ROOT,
        [str(item) for item in source.get("funding_stress_candidates", [])],
    )

    if baseline_path is None or member_path is None or funding_path is None:
        if not args.allow_demo:
            raise FileNotFoundError(
                "Section 14 baseline cash flows, Section 12 synthetic members, and "
                "Section 16 funding-stress cash flows are required."
            )
        baseline = _demo_baseline()
        members = _demo_members()
        funding = _demo_funding()
        baseline_source = "CONTROLLED_SYNTHETIC_BASELINE_SMOKE_DATA"
        member_source = "CONTROLLED_SYNTHETIC_MEMBER_SMOKE_DATA"
        funding_source = "CONTROLLED_SYNTHETIC_FUNDING_SMOKE_DATA"
    else:
        baseline = read_table(baseline_path)
        members = read_table(member_path)
        funding = read_table(funding_path)
        baseline_source = str(baseline_path.resolve())
        member_source = str(member_path.resolve())
        funding_source = str(funding_path.resolve())

    first = run_model(baseline, members, funding, config)
    second = run_model(
        baseline.sample(frac=1.0, random_state=2026).reset_index(drop=True),
        members.sample(frac=1.0, random_state=2026).reset_index(drop=True),
        funding.sample(frac=1.0, random_state=2026).reset_index(drop=True),
        config,
    )
    deterministic = dataframe_digest(first.cashflows) == dataframe_digest(second.cashflows)

    args.output_dir.mkdir(parents=True, exist_ok=True)
    args.evidence_dir.mkdir(parents=True, exist_ok=True)
    suffix = "_smoke" if args.smoke else ""
    written: list[Path] = []
    written.extend(
        write_frame(
            first.cashflows,
            args.output_dir / f"settlement_fail_stress_cashflows{suffix}",
            write_csv=bool(output.get("write_csv", True)),
            write_parquet=bool(output.get("write_parquet", True)),
        )
    )
    written.extend(
        write_frame(
            first.member_summary,
            args.output_dir / f"settlement_fail_stress_member_summary{suffix}",
            write_csv=bool(output.get("write_csv", True)),
            write_parquet=bool(output.get("write_parquet", True)),
        )
    )
    written.extend(
        write_frame(
            first.scenario_summary,
            args.output_dir / f"settlement_fail_stress_scenario_summary{suffix}",
            write_csv=bool(output.get("write_csv", True)),
            write_parquet=bool(output.get("write_parquet", True)),
        )
    )

    gates = {
        **{name: "PASS" if passed else "FAIL" for name, passed in first.checks.items()},
        "deterministic_reproduction": "PASS" if deterministic else "FAIL",
    }
    generated_at = datetime.now(UTC).isoformat()
    evidence = {
        "section": 18,
        "model": config.get("model_name", "settlement_fail_stress"),
        "model_version": config.get("model_version", "section-18-v1"),
        "generated_at_utc": generated_at,
        "run_type": "SMOKE_TEST" if args.smoke else "CONTROLLED_MODEL_RUN",
        "baseline_source": baseline_source,
        "member_source": member_source,
        "funding_source": funding_source,
        "cashflow_rows": len(first.cashflows),
        "member_scenario_rows": len(first.member_summary),
        "scenario_rows": len(first.scenario_summary),
        "scenario_names": first.scenario_summary["scenario_name"].tolist(),
        "result_sha256": dataframe_digest(first.cashflows),
        "gates": gates,
        "limitations": [
            "All member-level records are fictional synthetic observations.",
            "Fail splits, delays, persistence, replacement rates, and penalties are assumptions.",
            "Section 16 funding outflows are scenario overlays, not bilateral lender forecasts.",
            "Public aggregate data do not reveal actual FICC participant settlement behavior.",
        ],
    }
    evidence_json = args.evidence_dir / f"section18_settlement_fail_stress{suffix}.json"
    evidence_json.write_text(json.dumps(evidence, indent=2), encoding="utf-8")
    evidence_md = args.evidence_dir / f"section18_settlement_fail_stress{suffix}.md"
    gate_lines = "\n".join(f"- {name}: **{status}**" for name, status in gates.items())
    evidence_md.write_text(
        "\n".join(
            [
                "# Section 18 Settlement-Fail Stress Evidence",
                "",
                f"- Generated at (UTC): {generated_at}",
                f"- Run type: {evidence['run_type']}",
                f"- Baseline source: `{baseline_source}`",
                f"- Synthetic member source: `{member_source}`",
                f"- Section 16 funding source: `{funding_source}`",
                f"- Cash-flow scenario rows: {len(first.cashflows):,}",
                f"- Result SHA-256: `{evidence['result_sha256']}`",
                "",
                "## Completion gates",
                "",
                gate_lines,
                "",
                "## Scope limitation",
                "",
                "All member records are fictional and synthetic. No output identifies, ",
                "represents, ranks, or infers an actual FICC participant.",
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
                len(first.cashflows)
                if "cashflows" in path.name
                else len(first.member_summary)
                if "member_summary" in path.name
                else len(first.scenario_summary),
            )
            for path in written
        ],
        (evidence_json, "modeled", None),
        (evidence_md, "modeled", None),
    ]
    if baseline_path is not None:
        manifest_files.append((baseline_path, "modeled", len(baseline)))
    if member_path is not None:
        manifest_files.append((member_path, "synthetic", len(members)))
    if funding_path is not None:
        manifest_files.append((funding_path, "modeled", len(funding)))
    write_manifest(args.manifest, manifest_files)

    print(first.scenario_summary.to_string(index=False))
    print("\nCompletion gates:")
    for name, status in gates.items():
        print(f"  {name}: {status}")
    print(f"\nEvidence: {evidence_md}")
    print(f"Manifest: {args.manifest}")
    return 0 if all(status == "PASS" for status in gates.values()) else 1


if __name__ == "__main__":
    raise SystemExit(main())
