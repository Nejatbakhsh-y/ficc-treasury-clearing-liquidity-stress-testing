"""Controlled New York Fed SOFR ingestion pipeline."""

from __future__ import annotations

import argparse
import json
from collections.abc import Mapping, Sequence
from datetime import date, datetime
from pathlib import Path
from typing import Final
from urllib.parse import urlencode

import pandas as pd

from ficc_liquidity.data import _fed_common as common

SOURCE_ID: Final = "nyfed_sofr"
SOFR_HISTORY_START: Final = date(2018, 4, 2)
SOURCE_URL: Final = "https://markets.newyorkfed.org/api/rates/secured/sofr/search.json"
FIELD_MAP: Final[dict[str, tuple[str, ...]]] = {
    "observation_date": ("effectiveDate", "effective_date", "date", "businessDate"),
    "sofr_rate": ("percentRate", "rate", "sofr"),
    "percentile_01": ("percentile1", "percentile01", "percentile_1"),
    "percentile_25": ("percentile25", "percentile_25"),
    "percentile_75": ("percentile75", "percentile_75"),
    "percentile_99": ("percentile99", "percentile_99"),
    "volume_billions": ("volumeInBillions", "volume", "volume_billions"),
    "revision_indicator": ("revisionIndicator", "revision", "revision_indicator"),
}
OUTPUT_COLUMNS: Final[tuple[str, ...]] = tuple(FIELD_MAP)


def build_url(start_date: date | None = None, end_date: date | None = None) -> str:
    """Build the official SOFR historical-search API URL."""

    effective_start = start_date or SOFR_HISTORY_START
    parameters: dict[str, str] = {
        "type": "rate",
        "startDate": effective_start.isoformat(),
    }
    if end_date is not None:
        parameters["endDate"] = end_date.isoformat()
    if start_date is not None and end_date is not None and start_date > end_date:
        raise common.IngestionError("SOFR start date cannot be after end date")
    return f"{SOURCE_URL}?{urlencode(parameters)}"


def _records_from_document(document: object) -> list[Mapping[str, object]]:
    if isinstance(document, list):
        records = document
    elif isinstance(document, dict):
        candidate: object | None = None
        for key in ("refRates", "rates", "results", "data", "observations"):
            if key in document:
                candidate = document[key]
                break
        if isinstance(candidate, dict):
            for key in ("refRates", "rates", "results", "data", "observations"):
                nested = candidate.get(key)
                if isinstance(nested, list):
                    candidate = nested
                    break
        records = candidate if isinstance(candidate, list) else []
    else:
        records = []

    normalized: list[Mapping[str, object]] = []
    for record in records:
        if isinstance(record, Mapping):
            normalized.append(record)
    if not normalized:
        raise common.IngestionError("SOFR payload contains no observation records")
    return normalized


def _first_value(record: Mapping[str, object], candidates: Sequence[str]) -> object:
    for candidate in candidates:
        if candidate in record:
            return record[candidate]
    return None


def parse_payload(payload: bytes) -> pd.DataFrame:
    """Parse and validate a New York Fed SOFR JSON payload."""

    try:
        document = json.loads(payload.decode("utf-8-sig"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise common.IngestionError("SOFR payload is not valid UTF-8 JSON") from exc

    rows: list[dict[str, object]] = []
    for record in _records_from_document(document):
        rows.append(
            {output: _first_value(record, candidates) for output, candidates in FIELD_MAP.items()}
        )

    frame = pd.DataFrame(rows, columns=list(OUTPUT_COLUMNS))
    frame["observation_date"] = pd.to_datetime(
        frame["observation_date"], errors="coerce", utc=False
    ).dt.normalize()
    for column in (
        "sofr_rate",
        "percentile_01",
        "percentile_25",
        "percentile_75",
        "percentile_99",
        "volume_billions",
    ):
        frame[column] = common.normalize_numeric(frame[column])
    frame["revision_indicator"] = frame["revision_indicator"].astype("string").fillna("")

    if frame["observation_date"].isna().any():
        raise common.IngestionError("SOFR payload contains an invalid observation date")
    if frame["sofr_rate"].isna().any():
        raise common.IngestionError("SOFR rate is missing or nonnumeric")
    if not frame["sofr_rate"].between(-10.0, 100.0).all():
        raise common.IngestionError("SOFR rate is outside the controlled range [-10, 100]")
    if frame["volume_billions"].dropna().lt(0).any():
        raise common.IngestionError("SOFR transaction volume cannot be negative")

    percentile_columns = ["percentile_01", "percentile_25", "percentile_75", "percentile_99"]
    complete = frame[percentile_columns].notna().all(axis=1)
    ordered = (
        (frame.loc[complete, "percentile_01"] <= frame.loc[complete, "percentile_25"])
        & (frame.loc[complete, "percentile_25"] <= frame.loc[complete, "sofr_rate"])
        & (frame.loc[complete, "sofr_rate"] <= frame.loc[complete, "percentile_75"])
        & (frame.loc[complete, "percentile_75"] <= frame.loc[complete, "percentile_99"])
    )
    if not ordered.all():
        raise common.IngestionError("SOFR percentile ordering is invalid")

    common.validate_unique(frame, ["observation_date"])
    return frame.sort_values("observation_date").reset_index(drop=True)


def ingest(
    project_root: Path,
    *,
    start_date: date | None = None,
    end_date: date | None = None,
    downloader: common.Downloader = common.download_bytes,
    retrieved_at: datetime | None = None,
) -> dict[str, object]:
    """Download, preserve, validate, transform and manifest SOFR observations."""

    retrieval_time = retrieved_at or common.utc_now()
    url = build_url(start_date, end_date)
    payload = downloader(url)
    raw_path, digest = common.save_immutable_raw(
        payload=payload,
        raw_directory=project_root / "data" / "raw" / "fed" / "sofr",
        source_id=SOURCE_ID,
        series_id="SOFR",
        suffix=".json",
        retrieved_at=retrieval_time,
    )
    frame = parse_payload(payload)
    processed_path = (
        project_root / "data" / "processed" / "fed" / "sofr" / f"sofr_{digest[:12]}.parquet"
    )
    common.write_parquet_atomic(frame, processed_path)
    observation_start, observation_end = common.observation_bounds(frame)
    manifest_path = project_root / "data" / "manifests" / "sofr_manifest.csv"
    common.append_manifest(
        manifest_path,
        {
            "source_id": SOURCE_ID,
            "series_id": "SOFR_RATE_PERCENTILES_VOLUME",
            "retrieved_at_utc": common.utc_timestamp(retrieval_time),
            "source_url": url,
            "raw_path": common.relative_posix(raw_path, project_root),
            "processed_path": common.relative_posix(processed_path, project_root),
            "sha256": digest,
            "file_size_bytes": len(payload),
            "row_count": len(frame),
            "observation_start": observation_start,
            "observation_end": observation_end,
            "status": "PASS",
            "notes": "Official New York Fed SOFR rate, percentiles and volume.",
        },
    )
    return {
        "source_id": SOURCE_ID,
        "rows": len(frame),
        "observation_start": observation_start,
        "observation_end": observation_end,
        "raw_path": raw_path,
        "processed_path": processed_path,
        "manifest_path": manifest_path,
    }


def _parse_iso_date(value: str | None) -> date | None:
    return date.fromisoformat(value) if value else None


def main(argv: Sequence[str] | None = None) -> int:
    """Command-line entry point for the SOFR pipeline."""

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
