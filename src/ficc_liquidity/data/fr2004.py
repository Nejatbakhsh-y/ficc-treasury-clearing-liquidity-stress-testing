"""Controlled ingestion for New York Fed FR 2004 Primary Dealer Statistics."""

from __future__ import annotations

import csv
import hashlib
import json
import os
import re
import shutil
import stat
import tempfile
from collections.abc import Iterable, Mapping
from dataclasses import asdict, dataclass
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

import pandas as pd
import requests
from requests.adapters import HTTPAdapter
from urllib3.util.retry import Retry

DEFAULT_SOURCE_URL = "https://markets.newyorkfed.org/api/pd/get/all/timeseries.csv"
OFFICIAL_PAGE_URL = "https://www.newyorkfed.org/markets/counterparties/primary-dealers-statistics"
SOURCE_NAME = "FR 2004 Primary Dealer Statistics"

MANIFEST_COLUMNS = [
    "source_name",
    "source_url",
    "official_page_url",
    "retrieved_at_utc",
    "download_status",
    "raw_file",
    "sha256",
    "file_size_bytes",
    "row_count",
    "observation_start",
    "observation_end",
    "column_count",
    "columns_json",
    "duplicate_rows",
    "schema_status",
    "http_status",
    "download_attempts",
    "etag",
    "last_modified",
    "content_type",
    "error_message",
]

_COLUMN_ALIASES = {
    "observation_date": {
        "as_of_date",
        "asof_date",
        "date",
        "observation_date",
        "report_date",
    },
    "series_id": {
        "time_series",
        "timeseries",
        "time_series_id",
        "series_id",
        "key_id",
        "keyid",
    },
    "value": {
        "value",
        "value_millions",
        "amount",
        "observation_value",
    },
    "series_break": {
        "series_break",
        "seriesbreak",
        "series_break_id",
    },
}

_NULL_VALUE_TOKENS = {"", ".", "-", "*", "na", "n/a", "n.a.", "null", "none"}


class FR2004Error(RuntimeError):
    """Base error for FR 2004 ingestion."""


class DownloadError(FR2004Error):
    """Raised when the official-source download fails."""


class SchemaValidationError(FR2004Error):
    """Raised when the downloaded file does not satisfy the source contract."""


class DuplicateObservationError(SchemaValidationError):
    """Raised when duplicate observation keys are present."""


@dataclass(frozen=True)
class FileProfile:
    """Validated file-level statistics used by the source manifest."""

    sha256: str
    file_size_bytes: int
    row_count: int
    observation_start: str
    observation_end: str
    column_count: int
    columns_json: str
    duplicate_rows: int
    schema_status: str = "PASS"


@dataclass(frozen=True)
class DownloadMetadata:
    """HTTP metadata captured during retrieval."""

    http_status: int | None
    download_attempts: int
    etag: str
    last_modified: str
    content_type: str


@dataclass(frozen=True)
class IngestionResult:
    """Result returned by the controlled ingestion workflow."""

    raw_path: Path
    manifest_path: Path
    retrieved_at_utc: str
    download_status: str
    profile: FileProfile
    download_metadata: DownloadMetadata


class _CountingHTTPAdapter(HTTPAdapter):
    """HTTP adapter that counts transport attempts, including retries."""

    def __init__(self, *args: Any, **kwargs: Any) -> None:
        self.attempts = 0
        super().__init__(*args, **kwargs)

    def send(
        self,
        request: requests.PreparedRequest,
        stream: bool = False,
        timeout: float | tuple[float | None, float | None] | None = None,
        verify: bool | str = True,
        cert: str | tuple[str, str] | None = None,
        proxies: dict[str, str] | None = None,
    ) -> requests.Response:
        self.attempts += 1
        return super().send(
            request=request,
            stream=stream,
            timeout=timeout,
            verify=verify,
            cert=cert,
            proxies=proxies,
        )


