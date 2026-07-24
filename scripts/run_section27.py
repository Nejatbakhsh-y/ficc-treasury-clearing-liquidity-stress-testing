"""Command-line runner for Section 27 outcomes and benchmark analysis."""

from __future__ import annotations

import argparse
import json
from pathlib import Path

from ficc_liquidity.validation.outcomes_benchmark import execute_section27

REPO_ROOT = Path(__file__).resolve().parents[1]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--config",
        type=Path,
        default=REPO_ROOT / "configs" / "section27_outcomes_benchmark.yaml",
    )
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=REPO_ROOT / "reports" / "validation" / "section27",
    )
    parser.add_argument(
        "--input",
        type=Path,
        default=None,
        help="Optional CSV, JSON, or JSONL model-output file. Omit for controlled benchmark mode.",
    )
    parser.add_argument(
        "--require-external-input",
        action="store_true",
        help="Fail rather than use controlled benchmark mode when --input is omitted.",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.require_external_input and args.input is None:
        raise SystemExit("--require-external-input was set, but no --input file was supplied.")
    summary = execute_section27(
        config_path=args.config,
        output_dir=args.output_dir,
        input_path=args.input,
    )
    print(json.dumps(summary, indent=2, sort_keys=True))
    status = str(summary["overall_status"])
    return 1 if status == "FAIL" else 0


if __name__ == "__main__":
    raise SystemExit(main())
