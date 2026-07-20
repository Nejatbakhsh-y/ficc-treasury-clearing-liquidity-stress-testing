"""Command-line entry point for controlled FR 2004 ingestion."""

from __future__ import annotations

import argparse
import json
import logging
from pathlib import Path

from ficc_liquidity.data.fr2004 import DEFAULT_SOURCE_URL, ingest_fr2004

LOGGER = logging.getLogger(__name__)


def build_parser() -> argparse.ArgumentParser:
    project_root = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(
        description="Download and validate New York Fed FR 2004 Primary Dealer Statistics."
    )
    parser.add_argument("--source-url", default=DEFAULT_SOURCE_URL)
    parser.add_argument(
        "--raw-dir",
        type=Path,
        default=project_root / "data" / "raw" / "fr2004",
    )
    parser.add_argument(
        "--manifest",
        type=Path,
        default=project_root / "data" / "manifests" / "fr2004_manifest.csv",
    )
    parser.add_argument("--timeout-seconds", type=float, default=60.0)
    parser.add_argument("--max-attempts", type=int, default=5)
    parser.add_argument(
        "--no-cached-recovery",
        action="store_true",
        help="Fail instead of validating the latest immutable raw file after a download failure.",
    )
    return parser


def main() -> int:
    args = build_parser().parse_args()
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)sZ %(levelname)s %(name)s %(message)s",
        datefmt="%Y-%m-%dT%H:%M:%S",
    )
    result = ingest_fr2004(
        raw_dir=args.raw_dir,
        manifest_path=args.manifest,
        source_url=args.source_url,
        timeout_seconds=args.timeout_seconds,
        max_attempts=args.max_attempts,
        allow_cached_recovery=not args.no_cached_recovery,
    )
    summary = {
        "download_status": result.download_status,
        "retrieved_at_utc": result.retrieved_at_utc,
        "raw_file": str(result.raw_path),
        "manifest": str(result.manifest_path),
        "sha256": result.profile.sha256,
        "file_size_bytes": result.profile.file_size_bytes,
        "row_count": result.profile.row_count,
        "observation_start": result.profile.observation_start,
        "observation_end": result.profile.observation_end,
        "duplicate_rows": result.profile.duplicate_rows,
        "schema_status": result.profile.schema_status,
    }
    LOGGER.info("FR 2004 ingestion completed: %s", json.dumps(summary, sort_keys=True))
    print(json.dumps(summary, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