def utc_timestamp(now: datetime | None = None) -> str:
    """Return a second-resolution UTC timestamp in ISO 8601 form."""

    value = now or datetime.now(UTC)
    if value.tzinfo is None:
        value = value.replace(tzinfo=UTC)
    return value.astimezone(UTC).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def _filename_timestamp(retrieved_at_utc: str) -> str:
    parsed = datetime.fromisoformat(retrieved_at_utc.replace("Z", "+00:00"))
    return parsed.astimezone(UTC).strftime("%Y%m%dT%H%M%SZ")


def _normalize_column(name: str) -> str:
    normalized = re.sub(r"[^a-z0-9]+", "_", name.strip().lower()).strip("_")
    return normalized.replace("value_in_millions", "value_millions")


def _resolve_columns(columns: Iterable[str]) -> dict[str, str]:
    normalized_to_original = {_normalize_column(column): column for column in columns}
    resolved: dict[str, str] = {}
    for canonical, aliases in _COLUMN_ALIASES.items():
        for alias in aliases:
            if alias in normalized_to_original:
                resolved[canonical] = normalized_to_original[alias]
                break
    missing = {"observation_date", "series_id", "value"} - resolved.keys()
    if missing:
        available = ", ".join(str(column) for column in columns)
        raise SchemaValidationError(
            "Missing required FR 2004 field(s): "
            f"{', '.join(sorted(missing))}. Available columns: {available}"
        )
    return resolved


def sha256_file(path: Path, chunk_size: int = 1024 * 1024) -> str:
    """Return the SHA-256 digest of a file."""

    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while chunk := handle.read(chunk_size):
            digest.update(chunk)
    return digest.hexdigest()


def _validate_values(series: pd.Series) -> None:
    text = series.astype("string").fillna("").str.strip()
    normalized = text.str.lower()
    candidate = text.str.replace(",", "", regex=False).str.replace("$", "", regex=False)
    candidate = candidate.str.replace(r"^\((.*)\)$", r"-\1", regex=True)
    numeric = pd.to_numeric(candidate, errors="coerce")
    invalid = numeric.isna() & ~normalized.isin(_NULL_VALUE_TOKENS)
    if invalid.any():
        examples = sorted(set(text[invalid].head(5).tolist()))
        raise SchemaValidationError(
            f"The value column contains nonnumeric, nonsuppression values: {examples}"
        )
    if numeric.notna().sum() == 0:
        raise SchemaValidationError("The value column contains no numeric observations.")


def validate_and_profile_csv(path: Path) -> FileProfile:
    """Validate source schema, dates, values, and duplicate observation keys."""

    if not path.exists() or not path.is_file():
        raise SchemaValidationError(f"FR 2004 file does not exist: {path}")
    if path.stat().st_size == 0:
        raise SchemaValidationError("FR 2004 file is empty.")

    try:
        frame = pd.read_csv(path, dtype="string", keep_default_na=False)
    except Exception as exc:
        raise SchemaValidationError(f"FR 2004 CSV parsing failed: {exc}") from exc

    if frame.empty:
        raise SchemaValidationError("FR 2004 CSV contains no data rows.")
    if frame.columns.duplicated().any():
        duplicates = frame.columns[frame.columns.duplicated()].tolist()
        raise SchemaValidationError(f"FR 2004 CSV contains duplicate columns: {duplicates}")

    resolved = _resolve_columns([str(column) for column in frame.columns])
    date_column = resolved["observation_date"]
    series_column = resolved["series_id"]
    value_column = resolved["value"]

    parsed_dates = pd.to_datetime(frame[date_column], errors="coerce", utc=True)
    invalid_date_count = int(parsed_dates.isna().sum())
    if invalid_date_count:
        raise SchemaValidationError(
            f"FR 2004 CSV contains {invalid_date_count} invalid observation date(s)."
        )

    series_ids = frame[series_column].astype("string").str.strip()
    if series_ids.eq("").any():
        raise SchemaValidationError("FR 2004 CSV contains blank series identifiers.")

    _validate_values(frame[value_column])

    duplicate_key = [series_column, date_column]
    if "series_break" in resolved:
        duplicate_key.insert(0, resolved["series_break"])
    duplicate_mask = frame.duplicated(subset=duplicate_key, keep=False)
    duplicate_rows = int(duplicate_mask.sum())
    if duplicate_rows:
        raise DuplicateObservationError(
            f"FR 2004 CSV contains {duplicate_rows} rows involved in duplicate "
            f"observation keys {duplicate_key}."
        )

    columns = [str(column) for column in frame.columns]
    return FileProfile(
        sha256=sha256_file(path),
        file_size_bytes=path.stat().st_size,
        row_count=len(frame),
        observation_start=parsed_dates.min().date().isoformat(),
        observation_end=parsed_dates.max().date().isoformat(),
        column_count=len(columns),
        columns_json=json.dumps(columns, ensure_ascii=True, separators=(",", ":")),
        duplicate_rows=duplicate_rows,
    )


