"""Execute Phase IV, Section 12 synthetic-member aggregate calibration."""

from __future__ import annotations

import argparse
from pathlib import Path

from ficc_liquidity.synthetic.calibrate_members import (
    result_summary,
    run_calibration,
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--project-root",
        type=Path,
        default=Path.cwd(),
        help="Repository root. Defaults to the current directory.",
    )
    parser.add_argument(
        "--config",
        type=Path,
        default=Path("configs/synthetic_calibration.yaml"),
        help="Controlled Section 12 YAML configuration.",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    project_root = args.project_root.resolve()
    config_path = args.config if args.config.is_absolute() else project_root / args.config
    result = run_calibration(project_root, config_path)
    print(result_summary(result))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
