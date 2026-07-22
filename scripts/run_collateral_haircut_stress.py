"""Run Phase V, Section 17 collateral haircut stress."""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
from datetime import UTC, datetime
from pathlib import Path

import pandas as pd

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "src"
if str(SRC) not in sys.path:
    sys.path.insert(0, str(SRC))

from ficc_liquidity.stress.collateral_haircut_stress import (  # noqa: E402
    CollateralHaircutStressResult,
    dataframe_digest,
    load_config,
    read_table,
    run_model,
)


def parse_args() -> argparse.Namespace:
    """Parse command-line arguments."""
    parser = argparse.ArgumentParser(description="Run Section 17 collateral haircut stress.")
    parser.add_argument(
        "--config",
        type=Path,
        default=ROOT / "configs" / "collateral_haircut_stress.yaml",
    )
    parser.add_argument("--members", type=Path, default=None)
    parser.add_argument("--baseline", type=Path, default=None)
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
        default=ROOT / "data" / "manifests" / "collateral_haircut_stress_manifest.csv",
    )
    parser.add_argument(
        "--allow-demo",
        action="store_true",
        help="Allow controlled synthetic smoke inputs when prior-section files are absent.",
    )
    parser.add_argument(
        "--smoke",
        action="store_true",
        help="Label generated outputs as smoke-test artifacts.",
    )
    return parser.parse_args()


def discover_input(root: Path, candidates: list[str]) -> Path | None:
    """Return the first existing candidate path."""
    for candidate in candidates:
        path = root / candidate
        if path.exists():
            return path
    return None


def demo_members() -> pd.DataFrame:
    """Return controlled fictional members for smoke testing only."""
    records: list[dict[str, object]] = []
    maturity_scales = [
        (0.30, 0.22, 0.18, 0.12, 0.12, 0.06),
        (0.12, 0.16, 0.19, 0.18, 0.23, 0.12),
        (0.72, 0.08, 0.06, 0.05, 0.05, 0.04),
    ]
    for number, weights in enumerate(maturity_scales, start=1):
        total = 1_000_000_000.0 * (1.0 - 0.18 * (number - 1))
        positions = [total * weight for weight in weights]
        repo_need = total * (0.42 + 0.04 * number)
        collateral_inventory = total * (0.78 + 0.03 * number)
        qlr = collateral_inventory * 0.62
        records.append(
            {
                "member_id": f"SYN-MBR-{number:04d}",
                "treasury_position_bills_0_1y_usd": positions[0],
                "treasury_position_notes_1_3y_usd": positions[1],
                "treasury_position_notes_3_7y_usd": positions[2],
                "treasury_position_notes_7_10y_usd": positions[3],
                "treasury_position_bonds_10_30y_usd": positions[4],
                "treasury_position_strips_30y_plus_usd": positions[5],
                "total_treasury_position_usd": total,
                "repo_financing_need_usd": repo_need,
                "collateral_inventory_usd": collateral_inventory,
                "available_qualified_liquid_resources_usd": qlr,
                "value_class": "synthetic",
                "actual_ficc_participant": False,
                "participant_level_inference": False,
            }
        )
    return pd.DataFrame.from_records(records)


def demo_baseline(members: pd.DataFrame) -> pd.DataFrame:
    """Return controlled final-horizon liquidity rows for smoke testing."""
    records: list[dict[str, object]] = []
    for index, row in members.reset_index(drop=True).iterrows():
        resources = float(row["available_qualified_liquid_resources_usd"]) + (
            120_000_000.0 - 10_000_000.0 * index
        )
        need = resources * (0.80 + 0.04 * index)
        headroom = resources - need
        records.append(
            {
                "member_id": row["member_id"],
                "bucket_order": 5,
                "time_bucket": "day2_close",
                "cumulative_net_liquidity_need_usd": need,
                "cumulative_available_resources_usd": resources,
                "eligible_collateral_liquidity_usd": row[
                    "available_qualified_liquid_resources_usd"
                ],
                "available_cash_usd": resources
                - float(row["available_qualified_liquid_resources_usd"]),
                "liquidity_headroom_usd": headroom,
                "liquidity_shortfall_usd": max(-headroom, 0.0),
                "value_class": "synthetic",
                "actual_ficc_participant": False,
                "participant_level_inference": False,
            }
        )
    return pd.DataFrame.from_records(records)