def build_session(max_attempts: int = 5) -> tuple[requests.Session, _CountingHTTPAdapter]:
    """Build a retry-enabled HTTP session for official-source retrieval."""

    if max_attempts < 1:
        raise ValueError("max_attempts must be at least 1")
    retry = Retry(
        total=max_attempts - 1,
        connect=max_attempts - 1,
        read=max_attempts - 1,
        status=max_attempts - 1,
        backoff_factor=1.0,
        status_forcelist=(408, 425, 429, 500, 502, 503, 504),
        allowed_methods=frozenset({"GET"}),
        raise_on_status=False,
        respect_retry_after_header=True,
    )
    adapter = _CountingHTTPAdapter(max_retries=retry)
    session = requests.Session()
    session.headers.update(
        {
            "Accept": "text/csv,application/csv,text/plain;q=0.9,*/*;q=0.1",
            "User-Agent": "ficc-liquidity-fr2004-ingestion/0.1",
        }
    )
    session.mount("https://", adapter)
    return session, adapter


def _download_to_staging(
    source_url: str,
    staging_path: Path,
    timeout_seconds: float,
    max_attempts: int,
    session: requests.Session | None = None,
) -> DownloadMetadata:
    owned_session = session is None
    adapter: _CountingHTTPAdapter | None = None
    if session is None:
        session, adapter = build_session(max_attempts=max_attempts)

    try:
        with session.get(source_url, stream=True, timeout=timeout_seconds) as response:
            http_status = response.status_code
            if http_status != 200:
                raise DownloadError(
                    f"Official FR 2004 source returned HTTP {http_status}: {source_url}"
                )
            content_type = response.headers.get("Content-Type", "")
            if "html" in content_type.lower():
                raise DownloadError(
                    "Official FR 2004 source returned HTML instead of a CSV payload."
                )
            with staging_path.open("wb") as handle:
                for chunk in response.iter_content(chunk_size=1024 * 1024):
                    if chunk:
                        handle.write(chunk)
                handle.flush()
                os.fsync(handle.fileno())
            if staging_path.stat().st_size == 0:
                raise DownloadError("Official FR 2004 source returned an empty payload.")
            return DownloadMetadata(
                http_status=http_status,
                download_attempts=adapter.attempts if adapter is not None else 1,
                etag=response.headers.get("ETag", ""),
                last_modified=response.headers.get("Last-Modified", ""),
                content_type=content_type,
            )
    except DownloadError:
        raise
    except requests.RequestException as exc:
        attempts = adapter.attempts if adapter is not None else 1
        raise DownloadError(f"FR 2004 download failed after {attempts} attempt(s): {exc}") from exc
    finally:
        if owned_session:
            session.close()


def _make_read_only(path: Path) -> None:
    path.chmod(stat.S_IREAD | stat.S_IRGRP | stat.S_IROTH)


