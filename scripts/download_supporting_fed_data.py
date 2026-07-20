"""Run the controlled SOFR, H.15 and H.4.1 ingestion pipelines."""

from __future__ import annotations

import argparse
import json
from collections.abc import Sequence
from datetime import date
from pathlib import Path

from ficc_liquidity.data import h15, h41, sofr


def _parse_date(value: str | None) -> date | None:
    return date.fromisoformat(value) if value else None


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project-root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--source", choices=("all", "sofr", "h15", "h41"), default="all")
    parser.add_argument("--start-date")
    parser.add_argument("--end-date")
    arguments = parser.parse_args(argv)

    project_root = arguments.project_root.resolve()
    start_date = _parse_date(arguments.start_date)
    end_date = _parse_date(arguments.end_date)
    results: dict[str, object] = {}

    if arguments.source in {"all", "sofr"}:
        results["sofr"] = sofr.ingest(project_root, start_date=start_date, end_date=end_date)
    if arguments.source in {"all", "h15"}:
        results["h15"] = h15.ingest(project_root, start_date=start_date, end_date=end_date)
    if arguments.source in {"all", "h41"}:
        results["h41"] = h41.ingest(project_root, start_date=start_date, end_date=end_date)

    print(
        json.dumps(
            results,
            indent=2,
            default=lambda value: value.as_posix() if isinstance(value, Path) else str(value),
        )
    )
    return 0


if __name__ == "__main__":  # pragma: no cover
    raise SystemExit(main())