def file_sha256(path: Path) -> str:
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
    """Write controlled tabular outputs."""
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


def result_gates(
    result: CollateralHaircutStressResult,
    deterministic: bool,
) -> dict[str, str]:
    """Translate model checks into completion gates."""
    gates = {
        name.replace("_", " ").title(): "PASS" if passed else "FAIL"
        for name, passed in result.checks.items()
    }
    gates["Deterministic Reproduction"] = "PASS" if deterministic else "FAIL"
    required_columns = {
        "base_haircut_rate",
        "stressed_haircut_rate",
        "concentration_haircut_addon",
        "additional_collateral_requirement_usd",
        "stressed_available_collateral_usd",
        "collateral_shortfall_usd",
    }
    gates["All Required Stress Channels"] = (
        "PASS" if required_columns.issubset(result.bucket_results.columns) else "FAIL"
    )
    return gates


def manifest_rows(
    paths: list[tuple[Path, str, int | None]],
    generated_at: str,
) -> pd.DataFrame:
    """Create controlled artifact lineage rows."""
    rows: list[dict[str, object]] = []
    for path, value_class, row_count in paths:
        rows.append(
            {
                "section": 17,
                "artifact_path": str(path.resolve()),
                "artifact_name": path.name,
                "value_class": value_class,
                "row_count": row_count,
                "sha256": file_sha256(path),
                "generated_at_utc": generated_at,
                "actual_ficc_participant": False,
                "participant_level_inference": False,
            }
        )
    return pd.DataFrame.from_records(rows)