def _promote_immutable_raw(
    staging_path: Path,
    raw_dir: Path,
    retrieved_at_utc: str,
    digest: str,
) -> Path:
    raw_dir.mkdir(parents=True, exist_ok=True)
    final_name = f"fr2004_{_filename_timestamp(retrieved_at_utc)}_{digest[:12]}.csv"
    final_path = raw_dir / final_name
    if final_path.exists():
        if sha256_file(final_path) != digest:
            raise FR2004Error(f"Immutable raw-file collision detected: {final_path}")
        staging_path.unlink(missing_ok=True)
        return final_path
    shutil.move(str(staging_path), str(final_path))
    _make_read_only(final_path)
    return final_path


def _latest_raw_file(raw_dir: Path) -> Path | None:
    candidates = sorted(raw_dir.glob("fr2004_*.csv"), key=lambda item: item.name)
    return candidates[-1] if candidates else None


def _atomic_write_manifest(path: Path, rows: list[dict[str, str]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(
        mode="w",
        encoding="utf-8",
        newline="",
        dir=path.parent,
        delete=False,
        suffix=".tmp",
    ) as handle:
        temporary_path = Path(handle.name)
        writer = csv.DictWriter(handle, fieldnames=MANIFEST_COLUMNS, extrasaction="ignore")
        writer.writeheader()
        writer.writerows(rows)
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(temporary_path, path)


def read_manifest(path: Path) -> list[dict[str, str]]:
    """Read an existing manifest and enforce its controlled column contract."""

    if not path.exists():
        return []
    with path.open("r", encoding="utf-8", newline="") as handle:
        reader = csv.DictReader(handle)
        if reader.fieldnames != MANIFEST_COLUMNS:
            raise FR2004Error(
                "Existing FR 2004 manifest columns do not match the controlled schema."
            )
        return [dict(row) for row in reader]


def append_manifest_row(path: Path, row: Mapping[str, Any]) -> None:
    """Append a manifest row through an atomic full-file replacement."""

    rows = read_manifest(path)
    normalized = {column: str(row.get(column, "")) for column in MANIFEST_COLUMNS}
    rows.append(normalized)
    _atomic_write_manifest(path, rows)


def initialize_manifest(path: Path) -> None:
    """Create an empty controlled manifest if one does not already exist."""

    if not path.exists():
        _atomic_write_manifest(path, [])


def _raw_file_reference(raw_path: Path | None, manifest_path: Path) -> str:
    if raw_path is None:
        return ""
    manifest_parent = manifest_path.parent
    if manifest_parent.name == "manifests" and manifest_parent.parent.name == "data":
        project_root = manifest_parent.parent.parent
        try:
            return raw_path.resolve().relative_to(project_root.resolve()).as_posix()
        except ValueError:
            pass
    return raw_path.as_posix()


def _manifest_row(
    *,
    source_url: str,
    retrieved_at_utc: str,
    download_status: str,
    raw_path: Path | None,
    manifest_path: Path,
    profile: FileProfile | None,
    metadata: DownloadMetadata,
    error_message: str = "",
) -> dict[str, str]:
    profile_data = asdict(profile) if profile is not None else {}
    return {
        "source_name": SOURCE_NAME,
        "source_url": source_url,
        "official_page_url": OFFICIAL_PAGE_URL,
        "retrieved_at_utc": retrieved_at_utc,
        "download_status": download_status,
        "raw_file": _raw_file_reference(raw_path, manifest_path),
        "sha256": str(profile_data.get("sha256", "")),
        "file_size_bytes": str(profile_data.get("file_size_bytes", "")),
        "row_count": str(profile_data.get("row_count", "")),
        "observation_start": str(profile_data.get("observation_start", "")),
        "observation_end": str(profile_data.get("observation_end", "")),
        "column_count": str(profile_data.get("column_count", "")),
        "columns_json": str(profile_data.get("columns_json", "")),
        "duplicate_rows": str(profile_data.get("duplicate_rows", "")),
        "schema_status": str(profile_data.get("schema_status", "FAIL")),
        "http_status": "" if metadata.http_status is None else str(metadata.http_status),
        "download_attempts": str(metadata.download_attempts),
        "etag": metadata.etag,
        "last_modified": metadata.last_modified,
        "content_type": metadata.content_type,
        "error_message": error_message,
    }


def ingest_fr2004(
    *,
    raw_dir: Path,
    manifest_path: Path,
    source_url: str = DEFAULT_SOURCE_URL,
    timeout_seconds: float = 60.0,
    max_attempts: int = 5,
    allow_cached_recovery: bool = True,
    now: datetime | None = None,
    session: requests.Session | None = None,
) -> IngestionResult:
    """Download, validate, preserve, profile, and manifest the FR 2004 extract."""

    retrieved_at_utc = utc_timestamp(now)
    raw_dir.mkdir(parents=True, exist_ok=True)
    staging_dir = raw_dir / ".staging"
    staging_dir.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(
        prefix="fr2004_",
        suffix=".part",
        dir=staging_dir,
        delete=False,
    ) as staging_handle:
        staging_path = Path(staging_handle.name)

    metadata = DownloadMetadata(
        http_status=None,
        download_attempts=0,
        etag="",
        last_modified="",
        content_type="",
    )
    try:
        metadata = _download_to_staging(
            source_url=source_url,
            staging_path=staging_path,
            timeout_seconds=timeout_seconds,
            max_attempts=max_attempts,
            session=session,
        )
        staging_profile = validate_and_profile_csv(staging_path)
        raw_path = _promote_immutable_raw(
            staging_path=staging_path,
            raw_dir=raw_dir,
            retrieved_at_utc=retrieved_at_utc,
            digest=staging_profile.sha256,
        )
        profile = validate_and_profile_csv(raw_path)
        status = "downloaded"
        append_manifest_row(
            manifest_path,
            _manifest_row(
                source_url=source_url,
                retrieved_at_utc=retrieved_at_utc,
                download_status=status,
                raw_path=raw_path,
                manifest_path=manifest_path,
                profile=profile,
                metadata=metadata,
            ),
        )
        return IngestionResult(
            raw_path=raw_path,
            manifest_path=manifest_path,
            retrieved_at_utc=retrieved_at_utc,
            download_status=status,
            profile=profile,
            download_metadata=metadata,
        )
    except SchemaValidationError as exc:
        append_manifest_row(
            manifest_path,
            _manifest_row(
                source_url=source_url,
                retrieved_at_utc=retrieved_at_utc,
                download_status="validation_failed",
                raw_path=None,
                manifest_path=manifest_path,
                profile=None,
                metadata=metadata,
                error_message=str(exc),
            ),
        )
        raise
    except DownloadError as exc:
        staging_path.unlink(missing_ok=True)
        cached_path = _latest_raw_file(raw_dir) if allow_cached_recovery else None
        if cached_path is None:
            metadata = DownloadMetadata(
                http_status=None,
                download_attempts=max_attempts,
                etag="",
                last_modified="",
                content_type="",
            )
            append_manifest_row(
                manifest_path,
                _manifest_row(
                    source_url=source_url,
                    retrieved_at_utc=retrieved_at_utc,
                    download_status="failed",
                    raw_path=None,
                    manifest_path=manifest_path,
                    profile=None,
                    metadata=metadata,
                    error_message=str(exc),
                ),
            )
            raise
        profile = validate_and_profile_csv(cached_path)
        metadata = DownloadMetadata(
            http_status=None,
            download_attempts=max_attempts,
            etag="",
            last_modified="",
            content_type="text/csv (cached)",
        )
        status = "cached_recovery"
        append_manifest_row(
            manifest_path,
            _manifest_row(
                source_url=source_url,
                retrieved_at_utc=retrieved_at_utc,
                download_status=status,
                raw_path=cached_path,
                manifest_path=manifest_path,
                profile=profile,
                metadata=metadata,
                error_message=str(exc),
            ),
        )
        return IngestionResult(
            raw_path=cached_path,
            manifest_path=manifest_path,
            retrieved_at_utc=retrieved_at_utc,
            download_status=status,
            profile=profile,
            download_metadata=metadata,
        )
    finally:
        staging_path.unlink(missing_ok=True)
