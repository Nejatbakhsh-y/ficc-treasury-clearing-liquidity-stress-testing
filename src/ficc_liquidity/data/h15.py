"""Controlled H.15 Treasury constant-maturity yield ingestion pipeline."""

from __future__ import annotations

import argparse
import io
import json
from collections.abc import Sequence
from datetime import date, datetime
from pathlib import Path
from typing import Final
from urllib.parse import urlencode

import pandas as pd

from ficc_liquidity.data import _fed_common as common

SOURCE_ID: Final = "frb_h15"
FRED_CSV_URL: Final = "https://fred.stlouisfed.org/graph/fredgraph.csv"
SERIES_IDS: Final[tuple[str, ...]] = (
    "DGS1MO",
    "DGS3MO",
    "DGS6MO",
    "DGS1",
    "DGS2",
    "DGS3",
    "DGS5",
    "DGS7",
    "DGS10",
    "DGS20",
    "DGS30",
)


def build_url(series_id: str, start_date: date | None = None, end_date: date | None = None) -> str:
    """Build the official Federal Reserve Bank of St. Louis CSV URL."""

    if series_id not in SERIES_IDS:
        raise common.IngestionError(f"uncontrolled H.15 series: {series_id}")
    if start_date is not None and end_date is not None and start_date > end_date:
        raise common.IngestionError("H.15 start date cannot be after end date")
    parameters = {"id": series_id}
    if start_date is not None:
        parameters["cosd"] = start_date.isoformat()
    if end_date is not None:
        parameters["coed"] = end_date.isoformat()
    return f"{FRED_CSV_URL}?{urlencode(parameters)}"


def parse_series_payload(payload: bytes, series_id: str) -> pd.DataFrame:
    """Parse and validate one H.15 FRED CSV series."""

    if series_id not in SERIES_IDS:
        raise common.IngestionError(f"uncontrolled H.15 series: {series_id}")
    try:
        source = pd.read_csv(io.BytesIO(payload), dtype="string")
    except (UnicodeDecodeError, pd.errors.ParserError) as exc:
        raise common.IngestionError(f"invalid H.15 CSV for {series_id}") from exc

    date_column = "observation_date" if "observation_date" in source.columns else "DATE"
    common.validate_required_columns(source, [date_column, series_id])
    frame = pd.DataFrame(
        {
            "observation_date": pd.to_datetime(source[date_column], errors="coerce"),
            "series_id": series_id,
            "value": common.normalize_numeric(source[series_id]),
        }
    )
    frame = frame.dropna(subset=["value"]).reset_index(drop=True)
    if frame.empty:
        raise common.IngestionError(f"H.15 series has no usable observations: {series_id}")
    if frame["observation_date"].isna().any():
        raise common.IngestionError(f"H.15 series has invalid dates: {series_id}")
    if not frame["value"].between(-20.0, 100.0).all():
        raise common.IngestionError(f"H.15 value outside controlled range: {series_id}")
    common.validate_unique(frame, ["observation_date", "series_id"])
    return frame.sort_values("observation_date").reset_index(drop=True)


def ingest(
    project_root: Path,
    *,
    start_date: date | None = None,
    end_date: date | None = None,
    downloader: common.Downloader = common.download_bytes,
    retrieved_at: datetime | None = None,
    series_ids: Sequence[str] = SERIES_IDS,
) -> dict[str, object]:
    """Download, preserve, validate, combine and manifest H.15 series."""

    retrieval_time = retrieved_at or common.utc_now()
    requested = tuple(series_ids)
    if not requested or len(set(requested)) != len(requested):
        raise common.IngestionError("H.15 series list must be nonempty and unique")
    uncontrolled = sorted(set(requested).difference(SERIES_IDS))
    if uncontrolled:
        raise common.IngestionError(f"uncontrolled H.15 series: {', '.join(uncontrolled)}")

    frames: list[pd.DataFrame] = []
    raw_metadata: list[dict[str, object]] = []
    raw_directory = project_root / "data" / "raw" / "fed" / "h15"
    for series_id in requested:
        url = build_url(series_id, start_date, end_date)
        payload = downloader(url)
        raw_path, digest = common.save_immutable_raw(
            payload=payload,
            raw_directory=raw_directory,
            source_id=SOURCE_ID,
            series_id=series_id,
            suffix=".csv",
            retrieved_at=retrieval_time,
        )
        frame = parse_series_payload(payload, series_id)
        frames.append(frame)
        observation_start, observation_end = common.observation_bounds(frame)
        raw_metadata.append(
            {
                "series_id": series_id,
                "url": url,
                "raw_path": raw_path,
                "digest": digest,
                "file_size_bytes": len(payload),
                "row_count": len(frame),
                "observation_start": observation_start,
                "observation_end": observation_end,
            }
        )

    combined = pd.concat(frames, ignore_index=True).sort_values(["observation_date", "series_id"])
    common.validate_unique(combined, ["observation_date", "series_id"])
    combined_digest = common.sha256_bytes(
        "|".join(str(item["digest"]) for item in raw_metadata).encode("ascii")
    )
    processed_path = (
        project_root
        / "data"
        / "processed"
        / "fed"
        / "h15"
        / f"h15_treasury_yields_{combined_digest[:12]}.parquet"
    )
    common.write_parquet_atomic(combined, processed_path)

    manifest_path = project_root / "data" / "manifests" / "h15_manifest.csv"
    for item in raw_metadata:
        common.append_manifest(
            manifest_path,
            {
                "source_id": SOURCE_ID,
                "series_id": item["series_id"],
                "retrieved_at_utc": common.utc_timestamp(retrieval_time),
                "source_url": item["url"],
                "raw_path": common.relative_posix(Path(str(item["raw_path"])), project_root),
                "processed_path": common.relative_posix(processed_path, project_root),
                "sha256": item["digest"],
                "file_size_bytes": item["file_size_bytes"],
                "row_count": item["row_count"],
                "observation_start": item["observation_start"],
                "observation_end": item["observation_end"],
                "status": "PASS",
                "notes": "H.15 Treasury constant-maturity yield via official FRED CSV.",
            },
        )

    observation_start, observation_end = common.observation_bounds(combined)
    return {
        "source_id": SOURCE_ID,
        "rows": len(combined),
        "series_count": len(requested),
        "observation_start": observation_start,
        "observation_end": observation_end,
        "processed_path": processed_path,
        "manifest_path": manifest_path,
    }


def _parse_iso_date(value: str | None) -> date | None:
    return date.fromisoformat(value) if value else None


def main(argv: Sequence[str] | None = None) -> int:
    """Command-line entry point for the H.15 pipeline."""

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project-root", type=Path, default=Path.cwd())
    parser.add_argument("--start-date")
    parser.add_argument("--end-date")
    arguments = parser.parse_args(argv)
    result = ingest(
        arguments.project_root.resolve(),
        start_date=_parse_iso_date(arguments.start_date),
        end_date=_parse_iso_date(arguments.end_date),
    )
    print(json.dumps({key: str(value) for key, value in result.items()}, indent=2))
    return 0


if __name__ == "__main__":  # pragma: no cover
    raise SystemExit(main())
