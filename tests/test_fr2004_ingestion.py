from __future__ import annotations

import csv
from datetime import UTC, datetime
from pathlib import Path

import pytest

from ficc_liquidity.data import fr2004

VALID_CSV = """As Of Date,Time Series,Value (millions),Series Break
2024-07-03,PDPOSGSC-L2,100,SBN2024
2024-07-10,PDPOSGSC-L2,110,SBN2024
2024-07-03,PDPOSGSC-L3,200,SBN2024
"""


class FakeResponse:
    status_code = 200
    headers = {
        "Content-Type": "text/csv",
        "ETag": '"sample-etag"',
        "Last-Modified": "Thu, 11 Jul 2024 20:15:00 GMT",
    }

    def __enter__(self) -> FakeResponse:
        return self

    def __exit__(self, *_args: object) -> None:
        return None

    def iter_content(self, chunk_size: int) -> list[bytes]:
        assert chunk_size > 0
        return [VALID_CSV.encode("utf-8")]


class FakeSession:
    def get(self, *_args: object, **_kwargs: object) -> FakeResponse:
        return FakeResponse()


def write_csv(path: Path, content: str = VALID_CSV) -> Path:
    path.write_text(content, encoding="utf-8")
    return path


def test_validate_and_profile_csv_records_required_controls(tmp_path: Path) -> None:
    profile = fr2004.validate_and_profile_csv(write_csv(tmp_path / "fr2004.csv"))

    assert profile.row_count == 3
    assert profile.file_size_bytes > 0
    assert len(profile.sha256) == 64
    assert profile.observation_start == "2024-07-03"
    assert profile.observation_end == "2024-07-10"
    assert profile.duplicate_rows == 0
    assert profile.schema_status == "PASS"


def test_schema_accepts_asterisk_suppression_marker(tmp_path: Path) -> None:
    content = """As Of Date,Time Series,Value (millions),Series Break
2024-07-03,PDPOSGSC-L2,100,SBN2024
2024-07-10,PDPOSGSC-L2,*,SBN2024
"""
    profile = fr2004.validate_and_profile_csv(write_csv(tmp_path / "suppressed.csv", content))

    assert profile.row_count == 2
    assert profile.schema_status == "PASS"


def test_schema_validation_rejects_missing_series_identifier(tmp_path: Path) -> None:
    path = write_csv(tmp_path / "bad.csv", "As Of Date,Value\n2024-07-03,10\n")

    with pytest.raises(fr2004.SchemaValidationError, match="series_id"):
        fr2004.validate_and_profile_csv(path)


def test_duplicate_detection_uses_series_break_series_and_date(tmp_path: Path) -> None:
    duplicate = VALID_CSV + "2024-07-03,PDPOSGSC-L2,999,SBN2024\n"

    with pytest.raises(fr2004.DuplicateObservationError, match="duplicate"):
        fr2004.validate_and_profile_csv(write_csv(tmp_path / "duplicate.csv", duplicate))


def test_ingestion_creates_immutable_raw_file_and_manifest(tmp_path: Path) -> None:
    raw_dir = tmp_path / "data" / "raw" / "fr2004"
    manifest = tmp_path / "data" / "manifests" / "fr2004_manifest.csv"

    result = fr2004.ingest_fr2004(
        raw_dir=raw_dir,
        manifest_path=manifest,
        now=datetime(2026, 7, 19, 12, 30, tzinfo=UTC),
        session=FakeSession(),
    )

    assert result.raw_path.exists()
    assert result.raw_path.name.startswith("fr2004_20260719T123000Z_")
    assert result.download_status == "downloaded"
    assert result.profile.row_count == 3
    assert not result.raw_path.stat().st_mode & 0o200

    with manifest.open("r", encoding="utf-8", newline="") as handle:
        rows = list(csv.DictReader(handle))
    assert rows[0]["sha256"] == result.profile.sha256
    assert rows[0]["schema_status"] == "PASS"
    assert rows[0]["download_status"] == "downloaded"


def test_download_failure_recovers_from_latest_valid_raw_file(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    raw_dir = tmp_path / "raw"
    raw_dir.mkdir()
    cached = write_csv(raw_dir / "fr2004_20260718T120000Z_abc123.csv")
    manifest = tmp_path / "manifest.csv"

    def fail_download(**_kwargs: object) -> fr2004.DownloadMetadata:
        raise fr2004.DownloadError("simulated outage")

    monkeypatch.setattr(fr2004, "_download_to_staging", fail_download)
    result = fr2004.ingest_fr2004(raw_dir=raw_dir, manifest_path=manifest)

    assert result.download_status == "cached_recovery"
    assert result.raw_path == cached
    rows = fr2004.read_manifest(manifest)
    assert rows[0]["download_status"] == "cached_recovery"
    assert "simulated outage" in rows[0]["error_message"]


def test_failed_first_download_is_recorded_and_raised(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    manifest = tmp_path / "manifest.csv"

    def fail_download(**_kwargs: object) -> fr2004.DownloadMetadata:
        raise fr2004.DownloadError("source unavailable")

    monkeypatch.setattr(fr2004, "_download_to_staging", fail_download)
    with pytest.raises(fr2004.DownloadError, match="source unavailable"):
        fr2004.ingest_fr2004(
            raw_dir=tmp_path / "raw",
            manifest_path=manifest,
            allow_cached_recovery=False,
        )

    rows = fr2004.read_manifest(manifest)
    assert rows[0]["download_status"] == "failed"
    assert rows[0]["schema_status"] == "FAIL"
