"""Command-line entry point for Section 8 processed analytical datasets."""

from __future__ import annotations

import argparse
import json
import logging
from pathlib import Path

from ficc_liquidity.data.processed import build_processed_datasets


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--repo-root",
        type=Path,
        default=Path.cwd(),
        help="Repository root. Defaults to the current working directory.",
    )
    parser.add_argument(
        "--config",
        type=Path,
        default=Path("configs/processed_data.yaml"),
        help="Processed-data configuration path, relative to the repository root.",
    )
    parser.add_argument("--log-level", default="INFO")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    logging.basicConfig(
        level=getattr(logging, args.log_level.upper()),
        format="%(asctime)s %(levelname)s %(name)s â€” %(message)s",
    )
    repo_root = args.repo_root.resolve()
    config_path = args.config if args.config.is_absolute() else repo_root / args.config
    result = build_processed_datasets(repo_root, config_path)
    print(json.dumps(result, indent=2, default=str))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
