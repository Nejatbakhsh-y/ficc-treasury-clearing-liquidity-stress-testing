"""Shared controls for official Federal Reserve data ingestion.

The helpers in this module are deliberately source-agnostic.  Source-specific
schema and economic validation remain in ``sofr.py``, ``h15.py`` and ``h41.py``.
"""

from __future__ import annotations

import csv
import hashlib
import os
import time
from collections.abc import Callable, Mapping, Sequence
from datetime import UTC, datetime
from pathlib import Path
from typing import Final
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

import pandas as pd

Downloader = Callable[[str], bytes]

MANIFEST_COLUMNS: Final[tuple[str, ...]] = (
    "source_id",
    "series_id",
    "retrieved_at_utc",
    "source_url",
    "raw_path",
    "processed_path",
    "sha256",
    "file_size_bytes",
    "row_count",
    "observation_start",
    "observation_end",
    "status",
    "notes",
)


class IngestionError(RuntimeError):
    """Raised when a controlled ingestion requirement is not satisfied."""


def utc_now() -> datetime:
    """Return a timezone-aware UTC timestamp."""

    return datetime.now(UTC)


def utc_timestamp(value: datetime) -> str:
    """Return an ISO-8601 UTC timestamp with second precision."""

    if value.tzinfo is None:
        raise IngestionError("retrieval timestamp must be timezone-aware")
    return value.astimezone(UTC).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def filename_timestamp(value: datetime) -> str:
    """Return a filesystem-safe UTC timestamp."""

    if value.tzinfo is None:
        raise IngestionError("retrieval timestamp must be timezone-aware")
    return value.astimezone(UTC).strftime("%Y%m%dT%H%M%SZ")


def sha256_bytes(payload: bytes) -> str:
    """Calculate a SHA-256 digest for a raw source payload."""

    return hashlib.sha256(payload).hexdigest()


def download_bytes(url: str, attempts: int = 4, timeout_seconds: int = 90) -> bytes:
    """Download bytes from an HTTPS endpoint with bounded retry recovery."""

    if not url.startswith("https://"):
        raise IngestionError(f"official-source URL must use HTTPS: {url}")
    if attempts < 1:
        raise IngestionError("attempts must be at least one")

    last_error: Exception | None = None
    for attempt in range(1, attempts + 1):
        try:
            request = Request(
                url,
                headers={
                    "Accept": "application/json,text/csv,text/plain,*/*",
                    "User-Agent": (
                        "ficc-liquidity-validation/0.1 (+controlled-public-data-ingestion)"
                    ),
                },
            )
            with urlopen(request, timeout=timeout_seconds) as response:
                payload = bytes(response.read())
            if not payload:
                raise IngestionError(f"empty payload returned by {url}")
            return payload
        except (HTTPError, URLError, TimeoutError, OSError, IngestionError) as exc:
            last_error = exc
            if attempt < attempts:
                time.sleep(min(2 ** (attempt - 1), 8))

    raise IngestionError(f"download failed after {attempts} attempts: {url}") from last_error


def save_immutable_raw(
    *,
    payload: bytes,
    raw_directory: Path,
    source_id: str,
    series_id: str,
    suffix: str,
    retrieved_at: datetime,
) -> tuple[Path, str]:
    """Persist an immutable raw payload using timestamp and hash identity."""

    digest = sha256_bytes(payload)
    safe_series = "".join(character if character.isalnum() else "_" for character in series_id)
    filename = f"{source_id}_{safe_series}_{filename_timestamp(retrieved_at)}_{digest[:12]}{suffix}"
    raw_directory.mkdir(parents=True, exist_ok=True)
    destination = raw_directory / filename

    if destination.exists():
        if destination.read_bytes() != payload:
            raise IngestionError(f"immutable raw-file collision: {destination}")
        return destination, digest

    temporary = destination.with_suffix(f"{destination.suffix}.tmp")
    temporary.write_bytes(payload)
    os.replace(temporary, destination)
    return destination, digest


def write_parquet_atomic(frame: pd.DataFrame, destination: Path) -> None:
    """Write a processed dataframe atomically in Parquet format."""

    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = destination.with_suffix(f"{destination.suffix}.tmp")
    frame.to_parquet(temporary, index=False)
    os.replace(temporary, destination)


def relative_posix(path: Path, project_root: Path) -> str:
    """Return a repository-relative POSIX path for auditable manifests."""

    return path.resolve().relative_to(project_root.resolve()).as_posix()


def observation_bounds(frame: pd.DataFrame) -> tuple[str, str]:
    """Return inclusive observation-date bounds for a validated dataframe."""

    if frame.empty:
        raise IngestionError("cannot calculate bounds for an empty dataframe")
    dates = pd.to_datetime(frame["observation_date"], errors="raise")
    return dates.min().date().isoformat(), dates.max().date().isoformat()


def validate_unique(frame: pd.DataFrame, keys: Sequence[str]) -> None:
    """Reject duplicate source observations."""

    duplicate_count = int(frame.duplicated(subset=list(keys), keep=False).sum())
    if duplicate_count:
        joined = ", ".join(keys)
        raise IngestionError(f"duplicate observations detected for [{joined}]: {duplicate_count}")


def validate_required_columns(frame: pd.DataFrame, required: Sequence[str]) -> None:
    """Reject schemas that omit required columns."""

    missing = [column for column in required if column not in frame.columns]
    if missing:
        raise IngestionError(f"required columns missing: {', '.join(missing)}")


def normalize_numeric(series: pd.Series) -> pd.Series:
    """Normalize official numeric text, including commas and FRED dot nulls."""

    text = series.astype("string").str.replace(",", "", regex=False).str.strip()
    return pd.to_numeric(text, errors="coerce")


def append_manifest(manifest_path: Path, row: Mapping[str, object]) -> None:
    """Append one controlled manifest row atomically, deduplicated by source hash."""

    manifest_path.parent.mkdir(parents=True, exist_ok=True)
    normalized = {column: str(row.get(column, "")) for column in MANIFEST_COLUMNS}

    existing_rows: list[dict[str, str]] = []
    if manifest_path.exists() and manifest_path.stat().st_size > 0:
        with manifest_path.open("r", encoding="utf-8", newline="") as handle:
            reader = csv.DictReader(handle)
            if tuple(reader.fieldnames or ()) != MANIFEST_COLUMNS:
                raise IngestionError(f"manifest schema mismatch: {manifest_path}")
            existing_rows.extend(reader)

    identity = (normalized["source_id"], normalized["series_id"], normalized["sha256"])
    if any(
        (item["source_id"], item["series_id"], item["sha256"]) == identity for item in existing_rows
    ):
        return

    existing_rows.append(normalized)
    temporary = manifest_path.with_suffix(f"{manifest_path.suffix}.tmp")
    with temporary.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(MANIFEST_COLUMNS))
        writer.writeheader()
        writer.writerows(existing_rows)
    os.replace(temporary, manifest_path)


def ensure_manifest_header(manifest_path: Path) -> None:
    """Create an empty source manifest with the controlled schema."""

    if manifest_path.exists() and manifest_path.stat().st_size > 0:
        return
    manifest_path.parent.mkdir(parents=True, exist_ok=True)
    with manifest_path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(MANIFEST_COLUMNS))
        writer.writeheader()