def main() -> int:
    """Run Section 17 and return a process exit code."""
    args = parse_args()
    config = load_config(args.config)
    source = config["source"]

    member_path = args.members or discover_input(ROOT, list(source["member_profile_candidates"]))
    baseline_path = args.baseline or discover_input(
        ROOT, list(source["baseline_cashflow_candidates"])
    )

    if member_path is None or baseline_path is None:
        if not args.allow_demo:
            missing = []
            if member_path is None:
                missing.append("synthetic member profiles")
            if baseline_path is None:
                missing.append("baseline liquidity cash flows")
            raise FileNotFoundError(
                "Required prior-section inputs were not found: "
                + ", ".join(missing)
                + ". Supply explicit paths or use --allow-demo only for smoke testing."
            )
        members = demo_members()
        baseline = demo_baseline(members)
        member_source = "CONTROLLED_SYNTHETIC_SMOKE_DATA"
        baseline_source = "CONTROLLED_BASELINE_SMOKE_DATA"
    else:
        members = read_table(member_path)
        baseline = read_table(baseline_path)
        member_source = str(member_path.resolve())
        baseline_source = str(baseline_path.resolve())

    first = run_model(members, baseline, config)
    second = run_model(
        members.sample(frac=1.0, random_state=2026).reset_index(drop=True),
        baseline.sample(frac=1.0, random_state=2027).reset_index(drop=True),
        config,
    )
    deterministic = (
        dataframe_digest(first.bucket_results) == dataframe_digest(second.bucket_results)
        and dataframe_digest(first.member_summary) == dataframe_digest(second.member_summary)
        and dataframe_digest(first.scenario_summary) == dataframe_digest(second.scenario_summary)
    )

    args.output_dir.mkdir(parents=True, exist_ok=True)
    args.evidence_dir.mkdir(parents=True, exist_ok=True)
    args.manifest.parent.mkdir(parents=True, exist_ok=True)

    suffix = "_smoke" if args.smoke else ""
    output = config["output"]
    written: list[Path] = []
    written.extend(
        write_frame(
            first.bucket_results,
            args.output_dir / f"collateral_haircut_stress_bucket_results{suffix}",
            write_csv=bool(output.get("write_csv", True)),
            write_parquet=bool(output.get("write_parquet", True)),
        )
    )
    written.extend(
        write_frame(
            first.member_summary,
            args.output_dir / f"collateral_haircut_stress_member_summary{suffix}",
            write_csv=bool(output.get("write_csv", True)),
            write_parquet=bool(output.get("write_parquet", True)),
        )
    )
    written.extend(
        write_frame(
            first.scenario_summary,
            args.output_dir / f"collateral_haircut_stress_scenario_summary{suffix}",
            write_csv=bool(output.get("write_csv", True)),
            write_parquet=bool(output.get("write_parquet", True)),
        )
    )

    gates = result_gates(first, deterministic)
    generated_at = datetime.now(UTC).isoformat()
    evidence = {
        "section": 17,
        "model": config["model_name"],
        "model_version": config["model_version"],
        "generated_at_utc": generated_at,
        "run_type": "SMOKE_TEST" if args.smoke else "CONTROLLED_MODEL_RUN",
        "member_source": member_source,
        "baseline_source": baseline_source,
        "bucket_rows": len(first.bucket_results),
        "member_scenario_rows": len(first.member_summary),
        "scenario_rows": len(first.scenario_summary),
        "scenario_names": first.scenario_summary["scenario_name"].tolist(),
        "bucket_result_sha256": dataframe_digest(first.bucket_results),
        "member_summary_sha256": dataframe_digest(first.member_summary),
        "gates": gates,
        "limitations": [
            "Haircuts are controlled model assumptions, not participant-level contractual terms.",
            "Public aggregate data do not disclose actual FICC member collateral inventories.",
            "Treasury positions and members are fictional synthetic records.",
            "The model is a deterministic scenario overlay and not a market equilibrium model.",
        ],
    }

    evidence_json = args.evidence_dir / f"section17_collateral_haircut_stress{suffix}.json"
    evidence_json.write_text(json.dumps(evidence, indent=2), encoding="utf-8")
    evidence_md = args.evidence_dir / f"section17_collateral_haircut_stress{suffix}.md"
    gate_lines = "\n".join(f"- {name}: **{status}**" for name, status in gates.items())
    evidence_md.write_text(
        "\n".join(
            [
                "# Section 17 Collateral Haircut-Stress Evidence",
                "",
                f"- Generated at (UTC): {generated_at}",
                f"- Run type: {evidence['run_type']}",
                f"- Synthetic member source: `{member_source}`",
                f"- Baseline liquidity source: `{baseline_source}`",
                f"- Bucket-scenario rows: {len(first.bucket_results):,}",
                f"- Member-scenario rows: {len(first.member_summary):,}",
                f"- Result SHA-256: `{evidence['bucket_result_sha256']}`",
                "",
                "## Completion gates",
                "",
                gate_lines,
                "",
                "## Scope limitation",
                "",
                "All member records are fictional and synthetic. No output identifies, "
                "represents, ranks, or infers an actual FICC participant.",
                "",
            ]
        ),
        encoding="utf-8",
    )

    lineage: list[tuple[Path, str, int | None]] = [
        (args.config, "assumed", None),
        *[
            (
                path,
                "modeled",
                (
                    len(first.bucket_results)
                    if "bucket_results" in path.name
                    else len(first.member_summary)
                    if "member_summary" in path.name
                    else len(first.scenario_summary)
                ),
            )
            for path in written
        ],
        (evidence_json, "modeled", None),
        (evidence_md, "modeled", None),
    ]
    if member_path is not None:
        lineage.append((member_path, "synthetic", len(members)))
    if baseline_path is not None:
        lineage.append((baseline_path, "modeled", len(baseline)))
    manifest = manifest_rows(lineage, generated_at)
    manifest.to_csv(args.manifest, index=False)

    print(first.scenario_summary.to_string(index=False))
    print("\nCompletion gates:")
    for name, status in gates.items():
        print(f"  {name}: {status}")
    print(f"\nEvidence: {evidence_md}")
    print(f"Manifest: {args.manifest}")

    if any(status != "PASS" for status in gates.values()):
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
