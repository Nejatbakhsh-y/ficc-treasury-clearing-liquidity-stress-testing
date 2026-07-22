"""Run Section 15 Treasury yield-shock stress testing."""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

import numpy as np
import pandas as pd

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "src"
if str(SRC) not in sys.path:
    sys.path.insert(0, str(SRC))

from ficc_liquidity.stress.treasury_yield_shock import (  # noqa: E402
    TreasuryYieldShockModel,
    derive_h15_bucket_shocks,
    load_stress_config,
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Run Section 15 Treasury yield-shock stress testing."
    )
    parser.add_argument(
        "--config",
        type=Path,
        default=ROOT / "configs" / "treasury_yield_stress.yaml",
    )
    parser.add_argument("--input", type=Path, default=None)
    parser.add_argument("--h15-input", type=Path, default=None)
    parser.add_argument("--h15-start-date", type=str, default=None)
    parser.add_argument("--h15-end-date", type=str, default=None)
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
        "--allow-demo",
        action="store_true",
        help="Use controlled synthetic smoke-test positions if no Section 12 input exists.",
    )
    parser.add_argument(
        "--smoke",
        action="store_true",
        help="Label outputs as smoke-test evidence.",
    )
    return parser.parse_args()


def read_table(path: Path) -> pd.DataFrame:
    suffix = path.suffix.lower()
    if suffix in {".parquet", ".pq"}:
        return pd.read_parquet(path)
    if suffix == ".csv":
        return pd.read_csv(path)
    raise ValueError(f"Unsupported tabular input format: {path}")


def discover_input(root: Path, candidates: list[str]) -> Path | None:
    for candidate in candidates:
        path = root / candidate
        if path.exists():
            return path
    return None


def demo_positions() -> pd.DataFrame:
    buckets = [
        "bills_0_1y",
        "notes_1_2y",
        "notes_2_3y",
        "notes_3_5y",
        "notes_5_7y",
        "notes_7_10y",
        "bonds_10_20y",
        "bonds_20_30y",
        "bonds_30y_plus",
    ]
    records: list[dict[str, Any]] = []
    for member_number, scale in ((1, 1.00), (2, 0.65), (3, 0.40)):
        for bucket_number, bucket in enumerate(buckets, start=1):
            records.append(
                {
                    "member_id": f"SYNTH_MEMBER_{member_number:03d}",
                    "as_of_date": "2026-06-30",
                    "maturity_bucket": bucket,
                    "market_value_usd": (scale * (55_000_000.0 + bucket_number * 7_500_000.0)),
                }
            )
    return pd.DataFrame.from_records(records)


def dataframe_hash(frame: pd.DataFrame) -> str:
    ordered = frame.sort_index(axis=1).sort_values(
        list(frame.columns),
        kind="mergesort",
    )
    payload = ordered.to_csv(index=False, float_format="%.12g").encode("utf-8")
    return hashlib.sha256(payload).hexdigest()


def write_frame(frame: pd.DataFrame, stem: Path, write_parquet: bool) -> list[str]:
    written: list[str] = []
    csv_path = stem.with_suffix(".csv")
    frame.to_csv(csv_path, index=False)
    written.append(str(csv_path))

    if write_parquet:
        parquet_path = stem.with_suffix(".parquet")
        try:
            frame.to_parquet(parquet_path, index=False)
            written.append(str(parquet_path))
        except (ImportError, ModuleNotFoundError, ValueError) as exc:
            print(f"Parquet output skipped: {exc}")

    return written


def gate_results(
    position_results: pd.DataFrame,
    member_summary: pd.DataFrame,
    scenario_summary: pd.DataFrame,
) -> dict[str, str]:
    scenario_families = set(position_results["scenario_family"])
    required_families = {"parallel", "steepening", "flattening", "key_rate"}

    gates = {
        "Required scenario families": (
            "PASS" if required_families.issubset(scenario_families) else "FAIL"
        ),
        "Finite position outputs": (
            "PASS"
            if np.isfinite(
                position_results[
                    [
                        "effective_yield_shock_bp",
                        "estimated_price_return",
                        "treasury_pnl_usd",
                        "treasury_loss_usd",
                    ]
                ].to_numpy(dtype=float)
            ).all()
            else "FAIL"
        ),
        "Nonnegative modeled losses": (
            "PASS" if (position_results["treasury_loss_usd"] >= 0).all() else "FAIL"
        ),
        "Member aggregation complete": ("PASS" if not member_summary.empty else "FAIL"),
        "Scenario aggregation complete": ("PASS" if not scenario_summary.empty else "FAIL"),
    }
    return gates


def main() -> int:
    args = parse_args()
    config = load_stress_config(args.config)

    input_path = args.input
    if input_path is None:
        input_path = discover_input(ROOT, config["input"]["position_candidates"])

    if input_path is None:
        if not args.allow_demo:
            raise FileNotFoundError(
                "No Section 12 Treasury-position file was found. Supply --input or "
                "use --allow-demo only for controlled smoke testing."
            )
        positions = demo_positions()
        input_source = "CONTROLLED_SYNTHETIC_SMOKE_DATA"
    else:
        positions = read_table(input_path)
        input_source = str(input_path.resolve())

    scenarios = [
        scenario.copy() for scenario in config["scenarios"] if bool(scenario.get("enabled", True))
    ]

    if bool(args.h15_start_date) ^ bool(args.h15_end_date):
        raise ValueError("--h15-start-date and --h15-end-date must be supplied together.")

    if args.h15_start_date and args.h15_end_date:
        h15_path = args.h15_input
        if h15_path is None:
            h15_path = discover_input(ROOT, config["input"]["h15_candidates"])
        if h15_path is None:
            raise FileNotFoundError(
                "Historical H.15 scenario requested, but no H.15 input was found."
            )

        historical_shocks = derive_h15_bucket_shocks(
            read_table(h15_path),
            args.h15_start_date,
            args.h15_end_date,
            config,
        )
        scenarios.append(
            {
                "name": (
                    f"h15_{args.h15_start_date.replace('-', '')}_"
                    f"{args.h15_end_date.replace('-', '')}"
                ),
                "family": "historical_h15",
                "type": "h15_historical",
                "shocks_bp": historical_shocks,
                "enabled": True,
            }
        )

    model = TreasuryYieldShockModel(config)
    first = model.run(positions, scenarios=scenarios)
    second = model.run(positions, scenarios=scenarios)

    deterministic = dataframe_hash(first.positions) == dataframe_hash(second.positions)

    args.output_dir.mkdir(parents=True, exist_ok=True)
    args.evidence_dir.mkdir(parents=True, exist_ok=True)

    suffix = "_smoke" if args.smoke else ""
    write_parquet = bool(config["output"].get("write_parquet", True))
    output_files: list[str] = []
    output_files.extend(
        write_frame(
            first.positions,
            args.output_dir / f"treasury_yield_stress_position_results{suffix}",
            write_parquet,
        )
    )
    output_files.extend(
        write_frame(
            first.member_summary,
            args.output_dir / f"treasury_yield_stress_member_summary{suffix}",
            write_parquet,
        )
    )
    output_files.extend(
        write_frame(
            first.scenario_summary,
            args.output_dir / f"treasury_yield_stress_scenario_summary{suffix}",
            write_parquet,
        )
    )

    gates = gate_results(
        first.positions,
        first.member_summary,
        first.scenario_summary,
    )
    gates["Deterministic reproduction"] = "PASS" if deterministic else "FAIL"
    gates["Synthetic member identifiers"] = (
        "PASS"
        if first.positions["member_id"]
        .str.match(config["input"]["required_member_id_pattern"])
        .all()
        else "FAIL"
    )

    run_timestamp = datetime.now(UTC).isoformat()
    evidence = {
        "section": 15,
        "model": config["model_name"],
        "run_timestamp_utc": run_timestamp,
        "run_type": "SMOKE_TEST" if args.smoke else "CONTROLLED_MODEL_RUN",
        "input_source": input_source,
        "position_rows": len(first.positions),
        "member_scenario_rows": len(first.member_summary),
        "scenario_rows": len(first.scenario_summary),
        "scenario_names": sorted(first.positions["scenario_name"].unique().tolist()),
        "result_sha256": dataframe_hash(first.positions),
        "gates": gates,
        "output_files": output_files,
        "limitations": [
            "Duration-convexity is a second-order approximation, not full repricing.",
            "Public aggregate data do not reveal actual FICC participant portfolios.",
            "Market-impact parameters are explicit model assumptions requiring validation.",
            "Smoke-test results are not production stress estimates.",
        ],
    }

    evidence_json = args.evidence_dir / f"section15_treasury_yield_stress{suffix}.json"
    evidence_json.write_text(json.dumps(evidence, indent=2), encoding="utf-8")

    evidence_md = args.evidence_dir / f"section15_treasury_yield_stress{suffix}.md"
    gate_lines = "\n".join(f"- {name}: **{status}**" for name, status in gates.items())
    evidence_md.write_text(
        "\n".join(
            [
                "# Section 15 Treasury Yield-Shock Evidence",
                "",
                f"- Run timestamp (UTC): {run_timestamp}",
                f"- Run type: {evidence['run_type']}",
                f"- Input source: `{input_source}`",
                f"- Position-scenario rows: {len(first.positions):,}",
                f"- Result SHA-256: `{evidence['result_sha256']}`",
                "",
                "## Completion gates",
                "",
                gate_lines,
                "",
                "## Scope limitation",
                "",
                "All member records are synthetic. No result identifies or infers an "
                "actual FICC participant.",
                "",
            ]
        ),
        encoding="utf-8",
    )

    print(first.scenario_summary.to_string(index=False))
    print("")
    print("Completion gates:")
    for name, status in gates.items():
        print(f"  {name}: {status}")
    print(f"\nEvidence: {evidence_md}")

    if any(status != "PASS" for status in gates.values()):
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
